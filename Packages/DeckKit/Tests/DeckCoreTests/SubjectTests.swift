//
//  SubjectTests.swift · Tests/DeckCoreTests
//
//  Subject fidelity: the caption a tool wrote about itself, the one tool
//  whose subject is a markdown plan rather than a command, and the overflow
//  affordance both of them can outgrow.
//

import Testing
import DeckCore

struct SubjectTests {

    // ------------------------------------------------------------ caption

    /// The audit's own citation, replayed: the LVV-permission fixture's
    /// `PermissionRequest` carries `tool_input: {command, description}`, and
    /// before this pass that `description` key was discarded before anything
    /// could render it. `Corpus.permissionRun()` decodes the recording
    /// through the product's own ingest, so this exercises `SubjectReader`
    /// rather than re-deriving its answer by hand. The Swift-side property is
    /// `caption` — the wire's own key stays spelled `description` (`Subject
    /// .caption`'s own doc comment says why the two names diverge).
    @Test("Bash's caption binds alongside its command, off the LVV-permission fixture")
    func captionBindsForBashFromTheLVVFixture() {
        let events = Corpus.permissionRun()
        guard let request = events.first(where: { $0.kind == .permissionRequest }) else {
            Issue.record("the fixture lost its PermissionRequest row")
            return
        }
        #expect(request.subject?.field == "command")
        #expect(request.subject?.detail?.value == "git push --force origin main")
        #expect(request.subject?.caption?.value == "Force push local main to origin/main")
    }

    /// The naming table's own no-invention rule, applied to the new field: a
    /// tool absent from `captionField` yields `caption == nil` even when the
    /// payload it was actually given happens to carry a key spelled
    /// `description` — binding it anyway would be exactly the guess
    /// `fallbackKeys` is allowed to make for a PRIMARY field and `caption`
    /// deliberately is not (see `SubjectReader.captionField`'s own doc
    /// comment for why the two are held to different standards).
    @Test("caption stays nil for a tool the naming table has not vouched for")
    func captionStaysNilOutsideTheCaptionTable() throws {
        let input = try #require(JSONValue.parse(
            #"{"file_path":"/a/b.txt","description":"a caption Read has never been seen to carry"}"#))
        let subject = SubjectReader.subject(tool: "Read", input: input)
        #expect(subject?.detail?.value == "/a/b.txt")
        #expect(subject?.caption == nil)
    }

    /// The ordering the provenance rule already enforces between `detail`
    /// and `field`, extended to `caption`: a caption with no detail beside it
    /// would be labelling bytes the frame is not showing, so a tool whose
    /// primary key was missing gets no caption either, even if the
    /// `description` key itself was present.
    @Test("caption does not bind when the tool's own detail could not be read")
    func captionStaysNilWithoutADetail() throws {
        let input = try #require(JSONValue.parse(
            #"{"description":"a caption with nothing to caption"}"#))
        let subject = SubjectReader.subject(tool: "Bash", input: input)
        #expect(subject?.detail == nil)
        #expect(subject?.caption == nil)
    }

    // ------------------------------------------------------- ExitPlanMode

    /// **No fixture exists for this.** `LV14-plan` — this corpus's one
    /// recorded planning session, walked end to end in `Corpus.liveRun`'s
    /// own doc comment — never once calls `ExitPlanMode`; grepped to be
    /// sure (`grep -c ExitPlanMode` over its `payloads.ndjson` is `0`). The
    /// shape below is built by hand from the CLI's documented schema —
    /// `tool_input.plan` — the same "published, not recorded" standing
    /// `SubjectReader.namingField`'s own doc comment now states for the
    /// entry this test exercises.
    @Test("ExitPlanMode's subject is its plan, read off tool_input.plan")
    func exitPlanModeSubjectFromAConstructedPayload() {
        let plan = "1. Read the config loader\n2. Add the new flag\n3. Wire it into Settings"
        let input = JSONValue.object(["plan": .string(plan)])
        let subject = SubjectReader.subject(tool: "ExitPlanMode", input: input)
        #expect(subject?.field == "plan")
        #expect(subject?.detail?.value == plan)
        // No caption key is claimed for this tool — `captionField` has no
        // entry for it, and a plan is not a shell command with a 5–10-word
        // caption; inventing one here would be the same mistake
        // `captionStaysNilOutsideTheCaptionTable` guards against.
        #expect(subject?.caption == nil)
    }

