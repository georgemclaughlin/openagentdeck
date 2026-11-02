//
//  AutoContinueDefaultsTests.swift · Tests/DeckCoreTests
//
//  The standing default for auto-continue, and the surface-rename repair it
//  shares with every other surface-keyed preference.
//
//  **What makes this feature hard is not the switch, it is the word
//  "default".** A default that is a READ-TIME fallback cannot represent "I
//  turned this one off" — absence would mean both "never decided" and
//  "explicitly declined" — so it re-arms a session the instant after a
//  person disarms it. `DeckPrefs.autoContinueByDefault` is therefore applied
//  at WRITE time, on a session actually STARTING, and `autoContinueRefused`
//  records the one answer that has to overrule it — the user's own "never
//  this tab". Only refusals are kept: a pane the user armed needs no record,
//  since it is already in `autoContinue` and arming it again is a no-op, and
//  keeping both directions forced every reader to GUESS which one an entry
//  was. Most of the cases below exist to hold that distinction rather than
//  the happy path.
//
//  The other half is that `autoContinue` is keyed on the SURFACE, and a
//  surface has two spellings (`Reducer.followSurfaceRename`'s own doc
//  comment, and [the LV32 evidence it cites]): the hook reports the
//  `CMUX_SURFACE_ID` UUID pair, `cmux tree` answers in short refs. Every
//  surface-keyed preference loses its entry when the spelling flips, and for
//  auto-continue that loss is SILENT — a session quietly stops being armed
//  and says nothing until a usage limit arrives and nothing continues.
//

import Testing
@testable import DeckCore

