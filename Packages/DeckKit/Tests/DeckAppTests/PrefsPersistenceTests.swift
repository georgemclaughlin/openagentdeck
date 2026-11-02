//
//  PrefsPersistenceTests.swift · Tests/DeckAppTests
//
//  The persistence half of card-colour auto-assignment, driven through the
//  real seams rather than read off the reducer: `DeckRuntime.setPrefs`,
//  `DeckRuntime.handle` (the same funnel `PanelDrainTests` and
//  `HoldBudgetRuntimeTests` drive), and `loadPrefs` (a test seam of its own —
//  see that method's doc comment for why `start()` itself cannot run here).
//
//  The reducer-side assignment
//  (`CardColorTests`, `HostIdentityTests`, both in `DeckCoreTests`) was
//  arbitered end to end, but the DISK half — `lastPersistedPrefs`, the
//  equality-guarded save in `apply(_:)`, the pre-set ordering in `setPrefs`
//  and `loadPrefs` that keeps an explicit change or a launch from writing
//  twice — had nothing checking it ran at all. These tests read the
//  throwaway `UserDefaults` suite's ACTUAL bytes back, through `PrefsStore`,
//  rather than trusting `DeckRuntime`'s own bookkeeping to grade its own
//  homework.
//

import Testing
import Foundation
import DeckCore
import DeckAdapters
@testable import DeckApp

/// A `UserDefaults` that counts writes instead of only performing them —
/// the one way to arbiter "saved exactly once" and "saved nothing" from
/// OUTSIDE `DeckRuntime`, which exposes no write-count of its own by design
/// (the prefs-adapter-owns-storage rule: only `PrefsStore` may know
/// `UserDefaults` exists, so `DeckRuntime` cannot be asked "how many times
/// did you write" any other way). `UserDefaults` is a plain, non-final
/// class and `set(_:forKey:)` is the one entry point every write in this
/// codebase goes through (`PrefsStore.save`'s only call), so overriding
/// just that method counts exactly the calls that matter.
final class SpyDefaults: UserDefaults {
    private(set) var writeCount = 0

    override func set(_ value: Any?, forKey defaultName: String) {
        writeCount += 1
        super.set(value, forKey: defaultName)
    }
}

@MainActor
struct PrefsPersistenceTests {

    /// The same hermetic-suite idiom `PrefsStore.throwaway()` uses, naming
    /// the spy subclass instead of the plain `UserDefaults` that function
    /// returns — a unique suite per call, so no test's writes are visible
    /// to another's.
    private func spyDefaults() -> SpyDefaults {
        SpyDefaults(suiteName: "spy-\(UUID().uuidString)")!
    }

    /// `cwd` defaults to nil so any call site testing something unrelated
    /// to colour keeps reading as it always has; every colour test below
    /// supplies one explicitly, since assignment fires off the DIRECTORY
    /// now, not the host surface.
    private func hostedStart(_ session: SessionID, surface: String, cwd: String? = nil) -> HookEvent {
        HookEvent(id: EventID("start-\(session.raw)"), at: .start, kind: .sessionStart,
                 session: session, cwd: cwd.map(Redacted.init), tool: nil, toolUseID: nil, held: .absent,
                 host: HostAddress(workspace: "WS", surface: surface))
    }

    // -------------------------------------------------------------- setPrefs