    /// The empty-slot rule's ordinary case, checked against the one new
    /// entry: a `PreToolUse` for the tool with no `plan` key at all still
    /// yields a subject, just one with no detail — never a crash, never a
    /// subject silently dropped.
    @Test("ExitPlanMode with no plan key yields an unlabelled subject, not nothing")
    func exitPlanModeWithNoPlanKey() {
        let subject = SubjectReader.subject(tool: "ExitPlanMode", input: JSONValue.object([:]))
        #expect(subject?.tool == "ExitPlanMode")
        #expect(subject?.detail == nil)
        #expect(subject?.field == nil)
    }

    // ------------------------------------------------------- display name

    /// `ExitPlanMode`'s dialog never prints its own wire name — see
    /// `Subject.displayName`'s own doc comment — so the fallback word this
    /// deck shows when there is truly nothing else reads "Plan", not the
    /// literal tool string the audit found on screen.
    @Test("ExitPlanMode's display name is Plan, not its wire name")
    func exitPlanModeDisplayName() {
        let subject = Subject(tool: "ExitPlanMode", detail: nil, field: nil)
        #expect(subject.displayName == "Plan")
    }

    /// And every tool this has not been checked for falls straight through
    /// unchanged — the table stays small on purpose.
    @Test("every other tool's display name is its own wire name",
          arguments: ["Bash", "Read", "SomeToolInventedNextMonth"])
    func otherToolsKeepTheirWireName(_ tool: String) {
        let subject = Subject(tool: tool, detail: nil, field: nil)
        #expect(subject.displayName == tool)
    }

    // ------------------------------------------------------- overflow chip

