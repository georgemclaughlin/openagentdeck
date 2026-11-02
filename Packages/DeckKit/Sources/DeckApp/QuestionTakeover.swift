//
//  QuestionTakeover.swift · DeckApp
//
//  Answering an `AskUserQuestion` call on the deck.
//
//  Tier 1 of the spec: tapping options answers outright; the frontend picker
//  never renders.
//
//  Everything it needs is in the frame. The step, the answers gathered so far
//  and the options picked but not sent live in `AnswerProgress`, in the
//  reducer, because a stepper held in `@State` resets when the view is rebuilt
//  (a display waking up would lose a half-answered question). This file holds
//  nothing: it draws the progress it is given and sends taps back.
//

import SwiftUI
import Foundation
import DeckCore

struct QuestionTakeover: View {
    let decision: Decision
    let runtime: DeckRuntime
    /// Test seam only: production always starts with the "Other…" field
    /// collapsed (`OtherAnswerField`'s default). Lets
    /// `RenderSweepTests.theTakeoverInteriorNeverClipsInTheLiveRecordedShape`
    /// measure the expanded field in the composed takeover.
    var otherFieldInitiallyExpanded: Bool = false
    /// Test seam only: half of the takeover's "bottom-most interactive
    /// element" probe (`onControlsFrameMeasured` is the other half). Reports
    /// `OtherAnswerField`'s frame in the named coordinate space an ancestor
    /// established (`DetailBand`'s `detailBandRootSpace`); harmless if none
    /// exists.
    var onOtherFieldFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only, same reason as `onOtherFieldFrameMeasured`.
    /// `QuestionControls` renders nothing (`.isEmpty`) on a single-select
    /// question's first step, so a probe on `OtherAnswerField` alone cannot
    /// tell "no controls to clip" from "the probe never fired".
    var onControlsFrameMeasured: ((CGRect) -> Void)?

    private var progress: AnswerProgress { decision.progress ?? AnswerProgress() }
    private var question: Question? { decision.currentQuestion }

    /// True while `OtherAnswerField`'s text field is open, hoisted out of that
    /// view's `@State` so the shortcuts below can read it. On macOS none of
    /// `.keyboardShortcut`, `.leftArrow` or `.defaultAction` suppress
    /// themselves while a `TextField` has focus, so the only fix is not
    /// attaching the shortcut at all while a field is active (see
    /// `GatedShortcut`).
    @State private var otherFieldExpanded: Bool

    /// Explicit `init` so `otherFieldInitiallyExpanded` can seed `@State` (a
    /// synthesised memberwise init cannot see a `@State` property). Every
    /// parameter defaults to what a bare `decision`/`runtime` call gets.
    init(decision: Decision, runtime: DeckRuntime,
         otherFieldInitiallyExpanded: Bool = false,
         onOtherFieldFrameMeasured: ((CGRect) -> Void)? = nil,
         onControlsFrameMeasured: ((CGRect) -> Void)? = nil) {
        self.decision = decision
        self.runtime = runtime
        self.otherFieldInitiallyExpanded = otherFieldInitiallyExpanded
        self.onOtherFieldFrameMeasured = onOtherFieldFrameMeasured
        self.onControlsFrameMeasured = onControlsFrameMeasured
        _otherFieldExpanded = State(initialValue: otherFieldInitiallyExpanded)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let question {
                QuestionText(text: question.text.value)

                // Bare and previewed questions are two different shapes; see
                // `previewedOptionsBand` for why capping both loses options.
                if question.hasPreview {
                    previewedOptionsBand(for: question)
                } else {
                    options(for: question)
                }

                // The terminal's free-text escape ("Other…"), mirrored rather than
                // reinterpreted. Keyed to the question so switching questions
                // never shows a draft typed against a different one.
                OtherAnswerField(hold: decision.hold,
                                 currentFreeText: progress.freeText(in: question),
                                 step: progress.step,
                                 expanded: $otherFieldExpanded,
                                 runtime: runtime)
                    .id("\(decision.hold)-\(progress.step)")
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(detailBandRootSpace)) }
                        action: { onOtherFieldFrameMeasured?($0) }

