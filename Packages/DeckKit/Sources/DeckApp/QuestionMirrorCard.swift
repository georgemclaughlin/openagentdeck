//
//  QuestionMirrorCard.swift · DeckApp
//
//  A question that has stopped being an open `Decision` and become a
//  `MirrorView`: `released`, `terminalLive`, or `resolved`. `QuestionTakeover`
//  renders the first stage (`deckWindow`, still an actionable hold); this
//  file renders everything after it, reading `Frame.mirrors` rather than
//  `Frame.decisions`. `Projection.frame` excludes `.deckWindow` from
//  `mirrors`, so the two never overlap for the same hold.
//
//  Simpler than `QuestionTakeover`: a mirror only ever shows the first (and
//  only) question (`MirrorView.question`), and there is no deck-side
//  `AnswerProgress` once the hold has fallen through. The card offers
//  nothing (`released`), a scripted keystroke send (`terminalLive`), or a
//  review of what happened (`resolved`).
//
//  "Other" reuses `OtherAnswerField` so the escape hatch cannot drift between
//  views. Only the submit target differs: `onForward` routes to
//  `runtime.forward(mirror, otherText:)` (the terminal keystroke path), never
//  `runtime.answerFreely`, which answers a hold that is no longer open.
//

import SwiftUI
import DeckCore

/// One label per `MirrorStage`, shared by `QuestionMirrorCard` and
/// `QuestionMirrorStage` so the four cases, the three `ResolvedOrigin`
/// sentences, the icons and the dimming can only be edited in one place.
struct MirrorStatusLabel: View {
    let stage: MirrorStage
    /// `MirrorView.awaitingConfirmation`: true from the instant a forwarded plan
    /// sends its last step until a confirmation arrives (the mirror resolves).
    /// It stays true after the allowance elapses; `forwardUnconfirmed` then
    /// takes over the copy. Defaulted `false` like `forwardUnconfirmed`.
    let awaitingConfirmation: Bool
    /// `MirrorView.forwardUnconfirmed`: a forwarded plan finished and the
    /// recovery window elapsed with no confirmation. The deck can confirm a
    /// landing but never its absence, hence the name. Defaulted `false` so
    /// callers that do not care (and bare `.status(for:)` calls) stay simple.
    let forwardUnconfirmed: Bool

    init(stage: MirrorStage, awaitingConfirmation: Bool = false, forwardUnconfirmed: Bool = false) {
        self.stage = stage
        self.awaitingConfirmation = awaitingConfirmation
        self.forwardUnconfirmed = forwardUnconfirmed
    }

    /// Icon, text, and whether the label reads dimmed. Split from the view so
    /// `MirrorStatusLabelTests` can pin the `resolved` sentences without
    /// rendering. `nil` for `.deckWindow`, which never reaches a mirror
    /// surface (`Projection.frame.mirrors` and `DeckWindow.stageMirror` both
    /// exclude it; the hold is still actionable and owned by `stageDecision`).
    static func status(for stage: MirrorStage, awaitingConfirmation: Bool = false,
                       forwardUnconfirmed: Bool = false) -> (icon: String, text: String, dimmed: Bool)? {
        switch stage {
        case .deckWindow:
            return nil
        case .released:
            // A state in motion, not a dead end: name what it is waiting for so a
            // grayed card reads as "in progress", not "broken". The state is
            // temporary, bounded by `HoldPolicy.noSignalAllowance`.
            return ("terminal", "Terminal is opening the question…", true)
        case .terminalLive:
            // Check order matters: `forwardUnconfirmed` first, because the reducer
            // does not clear `forwardSentAt` when it sets `forwardUnconfirmedAt`,
            // so both are true once the allowance elapses and "no confirmation
            // yet" is the more specific claim. Never say the tap failed: it may
            // have landed, and a false "didn't land" invites a duplicate send.
            if forwardUnconfirmed {
                return ("exclamationmark.triangle", "No confirmation yet", false)
            }
            if awaitingConfirmation {
                return ("paperplane", "Answer sent — waiting for the terminal", false)
            }
            return ("terminal.fill", "Answerable from here", false)
        case .resolved(let answers, let origin, _):
            // Answered-elsewhere copy is distinct from deck-answered.
            let (icon, text): (String, String) = {
                switch origin {
                case .deck:     return ("checkmark.circle.fill", "Answered on the deck")
                case .terminal: return ("checkmark.circle", "Answered in the terminal")
                case .movedOn:  return ("xmark.circle", "The session moved on")
                }
            }()
            return (icon, text, answers == nil)
        }
    }

