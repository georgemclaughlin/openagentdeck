//
//  Subject.swift · DeckCore/Model
//
//  What a decision is **about**.
//
//  Three rules govern this file:
//
//  The byte-identical-command rule: the detail is the payload's bytes,
//  **unchanged**. Nothing is prepended, quoted, escaped or elided here. A
//  view may draw "Bash" beside it; it may not fold that into the bytes,
//  because once the subject is a composed string, "byte-identical to the
//  payload's command" is no longer a property anything can check.
//
//  The provenance rule: `field` names the payload key the bytes came from.
//  A rendered value whose origin the frame cannot state is a bug.
//
//  The empty-slot rule / the visible-supervision rule: when the deck does
//  not know which key names a tool's subject, `detail` is **nil** and the
//  frame says so explicitly. Not a blank box, not the tool name doing double
//  duty, and above all not the takeover silently declining to appear: a deck
//  that stops supervising a tool because it could not label it has turned a
//  display gap into a supervision gap.
//

/// The one-line answer to "what am I being asked about?".
public struct Subject: Equatable, Codable, Sendable {
    /// The tool as the wire named it. Never `Redacted` — a tool name is a fixed
    /// vocabulary item, not payload content, and the mast needs to count them.
    public let tool: String
    /// The bytes that say *which* — the command, the path, the URL. `nil` when
    /// the deck cannot tell which key of this tool's input carries them.
    public let detail: Redacted?
    /// Which key of `tool_input` `detail` was read from. Present exactly when
    /// `detail` is.
    public let field: String?
    /// `tool_input.description`: the human-readable line the terminal prints under
    /// the command (`"Force push local main to origin/main"` beside
    /// `git push --force origin main`, in the LVV-permission fixture).
    ///
    /// **Named `caption`, not `description`.** A public stored property spelled
    /// `description` on a `struct` collides with `CustomStringConvertible` as soon
    /// as this type (or an extension of it) adopts that protocol. The wire key is
    /// still `description`; `SubjectReader.captionField` reads it unchanged. The
    /// rename is Swift-side only.
    ///
    /// `nil` means one of two things and both render the same way (no second
    /// line): the tool's schema has no description key (`SubjectReader
    /// .captionField` has no entry for it), or it does and this call carried none.
    /// There is no `field`-style provenance witness for `caption`: it is
    /// decoration, not the payload the provenance rule guards, so a second
    /// optional that is nil for the same reasons `detail == nil` covers would tell
    /// a reader nothing.
    public let caption: Redacted?

    public init(tool: String, detail: Redacted?, field: String?, caption: Redacted? = nil) {
        self.tool = tool
        self.detail = detail
        self.field = field
        self.caption = caption
    }

    /// The provenance rule's falsifier, one component along: bytes on screen
    /// whose origin the frame cannot name.
    public var isUnprovenanced: Bool { (detail == nil) != (field == nil) }
}

public extension Subject {
    /// The name a person would call this subject when there is nothing else to
    /// show: `detail`'s fallback in every view that reads it. Almost always `tool`
    /// unchanged, since a tool name is not payload content (see `tool`).
    /// `ExitPlanMode` is the exception: its terminal dialog asks "Would you like to
    /// proceed?" over the plan and never prints the tool's wire name, so showing
    /// the literal string would be jargon the terminal does not use.
    /// `SubjectReader.displayNames` lists the tools checked this way; every other
    /// tool falls through to its own name.
    var displayName: String { SubjectReader.displayNames[tool] ?? tool }
}

public enum SubjectReader {

    /// Which key of `tool_input` names what a tool is about to do.
    ///
    /// Split by how it is known:
    ///
    /// **Recorded**: present in `Packages/DeckKit/Tests/DeckCoreTests/Fixtures/events.ndjson`, so these are
    /// observations: `Bash.command`, `Read.file_path`, `ToolSearch.query`,
    /// `AskUserQuestion.questions`.
    ///
    /// **Published**: stated in the Claude Code tool documentation and not yet seen
    /// on this deck's wire: `Write.file_path`, `Edit.file_path`, `Glob.pattern`,
    /// `Grep.pattern`, `WebFetch.url`, `ExitPlanMode.plan`.
    ///
    /// A tool absent from both lists is not an error. It falls through to
    /// `fallbackKeys` and, failing that, to a subject with no detail.
    static let namingField: [String: String] = [
        // recorded
        "Bash":             "command",
        "Read":             "file_path",
        "ToolSearch":       "query",
        // published
        "PowerShell":       "command",
        "Write":            "file_path",
        "Edit":             "file_path",
        "NotebookEdit":     "notebook_path",
        "Glob":             "pattern",
        "Grep":             "pattern",
        "WebFetch":         "url",
        // The "would you like to proceed?" dialog: the plan body IS the subject, the
        // way a command is Bash's. Published, not recorded: no fixture calls it
        // (`live/LV14-plan/payloads.ndjson` never does). A wrong guess still renders
        // honestly because `field` says where the bytes came from.
        "ExitPlanMode":     "plan",
    ]

    /// Tried in order for a tool nobody has named. This is a guess, and survivable
    /// because it is recorded: whatever it finds is reported with the key it came
    /// from, so a wrong guess renders as a visibly odd label rather than as an
    /// authoritative wrong subject.
    static let fallbackKeys = ["command", "file_path", "path", "url", "pattern", "query"]

    /// Which key of `tool_input` carries a tool's human-readable caption: the
    /// sentence the terminal prints dimmer, under the command, never instead of it.
    /// Recorded for `Bash` in the LVV-permission fixture.
    ///
    /// `PowerShell` has no recording and no citation; it is here only because it
    /// has the same shell-tool shape as `Bash`. That is a weaker standing than
    /// "published".
    ///
    /// Deliberately small. A tool absent here yields `caption == nil`: guessing a
    /// caption key the way `fallbackKeys` guesses a primary one could label some
    /// OTHER field's bytes as a caption, and a caption is trusted because nothing
    /// else competes for the label.
    static let captionField: [String: String] = [
        "Bash":       "description",
        "PowerShell": "description",
    ]

