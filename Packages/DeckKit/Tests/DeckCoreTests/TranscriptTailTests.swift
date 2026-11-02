//
//  TranscriptTailTests.swift · Tests/DeckCoreTests
//
//  `TranscriptTail.humanPrompts(fromJSONL:cap:)` — the transcript-well
//  backfill's own pure parser, held to the real shapes its own file doc
//  found in this repo's own `~/.claude/projects/…` corpus.
//

import Testing
@testable import DeckCore

struct TranscriptTailTests {

    // ---------------------------------------------------------- fixtures
    //
    // **AUTHORED to the verified real shape, not lifted byte-for-byte from
    // a captured file — the same honesty `PromptHistoryTests
    // .taskNotificationFixture`'s own doc comment models.** Each line's
    // FIELD NAMES, NESTING, and the four `content` SHAPES below are
    // exactly what `TranscriptTail.swift`'s own file doc recorded from a
    // direct read of 18 real transcript files (608 `str`, 7,018
    // `tool_result`, 50 `text`-only, 23 `image`+`text` — every one counted
    // by hand); the SESSION ids, prompt wording, tool output and
    // timestamps below are invented, since the real ones are this
    // project's own conversation history and file paths — exactly what the
    // privacy absolute forbids a fixture from carrying.

    /// A genuine human prompt, `content` as a plain string — the shape 608
    /// of the corpus's real occurrences took.
    private static let humanPromptLine = """
        {"type":"user","message":{"role":"user","content":"add a dark mode toggle to settings"},\
        "uuid":"11111111-1111-1111-1111-111111111111","sessionId":"s1"}
        """

    /// A tool result, echoed back as a `user`-role row — the shape 7,018 of
    /// the corpus's real occurrences took, the overwhelming majority, and
    /// the one this parser must never mistake for a prompt.
    private static let toolResultLine = """
        {"type":"user","message":{"role":"user","content":[{"type":"tool_result",\
        "tool_use_id":"toolu_ABC123","content":"file1.swift\\nfile2.swift","is_error":false}]},\
        "uuid":"22222222-2222-2222-2222-222222222222","sessionId":"s1"}
        """

    /// A synthetic image-clipboard notice — `content` is text-only (no
    /// `image` item) but the row carries `isMeta: true`, the signal this
    /// parser's own file doc found correlates perfectly with "not a
    /// genuine human prompt" across the whole real corpus.
    private static let syntheticImageNoticeLine = """
        {"type":"user","isMeta":true,"message":{"role":"user","content":[{"type":"text",\
        "text":"[Image: source: /var/folders/xx/clipboard-2026-01-01-000000-ABCDEF.png]"}]},\
        "uuid":"33333333-3333-3333-3333-333333333333","sessionId":"s1"}
        """

    /// The terminal's own plain-text interruption notice — text-only,
    /// `isMeta` ABSENT this time (a real recorded pairing: not every
    /// non-prompt row carries the flag), so this specifically exercises
    /// `PromptProvenance.classify(_:)` catching what `isMeta` did not.
    private static let interruptedLine = """
        {"type":"user","message":{"role":"user","content":[{"type":"text",\
        "text":"[Request interrupted by user]"}]},"uuid":"44444444-4444-4444-4444-444444444444","sessionId":"s1"}
        """

    /// A real human prompt with a screenshot attached — `content` is a
    /// list carrying BOTH a `text` item and an `image` item, the shape 23
    /// of the corpus's real occurrences took. The text is the prompt; the
    /// image contributes nothing extractable and must not suppress it.
    private static let promptWithImageLine = """
        {"type":"user","message":{"role":"user","content":[{"type":"text",\
        "text":"the delete should be a button, not a gesture"},{"type":"image"}]},\
        "uuid":"55555555-5555-5555-5555-555555555555","sessionId":"s1"}
        """

