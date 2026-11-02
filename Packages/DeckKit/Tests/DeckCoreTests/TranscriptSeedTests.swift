//
//  TranscriptSeedTests.swift · Tests/DeckCoreTests
//
//  `DeckEvent.transcriptSeeded` — the transcript-well backfill's own
//  reducer-level laws: ordering (the past, never the present), dedup
//  (live arrivals beat the file read), the cap, idempotence, and
//  replay/permutation safety — `Reducer.swift`'s own doc comment on the
//  case handler carries the full reasoning; these are its arbiters.
//

import Testing
@testable import DeckCore

struct TranscriptSeedTests {

    private static let session = SessionID("s1")

    private static func start(_ ms: Int64, session: SessionID = Self.session) -> DeckEvent {
        .hook(HookEvent(id: EventID("start-\(session.raw)-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                        kind: .sessionStart, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent))
    }

    private static func livePrompt(_ text: String, at ms: Int64, session: SessionID = Self.session) -> DeckEvent {
        .hook(HookEvent(id: EventID("p-\(session.raw)-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                        kind: .userPromptSubmit, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent, prompt: Redacted(text)))
    }

    private static func seed(_ texts: [String], at ms: Int64, session: SessionID = Self.session) -> DeckEvent {
        .transcriptSeeded(session, texts: texts.map(Redacted.init), at: Instant(sinceStart: Millis(ms)))
    }

    // ------------------------------------------------------------- placement

    @Test("seeded entries land in the ledger, oldest file order preserved")
    func seededEntriesLandInFileOrder() {
        let state = Reducer.run([Self.start(0), Self.seed(["first", "second", "third"], at: 1_000)])
        let lane = state.lanes[Self.session]
        // Newest-first storage (the ledger's own convention, `LaneRecord
        // .rememberTranscript`'s own doc comment): the LAST-seeded (file-
        // newest) text reads first.
        #expect(lane?.transcript.map { $0.text.value } == ["third", "second", "first"])
        #expect(lane?.transcript.allSatisfy { $0.origin == .terminal && $0.deckStatus == nil } == true,
                "seeded rows are .terminal with no deckStatus — a deck send in the file is indistinguishable from typed bytes")
    }

    @Test("backfill fills the past, never the present — seeded entries sort strictly before every live entry")
    func seededEntriesSortBeforeLiveEntries() {
        let state = Reducer.run([Self.start(0), Self.livePrompt("a live prompt", at: 5_000),
                                 Self.seed(["an old file prompt"], at: 6_000)])
        let lane = state.lanes[Self.session]
        let seededAt = lane?.transcript.first { $0.text.value == "an old file prompt" }?.at
        let liveAt = lane?.transcript.first { $0.text.value == "a live prompt" }?.at
        #expect(seededAt != nil && liveAt != nil)
        #expect(seededAt! < liveAt!,
                "the seeded entry (\(String(describing: seededAt))) must sort strictly before the live one (\(String(describing: liveAt)))")
        // The well renders order, not wall-clock (the law's own words) —
        // the newest-first array must show the live entry FIRST.
        #expect(lane?.transcript.map { $0.text.value } == ["a live prompt", "an old file prompt"])
    }

    @Test("a lane with no live entries yet still seeds — the synthetic era does not depend on lane.transcript being non-empty")
    func seedingAnEmptyLedgerStillWorks() {
        let state = Reducer.run([Self.start(0), Self.seed(["only entry"], at: 1_000)])
        #expect(state.lanes[Self.session]?.transcript.map { $0.text.value } == ["only entry"])
    }

    // ----------------------------------------------------------------- dedup

    @Test("live arrivals beat the file read — a seeded text equal to an existing entry's text is dropped")
    func overlappingTextIsDeduplicated() {
        let state = Reducer.run([Self.start(0), Self.livePrompt("shared text", at: 1_000),
                                 Self.seed(["older prompt", "shared text"], at: 2_000)])
        let lane = state.lanes[Self.session]
        #expect(lane?.transcript.filter { $0.text.value == "shared text" }.count == 1,
                "the overlapping text must appear exactly once, not once from the wire and once from the file")
        #expect(lane?.transcript.map { $0.text.value } == ["shared text", "older prompt"])
    }

    // -------------------------------------------------------------------- cap

    @Test("seeding beyond the ledger's own cap keeps the newest, live entries always winning over seeded ones")
    func seedingBeyondTheCapKeepsTheNewest() {
        let manyOldTexts = (1...10).map { "old \($0)" }
        let state = Reducer.run([Self.start(0), Self.livePrompt("a live prompt", at: 5_000),
                                 Self.seed(manyOldTexts, at: 6_000)])
        let lane = state.lanes[Self.session]
        #expect(lane?.transcript.count == LaneRecord.historyCap)
        #expect(lane?.transcript.first?.text.value == "a live prompt",
                "the live entry must survive the cap — it is newer than anything seeded")
    }

    // ------------------------------------------------------------ idempotence

    @Test("a second seed for the same session is a no-op")
    func secondSeedIsANoOp() {
        let once = Reducer.run([Self.start(0), Self.seed(["a", "b"], at: 1_000)])
        let twice = Reducer.run([Self.start(0), Self.seed(["a", "b"], at: 1_000), Self.seed(["a", "b"], at: 2_000)])
        #expect(once == twice)
    }

    @Test("a second seed with DIFFERENT texts still changes nothing — the guard is per-session, not per-payload")
    func secondSeedWithDifferentTextsIsStillANoOp() {
        let firstOnly = Reducer.run([Self.start(0), Self.seed(["a", "b"], at: 1_000)])
        let firstThenSecond = Reducer.run([Self.start(0), Self.seed(["a", "b"], at: 1_000),
                                           Self.seed(["c", "d"], at: 2_000)])
        #expect(firstOnly == firstThenSecond)
        #expect(firstThenSecond.lanes[Self.session]?.transcript.map { $0.text.value } == ["b", "a"])
    }

    // ------------------------------------------------------- no-synthesized-lane

    @Test("a seed for a session with no lane yet is a no-op, the same guard .worktree/.located already hold")
    func seedWithNoLaneIsANoOp() {
        let state = Reducer.run([Self.seed(["a"], at: 1_000)])
        #expect(state.lanes[Self.session] == nil)
    }

    // -------------------------------------------------------------- permutation

    /// **The order-independence law, proven directly — not merely argued
    /// in the case handler's own doc comment.** Three orderings of the
    /// SAME three events, each with the lane-creating hook validly ahead
    /// of the seed (the no-synthesized-lane rule's own precondition —
    /// `seedWithNoLaneIsANoOp` above covers what happens when it is not),
    /// but the LIVE prompt's own position relative to the seed varies:
    /// before it, after it, and (implicitly, via `Reducer.run`'s own
    /// single-pass application) interleaved by whatever order this list
    /// gives. If the synthetic seeded instants were derived from `lane
    /// .transcript`'s own CURRENT contents at the moment the seed case
    /// runs (the mechanism the case handler's own doc comment explains
    /// choosing AGAINST), orderings 2 and 3 would reach that line with
    /// DIFFERENT `lane.transcript` contents already present (empty vs.
    /// one live entry) and could assign the seeded entry a different
    /// synthetic instant depending on which — this test is RED under that
    /// mechanism and green under the fixed-era one actually shipped.
    @Test("seed/live ordering converges to the identical final state regardless of which is applied first")
    func seedAndLiveOrderingConverges() {
        let startEvt = Self.start(0)
        let liveEvt = Self.livePrompt("a live prompt", at: 5_000)
        let seedEvt = Self.seed(["an old file prompt"], at: 6_000)

        let orderings: [[DeckEvent]] = [
            [startEvt, liveEvt, seedEvt],
            [startEvt, seedEvt, liveEvt],
        ]
        let results = orderings.map { Reducer.run($0) }
        #expect(results.allSatisfy { $0 == results[0] },
                "the seed and the live prompt converged to different states depending on which was applied first")
        #expect(results[0].lanes[Self.session]?.transcript.map { $0.text.value }
                == ["a live prompt", "an old file prompt"],
                "the converged state was not the one every ordering should reach")
    }

