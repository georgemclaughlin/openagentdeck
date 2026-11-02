//
//  HoldLifecycleTests.swift · Tests/DeckCoreTests
//
//  What happens to a request nobody answers, and what the deck keeps
//  afterwards.
//
//  A hold is an HTTP request held open while a human decides. Every one this
//  codebase builds is `frontendOwned: true`, so when the budget runs out the
//  deck RELEASES it — the terminal owns the call from that instant. The
//  request is still sitting there and a human is still needed; they are needed
//  somewhere the deck cannot reach.
//
//  The deck used to repaint that lane as ordinary working. Two minutes after a
//  session asked for permission, its card went from the loudest treatment on
//  the glass to one of the quietest and the waiting counter ticked down — at
//  the exact moment the deck stopped being able to help. That is the deck
//  concealing a session waiting for a human, on a timer, silently.
//

import Testing
import DeckCore

struct HoldLifecycleTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private func opening(_ session: String, _ use: String, ms: Int64,
                         questions: [Question] = []) -> [DeckEvent] {
        [.hook(HookEvent(id: EventID("start-\(session)"), at: at(ms), kind: .sessionStart,
                         session: SessionID(session), cwd: Redacted("/w/\(session)"),
                         tool: nil, toolUseID: nil, held: .absent)),
         .hook(HookEvent(id: EventID("call-\(session)-\(use)"), at: at(ms + 10),
                         kind: .preToolUse, session: SessionID(session),
                         cwd: Redacted("/w/\(session)"),
                         tool: questions.isEmpty ? "Bash" : SubjectReader.questionTool,
                         toolUseID: use, held: .value(120_000),
                         questions: questions))]
    }

    private static let question = Question(
        text: Redacted("Which one?"), header: Redacted("Pick"),
        options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                  QuestionOption(label: Redacted("B"), detail: Redacted(""))],
        multiSelect: false)

    // ------------------------------------------------- a release is not an answer

    /// **The one this file exists for.**
    ///
    /// Timing out hands the call back to the terminal. It does not answer it,
    /// so the lane may not be drawn as though somebody had.
    @Test("a timed-out request leaves the session asking for a human")
    func aReleasedHoldKeepsItsLaneWaiting() {
        var state = Reducer.run(opening("alpha", "t1", ms: 0))
        #expect(state.lanes[SessionID("alpha")]?.state == .needsYou,
                "the fixture never reached needs-you")

        Reducer.reduce(&state, .holdExpired(HoldID(session: SessionID("alpha"), toolUseID: "t1"),
                                            at: at(130_000)))

        #expect(state.lanes[SessionID("alpha")]?.state == .needsYou,
                "the deck stopped saying a human is needed while a human is still needed")

        let frame = Projection.frame(from: state, at: at(130_000))
        #expect(frame.mastNeedsYou == 1,
                "the waiting counter ticked down for a request that is still waiting")
        // And it offers no controls for it: the deck cannot relay a decision
        // it no longer holds, so a live Allow would be a button that lies.
        #expect(frame.decisions.isEmpty,
                "the deck offers a decision for a hold it has already released")
    }

    /// **Why release is the only expiry that ships.**
    ///
    /// The reducer picks `.release` or `.deny` on `hold.frontendOwned`, and
    /// every hold this codebase constructs sets it true — so the deny branch,
    /// and the `.errored` lane it paints, are unreachable in production. That
    /// is worth pinning: it is the reason the release path had to stop being
    /// treated as a footnote, and if a headless hold is ever introduced this
    /// test is where somebody finds out the two paths differ.
    @Test("every hold the reducer opens is frontend-owned")
    func everyHoldIsFrontendOwned() {
        var state = Reducer.run(opening("alpha", "t1", ms: 0))
        for event in opening("beta", "t2", ms: 1_000, questions: [Self.question]) {
            Reducer.reduce(&state, event)
        }
        #expect(!state.holds.isEmpty)
        for (id, hold) in state.holds {
            #expect(hold.frontendOwned,
                    Comment(rawValue: "\(id) is headless — its expiry denies rather than "
                            + "releases, and paints the lane errored"))
        }
    }

    /// Answering it normally does move the lane on — the acknowledgement IS
    /// the response write, and that has not changed.
    @Test("answering a request moves the lane off needs-you")
    func decidingMovesTheLane() {
        var state = Reducer.run(opening("alpha", "t1", ms: 0))
        Reducer.reduce(&state, .decision(HoldID(session: SessionID("alpha"), toolUseID: "t1"),
                                         .allow, at: at(5_000)))
        #expect(state.lanes[SessionID("alpha")]?.state == .working)
    }

    // --------------------------------------------------- what the deck keeps

    /// A resolved hold takes its question call and its half-finished answer
    /// with it — on every path, not only the two that remembered to.
    @Test("a resolved question call is not kept", arguments: [true, false])
    func questionStateGoesWithTheHold(_ byExpiry: Bool) {
        var state = Reducer.run(opening("alpha", "t1", ms: 0, questions: [Self.question]))
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        #expect(state.questions[hold] != nil, "the fixture opened no question call")

        Reducer.reduce(&state, .questionPicked(hold, label: Redacted("A"), at: at(1_000)))

        if byExpiry {
            Reducer.reduce(&state, .holdExpired(hold, at: at(130_000)))
        } else {
            Reducer.reduce(&state, .decision(hold, .allow, at: at(5_000)))
        }

        #expect(state.questions[hold] == nil,
                Comment(rawValue: "the call survived \(byExpiry ? "expiry" : "a decision")"))
        #expect(state.answering[hold] == nil,
                Comment(rawValue: "the half-finished answer survived "
                        + "\(byExpiry ? "expiry" : "a decision")"))
    }

    /// **A resolved hold is remembered long enough to refuse a retry.**
    ///
    /// This is why holds are kept at all: `state.holds[id] == nil` is the
    /// guard that stops a retried hook reopening a call somebody already
    /// answered. Forgetting them promptly would let one tool call be decided
    /// twice.
    @Test("a retried hook cannot reopen a decided call")
    func aDecidedCallRefusesAReopen() {
        var state = Reducer.run(opening("alpha", "t1", ms: 0))
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        Reducer.reduce(&state, .decision(hold, .allow, at: at(5_000)))
        #expect(state.holds[hold]?.isOpen == false)

        // The same call arrives again, as a retry would.
        for event in opening("alpha", "t1", ms: 6_000) { Reducer.reduce(&state, event) }
        #expect(state.holds[hold]?.isOpen == false,
                "a retried hook reopened a call that had already been answered")
    }

    /// And forgotten once no retry could possibly arrive — because keeping
    /// them forever made every frame walk every permission ever granted.
    ///
    /// The sweep is amortised: a pass that reclaims nothing raises its own bar
    /// to twice what survived, so it cannot re-scan on every resolution during
    /// a busy stretch. That is why this builds a run long enough for the
    /// window to actually mature rather than a few over the initial threshold.
    @Test("resolved holds are forgotten once they are old enough")
    func oldResolvedHoldsAreSwept() {
        var state = DeckState()
        let created = HoldPolicy.sweepAbove * 3
        for i in 0 ..< created {
            let ms = Int64(i) * 5_000
            for event in opening("s\(i)", "t\(i)", ms: ms) { Reducer.reduce(&state, event) }
            Reducer.reduce(&state, .decision(HoldID(session: SessionID("s\(i)"),
                                                    toolUseID: "t\(i)"),
                                             .allow, at: at(ms + 500)))
        }

        #expect(state.holds.count < created,
                Comment(rawValue: "kept all \(created) resolved holds — every frame walks them"))
        // Bounded by the window, not by the run. The plateau is the sweep's
        // threshold doubling, so a couple of multiples of it is the honest
        // ceiling to assert rather than a tight number that would drift.
        #expect(state.holds.count <= HoldPolicy.sweepAbove * 2 + 64,
                Comment(rawValue: "\(state.holds.count) resolved holds survived a run of "
                        + "\(created) — the retention window is not bounding them"))
    }

    /// The memory observable counts every side table, not a chosen few. It
    /// omitted `questions` and `answering`, which are the two that leaked.
    @Test("the memory observable counts the collections that can leak")
    func retainedItemsCountsEverything() {
        // TWO questions, because a single-select pick on a one-question call
        // answers outright — the reducer commits and resolves in the same
        // step, and the call is gone before anything can be counted.
        var state = Reducer.run(opening("alpha", "t1", ms: 0,
                                        questions: [Self.question, Self.question]))
        let bare = state.retainedItems
        Reducer.reduce(&state, .questionPicked(HoldID(session: SessionID("alpha"),
                                                      toolUseID: "t1"),
                                               label: Redacted("A"), at: at(1_000)))
        #expect(state.answering[HoldID(session: SessionID("alpha"), toolUseID: "t1")] != nil,
                "the fixture answered the whole call, so there is no in-flight state to count")
        #expect(state.retainedItems > bare,
                "an in-flight answer is not counted, so a leak in it would be invisible")
    }
}
