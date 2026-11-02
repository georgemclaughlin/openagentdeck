//
//  UsageTests.swift · Tests/DeckCoreTests
//
//  Task 35: the usage dot, pinned to the LV19 recording — the fixture whose
//  capture apparatus was verified minutes before the real limit hit, and
//  whose three findings are the design:
//
//    - the statusline's rate_limits is the ONLY machine-readable source
//      (the refusal fires UserPromptSubmit and then nothing);
//    - limited is a deadline fact and outlives the quiet feed;
//    - the 100→0 flip lags the reset by one completed turn, so the clock
//      beats the feed.
//

import Testing
@testable import DeckCore

struct UsageTests {

    /// Restart forgets the reading with everything else — the
    /// recover-from-feeds rule, the next statusline re-supplies it, nothing
    /// is cached.
    @Test("restart clears the usage slot")
    func restartClears() {
        var state = DeckState()
        for event in Corpus.usageRun() { Reducer.reduce(&state, event) }
        #expect(state.usage != nil)
        Reducer.reduce(&state, .restart(at: Instant(sinceStart: Millis(999_999_999))))
        #expect(state.usage == nil)
    }

    /// **Standardized paint, as an arbiter.** Age used to make the indicator
    /// sometimes coloured and sometimes grey, so the fix was to stop the reading's age from changing its paint at all
    /// — which means age can no longer change the PROJECTED VALUE either,
    /// or the paint would just be reading a value that still secretly knows
    /// how old it is. A fine reading projected once right after receipt and
    /// again 40 s later — past the old 30 s line `MaxAges.usage` drew — must
    /// come out as the identical indicator: `UsageIndicator` carries nothing
    /// left for an age to move.
    @Test("an old reading and a fresh one project the same indicator")
    func staleAndFreshProjectTheSameIndicator() {
        let session = SessionID("s1")
        let feed = StatuslinePayload(
            session: session, contextPercent: .absent, costUSD: .absent,
            model: nil, version: nil,
            rateLimits: [RateWindow(window: "five_hour", usedPercentage: 42,
                                    resetsAt: Instant(sinceStart: Millis(999_000)))])
        let state = Reducer.run([
            .hook(HookEvent(id: EventID("start"), at: Instant(sinceStart: .zero),
                            kind: .sessionStart, session: session, cwd: nil,
                            tool: nil, toolUseID: nil, held: .absent)),
            .statusline(feed, at: Instant(sinceStart: Millis(1_000)), id: EventID("sl-1"))
        ])

        let fresh = Projection.frame(from: state, at: Instant(sinceStart: Millis(1_000))).usage
        let old = Projection.frame(from: state, at: Instant(sinceStart: Millis(41_001))).usage
        #expect(fresh != nil, "the fixture itself carried no reading")
        #expect(fresh == old, "an old reading projected a different indicator from a fresh one")
    }
}

/// `UsageIndicator.Window.load` — the per-window colour step the toolbar
/// readout paints by (`DecisionBar.swift`'s `Load.tint`). Pure over an `Int`,
/// so the three boundaries are checked directly rather than through a
/// projected frame.
struct UsageWindowLoadTests {

    private func window(_ percent: Int) -> UsageIndicator.Window {
        UsageIndicator.Window(shortName: "5h", percent: percent)
    }

    @Test("under half is easy, at either boundary")
    func easyAtItsBoundaries() {
        #expect(window(0).load == .easy)
        #expect(window(49).load == .easy)
    }

    @Test("half to just under eighty is busy, at either boundary")
    func busyAtItsBoundaries() {
        #expect(window(50).load == .busy)
        #expect(window(79).load == .busy)
    }

    @Test("eighty and up is heavy, at either boundary")
    func heavyAtItsBoundaries() {
        #expect(window(80).load == .heavy)
        #expect(window(100).load == .heavy)
    }
}

