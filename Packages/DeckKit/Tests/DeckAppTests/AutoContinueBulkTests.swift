//
//  AutoContinueBulkTests.swift · Tests/DeckAppTests
//
//  The two Settings controls, at the runtime seam where they actually act.
//
//  `AutoContinueDefaultsTests` (DeckCore) holds the STANDING DEFAULT and the
//  surface-rename repair, both of which are pure reducer arithmetic. What
//  cannot be tested there is the bulk act: it reads the live fleet to decide
//  which surfaces exist, which is a runtime question, and it has to agree
//  with the sentence the Settings footer prints about it — a button that
//  claims one number and a footer that claims another is the failure mode
//  this file exists to prevent.
//

import Testing
import Foundation
@testable import DeckApp
@testable import DeckAdapters
@testable import DeckCore

@MainActor
struct AutoContinueBulkTests {

    private func hook(_ session: String, surface: String?, id: String) -> HookEvent {
        HookEvent(id: EventID(id), at: .start, kind: .sessionStart, session: SessionID(session),
                  cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
                  host: surface.flatMap { HostAddress(workspace: "WS", surface: $0) })
    }

    /// `markStartedForTesting()` installs a throwaway prefs suite of its own
    /// — that seam's own doc comment records the leak it was added for — so
    /// nothing here can reach the developer's real preferences.
    private func runtime(_ sessions: [(String, String?)]) async -> DeckRuntime {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        for (index, pair) in sessions.enumerated() {
            _ = await runtime.handle(hook(pair.0, surface: pair.1, id: "start-\(index)"))
        }
        return runtime
    }

    // ------------------------------------------------------------ the button

    @Test("Turn On for All arms every addressable session, and says how many it changed")
    func bulkOnArmsEveryAddressableSession() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2"), ("c", "surface:3")])

        let changed = deck.setAutoContinueForAllSessions(true)