    /// `Subject.displayName`'s table; see that property for why it stays short.
    static let displayNames: [String: String] = [
        "ExitPlanMode": "Plan",
    ]

    /// `AskUserQuestion` carries its subject as a structured array rather than a
    /// string, so it is absent from the string path: the question grid is its
    /// subject, and `Question` is the type that renders it.
    public static let questionTool = "AskUserQuestion"

    /// Total. Every tool yields a subject; only the detail can be missing.
    public static func subject(tool: String?, input: JSONValue?) -> Subject? {
        guard let tool, !tool.trimmed.isEmpty else { return nil }
        guard let key = key(for: tool, in: input),
              let raw = input?[key]?.stringValue,
              let detail = Redacted(optional: raw)
        else { return Subject(tool: tool, detail: nil, field: nil) }
        // Bound only alongside a DETAIL the deck actually found: a caption with no
        // command beside it would caption bytes the frame is not showing (the same
        // ordering the provenance rule enforces between `detail` and `field`).
        let caption = captionField[tool]
            .flatMap { input?[$0]?.stringValue }
            .flatMap(Redacted.init(optional:))
        return Subject(tool: tool, detail: detail, field: key, caption: caption)
    }

    static func key(for tool: String, in input: JSONValue?) -> String? {
        if let known = namingField[tool] { return known }
        guard let input else { return nil }
        // Only a key actually carrying a non-empty string counts. A tool whose `path`
        // is null must fall through to the next candidate.
        return fallbackKeys.first { input[$0]?.stringValue?.trimmed.isEmpty == false }
    }
}

/// The overflow affordance UX_DESIGN §4 mandates for the subject well: "Long
/// single lines **wrap**, no horizontal clipping, ever. Content taller than the
/// well shows a mandatory '▾ N more lines' chip". A pure function of the text,
/// kept apart from the SwiftUI button so the arithmetic is testable without a
/// view.
///
/// **Two tiers.** This enum can only count `\n` characters (see `lineCount`),
/// so a long WRAPPING single line is invisible to it. `SubjectWell` adds a
/// second, MEASURED check in the view: it renders the text once unconstrained
/// and once capped at `collapsedLines`, at the well's own width, and compares
/// heights. So a tool with no `chipText` here can still show a chip there.
public enum SubjectOverflow {

    /// How many lines the well shows collapsed before it needs a chip.
    /// `DecisionBar`'s `.lineLimit` reads this rather than restating `4`.
    public static let collapsedLines = 4

    /// Ceiling for the EXPANDED well on the 480 pt strip, found by measurement.
    /// `RenderSweepTests.decisionBarWithSuggestionAndExpandedPlanFitsTheStrip`
    /// renders the worst shape the bar takes (a suggestion button beside
    /// Allow/Deny plus a 20-line expanded plan) at a narrow width
    /// (the `narrowPaneWidth` constant in `RenderSweepTests`, 380) and asserts the bar stays under
    /// 480 pt. That test is this constant's arbiter.
    ///
    /// The bar's height tracks this constant one point for one point (150 pt
    /// measured 496 pt total, 200 pt measured 546 pt), so everything else the bar
    /// spends is a fixed 346 pt: the "Waiting for you" label and outer padding,
    /// the suggestion button (`ViewThatFits`' vertical fallback stacks all three
    /// `TouchTarget.decision` controls at this width), the well's padding, and the
    /// overflow chip's row. 346 pt of chrome leaves 134 pt; 120 pt is that ceiling
    /// with 14 pt of margin.
    ///
    /// Also the cap for `QuestionTakeover`'s option previews, which reuse it
    /// rather than naming a second 120 that could drift; see
    /// `PreviewOverflow.visibleLines`.
    public static let expandedMaxHeight: Double = 120

    /// Newline-only. A TRAILING newline drops its own artifact: `"a\nb\n"` splits
    /// into `["a", "b", ""]`, and that last empty component is the string ending
    /// with a newline, not a third, blank line (the reading a text editor gives).
    /// Only the FINAL empty component is dropped; a blank line in the middle
    /// (`"a\n\nb"`) still counts.
    ///
    /// A long single line that will also soft-wrap once laid out is undercounted
    /// here: width-based wrapping is unknowable without a layout pass. The chip
    /// promises there is more to see, not an exact row count. (`SubjectWell`
    /// closes that gap with a measured check; see the type's doc comment.)
    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines.count
    }

    /// `nil` when the collapsed well already shows the whole text. Otherwise
    /// "▾ N more lines", where N counts only the lines the collapsed well is not
    /// showing (not the total), because "more" is a claim about what is hidden.
    ///
    /// **The N-label rule.** This only ever returns `nil` or a STATED count, never
    /// a number it cannot back. A single physical line that will visibly wrap past
    /// `collapsedLines` still returns `nil` here; `SubjectWell` shows the chip
    /// captioned "▾ more" for that shape (`SubjectWell.chipTitle`).
    ///
    /// `collapsedLines` is a parameter so a caller with a tighter budget
    /// (`DetailBand`, whose well collapses to fewer lines) gets a hidden count that
    /// matches the collapse depth actually on screen.
    public static func chipText(for text: String, collapsedLines: Int = collapsedLines) -> String? {
        let hidden = lineCount(text) - collapsedLines
        guard hidden > 0 else { return nil }
        return "▾ \(hidden) more line\(hidden == 1 ? "" : "s")"
    }

    /// The chip's other face, once expanded. Stated once rather than as a literal
    /// at each call site.
    public static let collapseChipText = "▴ collapse"

    /// The chip's third face: wrap-only overflow, where `chipText` has no `N` to
    /// offer. Never "▾ 0 more lines" or any other invented count. `SubjectWell`
    /// uses this when newline arithmetic came back `nil` but a measured render
    /// found more text than `collapsedLines` shows.
    public static let wrapOnlyChipText = "▾ more"
}

