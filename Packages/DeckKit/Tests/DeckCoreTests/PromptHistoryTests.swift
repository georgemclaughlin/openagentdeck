//
//  PromptHistoryTests.swift · Tests/DeckCoreTests
//
// The last N prompts. The lane retains a capped, provenanced
// history (the bounded-memory rule's bound, the provenance rule's sourcing);
// the frame carries the N the user asked for (a projection decision, because
// the renderer decides nothing); and a replayed permutation lands on one
// history, because the order is event time, never arrival.
//

import Testing
@testable import DeckCore

struct PromptHistoryTests {

    private func prompt(_ text: String, at ms: Int64,
                        session: SessionID = SessionID("s1")) -> DeckEvent {
        .hook(HookEvent(id: EventID("p-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                        kind: .userPromptSubmit, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent,
                        prompt: Redacted(text)))
    }

    @Test("prompts accumulate newest-first and the newest stays the prompt of record")
    func historyAccumulatesNewestFirst() {
        let state = Reducer.run([prompt("first", at: 1_000),
                                 prompt("second", at: 2_000),
                                 prompt("third", at: 3_000)])
        let lane = state.lanes[SessionID("s1")]
        #expect(lane?.prompts.map(\.value.value) == ["third", "second", "first"])
        // The existing single-prompt slot is untouched by the history: it is
        // the newest, same as ever, so nothing downstream re-learns anything.
        #expect(lane?.prompt?.value.value == "third")
    }

    @Test("the history is capped at the lane cap and counted as retained")
    func historyIsBoundedAndCounted() {
        let events = (1...20).map { prompt("p\($0)", at: Int64($0) * 1_000) }
        let state = Reducer.run(events)
        let lane = state.lanes[SessionID("s1")]
        #expect(lane?.prompts.count == LaneRecord.historyCap)
        // Newest survive, oldest fall off.
        #expect(lane?.prompts.first?.value.value == "p20")
        #expect(lane?.prompts.last?.value.value == "p\(20 - LaneRecord.historyCap + 1)")
        // The bound is observable, so growth is a number a test can
        // watch rather than a leak a profiler finds.
        #expect(state.retainedItems >= LaneRecord.historyCap)
    }

    @Test("a re-delivered prompt does not lengthen the history")
    func redeliveryIsIdempotent() {
        let once = Reducer.run([prompt("hello", at: 1_000)])
        let twice = Reducer.run([prompt("hello", at: 1_000),
                                 prompt("hello", at: 1_000)])
        #expect(once.lanes[SessionID("s1")]?.prompts.count == 1)
        #expect(twice == once)
    }

    @Test("a replayed permutation lands on one history")
    func permutationLandsOnOneHistory() {
        let events = [prompt("a", at: 1_000), prompt("b", at: 2_000),
                      prompt("c", at: 3_000), prompt("d", at: 4_000)]
        let forward = Reducer.run(events)
        let backward = Reducer.run(events.reversed())
        let shuffled = Reducer.run([events[2], events[0], events[3], events[1]])
        #expect(forward == backward)
        #expect(forward == shuffled)
        #expect(forward.lanes[SessionID("s1")]?.prompts.map(\.value.value)
                == ["d", "c", "b", "a"])
    }

    @Test("the frame carries the N the user asked for, newest first, provenanced")
    func frameCarriesTheAskedForWindow() {
        var state = Reducer.run((1...6).map { prompt("p\($0)", at: Int64($0) * 1_000) })
        _ = Reducer.reduce(&state, .prefsChanged({
            var p = DeckPrefs.firstRun; p.promptHistory = 2; return p
        }(), at: .start))

        let frame = Projection.frame(from: state, at: Instant(sinceStart: Millis(10_000)))
        let lane = frame.lanes.first
        #expect(lane?.prompts.map(\.value) == ["p6", "p5"])
        // A non-empty history names the event behind its newest entry.
        #expect(lane?.sources["prompts"] == EventID("p-6000"))
        #expect(frame.unprovenancedFields.isEmpty)

        // The default asks for three.
        var untouched = state
        _ = Reducer.reduce(&untouched, .prefsChanged(.firstRun, at: .start))
        let defaulted = Projection.frame(from: untouched, at: Instant(sinceStart: Millis(10_000)))
        #expect(defaulted.lanes.first?.prompts.count == DeckPrefs.defaultPromptHistory)
    }

