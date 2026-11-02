//
//  QuestionStage.swift · DeckApp
//
//  Full-strip stage for a previewed question.
//
//  A question whose current step carries at least one option preview gets
//  this instead of the band: it owns the glass, and the fleet and detail band
//  behind it go dark, like a terminal dialog taking the whole screen. A 19-line
//  mockup (LV37) cannot fit the band's capped options area, so the preview
//  pane here has no height cap.
//
//  Dismissing the stage is a deck-UI act that collapses back to the band
//  without answering anything (`Decision.showsStage(dismissedStage:)` going
//  false for this hold). `DeckWindow` decides when this shows and does not
//  compose the band while it does (`DeckWindow.bandShown`); this file only
//  draws the stage.
//
//  Everything that reaches the wire (`runtime.pick`, `runtime.commit`,
//  `runtime.answerFreely`, `runtime.stepBack`) is the same call
//  `QuestionTakeover` makes, through the same shared subviews
//  (`OtherAnswerField`, `GatedShortcut`, `QuestionControls`). Only the shape
//  is new: an option list on the left, an uncapped preview pane on the right.
//

import SwiftUI
import DeckCore

struct QuestionStage: View {
    let decision: Decision
    /// The selected lane's name (`Frame.displayName(for:)`), threaded in rather
    /// than looked up here.
    let sessionName: String
    let runtime: DeckRuntime
    /// Fires on the dismiss button only. Never on an answer: answering routes
    /// through `runtime`. `DeckWindow` turns this into
    /// `dismissedStage = decision.hold`.
    let onDismiss: () -> Void

    private var progress: AnswerProgress { decision.progress ?? AnswerProgress() }
    private var question: Question? { decision.currentQuestion }

    /// First tap on an option focuses it (the preview pane swaps to it); a
    /// second tap on the focused row answers it. Defaults to option 1, the row
    /// the terminal highlights first. The pure rule is `OptionTap`
    /// (`DeckCore/Subject.swift`); digit shortcuts bypass it (see
    /// `digitShortcuts`).
    @State private var focusedIndex = 0
    /// Hoisted like `QuestionTakeover.otherFieldExpanded`; see `GatedShortcut`
    /// for the macOS quirk it works around.
    @State private var otherFieldExpanded = false

    /// The left column's fixed width. The right pane takes the rest: well over
    /// 800 pt at the strip's 1920, and still over 800 pt in a 1254 pt window.
    static let leftColumnWidth: Double = 420

