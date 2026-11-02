//
//  SessionActions.swift · DeckApp
//
//  Views for session-level flows: hiding and deleting a session, cancelling
//  queued actions, auto-continue, and moving between waiting sessions.
//
//  Each is placed where a Mac user would look for it: destructive and per-row
//  things in a context menu, the queue as a section of the detail, and
//  "next waiter" in the toolbar beside the count it acts on.
//

import SwiftUI
import DeckCore

// -------------------------------------------------------- per-session menu

/// Hide, delete, and the confirmation delete needs.
///
/// A context menu because these are per-row and one of them is destructive:
/// putting Delete on the surface next to a control you press all day is how a
/// session gets removed by a thumb that meant to select it.
struct SessionMenu: View {
    let lane: LaneView
    let runtime: DeckRuntime

    var body: some View {
        Button {
            runtime.select(lane.session)
        } label: {
            Label("Show Details", systemImage: "sidebar.right")
        }

        Divider()

        // Hiding is reversible and says so: the row moves to a section that names
        // itself, and Settings offers the way back. Offered in both directions so a
        // revealed hidden lane can be un-hidden individually.
        //
        // Offered only where it can be honoured: hiding is keyed on the SURFACE, so a
        // lane the deck has not located yet has nothing to key on and `runtime.hide`
        // declines (see `LaneView.host`).
        if lane.host != nil {
            Button {
                if lane.isHidden { runtime.unhide(lane.session) } else { runtime.hide(lane.session) }
            } label: {
                Label(lane.isHidden ? "Show on the Deck" : "Hide",
                      systemImage: lane.isHidden ? "eye" : "eye.slash")
            }
        }

        // Delete asks first. `requestDelete` puts the frame into a confirming state
        // rather than opening a sheet, so the question survives the window being
        // rebuilt.
        Button(role: .destructive) {
            runtime.requestDelete(lane.session)
        } label: {
            Label("Delete Session…", systemImage: "trash")
        }
    }
}

/// The confirmation, as an alert — the platform's own answer to "are you
/// sure", and the one place a modal is right: a destructive act should stop
/// the hand that is already moving.
struct DeleteConfirmation: ViewModifier {
    let runtime: DeckRuntime

    private var confirming: SessionID? {
        runtime.frame.confirmingDelete ? runtime.frame.selection : nil
    }

    func body(content: Content) -> some View {
        content.alert("Delete this session from the deck?",
                      isPresented: Binding(
                        get: { confirming != nil },
                        set: { if !$0 { runtime.cancelDelete() } })) {
            Button("Cancel", role: .cancel) { runtime.cancelDelete() }
            Button("Delete", role: .destructive) {
                if let id = confirming { runtime.confirmDelete(id) }
            }
        } message: {
            Text("The session keeps running in its own terminal. The deck stops "
                 + "showing it and stops counting it, including when it needs you.")
        }
    }
}

extension View {
    func deleteConfirmation(_ runtime: DeckRuntime) -> some View {
        modifier(DeleteConfirmation(runtime: runtime))
    }
}

// ---------------------------------------------------------------- the queue

/// The queue's shared vocabulary: a namespace, not a view. The queue itself is
/// drawn by `TranscriptWell`.
@MainActor
enum QueueSection {
    /// Why the queue is not moving, when it is not; a queue that has stopped and
    /// does not say so reads as a deck that has stopped.
    ///
    /// Shared with `TranscriptWell`'s header line so both read one derivation of
    /// the same strings.
    static func waitingLabel(runtime: DeckRuntime) -> String {
        if runtime.frame.queueAwaitsUsage { return "Queued — waiting for the usage window" }
        if runtime.frame.queueStalled { return "Queued — the session has not moved" }
        return "Queued"
    }
}

// -------------------------------------------------------- auto-continue

/// A toggle, offered only where it can be honoured.
///
/// `autoContinuable` is the frame's own answer to whether this session has a
/// Continue action to send; a switch that silently does nothing is the mute
/// failure the deck refuses everywhere else.
struct AutoContinueToggle: View {
    let runtime: DeckRuntime

    var body: some View {
        if runtime.frame.autoContinuable {
            Toggle(isOn: Binding(get: { runtime.frame.autoContinueOn },
                                 set: { runtime.setAutoContinue($0) })) {
                Label("Continue automatically", systemImage: "forward.fill")
            }
            .toggleStyle(.switch)
            // A stock switch renders 24 pt tall: a pointer's target, not a thumb's.
            .touchTarget()
            .help("Sends \u{201C}Continue\u{201D} when your usage limit interrupts this session and the limit then resets.")
        }
    }
}

// ---------------------------------------------------------- queued status

