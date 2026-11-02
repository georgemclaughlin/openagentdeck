//
//  QuestionPreviewFixtureTests.swift · Tests/DeckCoreTests
//
//  `LV37-question-preview` is the first recorded `AskUserQuestion` call that
//  carries option `preview` mockups. `QuestionOption.preview` has existed in
//  the model since the field's own audit found it undecoded, but every
//  fixture the corpus held until now — the seven calls in `events.ndjson`,
//  `LV14-plan`'s question, the `bannerFontDensity` triple — predates the
//  feature: none of those calls' options ever carried a `preview` key at
//  all, so nothing in the corpus had ever exercised the decode, the hold, or
//  the echo for one. `QuestionWireTests` (DeckAppTests) proved the wire
//  round trip with a hand-synthesised payload for exactly that reason.
//
//  **This fixture's own history, honestly.** The first version of it was
//  rejected as fabricated: its `ts` was copied from the
//  transcript's assistant-message timestamp rather than stamped at receipt,
//  its `held_ms` (8002) matched nothing any log ever recorded, its
//  `SessionStart` row described an event no recorder witnessed, and its
//  envelope mixed two hook-relay formats no real recorder ever emits
//  together. `payloads.ndjson` below is a genuine replacement: a
//  pure-observer hook — stamps `ts` at RECEIPT, records the payload verbatim
//  plus the CMUX `workspace`/`surface` environment, posts nothing, holds
//  nothing — ran alongside the deck's own hooks, 2026-08-07, while a scratch
//  session (`bypassPermissions`, session `b28a5fff-…`) reproduced the
//  original `Preview UI` question value-for-value (canonically identical
//  JSON; the two serializations differ in key order). The one number the
//  observer could not witness — `held_ms` on the `AskUserQuestion` row — is
//  the deck's OWN log measurement of the hold it actually opened and the user
//  actually closed by answering "Side-by-side" on the deck; `Corpus
//  .questionPreviewRun()`'s own doc comment cites the exact log lines.
//
//  `plan-mode-question.json` is a second, separate, real call — a different
//  session, a different day, assembled from that session's own transcript
//  rather than wire-recorded (`Corpus.planModeQuestionPayload`'s own doc
//  comment explains why it is a standalone payload rather than an ndjson
//  row). Its `permission_mode` reads `plan`, corrected from an earlier draft
//  that had it wrong — the transcript's bracketing entries all read `plan`,
//  and `ExitPlanMode` did not fire until 4 minutes after this call.
//

import Testing
// `@testable` for one reason: `QuestionReader.questions(from:)` — the
// all-or-nothing decode ingest itself calls — is internal, not public
// (`QuestionReader.question(from:)`, the per-row decoder, is the public
// half). Test (e) below needs the all-or-nothing guard, not a hand-rolled
// re-implementation of it, so it reaches for the same internal function
// `HookIngest.event(from:epochBase:)` calls rather than risk drifting from
// what ingest actually does.
@testable import DeckCore

struct QuestionPreviewFixtureTests {

    // ------------------------------------------------------------- a. ingest

    @Test("the recorded AskUserQuestion row decodes one question, three options, and every option carries a preview at its recorded geometry")
    func ingestDecodesAllThreePreviews() {
        let events = Corpus.questionPreviewRun()
        guard let ask = events.first(where: { $0.kind == .preToolUse && $0.tool == SubjectReader.questionTool }) else {
            Issue.record("the fixture lost its AskUserQuestion PreToolUse row")
            return
        }

        #expect(ask.questionsUnreadable == false,
                "the recorded call decoded as unreadable — the fixture's tool_input lost its shape")
        #expect(ask.questions.count == 1)

        let options = ask.questions.first?.options ?? []
        #expect(options.count == 3)

        let previews = options.compactMap { $0.preview?.value }
        #expect(previews.count == 3, "not every option carried a preview — the fixture's whole point is that all three do")