/// The option preview's own overflow affordance. `SubjectOverflow`'s chip is
/// copy the DECK authored; this marker is copy the deck is QUOTING. Claude
/// Code's terminal says "✂ N lines hidden" for a preview too tall to show,
/// agrammatical plural included, and dialog parity means saying it exactly
/// that way rather than correcting the terminal's copy.
public enum PreviewOverflow {

    /// The preview font's line height in points (`.callout.monospaced()`, the font
    /// `QuestionTakeover`'s preview `Text` uses).
    ///
    /// Measured, like `SubjectOverflow.expandedMaxHeight`, through the same harness
    /// as `RenderSweepTests.measured(_:width:)` (`NSHostingView` +
    /// `layoutSubtreeIfNeeded()` + `fittingSize`) at 1 to 40 lines. Every
    /// consecutive pair differed by exactly 15.0 pt (1 line = 15 pt, 40 lines =
    /// 600 pt) with no fixed offset. Width does not matter because this text never
    /// wraps (`fixedSize(horizontal: true, ...)` in the view).
    private static let lineHeight: Double = 15

    /// How many source lines the preview shows before it clips:
    /// `SubjectOverflow.expandedMaxHeight` (120 pt) divided by `lineHeight`. The
    /// division is exact, so there is no rounding.
    public static let visibleLines = Int(SubjectOverflow.expandedMaxHeight / lineHeight)

    /// Whether `text` has more source lines than `visibleLines` shows. Reuses
    /// `SubjectOverflow.lineCount` so both overflow affordances count a "line"
    /// identically, including its undercount of soft-wrapped long lines.
    public static func clips(_ text: String) -> Bool {
        SubjectOverflow.lineCount(text) > visibleLines
    }

    /// The marker itself; `nil` when nothing is hidden (the empty-slot rule).
    ///
    /// **The grammar is quoted, not authored.** "✂ 1 lines hidden" is literally
    /// what Claude Code's terminal prints for one hidden line, so this returns that
    /// string rather than the grammatical "1 line" that `SubjectOverflow.chipText`
    /// writes for the deck's own copy.
    public static func marker(for text: String) -> String? {
        let hidden = SubjectOverflow.lineCount(text) - visibleLines
        guard hidden > 0 else { return nil }
        return "✂ \(hidden) lines hidden"
    }

    /// What actually reaches `Text`, as opposed to what `lineCount` counted. They
    /// diverge on a TRAILING newline: an 8-line preview rendered 120 pt, but the
    /// same lines plus one trailing `"\n"` rendered 135 pt, although `lineCount`
    /// reports both as 8. SwiftUI's `Text` counts rows as "newline characters plus
    /// one" with no trailing exception. Left alone, a preview at exactly
    /// `visibleLines` with a trailing newline would render one row past the budget
    /// while `clips` said `false`.
    ///
    /// Drops exactly one trailing `"\n"` (never more, so a deliberate blank line
    /// survives). This is the render boundary's fix, not `lineCount`'s, because
    /// `lineCount` is shared with `SubjectWell`, which may not share the quirk.
    public static func renderText(_ text: String) -> String {
        text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    /// What actually reaches the CLIPPING preview's cell. A preview has no inner
    /// `ScrollView`: nested vertical scrollers on a touch strip contest every drag,
    /// and the inner one could never be fully seen inside the options band. A
    /// clipping preview's cell is STATIC, truncated to exactly `visibleLines`
    /// lines, the same lines `marker` says are kept. `renderText`'s trailing-newline
    /// fix runs first so the split agrees with what `clips` / `marker` counted.
    /// Text that does not clip passes through unchanged (past `renderText`). This
    /// is `previewBlock`'s only entry point, so exactly one place decides what a
    /// preview cell shows.
    public static func visibleText(_ text: String) -> String {
        let rendered = renderText(text)
        guard clips(text) else { return rendered }
        return rendered.components(separatedBy: "\n").prefix(visibleLines).joined(separator: "\n")
    }
}

/// The takeover's vertical budget: how tall the whole SCROLLABLE OPTIONS BAND
/// may be (not the well, not one preview). Without it, a `QuestionTakeover`
/// pinned as a `.safeAreaInset` is neither scrolled nor compressed by SwiftUI:
/// it renders at full ideal height and clips at both ends, so a takeover taller
/// than the strip disappears off it.
///
/// **Only for a PREVIEWED question, and only ever ONE scroller deep.** Capping
/// a bare question's options too would hide options past the first with no
/// affordance (`TouchTarget.decision` alone is 64 pt, so two options saturate
/// the cap). `QuestionTakeover` applies this band only when the current
/// question carries at least one preview; a bare question lays out every
/// option directly. And previews have no inner `ScrollView`
/// (`PreviewOverflow.visibleText` truncates statically), so this band is the
/// only thing that scrolls a previewed question's options.
public enum QuestionOptionsBand {

    /// The strip's usable viewport with chrome the deck does not control removed
    /// (not the `stripHeight` constant in `RenderSweepTests` itself): 480 - 40 pt titlebar - 21 pt
    /// status line = 419. The 40 is the compact toolbar's real height, read via the
    /// Accessibility API against the running `.unifiedCompact` build (`DeckScene`
    /// cites the same figure). The 21 is `StatusLine`'s headless height at the
    /// strip's 1920 pt width, measured
    /// headlessly (the test that did so is retired). A headless render cannot
    /// see the titlebar's contribution, which is why this constant carries the
    /// number rather than deriving it inline.
    public static let usableStripHeight: Double = 419