    @Test("a lane with no prompts carries an empty history and no provenance for it")
    func emptyHistoryClaimsNothing() {
        let state = Reducer.run([.hook(HookEvent(id: EventID("s"), at: .start,
                                                 kind: .sessionStart, session: SessionID("s9"),
                                                 cwd: nil, tool: nil, toolUseID: nil, held: .absent))])
        let lane = Projection.frame(from: state, at: .start).lanes.first
        #expect(lane?.prompts.isEmpty == true)
        #expect(lane?.sources["prompts"] == nil)
    }

    // ---------------------------------------------------- machine turns (PromptProvenance)
    //
    // The defect: Claude Code fires UserPromptSubmit for a MACHINE-injected
    // turn — a background task waking the session back up — with no
    // distinguishing envelope metadata on the wire, so `DeckState.apply`
    // absorbed it exactly like a person's own words and a robot wake-up
    // became the card's own LAST USER PROMPT. `PromptProvenance.classify(_:)`
    // is the fix; these are its own reducer-level tests, red before it
    // existed.

    /// **Fixture-grade, not wire-recorded.** No hook in this corpus ever
    /// captured a real `<task-notification>` turn — the defect was found by
    /// reading Claude Code's own behaviour, not by a recording of it — so
    /// this is AUTHORED to the documented envelope shape
    /// (`<task-notification>` wrapping `<task-id>`/`<tool-use-id>`, the
    /// shape `PromptProvenance`'s own file doc states was verified) rather
    /// than lifted from a captured payload, the same honesty `Corpus
    /// .planModeQuestionPayload`'s own doc comment already models for a
    /// fixture assembled rather than captured. Multi-line and full-shaped on
    /// purpose — a classifier tested only against its own shortest possible
    /// match (`"<task-notification>"` alone) would not prove the EXACT-
    /// PREFIX rule against a real envelope's own trailing bytes.
    static let taskNotificationFixture = """
        <task-notification>
        <task-id>bg-task-7f3a1c</task-id>
        <tool-use-id>toolu_01A2B3C4D5E6F7G8H9J0K1L2</tool-use-id>
        <status>completed</status>
        The background task finished. Its output is available below.
        </task-notification>
        """

    private func machineTurn(at ms: Int64, session: SessionID = SessionID("s1")) -> DeckEvent {
        .hook(HookEvent(id: EventID("mt-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                        kind: .userPromptSubmit, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent,
                        prompt: Redacted(Self.taskNotificationFixture)))
    }

    /// **The red-first case.** A REAL turn — the session genuinely woke up,
    /// `.working`/`lastPromptAt` both fire — but a machine-classified one,
    /// so its TEXT must never become an identity fact: not `lane.prompt`,
    /// not the history. **Confirmed genuinely red before the fix, not
    /// assumed:** four of the six expectations below fail against the
    /// pre-fix reducer — the fixture's own bytes show up as `lane.prompt`,
    /// lengthen the history, AND overwrite the human prompt that came
    /// before it (the SAME defect read three ways, not three separate
    /// bugs) — while the LAST two (`.working`/`lastPromptAt`) already pass,
    /// because the turn IS real. That asymmetry is exactly what the fix has
    /// to preserve rather than accidentally correct by suppressing the
    /// whole event.
    @Test("a machine-injected task-notification turn never becomes the prompt of record, but still moves the lane")
    func machineTurnNeverBecomesThePromptOfRecord() {
        let state = Reducer.run([prompt("what should I fix next?", at: 1_000),
                                 machineTurn(at: 2_000)])
        let lane = state.lanes[SessionID("s1")]

        // Four assertions that must go RED against the pre-fix code — the
        // same defect read three ways (the envelope becomes the prompt of
        // record, lengthens the history, and overwrites the human prompt
        // that came before it), confirmed by an actual pre-fix run, not
        // assumed.
        #expect(lane?.prompt?.value.value != Self.taskNotificationFixture,
                "the machine envelope became the lane's own prompt of record")
        #expect(lane?.prompts.contains(where: { $0.value.value == Self.taskNotificationFixture }) != true,
                "the machine envelope lengthened the prompt history")
        // The human turn from before it stays the prompt of record — the
        // machine turn did not overwrite it with nothing, it simply
        // declined to overwrite it with itself.
        #expect(lane?.prompt?.value.value == "what should I fix next?")
        #expect(lane?.prompts.map(\.value.value) == ["what should I fix next?"])

