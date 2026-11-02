//
//  QuestionMirrorStage.swift · DeckApp
//
//  Full-strip home for `QuestionMirrorCard`, the way `QuestionStage` is for
//  `QuestionTakeover`: a previewed mirror gets the room a 420 pt column
//  cannot give it.
//
//  A sibling of `QuestionStage`, not an extension: that view is built around
//  an open hold's interactive picking (`AnswerProgress`, `runtime.pick`,
//  digit shortcuts), none of which exist for a mirror. Here, picking either
//  stages a local selection (`terminalLive`) or does nothing
//  (`released`/`resolved`). Reused: the two-column layout, `OtherAnswerField`,
//  and `DeckWindow`'s routing (`stageMirror`, same rule as `stageDecision`).
//

import SwiftUI
import DeckCore

struct QuestionMirrorStage: View {
    let mirror: MirrorView
    let sessionName: String
    let runtime: DeckRuntime
    /// Deck-UI dismissal only, same contract as `QuestionStage.onDismiss`: the
    /// session's own call is untouched, and the next selection of this lane
    /// next selection of this lane brings the stage right back up.
    let onDismiss: () -> Void

    @State private var otherFieldExpanded = false
    @State private var picked: [Redacted] = []

    static var leftColumnWidth: Double { QuestionStage.leftColumnWidth }

    private var question: Question? { mirror.question }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let question {
                stageBody(for: question)
            }
        }
        .id(mirror.hold)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThickMaterial)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
    }

    // ------------------------------------------------------------- header

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
            // The resolved copy must say the same thing here as on the band card.
            // `MirrorStatusLabel` (`QuestionMirrorCard.swift`) is the one
            // derivation both surfaces read.
            MirrorStatusLabel(stage: mirror.stage, awaitingConfirmation: mirror.awaitingConfirmation,
                              forwardUnconfirmed: mirror.forwardUnconfirmed)
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
            // `QuestionStage.previewPane` is static and shared, like `leftColumnWidth`.
            QuestionStage.previewPane(for: focusedOption(in: question))
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// No digit shortcuts and no tap-to-focus stepper: a mirror's tap either
    /// sends outright or stages a local pick, so there is no "look, don't
    /// answer yet" gesture to hang a focus index on. The pane follows the
    /// chosen option once `resolved`, otherwise the first option, so it is
    /// never blank.
    ///
    /// A digit pressed while this stage is showing does nothing (no keyboard
    /// handler here), while the same digit typed in the terminal answers the
    /// question. Wiring digits to `runtime.forward` on `terminalLive` is a
    /// possible follow-on.
    private func focusedOption(in question: Question) -> QuestionOption? {
        if case .resolved(let answers, _, _) = mirror.stage {
            return question.options.first { option in
                answers?.contains { $0.labels.contains(option.label) } ?? false
            } ?? question.options.first
        }
        return question.options.first
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
                        optionRow(option, index: index, question: question)
                    }
                }

                if case .terminalLive = mirror.stage {
                    if question.multiSelect {
                        submitRow
                    }
                    // Explicit re-arm: `MirrorSendAgainRow` (`QuestionMirrorCard.swift`)
                    // is the only way back to tappable options while awaiting
                    // confirmation.
                    if mirror.forwardUnconfirmed {
                        sendAgainRow
                    }
                    // The terminal's free-text escape: the same field the takeover and
                    // card share (see `OtherAnswerField`).
                    OtherAnswerField(hold: mirror.hold, currentFreeText: nil, step: 0,
                                     expanded: $otherFieldExpanded, runtime: runtime) { hold, text in
                        guard let typed = Redacted(optional: text) else { return }
                        runtime.forward(mirror, otherText: typed)
                    }
                    // See `MirrorView.optionsDisabled` (`forwarding || awaitingConfirmation`).
                    .disabled(mirror.optionsDisabled)
                    .opacity(mirror.optionsDisabled ? 0.5 : 1)
                }
            }
            .padding(12)
            .padding(.bottom, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One option's row: `QuestionStage.optionRow`'s look without the inline
    /// preview (the right pane shows it). Grayed and inert for `released`, a
    /// real send for `terminalLive`, the winning option highlighted for
    /// `resolved`.
    private func optionRow(_ option: QuestionOption, index: Int, question: Question) -> some View {
        let chosen: Bool
        let interactive: Bool
        switch mirror.stage {
        case .deckWindow:
            chosen = false; interactive = false
        case .released:
            chosen = false; interactive = false
        case .terminalLive:
            chosen = picked.contains(option.label); interactive = true
        case .resolved(let answers, _, _):
            chosen = answers?.contains { $0.labels.contains(option.label) } ?? false
            interactive = false
        }
        return Button {
            guard interactive else { return }
            if question.multiSelect {
                if chosen { picked.removeAll { $0 == option.label } } else { picked.append(option.label) }
            } else {
                runtime.forward(mirror, picking: [option.label])
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chosen
                      ? (question.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                      : (question.multiSelect ? "square" : "circle"))
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text("\(index + 1).")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label.value)
                        .font(.body.weight(chosen ? .semibold : .regular))
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
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        // See `MirrorView.optionsDisabled` for why this is `forwarding ||
        // awaitingConfirmation`, not `forwarding` alone.
        .disabled(!interactive || mirror.optionsDisabled)
        .opacity(!interactive && mirror.stage.isReleased ? 0.5 : (mirror.optionsDisabled ? 0.5 : 1))
        .touchTarget(minHeight: TouchTarget.decision, minWidth: TouchTarget.decision)
        .accessibilityLabel("Option \(index + 1) of \(question.options.count), \(option.label.value)")
        .accessibilityAddTraits(chosen ? [.isButton, .isSelected] : (interactive ? .isButton : []))
    }

    /// Shared with the card; see `MirrorSubmitRow` (`QuestionMirrorCard.swift`).
    private var submitRow: some View {
        MirrorSubmitRow(pickedCount: picked.count, disabled: picked.isEmpty || mirror.optionsDisabled) {
            runtime.forward(mirror, picking: picked)
            picked.removeAll()
        }
    }

    /// Shared with the card; see `MirrorSendAgainRow` for why it applies
    /// `.forwardRearmed` rather than re-running `ForwardPlanBuilder`.
    private var sendAgainRow: some View {
        MirrorSendAgainRow {
            runtime.rearmForward(mirror)
        }
    }
}

private extension MirrorStage {
    var isReleased: Bool { if case .released = self { return true }; return false }
}
