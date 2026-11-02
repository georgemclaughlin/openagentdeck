//
//  ApiErrorTests.swift · Tests/DeckCoreTests
//
//  `DeckEvent.apiError` — the transcript-learned API-error message's own
//  reducer-level laws: the no-synthesized-lane rule, the dominance table
//  (a peek is stamped with its TRIGGER hook's own provenance, so every
//  race resolves through the SAME gate `apply(_:HookEvent)` already
//  uses), the clearing rule (a lane that moved on has no stale error left
//  to show), and the two boundary facts — `DiagnosticExport` and
//  `Replay.timestamp(of:)` — every OTHER content-bearing event already
//  holds. `TranscriptSeedTests.swift`'s own idiom (fixture builders,
//  `Reducer.run`/`Reducer.reduce`) is this file's direct model.
//

import Testing
@testable import DeckCore

struct ApiErrorTests {

    private static let session = SessionID("s1")

    /// The 529 specimen — Claude Code's own product copy, pinned verbatim
    /// the same way `TranscriptTailTests` pins it, not user content the
    /// privacy absolute would forbid.
    private static let overloadedText =
        "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. "
        + "If it persists, check https://status.claude.com."

    private static func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private static func start(_ ms: Int64, session: SessionID = Self.session) -> DeckEvent {
        .hook(HookEvent(id: EventID("start-\(session.raw)-\(ms)"), at: Self.at(ms),
                        kind: .sessionStart, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent))
    }

    private static func userPromptSubmit(_ ms: Int64, id: String, session: SessionID = Self.session) -> DeckEvent {
        .hook(HookEvent(id: EventID(id), at: Self.at(ms), kind: .userPromptSubmit,
                        session: session, cwd: nil, tool: nil, toolUseID: nil, held: .absent,
                        prompt: Redacted("trying again")))
    }

    private static func preToolUse(_ ms: Int64, id: String, toolUseID: String,
                                   session: SessionID = Self.session) -> DeckEvent {
        .hook(HookEvent(id: EventID(id), at: Self.at(ms), kind: .preToolUse,
                        session: session, cwd: nil, tool: "Bash", toolUseID: toolUseID,
                        held: .value(120_000)))
    }

    private static func notification(_ ms: Int64, id: String, type: String,
                                     session: SessionID = Self.session) -> DeckEvent {
        .hook(HookEvent(id: EventID(id), at: Self.at(ms), kind: .notification,
                        session: session, cwd: nil, tool: nil, toolUseID: nil, held: .absent,
                        notificationType: type))
    }

    private static func sessionEnd(_ ms: Int64, id: String, session: SessionID = Self.session) -> DeckEvent {
        .hook(HookEvent(id: EventID(id), at: Self.at(ms), kind: .sessionEnd,
                        session: session, cwd: nil, tool: nil, toolUseID: nil, held: .absent))
    }

    private static func apiError(_ text: String = Self.overloadedText, at ms: Int64, id: String,
                                 session: SessionID = Self.session) -> DeckEvent {
        .apiError(session, text: Redacted(text), at: Self.at(ms), id: EventID(id))
    }

    // ------------------------------------------------- no-synthesized-lane

    @Test("an api-error peek for a session with no lane yet is a no-op, the same guard .worktree/.transcriptSeeded already hold")
    func peekWithNoLaneIsANoOp() {
        let state = Reducer.run([Self.apiError(at: 1_000, id: "e1")])
        #expect(state.lanes[Self.session] == nil)
    }

    // --------------------------------------------------------- dominance

