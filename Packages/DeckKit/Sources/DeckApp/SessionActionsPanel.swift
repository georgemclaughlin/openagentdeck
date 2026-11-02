//
//  SessionActionsPanel.swift · DeckApp
//
//  The per-session controls, as a modal grid of touch targets instead of a
//  dropdown menu.
//
//  Why not a menu: `NSMenu` is a pointer affordance. Its rows are ~22 pt tall,
//  it opens anchored to a small control, and a checked item is a 10 pt tick in
//  a gutter. The deck's primary surface is an 8.8" 1920x480 touchscreen with no
//  mouse, and a context menu needs a SECONDARY CLICK a thumb cannot make.
//
//  So the `...` control opens a panel of cells that are all at least
//  `TouchTarget.decision` tall, over a scrim that dismisses on a tap anywhere
//  outside (the "click away and it is gone" a menu gave for free).
//
//  State is shown, not ticked. Auto-continue is a standing preference with an
//  ON and an OFF rather than an action, so it renders as a switch: a 76x40
//  track with a 32 pt knob, the whole 64 pt row tappable, the track tinted when
//  on. That reads as a state at arm's length on the strip.
//
//  Where the scrim lives is load-bearing. The overlay is attached in
//  `DeckWindow`, on the composition root, NOT inside `DetailBand` where the
//  `...` button lives. A scrim covering only the band would leave the fleet
//  clickable behind it, so a tap "away" would select a different session while
//  a panel about the previous one was still up. `DetailBand` therefore reports
//  the intent upward (`onOpenSessionActions`) and owns none of the presentation.
//

import SwiftUI
import DeckCore

// ----------------------------------------------------------------- the panel

/// Hide, Remove, Card Color, Show Details, and the auto-continue switch, at a
/// size a thumb can hit.
///
/// Takes the LANE rather than a session id so every gate (`lane.host` for Hide,
/// `lane.directory` for Card Color) reads one value instead of re-deriving it
/// from the frame and risking a different answer in the same render.
struct SessionActionsPanel: View {
    let lane: LaneView
    let runtime: DeckRuntime
    /// Called when the panel has done something that should close it, and by the
    /// scrim. Presentation belongs to the caller; this view never dismisses itself
    /// by mutating shared state.
    let dismiss: () -> Void

    /// The colour picker is shown INLINE, as a section of this panel, not in a
    /// `.popover`. A popover inside a modal is a second dismissal surface, and on a
    /// touch screen tapping "away" from it is often also "away" from the panel,
    /// so one tap dismisses both and the colour is never chosen.
    ///
    /// A `Binding` owned by the presenter, NOT `@State` here (load-bearing). The
    /// presenter offers this panel to `ViewThatFits` as two candidates (plain, and
    /// wrapped in a `ScrollView`) with SEPARATE `@State` storage. Held locally,
    /// opening the picker grew candidate one past the proposal, `ViewThatFits`
    /// switched to candidate two whose own `showingColors` was still `false`, the
    /// content fitted again, and it switched back: Card Color was inoperable at
    /// ordinary desktop window heights. One storage above both candidates fixes it.
    @Binding var showingColors: Bool