    /// The full `fleetAndHookPermutationsConverge`-style sweep — every
    /// permutation of four events (session start, two live prompts, one
    /// seed), not just two hand-picked orderings.
    @Test("every permutation of a small seed/live event set converges")
    func everyPermutationConverges() {
        let events: [DeckEvent] = [
            Self.start(0),
            Self.livePrompt("first live", at: 1_000),
            Self.livePrompt("second live", at: 2_000),
            Self.seed(["a file prompt"], at: 3_000),
        ]
        // All permutations that keep `start` first — the no-synthesized-
        // lane rule's own precondition, the same one production always
        // satisfies (the runtime cannot seed a session it has not yet
        // discovered). Permutations where `start` is NOT first are a
        // DIFFERENT, already-covered case (`seedWithNoLaneIsANoOp`), not
        // this law's own subject.
        let rest = Array(events.dropFirst())
        let permutations: [[DeckEvent]] = [
            [rest[0], rest[1], rest[2]],
            [rest[0], rest[2], rest[1]],
            [rest[1], rest[0], rest[2]],
            [rest[1], rest[2], rest[0]],
            [rest[2], rest[0], rest[1]],
            [rest[2], rest[1], rest[0]],
        ].map { [events[0]] + $0 }

        let results = permutations.map { Reducer.run($0) }
        #expect(results.allSatisfy { $0 == results[0] },
                "not every permutation of the seed/live event set converged to the same final state")
        #expect(results[0].lanes[Self.session]?.transcript.map { $0.text.value }
                == ["second live", "first live", "a file prompt"])
    }
}