struct AutoContinueDefaultsTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private let s1 = SessionID("s1")
    private let s2 = SessionID("s2")

    /// A session start carrying a host, so the lane has a SURFACE for the
    /// default to key on.
    private func start(_ session: SessionID, surface: String, ms: Int64,
                       id: String? = nil) -> DeckEvent {
        .hook(HookEvent(id: EventID(id ?? "start-\(session.raw)-\(ms)"), at: at(ms),
                        kind: .sessionStart, session: session, cwd: Redacted("/w/app"),
                        tool: nil, toolUseID: nil, held: .absent,
                        host: HostAddress(workspace: "WS", surface: surface)))
    }

    private func prefs(_ state: DeckState) -> DeckPrefs { state.prefs }

    // ------------------------------------------------------- the default off

    @Test("with the default off, a brand-new session is not armed and leaves no record behind")
    func defaultOffArmsNothing() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))

        #expect(prefs(state).autoContinue.isEmpty)
        #expect(prefs(state).autoContinueRefused.isEmpty,
                "a default that is OFF still marked a pane as offered, which would suppress it later")
    }

    // -------------------------------------------------------- the default on

    @Test("with the default on, a brand-new session is armed as its surface is learned")
    func defaultOnArmsANewSession() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))

        #expect(prefs(state).autoContinue == ["surface:12"])
        // And the pane is NOT marked decided: that set is the user's own
        // opinions, and a pane the deck armed on its own must stay eligible
        // for the next session that starts in it.
        #expect(prefs(state).autoContinueRefused.isEmpty,
                "the deck recorded its OWN choice as the user's, which would freeze the pane out")
    }

    /// **A session the fleet merely DISCOVERS is not armed.** It was already
    /// running before the deck knew it existed, which is not what "new
    /// session" means to the person reading the label — and arming everything
    /// the deck finds is what made an earlier design arm the whole fleet
    /// after a relaunch. The lane here is created by an ordinary mid-session
    /// hook, never by a `SessionStart`, which is exactly how a
    /// fleet-discovered session reaches the deck.
    @Test("a session the fleet merely discovers is not armed by the standing default")
    func aDiscoveredSessionIsNotArmed() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("mid"), at: at(10), kind: .stop, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent)))
        Reducer.reduce(&state, .located(s1, host: HostAddress(workspace: "WS", surface: "surface:27")!,
                                        at: at(20), id: EventID("loc")))

        #expect(prefs(state).autoContinue.isEmpty, Comment(rawValue:
                "a session that was already running got armed just for being discovered — "
                + "after a relaunch that is the entire fleet: \(prefs(state).autoContinue)"))
    }

    /// **But a session that genuinely STARTED keeps its offer until the deck
    /// can address it.**
    ///
    /// `HostAddress` is failable on either half, so a `SessionStart` can
    /// arrive before the pane is resolvable. Spending the default's one
    /// chance on that nil used to forfeit it forever: no later hook and no
    /// later `.located` retried, and the user saw the setting switched on
    /// above a brand-new session that was never armed, with nothing said.
    @Test("a new session placed only after it started still gets the standing default")
    func aNewSessionPlacedLaterIsStillArmed() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
        // It STARTED — but the deck cannot address it yet.
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("bare-start"), at: at(10), kind: .sessionStart, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent)))
        #expect(prefs(state).autoContinue.isEmpty, "armed a lane with no surface to key on")

        Reducer.reduce(&state, .located(s1, host: HostAddress(workspace: "WS", surface: "surface:27")!,
                                        at: at(20), id: EventID("loc")))

        #expect(prefs(state).autoContinue == ["surface:27"], Comment(rawValue:
                "a session that started while the setting was on was never armed, because the "
                + "deck could not address it at the instant it started"))
    }

    /// And the held-open offer is still subject to the user's own decision —
    /// it is a deferred default, not a licence to overrule one.
    @Test("a held-open offer still yields to a pane the user has decided")
    func aHeldOfferRespectsADecidedPane() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(autoContinueByDefault: true, autoContinueRefused: ["surface:27"]), at: at(0)))
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("bare-start"), at: at(10), kind: .sessionStart, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent)))
        Reducer.reduce(&state, .located(s1, host: HostAddress(workspace: "WS", surface: "surface:27")!,
                                        at: at(20), id: EventID("loc")))

        #expect(prefs(state).autoContinue.isEmpty,
                "a deferred default overruled a pane the user had turned off")
    }

    /// **The case the pane-keyed design got wrong, and the reason the record
    /// now means "the user decided" rather than "already offered".**
    ///
    /// `/exit` and a fresh session in the same tab is the commonest way a new
    /// session appears on this deck. Under a record of panes-already-offered,
    /// that tab was permanently ineligible and the new session was never
    /// armed, although the setting promises exactly that.
    @Test("a NEW session started in a tab the deck already knows is armed by the default")
    func aNewSessionInAKnownPaneIsArmed() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))

        // The user turns the standing default on with that tab already open.
        var on = prefs(state)
        on.autoContinueByDefault = true
        Reducer.reduce(&state, .prefsChanged(on, at: at(20)))
        #expect(prefs(state).autoContinue.isEmpty, "armed retroactively at the flip")

        // `/exit`, then a brand-new session in the SAME tab.
        Reducer.reduce(&state, start(s2, surface: "surface:12", ms: 30, id: "relaunch"))

        #expect(prefs(state).autoContinue == ["surface:12"],
                "a new session in a tab the deck had already seen was never armed")
    }

    /// **The case a read-time default cannot express.** The whole reason
    /// `autoContinueRefused` exists.
    @Test("a session turned OFF by hand stays off, however many more hooks it sends")
    func anExplicitOffIsNeverUndoneByTheDefault() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))
        #expect(prefs(state).autoContinue == ["surface:12"])

        // The user turns it off — which is what `DeckRuntime.setAutoContinue`
        // does: clear the arming AND record that this pane is the user's own
        // decision now, so the standing default stops applying to it.
        var off = prefs(state)
        off.autoContinue.remove("surface:12")
        off.autoContinueRefused.insert("surface:12")
        Reducer.reduce(&state, .prefsChanged(off, at: at(20)))

        // Three more hooks from the same pane — a turn, a stop, a new session
        // in the same tab.
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 30, id: "again"))
        Reducer.reduce(&state, start(s2, surface: "surface:12", ms: 40, id: "relaunch"))
        Reducer.reduce(&state, .located(s1, host: HostAddress(workspace: "WS", surface: "surface:12")!,
                                        at: at(50), id: EventID("loc")))

        #expect(prefs(state).autoContinue.isEmpty,
                "the standing default re-armed a session the user had turned off")
    }

    @Test("turning the default ON does not arm sessions already on the deck")
    func thedefaultIsNotRetroactive() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))
        Reducer.reduce(&state, start(s2, surface: "surface:37", ms: 20))
        #expect(prefs(state).autoContinue.isEmpty)

        var on = prefs(state)
        on.autoContinueByDefault = true
        Reducer.reduce(&state, .prefsChanged(on, at: at(30)))

        #expect(prefs(state).autoContinue.isEmpty, Comment(rawValue:
                "flipping the standing default retroactively armed existing sessions — "
                + "that is what the bulk button is for, and it would make the button redundant"))

        // **And it must still be empty after the sessions go on living.**
        // Asserting only at the instant of the flip is what let this ship:
        // the seeding runs on every host report, so an existing session is
        // armed by its next ORDINARY hook, not by the flip itself. One stop
        // and one fleet re-location is all it takes.
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("stop"), at: at(40), kind: .stop, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
            host: HostAddress(workspace: "WS", surface: "surface:12"))))
        Reducer.reduce(&state, .located(s2, host: HostAddress(workspace: "WS", surface: "surface:37")!,
                                        at: at(50), id: EventID("loc")))

        #expect(prefs(state).autoContinue.isEmpty, Comment(rawValue:
                "an ordinary hook armed a session that existed before the default was turned on — "
                + "the deck would start typing into terminals nobody opted in: \(prefs(state).autoContinue)"))
    }

    @Test("a pane that arrives AFTER the default is turned on is armed, unlike the ones already there")
    func aPaneArrivingAfterTheFlipIsArmed() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))

        var on = prefs(state)
        on.autoContinueByDefault = true
        Reducer.reduce(&state, .prefsChanged(on, at: at(20)))
        Reducer.reduce(&state, start(s2, surface: "surface:99", ms: 30))

        #expect(prefs(state).autoContinue == ["surface:99"])
    }

    /// **Determinism, and duplicate delivery — two different questions, and
    /// an earlier version of this test asked neither.**
    ///
    /// It compared `run(events)` against `run(events + events)`, which is not
    /// a replay at all: `.prefsChanged` replaces the WHOLE preferences value,
    /// so the second copy reset the arming and the comparison was between two
    /// different event streams. What the wire actually promises is that the
    /// same stream lands the same way, and that a re-delivered event
    /// (same id) changes nothing.
    @Test("the standing default is deterministic, and a re-delivered hook changes nothing")
    func seedingIsDeterministicAndDuplicateSafe() {
        let events: [DeckEvent] = [
            .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)),
            start(s1, surface: "surface:12", ms: 10),
            start(s2, surface: "surface:37", ms: 20),
        ]

        var once = DeckState()
        for e in events { Reducer.reduce(&once, e) }
        var again = DeckState()
        for e in events { Reducer.reduce(&again, e) }
        #expect(once.prefs.autoContinue == again.prefs.autoContinue,
                "the same stream landed two different ways")
        #expect(once.prefs.autoContinue == ["surface:12", "surface:37"])

        // The SAME hook arriving twice — the wire promises no de-duplication,
        // so the reducer has to. Re-delivering a session's start must not
        // arm a pane the user has since turned off.
        var redelivered = once
        var off = redelivered.prefs
        off.autoContinue.remove("surface:12")
        off.autoContinueRefused.insert("surface:12")
        Reducer.reduce(&redelivered, .prefsChanged(off, at: at(30)))
        Reducer.reduce(&redelivered, start(s1, surface: "surface:12", ms: 10))

        #expect(redelivered.prefs.autoContinue == ["surface:37"],
                "a re-delivered SessionStart re-armed a pane the user had turned off")
    }

    /// **A held-open offer must not outlive the switch that created it.**
    ///
    /// Proven repro: start a session the deck cannot place yet (offer held),
    /// turn the default OFF, let the session be located, turn it back ON
    /// hours later — and the next ordinary hook from that old session armed
    /// it. Nothing had started; the offer had simply been left lying.
    @Test("an offer held while the default was on is discarded when it is turned off")
    func aHeldOfferDiesWithTheDefault() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("bare-start"), at: at(10), kind: .sessionStart, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, source: "startup")))

        // Turned off while the offer is still outstanding.
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: false), at: at(20)))
        Reducer.reduce(&state, .located(s1, host: HostAddress(workspace: "WS", surface: "S27")!,
                                        at: at(30), id: EventID("loc")))
        #expect(prefs(state).autoContinue.isEmpty, "armed while the default was off")

        // Turned back on much later. Nothing has STARTED since.
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(40)))
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("tick"), at: at(50), kind: .stop, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
            host: HostAddress(workspace: "WS", surface: "S27"))))

        #expect(prefs(state).autoContinue.isEmpty, Comment(rawValue:
                "a stale offer armed a session hours after the fact (\(prefs(state).autoContinue.sorted())) "
                + "— retroactive arming through the back door"))
    }

    /// **`source` is what tells a session that BEGAN from one that merely
    /// re-announced itself**, and the in-memory "have I seen this id" test
    /// cannot: after a relaunch every running session is new to the deck.
    @Test("a resumed session is not armed by the standing default, even on a deck that has never seen it")
    func aResumedSessionIsNotArmed() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(autoContinueByDefault: true), at: at(0)))

        // A relaunched deck's first sight of this session is a `SessionStart`
        // — but a RESUMED one, which is not a session beginning.
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("resume"), at: at(10), kind: .sessionStart, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
            prompt: nil, source: "resume",
            host: HostAddress(workspace: "WS", surface: "surface:12"))))

        #expect(prefs(state).autoContinue.isEmpty, Comment(rawValue:
                "a resumed session was armed as though it had just started: "
                + "\(prefs(state).autoContinue.sorted())"))

        // The control: the same shape, but genuinely starting.
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("startup"), at: at(20), kind: .sessionStart, session: s2,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
            prompt: nil, source: "startup",
            host: HostAddress(workspace: "WS", surface: "surface:37"))))
        #expect(prefs(state).autoContinue == ["surface:37"],
                "a genuinely new session was not armed — the fixture's own control")
    }

    // ------------------------------------------------------ the rename repair

    /// **The silent loss.** `autoContinue` is keyed on the surface exactly
    /// like `cardOrder`, and a re-spelling used to drop its entry — a session
    /// quietly stopping being armed, saying nothing until a usage limit
    /// arrived and nothing continued.
    @Test("an armed session that is RE-SPELLED by its own next hook stays armed")
    func armingSurvivesASurfaceRename() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:13", ms: 10))

        var armed = prefs(state)
        // Armed and hidden, but NOT also refused: no path produces a surface
        // that is both, since every writer of one removes it from the other.
        // An earlier version of this fixture set both and so pinned rename-
        // following for a state the product cannot reach.
        armed.autoContinue = ["surface:13"]
        armed.hidden = ["surface:13"]
        Reducer.reduce(&state, .prefsChanged(armed, at: at(20)))

        let uuid = "7BB88BAA-6151-4BED-950D-81A33DFA27C6"
        Reducer.reduce(&state, start(s1, surface: uuid, ms: 30, id: "respell"))

        #expect(prefs(state).autoContinue == [uuid],
                "a re-spelled session silently stopped being armed")
        #expect(prefs(state).hidden == [uuid],
                "a re-spelled session came back from the shelf on its own")
    }

    /// **A refusal must follow its pane across a re-spelling too.**
    ///
    /// Dropped when the armed-and-refused fixture was corrected — but that
    /// state being unreachable argues for a refusal-ONLY fixture, not for
    /// losing the case. Unguarded, a pane re-spelled by its own next hook
    /// loses its refusal and the standing default re-arms a tab the user
    /// explicitly told the deck to leave alone, silently.
    @Test("a REFUSED pane that is re-spelled stays refused")
    func refusalSurvivesASurfaceRename() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(autoContinueByDefault: true, autoContinueRefused: ["surface:13"]), at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:13", ms: 10))

        let uuid = "7BB88BAA-6151-4BED-950D-81A33DFA27C6"
        Reducer.reduce(&state, start(s1, surface: uuid, ms: 20, id: "respell"))

        #expect(prefs(state).autoContinueRefused == [uuid], Comment(rawValue:
                "the refusal did not follow the rename (\(prefs(state).autoContinueRefused.sorted()))"))
        // And the consequence that makes it matter: a NEW session in that
        // same pane is still not armed.
        Reducer.reduce(&state, start(s2, surface: uuid, ms: 30, id: "fresh"))
        #expect(prefs(state).autoContinue.isEmpty, Comment(rawValue:
                "the standing default armed a tab the user had refused, because the refusal was "
                + "lost to a re-spelling"))
    }

    @Test("while two sessions still share a pane, a re-spelling strands neither")
    func aSharedPaneKeepsBothSpellingsWhileBothAreLive() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))
        Reducer.reduce(&state, start(s2, surface: "surface:12", ms: 20))

        var armed = prefs(state)
        armed.autoContinue = ["surface:12"]
        Reducer.reduce(&state, .prefsChanged(armed, at: at(30)))

        // Only ONE of the two re-spells.
        Reducer.reduce(&state, start(s2, surface: "UUID-FOR-12", ms: 40, id: "respell"))

        #expect(prefs(state).autoContinue == ["surface:12", "UUID-FOR-12"],
                "the pane's other live session lost its arming to its neighbour's rename")
    }

    /// **`legacyCardColors` tested DIRECTLY, not through a hook.** Driving
    /// it through the reducer confounds the question: `recordCardColorIfNeeded`
    /// runs on the same event and DRAINS that map into `directoryColors` by
    /// design, so the entry legitimately disappears whether or not the rename
    /// carried it. Calling the rename on its own is the only way to see the
    /// dictionary arm answer for itself.
    @Test("the rename carries a dictionary entry across, value and all")
    func renameCarriesTheLegacyColourMap() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(legacyCardColors: ["surface:13": .slot(3)]), at: at(0)))

        Reducer.followSurfaceRename(&state, from: "surface:13", to: "UUID-13")

        #expect(state.prefs.legacyCardColors["UUID-13"] == .slot(3),
                "the pending colour migration lost its entry to the rename")
        #expect(state.prefs.legacyCardColors["surface:13"] == nil,
                "the old spelling was left behind with nothing answering to it")
    }
    /// And an ended session does not cause a duplicate to be written in the
    /// first place — the same rule, at the other end.
    ///
    /// **The rename is one LANE re-spelling itself.** A different session
    /// reporting a different spelling is not a rename and cannot be treated
    /// as one: the deck has no way to tell "the same pane under its other
    /// name" from "a different pane" without a lane to carry the identity
    /// across. So this drives the case that genuinely arises — a surviving
    /// session re-spells while its ended co-resident still names the old
    /// spelling — and asserts the old one is replaced rather than duplicated.
    @Test("a rename over an ENDED co-resident replaces outright rather than duplicating")
    func aRenameOverAnEndedLaneDoesNotDuplicate() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))
        Reducer.reduce(&state, start(s2, surface: "surface:12", ms: 20))
        var armed = prefs(state)
        armed.autoContinue = ["surface:12"]
        Reducer.reduce(&state, .prefsChanged(armed, at: at(30)))

        // The co-resident ends first.
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("end"), at: at(40), kind: .sessionEnd, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
            host: HostAddress(workspace: "WS", surface: "surface:12"))))

        // Now the SURVIVING session re-spells. Nothing live answers to the old
        // name any more, so there is no reason to keep it.
        Reducer.reduce(&state, start(s2, surface: "UUID-12", ms: 50, id: "respell"))

        #expect(prefs(state).autoContinue == ["UUID-12"], Comment(rawValue:
                "a dead session's spelling was duplicated into the persisted preference: "
                + "\(prefs(state).autoContinue.sorted())"))
    }

    /// **A preference for a pane that is simply not RUNNING must survive
    /// everything.** Outliving the session is the whole reason these are
    /// keyed on the surface rather than the session id, and it is half the
    /// proof that no key is ever safe to retire — `DeckState`'s own note
    /// where `surfaceAliases` used to be carries the other half.
    @Test("a preference for a pane with no live session is left alone")
    func anIdlePanesPreferenceIsNotSwept() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(autoContinue: ["surface:99"], hidden: ["surface:99"]), at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))
        Reducer.reduce(&state, start(s1, surface: "UUID-12", ms: 20, id: "respell"))

        #expect(prefs(state).autoContinue.contains("surface:99"),
                "a preference for a pane that simply is not running was swept away")
        #expect(prefs(state).hidden.contains("surface:99"))
    }

    @Test("a rename with nothing to rename changes nothing")
    func renameIsTotalOnEmptyInput() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinue: ["surface:1"]), at: at(0)))
        let before = state.prefs

        Reducer.followSurfaceRename(&state, from: String?.none, to: "x")
        Reducer.followSurfaceRename(&state, from: "x", to: String?.none)
        Reducer.followSurfaceRename(&state, from: "same", to: "same")
        Reducer.followSurfaceRename(&state, from: "never-seen", to: "new")

        #expect(state.prefs == before)
    }

    /// **The known residual, pinned so it is visible rather than silent.**
    ///
    /// With two sessions LIVE in one pane and one re-spelled, that pane is
    /// named twice in the persisted preferences and nothing removes the
    /// second name — `DeckState`'s own note where `surfaceAliases` used to be
    /// carries the proof that no key is safe to retire. If cmux later reuses
    /// the short ref for an unrelated pane, that pane inherits the setting.
    ///
    /// The hazard predates this work (`hidden` and `autoContinue` have been
    /// keyed on reusable short refs since they existed) and the honest fix is
    /// upstream, canonicalising the host's spelling at ingest. This test
    /// exists so the state is ASSERTED rather than merely tolerated: if a
    /// future change makes it stop happening, this fails and says so.
    @Test("KNOWN RESIDUAL: two live sessions in one pane leave it named twice, and nothing removes the second name")
    func twoLiveSessionsLeaveAPaneNamedTwice() {
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(DeckPrefs.firstRun, at: at(0)))
        Reducer.reduce(&state, start(s1, surface: "surface:12", ms: 10))
        Reducer.reduce(&state, start(s2, surface: "surface:12", ms: 20))
        var armed = prefs(state)
        armed.autoContinue = ["surface:12"]
        Reducer.reduce(&state, .prefsChanged(armed, at: at(30)))

        Reducer.reduce(&state, start(s2, surface: "UUID-12", ms: 40, id: "respell"))

        #expect(prefs(state).autoContinue == ["surface:12", "UUID-12"], Comment(rawValue:
                "the residual changed shape (\(prefs(state).autoContinue.sorted())) — if the second "
                + "name is now removed, check it is not one a LIVE lane still reads by"))

        // **And both must remain, because each lane reads its OWN spelling.**
        // This is the half of the proof that kills every retirement sweep:
        // whichever name you delete, the lane keyed on it silently loses its
        // setting.
        for session in [s1, s2] {
            let surface = state.lanes[session]?.host?.value.surface
            #expect(surface.map(prefs(state).autoContinue.contains) == true, Comment(rawValue:
                    "session \(session.raw) reads by \(surface ?? "nil"), which the preferences "
                    + "no longer name — it has silently stopped being armed"))
        }
    }

    // ---------------------------------------------------------------- codec

    @Test("the default and its seeded record round-trip through the codec")
    func codecRoundTrip() {
        let original = DeckPrefs(autoContinue: ["surface:1"],
                                 autoContinueByDefault: true,
                                 autoContinueRefused: ["surface:1", "surface:2"])
        let decoded = DeckPrefs.decode(original.encoded())
        #expect(decoded.autoContinueByDefault)
        #expect(decoded.autoContinueRefused == ["surface:1", "surface:2"])
        #expect(decoded.autoContinue == ["surface:1"])
    }

    /// **Upgrade safety.** A prefs file written by a version that never heard
    /// of this must not start typing into somebody's terminals.
    /// **The upgrade path, which is user data and not a detail.**
    ///
    /// The retired `autoContinueDecided` held hand-set answers both ways.
    /// Dropping it would have armed, on upgrade, exactly the tabs a person
    /// had told the deck to leave alone — the same failure the rewrite exists
    /// to prevent, delivered by a version bump rather than a button. It is
    /// recoverable: the old code's own bulk-OFF did
    /// `decided.subtract(autoContinue)` before clearing, so a decided entry
    /// whose surface is not armed is precisely a refusal.
    @Test("an old prefs file's refusals survive the move to a refusals-only record")
    func theRetiredDecidedKeyMigrates() {
        let decoded = DeckPrefs.decode(.object([
            "autoContinueByDefault": .bool(true),
            "autoContinue": .array([.string("armed-pane")]),
            // Both an ON decision (armed) and an OFF one (not armed).
            "autoContinueDecided": .array([.string("armed-pane"), .string("refused-pane")]),
        ]))

        #expect(decoded.autoContinueRefused == ["refused-pane"], Comment(rawValue:
                "the upgrade lost the user's refusals (\(decoded.autoContinueRefused.sorted())) — "
                + "those tabs would be armed again by the standing default"))
        #expect(decoded.autoContinue == ["armed-pane"])
        #expect(decoded.retained["autoContinueDecided"] == nil,
                "the retired key would be written back forever")
    }

    @Test("a file already written with refusals is not second-guessed by the migration")
    func theMigrationDefersToTheNewKey() {
        let decoded = DeckPrefs.decode(.object([
            "autoContinue": .array([.string("a")]),
            "autoContinueRefused": .array([.string("b")]),
            "autoContinueDecided": .array([.string("a"), .string("c")]),
        ]))
        #expect(decoded.autoContinueRefused == ["b"])
    }

    /// **Order independence, which the reducer promises and a `.sessionEnd`
    /// side effect broke.**
    ///
    /// Releasing a held offer when the END HOOK arrived made two orderings of
    /// the same real events leave permanently different preferences: place
    /// the lane first and the pane is armed for good, place it after the end
    /// and it never is. The relay and the fleet poll race, so which you got
    /// was timing. Asking the lane's CURRENT state at redeem time instead is
    /// a question no permutation changes.
    @Test("a held offer resolves the same way whichever order the end and the placement arrive in")
    func theHeldOfferIsOrderIndependent() {
        func run(endFirst: Bool) -> Set<String> {
            var state = DeckState()
            Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("bare-start"), at: at(10), kind: .sessionStart, session: s1,
                cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, source: "startup")))
            let end = DeckEvent.hook(HookEvent(
                id: EventID("end"), at: at(20), kind: .sessionEnd, session: s1,
                cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent))
            let place = DeckEvent.located(s1, host: HostAddress(workspace: "WS", surface: "S27")!,
                                          at: at(30), id: EventID("loc"))
            for event in (endFirst ? [end, place] : [place, end]) {
                Reducer.reduce(&state, event)
            }
            return state.prefs.autoContinue
        }

        #expect(run(endFirst: true) == run(endFirst: false), Comment(rawValue:
                "arrival order decided whether the pane stayed armed: "
                + "end-first \(run(endFirst: true).sorted()) vs place-first \(run(endFirst: false).sorted())"))
        // **And pin the VALUE, not merely the agreement.** Both orders
        // returning nothing would satisfy the equality above, so a future
        // change that forfeits held offers entirely would still pass the test
        // written to guard them.
        #expect(run(endFirst: true) == ["S27"],
                "the offer was forfeited in both orders — consistently wrong is still wrong")
    }

    /// **A held offer expires, and the deadline is what lets it without
    /// reintroducing order dependence.**
    ///
    /// Watching for the session to end made two orderings of the same events
    /// land differently. A deadline compares the two events' own timestamps,
    /// so every permutation agrees — and it stops an offer for a session the
    /// deck can never place from claiming forever that it is "still being
    /// placed".
    @Test("an offer the deck takes too long to place expires instead of arming")
    func aStaleOfferExpires() {
        let budget = Reducer.autoContinueOfferBudget.raw
        func armed(placedAfter delay: Int64) -> Set<String> {
            var state = DeckState()
            Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("bare-start"), at: at(10), kind: .sessionStart, session: s1,
                cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, source: "startup")))
            Reducer.reduce(&state, .located(s1, host: HostAddress(workspace: "WS", surface: "S27")!,
                                            at: at(10 + delay), id: EventID("loc")))
            #expect(state.awaitingAutoContinue.isEmpty,
                    "the offer was left standing, spent or not")
            return state.prefs.autoContinue
        }

        #expect(armed(placedAfter: budget) == ["S27"], "an in-time placement did not arm")
        #expect(armed(placedAfter: budget + 1).isEmpty, Comment(rawValue:
                "a stale offer armed a pane long after the session that asked for it"))
    }

    @Test("expiry is a deadline, not a race — both arrival orders agree even past the budget")
    func expiryIsOrderIndependent() {
        func run(endFirst: Bool) -> Set<String> {
            var state = DeckState()
            Reducer.reduce(&state, .prefsChanged(DeckPrefs(autoContinueByDefault: true), at: at(0)))
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("bare-start"), at: at(10), kind: .sessionStart, session: s1,
                cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, source: "startup")))
            let late = at(10 + Reducer.autoContinueOfferBudget.raw + 1)
            let end = DeckEvent.hook(HookEvent(
                id: EventID("end"), at: at(20), kind: .sessionEnd, session: s1,
                cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent))
            let place = DeckEvent.located(s1, host: HostAddress(workspace: "WS", surface: "S27")!,
                                          at: late, id: EventID("loc"))
            for event in (endFirst ? [end, place] : [place, end]) { Reducer.reduce(&state, event) }
            return state.prefs.autoContinue
        }
        #expect(run(endFirst: true) == run(endFirst: false))
        #expect(run(endFirst: true).isEmpty, "a stale offer armed in at least one order")
    }

    @Test("a prefs file with no auto-continue default decodes as OFF")
    func absentDefaultDecodesOff() {
        let decoded = DeckPrefs.decode(.object(["autoContinue": .array([.string("surface:1")])]))
        #expect(decoded.autoContinueByDefault == false)
        #expect(decoded.autoContinueRefused.isEmpty)
        #expect(decoded.autoContinue == ["surface:1"])
    }

    @Test("an untouched default writes no key at all, so an unconfigured deck leaves no trace")
    func offWritesNothing() {
        guard case .object(let o) = DeckPrefs.firstRun.encoded() else {
            Issue.record("encoded() did not produce an object"); return
        }
        #expect(o["autoContinueByDefault"] == nil)
        #expect(o["autoContinueRefused"] == nil)
    }

    /// The keys must be declared KNOWN, or `retained` would carry them as
    /// somebody else's and write them back twice.
    @Test("the new keys are not mistaken for a foreign version's")
    func theNewKeysAreClaimed() {
        let decoded = DeckPrefs.decode(.object([
            "autoContinueByDefault": .bool(true),
            "autoContinueRefused": .array([.string("surface:1")]),
            "somebodyElses": .string("keep me"),
        ]))
        #expect(decoded.retained["autoContinueByDefault"] == nil)
        #expect(decoded.retained["autoContinueRefused"] == nil)
        #expect(decoded.retained["somebodyElses"] == .string("keep me"),
                "a foreign key stopped surviving a round trip")
    }
}