    /// The context-compaction summary, `content` as a plain string —
    /// `PromptHistoryTests.contextCompactionSummaryFixture`'s own doc
    /// comment carries the full recorded-prefix investigation; this line
    /// only needs the stable leading sentence to exercise the SAME
    /// closed-set entry from the parser's own side of the boundary.
    private static let compactionSummaryLine = """
        {"type":"user","isCompactSummary":true,"message":{"role":"user",\
        "content":"This session is being continued from a previous conversation that ran out of context. \
        The summary below covers the earlier portion."},\
        "uuid":"66666666-6666-6666-6666-666666666666","sessionId":"s1"}
        """

    /// An assistant turn — never a candidate at all, `type != "user"`.
    private static let assistantLine = """
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"On it."}]},\
        "uuid":"77777777-7777-7777-7777-777777777777","sessionId":"s1"}
        """

    // -------------------------------------------------------------- tests

    @Test("a genuine human prompt survives")
    func humanPromptSurvives() {
        let result = TranscriptTail.humanPrompts(fromJSONL: Self.humanPromptLine)
        #expect(result.map(\.value) == ["add a dark mode toggle to settings"])
    }

    @Test("a tool-result row — the overwhelming majority shape in a real file — is never mistaken for a prompt")
    func toolResultIsExcluded() {
        let result = TranscriptTail.humanPrompts(fromJSONL: Self.toolResultLine)
        #expect(result.isEmpty)
    }

    @Test("a synthetic isMeta notice is excluded even though PromptProvenance's own closed set has no tag for its text")
    func syntheticMetaNoticeIsExcluded() {
        let result = TranscriptTail.humanPrompts(fromJSONL: Self.syntheticImageNoticeLine)
        #expect(result.isEmpty)
    }

    @Test("the plain-text interruption notice is excluded by PromptProvenance even without an isMeta flag")
    func interruptedNoticeIsExcluded() {
        let result = TranscriptTail.humanPrompts(fromJSONL: Self.interruptedLine)
        #expect(result.isEmpty)
    }

    @Test("a real prompt with an attached image still extracts its own text")
    func promptWithImageExtractsText() {
        let result = TranscriptTail.humanPrompts(fromJSONL: Self.promptWithImageLine)
        #expect(result.map(\.value) == ["the delete should be a button, not a gesture"])
    }

    @Test("the context-compaction summary is excluded, the same closed-set entry PromptHistoryTests holds on the reducer side")
    func compactionSummaryIsExcluded() {
        let result = TranscriptTail.humanPrompts(fromJSONL: Self.compactionSummaryLine)
        #expect(result.isEmpty)
    }

    @Test("an assistant row is never a candidate at all")
    func assistantRowIsExcluded() {
        let result = TranscriptTail.humanPrompts(fromJSONL: Self.assistantLine)
        #expect(result.isEmpty)
    }