    /// `setPrefs`'s own doc comment claims exactly one `PrefsStore.save` per
    /// call — the tracker is pre-set before the reducer runs specifically so
    /// the funnel's own equality-guarded save (added for card-colour
    /// auto-assignment) sees no difference and stays quiet. Unverified,
    /// that pre-set is just an assertion in a comment; this is what makes it
    /// a fact about the code.
    @Test("an explicit setPrefs writes to disk exactly once")
    func setPrefsWritesExactlyOnce() {
        let runtime = DeckRuntime()
        // `markStartedForTesting()` itself resets `prefsDefaults` to a
        // throwaway suite, so the spy has to be installed AFTER it, not
        // before — the same ordering every test below follows.
        runtime.markStartedForTesting()
        let spy = spyDefaults()
        runtime.prefsDefaults = spy

        var next = runtime.prefs
        next.hidden.insert("surface-under-test")
        runtime.setPrefs(next)

        #expect(spy.writeCount == 1, Comment(rawValue:
                "setPrefs wrote \(spy.writeCount) times, not exactly once — the pre-set " +
                "lastPersistedPrefs ordering no longer suppresses the funnel's own save"))
    }

    // --------------------------------------------------------- auto-assignment

    /// The claim `HostIdentityTests` pins at the reducer — a hosted
    /// `SessionStart` earns a recorded assignment — carried one layer
    /// further: through the runtime's real `handle` funnel and onto the
    /// throwaway suite's actual bytes, read back through `PrefsStore` like
    /// any other consumer would.
    @Test("a hosted hook event that earns a fresh card colour reaches disk")
    func hostedHookEventPersistsItsAssignment() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let spy = spyDefaults()
        runtime.prefsDefaults = spy

        let session = SessionID("s-persist")
        let dir = "/w/persist"
        _ = await runtime.handle(hostedStart(session, surface: "SURF-PERSIST", cwd: dir))

        let onDisk = PrefsStore.load(from: spy)
        let expected = CardColor.slot(CardColor.fallbackSlot(for: dir))
        #expect(onDisk.directoryColors[dir] == expected,
                "the fresh assignment did not reach the throwaway suite's actual bytes")
    }

    /// The other half of "only the tick that earns a fresh entry touches
    /// disk": a second event for a directory that already has a colour must
    /// leave the write count exactly where the first event left it. Two
    /// events through the SAME spy, so the count itself — not a
    /// reconstruction of what "already existed" means — is the arbiter.
    @Test("a hook event for a directory that already has a colour writes nothing new")
    func ordinaryHookEventWithAnExistingColorWritesNothing() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let spy = spyDefaults()
        runtime.prefsDefaults = spy

        let session = SessionID("s-quiet")
        let surface = "SURF-QUIET"
        let dir = "/w/quiet"
        _ = await runtime.handle(hostedStart(session, surface: surface, cwd: dir))
        #expect(spy.writeCount == 1,
                "the setup event itself did not persist — the count below cannot be trusted until this does")
        let writesAfterAssignment = spy.writeCount

        let ordinary = HookEvent(id: EventID("post-quiet"), at: .start, kind: .postToolUse,
                                 session: session, cwd: Redacted(dir), tool: "Bash", toolUseID: "t1",
                                 held: .absent, host: HostAddress(workspace: "WS", surface: surface))
        _ = await runtime.handle(ordinary)

        #expect(spy.writeCount == writesAfterAssignment, Comment(rawValue:
                "an ordinary event with no new assignment wrote to disk anyway " +
                "(\(spy.writeCount - writesAfterAssignment) extra write(s))"))
    }

    // -------------------------------------------------------------- launch

    /// The redundant-write guard `loadPrefs`'s own comment claims: reading
    /// back a prefs file that already exists must not write the same bytes
    /// straight to disk a second time. `loadPrefs` is the narrow seam —
    /// see its doc comment for why `start()` itself cannot run headless.
    @Test("loading existing prefs at launch writes nothing back")
    func launchWritesNothingWhenPrefsAlreadyExist() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let spy = spyDefaults()
        runtime.prefsDefaults = spy
        // Hermeticity, not a premise of THIS test: `loadPrefs()` also runs
        // the accessibility read now (`refreshAccessibility()`), and the
        // default seam closure would read the MACHINE's real Reduce Motion
        // setting — harmless to the write-count assertions below today, but
        // a determinism debt the first frame assertion added here would
        // inherit. Scripted flat, like every other seam this test stubs.
        runtime.readsReduceMotion = { false }

        // Pre-populate the suite exactly the way a previous run would have
        // left it — through `PrefsStore` itself, not by poking at raw Data.
        var existing = DeckPrefs()
        existing.hidden = ["already-there"]
        existing.directoryColors = ["/w/already-colored": .slot(6)]
        PrefsStore.save(existing, to: spy)
        let writesFromSetup = spy.writeCount

        runtime.loadPrefs()

        #expect(spy.writeCount == writesFromSetup, Comment(rawValue:
                "loading prefs that already existed wrote " +
                "\(spy.writeCount - writesFromSetup) time(s) more — the pre-set lastPersistedPrefs " +
                "ordering in loadPrefs stopped suppressing the funnel's redundant save"))
        #expect(runtime.prefs.hidden == existing.hidden,
                "the loaded value did not reach state.prefs even though nothing was written")
        #expect(runtime.prefs.directoryColors == existing.directoryColors)
    }

    // ------------------------------------------------------- setCardColor

    /// `setCardColor`'s own doc comment claims exactly one write per call —
    /// the same claim `setPrefsWritesExactlyOnce` pins for `setPrefs`
    /// itself, carried one layer up to the picker's actual entry point.
    @Test("setting a card colour to a palette slot saves exactly once")
    func settingACardColorSavesExactlyOnce() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let session = SessionID("s-pick-slot")
        let dir = "/w/pick-slot"
        _ = await runtime.handle(hostedStart(session, surface: "SURF-PICK-SLOT", cwd: dir))

        let spy = spyDefaults()
        runtime.prefsDefaults = spy

        // A slot other than whatever fallbackSlot/assign already landed on,
        // so the write below is guaranteed to be a real change and not
        // silently absorbed by the `next != state.prefs` guard.
        let already = runtime.prefs.directoryColors[dir]
        let chosen = CardColor.slot((CardColor.fallbackSlot(for: dir) + 1) % CardColor.paletteCount)
        #expect(already != chosen, "the fixture's own premise: picking a colour that differs from the assigned one")

        runtime.setCardColor(chosen, for: session)

        #expect(spy.writeCount == 1, Comment(rawValue:
                "setCardColor wrote \(spy.writeCount) times, not exactly once"))
        let onDisk = PrefsStore.load(from: spy)
        #expect(onDisk.directoryColors[dir] == chosen,
                "the chosen slot did not reach the throwaway suite's actual bytes")
    }

    /// "Automatic" removes the stored entry and immediately re-records what
    /// a fresh arrival would get right now — `setCardColor`'s own doc
    /// comment states the rule; this pins it against the identical
    /// `CardColor.fallbackSlot`/`.assign` pair the reducer runs, computed
    /// here independently so the test cannot pass merely by calling the
    /// same code under test twice.
    @Test("Automatic reassigns the way a fresh arrival would, landing in the same gesture")
    func automaticReassignsTheWayAFreshArrivalWould() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let session = SessionID("s-automatic")
        let dir = "/w/automatic"
        _ = await runtime.handle(hostedStart(session, surface: "SURF-AUTOMATIC", cwd: dir))

        let spy = spyDefaults()
        runtime.prefsDefaults = spy

        runtime.setCardColor(.custom(red: 0.2, green: 0.4, blue: 0.6), for: session)
        #expect(spy.writeCount == 1, "the custom pick itself did not write exactly once")
        #expect(runtime.prefs.directoryColors[dir] == .custom(red: 0.2, green: 0.4, blue: 0.6))

        runtime.setCardColor(nil, for: session)

        #expect(spy.writeCount == 2, Comment(rawValue:
                "Automatic wrote \(spy.writeCount - 1) time(s), not exactly one additional write"))

        // The independent prediction — computed from `fallbackSlot` alone,
        // never from `runtime.prefs` (which already holds the answer under
        // test, and reading it back into the prediction would make this
        // test pass no matter what `setCardColor(nil:)` actually wrote).
        // Valid because this fixture has exactly one live directory: with
        // no OTHER directory holding a slot, `CardColor.assign` always
        // returns `preferred` outright — the same fact
        // `hostedHookEventPersistsItsAssignment` above already pins for the
        // ordinary (non-Automatic) path, reused here for the Automatic one.
        let predicted = CardColor.slot(CardColor.fallbackSlot(for: dir))
        #expect(runtime.prefs.directoryColors[dir] == predicted, Comment(rawValue:
                "Automatic landed \(String(describing: runtime.prefs.directoryColors[dir])), not the " +
                "fresh-arrival prediction \(predicted)"))

        let onDisk = PrefsStore.load(from: spy)
        #expect(onDisk.directoryColors[dir] == predicted,
                "the reassigned colour did not reach the throwaway suite's actual bytes")
    }

    /// The `hide`/`unhide` precedent, carried to `setCardColor`: a lane with
    /// no resolved DIRECTORY has nothing to key a colour preference on, and
    /// the call declines silently — belt-and-braces beside the control's
    /// own `lane.directory != nil` gate, arbitered here by write count
    /// rather than by inspecting the prefs value (a no-op write would leave
    /// the value unchanged too, which is a weaker claim than "nothing wrote
    /// at all"). No `host:` either, in this fixture — the simplest way to
    /// have no `cwd` — but the guard this pins is on the directory, not the
    /// host; `setCardColorOnAHostedButDirectorylessSessionWritesNothing`
    /// just below pins the sharper case where a host DOES exist.
    @Test("setCardColor on a directory-less session leaves prefs untouched")
    func setCardColorOnADirectorylessSessionWritesNothing() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let spy = spyDefaults()
        runtime.prefsDefaults = spy

        // Seeded straight through the reducer-seam, with no `host:` and no
        // `cwd:` at all.
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("hostless-start"), at: .start, kind: .sessionStart,
                            session: SessionID("s-hostless"), cwd: nil, tool: nil, toolUseID: nil,
                            held: .absent)),
        ]))

        runtime.setCardColor(.slot(2), for: SessionID("s-hostless"))

        #expect(spy.writeCount == 0, Comment(rawValue:
                "a directory-less session's colour write reached disk \(spy.writeCount) time(s) — " +
                "the hide precedent's silent decline did not hold"))
    }

    /// The sharper case: a lane WITH a resolved host (so Hide, and the old
    /// surface-keyed gate, would have let this through) but no `cwd` yet.
    /// `setCardColor`'s gate is on the DIRECTORY specifically — a host
    /// alone must not be mistaken for enough to key a colour write on.
    @Test("setCardColor on a hosted but directory-less session leaves prefs untouched")
    func setCardColorOnAHostedButDirectorylessSessionWritesNothing() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let spy = spyDefaults()
        runtime.prefsDefaults = spy

        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("hosted-no-dir"), at: .start, kind: .sessionStart,
                            session: SessionID("s-hosted-no-dir"), cwd: nil, tool: nil, toolUseID: nil,
                            held: .absent, host: HostAddress(workspace: "WS", surface: "SURF-NO-DIR"))),
        ]))

        runtime.setCardColor(.slot(2), for: SessionID("s-hosted-no-dir"))

        #expect(spy.writeCount == 0, Comment(rawValue:
                "a hosted-but-directory-less session's colour write reached disk " +
                "\(spy.writeCount) time(s) — the host alone must not satisfy the directory gate"))
    }
}
