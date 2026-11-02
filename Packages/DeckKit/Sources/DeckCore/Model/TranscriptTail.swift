//
//  TranscriptTail.swift · DeckCore/Model
//
//  A pure parser: raw JSONL bytes from a Claude Code session's on-disk
//  transcript file in, two products out, each answering its own question over
//  the same bytes:
//    - the last N human prompts (`humanPrompts(fromJSONL:cap:)`), file order
//      preserved, newest last;
//    - the session's last word, when that word was an API-error message
//      (`apiErrorLastWord(fromJSONL:)`).
//  No filesystem I/O happens here or anywhere in `DeckCore` (the runtime
//  adapter that reads the file lives in `DeckApp`; see
//  `HookEvent.transcriptPath`), so this boundary is testable with ordinary
//  strings rather than fixtures on disk.
//
//  **The row shapes were verified against real transcript files, not assumed
//  from Claude Code's (unpublished) format.** Across 18 transcripts and ~7,700
//  user-role rows, `message.content` on a `type: "user"` row took these shapes:
//
//    - `content: <string>` (608) — a real human-typed prompt, or a
//      machine-injected envelope/notice that `PromptProvenance`'s closed set
//      already catches.
//    - `content: [{type: "tool_result", ...}]` (7,018) — a tool's output echoed
//      back as a "user" turn. Never a prompt; skipped unconditionally.
//    - `content: [{type: "text", ...}, ...]`, no `image` (50) — none were
//      genuine human prompts: either `[Request interrupted by user]`-shaped
//      (already in `PromptProvenance`'s closed set) or synthetic image/skill
//      notices carrying `isMeta: true` on the row.
//    - `content: [{type: "text", ...}, {type: "image"}]` (23) — a REAL prompt
//      with a screenshot attached. The text is the prompt; the image is not
//      decoded (this parser produces text, `Redacted`, nothing else).
//
//  **`isMeta: true` is used here and deliberately NOT folded into
//  `PromptProvenance`.** Every synthetic notice in the sample carried it, and
//  nothing recognisably human ever did. It is a field of the `.jsonl` row only;
//  a live `UserPromptSubmit` hook has no equivalent, so it can help this parser
//  and never the live-wire classifier. Filtering on it ahead of
//  `PromptProvenance.classify(_:)` catches synthetic rows no leading-prefix rule
//  recognises (an image notice has no stable envelope tag) without changing the
//  shared classifier's behaviour on the live hook path.
//
//  **Lenient by design.** A bounded tail read (see `backfillWindows(fileSize:)`
//  for the per-rung bounds) starts mid-file, so it can start mid-line: a
//  truncated leading line is the ORDINARY case, not a corrupt file. Every
//  malformed line (not JSON, not an object, no readable `type`) is silently
//  skipped, the same "skip what cannot be read" discipline
//  `HookIngest.event(from:epochBase:)` applies to hook rows. This holds at
//  every rung of the ladder, not only the shallowest.
//

public enum TranscriptTail {