    @Test("a whole file's worth of every real shape at once — order preserved, only genuine prompts survive")
    func mixedFileExtractsOnlyGenuinePromptsInOrder() {
        let lines = [Self.toolResultLine, Self.humanPromptLine, Self.syntheticImageNoticeLine,
                     Self.interruptedLine, Self.assistantLine, Self.promptWithImageLine,
                     Self.compactionSummaryLine].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["add a dark mode toggle to settings",
                                        "the delete should be a button, not a gesture"])
    }

    // ---------------------------------------------------- leniency (a tail read starts mid-line)

    @Test("a truncated leading line — the ordinary shape of a bounded tail read, not a corrupt file — is silently skipped")
    func truncatedLeadingLineIsSkippedNotFatal() {
        let truncated = #"session":"s1"}"#  // the tail end of some earlier line, cut mid-object
        let lines = [truncated, Self.humanPromptLine].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["add a dark mode toggle to settings"],
                "a malformed leading line must not prevent a well-formed line after it from being read")
    }

    @Test("blank lines between records are tolerated")
    func blankLinesAreTolerated() {
        let lines = "\n\n" + Self.humanPromptLine + "\n\n" + Self.humanPromptLine.replacingOccurrences(
            of: "add a dark mode toggle to settings", with: "second prompt") + "\n\n"
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["add a dark mode toggle to settings", "second prompt"])
    }

    @Test("a line that is syntactically valid JSON but not an object is skipped, not fatal")
    func nonObjectTopLevelJSONIsSkipped() {
        let lines = ["[1, 2, 3]", "\"just a string\"", "42", Self.humanPromptLine].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["add a dark mode toggle to settings"])
    }

    // ---------------------------------------------------------------- cap

    private static func promptLine(_ text: String) -> String {
        #"{"type":"user","message":{"role":"user","content":""# + text + #""}}"#
    }

    @Test("more candidates than the cap keeps the NEWEST, file order preserved, newest last")
    func capKeepsNewestFileOrderPreserved() {
        let lines = (1...12).map { Self.promptLine("prompt \($0)") }.joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines, cap: 8)
        #expect(result.count == 8)
        #expect(result.map(\.value) == (5...12).map { "prompt \($0)" },
                "expected the last 8 of 12, oldest-of-the-kept first, newest last")
    }

    @Test("fewer candidates than the cap keeps them all")
    func underCapKeepsEverything() {
        let lines = (1...3).map { Self.promptLine("prompt \($0)") }.joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines, cap: 8)
        #expect(result.map(\.value) == ["prompt 1", "prompt 2", "prompt 3"])
    }

    @Test("the default cap is LaneRecord.historyCap — one derivation, not a second restated number")
    func defaultCapMatchesLaneRecordHistoryCap() {
        let lines = (1...12).map { Self.promptLine("prompt \($0)") }.joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.count == LaneRecord.historyCap)
    }

    @Test("an empty file yields no candidates")
    func emptyFileYieldsNothing() {
        #expect(TranscriptTail.humanPrompts(fromJSONL: "").isEmpty)
    }

    @Test("whitespace-only text after trimming is not a candidate")
    func whitespaceOnlyTextIsExcluded() {
        let line = Self.promptLine("   \\n  ")
        #expect(TranscriptTail.humanPrompts(fromJSONL: line).isEmpty)
    }

    // -------------------------------------------------------- dead-branch pruning
    //
    // **`humanPrompts(fromJSONL:cap:)`'s own tree rule — `liveBranches(of:)`'s
    // own doc comment (`TranscriptTail.swift`) carries the full
    // investigation this section holds accountable: the three real
    // contested slots found in the live 44MB file, why adjacent-text
    // dedup was rejected (slot 3, the `/compact` shape), why a whole-file
    // parent-chain walk was rejected (the 441-row compaction break), and
    // why the surviving rule is local and window-stable.**

    /// `promptLine(_:)`'s own tree-aware twin — carries `uuid` and
    /// `parentUuid` so a fixture can build the SIBLING shape the live
    /// file's own contested slots take. `parentUuid: nil` writes JSON
    /// `null`, never an absent key — `absentParentIsNeverGrouped` below
    /// is the one fixture that needs the key missing entirely, built by
    /// hand for that reason.
    private static func promptRow(_ text: String, uuid: String, parentUuid: String?) -> String {
        let parentJSON = parentUuid.map { "\"\($0)\"" } ?? "null"
        return #"{"type":"user","message":{"role":"user","content":""# + text
            + #""},"uuid":""# + uuid + #"","parentUuid":"# + parentJSON + "}"
    }

    @Test("a same-parent, IDENTICAL-text retry keeps only the newest sibling")
    func sameParentIdenticalTextRetryKeepsNewest() {
        // Slot 1 from the live file's own investigation — "2 major ux
        // improvements…", two rows, the same parent, the same words.
        let lines = [
            Self.promptRow("2 major ux improvements to consider", uuid: "a1", parentUuid: "p1"),
            Self.promptRow("2 major ux improvements to consider", uuid: "a2", parentUuid: "p1"),
        ].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["2 major ux improvements to consider"],
                Comment(rawValue: "the earlier sibling (the dead retry) must not survive alongside the later "
                        + "one — got \(result.map(\.value))"))
    }

    @Test("a same-parent, DIFFERENT-text supersede keeps only the newest — the /compact shape that disproves text dedup")
    func sameParentDifferentTextSupersedeKeepsNewest() {
        // Slot 3 — the one that makes adjacent-IDENTICAL-text dedup the
        // WRONG fix. An abandoned message and the "/compact" that
        // superseded it: different words, the same parent. A text-dedup
        // rule sees two unrelated sentences and keeps both; the tree
        // rule sees one live branch.
        let lines = [
            Self.promptRow("actually let's try a different approach here", uuid: "b1", parentUuid: "p2"),
            Self.promptRow("/compact", uuid: "b2", parentUuid: "p2"),
        ].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["/compact"],
                Comment(rawValue: "the abandoned message must not survive alongside its own supersession — a "
                        + "text-dedup rule would have kept both, since the two do not read the same — got "
                        + "\(result.map(\.value))"))
    }

    @Test("a null parentUuid never groups two candidates together")
    func nullParentIsNeverGrouped() {
        let lines = [
            Self.promptRow("first standalone prompt", uuid: "c1", parentUuid: nil),
            Self.promptRow("second standalone prompt", uuid: "c2", parentUuid: nil),
        ].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["first standalone prompt", "second standalone prompt"],
                Comment(rawValue: "both should survive — an explicit JSON null parent must never be treated "
                        + "as a shared sibling group — got \(result.map(\.value))"))
    }

    @Test("an absent parentUuid key never groups two candidates together — the same rule as an explicit null")
    func absentParentIsNeverGrouped() {
        // No `parentUuid` key at all, on either row — `.stringValue`'s
        // own collapsing of absent-and-null (`humanPrompts(fromJSONL:cap:)`'s
        // own doc comment on the call site that reads it) means this
        // must behave identically to `nullParentIsNeverGrouped` above.
        let rowWithoutParent = { (text: String, uuid: String) in
            #"{"type":"user","message":{"role":"user","content":""# + text + #""},"uuid":""# + uuid + "\"}"
        }
        let lines = [rowWithoutParent("first standalone prompt", "e1"),
                     rowWithoutParent("second standalone prompt", "e2")].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["first standalone prompt", "second standalone prompt"],
                Comment(rawValue: "both should survive — a MISSING parentUuid key must never be treated as a "
                        + "shared sibling group — got \(result.map(\.value))"))
    }

    @Test("dead-branch pruning happens BEFORE the cap — a real prompt is not crowded out of the suffix by dead siblings")
    func deadBranchPruningHappensBeforeTheCap() {
        // A real prompt FIRST, then MORE dead retries (same parent, only
        // the LAST survives pruning) than the cap. If pruning ran AFTER
        // `.suffix(cap)` instead of before it, the raw suffix would
        // already be nothing but dead retries by the time pruning ever
        // saw it, and the real prompt would never reach the result.
        var lines = [Self.promptRow("the real prompt, early in the file", uuid: "real1", parentUuid: nil)]
        for i in 0..<9 {
            lines.append(Self.promptRow("retry attempt \(i)", uuid: "r\(i)", parentUuid: "shared-parent"))
        }
        let result = TranscriptTail.humanPrompts(fromJSONL: lines.joined(separator: "\n"), cap: 8)
        #expect(result.map(\.value) == ["the real prompt, early in the file", "retry attempt 8"],
                Comment(rawValue: "expected pruning BEFORE the cap to leave the real prompt in — a "
                        + "prune-after-cap bug would already have dropped it inside a raw 8-item suffix of "
                        + "nothing but dead retries — got \(result.map(\.value))"))
    }

    @Test("genuinely distinct prompts that happen to share text, under DIFFERENT parents, both survive")
    func distinctPromptsSameTextDifferentParentsBothSurvive() {
        // "/compact typed twice today" — two REAL, unrelated turns that
        // happen to read the same, each its own parent. The tree rule
        // must never conflate "same text" with "same branch".
        let lines = [
            Self.promptRow("/compact", uuid: "d1", parentUuid: "parent-morning"),
            Self.promptRow("/compact", uuid: "d2", parentUuid: "parent-afternoon"),
        ].joined(separator: "\n")
        let result = TranscriptTail.humanPrompts(fromJSONL: lines)
        #expect(result.map(\.value) == ["/compact", "/compact"],
                Comment(rawValue: "two genuinely distinct prompts under different parents must both survive, "
                        + "even sharing text — got \(result.map(\.value))"))
    }

    // -------------------------------------------------------- backfill ladder

    /// **`backfillWindows(fileSize:)`'s own worked table — every shape its
    /// own doc comment names, held to literal numbers.** `nil` (unknown
    /// size): the raw ladder, unclamped. A file smaller than the floor:
    /// one rung, clamped exactly to the file's own size — the shape a
    /// quiet, short session's own transcript takes. Mid-size: clamping
    /// stops the ladder EARLY, at the file's own size, rather than
    /// listing rungs past it. A giant file, past the 64MB ceiling: all
    /// four rungs survive unclamped — the honest "seeds fewer than the
    /// cap past this depth" case.
    @Test("backfillWindows worked table",
          arguments: [
            (nil, [262_144, 2_097_152, 16_777_216, 67_108_864],
             "unknown size falls back to the full, un-clamped ladder"),
            (0, [0], "an empty file collapses every rung to a single zero-byte read"),
            (1000, [1000], "smaller than the floor: one rung, clamped to the file's own size"),
            (262_144, [262_144], "exactly the floor: one rung — the floor already covers the whole file"),
            (5_000_000, [262_144, 2_097_152, 5_000_000],
             "mid-size: the ladder stops AT the file's own size, one rung short of the full four"),
            (67_108_864, [262_144, 2_097_152, 16_777_216, 67_108_864],
             "exactly the ceiling: all four rungs, the last one landing on the file's own size by coincidence"),
            (100_000_000, [262_144, 2_097_152, 16_777_216, 67_108_864],
             "past the ceiling: all four rungs, UNCLAMPED — the ceiling never binds past its own size"),
          ])
    func backfillWindowsWorkedTable(_ fileSize: Int?, _ expected: [Int], _ what: String) {
        let got = TranscriptTail.backfillWindows(fileSize: fileSize)
        #expect(got == expected, Comment(rawValue: "\(what) — got \(got), expected \(expected)"))
    }

    @Test("the ladder's own floor rung is exactly backfillFloorBytes, restated as a literal")
    func floorRungMatchesTheNamedConstant() {
        #expect(TranscriptTail.backfillWindows(fileSize: nil).first == TranscriptTail.backfillFloorBytes)
        #expect(TranscriptTail.backfillFloorBytes == 256 * 1_024,
                Comment(rawValue: "got \(TranscriptTail.backfillFloorBytes)"))
    }

    @Test("a negative fileSize (never a real answer, but never trusted blindly either) floors to a single zero-byte rung")
    func negativeFileSizeNeverProducesANegativeRung() {
        let got = TranscriptTail.backfillWindows(fileSize: -5)
        #expect(got == [0], Comment(rawValue: "got \(got)"))
    }

    // -------------------------------------------------- the session's last word
    //
    // **`apiErrorLastWord(fromJSONL:)` — held to the real specimen shapes
    // `TranscriptTail.swift`'s own file doc cites (the clean hook-probe
    // transcript, read directly for row SHAPE, never copied from it
    // byte-for-byte — the same authored-not-lifted discipline this file's
    // own top doc states for `humanPrompts`'s own fixtures).** Session ids
    // and timestamps below are invented; the two ERROR STRINGS are Claude
    // Code's own product copy — not user content — and are pinned
    // verbatim, the privacy absolute's own carve-out for exactly this
    // class of string.

    /// The 529 specimen, quoted verbatim from a live occurrence
    /// — dialog parity's own receipt: the deck relays this
    /// exact sentence, never a paraphrase of it.
    private static let overloadedText =
        "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. "
        + "If it persists, check https://status.claude.com."

    /// The 401 specimen — the real recorded pairing with an ABSENT
    /// `apiErrorStatus` key (the probe's own row carries no such field at
    /// all), which `apiErrorStatusAbsentStillFinds` below holds
    /// accountable directly.
    private static let authExpiredText =
        "Please run /login · API Error: 401 OAuth access token has expired. Re-authenticate to continue."

    private static func userRow(_ text: String, timestamp: String, isSidechain: Bool = false) -> String {
        #"{"type":"user","isSidechain":"# + (isSidechain ? "true" : "false")
            + #","message":{"role":"user","content":""# + text
            + #""},"timestamp":""# + timestamp + "\"}"
    }

    private static func errorRow(_ text: String, timestamp: String, isSidechain: Bool = false,
                                 includeStatus: Bool = true) -> String {
        let status = includeStatus ? #","apiErrorStatus":529"# : ""
        return #"{"type":"assistant","isSidechain":"# + (isSidechain ? "true" : "false")
            + #","message":{"role":"assistant","model":"<synthetic>","content":[{"type":"text","text":""#
            + text + #""}]},"error":"server_error","isApiErrorMessage":true"# + status
            + #","timestamp":""# + timestamp + "\"}"
    }

    /// A row shape that is never a candidate at all — `attachment`,
    /// `system`, `queue-operation`, `file-history-snapshot` all take this
    /// same minimal shape as far as this parser is concerned: `type`
    /// alone already disqualifies them before anything else about the row
    /// is read.
    private static func nonMessageRow(type: String, timestamp: String) -> String {
        #"{"type":""# + type + #"","timestamp":""# + timestamp + "\"}"
    }

    @Test("the 529 specimen as the latest row surfaces verbatim — dialog parity's own receipt")
    func the529SpecimenIsFoundVerbatim() {
        let line = Self.errorRow(Self.overloadedText, timestamp: "2026-08-13T16:00:00.000Z")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: line)?.value == Self.overloadedText)
    }

    @Test("an error row physically LAST loses to a user row that is chronologically NEWER — file order is not recency")
    func physicallyLastErrorLosesToATimestampNewerUserRow() {
        // The user row sits FIRST in the file yet carries the LATER
        // timestamp — the flush-disorder fact 3's own evidence proves
        // happens, exercised in the direction that must produce nil.
        let lines = [
            Self.userRow("trying again", timestamp: "2026-08-13T16:00:05.000Z"),
            Self.errorRow(Self.overloadedText, timestamp: "2026-08-13T16:00:01.000Z"),
        ].joined(separator: "\n")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: lines) == nil,
                "the error is physically last but chronologically OLDER than the user row before it — the retry already superseded it")
    }

    @Test("an error row physically FIRST still wins by timestamp — the probe's own recorded shape")
    func physicallyFirstErrorWinsByTimestamp() {
        // The exact shape the live probe recorded: the synthetic error row
        // (timestamp 16:17:15.049) physically precedes the user row that
        // caused it (16:17:14.579) — the error is chronologically LATER
        // despite landing first on disk.
        let lines = [
            Self.errorRow(Self.overloadedText, timestamp: "2026-08-13T16:17:15.049Z"),
            Self.userRow("say hi", timestamp: "2026-08-13T16:17:14.579Z"),
        ].joined(separator: "\n")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: lines)?.value == Self.overloadedText)
    }

    @Test("a sidechain's own error row is never the session's last word")
    func sidechainErrorRowIsExcluded() {
        let line = Self.errorRow(Self.overloadedText, timestamp: "2026-08-13T16:00:00.000Z", isSidechain: true)
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: line) == nil,
                "a subagent's own death must never be read as the session's own last word")
    }

    @Test("apiErrorStatus absent still finds the error — detection keys on the boolean, never the status")
    func apiErrorStatusAbsentStillFinds() {
        let line = Self.errorRow(Self.authExpiredText, timestamp: "2026-08-13T16:00:00.000Z", includeStatus: false)
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: line)?.value == Self.authExpiredText)
    }

    @Test("trailing attachment/system/queue-operation/file-history-snapshot rows after the error change nothing")
    func trailingNonMessageRowsDoNotSupersedeTheError() {
        let lines = ([Self.errorRow(Self.overloadedText, timestamp: "2026-08-13T16:00:00.000Z")]
            + ["attachment", "system", "queue-operation", "file-history-snapshot"].enumerated().map { i, type in
                Self.nonMessageRow(type: type, timestamp: "2026-08-13T16:00:0\(i + 1).000Z")
            }).joined(separator: "\n")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: lines)?.value == Self.overloadedText,
                "none of these rows carry type \"user\" or \"assistant\" — they are never candidates, however new their own timestamps are")
    }

    @Test("malformed lines interleaved around the error row are silently skipped")
    func malformedLinesAreLenientAroundTheErrorRow() {
        let lines = [#"{"broken"#, Self.errorRow(Self.overloadedText, timestamp: "2026-08-13T16:00:00.000Z"),
                     "not json at all", "[1, 2, 3]"].joined(separator: "\n")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: lines)?.value == Self.overloadedText)
    }

    @Test("an empty file yields nil")
    func emptyFileYieldsNilApiError() {
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: "") == nil)
    }

    @Test("a tail window with zero message rows — only non-message rows present — yields nil, honestly")
    func zeroMessageRowsYieldsNilApiError() {
        let lines = [Self.nonMessageRow(type: "attachment", timestamp: "2026-08-13T16:00:00.000Z"),
                     Self.nonMessageRow(type: "system", timestamp: "2026-08-13T16:00:01.000Z")].joined(separator: "\n")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: lines) == nil)
    }

    @Test("a user row alone, no error anywhere, yields nil")
    func noErrorAnywhereYieldsNil() {
        let line = Self.userRow("just an ordinary prompt", timestamp: "2026-08-13T16:00:00.000Z")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: line) == nil)
    }

    @Test("an error row superseded by a LATER user row — the retry that already happened")
    func errorSupersededByALaterUserRowYieldsNil() {
        let lines = [Self.errorRow(Self.overloadedText, timestamp: "2026-08-13T16:00:00.000Z"),
                     Self.userRow("okay trying again", timestamp: "2026-08-13T16:00:01.000Z")].joined(separator: "\n")
        #expect(TranscriptTail.apiErrorLastWord(fromJSONL: lines) == nil,
                "a later user row — the user already retried — must supersede the error, not merely coexist with it")
    }

    // --------------------------------------------------------- the recap
    //
    // **Authored to the shape counted out of the real corpus, with
    // invented wording — the same split this file's own fixture doc
    // comment states.** The FIELD NAMES and nesting below are exactly
    // what all 321 real `away_summary` rows carry (`TranscriptTail
    // .swift`'s own recap section records the count and the versions);
    // the summary sentences are invented, since the real ones describe
    // this project's own conversations.

    /// A recap row, at the one shape the corpus ever takes: `type`
    /// `"system"`, `subtype` `"away_summary"`, `content` a plain string.
    private static func recapRow(_ content: String, timestamp: String,
                                 isSidechain: Bool = false) -> String {
        """
        {"type":"system","subtype":"away_summary","content":"\(content)",\
        "timestamp":"\(timestamp)","isSidechain":\(isSidechain),\
        "sessionId":"s1","version":"2.1.251"}
        """
    }

    @Test("a recap row surfaces its own text and its own timestamp")
    func recapSurfaces() {
        let line = Self.recapRow("Goal was wiring the recap into the well; the parser is written and green.",
                                 timestamp: "2026-08-18T02:10:22.343Z")
        let recap = TranscriptTail.latestRecap(fromJSONL: line)
        #expect(recap?.text.value == "Goal was wiring the recap into the well; the parser is written and green.")
        #expect(recap?.iso == "2026-08-18T02:10:22.343Z",
                "the recap's OWN moment is what places it in the ledger and dates it on screen")
    }

    @Test("the trailing (disable recaps in /config) hint is stripped, with the space it left behind")
    func recapHintIsStripped() {
        let line = Self.recapRow("All five phases shipped and deployed. \(TranscriptTail.recapConfigHint)",
                                 timestamp: "2026-08-18T02:10:22.343Z")
        #expect(TranscriptTail.latestRecap(fromJSONL: line)?.text.value == "All five phases shipped and deployed.",
                "the hint points at a /config screen the deck does not have — terminal chrome, not Claude Code's own words about the session")
    }

    @Test("a recap WITHOUT the hint — 280 of the corpus's 321 — is left exactly as written")
    func recapWithoutHintIsUntouched() {
        let line = Self.recapRow("Card colors are now directory-keyed and never auto-duplicate.",
                                 timestamp: "2026-08-18T02:10:22.343Z")
        #expect(TranscriptTail.latestRecap(fromJSONL: line)?.text.value
                    == "Card colors are now directory-keyed and never auto-duplicate.")
    }

    @Test("the NEWEST recap wins by timestamp, never by file order — rows flush out of order")
    func newestRecapWinsByTimestamp() {
        let lines = [Self.recapRow("the newer summary", timestamp: "2026-08-18T05:00:00.000Z"),
                     Self.recapRow("the older summary", timestamp: "2026-08-18T02:00:00.000Z")].joined(separator: "\n")
        #expect(TranscriptTail.latestRecap(fromJSONL: lines)?.text.value == "the newer summary",
                "the older row sits LAST in file order here on purpose — timestamp must decide, not position")
    }

    @Test("a subagent's own recap is never the session's")
    func sidechainRecapIsExcluded() {
        let line = Self.recapRow("a subagent's summary", timestamp: "2026-08-18T02:10:22.343Z", isSidechain: true)
        #expect(TranscriptTail.latestRecap(fromJSONL: line) == nil)
    }

    @Test("a system row that is not an away_summary is never a recap")
    func otherSystemSubtypeIsExcluded() {
        let line = """
            {"type":"system","subtype":"post_tool_use_hook","content":"hook fired",\
            "timestamp":"2026-08-18T02:10:22.343Z","sessionId":"s1"}
            """
        #expect(TranscriptTail.latestRecap(fromJSONL: line) == nil)
    }

    @Test("a recap with no timestamp cannot be placed, so it is not offered")
    func recapWithoutTimestampIsExcluded() {
        let line = """
            {"type":"system","subtype":"away_summary","content":"a summary with no moment","sessionId":"s1"}
            """
        #expect(TranscriptTail.latestRecap(fromJSONL: line) == nil)
    }

    @Test("a recap that is nothing but the hint reduces to nothing, not to a stray space")
    func recapOfOnlyTheHintYieldsNil() {
        let line = Self.recapRow(TranscriptTail.recapConfigHint, timestamp: "2026-08-18T02:10:22.343Z")
        #expect(TranscriptTail.latestRecap(fromJSONL: line) == nil)
    }

    @Test("no recap in the window yields nil — switched off, none yet, or simply out of reach")
    func noRecapYieldsNil() {
        let lines = [Self.humanPromptLine, Self.assistantLine, "", "not json at all"].joined(separator: "\n")
        #expect(TranscriptTail.latestRecap(fromJSONL: lines) == nil)
    }

    @Test("a recap survives the malformed leading line every tail read starts with")
    func recapSurvivesTruncatedLeadingLine() {
        let lines = ["ontent\":\"half a row the tail read cut through\"}",
                     Self.recapRow("the summary after it", timestamp: "2026-08-18T02:10:22.343Z")]
            .joined(separator: "\n")
        #expect(TranscriptTail.latestRecap(fromJSONL: lines)?.text.value == "the summary after it")
    }
}
