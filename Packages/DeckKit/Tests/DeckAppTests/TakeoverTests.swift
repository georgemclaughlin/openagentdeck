//
//  TakeoverTests.swift · Tests/DeckAppTests
//
//  Answering a question call, and the pairing that decides whose decision is
//  on screen.
//
//  The views are SwiftUI's to draw; what is tested here is what they read and
//  what they send — the progress a takeover renders, and the rule that a
//  decision belongs to the session it names.
//

import Testing
import Foundation
import DeckCore
@testable import DeckApp

@MainActor
struct TakeoverTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private func questionCall(_ session: String, _ use: String,
                              questions: [Question], ms: Int64 = 0) -> [DeckEvent] {
        [.hook(HookEvent(id: EventID("start-\(session)"), at: at(ms), kind: .sessionStart,
                         session: SessionID(session), cwd: Redacted("/w/\(session)"),
                         tool: nil, toolUseID: nil, held: .absent)),
         .hook(HookEvent(id: EventID("q-\(session)-\(use)"), at: at(ms + 10), kind: .preToolUse,
                         session: SessionID(session), cwd: Redacted("/w/\(session)"),
                         tool: SubjectReader.questionTool, toolUseID: use,
                         held: .value(120_000), questions: questions))]
    }

    private func question(_ text: String, _ labels: [String],
                          multiSelect: Bool = false) -> Question {
        Question(text: Redacted(text), header: Redacted("Pick"),
                 options: labels.map { QuestionOption(label: Redacted($0),
                                                      detail: Redacted("")) },
                 multiSelect: multiSelect)
    }

    private func runtime(_ events: [DeckEvent]) -> DeckRuntime {
        let r = DeckRuntime()
        r.markStartedForTesting()
        r.replaceStateForTesting(Reducer.run(events))
        return r
    }

    // ------------------------------------------------------- the takeover

    /// A question call reaches the frame carrying its questions, which is what
    /// the takeover renders instead of Allow and Deny. Without this the deck
    /// can show a question and offer no way to answer it — which is the state
    /// the rewrite shipped in.
    @Test("a question call arrives as a decision with questions on it")
    func aQuestionCallIsAnAnswerableDecision() {
        let r = runtime(questionCall("alpha", "t1", questions: [
            question("Which colour?", ["Teal", "Coral"]),
        ]))

        let decision = r.frame.decisions.first
        #expect(decision != nil, "the question call produced no decision")
        #expect(decision?.questions.isEmpty == false,
                "the decision carries no questions, so Allow/Deny would be offered instead")
        #expect(decision?.currentQuestion?.options.count == 2)
        #expect(decision?.namesItsSubject == true,
                "a decision that cannot name its subject must not offer controls")
    }

    /// Picking then committing walks the call forward, and nothing reaches the
    /// wire until the last question is answered — answers are all-or-nothing.
    ///
    /// Driven through the reducer with explicit instants rather than through
    /// the runtime's clock. A tap inside the takeover's arm delay is REFUSED —
    /// correctly, that is the rule that stops a rhythm tap answering a
    /// takeover that just appeared — so a test on the real clock would be
    /// asserting how fast the machine is.
    @Test("picking and committing walks a multi-question call to the end")
    func theStepperWalksForward() {
        var state = Reducer.run(questionCall("alpha", "t1", questions: [
            question("First?", ["A", "B"]),
            question("Second?", ["C", "D"]),
        ]))
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        #expect(state.questions[hold] != nil, "the call never reached the reducer")

        // Past the arm delay, so the tap is a decision rather than a reflex.
        //
        // A single-select pick ANSWERS: the reducer commits it and advances in
        // the same step, which is the spec's "tapping options answers
        // outright". So there is no separate commit here, and a Next button
        // for a single-select question would have nothing to do.
        Reducer.reduce(&state, .questionPicked(hold, label: Redacted("A"), at: at(1_000)))
        #expect(state.answering[hold]?.step == 1,
                "a single-select pick did not answer and advance")
        #expect(state.answering[hold]?.gathered.count == 1,
                "the answer was not gathered, so all-or-nothing has nothing to send")

        // The frame the takeover actually reads.
        let frame = Projection.frame(from: state, at: at(2_100))
        #expect(frame.decisions.first?.currentQuestion?.text == Redacted("Second?"))
    }

    /// Stepping back is free, total and silent: it restores the answer and
    /// cannot underflow, so the takeover offers it whenever step > 0.
    @Test("stepping back returns to the previous question")
    func steppingBackReturns() {
        var state = Reducer.run(questionCall("alpha", "t1", questions: [
            question("First?", ["A", "B"]),
            question("Second?", ["C", "D"]),
        ]))
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")

        Reducer.reduce(&state, .questionPicked(hold, label: Redacted("A"), at: at(1_000)))
        #expect(state.answering[hold]?.step == 1)

        Reducer.reduce(&state, .questionSteppedBack(hold, at: at(3_000)))
        #expect(state.answering[hold]?.step == 0,
                "Back did not return to the previous question")
        #expect(state.answering[hold]?.picked == [Redacted("A")],
                "stepping back lost the answer it was supposed to restore")
    }

    /// Multi-select is the case that needs a commit control: taps toggle and
    /// accumulate, and nothing advances until the user says so.
    @Test("a multi-select question accumulates picks and waits to be committed")
    func multiSelectAccumulates() {
        var state = Reducer.run(questionCall("alpha", "t1", questions: [
            question("Which apply?", ["A", "B", "C"], multiSelect: true),
            question("And then?", ["D", "E"]),
        ]))
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")

        Reducer.reduce(&state, .questionPicked(hold, label: Redacted("A"), at: at(1_000)))
        Reducer.reduce(&state, .questionPicked(hold, label: Redacted("C"), at: at(1_500)))
        #expect(state.answering[hold]?.picked == [Redacted("A"), Redacted("C")],
                "multi-select did not accumulate")
        #expect(state.answering[hold]?.step == 0, "multi-select advanced without being told to")

        // Tapping a picked option again takes it back.
        Reducer.reduce(&state, .questionPicked(hold, label: Redacted("A"), at: at(2_000)))
        #expect(state.answering[hold]?.picked == [Redacted("C")], "a second tap did not deselect")

        Reducer.reduce(&state, .questionCommitted(hold, at: at(2_500)))
        #expect(state.answering[hold]?.step == 1, "the commit did not advance")
    }

    // ------------------------------------------------- whose decision is it

    /// **The pairing bug.**
    ///
    /// The detail showed `decisions.first`, so selecting a quiet session could
    /// put ANOTHER session's Allow and Deny above its detail — a decision
    /// offered under the wrong name. A hold knows its session, so the pairing
    /// is made rather than assumed.
    @Test("a decision belongs to the session that owns its hold")
    func decisionsArePairedToTheirSession() {
        var events = questionCall("alpha", "t1", questions: [question("A?", ["x"])])
        events += questionCall("beta", "t2", questions: [question("B?", ["y"])], ms: 100)
        let r = runtime(events)

        #expect(r.frame.decisions.count == 2, "the fixture needs two waiting sessions")

        for session in ["alpha", "beta"] {
            let id = SessionID(session)
            let mine = r.frame.decisions.first { $0.hold.session == id }
            #expect(mine != nil, "\(session) has a hold but no decision paired to it")
            #expect(mine?.hold.session == id,
                    "the decision shown for \(session) belongs to another session")
        }

        // And the two are genuinely different, so the pairing is doing work
        // rather than passing because both happen to be the same decision.
        let alpha = r.frame.decisions.first { $0.hold.session == SessionID("alpha") }
        let beta = r.frame.decisions.first { $0.hold.session == SessionID("beta") }
        #expect(alpha?.hold != beta?.hold)
    }

    // --------------------------------------------------------- free text

    /// **Redaction by construction, exercised at the layer that owns it.**
    /// `questionAnsweredFreely`'s `text` is `Redacted`, not `String` — blank
    /// or whitespace-only input is refused by `Redacted(optional:)` failing
    /// to construct, inside `DeckRuntime.answerFreely` itself, before an
    /// event exists for the reducer to receive at all. This used to be
    /// pinned as a reducer-level guard in `WriteAndQuestionTests`; it moved
    /// here because the reducer no longer has a `String` it could refuse.
    @Test("answerFreely refuses blank text before an event is ever built")
    func answerFreelyRefusesBlankText() {
        let r = runtime(questionCall("alpha", "t1", questions: [
            question("Which one?", ["A", "B"]),
        ]))
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")

        r.testClockMS = 1_000
        r.answerFreely(hold, "   ", step: 0)
        #expect(r.frame.decisions.first?.progress?.picked.isEmpty ?? true,
                "whitespace-only text reached the reducer as a pick")
        #expect(r.frame.decisions.first?.hold == hold, "the hold resolved on a blank submit")
    }

    /// **The staleness fix, exercised at the layer it fixes.** `answerFreely`
    /// used to read `step` off LIVE state — `state.answering[hold]?.step`,
    /// at the moment the call landed — which made the reducer's own
    /// `progress.step == step` guard compare a number to itself: the value
    /// could never fail to match, on any input, because both sides were the
    /// same read of the same state. Passing the caller's own step (the one
    /// `OtherAnswerField` captured when its field opened) is what makes a
    /// submit racing a step change something the reducer can actually
    /// catch, rather than something this call quietly launders into a fresh
    /// one.
    @Test("answerFreely against a stale step is refused, not laundered into a fresh one")
    func answerFreelyRefusesAStaleStep() {
        let r = runtime(questionCall("alpha", "t1", questions: [
            question("First?", ["A", "B"]),
            question("Second?", ["C", "D"], multiSelect: true),
        ]))
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")

        r.testClockMS = 1_000
        r.pick(hold, Redacted("A"))   // a single-select answer commits and advances
        #expect(r.frame.decisions.first?.progress?.step == 1,
                "the fixture needs to be on the second question for this to test anything")

        // Submitted against step 0 — the question that was on screen when a
        // (hypothetical) field opened — after the stepper has already moved
        // on to step 1.
        r.testClockMS = 1_500
        r.answerFreely(hold, "typed against a stale step", step: 0)
        #expect(r.frame.decisions.first?.progress?.step == 1, "a stale submit moved the stepper")
        #expect(r.frame.decisions.first?.progress?.picked.isEmpty ?? true,
                "a stale submit's text reached the live step's picked set")

        // The current step accepts the identical shape of call.
        r.answerFreely(hold, "typed against the live step", step: 1)
        #expect(r.frame.decisions.first?.progress?.picked == [Redacted("typed against the live step")],
                "a submit against the live step was refused")
    }
}