    var body: some View {
        VStack(spacing: 0) {
            header
            if let question {
                stageBody(for: question)
            }
        }
        // Keyed to the hold and the step so stepping (forward or Back) or a new
        // question call resets `focusedIndex` and `otherFieldExpanded`.
        .id("\(decision.hold)-\(progress.step)")
        // The overlay owns the strip: opaque enough that nothing behind it reads
        // through, with the same glass family as every other surface.
        .background(.ultraThickMaterial)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    // ------------------------------------------------------------- header

    /// Not `private`: `RenderSweepTests` measures this directly to hold the
    /// pinned chrome to a room-left budget, like the band's pinned pieces
    /// (`StatusLine`, `DecisionBar`, the Quick Actions column).
    var header: some View {
        HStack(spacing: 12) {
            if let question, !question.header.value.isEmpty {
                Label(question.header.value, systemImage: "questionmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }
            if !sessionName.isEmpty {
                Text(sessionName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            if decision.questions.count > 1 {
                Text("\(progress.step + 1) of \(decision.questions.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Question \(progress.step + 1) of \(decision.questions.count)")
            }
            // Deck-UI dismissal only (see `onDismiss`), never a cancel: the
            // session's call is untouched and the next selection of this lane
            // brings the stage back.
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.glass)
            .touchTarget(minHeight: TouchTarget.minimum, minWidth: TouchTarget.minimum)
            .accessibilityLabel("Dismiss, keep the question open in its own session")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) { Divider() }
    }

    // --------------------------------------------------------------- body

    @ViewBuilder
    private func stageBody(for question: Question) -> some View {
        HStack(alignment: .top, spacing: 0) {
            leftColumn(for: question)
                .frame(width: Self.leftColumnWidth, alignment: .leading)
            Divider()
            Self.previewPane(for: focusedOption(in: question))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(digitShortcuts(for: question))
    }

    private func focusedOption(in question: Question) -> QuestionOption? {
        question.options.indices.contains(focusedIndex) ? question.options[focusedIndex] : nil
    }

    // -------------------------------------------------------- left column

    private func leftColumn(for question: Question) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(question.text.value)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                        optionRow(option, index: index, of: question.options.count)
                    }
                }

                // The terminal's free-text escape: the same field as
                // `QuestionTakeover` (see `OtherAnswerField`).
                OtherAnswerField(hold: decision.hold,
                                 currentFreeText: progress.freeText(in: question),
                                 step: progress.step,
                                 expanded: $otherFieldExpanded,
                                 runtime: runtime)

                Text(question.multiSelect
                     ? "Tap to preview, tap again to choose as many as apply, then submit."
                     : "Tap to preview, tap again to choose.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            // Lets the last line settle clear of the pinned footer's rule.
            .padding(.bottom, 8)
        }
        // Controls are pinned in a bottom `safeAreaInset`, not the last item of the
        // `ScrollView`: inside it, DONE fell below the fold once the scrollable
        // content (three previewed options plus the free-text row) saturated
        // the window height, with no hint that scrolling would reach it. The
        // scrollable middle shrinks to make room, as at every pinned edge.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // Skip the padding when empty: a first-step single-select question has
            // no Back and no DONE, and padding around an `EmptyView` is still a
            // blank inset. `QuestionControls.isEmpty` is the rule its buttons
            // gate on.
            let footer = QuestionControls(decision: decision, runtime: runtime, progress: progress,
                                          question: question, otherFieldExpanded: $otherFieldExpanded)
            if !footer.isEmpty {
                // Backed, not transparent: safe-area content scrolls beneath an
                // inset, and an unbacked footer let the Other row draw beside
                // DONE. Same glass-and-rule edge as other pinned bars.
                footer.padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
                    .overlay(alignment: .top) { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One option's row: no inline preview (the right pane shows it), a focus
    /// ring, and a "tap to choose" hint on the focused row so the second
    /// tap's effect is discoverable.
    ///
    /// The touch floor is `.decision` (64), not `.minimum` (44): the second tap
    /// resolves a hold ("Allow, Deny, and anything else that resolves a
    /// hold", per `TouchTarget.decision`), and the 420 pt column has room.
    ///
    /// Not `private`: `RenderSweepTests` measures a row directly, as with
    /// `QuestionTakeover.optionButton`.
    func optionRow(_ option: QuestionOption, index: Int, of count: Int) -> some View {
        let isFocused = index == focusedIndex
        let isPicked = progress.picked.contains(option.label)
        return Button {
            switch QuestionStageInteraction.tap(index, focusedIndex: focusedIndex) {
            case .focus(let i): focusedIndex = i
            case .pick: runtime.pick(decision.hold, option.label)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isPicked
                      ? (question?.multiSelect == true ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question?.multiSelect == true ? "square" : "circle"))
                    .foregroundStyle(isPicked ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("\(index + 1).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label.value)
                        .font(.body.weight(isPicked ? .semibold : .regular))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !option.detail.value.isEmpty {
                        Text(option.detail.value)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            // Matches `QuestionTakeover.answerButton`'s `.lineLimit(2)`: one
                            // line truncated descriptions mid-sentence with no way
                            // to read the rest.
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    // A focused row says what a second tap does. "tap to choose", not
                    // "tap again": the default-focused row shows this before any
                    // tap, and any tap on a row chooses it.
                    if isFocused {
                        Text("tap to choose")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .touchTarget(minHeight: TouchTarget.decision, minWidth: TouchTarget.decision)
        .accessibilityLabel("Option \(index + 1) of \(count), \(option.label.value)"
                            + (isFocused ? ", focused, tap to choose" : ""))
        .accessibilityAddTraits(isPicked ? [.isButton, .isSelected] : .isButton)
    }

    /// Digit parity, separate from the visible row's tap. The terminal answers
    /// a digit outright (never a focus move), so this must not reuse
    /// `optionRow`'s action, which on an unfocused row only focuses. A
    /// zero-sized invisible button per option carries `GatedShortcut`: "1"-"9"
    /// focuses and answers in one step, gated off while `OtherAnswerField` is
    /// open (as in `QuestionTakeover`).
    @ViewBuilder
    private func digitShortcuts(for question: Question) -> some View {
        ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
            if index < 9 {
                Button("") {
                    focusedIndex = index
                    runtime.pick(decision.hold, option.label)
                }
                .buttonStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
                .modifier(GatedShortcut(
                    shortcut: KeyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: []),
                    active: !otherFieldExpanded))
            }
        }
    }

    // -------------------------------------------------------- preview pane

    /// The preview pane, with no height cap: the full preview, monospaced,
    /// scrolling both axes like the terminal's own mockup. Horizontal scroll
    /// rather than wrapping, since a wrapped 80-column mockup is a different
    /// drawing (as in `QuestionTakeover.previewText`). A 19-line mockup
    /// renders all 19.
    ///
    /// Not `private`: `RenderSweepTests` measures it alone, because inside the
    /// full stage layout a working uncapped preview cannot be told apart from a
    /// silently re-capped one once anything above it saturates.
    ///
    /// `static` because it reads no instance state; `QuestionMirrorStage` shares
    /// it the same way as `leftColumnWidth`, avoiding a second copy.
    @ViewBuilder
    static func previewPane(for option: QuestionOption?) -> some View {
        if let preview = option?.preview {
            ScrollView([.vertical, .horizontal]) {
                Text(preview.value)
                    .font(.callout.monospaced())
                    .fixedSize(horizontal: true, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(16)
            }
            .scrollIndicators(.hidden)
        } else {
            Text("no preview for this option")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}
