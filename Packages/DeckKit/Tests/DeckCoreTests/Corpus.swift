//
//  Corpus.swift · Tests/DeckCoreTests
//
//  Reading recorded bytes off disk, in the test target, because `DeckCore` is
//  not allowed to touch a filesystem. The split is architecture §2's and it is
//  also what makes the replay harness a pure function: events in, frames out.
//
//  The recordings are resources of this test target, resolved through
//  `Bundle.module`. A path walked up from `#filePath` reaches outside the
//  package and makes the suite depend on where the package happens to sit in
//  a repository; a bundled resource travels with the target that reads it.
//

import Foundation
import DeckCore

enum Corpus {

    /// The `Fixtures` directory, copied into this target's resource bundle.
    static let root: URL = {
        guard let url = Bundle.module.resourceURL?.appendingPathComponent("Fixtures") else {
            preconditionFailure("no resource bundle — the fixtures are not built into the target")
        }
        return url
    }()

    static func text(_ relative: String) -> String {
        (try? String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)) ?? ""
    }

    /// Newline-delimited JSON. A line that will not parse is *reported*, not
    /// skipped: An early version shipped a predicate that returned true over a file its
    /// parser could not read, and 14 of 29 corpus files were accepted by it.
    static func ndjson(_ relative: String) -> [JSONValue] {
        let lines = text(relative).split(separator: "\n").map(String.init)
        let parsed = lines.compactMap { JSONValue.parse($0) }
        precondition(parsed.count == lines.count,
                     "\(relative): \(lines.count - parsed.count) of \(lines.count) lines did not parse")
        precondition(!parsed.isEmpty, "\(relative): no rows — the corpus is not where the test thinks it is")
        return parsed
    }

    static func json(_ relative: String) -> JSONValue {
        let value = JSONValue.parse(text(relative))
        precondition(value != nil, "\(relative): did not parse")
        return value!
    }

    // ------------------------------------------------------------ the fixtures
    static var events: [JSONValue]     { ndjson("events.ndjson") }
    static var statusline: [JSONValue] { ndjson("statusline-feed.ndjson") }
    static var fleetS9: JSONValue      { json("S9-agents.json") }
    static var fleetS18: JSONValue     { json("S18-agents.json") }
    /// The fleet reading a permission dialog off `claude agents --json`
    /// itself — `status: "waiting"` with `waitingFor: "permission prompt"` on
    /// `alpha-b5`, alongside a `blocked` background row, an `idle`
    /// interactive row and a `busy` one. Real, live, four shapes in one file.
    static var fleetDialogOpen: JSONValue { json("live/LV36-dialog-open/agents.json") }

    /// The recorded hook stream, decoded into deck events on the deck's own
    /// timeline.
    static func hookEvents() -> [DeckEvent] {
        let rows = events
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }.map(DeckEvent.hook)
    }

    // ------------------------------------------------- the questions nobody used
    //
    // Seven real `AskUserQuestion` calls have been sitting in `events.ndjson`
    // since the spike, cited by no invariant and read by no test, while three
    // planning documents recorded that the deck had "never seen a question".
    // They were found by a census run to check a different claim.

    /// Every recorded `AskUserQuestion` `PreToolUse` payload, newest last.
    static func questionPayloads() -> [JSONValue] {
        events.compactMap { row in
            guard let p = row["payload"],
                  p["tool_name"]?.stringValue == SubjectReader.questionTool,
                  p["hook_event_name"]?.stringValue == "PreToolUse" else { return nil }
            return p
        }
    }

    /// Decoded through the product's own reader, so the fixture exercises the
    /// decoder rather than bypassing it.
    static func recordedQuestionCalls() -> [[Question]] {
        questionPayloads().compactMap { payload in
            guard let rows = payload["tool_input"]?["questions"]?.arrayValue else { return nil }
            let questions = rows.compactMap(QuestionReader.question(from:))
            return questions.count == rows.count ? questions : nil
        }
    }

    /// The one three-question call in the corpus — banner colour, font, density.
    /// The only recorded call with more than one question, which makes it the
    /// only one that can witness the all-or-nothing rule at all.
    static var bannerFontDensity: [Question] {
        let call = recordedQuestionCalls().first { $0.count == 3 }
        precondition(call != nil,
                     "the corpus no longer contains a multi-question AskUserQuestion call")
        return call!
    }

    /// The first live run that answered a question on the deck — 31 payloads,
    /// and the measurement that killed the supervised-tool set.
    static func liveRun() -> [HookEvent] {
        let rows = ndjson("live/LV14-plan/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// The first recorded `AskUserQuestion` call carrying option `preview`
    /// mockups, decoded off REAL wire bytes. `QuestionOption.preview`
    /// existed in the model long before any recording exercised it
    /// (`QuestionWireTests` had to synthesise a fixture-shaped payload by
    /// hand to prove the wire round-trip at all); this is the first corpus
    /// row where the ingest path itself decodes one.
    ///
    /// **How this was recorded, honestly, because the first attempt at this
    /// fixture was not honest about it and got rejected for exactly that.**
    /// A pure-observer hook — stamps `ts` at RECEIPT, records the payload
    /// verbatim plus the CMUX `workspace`/`surface` environment, posts
    /// nothing back to the engine, holds nothing, and deliberately writes no
    /// `held_ms` because it never held anything — was installed alongside
    /// the deck's own hooks, 2026-08-07, and a scratch Claude session
    /// (`bypassPermissions`, in this repo) was driven to reproduce the
    /// original `Preview UI` question. Its `tool_input.questions` verified
    /// canonically identical to the original capture (same values; the two
    /// serializations differ in key order). All 3 rows below are that
    /// observer's rows, value-verbatim — re-encoded from the capture file's
    /// ASCII-escaped serialization to UTF-8, canonically identical against
    /// the preserved capture — with exactly one addition: the
    /// `AskUserQuestion` row carries `held_ms: 53373`, a fact the observer
    /// COULD NOT witness (it holds nothing) and which comes instead from
    /// the deck's own log, running the same session at the same time —
    /// `holdOpened session=b28a5fff… tool=AskUserQuestion` at 11770209 ms,
    /// `answered … toolu_01BEiVAAiDngdBWGJWYhGHNc with 1 of 1` at
    /// 11823582 ms, a span of 53,373 ms. (The engine's own tool_result
    /// stamp trails that answer by ~20 s; 53,373 ms is the deck's witnessed
    /// open→answer span, not the engine's.) The observer was repo-wide, so
    /// the capture also caught the sibling development session's rows; this
    /// file keeps the scratch session's complete lane — all three of its
    /// rows, sequence intact — and nothing else. The user answered that hold
    /// ON the deck — "Side-by-side" — and the answer reached the engine
    /// (the transcript's tool_result reads `="Side-by-side" selected
    /// preview:`), so the number pinned here is the deck's own measurement
    /// of a takeover a person actually closed, not an invented duration.
    ///
    /// The `Read` row (`PreToolUse`, no `held_ms` at all — `Fed.absent`)
    /// opens no hold in replay: `Reducer`'s `.preToolUse` case only opens
    /// one when `held_ms` is present and positive, and the observer wrote
    /// none because it genuinely held nothing. The deck's own log agrees —
    /// no hold span appears for that row either — so replay and the live
    /// deck tell the same story about which of these two `PreToolUse` calls
    /// needed a human. `permission_mode: bypassPermissions` is now a
    /// recorded fact of this session, not an assumption.
    static func questionPreviewRun() -> [HookEvent] {
        let rows = ndjson("live/LV37-question-preview/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// A second, UNRELATED real `AskUserQuestion` call — a different
    /// session (`7b373721-…`, the earlier development session in which the
    /// preview-UI questions above were themselves being designed) from a
    /// different day than `questionPreviewRun()`'s `b28a5fff-…` observer
    /// recording. **Not wire-recorded.** No hook observed this call in
    /// flight; this payload is assembled from that session's own transcript
    /// — the tool's `tool_input.questions` are the transcript's recorded
    /// bytes, verbatim, and the envelope fields (`session_id`,
    /// `transcript_path`, `cwd`, `tool_use_id`, `permission_mode: "plan"`,
    /// the last matching the transcript's own bracketing entries, all of
    /// which read `plan`; `ExitPlanMode` did not fire until 4 minutes
    /// later) are read off that same transcript rather than posted by any
    /// hook. That is exactly why this is a standalone hook PAYLOAD rather
    /// than an ndjson row: there is no receipt-stamped `ts` to put in an
    /// envelope, because nothing received it. Shaped to match what
    /// `HookIngest.event(from:epochBase:)` expects of a payload, so it can
    /// still exercise the question reader against a call with previews on
    /// some options and none on others.
    static var planModeQuestionPayload: JSONValue { json("live/LV37-question-preview/plan-mode-question.json") }

    /// The first `PermissionRequest` recorded WITHOUT a `tool_use_id` — CLI
    /// 2.1.220, caught on camera by the video scenario while the deck waved
    /// through the very event the hold policy names as its subject and the
    /// terminal asked instead. The ingest synthesis is pinned to this row.
    static func permissionRun() -> [HookEvent] {
        let rows = ndjson("live/LVV-permission/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// The usage-limit recording (LV19): healthy turns at 96 %, the
    /// hook-silent refusal at 100 %, and the recovery whose first render still
    /// carried the stale 100 — the row that decides the indicator's
    /// clock-over-feed rule. Hook rows decode through `HookIngest`, statusline
    /// rows through `StatuslineIngest` with the SAME epoch base, so the
    /// windows' deadlines land on the run's own timeline.
    static func usageRun() -> [DeckEvent] {
        let rows = ndjson("live/LV19-usage-limit/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { row in
            guard let epoch = HookIngest.epochBase(rows: [row]) else { return nil }
            let at = Instant(sinceStart: Millis(epoch - base))
            if row["event"]?.stringValue == "statusline" {
                guard let payload = row["payload"],
                      let decoded = StatuslineIngest.payload(from: payload, epochBase: base)
                else { return nil }
                return .statusline(decoded, at: at, id: EventID("sl|\(epoch)"))
            }
            return HookIngest.event(from: row, epochBase: base).map(DeckEvent.hook)
        }
    }

    // --------------------------------------------------------- LV38: never hold questions
    //
    // Recorded live, CLI 2.1.227, 2026-08-11, investigating whether
    // `AskUserQuestion` can be released instantly instead of held — see
    // `Fixtures/live/LV38-question-mirror-PROVENANCE.md` for the full
    // recording methodology and the safety finding (every one of these
    // sessions also reached the real, live deck, because the global hook
    // merges with the scratch project's own). Graduated from candidate
    // fixtures into the corpus proper by the question-mirror arc itself,
    // the design work the investigation's own doc says is still owed.

    /// `SessionStart` through `Notification`, cut off before the answer —
    /// the recorder held this call's `PreToolUse` for an artificial 8 s
    /// before answering `{}`. Demonstrates the hold/release mechanics in
    /// isolation: nothing about the question reaches the terminal screen
    /// for the entire held span.
    static func questionMirrorHeldReleased() -> [HookEvent] {
        let rows = ndjson("live/LV38-question-mirror-held-released/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// The SAME session as `questionMirrorHeldReleased()`, continued
    /// through the terminal answer: a digit `"1"` keystroke, `PostToolUse`
    /// (`tool_input.answers` reads `{"Pick": "Option A"}`, arriving
    /// directly on `tool_input` — NOT nested under an `updatedInput` the
    /// way a deck-authored `hookSpecificOutput` response is shaped), and
    /// `Stop`. The corpus's own answer for "does a hold answered at the
    /// terminal ever retire" — before this arc, nothing here did.
    static func questionMirrorTerminalAnswered() -> [HookEvent] {
        let rows = ndjson("live/LV38-question-mirror-terminal-answered/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// The late-tap simulation (session `4aaca1c7-…`): a digit `"1"` answer
    /// immediately followed by a second, unrelated digit that never
    /// reaches the (already-closed) dialog. `PostToolUse` here is where
    /// "the inert hold" defect gets its RED: fed through the reducer with
    /// no synthetic `.holdExpired` in the stream, the hold this
    /// `PreToolUse` opened is still genuinely open when this `PostToolUse`
    /// arrives — the golden shape for `Resolution.answeredElsewhere`.
    static func questionMirrorRace() -> [HookEvent] {
        let rows = ndjson("live/LV38-question-mirror-race/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// A session with NO project-level hooks — only a global one (in
    /// ~/.claude) fired. `PreToolUse` to `PermissionRequest` measured a 20.033 s gap
    /// here, independent of any hold this reducer opens (nothing in this
    /// six-row file ever resolves a hold) — kept for the readiness-gate's
    /// own timing-agnosticism: `terminalLive` must never assume a
    /// particular gap, and this fixture is the proof that assuming one
    /// would have been wrong. (The PROVENANCE doc's own prose cites a DIFFERENT
    /// number — 120.8 s — for this same session, sourced from two OTHER,
    /// unrecorded sessions its own text describes but does not attach;
    /// this accessor reads the six rows that are actually here, which is
    /// the 20.033 s figure, not the prose's.)
    static func questionMirrorLatencyControl() -> [HookEvent] {
        let rows = ndjson("live/LV38-question-mirror-latency-control/payloads.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// Multi-select, one box checked: `tool_input.answers` reads
    /// `{"Which?": "Option C"}` — a bare string, same shape as
    /// single-select, because only one label was ever chosen.
    static func questionMirrorMultiSelectOnePick() -> [HookEvent] {
        let rows = ndjson("live/LV38-question-mirror-digit-answered/multiselect-one-pick.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// Multi-select, two boxes checked: `tool_input.answers` reads
    /// `{"Pick": "Option A, Option B"}` — a comma-joined STRING, never a
    /// JSON array, contradicting `HookResponse.answered`'s own doc comment
    /// (which describes the DECK'S outbound shape, not the terminal's).
    /// `AnswerReader`'s own golden case.
    static func questionMirrorMultiSelectTwoPicks() -> [HookEvent] {
        let rows = ndjson("live/LV38-question-mirror-digit-answered/multiselect-two-picks.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// The "Other" flow: typed free text becomes the answer value
    /// directly. `tool_input.answers` reads `{"Other": "Hello free text
    /// answer"}` — nothing on the wire marks this as the free-text branch
    /// versus an ordinary label match, which is why `AnswerReader` does
    /// not try to tell the two apart.
    static func questionMirrorOtherFreetext() -> [HookEvent] {
        let rows = ndjson("live/LV38-question-mirror-digit-answered/other-freetext.ndjson")
        guard let base = HookIngest.epochBase(rows: rows) else { return [] }
        return rows.compactMap { HookIngest.event(from: $0, epochBase: base) }
    }

    /// Every session id that literally appears in a recorded payload. The
    /// no-synthesised-lane rule's denominator: a lane outside this set is a
    /// lane the deck invented.
    static func recordedSessions() -> Set<SessionID> {
        var ids = Set<SessionID>()
        for row in events {
            if let s = row["payload"]?["session_id"]?.stringValue, !s.isEmpty { ids.insert(SessionID(s)) }
        }
        for row in statusline {
            if let s = row["session_id"]?.stringValue, !s.isEmpty { ids.insert(SessionID(s)) }
        }
        return ids
    }
}