        // The recorded geometry future UI sizing tests rely on: 12, 19 and
        // 10 lines, none of them wider than 42 columns. Pinned here, off
        // the ingested model, rather than only off the raw scratchpad JSON,
        // so a future decoder change that mangled a preview's newlines
        // would fail THIS test rather than only a fixture-building script
        // nothing runs again.
        #expect(previews.map(SubjectOverflow.lineCount) == [12, 19, 10],
                "the recorded preview line counts moved")
        for preview in previews {
            for line in preview.split(separator: "\n", omittingEmptySubsequences: false) {
                // `.count` on a `Substring` measures extended GRAPHEME
                // CLUSTERS, not terminal display columns — the two diverge
                // the moment a line carries a wide character. The "Stacked
                // inline" preview's `⚙ 👤` line is exactly that case: 40
                // graphemes (this assertion's own unit) but 41 display
                // columns (a wide emoji renders two columns wide in a
                // terminal), so a future test sizing a view to a terminal
                // grid must not read "42" here as a column budget — it
                // measures a narrower thing than that.
                #expect(line.count <= 42, "a preview line exceeded the recorded 42-column geometry: \(line)")
            }
        }

        #expect(ask.rawQuestions != nil, "rawQuestions was nil for a readable AskUserQuestion PreToolUse")
    }

    // -------------------------------------------------------- b. host address

    @Test("the recorded AskUserQuestion row's host address carries the session's workspace and surface")
    func hostAddressThreadsThroughIngest() {
        let events = Corpus.questionPreviewRun()
        guard let ask = events.first(where: { $0.kind == .preToolUse && $0.tool == SubjectReader.questionTool }) else {
            Issue.record("the fixture lost its AskUserQuestion PreToolUse row")
            return
        }
        #expect(ask.host == HostAddress(workspace: "06943745-FF0C-4E50-B566-08504DD3B16A",
                                        surface: "F515C922-B35E-4A17-B6BD-6D37CAAA5BD9"),
                "the envelope's workspace/surface did not reach HookEvent.host")
    }

    // ------------------------------------------------------------- c. replay

    @Test("replayed through the reducer, only the AskUserQuestion row opens a hold — the Read row does not — and the hold's QuestionCall carries the previews")
    func replayOpensExactlyOneHoldWithPreviews() {
        let events = Corpus.questionPreviewRun()
        #expect(events.count == 3, "the recording gained or lost a row")
        #expect(events.contains { $0.permissionMode == "bypassPermissions" },
                "the fixture stopped recording the bypass mode this test is pinning")

        var state = DeckState()
        for event in events { Reducer.reduce(&state, .hook(event)) }

        #expect(state.holds.count == 1,
                "expected exactly one hold open after replay, got \(state.holds.count) — a question needs a human even under bypassPermissions")

        // Pinned from BOTH sides, not just by counting: the Read PreToolUse
        // row, recorded eleven seconds before the question, must not have
        // opened a hold of its OWN. The observer wrote it no `held_ms`
        // because it witnessed no hold, and the deck's own log agrees — no
        // hold span appears for that row either. Checking this exact
        // HoldID, rather than only `state.holds.count`, is what makes the
        // assertion about THIS row and not just about the total.
        let readHold = HoldID(session: SessionID("b28a5fff-e198-41c9-ba4a-a06df778e261"),
                              toolUseID: "toolu_01QWGJuCJiGuFyywPAeooQsY")
        #expect(state.holds[readHold] == nil,
                "the Read row opened a hold — bypassPermissions gates only what the engine actually asked about")

        guard let holdID = state.holds.keys.first else {
            Issue.record("no hold opened for the recorded question")
            return
        }
        #expect(holdID.toolUseID == "toolu_01BEiVAAiDngdBWGJWYhGHNc",
                "the one open hold was not the recorded AskUserQuestion call")
        #expect(state.holds[holdID]?.isOpen == true)

        guard let call = state.questions[holdID] else {
            Issue.record("the hold opened with no QuestionCall attached")
            return
        }
        #expect(call.questions.count == 1)
        let previews = call.questions.first?.options.compactMap { $0.preview?.value } ?? []
        #expect(previews.count == 3,
                "the previews did not survive the reducer's own QuestionCall composition")

        let frame = Projection.frame(from: state, at: events.last?.at ?? .start)
        #expect(frame.decisions.contains { $0.hold == holdID },
                "the hold opened but never reached the frame as a decision")
    }

    // --------------------------------------------------------------- d. echo

    @Test("the QuestionCall's rawQuestions stays value-identical to the recorded tool_input.questions, previews included")
    func questionCallRawQuestionsMatchesRecordedQuestions() {
        let events = Corpus.questionPreviewRun()
        var state = DeckState()
        for event in events { Reducer.reduce(&state, .hook(event)) }

        guard let holdID = state.holds.keys.first, let call = state.questions[holdID] else {
            Issue.record("no QuestionCall opened to check the echo against")
            return
        }

        // Row index 2: SessionStart (0), Read (1), AskUserQuestion (2).
        let row = Corpus.ndjson("live/LV37-question-preview/payloads.ndjson")[2]
        let recorded = row["payload"]?["tool_input"]?["questions"]
        #expect(recorded != nil, "the fixture row itself lost its questions array")

        // `DeckCoreTests` depends only on `DeckCore` (Package.swift's own
        // dependency rule) — `HookResponse.answered`, the function that
        // actually renders this onto the wire, lives one layer up in
        // `DeckAdapters`, and `QuestionWireTests` (DeckAppTests) already
        // proves ITS rendering, end to end, for a hand-synthesised preview
        // payload. What belongs to DeckCore, and what this pins, is the
        // value `answered(_:_:)` is HANDED: `call.rawQuestions` must still
        // be the recording's own value — unmodified by ingest or by the
        // reducer's own `QuestionCall` composition — all the way to the
        // boundary where the adapter takes over and echoes it verbatim.
        // `JSONValue`'s `.object` case is a Swift `Dictionary`, so `==`
        // here is already a value comparison, not a byte one: exactly the
        // "value-verbatim, not byte-verbatim" distinction `WritePlan
        // .render`'s own doc comment draws.
        #expect(call.rawQuestions == recorded,
                "rawQuestions drifted from the recorded tool_input.questions somewhere between ingest and the hold")
    }

    // ------------------------------------------------------- e. plan-mode call

    @Test("the plan-mode payload is shaped the way ingest expects a payload to be, its three questions decode, previews sit on exactly the two options under 'Preview stage', multiSelect is false throughout, and permission_mode reads the transcript's own 'plan'")
    func planModePayloadDecodesMixedPreviews() throws {
        let payload = Corpus.planModeQuestionPayload

        // This payload is assembled from a transcript rather than
        // wire-recorded (Corpus.planModeQuestionPayload's own doc
        // comment), so nothing guarantees it is shaped the way
        // HookIngest.event(from:epochBase:) expects a payload to be —
        // asserted directly rather than only assumed.
        #expect(payload["session_id"]?.stringValue?.isEmpty == false)
        #expect(payload["hook_event_name"]?.stringValue == "PreToolUse")
        #expect(payload["tool_name"]?.stringValue == "AskUserQuestion")
        #expect(payload["permission_mode"]?.stringValue == "plan",
                "the transcript's bracketing entries all read plan — an earlier draft of this fixture had bypassPermissions here, wrongly")

        let questions = try #require(QuestionReader.questions(from: payload["tool_input"]),
                                     "the plan-mode payload failed the all-or-nothing question decode")

        #expect(questions.count == 3)
        #expect(questions.allSatisfy { !$0.multiSelect }, "multiSelect was true somewhere it never recorded true")

        let previewed = questions.flatMap { question in
            question.options.filter { $0.preview != nil }.map { (header: question.header.value, option: $0) }
        }
        #expect(previewed.count == 2,
                "expected exactly 2 options with a preview across all 3 questions, found \(previewed.count)")
        #expect(previewed.allSatisfy { $0.header == "Preview stage" },
                "a preview turned up outside the 'Preview stage' question")
    }
}