extension QueuedAction.Status {
    var symbolName: String {
        switch self {
        case .queued: "clock"
        case .sent: "paperplane.fill"
        case .confirmed: "checkmark.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .queued: .secondary
        case .sent: .accentColor
        // Confirmed means a receipt came back carrying the deck's own bytes, a
        // stronger claim than "sent".
        case .confirmed: .green
        }
    }

    var spokenName: String {
        switch self {
        case .queued: "Waiting"
        case .sent: "Sent"
        case .confirmed: "Confirmed"
        }
    }
}

// ------------------------------------------------- reachable without a mouse

/// Hide and Delete, as buttons.
///
/// They are buttons, not a `.contextMenu`, because on macOS a context menu is a
/// SECONDARY CLICK, which a touchscreen (and the iPad over Sidecar) cannot
/// produce. They live at the bottom of `DetailBand`'s Controls column, two
/// deliberate steps from the fleet (select the session, read its detail).
/// Delete still asks first.
struct SessionControls: View {
    let lane: LaneView
    let runtime: DeckRuntime
    /// Emphasizes the Remove control. `DetailBand` passes `true` for an `.ended`
    /// lane; it is a parameter, not a style change to every use of the view.
    /// default weight.
    var emphasizeRemove: Bool = false
    /// Whether to show the Card Color row. `DetailBand`'s `controlsZone` passes
    /// `true`.
    var showsColorPicker: Bool = false

    /// Drives the popover below. View state rather than reducer state: whether the
    /// picker is open is a fact about this glass, not the session. `.popover`
    /// dismisses itself on an outside click/tap, and unmounting the band takes the
    /// popover with it.
    @State private var showingColorPicker = false

