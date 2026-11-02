//
//  WriteAndQuestionTests.swift · Tests/DeckCoreTests
//
//  Cases P1.56–P1.58. Three more that were on the blocked list, and the fourth
//  time that list has been wrong. The question each row needed was the same
//  one: is this a claim about the *app*, or about a *rule*?
//

import Testing
import DeckCore

struct WriteAndQuestionTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private var hold: HoldID { HoldID(session: SessionID("a"), toolUseID: "t1") }

    /// In the half that is a rule.
    ///
    /// `rename(2)`'s atomicity is the filesystem's to provide and this cannot
    /// test it. What it can test is the **plan**: the target is never opened for
    /// a truncating write, and nothing lands on it before a backup exists. Same
    /// move effects-as-data made for class D — the ordering becomes a property
    /// of a list.
    @Test("the write plan backs up first, writes a temp, and never truncates the target")
    func writesAreBackedUpAndAtomic() {
        let target = "/Users/x/.claude/settings.json"
        let diff = SettingsMerge.install(into: JSONValue.object([:]), port: 8765)
        let plan = WritePlan.plan(diff, target: target, stamp: 1_784_962_297)

        #expect(WritePlan.violations(plan, target: target).isEmpty)
        #expect(plan.count == 3)
        if case .backup(let from, let to) = plan[0] {
            #expect(from == target)
            #expect(to.hasSuffix(".bak"), "the backup is not timestamped")
        } else { Issue.record("the first step is not a backup") }
        if case .rename(_, let to) = plan[2] { #expect(to == target) }
        else { Issue.record("the last step does not land on the target") }

        // The three ways a plan can be wrong, each found rather than assumed.
        #expect(!WritePlan.violations([.truncateAndWrite(path: target, contents: "{}")],
                                      target: target).isEmpty)
        #expect(!WritePlan.violations([.rename(from: "/tmp/x", to: target)],
                                      target: target).isEmpty)
        #expect(!WritePlan.violations([.backup(from: target, to: "/tmp/b")],
                                      target: target).isEmpty)
    }

    /// A second launch surrenders rather than racing for the port.
    ///
    /// This used to assert `LaunchDecision.decide(portAlreadyBound: true)`,
    /// which was a rule with tests and no callers for its whole life: the
    /// surrender is emergent from the OS refusing the bind, and what a person
    /// sees is `Connection.superseded`. So the assertion moved to the value
    /// that actually reaches the glass, and lives in `ConnectionTests`
    /// alongside the rest of that truth table.

    /// All-or-nothing answers.
    @Test("a multi-question call submits every answer at once, or none reaches the wire")
    func allOrNothingAnswers() {
        // The three questions are the ones Claude actually asked, lifted from
        // a capture in `Fixtures/events.ndjson`. A composed
        // fixture here would test what I expect a question to look like; this
        // one tests what one is.
        let call = QuestionCall(hold: hold, questions: Corpus.bannerFontDensity)
        let opened = DeckEvent.questionOpened(call, at: .start)

        func answer(_ question: String, _ labels: String...) -> Answer {
            Answer(question: Redacted(question), labels: labels.map(Redacted.init))
        }
        let full = [answer("Banner colour?", "Teal"),
                    answer("Font?", "Sans"),
                    answer("Density?", "Roomy")]

        // Fewer answers than questions is not a partial submission; it is not a
        // submission.
        for partial in [[], Array(full.prefix(1)), Array(full.prefix(2))] {
            let (state, effects) = Reducer.effects([opened,
                                                    .questionSubmitted(hold, answers: partial, at: at(1_000))])
            #expect(!effects.contains { if case .updatedInput = $0 { return true }; return false },
                    "\(partial.count) of 3 answers reached the wire")
            #expect(state.holds[hold]?.isOpen == true, "a partial submission closed the hold")
        }

        // All of them, at once.
        let (state, effects) = Reducer.effects([opened,
                                                .questionSubmitted(hold, answers: full, at: at(1_000))])
        let submitted = effects.compactMap { effect -> [Answer]? in
            if case .updatedInput(_, let answers) = effect { return answers }
            return nil
        }
        #expect(submitted == [full])
        #expect(effects.filter { $0.resolves(hold) }.count == 1)
        #expect(state.holds[hold]?.outcome == .updatedInput)

        // More answers than questions is equally not a submission.
        let (over, overEffects) = Reducer.effects([opened,
                                                   .questionSubmitted(hold, answers: full + [answer("Extra?", "Yes")],
                                                                      at: at(1_000))])
        #expect(!overEffects.contains { if case .updatedInput = $0 { return true }; return false })
        #expect(over.holds[hold]?.isOpen == true)

        // **The case counting could never see.** Three answers for three
        // questions, where two of them answer the same question and one question
        // is untouched. The old `[Int]` shape could not express it — a positional
        // array cannot answer a question twice — so the guard `answers.count ==
        // questionCount` was sufficient by accident of the type rather than by
        // being right.
        let duplicated = [answer("Banner colour?", "Teal"),
                          answer("Banner colour?", "Crimson"),
                          answer("Font?", "Sans")]
        let (dup, dupEffects) = Reducer.effects([opened,
                                                 .questionSubmitted(hold, answers: duplicated, at: at(1_000))])
        #expect(!dupEffects.contains { if case .updatedInput = $0 { return true }; return false },
                "three answers covering two questions reached the wire")
        #expect(dup.holds[hold]?.isOpen == true)

        // An answer with no label selected is not an answer either. A
        // multi-select row the user tabbed past has the right key and nothing
        // in it, and it must not count towards completeness.
        let empty = [answer("Banner colour?", "Teal"),
                     answer("Font?"),
                     answer("Density?", "Roomy")]
        let (blank, blankEffects) = Reducer.effects([opened,
                                                     .questionSubmitted(hold, answers: empty, at: at(1_000))])
        #expect(!blankEffects.contains { if case .updatedInput = $0 { return true }; return false })
        #expect(blank.holds[hold]?.isOpen == true)

        // And abandoning is a real outcome, not a partial one: the hold is
        // released to the terminal and nothing is answered.
        let (done, abandoned) = Reducer.effects([opened, .questionAbandoned(hold, at: at(2_000))])
        #expect(!abandoned.contains { if case .updatedInput = $0 { return true }; return false })
        #expect(abandoned.compactMap(\.resolution).first?.1 == .release)
        #expect(done.holds[hold]?.isOpen == false)
    }

    private func submitted(_ effects: [Effect]) -> [Answer]? {
        effects.compactMap { effect -> [Answer]? in
            if case .updatedInput(_, let answers) = effect { return answers }
            return nil
        }.first
    }

    /// `progress.picked` accumulates in tap order — fact 5's own finding —
    /// and used to ship that way: a multi-select answer whose element order
    /// depended on which finger landed first, where the terminal's own
    /// answer has no such thing to get wrong. The reducer now re-sorts at
    /// commit, so the tap order is a display fact only.
    @Test("a multi-select answer ships in option order, regardless of tap order")
    func multiSelectShipsInOptionOrder() {
        let q = Question(text: Redacted("Which apply?"), header: Redacted("Pick"),
                         options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                   QuestionOption(label: Redacted("B"), detail: Redacted("")),
                                   QuestionOption(label: Redacted("C"), detail: Redacted(""))],
                         multiSelect: true)
        let call = QuestionCall(hold: hold, questions: [q])
        let opened = DeckEvent.questionOpened(call, at: .start)

        // Tapped out of order: C, then A — B is never picked at all, so the
        // answer must also be a strict subset in the right relative order.
        let (state, effects) = Reducer.effects([
            opened,
            .questionPicked(hold, label: Redacted("C"), at: at(1_000)),
            .questionPicked(hold, label: Redacted("A"), at: at(1_500)),
            .questionCommitted(hold, at: at(2_000)),
        ])
        #expect(submitted(effects)?.first?.labels == [Redacted("A"), Redacted("C")],
                "the answer travelled in tap order instead of option order")
        #expect(state.holds[hold]?.outcome == .updatedInput)
    }

    // ------------------------------------------------------- typed answers

    /// The offered-label guard (`questionPicked`) is unmoved by the new
    /// door beside it: a PICK for a label the call never offered is still
    /// refused, exactly as before. Only `questionAnsweredFreely` — a
    /// distinct event a view can only reach through its own text field —
    /// bypasses it, and only for that same unoffered text.
    ///
    /// The blank-text case moved out of this suite: `questionAnsweredFreely`
    /// now carries `Redacted`, not `String`, and `Redacted(optional:)`
    /// refuses blank/whitespace-only text by failing to construct at all —
    /// redaction by construction, the same doctrine `Redacted` itself is
    /// built on. There is no longer a way to HAND the reducer a blank typed
    /// answer to refuse; the refusal happens one layer up, in
    /// `DeckRuntime.answerFreely`, where `TakeoverTests` covers it.
    @Test("a typed answer reaches the wire; the offered-label guard still refuses an unoffered pick")
    func freeTextBypassesTheGuardPicksStillDoNot() {
        let q = Question(text: Redacted("Which one?"), header: Redacted("Pick"),
                         options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                   QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                         multiSelect: false)
        let call = QuestionCall(hold: hold, questions: [q])
        let opened = DeckEvent.questionOpened(call, at: .start)

        var guarded = Reducer.run([opened])
        Reducer.reduce(&guarded, .questionPicked(hold, label: Redacted("Something else entirely"),
                                                  at: at(1_000)))
        #expect(guarded.answering[hold] == nil, "a pick for an unoffered label was accepted")
        #expect(guarded.holds[hold]?.isOpen == true)

        let (state, effects) = Reducer.effects([opened,
            .questionAnsweredFreely(hold, step: 0, text: Redacted("Something else entirely"),
                                    at: at(1_000))])
        #expect(submitted(effects)?.first?.labels == [Redacted("Something else entirely")],
                "the typed answer did not reach the wire")
        #expect(state.holds[hold]?.outcome == .updatedInput)
    }

    /// multiSelect: "Other" is one selectable answer, mirroring the
    /// terminal — the typed text joins `picked` as a single member beside
    /// any options already tapped, and re-submitting the identical string
    /// takes it back exactly like a second tap on an already-picked option.
    /// A DIFFERENT typed string REPLACES that entry rather than
    /// accumulating a second one beside it — the terminal has exactly one
    /// Other slot to type into, never two.
    @Test("multi-select free text joins the picked set as one entry, toggles like a pick, and edits replace rather than accumulate")
    func freeTextJoinsMultiSelectPickedSet() {
        let q = Question(text: Redacted("Which apply?"), header: Redacted("Pick"),
                         options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                         multiSelect: true)
        let call = QuestionCall(hold: hold, questions: [q])
        let opened = DeckEvent.questionOpened(call, at: .start)

        var state = Reducer.run([opened])
        Reducer.reduce(&state, .questionPicked(hold, label: Redacted("A"), at: at(1_000)))
        Reducer.reduce(&state, .questionAnsweredFreely(hold, step: 0, text: Redacted("Custom"),
                                                        at: at(1_500)))
        #expect(state.answering[hold]?.picked == [Redacted("A"), Redacted("Custom")])

        Reducer.reduce(&state, .questionAnsweredFreely(hold, step: 0, text: Redacted("Custom"),
                                                        at: at(2_000)))
        #expect(state.answering[hold]?.picked == [Redacted("A")],
                "resubmitting the identical text did not take it back")

        // The edit case: type it back in, differently. "Custom" is gone —
        // replaced by "Custom2", not sitting beside it — because `picked`
        // holds exactly at most one label outside the options, by the
        // reducer.
        Reducer.reduce(&state, .questionAnsweredFreely(hold, step: 0, text: Redacted("Custom"),
                                                        at: at(2_500)))
        Reducer.reduce(&state, .questionAnsweredFreely(hold, step: 0, text: Redacted("Custom2"),
                                                        at: at(3_000)))
        #expect(state.answering[hold]?.picked == [Redacted("A"), Redacted("Custom2")],
                "editing the typed answer accumulated a second Other entry instead of replacing the first")
    }
}
