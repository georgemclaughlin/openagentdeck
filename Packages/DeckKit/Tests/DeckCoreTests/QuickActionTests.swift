//
//  QuickActionTests.swift · Tests/DeckCoreTests
//
//  Every rule here exists because a probe measured something,
//  and each test names which one.
//

import Testing
// `JSONEncoder` — for `scopeNeverEncodesItsPatternThroughCodable`, which has
// to drive the REAL `Codable` conformance rather than the hand-written
// `encoded`/`decode` pair, because those two are precisely what it must prove
// the encoder path does NOT behave like.
import Foundation
@testable import DeckCore

struct QuickActionTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private let s1 = SessionID("s1")
    private let s2 = SessionID("s2")

    private func hook(_ session: SessionID, _ kind: HookKind, _ ms: Int64,
                      prompt: String? = nil, notificationType: String? = nil) -> DeckEvent {
        .hook(HookEvent(id: EventID("\(kind)-\(session.raw)-\(ms)"), at: at(ms),
                        kind: kind, session: session, cwd: Redacted("/w"),
                        tool: nil, toolUseID: nil, held: .absent,
                        prompt: Redacted(optional: prompt),
                        host: HostAddress(workspace: "WS", surface: "SURF-\(session.raw)"),
                        notificationType: notificationType))
    }

    private func started(_ sessions: SessionID...) -> DeckState {
        var state = DeckState()
        for (i, s) in sessions.enumerated() {
            Reducer.reduce(&state, hook(s, .sessionStart, Int64(10 + i)))
        }
        return state
    }

    /// A fleet row corroborating an open dialog — LV36's `alpha-b5` shape,
    /// the one value `DeckState.hasOpenDialog` treats as evidenced. No
    /// `pid`/`cwd`: nothing at this layer needs `locate` or the branch
    /// resolver, only `status` and `waitingFor`.
    private func waitingRow(_ session: SessionID) -> FleetRow {
        FleetRow(session: session, name: "s", kind: "interactive",
                 state: .absent, status: .value("waiting"), waitingFor: "permission prompt")
    }

    /// Selection is display only, and emits nothing.
    @Test("selecting and dismissing produce no effects")
    func selectionIsDisplayOnly() {
        var state = started(s1)
        let selecting = Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))
        #expect(selecting.isEmpty)
        #expect(state.selected == s1)

        let dismissing = Reducer.reduce(&state, .dismissRequested(at: at(200)))
        #expect(dismissing.isEmpty)
        #expect(state.selected == nil, "dismiss did not clear the selection")

        // Dismiss with nothing open is a no-op, not an error — it is bound to
        // Esc, which people press reflexively.
        #expect(Reducer.reduce(&state, .dismissRequested(at: at(300))).isEmpty)
    }

    /// The queue belongs to the SESSION. Looking elsewhere must not
    /// stop work a person asked for.
    @Test("a queue survives the selection moving away")
    func queueBelongsToTheSession() {
        var state = started(s1, s2)
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(110)))
        Reducer.reduce(&state, .sessionSelected(s2, at: at(120)))

        #expect(state.pending[s1]?.count == 1, "the queue was dropped when the selection moved")
        #expect(state.nextSend(at: at(130))?.session == s1,
                "a queue stopped draining because somebody looked elsewhere")
    }

    /// Nothing is sent while the session is mid-turn.
    ///
    /// LV21 measured why this is about HONESTY rather than safety: text sent
    /// mid-turn is not lost, it is deferred — it arrived 68 ms after the
    /// running turn's Stop. The deck waits because a send it cannot report is
    /// a send it should not claim.
    @Test("a busy session is not sent to, and an idle one is")
    func idleGate() {
        var state = started(s1)
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "do a thing"))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(110)))

        #expect(state.isIdle(s1) == false)
        #expect(state.nextSend(at: at(120)) == nil, "sent into a running turn")

        Reducer.reduce(&state, hook(s1, .stop, 200))
        #expect(state.isIdle(s1))
        #expect(state.nextSend(at: at(210))?.action.id == "continue")
    }

    /// Escape jumps the queue AND empties it. An interrupt held behind
    /// two prompts is absurd; a queue that survived one would resume the work
    /// the person just stopped. And it does not wait for idle — interrupting
    /// an idle session is not what anybody means by Escape.
    @Test("escape clears the queue, jumps it, and ignores the idle gate")
    func escapeJumpsAndClears() {
        var state = started(s1)
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "long work"))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(110)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(120)))
        #expect(state.pending[s1]?.count == 2)

        let escape = QuickAction.shipped[2]
        Reducer.reduce(&state, .actionQueued(s1, escape, at: at(130)))
        #expect(state.pending[s1]?.count == 1, "escape did not clear the queue")
        #expect(state.pending[s1]?.first?.action.kind == .escape)

        // The session is still mid-turn — that is the point.
        #expect(state.isIdle(s1) == false)
        #expect(state.nextSend(at: at(140))?.action.id == "escape",
                "escape waited for idle, which is when it is least wanted")
    }

    /// A dialog key answers a terminal prompt that is BLOCKING the turn — a
    /// dialog-parked session has fired neither the prompt nor the stop
    /// `isIdle` reads, so it is not-idle by construction, and waiting for
    /// idle would refuse the key in exactly the state it exists to answer.
    /// Unlike escape it does NOT jump or clear the queue — it is not an
    /// interrupt, and there is no reason a queued Continue behind it should
    /// be thrown away.
    ///
    /// The fleet row opening the dialog is part of the fixture, not
    /// incidental: `hasOpenDialog` is the drain-time guard a review added
    /// after this test first shipped exempting ANY queued `.dialogKey`
    /// unconditionally, so a stale one — its dialog already closed — would
    /// have been offered forever. Without the row this test would now be
    /// proving the opposite of what its name says.
    @Test("a dialog key is sendable mid-turn, and does not disturb the rest of the queue")
    func dialogKeySkipsTheIdleGate() {
        var state = started(s1)
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "long work"))
        Reducer.reduce(&state, .fleet([waitingRow(s1)], at: at(105), id: EventID("dlg")))
        #expect(state.hasOpenDialog(s1), "the fixture never actually opened a dialog")
        let dialogKey = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        Reducer.reduce(&state, .actionQueued(s1, dialogKey, at: at(110)))

        #expect(state.isIdle(s1) == false)
        #expect(state.pending[s1]?.count == 1, "a dialog key jumped the queue like an interrupt")
        #expect(state.nextSend(at: at(120))?.action.id == "dialog-1",
                "a dialog key waited for idle, which is exactly the state it answers")
    }

    /// And exempt from the usage gate for the same reason `.escape` is: a key
    /// press into a terminal dialog is not a new turn, so it spends no
    /// budget — the account being out of it is not this key's problem.
    @Test("a dialog key is sendable while the account is at its usage limit")
    func dialogKeySkipsTheUsageGate() {
        var state = started(s1)
        Reducer.reduce(&state, .statusline(
            StatuslinePayload(session: s1, contextPercent: .absent, costUSD: .absent,
                              model: nil, version: nil,
                              rateLimits: [RateWindow(window: "five_hour", usedPercentage: 100,
                                                      resetsAt: at(9_000))]),
            at: at(50), id: EventID("limit")))
        #expect(state.bindingUsageWindow(at: at(60)) != nil, "the fixture is not actually limited")
        Reducer.reduce(&state, .fleet([waitingRow(s1)], at: at(65), id: EventID("dlg")))
        #expect(state.hasOpenDialog(s1), "the fixture never actually opened a dialog")

        let dialogKey = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        Reducer.reduce(&state, .actionQueued(s1, dialogKey, at: at(70)))
        #expect(state.nextSend(at: at(80))?.action.id == "dialog-1",
                "a dialog key waited for the usage window like a prompt would")

        // A prompt behind it in the same slot is still refused at the limit —
        // the gate narrows for the key, not for the session.
        var promptOnly = started(s2)
        Reducer.reduce(&promptOnly, .statusline(
            StatuslinePayload(session: s2, contextPercent: .absent, costUSD: .absent,
                              model: nil, version: nil,
                              rateLimits: [RateWindow(window: "five_hour", usedPercentage: 100,
                                                      resetsAt: at(9_000))]),
            at: at(50), id: EventID("limit2")))
        Reducer.reduce(&promptOnly, .actionQueued(s2, QuickAction.shipped[0], at: at(70)))
        #expect(promptOnly.nextSend(at: at(80)) == nil,
                "a plain prompt was sent while the account was still out")
    }

    // ------------------------------------------------- the drain-time guard

    /// **Fix 1 (MUST): a `.dialogKey` left queued past its own dialog is
    /// dropped, not merely skipped.** Demoted here by an `idle_prompt`
    /// Notification — the wire's own definition of "the turn ended", and one
    /// of the three `lane.state` writers `Reducer.cullStaleDialogKeys`'s doc
    /// comment names. `nextSend` must never offer the stale key, and the
    /// reducer must not leave a dead chip sitting in `pending` for a queue
    /// view to keep drawing forever.
    @Test("a dialog key does not survive its dialog closing via a hook demotion")
    func dialogKeyCulledOnHookDemotion() {
        var state = started(s1)
        Reducer.reduce(&state, .fleet([waitingRow(s1)], at: at(50), id: EventID("dlg")))
        #expect(state.hasOpenDialog(s1))
        let dialogKey = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        Reducer.reduce(&state, .actionQueued(s1, dialogKey, at: at(60)))
        #expect(state.pending[s1]?.count == 1)

        Reducer.reduce(&state, hook(s1, .notification, 70, notificationType: "idle_prompt"))
        #expect(state.lanes[s1]?.state == .idle, "the demotion itself did not land — the fixture is wrong")

        #expect(state.nextSend(at: at(80)) == nil, "a stale dialog key was still offered")
        #expect(state.pending[s1] == nil, "the reducer left a stale dialog key sitting in the queue")
    }

    /// **The other half of the guard.** `waitingFor` can clear WITHOUT
    /// `lane.state` moving at all — the fleet apply writes it
    /// unconditionally on any poll whose roster still names the session,
    /// while the holdless-needs-you guard refuses to move `state` off a row
    /// that is not `idle`. A sweep keyed only to `lane.state` would miss
    /// this half entirely.
    @Test("a dialog key does not survive waitingFor clearing with state unchanged")
    func dialogKeyCulledOnWaitingForCleared() {
        var state = started(s1)
        Reducer.reduce(&state, .fleet([waitingRow(s1)], at: at(50), id: EventID("dlg")))
        #expect(state.hasOpenDialog(s1))
        let dialogKey = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        Reducer.reduce(&state, .actionQueued(s1, dialogKey, at: at(60)))
        #expect(state.pending[s1]?.count == 1)

        // Same session, still named by the roster, but the dialog itself has
        // closed: "busy", no `waitingFor` at all.
        let busyRow = FleetRow(session: s1, name: "s", kind: "interactive",
                               state: .absent, status: .value("busy"), waitingFor: nil)
        Reducer.reduce(&state, .fleet([busyRow], at: at(70), id: EventID("dlg2")))
        #expect(state.lanes[s1]?.state == .needsYou,
                "the fixture moved state too — this proves nothing about waitingFor alone")
        #expect(state.lanes[s1]?.waitingFor.value == nil, "waitingFor was not actually cleared")

        #expect(state.nextSend(at: at(80)) == nil, "a stale dialog key was still offered")
        #expect(state.pending[s1] == nil, "the reducer left a stale dialog key sitting in the queue")
    }

    /// Two different digits — a mis-tap and a correction, say — are culled
    /// TOGETHER. A filter keyed to the first stale entry it finds rather
    /// than every one would leave a sibling standing.
    @Test("two different dialog keys queued together are culled together")
    func twoDialogKeysCulledTogether() {
        var state = started(s1)
        Reducer.reduce(&state, .fleet([waitingRow(s1)], at: at(50), id: EventID("dlg")))
        let one = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        let two = QuickAction(id: "dialog-2", title: "2. Yes, and don't ask again", kind: .dialogKey("2"))
        Reducer.reduce(&state, .actionQueued(s1, one, at: at(60)))
        Reducer.reduce(&state, .actionQueued(s1, two, at: at(65)))
        #expect(state.pending[s1]?.count == 2, "queuing two different digits did not stack")

        Reducer.reduce(&state, hook(s1, .notification, 70, notificationType: "idle_prompt"))
        #expect(state.pending[s1] == nil,
                "one stale digit survived the sweep while its sibling did not")
        #expect(state.nextSend(at: at(80)) == nil)
    }

    // ---------------------------------------------------------- the gate scan

    /// **The head-only scan starved an answer key behind a
    /// gated prompt.** That produced a circular wait when
    /// the prompt ahead of it is itself waiting on the very dialog the key
    /// answers: the prompt waits for idle, idle waits for the dialog, and
    /// the dialog waits for a key `nextSend` never looked at because it was
    /// not the head. Scanning the whole unsent queue is the fix, and
    /// "overtakes without discarding" is the constraint: the prompt is still
    /// there afterward, still gated, exactly where it was.
    @Test("a dialog key behind a queued prompt is offered before the prompt")
    func dialogKeyOvertakesAQueuedPromptAheadOfIt() {
        var state = started(s1)
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 40, prompt: "long work"))
        Reducer.reduce(&state, .fleet([waitingRow(s1)], at: at(50), id: EventID("dlg")))
        #expect(state.hasOpenDialog(s1))

        let prompt = QuickAction.shipped[0]  // Continue
        Reducer.reduce(&state, .actionQueued(s1, prompt, at: at(60)))
        let digit = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        Reducer.reduce(&state, .actionQueued(s1, digit, at: at(70)))
        #expect(state.pending[s1]?.map(\.action.id) == ["continue", "dialog-1"],
                "the fixture's own queue order is not what this test assumes")

        #expect(state.isIdle(s1) == false)
        #expect(state.nextSend(at: at(80))?.action.id == "dialog-1",
                "the head-only scan let the gated prompt block the dialog key behind it")
    }

    /// After the key sends, the prompt it overtook is untouched — still
    /// queued, still waiting for idle. The answer key answered the DIALOG,
    /// not the turn, so nothing about the turn's own gate has changed.
    ///
    /// A `.dialogKey` is unconfirmable like `.escape` (`QuickAction
    /// .isConfirmable`: only a `.prompt` can be) — no receipt a raw key
    /// could ever match — so `.actionSent` retires it from `pending`
    /// immediately rather than leaving it there with `sentAt` set. The
    /// thing this test actually pins is that retiring the KEY does not
    /// retire, gate-skip, or otherwise disturb the PROMPT still sitting
    /// behind where it was.
    @Test("the prompt behind an answered dialog key still waits for idle")
    func promptStillGatedAfterDialogKeySends() {
        var state = started(s1)
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 40, prompt: "long work"))
        Reducer.reduce(&state, .fleet([waitingRow(s1)], at: at(50), id: EventID("dlg")))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(60)))
        let digit = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        Reducer.reduce(&state, .actionQueued(s1, digit, at: at(70)))
        #expect(state.nextSend(at: at(80))?.action.id == "dialog-1")

        Reducer.reduce(&state, .actionSent(s1, actionID: "dialog-1", at: at(90)))
        #expect(state.pending[s1]?.contains(where: { $0.action.id == "dialog-1" }) != true,
                "the dialog key did not retire on send, unconfirmable though it is")

        #expect(state.isIdle(s1) == false, "the fixture went idle on its own — proves nothing")
        #expect(state.nextSend(at: at(100)) == nil,
                "the prompt behind it was offered while the session was still mid-turn")
        #expect(state.pending[s1]?.contains(where: { $0.action.id == QuickAction.continueID }) == true,
                "the Continue behind the dialog key vanished instead of merely waiting")
    }

    /// A receipt retires a send: exactly, once, oldest first.
    ///
    /// Exactly, because a substring rule is what hid the composer-splice
    /// defect for a long time. Once, because a person typing the same
    /// words must not retire two queued copies.
    @Test("a receipt matches exactly and only once")
    func receipts() {
        var state = started(s1)
        let action = QuickAction(id: "cont", title: "Continue", kind: .prompt("Continue"))
        // Two copies on the wire, reached the way it is actually reachable: queue,
        // send, then arm the same action again. Queueing twice while the first is
        // still UNSENT is refused now (E17.39) — three impatient taps during a
        // usage hold must not become three sends — but re-arming after one has gone
        // is a legitimate thing to want, and it is what makes an exactly-once
        // receipt rule matter at all.
        Reducer.reduce(&state, .actionQueued(s1, action, at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "cont", at: at(110)))
        Reducer.reduce(&state, .actionQueued(s1, action, at: at(120)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "cont", at: at(130)))
        #expect(state.pending[s1]?.count == 2)
        #expect(state.pending[s1]?.allSatisfy { $0.sentAt != nil } == true)

        // One receipt retires exactly one.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 140, prompt: "Continue"))
        #expect(state.pending[s1]?.count == 1, "one receipt retired more than one send")

        // A mangled receipt — the composer splice LV23 recorded — matches
        // nothing, and the action stays visibly unconfirmed.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 150, prompt: "MYDRAFTContinue"))
        #expect(state.pending[s1]?.count == 1,
                "a spliced prompt was accepted as a receipt for a clean send")

        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 160, prompt: "Continue"))
        #expect(state.pending[s1] == nil, "the last confirmed action did not retire")
    }

    /// What the deck can never confirm, it never claims. A slash
    /// command fires no `UserPromptSubmit` (LV21, LV23, both mechanisms) and
    /// an interrupt fires no `Stop`, so both retire on the send and say so.
    @Test("unconfirmable actions retire on send, not on a receipt")
    func unconfirmable() {
        #expect(QuickAction.shipped[0].isConfirmable)          // Continue
        #expect(!QuickAction.shipped[1].isConfirmable)         // /compact
        #expect(!QuickAction.shipped[2].isConfirmable)         // Escape

        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "compact", at: at(110)))
        #expect(state.pending[s1] == nil,
                "an unconfirmable action waited for a receipt that can never come")
    }

    /// A queue that cannot drain is SURFACED, not sent anyway and not
    /// dropped. The grace is five minutes because this repository's own
    /// fixtures recorded a routine turn at ~57 s.
    @Test("a stalled queue is surfaced rather than forced or forgotten")
    func stall() {
        var state = started(s1)
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 1_000, prompt: "work"))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(1_100)))

        // A minute in: ordinary work, not a stall. (LV21: ~57 s turns.)
        #expect(state.stalledQueues(at: at(61_100)).isEmpty,
                "a one-minute turn was called stalled")
        #expect(state.nextSend(at: at(61_100)) == nil, "a stalled queue was force-sent")

        // Five minutes in: say so.
        #expect(state.stalledQueues(at: at(301_200)) == [s1])
        #expect(state.pending[s1]?.count == 1, "a stalled action was dropped")

        // And the other half of the rule, which the mutation harness had to
        // point out was missing: a session that is IDLE is not stalled, however
        // long its action has waited. That queue is about to drain, and
        // labelling it "waiting on the session" would be the deck reporting a
        // problem it is in the middle of solving.
        Reducer.reduce(&state, hook(s1, .stop, 302_000))
        #expect(state.isIdle(s1))
        #expect(state.stalledQueues(at: at(400_000)).isEmpty,
                "an idle session with a pending action was called stalled")
        #expect(state.nextSend(at: at(400_000))?.session == s1,
                "the queue did not become sendable once the session went idle")
    }

    /// Still holds. The reducer emits no sends,
    /// so a permuted wire stream lands on one state — the property that failed
    /// the first design, where a drain effect depended on arrival order.
    @Test("a permuted stream with a pending queue lands on one state")
    func permutation() {
        let wire = [hook(s1, .sessionStart, 10),
                    hook(s1, .userPromptSubmit, 100, prompt: "work"),
                    hook(s1, .stop, 200)]
        let action = QuickAction.shipped[0]

        func run(_ order: [DeckEvent]) -> DeckState {
            var state = DeckState()
            Reducer.reduce(&state, hook(s1, .sessionStart, 10))
            Reducer.reduce(&state, .actionQueued(s1, action, at: at(50)))
            for e in order { Reducer.reduce(&state, e) }
            return state
        }

        let straight = run(wire)
        let reversed = run(wire.reversed())
        #expect(straight.pending == reversed.pending,
                "the queue depends on arrival order")
        #expect(straight.lanes[s1]?.lastPromptAt == reversed.lanes[s1]?.lastPromptAt)
        #expect(straight.lanes[s1]?.lastStopAt == reversed.lanes[s1]?.lastStopAt)
        #expect(straight.isIdle(s1) == reversed.isIdle(s1))
    }

    /// The deck does not queue for a session it has never heard of.
    @Test("an unknown session cannot be queued for")
    func unknownSession() {
        var state = DeckState()
        Reducer.reduce(&state, .actionQueued(SessionID("ghost"), QuickAction.shipped[0], at: at(10)))
        #expect(state.pending.isEmpty, "the deck queued work for a session it invented")
    }

    /// Restart forgets it all. Nothing survives that a feed
    /// did not re-supply, and a queue that outlived a restart would send work
    /// nobody could still see they had asked for.
    @Test("restart clears selection and every queue")
    func restart() {
        var state = started(s1)
        Reducer.reduce(&state, .sessionSelected(s1, at: at(100)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(110)))
        _ = Reducer.reduce(&state, .restart(at: at(200)))
        #expect(state.selected == nil)
        #expect(state.pending.isEmpty)
    }

    // ------------------------------------------- renaming a shipped button
    //
    // A stored action carries its title as it was when it was saved. So renaming
    // a button the deck ships reaches only people who have NEVER opened the
    // deck — everyone who has is pinned to the old word forever, which is the
    // inverse of who a rename is for. `Compact` -> `/compact` and `Escape` ->
    // `Escape Key` are the first two, and the mechanism has to work before the
    // words are worth arguing about.

    /// The deck's own old word moves forward.
    @Test("a stored button still carrying the deck's old default is renamed")
    func renamedDefaultsMigrate() {
        // A stored blob as an older build wrote it to the prefs plist.
        let stored: [JSONValue] = [
            .object(["id": .string("continue"), "title": .string("Continue"),
                     "prompt": .string("Continue")]),
            .object(["id": .string("compact"), "title": .string("Compact"),
                     "prompt": .string("/compact")]),
            .object(["id": .string("escape"), "title": .string("Escape"),
                     "escape": .bool(true)]),
        ]
        let decoded = stored.compactMap(QuickAction.decode).map(QuickAction.migrated)
        // `displayTitle`, not `title` — the migrated "continue"/"compact"
        // rows now carry the CURRENT shipped row's own title, which is
        // itself derived (`nil`, `shipped`'s own doc comment); comparing the
        // raw optional would see `nil` where this test wants to see the word
        // that actually renders.
        #expect(decoded.map(\.displayTitle) == ["Continue", "/compact", "Escape Key"],
                Comment(rawValue: "migrated to \(decoded.map(\.displayTitle))"))
        // The MESSAGE is untouched: a migration that rewrote it would change
        // what a button sends, which is the one thing a rename must not do.
        #expect(decoded[1].kind == .prompt("/compact"))
        #expect(decoded[2].kind == .escape)
        // And through the real codec, which is the path a launch takes.
        var prefs = DeckPrefs.firstRun
        prefs.quickActions = []
        let round = DeckPrefs.decode(.object(["quickActions": .array(stored)]))
        #expect(round.quickActions.map(\.displayTitle) == ["Continue", "/compact", "Escape Key"])
    }

    /// And a name the USER chose is left exactly alone. The migration
    /// only recognises words the deck itself once shipped; anything else is
    /// somebody's own label and renaming it would be the deck overwriting a
    /// preference with its own taste.
    @Test("a button the user renamed keeps its name")
    func migrationLeavesAUsersOwnNameAlone() {
        let mine = QuickAction(id: "compact", title: "Squish", kind: .prompt("/compact"))
        #expect(QuickAction.migrated(mine).title == "Squish")
        // Including a user who renamed a DIFFERENT button to the old word: the
        // migration keys on the id, so a stray "Compact" elsewhere is safe.
        let elsewhere = QuickAction(id: "my-button", title: "Compact", kind: .prompt("tidy up"))
        #expect(QuickAction.migrated(elsewhere).title == "Compact")
        // Already-current titles are fixed points, so re-running it is a no-op.
        for action in QuickAction.shipped {
            #expect(QuickAction.migrated(action) == action)
        }
    }

    // --------------------------------------------------- truncate, not reject
    //
    // `titleBudget` (16) stopped gating `rejection(at:among:)` in Q2 and
    // stopped being a sizing basis at all with Q3's pill retune
    // (`QuickAction.titleBudget`'s own doc comment carries the full
    // history) — a longer title is legal and truncates on the glass at
    // `OverviewLayout.actionPillMaxWidth` (320) instead of being refused.
    // `editorTitleCap` (64) is the one length rule left, enforced by
    // `user(title:message:among:)` at the point of authoring rather than
    // by `rejection` after the fact.

    /// A title well past the old 16-char gate (40 characters, exactly) is
    /// offerable — the direct proof the length rule is gone, independent of
    /// `PanelTests.invalidActionsAreNotOffered`'s own end-to-end version of
    /// the same claim.
    @Test("a 40-character title is offerable — the old length gate is retired")
    func longTitleIsOfferable() {
        let title = "This is a title exactly forty characters"
        #expect(title.count == 40, "the fixture's own premise: it has to actually be 40 characters")
        let action = QuickAction(id: "long", title: title, kind: .prompt("go"))
        #expect(action.rejection(at: 0, among: [action]) == nil,
                "a title this long was rejected — the length rule is supposed to be retired")
        #expect(QuickAction.offerable([action]).map(\.id) == ["long"],
                "a title this long was withheld from the offered set")
    }

    /// The one length rule left: the EDITOR's own input cap, enforced by
    /// `user(...)` rather than by `rejection`. A title past it is clamped,
    /// not refused — there is no reason to lose the id/slug derivation over
    /// a paste that ran long, the way a hard rejection would.
    @Test("user(title:message:among:) clamps a title to editorTitleCap")
    func userClampsTitleToEditorCap() {
        let hugeTitle = String(repeating: "x", count: 500)
        let action = QuickAction.user(title: hugeTitle, message: "go", among: [])
        // `displayTitle`, not `.title.count` — `title` explicit here (`user`
        // was given a real string, not `nil`), so the two agree; `displayTitle`
        // is used because `title` is `String?` and has no `.count` of its own.
        #expect(action.displayTitle.count == QuickAction.editorTitleCap,
                Comment(rawValue: "the stored title was \(action.displayTitle.count) characters, expected the cap "
                        + "(\(QuickAction.editorTitleCap))"))
        #expect(action.title == String(repeating: "x", count: QuickAction.editorTitleCap))
        // A title already under the cap is untouched.
        let short = QuickAction.user(title: "Ship it", message: "go", among: [])
        #expect(short.title == "Ship it")
        // The message itself is never clamped — clamping it would change
        // what the button sends, not merely how it reads.
        let longMessage = String(repeating: "y", count: 500)
        let messageAction = QuickAction.user(title: "Short", message: longMessage, among: [])
        #expect(messageAction.payload == longMessage)
    }

    // ---------------------------------------------------- the offered-count cap
    //
    // `QuickAction.maxOffered` (10) — the band's own Quick Actions column,
    // 2×5, run out of room. **moved out of `rejection(at:among:)`
    // entirely, into `offerable(_:in:)`** (that function's own doc comment
    // states why — visibility became per-session the moment `Scope` did).
    // Every test below now drives the cap through `offerable(_:in:)`; none
    // of them asserts on `rejection` returning a cap sentence any more,
    // because it never does, for any row, regardless of count.

    /// The cap itself: twelve legal, distinct rows offer exactly the first
    /// ten, in order. `in: nil` is harmless here — every row is `.everywhere`
    /// by construction (no `scope:` argument given), so no directory could
    /// ever change the answer, and this stays a pure test of the cap
    /// arithmetic alone, nothing about a session or a folder.
    @Test("offerable(_:in:) caps at ten, offering the first ten in order")
    func offerableCapsAtTen() {
        let rows = (0..<12).map { QuickAction(id: "a\($0)", title: "Title \($0)", kind: .prompt("go")) }
        let offered = QuickAction.offerable(rows, in: nil)
        #expect(offered.count == QuickAction.maxOffered,
                Comment(rawValue: "got \(offered.count) offered, expected maxOffered (\(QuickAction.maxOffered))"))
        #expect(offered.map(\.id) == rows.prefix(10).map(\.id),
                "the first ten rows, in order, should be the ones offered")
    }

    /// **The cap counts earlier OFFERABLE rows, not raw position — an
    /// invalid row never consumed a slot, so it must not be able to
    /// deny one to a later, valid row either.** Twelve rows, an empty
    /// MESSAGE (invalid on its own terms) at index 3: the ten VALID rows
    /// at indices 0, 1, 2, 4–10 are all offered — position 3's own
    /// absence does not shift the cap boundary earlier — and the
    /// ELEVENTH valid row (index 11) is the one the cap actually catches.
    ///
    /// **Retargeted twice now.** First to an empty MESSAGE rather than an
    /// empty TITLE, when "a button needs a label" retired. **a
    /// second retarget** — `rows[11].rejection(...)` used to carry the
    /// cap's own sentence directly; now that the cap lives entirely in
    /// `offerable(_:in:)` and never in `rejection`, row 11's own
    /// `rejection` reads `nil` (it IS a finished button — merely one this
    /// stored-set size has no everywhere-cap room left for), so what this
    /// test can still prove is what `offerable(_:in:)` actually returns,
    /// not a sentence `rejection` no longer carries for this case.
    @Test("an earlier invalid row does not consume a cap slot")
    func earlierInvalidRowsDoNotConsumeCapSlots() {
        let rows = (0..<12).map { i in
            QuickAction(id: "a\(i)", title: "Title \(i)", kind: .prompt(i == 3 ? "" : "go"))
        }
        #expect(rows[3].rejection(at: 3, among: rows) == "a button needs a message to send",
                "the fixture's own premise: index 3 must be invalid for its own reason, not the cap's")

        let offered = QuickAction.offerable(rows, in: nil)
        let expectedIDs = ["a0", "a1", "a2", "a4", "a5", "a6", "a7", "a8", "a9", "a10"]
        #expect(offered.map(\.id) == expectedIDs,
                Comment(rawValue: "got \(offered.map(\.id)) — the invalid row at index 3 should not have "
                        + "shifted which ten VALID rows land inside the cap"))
        #expect(rows[11].rejection(at: 11, among: rows) == nil,
                Comment(rawValue: "the 11th valid row is a perfectly finished button — the cap is no longer a "
                        + "fact `rejection` states about it"))
        #expect(!offered.contains { $0.id == "a11" },
                "the 11th valid row should still be the one offerable(_:in:) caps out")
    }

    /// **The cap's own release valve — removing an earlier row frees a
    /// slot for whichever row the cap was catching.** Eleven rows caps
    /// the last one out; dropping the FIRST row (not the capped one)
    /// shifts everyone up one position, and the row that was capped out
    /// is now offered.
    @Test("removing an earlier row releases a cap slot for the one that was capped out")
    func capReleasesWhenAnEarlierRowIsRemoved() {
        let rows = (0..<11).map { QuickAction(id: "a\($0)", title: "Title \($0)", kind: .prompt("go")) }
        #expect(QuickAction.offerable(rows, in: nil).count == 10,
                "the fixture's own premise: eleven rows should cap at ten")
        #expect(!QuickAction.offerable(rows, in: nil).contains { $0.id == "a10" },
                "the fixture's own premise: the 11th row should start out capped")

        var reduced = rows
        reduced.removeFirst()
        let offeredAfter = QuickAction.offerable(reduced, in: nil)
        #expect(offeredAfter.count == 10,
                "removing one row should not itself shrink the offered set below the cap")
        #expect(offeredAfter.contains { $0.id == "a10" },
                "removing an earlier row should release a slot for the row the cap had caught")
    }

    /// **The deliberate side effect this cap creates, pinned directly —
    /// `Frame.autoContinuable` (`Frame.swift`) checks `Continue ∈
    /// offerable(...)`, the SAME predicate this test reads.** Continue
    /// dragged past the tenth position is not merely un-shown — it
    /// disarms auto-continue entirely, because the toggle's own arming
    /// condition is downstream of `offerable`, not a separate "is Continue
    /// anywhere in the list" check. `scopedContinueArmsOnlyInsideItsFolders`,
    /// just below, is this same side effect's scope-based sibling, arriving
    /// through visibility instead of position.
    @Test("Continue dragged past the cap disarms auto-continue")
    func continuePastTheCapDisarmsAutoContinue() {
        var rows = (0..<10).map { QuickAction(id: "ahead\($0)", title: "Title \($0)", kind: .prompt("go")) }
        let continueAction = QuickAction.shipped.first { $0.id == QuickAction.continueID }!
        rows.append(continueAction)
        #expect(rows.count == 11, "the fixture's own premise: Continue sits at the 11th position")

        let offered = QuickAction.offerable(rows, in: nil)
        #expect(!offered.contains { $0.id == QuickAction.continueID },
                "Continue dragged past position ten should be absent from offerable — auto-continue should disarm")

        // The control: Continue at the FRONT is offered, so the fixture's
        // own claim is about POSITION, not about Continue being somehow
        // unofferable on its own terms.
        var restored = rows
        restored.removeAll { $0.id == QuickAction.continueID }
        restored.insert(continueAction, at: 0)
        #expect(QuickAction.offerable(restored, in: nil).contains { $0.id == QuickAction.continueID },
                "Continue at the front should be offered — the fixture's own control")
    }

    /// **The identical side effect, arriving through VISIBILITY instead of
    /// POSITION.** `DeckState.swift`'s own `arm(_:at:)` — the reducer
    /// function that actually queues an automatic Continue — used to look
    /// the action up in the GLOBAL offerable set (`QuickAction
    /// .offerable(_:)`, no directory); a Continue scoped to a folder that
    /// does not name THIS session's own `cwd` must never be found there,
    /// the same as one dragged past position ten above. Every `hook(...)`
    /// this file builds carries `cwd: Redacted("/w")` and a host
    /// (`"SURF-\(session.raw)"`) unconditionally — this fixture leans on
    /// both, exactly as `dialogKeySkipsTheUsageGate` above already does for
    /// the identical `.statusline` shape.
    ///
    /// **Asserts on `pending`, never on `autoLatch`, for the no-match
    /// half.** `arm`'s own code sets the latch the instant
    /// `shouldArmAutoContinue` passes — BEFORE it ever looks up a Continue
    /// to queue — so the latch fires whether or not a matching action
    /// exists; that is a pre-existing fact about a session with no
    /// Continue in its set at all, not something this test is about. What
    /// scoping changes is whether anything actually gets QUEUED.
    @Test("a scoped Continue does not arm outside its own folders, and does arm inside")
    func scopedContinueArmsOnlyInsideItsFolders() {
        func run(pattern: String) -> DeckState {
            var state = started(s1)
            var prefs = DeckPrefs.firstRun
            prefs.autoContinue = ["SURF-s1"]
            prefs.quickActions = [QuickAction(id: QuickAction.continueID, title: nil,
                                              kind: .prompt("Continue"), scope: .folders(pattern))]
            Reducer.reduce(&state, .prefsChanged(prefs, at: at(20)))
            Reducer.reduce(&state, hook(s1, .userPromptSubmit, 100, prompt: "do a thing"))
            Reducer.reduce(&state, .statusline(
                StatuslinePayload(session: s1, contextPercent: .absent, costUSD: .absent,
                                  model: nil, version: nil,
                                  rateLimits: [RateWindow(window: "five_hour", usedPercentage: 100,
                                                          resetsAt: at(9_000))]),
                at: at(110), id: EventID("limit")))
            return state
        }

        let outside = run(pattern: "*/nomatch*")
        #expect((outside.pending[s1] ?? []).isEmpty,
                "a Continue scoped away from this session's own folder was queued anyway")

        // The control: the identical fixture, a pattern that DOES match
        // every hook's own fixed "/w" cwd.
        let inside = run(pattern: "*/w*")
        #expect(inside.autoLatch[s1] == at(9_000),
                "a Continue scoped to match this session's own folder failed to arm")
        #expect((inside.pending[s1] ?? []).count == 1,
                "a Continue scoped to match this session's own folder was not queued")
    }

    /// **The cap rule must stay cheap, pinned at the row count a pre-cap
    /// prefs blob can legally carry.** Forty valid rows: the Add button
    /// never allows this many NEW, but a legacy or hand-edited prefs file
    /// decodes untouched by design (`PrefsTests
    /// .storedRowsPastTheCapSurviveDecode`) and `offerable(_:in:)` runs
    /// inside the frame projection on every refresh. **the
    /// hazard this pins is now structurally impossible rather than merely
    /// avoided** — `rejection(at:among:)`'s own doc comment carries the
    /// full argument: with the cap gone from `rejection` entirely, nothing
    /// counts `rejection`'s own earlier answers by calling `rejection`
    /// again, so there is no recursive prefix left to blow up. This test
    /// stays anyway, as the regression pin: a call that returns at all (a
    /// reintroduced hang here fails the suite loudly by timeout) and
    /// returns the cap's own exact answer.
    @Test("forty stored rows still cap at ten without the projection hanging")
    func aLegacySizedSetCapsWithoutHanging() {
        let rows = (0..<40).map { QuickAction(id: "a\($0)", title: "Title \($0)", kind: .prompt("go")) }
        let offered = QuickAction.offerable(rows, in: nil)
        #expect(offered.map(\.id) == rows.prefix(QuickAction.maxOffered).map(\.id),
                "forty valid rows should offer exactly the first ten, in order")
        #expect(rows[39].rejection(at: 39, among: rows) == nil,
                "row 39 is a perfectly finished button — only offerable(_:in:)'s own cap withholds it now")
        #expect(!offered.contains { $0.id == "a39" })
    }

    // -------------------------------------------------------------- Scope

    /// `shows(in:)` for both cases — `.everywhere` is unconditional;
    /// `.folders(pattern)` defers to `Glob.matches` and, against a `nil`
    /// directory, fails CLOSED rather than guessing either way.
    @Test("shows(in:) is unconditional for .everywhere, and fails closed for .folders against a nil directory")
    func showsInResolvesScope() {
        let everywhere = QuickAction(id: "a", title: "Status", kind: .prompt("/status"))
        #expect(everywhere.shows(in: nil))
        #expect(everywhere.shows(in: "/Users/dev/anything"))

        let scoped = QuickAction(id: "b", title: "Status", kind: .prompt("/status"),
                                 scope: .folders("*/alpha-site*"))
        #expect(scoped.shows(in: "/Users/dev/projects/alpha-site/deck"))
        #expect(!scoped.shows(in: "/Users/dev/projects/alpha-sight/deck"))
        #expect(!scoped.shows(in: nil),
                "a folder-scoped action showed on a session with no known directory")
    }

    /// Encode/decode round-trips `scope` the same way it already round-trips
    /// `title`: `.everywhere` omits the key, `.folders` preserves the
    /// pattern, and a row stored WITHOUT the key decodes `.everywhere`.
    @Test("scope round-trips through encode/decode: .everywhere omits the key, .folders preserves the pattern")
    func scopeRoundTripsThroughEncodeDecode() {
        let everywhere = QuickAction(id: "a", title: "Status", kind: .prompt("/status"))
        guard case .object(let o) = everywhere.encoded else {
            Issue.record("encoded() did not produce an object")
            return
        }
        #expect(o["folders"] == nil, "an .everywhere action wrote a \"folders\" key that was never stored")
        #expect(QuickAction.decode(everywhere.encoded)?.scope == .everywhere)

        let scoped = QuickAction(id: "b", title: "Status", kind: .prompt("/status"),
                                 scope: .folders("*/alpha-site*"))
        guard case .object(let so) = scoped.encoded, case .string(let pattern)? = so["folders"] else {
            Issue.record("a .folders action did not encode a \"folders\" string key")
            return
        }
        #expect(pattern == "*/alpha-site*")
        #expect(QuickAction.decode(scoped.encoded)?.scope == .folders("*/alpha-site*"))

        // A row stored before this feature — no "folders" key at all —
        // decodes .everywhere. Migration is nothing.
        let legacy = QuickAction.decode(.object(["id": .string("c"), "title": .string("Old"),
                                                 "prompt": .string("go")]))
        #expect(legacy?.scope == .everywhere)
    }

    /// **A pattern is stored verbatim, whatever is in it.** `encoded`/`decode`
    /// pass the string through `JSONValue` with no hand-rolled escaping, so
    /// the characters that break hand-rolled escaping are exactly the ones
    /// worth pinning.
    @Test("a folder pattern survives encode/decode with quotes, backslashes, newlines and non-ASCII",
          arguments: ["*/say \"hello\"*", "*\\windows\\style*", "*/multi\nline*",
                      "*/проект*", "*/日本語/*", "*/emoji-🌮*"])
    func scopePatternsRoundTripWhateverIsInThem(_ pattern: String) {
        let action = QuickAction(id: "a", title: "Go", kind: .prompt("go"),
                                 scope: .folders(pattern))
        #expect(QuickAction.decode(action.encoded)?.scope == .folders(pattern),
                Comment(rawValue: "pattern \(pattern.debugDescription) did not survive the round trip"))
    }

    /// **The pattern must never ride out in an ENCODED frame.** `Frame` is
    /// `Codable` and carries `[QuickAction]`; a folder rule is a person's own
    /// word for a project (the feature's own example names a client). That is
    /// `Redacted`-class text, so `Scope`'s `Codable` writes the same
    /// placeholder `Redacted` does — while `encoded`/`decode` above, which is
    /// what actually persists a person's settings, keeps the real pattern.
    /// Both halves matter: a leak on one side, a broken feature on the other.
    @Test("Scope's Codable conformance writes the redaction placeholder, never the pattern")
    func scopeNeverEncodesItsPatternThroughCodable() throws {
        let scoped = QuickAction(id: "a", title: "Go", kind: .prompt("go"),
                                 scope: .folders("*/alpha-site*"))
        let json = String(decoding: try JSONEncoder().encode(scoped), as: UTF8.self)
        #expect(!json.contains("bravo"),
                Comment(rawValue: "the folder pattern reached an encoder in plaintext: \(json)"))
        #expect(json.contains(Redacted.placeholder),
                "the placeholder is what should have been written in its place")

        // `.everywhere` has nothing to hide and encodes as null.
        let global = QuickAction(id: "b", title: "Go", kind: .prompt("go"))
        let globalJSON = String(decoding: try JSONEncoder().encode(global), as: UTF8.self)
        #expect(globalJSON.contains("null"))
    }

    /// **`migrated` must carry `scope` forward.**
    /// It runs over every decoded row on every launch, and rebuilding a
    /// `QuickAction` from parts is the operation that drops fields: `scope`
    /// is a defaulted initialiser parameter, so omitting it compiles happily
    /// and silently un-scopes the row. A shipped button still carrying its
    /// old default title AND a folder rule went global on every launch.
    @Test("migrating a superseded title does not discard the action's folder scope")
    func migrationKeepsTheFolderScope() {
        let stored = QuickAction(id: "compact", title: "Compact", kind: .prompt("/compact"),
                                 scope: .folders("*/some-project*"))
        let migrated = QuickAction.migrated(stored)
        #expect(migrated.displayTitle == "/compact", "the title migration itself stopped working")
        #expect(migrated.scope == .folders("*/some-project*"),
                "migration silently turned a folder-scoped button global")
    }

    /// An empty or whitespace-only pattern is a rejection, and the row it
    /// belongs to is offered nowhere — not to the editor's own uncapped
    /// view, and not to any particular session's.
    @Test("an empty or whitespace folder pattern is a rejection, and the row is offered nowhere",
          arguments: ["", "   ", "\t"])
    func emptyFolderPatternIsRejected(_ pattern: String) {
        let action = QuickAction(id: "a", title: "Status", kind: .prompt("/status"), scope: .folders(pattern))
        #expect(action.rejection(at: 0, among: [action]) == "a folder rule needs a pattern",
                Comment(rawValue: "got \(action.rejection(at: 0, among: [action]).debugDescription)"))
        #expect(QuickAction.offerable([action]).isEmpty,
                "an unfinished folder rule reached the editor's own offered set")
        #expect(QuickAction.offerable([action], in: "/Users/dev/anywhere/at/all").isEmpty,
                "an unfinished folder rule reached a session's own offered set")
    }

    /// **Item 5 of the brief's own test list — the cap applies AFTER
    /// filtering, not before.** Twelve stored, eight of them scoped to match
    /// one directory and four scoped to a different one: eight offered to
    /// the first directory, none capped away, because eight never competed
    /// with the other four for a slot in the first place. A second twelve,
    /// all matching the same directory: exactly ten, first-stored-first —
    /// the ordinary cap, once every row is actually in contention for it.
    @Test("offerable(_:in:) caps after filtering by directory, not before")
    func offerableInDirectoryCapsAfterFiltering() {
        let rows = (0..<12).map { i -> QuickAction in
            let pattern = i < 8 ? "*/mike*" : "*/november*"
            return QuickAction(id: "a\(i)", title: "Title \(i)", kind: .prompt("go"), scope: .folders(pattern))
        }
        let offeredMike = QuickAction.offerable(rows, in: "/Users/dev/projects/mike/deck")
        #expect(offeredMike.map(\.id) == rows.prefix(8).map(\.id),
                Comment(rawValue: "got \(offeredMike.map(\.id)) — eight rows matched this directory and none "
                        + "of them should have been capped away"))

        let allWide = (0..<12).map { QuickAction(id: "b\($0)", title: "Title \($0)", kind: .prompt("go"),
                                                  scope: .folders("*")) }
        let offeredAll = QuickAction.offerable(allWide, in: "/Users/dev/projects/anywhere/deck")
        #expect(offeredAll.map(\.id) == allWide.prefix(10).map(\.id),
                Comment(rawValue: "got \(offeredAll.map(\.id)) — twelve matching rows should cap at exactly "
                        + "ten, the first ten in stored order"))
    }

    // ------------------------------------------------ Q3: the commit boundary
    //
    // `commitTitle(_:)` is the rule `ActionRowEditor` (`SettingsView.swift`)
    // runs when a title field's edit boundary closes — `.onSubmit` or focus
    // loss — mirroring exactly what `user(title:message:among:)` already does
    // to a brand-new title, so an EDIT and an AUTHORING go through the same
    // gate.

    /// Whitespace trims, then the result clamps to `editorTitleCap` — the
    /// same two steps, in the same order, `userClampsTitleToEditorCap` above
    /// already pins for `user(...)`, now pinned for the function the two
    /// share.
    @Test("commitTitle trims whitespace, then clamps to editorTitleCap")
    func commitTitleTrimsThenClamps() {
        #expect(QuickAction.commitTitle("  Ship it  ") == "Ship it")
        let padded = "  " + String(repeating: "x", count: 500) + "  "
        #expect(QuickAction.commitTitle(padded) == String(repeating: "x", count: QuickAction.editorTitleCap))
        // A title that is ALL whitespace commits to empty. This function's
        // own job is only the trim-and-clamp — what an empty COMMITTED
        // title means (derived, once it reaches `ActionRowEditor
        // .pendingCommit`'s own empty-maps-to-nil rule, `SettingsView.swift`)
        // is a different function's job, not this one's.
        #expect(QuickAction.commitTitle("   ") == "")
    }

    /// `user(...)` and `commitTitle(...)` must actually agree, not merely
    /// both claim to trim-and-clamp — a future edit to one that quietly
    /// diverges from the other is exactly the kind of drift a shared
    /// function exists to prevent, and this is the test that would catch it.
    @Test("user(...) derives its own clamped title by calling commitTitle")
    func userAgreesWithCommitTitle() {
        // Titles with actual content: `user` stores exactly what `commitTitle`
        // makes of them.
        for raw in ["  Ship it  ", String(repeating: "z", count: 200), "Plain"] {
            let viaUser = QuickAction.user(title: raw, message: "go", among: []).title
            #expect(viaUser == QuickAction.commitTitle(raw),
                    Comment(rawValue: "user(title: \(raw.debugDescription)) produced \(viaUser.debugDescription), "
                            + "commitTitle produced \(QuickAction.commitTitle(raw).debugDescription)"))
        }
    }

    /// **A blank title given to `user(...)` is ABSENT, not an empty string —
    /// an earlier assertion here was wrong.**
    ///
    /// This case used to sit in the loop above, asserting `user(title: "")
    /// .title == commitTitle("")`, i.e. `Optional("")`. That certified the
    /// exact state `QuickAction.title` and `rejection` both describe as
    /// unreachable — "`user(title:message:among:)` and `pendingCommit` both
    /// map a cleared field to nil, never to `""`" — so the suite was pinning
    /// the counter-example to its own documentation rather than catching it.
    ///
    /// Two things must hold, and only the first is about storage: a blank
    /// title stores as nil, AND the id still comes from the MESSAGE rather
    /// than collapsing to the generic `"action"` fallback that every other
    /// blank-titled row would also collide with.
    @Test("a blank title is stored as absent, and the id still derives from the message",
          arguments: ["", "   ", "\t", "\n "])
    func userTreatsABlankTitleAsAbsent(_ blank: String) {
        let action = QuickAction.user(title: blank, message: "Ship the release", among: [])
        #expect(action.title == nil,
                Comment(rawValue: "stored \(action.title.debugDescription) rather than nil"))
        #expect(action.displayTitle == "Ship the release",
                "a blank title should leave the label derived from the message")
        #expect(action.id == "ship-the-release",
                Comment(rawValue: "id \(action.id.debugDescription) — a blank title collapsed the id to the "
                        + "generic fallback instead of slugging the message"))
    }

    /// **A de-duplicated id keeps its base — found in a real prefs file.**
    /// Adding buttons before typing anything into them produced
    /// `{"id": "action"}, {"id": "-2"}, {"id": "-3"}`: the suffix used to hang
    /// off the raw slug, which is empty in that case, so only the FIRST row
    /// got the `"action"` fallback and the rest got ids naming nothing.
    @Test("de-duplicating an empty slug keeps the action fallback as its base")
    func blankSlugDeduplicationKeepsItsBase() {
        // Three buttons added back to back, each still empty — the exact
        // sequence that produced "-2" and "-3" on disk.
        var set: [QuickAction] = []
        for _ in 0..<3 {
            set.append(QuickAction.user(title: nil, message: "", among: set))
        }
        #expect(set.map(\.id) == ["action", "action-2", "action-3"],
                Comment(rawValue: "ids were \(set.map(\.id)) — a suffix hung off an empty base"))
    }

    /// And the collision the bug produced, pinned directly: two blank-titled
    /// rows with DIFFERENT messages must get different ids, not `"action"`
    /// and `"action-2"`.
    @Test("two blank-titled buttons with different messages get message-derived ids")
    func blankTitledButtonsDoNotCollideOnAGenericID() {
        let first = QuickAction.user(title: "", message: "Ship the release", among: [])
        let second = QuickAction.user(title: "  ", message: "Roll it back", among: [first])
        #expect(first.id == "ship-the-release")
        #expect(second.id == "roll-it-back",
                Comment(rawValue: "second id was \(second.id.debugDescription) — both blank-titled rows "
                        + "fell back to the same generic slug"))
    }

    /// **The preview's own "no second opinion" claim,
    /// pinned at the exact boundary where it could quietly fail.**
    /// `ActionRowEditor`'s live input clamp is prefix-only, deliberately: it
    /// must never TRIM while the field has focus, because trimming under the
    /// typist's own fingers would eat a trailing space they just typed on
    /// the way to a next word. That means a draft can legitimately sit at
    /// `editorTitleCap` with trailing whitespace baked into the count — and
    /// the row's preview cell renders `commitTitle(draftTitle)`, not the raw
    /// draft, precisely so what it shows already matches what committing
    /// right now would actually store. This is the fact that promise rests
    /// on: at the cap, with trailing spaces, `commitTitle`'s output is
    /// SHORTER than the raw draft and the two are not equal.
    @Test("commitTitle trims trailing whitespace sitting exactly at the editor's own input cap")
    func commitTitleTrimsWhitespaceAtTheCapBoundary() {
        let draft = String(repeating: "X", count: 60) + "    "  // 64 chars: 60 real, 4 trailing spaces
        #expect(draft.count == QuickAction.editorTitleCap,
                "the fixture's own premise: the draft sits exactly at the live input cap")
        let committed = QuickAction.commitTitle(draft)
        #expect(committed == String(repeating: "X", count: 60),
                Comment(rawValue: "commitTitle produced \(committed.debugDescription) — trailing "
                        + "whitespace at the cap boundary should trim away entirely"))
        #expect(committed != draft,
                "the preview's own claim needs commitTitle's output to actually differ from the raw draft here")
    }

    // ------------------------------------------- label ⟂ message
    //
    // `title` became `String?`: `nil` means "derive the label
    // from the message" (`QuickAction.title`'s own doc comment). These pin
    // `displayTitle`'s resolution, `derivedTitle`'s own first-line/trim/clamp
    // rule, the shipped set's unchanged on-screen labels, `supersededTitles`'
    // explicit-only key, and the duplicate rule now comparing `displayTitle`.

    /// The resolution itself: explicit wins, and nil derives from the message.
    @Test("displayTitle returns the explicit title, or derives one from the message when nil")
    func displayTitleResolvesExplicitOrDerived() {
        let explicit = QuickAction(id: "a", title: "My Label", kind: .prompt("do the thing"))
        #expect(explicit.displayTitle == "My Label")

        let derived = QuickAction(id: "b", title: nil, kind: .prompt("do the other thing"))
        #expect(derived.displayTitle == "do the other thing")
    }

    /// The FIRST LINE only, trimmed, then clamped — a label must never
    /// become a paragraph once messages go multi-line (a later phase), and
    /// must never blow past what a pill can wear now.
    @Test("derivedTitle takes the first line only, trims it, and clamps to editorTitleCap")
    func derivedTitleTakesFirstLineTrimmedAndClamped() {
        let multiline = QuickAction(id: "a", title: nil,
                                    kind: .prompt("  first line here  \nsecond line\nthird"))
        #expect(multiline.displayTitle == "first line here",
                Comment(rawValue: "got \(multiline.displayTitle.debugDescription) — expected only the first "
                        + "line, trimmed, with later lines dropped entirely"))

        let longLine = String(repeating: "q", count: 200)
        let longAction = QuickAction(id: "b", title: nil, kind: .prompt(longLine))
        #expect(longAction.displayTitle == String(repeating: "q", count: QuickAction.editorTitleCap),
                "a single long line should derive to exactly editorTitleCap characters, not the whole line")
    }

    /// **A blank label can never reach a real button.** Retiring "a button
    /// needs a label" made an empty label legal — it means "use the message" —
    /// but `decode` accepts any string under the `"title"` key, `""` included,
    /// so an explicitly-empty stored title had nothing standing behind it and
    /// would have produced an offerable, perfectly blank pill. `displayTitle`
    /// resolves blank-explicit exactly like absent.
    @Test("an explicitly empty or whitespace title derives instead of rendering blank",
          arguments: ["", "   ", "\n", "\t "])
    func blankExplicitTitleFallsThroughToTheDerivedOne(_ stored: String) {
        let action = QuickAction(id: "a", title: stored, kind: .prompt("Add the reference"))
        #expect(action.displayTitle == "Add the reference",
                Comment(rawValue: "a stored title of \(stored.debugDescription) rendered as "
                        + "\(action.displayTitle.debugDescription) — a blank button"))
        #expect(action.rejection(at: 0, among: [action]) == nil,
                "the row should be offerable; it has a message to derive from")
    }

    /// The same hazard from the other side: a message that OPENS with a blank
    /// line derives its label from the first line with something on it, not
    /// from the empty one. Reachable the moment the editor goes multi-line,
    /// and reachable from a stored prefs file today.
    @Test("a message beginning with blank lines derives from the first written line")
    func derivedTitleSkipsLeadingBlankLines() {
        let action = QuickAction(id: "a", title: nil,
                                 kind: .prompt("\n  \nAdd this reference\nto the list"))
        #expect(action.displayTitle == "Add this reference",
                Comment(rawValue: "derived \(action.displayTitle.debugDescription) — a leading blank "
                        + "line produced a blank label"))
    }

    /// **The duplicate rule compares TRIMMED labels, as it always did.** The
    /// rule it replaced read `$0.title.trimmed == cleanTitle`, both sides
    /// trimmed; `displayTitle` trims a derived label but returns an explicit
    /// one verbatim, so comparing raw would let `" Continue "` and
    /// `"Continue"` both stand — two buttons rendering identically with
    /// neither flagged.
    @Test("two titles differing only by surrounding whitespace are still a duplicate")
    func duplicateDetectionTrimsBothSides() {
        let first = QuickAction(id: "a", title: "Continue", kind: .prompt("go"))
        let second = QuickAction(id: "b", title: "  Continue  ", kind: .prompt("go again"))
        let set = [first, second]
        #expect(first.rejection(at: 0, among: set) == nil)
        #expect(second.rejection(at: 1, among: set) == "an earlier button already says that",
                "a padded copy of an earlier label was not seen as a duplicate")
    }

    /// Two rows deriving the SAME label are exactly as much a duplicate as
    /// two rows spelling it out by hand — `baseRejection`'s own comparison
    /// moved to `displayTitle` this phase so this holds.
    @Test("two derived rows whose messages produce the same label are a duplicate — the later one is rejected")
    func derivedDuplicateTitlesAreRejected() {
        let first = QuickAction(id: "a", title: nil, kind: .prompt("Ship it"))
        let second = QuickAction(id: "b", title: nil, kind: .prompt("Ship it"))
        let set = [first, second]
        #expect(first.rejection(at: 0, among: set) == nil,
                "the earlier of two identical derived rows should not be the one punished")
        #expect(second.rejection(at: 1, among: set) == "an earlier button already says that")
    }

    /// The shipped set's on-screen labels are byte-for-byte unchanged —
    /// `shipped`'s own doc comment states why `title: nil` on the first two
    /// derives EXACTLY the words this array used to spell out explicitly.
    @Test("the shipped set's on-screen labels are unchanged")
    func shippedSetDisplayTitlesAreUnchanged() {
        #expect(QuickAction.shipped.map(\.displayTitle) == ["Continue", "/compact", "Escape Key"])
    }

    /// `supersededTitles`/`migrated(_:)` key on the EXPLICIT title only — a
    /// derived row has no word of its own for the deck to have shipped and
    /// later renamed, so migration must leave it exactly alone.
    @Test("supersededTitles migrates a stored explicit default, and never fires for a derived row")
    func supersededTitlesOnlyMigratesExplicitTitles() {
        let storedExplicit = QuickAction(id: "compact", title: "Compact", kind: .prompt("/compact"))
        let migrated = QuickAction.migrated(storedExplicit)
        #expect(migrated.title == nil,
                Comment(rawValue: "an explicit stored default should migrate to the CURRENT shipped row's own "
                        + "title, which is itself derived (nil) now that \"compact\" ships without an explicit one"))
        #expect(migrated.displayTitle == "/compact")

        let storedDerived = QuickAction(id: "compact", title: nil, kind: .prompt("/compact"))
        #expect(QuickAction.migrated(storedDerived) == storedDerived,
                "a derived row has no explicit word for the deck to supersede — migration must not touch it")
    }

    /// `user(...)`'s id derives from `displayTitle` — explicit if typed, else
    /// the message — and the SLUG clamps separately (`idSlugCap`) so a
    /// whole-sentence message cannot produce a whole-sentence id.
    @Test("user(title:message:among:) with a long sentence message produces a bounded, unique id")
    func userDerivedTitleProducesABoundedUniqueID() {
        let sentence = "Add this reference to the list of places we still need to review before Friday"
        let first = QuickAction.user(title: nil, message: sentence, among: [])
        #expect(first.title == nil, "a nil title in should stay nil out — the whole point of the derived path")
        #expect(first.id.count <= QuickAction.idSlugCap,
                Comment(rawValue: "the id \(first.id.debugDescription) (\(first.id.count) chars) was not "
                        + "bounded by idSlugCap (\(QuickAction.idSlugCap))"))

        // A second row deriving the SAME label still gets a unique id — the
        // existing de-duplication loop runs on the clamped slug exactly as
        // it always has on an authored one.
        let second = QuickAction.user(title: nil, message: sentence, among: [first])
        #expect(second.id != first.id, "two rows deriving the same label collided on id")
        #expect(second.id.count <= QuickAction.idSlugCap + 4,
                "the de-dup suffix should add only a couple of characters to the bounded slug")
    }

    // ---------------------------------------------- Q3: decode-time id dedup
    //
    // `DeckPrefs.decode`'s own `quickActions` path
    // performed no id-dedup — a hand-edited prefs file with two rows sharing
    // an id left every id-keyed lookup this feature does (the Q3 editor's
    // own commit and remove) ambiguous about which row a draft actually
    // lands on. `dedupedByID` closes that: first entry wins, entry-wise, the
    // same tolerant-decode posture `QuickAction.decode` already takes for a
    // row it cannot parse at all.

    /// The rule itself, directly: two rows sharing an id decode to one — the
    /// FIRST — and a third, distinct id is untouched and keeps its place.
    @Test("dedupedByID keeps the first entry for a shared id and leaves distinct ids alone")
    func dedupedByIDKeepsFirstMatch() {
        let first = QuickAction(id: "dup", title: "First", kind: .prompt("go"))
        let second = QuickAction(id: "dup", title: "Second", kind: .prompt("go"))
        let other = QuickAction(id: "other", title: "Other", kind: .prompt("go"))
        let result = QuickAction.dedupedByID([first, other, second])
        #expect(result.map(\.id) == ["dup", "other"],
                "a duplicate id was not collapsed, or the surviving order changed")
        #expect(result.first?.title == "First",
                "the LATER duplicate won instead of the first")

        // No duplicates at all: untouched, order preserved.
        let clean = [first, other]
        #expect(QuickAction.dedupedByID(clean) == clean)
    }

    /// **Through the real decoder, not just the pure function in isolation**
    /// — a hand-edited prefs file with two rows sharing an id, decoded the
    /// way a launch actually decodes one, must land on exactly one row for
    /// that id. Migration runs before the dedup in `DeckPrefs.decode`, so
    /// this also proves the two compose: a duplicated SHIPPED id still
    /// migrates its surviving row's old title forward.
    @Test("DeckPrefs.decode collapses two stored rows that share an id, first wins")
    func decodeDedupsSharedIDs() {
        let stored: [JSONValue] = [
            .object(["id": .string("continue"), "title": .string("Continue"), "prompt": .string("Continue")]),
            .object(["id": .string("continue"), "title": .string("Second Copy"), "prompt": .string("go")]),
            .object(["id": .string("compact"), "title": .string("/compact"), "prompt": .string("/compact")]),
        ]
        let prefs = DeckPrefs.decode(.object(["quickActions": .array(stored)]))
        #expect(prefs.quickActions.map(\.id) == ["continue", "compact"],
                Comment(rawValue: "expected the duplicate \"continue\" row collapsed, got "
                        + "\(prefs.quickActions.map(\.id))"))
        #expect(prefs.quickActions.first?.title == "Continue",
                "the first stored row for the duplicated id did not win")

        // Round-trip: encoding the deduped set and decoding it again is a
        // fixed point — no duplicate survives to be re-introduced, and
        // nothing about a CLEAN set (no duplicates to begin with) is
        // disturbed by passing through `dedupedByID` a second time.
        let reencoded = DeckPrefs.decode(prefs.encoded())
        #expect(reencoded.quickActions == prefs.quickActions,
                "the deduped set did not round-trip through encode/decode unchanged")
    }

    // -------------------------------------------------------- Q3: reordering
    //
    // `moved(_:fromOffsets:toOffset:)` is the pure arithmetic behind a drag
    // in the editor — SwiftUICore's own `move(fromOffsets:toOffset:)`
    // semantics, reimplemented so `DeckCore` (no platform framework) can
    // still be tested against them headlessly.

    private func actions(_ ids: String...) -> [QuickAction] {
        ids.map { QuickAction(id: $0, title: $0, kind: .prompt($0)) }
    }

    /// A single row dragged later in the list — "insert before offset 4" on
    /// a 5-row list moves B to just ahead of E.
    @Test("a single row moves later in the list")
    func singleRowMovesLater() {
        let start = actions("A", "B", "C", "D", "E")
        let result = QuickAction.moved(start, fromOffsets: [1], toOffset: 4)
        #expect(result.map(\.id) == ["A", "C", "D", "B", "E"])
    }

    /// The same row dragged earlier — "insert before offset 1" moves D to
    /// just after A.
    @Test("a single row moves earlier in the list")
    func singleRowMovesEarlier() {
        let start = actions("A", "B", "C", "D", "E")
        let result = QuickAction.moved(start, fromOffsets: [3], toOffset: 1)
        #expect(result.map(\.id) == ["A", "D", "B", "C", "E"])
    }

    /// A multi-row selection, moved to the very end — `destination ==
    /// count` is `onMove`'s own way of saying "append after everything".
    /// The two rows keep their own relative order (A before C) rather than
    /// the order `IndexSet` happens to iterate.
    @Test("a multi-row selection moves to the end, keeping relative order")
    func multiRowSelectionMovesToEnd() {
        let start = actions("A", "B", "C", "D", "E")
        let result = QuickAction.moved(start, fromOffsets: [0, 2], toOffset: 5)
        #expect(result.map(\.id) == ["B", "D", "E", "A", "C"])
    }

    /// Order is round-trippable to the identity permutation — dragging a row
    /// onto its own current slot changes nothing.
    @Test("moving a row to its own position is a no-op")
    func movingToOwnPositionIsANoOp() {
        let start = actions("A", "B", "C")
        // Offset 1 (B) to destination 1 — "insert before B's own current
        // slot" — is exactly where it already sits once removed and
        // reinserted at the corrected offset.
        let result = QuickAction.moved(start, fromOffsets: [1], toOffset: 1)
        #expect(result.map(\.id) == ["A", "B", "C"])
    }

    /// A stale offset past the end of the array — a view that raced its own
    /// data update — is ignored rather than trapping. An entirely
    /// out-of-range source moves nothing at all.
    @Test("an out-of-range offset is ignored rather than crashing")
    func outOfRangeOffsetIsIgnored() {
        let start = actions("A", "B", "C")
        let mixed = QuickAction.moved(start, fromOffsets: [1, 99], toOffset: 0)
        #expect(mixed.map(\.id) == ["B", "A", "C"],
                "the valid offset in a mixed set was not applied")
        let allInvalid = QuickAction.moved(start, fromOffsets: [99], toOffset: 0)
        #expect(allInvalid.map(\.id) == ["A", "B", "C"],
                "an entirely out-of-range source changed the order")
    }

    /// **The reason any of this matters, stated as a test.** Order now
    /// drives two live things: the bar's own fill order (`QuickActionBar`'s
    /// `ForEach`, over `OverviewLayout.actionPillLayout`'s own rows) and
    /// which action the overflow menu hides first (`actionPillLayout`'s
    /// own `hiddenCount` takes from the END of the list). Moving the LAST
    /// action to the FRONT must change which id sits last, not merely
    /// reorder cosmetically.
    @Test("reordering changes which action is last, and therefore first to hide")
    func reorderingChangesWhichActionHidesFirst() {
        let start = actions("A", "B", "C")
        #expect(start.last?.id == "C")
        let result = QuickAction.moved(start, fromOffsets: [2], toOffset: 0)
        #expect(result.last?.id == "B",
                "moving C to the front should leave B, not C, as the last (first-to-hide) action")
    }

    // --------------------------------------------------------- dialog answers
    //
    // Titles are the parity deliverable. Nothing else in the suite reads them,
    // so regressing to the middle-dot forms passed 501 tests.

    /// Exactly three entries with matching titles, kinds, and stable ids.
    @Test("dialogAnswers pins the three terminal dialog options")
    func dialogAnswersStructure() {
        let answers = QuickAction.dialogAnswers
        #expect(answers.count == 3, "dialogAnswers carries a different number of entries")

        #expect(answers[0].id == "dialog-1")
        #expect(answers[0].title == "1. Yes")
        #expect(answers[0].kind == .dialogKey("1"))

        #expect(answers[1].id == "dialog-2")
        #expect(answers[1].title == "2. Yes, and don't ask again")
        #expect(answers[1].kind == .dialogKey("2"))

        #expect(answers[2].id == "dialog-3")
        #expect(answers[2].title == "3. No")
        #expect(answers[2].kind == .dialogKey("3"))
    }
}