    /// Two columns where the panel is wide enough, one when it is not. `.adaptive`
    /// so the same panel suits the strip and a narrow desktop window.
    private var columns: [GridItem] {
        [GridItem(.adaptive(minimum: 210), spacing: 12)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            // The switch goes FIRST and spans the full width: it reports a state rather
            // than performing an act.
            //
            // It reads and writes THIS lane, not the current selection. The
            // `frame.autoContinuable`/`autoContinueOn`/`setAutoContinue()` accessors derive
            // from `state.selected`, which can differ from this lane (the toolbar stays
            // live above the scrim, so a resize out of the banded layout plus "Session
            // Details" can change the selection). A panel about one session must not have
            // a control about another.
            if let surface = lane.host?.surface, runtime.offersContinue(to: lane) {
                SessionActionSwitch(
                    title: "Continue automatically",
                    systemImage: "forward.fill",
                    isOn: runtime.prefs.autoContinue.contains(surface),
                    help: "Sends \u{201C}Continue\u{201D} when your usage limit interrupts this session and the limit then resets.",
                    set: { runtime.setAutoContinue($0, forSurface: surface) })
            }

            LazyVGrid(columns: columns, spacing: 12) {
                SessionActionTile(title: "Show Details", systemImage: "sidebar.right") {
                    runtime.select(lane.session)
                    dismiss()
                }

                // Same gate as `SessionMenu`: hiding is keyed on the SURFACE, so a lane the
                // deck has not located yet has nothing to key on and `runtime.hide` declines.
                if lane.host != nil {
                    SessionActionTile(title: lane.isHidden ? "Show on the Deck" : "Hide from the Deck",
                                      systemImage: lane.isHidden ? "eye" : "eye.slash") {
                        if lane.isHidden { runtime.unhide(lane.session) } else { runtime.hide(lane.session) }
                        dismiss()
                    }
                }

                // A colour preference is DIRECTORY-keyed (`runtime.setCardColor`), so the gate
                // is `lane.directory`, not Hide's `lane.host`: a lane can have a host before
                // its `cwd` resolves, and the picker would have nothing to write through.
                if lane.directory != nil {
                    SessionActionTile(title: "Card Color", systemImage: nil, swatch: lane.color.tint,
                                      isActive: showingColors) {
                        showingColors.toggle()
                    }
                    .accessibilityLabel("Card color, currently \(lane.color.spokenName)")
                }

                // Destructive, and last. `requestDelete` puts the frame into a confirming
                // state, so the question survives this panel closing; the alert is presented
                // on the window, not on this view.
                SessionActionTile(title: "Remove from the Deck…", systemImage: "trash", alarming: true) {
                    // Select first: `DeleteConfirmation` reads `frame.selection` for both whether
                    // to present the alert and which id to delete, and `Frame` only reports
                    // `confirmingDelete` when the two agree. This panel is built for the case
                    // where lane and selection diverge, so without selecting, Remove was a silent
                    // no-op there and left `confirmingDelete` set, popping an unrequested alert
                    // when that session was later selected. A destructive confirmation should
                    // also be about the session the deck is showing.
                    runtime.select(lane.session)
                    runtime.requestDelete(lane.session)
                    dismiss()
                }
            }

            if showingColors, lane.directory != nil {
                Divider()
                CardColorPicker(lane: lane, runtime: runtime)
            }
        }
        .padding(20)
        .frame(maxWidth: 560)
        .background {
            RoundedRectangle(cornerRadius: 20)
                .fill(.background)
                .overlay {
                    RoundedRectangle(cornerRadius: 20)
                        .strokeBorder(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        }
        // A modal's contents must not let a tap fall through to the scrim. The panel
        // is drawn above the scrim, so hit-testing already prefers it; this makes the
        // WHOLE rounded rectangle, padding included, part of that shape.
        .contentShape(.rect)
    }

    /// Names the session the panel is about, with the explicit way out beside it.
    /// The scrim is the fast dismissal; this is the discoverable one, and
    /// `.cancelAction` makes Escape close the panel as it does every other modal.
    ///
    /// Safe to bind Escape here: `DigitShortcut` (`DecisionBar.swift`) refuses
    /// Return/Escape for DECISIONS because a stray Escape must never deny a tool
    /// call. Nothing in this panel answers a hold; an accidental Escape only closes
    /// a panel that reopens with one tap.
    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(runtime.frame.displayName(for: lane))
                    .font(.title2.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("Session controls")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(width: TouchTarget.minimum, height: TouchTarget.minimum)
                    .contentShape(.rect)
            }
            .buttonStyle(.glass)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Close session controls")
        }
    }
}

// ------------------------------------------------------------------ the tile