    var body: some View {
        if let (icon, text, dimmed) = Self.status(for: stage, awaitingConfirmation: awaitingConfirmation,
                                                   forwardUnconfirmed: forwardUnconfirmed) {
            Label(text, systemImage: icon)
                .font(.callout.weight(.medium))
                .foregroundStyle(dimmed ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
        }
    }
}

/// Explicit re-arm control, shared by `QuestionMirrorCard` and
/// `QuestionMirrorStage`. Shown only while `mirror.forwardUnconfirmed`.
/// Taps `DeckRuntime.rearmForward`, which applies `.forwardRearmed`, never a
/// replay of the original plan: it clears the way for a fresh, deliberate
/// re-tap (`.forwardPlanStarted` requires `forwardSentAt == nil`, which only
/// this event or a resolution produces). The person decides; the deck never
/// guesses.
struct MirrorSendAgainRow: View {
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Send again", action: action)
                .buttonStyle(.bordered)
                .touchTarget(minWidth: 120)
        }
    }
}

/// Multi-select submit row, shared by `QuestionMirrorCard` and
/// `QuestionMirrorStage`. Builds and runs the full scripted sequence (toggle
/// every staged pick, navigate to Submit, enter, review-digit) on tap.
/// Disabled with nothing staged: `ForwardPlanBuilder.build` refuses an empty
/// plan, and a control that silently does nothing is a mute failure.
struct MirrorSubmitRow: View {
    let pickedCount: Int
    let disabled: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button("Submit (\(pickedCount) selected)", action: action)
                .buttonStyle(.borderedProminent)
                .touchTarget(minWidth: 120)
                .disabled(disabled)
        }
    }
}

struct QuestionMirrorCard: View {
    let mirror: MirrorView
    let runtime: DeckRuntime
    /// Test seam: reports `OtherAnswerField`'s rendered frame in the named
    /// coordinate space an ancestor established (same shape as
    /// `QuestionTakeover.onOtherFieldFrameMeasured`).
    var onOtherFieldFrameMeasured: ((CGRect) -> Void)?

    init(mirror: MirrorView, runtime: DeckRuntime,
         otherFieldInitiallyExpanded: Bool = false,
         onOtherFieldFrameMeasured: ((CGRect) -> Void)? = nil) {
        self.mirror = mirror
        self.runtime = runtime
        self.onOtherFieldFrameMeasured = onOtherFieldFrameMeasured
        _otherFieldExpanded = State(initialValue: otherFieldInitiallyExpanded)
    }

    /// Multi-select accumulation, local to this card and never `AnswerProgress`
    /// (that answers a hold still open; this stages a send for a call the deck
    /// no longer holds). Reset per hold via `.id(mirror.hold)` below.
    @State private var picked: [Redacted] = []
    /// `OtherAnswerField`'s collapsed/expanded state, hoisted (as in
    /// `QuestionTakeover.otherFieldExpanded`) so tests can measure the
    /// expanded shape.
    @State private var otherFieldExpanded: Bool