    /// The options band's ceiling, derived from the worst binding case: `controls`
    /// (Back/DONE) visible, at least one option previewed and clipping (so the band
    /// saturates AND the marker shows), at the 380 pt narrow width.
    ///
    /// Chrome (header, question text, collapsed "Other..." row, caption line,
    /// `controls`, outer padding) was measured at 228 pt at 480 pt wide and 244 pt
    /// at 380 pt wide with no `controls` row, and 292 / 308 pt with one (Back and
    /// DONE together cost one row). `moreOptionsText`'s row adds 19 pt (a worst-case
    /// takeover with and without it differed by exactly that;
    /// `RenderSweepTests.moreOptionsMarkerRenders` proves the row exists and costs
    /// real height, not its exact figure).
    ///
    /// 419 (`usableStripHeight`) - 308 - 19 = 92 pt of room; 78 pt is that ceiling
    /// with 14 pt of margin, the same margin `expandedMaxHeight` keeps.
    /// `RenderSweepTests.worstCaseComboFitsTheUsableStrip` and
    /// `.theRecordedLV37QuestionFitsTheUsableStrip` hold the end-to-end fit live
    /// against this constant.
    public static let maxHeight: Double = 78

    /// The vertical gap `QuestionTakeover.previewedOptions` puts between rows.
    /// Named here so the row-fit arithmetic below and the view's `spacing:` cannot
    /// drift apart.
    public static let rowSpacing: Double = 10

    /// One previewed option's row height inside the band, measured:
    /// `RenderSweepTests.theClippedCellClaimsRealHeight` pins the 208. It is one
    /// clipping-preview cell (`QuestionTakeover.optionButton`) at 480 pt wide: the
    /// answer button's `TouchTarget.decision` floor (64), 6 pt of `VStack` spacing,
    /// `PreviewOverflow.visibleLines` lines of monospaced text (8 x 15 = 120), 4 pt
    /// of spacing before the marker, and one caption-height marker row. A fixed
    /// number, not a range, because every clipping preview is truncated to the same
    /// line count.
    static let previewRowHeight: Double = 208

    /// How many of `hasPreview`'s rows the band's unscrolled `maxHeight` viewport
    /// shows AT LEAST THE TOP EDGE of, in render order. Not how many fit
    /// completely: `moreOptionsText` is about OPTIONS the reader has not seen any
    /// of yet, and a single previewed option taller than the band still counts as
    /// visible (a downward drag reveals the rest of that SAME option; its own
    /// truncation is `PreviewOverflow.marker`'s claim). Getting this wrong would
    /// make a one-option question claim "▾ 1 more option".
    public static func visibleOptionCount(hasPreview: [Bool]) -> Int {
        var used = 0.0
        var visible = 0
        for (index, preview) in hasPreview.enumerated() {
            let spacing = index > 0 ? rowSpacing : 0
            guard used + spacing < maxHeight else { break }
            visible += 1
            used += spacing + (preview ? previewRowHeight : TouchTarget.decision)
        }
        return visible
    }

    /// The band's overflow affordance. Without it, options past the first would be
    /// absent with no sign (a "same options, never a subset" parity violation).
    /// Same grammar as `SubjectOverflow.chipText`: "▾ N more options" here, "▾ N
    /// more lines" there.
    public static func moreOptionsText(total: Int, visible: Int) -> String? {
        let hidden = total - visible
        guard hidden > 0 else { return nil }
        return "▾ \(hidden) more option\(hidden == 1 ? "" : "s")"
    }
}

/// **`QuestionStage`'s tap rule.** The full-strip takeover has room for a
/// previewed question's options AND one full preview at once, which makes a
/// two-step tap worthwhile: the first tap on an option swaps the preview pane
/// to it (a look, not a commitment) and only a SECOND tap on the focused row
/// answers with it. `QuestionTakeover`'s `optionButton` is single-tap: with no
/// preview pane to aim a first tap at, a tap goes straight to the wire.
///
/// Pure and index-only so it is testable without a view. Nothing here reads
/// `multiSelect`: a single-select pick and a multi-select toggle are both
/// `.pick`, because the reducer (`questionPicked`) decides whether a pick
/// commits or toggles. This rule only decides FOCUS vs. ANSWER.
public enum OptionTap: Equatable, Sendable {
    /// The tapped row becomes the focused one; nothing reaches the wire.
    case focus(Int)
    /// The tapped row was already focused — send it, the same call a
    /// single tap makes on `QuestionTakeover`.
    case pick(Int)
}

public enum QuestionStageInteraction {
    /// A digit shortcut never calls this: dialog parity makes a digit an ANSWER,
    /// not a focus move, so `QuestionStage` routes digits straight to `.pick`. This
    /// is the TAP path only.
    public static func tap(_ index: Int, focusedIndex: Int) -> OptionTap {
        index == focusedIndex ? .pick(index) : .focus(index)
    }
}

// ---------------------------------------------------------------- questions

/// One option on one question.
///
/// Shape taken from the seven `AskUserQuestion` captures in
/// `Packages/DeckKit/Tests/DeckCoreTests/Fixtures/events.ndjson`, which agree with the published schema field
/// for field, so this is one place the deck is not guessing.
public struct QuestionOption: Equatable, Codable, Sendable {
    /// What the deck sends back as the answer. The wire wants the **label**,
    /// not an index — see `Answer`.
    public let label: Redacted
    public let detail: Redacted
    /// An ASCII mockup or worked example for this option: an optional per-option
    /// field the published schema documents and no fixture carries (all recorded
    /// `AskUserQuestion` calls predate it). Empty-slot rule: absent renders no well
    /// at all, never an empty one. (`detail` above instead defaults to an empty
    /// string.)
    public let preview: Redacted?
    public init(label: Redacted, detail: Redacted, preview: Redacted? = nil) {
        self.label = label; self.detail = detail; self.preview = preview
    }
}

public struct Question: Equatable, Codable, Sendable {
    /// Also the **key** of the answer map on the way back, which is why it is
    /// kept verbatim rather than trimmed or normalised for display.
    public let text: Redacted
    /// Documented as at most 12 characters. Not enforced here — a longer header
    /// is Claude's to send and the deck's to fit, and refusing to render one
    /// would be the deck failing on an input it was told to expect.
    public let header: Redacted
    public let options: [QuestionOption]
    public let multiSelect: Bool

