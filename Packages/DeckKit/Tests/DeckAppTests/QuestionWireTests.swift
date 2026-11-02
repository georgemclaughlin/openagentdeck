//
//  QuestionWireTests.swift · Tests/DeckAppTests
//
//  Change 1's raw-passthrough claim and change 2's honest refusal, both
//  driven through `DeckRuntime.handle` end to end — the same seam
//  `PermissionWireTests` exists for, one payload over. That suite's own
//  doc comment is the reason this one exists too: `HoldTests` and
//  `RenderSweepTests` seed a hold through the reducer directly, and
//  `TakeoverTests` drives `Reducer.reduce`/`Reducer.run`, so none of them
//  would notice `handle`'s or `openHold`'s own re-stamping constructors
//  dropping a field on the way through — which is exactly what
//  `permissionSuggestions` did, once, in this same tree, and what this
//  file is here to make sure `rawQuestions` and `questionsUnreadable`
//  never do.
//

import Testing
import Foundation
import DeckCore
@testable import DeckApp

@MainActor
struct QuestionWireTests {

    /// A fixture-shaped `AskUserQuestion` call with an injected `preview`
    /// key on one option — the audit's own finding: no recorded fixture
    /// carries one (all eight predate it), so a live round trip has to be
    /// synthesised. Driven through `handle`, not constructed mid-pipeline,
    /// so both re-stamp sites — `handle`'s own and `openHold`'s — are
    /// actually exercised; see either doc comment for why going around
    /// one of them is exactly how this trap has bitten before.
    @Test("a question call's preview key round-trips through handle, pick and the wire, verbatim")
    func previewRoundTripsEndToEnd() async throws {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        let session = SessionID("s-question-e2e")
        let hold = HoldID(session: session, toolUseID: "toolu-question-e2e")
        let rawQuestions = try #require(JSONValue.parse(
            #"[{"question":"Which approach?","header":"Approach","options":["#
            + #"{"label":"Rewrite","description":"Slower, cleaner","preview":"$ diff --stat\n 3 files changed"},"#
            + #"{"label":"Patch","description":"Faster, riskier"}],"multiSelect":false}]"#))
        let question = Question(text: Redacted("Which approach?"), header: Redacted("Approach"),
                                options: [QuestionOption(label: Redacted("Rewrite"),
                                                         detail: Redacted("Slower, cleaner"),
                                                         preview: Redacted("$ diff --stat\n 3 files changed")),
                                          QuestionOption(label: Redacted("Patch"),
                                                         detail: Redacted("Faster, riskier"))],
                                multiSelect: false)

        let event = HookEvent(id: EventID("q-e2e"), at: .start, kind: .preToolUse,
                              session: session, cwd: nil, tool: SubjectReader.questionTool,
                              toolUseID: hold.toolUseID, held: .value(120_000),
                              questions: [question], rawQuestions: rawQuestions)

        runtime.testClockMS = 0
        async let body = runtime.handle(event)

        // Let `handle`'s child task run up to its continuation before the
        // clock moves and the tap lands — the same interleaving forced in
        // `PermissionWireTests`, for the same reason.
        await Task.yield()

        #expect(runtime.frame.decisions.first?.hold == hold,
                "the hold never reached the frame, so nothing below is exercising handle at all")
        #expect(runtime.frame.decisions.first?.questions.first?.options.first?.preview?.value
                == "$ diff --stat\n 3 files changed",
                "the decoded preview did not survive to the frame")

        runtime.testClockMS = 1_000   // past the 250 ms arm delay
        runtime.pick(hold, Redacted("Rewrite"))

        let response = await body
        let parsed = try #require(JSONValue.parse(response),
                                  Comment(rawValue: "handle's response was not valid JSON: \(response)"))
        let updated = try #require(parsed["hookSpecificOutput"]?["updatedInput"])
        let echoedPreview = updated["questions"]?.arrayValue?.first?["options"]?
            .arrayValue?.first?["preview"]?.stringValue
        #expect(echoedPreview == "$ diff --stat\n 3 files changed",
                "the preview key was stripped from the tool's own input on the way back")
        #expect(updated["answers"]?["Which approach?"]?.stringValue == "Rewrite")
    }

    /// Fix 3's ruling — "never hold what you cannot answer" — is the
    /// stronger fix over the honest-refusal notice this test used to pin:
    /// an unreadable `AskUserQuestion` no longer opens a hold AT ALL.
    /// `HoldPolicy.needsAHuman` refuses it before `handle` ever reaches
    /// `openHold` or the continuation that blocks on a human, so the
    /// response is `{}` — immediately, not after a release — and the
    /// terminal sees the question with zero deck-added delay, the same as
    /// if the deck had never intercepted the call. No decision reaches the
    /// frame for it, which is the same fact `UnreadableQuestionNotice`
    /// (deleted along with `Decision.questionsUnreadable` — both went
    /// unreachable once a hold for this case could no longer exist) used to
    /// have to render honestly; there is nothing left here to render at all.
    @Test("an unreadable question call opens no hold and answers instantly")
    func unreadableQuestionCallOpensNoHold() async throws {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        let session = SessionID("s-question-unreadable")
        let hold = HoldID(session: session, toolUseID: "toolu-question-unreadable")
        let event = HookEvent(id: EventID("q-bad"), at: .start, kind: .preToolUse,
                              session: session, cwd: nil, tool: SubjectReader.questionTool,
                              toolUseID: hold.toolUseID, held: .value(120_000),
                              questions: [], questionsUnreadable: true)

        runtime.testClockMS = 0
        // No `async let` / `Task.yield()` interleaving needed — the whole
        // point is that this returns without ever reaching a continuation
        // that waits on a human. If it opened a hold instead, `await`ing
        // this directly would hang the test until the budget above expired.
        let response = await runtime.handle(event)
        #expect(response == "{}",
                "an unreadable question call answered with something other than instant nothing")
        #expect(runtime.frame.decisions.isEmpty,
                "a decision reached the frame for a call the deck refused to hold at all")
    }

    /// **`answers` surviving `handle`'s re-stamp,
    /// end to end — `triggersExactlyOnce`'s template, one field over.**
    /// `rawQuestions`/`questionsUnreadable` already have `
    /// previewRoundTripsEndToEnd` above as their own proof that `handle`'s
    /// re-stamping constructor does not silently drop them; `answers` had
    /// no equivalent, and every golden test for the question-mirror arc's
    /// own `.postToolUse` retirement drives `Reducer.reduce`/`Reducer.run`
    /// DIRECTLY — never `handle` — so a field dropped on the way through
    /// `handle`'s constructor would be invisible to every one of them and
    /// would only ever surface live, on the strip, as a hold that never
    /// closes.
    ///
    /// Also the direct proof of the SECOND half of the same gap: the
    /// effects `apply(.hook(arrived))` returns inside `handle` used to be
    /// discarded entirely, so even a `PostToolUse` that DID carry its
    /// `answers` intact would retire the hold in the REDUCER's own state
    /// and never resume the `waiting` continuation blocking the terminal's
    /// own `curl` — this test hangs (on the 8 s question budget's own
    /// real-time timer, not 120 s) rather than failing cleanly if either
    /// half regresses, the same accepted shape `previewRoundTripsEndToEnd`
    /// above already has via `pick`.
    @Test("a PostToolUse answered elsewhere retires a still-open hold and closes its own held connection")
    func postToolUseRetiresAStillOpenHoldThroughHandle() async throws {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        let session = SessionID("s-answered-elsewhere")
        let hold = HoldID(session: session, toolUseID: "toolu-answered-elsewhere")
        let question = Question(text: Redacted("Pick"), header: Redacted("Header"),
                                options: [QuestionOption(label: Redacted("Option A"), detail: Redacted(""))],
                                multiSelect: false)
        let preToolUse = HookEvent(id: EventID("pre"), at: .start, kind: .preToolUse,
                                   session: session, cwd: nil, tool: SubjectReader.questionTool,
                                   toolUseID: hold.toolUseID, held: .value(8_000),
                                   questions: [question])

        runtime.testClockMS = 0
        async let body = runtime.handle(preToolUse)
        await Task.yield()

        #expect(runtime.frame.decisions.first?.hold == hold,
                "the hold never reached the frame, so PostToolUse has nothing to retire")

        // The terminal answers directly — a `PostToolUse` for the SAME
        // `tool_use_id`, carrying the chosen answer, arriving well inside
        // the budget. `answers` is the field this test exists to protect.
        runtime.testClockMS = 500
        let postToolUse = HookEvent(id: EventID("post"), at: .start, kind: .postToolUse,
                                    session: session, cwd: nil, tool: SubjectReader.questionTool,
                                    toolUseID: hold.toolUseID, held: .absent, questions: [question],
                                    answers: [Answer(question: Redacted("Pick"), labels: [Redacted("Option A")])])
        let postResponse = await runtime.handle(postToolUse)
        #expect(postResponse == "{}",
                "PostToolUse's own response should be no-opinion — it observes, it never holds")

        // The ORIGINAL PreToolUse connection — the one actually blocking a
        // human, or a hung deck, or nothing — must close NOW, not eight
        // real seconds from now.
        let preResponse = await body
        #expect(preResponse == "{}",
                "the held connection was not resumed when PostToolUse retired its hold")
        #expect(runtime.frame.decisions.isEmpty,
                "the hold is still showing as an actionable decision after being retired")
    }
}