/// One action in the grid, sized so a thumb can hit it.
///
/// Floors at `TouchTarget.decision` (64) rather than the general 44: at ~225 ppi
/// and 1x scale, 44 pt is only ~5 mm of glass against the ~7 mm the HIG number
/// assumes (see `TouchTarget`). The height is applied to the LABEL, inside the
/// button, so the glass itself grows; a floor applied from OUTSIDE leaves the
/// drawn control at its natural size in a box of nothing (see
/// `DecisionBar.control`).
struct SessionActionTile: View {
    let title: String
    /// `nil` when the tile draws a colour swatch instead of a glyph.
    var systemImage: String?
    /// Drawn in place of `systemImage` — the card's own current colour, so
    /// the Card Color tile shows what it would be changing.
    var swatch: Color?
    /// Destructive weight: red label, never a red fill. The fill is reserved
    /// for the decision bar's own Allow, and a Remove that shouted louder
    /// than an Allow would be the wrong thing loudest on the glass.
    var alarming: Bool = false
    /// Whether this tile's own inline section is currently open — the Card
    /// Color tile is a disclosure, not an act, and a grid where one cell
    /// toggles something below it has to say which cell did.
    var isActive: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                icon
                Text(title)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(alarming ? Color.red : Color(nsColor: .labelColor))
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.decision + 20)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .help(title)
    }

    @ViewBuilder
    private var icon: some View {
        if let swatch {
            Circle()
                .fill(swatch)
                .frame(width: 22, height: 22)
                .overlay { Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1) }
        } else if let systemImage {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(alarming ? Color.red : Color.accentColor)
        }
    }
}

// ---------------------------------------------------------------- the switch

/// A standing preference, drawn as a switch big enough to read and hit.
///
/// A standing preference, drawn as a switch big enough to read and hit.
///
/// Deliberately not `Toggle(...).toggleStyle(.switch)`: the stock AppKit switch
/// renders 24 pt tall whatever `controlSize` it is given (measured 229 x 24),
/// below the floor this panel imposes. The track and knob are drawn to the same
/// 64 pt rhythm as the tiles, and the WHOLE row is the button. State shows as a
/// tinted track and a travelling knob, legible at arm's length.
struct SessionActionSwitch: View {
    let title: String
    let systemImage: String
    let isOn: Bool
    let help: String
    let set: (Bool) -> Void

    private var trackWidth: Double { 76 }
    private var trackHeight: Double { 40 }
    private var knob: Double { 32 }

    var body: some View {
        Button { set(!isOn) } label: {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color(nsColor: .labelColor))
                    Text(isOn ? "On" : "Off")
                        .font(.callout)
                        .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
                }
                Spacer(minLength: 12)
                track
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: TouchTarget.decision)
            .contentShape(.rect)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 12))
        .help(help)
        // One control, one announcement: without this the row reads as a
        // button whose label happens to contain the word "On", rather than
        // as a switch a screen reader can report and flip.
        .accessibilityRepresentation {
            Toggle(title, isOn: Binding(get: { isOn }, set: set))
        }
    }

    /// The track, drawn rather than borrowed. `alignment` on the overlay is
    /// what moves the knob, so the travel animates for free off the same
    /// `isOn` the tint reads.
    private var track: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary))
            .frame(width: trackWidth, height: trackHeight)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: knob, height: knob)
                    .padding((trackHeight - knob) / 2)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
            }
            .animation(.snappy(duration: 0.18), value: isOn)
    }
}

// ---------------------------------------------------------- the presentation

/// The scrim and the centring, attached once on `DeckWindow`'s own root.
///
/// The scrim is the dismissal: a tap anywhere it covers closes the panel, as a
/// menu does. It must cover the WHOLE window (see the file header), so this
/// modifier is applied at the composition root and nowhere else.
///
/// `lane` is looked up FRESH from the frame on every render, not captured when
/// the panel opened: a stale `isHidden` or colour would offer a control whose
/// label disagrees with what it does. If the lane goes away entirely (retired,
/// deleted from another surface) the panel closes itself.
struct SessionActionsPresenter: ViewModifier {
    let runtime: DeckRuntime
    @Binding var session: SessionID?

    /// Owned HERE so both `ViewThatFits` candidates share ONE storage (see
    /// `SessionActionsPanel.showingColors`). Reset whenever the panel closes, so
    /// the next session's panel opens with the picker shut.
    @State private var showingColors = false

    /// One panel, built twice for `ViewThatFits`, both reading the SAME
    /// `showingColors`.
    private func panel(for lane: LaneView) -> SessionActionsPanel {
        SessionActionsPanel(lane: lane, runtime: runtime,
                            dismiss: {
                                session = nil
                                showingColors = false
                            },
                            showingColors: $showingColors)
    }