    /// The floor: text that fits inside the collapsed well outright needs no
    /// chip at all — including the boundary itself, four lines exactly.
    @Test("no chip at or under the collapsed line count", arguments: [0, 1, 4])
    func noChipWithinCollapsedLines(_ lines: Int) {
        let text = lines == 0 ? "" : (1...lines).map { "line \($0)" }.joined(separator: "\n")
        #expect(SubjectOverflow.chipText(for: text) == nil,
                Comment(rawValue: "\(lines) lines should fit inside the collapsed well"))
    }

    /// Past the boundary, the chip counts only what the collapsed well is
    /// NOT showing — "more" is a claim about what's hidden, not the total.
    @Test("the chip counts hidden lines, not total lines")
    func chipCountsHiddenLinesOnly() {
        let twelveLines = (1...12).map { "line \($0)" }.joined(separator: "\n")
        #expect(SubjectOverflow.chipText(for: twelveLines) == "▾ 8 more lines")
    }

    /// One hidden line reads as singular — the kind of small correctness
    /// this codebase has already spent care on elsewhere (`HandedBackNotice`'s
    /// split copy, "≥ N muted" never a bare count).
    @Test("exactly one hidden line reads as singular")
    func chipSingularForOneHiddenLine() {
        let fiveLines = (1...5).map { "line \($0)" }.joined(separator: "\n")
        #expect(SubjectOverflow.chipText(for: fiveLines) == "▾ 1 more line")
    }

    /// **The N-label rule**, reworked from what used to be named
    /// `lineCountIsNewlineOnly`: a single very long line is still ONE line
    /// by newline arithmetic, so `chipText` — the function that can only
    /// ever offer a STATED count — correctly declines to claim one. This is
    /// no longer the last word on whether a chip shows at all: `SubjectWell`
    /// layers a MEASURED check on top precisely for this shape (a
    /// newline-free line that visibly wraps), captioned "▾ more" rather than
    /// a number this pure function never had grounds to claim
    /// (`SubjectOverflow.wrapOnlyChipText`'s own doc comment; the render-level
    /// proof is `RenderSweepTests.theSubjectWellRendersAWrapOnlyChip`). What
    /// this test still holds is narrower and just as real: `lineCount` and
    /// `chipText` themselves stay newline-only, and undercounting here is
    /// the stated, honest failure mode rather than a silently wrong number.
    @Test("chipText never claims a number it cannot back for a wrap-only line")
    func chipTextNeverClaimsANumberForAWrapOnlyLine() {
        let oneLongLine = String(repeating: "x", count: 500)
        #expect(SubjectOverflow.lineCount(oneLongLine) == 1)
        #expect(SubjectOverflow.chipText(for: oneLongLine) == nil,
                Comment(rawValue: "a single physical line never gets a NUMBERED chip from this pure "
                        + "function, however wide it renders — SubjectWell's measured check is a "
                        + "separate mechanism"))
    }

    @Test("an empty string is zero lines, not one")
    func lineCountOfEmptyStringIsZero() {
        #expect(SubjectOverflow.lineCount("") == 0)
    }

    /// Item 4: a trailing newline terminates the last line, it does not
    /// start a phantom empty one after it — `"a\nb\nc\nd\n"` is four lines,
    /// the same count a text editor would show for a file whose last line
    /// ends with `\n`, not five.
    @Test("a trailing newline does not add a phantom line")
    func trailingNewlineDoesNotAddAPhantomLine() {
        #expect(SubjectOverflow.lineCount("a\nb\nc\nd\n") == 4)
        #expect(SubjectOverflow.lineCount("a\nb\nc\nd") == 4,
                "the same text without the trailing newline should count identically")
    }

    /// The trailing-drop is narrow — only the FINAL empty component, from
    /// the string simply ending on a newline. A genuine blank line in the
    /// middle is not an artifact and still counts.
    @Test("a blank line in the middle still counts, only the trailing artifact is dropped")
    func middleBlankLineStillCounts() {
        #expect(SubjectOverflow.lineCount("a\n\nb") == 3, "a, blank, b — three lines")
        #expect(SubjectOverflow.lineCount("a\n\nb\n") == 3,
                "same three lines, with the trailing newline that terminates \"b\" dropped")
    }

    /// A string that is nothing BUT a trailing newline: one (empty) line,
    /// not zero and not two — the same reading `lineCountOfEmptyStringIsZero`
    /// gives the true empty string, extended to the one-character case.
    @Test("a single newline is one empty line, not two")
    func singleNewlineIsOneLine() {
        #expect(SubjectOverflow.lineCount("\n") == 1)
    }

    // ------------------------------------------------- preview clip marker

    /// The floor, `PreviewOverflow`'s own version of `noChipWithinCollapsedLines`
    /// above: a preview with no more source lines than the budget shows
    /// gets no marker at all — including the boundary itself, exactly
    /// `visibleLines` lines.
    @Test("no clip marker at or under the visible-line budget",
          arguments: [0, 1, PreviewOverflow.visibleLines])
    func noMarkerWithinVisibleLines(_ lines: Int) {
        let text = lines == 0 ? "" : (1...lines).map { "line \($0)" }.joined(separator: "\n")
        #expect(!PreviewOverflow.clips(text),
                Comment(rawValue: "\(lines) lines should fit inside the visible-line budget"))
        #expect(PreviewOverflow.marker(for: text) == nil)
    }

    /// One line past the boundary, the budget's floor and the marker's
    /// arithmetic in the same test: `visibleLines` itself does not clip,
    /// `visibleLines + 1` does, by exactly one hidden line.
    @Test("one line past the budget clips by exactly one hidden line")
    func oneLinePastTheBudgetClipsByOne() {
        let atBudget = (1...PreviewOverflow.visibleLines).map { "line \($0)" }.joined(separator: "\n")
        let onePast = atBudget + "\nline \(PreviewOverflow.visibleLines + 1)"
        #expect(!PreviewOverflow.clips(atBudget))
        #expect(PreviewOverflow.clips(onePast))
    }

    /// Past the boundary, the marker counts only what the cap is NOT
    /// showing — "hidden", not "total" — the same reading `SubjectOverflow
    /// .chipText`'s own `chipCountsHiddenLinesOnly` holds itself to for the
    /// deck's other overflow affordance.
    @Test("the marker counts hidden lines past the budget, not the total")
    func markerCountsHiddenLinesOnly() {
        let lines = PreviewOverflow.visibleLines + 4
        let text = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        #expect(PreviewOverflow.clips(text))
        #expect(PreviewOverflow.marker(for: text) == "✂ 4 lines hidden")
    }

    /// **Dialog parity, grammar included.** Claude Code's own terminal
    /// prints "✂ 1 lines hidden" for exactly one hidden line — not the
    /// grammatically correct "1 line" — and this deck quotes that exactly,
    /// agrammatical plural and all, rather than silently correcting copy
    /// that is not the deck's own to correct. `SubjectOverflow.chipText`
    /// (this file's own `chipSingularForOneHiddenLine`, just above) makes
    /// the OPPOSITE choice on purpose: that chip is copy the deck authored
    /// for itself; this marker is copy the deck is quoting from the
    /// terminal.
    @Test("exactly one hidden line still reads as the terminal's agrammatical plural")
    func markerStaysPluralForOneHiddenLine() {
        let lines = PreviewOverflow.visibleLines + 1
        let text = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        #expect(PreviewOverflow.marker(for: text) == "✂ 1 lines hidden")
    }

    /// Zero hidden lines is not a marker reading "0" — the empty-slot rule
    /// applied to this affordance: nothing hidden means no marker at all,
    /// never an honest but useless "✂ 0 lines hidden".
    @Test("zero hidden lines means no marker, not a zero count")
    func noMarkerForZeroHiddenLines() {
        let text = (1...PreviewOverflow.visibleLines).map { "line \($0)" }.joined(separator: "\n")
        #expect(PreviewOverflow.marker(for: text) == nil)
    }

    /// **Trailing newline.** `renderText`'s own doc
    /// comment has the measurement: `.callout.monospaced()` `Text` renders
    /// one MORE visual row for a trailing `"\n"` than `lineCount` counts
    /// (8 lines measured 120 pt; the same 8 lines plus one trailing `"\n"`
    /// measured 135 pt). `renderText` closes that gap by dropping exactly
    /// one trailing newline — never more, matching `lineCount`'s own
    /// restraint — so what gets rendered and what gets counted describe
    /// the same text again.
    @Test("renderText drops exactly one trailing newline, and nothing else")
    func renderTextDropsExactlyOneTrailingNewline() {
        #expect(PreviewOverflow.renderText("a\nb\n") == "a\nb",
                "a single trailing newline should be dropped")
        #expect(PreviewOverflow.renderText("a\nb") == "a\nb",
                "text with no trailing newline should be unchanged")
        #expect(PreviewOverflow.renderText("a\nb\n\n") == "a\nb\n",
                "only the FINAL trailing newline is dropped — a genuine blank line stays")
        #expect(PreviewOverflow.renderText("") == "", "an empty string has nothing to drop")
        #expect(PreviewOverflow.renderText("\n") == "",
                "a lone newline is one empty line's worth of trailing artifact, dropped to nothing")
    }

    /// The bug itself, at the exact boundary: a preview at PRECISELY
    /// `visibleLines` lines by `lineCount` — so `clips`/`marker` correctly
    /// see nothing to cap — but ending in a trailing `"\n"`, the shape that
    /// rendered one row past the budget, uncapped, before `renderText`
    /// existed. `lineCount` (unchanged, and correctly so — `SubjectWell`
    /// shares it and has no reason to read a trailing newline differently)
    /// still calls this `visibleLines` lines; `renderText` is what makes
    /// the RENDERED text agree with that count instead of adding a row
    /// `lineCount` never promised.
    @Test("a preview at exactly the visible-line budget with a trailing newline still counts as in-budget, and renderText keeps it that way")
    func trailingNewlineAtTheBoundaryDoesNotCoverIntoAPhantomLine() {
        let atBudget = (1...PreviewOverflow.visibleLines).map { "line \($0)" }.joined(separator: "\n")
        let withTrailingNewline = atBudget + "\n"
        #expect(SubjectOverflow.lineCount(withTrailingNewline) == PreviewOverflow.visibleLines,
                "lineCount's own trailing-artifact rule should still read this as in-budget")
        #expect(!PreviewOverflow.clips(withTrailingNewline), "in-budget text should not clip")
        #expect(PreviewOverflow.renderText(withTrailingNewline) == atBudget,
                "renderText should restore exactly the in-budget text, dropping the added newline")
    }

    /// The three RECORDED LV37 previews, through the real ingest rather than
    /// hand-built text — 12, 19 and 10 lines
    /// (`QuestionPreviewFixtureTests.ingestDecodesAllThreePreviews` pins the
    /// same three numbers off the same fixture). All three land past
    /// `visibleLines`, so all three clip: this corpus does not yet hold a
    /// recorded preview short enough to prove the does-NOT-clip path
    /// against a real terminal capture, only the synthetic boundary tests
    /// above do that.
    @Test("the three recorded LV37 previews all clip under the cap's line budget")
    func recordedLV37PreviewsClip() {
        let events = Corpus.questionPreviewRun()
        guard let ask = events.first(where: { $0.kind == .preToolUse && $0.tool == SubjectReader.questionTool })
        else {
            Issue.record("the fixture lost its AskUserQuestion PreToolUse row")
            return
        }
        let previews = ask.questions.first?.options.compactMap { $0.preview?.value } ?? []
        #expect(previews.count == 3, "the fixture lost one of its three previewed options")
        #expect(previews.map(SubjectOverflow.lineCount) == [12, 19, 10],
                "the recorded preview line counts moved — this test's own premise")
        #expect(previews.allSatisfy(PreviewOverflow.clips),
                "a recorded preview stopped clipping — either the budget or the fixture moved")
        #expect(previews.map { PreviewOverflow.marker(for: $0) } ==
                ["✂ 4 lines hidden", "✂ 11 lines hidden", "✂ 2 lines hidden"])
    }

    // -------------------------------------------------------- visible text

    /// A clipping preview truncates to EXACTLY `visibleLines` lines —
    /// replacing the old per-preview inner
    /// scroll: a preview's own cell is now static content, not a
    /// scrollable capped region, so what gets rendered has to BE the
    /// truncation rather than merely fit inside one.
    @Test("visibleText truncates a clipping preview to exactly the visible-line budget")
    func visibleTextTruncatesClippingPreviews() {
        let lines = PreviewOverflow.visibleLines + 5
        let text = (1...lines).map { "line \($0)" }.joined(separator: "\n")
        let expected = (1...PreviewOverflow.visibleLines).map { "line \($0)" }.joined(separator: "\n")
        #expect(PreviewOverflow.visibleText(text) == expected)
        #expect(SubjectOverflow.lineCount(PreviewOverflow.visibleText(text)) == PreviewOverflow.visibleLines)
    }

    /// A preview that does NOT clip passes through unchanged (past
    /// `renderText`'s own trailing-newline fix) — `visibleText` is not a
    /// second, competing truncation rule, it is `previewBlock`'s ONE entry
    /// point for both shapes.
    @Test("visibleText leaves a non-clipping preview unchanged, past renderText's own fix")
    func visibleTextLeavesShortPreviewsUnchanged() {
        let text = (1...PreviewOverflow.visibleLines).map { "line \($0)" }.joined(separator: "\n")
        #expect(PreviewOverflow.visibleText(text) == text)
        #expect(PreviewOverflow.visibleText(text + "\n") == text,
                "the trailing-newline fix should still apply even when nothing clips")
    }

    // --------------------------------------------------- options band overflow

    /// The floor: a single previewed option — clipping or not — is never
    /// reported as hiding "more options", because there ARE no more. This
    /// is a correctness fix: an earlier draft counted a tall
    /// option's own un-scrolled-into content as a hidden OPTION, which
    /// would have made a one-option previewed question falsely claim
    /// "▾ 1 more option" when there is no second option at all.
    @Test("a single previewed option is never reported as hiding more options")
    func singlePreviewedOptionNeverClaimsMoreOptions() {
        #expect(QuestionOptionsBand.visibleOptionCount(hasPreview: [true]) == 1)
        #expect(QuestionOptionsBand.moreOptionsText(total: 1, visible: 1) == nil)
    }

    /// The recorded LV37 shape: three previewed options, the band's own
    /// `maxHeight` only wide enough for the first to even START rendering
    /// — `QuestionOptionsBand.maxHeight`'s own doc comment cites this
    /// exact figure as its arbiter.
    @Test("three previewed options report one visible and two hidden, matching the recorded LV37 shape")
    func threePreviewedOptionsReportOneVisibleTwoHidden() {
        let visible = QuestionOptionsBand.visibleOptionCount(hasPreview: [true, true, true])
        #expect(visible == 1)
        #expect(QuestionOptionsBand.moreOptionsText(total: 3, visible: visible) == "▾ 2 more options")
    }

    /// Grammar matches `SubjectOverflow.chipText`'s own house style exactly
    /// — singular for one hidden, plural otherwise — the same "small
    /// correctness this codebase has already spent care on elsewhere" its
    /// own sibling test says of the subject well's chip.
    @Test("moreOptionsText reads singular for exactly one hidden option")
    func moreOptionsTextSingularForOneHidden() {
        #expect(QuestionOptionsBand.moreOptionsText(total: 2, visible: 1) == "▾ 1 more option")
        #expect(QuestionOptionsBand.moreOptionsText(total: 4, visible: 1) == "▾ 3 more options")
    }

    /// Zero hidden means no marker — the empty-slot rule, applied to this
    /// affordance the same as every other optional in this file: a marker
    /// for nothing hidden would be announcing an overflow that never
    /// happened.
    @Test("moreOptionsText is nil when nothing is hidden")
    func moreOptionsTextNilWhenNothingHidden() {
        #expect(QuestionOptionsBand.moreOptionsText(total: 2, visible: 2) == nil)
        #expect(QuestionOptionsBand.moreOptionsText(total: 0, visible: 0) == nil)
    }

    /// **Honest about what the current `maxHeight` actually lets through —
    /// and the old comment here got exactly the future edit it asked for.**
    /// A MIXED question — some options previewed, some bare — is so far a
    /// SYNTHETIC shape only: no recorded question mixes them.
    /// `Corpus.planModeQuestionPayload` comes closest — its call carries
    /// previews on exactly two options across three questions — but the
    /// question those two belong to previews BOTH its options, so even
    /// there no single question is mixed. `visibleOptionCount` checks a
    /// SECOND row's TOP EDGE only, not its full height (its own doc
    /// comment), so what decides visibility is `usedByRow1 + rowSpacing`
    /// against `maxHeight`, not the sum of both rows.
    ///
    /// At `maxHeight`'s earlier figure of 61, that check failed for
    /// EVERY leading-row type: a bare row costs `TouchTarget.decision`'s 64
    /// alone, already past 61 before `rowSpacing` is even added, so the
    /// bare/previewed distinction never got to matter — every shape showed
    /// exactly one option, whatever it was. Retuned to 78
    /// (`usableStripHeight`'s own retune propagated — see that constant's
    /// doc comment), a leading BARE row's second-row check now reads
    /// `64 + 10 = 74`, four points UNDER 78: reachable. A leading PREVIEWED
    /// row's does not move — `previewRowHeight`'s 208 clears 78 on its own,
    /// nowhere near either figure — so that shape is unchanged. This is not
    /// a bug this test papers over — it is the honest, current, and rather
    /// narrow-margin (4 pt) behaviour, pinned so a future change to
    /// `maxHeight`, `TouchTarget.decision`, or `rowSpacing` that moves that
    /// margin is a deliberate edit, not a silent one.
    @Test("a leading bare row now lets a second row's top edge show at the retuned maxHeight; a leading previewed row still does not")
    func secondRowVisibilityDependsOnTheLeadingRowsType() {
        #expect(QuestionOptionsBand.visibleOptionCount(hasPreview: [false, false]) == 2,
                "two bare rows: option 2's top edge (64 + 10 = 74) now clears the retuned 78 pt ceiling")
        #expect(QuestionOptionsBand.visibleOptionCount(hasPreview: [true, false]) == 1,
                "a leading previewed row (208 pt) clears the ceiling alone — option 2 is never reached")
        #expect(QuestionOptionsBand.visibleOptionCount(hasPreview: [false, true, true]) == 2,
                "a leading bare row lets option 2's top edge show (74); option 3's does not (282 + 10 = 292)")
    }

    // -------------------------------------------------------- Question.hasPreview

    /// The one rule `Decision.currentQuestionHasPreview` and
    /// `QuestionTakeover`'s own layout split both read — named once so the
    /// two cannot quietly diverge into two spellings of "does this question
    /// carry a preview".
    @Test("hasPreview is true the moment any option carries a preview")
    func hasPreviewTrueWithAnyPreviewedOption() {
        let bare = Question(text: Redacted("Which?"), header: Redacted("Q"),
                            options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                      QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                            multiSelect: false)
        #expect(!bare.hasPreview)

        let mixed = Question(text: Redacted("Which?"), header: Redacted("Q"),
                             options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                       QuestionOption(label: Redacted("B"), detail: Redacted(""),
                                                      preview: Redacted("mockup"))],
                             multiSelect: false)
        #expect(mixed.hasPreview)
    }

    // ---------------------------------------------------- AnswerProgress.freeText

    /// The typed answer left behind — the one entry in `picked` naming
    /// nothing the question offers. `nil` when nothing has been typed, or
    /// when every picked label names an offered option.
    @Test("freeText finds the one picked label naming none of the question's own options")
    func answerProgressFreeTextFindsTheOutOfOptionsEntry() {
        let question = Question(text: Redacted("Which?"), header: Redacted("Q"),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: true)

        let nothingTyped = AnswerProgress(picked: [Redacted("A")])
        #expect(nothingTyped.freeText(in: question) == nil,
                "a picked label that names an offered option was read as free text")

        let typed = AnswerProgress(picked: [Redacted("A"), Redacted("something else entirely")])
        #expect(typed.freeText(in: question)?.value == "something else entirely")

        let empty = AnswerProgress()
        #expect(empty.freeText(in: question) == nil)
    }

    // --------------------------------------------------------------- OptionTap

    /// **`QuestionStage`'s own two-tap rule, pure.** A tap on a row that is
    /// not already focused only moves focus; a tap on the row already
    /// focused is the one that answers. Digit shortcuts never go through
    /// this — `QuestionStageInteraction.tap`'s own doc comment states why —
    /// so this covers the TAP path exclusively.
    @Test("a tap on an unfocused row focuses it; a tap on the focused row picks it")
    func tapFocusesThenPicks() {
        #expect(QuestionStageInteraction.tap(0, focusedIndex: 0) == .pick(0),
                "the default-focused row's own tap should answer immediately")
        #expect(QuestionStageInteraction.tap(2, focusedIndex: 0) == .focus(2),
                "tapping an unfocused row should move focus, not answer")
        #expect(QuestionStageInteraction.tap(2, focusedIndex: 2) == .pick(2),
                "a second tap on the now-focused row should answer")
    }

    // ------------------------------------------------- Decision.showsStage

    private func question(withPreview: Bool) -> Question {
        Question(text: Redacted("Which?"), header: Redacted("Q"),
                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""),
                                         preview: withPreview ? Redacted("mockup") : nil)],
                multiSelect: false)
    }

    /// The fork `DeckWindow` (the overlay) and `DetailBand` (the pinned
    /// takeover it must suppress) both read. A bare question — however many
    /// steps it has — never shows the stage; a previewed one does, until its
    /// OWN hold is the one dismissed.
    @Test("currentQuestionHasPreview and showsStage read the current step, not just any step")
    func currentQuestionHasPreviewReadsTheCurrentStep() {
        let hold = HoldID(session: SessionID("s1"), toolUseID: "t1")
        // Step 0 is bare, step 1 carries a preview — `progress.step` decides
        // which one `currentQuestion` (and therefore both properties below)
        // actually sees.
        let decision = Decision(hold: hold, subject: nil,
                                questions: [question(withPreview: false), question(withPreview: true)],
                                progress: AnswerProgress(step: 0))
        #expect(!decision.currentQuestionHasPreview,
                "step 0 is bare, but the decision claimed a preview anyway")
        #expect(!decision.showsStage(dismissedStage: nil))

        let onStepOne = Decision(hold: hold, subject: nil,
                                 questions: decision.questions,
                                 progress: AnswerProgress(step: 1))
        #expect(onStepOne.currentQuestionHasPreview,
                "step 1 carries a preview, but the decision missed it")
        #expect(onStepOne.showsStage(dismissedStage: nil))
    }

    @Test("showsStage is false only for the exact hold that was dismissed")
    func showsStageRespectsDismissalByHoldIdentity() {
        let dismissed = HoldID(session: SessionID("s1"), toolUseID: "t1")
        let other = HoldID(session: SessionID("s1"), toolUseID: "t2")
        let previewed = question(withPreview: true)

        let dismissedDecision = Decision(hold: dismissed, subject: nil, questions: [previewed])
        #expect(!dismissedDecision.showsStage(dismissedStage: dismissed),
                "the dismissed hold's own decision should not re-show the stage")

        let otherDecision = Decision(hold: other, subject: nil, questions: [previewed])
        #expect(otherDecision.showsStage(dismissedStage: dismissed),
                "a DIFFERENT hold — a fresh call — must not stay suppressed by a previous dismissal")

        #expect(dismissedDecision.showsStage(dismissedStage: nil),
                "with nothing dismissed, the same decision should show the stage")
    }
}
