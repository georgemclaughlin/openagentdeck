//
//  PanelTests.swift · Tests/DeckCoreTests
//
//  In the core: what the panel is allowed to say, and why a
//  control is dark.
//
//  The composer reading is checked against RECORDED SCREENS — the two files
//  `fixtures/live/LV30-multitab` left behind, one a live Claude Code session and
//  one the accidental control where a surface's session had never started and
//  the deck's prompt ran in a shell. Neither was written for this test, which is
//  what makes them worth more than an example would be.
//

import Testing
@testable import DeckCore

struct PanelTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private let s1 = SessionID("s1")
    private let s2 = SessionID("s2")
    private let address = HostAddress(workspace: "workspace:14", surface: "surface:18")

    private func hook(_ session: SessionID, _ kind: HookKind, _ ms: Int64,
                      prompt: String? = nil, host: HostAddress? = nil) -> DeckEvent {
        .hook(HookEvent(id: EventID("\(kind)-\(session.raw)-\(ms)"), at: at(ms),
                        kind: kind, session: session, cwd: Redacted("/work"),
                        tool: nil, toolUseID: nil, held: .absent,
                        prompt: Redacted(optional: prompt), host: host))
    }

    /// A session the deck can speak to: started, and carrying an address.
    private func routable(_ session: SessionID, _ ms: Int64 = 10) -> DeckEvent {
        hook(session, .sessionStart, ms, host: address)
    }

    // ------------------------------------------------------ the composer read

    /// The recorded live composer is EMPTY, and the recorded shell is
    /// not a session at all. Both from `LV30-multitab`, unedited.
    @Test("the recorded screens read as the states they were recorded in")
    func composerFromRecordedScreens() {
        let live = Corpus.text("live/LV30-multitab/screen-B.txt")
        let shell = Corpus.text("live/LV30-multitab/screen-A.txt")
        #expect(!live.isEmpty && !shell.isEmpty,
                "the LV30 screens are missing — this predicate has no real input")

        #expect(Composer.read(live) == .empty,
                "a live session's empty composer did not read as sendable")
        #expect(Composer.maySend(into: Composer.read(live)))

        // The control that cost a real send: no prompt glyph anywhere, and LV30
        // recorded `zsh: command not found: reply` when a prompt went there.
        #expect(Composer.read(shell) == .notASession,
                "a shell read as a session — the deck would type a prompt at a shell")
        // And it reports ITSELF, not a full composer. Reporting a shell as a
        // busy composer told a user their draft was in the way when nothing
        // had been typed — the deck was simply pointed at the wrong pane.
        #expect(Composer.block(for: Composer.read(shell)) == .surfaceNotASession)
    }

    /// A draft is seen, and the deck refuses. LV23 measured the
    /// alternative: `MYDRAFT` plus the deck's text arrived as ONE prompt.
    @Test("a composer holding a draft refuses the send")
    func draftRefuses() {
        let withDraft = """
        ────────────────────
        ❯ MYDRAFT
        ────────────────────
          main  |  /work  |  ctx:3%
        """
        #expect(Composer.read(withDraft) == .holdingText)
        #expect(!Composer.maySend(into: Composer.read(withDraft)))

        // The LAST prompt is the composer: a transcript above it may quote
        // earlier ones, and reading the first would judge the wrong line.
        let quoted = """
        ❯ an earlier prompt somebody already sent
        ⋯ working
        ────────────────────
        ❯
        ────────────────────
        """
        #expect(Composer.read(quoted) == .empty,
                "an earlier prompt in the transcript was mistaken for the composer")
    }

    /// It fails CLOSED. Nothing at all, and a screen the deck cannot
    /// make sense of, both refuse rather than defaulting to send.
    @Test("an unreadable screen refuses rather than assuming")
    func failsClosed() {
        for screen in ["", "\n\n\n", "some tool output with no prompt at all",
                       "dev@devbox project % "] {
            #expect(Composer.read(screen) == .notASession,
                    Comment(rawValue: "\(screen.debugDescription) read as sendable"))
        }
    }

    /// The prophecy in `maySend`'s own doc comment, on a recorded screen:
    /// Claude Code 2.1.231 mid-turn with a message queued draws
    /// `❯\u{00A0}Press up to edit queued messages` where LV30 recorded
    /// emptiness. `LV39-queued-composer/screen-queued.txt` is that session,
    /// its composer line byte-identical to the recording (the rest is
    /// synthesized shape — `PROVENANCE.md` beside it draws the line) — this
    /// is what a fails-closed read used to refuse in exactly the state where
    /// a send would have QUEUED cleanly, measured live the same night.
    @Test("Claude Code's own queued-message placeholder reads as empty")
    func queuedPlaceholderReadsAsEmpty() {
        let queued = Corpus.text("live/LV39-queued-composer/screen-queued.txt")
        #expect(!queued.isEmpty, "the LV39 fixture is missing — this predicate has no real input")
        #expect(Composer.read(queued) == .empty,
                "the queued-state placeholder was read as a draft, refusing a send that would have queued cleanly")
        #expect(Composer.maySend(into: Composer.read(queued)))
    }

    /// The last `❯` still decides, even with the queued-echo line the
    /// transcript shows above the composer (`  ❯ /surf-a` in the recording) —
    /// the placeholder carve-out must not become a scan for the sentence
    /// anywhere on the screen. The refusing direction is the one that
    /// matters: a placeholder QUOTED above a real draft must still refuse,
    /// or an any-line-matches implementation would type over the draft —
    /// the LV23 splice this module exists to prevent.
    @Test("a queued echo above the composer never decides the read")
    func queuedEchoLineIsNotTheComposer() {
        let placeholderBelowEcho = "  ❯ real-draft-echo\n❯\u{00A0}Press up to edit queued messages"
        #expect(Composer.read(placeholderBelowEcho) == .empty,
                "the echo line above the composer, not the composer itself, decided the read")

        let emptyBelowEcho = "  ❯ echo\n❯\u{00A0}"
        #expect(Composer.read(emptyBelowEcho) == .empty)

        let draftBelowPlaceholder = "❯\u{00A0}Press up to edit queued messages\n❯\u{00A0}a real draft"
        #expect(Composer.read(draftBelowPlaceholder) == .holdingText,
                "a placeholder quoted above the composer spared a send onto a real draft — the carve-out became a scan")
    }

    /// The carve-out is exactly one sentence. One trailing character past
    /// it, or a different capitalization of it, are not that sentence and
    /// still refuse — the fails-closed default stands for everything the
    /// recording did not measure.
    @Test("only the exact placeholder sentence is spared; anything else still refuses")
    func onlyTheExactPlaceholderIsSpared() {
        #expect(Composer.read("❯\u{00A0}Press up to edit queued messages!") == .holdingText,
                "a trailing character past the pinned sentence was spared too")
        #expect(Composer.read("❯\u{00A0}press up to edit queued messages") == .holdingText,
                "a different capitalization of the placeholder was spared")
    }

    // ------------------------------------------------------ why it is dark

    /// The precedence of reasons, most global first. A host refusing
    /// outranks a session's own trouble, which outranks the standing fact that
    /// the deck has no address for it.
    @Test("the reason shown is the most global one that applies")
    func blockPrecedence() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))

        // Routable, nothing reported: the cells are live.
        #expect(Projection.frame(from: state, at: at(110)).actionBlock == nil)

        // A session-level refusal.
        Reducer.reduce(&state, .actionBlocked(s1, .composerBusy, at: at(120)))
        #expect(Projection.frame(from: state, at: at(130)).actionBlock == .composerBusy)

        // The host itself, which outranks it — nothing can be sent anywhere, so
        // naming one session's composer would send the person to fix the wrong
        // thing.
        Reducer.reduce(&state, .actionBlocked(nil, .hostUnavailable, at: at(140)))
        #expect(Projection.frame(from: state, at: at(150)).actionBlock == .hostUnavailable)

        // And with nothing selected there is no panel and no reason to give.
        Reducer.reduce(&state, .sessionSelected(nil, at: at(160)))
        #expect(Projection.frame(from: state, at: at(170)).actionBlock == nil)
    }

    /// A lane with no address is unroutable, DERIVED rather than
    /// remembered. The host slot is re-fed by every payload, so "no route" is a
    /// property of the lane as it stands — a remembered one would outlive the
    /// arrival of the very address that fixed it.
    @Test("a lane with no address is unroutable, and stops being so when one arrives")
    func unroutableIsDerived() {
        var state = DeckState()
        Reducer.reduce(&state, hook(s1, .sessionStart, 10))       // no host
        Reducer.reduce(&state, .sessionSelected(s1, at: at(20)))
        #expect(Projection.frame(from: state, at: at(30)).actionBlock == .unroutable)

        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 40, prompt: "x", host: address))
        #expect(Projection.frame(from: state, at: at(50)).actionBlock == nil,
                "an address arrived and the lane was still called unroutable")
    }

    /// A send that reached the wire clears what the last failure said.
    /// Otherwise a socket that came back would leave every control dark behind a
    /// stale reason until the deck was relaunched.
    @Test("a successful send clears the remembered failure")
    func sendClearsTheBlock() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))
        Reducer.reduce(&state, .actionBlocked(nil, .hostUnavailable, at: at(110)))
        Reducer.reduce(&state, .actionBlocked(s1, .composerBusy, at: at(120)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(130)))

        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(140)))
        #expect(state.hostBlock == nil, "the host block outlived a send that worked")
        #expect(state.blocked[s1] == nil)
        #expect(Projection.frame(from: state, at: at(150)).actionBlock == nil)
    }

    /// A block is a fact about a session, so the deck holds none for
    /// a session it has never heard of, and none at all across a restart (the
    /// recover-from-feeds rule, bad news is a cache too).
    @Test("blocks are not invented and do not survive a restart")
    func blockLifecycle() {
        var state = DeckState()
        Reducer.reduce(&state, .actionBlocked(SessionID("ghost"), .hostError, at: at(10)))
        #expect(state.blocked.isEmpty, "the deck remembered trouble for a session it invented")

        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .actionBlocked(s1, .hostError, at: at(20)))
        Reducer.reduce(&state, .actionBlocked(nil, .hostUnavailable, at: at(21)))
        _ = Reducer.reduce(&state, .restart(at: at(30)))
        #expect(state.blocked.isEmpty)
        #expect(state.hostBlock == nil)
    }

    /// The probe can say "no longer blocked". A one-way event would mean
    /// a deck that had ever been refused could never report being able to send.
    @Test("a nil block clears rather than being ignored")
    func blockClears() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .actionBlocked(nil, .hostUnavailable, at: at(10)))
        Reducer.reduce(&state, .actionBlocked(nil, nil, at: at(20)))
        #expect(state.hostBlock == nil, "the probe found the host and the deck kept saying it was gone")
    }

    /// **The hole a live account found: a block with nothing left to
    /// retry it.** Normally `.actionBlocked` leaves the action queued, the
    /// queue retries, and a later `.actionSent` clears the block on the
    /// send that finally worked. Nothing here retries anything — the
    /// session's own next hook, of ANY kind, is what has to clear it — so
    /// this is the DIRECT proof of that rule, apart from the withdrawal
    /// story `queuedActionWithdrawnAfterBlockGoesLiveAgain` walks in full.
    @Test("a block clears on the session's own next lifecycle event")
    func blockClearsOnNextLifecycleEvent() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(20)))
        Reducer.reduce(&state, .actionBlocked(s1, .composerBusy, at: at(30)))
        #expect(state.blocked[s1] == .composerBusy)
        #expect(Projection.frame(from: state, at: at(40)).actionBlock == .composerBusy)

        Reducer.reduce(&state, hook(s1, .stop, 50))
        #expect(state.blocked[s1] == nil, "the block outlived the session's own next event")
        #expect(Projection.frame(from: state, at: at(60)).actionBlock == nil)
    }

    /// **The exact reported sequence.** A quick action is queued, the send
    /// fails with `composerBusy` — correctly, the composer genuinely held a
    /// draft — and then the user withdraws BOTH the draft (off-screen,
    /// the deck only learns of it via the session's next hook) and the
    /// queued action itself. `.actionCancelled` alone does not touch
    /// `state.blocked` — nothing sent, nothing to retry into a clear — so
    /// before the session's own next event the block is still exactly
    /// what it was, and only that event, not the cancel, retires it.
    @Test("queue, block, withdraw the queued action, then the session's own next event clears it")
    func queuedActionWithdrawnAfterBlockGoesLiveAgain() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(20)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(30)))
        Reducer.reduce(&state, .actionBlocked(s1, .composerBusy, at: at(40)))
        #expect(Projection.frame(from: state, at: at(50)).actionBlock == .composerBusy)

        Reducer.reduce(&state, .actionCancelled(s1, actionID: "continue", at: at(60)))
        #expect(state.pending[s1] == nil, "the withdrawal itself did not clear the queue")
        #expect(state.blocked[s1] == .composerBusy,
                "a cancel with nothing sent cleared a block it never touched")
        #expect(Projection.frame(from: state, at: at(70)).actionBlock == .composerBusy,
                "the banner cleared before anything told the deck the world had moved on")

        Reducer.reduce(&state, hook(s1, .stop, 80))
        #expect(state.blocked[s1] == nil, "the block survived the session's own next event")
        let frame = Projection.frame(from: state, at: at(90))
        #expect(frame.actionBlock == nil, "the banner kept asserting a condition the deck had no evidence for")
        #expect(!frame.debouncingActionIDs.contains("continue"),
                "a withdrawn, never-sent action stayed dark with nothing left to explain it")
    }

    /// **Per-lane, not per-deck.** A block is a fact about ONE session; an
    /// event on a different one is not that session's own next lifecycle
    /// event and must not be read as though it were.
    @Test("a block on one session is not cleared by an event on another")
    func blockIsNotClearedByAnUnrelatedSession() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, routable(s2, 11))
        Reducer.reduce(&state, .actionBlocked(s1, .composerBusy, at: at(20)))

        Reducer.reduce(&state, hook(s2, .stop, 30))
        #expect(state.blocked[s1] == .composerBusy,
                "session B's own event reached across and cleared session A's block")

        Reducer.reduce(&state, hook(s1, .stop, 40))
        #expect(state.blocked[s1] == nil, "session A's own event should have cleared its own block")
    }

    /// **The host-level block is a different fact with a different
    /// lifetime, and this fix must not quietly touch it.** `state.hostBlock`
    /// describes the SOCKET, not any one lane — `.actionBlocked(nil, ...)`
    /// is how it is written, and today only `.restart`, a fresh
    /// `.actionBlocked(nil, nil, _)`, and (already, before this fix) a
    /// successful `.actionSent` retire it. A per-session hook must not
    /// become a fourth way in: a probe failing the socket has nothing to
    /// do with any one lane's own next event, and clearing it on one would
    /// make the host block flicker live for exactly as long as the next
    /// lane happened to report in, over a socket that was never fixed.
    @Test("a per-lane lifecycle event does not touch the host-level block")
    func hostBlockSurvivesAnUnrelatedLifecycleEvent() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .actionBlocked(nil, .hostUnavailable, at: at(10)))
        #expect(state.hostBlock == .hostUnavailable)

        Reducer.reduce(&state, hook(s1, .stop, 20))
        #expect(state.hostBlock == .hostUnavailable,
                "a lane's own lifecycle event cleared the host-level block, a different fact entirely")
    }

    // ------------------------------------------------------ what the panel says

    /// The queue reaches the frame with its TITLES, in order, with each
    /// entry's status. A frame carrying only statuses cannot say what is waiting,
    /// and a panel that looked the titles up in the action set would draw blanks
    /// for an action the user has since deleted.
    @Test("the queue reaches the frame as titles and statuses, oldest first")
    func queueReachesTheFrame() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 110, prompt: "work"))
        // Sent, then re-armed — the reachable way to have two of the same action,
        // now that a second tap on an unsent one cancels instead of stacking.
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(120)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(130)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(140)))

        let frame = Projection.frame(from: state, at: at(150))
        #expect(frame.queued.count == 2)
        #expect(frame.queued.map(\.title) == ["Continue", "Continue"])
        #expect(frame.queued.map(\.actionID) == ["continue", "continue"])
        #expect(frame.queued.map(\.status) == [.sent, .queued],
                "the oldest entry is the one that went on the wire, and the frame said otherwise")

        // Another session's queue is not this panel's business.
        Reducer.reduce(&state, routable(s2, 11))
        Reducer.reduce(&state, .actionQueued(s2, QuickAction.shipped[1], at: at(160)))
        #expect(Projection.frame(from: state, at: at(170)).queued.count == 2,
                "the panel showed a queue belonging to a session it is not about")
    }

    /// The stall reaches the frame, and only for the selected session.
    @Test("a stalled queue is announced in the frame")
    func stallReachesTheFrame() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 1_000, prompt: "long work"))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(1_100)))

        #expect(!Projection.frame(from: state, at: at(61_100)).queueStalled,
                "a one-minute turn was announced as stalled")
        #expect(Projection.frame(from: state, at: at(301_200)).queueStalled)

        // Looking elsewhere does not un-stall it, but the panel is about the
        // other session now and says nothing about this one.
        Reducer.reduce(&state, routable(s2, 11))
        Reducer.reduce(&state, .sessionSelected(s2, at: at(301_300)))
        #expect(!Projection.frame(from: state, at: at(301_400)).queueStalled)
        #expect(state.stalledQueues(at: at(301_400)) == [s1],
                "the queue stopped being stalled because nobody was looking at it")
    }

    /// 'S second sanctioned timer. The notice is derived from the
    /// clock, and the case it exists for — a session that wedges — emits no
    /// further hooks, so without a wake it would never draw.
    @Test("a queue waiting on a busy session asks for one wake, and only then")
    func stallWatchTimer() {
        let watch = TimerID("stall-watch")
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        #expect(!state.scheduledWork.contains(watch), "an empty queue asked for a timer")

        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "work"))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(110)))
        #expect(state.scheduledWork.contains(watch),
                "a queue waiting on a running turn asked for nothing, so the notice can never draw")

        // Idle: the queue is about to drain, so there is nothing to watch for.
        Reducer.reduce(&state, hook(s1, .stop, 200))
        #expect(!state.scheduledWork.contains(watch),
                "an idle session with a pending action still asked for a stall timer")

        // Sent: nothing is waiting.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 300, prompt: "more work"))
        #expect(state.scheduledWork.contains(watch))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(310)))
        #expect(!state.scheduledWork.contains(watch),
                "an action already on the wire kept a stall timer alive")
    }

    /// **A tie means BUSY.** Both stamps come from event time and
    /// the order-insensitivity rule forces `max()` over them, so two events
    /// in the same millisecond are indistinguishable by construction — the
    /// tie is a real case, not a pedantic one. It was resolved as *idle*
    /// until an app-target test sent a prompt and a `Stop` inside one
    /// millisecond and the deck typed into the running turn.
    ///
    /// Deterministic here, in the core, rather than in the runtime: pinning it
    /// against a real clock means racing the millisecond, which is how a test
    /// comes to pass for reasons unrelated to the rule.
    @Test("a stop sharing a millisecond with a prompt leaves the session busy")
    func idleTieMeansBusy() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 500, prompt: "work"))
        Reducer.reduce(&state, hook(s1, .stop, 500))
        #expect(!state.isIdle(s1),
                "a stop in the prompt's own millisecond was read as the turn being over")

        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(510)))
        #expect(state.nextSend(at: at(520)) == nil,
                "the deck would have typed into a turn it cannot know has ended")

        // And the next Stop — the turn's own — releases it. The fail-closed
        // answer costs a wait, never a stuck queue.
        Reducer.reduce(&state, hook(s1, .stop, 600))
        #expect(state.isIdle(s1))
        #expect(state.nextSend(at: at(610))?.session == s1)
    }

    // ------------------------------------------------------ the tap's meaning

    // -------------------------------------------------- user-defined actions

    /// **The actions persist.** `quickActions` was a field on
    /// `DeckPrefs` that neither `decode` nor `encode` touched and that
    /// `knownKeys` did not list, so every button a user added or removed
    /// reverted to the shipped three on relaunch. The panel, the queue, the
    /// sends and the editor were all built around a preference that was never
    /// stored — the third instance of that shape in this one feature.
    @Test("a user's buttons survive a round trip through the prefs file")
    func actionsPersist() {
        var prefs = DeckPrefs.firstRun
        prefs.quickActions = [
            QuickAction(id: "cont", title: "Continue", kind: .prompt("Continue")),
            QuickAction(id: "ship", title: "Ship it", kind: .prompt("commit and push")),
            QuickAction(id: "stop", title: "Stop", kind: .escape),
        ]
        let back = DeckPrefs.decode(prefs.encoded())
        #expect(back.quickActions == prefs.quickActions,
                "the buttons did not survive: \(back.quickActions.map(\.displayTitle))")
        // And the kinds survive, which is what decides whether a tap types text
        // or sends an interrupt.
        #expect(back.quickActions.last?.kind == .escape)
    }

    /// An ABSENT key and an EMPTY list are different facts. Never
    /// edited yields the shipped set; deliberately emptied yields nothing. A
    /// codec that conflated them would resurrect three buttons a user had
    /// removed, every launch.
    @Test("no stored actions means shipped; an empty list means empty")
    func absentIsNotEmpty() {
        #expect(DeckPrefs.decode(.object([:])).quickActions == QuickAction.shipped)
        #expect(DeckPrefs.decode(.object(["quickActions": .array([])])).quickActions.isEmpty,
                "a user who removed every button got them all back")
    }

    /// A malformed row is DROPPED, not defaulted. An action whose text
    /// did not survive would send something its author never wrote, and a button
    /// that does the wrong thing is worse than a button that is missing.
    @Test("an unreadable stored action is dropped rather than invented")
    func malformedActionsAreDropped() {
        let stored = JSONValue.object(["quickActions": .array([
            .object(["id": .string("ok"), "title": .string("Fine"), "prompt": .string("go")]),
            .object(["id": .string("nomsg"), "title": .string("Broken")]),   // no prompt, no escape
            .object(["title": .string("No id"), "prompt": .string("x")]),    // no id
            .string("not even an object"),
        ])])
        let actions = DeckPrefs.decode(stored).quickActions
        #expect(actions.map(\.id) == ["ok"],
                "decoded \(actions.map(\.id)) — a row that could not be read was invented instead of dropped")
    }

    /// An unfinished button never reaches a surface a finger can touch.
    /// It stays in prefs so the editor can show it with its reason; the panel
    /// only offers what is complete.
    ///
    /// **The "long" row is the retired rule's own live witness.** It used to
    /// be a fourth invalid row here — 20 characters past the old 16-char
    /// `titleBudget` gate — and this test is where the length-rejection
    /// change (`QuickAction.rejection(at:among:)`'s own doc comment) is
    /// shown unlocking something real: the row is unchanged, and it is now
    /// OFFERED. `titleBudget` no longer sizes anything since the pill
    /// retune (`QuickAction.titleBudget`'s own doc comment carries the
    /// retirement) and never gated the panel either.
    @Test("an invalid action is editable but never sendable, and a merely long one is neither")
    func invalidActionsAreNotOffered() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        var prefs = DeckPrefs.firstRun
        prefs.quickActions = [
            QuickAction(id: "good", title: "Continue", kind: .prompt("Continue")),
            QuickAction(id: "empty", title: "New", kind: .prompt("")),
            QuickAction(id: "long", title: "Far too long a label", kind: .prompt("x")),
            QuickAction(id: "dupe", title: "Continue", kind: .prompt("something else")),
        ]
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(50)))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))

        let offered = Projection.frame(from: state, at: at(110)).actions
        #expect(offered.map(\.id) == ["good", "long"],
                Comment(rawValue: "the panel offered \(offered.map(\.id)) — either an unfinished button was "
                        + "tappable, or a merely-long one was wrongly withheld"))

        // "long" (20 characters) cleared the old 16-char gate before this
        // change and is legal now — no migration needed, the gate simply
        // opened.
        #expect(prefs.quickActions[2].displayTitle.count == 20,
                "the fixture's own premise: this row has to be over the old 16-char budget to prove anything")
        #expect(prefs.quickActions[2].rejection(at: 2, among: prefs.quickActions) == nil,
                "a 20-character title was rejected — the length rule is supposed to be retired")

        // Each remaining rejection still names itself, so the editor and the
        // filter cannot disagree about which buttons are ready.
        for bad in [1, 3] {
            #expect(prefs.quickActions[bad].rejection(at: bad, among: prefs.quickActions) != nil,
                    Comment(rawValue: "row \(bad) was accepted"))
        }
        // The ORIGINAL survives its own duplicate. Rejecting both would mean a
        // user typing a second "Continue" lost the first one from the panel.
        #expect(prefs.quickActions[0].rejection(at: 0, among: prefs.quickActions) == nil,
                "an existing button was invalidated by a later copy of its label")
    }

    // -------------------------------------------------- folder scope

    /// **Driven through the real frame projection, not the pure
    /// `offerable(_:in:)` unit — item 4 of the phase's own test list.**
    /// `routable(s1)`'s own fixture cwd is `/work` (this file's own `hook`
    /// helper). A folder rule matching it shows; one naming an unrelated
    /// project does not — the same session, the same selection, two
    /// different stored patterns.
    @Test("the projection offers a folder-scoped action on a matching directory and withholds a non-matching one")
    func projectionFiltersActionsByDirectory() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        var prefs = DeckPrefs.firstRun
        prefs.quickActions = [
            QuickAction(id: "matches", title: nil, kind: .prompt("/status"),
                       scope: .folders("*/work*")),
            QuickAction(id: "no-match", title: nil, kind: .prompt("/other"),
                       scope: .folders("*/nonexistent-project*")),
        ]
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(50)))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))

        let offered = Projection.frame(from: state, at: at(110)).actions
        #expect(offered.map(\.id) == ["matches"],
                Comment(rawValue: "the panel offered \(offered.map(\.id)) — a folder rule should show on a "
                        + "matching directory and withhold on a non-matching one"))
    }

    /// **Performance sanity, item 8 of the phase's own test list — no timing
    /// assertion, deliberately (this suite has been burned by wall-clock
    /// ratios before).** Thirty stored folder-scoped rows, projected against
    /// a realistic session: simply COMPLETING is the assertion. A rewrite
    /// that reintroduced a per-refresh hazard here would fail the suite by
    /// timeout, the same "verified by construction, pinned by a hang"
    /// posture `QuickActionTests.aLegacySizedSetCapsWithoutHanging` already
    /// takes for the stored-set version of a neighbouring hazard. Three of
    /// the thirty are scoped to match this session's own directory, so the
    /// count is checked too — completion alone would not catch a filter
    /// that silently matched everything or nothing.
    @Test("thirty stored folder-scoped actions project without hanging, and only the matching ones show")
    func manyScopedActionsProjectWithoutHanging() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        var prefs = DeckPrefs.firstRun
        prefs.quickActions = (0..<30).map { i in
            QuickAction(id: "a\(i)", title: "Title \(i)", kind: .prompt("go"),
                       scope: .folders(i < 3 ? "*/work*" : "*/nonexistent-project-\(i)*"))
        }
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(50)))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))

        let offered = Projection.frame(from: state, at: at(110)).actions
        #expect(offered.map(\.id) == ["a0", "a1", "a2"],
                Comment(rawValue: "got \(offered.map(\.id)) — expected exactly the three rows scoped to match "
                        + "this session's own directory"))
    }

    /// A new button gets an id nothing else owns. Ids are what the
    /// queue, the prefs file and every accessibility label refer to, so a
    /// collision would make two buttons one target — the label-collapse defect
    /// recorded earlier, arriving through authoring.
    @Test("added buttons never collide on id, whatever they are called")
    func derivedIdsAreUnique() {
        var set: [QuickAction] = []
        for _ in 0 ..< 4 {
            set.append(QuickAction.user(title: "Ship it", message: "go", among: set))
        }
        #expect(Set(set.map(\.id)).count == 4,
                "ids collided: \(set.map(\.id))")
        // And a title made only of punctuation still yields a usable id.
        let odd = QuickAction.user(title: "!!!", message: "go", among: set)
        #expect(!odd.id.isEmpty)
    }

    // ------------------------------------------------------ the usage window

    /// A statusline reading that puts the account at its limit until `resetsAt`.
    private func limited(_ ms: Int64, until: Int64, percent: Int = 100) -> DeckEvent {
        .statusline(StatuslinePayload(
            session: s1, contextPercent: .absent, costUSD: .absent,
            model: nil, version: nil,
            rateLimits: [RateWindow(window: "five_hour", usedPercentage: percent,
                                    resetsAt: at(until))]),
            at: at(ms), id: EventID("sl-\(ms)"))
    }

    /// `limited` above pins ONE window because that is all the limit tests
    /// need; the per-window indicator tests need to name more than one, so
    /// this is the same construction generalised to an arbitrary set.
    private func reading(_ ms: Int64, _ windows: [RateWindow]) -> DeckEvent {
        .statusline(StatuslinePayload(
            session: s1, contextPercent: .absent, costUSD: .absent,
            model: nil, version: nil, rateLimits: windows),
            at: at(ms), id: EventID("sl-\(ms)"))
    }

    /// **At the usage limit a prompt WAITS; it is not refused.**
    ///
    /// The tap is accepted and the action stays queued, because the deck has a
    /// published deadline it can wait for and the person should not have to hold
    /// the intention in their head for four hours. What must not happen is a send:
    /// the engine would refuse it, and the deck would report "sent" for something
    /// that never landed.
    @Test("a prompt queued at the usage limit is held, not sent and not dropped")
    func promptWaitsForTheWindow() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .stop, 20))              // idle
        Reducer.reduce(&state, limited(100, until: 5_000))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(200)))

        #expect(state.isIdle(s1), "the session is idle — only the ACCOUNT is out of budget")
        #expect(state.nextSend(at: at(300)) == nil,
                "the deck sent a prompt the engine has no budget for")
        #expect(state.pending[s1]?.count == 1, "the held action was dropped")
        #expect(state.awaitsUsageWindow(s1, at: at(300)))

        // Not STALLED: stalled means the deck cannot explain the wait, and this
        // wait has a deadline the deck is showing on the mast.
        //
        // Asserted on a BUSY session inside the hold, which is the only shape where
        // the distinction exists: an idle session is never stalled anyway, so the
        // first version of this check passed whether the rule was there or not.
        var busy = DeckState()
        Reducer.reduce(&busy, routable(s1))
        Reducer.reduce(&busy, hook(s1, .userPromptSubmit, 100, prompt: "long work"))
        Reducer.reduce(&busy, limited(150, until: 900_000))
        Reducer.reduce(&busy, .actionQueued(s1, QuickAction.shipped[0], at: at(200)))
        #expect(!busy.isIdle(s1))
        #expect(busy.stalledQueues(at: at(600_000)).isEmpty,
                "a queue waiting on a published deadline was reported as a fault")
    }

    /// And it GOES when the window opens, on the clock rather than on a
    /// fresh reading. LV19 recorded the feed going quiet at the limit and a stale
    /// 100 % still rendering one turn into the new window, so a gate that waited
    /// for a better number would wait forever.
    @Test("the held prompt sends itself the moment the window resets")
    func theClockOpensTheWindow() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .stop, 20))
        Reducer.reduce(&state, limited(100, until: 5_000))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(200)))

        #expect(state.nextSend(at: at(4_999)) == nil, "it went a millisecond early")
        // No new statusline has arrived — the reading still says 100 %.
        #expect(state.nextSend(at: at(5_000))?.action.id == "continue",
                "the window opened and the queue did not move — the gate is waiting for a feed that has gone quiet")
        #expect(!state.awaitsUsageWindow(s1, at: at(5_000)))
    }

    /// An INTERRUPT is never held. It spends no budget, and its whole
    /// purpose is to stop work that is already running: the moment it is most
    /// wanted is exactly when the account is exhausted mid-turn.
    @Test("escape is not held by the usage limit")
    func escapeIgnoresTheUsageLimit() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "long work"))
        Reducer.reduce(&state, limited(150, until: 500_000))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[2], at: at(200)))

        #expect(state.nextSend(at: at(300))?.action.kind == .escape,
                "the interrupt was held by a budget it does not spend")
    }

    /// A slash command IS held. `/compact` summarises, which costs
    /// tokens, so at the limit it fails like any other prompt — and its failure is
    /// invisible to the deck (no UserPromptSubmit comes back for a command), which
    /// makes sending it the worst of the options.
    @Test("a slash command is held like any other prompt")
    func commandsAreHeldToo() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .stop, 20))
        Reducer.reduce(&state, limited(100, until: 5_000))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(200)))
        #expect(state.nextSend(at: at(300)) == nil,
                "/compact went at the limit — it costs tokens and its refusal is silent")
    }

    /// The panel SAYS which wait it is, and the cells stay live so the
    /// tap that queues the action is accepted in the first place.
    @Test("the frame reports the usage hold and keeps the cells enabled")
    func theHoldIsVisible() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .stop, 20))
        Reducer.reduce(&state, limited(100, until: 5_000))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(150)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(200)))

        let frame = Projection.frame(from: state, at: at(300))
        #expect(frame.queueAwaitsUsage, "the panel cannot say why the queue is not moving")
        #expect(frame.actionBlock == nil,
                "the cells were disabled — then the tap that queues this could never happen")
        #expect(frame.usage?.limited == true, "the dot is not showing the limit")
        #expect(frame.queued.count == 1)

        // Past the deadline: the hold lifts and the dot goes quiet, both from the
        // clock alone.
        let after = Projection.frame(from: state, at: at(5_001))
        #expect(!after.queueAwaitsUsage)
        #expect(after.usage?.limited != true)
    }

    /// **One array, two renderings, and they cannot disagree.** `label` and
    /// `windows` are both built from `indicatorWindows` in the projection
    /// (Frame.swift) rather than from two separate `.map`s over the raw
    /// reading, so this checks the invariant that construction is meant to
    /// guarantee rather than re-deriving the label by hand and hoping it
    /// matches.
    ///
    /// The figures are the `max()` retirement's own worked example —
    /// five-hour 3 %, seven-day 81 % — reused here because that comment is
    /// the reason `windows` exists at all: two windows are two facts.
    @Test("the usage label is exactly its windows array, joined")
    func usageLabelIsExactlyItsWindowsJoined() {
        var state = DeckState()
        Reducer.reduce(&state, reading(100, [
            RateWindow(window: "seven_day", usedPercentage: 81, resetsAt: at(999_000)),
            RateWindow(window: "five_hour", usedPercentage: 3, resetsAt: at(5_000)),
        ]))

        let frame = Projection.frame(from: state, at: at(150))
        #expect(frame.usage?.limited == false, "the fixture is at its limit — reread it")
        #expect(frame.usage?.windows.count == 2, "one of the two windows went missing")
        let expected = frame.usage?.windows
            .map { "\($0.shortName):\($0.percent)%" }
            .joined(separator: " ")
        #expect(frame.usage?.label == expected,
                "label \"\(frame.usage?.label ?? "nil")\" and windows disagree: \"\(expected ?? "nil")\"")
    }

    /// The windows read soonest-deadline-first — the same ordering `label`
    /// has always used — and each window's percent is capped at 100 even
    /// when the wire's own reading runs over, the same clamp `label` has
    /// always applied. Named deliberately out of insertion order and out of
    /// numeric order, so a sort or a cap silently dropped would show up as a
    /// wrong array rather than a coincidentally-right one.
    @Test("projected windows are sorted soonest-deadline-first and capped at 100")
    func projectedWindowsAreSortedAndCapped() {
        var state = DeckState()
        // five_hour's own deadline has already passed by the time the frame
        // is read, so this reading is fine-at-any-age, never limited — the
        // cap and the sort are what this test is about, not the alarm path
        // (that is `limitedProjectionCarriesItsWindows` below).
        Reducer.reduce(&state, reading(100, [
            RateWindow(window: "seven_day", usedPercentage: 55, resetsAt: at(50_000)),
            RateWindow(window: "five_hour", usedPercentage: 140, resetsAt: at(1_000)),
        ]))

        let frame = Projection.frame(from: state, at: at(1_500))
        #expect(frame.usage?.limited == false, "the expired window still reads as binding")
        #expect(frame.usage?.windows.map(\.shortName) == ["5h", "7d"],
                "not ordered soonest-deadline-first")
        #expect(frame.usage?.windows.map(\.percent) == [100, 55],
                "an over-100 reading rode into the indicator uncapped")
    }

    /// The alarm path flattens the windows into one colour in the VIEW
    /// (`DeckWindow.usageText(for:)`), but the data survives the flattening
    /// — this is what proves it does, at the model layer the view never
    /// gets to shortcut.
    @Test("the limited projection also carries its windows")
    func limitedProjectionCarriesItsWindows() {
        var state = DeckState()
        Reducer.reduce(&state, reading(100, [
            RateWindow(window: "five_hour", usedPercentage: 100, resetsAt: at(5_000)),
            RateWindow(window: "seven_day", usedPercentage: 42, resetsAt: at(90_000)),
        ]))

        let frame = Projection.frame(from: state, at: at(200))
        #expect(frame.usage?.limited == true, "the fixture is not actually at its limit")
        #expect(frame.usage?.windows.map(\.shortName) == ["5h", "7d"],
                "the limited reading dropped its per-window data")
        #expect(frame.usage?.windows.map(\.percent) == [100, 42])
    }

    /// **A second tap does not stack; it cancels.**
    ///
    /// Two Continues in a row is one Continue as far as anybody's intention goes,
    /// and during a usage hold — which lasts hours — a queue that accepted every
    /// impatient tap would fire them all the moment the window opened. That is the
    /// accidental-authority failure the arm delays exist to prevent, arriving
    /// through patience instead of through haste.
    ///
    /// The same control both arms and cancels, which also gives the deck its first
    /// undo: before this, the only way to stop a mis-tapped Continue was to send an
    /// interrupt — a worse act than the mistake.
    @Test("queueing the same action twice does not stack, and cancelling takes it back")
    func queueIsIdempotentAndCancellable() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "work"))
        let cont = QuickAction.shipped[0], compact = QuickAction.shipped[1]

        Reducer.reduce(&state, .actionQueued(s1, cont, at: at(200)))
        Reducer.reduce(&state, .actionQueued(s1, cont, at: at(210)))
        Reducer.reduce(&state, .actionQueued(s1, cont, at: at(220)))
        #expect(state.pending[s1]?.count == 1,
                "three taps queued \(state.pending[s1]?.count ?? 0) sends")

        // Different actions still stack — the case the directive asked for.
        Reducer.reduce(&state, .actionQueued(s1, compact, at: at(230)))
        #expect(state.pending[s1]?.map(\.action.id) == ["continue", "compact"])

        // Cancelling removes exactly one, leaving the rest in order.
        Reducer.reduce(&state, .actionCancelled(s1, actionID: "continue", at: at(240)))
        #expect(state.pending[s1]?.map(\.action.id) == ["compact"])

        // A SENT action cannot be cancelled — it is beyond recall, and pretending
        // otherwise would be the deck claiming an authority it does not have.
        //
        // Checked with a CONFIRMABLE action, and that matters: `/compact` is
        // unconfirmable, so `.actionSent` already retires it and a cancel finds
        // nothing either way — the guard was untested until this used Continue,
        // which stays in the queue until its receipt arrives.
        Reducer.reduce(&state, .actionQueued(s1, cont, at: at(250)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(260)))
        #expect(state.pending[s1]?.contains { $0.action.id == "continue" && $0.sentAt != nil } == true)
        Reducer.reduce(&state, .actionCancelled(s1, actionID: "continue", at: at(270)))
        #expect(state.pending[s1]?.contains { $0.action.id == "continue" } == true,
                "a send already on the wire was cancelled — the deck cannot recall it")
    }

    /// Clearing discards what has not gone and KEEPS what has. A sent
    /// action cannot be recalled, and forgetting it would stop the deck matching
    /// the receipt that proves it landed.
    @Test("clearing the queue drops the unsent and keeps the sent")
    func clearKeepsWhatIsAlreadyGone() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "work"))
        let cont = QuickAction(id: "cont", title: "Continue", kind: .prompt("Continue"))
        Reducer.reduce(&state, .actionQueued(s1, cont, at: at(200)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "cont", at: at(210)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(220)))

        Reducer.reduce(&state, .queueCleared(s1, at: at(230)))
        #expect(state.pending[s1]?.count == 1, "clear took the sent action with it")
        #expect(state.pending[s1]?.first?.sentAt != nil)
        // And its receipt still lands, which is the whole reason it was kept.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 240, prompt: "Continue"))
        #expect(state.pending[s1] == nil, "the kept send never got its receipt")
    }

    /// The hold's copy NAMES the actions. "waiting for the usage window"
    /// does not tell somebody what they will get when it opens, and after an hour
    /// away that is the only question worth answering.
    @Test("the hold notice names what is waiting")
    func holdNoticeNamesTheActions() {
        var state = DeckState()
        Reducer.reduce(&state, routable(s1))
        Reducer.reduce(&state, hook(s1, .stop, 20))
        Reducer.reduce(&state, limited(100, until: 5_000))
        Reducer.reduce(&state, .sessionSelected(s1, at: at(150)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(200)))

        let one = Projection.frame(from: state, at: at(300))
        #expect(one.holdNotice == "Continue will be sent when the usage limit resets.",
                Comment(rawValue: "notice was \(one.holdNotice ?? "nil")"))

        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(310)))
        let two = Projection.frame(from: state, at: at(320))
        #expect(two.holdNotice == "Continue and /compact will be sent when the usage limit resets.",
                Comment(rawValue: "notice was \(two.holdNotice ?? "nil")"))

        // No hold, no notice — the banner is for a wait, not for decoration.
        #expect(Projection.frame(from: state, at: at(6_000)).holdNotice == nil)
    }

    // ------------------------------------------------------------- density
}