    public init(text: Redacted, header: Redacted,
                options: [QuestionOption], multiSelect: Bool) {
        self.text = text; self.header = header
        self.options = options; self.multiSelect = multiSelect
    }

    /// True when at least one option here carries a preview: the fork between the
    /// compact, uncapped layout (`QuestionTakeover`'s `options(for:)`) and the
    /// scrollable band / full-strip stage layouts a preview earns. Named once so
    /// `Decision.currentQuestionHasPreview` and `QuestionTakeover` cannot diverge
    /// into two spellings of the same check.
    public var hasPreview: Bool { options.contains { $0.preview != nil } }
}

/// One answer to one question, in the shape the wire takes.
///
/// The documented response maps each question's own *text* to the selected
/// option's *label*, with an array of labels when `multiSelect` is set. Indices
/// are not labels, and one integer per question cannot express a multi-select
/// answer at all. The all-or-nothing rule is about how many answers travel
/// together and is unaffected by the element type.
public struct Answer: Equatable, Codable, Sendable {
    public let question: Redacted
    /// One label for a single-select question, several for a multi-select. An
    /// empty array is not an answer and `QuestionCall.isComplete` refuses it.
    public let labels: [Redacted]
    public init(question: Redacted, labels: [Redacted]) {
        self.question = question; self.labels = labels
    }
}

/// How far through a multi-question call the user has got.
///
/// **This lives in the reducer because it cannot live anywhere else.** The
/// renderer is a pure function of the frame, so a view holding the step, the
/// gathered answers and the current selection in `@State` would produce output
/// that cannot be predicted from a frame. Worse, a stepper in view state
/// resets when the view is rebuilt, and on this product a display waking up
/// would lose a half-answered question (the handoff rule's falsifier).
public struct AnswerProgress: Equatable, Codable, Sendable {
    /// Which question is on screen.
    public var step: Int
    /// Answers to the questions already passed. Nothing here has reached the
    /// wire — answers are all-or-nothing, and this is the "nothing" half made
    /// visible so it can be checked.
    public var gathered: [Answer]
    /// Options selected for the current question and not yet committed. Always
    /// at most one unless the question is `multiSelect`.
    public var picked: [Redacted]
    /// When the question on screen last changed (a forward commit or a step back).
    /// UX_DESIGN §4.1's 400 ms stepper re-arm measures from here: new buttons must
    /// never inherit a rhythm tap aimed at the old ones, and the same columns
    /// change meaning in both directions.
    public var stepChangedAt: Instant?

    public init(step: Int = 0, gathered: [Answer] = [], picked: [Redacted] = [],
                stepChangedAt: Instant? = nil) {
        self.step = step; self.gathered = gathered; self.picked = picked
        self.stepChangedAt = stepChangedAt
    }

    /// The picked entry that names none of `question`'s own options: the one a
    /// typed answer left behind. The reducer guarantees `picked` holds at most one
    /// label outside `question.options` (the multiSelect branch of
    /// `questionAnsweredFreely` evicts any prior out-of-options entry before
    /// appending), so "first" is "the".
    ///
    /// Shared by `QuestionTakeover` and `QuestionStage`, which both seed the same
    /// `OtherAnswerField` with the free text already on record for the step, so the
    /// rule lives once on the type that carries `picked`.
    public func freeText(in question: Question) -> Redacted? {
        picked.first { label in !question.options.contains { $0.label == label } }
    }
}

/// An `AskUserQuestion` call: N questions, each with its own options.
///
/// **All-or-nothing.** A multi-question call submits every answer at once or
/// none; a partial answer never reaches the wire. The stepper is a display
/// concern.
///
/// **Not `Codable`.** `rawQuestions` is a `JSONValue`, which is `Decodable`
/// only (nothing here encodes one). `Hold.suggestions` and
/// `HookEvent.permissionSuggestions` are the same shape and are not `Codable`
/// either.
public struct QuestionCall: Equatable, Sendable {
    public let hold: HoldID
    public let questions: [Question]
    /// `tool_input["questions"]`, byte-value-verbatim from the wire (the doctrine
    /// `HookEvent.permissionSuggestions` established). Re-deriving the array from
    /// `questions` above would strip any key the deck's model does not carry
    /// (`preview`, or a future one) from the tool's input when the deck answers.
    /// `nil` for a call built by hand with no raw array attached.
    public let rawQuestions: JSONValue?

    public init(hold: HoldID, questions: [Question], rawQuestions: JSONValue? = nil) {
        self.hold = hold; self.questions = questions; self.rawQuestions = rawQuestions
    }

    public var questionCount: Int { questions.count }

    /// Published bounds: one to four questions, two to four options each. Named
    /// because `Layout` stacks option rows at a fixed 90 px and five of them
    /// already exceed the 480 px strip.
    public static let maxQuestions = 4
    public static let maxOptions = 4

    /// The all-or-nothing rule's guard. It must tell *which* question an answer
    /// belongs to: since answers are keyed by question text, two answers to the
    /// same question and none to another is a partial submission with the right
    /// count.
    ///
    /// A call whose questions repeat a text can never be completed, and that is
    /// correct. The wire keys answers by question text, so identical texts collide
    /// in a map with room for one; submitting one would tell Claude the user
    /// answered a question they were never asked. Refusing lets the hold run out
    /// its budget and release to the terminal (graceful degradation: no session is
    /// ever worse off because the deck exists).
    public func isComplete(_ answers: [Answer]) -> Bool {
        guard answers.count == questions.count else { return false }
        guard answers.allSatisfy({ !$0.labels.isEmpty }) else { return false }
        let asked = Set(questions.map(\.text.value))
        let answered = Set(answers.map(\.question.value))
        return asked == answered && answered.count == questions.count
    }
}

public enum QuestionReader {