    @Test("a peek stamped EARLIER than the lane's own current state loses to it")
    func earlierPeekLosesToALaterRealHook() {
        let state = Reducer.run([Self.start(0), Self.userPromptSubmit(2_000, id: "p1"),
                                 Self.apiError(at: 1_000, id: "e1")])
        let lane = state.lanes[Self.session]
        #expect(lane?.state == .working,
                "the real UserPromptSubmit's own .working must survive a peek stamped BEFORE it")
        #expect(lane?.apiError == nil,
                "a dominated peek records nothing — not even a text nobody is showing")
    }

    /// **The flush-lag case, the design's own words, and the RECEIPT for
    /// why the refined guard's own exception is scoped to `.idle` and
    /// nothing wider.** A peek is stamped with the SAME `(at, id)` as the
    /// hook that triggered it whenever that hook is itself the trigger —
    /// here, a `UserPromptSubmit` retry. `.working` is a HARD, NEW fact —
    /// a person just acted — and the file read racing it (this session's
    /// OLD error, not yet superseded on disk) is BY CONSTRUCTION staler
    /// than the retry it is actually describing the moment before: the
    /// reducer's own `.apiError` case handler ORs its `dominates` guard
    /// with "the trigger's own anchor is `.idle`" precisely so a tie like
    /// THIS one — `.working`, not `.idle` — still falls through to
    /// `dominates` alone and loses on the tie-break (`DeckState.swift`'s
    /// own doc comment on `dominates`: "a tie break on event id is not
    /// decoration"). Letting it win would overturn a retry the same
    /// instant it happened.
    @Test("a peek carrying the IDENTICAL (at, id) as the hook that already decided .working loses the tie")
    func tiedPeekLosesToItsOwnTriggeringHook() {
        let state = Reducer.run([Self.start(0), Self.userPromptSubmit(2_000, id: "p1"),
                                 Self.apiError(at: 2_000, id: "p1")])
        let lane = state.lanes[Self.session]
        #expect(lane?.state == .working, "an equal-(at,id) peek must not overturn the hook it is tied with")
        #expect(lane?.apiError == nil)
    }

    /// **The live 529 flow, reduced to its own reducer-level table — the
    /// design's own worst-case-latency claim, held accountable directly,
    /// not merely argued in a doc comment.** Fact 2's own probe: no hook
    /// fires at the abort moment, so `SessionStart` opens the lane
    /// `.idle` and nothing else ever happens until a `Notification`
    /// carrying `idle_prompt` arrives 60 seconds later. That
    /// notification's OWN `transition(on:)` ALSO writes `.idle` — a tie
    /// against the anchor it JUST planted — and this is the one tie the
    /// refined guard exists to let win: `idle_prompt` is a verdict
    /// reached out of SILENCE (nothing contradicted it), and the
    /// transcript's own last word is exactly the missing WHY of that
    /// silence. Before the refined guard existed this test was RED —
    /// the strict `dominates`-only gate ties and loses here exactly the
    /// same way it does in `tiedPeekLosesToItsOwnTriggeringHook` above,
    /// which is precisely the gap `TranscriptBackfillTests`'s own probe
    /// found empirically and this table now pins structurally.
    @Test("a Notification's own idle_prompt write is refined by its own peek — the 60s worst-case latency claim, made true")
    func idlePromptsOwnPeekRefinesTheIdleItWrote() {
        let state = Reducer.run([Self.start(0),
                                 Self.notification(60_000, id: "n1", type: "idle_prompt"),
                                 Self.apiError(at: 60_000, id: "n1")])
        let lane = state.lanes[Self.session]
        #expect(lane?.state == .errored,
                "the notification's own idle_prompt write must be REFINED by its own peek, not tied-and-lost against")
        #expect(lane?.apiError?.value.value == Self.overloadedText)
        #expect(lane?.apiError?.source == EventID("n1"))
    }

    /// **The refinement's own OTHER boundary — `.ended` stands.** A
    /// `SessionEnd` hook's own `transition(on:)` always writes `.ended`,
    /// unconditionally, and a peek tied against ITS OWN trigger there
    /// must still lose: a session the user closed is truthfully ended
    /// regardless of how its last turn died, and how it died is no
    /// longer the lane's headline the way it is for a session still
    /// sitting on the strip reading a guessed `.idle`. Only `.idle`
    /// is a guess reached out of silence; `.ended` is not.
    @Test("a tie against own-trigger .ended (SessionEnd) still loses — a closed session stands closed")
    func tiedPeekAgainstOwnEndedTriggerLoses() {
        let state = Reducer.run([Self.start(0),
                                 Self.sessionEnd(5_000, id: "se1"),
                                 Self.apiError(at: 5_000, id: "se1")])
        let lane = state.lanes[Self.session]
        #expect(lane?.state == .ended,
                Comment(rawValue: "SessionEnd's own .ended write must survive its own tied peek — got \(String(describing: lane?.state))"))
        #expect(lane?.apiError == nil)
    }

    /// The fourth tie cell, pinned like its siblings rather than left to
    /// the reducer comment's argument alone: a `permission_prompt`
    /// notification writes `.needsYou` — a live dialog on screen — and a
    /// peek tied with that very write must lose. A dialog somebody can
    /// still answer is newer news than any recorded last word can be.
    @Test("a tie against own-trigger .needsYou (a permission_prompt notification) still loses — a live dialog stands")
    func tiedPeekAgainstOwnNeedsYouTriggerLoses() {
        let state = Reducer.run([Self.start(0),
                                 .hook(HookEvent(id: EventID("n1"), at: Self.at(2_000), kind: .notification,
                                                 session: Self.session, cwd: nil, tool: nil, toolUseID: nil,
                                                 held: .absent, notificationType: "permission_prompt")),
                                 Self.apiError(at: 2_000, id: "n1")])
        let lane = state.lanes[Self.session]
        #expect(lane?.state == .needsYou,
                Comment(rawValue: "the live dialog's own .needsYou must survive its own tied peek — got \(String(describing: lane?.state))"))
        #expect(lane?.apiError == nil)
    }

    @Test("a winning peek sets .errored and carries the verbatim text")
    func winningPeekSetsErroredAndText() {
        let state = Reducer.run([Self.start(0), Self.apiError(at: 1_000, id: "e1")])
        let lane = state.lanes[Self.session]
        #expect(lane?.state == .errored)
        #expect(lane?.apiError?.value.value == Self.overloadedText)
        #expect(lane?.apiError?.source == EventID("e1"))
        #expect(lane?.stateSource == EventID("e1"),
                "the lane's own state provenance must point at the peek's trigger, not a synthesized id")
    }

    // ---------------------------------------------------------- clearing

    @Test("a subsequent UserPromptSubmit clears apiError AND moves the lane off .errored")
    func subsequentUserPromptSubmitClearsApiErrorAndMovesState() {
        let state = Reducer.run([Self.start(0), Self.apiError(at: 1_000, id: "e1"),
                                 Self.userPromptSubmit(2_000, id: "p1")])
        let lane = state.lanes[Self.session]
        #expect(lane?.state == .working)
        #expect(lane?.apiError == nil, "a lane that moved on has no API error left to report")
    }

    @Test("acknowledge() — a decision resolving an open hold — clears apiError the same way a hook transition does")
    func acknowledgeClearsApiError() {
        let holdID = HoldID(session: Self.session, toolUseID: "t1")
        var state = Reducer.run([Self.start(0), Self.preToolUse(10, id: "call1", toolUseID: "t1")])
        #expect(state.lanes[Self.session]?.state == .needsYou, "the fixture's own premise: an open hold, needs-you")

        // A peek stamped AFTER the hold opened wins — the session's own
        // transcript is allowed to override a stale needs-you the same
        // way it overrides idle or working; nothing about `.apiError`'s
        // own dominance gate is state-specific.
        Reducer.reduce(&state, Self.apiError(at: 500, id: "e1"))
        #expect(state.lanes[Self.session]?.state == .errored)
        #expect(state.lanes[Self.session]?.apiError != nil)

        // The hold is still open — a human can still tap the stale
        // decision — and resolving it acknowledges through the SAME
        // function `.decision`/`.questionSubmitted` share. Past the
        // hold's own `armedAt` (`openedAt` + `armDelay`, 250ms in
        // `HoldPolicy.spec`) so `Hold.resolve(_:at:)` itself does not
        // refuse the tap as landing too soon after the dialog opened —
        // an unrelated safety gate this test has no business exercising.
        Reducer.reduce(&state, .decision(holdID, .allow, at: Self.at(600)))
        #expect(state.lanes[Self.session]?.state == .working)
        #expect(state.lanes[Self.session]?.apiError == nil,
                "acknowledge() must clear apiError the same way the hook transition gate does")
    }

    @Test("a fleet-reported failure landing AFTER apiError was already cleared shows no text — the clearing rule's own receipt")
    func fleetErroredAfterClearedApiErrorShowsNoText() {
        var state = Reducer.run([Self.start(0), Self.apiError(at: 1_000, id: "e1"),
                                 Self.userPromptSubmit(2_000, id: "p1")])
        #expect(state.lanes[Self.session]?.state == .working)
        #expect(state.lanes[Self.session]?.apiError == nil)

        let row = FleetRow(session: Self.session, name: nil, kind: "background",
                           state: .value("blocked"), status: .absent)
        Reducer.reduce(&state, .fleet([row], at: Self.at(3_000), id: EventID("f1")))
        #expect(state.lanes[Self.session]?.state == .errored,
                "the fixture's own premise: the fleet's own failure report must still land")
        #expect(state.lanes[Self.session]?.apiError == nil,
                "the apiError text was already cleared by the retry — a later, UNRELATED fleet failure must not wear it")
    }

    // ------------------------------------------------------------- projection

    @Test("the projected LaneView carries apiError while .errored, and nil once a retry clears it")
    func projectionGatesApiErrorOnErroredState() {
        var state = Reducer.run([Self.start(0), Self.apiError(at: 1_000, id: "e1")])
        var frame = Projection.frame(from: state, at: Self.at(1_000))
        #expect(frame.lanes.first { $0.session == Self.session }?.apiError?.value == Self.overloadedText)

        Reducer.reduce(&state, Self.userPromptSubmit(2_000, id: "p1"))
        frame = Projection.frame(from: state, at: Self.at(2_000))
        #expect(frame.lanes.first { $0.session == Self.session }?.apiError == nil,
                Comment(rawValue: "unrepresentable any other way through events: the record's own field is "
                        + "cleared by the retry, so this also proves the PROJECTION's own gate never has stale "
                        + "text to hide in the first place"))
    }

    // ----------------------------------------------------------- boundary facts

    @Test("DiagnosticExport never exports an api-error's own text — the .transcriptSeeded precedent, restated")
    func diagnosticExportReturnsNilForApiError() {
        let event = Self.apiError(at: 1_000, id: "e1")
        #expect(DiagnosticExport.record(event) == nil)
    }

    @Test("Replay.timestamp(of:) answers the event's own at")
    func replayTimestampReadsTheEventsOwnAt() {
        let event = Self.apiError(at: 1_234, id: "e1")
        #expect(Replay.timestamp(of: event) == Self.at(1_234))
    }
}