        #expect(changed == 3, Comment(rawValue: "reported \(changed) changed, expected 3"))
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (3, 3))
    }

    /// The count is what CHANGED, not what is now true — a button that
    /// reported "3 sessions" after arming one would be claiming work it did
    /// not do.
    @Test("the reported count is what changed, not the total already armed")
    func bulkReportsOnlyRealChanges() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])
        deck.select(SessionID("a"))
        deck.setAutoContinue(true)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (1, 2))

        let changed = deck.setAutoContinueForAllSessions(true)
        #expect(changed == 1, Comment(rawValue: "reported \(changed) changed, expected 1"))
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (2, 2))
    }

    @Test("a second Turn On for All changes nothing and writes nothing")
    func bulkIsIdempotent() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])
        _ = deck.setAutoContinueForAllSessions(true)
        let before = deck.frame

        let changed = deck.setAutoContinueForAllSessions(true)

        #expect(changed == 0)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (2, 2))
        #expect(deck.frame.autoContinueOn == before.autoContinueOn)
    }

    @Test("Turn Off for All disarms everything")
    func bulkOffDisarmsEverything() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])
        _ = deck.setAutoContinueForAllSessions(true)

        let changed = deck.setAutoContinueForAllSessions(false)

        #expect(changed == 2)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 2))
    }

    /// **Hidden sessions are included, deliberately.** Hiding takes a session
    /// off the strip; it does not take it out of the fleet
    /// (`DeckPrefs.hidden`'s own doc comment), and a hidden session stalled
    /// at the usage limit is precisely the one nobody is watching.
    @Test("the bulk act reaches hidden sessions too")
    func bulkReachesHiddenSessions() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])
        deck.select(SessionID("b"))
        deck.hide(SessionID("b"))
        #expect(deck.frame.hidden.contains { $0.session == SessionID("b") },
                "the fixture's own premise: b is actually hidden")

        _ = deck.setAutoContinueForAllSessions(true)

        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (2, 2),
                "a hidden session was skipped — the one nobody is watching is the one that needs this most")
    }

    /// A lane with no host has no surface to key a preference on, so there is
    /// nothing to write. Inventing one would arm something the user cannot
    /// see on the glass to check.
    @Test("a session the deck cannot address is neither armed nor counted")
    func anUnroutableSessionIsNotCounted() async {
        let deck = await runtime([("a", "surface:1"), ("b", nil)])

        let changed = deck.setAutoContinueForAllSessions(true)

        #expect(changed == 1)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (1, 1),
                "a hostless lane was counted, so the footer would promise a session the deck cannot reach")
    }

    @Test("an empty deck's bulk act is a no-op rather than a crash or a write")
    func bulkOnAnEmptyDeckDoesNothing() async {
        let deck = await runtime([])
        #expect(deck.setAutoContinueForAllSessions(true) == 0)
        #expect(deck.setAutoContinueForAllSessions(false) == 0)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 0))
    }

    /// **Arming is TWO facts, and the footer used to count one.**
    ///
    /// `Reducer.arm` skips any session whose `QuickAction.offerable(_:in:)`
    /// set carries no Continue — dragged past the ten-action cap here, the
    /// case `QuickActionTests.continuePastTheCapDisarmsAutoContinue` pins on
    /// the pure side. Counting the preference alone, the footer promised
    /// "All N sessions will continue automatically" about sessions that
    /// never would, and disabled the button as though the job were done.
    @Test("a session with no offerable Continue is neither counted nor promised")
    func aSessionThatCannotContinueIsNotCounted() async {
        let deck = await runtime([("a", "surface:1")])
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 1),
                "the fixture's own premise: Continue is offerable to begin with")

        // Push Continue past the offerable cap, exactly as a drag would.
        var prefs = deck.prefs
        var rows = (0..<10).map { QuickAction(id: "ahead\($0)", title: "T\($0)", kind: .prompt("go")) }
        rows.append(QuickAction.shipped.first { $0.id == QuickAction.continueID }!)
        prefs.quickActions = rows
        deck.setPrefs(prefs)

        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 0), Comment(rawValue:
                "a session the deck cannot send Continue to was still counted, so the footer "
                + "would promise a continuation that `Reducer.arm` will skip"))
        #expect(deck.setAutoContinueForAllSessions(true) == 0,
                "the bulk act wrote a preference the deck has no way to honour")
    }

    /// **A relaunch must not arm the fleet it finds.**
    ///
    /// Modelled the way a relaunch actually works: a second runtime over the
    /// SAME `UserDefaults`, re-discovering already-running sessions through
    /// the FLEET (`.located`), which is the only way it learns about them —
    /// a session that started before the deck did fires no `SessionStart`
    /// the deck can hear.
    ///
    /// This is also the seam that hid a real defect: `setPrefs` used to save
    /// the value it was HANDED rather than the one the reducer settled on, so
    /// reducer-side refinements reached `state.prefs` and never reached disk.
    /// Every in-memory assertion passed while the file was wrong, which is
    /// why this test reads the bytes back rather than the runtime.
    @Test("a relaunch neither arms the fleet it finds nor loses what was on disk")
    func nonRetroactivitySurvivesARelaunch() async {
        let suite = PrefsStore.throwaway()
        let first = DeckRuntime()
        first.markStartedForTesting()
        first.prefsDefaults = suite
        _ = await first.handle(hook("a", surface: "surface:1", id: "s-a"))
        _ = await first.handle(hook("b", surface: "surface:2", id: "s-b"))

        first.setAutoContinueByDefault(true)
        #expect((first.autoContinueCoverage.armed, first.autoContinueCoverage.total) == (0, 2), "armed in memory at the flip")

        // The flag itself has to survive; the bytes are what a relaunch reads.
        let onDisk = PrefsStore.load(from: suite)
        #expect(onDisk.autoContinueByDefault, "the flag never reached disk")

        // The relaunch: a fresh runtime over the same bytes, re-discovering
        // the two running sessions the only way it can — through the fleet.
        let second = DeckRuntime()
        second.markStartedForTesting()
        second.prefsDefaults = suite
        second.setPrefs(onDisk)
        _ = second.apply(.located(SessionID("a"),
                                        host: HostAddress(workspace: "WS", surface: "surface:1")!,
                                        at: .start, id: EventID("loc-a")))
        _ = second.apply(.located(SessionID("b"),
                                        host: HostAddress(workspace: "WS", surface: "surface:2")!,
                                        at: .start, id: EventID("loc-b")))

        #expect(second.prefs.autoContinue.isEmpty, Comment(rawValue:
                "after a relaunch the standing default armed the fleet it found "
                + "(\(second.prefs.autoContinue.sorted())) — the deck would type Continue "
                + "into terminals nobody opted in"))
    }

    /// **A narrow OFF leaves armed entries behind for exactly the sessions
    /// it could not see, and they come back to life.**
    ///
    /// Arm a session, then push Continue out of the offerable set, then
    /// press "Turn Off for All Sessions" — the footer says nothing will
    /// continue. Put Continue back and `Reducer.arm` finds the stale entry
    /// and continues a session the user explicitly disarmed.
    @Test("Turn Off for All reaches sessions whose Continue is not currently offerable")
    func bulkOffReachesSessionsThatCannotCurrentlyContinue() async {
        let deck = await runtime([("a", "surface:1")])
        _ = deck.setAutoContinueForAllSessions(true)
        #expect(deck.prefs.autoContinue == ["surface:1"])

        // Continue leaves the offerable set, so the session drops out of
        // `continuableSurfaces` entirely.
        let shipped = QuickAction.shipped.first { $0.id == QuickAction.continueID }!
        var pushed = deck.prefs
        pushed.quickActions = (0..<10).map {
            QuickAction(id: "ahead\($0)", title: "T\($0)", kind: .prompt("go"))
        } + [shipped]
        deck.setPrefs(pushed)
        #expect(deck.autoContinueCoverage.total == 0, "the fixture's own premise")

        _ = deck.setAutoContinueForAllSessions(false)

        #expect(deck.prefs.autoContinue.isEmpty, Comment(rawValue:
                "Turn Off left \(deck.prefs.autoContinue.sorted()) armed — putting Continue back "
                + "would resume continuing a session the user disarmed"))

        // And putting Continue back must not resurrect anything.
        var restored = deck.prefs
        restored.quickActions = QuickAction.shipped
        deck.setPrefs(restored)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 1),
                "a disarmed session came back armed when Continue returned to the offerable set")
    }

    // ----------------------------------------------------- default vs. bulk

    /// The two controls must not be the same control. Turning the standing
    /// default on arms nothing that already exists; the button is what does
    /// the retroactive thing, on purpose and under its own name.
    @Test("the standing default and the bulk act do genuinely different things")
    func theDefaultAndTheBulkActAreDifferent() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])

        deck.setAutoContinueByDefault(true)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 2),
                "the standing default armed existing sessions, which makes the bulk button redundant")

        _ = deck.setAutoContinueForAllSessions(true)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (2, 2))
    }

    /// **Off must stick.** Disarming one session while the standing default
    /// is ON must survive that session's next host report — otherwise the
    /// switch does not stay where it is put, which is the shape of bug a
    /// person reads as the deck ignoring them.
    @Test("a session disarmed by hand stays disarmed while the standing default is on")
    func aHandDisarmSticksUnderTheStandingDefault() async {
        let deck = await runtime([])
        deck.setAutoContinueByDefault(true)
        _ = await deck.handle(hook("a", surface: "surface:1", id: "start"))
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (1, 1), "the default did not arm a new session")

        deck.select(SessionID("a"))
        deck.setAutoContinue(false)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 1))

        // The same pane keeps talking.
        _ = await deck.handle(hook("a", surface: "surface:1", id: "again"))
        _ = await deck.handle(hook("a2", surface: "surface:1", id: "relaunch"))

        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 1),
                "the standing default re-armed a session the user had just turned off")
    }

    /// A bulk OFF must not be undone by the SAME sessions carrying on —
    /// including the `SessionStart` a session fires again on resume or
    /// `/clear`, which is not a new session however much it looks like one on
    /// the wire.
    @Test("Turn Off for All survives the standing default's next chance to re-arm")
    func bulkOffSticksUnderTheStandingDefault() async {
        let deck = await runtime([])
        deck.setAutoContinueByDefault(true)
        _ = await deck.handle(hook("a", surface: "surface:1", id: "start"))
        _ = deck.setAutoContinueForAllSessions(false)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 1))

        _ = await deck.handle(hook("a", surface: "surface:1", id: "again"))

        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 1),
                "the standing default undid a bulk Turn Off")
    }

    /// **But a genuinely NEW session in one of those tabs IS armed again,
    /// and that is the intended reading of the two controls together.**
    ///
    /// The bulk act is an opinion about the sessions in front of you, not a
    /// standing instruction about their tabs — so it disarms them and records
    /// nothing. An earlier version marked every addressable pane as decided,
    /// which meant one press of "Turn Off for All Sessions" silently voided
    /// the toggle directly above it forever. The per-session switch is the
    /// control that speaks for a tab permanently.
    @Test("a new session in a bulk-disarmed tab is armed again, because the bulk act is not a standing rule")
    func aNewSessionAfterABulkOffIsArmedAgain() async {
        let deck = await runtime([])
        deck.setAutoContinueByDefault(true)
        _ = await deck.handle(hook("a", surface: "surface:1", id: "start"))
        _ = deck.setAutoContinueForAllSessions(false)
        #expect((deck.autoContinueCoverage.armed, deck.autoContinueCoverage.total) == (0, 1))

        // `/exit`, then a brand-new session in the SAME tab.
        _ = await deck.handle(hook("a2", surface: "surface:1", id: "relaunch"))

        #expect(deck.prefs.autoContinue == ["surface:1"], Comment(rawValue:
                "a new session in a bulk-disarmed tab was not armed, though the toggle above the "
                + "button promises new sessions are — the bulk act had become a permanent rule"))
    }

    /// The per-session switch, by contrast, DOES speak for the tab
    /// permanently: that is the whole difference between the two controls.
    @Test("a session disarmed by its own switch keeps the tab disarmed for the next session too")
    func aHandDisarmBindsTheTab() async {
        let deck = await runtime([])
        deck.setAutoContinueByDefault(true)
        _ = await deck.handle(hook("a", surface: "surface:1", id: "start"))
        deck.select(SessionID("a"))
        deck.setAutoContinue(false)

        _ = await deck.handle(hook("a2", surface: "surface:1", id: "relaunch"))

        #expect(deck.prefs.autoContinue.isEmpty,
                "a tab the user turned off by hand armed itself again for the next session")
    }

    // ------------------------------------------------- the lane-keyed setter

    /// **The panel's switch must speak for the lane it names, not for
    /// whatever is selected.**
    ///
    /// Every other control in `SessionActionsPanel` is lane-keyed; the switch
    /// used to borrow `frame.autoContinueOn` / `setAutoContinue()`, both
    /// derived from `state.selected`. The two are equal while the panel is
    /// open from the band — but the toolbar stays live above the scrim, so a
    /// resize out of the banded layout plus a press of "Session Details"
    /// would leave the switch reporting and writing a different session than
    /// the panel header names.
    @Test("the surface-keyed setter writes the session it was given, not the selected one")
    func theSurfaceKeyedSetterIgnoresTheSelection() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])
        deck.select(SessionID("a"))

        deck.setAutoContinue(true, forSurface: "surface:2")

        #expect(deck.prefs.autoContinue == ["surface:2"], Comment(rawValue:
                "wrote \(deck.prefs.autoContinue.sorted()) — the setter followed the selection "
                + "instead of the surface it was handed"))
        // Arming records NO refusal — only a refusal is worth remembering,
        // since an armed pane is already in `autoContinue` and the standing
        // default arming it again is a no-op.
        #expect(deck.prefs.autoContinueRefused.isEmpty)

        // The other direction does record one, for the surface it was given.
        deck.setAutoContinue(false, forSurface: "surface:2")
        #expect(deck.prefs.autoContinueRefused == ["surface:2"])
        #expect(deck.prefs.autoContinue.isEmpty)
    }

    /// The per-lane offerability gate, which decides whether the switch is
    /// drawn at all — the same question `continuableSurfaces` asks of the
    /// whole fleet, asked of one lane.
    @Test("a lane is offered the switch only when the deck could actually continue it")
    func theLaneGateMatchesWhatArmWouldDo() async {
        let deck = await runtime([("a", "surface:1")])
        let lane = deck.frame.lanes.first { $0.session == SessionID("a") }
        #expect(lane != nil, "the fixture's own premise")
        #expect(deck.offersContinue(to: lane!), "Continue is offerable to begin with")

        var pushed = deck.prefs
        pushed.quickActions = (0..<10).map {
            QuickAction(id: "ahead\($0)", title: "T\($0)", kind: .prompt("go"))
        } + [QuickAction.shipped.first { $0.id == QuickAction.continueID }!]
        deck.setPrefs(pushed)

        let after = deck.frame.lanes.first { $0.session == SessionID("a") }!
        #expect(!deck.offersContinue(to: after), Comment(rawValue:
                "the switch would still be drawn for a session `Reducer.arm` will skip"))

        // A lane the deck cannot address is never offered it either.
        let hostless = LaneView(session: SessionID("z"), state: .idle, isExpanded: false,
                                contextPercent: nil, sources: [:])
        #expect(!deck.offersContinue(to: hostless))
    }

    /// **A bulk OFF must also drop offers being held for sessions the deck
    /// cannot address yet.**
    ///
    /// A session that fired `SessionStart` before its pane resolved is parked
    /// in `awaitingAutoContinue`. Without this it was re-armed by its own
    /// held offer seconds after the user disarmed the fleet and read "No
    /// sessions on the deck will continue automatically."
    @Test("Turn Off for All also cancels an offer held for a session it cannot yet address")
    func bulkOffCancelsHeldOffers() async {
        let deck = await runtime([("a", "surface:1")])
        deck.setAutoContinueByDefault(true)
        // Something IS armed, so the bulk act has real work to do — which is
        // also the only state where the button is enabled.
        _ = deck.setAutoContinueForAllSessions(true)
        #expect(deck.prefs.autoContinue == ["surface:1"])
        // A second session starts, unaddressable — its offer is held.
        _ = await deck.handle(HookEvent(
            id: EventID("bare"), at: .start, kind: .sessionStart, session: SessionID("b"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup"))

        _ = deck.setAutoContinueForAllSessions(false)
        #expect(deck.prefs.autoContinue.isEmpty, "the fixture's own premise: the fleet is disarmed")

        // The deck finally places it.
        _ = deck.apply(.located(SessionID("b"),
                                host: HostAddress(workspace: "WS", surface: "surface:2")!,
                                at: .start, id: EventID("loc")))

        #expect(deck.prefs.autoContinue.isEmpty, Comment(rawValue:
                "a held offer re-armed a session just after the user disarmed everything: "
                + "\(deck.prefs.autoContinue.sorted())"))
    }

    /// **Remove selects the session it is about.**
    ///
    /// `requestDelete` records the session on the reducer, but the alert that
    /// gates it reads `frame.selection` for both presentation and the id it
    /// deletes — and `Frame` reports `confirmingDelete` only when the two
    /// agree. This panel is the surface built for the case where lane and
    /// selection diverge, so Remove had to stop riding the selection.
    @Test("removing from the panel raises the confirmation for the session the panel names")
    func removeConfirmsTheLaneItWasOpenedFor() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])
        deck.select(SessionID("a"))

        // What the panel's Remove tile does.
        deck.select(SessionID("b"))
        deck.requestDelete(SessionID("b"))

        #expect(deck.frame.confirmingDelete, Comment(rawValue:
                "no confirmation was raised — Remove would close the panel and do nothing"))
        #expect(deck.frame.selection == SessionID("b"),
                "the confirmation is about a different session than the one being removed")
    }

    /// **"Turn Off for All Sessions" must reach a tab that has gone quiet.**
    ///
    /// The standing default arms a pane at `SessionStart`; that session ends
    /// and the pane stops being addressable, but the entry persists — surface
    /// keys outlive sessions by design. A sweep over the live fleet could
    /// never reach it, and once it was the only entry left the button
    /// disabled itself while the footer read "No sessions on the deck will
    /// continue automatically" — and the next session started in that tab was
    /// continued anyway.
    @Test("Turn Off for All reaches an armed pane whose session is no longer running")
    func bulkOffReachesAQuietPane() async {
        let deck = await runtime([("a", "surface:1")])
        deck.setAutoContinueByDefault(true)
        _ = deck.setAutoContinueForAllSessions(true)
        #expect(deck.prefs.autoContinue == ["surface:1"])

        // A pane armed earlier, whose session is long gone — exactly what the
        // standing default leaves behind.
        var withGhost = deck.prefs
        withGhost.autoContinue.insert("surface:99")
        deck.setPrefs(withGhost)

        #expect(deck.autoContinueCoverage.armedAnywhere == 2, Comment(rawValue:
                "the quiet pane is invisible to the button's own enabled state "
                + "(armedAnywhere = \(deck.autoContinueCoverage.armedAnywhere))"))

        _ = deck.setAutoContinueForAllSessions(false)

        #expect(deck.prefs.autoContinue.isEmpty, Comment(rawValue:
                "a quiet armed pane survived Turn Off for All (\(deck.prefs.autoContinue.sorted())) "
                + "and would continue the next session started in that tab"))
    }

    /// **An unrelated preference write must not cancel held offers.**
    ///
    /// The cancellation used to be INFERRED from the resulting preferences —
    /// "nothing is armed, so the user must have pressed Turn Off for All" —
    /// which fired on any of the dozens of ordinary `setPrefs` writes while
    /// the deck happened to have nothing armed, silently costing a new
    /// session the arming the setting promises it.
    @Test("changing an unrelated setting does not cancel a held auto-continue offer")
    func anUnrelatedSettingDoesNotCancelHeldOffers() async {
        let deck = await runtime([])
        deck.setAutoContinueByDefault(true)
        // Starts, but the deck cannot address it yet — the offer is held.
        _ = await deck.handle(HookEvent(
            id: EventID("bare"), at: .start, kind: .sessionStart, session: SessionID("b"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup"))
        #expect(deck.prefs.autoContinue.isEmpty, "the fixture's own premise: nothing armed yet")

        // Something entirely unrelated.
        var other = deck.prefs
        other.promptHistory = 7
        deck.setPrefs(other)

        // The deck finally places the session.
        _ = deck.apply(.located(SessionID("b"),
                                host: HostAddress(workspace: "WS", surface: "surface:2")!,
                                at: .start, id: EventID("loc")))

        #expect(deck.prefs.autoContinue == ["surface:2"], Comment(rawValue:
                "an unrelated preference write cancelled the held offer, so a new session was "
                + "never armed although the setting promises it"))
    }

    /// **A bulk OFF does not create a standing rule, so a tab it merely
    /// disarmed is armed again for its next session.**
    ///
    /// The button is an opinion about the sessions in front of you. Only the
    /// per-session switch speaks for a tab permanently.
    @Test("a tab the bulk button merely disarmed is armed again for its next session")
    func bulkOffIsNotAStandingRule() async {
        let deck = await runtime([("a", "surface:1")])
        deck.setAutoContinueByDefault(true)
        deck.select(SessionID("a"))
        deck.setAutoContinue(true)
        #expect(deck.prefs.autoContinueRefused.isEmpty, "arming recorded a refusal")

        _ = deck.setAutoContinueForAllSessions(false)
        #expect(deck.prefs.autoContinue.isEmpty)
        #expect(deck.prefs.autoContinueRefused.isEmpty,
                "a bulk disarm invented a refusal it was never asked for")

        _ = await deck.handle(HookEvent(
            id: EventID("relaunch"), at: .start, kind: .sessionStart, session: SessionID("a2"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup", host: HostAddress(workspace: "WS", surface: "surface:1")))

        #expect(deck.prefs.autoContinue == ["surface:1"], Comment(rawValue:
                "a new session in a merely-disarmed tab was not armed, though the toggle promises it"))
    }

    /// **A button labelled "Turn Off" must never be the thing that arms a
    /// tab.**
    ///
    /// Clearing every per-pane decision made exactly that happen: the user
    /// says "never auto-continue this tab" with the per-session switch, later
    /// presses Turn Off for All to disarm the fleet, and the tab's explicit
    /// refusal is destroyed — so the next session started there is armed by
    /// the standing default. Pressing OFF caused an ON. The off decisions are
    /// kept; only the ones being disarmed are dropped.
    @Test("a hand-set OFF survives Turn Off for All, so the button never arms a tab")
    func aHandSetOffSurvivesTheBulkButton() async {
        let deck = await runtime([("a", "surface:1"), ("b", "surface:2")])
        deck.setAutoContinueByDefault(true)

        // One tab is armed; the other the user explicitly refuses.
        deck.select(SessionID("b"))
        deck.setAutoContinue(true)
        deck.select(SessionID("a"))
        deck.setAutoContinue(false)
        #expect(deck.prefs.autoContinue == ["surface:2"])
        #expect(deck.prefs.autoContinueRefused == ["surface:1"],
                "arming surface:2 by hand should record no refusal for it")

        _ = deck.setAutoContinueForAllSessions(false)

        #expect(deck.prefs.autoContinue.isEmpty)
        #expect(deck.prefs.autoContinueRefused == ["surface:1"], Comment(rawValue:
                "the refusal for surface:1 was destroyed by a Turn Off "
                + "(refused = \(deck.prefs.autoContinueRefused.sorted()))"))

        // `/exit` + a brand-new session in the REFUSED tab must stay unarmed.
        _ = await deck.handle(HookEvent(
            id: EventID("relaunch-a"), at: .start, kind: .sessionStart, session: SessionID("a2"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup", host: HostAddress(workspace: "WS", surface: "surface:1")))
        #expect(deck.prefs.autoContinue.isEmpty, Comment(rawValue:
                "pressing Turn Off armed a tab the user had explicitly refused: "
                + "\(deck.prefs.autoContinue.sorted())"))

        // …while the tab that was merely disarmed IS armed again, which is
        // what the toggle above the button promises.
        _ = await deck.handle(HookEvent(
            id: EventID("relaunch-b"), at: .start, kind: .sessionStart, session: SessionID("b2"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup", host: HostAddress(workspace: "WS", surface: "surface:2")))
        #expect(deck.prefs.autoContinue == ["surface:2"],
                "a reset tab was not armed for its next session")
    }

    /// **The sequence that killed the previous fix: refuse, bulk ON, bulk
    /// OFF.**
    ///
    /// The old record held hand-set answers in BOTH directions, so every
    /// reader had to infer which one each was — "decided and armed" was taken
    /// to mean "decided on". "Turn On for All Sessions" arms without
    /// recording anything, so a refused pane it armed then read as an
    /// approval, and the next bulk OFF dropped the refusal. Recording only
    /// refusals removes the inference: bulk ON clears the refusal EXPLICITLY,
    /// because asking for the thing you refused is asking for it, and bulk
    /// OFF then has nothing to guess about.
    @Test("refuse, Turn On for All, Turn Off for All — the tab ends up armed only because the user asked for it")
    func aRefusalClearedByAnExplicitArmStaysCleared() async {
        let deck = await runtime([("a", "surface:1")])
        deck.setAutoContinueByDefault(true)
        deck.select(SessionID("a"))
        deck.setAutoContinue(false)
        #expect(deck.prefs.autoContinueRefused == ["surface:1"])

        // The user explicitly asks for everything to be armed.
        _ = deck.setAutoContinueForAllSessions(true)
        #expect(deck.prefs.autoContinue == ["surface:1"])
        #expect(deck.prefs.autoContinueRefused.isEmpty, Comment(rawValue:
                "an explicit Turn On left the refusal standing, so the two controls disagree "
                + "about the same tab"))

        _ = deck.setAutoContinueForAllSessions(false)
        _ = await deck.handle(HookEvent(
            id: EventID("relaunch"), at: .start, kind: .sessionStart, session: SessionID("a2"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup", host: HostAddress(workspace: "WS", surface: "surface:1")))

        // Armed — and correctly so: the refusal was withdrawn by the user's
        // own Turn On, not guessed away by a Turn Off.
        #expect(deck.prefs.autoContinue == ["surface:1"])

        // The control: without the intervening Turn On, the refusal holds.
        let other = await runtime([("z", "surface:9")])
        other.setAutoContinueByDefault(true)
        other.select(SessionID("z"))
        other.setAutoContinue(false)
        _ = other.setAutoContinueForAllSessions(false)
        _ = await other.handle(HookEvent(
            id: EventID("relaunch-z"), at: .start, kind: .sessionStart, session: SessionID("z2"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup", host: HostAddress(workspace: "WS", surface: "surface:9")))
        #expect(other.prefs.autoContinue.isEmpty, Comment(rawValue:
                "pressing Turn Off armed a tab the user had refused: \(other.prefs.autoContinue.sorted())"))
    }

    /// **An offer outlives its session, and must stay VISIBLE while it
    /// does.**
    ///
    /// The reducer redeems every held offer regardless of whether the
    /// session that made it is still running — that is what makes redemption
    /// order-free (`Reducer.redeemAwaitedAutoContinue`). So the UI may not
    /// quietly stop counting one: hiding an ended session's offer made the
    /// whole Auto-Continue section disappear, and then a fleet poll placed
    /// the session and armed the pane with no control left on screen to stop
    /// it. What will arm must be cancellable.
    @Test("an offer held by an ended session stays visible and cancellable, because it will still arm")
    func anEndedSessionsOfferStaysCancellable() async {
        let deck = await runtime([])
        deck.setAutoContinueByDefault(true)
        _ = await deck.handle(HookEvent(
            id: EventID("bare"), at: .start, kind: .sessionStart, session: SessionID("b"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup"))
        _ = await deck.handle(HookEvent(
            id: EventID("end"), at: .start, kind: .sessionEnd, session: SessionID("b"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent))

        #expect(deck.autoContinueCoverage.heldOffers == 1)
        #expect(deck.autoContinueCoverage.hasAnythingToShow, Comment(rawValue:
                "the section hid an offer that is still going to arm a pane"))

        // And the button can actually cancel it.
        _ = deck.setAutoContinueForAllSessions(false)
        _ = deck.apply(.located(SessionID("b"),
                                host: HostAddress(workspace: "WS", surface: "surface:2")!,
                                at: .start, id: EventID("loc")))
        #expect(deck.prefs.autoContinue.isEmpty, Comment(rawValue:
                "Turn Off could not reach the offer, so the pane armed anyway: "
                + "\(deck.prefs.autoContinue.sorted())"))
    }

    /// The other half: left alone, that offer DOES arm when the pane
    /// resolves — which is why it has to be visible in the first place.
    @Test("an uncancelled offer arms its pane when the deck finally places the session")
    func anUncancelledOfferStillArms() async {
        let deck = await runtime([])
        deck.setAutoContinueByDefault(true)
        _ = await deck.handle(HookEvent(
            id: EventID("bare"), at: .start, kind: .sessionStart, session: SessionID("b"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent,
            source: "startup"))
        _ = await deck.handle(HookEvent(
            id: EventID("end"), at: .start, kind: .sessionEnd, session: SessionID("b"),
            cwd: Redacted("/work/project"), tool: nil, toolUseID: nil, held: .absent))

        _ = deck.apply(.located(SessionID("b"),
                                host: HostAddress(workspace: "WS", surface: "surface:2")!,
                                at: .start, id: EventID("loc")))

        #expect(deck.prefs.autoContinue == ["surface:2"],
                "the offer was silently forfeited, so the setting did not do what it promises")
    }

    // -------------------------------------------------------- the sentence

    /// The footer is a claim about the fleet, so it is pinned as a table
    /// rather than left to read right at one sample. Singular/plural agrees
    /// with the TOTAL, which is the noun the verb attaches to, and the
    /// all-armed case says "All" rather than "3 of 3" because that is the
    /// state a person is trying to reach and deserves to be told plainly.
    /// The hidden sentence has the same job and the same trap: it must
    /// report what is OBSERVABLE, because `prefs.hidden` counts surfaces —
    /// and a pane can legitimately be named twice there while two sessions
    /// share it and one is re-spelled, or named once with nothing running in
    /// it at all.
    @Test("the hidden sentence reports sessions on the deck, not entries in the preference",
          arguments: [
            (0, "The hidden sessions are not running right now."),
            (1, "1 session is hidden from the deck."),
            (3, "3 sessions are hidden from the deck."),
          ])
    func theHiddenSentenceReadsCorrectly(_ onDeck: Int, _ expected: String) {
        #expect(DeckSettingsView.hiddenSentence(onDeck: onDeck) == expected)
    }

    /// **The footer must not say "none" over the top of a line saying
    /// "one".** The two sentences were composed blind, and three reachable
    /// states had the first asserting that nothing would continue
    /// automatically while the second named a session that would.
    ///
    /// Covers BOTH things that can continue while the countable set is
    /// empty — an offer still being placed, and a pane armed in the
    /// preferences whose session is not currently continuable — plus the one
    /// case where the absolute "will continue automatically" is actually
    /// true.
    ///
    /// **Asserts the WHOLE sentence, not a substring.** An earlier version
    /// checked only that it contained "armed", which let it pass while
    /// rendering "No sessions on the deck IS armed to continue
    /// automatically" — the suite producing an ungrammatical string and
    /// calling it green.
    @Test("the coverage sentence never promises nothing will continue while something still will",
          arguments: [
            // Nothing on the deck offers Continue, nothing armed, one pending.
            (DeckRuntime.AutoContinueCoverage(armed: 0, total: 0, armedAnywhere: 1,
                                              heldOffers: 1, refusals: 0),
             "No session on the deck is armed to continue automatically."),
            // A pane armed from an earlier session, none offering Continue now,
            // one pending — the third state, and the one that survived.
            (DeckRuntime.AutoContinueCoverage(armed: 0, total: 0, armedAnywhere: 2,
                                              heldOffers: 1, refusals: 0),
             "No session on the deck is offered Continue right now."),
            // Sessions on the deck, none armed, one pending — plural agreement.
            (DeckRuntime.AutoContinueCoverage(armed: 0, total: 3, armedAnywhere: 1,
                                              heldOffers: 1, refusals: 0),
             "No sessions on the deck are armed to continue automatically."),
            // One session, so the verb is singular.
            (DeckRuntime.AutoContinueCoverage(armed: 0, total: 1, armedAnywhere: 1,
                                              heldOffers: 1, refusals: 0),
             "No session on the deck is armed to continue automatically."),
            // **No pending offer at all — the absence is owed to an ARMED
            // pane whose session is not currently continuable.** A quiet tab,
            // or one whose Continue was dragged past the cap: it really will
            // continue the next session started in it, and it keeps "Turn Off
            // for All Sessions" enabled directly above this line.
            (DeckRuntime.AutoContinueCoverage(armed: 0, total: 0, armedAnywhere: 1,
                                              heldOffers: 0, refusals: 0),
             "No session on the deck is offered Continue right now."),
            (DeckRuntime.AutoContinueCoverage(armed: 0, total: 2, armedAnywhere: 1,
                                              heldOffers: 0, refusals: 0),
             "No sessions on the deck are armed to continue automatically."),
            // And the one case where the absolute IS true: nothing armed,
            // nothing pending, nothing waiting in the preferences.
            (DeckRuntime.AutoContinueCoverage(armed: 0, total: 2, armedAnywhere: 0,
                                              heldOffers: 0, refusals: 0),
             "No sessions on the deck will continue automatically."),
          ])
    func theCoverageSentenceDefersToPendingOffers(
        _ coverage: DeckRuntime.AutoContinueCoverage, _ expected: String) {
        // **The whole sentence, and nothing else.** Two extra guards were
        // tried here and both were worse than this line.
        //
        // Recomputing `prefArmed > 0 || heldOffers > 0` to decide whether the
        // absolute was allowed was tautological: change the production
        // formula and the copy changes with it. Replacing that with a
        // hand-written per-case column removed the tautology and bought a new
        // hazard — a row added with the wrong flag disables its own guard
        // silently — for no coverage at all, because `expected` pins the
        // entire literal sentence, so any row that wrongly rendered the
        // absolute fails on THIS comparison before a guard could run.
        //
        // The invariant has no statement independent of the rule it is about;
        // it IS the rule. What holds it honest is that every row spells its
        // sentence out in full, so a change to the rule must be re-argued
        // row by row rather than absorbed by a predicate.
        let got = DeckSettingsView.coverageSentence(coverage)
        #expect(got == expected, Comment(rawValue: "read: \(got)"))
    }

    @Test("the coverage sentence reads correctly at every shape of fleet",
          arguments: [
            (0, 0, "No sessions on the deck will continue automatically."),
            (0, 1, "No session on the deck will continue automatically."),
            (0, 4, "No sessions on the deck will continue automatically."),
            (1, 1, "The one session on the deck will continue automatically."),
            (1, 4, "1 of 4 sessions on the deck will continue automatically."),
            (3, 4, "3 of 4 sessions on the deck will continue automatically."),
            (4, 4, "All 4 sessions on the deck will continue automatically."),
          ])
    func theCoverageSentenceReadsCorrectly(_ armed: Int, _ total: Int, _ expected: String) {
        let got = DeckSettingsView.coverageSentence(.init(armed: armed, total: total, armedAnywhere: armed, heldOffers: 0, refusals: 0))
        #expect(got == expected, Comment(rawValue: "armed \(armed) of \(total) read: \(got)"))
    }
}