    /// All-or-nothing decode of the raw `questions` array on its own, with no
    /// `HoldID`: the shape ingest needs, since `HookEvent.questions` exists before
    /// a hold does. `nil` on no array, an empty one, or any row this reader cannot
    /// decode: a call the deck cannot read must not open a takeover it cannot
    /// populate (T11). The `HoldID`-bearing `QuestionCall` is composed later, in
    /// the reducer, off `HookEvent.questions`/`rawQuestions`.
    static func questions(from input: JSONValue?) -> [Question]? {
        guard case .array(let rows)? = input?["questions"], !rows.isEmpty else { return nil }
        let questions = rows.compactMap(question(from:))
        return questions.count == rows.count ? questions : nil
    }

    public static func question(from row: JSONValue) -> Question? {
        guard let text = Redacted(optional: row["question"]?.stringValue) else { return nil }
        guard case .array(let rawOptions)? = row["options"] else { return nil }
        let options = rawOptions.compactMap { option -> QuestionOption? in
            guard let label = Redacted(optional: option["label"]?.stringValue) else { return nil }
            return QuestionOption(label: label,
                                  detail: Redacted(option["description"]?.stringValue ?? ""),
                                  preview: Redacted(optional: option["preview"]?.stringValue))
        }
        guard options.count == rawOptions.count, !options.isEmpty else { return nil }
        return Question(text: text,
                        header: Redacted(row["header"]?.stringValue ?? ""),
                        options: options,
                        // Absent means false. The corpus carries the key on every recorded
                        // question and the documentation calls it optional, so defaulting to the
                        // narrower behaviour covers both.
                        multiSelect: row["multiSelect"]?.boolValue ?? false)
    }
}

/// Decodes the terminal's own answer to a question
/// (`PostToolUse.tool_input.answers` / `tool_response.answers`), as recorded in
/// the LV38 corpus. This differs from the deck's OWN outbound answer
/// (`HookResponse.answered`) on multi-select: the deck sends `updatedInput`
/// with an array of labels, but a real terminal answer is one comma-joined
/// STRING (`{"Pick": "Option A, Option B"}` in `multiselect-two-picks.ndjson`).
/// Reading the wrong shape would not throw; it would silently read one merged
/// label instead of two.
public enum AnswerReader {

    /// All-or-nothing, like `QuestionReader.questions(from:)`: a `PostToolUse` this
    /// reader cannot fully decode must not retire a hold on a partial, possibly
    /// wrong understanding of what was chosen.
    ///
    /// **Split-on-comma is decided from the SAME payload's `questions` array, never
    /// guessed from the answer string.** A single-select label or typed "Other"
    /// answer containing `", "` must not be split into labels it never was, so this
    /// looks up each answer's question by TEXT in `input["questions"]` (carried on
    /// `PostToolUse`, confirmed in every LV38 fixture) and splits only when that
    /// question's `multiSelect` says so.
    ///
    /// **Known gap: a MULTI-select LABEL that itself contains `", "`.** Choosing
    /// `"Salt, then pepper"` and `"Sugar"` joins on the wire as `"Salt, then
    /// pepper, Sugar"`, indistinguishable from three picks. That is Claude Code's
    /// own encoding, and the wire does not carry enough information to recover
    /// which commas are delimiters. No LV38 fixture has a comma in a label, so the
    /// gap is documented rather than worked around with a guess.
    static func answers(from input: JSONValue?) -> [Answer]? {
        guard case .object(let raw)? = input?["answers"], !raw.isEmpty else { return nil }
        guard case .array(let rows)? = input?["questions"], !rows.isEmpty else {
            // No `questions` array to anchor order or `multiSelect` against. Every
            // recorded `PostToolUse` for the question tool carries one, so this is a
            // defensive fallback. It fails toward NOT splitting: an un-split
            // multi-select answer is a display gap, while a single label torn apart by
            // a guessed comma would be a fabricated answer.
            let decoded: [Answer] = raw.compactMap { key, value in
                guard let str = value.stringValue else { return nil }
                return Answer(question: Redacted(key), labels: [Redacted(str)])
            }
            return decoded.count == raw.count ? decoded : nil
        }
        var out: [Answer] = []
        for row in rows {
            guard let text = row["question"]?.stringValue,
                  let value = raw[text]?.stringValue else { return nil }
            let isMultiSelect = row["multiSelect"]?.boolValue ?? false
            let labels = isMultiSelect
                ? value.components(separatedBy: ", ").map(Redacted.init)
                : [Redacted(value)]
            guard !labels.isEmpty else { return nil }
            out.append(Answer(question: Redacted(text), labels: labels))
        }
        // Every question answered, nothing answered that was not asked (the
        // same check as `raw.count` on the fallback branch above).
        return out.count == raw.count ? out : nil
    }
}

// ------------------------------------------------------------ mirror lifecycle

/// Where an `AskUserQuestion` mirror stands, independent of `Hold.outcome`.
/// A hold's outcome is written once (`Hold.resolve`), but in the realistic
/// timeline (LV38) the terminal's own picker cannot render until `PreToolUse`'s
/// hold has already fallen through, so by the time a human answers the hold is
/// very likely `.release`d. The mirror keeps rendering, and keeps learning,
/// past that point.
///
/// **No `.retired` case.** A mirror's retirement is represented by absence from
/// `state.mirrors` (as `state.questions[id] = nil` does for a question call),
/// not by a stored value nobody would construct. `sweepHolds` removes a mirror
/// in the same sweep that removes its hold (see `DeckState.sweepHolds`).
public enum MirrorStage: Equatable, Codable, Sendable {
    /// The hold is open. The deck's own takeover answers it directly.
    case deckWindow
    /// The hold fell through (released or naturally expired) with no deck-side
    /// decision. The mirror STAYS rendered, marked "live in the terminal", but is
    /// not yet forwardable: nothing yet proves the terminal's picker exists to
    /// answer by keystroke.
    case released(at: Instant)
    /// The readiness gate has cleared: a `PermissionRequest` naming this session's
    /// question tool, THEN a `Notification`, both observed after `.released`. This
    /// proves the terminal picker exists, so the mirror is forwardable (V2
    /// forwarding).
    case terminalLive(at: Instant)
    /// Answered (by the deck, or at the terminal via `PostToolUse`) or the session
    /// moved on with nothing chosen. `answers` is `nil` only for the latter; a real
    /// answer always carries at least one label (`Answer.labels`). `origin` says
    /// WHICH of the three paths got here. It is a separate field rather than
    /// inferred from `answers == nil` because a deck-side `.questionSubmitted` and a
    /// terminal-side `.answeredElsewhere` both carry real answers yet need
    /// different copy.
    case resolved(answers: [Answer]?, origin: ResolvedOrigin, at: Instant)

