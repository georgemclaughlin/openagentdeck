//
//  TranscriptLedgerTests.swift · Tests/DeckCoreTests
//
//  The transcript-well's send-ledger — the design decision that the card
//  shows the last thing a person said through ANY door, a terminal prompt or
//  a deck send — and the debounce fact riding beside it on the same frame.
//  Both are DeckCore-reducer/projection halves of the transcript-well arc;
//  the view (`TranscriptWell` itself, pill dimming) is a later delivery —
//  these tests are the facts that delivery will render, proved here without
//  one.
//

import Testing
@testable import DeckCore

struct TranscriptLedgerTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private let s1 = SessionID("s1")

    private func hook(_ session: SessionID, _ kind: HookKind, _ ms: Int64,
                      prompt: String? = nil) -> DeckEvent {
        .hook(HookEvent(id: EventID("\(kind)-\(session.raw)-\(ms)"), at: at(ms),
                        kind: kind, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent,
                        prompt: Redacted(optional: prompt)))
    }

    private func started(_ session: SessionID, at ms: Int64 = 0) -> DeckState {
        var state = DeckState()
        Reducer.reduce(&state, hook(session, .sessionStart, ms))
        return state
    }

    // ------------------------------------------------------------- the ledger

    @Test("a confirmable send becomes the lane's prompt of record at wire time, not at the receipt")
    func confirmableSendIsThePromptAtSendTime() {
        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(110)))

        let lane = state.lanes[s1]
        #expect(lane?.prompt?.value.value == "Continue")
        #expect(lane?.prompts.first?.value.value == "Continue")
        #expect(lane?.transcript.last?.text.value == "Continue")
        #expect(lane?.transcript.last?.origin == .deck)
        #expect(lane?.transcript.last?.deckStatus == .sent)
        #expect(lane?.transcript.last?.actionID == "continue")
    }

    /// **The exact defect this ledger fixes.** A tapped `/compact` used to
    /// show nothing, forever: a slash command fires no `UserPromptSubmit`
    /// and an unconfirmable action retires from the queue the instant it is
    /// sent, so the only feedback a person ever got was a `GroupBox`
    /// flickering for the sub-second between queue and send.
    @Test("an unconfirmable send (/compact) becomes the prompt of record and stays sent, forever")
    func unconfirmableSendNeverGoesUnseen() {
        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "compact", at: at(110)))

        let lane = state.lanes[s1]
        #expect(lane?.prompt?.value.value == "/compact")
        #expect(lane?.transcript.last?.text.value == "/compact")
        #expect(lane?.transcript.last?.deckStatus == .sent)
        #expect(state.pending[s1] == nil, "an unconfirmable send still retires from the queue")

        // No receipt will ever arrive for it — a later, UNRELATED prompt
        // must not upgrade the row a receipt can never reach.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 200, prompt: "something else"))
        #expect(state.lanes[s1]?.transcript.first(where: { $0.actionID == "compact" })?.deckStatus == .sent)
    }

    @Test("a confirmable send's receipt upgrades its own transcript row to confirmed, rather than duplicating it")
    func receiptUpgradesRatherThanDuplicates() {
        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(110)))
        #expect(state.lanes[s1]?.transcript.count == 1)

        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 120, prompt: "Continue"))

        let lane = state.lanes[s1]
        #expect(lane?.transcript.count == 1, "the receipt duplicated the row instead of upgrading it")
        #expect(lane?.transcript.last?.deckStatus == .confirmed)
        #expect(state.pending[s1] == nil, "the receipt did not retire the confirmed entry")
    }

    /// **A regression guard.** Nothing enforces
    /// one-in-flight: a person can queue and send the same action twice
    /// before its first receipt lands (or two authored actions can share a
    /// payload). `transcript` sorts newest-first, so a naive `firstIndex`
    /// in `confirmTranscript` would upgrade the NEWEST `.sent` row while
    /// the queue's own matcher — which walks oldest-first — retires the
    /// OLDEST entry: two "which send was this?" answers that disagree, and
    /// if the second receipt never arrives, the inversion is permanent.
    /// The two must always name the same send.
    @Test("with two same-action sends in flight, the first receipt confirms the OLDEST ledger row and retires the OLDEST queue entry — the two must agree")
    func receiptConfirmsOldestOfTwoInFlightSends() {
        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(110)))
        // Queued and sent again, before any receipt for the first arrives —
        // the guard on `.actionQueued` only blocks a duplicate while the
        // existing entry's `sentAt` is still nil, so this is reachable.
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(120)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(130)))

        #expect(state.pending[s1]?.count == 2, "both sends should still be awaiting their own receipt")
        #expect(state.lanes[s1]?.transcript.filter { $0.actionID == "continue" }.count == 2)

        // One receipt arrives, matching both by text — it must retire and
        // confirm the SAME send.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 140, prompt: "Continue"))

        #expect(state.pending[s1]?.first?.queuedAt == at(120),
                "the receipt retired the wrong queue entry — the OLDEST (queuedAt 100) should be gone")

        let rows = state.lanes[s1]?.transcript.filter { $0.actionID == "continue" } ?? []
        #expect(rows.count == 2, "the receipt must upgrade in place, never duplicate")
        #expect(rows.first { $0.deckStatus == .confirmed }?.at == at(110),
                "the receipt confirmed the NEWEST ledger row instead of the OLDEST — the exact inversion the review caught")
        #expect(rows.first { $0.deckStatus == .sent }?.at == at(130),
                "the second send's own row should still read sent, awaiting its own receipt")
    }

    /// The other half of the same regression: if the second send's own
    /// receipt never comes back — the composer-splice case, where the
    /// echoed bytes do not match — its ledger row must stay `.sent`
    /// forever rather than being silently swept into `.confirmed` by
    /// anything that happens afterward.
    @Test("if the second send's own receipt never arrives, its ledger row stays sent forever")
    func secondSendStaysUnconfirmedIfItsOwnReceiptNeverArrives() {
        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(110)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(120)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(130)))

        // Only the first receipt ever lands.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 140, prompt: "Continue"))
        // Time passes, unrelated events keep arriving — nothing else may
        // ever confirm the second row.
        Reducer.reduce(&state, hook(s1, .stop, 500))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 600, prompt: "something unrelated"))

        let rows = state.lanes[s1]?.transcript.filter { $0.actionID == "continue" } ?? []
        #expect(rows.count == 2)
        #expect(rows.filter { $0.deckStatus == .sent }.count == 1,
                "the never-confirmed send must stay .sent, permanently")
        #expect(rows.filter { $0.deckStatus == .confirmed }.count == 1)
        #expect(state.pending[s1]?.count == 1, "the unconfirmed send stays visibly pending, forever")
    }

    /// **The third-order corner a follow-up review caught.** A button's
    /// payload can be RE-AUTHORED between two sends — same action id, new
    /// text — so two `.sent` rows can share an id while carrying genuinely
    /// different bytes. If the FIRST send's own receipt is lost (the
    /// composer-splice case) and the SECOND send's receipt then arrives, an
    /// action-id-only match would still find the oldest same-id row — the
    /// FIRST send's — and confirm it with a receipt that was never its own.
    @Test("a receipt for a re-authored action (same id, new payload) confirms the row with the matching text, not merely the oldest same-id row")
    func receiptMatchesTextAsWellAsActionID() {
        var state = started(s1)
        let original = QuickAction(id: "p1", title: "P1", kind: .prompt("hello"))
        Reducer.reduce(&state, .actionQueued(s1, original, at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "p1", at: at(110)))
        // Its own receipt is lost and will never arrive.

        // The button is re-authored — same id, new payload — and sent again.
        let reauthored = QuickAction(id: "p1", title: "P1", kind: .prompt("goodbye"))
        Reducer.reduce(&state, .actionQueued(s1, reauthored, at: at(200)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "p1", at: at(210)))

        // Only the SECOND send's own receipt arrives.
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 220, prompt: "goodbye"))

        let rows = state.lanes[s1]?.transcript.filter { $0.actionID == "p1" } ?? []
        #expect(rows.count == 2)
        #expect(rows.first { $0.text.value == "goodbye" }?.deckStatus == .confirmed,
                "the row whose text actually matches the receipt must be the one confirmed")
        #expect(rows.first { $0.text.value == "hello" }?.deckStatus == .sent,
                "the old-text row's own receipt was lost — a different send's receipt must not confirm it")
        #expect(state.pending[s1]?.count == 1, "the SECOND (matching-text) queue entry should be the one retired")
        #expect(state.pending[s1]?.first?.action.payload == "hello",
                "the surviving pending entry should be the first, still-unconfirmed one")
    }

    @Test("escape and other payload-less sends track the debounce instant but never touch the prompt or the ledger")
    func payloadLessSendsTouchNeitherPromptNorTranscript() {
        var state = started(s1)
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 50, prompt: "hello"))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[2], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "escape", at: at(110)))

        let lane = state.lanes[s1]
        #expect(lane?.prompt?.value.value == "hello", "an escape overwrote the last thing anybody actually said")
        // The human prompt from before joined the ledger normally; the
        // escape send beside it added nothing — the ledger still has
        // exactly the one row.
        #expect(lane?.transcript.map(\.text.value) == ["hello"])
        #expect(lane?.transcript.first?.origin == .terminal)
        #expect(lane?.lastSentAt["escape"] == at(110))
    }

    @Test("a re-delivered actionSent does not lengthen the ledger or move lastSentAt")
    func redeliveredSendIsIdempotent() {
        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "compact", at: at(110)))
        let once = state

        // The queue no longer holds "compact" — it retired at the first
        // send — so a re-delivered `.actionSent` for the same id finds no
        // matching entry and declines silently, the same guard
        // `.actionCancelled`/`.queueCleared` already lean on.
        Reducer.reduce(&state, .actionSent(s1, actionID: "compact", at: at(110)))
        #expect(state == once)
    }

    @Test("the ledger is capped like the prompt history, newest surviving")
    func ledgerIsCappedNewestFirst() {
        var state = started(s1)
        for i in 1...20 {
            let action = QuickAction(id: "p\(i)", title: "p\(i)", kind: .prompt("/p\(i)"))
            Reducer.reduce(&state, .actionQueued(s1, action, at: at(Int64(i) * 10)))
            Reducer.reduce(&state, .actionSent(s1, actionID: "p\(i)", at: at(Int64(i) * 10 + 1)))
        }
        let lane = state.lanes[s1]
        #expect(lane?.transcript.count == LaneRecord.historyCap)
        #expect(lane?.transcript.first?.actionID == "p20", "the newest fell off instead of the oldest")
        #expect(lane?.transcript.last?.actionID == "p\(20 - LaneRecord.historyCap + 1)")
    }

    // -------------------------------------------------- projection: LaneView

    @Test("LaneView.transcript merges the persisted ledger, oldest first, with the still-queued tail")
    func projectedTranscriptMergesQueuedTail() {
        var state = started(s1)
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(110)))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 120, prompt: "Continue")) // confirms it

        // A second, still-waiting send — never sent.
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(200)))

        let frame = Projection.frame(from: state, at: at(300))
        let lane = frame.lanes.first { $0.session == s1 }
        #expect(lane?.transcript.map(\.text.value) == ["Continue", "/compact"])
        #expect(lane?.transcript.first?.deckStatus == .confirmed)
        #expect(lane?.transcript.last?.deckStatus == .queued)
    }

    /// **Permutation safety, the arc's own bar.** `.actionQueued`/
    /// `.actionSent` are commands, not wire events — "order IS the
    /// history", the same doctrine `ReplayTests` already states for
    /// `.decision`/`.holdExpired` — so their OWN relative order cannot be
    /// scrambled (a send cannot precede its own queue). What this proves
    /// instead is the promise this arc actually needs: an UNRELATED
    /// session's hook events may land at any position around that fixed
    /// causal sequence without changing the outcome.
    @Test("a queue/send/receipt sequence on one session converges under every interleaving with unrelated hook events on another")
    func sendLedgerConvergesUnderInterleaving() {
        let session = SessionID("led-1")
        let other = SessionID("led-2")
        let start1 = hook(session, .sessionStart, 0)
        let start2 = hook(other, .sessionStart, 0)
        let queued = DeckEvent.actionQueued(session, QuickAction.shipped[0], at: at(100))
        let sent = DeckEvent.actionSent(session, actionID: "continue", at: at(110))
        let receipt = hook(session, .userPromptSubmit, 120, prompt: "Continue")
        let unrelated1 = hook(other, .preToolUse, 105)
        let unrelated2 = hook(other, .stop, 115)

        let orderings: [[DeckEvent]] = [
            [start1, start2, queued, sent, receipt, unrelated1, unrelated2],
            [start1, start2, unrelated1, queued, unrelated2, sent, receipt],
            [start2, start1, unrelated1, unrelated2, queued, sent, receipt],
            [start1, unrelated1, start2, queued, sent, unrelated2, receipt],
        ]
        let results = orderings.map { Reducer.run($0) }
        #expect(results.allSatisfy { $0 == results[0] },
                "the same causal sequence converged to different states depending on where the unrelated events landed")
        #expect(results[0].lanes[session]?.transcript.last?.deckStatus == .confirmed)
    }

    // --------------------------------------------------------- the debounce

    @Test("an unconfirmable send's own pill is dark; it re-arms only once the session's own next event lands")
    func debounceHoldsUntilNextSessionEvent() {
        var state = started(s1)
        Reducer.reduce(&state, .sessionSelected(s1, at: at(50)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[1], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "compact", at: at(110)))

        var frame = Projection.frame(from: state, at: at(120))
        #expect(frame.debouncingActionIDs.contains("compact"),
                "an unconfirmable send's own pill re-armed before the session moved again")

        // The session's own next lifecycle event — any kind — re-arms it.
        Reducer.reduce(&state, hook(s1, .stop, 200))
        frame = Projection.frame(from: state, at: at(210))
        #expect(!frame.debouncingActionIDs.contains("compact"),
                "the pill stayed dark past the session's own next event")
    }

    @Test("a queued-but-not-yet-sent action is dark; per-action independence keeps its neighbour live")
    func queuedActionIsDarkNeighbourStaysLive() {
        var state = started(s1)
        Reducer.reduce(&state, .sessionSelected(s1, at: at(50)))
        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 60, prompt: "work"))
        // Escape is queued (mid-turn) but not yet sent.
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[2], at: at(100)))

        let frame = Projection.frame(from: state, at: at(110))
        #expect(frame.debouncingActionIDs.contains("escape"))
        #expect(!frame.debouncingActionIDs.contains("continue"),
                "Continue darkened beside a queued Escape it has nothing to do with")
    }

    @Test("a sent-but-unconfirmed action stays dark across an unrelated same-session event, until its own receipt lands")
    func sentUnconfirmedStaysDarkAcrossUnrelatedEvents() {
        var state = started(s1)
        Reducer.reduce(&state, .sessionSelected(s1, at: at(50)))
        Reducer.reduce(&state, .actionQueued(s1, QuickAction.shipped[0], at: at(100)))
        Reducer.reduce(&state, .actionSent(s1, actionID: "continue", at: at(110)))

        // An unrelated event on the SAME session (a tool call) moves
        // `lastEventAt`, but the pending-entry half of the rule still
        // holds — the send has not been confirmed yet.
        Reducer.reduce(&state, hook(s1, .preToolUse, 150))
        var frame = Projection.frame(from: state, at: at(160))
        #expect(frame.debouncingActionIDs.contains("continue"),
                "a confirmable send re-armed off an unrelated event, before its own receipt")

        Reducer.reduce(&state, hook(s1, .userPromptSubmit, 200, prompt: "Continue"))
        frame = Projection.frame(from: state, at: at(210))
        #expect(!frame.debouncingActionIDs.contains("continue"))
    }
}
