//
//  QuestionMirrorTests.swift · Tests/DeckCoreTests
//
//  The question-mirror arc's own core delivery: `PostToolUse` ingest, the
//  `.answeredElsewhere` retirement, the mirror lifecycle state machine, and
//  the bookkeeping fix — golden tests against the LV38 corpus wherever
//  feasible, per the arc's own instruction to trust recorded bytes over
//  prose. See `Fixtures/live/LV38-question-mirror-PROVENANCE.md` for how
//  these were recorded.
//

import Testing
import DeckCore

struct QuestionMirrorTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// **The LV38 recorder's own known gap, worked around honestly rather
    /// than silently.** Its wrapper carries `{ts, event, tool, workspace,
    /// surface, payload}` — the same shape every other `live/*` fixture
    /// uses — but never a `held_ms`, unlike the hook-server's own live
    /// stamping (`Corpus.liveRun()`'s doc comment) or the LV37 preview
    /// observer's after-the-fact reconstruction. `opensAHold` (`DeckState
    /// .apply(_:HookEvent)`) gates on exactly that field being present and
    /// positive, so replaying these rows through `HookIngest` alone opens
    /// no hold at all — not because no hold was opened (the PROVENANCE
    /// doc's own recording notes describe an artificial hold, and for
    /// several of these sessions the REAL global deck held it too), only
    /// because THIS recorder never wrote the one field that says so. This
    /// re-stamps `held` on the fixture's own `PreToolUse` row — every
    /// other field, including every one of these tests actually cares
    /// about (`tool_use_id`, the questions, the answers, the timestamps),
    /// stays exactly what was recorded.
    private func holdOpened(_ events: [HookEvent]) -> [HookEvent] {
        events.map { event in
            guard event.kind == .preToolUse else { return event }
            return HookEvent(id: event.id, at: event.at, kind: event.kind, session: event.session,
                             cwd: event.cwd, transcriptPath: event.transcriptPath, tool: event.tool,
                             toolUseID: event.toolUseID, held: .value(120_000), subject: event.subject,
                             questions: event.questions, questionsUnreadable: event.questionsUnreadable,
                             rawQuestions: event.rawQuestions, answers: event.answers,
                             permissionSuggestions: event.permissionSuggestions, prompt: event.prompt,
                             title: event.title, permissionMode: event.permissionMode, host: event.host,
                             notificationType: event.notificationType)
        }
    }

    // ------------------------------------------------------------ AnswerReader

    /// The single-select shape, and the multi-select shape it is NOT: the
    /// race fixture's own answer is a bare string even though it happens to
    /// read like a sentence, and the reader must not go looking for a comma
    /// in it just because one exists in other fixtures.
    @Test("a single-select PostToolUse answer decodes to one label")
    func singleSelectAnswerDecodes() {
        let events = Corpus.questionMirrorRace()
        let post = events.first { $0.kind == .postToolUse }
        #expect(post?.answers == [Answer(question: Redacted("Race"),
                                         labels: [Redacted("Skip this question")])])
    }

    /// The corpus's own proof that a multi-select answer with exactly ONE
    /// box checked is still a bare string, not a one-element array — the
    /// shape stays uniform with single-select regardless of how many boxes
    /// happen to be checked.
    @Test("a multi-select PostToolUse answer with one pick decodes to one label")
    func multiSelectOnePickDecodes() {
        let events = Corpus.questionMirrorMultiSelectOnePick()
        let post = events.first { $0.kind == .postToolUse }
        #expect(post?.answers == [Answer(question: Redacted("Which?"),
                                         labels: [Redacted("Option C")])])
    }

    /// **The corpus's own falsifier for `HookResponse.answered`'s doc
    /// comment.** That comment describes the DECK's own outbound shape —
    /// an array of labels. The terminal's real answer, recorded here, is a
    /// single comma-joined STRING. A reader expecting an array would read
    /// this as one garbled label; `AnswerReader` must split it into two.
    @Test("a multi-select PostToolUse answer with two picks splits on the recorded comma-join, never an array")
    func multiSelectTwoPicksSplits() {
        let events = Corpus.questionMirrorMultiSelectTwoPicks()
        let post = events.first { $0.kind == .postToolUse }
        #expect(post?.answers == [Answer(question: Redacted("Pick"),
                                         labels: [Redacted("Option A"), Redacted("Option B")])])
    }

    /// The "Other" flow: typed free text becomes the answer value directly,
    /// verbatim, even though it names neither of the question's own two
    /// options ("Yes"/"No") — proving the reader trusts the wire's answer
    /// over the question's own option list.
    @Test("a typed \"Other\" answer decodes verbatim, not matched against the question's own options")
    func otherFreetextDecodesVerbatim() {
        let events = Corpus.questionMirrorOtherFreetext()
        let post = events.first { $0.kind == .postToolUse }
        #expect(post?.answers == [Answer(question: Redacted("Other"),
                                         labels: [Redacted("Hello free text answer")])])
    }

    /// **Synthetic, because no recorded fixture happens to contain a
    /// single-select label with a literal `", "` inside it.** The split
    /// decision must come from the question's own `multiSelect` flag, never
    /// from the answer string's own shape — this is the case that would
    /// silently fail if it were guessed from the string instead.
    @Test("a single-select answer containing the literal split token is never torn into two labels")
    func singleSelectValueContainingCommaIsNotSplit() {
        let input = JSONValue.object([
            "answers": .object(["Pick": .string("Salt, then pepper")]),
            "questions": .array([.object([
                "question": .string("Pick"), "header": .string("H"),
                "multiSelect": .bool(false),
                "options": .array([.object(["label": .string("Salt, then pepper")])]),
            ])]),
        ])
        // `AnswerReader` is internal to DeckCore; exercised here through
        // the SAME public door `HookIngest.event` uses, so this is not a
        // second, untested path to the same guard.
        let row = JSONValue.object([
            "ts": .string("2026-08-11T00:00:00.000Z"),
            "event": .string("PostToolUse"),
            "payload": .object([
                "hook_event_name": .string("PostToolUse"),
                "session_id": .string("s"), "tool_name": .string("AskUserQuestion"),
                "tool_use_id": .string("t1"), "tool_response": input,
            ]),
        ])
        let event = HookIngest.event(from: row, epochBase: 0)
        #expect(event?.answers == [Answer(question: Redacted("Pick"),
                                          labels: [Redacted("Salt, then pepper")])])
    }

    // ------------------------------------------------------- defect #1: the inert hold

    /// **RED verified by temporary reversion, GREEN is what ships.** Before
    /// this arc's `.postToolUse` handling existed, feeding this exact
    /// stream through the reducer left `state.holds[id]` open forever —
    /// `PostToolUse` carried the chosen answer and the reducer read none of
    /// it. This is the golden shape: the
    /// race fixture's own session `4aaca1c7-…`, fed with no synthetic
    /// `.holdExpired` in the stream, so the hold `PreToolUse` opened is
    /// still genuinely open when `PostToolUse` arrives — the reducer-only
    /// replay's own natural way of putting a hold in exactly the state the
    /// bug report described.
    @Test("PostToolUse retires a still-open question hold immediately, as answeredElsewhere")
    func postToolUseRetiresAnOpenQuestionHold() {
        let events = holdOpened(Corpus.questionMirrorRace())
        let hold = HoldID(session: SessionID("4aaca1c7-54d5-4a8e-af60-c3ac8e5980b2"),
                          toolUseID: "toolu_01Nh7d2VBxLoAUt9JkWGiBHY")

        // Feed only through PreToolUse first — the hold must be open, or
        // this test is not exercising what it claims to.
        let preOnly = events.prefix { $0.kind != .postToolUse }
        let opened = Reducer.run(preOnly.map(DeckEvent.hook))
        #expect(opened.holds[hold]?.isOpen == true,
                "the fixture's own premise: the hold must still be open before PostToolUse arrives")

        let (state, effects) = Reducer.effects(events.map(DeckEvent.hook))
        #expect(state.holds[hold]?.outcome == .answeredElsewhere)
        #expect(state.holds[hold]?.isOpen == false)

        let resolved = effects.compactMap(\.resolution)
        #expect(resolved.contains { $0.0 == hold && $0.1 == .answeredElsewhere })
        let carried = effects.compactMap { effect -> [Answer]? in
            if case .updatedInput(let id, let answers) = effect, id == hold { return answers }
            return nil
        }
        #expect(carried.first == [Answer(question: Redacted("Race"),
                                         labels: [Redacted("Skip this question")])])
    }

    /// The exactly-once rule holding, not a second write: replaying the
    /// SAME `PostToolUse` twice must not attempt a second resolution.
    @Test("a repeated PostToolUse for an already-retired hold is inert, not a crash")
    func repeatedPostToolUseIsInert() {
        let events = holdOpened(Corpus.questionMirrorRace()).map(DeckEvent.hook)
        var state = Reducer.run(events)
        let hold = HoldID(session: SessionID("4aaca1c7-54d5-4a8e-af60-c3ac8e5980b2"),
                          toolUseID: "toolu_01Nh7d2VBxLoAUt9JkWGiBHY")
        #expect(state.holds[hold]?.outcome == .answeredElsewhere)

        let original = events.last { if case .hook(let h) = $0 { return h.kind == .postToolUse }; return false }!
        let effects = Reducer.reduce(&state, original)
        #expect(effects.isEmpty, "a second PostToolUse for the same call produced a second effect")
        #expect(state.holds[hold]?.outcome == .answeredElsewhere, "the first resolution was overwritten")

        // **A relay retry, not a byte-identical replay — a different `at`,
        // the shape `rememberTranscript`'s own `at`-keyed dedup (`DeckState
        // .rememberTranscript`) would NOT catch on its own.** This is what
        // isolates the mirror-stage guard THIS arc adds: without it, a
        // retried `PostToolUse` arriving with its own fresh receipt
        // timestamp would still pass every other guard (`existingHold
        // .outcome != .updatedInput` stays true across any number of
        // retries) and double the ledger row.
        guard case .hook(let h) = original else { fatalError("fixture's own premise") }
        let retried = DeckEvent.hook(HookEvent(id: EventID("retry-\(h.id.raw)"), at: at(999_999),
                                               kind: h.kind, session: h.session, cwd: h.cwd,
                                               tool: h.tool, toolUseID: h.toolUseID, held: h.held,
                                               questions: h.questions, answers: h.answers))
        _ = Reducer.reduce(&state, retried)
        let rows = state.lanes[hold.session]?.transcript.filter { $0.origin == .answeredQuestion } ?? []
        #expect(rows.count == 1, "a retried PostToolUse with a fresh timestamp doubled the ledger row (\(rows.count) rows)")
    }

    /// `.answeredElsewhere` is exempt from the arm-delay guard the same way
    /// `.release`/`.expire` are — it is a fact arriving from the terminal,
    /// not a tap on this hold's own not-yet-settled takeover. The LV38
    /// race fixture itself measured a second keystroke landing well inside
    /// a single arm delay of the first, so this is not a theoretical
    /// window: `HoldPolicy.spec.armDelay` is 250ms, and this answers at 10.
    @Test("PostToolUse retires a hold even inside the arm delay")
    func answeredElsewhereIgnoresArmDelay() {
        var state = DeckState()
        let hold = openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
        #expect(at(10).sinceStart.raw < HoldPolicy.spec.armDelay.raw,
                "the fixture's own premise: 10ms is inside the arm delay")

        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        let effects = Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("post"), at: at(10), kind: .postToolUse, session: SessionID("s"), cwd: nil,
            tool: SubjectReader.questionTool, toolUseID: "t1", held: .absent, questions: [question],
            answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))

        #expect(state.holds[hold]?.outcome == .answeredElsewhere,
                "an answer arriving from the terminal was refused as if it were a mis-aimed tap")
        #expect(effects.contains { $0.resolves(hold) })
    }

    // ------------------------------------------------ defect #2: the bookkeeping fix

    /// **Golden, against the terminal-answered fixture.** The full chain:
    /// the hold resolves, the mirror resolves with the chosen labels, and
    /// a ledger row lands in the transcript well — none of which happened
    /// before this arc for a call answered at the terminal.
    @Test("a terminal answer resolves the hold, the mirror, and earns a ledger row")
    func terminalAnswerClosesTheWholeLoop() {
        let events = holdOpened(Corpus.questionMirrorTerminalAnswered()).map(DeckEvent.hook)
        let state = Reducer.run(events)
        let session = SessionID("eb096a00-78bb-49be-8c5b-f9197a4088af")
        let hold = HoldID(session: session, toolUseID: "toolu_01DVUy1j3pMco66jo7Lyc5mk")

        #expect(state.holds[hold]?.outcome == .answeredElsewhere)

        let expected = [Answer(question: Redacted("Pick"), labels: [Redacted("Option A")])]
        if case .resolved(let answers, let origin, _)? = state.mirrors[hold]?.stage {
            #expect(answers == expected)
            #expect(origin == .terminal, "a terminal answer resolved with the wrong origin")
        } else {
            Issue.record("mirror did not reach .resolved — stage is \(String(describing: state.mirrors[hold]?.stage))")
        }

        let ledgerRow = state.lanes[session]?.transcript.last { $0.origin == .answeredQuestion }
        #expect(ledgerRow != nil, "no ledger row for the answered question")
        #expect(ledgerRow?.text.value == "Pick: Option A")
    }

    /// **The class fix, isolated from the retirement path.** `.holdExpired`
    /// used to produce a diagnostic with NO outcome at all, regardless of
    /// whether the resolved hold was a question or an ordinary permission —
    /// the class this fixes is every hold that falls through, not only
    /// question ones.
    @Test("a naturally expired hold's diagnostic now carries its own resolved outcome")
    func holdExpiredDiagnosticCarriesItsOutcome() {
        let hold = HoldID(session: SessionID("s"), toolUseID: "t1")
        var state = DeckState()
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("h"), at: .start, kind: .preToolUse,
                                               session: hold.session, cwd: nil, tool: "Bash",
                                               toolUseID: hold.toolUseID, held: .value(1))))
        let effects = Reducer.reduce(&state, .holdExpired(hold, at: at(120_001)))
        let diagnostic = DiagnosticExport.record(.holdExpired(hold, at: at(120_001)), effects: effects)
        #expect(diagnostic?.outcome == .release,
                "holdExpired's own diagnostic carries no outcome — the exact bookkeeping gap this arc fixes")
        #expect(diagnostic?.line.contains("outcome=release") == true)
    }

    /// The SAME class fix, for a deck-side dismissal — `.questionAbandoned`
    /// used to sit in the diagnostic export's no-op bucket entirely.
    @Test("an abandoned question's diagnostic also carries its resolved outcome")
    func questionAbandonedDiagnosticCarriesItsOutcome() {
        let hold = HoldID(session: SessionID("s"), toolUseID: "t1")
        var state = DeckState()
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("h"), at: .start, kind: .preToolUse,
                                               session: hold.session, cwd: nil,
                                               tool: SubjectReader.questionTool,
                                               toolUseID: hold.toolUseID, held: .value(1),
                                               questions: [Question(text: Redacted("Q"), header: Redacted(""),
                                                                    options: [QuestionOption(label: Redacted("A"),
                                                                                             detail: Redacted(""))],
                                                                    multiSelect: false)])))
        let effects = Reducer.reduce(&state, .questionAbandoned(hold, at: at(1_000)))
        let diagnostic = DiagnosticExport.record(.questionAbandoned(hold, at: at(1_000)), effects: effects)
        #expect(diagnostic?.outcome == .release)
        #expect(diagnostic?.kind == .holdResolved)
    }

    /// A `PostToolUse` retirement earns its own diagnostic line too — the
    /// generic effects-based read covers this arc's own new path for free,
    /// with no case written specifically for `.answeredElsewhere`.
    @Test("a PostToolUse retirement's diagnostic carries answeredElsewhere")
    func postToolUseRetirementDiagnosticCarriesItsOutcome() {
        var state = DeckState()
        let events = holdOpened(Corpus.questionMirrorRace()).map(DeckEvent.hook)
        // `PostToolUse` is mid-stream here, not the last row (`Stop`,
        // `Notification` and `SessionEnd` all follow it in this fixture) —
        // found by kind rather than assumed to be the tail.
        guard let postIndex = events.firstIndex(where: {
            if case .hook(let h) = $0 { return h.kind == .postToolUse }; return false
        }) else { Issue.record("fixture carries no PostToolUse row"); return }
        for event in events[..<postIndex] { Reducer.reduce(&state, event) }
        let post = events[postIndex]
        let effects = Reducer.reduce(&state, post)
        let diagnostic = DiagnosticExport.record(post, effects: effects)
        #expect(diagnostic?.outcome == .answeredElsewhere)
    }

    // ---------------------------------------------------------- mirror lifecycle

    private func openQuestionMirror(_ state: inout DeckState, session: SessionID, use: String,
                                    at: Instant) -> HoldID {
        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("open-\(use)"), at: at, kind: .preToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: use,
                                               held: .value(1), questions: [question])))
        return HoldID(session: session, toolUseID: use)
    }

    /// **The fourth way `.resolved` is reached — `answers: nil`, "the
    /// session moved on".** A mirror left `.released` with nobody ever
    /// answering must not claim "live in the terminal" forever once the
    /// terminal itself is gone.
    @Test("a session ending resolves any mirror still released or terminalLive, with no answers")
    func sessionEndResolvesAStrandedMirror() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.mirrors[hold]?.stage.releasedAt != nil)

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("end"), at: at(60_000), kind: .sessionEnd,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent)))
        #expect(state.mirrors[hold]?.stage == .resolved(answers: nil, origin: .movedOn, at: at(60_000)))
    }

    /// A mirror already `.resolved` — the deck answered it, or the
    /// terminal did — is left exactly as it is when the session ends;
    /// `SessionEnd` never overwrites a real answer with "nothing chosen".
    @Test("a session ending does not overwrite an already-resolved mirror")
    func sessionEndDoesNotOverwriteAResolvedMirror() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        let answers = [Answer(question: Redacted("Q"), labels: [Redacted("A")])]
        Reducer.reduce(&state, .questionSubmitted(hold, answers: answers, at: at(1_000)))

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("end"), at: at(60_000), kind: .sessionEnd,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent)))
        #expect(state.mirrors[hold]?.stage == .resolved(answers: answers, origin: .deck, at: at(1_000)),
                "SessionEnd overwrote a real answer")
    }

    @Test("a question hold opens its mirror in deckWindow")
    func mirrorOpensInDeckWindow() {
        var state = DeckState()
        let hold = openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
        #expect(state.mirrors[hold]?.stage == .deckWindow)
    }

    @Test("a fallen-through hold releases its mirror; a deck answer resolves it directly")
    func releaseAndDeckAnswerTakeDifferentPaths() {
        var released = DeckState()
        let releasedHold = openQuestionMirror(&released, session: SessionID("s"), use: "t1", at: .start)
        Reducer.reduce(&released, .holdExpired(releasedHold, at: at(8_000)))
        #expect(released.mirrors[releasedHold]?.stage.releasedAt != nil,
                "a naturally expired question hold did not release its mirror")

        var answered = DeckState()
        let answeredHold = openQuestionMirror(&answered, session: SessionID("s2"), use: "t1", at: .start)
        Reducer.reduce(&answered, .questionSubmitted(answeredHold,
                                                      answers: [Answer(question: Redacted("Q"),
                                                                       labels: [Redacted("A")])],
                                                      at: at(1_000)))
        if case .resolved? = answered.mirrors[answeredHold]?.stage {} else {
            Issue.record("a deck answer did not resolve its mirror directly")
        }
    }

    /// **The readiness gate, both halves, in order.** `PermissionRequest`
    /// (no `tool_use_id` on the wire — the correlation this proves is
    /// session-scoped) records the first half; `Notification` promotes.
    @Test("released, then PermissionRequest, then Notification reaches terminalLive")
    func readinessGateBothHalvesPromoteToTerminalLive() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.mirrors[hold]?.stage.releasedAt != nil)

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pr"), at: at(28_000), kind: .permissionRequest,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: nil,
                                               held: .absent)))
        #expect(state.mirrors[hold]?.permissionRequestSeenAt == at(28_000))
        if case .terminalLive = state.mirrors[hold]?.stage {
            Issue.record("PermissionRequest alone promoted to terminalLive — Notification is the second half")
        }

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("nt"), at: at(34_000), kind: .notification,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent, notificationType: "permission_prompt")))
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(34_000)))
    }

    /// **The bypass the LV38 multiselect-two-picks fixture proved is real:**
    /// a `PostToolUse` arriving before any `Notification` — sometimes before
    /// even a `PermissionRequest` — still resolves the mirror directly.
    /// `terminalLive` is not a mandatory waypoint to `resolved`.
    @Test("PostToolUse resolves a mirror directly from released, without ever passing through terminalLive")
    func releasedMirrorResolvesDirectlyWithoutTerminalLive() {
        var state = DeckState()
        let session = SessionID("s")
        let use = "t1"
        let hold = openQuestionMirror(&state, session: session, use: use, at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.mirrors[hold]?.stage.releasedAt != nil)

        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(9_000), kind: .postToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: use,
                                               held: .absent, questions: [question],
                                               answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))
        if case .resolved(let answers, _, _)? = state.mirrors[hold]?.stage {
            #expect(answers == [Answer(question: Redacted("Q"), labels: [Redacted("A")])])
        } else {
            Issue.record("PostToolUse did not resolve a released mirror directly")
        }
    }

    /// **The correlation's own stated bound.** Two sessions, both with a
    /// released mirror waiting — a `PermissionRequest` for one session must
    /// never touch the other's mirror. The one thing this correlation
    /// cannot get wrong, proven directly.
    @Test("PermissionRequest never binds across sessions")
    func permissionRequestNeverBindsAcrossSessions() {
        var state = DeckState()
        let holdA = openQuestionMirror(&state, session: SessionID("a"), use: "t1", at: .start)
        let holdB = openQuestionMirror(&state, session: SessionID("b"), use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(holdA, at: at(8_000)))
        Reducer.reduce(&state, .holdExpired(holdB, at: at(8_000)))

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pr"), at: at(20_000), kind: .permissionRequest,
                                               session: SessionID("a"), cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: nil,
                                               held: .absent)))
        #expect(state.mirrors[holdA]?.permissionRequestSeenAt == at(20_000))
        #expect(state.mirrors[holdB]?.permissionRequestSeenAt == nil,
                "a PermissionRequest for session a marked session b's mirror as seen too")
    }

    /// A mirror is swept the instant its own hold is — `sweepHolds`'s own
    /// amortised threshold, exercised directly rather than through a
    /// thousand-event stream.
    @Test("a mirror is forgotten the same sweep that forgets its hold")
    func mirrorSweptAlongsideItsHold() {
        var state = DeckState()
        // Ten seconds apart, not two: `HoldPolicy.memory` is 20 minutes, and
        // the sweep only reclaims a hold OLD enough to fall outside it — at
        // two-second spacing 300 holds span ten minutes, never ages out,
        // and the sweep's own threshold-raise (`sweepHolds`'s doc comment)
        // just backs off forever with nothing to reclaim, the identical
        // trap `PerformanceTests`'s own header warns a short-spaced fixture
        // falls into. At ten seconds, 300 holds span fifty minutes —
        // comfortably past the window more than once.
        for i in 0 ..< 300 {
            let hold = openQuestionMirror(&state, session: SessionID("s\(i)"), use: "t1",
                                          at: at(Int64(i) * 10_000))
            Reducer.reduce(&state, .holdExpired(hold, at: at(Int64(i) * 10_000 + 8_000)))
        }
        #expect(state.holds.count == state.mirrors.count,
                "holds and mirrors drifted apart after a sweep")
        #expect(state.holds.count < 300, "the sweep never fired")
    }

    // --------------------------------------------------------------- describeAnswers

    @Test("the ledger line joins question and chosen labels, one line per question")
    func describeAnswersFormatsOneLinePerQuestion() {
        let events = holdOpened(Corpus.questionMirrorMultiSelectTwoPicks()).map(DeckEvent.hook)
        let state = Reducer.run(events)
        let session = SessionID("10c3951c-c9fb-4e2b-a9ab-d5dabfbc73bd")
        let row = state.lanes[session]?.transcript.last { $0.origin == .answeredQuestion }
        #expect(row?.text.value == "Pick: Option A, Option B")
    }

    /// A deck answer and a terminal answer never both earn a ledger row for
    /// the SAME call — `PostToolUse` echoing a deck-authored answer back
    /// must not double the line `.questionSubmitted` already wrote.
    @Test("a deck-answered call's own echoed PostToolUse does not double the ledger row")
    func deckAnsweredCallIsNotDoubleLedgered() {
        var state = DeckState()
        let session = SessionID("s")
        let use = "t1"
        let hold = openQuestionMirror(&state, session: session, use: use, at: .start)
        let answers = [Answer(question: Redacted("Q"), labels: [Redacted("A")])]
        Reducer.reduce(&state, .questionSubmitted(hold, answers: answers, at: at(1_000)))

        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(1_100), kind: .postToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: use,
                                               held: .absent, questions: [question], answers: answers)))

        let rows = state.lanes[session]?.transcript.filter { $0.origin == .answeredQuestion } ?? []
        #expect(rows.count == 1, "the deck's own answer earned \(rows.count) ledger rows instead of one")
    }

    // ------------------------------------------------------- the projection surface

    /// **`.deckWindow` never reaches `Frame.mirrors`.** That stage's own
    /// hold is still `isActionable`, so it is already showing through
    /// `Frame.decisions`, through the pre-existing takeover this arc leaves
    /// untouched — carrying it here too would be a second, competing
    /// surface for the SAME hold.
    @Test("a deckWindow mirror is absent from Frame.mirrors; its hold is in decisions instead")
    func deckWindowMirrorStaysOutOfTheProjection() {
        var state = DeckState()
        let hold = openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
        let frame = Projection.frame(from: state, at: at(1_000))
        #expect(frame.mirrors.isEmpty, "a deckWindow mirror leaked into Frame.mirrors")
        #expect(frame.decisions.contains { $0.hold == hold },
                "the SAME hold is missing from decisions — nothing renders it at all")
    }

    /// **`released`, projected.** The one stage the whole arc's own UI
    /// requirement turns on: a hold that stopped being actionable, and a
    /// question that must still be on screen because of it.
    @Test("a released mirror reaches Frame.mirrors with its question intact")
    func releasedMirrorReachesTheProjection() {
        var state = DeckState()
        let hold = openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.holds[hold]?.isActionable == false,
                "the fixture's own premise: decisions must have nothing left to show for this hold")

        let frame = Projection.frame(from: state, at: at(9_000))
        #expect(!frame.decisions.contains { $0.hold == hold },
                "a released hold is still in decisions — the mirror and the takeover would double-render")
        let mirror = frame.mirrors.first { $0.hold == hold }
        #expect(mirror != nil, "a released mirror never reached the frame at all")
        #expect(mirror?.stage == .released(at: at(8_000)))
        #expect(mirror?.question?.text.value == "Q")
    }

    /// **`resolved`, with the chosen answers riding along.**
    @Test("a resolved mirror carries its chosen answers into the projection")
    func resolvedMirrorCarriesAnswers() {
        var state = DeckState()
        let hold = openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
        let answers = [Answer(question: Redacted("Q"), labels: [Redacted("A")])]
        Reducer.reduce(&state, .questionSubmitted(hold, answers: answers, at: at(1_000)))

        let frame = Projection.frame(from: state, at: at(2_000))
        let mirror = frame.mirrors.first { $0.hold == hold }
        guard case .resolved(let carried, let origin, _)? = mirror?.stage else {
            Issue.record("resolved mirror missing or wrong stage: \(String(describing: mirror?.stage))")
            return
        }
        #expect(carried == answers)
        #expect(origin == .deck)
    }

    /// **Determinism.** Two mirrors released out of insertion order project
    /// oldest-stage-first, every time — the same "stable order across
    /// frames" `decisions`' own front-first sort exists for, so a `ForEach`
    /// never reorders a card out from under a finger mid-tap.
    @Test("mirrors project oldest-released-first, regardless of dictionary order")
    func mirrorsProjectInAStableOrder() {
        var state = DeckState()
        let later = openQuestionMirror(&state, session: SessionID("a"), use: "t1", at: .start)
        let earlier = openQuestionMirror(&state, session: SessionID("b"), use: "t1", at: at(1))
        Reducer.reduce(&state, .holdExpired(later, at: at(9_000)))
        Reducer.reduce(&state, .holdExpired(earlier, at: at(8_000)))

        let frame = Projection.frame(from: state, at: at(10_000))
        let order = frame.mirrors.map(\.hold)
        #expect(order == [earlier, later],
                Comment(rawValue: "expected earlier-released first, got \(order)"))
    }

    /// **The equality guard's own investigation, one field over.**
    /// `PerformanceTests.frameEqualityIgnoresTheProjectionInstant` proved
    /// `Frame`'s hand-written `==` survives a sub-threshold time gap for
    /// `decisions`; this is the same proof for `mirrors`, which reaches the
    /// SAME hand-written `==` through a field that did not exist when that
    /// conformance was written and could have been forgotten.
    @Test("two frames a millisecond apart, same state, compare equal with a mirror present")
    func frameEqualityCoversMirrorsToo() {
        var state = DeckState()
        let hold = openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))

        let a = Projection.frame(from: state, at: at(20_000))
        let b = Projection.frame(from: state, at: at(20_001))
        #expect(a.at != b.at, "the fixture's own premise: the instants must differ")
        #expect(!a.mirrors.isEmpty, "the fixture's own premise: nothing is being compared")
        #expect(a == b, "two frames one millisecond apart, from IDENTICAL state, compared unequal")
    }

    // ---------------------------------------------------------- ForwardPlanBuilder

    private func singleSelect(_ labels: String...) -> Question {
        Question(text: Redacted("Q"), header: Redacted(""),
                 options: labels.map { QuestionOption(label: Redacted($0), detail: Redacted("")) },
                 multiSelect: false)
    }

    private func multiSelect(_ labels: String...) -> Question {
        Question(text: Redacted("Q"), header: Redacted(""),
                 options: labels.map { QuestionOption(label: Redacted($0), detail: Redacted("")) },
                 multiSelect: true)
    }

    @Test("single-select builds one digit, matching the recorded race/held-released grammar")
    func singleSelectPlanIsOneDigit() {
        let question = singleSelect("Skip this question", "Provide details myself")
        let steps = ForwardPlanBuilder.build(for: question, picking: [Redacted("Skip this question")])
        #expect(steps == [.bytes("1")])

        let second = ForwardPlanBuilder.build(for: question, picking: [Redacted("Provide details myself")])
        #expect(second == [.bytes("2")])
    }

    @Test("single-select refuses a label the question never offered")
    func singleSelectRefusesAnUnknownLabel() {
        let question = singleSelect("Yes", "No")
        #expect(ForwardPlanBuilder.build(for: question, picking: [Redacted("Maybe")]) == nil)
    }

    @Test("single-select refuses more than one pick")
    func singleSelectRefusesMultiplePicks() {
        let question = singleSelect("Yes", "No")
        #expect(ForwardPlanBuilder.build(for: question,
                                         picking: [Redacted("Yes"), Redacted("No")]) == nil)
    }

    /// **The arithmetic, checked directly against the LV38 corpus's own
    /// row order.** `multiselect-one-pick.ndjson`: 3 options (A/B/C). One
    /// pick at option 3 (the LAST one) — 0 remaining options, so the only
    /// rows left between it and Submit are "Type something" then "Submit"
    /// itself: 2 downs.
    @Test("multi-select toggles the picked digit(s), then downs to Submit, enter, review-digit-1")
    func multiSelectPlanMatchesTheRecordedRowOrder() {
        let question = multiSelect("Option A", "Option B", "Option C")
        let steps = ForwardPlanBuilder.build(for: question, picking: [Redacted("Option C")])
        #expect(steps == [.bytes("3"), .key("down"), .key("down"), .key("enter"), .bytes("1")],
                Comment(rawValue: "got \(String(describing: steps))"))
    }

    /// The SAME shape, a pick that is NOT the last option — more downs,
    /// computed the same way: option 1 of 3 picked, 2 options remain below
    /// it PLUS "Type something" PLUS "Submit" = 4 downs.
    @Test("multi-select's down count grows the further the last pick is from the end")
    func multiSelectDownCountTracksDistanceFromTheLastPick() {
        let question = multiSelect("Option A", "Option B", "Option C")
        let steps = ForwardPlanBuilder.build(for: question, picking: [Redacted("Option A")])
        #expect(steps == [.bytes("1"), .key("down"), .key("down"), .key("down"), .key("down"),
                          .key("enter"), .bytes("1")],
                Comment(rawValue: "got \(String(describing: steps))"))
    }

    /// **Two picks — the golden shape, against `multiselect-two-picks
    /// .ndjson` directly: `{"Pick": "Option A, Option B"}`.** Both digits
    /// toggle, in ascending order regardless of the CALLER's own order —
    /// the down count anchors on the highest index touched (Option B, index
    /// 1 of 2): `(optionCount + 1) - lastIndex` = `(2 + 1) - 1` = 2, the
    /// "Type something" row then "Submit" itself.
    @Test("multi-select toggles both picks in ascending order, regardless of caller order")
    func multiSelectTogglesInAscendingOrderRegardlessOfCallerOrder() {
        let question = multiSelect("Option A", "Option B")
        let forward = ForwardPlanBuilder.build(for: question,
                                               picking: [Redacted("Option A"), Redacted("Option B")])
        let reversed = ForwardPlanBuilder.build(for: question,
                                                picking: [Redacted("Option B"), Redacted("Option A")])
        #expect(forward == reversed, "the same set built two different plans depending on caller order")
        #expect(forward == [.bytes("1"), .bytes("2"), .key("down"), .key("down"), .key("enter"), .bytes("1")],
                Comment(rawValue: "got \(String(describing: forward))"))
    }

    @Test("multi-select refuses an empty pick set")
    func multiSelectRefusesEmptyPicks() {
        let question = multiSelect("A", "B")
        #expect(ForwardPlanBuilder.build(for: question, picking: []) == nil)
    }

    /// **Other, against `other-freetext.ndjson` directly.** The option's
    /// own digit (here, `3` — two declared options, "Other" is the row
    /// after them) FOCUSES, never submits on its own; the typed text
    /// follows as bytes; enter submits.
    @Test("Other focuses with its own digit, types the text, then enters — never bare")
    func otherPlanFocusesTypesAndEnters() {
        let question = singleSelect("Yes", "No")
        let steps = ForwardPlanBuilder.build(for: question, picking: [],
                                             otherText: Redacted("Hello free text answer"))
        #expect(steps == [.bytes("3"), .bytes("Hello free text answer"), .key("enter")])
    }

    /// **The one rule this builder exists to enforce absolutely.** LV38's
    /// own caution: a bare `enter` on the unfocused "Type something" row
    /// submits an EMPTY answer, reported as "User declined to answer
    /// questions" — unrecoverable, and this builder must never construct
    /// the plan shape that could produce it.
    @Test("Other refuses empty or whitespace-only text — never builds a bare-enter plan")
    func otherRefusesEmptyText() {
        let question = singleSelect("Yes", "No")
        #expect(ForwardPlanBuilder.build(for: question, picking: [], otherText: Redacted("")) == nil)
        #expect(ForwardPlanBuilder.build(for: question, picking: [], otherText: Redacted("   ")) == nil)
        #expect(ForwardPlanBuilder.build(for: question, picking: []) == nil,
                "no picks and no Other text at all must not build anything either")
    }

    @Test("a plan's cursor tracks completion without a sentinel")
    func planCursorTracksCompletion() {
        var plan = ForwardPlan(hold: HoldID(session: SessionID("s"), toolUseID: "t1"),
                               steps: [.bytes("1"), .key("enter")])
        #expect(!plan.isComplete)
        #expect(plan.currentStep == .bytes("1"))
        plan.cursor += 1
        #expect(!plan.isComplete)
        #expect(plan.currentStep == .key("enter"))
        plan.cursor += 1
        #expect(plan.isComplete)
        #expect(plan.currentStep == nil)
    }

    // -------------------------------------------------------- forward plan lifecycle

    /// Drives a mirror all the way to `.terminalLive` — the readiness
    /// gate's own two-event pair, the identical sequence
    /// `readinessGateBothHalvesPromoteToTerminalLive` above exercises,
    /// pulled out since every forwarding test needs one to even attempt a
    /// plan against. `base` shifts the whole sequence in time — 0 for an
    /// ordinary test, spread out for a sweep test where many of these need
    /// to age at genuinely different instants rather than all collide on
    /// the same four timestamps.
    private func terminalLiveMirror(_ state: inout DeckState, session: SessionID,
                                    use: String, base: Int64 = 0) -> HoldID {
        let hold = openQuestionMirror(&state, session: session, use: use, at: at(base))
        Reducer.reduce(&state, .holdExpired(hold, at: at(base + 8_000)))
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pr-\(use)"), at: at(base + 20_000),
                                               kind: .permissionRequest,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: nil,
                                               held: .absent)))
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("nt-\(use)"), at: at(base + 26_000),
                                               kind: .notification,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent, notificationType: "permission_prompt")))
        return hold
    }

    @Test("a plan starts only against a terminalLive mirror")
    func planStartsOnlyAgainstTerminalLive() {
        for (label, setup) in [
            ("deckWindow", { (state: inout DeckState) in
                _ = self.openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
            }),
            ("released", { (state: inout DeckState) in
                let hold = self.openQuestionMirror(&state, session: SessionID("s"), use: "t1", at: .start)
                Reducer.reduce(&state, .holdExpired(hold, at: self.at(8_000)))
            }),
        ] {
            var state = DeckState()
            setup(&state)
            let hold = HoldID(session: SessionID("s"), toolUseID: "t1")
            let plan = ForwardPlan(hold: hold, steps: [.bytes("1")])
            Reducer.reduce(&state, .forwardPlanStarted(plan, at: at(1_000)))
            #expect(state.forwarding[hold] == nil,
                    Comment(rawValue: "a plan started against a \(label) mirror"))
        }

        var live = DeckState()
        let hold = terminalLiveMirror(&live, session: SessionID("s2"), use: "t1")
        let plan = ForwardPlan(hold: hold, steps: [.bytes("1")])
        Reducer.reduce(&live, .forwardPlanStarted(plan, at: at(30_000)))
        #expect(live.forwarding[hold] != nil, "a plan against a genuinely terminalLive mirror was refused")
    }

    @Test("a second plan is refused while one is already running")
    func aSecondPlanIsRefusedMidFlight() {
        var state = DeckState()
        let hold = terminalLiveMirror(&state, session: SessionID("s"), use: "t1")
        let first = ForwardPlan(hold: hold, steps: [.bytes("1"), .key("enter")])
        Reducer.reduce(&state, .forwardPlanStarted(first, at: at(30_000)))
        #expect(state.forwarding[hold]?.steps.count == 2)

        let second = ForwardPlan(hold: hold, steps: [.bytes("2")])
        Reducer.reduce(&state, .forwardPlanStarted(second, at: at(30_100)))
        #expect(state.forwarding[hold]?.steps.count == 2,
                "a second plan overwrote the one already running")
    }

    @Test("forwardStepSent advances the cursor and clears the plan on completion")
    func forwardStepSentAdvancesAndCompletes() {
        var state = DeckState()
        let hold = terminalLiveMirror(&state, session: SessionID("s"), use: "t1")
        let plan = ForwardPlan(hold: hold, steps: [.bytes("1"), .key("enter")])
        Reducer.reduce(&state, .forwardPlanStarted(plan, at: at(30_000)))

        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_200)))
        #expect(state.forwarding[hold]?.cursor == 1, "the first step did not advance the cursor")

        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_400)))
        #expect(state.forwarding[hold] == nil, "a completed plan is still occupying state.forwarding")
    }

    @Test("forwardPlanCancelled clears the plan immediately")
    func forwardPlanCancelledClears() {
        var state = DeckState()
        let hold = terminalLiveMirror(&state, session: SessionID("s"), use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("1"), .key("enter")]),
                                                    at: at(30_000)))
        #expect(state.forwarding[hold] != nil)

        Reducer.reduce(&state, .forwardPlanCancelled(hold, at: at(30_050)))
        #expect(state.forwarding[hold] == nil)
    }

    /// **The `cullStaleDialogKeys`-class cancellation, red-green material:
    /// a `PostToolUse` landing mid-plan must abort whatever steps have not
    /// yet run — the LV38 `race` fixture's own hazard (a stray second
    /// keystroke reaching an already-closed dialog), one layer up from a
    /// single digit to a whole scripted plan.**
    @Test("PostToolUse mid-plan cancels every remaining step")
    func postToolUseMidPlanCancelsTheRemainingSteps() {
        var state = DeckState()
        let session = SessionID("s")
        let use = "t1"
        let hold = terminalLiveMirror(&state, session: session, use: use)
        Reducer.reduce(&state, .forwardPlanStarted(
            ForwardPlan(hold: hold, steps: [.bytes("1"), .key("down"), .key("enter"), .bytes("1")]),
            at: at(30_000)))
        #expect(state.forwarding[hold] != nil, "the fixture's own premise: a plan must be running")

        // One step actually sent, matching what a real mid-flight
        // cancellation catches: SOME steps landed, the rest never will.
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_200)))
        #expect(state.forwarding[hold]?.cursor == 1)

        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(30_300), kind: .postToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: use,
                                               held: .absent, questions: [question],
                                               answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))
        #expect(state.forwarding[hold] == nil,
                "a PostToolUse landing mid-plan left the remaining steps still scheduled")
    }

    @Test("a forward plan is swept alongside its own hold")
    func forwardPlanSweptAlongsideItsHold() {
        // 40 seconds apart per iteration's own four-event sequence — the
        // same spacing reasoning `mirrorSweptAlongsideItsHold` above
        // states in full: `HoldPolicy.memory` is 20 minutes, and nothing
        // ages out of a sweep's own reach unless the stream genuinely
        // spans past it. One shared, accumulating state, not one per
        // iteration — a fresh `DeckState` every time is a stream that
        // never grows, which is the same trap that comment warns about.
        var state = DeckState()
        for i in 0 ..< 300 {
            let base = Int64(i) * 40_000
            let hold = terminalLiveMirror(&state, session: SessionID("s\(i)"), use: "t1", base: base)
            Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("1")]),
                                                        at: at(base + 30_000)))
        }
        #expect(state.holds.count == state.mirrors.count)
        #expect(state.holds.count < 300, "the sweep never fired")
        // `forwarding` can never name a hold `holds` has already forgotten
        // — the actual property this test exists to prove, checked
        // directly rather than inferred from the two counts above merely
        // agreeing.
        #expect(state.forwarding.keys.allSatisfy { state.holds[$0] != nil },
                "a forward plan survived the sweep that removed its own hold")
    }

    // ------------------------------------------------- the readiness-gate fix
    //
    // Past defect: a user was blocked at the strip. A real
    // `AskUserQuestion` released, the mirror rendered "Live in the
    // terminal", options grayed, and NEITHER ceremony half ever arrived —
    // the old gate had no other door to `.terminalLive`, so the mirror
    // stayed grayed forever. `DeckRuntime.scheduleReadinessWatch()` is
    // where the CLOCK lives (deliberately outside the reducer, the same
    // `.holdExpired` discipline); these tests drive the reducer directly
    // with the events that clock produces, at hand-picked instants — the
    // red-green protocol's own "time-advance" shape, no real sleep
    // anywhere in this file.

    /// **The red this whole fix answers.** A `.released` mirror with
    /// NEITHER ceremony half ever arriving is exactly the live
    /// shape — before `.mirrorReadinessElapsed` existed, nothing in this
    /// reducer could ever move it, which is what "stayed grayed forever"
    /// meant. `DeckRuntime`'s own two allowances decide WHEN this fires
    /// in production (`HoldPolicy.noSignalAllowance`'s own doc comment);
    /// this test only proves the reducer answers correctly once it does.
    @Test("a released mirror with no ceremony at all still reaches terminalLive")
    func noCeremonyMirrorStillReachesTerminalLive() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.mirrors[hold]?.stage.releasedAt != nil)
        #expect(state.mirrors[hold]?.permissionRequestSeenAt == nil,
                "the fixture's own premise: no PermissionRequest arrived either")

        Reducer.reduce(&state, .mirrorReadinessElapsed(hold, at: at(28_000)))
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(28_000)))
    }

    /// The SAME promotion, reached with only HALF the ceremony seen —
    /// `DeckRuntime`'s own shorter `permissionRequestAllowance` is what
    /// decides to fire it this early in production; the reducer's own
    /// job is identical either way.
    @Test("a released mirror that saw only a PermissionRequest still reaches terminalLive")
    func permissionRequestOnlyMirrorStillReachesTerminalLive() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pr"), at: at(20_000), kind: .permissionRequest,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: nil,
                                               held: .absent)))
        #expect(state.mirrors[hold]?.permissionRequestSeenAt == at(20_000))

        Reducer.reduce(&state, .mirrorReadinessElapsed(hold, at: at(27_000)))
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(27_000)))
    }

    /// **Once-only, the same discipline `Hold.resolve`'s exactly-once
    /// rule holds one layer up.** The ceremony pair winning the race
    /// first must not be walked backward by a timer that was already
    /// racing it and lost — `promoteMirrorIfStillReleased`'s own guard is
    /// what this proves.
    @Test("mirrorReadinessElapsed is a no-op once the ceremony pair already promoted the mirror")
    func readinessElapsedIsANoOpOnceAlreadyTerminalLive() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(26_000)))

        // A timer that was already in flight when the ceremony won —
        // fired late, deliberately, to prove it changes nothing.
        Reducer.reduce(&state, .mirrorReadinessElapsed(hold, at: at(40_000)))
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(26_000)),
                "a late-firing timer overwrote the ceremony pair's own, earlier promotion")
    }

    /// Design point (d) — the screen-read signal, reducer side. Promotes
    /// exactly the same way the timer does; `DeckRuntime
    /// .attemptScreenObservation`'s own doc comment states what makes
    /// THIS signal fire, never the reducer's concern.
    @Test("mirrorObservedLive promotes a released mirror to terminalLive")
    func observedLivePromotesAReleasedMirror() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))

        Reducer.reduce(&state, .mirrorObservedLive(hold, at: at(10_000)))
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(10_000)))
    }

    /// The identical once-only guard, proven for the OTHER promotion
    /// door — a screen read that resolves after the mirror already
    /// answered must not walk `.resolved` back to `.terminalLive`.
    @Test("mirrorObservedLive is a no-op once the mirror has already resolved")
    func observedLiveIsANoOpOnceResolved() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        let answers = [Answer(question: Redacted("Q"), labels: [Redacted("A")])]
        Reducer.reduce(&state, .questionSubmitted(hold, answers: answers, at: at(1_000)))
        guard case .resolved? = state.mirrors[hold]?.stage else {
            Issue.record("the fixture's own premise: the mirror must already be resolved")
            return
        }

        Reducer.reduce(&state, .mirrorObservedLive(hold, at: at(2_000)))
        if case .resolved? = state.mirrors[hold]?.stage {} else {
            Issue.record("a late screen-read observation walked a resolved mirror back to terminalLive")
        }
    }

    // ---------------------------------------------- the forward-recovery fix
    //
    // Renamed `forwardDidNotLand` → `forwardUnconfirmed` (D4): in that incident the tap HAD landed —
    // the user tapped option 2, it reached the terminal, and the deck kept
    // showing plain "Answerable from here" instead of anything that would
    // have stopped the second "2" from also being sent. The deck can
    // confirm a landing but never truly confirm its absence, so the
    // field, the event, and the copy all claim only what is actually
    // known now.

    /// **D5 — the awaiting-confirmation window's own start.** The instant
    /// a plan completes (`forwardStepSent` marking the LAST step),
    /// `forwardSentAt` is set — BEFORE anything has had a chance to
    /// confirm or fail to confirm it. This is the field
    /// `MirrorView.awaitingConfirmation` reads, and closing the literal
    /// double-send window (D5's whole point) starts exactly here.
    @Test("a completed forward plan sets forwardSentAt, the awaiting-confirmation window's own start")
    func completedForwardPlanSetsForwardSentAt() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        #expect(state.mirrors[hold]?.forwardSentAt == nil)

        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        #expect(state.forwarding[hold] == nil,
                "the fixture's own premise: a one-step plan completes on its own first step")
        #expect(state.mirrors[hold]?.forwardSentAt == at(30_100))
    }

    /// A plan mid-flight (more than one step, not yet complete) must NOT
    /// set `forwardSentAt` early — the awaiting-confirmation window opens
    /// at completion, never before; a mid-flight plan already disables
    /// its own options through `mirror.forwarding`.
    @Test("forwardSentAt stays nil while a multi-step plan is still mid-flight")
    func forwardSentAtStaysNilMidFlight() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")

        Reducer.reduce(&state, .forwardPlanStarted(
            ForwardPlan(hold: hold, steps: [.bytes("1"), .key("down"), .key("enter")]), at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        #expect(state.forwarding[hold] != nil, "the fixture's own premise: two steps remain")
        #expect(state.mirrors[hold]?.forwardSentAt == nil,
                "forwardSentAt was set before the plan actually completed")
    }

    /// **What makes the two promotions above safe to be aggressive
    /// about.** A plan that sent every step and then got no confirmation
    /// within the recovery window marks `forwardUnconfirmedAt` — the
    /// surface reads it through `MirrorView.forwardUnconfirmed`.
    /// `forwardSentAt` stays set throughout: the window has not actually
    /// ended, only the CLAIM about it has, and `MirrorView
    /// .awaitingConfirmation`'s own doc comment states why both reading
    /// true at once is deliberate, not a bug.
    @Test("forwardUnconfirmed marks a terminalLive mirror's own forwardUnconfirmedAt, leaving forwardSentAt standing")
    func forwardUnconfirmedMarksTheMirror() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        #expect(state.mirrors[hold]?.forwardSentAt == at(30_100))

        Reducer.reduce(&state, .forwardUnconfirmed(hold, at: at(35_100)))
        #expect(state.mirrors[hold]?.forwardUnconfirmedAt == at(35_100))
        #expect(state.mirrors[hold]?.forwardSentAt == at(30_100),
                "the unconfirmed mark cleared the awaiting-confirmation window instead of layering on it")
        // Still `.terminalLive` — an unconfirmed send is recoverable, not
        // a resolution, and does not itself change the stage.
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(26_000)))
    }

    /// `forwardUnconfirmed` is a no-op with no completed send to be
    /// unconfirmed ABOUT — `forwardSentAt == nil` refuses it, the same
    /// "claim only what the deck actually knows" doctrine this whole
    /// rename exists for. Reachable if `.forwardRearmed` already cleared
    /// the window before a late-firing watchdog caught up.
    @Test("forwardUnconfirmed is a no-op once forwardSentAt has already been cleared")
    func forwardUnconfirmedIsANoOpWithNoAwaitingSend() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        #expect(state.mirrors[hold]?.forwardSentAt == nil)

        Reducer.reduce(&state, .forwardUnconfirmed(hold, at: at(30_000)))
        #expect(state.mirrors[hold]?.forwardUnconfirmedAt == nil,
                "a watchdog with nothing sent yet still marked the mirror unconfirmed")
    }

    /// The watchdog and a genuine, on-time `PostToolUse` race the same
    /// clock; a `PostToolUse` that wins does not need to be told so —
    /// `DeckEvent.forwardUnconfirmed`'s own doc comment states the same
    /// claim this proves.
    @Test("forwardUnconfirmed is a no-op once the mirror has already resolved")
    func forwardUnconfirmedIsANoOpOnceResolved() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("1")]),
                                                    at: at(26_500)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(26_600)))
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(27_000), kind: .postToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: "t1",
                                               held: .absent, questions: [question],
                                               answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))
        guard case .resolved? = state.mirrors[hold]?.stage else {
            Issue.record("the fixture's own premise: the mirror must already be resolved")
            return
        }

        Reducer.reduce(&state, .forwardUnconfirmed(hold, at: at(32_000)))
        #expect(state.mirrors[hold]?.forwardUnconfirmedAt == nil,
                "a stale watchdog marked a mirror that had already resolved on time")
    }

    /// A retry clears the PREVIOUS attempt's own stale notice the
    /// instant it starts — `QuestionMirror.forwardUnconfirmedAt`'s own
    /// doc comment states why a notice surviving a fresh attempt would
    /// be worse than none. Only reachable at all because `.forwardRearmed`
    /// cleared `forwardSentAt` first — the next test proves the guard
    /// this one depends on.
    @Test("a new forward plan clears a stale forwardUnconfirmedAt from the previous attempt")
    func newForwardPlanClearsAStaleForwardUnconfirmedAt() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        Reducer.reduce(&state, .forwardUnconfirmed(hold, at: at(40_000)))
        #expect(state.mirrors[hold]?.forwardUnconfirmedAt == at(40_000))

        Reducer.reduce(&state, .forwardRearmed(hold, at: at(44_000)))
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("1")]),
                                                    at: at(45_000)))
        #expect(state.mirrors[hold]?.forwardUnconfirmedAt == nil,
                "retrying left the previous attempt's own unconfirmed notice standing")
    }

    /// **D5's own reducer-level door, never trusted to the view alone —
    /// a root cause, closed at the model
    /// layer.** A plan may not start while `forwardSentAt` is still set:
    /// the exact shape of the incident's tap 3, which reached
    /// `DeckRuntime.forward` and rebuilt a plan for a mirror that had
    /// already sent one.
    @Test("forwardPlanStarted refuses a fresh plan while forwardSentAt is still set")
    func forwardPlanStartedRefusesWhileAwaitingConfirmation() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        #expect(state.mirrors[hold]?.forwardSentAt == at(30_100))

        // The exact shape of a duplicate tap: a SECOND plan for the SAME
        // hold, built for the SAME digit, while the first is still
        // awaiting confirmation.
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_400)))
        #expect(state.forwarding[hold] == nil,
                "a second plan started while the first was still awaiting confirmation — the duplicate-send door")
    }

    /// **D5's own explicit re-arm, proven end to end: it clears the way,
    /// and ONLY an explicit `.forwardRearmed` does.** Not a replay of the
    /// original plan — a fresh `.forwardPlanStarted` after it, the
    /// ordinary door, now admitted again.
    @Test("forwardRearmed clears the awaiting/unconfirmed marks and re-admits a fresh plan")
    func forwardRearmedReadmitsAFreshPlan() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        Reducer.reduce(&state, .forwardUnconfirmed(hold, at: at(35_100)))
        #expect(state.mirrors[hold]?.forwardSentAt != nil)
        #expect(state.mirrors[hold]?.forwardUnconfirmedAt != nil)

        Reducer.reduce(&state, .forwardRearmed(hold, at: at(36_000)))
        #expect(state.mirrors[hold]?.forwardSentAt == nil)
        #expect(state.mirrors[hold]?.forwardUnconfirmedAt == nil)

        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(36_500)))
        #expect(state.forwarding[hold] != nil,
                "forwardRearmed cleared the marks but a fresh plan still could not start")
    }

    /// **D5, projected — `MirrorView.awaitingConfirmation` and
    /// `.optionsDisabled`, the fact both surfaces actually read.** Pinned
    /// through `Projection.frame`, not the reducer's own field directly,
    /// so this proves the SAME thing `QuestionMirrorCard`/
    /// `QuestionMirrorStage` see.
    @Test("a completed plan reads awaitingConfirmation and optionsDisabled in the projection")
    func completedPlanProjectsAwaitingConfirmation() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))

        let frame = Projection.frame(from: state, at: at(31_000))
        let mirror = frame.mirrors.first { $0.hold == hold }
        #expect(mirror?.awaitingConfirmation == true)
        #expect(mirror?.forwarding == false, "the plan already completed — forwarding must not still read true")
        #expect(mirror?.optionsDisabled == true,
                "awaitingConfirmation is exactly the case optionsDisabled exists to also cover")

        Reducer.reduce(&state, .forwardRearmed(hold, at: at(32_000)))
        let after = Projection.frame(from: state, at: at(33_000)).mirrors.first { $0.hold == hold }
        #expect(after?.awaitingConfirmation == false)
        #expect(after?.optionsDisabled == false, "forwardRearmed did not actually re-enable the options")
    }

    // ------------------------------------------------ the bypass hold-spam fix
    //
    // Past defect: the 2,515-bogus-holds
    // defect reborn with a `nil` `permission_mode` where the hardcoded
    // `true` used to be. `HoldPolicy.needsAHuman`'s own doc comment states
    // the fix's premise (`permissionMode != "bypassPermissions"` reads
    // `nil != "bypassPermissions"` as true); these tests drive the LANE
    // fallback that fixes it, directly.

    /// **The wire-shaped half of the secondary suspicion.** Raw JSON,
    /// through `HookIngest.event` — never a hand-built `HookEvent` — for
    /// a `PermissionRequest` naming the question tool, proving ingest
    /// actually decodes `tool_name` off this specific kind's payload
    /// (`HookIngest.event`'s own `tool` line reads `row["tool"]` first,
    /// `payload["tool_name"]` second, unconditional on `kind`) and that
    /// the decoded event reaches the reducer's own readiness-gate
    /// correlation end to end.
    @Test("a raw PermissionRequest payload decodes its tool name and reaches the readiness gate")
    func rawPermissionRequestPayloadReachesTheReadinessGate() {
        let row = JSONValue.object([
            "ts": .string("2026-08-11T00:00:00.000Z"),
            "event": .string("PermissionRequest"),
            "payload": .object([
                "hook_event_name": .string("PermissionRequest"),
                "session_id": .string("s"),
                "tool_name": .string(SubjectReader.questionTool),
                "permission_mode": .string("default"),
            ]),
        ])
        let event = HookIngest.event(from: row, epochBase: 0)
        #expect(event?.tool == SubjectReader.questionTool,
                "ingest did not decode tool_name off a raw PermissionRequest payload")

        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        guard let decoded = event else {
            Issue.record("ingest refused a well-formed PermissionRequest payload")
            return
        }
        // The decoded event's own `at` is epoch-based (0), not this
        // stream's `Instant` timeline — re-stamped the same way
        // `DeckRuntime.handle` re-stamps every live arrival, so this
        // reads as "the next event on the stream" rather than a row from
        // a different clock entirely.
        let restamped = HookEvent(id: decoded.id, at: at(20_000), kind: decoded.kind,
                                  session: decoded.session, cwd: decoded.cwd, tool: decoded.tool,
                                  toolUseID: decoded.toolUseID, held: decoded.held,
                                  permissionMode: decoded.permissionMode)
        Reducer.reduce(&state, .hook(restamped))
        #expect(state.mirrors[hold]?.permissionRequestSeenAt == at(20_000),
                "a PermissionRequest decoded off raw wire bytes did not reach the readiness gate's own correlation")
    }

    /// **The reducer-level half — the bypass session itself.** A
    /// `PermissionRequest` naming an ordinary tool (never the question
    /// tool — bypass auto-answers PERMISSIONS, not QUESTIONS,
    /// `HoldPolicy.needsAHuman`'s own doc comment states why) with NO
    /// `permission_mode` on THIS particular event must still read as
    /// bypass and open no hold, once an EARLIER event on the same
    /// session already established it. Absent that fallback, a `nil`
    /// here reads as "not bypassPermissions" and re-opens the class this
    /// test exists to close.
    @Test("a PermissionRequest missing permission_mode still reads bypass from the lane's own history")
    func permissionRequestMissingModeFallsBackToTheLanesOwnHistory() {
        var state = DeckState()
        let session = SessionID("s")
        // Establishes the lane AND absorbs `permissionMode: bypassPermissions`
        // — an ordinary `UserPromptSubmit`, the same kind every real
        // session opens with, carrying the mode the way `HookEvent
        // .permissionMode`'s own doc comment says every payload does.
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("prompt"), at: .start, kind: .userPromptSubmit,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent, permissionMode: "bypassPermissions")))

        // A `PermissionRequest` for an ordinary tool call, `permissionMode`
        // absent on THIS event — the exact wire gap the tertiary finding
        // suspects. `toolUseID` present (unlike the correlation tests
        // above) so a hold, if one opened, would be findable at all —
        // opening a hold via this path writes `state.holds` directly and
        // emits no `Effect` of its own, so `state.holds` is the only
        // observable here.
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("pr"), at: at(1_000), kind: .permissionRequest,
            session: session, cwd: nil, tool: "Bash", toolUseID: "t1",
            held: .absent, permissionMode: nil)))

        #expect(state.holds.isEmpty,
                "state.holds carries a hold this bypass session's own history should have refused")
    }

    /// **The control — same shape, mode absorbed as `"default"` instead.**
    /// Proves the fallback reads the lane's actual last-known value
    /// rather than always refusing regardless of it: a `nil` on this
    /// event over a genuinely non-bypass history still opens the hold a
    /// real permission dialog deserves.
    @Test("a PermissionRequest missing permission_mode still holds when the lane's own history is not bypass")
    func permissionRequestMissingModeStillHoldsForANonBypassLane() {
        var state = DeckState()
        let session = SessionID("s")
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("prompt"), at: .start, kind: .userPromptSubmit,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent, permissionMode: "default")))

        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("pr"), at: at(1_000), kind: .permissionRequest,
            session: session, cwd: nil, tool: "Bash", toolUseID: "t1",
            held: .absent, permissionMode: nil)))

        #expect(state.holds[HoldID(session: session, toolUseID: "t1")] != nil,
                "a non-bypass session's own PermissionRequest opened no hold")
    }

    /// **The LANE state half of the same fallback** — `transition(on:
    /// policy:permissionMode:)`'s own signature exists so this cannot
    /// disagree with `opensAHold`'s verdict above about the identical
    /// event. A bypass lane with no `permission_mode` on this specific
    /// `PermissionRequest` must move to `.working`, never `.needsYou` —
    /// the card-goes-red half of the 2,515-bogus-holds defect, reborn.
    @Test("a bypass lane's own state does not flip to needsYou when permission_mode is missing on this event")
    func bypassLaneStateFallsBackToTheLanesOwnHistoryToo() {
        var state = DeckState()
        let session = SessionID("s")
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("prompt"), at: .start, kind: .userPromptSubmit,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent, permissionMode: "bypassPermissions")))
        #expect(state.lanes[session]?.state == .working)

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pr"), at: at(1_000), kind: .permissionRequest,
                                               session: session, cwd: nil, tool: "Bash", toolUseID: nil,
                                               held: .absent, permissionMode: nil)))
        #expect(state.lanes[session]?.state == .working,
                "a bypass lane with no permission_mode on this event flipped to needsYou")
    }

    // ------------------------------------------------- D3: retirement widened
    //
    // Past defect, D3. Even with D2's
    // auto-heal, a session STARTED before the deck learned to ask for
    // `PostToolUse` snapshotted its own hook list at launch and will
    // NEVER fire one — a live session, incident two: `holdExpired`
    // (release) at 2414298ms, and then no retirement event of any kind,
    // ever. These tests replay that shape directly against the reducer.

    /// **The incident itself, replayed.** Question opens, releases, and
    /// NO `PostToolUse` of any kind ever arrives for it — only a LATER
    /// `PreToolUse` for a completely different tool call, which is
    /// exactly what a session moving on to its next turn looks like on
    /// the wire.
    @Test("a later PreToolUse on the same session retires a released mirror that never got a PostToolUse")
    func laterPreToolUseRetiresAReleasedMirrorWithNoPostToolUseEver() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.mirrors[hold]?.stage.releasedAt != nil)

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("bash"), at: at(20_000), kind: .preToolUse,
                                               session: session, cwd: nil, tool: "Bash", toolUseID: "t2",
                                               held: .value(1))))
        #expect(state.mirrors[hold]?.stage == .resolved(answers: nil, origin: .movedOn, at: at(20_000)))
    }

    /// **The companion — the SAME event, while the hold is still doing
    /// its job.** `.deckWindow` is live and actionable; D3 must never
    /// touch it, the identical bound `.sessionEnd`'s own pre-existing
    /// block already holds.
    @Test("the same PreToolUse touches nothing while the mirror is still deckWindow")
    func preToolUseTouchesNothingWhileDeckWindow() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        #expect(state.mirrors[hold]?.stage == .deckWindow)

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("bash"), at: at(1_000), kind: .preToolUse,
                                               session: session, cwd: nil, tool: "Bash", toolUseID: "t2",
                                               held: .value(1))))
        #expect(state.mirrors[hold]?.stage == .deckWindow,
                "a sibling PreToolUse resolved a mirror whose hold is still open and doing its job")
    }

    /// **The doors, parameterized.** `.userPromptSubmit`, `.stop`,
    /// `.sessionStart` each independently prove the session moved past
    /// the question, the identical claim `.preToolUse` proves above.
    @Test("each qualifying hook kind retires a released mirror with no PostToolUse ever",
          arguments: [HookKind.stop, .userPromptSubmit, .sessionStart])
    func qualifyingKindsRetireAReleasedMirror(_ kind: HookKind) {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("door"), at: at(20_000), kind: kind,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent)))
        #expect(state.mirrors[hold]?.stage == .resolved(answers: nil, origin: .movedOn, at: at(20_000)),
                Comment(rawValue: "\(kind) did not retire a released mirror"))
    }

    /// **The exclusion — the ceremony pair is not a door out.** A
    /// `PermissionRequest`/`Notification` arriving on a `.released`
    /// mirror is exactly what PROVES a picker exists — the opposite
    /// claim D3 would be making — and must promote toward `.terminalLive`
    /// exactly as before, never resolve the mirror as moved-on.
    @Test("permissionRequest and notification do not retire a released mirror — they are the ceremony, not a door out")
    func ceremonyEventsDoNotRetireAReleasedMirror() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pr"), at: at(20_000), kind: .permissionRequest,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: nil, held: .absent)))
        #expect(state.mirrors[hold]?.stage.releasedAt != nil, "PermissionRequest retired a released mirror")

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("nt"), at: at(21_000), kind: .notification,
                                               session: session, cwd: nil, tool: nil, toolUseID: nil,
                                               held: .absent, notificationType: "permission_prompt")))
        #expect(state.mirrors[hold]?.stage == .terminalLive(at: at(21_000)),
                "the ceremony pair itself got treated as a moved-on signal")
    }

    /// **The other exclusion — the mirror's OWN `PostToolUse` still takes
    /// the richer, dedicated path, never D3's `answers: nil` door.**
    /// Matching `toolUseID` AND the question tool is what the exclusion
    /// keys on; either mismatching is what makes D3 apply instead (the
    /// next test).
    @Test("the mirror's own PostToolUse still resolves with real answers, not the moved-on door")
    func ownPostToolUseStillTakesTheRicherPath() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))

        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(20_000), kind: .postToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: "t1",
                                               held: .absent, questions: [question],
                                               answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))
        guard case .resolved(let answers, let origin, _)? = state.mirrors[hold]?.stage else {
            Issue.record("the mirror's own PostToolUse did not resolve it at all")
            return
        }
        #expect(answers == [Answer(question: Redacted("Q"), labels: [Redacted("A")])])
        #expect(origin == .terminal,
                "the richer, real-answers path did not run — this reads like the moved-on door instead")
    }

    /// **A retried
    /// `PreToolUse` for the SAME `toolUseID` this mirror's own hold
    /// opened on must not read as evidence the session moved past its
    /// own question — it IS that question, resent, not a sibling call.**
    /// Before this exclusion, a duplicate or transport-retried
    /// `PreToolUse` arriving after release would retire the question's
    /// own mirror as `.movedOn` on the strength of itself — the event
    /// that CREATED the question read as proof the session had moved
    /// past it. The symmetric case one test above
    /// (`ownPostToolUseStillTakesTheRicherPath`) is the identical
    /// doctrine on the OTHER hook kind the mirror's own hold ever fires.
    @Test("a repeated PreToolUse for the mirror's own question leaves a released mirror released")
    func repeatedOwnPreToolUseLeavesAReleasedMirrorReleased() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.mirrors[hold]?.stage.releasedAt != nil)

        // The identical PreToolUse the question itself opened on — same
        // toolUseID, same question tool — resent, arriving after release.
        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("retry"), at: at(20_000), kind: .preToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: "t1",
                                               held: .value(1), questions: [question])))
        #expect(state.mirrors[hold]?.stage == .released(at: at(8_000)),
                "a retried PreToolUse for the mirror's own question retired it as moved-on")
    }

    /// **The mirror's own `PostToolUse` identity mismatched two ways —
    /// a different `toolUseID`, and a non-question tool — both retire.**
    @Test("a PostToolUse for a different call retires a released mirror with no answer of its own",
          arguments: [("t2", SubjectReader.questionTool), ("t1", "Bash")])
    func postToolUseForADifferentCallRetiresTheMirror(_ shape: (toolUseID: String, tool: String)) {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post2"), at: at(20_000), kind: .postToolUse,
                                               session: session, cwd: nil, tool: shape.tool,
                                               toolUseID: shape.toolUseID, held: .absent)))
        #expect(state.mirrors[hold]?.stage == .resolved(answers: nil, origin: .movedOn, at: at(20_000)),
                Comment(rawValue: "shape \(shape) did not retire the mirror"))
    }

    /// **The session bound, the one thing this correlation can never get
    /// wrong** — `permissionRequestNeverBindsAcrossSessions`'s own
    /// doctrine, applied to D3's wider door.
    @Test("a qualifying hook for one session never retires another session's released mirror")
    func qualifyingHookNeverBindsAcrossSessions() {
        var state = DeckState()
        let holdA = openQuestionMirror(&state, session: SessionID("a"), use: "t1", at: .start)
        let holdB = openQuestionMirror(&state, session: SessionID("b"), use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(holdA, at: at(8_000)))
        Reducer.reduce(&state, .holdExpired(holdB, at: at(8_000)))

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("bash"), at: at(20_000), kind: .preToolUse,
                                               session: SessionID("a"), cwd: nil, tool: "Bash",
                                               toolUseID: "t2", held: .value(1))))
        #expect(state.mirrors[holdA]?.stage == .resolved(answers: nil, origin: .movedOn, at: at(20_000)),
                "session a's own mirror was not retired")
        #expect(state.mirrors[holdB]?.stage == .released(at: at(8_000)),
                "a PreToolUse for session a retired session b's own mirror too")
    }

    /// **Cleanup on retirement.** A plan mid-flight or already awaiting
    /// confirmation, aimed at a picker the session has already left, is
    /// stopped the same `cullStaleDialogKeys`-class way the mirror's own
    /// `PostToolUse` block already stops one.
    @Test("D3's own retirement clears any in-flight or awaiting forward state")
    func d3RetirementClearsForwardState() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("2")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        #expect(state.mirrors[hold]?.forwardSentAt != nil)

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("bash"), at: at(40_000), kind: .preToolUse,
                                               session: session, cwd: nil, tool: "Bash", toolUseID: "t2",
                                               held: .value(1))))
        #expect(state.mirrors[hold]?.stage == .resolved(answers: nil, origin: .movedOn, at: at(40_000)))
        #expect(state.forwarding[hold] == nil)
        #expect(state.mirrors[hold]?.forwardSentAt == nil)
    }

    // ------------------------------------------- the resolved-mirror linger fix
    //
    // Past defect: a question resolved
    // correctly — `PostToolUse` arrived, answers shown, the second-tap
    // fix held — and the resolved card then sat in the band's act zone
    // INDEFINITELY, hiding the transcript well underneath it, which
    // already carries the SAME answer as a ledger row. `Projection
    // .frame`'s own `projectsMirror` predicate is what these pin — pure,
    // no runtime involved; `ReadinessGateRuntimeTests` (DeckAppTests)
    // proves the WAKE that keeps a quiet session's glass from going
    // stale once the predicate's own answer changes underneath it.

    /// One resolved mirror, built through the SAME reducer doors
    /// production reaches each origin through — never a direct `.stage`
    /// mutation, the discipline every other test in this file already
    /// holds.
    private func resolvedMirror(origin: ResolvedOrigin) -> (DeckState, HoldID) {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        switch origin {
        case .deck:
            // Past the hold's own 250ms arm delay — `Hold.resolve`'s own
            // guard refuses `.updatedInput` before `armedAt`, the same
            // arm-delay rule every takeover tap in this codebase answers
            // to (`resolvedMirrorCarriesAnswers`, above, uses the same
            // margin for the identical reason).
            Reducer.reduce(&state, .questionSubmitted(
                hold, answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])], at: at(1_000)))
        case .terminal:
            let question = Question(text: Redacted("Q"), header: Redacted(""),
                                    options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                    multiSelect: false)
            Reducer.reduce(&state, .holdExpired(hold, at: at(0)))
            Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(1), kind: .postToolUse,
                                                   session: session, cwd: nil,
                                                   tool: SubjectReader.questionTool, toolUseID: "t1",
                                                   held: .absent, questions: [question],
                                                   answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))
        case .movedOn:
            Reducer.reduce(&state, .holdExpired(hold, at: at(0)))
            Reducer.reduce(&state, .hook(HookEvent(id: EventID("end"), at: at(1), kind: .sessionEnd,
                                                   session: session, cwd: nil, tool: nil, toolUseID: nil,
                                                   held: .absent)))
        }
        return (state, hold)
    }

    /// **The red this section answers.** Before `resolvedMirrorLinger`
    /// existed, a resolved mirror projected forever — the exact shape
    /// of the live incident. `<=`, not `<`: the boundary instant itself
    /// still projects (`projectsMirror`'s own doc comment states the
    /// `Hold.expiresAt`-class inclusive convention this matches), one
    /// instant later it does not.
    @Test("a resolved mirror projects at exactly the linger boundary, not one instant past it",
          arguments: [(Int64(-1), true), (Int64(0), true), (Int64(1), false)])
    func resolvedMirrorProjectsAtTheLingerBoundary(_ offsetFromLinger: Int64, _ shouldStillProject: Bool) {
        let (state, hold) = resolvedMirror(origin: .deck)
        guard case .resolved(_, _, let resolvedAt)? = state.mirrors[hold]?.stage else {
            Issue.record("the fixture's own premise: the mirror must already be resolved")
            return
        }

        let renderAt = Instant(sinceStart: Millis(resolvedAt.sinceStart.raw
                                                   + state.policy.resolvedMirrorLinger.raw + offsetFromLinger))
        let frame = Projection.frame(from: state, at: renderAt)
        let stillProjects = frame.mirrors.contains { $0.hold == hold }
        #expect(stillProjects == shouldStillProject,
                Comment(rawValue: "offset \(offsetFromLinger)ms from the linger: expected "
                        + "projects=\(shouldStillProject), got \(stillProjects)"))
    }

    /// **Applies to every resolution origin alike** — `projectsMirror`
    /// reads only the stage's own `at`, never `origin`, so D3's own
    /// `.movedOn` retirements age out of the glass exactly the same way
    /// a deck- or terminal-answered card does.
    @Test("a resolved mirror ages out of the projection regardless of which origin resolved it",
          arguments: [ResolvedOrigin.deck, .terminal, .movedOn])
    func resolvedMirrorAgesOutRegardlessOfOrigin(_ origin: ResolvedOrigin) {
        let (state, hold) = resolvedMirror(origin: origin)
        guard case .resolved(_, let actualOrigin, let resolvedAt)? = state.mirrors[hold]?.stage else {
            Issue.record("the fixture's own premise: the mirror must already be resolved")
            return
        }
        #expect(actualOrigin == origin, "the fixture's own setup produced the wrong origin")

        let pastLinger = Instant(sinceStart: Millis(resolvedAt.sinceStart.raw
                                                     + state.policy.resolvedMirrorLinger.raw + 1))
        let frame = Projection.frame(from: state, at: pastLinger)
        #expect(!frame.mirrors.contains { $0.hold == hold },
                Comment(rawValue: "a mirror resolved via \(origin) did not age out of the projection"))
    }

    /// **`state.mirrors` itself is untouched — only the PROJECTION ages
    /// out.** The hold sweep stays the sole owner of state lifetime
    /// (`resolvedMirrorLinger`'s own doc comment states why:
    /// `repeatedPostToolUseIsInert`'s idempotency depends on the mirror
    /// SURVIVING so `mirrorAlreadyResolved` can still find it on a
    /// transport retry). A mirror well past its own linger is still
    /// sitting in `state.mirrors`, just no longer projected.
    @Test("a resolved mirror past its own linger is still in state.mirrors, only no longer projected")
    func resolvedMirrorSurvivesInStateWellPastItsOwnLinger() {
        let (state, hold) = resolvedMirror(origin: .deck)
        guard case .resolved(_, _, let resolvedAt)? = state.mirrors[hold]?.stage else {
            Issue.record("the fixture's own premise: the mirror must already be resolved")
            return
        }

        let wayPastLinger = Instant(sinceStart: Millis(resolvedAt.sinceStart.raw
                                                        + state.policy.resolvedMirrorLinger.raw + 60_000))
        #expect(state.mirrors[hold] != nil, "state.mirrors itself dropped the mirror early")
        let frame = Projection.frame(from: state, at: wayPastLinger)
        #expect(!frame.mirrors.contains { $0.hold == hold })
    }

    // ---------------------------------------------- the origin attribution fix
    //
    // Past defect: the user answered FROM THE
    // DECK — a forwarded plan, completed — and the card read "Answered
    // in the terminal." The dedicated `PostToolUse` block resolved with
    // `origin: .terminal` unconditionally, never consulting
    // `forwardSentAt` — the one fact that actually distinguishes the
    // deck's own forwarded keystrokes echoing back from a hand-typed
    // terminal answer.

    /// **The red this section answers.** A forward plan that finished
    /// sending, then its own `PostToolUse` — the identical shape the
    /// forward-recovery fix already builds a
    /// `.terminalLive` mirror to reach.
    @Test("a completed forward plan's own PostToolUse resolves with origin .deck, not .terminal")
    func completedForwardPlanResolvesWithDeckOrigin() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = terminalLiveMirror(&state, session: session, use: "t1")
        Reducer.reduce(&state, .forwardPlanStarted(ForwardPlan(hold: hold, steps: [.bytes("1")]),
                                                    at: at(30_000)))
        Reducer.reduce(&state, .forwardStepSent(hold, at: at(30_100)))
        #expect(state.mirrors[hold]?.forwardSentAt == at(30_100),
                "the fixture's own premise: the forward plan must have completed")

        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(31_000), kind: .postToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: "t1",
                                               held: .absent, questions: [question],
                                               answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))
        guard case .resolved(let answers, let origin, _)? = state.mirrors[hold]?.stage else {
            Issue.record("the mirror never resolved at all")
            return
        }
        #expect(answers == [Answer(question: Redacted("Q"), labels: [Redacted("A")])],
                "the origin fix changed WHAT was recorded, not just WHO gets credit for it")
        #expect(origin == .deck,
                "a forwarded plan's own completion resolved with origin .terminal — the regression this guards")
    }

    /// **No forward, ever — origin stays `.terminal`.** The negative
    /// half: `forwardSentAt` is `nil` throughout an ordinary
    /// terminal-answered call, so the fix must not relabel the common
    /// case. `terminalAnswerClosesTheWholeLoop` (above, golden against
    /// the LV38 fixture) already pins this exact claim against REAL
    /// recorded bytes; this is the same claim built by hand, beside the
    /// `.deck` case above so the two read as one pair.
    @Test("a hand-typed terminal answer, with no forward ever, still resolves with origin .terminal")
    func handTypedTerminalAnswerStillResolvesWithTerminalOrigin() {
        var state = DeckState()
        let session = SessionID("s")
        let hold = openQuestionMirror(&state, session: session, use: "t1", at: .start)
        Reducer.reduce(&state, .holdExpired(hold, at: at(8_000)))
        #expect(state.mirrors[hold]?.forwardSentAt == nil, "the fixture's own premise: no forward ever ran")

        let question = Question(text: Redacted("Q"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(9_000), kind: .postToolUse,
                                               session: session, cwd: nil,
                                               tool: SubjectReader.questionTool, toolUseID: "t1",
                                               held: .absent, questions: [question],
                                               answers: [Answer(question: Redacted("Q"), labels: [Redacted("A")])])))
        guard case .resolved(_, let origin, _)? = state.mirrors[hold]?.stage else {
            Issue.record("the mirror never resolved at all")
            return
        }
        #expect(origin == .terminal)
    }
}