    private var question: Question? { mirror.question }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if let question {
                QuestionText(text: question.text.value)
                optionsList(for: question)
                if case .terminalLive = mirror.stage {
                    if question.multiSelect {
                        submitRow
                    }
                    // Explicit re-arm, shown exactly while `forwardUnconfirmed`: the only
                    // way back to tappable options during the awaiting-confirmation
                    // window. Never a replay (see `MirrorSendAgainRow`).
                    if mirror.forwardUnconfirmed {
                        sendAgainRow
                    }
                    otherField
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
        .overlay(alignment: .bottom) { Divider() }
        .id(mirror.hold)
    }

    // ---------------------------------------------------------------- header

    /// The state said in words, not an icon alone. Shared derivation: see
    /// `MirrorStatusLabel`.
    private var header: some View {
        MirrorStatusLabel(stage: mirror.stage, awaitingConfirmation: mirror.awaitingConfirmation,
                          forwardUnconfirmed: mirror.forwardUnconfirmed)
    }

    /// Shared with the stage; see `MirrorSendAgainRow` for why it applies
    /// `.forwardRearmed` rather than re-running `ForwardPlanBuilder`.
    private var sendAgainRow: some View {
        MirrorSendAgainRow {
            runtime.rearmForward(mirror)
        }
    }

    // -------------------------------------------------------------- options

    private func optionsList(for question: Question) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10)], spacing: 10) {
            ForEach(Array(question.options.enumerated()), id: \.offset) { index, option in
                optionRow(option, index: index, question: question)
            }
        }
    }

    @ViewBuilder
    private func optionRow(_ option: QuestionOption, index: Int, question: Question) -> some View {
        switch mirror.stage {
        case .deckWindow:
            EmptyView()

        // Grayed and non-interactive: nothing here answers the question in this
        // stage. `.disabled` rather than omitted, so a screen reader still names
        // every option.
        case .released:
            optionLabel(option, index: index, chosen: false)
                .foregroundStyle(.tertiary)
                .disabled(true)
                .accessibilityHint("Terminal is opening the question — not answerable from here yet")

        case .terminalLive:
            terminalLiveOptionButton(option, index: index, question: question)

        case .resolved(let answers, _, _):
            let chosen = answers?.contains { $0.labels.contains(option.label) } ?? false
            optionLabel(option, index: index, chosen: chosen)
                .foregroundStyle(chosen ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                .disabled(true)
        }
    }

    /// The tappable control. Single-select sends outright (one tap, one digit:
    /// `ForwardPlanBuilder.build`'s one-step branch, no `Task.sleep`).
    /// Multi-select only stages the pick locally; `submitRow` builds and runs
    /// the plan, matching the terminal's grammar (LV38): a multi-select digit
    /// toggles, it does not answer.
    private func terminalLiveOptionButton(_ option: QuestionOption, index: Int,
                                          question: Question) -> some View {
        let isPicked = picked.contains(option.label)
        return Button {
            if question.multiSelect {
                if isPicked { picked.removeAll { $0 == option.label } } else { picked.append(option.label) }
            } else {
                runtime.forward(mirror, picking: [option.label])
            }
        } label: {
            optionLabel(option, index: index, chosen: isPicked)
        }
        .buttonStyle(.plain)
        .touchTarget()
        // Disabled on `optionsDisabled` (`forwarding || awaitingConfirmation`),
        // not `forwarding` alone: after a plan sent its last step, `forwarding`
        // alone left the card tappable and invited a duplicate send.
        // The whole card is disabled at once.
        .disabled(mirror.optionsDisabled)
        .opacity(mirror.optionsDisabled ? 0.5 : 1)
        .accessibilityAddTraits(isPicked ? .isSelected : [])
    }

    /// Shared with the stage; see `MirrorSubmitRow`.
    private var submitRow: some View {
        MirrorSubmitRow(pickedCount: picked.count, disabled: picked.isEmpty || mirror.optionsDisabled) {
            runtime.forward(mirror, picking: picked)
            picked.removeAll()
        }
    }

    /// The terminal's free-text escape: the same `OtherAnswerField` as
    /// `QuestionTakeover`, with `onForward` substituting the keystroke path.
    /// The bare-enter prohibition is satisfied by reuse: its `submit()` refuses
    /// an empty `Redacted(optional:)` and its Submit button is disabled on the
    /// same condition. `step: 0` is inert: `onForward` is non-nil here, so the
    /// `runtime.answerFreely` fallback (the only reader of `step`) never runs.
    private var otherField: some View {
        OtherAnswerField(hold: mirror.hold, currentFreeText: nil, step: 0,
                         expanded: $otherFieldExpanded, runtime: runtime) { hold, text in
            guard let typed = Redacted(optional: text) else { return }
            runtime.forward(mirror, otherText: typed)
        }
        // Same `optionsDisabled` debounce as the option buttons: typing into Other
        // mid-plan or while awaiting confirmation would race it the same way.
        .disabled(mirror.optionsDisabled)
        .opacity(mirror.optionsDisabled ? 0.5 : 1)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(detailBandRootSpace)) }
            action: { onOtherFieldFrameMeasured?($0) }
    }

    private func optionLabel(_ option: QuestionOption, index: Int, chosen: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            Text("\(index + 1).")
                .font(.body.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(option.label.value)
                .font(.body.weight(chosen ? .semibold : .regular))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(.rect)
    }
}