/// Hide, and the conservation rule that constrains it.
///
/// The whole product is "which session needs me". A hide that could conceal a
/// session asking for a human would invert that, so the conservation rule —
/// the mast counter equals the needs-you lanes "including scrolled-off ones"
/// — is the binding constraint rather than a detail. Hidden is a new kind of
/// off-screen.
struct HideTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private func deck(hidden: Set<String> = [], needsYouHidden: Bool = false) -> DeckState {
        var state = DeckState()
        var prefs = DeckPrefs.firstRun
        prefs.hidden = hidden
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(0)))
        for (i, surface) in ["surface:1", "surface:2", "surface:3"].enumerated() {
            let session = SessionID("s\(i + 1)")
            let host = HostAddress(workspace: "workspace:1", surface: surface)!
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("start\(i)"), at: at(Int64(i + 1)), kind: .sessionStart,
                session: session, cwd: Redacted("/w/p\(i)"), tool: nil, toolUseID: nil,
                held: .absent, host: host)))
            // Make the hidden one the one that needs a human. A
            // `permissionRequest` is the engine saying it is about to ask —
            // needs-you by definition rather than by inference, which is what
            // `transition(on:)` keys on. A bare `preToolUse` with no held time
            // is still just working.
            if needsYouHidden, hidden.contains(surface) {
                Reducer.reduce(&state, .hook(HookEvent(
                    id: EventID("ask\(i)"), at: at(Int64(100 + i)), kind: .permissionRequest,
                    session: session, cwd: Redacted("/w/p\(i)"), tool: "Bash",
                    toolUseID: "u\(i)", held: .absent, host: host)))
            }
        }
        return state
    }

    /// A hidden lane leaves the strip and stays in the frame.
    @Test("hiding takes a lane off the strip without removing it")
    func offTheStripNotOutOfTheFrame() {
        let frame = Projection.frame(from: deck(hidden: ["surface:2"]), at: at(200))
        #expect(frame.lanes.count == 3, "a hidden lane fell out of the frame entirely")
        #expect(frame.visibleLanes.count == 2, "the strip still draws the hidden lane")
        #expect(frame.hidden.count == 1)
        #expect(frame.hidden.first?.isHidden == true)
        #expect(frame.visibleLanes.allSatisfy { !$0.isHidden })
    }

    /// **The conservation rule, and the reason hide is safe to
    /// offer.** A hidden session that needs a human is still counted by the
    /// mast. Concealing it would be the deck hiding the one thing it exists
    /// to surface.
    @Test("the mast counts a hidden session that needs you")
    func conservationHoldsOverHiddenLanes() {
        let state = deck(hidden: ["surface:2"], needsYouHidden: true)
        let frame = Projection.frame(from: state, at: at(200))
        let waiting = frame.lanes.filter { $0.state == .needsYou }.count
        #expect(waiting >= 1, "the fixture produced no waiting lane to hide")
        #expect(frame.mastNeedsYou == waiting,
                Comment(rawValue: "the mast says \(frame.mastNeedsYou) of \(waiting) — "
                        + "a hidden request for a human went uncounted"))
        // And the rail knows, so the count has somewhere to point.
        #expect(frame.hiddenNeedsYou >= 1,
                "the rail cannot say that a hidden session is waiting")
    }

    /// Keyed on the surface, so it survives the `/exit` that gives a
    /// session a new id, and it round-trips the codec.
    @Test("hiding is keyed on the surface and persists")
    func hidingIsDurable() {
        var prefs = DeckPrefs.firstRun
        prefs.hidden = ["surface:2", "surface:7"]
        let round = DeckPrefs.decode(prefs.encoded())
        #expect(round.hidden == prefs.hidden)
        #expect(round.hidden.allSatisfy { $0.hasPrefix("surface:") })

        // A NEW session in the same surface is still hidden — that is what
        // keying on the place rather than the process buys.
        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(round, at: at(0)))
        let host = HostAddress(workspace: "workspace:1", surface: "surface:2")!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("fresh"), at: at(10), kind: .sessionStart,
            session: SessionID("brand-new-id"), cwd: Redacted("/w/p"), tool: nil,
            toolUseID: nil, held: .absent, host: host)))
        let frame = Projection.frame(from: state, at: at(20))
        #expect(frame.lanes.first?.isHidden == true,
                "a fresh session in a hidden tab came back visible")
    }

    /// A lane the deck has no address for cannot be hidden. There is
    /// nothing to key the preference on, and a Hide that silently did nothing
    /// would be the mute failure the darkened-control rule exists for.
    @Test("a lane with no address is never hidden")
    func noAddressNoHiding() {
        var state = DeckState()
        var prefs = DeckPrefs.firstRun
        prefs.hidden = ["surface:2"]
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(0)))
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("start"), at: at(1), kind: .sessionStart, session: SessionID("s1"),
            cwd: Redacted("/w/p"), tool: nil, toolUseID: nil, held: .absent)))
        let frame = Projection.frame(from: state, at: at(10))
        #expect(frame.lanes.first?.isHidden == false)
        #expect(frame.hidden.isEmpty)
    }
}