        // The two assertions that were already true — a machine turn is
        // still a REAL turn, and must keep behaving like one.
        #expect(lane?.state == .working,
                "a machine-injected turn must still move the lane to working, same as any UserPromptSubmit")
        #expect(lane?.lastPromptAt == Instant(sinceStart: Millis(2_000)),
                "a machine-injected turn must still advance lastPromptAt — the idle pair still needs it")
    }

    // ------------------------------------- the context-compaction summary
    //
    // The transcript-well backfill's own investigation: after the harness
    // compacts a session's context, it injects a user-role turn that is
    // ITS OWN summary of the conversation so far, prose rather than a tag,
    // but the identical "the machine narrating to itself" shape every
    // other entry in the closed set already covers.

    /// **RECORDED, not authored — the leading 87 bytes are byte-exact from
    /// a real transcript; everything past that point is scrubbed.** Found
    /// by grepping every `.jsonl` transcript file under
    /// `~/.claude/projects/-Users-dev-workspace-openagentdeck/`
    /// for `type == "user"` rows whose `message.content` (a plain string
    /// for this shape) starts with "This session is being continued" — 16
    /// occurrences across 8 files. Computing the LONGEST COMMON PREFIX
    /// across all 16 gave exactly 165 bytes before wording started to
    /// differ between Claude Code versions ("**Primary Request and
    /// Intent:**" vs "Primary Request and Intent:", a bold-markdown
    /// change) — comfortably more than the 87-byte leading SENTENCE this
    /// fixture (and `PromptProvenance`'s own closed-set entry) actually
    /// use. The body below this point is NOT any real transcript's own
    /// text — every real occurrence found is several KB of this repo's
    /// own prior conversation history, which is exactly the class of
    /// content the privacy absolute forbids a fixture from carrying
    /// verbatim — so it is replaced with generic, structurally similar
    /// prose past the stable prefix, the same "keep the exact shape,
    /// scrub the content" discipline `taskNotificationFixture` just above
    /// documents for its own (authored) case, applied here to a RECORDED
    /// one instead.
    ///
    /// **A structural signal was ALSO found, and deliberately NOT used
    /// here.** Every one of the 16 occurrences carries a top-level
    /// `isCompactSummary: true` on the JSONL row itself — a perfect,
    /// zero-exceptions correlate, checked against all 7,699 user-role
    /// rows in the corpus (16 true, all 16 exactly the continuation
    /// shape; 0 false positives, 0 false negatives). That field lives on
    /// the FILE's own JSON row, never on a live hook's wire payload
    /// (`PromptProvenance`'s own file doc: "no `isMeta` flag, no separate
    /// hook kind" — true of `isCompactSummary` too), so it could only ever
    /// help `TranscriptTail`'s own file-side parsing, never this
    /// classifier, which exists to answer the SAME question for live
    /// `UserPromptSubmit` text that carries no such field at all. Filed
    /// as a `TranscriptTail`-level finding, not folded in here.
    static let contextCompactionSummaryFixture = """
        This session is being continued from a previous conversation that ran out of context. \
        The summary below covers the earlier portion of the conversation.

        Summary:
        1. Primary Request and Intent:

           The user asked for a series of changes to an example project, escalating from a \
        small UI fix to a broader refactor across several files.

        2. Key Technical Concepts:

           Placeholder technical concepts, standing in for whatever a real compacted summary \
        would name.
        """

    /// **The red-first case, the SAME shape `machineTurnNeverBecomesThePromptOfRecord` above
    /// holds `<task-notification>` to.** A compaction summary is injected mid-session — the
    /// session genuinely continues (`.working`/`lastPromptAt` both fire) — but its TEXT must
    /// never become an identity fact, for the identical reason a task notification's must not.
    @Test("a context-compaction summary never becomes the prompt of record, but still moves the lane")
    func contextCompactionSummaryNeverBecomesThePromptOfRecord() {
        let machineTurn: (Int64) -> DeckEvent = { ms in
            .hook(HookEvent(id: EventID("cc-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                            kind: .userPromptSubmit, session: SessionID("s1"), cwd: nil,
                            tool: nil, toolUseID: nil, held: .absent,
                            prompt: Redacted(Self.contextCompactionSummaryFixture)))
        }
        let state = Reducer.run([prompt("what should I fix next?", at: 1_000), machineTurn(2_000)])
        let lane = state.lanes[SessionID("s1")]

        #expect(lane?.prompt?.value.value != Self.contextCompactionSummaryFixture,
                "the compaction summary became the lane's own prompt of record")
        #expect(lane?.prompts.contains(where: { $0.value.value == Self.contextCompactionSummaryFixture }) != true,
                "the compaction summary lengthened the prompt history")
        #expect(lane?.prompt?.value.value == "what should I fix next?")
        #expect(lane?.state == .working,
                "a compaction summary must still move the lane to working, same as any UserPromptSubmit")
        #expect(lane?.lastPromptAt == Instant(sinceStart: Millis(2_000)),
                "a compaction summary must still advance lastPromptAt — the idle pair still needs it")
    }

    /// **The classifier's own boundary — never a substring, never a generic
    /// `<`-prefix guess.** A person's own words that happen to CONTAIN an
    /// envelope tag mid-sentence, or that start with `<` for some unrelated
    /// reason, must still reach the card — only an EXACT leading match
    /// against the closed set counts.
    @Test("PromptProvenance classifies by exact leading prefix only, never a substring or a generic angle-bracket guess",
          arguments: [
            ("<task-notification>\n<task-id>x</task-id>", PromptProvenance.machine, "the real shape, minimal"),
            ("  \n<task-notification>\nleading whitespace", PromptProvenance.machine,
             "leading whitespace before the envelope still matches, trimmed first"),
            ("[Request interrupted by user]", PromptProvenance.machine, "the plain-text interruption notice"),
            ("<teammate-message>\nfrom another agent on the team", PromptProvenance.machine,
             "a relay from a teammate agent — the same nobody-typed-this shape one door over"),
            ("<local-command-caveat>\nsome caveat text", PromptProvenance.machine,
             "one of the three local-slash-command envelope pieces"),
            ("<command-name>/compact</command-name>", PromptProvenance.machine,
             "a second local-slash-command envelope piece — its own leading tag"),
            ("<local-command-stdout>\nthe command's own output", PromptProvenance.machine,
             "the third local-slash-command envelope piece"),
            ("please read <task-notification> and tell me what it means", PromptProvenance.human,
             "the tag appears mid-sentence, not as a leading envelope — a substring rule would wrongly flag this"),
            ("<taskrunner>not the real tag</taskrunner>", PromptProvenance.human,
             "starts with `<` but is not one of the six recorded shapes — a generic prefix guess would wrongly flag this"),
            ("<task-notification-ish>close but not exact</task-notification-ish>", PromptProvenance.human,
             "shares a prefix with the real tag but is not an exact match to it"),
            ("Continue", PromptProvenance.human, "an ordinary deck-sent payload"),
            ("This session is being continued from a previous conversation that ran out of context. "
                + "The summary below covers the earlier portion of the conversation.",
             PromptProvenance.machine, "the context-compaction summary — the seventh recorded shape"),
            ("  \nThis session is being continued from a previous conversation that ran out of context.",
             PromptProvenance.machine, "leading whitespace before the summary still matches, trimmed first"),
            ("This session is a continuation of nothing in particular, just a person's own words that "
                + "happen to start similarly",
             PromptProvenance.human, "shares a few leading words with the summary but is not an exact match to it"),
          ])
    func classifierBoundary(_ text: String, _ expected: PromptProvenance, _ what: String) {
        #expect(PromptProvenance.classify(text) == expected,
                Comment(rawValue: "\(what): \(text.debugDescription) classified as "
                        + "\(PromptProvenance.classify(text)), expected \(expected)"))
    }
}