    /// The instant this mirror released, or `nil` outside `.released`: the
    /// readiness-gate correlation's lookup key (`DeckState`'s
    /// `PermissionRequest`/`Notification` handling).
    public var releasedAt: Instant? {
        if case .released(let at) = self { return at }
        return nil
    }

    /// Every case but `.deckWindow` carries an instant: the moment THAT stage
    /// began, not the moment the underlying call started. `Projection.frame`'s
    /// `mirrors` sort reads this.
    public var at: Instant? {
        switch self {
        case .deckWindow: return nil
        case .released(let at), .terminalLive(let at): return at
        case .resolved(_, _, let at): return at
        }
    }
}

/// Which of the three ways a mirror reaches `.resolved` happened;
/// `MirrorStage.resolved` explains why this cannot be inferred from `answers`.
public enum ResolvedOrigin: Equatable, Codable, Sendable {
    /// The deck's own takeover answered it (`.questionSubmitted`) while the hold
    /// was still open.
    case deck
    /// A `PostToolUse` retired it: the terminal answered directly, either while the
    /// hold was still open (`Resolution.answeredElsewhere`) or after it had fallen
    /// through, which is the realistic case (see `DeckState`'s `.postToolUse`
    /// handling).
    case terminal
    /// The session ended with nobody having answered. `MirrorStage.resolved`'s
    /// `answers` is `nil` for this origin only.
    case movedOn
}

/// One mirror: the question call it renders, unchanged for the mirror's whole
/// life, and the stage, which is the only thing that moves.
///
/// **Carries its OWN copy of the call rather than reading
/// `state.questions[id]`.** `forgetQuestion` clears that dictionary the instant
/// a hold resolves (`.decision` and `.holdExpired` both call it), so a mirror
/// reading it would go blank exactly when it must stay lit. The copy is small
/// and bounded (`QuestionCall.maxQuestions` x `.maxOptions`).
public struct QuestionMirror: Equatable, Sendable {
    public let call: QuestionCall
    public var stage: MirrorStage
    /// The readiness gate's first half: set when a `PermissionRequest` naming this
    /// session's question tool arrives while `stage` is still `.released`. `nil`
    /// until then. There is no field for the second half (`Notification`); that
    /// promotes `stage` itself to `.terminalLive`.
    public var permissionRequestSeenAt: Instant?
    /// The awaiting-confirmation window. Set the instant a forwarded plan sends its
    /// LAST step (`.forwardStepSent`, gated on `plan.isComplete`), never before (a
    /// mid-flight plan already disables its options through `mirror.forwarding`).
    /// While non-nil the mirror's options stay disabled
    /// (`MirrorView.awaitingConfirmation`) regardless of `forwardUnconfirmedAt`:
    /// cmux's `.sent` is not proof the terminal acted, so the gap between "sent"
    /// and a real `PostToolUse` (or the unconfirmed mark below) is where a
    /// duplicate tap would otherwise land and send the digit twice.
    ///
    /// Cleared by `.forwardRearmed` (the deliberate "Send again", never an
    /// automatic re-arm) and by the two doors that retire a mirror WITHOUT an
    /// answer (the moved-on sweep and `sessionEnd`). The two ANSWER doors
    /// (`PostToolUse` resolution, `.questionSubmitted`) leave it set on purpose:
    /// origin attribution reads it AT resolution ("was this the deck's own
    /// completed forward echoing back?"), and afterwards every consumer is
    /// `.terminalLive`-gated, so the surviving value is an inert record.
    public var forwardSentAt: Instant?
    /// Set when `HoldPolicy.forwardLandingAllowance` elapsed with `forwardSentAt`
    /// still set and no confirmation arrived in time. This is what makes the
    /// readiness gate's bounded timers (`HoldPolicy.permissionRequestAllowance` /
    /// `.noSignalAllowance`) safe to be aggressive about.
    ///
    /// It claims only what is known: the deck can confirm a landing
    /// (`PostToolUse`) but can never confirm the absence of one, so it says "no
    /// confirmation in time", never "none is coming" (a false "failed" claim
    /// invites a duplicate tap). `nil` at rest; cleared when a NEW plan starts
    /// (`forwardPlanStarted`, which also requires `forwardSentAt == nil`) or the
    /// mirror resolves by any door, since a stale notice surviving a fresh attempt
    /// would be worse than none.
    public var forwardUnconfirmedAt: Instant?