    /// Parse raw JSONL bytes into the last N human prompts this transcript
    /// carries, file order preserved, newest last — the same convention
    /// `DeckEvent.transcriptSeeded`'s reducer case reads (`Reducer.swift` says why
    /// file order matters there).
    ///
    /// `cap` defaults to `LaneRecord.historyCap`, the ledger's own bound, so a
    /// caller never restates the number the reducer enforces anyway; only
    /// `TranscriptTailTests` overrides it, to test the capping rule without a
    /// fixture `historyCap` lines long.
    public static func humanPrompts(fromJSONL raw: String, cap: Int = LaneRecord.historyCap) -> [Redacted] {
        var candidates: [(text: String, parentUuid: String?)] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = JSONValue.parse(String(line)) else { continue }
            guard row["type"]?.stringValue == "user" else { continue }
            // Checked BEFORE content extraction, so a synthetic notice never reaches
            // `PromptProvenance` to be passed through as human for lack of a matching
            // envelope tag.
            guard row["isMeta"]?.boolValue != true else { continue }
            guard let message = row["message"], message["role"]?.stringValue == "user" else { continue }
            guard let text = candidateText(from: message["content"]) else { continue }
            let trimmed = text.trimmed
            guard !trimmed.isEmpty else { continue }
            guard PromptProvenance.classify(trimmed) == .human else { continue }
            // `.stringValue` collapses ABSENT and JSON `null` to the same `nil`.
            // `liveBranches(of:)` treats them identically on purpose: "no parent
            // recorded" and "parent explicitly null" both mean this row has no sibling
            // group to belong to.
            candidates.append((text: trimmed, parentUuid: row["parentUuid"]?.stringValue))
        }
        return Array(liveBranches(of: candidates).suffix(max(0, cap)))
    }

    // ------------------------------------------------------ the session's last word
    //
    // **A synthetic assistant row, not a hook.** When a turn dies on an API error
    // the CLI appends its own row to the transcript — top-level
    // `isApiErrorMessage: true`, `message.model == "<synthetic>"`, the text at
    // `message.content[0].text` — and this is the ONLY place that fact is recorded
    // (a live probe found no `Stop` and no hook at all at the abort moment; see
    // `DeckRuntime`'s trigger-set doc). This parser lets the deck go LOOKING for
    // that row rather than wait to be told.

    /// The session's own last word, if it was an API-error message —
    /// verbatim, or `nil`.
    ///
    /// **Examines `assistant` rows, which `humanPrompts(fromJSONL:cap:)` drops
    /// unconditionally — a different question, not a relaxed one.** That function
    /// asks what the HUMAN said; this one asks what the SESSION's last recorded
    /// word is, whoever spoke it. A synthetic API-error row is an `assistant`-typed
    /// row, so reusing `humanPrompts`'s candidate list would exclude the one shape
    /// this function exists to find.
    ///
    /// **Ordered by `timestamp`, never file order.** A live probe (a fake API
    /// endpoint forced to fail) recorded the error row landing PHYSICALLY BEFORE the
    /// user row that caused it: transcript rows flush out of chronological order,
    /// so "the last line of the file" is not a valid recency test. Every candidate
    /// carries an ISO-8601 Zulu `timestamp`, uniform within one file, so comparing
    /// the strings sorts chronologically. A row with no `timestamp` is ignored. An
    /// EXACT tie resolves to whichever row the file presents first: arbitrary but
    /// deterministic, and no two message rows were ever seen sharing a millisecond
    /// (the probe's closest pair sat 0.4 s apart).
    ///
    /// **Only the session's own words are candidates:** `type` is `"user"` or
    /// `"assistant"`, `message.role` matches it, `isMeta != true`, and `timestamp`
    /// is non-empty. `isSidechain: true` is excluded: a subagent's death is not the
    /// SESSION's last word. A trailing `attachment`, `system`, `queue-operation` or
    /// `file-history-snapshot` row changes nothing, since none is ever a candidate.
    ///
    /// **The verdict:** if the LATEST candidate (by `timestamp`) has
    /// `isApiErrorMessage == true`, this returns its message text verbatim (Claude
    /// Code's own words, per the dialog-parity rule). Detection keys on that
    /// boolean alone, never on `apiErrorStatus` (absent in at least one real
    /// specimen). Otherwise `nil`, which covers: no error ever happened; a later
    /// row (a retry) superseded it; and a tail window with no qualifying rows, or
    /// an empty file.
    public static func apiErrorLastWord(fromJSONL raw: String) -> Redacted? {
        var latest: (timestamp: String, isError: Bool, text: String?)?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = JSONValue.parse(String(line)) else { continue }
            guard let type = row["type"]?.stringValue, type == "user" || type == "assistant" else { continue }
            guard let message = row["message"], message["role"]?.stringValue == type else { continue }
            guard row["isMeta"]?.boolValue != true, row["isSidechain"]?.boolValue != true else { continue }
            guard let timestamp = row["timestamp"]?.stringValue, !timestamp.isEmpty else { continue }
            if let current = latest, timestamp <= current.timestamp { continue }
            let isError = row["isApiErrorMessage"]?.boolValue == true
            latest = (timestamp, isError, isError ? candidateText(from: message["content"]) : nil)
        }
        guard let latest, latest.isError, let text = latest.text else { return nil }
        return Redacted(text)
    }

    // ------------------------------------------------------------- the recap
    //
    // **Claude Code writes its own "where we are" summary into the transcript,
    // and this is the deck's only way to hear it — no hook carries a recap.** The
    // row shape, counted over 321 rows (CC 2.1.220 through 2.1.251):
    //
    //   {"type":"system","subtype":"away_summary",
    //    "content":"Goal: turn quick actions into scoped macros. All five
    //               phases shipped and deployed; …",
    //    "timestamp":"2026-08-18T02:10:22.343Z", …}
    //
    // Measured facts the code below leans on:
    //
    //   - `content` is a plain STRING in all 321, never the item-list shape
    //     `message.content` takes elsewhere, so `candidateText(from:)` is not used.
    //   - It never contains a newline and runs 172–310 bytes (median 239): prose,
    //     several times longer than a typical prompt, which `TranscriptWell`'s row
    //     treatment accounts for.
    //   - `isSidechain` is `false` in all 321. Excluded anyway, as in
    //     `apiErrorLastWord(fromJSONL:)`: a subagent's recap would not be THIS
    //     session's.
    //
    // **The trailing `(disable recaps in /config)` hint is stripped, conditionally,
    // because it is NOT a fixed suffix.** 41 of the 321 carry it, across every
    // version: a periodic nudge Claude Code adds to some recaps. It is terminal
    // chrome about a `/config` screen the deck does not have, so it is the one part
    // of Claude Code's words the dialog-parity rule does not ask the deck to
    // mirror. It is the only trailing parenthetical in the corpus, so a single
    // literal is the whole rule.
    //
    // **Ordered by `timestamp`, never file order**, for the reason given at
    // `apiErrorLastWord(fromJSONL:)`: rows flush out of chronological order.

    /// The latest recap this window holds, and when it was written.
    ///
    /// `iso` is carried ALONGSIDE the text rather than resolved to an `Instant`
    /// here, because this module may not read a clock (`DeckClock.swift`;
    /// `Timestamp.swift` says why even a `Date` is refused in the core) and the
    /// caller needs the recap's OWN moment for two jobs a bare string serves:
    /// placing the row chronologically in a ledger sorted by `at`, and telling a
    /// person how stale the summary is. Stamping the row with the peek's moment
    /// instead (as `peekForApiError` correctly does for an error, whose fact is "as
    /// of this trigger, the last word was X") would make a six-hour-old recap read
    /// as current.
    public struct Recap: Equatable, Sendable {
        public let text: Redacted
        /// The row's own `timestamp`, verbatim — ISO-8601 Zulu, the format
        /// `Timestamp.epochMillis(iso:)` decodes.
        public let iso: String

        public init(text: Redacted, iso: String) {
            self.text = text; self.iso = iso
        }
    }

    /// The trailing nudge some recaps carry, stripped (see the recap section
    /// above). `internal` so `TranscriptTailTests` can check the strip against the
    /// exact literal rather than a re-typed copy.
    static let recapConfigHint = "(disable recaps in /config)"

    /// The newest `away_summary` row in `raw`, or `nil`.
    ///
    /// `nil` covers three cases this does not distinguish: recaps are switched off
    /// for this session, none has been written yet, or the tail window does not
    /// reach one. All mean "nothing to show" and none is an error.
    public static func latestRecap(fromJSONL raw: String) -> Recap? {
        var latest: (timestamp: String, text: String)?
        for line in raw.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let row = JSONValue.parse(String(line)) else { continue }
            guard row["type"]?.stringValue == "system" else { continue }
            guard row["subtype"]?.stringValue == "away_summary" else { continue }
            guard row["isSidechain"]?.boolValue != true else { continue }
            guard let timestamp = row["timestamp"]?.stringValue, !timestamp.isEmpty else { continue }
            guard let content = row["content"]?.stringValue else { continue }
            let text = strippedHint(from: content)
            guard !text.isEmpty else { continue }
            if let current = latest, timestamp <= current.timestamp { continue }
            latest = (timestamp, text)
        }
        guard let latest else { return nil }
        return Recap(text: Redacted(latest.text), iso: latest.timestamp)
    }

    /// The hint off the end, and the whitespace it left behind. Trimmed FIRST as
    /// well as last: a recap may have trailing space whether or not it carries a
    /// hint, and a row that is nothing BUT a hint reduces to empty rather than to a
    /// stray space the caller would have to recognise as blank.
    static func strippedHint(from content: String) -> String {
        var text = content.trimmed
        if text.hasSuffix(recapConfigHint) {
            text = String(text.dropLast(recapConfigHint.count)).trimmed
        }
        return text
    }

    // ------------------------------------------------------- dead-branch pruning
    //
    // **A transcript is a TREE, not a list — every row carries `uuid` and
    // `parentUuid`, and a retried or superseded send writes a SIBLING row under the
    // SAME parent rather than a continuation of it.** Read in plain file order, a
    // retry shows the identical prompt twice, adjacent. In a real 44MB transcript
    // exactly three contested slots survived the filters:
    //
    //   1. A prompt sent twice, 10 lines and 38 seconds apart, the SAME
    //      `parentUuid`, IDENTICAL text: a retry after the first send did not take.
    //   2. The same shape, a second retry.
    //   3. An abandoned message SUPERSEDED by "/compact" — DIFFERENT text, the
    //      SAME parent.
    //
    // **Slot 3 is why adjacent-identical-text dedup is the wrong fix.** A
    // text-equality rule would keep the abandoned message beside the "/compact"
    // that superseded it. The rule must be about the TREE (which sibling the
    // conversation continued from), not about whether two prompts share words.
    //
    // **Full-path reconstruction from the newest leaf is also wrong.** Compaction
    // breaks the chain: in the sample, `parentUuid` links reached only 441 rows
    // back before hitting a row whose parent is absent, the compaction boundary,
    // where Claude Code's summary row starts a fresh lineage. A 44MB transcript is
    // a SEQUENCE of tree segments, and a bounded tail read (see
    // `backfillWindows(fileSize:)`) sees only the segment(s) the window reaches.
    //
    // **The rule: among filter-surviving prompt rows sharing a non-null
    // `parentUuid`, only the LAST in file order is live; earlier siblings are dead
    // branches.** It is LOCAL: it only compares candidates inside THIS parse. It is
    // also WINDOW-STABLE: a later sibling is always nearer EOF than an earlier one,
    // so any tail window containing the earlier sibling also contains the later
    // one, at every rung of the backfill ladder.
    //
    // **Null and absent parents are NEVER grouped together; each stands alone.**
    // The sample had no null-parent survivors, but grouping them into one bucket
    // and keeping only the last would silently discard every earlier prompt with no
    // recorded parent the moment an unseen transcript shape supplies more than one.

    /// `candidates` in FILE order, oldest first, as `humanPrompts(fromJSONL:cap:)`
    /// built it. Load-bearing: "the LAST in file order" is answered by comparing
    /// ARRAY INDICES, which is only valid because the caller never reorders the
    /// list first.
    private static func liveBranches(of candidates: [(text: String, parentUuid: String?)]) -> [Redacted] {
        // The last index each non-null parentUuid appears at, built in one pass so
        // the second pass is a plain lookup rather than an O(n²) rescan.
        var lastIndexForParent: [String: Int] = [:]
        for (index, candidate) in candidates.enumerated() {
            guard let parent = candidate.parentUuid else { continue }
            lastIndexForParent[parent] = index
        }
        return candidates.enumerated().compactMap { index, candidate in
            guard let parent = candidate.parentUuid else { return Redacted(candidate.text) }
            return lastIndexForParent[parent] == index ? Redacted(candidate.text) : nil
        }
    }

    // ---------------------------------------------------- the backfill ladder
    //
    // **The contract is a COUNT (`LaneRecord.historyCap` prompts), but a single
    // fixed-byte tail read is a GUESS, and any guess loses to a busy session.** A
    // 44.2MB transcript whose nearest genuine human prompt sat 950KB from EOF (a
    // session with subagents that append hundreds of KB per assistant turn) read
    // its old fixed 256KB tail, found 51 rows (8 user-role, all `isMeta` or
    // `tool_result`), and seeded ZERO prompts, silently. The filter was never
    // wrong; the READ never reached the prompts. `backfillWindows(fileSize:)` is
    // the fix: an ASCENDING plan of byte bounds a caller tries in order,
    // escalating only as far as the file, and an actual shortfall against the cap,
    // demands.

    /// The ladder's floor rung, 256KB. Right for the overwhelming majority of
    /// sessions, and kept as the FIRST rung so a quiet session costs one small
    /// read. The escalation PLAN lives in `DeckCore` (computing it needs no
    /// filesystem access), so this is the one place the number originates;
    /// `DeckRuntime.transcriptTailFloorBytes` reads it rather than restating it.
    public static let backfillFloorBytes: Int = 256 * 1_024

    /// **The ladder: four rungs, ascending.** The first three step ×8 (256KB →
    /// 2MB → 16MB): quiet sessions never pay for it, and each step is a different
    /// order of magnitude rather than a timid nudge. The FOURTH breaks the
    /// progression on purpose (×8 would be 128MB): 64MB is a SANITY BOUND, not a
    /// guarantee. A session whose last N prompts sit deeper than 64MB from EOF
    /// seeds fewer than N, honestly, rather than the ladder growing without limit.
    /// Cumulative worst case is ~82MB (256KB + 2MB + 16MB + 64MB), since each
    /// deeper rung re-reads rather than stitching (see
    /// `seedTranscript(for:path:)`); a one-off per session per launch.
    private static let backfillLadder: [Int] = [
        backfillFloorBytes,           // 256 KB
        backfillFloorBytes * 8,       // 2 MB
        backfillFloorBytes * 8 * 8,   // 16 MB
        64 * 1_024 * 1_024,           // 64 MB — the ceiling, not a further ×8 step
    ]

    /// **The ascending byte bounds a backfill tries, in order — pure, so the
    /// escalation POLICY can be table-tested against plain integers, never a
    /// file.** `fileSize` is `TranscriptFilePort.size(of:)`'s answer; `nil` means it
    /// could not be determined, a real outcome and not merely "not asked yet".
    ///
    /// **`fileSize` known: each rung CLAMPED to it, duplicates COLLAPSED.** A rung
    /// past the file's size is harmless (`tail(of:maxBytes:)` just returns the whole
    /// file), but two successive rungs clamping to the same value would cost an
    /// identical second read, which `windows.last != clamped` skips. The clamp also
    /// answers "reached the end" without a flag: the LAST element, when `fileSize`
    /// is known, is the file's full size (or the ceiling, for a file over 64MB).
    ///
    /// **`fileSize` unknown: the RAW, un-clamped ladder, all four rungs.**
    /// `size(of:)` can fail independently of `tail(of:maxBytes:)` (a narrow POSIX
    /// possibility; see `TranscriptFilePort`). That is not the same claim as "the
    /// file is unreadable", so the answer is "try the whole ladder", and
    /// `tail(of:maxBytes:)` still fails safe at whichever rung hits an unreadable
    /// file.
    ///
    /// **Worked:** `fileSize: nil` → `[262144, 2097152, 16777216, 67108864]`.
    /// `fileSize: 1000` (below the floor) → `[1000]`. `fileSize: 5_000_000` →
    /// `[262144, 2097152, 5000000]`. `fileSize: 100_000_000` (past the ceiling) →
    /// all four rungs, unclamped; a file this deep seeds fewer than the cap.
    public static func backfillWindows(fileSize: Int?) -> [Int] {
        guard let fileSize else { return backfillLadder }
        let bounded = max(0, fileSize)
        var windows: [Int] = []
        for rung in backfillLadder {
            let clamped = min(rung, bounded)
            if windows.last != clamped { windows.append(clamped) }
        }
        return windows
    }

    /// The text a `user`-role row's `content` carries, or `nil` when there is
    /// none. A plain string is itself the candidate; a list is scanned for
    /// `text`-typed items only (an `image` item contributes nothing). No list in
    /// the corpus mixed `text` and `tool_result` items, so "scan for text, ignore
    /// the rest" and "exclude lists that are ALL tool_result" give the same answer;
    /// this uses the simpler rule. Multiple `text` items (never observed, not
    /// forbidden) join with a newline rather than keeping only the first, which
    /// would silently drop a real sentence.
    private static func candidateText(from content: JSONValue?) -> String? {
        guard let content else { return nil }
        if let whole = content.stringValue { return whole }
        guard let items = content.arrayValue else { return nil }
        let texts = items.compactMap { item -> String? in
            guard item["type"]?.stringValue == "text" else { return nil }
            return item["text"]?.stringValue
        }
        guard !texts.isEmpty else { return nil }
        return texts.joined(separator: "\n")
    }
}