/// Auto-continue on usage limit reset.
///
/// The wire signature is measured, not guessed (`fixtures/live/LV19-usage-limit`):
/// a turn refused for budget leaves a `UserPromptSubmit` with **no `Stop` after
/// it** while `five_hour` reads 100 %, then an `idle_prompt` Notification. A
/// healthy turn gets its `Stop` within seconds. So "was it in the middle of
/// working" is this deck's own idle predicate inverted, and "was it idle when
/// the limit hit" arms nothing.
struct AutoContinueTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private let s1 = SessionID("s1")
    private let surface = "surface:27"

    /// A started, routable, auto-continue-enabled session.
    private func armed(prompt: Int64? = nil, stop: Int64? = nil,
                       enabled: Bool = true) -> DeckState {
        var state = DeckState()
        var prefs = DeckPrefs.firstRun
        if enabled { prefs.autoContinue = [surface] }
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(0)))
        let host = HostAddress(workspace: "workspace:19", surface: surface)!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("start"), at: at(1), kind: .sessionStart, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, host: host)))
        if let prompt {
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("p"), at: at(prompt), kind: .userPromptSubmit, session: s1,
                cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
                prompt: Redacted("do the thing"), host: host)))
        }
        if let stop {
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("s"), at: at(stop), kind: .stop, session: s1,
                cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, host: host)))
        }
        return state
    }

    /// The account at its limit, with a deadline in the future.
    private func atLimit(_ state: inout DeckState, at when: Int64, resetsAt: Int64,
                         id: String = "limit") {
        Reducer.reduce(&state, .statusline(
            StatuslinePayload(session: s1, contextPercent: .absent, costUSD: .absent,
                              model: nil, version: nil,
                              rateLimits: [RateWindow(window: "five_hour", usedPercentage: 100,
                                                      resetsAt: at(resetsAt))]),
            at: at(when), id: EventID(id)))
    }

    /// **The case the feature is for.** A prompt with no `Stop`, the
    /// account at 100 %: the deck queues a Continue itself, and the existing
    /// usage gate holds it until the window reopens.
    @Test("a session stalled mid-turn by the limit is queued to continue")
    func stalledMidTurnArms() {
        var state = armed(prompt: 100)
        atLimit(&state, at: 110, resetsAt: 9_000)

        #expect(state.autoLatch[s1] == at(9_000), "the session was not armed")
        let queue = state.pending[s1] ?? []
        #expect(queue.count == 1, Comment(rawValue: "queued \(queue.count) actions"))
        #expect(queue.first?.isAutomatic == true, "the queued Continue is not marked automatic")
        #expect(queue.first?.action.id == QuickAction.continueID)
        // And it WAITS: the usage gate is what holds it, not a special path.
        #expect(state.nextSend(at: at(120)) == nil, "it was sent while the account was still out")
        #expect(state.awaitsUsageWindow(s1, at: at(120)), "the panel would not say what it waits for")
    }

    /// **The other half of the feature, and the half that was missing: the
    /// Continue has to actually GO when the window reopens.**
    ///
    /// `stalledMidTurnArms` above proves the queue WAITS while the account is
    /// out. Nothing proved it ever stops waiting, and it did not: a session
    /// stalled by the limit is stalled precisely because its turn DIED, and a
    /// turn that dies emits no `Stop` — LV19 rows 18–22 record it directly,
    /// two prompts past the limit and a `Notification`, with no `Stop`
    /// anywhere between them, where every healthy turn in the same recording
    /// (rows 3–5, 8–10, 13–15, 23–25) has one within seconds.
    ///
    /// So `lastStopAt` stays behind `lastPromptAt` forever, `isIdle` answers
    /// false forever, and `nextSend`'s prompt gate — which asks for idle —
    /// never opens. The automatic Continue sits in the queue reading
    /// "Waiting" until a HUMAN types something, which is the one thing the
    /// feature exists to avoid. Row 23 of the fixture is exactly that: the
    /// session only came back because a person typed into it.
    @Test("the automatic Continue goes when the window reopens, even though the dead turn left no Stop behind")
    func theContinueDrainsWhenTheWindowReopens() {
        var state = armed(prompt: 100)                  // mid-turn: prompt, no Stop
        atLimit(&state, at: 110, resetsAt: 9_000)

        #expect(state.autoLatch[s1] == at(9_000), "the session was not armed")
        #expect(state.nextSend(at: at(120)) == nil, "it went while the account was still out")

        // What the deck actually learns next, and the only thing it learns.
        // LV19 row 22 is a `Notification` a minute after the refusal, and a
        // notification is one of the triggers for the api-error transcript
        // peek — so the deck reads the dead turn's own last word and the lane
        // goes `.errored`. This is exactly the state the live deck was in
        // when the bug was reported: the card wearing an Error badge reading
        // "You've hit your session limit · resets 4:40pm".
        Reducer.reduce(&state, .apiError(
            s1, text: Redacted("You've hit your session limit · resets 4:40pm (America/Chicago)"),
            at: at(200), id: EventID("api-error")))
        #expect(state.lanes[s1]?.state == .errored, "the lane did not reach the state the live deck showed")

        // The deadline passes. Nothing else happens — at a usage limit
        // nothing IS happening, which is why `DeckRuntime.scheduleUsageReset`
        // exists to wake the drain at all. No new hook, no Stop, no human.
        let sending = state.nextSend(at: at(9_500))
        #expect(sending?.session == s1,
                "the automatic Continue never went — it waits on an idle that a dead turn can never produce")
        #expect(sending?.action.id == QuickAction.continueID)
    }

    /// The gate that reopening removes is the USAGE gate, not the idle gate:
    /// a session genuinely mid-turn — one whose turn is alive, with work still
    /// running — must still wait its turn even after the window reopens.
    /// Otherwise this fix would type into live turns everywhere.
    @Test("reopening the window does not let a prompt into a turn that is genuinely still running")
    func aLiveTurnStillWaitsAfterTheWindowReopens() {
        var state = armed(prompt: 100)
        atLimit(&state, at: 110, resetsAt: 9_000)
        // A tool call lands AFTER the limit: this turn is demonstrably alive,
        // unlike the dead one above, and nothing has marked the lane errored.
        let host = HostAddress(workspace: "workspace:19", surface: surface)!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("alive"), at: at(200), kind: .preToolUse, session: s1,
            cwd: Redacted("/w/app"), tool: "Bash", toolUseID: nil, held: .absent, host: host)))

        #expect(state.nextSend(at: at(9_500)) == nil,
                "a prompt was typed into a turn that is still running")
    }

    /// **The PREMISE, pinned to the recorded bytes rather than to anyone's
    /// reading of them.**
    ///
    /// Everything above rests on one measured claim about the wire: a turn
    /// refused for budget leaves a `UserPromptSubmit` with no `Stop` after
    /// it, while a healthy turn always gets one. `turnDied(_:)` exists only
    /// because that is true, so it is worth holding the recording itself to
    /// it — if Claude Code ever starts emitting a `Stop` at a usage refusal,
    /// this fails and says the premise moved, instead of the feature quietly
    /// becoming unnecessary machinery nobody re-examines.
    ///
    /// Read straight out of `fixtures/live/LV19-usage-limit`, through the
    /// same `HookIngest` the deck uses, with no hand-built events.
    @Test("LV19 itself: every healthy turn gets a Stop, and the two prompts refused at the limit never do")
    func theRecordingItselfShowsARefusedTurnHasNoStop() {
        let hooks: [HookEvent] = Corpus.usageRun().compactMap {
            if case .hook(let h) = $0 { return h }
            return nil
        }
        let prompts = hooks.filter { $0.kind == .userPromptSubmit }
        #expect(prompts.count == 6,
                Comment(rawValue: "the recording no longer has its six prompts — found \(prompts.count)"))

        // For each prompt, is there a Stop after it and before the next one?
        let stops = hooks.filter { $0.kind == .stop }.map(\.at)
        let answered: [Bool] = prompts.enumerated().map { index, prompt in
            let nextPrompt = index + 1 < prompts.count ? prompts[index + 1].at : nil
            return stops.contains { stop in
                stop > prompt.at && (nextPrompt.map { stop < $0 } ?? true)
            }
        }

        // The whole arc in one array. The first three prompts are healthy
        // turns and each gets its `Stop` within seconds. The FOURTH and FIFTH
        // are the two submitted while the account was at 100 % — rows 18 and
        // 20 — and neither is ever answered by anything, which is the entire
        // reason `turnDied(_:)` has to exist. The sixth is row 23, the human
        // typing the session back to life, and it is answered like any other
        // healthy turn: the recording recovered only because a person
        // intervened, which is precisely what auto-continue is meant to spare
        // them.
        #expect(answered == [true, true, true, false, false, true],
                Comment(rawValue: "the Stop signature of the recording changed: \(answered)"))
    }

    /// The same premise seen the way the deck itself sees it: replay the
    /// recording into a real `DeckState` and ask the predicate. After the
    /// refused prompts the session reads NOT idle — permanently, with no
    /// further event coming — which is the state the queued Continue used to
    /// wait in forever.
    @Test("replaying LV19 leaves the session reading not-idle after the refusal, with nothing left to change it")
    func replayingTheRecordingStrandsTheSession() {
        var state = DeckState()
        var afterRefusal: Bool?
        for event in Corpus.usageRun() {
            Reducer.reduce(&state, event)
            // The moment the second refused prompt has landed and before the
            // human's recovery prompt (row 23) arrives.
            if case .hook(let h) = event, h.kind == .notification,
               afterRefusal == nil, !state.isIdle(h.session), state.lanes[h.session] != nil {
                afterRefusal = state.isIdle(h.session)
            }
        }
        #expect(afterRefusal == false,
                "the recording no longer strands the session mid-turn — the premise moved")
    }

    /// **The case it is not for.** Idle when the limit hit means a
    /// `Stop` newer than the last prompt: nothing was interrupted, so nothing
    /// is continued.
    @Test("a session that was idle when the limit hit is left alone")
    func idleDoesNotArm() {
        var state = armed(prompt: 100, stop: 200)
        atLimit(&state, at: 210, resetsAt: 9_000)

        #expect(state.autoLatch[s1] == nil, "an idle session was armed")
        #expect((state.pending[s1] ?? []).isEmpty, "an idle session was queued a Continue")
    }

    /// **Row 19 of the fixture.** A prompt submitted while the account
    /// was ALREADY at its limit is refused too, and that is the case a one-shot
    /// snapshot at the transition misses entirely: the session was idle when the
    /// limit bit, then tried to work during it.
    @Test("a prompt submitted during the limit arms it too")
    func aPromptDuringTheLimitArms() {
        var state = armed(prompt: 100, stop: 200)        // idle when the limit lands
        atLimit(&state, at: 210, resetsAt: 9_000)
        #expect(state.autoLatch[s1] == nil, "armed before there was anything to continue")

        // Now the user tries to work anyway. No Stop follows — LV19 rows 19–21.
        let host = HostAddress(workspace: "workspace:19", surface: surface)!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("p2"), at: at(300), kind: .userPromptSubmit, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
            prompt: Redacted("another test past the limit"), host: host)))

        #expect(state.autoLatch[s1] == at(9_000),
                "a prompt refused during the limit did not arm — the fixture's row 19")
        #expect((state.pending[s1] ?? []).count == 1)
    }

    /// The preference is what decides. Same wire, box unticked, nothing
    /// happens: the deck does not continue sessions nobody asked it to.
    @Test("an unticked session is never continued")
    func thePreferenceDecides() {
        var state = armed(prompt: 100, enabled: false)
        atLimit(&state, at: 110, resetsAt: 9_000)
        #expect(state.autoLatch[s1] == nil)
        #expect((state.pending[s1] ?? []).isEmpty)
    }

    /// **The loop guard.** One automatic continue per window instance.
    /// Repeated statuslines for the same episode must not stack a queue, and a
    /// window the deck's own Continue burned through is a new deadline and a new
    /// decision rather than a machine that continues forever.
    @Test("one automatic continue per window, however often the feed repeats")
    func oneMachinePerWindow() {
        var state = armed(prompt: 100)
        for (i, t) in [110, 120, 130, 140].enumerated() {
            atLimit(&state, at: Int64(t), resetsAt: 9_000, id: "limit\(i)")
        }
        #expect((state.pending[s1] ?? []).count == 1,
                Comment(rawValue: "stacked \((state.pending[s1] ?? []).count) automatic continues"))

        // **The actual loop, and the only thing that stops it.** The Continue
        // goes, its own `UserPromptSubmit` receipt comes back, and the session
        // is mid-turn again with the window still binding — which is the exact
        // condition that armed it in the first place. Without the latch the
        // deck arms again, sends again, and continues forever.
        Reducer.reduce(&state, .actionSent(s1, actionID: QuickAction.continueID, at: at(200)))
        let host = HostAddress(workspace: "workspace:19", surface: surface)!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("receipt"), at: at(210), kind: .userPromptSubmit, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent,
            prompt: Redacted("Continue"), host: host)))
        // The receipt RETIRES the confirmed action, so the queue is empty again
        // — and the session is mid-turn, and the window still binds. That is
        // the arming condition exactly, with nothing queued to notice. Only the
        // latch stands here.
        #expect((state.pending[s1] ?? []).isEmpty, "the confirmed continue did not retire")
        #expect(!state.isIdle(s1), "the receipt left the session looking idle")
        atLimit(&state, at: 220, resetsAt: 9_000, id: "still")
        #expect((state.pending[s1] ?? []).isEmpty,
                Comment(rawValue: "the deck armed itself again off its own receipt: "
                        + "\((state.pending[s1] ?? []).count) queued — this is the loop"))

        // A NEW window is a new decision.
        atLimit(&state, at: 10_000, resetsAt: 20_000, id: "second")
        #expect(state.autoLatch[s1] == at(20_000), "a second episode did not re-arm")
    }

    /// **The turn finished after all.** A `Stop` while the automatic
    /// continue waits means there was nothing to continue, so the queued action
    /// goes. Otherwise the deck sends a Continue into a session that had
    /// already moved on.
    ///
    /// The first version of this asserted `count <= 1`, which is true of a
    /// cancellation that never happens — and the code it was guarding had a
    /// comment claiming it cancelled while doing no such thing.
    @Test("a Stop while it waits cancels the automatic continue")
    func aStopCancelsIt() {
        var state = armed(prompt: 100)
        atLimit(&state, at: 110, resetsAt: 9_000)
        #expect((state.pending[s1] ?? []).count == 1, "nothing was queued to cancel")

        let host = HostAddress(workspace: "workspace:19", surface: surface)!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("late"), at: at(500), kind: .stop, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, host: host)))

        #expect((state.pending[s1] ?? []).isEmpty,
                Comment(rawValue: "the turn finished and \((state.pending[s1] ?? []).count) "
                        + "automatic continue(s) survived it"))
    }

    /// But only the UNSENT ones. Once the Continue is on the wire the
    /// session runs a turn and produces a `Stop` of its own; cancelling on that
    /// would be the deck retracting something it had already done.
    ///
    /// This is also the case only the LATCH can guard: with the action sent,
    /// an "is one already queued" check sees nothing pending and would arm a
    /// second time.
    @Test("a sent automatic continue survives the Stop it caused")
    func aSentOneIsNotRetracted() {
        var state = armed(prompt: 100)
        atLimit(&state, at: 110, resetsAt: 9_000)
        Reducer.reduce(&state, .actionSent(s1, actionID: QuickAction.continueID, at: at(200)))
        #expect(state.pending[s1]?.first?.sentAt != nil, "the action never went")

        let host = HostAddress(workspace: "workspace:19", surface: surface)!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("after"), at: at(300), kind: .stop, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent, host: host)))

        #expect(state.pending[s1]?.count == 1, "a sent action was retracted")
        // And the same window must not arm a second one now that the queue
        // holds nothing unsent — the latch is the only thing standing here.
        atLimit(&state, at: 400, resetsAt: 9_000, id: "again")
        #expect((state.pending[s1] ?? []).count == 1,
                Comment(rawValue: "a second continue was armed for one window: "
                        + "\((state.pending[s1] ?? []).count) queued"))
    }

    /// A lane the deck cannot route to cannot be continued, and the
    /// frame says so rather than drawing a checkbox that promises nothing.
    @Test("an unroutable lane offers no checkbox")
    func theCheckboxNeedsARoute() {
        var state = DeckState()
        var prefs = DeckPrefs.firstRun
        prefs.autoContinue = [surface]
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(0)))
        // Started with NO host address.
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("start"), at: at(1), kind: .sessionStart, session: s1,
            cwd: Redacted("/w/app"), tool: nil, toolUseID: nil, held: .absent)))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(2)))

        let frame = Projection.frame(from: state, at: at(3))
        #expect(!frame.autoContinuable, "a lane with no address offered a toggle")
        #expect(!frame.autoContinueOn)
        // Hide is keyed on the same missing surface — the runtime's `hide`
        // declines a lane without one, so the frame must not offer it either.
        #expect(!frame.hidable, "a lane with no address offered Hide")
    }

    /// The frame reports the preference for the SELECTED session, so the
    /// checkbox shows the state of the lane the panel is about.
    @Test("the frame carries the selected session's setting")
    func theFrameCarriesTheSetting() {
        var state = armed()
        Reducer.reduce(&state, .sessionSelected(s1, at: at(50)))
        var on = Projection.frame(from: state, at: at(60))
        #expect(on.autoContinuable, "a routable lane with a Continue offered no toggle")
        #expect(on.autoContinueOn)
        #expect(on.hidable, "a lane with an address offered no Hide")

        var prefs = state.prefs
        prefs.autoContinue = []
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(70)))
        on = Projection.frame(from: state, at: at(80))
        #expect(!on.autoContinueOn)
    }

    /// The preference survives the codec, and it survives a session
    /// restart, which is the whole reason it is keyed on the surface.
    @Test("the setting round-trips and is keyed on the surface")
    func thePreferenceIsDurable() {
        var prefs = DeckPrefs.firstRun
        prefs.autoContinue = ["surface:27", "surface:31"]
        let round = DeckPrefs.decode(prefs.encoded())
        #expect(round.autoContinue == prefs.autoContinue)
        // Keyed on a surface, never on a session id — a session id lasts one
        // invocation, so a preference keyed on one would evaporate on the first
        // `/exit`, which is exactly when nobody expects to lose it.
        #expect(round.autoContinue.allSatisfy { $0.hasPrefix("surface:") })
    }

    // ---------------------------------------------------- the composed failure

    /// **The scenario a review found, closed end to end.** An automatic
    /// Continue arms at the head of this session's queue the moment the
    /// usage window binds (`stalledMidTurnArms` above) — a tapped digit
    /// answering a permission dialog on the SAME session queues in behind
    /// it. Before the gate scan (fix 2), `nextSend` looked only at a
    /// session's HEAD: the Continue, refused by `limited`, and the loop
    /// moved to the next session without ever reaching the digit sitting
    /// right behind it — head-only gating. Told in full: the automatic
    /// Continue blocks the tapped digit, the human answers in the terminal
    /// anyway, the window reopens, the Continue drains, and the now-stale
    /// digit follows it into the fresh turn, because nothing had ever culled
    /// it and nothing had ever looked past the Continue to offer it sooner.
    /// The gate scan is what lets the digit answer the dialog immediately —
    /// still limited, still mid-turn — while the Continue it overtook keeps
    /// waiting for the window exactly as it should.
    @Test("a tapped digit drains before an automatic Continue queued ahead of it at the usage limit")
    func composedFailureDigitDrainsBeforeTheStalledContinue() {
        var state = armed(prompt: 100)
        atLimit(&state, at: 110, resetsAt: 9_000)
        #expect(state.pending[s1]?.map(\.action.id) == [QuickAction.continueID],
                "the automatic Continue did not arm — the fixture, not the fix, is wrong")

        // The same session's terminal opens a permission dialog, corroborated
        // by the fleet exactly as any other holdless raise would be.
        let row = FleetRow(session: s1, name: "s", kind: "interactive",
                           state: .absent, status: .value("waiting"), waitingFor: "permission prompt")
        Reducer.reduce(&state, .fleet([row], at: at(120), id: EventID("dialog")))
        #expect(state.hasOpenDialog(s1), "the fixture never actually opened a dialog")

        let digit = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        Reducer.reduce(&state, .actionQueued(s1, digit, at: at(130)))
        #expect(state.pending[s1]?.map(\.action.id) == [QuickAction.continueID, "dialog-1"],
                "the digit queued somewhere other than behind the Continue")

        // Still limited — the window has not reopened — and still mid-turn.
        #expect(state.bindingUsageWindow(at: at(140)) != nil)
        #expect(state.nextSend(at: at(140))?.action.id == "dialog-1",
                "the automatic Continue ahead of it starved the digit — the composed failure")

        // And the Continue behind it is untouched: still queued, still
        // waiting for the window, not discarded by the digit overtaking it —
        // "an answer must not throw away a queued Continue".
        #expect(state.pending[s1]?.contains {
            $0.action.id == QuickAction.continueID && $0.sentAt == nil
        } == true, "the digit discarded the Continue instead of overtaking it")
    }
}