    /// Order: Hide, Remove, Card Color. Card Color is last because it is the one
    /// button that opens a `.popover` instead of acting immediately.
    /// consequential controls would expect them.
    var body: some View {
        GroupBox("This Session") {
            VStack(alignment: .leading, spacing: 8) {
                if lane.host != nil {
                    Button {
                        if lane.isHidden { runtime.unhide(lane.session) } else { runtime.hide(lane.session) }
                    } label: {
                        Label(lane.isHidden ? "Show on the Deck" : "Hide from the Deck",
                              systemImage: lane.isHidden ? "eye" : "eye.slash")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                    .touchTarget()
                }
                removeButton

                // A colour preference is DIRECTORY-keyed (`runtime.setCardColor`), so the gate
                // is `lane.directory != nil`, not Hide's `lane.host != nil`: a lane can have a
                // host before its `cwd` resolves, and the picker would have nothing to write
                // through.
                if showsColorPicker, lane.directory != nil {
                    Button { showingColorPicker = true } label: {
                        Label { Text("Card Color") } icon: {
                            Circle().fill(lane.color.tint).frame(width: 14, height: 14)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(.glass)
                    .touchTarget()
                    .popover(isPresented: $showingColorPicker) {
                        CardColorPicker(lane: lane, runtime: runtime)
                    }
                    .accessibilityLabel("Card color, currently \(lane.color.spokenName)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Split out of `body` because `.buttonStyle` takes a concrete `ButtonStyle`,
    /// and `.glass` and `.glassProminent` are different types, so choosing needs a
    /// branch rather than a ternary.
    @ViewBuilder
    private var removeButton: some View {
        let label = Label("Remove from the Deck…", systemImage: "trash")
            .frame(maxWidth: .infinity, alignment: .leading)
        if emphasizeRemove {
            Button(role: .destructive) { runtime.requestDelete(lane.session) } label: { label }
                .buttonStyle(.glassProminent)
                .tint(.red)
                .touchTarget()
        } else {
            Button(role: .destructive) { runtime.requestDelete(lane.session) } label: { label }
                .buttonStyle(.glass)
                .tint(.red)
                .touchTarget()
        }
    }
}

// ------------------------------------------------- when the deck lost the call

/// A needs-you lane with no live decision and no fleet corroboration
/// (`LaneView.waitingFor == nil`). Transient: the next poll either raises
/// `waitingFor` or demotes the lane.
///
/// The copy is split on `sawAHold`: "held it as long as it could and time ran
/// out" is only true of a hold that actually opened and expired. A lane raised
/// straight to needs-you (a holdless `permission_prompt` notification, or a
/// session found by the fleet with no hook) was never the deck's to hand back.
///
/// Also the surface for every `waitingFor` the deck cannot answer.
/// `DialogAnswerPanel` renders only for `DialogAnswerPanel.answers`; every
/// other non-nil value ("dialog open", "input needed", "sandbox request",
/// "worker request") falls here, and the "Waiting on: ..." line keeps the
/// fleet's one fact visible, in the same phrasing the panel uses.
struct HandedBackNotice: View {
    /// Whether any hold, open or resolved, has ever existed for this session
    /// (`LaneView.sawAHold`).
    let sawAHold: Bool
    /// What the fleet says a human is being shown, verbatim (`LaneView.waitingFor`).
    /// nil when the fleet has nothing to say, or when the lane read `.needsYou`
    /// from a hook/decision with no fleet corroboration.
    let waitingFor: String?
    /// Compact shape for a squeezed band (`OverviewLayout.bandSqueezed`). Drops
    /// everything below the title (subtitle and "Waiting on:" line), the same
    /// single "detail" `ActionBlockNotice` used to drop. `spokenLabel` stays
    /// unconditional: `.accessibilityElement(children: .combine)` alone can only
    /// combine what is in the tree, so VoiceOver gets an explicit label.
    /// `accessibilityLabel` (`.accessibilityElement(children: .combine)`
    /// alone can only ever combine what is actually IN the tree).
    var compact: Bool = false

    init(sawAHold: Bool, waitingFor: String? = nil, compact: Bool = false) {
        self.sawAHold = sawAHold
        self.waitingFor = waitingFor
        self.compact = compact
    }

    /// The bold line. "Went back" implies the deck held it first, so the copy
    /// depends on `sawAHold`.
    static func title(sawAHold: Bool) -> String {
        sawAHold ? "This request went back to the terminal"
                 : "This session is asking in its own terminal"
    }

    /// The caption. The never-held half says what the title does not: the deck was
    /// never the one holding this request.
    static func subtitle(sawAHold: Bool) -> String {
        sawAHold
            ? "The deck held it as long as it could and time ran out. "
              + "The session is still waiting — answer it in its own window."
            : "The deck never held this request — answer it in the session's own window."
    }

    /// The full spoken text, read regardless of `compact`, so VoiceOver never loses
    /// information the glass shed for room.
    private var spokenLabel: String {
        var spoken = "\(Self.title(sawAHold: sawAHold)). \(Self.subtitle(sawAHold: sawAHold))"
        if let waitingFor {
            spoken += ". Waiting on: \(waitingFor)"
        }
        return spoken
    }

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.title(sawAHold: sawAHold))
                    .font(.callout.weight(.medium))
                if !compact {
                    Text(Self.subtitle(sawAHold: sawAHold))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let waitingFor {
                        Text("Waiting on: \(waitingFor)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        } icon: {
            Image(systemName: "arrow.uturn.backward.circle.fill")
                .foregroundStyle(.orange)
        }
        .padding(compact ? 6 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenLabel)
    }
}

// ------------------------------------------------- when the deck can still act

/// A needs-you lane with no live decision, but WITH fleet corroboration:
/// `LaneView.waitingFor` names what the terminal is showing. Where
/// `HandedBackNotice` says "go there", this says "or here": cmux `send-key`
/// reaches the surface directly, because answering a dialog is a keystroke.
///
/// Limits: this answers a dialog the deck only knows exists (`waitingFor`, sight
/// unseen), so there is no subject and no suggestion labels, just Claude Code's
/// fixed three-option vocabulary sent as raw digits. The caption says so.
///
/// Only built for `answers`'s one value. LV36 evidences the fixed three digits
/// for "permission prompt" only; sending "1" into "sandbox request" etc. would
/// be a guess, so the other values fall to `HandedBackNotice`.
///
/// Takes the same squeezed recipe as `DecisionBar` (`outerPadding`,
/// `contentSpacing`, `buttonHeight`, `buttonMinWidth`) and the same
/// `ViewThatFits(in: .horizontal)` reflow. Its three titles are FIXED
/// (`QuickAction.dialogAnswers`), so they also feed `decisionMinimumActWidth`'s
/// act-zone-widening guard; there is no shorter phrasing to fall back to.
struct DialogAnswerPanel: View {
    /// What the fleet says is on screen, already unwrapped from
    /// `LaneRecord.waitingFor`. Always `answers`'s one evidenced value; the caller
    /// checks the condition once, so this panel cannot be built for a lane without
    /// one.
    let waitingFor: String
    let runtime: DeckRuntime

    /// The squeezed recipe's four parameters, named and defaulted to match
    /// `DecisionBar`'s. `DetailBand.actZoneFallback(for:budget:)` passes the same
    /// functions `DecisionBar`'s call site reads, so there is one derivation of the
    /// squeezed step.
    ///
    /// Why they matter: the titles are fixed text, so the row has one natural width
    /// (`DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`): 490 pt at the
    /// 140 pt floor, 430 pt at the squeezed 110 pt one. That is past the content
    /// room a narrow act zone leaves, so the row stacks at the narrowest reachable
    /// act widths and, unsqueezed, overruns the band's height budget; the act
    /// zone's `.frame(maxHeight:).clipped()` then silently hides the overflow (see
    /// `DecisionBar.onButtonsFrameMeasured`).
    /// `RenderSweepTests.theDialogAnswerPanelObeysTheSameHeightBudgetAsItsSibling`
    /// guards it.
    var outerPadding: Double = 16
    /// VStack spacing; default 8, so `DetailBand` can pass its squeezed step.
    var contentSpacing: Double = 8
    /// Button height; default `TouchTarget.decision` (64), as in
    /// `DecisionBar.control(...)`.
    var buttonHeight: Double = TouchTarget.decision
    /// Button minimum width; default 140, as in `DecisionBar.control(...)`.
    var buttonMinWidth: Double = 140

    /// The one `waitingFor` value this panel is evidenced to answer: LV36 is the
    /// only recording of the field and it reads exactly this. Named so `DetailBand`'s
    /// branch and this fact cannot drift apart, and so it is unit-testable.
    static func answers(_ waitingFor: String?) -> Bool {
        waitingFor == "permission prompt"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            Text("Waiting on: \(waitingFor)")
                .font(.callout.weight(.medium))
            Text("The deck can answer it here, or you can in its terminal.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            // `bandDecisionRowSpacing`/`bandDecisionRowStackSpacing` are the same
            // constants `DecisionBar.body` reads and `DecisionRowMeasurer.bareRow` hosts
            // to measure. `decisionMinimumActWidth` (`DetailBand.swift`) reasons about one
            // natural width for this row, which only holds if the measured row is spaced
            // identically to the drawn one.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: OverviewLayout.bandDecisionRowSpacing) { buttons }
                VStack(alignment: .leading, spacing: OverviewLayout.bandDecisionRowStackSpacing) { buttons }
            }

            // The honesty constraint: the deck cannot see how many options the terminal's
            // dialog shows (option 2 exists only when the engine attached a suggestion,
            // and `waitingFor` is fleet text, not a decoded `PermissionRequest`). No live
            // recording covers cmux `send-key` against a dialog with fewer than three
            // options, so no claim like "a missing number is ignored" is made. This asks
            // instead of asserting.
            Text("Answer with the number the terminal shows.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(outerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    }

    /// One control per `QuickAction.dialogAnswers` entry, styled as `DecisionBar`
    /// styles the same shape: Allow-weight for Yes, a quieter Allow for "don't ask
    /// again", Deny-weight for No.
    @ViewBuilder
    private var buttons: some View {
        ForEach(QuickAction.dialogAnswers) { action in
            control(for: action)
                // A darkened control carries its reason in the same frame: `actionBlock` is
                // already shown by `ActionBlockNotice` beside this panel (`unroutable`
                // exactly when this lane's `host` is nil).
                .disabled(runtime.frame.actionBlock != nil)
        }
    }

    @ViewBuilder
    private func control(for action: QuickAction) -> some View {
        switch action.kind {
        case .dialogKey("3"):
            DecisionBar.control(action.displayTitle, destructive: true, height: buttonHeight, minWidth: buttonMinWidth) {
                runtime.queue(action)
            }
        case .dialogKey("2"):
            DecisionBar.control(action.displayTitle, destructive: false, prominent: false,
                                height: buttonHeight, minWidth: buttonMinWidth) {
                runtime.queue(action)
            }
        default:
            DecisionBar.control(action.displayTitle, destructive: false, height: buttonHeight, minWidth: buttonMinWidth) {
                runtime.queue(action)
            }
        }
    }
}

// ------------------------------------------------------- when it cannot act

/// Why the deck cannot speak to this session, said in the frame it applies to.
///
/// The runtime sets `actionBlock` on nine failure paths (a refused host, an
/// unroutable lane, a composer holding somebody else's text). A deck that
/// knows it cannot act and does not say so leaves a pressed button with no
/// reason on the glass.
///
/// Matters most on first launch: spawning `cmux` raises macOS's app-data
/// prompt, and denying it lands here, so "I said Don't Allow" and "the deck
/// is broken" would otherwise look identical.
struct ActionBlockNotice: View {
    let block: ActionBlock
    /// Compact shape for a squeezed band (`OverviewLayout.bandSqueezed`). Tightens
    /// the padding (16 to 6) but KEEPS the detail line: the reason the deck cannot
    /// send is exactly what must not be cut. At an impossible budget the act zone
    /// caps-and-clips below this notice. The accessibilityLabel is unconditional.
    var compact: Bool = false

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text("The deck cannot send to this session")
                    .font(.callout.weight(.medium))
                // The reason renders at EVERY size; `compact` only changes padding.
                Text(block.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
        .padding(compact ? 6 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("The deck cannot send to this session. \(block.message)")
    }
}