    private var lane: LaneView? {
        guard let session else { return nil }
        return runtime.frame.lanes.first { $0.session == session }
            ?? runtime.frame.hidden.first { $0.session == session }
    }

    func body(content: Content) -> some View {
        // A `ZStack`, not `content.overlay`, so the deck underneath can be DISABLED
        // without disabling the panel on top. `.disabled` propagates through the
        // environment to everything below the view it is applied to, overlay content
        // included; siblings in a stack do not inherit from each other.
        ZStack(alignment: .topLeading) {
            // Inert while the panel is up. This is a safety rule, not a nicety.
            //
            // A hand-built modal blocks the pointer with its scrim and nothing else.
            // `DecisionBar`'s Allow/Deny buttons carry BARE digit shortcuts and
            // `performKeyEquivalent` walks the whole window (`DigitShortcut`: "a WINDOW
            // invariant"), which assumes competing surfaces are mutually exclusive. This
            // panel opens from `DetailBand`'s header while the act zone's decision is
            // still mounted behind it, so without this, typing `1` while reaching for Card
            // Color would approve a tool call the person cannot see. An `NSMenu` swallows
            // key events in its own modal loop; a hand-built panel must do it explicitly.
            // `.accessibilityHidden` applies the same rule to VoiceOver.
            //
            // Not covered by a test (tooling limit): `performKeyEquivalent` answers
            // `false` on a hosted view with no key window, and SwiftUI buttons are not
            // `NSButton`s in the AppKit tree, so neither the shortcut nor the enabled
            // state is observable headlessly. If this is restructured into
            // `content.overlay { ... }`, the panel inherits the disable and stops working,
            // which is at least a loud failure.
            //
            // Gated on `lane`, the SAME predicate the scrim and panel use, not on
            // `session`: with a session id set but no resolvable lane, the window would be
            // inert with no scrim, panel or Escape target, recoverable only by relaunch.
            content
                .disabled(lane != nil)
                .accessibilityHidden(lane != nil)

            if let lane {
                // Fills the region itself and centres the panel INSIDE it, so the outer
                // stack's `.topLeading` (which `DeckWindow`'s greedy frame relies on to keep
                // the fleet pinned during a resize transient) still governs the composition.
                ZStack {
                    Rectangle()
                        .fill(.black.opacity(0.45))
                        .contentShape(.rect)
                        .onTapGesture {
                            session = nil
                            showingColors = false
                        }
                        .accessibilityLabel("Close session controls")
                        .accessibilityAddTraits(.isButton)
                    // Scrolls only when it must. With the colour picker open the panel wants
                    // ~923 pt against the strip's ~419 pt usable height, and a hand-built modal
                    // gets no sizing from AppKit as a `.popover` would. `ViewThatFits` rather than
                    // an unconditional `ScrollView`, which is greedy and would stretch the panel
                    // at every size.
                    ViewThatFits(in: .vertical) {
                        panel(for: lane)
                        ScrollView { panel(for: lane) }
                            .scrollBounceBehavior(.basedOnSize)
                    }
                    .padding(24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .ignoresSafeArea()
                // No `.transition` near the fleet's own containers: this is a sibling of the
                // whole composition, not a child of either grid, so a fade cannot reach a lazy
                // container's diff (see `SessionOverview`'s transaction rule).
                .transition(.opacity)
            }
        }
        // A lane that retires while its panel is open takes the panel with it.
        .onChange(of: runtime.frame.lanes.map(\.session)) { _, _ in
            if session != nil, lane == nil {
                session = nil
                // Cleared here too: a panel that closes because its session RETIRED would
                // otherwise leave the picker flagged open for the next session's panel.
                showingColors = false
            }
        }
    }
}

extension View {
    /// Present the session-actions panel over this view. `session` is the
    /// binding the `⋯` control sets and the scrim clears.
    func sessionActionsPanel(runtime: DeckRuntime, session: Binding<SessionID?>) -> some View {
        modifier(SessionActionsPresenter(runtime: runtime, session: session))
    }
}