/// Delete: full removal from the deck, and the session untouched.
///
/// "Nothing happens to the Claude Code instance, it is still alive — we just
/// delete it from Open Agent Deck." That sentence is only true if the deck
/// keeps ANSWERING after it stops listening: a deleted session with hooks
/// installed still posts its next `PreToolUse`, and silence there would hang
/// it until the hold budget expired. The graceful-degradation rule is the
/// safety floor.
struct DeleteTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private let s1 = SessionID("s1")
    private let s2 = SessionID("s2")

    private func started(_ extra: SessionID? = nil) -> DeckState {
        var state = DeckState()
        for (i, session) in ([s1] + (extra.map { [$0] } ?? [])).enumerated() {
            let host = HostAddress(workspace: "workspace:1", surface: "surface:\(i + 1)")!
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("start\(i)"), at: at(Int64(i + 1)), kind: .sessionStart,
                session: session, cwd: Redacted("/w/p\(i)"), tool: nil, toolUseID: nil,
                held: .absent, host: host)))
        }
        return state
    }

    private func tombstone(_ state: inout DeckState, _ session: SessionID, at when: Int64) {
        var prefs = state.prefs
        prefs.deleted.insert(session.raw)
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(when)))
    }

    /// Everything the deck held goes, and it goes at the REDUCER.
    /// Suppressing it at the projection would mean the deck still had every
    /// prompt, tool name and path and merely declined to draw them.
    @Test("delete removes the lane and everything attached to it")
    func removalIsTotal() {
        var state = started()
        Reducer.reduce(&state, .sessionSelected(s1, at: at(10)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(20)))
        #expect(state.lanes[s1] != nil && state.pending[s1] != nil && state.selected == s1)

        tombstone(&state, s1, at: 30)

        #expect(state.lanes[s1] == nil, "the lane record survived a delete")
        #expect(state.pending[s1] == nil, "a queued action survived a delete")
        #expect(state.selected == nil, "the panel is still about a deleted session")
        #expect(state.holds.keys.allSatisfy { $0.session != s1 })
        #expect(Projection.frame(from: state, at: at(40)).lanes.isEmpty)
    }

    /// **And it stays gone.** A deleted session keeps running, so its
    /// hooks keep arriving. Without the tombstone the next one walks the lane
    /// straight back in, and delete would mean "until it next speaks".
    @Test("a deleted session cannot walk back in through a hook")
    func itStaysDeleted() {
        var state = started()
        tombstone(&state, s1, at: 30)

        let host = HostAddress(workspace: "workspace:1", surface: "surface:1")!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("after"), at: at(100), kind: .userPromptSubmit, session: s1,
            cwd: Redacted("/w/p0"), tool: nil, toolUseID: nil, held: .absent,
            prompt: Redacted("still working"), host: host)))
        #expect(state.lanes[s1] == nil, "a hook resurrected a deleted session")

        // And through the OTHER door: the no-synthesised-lane rule admits a statusline as an origin.
        Reducer.reduce(&state, .statusline(
            StatuslinePayload(session: s1, contextPercent: .absent, costUSD: .absent,
                              model: nil, version: nil),
            at: at(110), id: EventID("sl")))
        #expect(state.lanes[s1] == nil, "a statusline resurrected a deleted session")
    }

    /// It removes ONE session. A delete that took the deck's other lanes
    /// with it would be a very different feature.
    @Test("delete touches nothing else")
    func itIsScoped() {
        var state = started(s2)
        #expect(state.lanes.count == 2)
        tombstone(&state, s1, at: 30)
        #expect(state.lanes[s2] != nil, "deleting one session removed another")
        #expect(state.lanes.count == 1)
    }

    /// **The confirmation is the feature.** A delete reachable in one
    /// tap would be an ALLOW with worse consequences and a longer word on it.
    /// Asking sets a mode; only confirming it removes anything.
    @Test("asking to delete removes nothing until it is confirmed")
    func askingIsNotDoing() {
        var state = started()
        Reducer.reduce(&state, .sessionSelected(s1, at: at(10)))
        Reducer.reduce(&state, .deleteRequested(s1, at: at(20)))

        #expect(state.confirmingDelete == s1)
        #expect(state.lanes[s1] != nil, "asking removed the lane")
        #expect(Projection.frame(from: state, at: at(25)).confirmingDelete,
                "the panel would not show the question")

        Reducer.reduce(&state, .deleteAbandoned(at: at(30)))
        #expect(state.confirmingDelete == nil)
        #expect(state.lanes[s1] != nil, "abandoning the question removed the lane anyway")
        #expect(!Projection.frame(from: state, at: at(35)).confirmingDelete)
    }

    /// The question is about a lane that exists, and the frame only
    /// raises it for the session the panel is about. A confirmation attached to
    /// the wrong lane is a delete of the wrong session.
    @Test("the question belongs to the selected session")
    func theQuestionIsScoped() {
        var state = started(s2)
        Reducer.reduce(&state, .sessionSelected(s2, at: at(10)))
        Reducer.reduce(&state, .deleteRequested(s1, at: at(20)))
        #expect(!Projection.frame(from: state, at: at(25)).confirmingDelete,
                "the panel asked about a session it is not showing")

        // And a session the deck has already lost cannot be asked about.
        var gone = DeckState()
        Reducer.reduce(&gone, .deleteRequested(s1, at: at(20)))
        #expect(gone.confirmingDelete == nil, "asked to delete a lane that does not exist")
    }

    /// The tombstone is a SESSION id, so it dies with the session: a
    /// fresh session in the same tab comes back. A tombstone that outlived its
    /// subject would become "why will my new session not show up?".
    @Test("a new session in the same tab is not deleted")
    func theTombstoneDiesWithTheSession() {
        var state = started()
        tombstone(&state, s1, at: 30)
        let host = HostAddress(workspace: "workspace:1", surface: "surface:1")!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("fresh"), at: at(100), kind: .sessionStart,
            session: SessionID("a-brand-new-id"), cwd: Redacted("/w/p0"), tool: nil,
            toolUseID: nil, held: .absent, host: host)))
        #expect(state.lanes[SessionID("a-brand-new-id")] != nil,
                "a fresh session in the same tab inherited the deletion")
    }

    /// It persists, or delete would evaporate on every relaunch — which
    /// on this project happens several times an hour.
    @Test("tombstones survive the codec")
    func tombstonesPersist() {
        var prefs = DeckPrefs.firstRun
        prefs.deleted = ["a-session-id", "another-one"]
        #expect(DeckPrefs.decode(prefs.encoded()).deleted == prefs.deleted)
    }

    /// The copy names the real consequence. SG9 is "supervision loss is
    /// invisible… the user goes on believing they are supervising an action the
    /// deck can no longer see", and a delete is that arriving on purpose. A
    /// confirmation that only asked "are you sure" would be the deck taking the
    /// user's consent without telling them what for.
    @Test("the confirmation says what will and will not happen")
    func theCopyIsHonest() {
        let copy = Frame.deleteConfirmation.lowercased()
        #expect(copy.contains("keeps running"), "the copy does not say the session survives")
        #expect(copy.contains("permission"), "the copy does not say it will still ask")
        #expect(copy.contains("terminal"), "the copy does not say where it will ask")
        #expect(copy.contains("needs you"),
                "the copy does not say the deck stops counting a request for a human")
    }
}