    public init(call: QuestionCall, stage: MirrorStage, permissionRequestSeenAt: Instant? = nil,
                forwardSentAt: Instant? = nil, forwardUnconfirmedAt: Instant? = nil) {
        self.call = call; self.stage = stage
        self.permissionRequestSeenAt = permissionRequestSeenAt
        self.forwardSentAt = forwardSentAt
        self.forwardUnconfirmedAt = forwardUnconfirmedAt
    }
}

// ------------------------------------------------------------- V2 forwarding

/// One keystroke a forward plan sends: a scripted answer aimed at the
/// TERMINAL's interactive picker once a mirror is `.terminalLive`, never at
/// anything the deck holds.
public enum ForwardStep: Equatable, Sendable {
    /// A digit or typed text, sent as literal BYTES (`CmuxHost.send`, the call
    /// `.dialogKey` answers a permission with). **Never `sendKey`**: cmux `send-key`
    /// rejects digit keys (`Unknown key`; see `DeckRuntime`'s comment), and by
    /// extension any literal text.
    case bytes(String)
    /// A named key with no byte form (`CmuxHost.sendKey`): `"down"` for
    /// multi-select navigation, `"enter"` for submission. Enter is a NAMED key, not
    /// a `"\n"` byte (see `DeckRuntime.drain()`, `.prompt`).
    case key(String)
}

/// A scripted sequence of `ForwardStep`s that answers ONE question by
/// keystroke. Reducer-owned state: `DeckRuntime` steps through it and reports
/// back, and never decides what the NEXT step is.
public struct ForwardPlan: Equatable, Sendable {
    public let hold: HoldID
    public let steps: [ForwardStep]
    /// The step about to run; `steps.count` once every step has been sent
    /// (`isComplete`).
    public var cursor: Int

    public init(hold: HoldID, steps: [ForwardStep], cursor: Int = 0) {
        self.hold = hold; self.steps = steps; self.cursor = cursor
    }

    public var isComplete: Bool { cursor >= steps.count }
    public var currentStep: ForwardStep? { steps.indices.contains(cursor) ? steps[cursor] : nil }
}

/// Builds a `ForwardPlan`'s steps from a question's shape. Pure, and the only
/// place that decides what a tap sends. Every rule is read off the LV38
/// corpus's recorded grammar; the fixture backing each is named below.
public enum ForwardPlanBuilder {

    /// - Single-select: one digit answers outright (LV38 `race`,
    ///   `held-released`/`terminal-answered`). `labels` must name exactly one of
    ///   the question's options; anything else refuses rather than guess.
    /// - Multi-select: a TOGGLE digit for every option in `labels`, each toggling
    ///   regardless of focus (LV38 `multiselect-one-pick`: a digit toggles a
    ///   checkbox even when it is not the focused row, and a stray `enter` on a
    ///   focused row toggles it AGAIN, so this plan never sends `enter` between
    ///   toggles). Then `"down"` past every remaining option and the built-in
    ///   "Type something" row to reach "Submit". The down-arrow COUNT is computed,
    ///   not byte-verified: LV38 recorded the wire bytes, not a log of keystrokes,
    ///   so it rests on the recorded row order (options, "Type something",
    ///   "Submit", one row each). It also assumes a digit toggle moves focus onto
    ///   the row it toggled, which is why counting starts from `lastIndex`; the
    ///   stray `enter` in `multiselect-one-pick` shows this directly. `"enter"` on
    ///   Submit opens "Review your answers"; digit `"1"` there submits (LV38
    ///   `multiselect-two-picks`).
    /// - Other: refuses when `otherText` is empty. A bare `enter` on the unfocused
    ///   "Type something" row with no text submits an EMPTY answer, reported as
    ///   "User declined to answer questions": unrecoverable and indistinguishable
    ///   from a real decline. The option's digit FOCUSES the row (LV38
    ///   `other-freetext`; it does not submit), the text follows as literal bytes,
    ///   `"enter"` submits.
    ///
    /// `nil` when the request cannot be built honestly: a multi-select call with
    /// empty `labels`, a single-select call with `labels` not exactly one
    /// recognised option, or empty or whitespace-only Other text. A plan that
    /// cannot be built with confidence must not run (graceful degradation): better
    /// to leave the mirror `.terminalLive` for a person than to send keys toward an
    /// outcome nobody chose.
    public static func build(for question: Question, picking labels: [Redacted],
                             otherText: Redacted? = nil) -> [ForwardStep]? {
        let optionCount = question.options.count

        if let otherText {
            guard !otherText.isEmpty else { return nil }
            let otherDigit = optionCount + 1
            return [.bytes(String(otherDigit)), .bytes(otherText.value), .key("enter")]
        }

        guard !labels.isEmpty else { return nil }

        if !question.multiSelect {
            guard labels.count == 1,
                  let index = question.options.firstIndex(where: { $0.label == labels[0] })
            else { return nil }
            return [.bytes(String(index + 1))]
        }

        // Ascending option order, never the caller's `labels` order, so the same
        // set picked in a different sequence builds the IDENTICAL plan, and
        // `lastIndex` is always the highest option touched, which minimises (and
        // makes deterministic) the run of `"down"` presses that follows.
        let indices = question.options.indices.filter { labels.contains(question.options[$0].label) }
        guard indices.count == labels.count else { return nil }   // every label must name a real option

        var steps: [ForwardStep] = indices.map { .bytes(String($0 + 1)) }
        let lastIndex = indices.max() ?? 0
        // Rows below the options: "Type something" at `optionCount`, "Submit" at
        // `optionCount + 1` (0-indexed), so this many presses reach Submit from the
        // last toggled option.
        let downs = (optionCount + 1) - lastIndex
        steps.append(contentsOf: Array(repeating: .key("down"), count: downs))
        steps.append(.key("enter"))          // opens "Review your answers"
        steps.append(.bytes("1"))            // submits from the review screen
        return steps
    }
}