                Text(question.multiSelect
                     ? "Choose as many as apply, then submit."
                     : "Tap an option to answer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            controls
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(detailBandRootSpace)) }
                    action: { onControlsFrameMeasured?($0) }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
        .overlay(alignment: .bottom) { Divider() }
        // Same reset as `OtherAnswerField`'s `.id()` above, applied to the
        // hoisted flag: a step or hold change must close the field along with
        // discarding its text, or a stale "expanded" flag would leave the
        // shortcuts refused on a question that never opened a field.
        .onChange(of: decision.hold) { _, _ in otherFieldExpanded = false }
        .onChange(of: progress.step) { _, _ in otherFieldExpanded = false }
    }

    // ------------------------------------------------------------- header

    private var header: some View {
        HStack(spacing: 8) {
            Label(question?.header.value ?? "Question", systemImage: "questionmark.circle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Spacer(minLength: 0)
            if decision.questions.count > 1 {
                // Which of how many: an all-or-nothing submit at the end is only
                // honest if you can see the end coming.
                Text("\(progress.step + 1) of \(decision.questions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Question \(progress.step + 1) of \(decision.questions.count)")
            }
        }
    }

    // ------------------------------------------------------------ options

    /// The bare path: no band, no cap. A grid that follows the width, since a
    /// call may carry two options or six on a strip or a window.
    /// `LazyVGrid` is safe here because nothing above it constrains its
    /// height (never inside a `ScrollView`), so SwiftUI builds every cell, as
    /// `previewedOptions` guarantees with a non-lazy container.
    private func options(for question: Question) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)],
                  spacing: 10) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionButton(option, index: index, of: question.options.count)
            }
        }
    }

    /// The previewed path: options in a height-capped scrolling band.
    ///
    /// The cap is load-bearing: `DetailBand` composes this view in a fixed-budget
    /// `VStack` with no `ScrollView`, so content past the budget clips silently
    /// instead of scrolling. The recorded LV37 question (3 options, each with a
    /// preview) measured 872 pt uncapped at 480 pt wide (885 pt at 380) against
    /// a usable strip height of `QuestionOptionsBand.usableStripHeight`, leaving
    /// only options 2 and 3 in reach.
    /// `RenderSweepTests.theRecordedLV37QuestionFitsTheUsableStrip` reproduces
    /// both numbers by setting the cap absurdly high.
    ///
    /// Only a question that carries a preview reaches this function (`hasPreview`).
    /// Capping bare questions too saturated 2/3/4-option calls to the same
    /// height, since `TouchTarget.decision` (64 pt) alone leaves no room for a
    /// second row under an 80 pt cap: options past the first were never drawn,
    /// with no chip or scroll hint ("same options, never a subset").
    ///
    /// `previewedOptions` is non-lazy and `moreOptionsText` states exactly what
    /// the band hides, the same overflow-honesty rule as
    /// `SubjectOverflow.chipText`.
    private func previewedOptionsBand(for question: Question) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ScrollView(.vertical) {
                previewedOptions(for: question)
            }
            .frame(maxWidth: .infinity, maxHeight: QuestionOptionsBand.maxHeight, alignment: .leading)
            if let marker = QuestionOptionsBand.moreOptionsText(
                total: question.options.count,
                visible: QuestionOptionsBand.visibleOptionCount(
                    hasPreview: question.options.map { $0.preview != nil })) {
                // Outside the scroller and static, not a `Button`: nothing here may
                // answer the question, only a tap on an option can.
                Text(marker)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The band's option list. Non-lazy, unlike `options(for:)`, because it sits
    /// in a height-constrained `ScrollView` where laziness is real: a
    /// `LazyVGrid` here built only the rows within the 80 pt initial viewport,
    /// and a keystroke is not a scroll gesture, so no rebuild ever created the
    /// rest for `.keyboardShortcut` to attach to (digit shortcuts were dead for
    /// scrolled-out rows). A plain `VStack` builds every option up front.
    ///
    /// Single column rather than the adaptive grid, on purpose: at wide widths
    /// the grid would set all three recorded previewed cells side by side.
    /// Previews' real home is the full-strip stage, and a container that can
    /// lazily drop a cell is worth more than a multi-column layout.
    private func previewedOptions(for question: Question) -> some View {
        VStack(alignment: .leading, spacing: QuestionOptionsBand.rowSpacing) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionButton(option, index: index, of: question.options.count)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One option's whole cell: the tappable answer button and, when the option
    /// carries one, the preview as a sibling below it, never inside the
    /// button's label (see `previewBlock`).
    ///
    /// Not `private`: a render-sweep floor measured only at the takeover's
    /// exterior is vacuous once a previewed cell saturates
    /// `QuestionOptionsBand.maxHeight` (the band reports its cap whether the
    /// preview works or silently collapsed). `internal` lets `RenderSweepTests`
    /// measure this cell at its own unconstrained height, where the
    /// sibling-move regression shows.
    func optionButton(_ option: QuestionOption, index: Int, of count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            answerButton(option, index: index, of: count)
            if let preview = option.preview {
                previewBlock(preview)
            }
        }
    }

    /// The tappable control: glyph, number, label, detail. The preview is not
    /// inside this label (see `previewBlock`), so this is the whole tap target.
    private func answerButton(_ option: QuestionOption, index: Int, of count: Int) -> some View {
        let isPicked = progress.picked.contains(option.label)
        return Button {
            runtime.pick(decision.hold, option.label)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                // A glyph, not just a fill: selection carried by colour alone is
                // invisible to a colour-blind user.
                Image(systemName: isPicked
                      ? (question?.multiSelect == true ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question?.multiSelect == true ? "square" : "circle"))
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                // The terminal numbers options 1., 2., 3., the same digits the
                // keyboard shortcut binds; show them on screen too.
                Text("\(index + 1).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text(option.label.value)
                        .font(.body.weight(isPicked ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !option.detail.value.isEmpty {
                        Text(option.detail.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .touchTarget(minHeight: TouchTarget.decision, minWidth: TouchTarget.minimum)
        // Selection is said as well as shown, for screen readers.
        .accessibilityLabel("Option \(index + 1) of \(count), \(option.label.value)")
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
        // Terminal parity: "1", "2", … pick the option. `.keyboardShortcut`
        // re-fires this same button's action; the modifier only decides
        // whether to attach one. Limited to the nine keys a keystroke can
        // name (`maxOptions` is 4 today). Also refused whenever
        // `OtherAnswerField` is open (see `GatedShortcut`).
        .modifier(GatedShortcut(
            shortcut: KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: []),
            active: index < 9 && !otherFieldExpanded))
    }

    /// The preview, drawn outside the button.
    ///
    /// A `ScrollView` nested in a `Button`'s label never receives the drag that
    /// would scroll it (the button's recogniser claims the touch), and a
    /// button inside a grid proposes a compressed height: a 19-line mockup
    /// added 0 pt of height. Moving the preview out as a sibling fixes both.
    /// `fixedSize(vertical: true)` stays on as a guard in case a refactor puts
    /// the `Text` back inside a label.
    ///
    /// No inner vertical scroller: two stacked vertical scrollers contest every
    /// drag on a touch strip. `PreviewOverflow.visibleText` truncates a
    /// clipping preview to `PreviewOverflow.visibleLines` lines before it
    /// reaches `Text`, so `previewedOptionsBand` is the only vertical scroller.
    ///
    /// Monospace, and scrolled horizontally rather than wrapped: a wrapped
    /// 80-column mockup is a different, broken drawing. A horizontal drag does
    /// not compete with the band's vertical one.
    @ViewBuilder
    private func previewBlock(_ preview: Redacted) -> some View {
        let text = preview.value
        VStack(alignment: .leading, spacing: 4) {
            previewText(PreviewOverflow.visibleText(text))
            if let marker = PreviewOverflow.marker(for: text) {
                // Static, like the terminal's own marker, and not a `Button`: only
                // `answerButton` may answer the question.
                Text(marker)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The (already `PreviewOverflow`-processed) text, horizontally scrollable
    /// and otherwise static. `previewBlock` decides full versus truncated, so
    /// this does not consult `PreviewOverflow` again.
    private func previewText(_ text: String) -> some View {
        ScrollView(.horizontal) {
            Text(text)
                .font(.callout.monospaced())
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.hidden)
    }

    // ----------------------------------------------------------- controls

    /// Shared with `QuestionStage` via `QuestionControls` below, so the two
    /// cannot drift.
    private var controls: some View {
        QuestionControls(decision: decision, runtime: runtime, progress: progress,
                         question: question, otherFieldExpanded: $otherFieldExpanded)
    }
}

/// The Back / DONE controls row, shared by `QuestionTakeover` and
/// `QuestionStage`: the same two runtime calls (`stepBack`/`commit`), the same
/// digit-field gating via `GatedShortcut`, and the same rule that Back is free
/// and total while DONE is multi-select-only (a single-select pick already
/// commits and advances). The same tree the render-sweep floors measure.
struct QuestionControls: View {
    let decision: Decision
    let runtime: DeckRuntime
    let progress: AnswerProgress
    let question: Question?
    @Binding var otherFieldExpanded: Bool

    /// Answers are all-or-nothing: nothing reaches the wire until every
    /// question has one, so the last step submits the whole call.
    private var isLastStep: Bool { progress.step == decision.questions.count - 1 }

    private var canAdvance: Bool { !progress.picked.isEmpty }

    /// True when neither Back nor DONE has anything to draw this step (first
    /// question, single-select). `QuestionStage` pads its pinned footer, and
    /// padding around nothing is still blank space on screen, so it uses this
    /// to skip the footer entirely.
    var isEmpty: Bool { !(progress.step > 0) && !(question?.multiSelect == true) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { buttons }
            VStack(alignment: .leading, spacing: 8) { buttons }
        }
    }

    @ViewBuilder
    private var buttons: some View {
        // Stepping back is free, total and silent (no effect reaches the wire),
        // so it is offered whenever a question precedes this one.
        if progress.step > 0 {
            Button {
                runtime.stepBack(decision.hold)
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.glass)
            .touchTarget(minHeight: TouchTarget.decision, minWidth: 120)
            // Refused while `OtherAnswerField` is open: the left arrow, typed as a
            // character, stepped back and destroyed the draft. See `GatedShortcut`.
            .modifier(GatedShortcut(shortcut: KeyboardShortcut(.leftArrow, modifiers: []),
                                    active: !otherFieldExpanded))
        }

        // Only multi-select needs one. A single-select pick is the answer (the
        // reducer commits and advances in the same step), so a Next button
        // would have nothing to do.
        if question?.multiSelect == true {
            Button {
                runtime.commit(decision.hold)
            } label: {
                // "DONE" at every step: one control, one label, whether it confirms
                // and advances or confirms and submits (UX_DESIGN §4.1).
                Label("DONE", systemImage: isLastStep ? "paperplane.fill" : "chevron.right")
            }
            .buttonStyle(.glassProminent)
            .touchTarget(minHeight: TouchTarget.decision, minWidth: 160)
            // Refused while `OtherAnswerField` is open: Return, typed to submit
            // the field's draft, also fired `.defaultAction` (two submissions
            // racing). See `GatedShortcut`.
            .modifier(GatedShortcut(shortcut: .defaultAction, active: !otherFieldExpanded))
            .disabled(!canAdvance)
            .help(canAdvance ? "" : "Choose at least one option first")
        }
    }
}

/// Attaches a keyboard shortcut to the content it wraps, only while `active`
/// is true. A `ViewModifier` can skip calling `.keyboardShortcut` entirely,
/// where a `@ViewBuilder` branch would still have to name a key.
///
/// Why a gate exists (measured on macOS): an unmodified `.keyboardShortcut`
/// is matched via `performKeyEquivalent`, which walks the window's view
/// hierarchy before the key reaches the first responder's field editor, so a
/// focused `TextField` does not suppress a same-key shortcut elsewhere in the
/// tree. Effects: typing "1" into the Other field picked option 1 and shipped
/// the whole call, draft and all; the left arrow fired `stepBack` and
/// destroyed the draft; Return fired DONE's `.defaultAction` alongside the
/// field's own submit. Nothing in `.keyboardShortcut` asks whether a text
/// field is focused, so the only fix is not attaching the shortcut while one
/// is. Every shortcut routes through this one modifier.
///
/// Not `private`: `QuestionStage` reuses it for the same reason, since the
/// macOS quirk applies regardless of which view hosts the field.
struct GatedShortcut: ViewModifier {
    let shortcut: KeyboardShortcut
    let active: Bool
    @ViewBuilder
    func body(content: Content) -> some View {
        if active {
            content.keyboardShortcut(shortcut)
        } else {
            content
        }
    }
}

/// The "Other…" affordance (UX_DESIGN §4.1): a collapsed row that expands into
/// a text field, so a question can be answered with something other than an
/// offered label. Submitting routes through `DeckRuntime.answerFreely`, which
/// the reducer's `questionAnsweredFreely` case answers without the
/// offered-label guard `questionPicked` enforces (see that case for why this
/// is the one narrow door).
///
/// The typed draft lives in local `@State`, not `AnswerProgress`: it is
/// pre-submission interaction state, unlike an answer already given.
/// `QuestionTakeover` keys this view to `(hold, progress.step)` so a step
/// change gets a fresh field instead of stale text.
///
/// `expanded` is a `Binding` into `QuestionTakeover.otherFieldExpanded` so the
/// shortcuts one level up can read it (see `GatedShortcut`).
///
/// Not `private`: `QuestionStage` reuses it verbatim, so the escape hatch has
/// one implementation.
struct OtherAnswerField: View {
    let hold: HoldID
    /// The already-picked entry that is free text, if any (`nil` if nothing was
    /// typed or it was toggled off). Seeds the field on expand and labels the
    /// collapsed row, so stepping back shows what was said.
    let currentFreeText: Redacted?
    /// The question this field answers, threaded to `answerFreely` rather than
    /// read from live state at submit time (see that function: reading it fresh
    /// would make the reducer's stale-submit guard unfalsifiable).
    let step: Int
    @Binding var expanded: Bool
    let runtime: DeckRuntime
    /// Where a submit goes. Defaults to the deck's open-hold answer
    /// (`answerFreely`). `QuestionMirrorCard` passes
    /// `runtime.forward(mirror, otherText:)`, the terminal keystroke path,
    /// because a mirror's hold is no longer open. Exactly one of the two runs
    /// per submit (a substitution, not a fallback). Named `onForward` to avoid
    /// confusion with SwiftUI's `.onSubmit`, used in `body`.
    var onForward: ((HoldID, String) -> Void)? = nil

    @State private var text = ""

    var body: some View {
        if expanded {
            HStack(spacing: 8) {
                TextField("Type your answer", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(submit)
                    .touchTarget(minHeight: TouchTarget.decision)
                Button("Submit", action: submit)
                    .buttonStyle(.glassProminent)
                    .disabled(Redacted(optional: text) == nil)
                    .touchTarget(minHeight: TouchTarget.decision, minWidth: 88)
            }
        } else {
            Button {
                text = currentFreeText?.value ?? ""
                expanded = true
            } label: {
                Label(currentFreeText.map { "Other: \($0.value)" } ?? "Other…",
                      systemImage: "square.and.pencil")
                    .font(.body.weight(currentFreeText != nil ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.glass)
            .touchTarget(minHeight: TouchTarget.decision, minWidth: TouchTarget.minimum)
        }
    }

    /// Guarded here as well as in `answerFreely`: a blank Return-key submit must
    /// leave the field open rather than collapse it. `.onSubmit` does not
    /// consult `.disabled`, so the Submit button's own guard does not reach it.
    private func submit() {
        guard Redacted(optional: text) != nil else { return }
        if let onForward {
            onForward(hold, text)
        } else {
            runtime.answerFreely(hold, text, step: step)
        }
        text = ""
        expanded = false
    }
}

// ------------------------------------------------------- the question text

/// `question.text`, overflow-honest under compression. Other unbounded fields
/// on the band declare what they hide (`SubjectWell`'s chip,
/// `QuestionOptionsBand.moreOptionsText`, `DetailBand`'s "▾ N more" marker);
/// a bare `Text` here let a 300-word question push `OtherAnswerField` (an
/// interactive control, possibly mid-type) to y ≈ 366–430 against a 358–419 pt
/// budget, with nothing saying the sentence was not shown in full.
///
/// Uses the measured-wrap pattern of `SubjectWell`.
/// `SubjectOverflow.lineCount` counts newlines only (wrapping is unknowable
/// without layout), so one long newline-free sentence reads as one line and
/// earns no chip. Two hidden `.background` probes (`unconstrainedProbe`,
/// `cappedProbe`), each `.fixedSize(horizontal: false, vertical: true)` so
/// they report their own true height, measure the same text at the same
/// width with and without the line cap; a difference over a point of
/// font-metric rounding means the text wraps past the cap (see
/// `SubjectWell.isWrapTruncated`).
///
/// `collapsedLines` is a fixed cap (3), not flexed by `usableHeight`: three
/// `.headline` lines leave room under every strip budget for what follows,
/// and a fixed ceiling is one fewer variable for the worst case.
struct QuestionText: View {
    let text: String
    var collapsedLines: Int = 3

    @State private var expanded = false
    /// The two readings a wrap-only overflow needs (as in `SubjectWell`).
    @State private var fullHeight: Double?
    @State private var cappedHeight: Double?

    private var isWrapTruncated: Bool {
        guard let fullHeight, let cappedHeight else { return false }
        return fullHeight > cappedHeight + 1
    }

    /// `SubjectOverflow.chipText` first, since it can state a count; only when
    /// newline arithmetic says the text fits does the measured wrap-only
    /// reading speak, and it never invents a number (see
    /// `SubjectOverflow.wrapOnlyChipText`).
    private var chipTitle: String? {
        SubjectOverflow.chipText(for: text, collapsedLines: collapsedLines)
            ?? (isWrapTruncated ? SubjectOverflow.wrapOnlyChipText : nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if expanded {
                    // Expanded text gets its own capped `ScrollView`, never one around the
                    // whole band (as in `SubjectWell`; see `DetailBand` for the
                    // doctrine). Reuses `SubjectOverflow.expandedMaxHeight`.
                    ScrollView(.vertical) {
                        content.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: SubjectOverflow.expandedMaxHeight)
                } else {
                    content
                        .lineLimit(collapsedLines)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(alignment: .topLeading) { unconstrainedProbe }
            .background(alignment: .topLeading) { cappedProbe }

            if let chipTitle {
                Button(expanded ? SubjectOverflow.collapseChipText : chipTitle) {
                    expanded.toggle()
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .touchTarget(minHeight: TouchTarget.minimum)
            }
        }
    }

    /// The bare text, styled as a bare `Text` always rendered (`.headline`). No
    /// `.lineLimit`/`.fixedSize` here: `body` and the two probes each apply
    /// their own.
    private var content: some View {
        Text(text).font(.headline)
    }

    /// The unconstrained half of the hidden measurement. `.background` rather
    /// than a `ZStack` sibling, which would inflate the visible height;
    /// `.fixedSize` is load-bearing, since a `Text` in a `.background` adopts
    /// its host's proposed height otherwise (see `SubjectWell.unconstrainedProbe`).
    private var unconstrainedProbe: some View {
        content
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { fullHeight = $0 }
    }

    /// The capped half: `content` at the same `collapsedLines` as the visible
    /// text, so the two readings are comparable.
    private var cappedProbe: some View {
        content
            .lineLimit(collapsedLines)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { cappedHeight = $0 }
    }
}
