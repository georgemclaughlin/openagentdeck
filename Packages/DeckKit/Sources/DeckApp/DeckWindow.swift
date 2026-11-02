//
//  DeckWindow.swift · DeckApp
//
//  The deck as a Mac window: the fleet, and a detail band for one of it.
//  The window is the fleet; selecting a session puts its detail beside the
//  fleet (`DetailBand`), narrowing the fleet to the selected card and giving
//  the rest of the strip to the detail, at every layout and size.
//
//  Why not `NavigationSplitView` or `.inspector`: both are browse-and-drill
//  shapes whose premise is that selection EXCLUDES the rest. A fleet monitor's
//  question is about the SET ("which of these needs me"), and a 380-760 pt
//  sidebar on a 1920 x 480 strip stacks its content until it scrolls, and a
//  decision that scrolls is a decision somebody can miss. So the band is always
//  the presentation (`OverviewLayout.presentation(...)`); there is no inspector.
//
//  Known gap compared with `List`: arrow-key traversal is reimplemented in
//  `SessionOverview.nextFocus`, but type-ahead select is not provided.
//

import SwiftUI
import AppKit
import DeckCore

public struct DeckWindow: View {
    private let runtime: DeckRuntime

    /// Measured at the composition root (`body`'s outermost `HStack`), so it reads
    /// the FULL content region regardless of selection. One geometry read decides
    /// the layout: the band does not narrow what `layout` is decided from, because
    /// `bandFleetWidth` (324) is far below `OverviewLayout.multiCardMinimumWidth`
    /// (620) and a fleet measured at its own narrowed viewport would flip to
    /// `.column` the instant a selection landed.
    @State private var layout: OverviewLayout = .row

    /// The same measurement `layout` is decided from, kept as its own value and
    /// threaded into `SessionOverview` rather than re-measured there. `layout` only
    /// changes at the row/grid/column boundaries. In `.row`, the band's
    /// `scrollToSelection` re-fires when this changes.
    @State private var fleetSize: CGSize = .zero

    /// Whether the setup sheet is up. Presented rather than navigated to,
    /// because the deck may be a 480 pt strip with no room for a second
    /// surface beside the fleet.
    @State private var showingSetup = false

    /// The `QuestionStage` overlay's dismissal: view-local, per hold.
    /// `Decision.showsStage(dismissedStage:)` is the pure rule this feeds. A NEW hold
    /// (a different `HoldID`) never equals the remembered one, so it always re-shows
    /// the stage: dismissal means "not THIS one again". Plain view state, like
    /// `QuestionTakeover.otherFieldExpanded`; nothing downstream of the reducer needs
    /// to know about it.
    @State private var dismissedStage: HoldID?

    /// Edit-reorder mode, fleet-wide (never per selection). Lives here rather than in
    /// `SessionOverview` so the exit-on-band-open rule below is a single flag flip;
    /// only the drop's final order matters downstream (`DeckRuntime.reorder(_:)`).
    @State private var editingLayout = false

    /// Which session's controls panel is open, or nil. Presented HERE, on the
    /// composition root, not where the `⋯` button lives: `SessionActionsPanel`'s scrim
    /// dismisses on a tap anywhere outside it, which only works if the scrim covers
    /// the whole window. Inside `DetailBand` it would cover the band alone and a tap
    /// "away" would select another session. `DetailBand` reports intent via
    /// `onOpenSessionActions` and owns no presentation.
    ///
    /// Holds a `SessionID`, not a `LaneView`: the lane is looked up fresh each render
    /// (`SessionActionsPresenter`), so a session that changes or retires while its
    /// panel is open cannot leave a stale label on a live control.
    @State private var sessionActionsFor: SessionID?

    /// Passed to `DetailBand` as a METHOD REFERENCE rather than written as a
    /// closure literal at the call site. Spelled inline it pushed the
    /// `if banded` branch past the type checker's own budget ("unable to
    /// type-check this expression in reasonable time") — a solver cost, not a
    /// semantic one, and this is the cheapest way to pay it: a declaration
    /// with an explicit signature the solver never has to infer.
    private func openSessionActions(_ session: SessionID) {
        sessionActionsFor = session
    }

    /// `layout` and `fleetSize` are test seams: production call sites take the
    /// defaults and a real window overwrites both within one `onGeometryChange`. A
    /// headless test never gets a geometry pass, so a test asserting `.grid` or
    /// `.column` band composition, or the band's height floor
    /// (`OverviewLayout.bandMinimumHeight`), must be able to set them explicitly.
    ///
    /// Test seam: called with the exact size just written to `fleetSize`, so a test
    /// can read what the one probe that every layout budget consumes reported
    /// (`RenderSweepTests.theProbeSeesOnlyTheRoomTheChromeLeaves`). The two
    /// `.safeAreaInset` calls below sit outside the probe, so it excludes the status
    /// line and connection banner.
    var onContentSizeMeasured: ((CGSize) -> Void)?

    public init(runtime: DeckRuntime, layout: OverviewLayout = .row, fleetSize: CGSize = .zero) {
        self.runtime = runtime
        _layout = State(initialValue: layout)
        _fleetSize = State(initialValue: fleetSize)
    }

    private var frame: Frame { runtime.frame }

    /// The decision the full-strip stage is showing right now, or nil.
    /// Pure — a static function over `Frame` and the one piece of view
    /// state the rule needs — for the same reason `detailToggle` and
    /// `autoOpen` are: a decision worth raising a whole-window overlay for
    /// is a decision worth being able to test without one.
    static func stageDecision(for frame: Frame, dismissedStage: HoldID?) -> Decision? {
        guard let selection = frame.selection,
              let decision = frame.decisions.first(where: { $0.hold.session == selection })
        else { return nil }
        return decision.showsStage(dismissedStage: dismissedStage) ? decision : nil
    }

    private var stageDecision: Decision? { Self.stageDecision(for: frame, dismissedStage: dismissedStage) }

    /// Twin of `stageDecision` over `Frame.mirrors`: the mirror is another input to
    /// the SAME rule. A `Decision` and a `MirrorView` for the same hold never coexist
    /// (`Projection.frame`'s `mirrors` filter excludes `.deckWindow`), so at most one
    /// of the two is non-nil for a selected lane.
    static func stageMirror(for frame: Frame, dismissedStage: HoldID?) -> MirrorView? {
        guard let selection = frame.selection,
              let mirror = frame.mirrors.first(where: { $0.hold.session == selection })
        else { return nil }
        return mirror.showsStage(dismissedStage: dismissedStage) ? mirror : nil
    }

    private var stageMirror: MirrorView? { Self.stageMirror(for: frame, dismissedStage: dismissedStage) }

    /// Whether the band is composed for this frame. Two guards: presentation must
    /// route to `.band` (it does for every selection at every size; the band
    /// thresholds `bandMinimumWidth`/`bandMinimumHeight` feed the squeezed recipe and
    /// the actions-column arithmetic, not this guard), and no stage may own the hold.
    ///
    /// The band is content an `.overlay` CAN cover, but covering is not enough: a
    /// `QuestionTakeover` in the act zone carries its own digit shortcuts
    /// (`GatedShortcut`), and a control merely painted over would stay in the
    /// responder chain, a second consumer for the same keystroke. So the band is not
    /// composed while staged: a compositional rule, not a z-order one.
    static func bandShown(for frame: Frame, dismissedStage: HoldID?, layout: OverviewLayout,
                          usableWidth: Double, usableHeight: Double) -> Bool {
        OverviewLayout.presentation(for: layout, hasSelection: frame.selection != nil,
                                    usableWidth: usableWidth, usableHeight: usableHeight) == .band
            && stageDecision(for: frame, dismissedStage: dismissedStage) == nil
            && stageMirror(for: frame, dismissedStage: dismissedStage) == nil
    }

    /// The animation for the band opening or closing. GEOMETRY only (the fleet's
    /// width and the band's in/out), never a state truth, the band's content, ticks,
    /// chips or the `QuestionStage` overlay. The only other sanctioned animation
    /// exception is `SessionCard.washTransitionAnimation` (`SessionOverview.swift`);
    /// see `SessionOverview.scrollToSelection`.
    ///
    /// Direction-aware on purpose: opening gets a spring so the fleet's narrowing and
    /// the band's `.transition` read as one motion; closing gets `nil` so the band
    /// leaves and the fleet re-widens in the same frame, with no tail to wait out.
    ///
    /// Evaluated with `banded`'s NEW value on every re-run of `body`, so the
    /// direction is read fresh. It drives the one `.animation(_:value: banded)` that
    /// spans the fleet width, `Ticks` and `DetailBand`. `banded` derives from
    /// `frame.selection` alone, and every route that closes the band (card tap, the
    /// band's ✕, the toolbar toggle, hide-while-selected, a hold closing or a lane
    /// retiring) drives the selection to `nil` (`Frame` treats a selection whose lane
    /// is gone as `nil`), so no route can animate a collapse that another cuts.
    ///
    /// Pure, so it is testable without a window. Reduce Motion (`frame.reduceMotion`)
    /// returns `nil`, a hard cut, in both directions.
    static func bandTransitionAnimation(banded: Bool, reduceMotion: Bool) -> Animation? {
        banded && !reduceMotion ? .snappy(duration: 0.3) : nil
    }

    /// The stage's own header needs a name for the session it is asking
    /// on behalf of — `Frame.displayName(for:)`, looked up the same way
    /// `DetailBand` already looks up its own lane. `stageDecision`
    /// and `stageMirror` never both name a session at once (`stageMirror`'s
    /// own doc comment states why), so reading either's session, whichever
    /// is non-nil, is unambiguous.
    private var stageSessionName: String {
        guard let session = stageDecision?.hold.session ?? stageMirror?.hold.session,
              let lane = frame.lanes.first(where: { $0.session == session })
        else { return "" }
        return frame.displayName(for: lane)
    }

    /// The composition root: the fleet, and the band beside it. Split out of `body`
    /// because `body` had grown past the type checker's budget ("unable to type-check
    /// this expression in reasonable time"); the view tree is unchanged.
    ///
    /// ONE composition, always. Branching `if bandShown { ... } else { ... }` with a
    /// `SessionOverview` in each branch tears the fleet down on every flip: SwiftUI
    /// diffs `@ViewBuilder` branches by POSITION, so `revealingHidden`, `@FocusState`
    /// and scroll position reset, and the `onChange(of: runtime.frame.selection)` that
    /// `scrollToSelection` needs fires against a view that did not exist a frame
    /// earlier (on the strip: tap card 4 and the viewport kept showing card 1,
    /// unringed). So the fleet is always the HStack's first child, at a width that
    /// changes (`bandFleetWidth` or `nil`) instead of an identity that does. `banded`
    /// is also the flag `SessionOverview` reads to filter down to the selected card
    /// alone (see `bandFleetWidth`).
    ///
    /// Deadlock breaker: `.frame(minHeight: 0)` on the fleet slot. Banded, the single
    /// selected card's natural height (113 promptless, 154 with a one-line prompt,
    /// plus 2 x `fleetOuterPadding`) would propagate through this slot as the
    /// window's minimum height, the same mechanism `DetailBand.body`'s `minHeight: 0`
    /// closes. Live signature: banded with the connection banner up, the window
    /// floored at ~302 pt instead of the root clamp (`DeckPrefs.minWindow`, 270),
    /// because the card's 178 pt demand won before
    /// `promptLineLimit(usableHeight:rows:banded:)` saw a small enough
    /// `usableHeight`. It is composed separately from the width frame (the same
    /// two-frames discipline as `DetailBand.body`) and applied unconditionally: it
    /// only refuses to report a FLOOR and never caps the ideal size, and scoping it to
    /// `banded` would leave the unbanded fleet open to a future minimum-propagating
    /// bug. `theBandTracksTheSelectionInRow` holds the ordinary behaviour.
    private var composition: some View {
        HStack(spacing: 0) {
            SessionOverview(runtime: runtime, layout: layout, fleetSize: fleetSize, banded: banded,
                            editing: editingLayout)
                .frame(width: banded ? OverviewLayout.bandFleetWidth : nil)
                .frame(minHeight: 0, alignment: .top)
            if banded {
                // `.move(edge: .trailing).combined(with: .opacity)` gives `Ticks` and
                // `DetailBand` a motion that eases together with the fleet's narrowing under the
                // same `.animation(value: banded)` below. Without a transition SwiftUI pops them
                // in at full size while only the fleet's width eases, which reads as janky.
                // Presentation only: the band's content is final from its first frame.
                //
                // On close the same transition governs removal, but
                // `bandTransitionAnimation(banded: false, ...)` returns `nil`, so the band simply
                // stops being there on the next frame. The asymmetry lives in the animation, not
                // in a second `.asymmetric` transition.
                //
                // This spring must not touch the fleet's own content: `SessionOverview`'s
                // `GlassEffectContainer` carries a container-scope `.transaction` override,
                // attached OUTSIDE the container as a load-bearing placement (see its comment
                // for the measured failures: lingering full-opacity ghosts over the selected
                // card, lazy-grid corruption). The open therefore moves only the fleet's width
                // and `Ticks`/`DetailBand`; cards and the shelf CUT on the selection frame.
                //
                // `Ticks` slot: a `VStack` of fixed 4x12 capsules, one per off-viewport
                // needs-you lane, with a minimum height of 15n - 3 (192 pt at 13 marks, 297 at
                // 20). Uncapped, it re-locks the window floor above the root clamp
                // (`DeckPrefs.minWindow`), the same deadlock as the fleet slot and the band: a
                // fixed-size stack anywhere in a `.windowResizability(.contentSize)` tree drags
                // the window floor up. Hence `minHeight: 0, maxHeight: .infinity` with
                // `.clipped()`; `.center` matches how the marks have always sat in this seam. The
                // seam is an indicator, not a ledger: marks past the clip are not counted
                // elsewhere. Arbiter: `theTicksSlotBareMinimumIsReducedByTheWrapper`
                // (`RenderSweepTests.swift`).
                Ticks(lanes: frame.lanes, selection: frame.selection)
                    .frame(minHeight: 0, maxHeight: .infinity, alignment: .center)
                    .clipped()
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                DetailBand(runtime: runtime, width: bandWidth, usableHeight: fleetSize.height,
                          dismissedStage: dismissedStage,
                          onOpenSessionActions: openSessionActions)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // The session-controls panel is attached HERE, on the composition root's own
        // content. Its scrim still covers the whole content area, which is all "tap away
        // to dismiss" needs (the toolbar is chrome). Attaching it near `.navigationTitle`
        // pushed the toolbar block past the type checker's budget.
        //
        // The delete confirmation stays further down the chain, presented by the WINDOW:
        // the Remove tile dismisses the panel as soon as it is tapped, and a
        // confirmation owned by a view that has just gone would go with it.
    }

    public var body: some View {
        composition
        .sessionActionsPanel(runtime: runtime, session: $sessionActionsFor)
        // The ONE geometry probe, on the ONE composition root. It measures the OFFER,
        // not the composition. Shrink a banded window 1600 -> 960: the `HStack` lays out
        // at exactly 324 + 8 + 628 = 960. Grow it back to 1600 and nothing asks the
        // `HStack` to BE wider, only not to be wider, so the probe kept reporting 960,
        // `bandWidth` never re-derived, and the composition floated centered with stale
        // fold state. Min-size fixes in `DetailBand.body` cannot help: this is a ceiling
        // problem, not a floor problem.
        //
        // The fix: `.frame(maxWidth: .infinity, maxHeight: .infinity, alignment:
        // .topLeading)` BEFORE the probe, so it measures the REGION. A greedy frame
        // accepts the full proposed size on both axes. `.topLeading` (not `.center`)
        // keeps content pinned to the corner the strip is read from during any transient
        // where the interior is smaller than the region. Arbiter:
        // `RenderSweepTests.theProbeReportsTheOfferNotTheStaleCompositionOnGrowth` does a
        // real shrink-then-grow (960, then 1600) on one host.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            layout = .forSize(width: size.width, height: size.height)
            fleetSize = size
            onContentSizeMeasured?(size)
        }
        // The deck says it is alive, permanently. Outside the band's content so it
        // survives a selection closing.
        //
        // Applied after (outside) the geometry probe so the probe measures only the room
        // the chrome leaves. The `.animation(_:value: banded)` below wraps both insets;
        // harmless, because neither bar's geometry changes when `banded` flips.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            StatusLine(status: runtime.status)
        }
        // And says when Claude Code cannot reach it, on the same terms. The fleet is NOT
        // always empty when the connection is broken: `claude agents --json` finds
        // sessions without any hooks, so a dead port shows cards that never update and
        // hides the explanation behind them.
        .safeAreaInset(edge: .top, spacing: 0) {
            ConnectionBanner(runtime: runtime, showingSetup: $showingSetup)
        }
        // The one animatable value is `banded` (a Bool, changing only at open/close),
        // never `fleetSize.width`: keyed on width it would also fire on every width
        // reported during a live drag-resize and on the full <-> compact zone flip inside
        // `DetailBand`, animating a CONTENT change (`OverviewLayout.BandZones` picking
        // different columns) instead of a state change. Keyed on `banded`, a live resize
        // while banded tracks the drag 1:1 and only the band's true in/out interpolates
        // (the scope `SessionOverview.scrollToSelection` records).
        //
        // `banded` is also threaded into the animation itself, so
        // `bandTransitionAnimation` answers per direction (spring opening, `nil`
        // closing) from this one call site. A hard cut on close also lets
        // `SessionOverview.scrollToSelection`'s `onChange(of: .selection)` re-scroll run
        // against a layout already at its final width.
        .animation(Self.bandTransitionAnimation(banded: banded, reduceMotion: frame.reduceMotion), value: banded)
            .sheet(isPresented: $showingSetup) {
                ConnectCard(runtime: runtime)
                    .frame(minWidth: 460, minHeight: 300)
                    .safeAreaInset(edge: .bottom) {
                        Button("Done") { showingSetup = false }
                            .buttonStyle(.glass)
                            .touchTarget(minWidth: 120)
                            .padding(12)
                    }
            }
            // A decision that arrives while nothing is open brings its own
            // session up. Keyed on the front hold rather than on the count, so
            // one request replacing another still counts as an arrival.
            .onChange(of: frame.decisions.first?.hold) { _, _ in
                if let session = Self.autoOpen(for: frame) { runtime.select(session) }
            }
            // Band-open exits edit mode: the banded fleet is a single-card rail with nothing
            // to reorder. Every route that opens the band funnels through `frame.selection`,
            // so this one `onChange` covers all of them.
            .onChange(of: banded) { _, isBanded in
                if isBanded { editingLayout = false }
            }
            // The deck runs for days. A settings file edited by hand, or
            // rewritten by another tool, would otherwise leave a Connected
            // badge on screen that stopped being true on Tuesday. Re-reading
            // when the window comes forward is cheap and catches the case that
            // actually happens; a file watcher would be more machinery for the
            // cases that do not.
            .onReceive(NotificationCenter.default.publisher(
                for: NSWindow.didBecomeKeyNotification)) { _ in
                Task { await runtime.refreshConnection() }
            }
            .navigationTitle("Open Agent Deck")
            .navigationSubtitle(subtitle)
            .deleteConfirmation(runtime)
            .toolbar {
                // The way back to the fleet, and the way to one session's detail.
                //
                // `!banded`: the band's own header carries this exact glyph and action
                // (`DetailBand.header`'s collapse button, `runtime.dismiss()`) at the full 44 pt
                // touch floor, and two copies rendered almost touching at the right edge. This
                // one is the open-details affordance whenever no band is up: nothing selected,
                // or a stage overlay owns the hold (`bandShown`: not merely covered, not
                // composed). `SessionOverview.cardTap` still collapses on a re-tap in `.row`.
                if !banded {
                    // Edit Layout is declared BEFORE "Session Details" so it renders to that
                    // button's left. Both are fleet-wide affordances with nothing to say while the
                    // band owns the strip; `.onChange(of: banded)` ends edit mode when the band opens.
                    //
                    // `.disabled` under two visible cards: nothing to reorder.
                    ToolbarItem(placement: .primaryAction) {
                        Button {
                            editingLayout.toggle()
                        } label: {
                            editingLayout
                                ? Label("Done", systemImage: "checkmark.circle.fill")
                                : Label("Edit Layout", systemImage: "square.grid.3x2")
                        }
                        .disabled(frame.visibleLanes.count < 2)
                        .help(editingLayout ? "Done editing the fleet's order"
                                            : "Reorder the fleet by dragging")
                    }
                    ToolbarItem(placement: .primaryAction) {
                        let toggle = Self.detailToggle(for: frame)
                        Button {
                            switch toggle {
                            case .open(let session): runtime.select(session)
                            case .close: runtime.dismiss()
                            case .unavailable: break
                            }
                        } label: {
                            Label("Session Details", systemImage: "sidebar.trailing")
                        }
                        .disabled(toggle == .unavailable)
                        .help(toggle.help)
                    }
                }
                if let usage = frame.usage {
                    ToolbarItem(placement: .status) {
                        // A readout, not a control, so no touch floor applies. Its meaning may not live
                        // in a tooltip: `help` needs a pointer, and the surfaces this app is for have
                        // none. The condition is in the accessibility label; `help` is enrichment for
                        // the mouse.
                        //
                        // TEXT, not a glyph: a toolbar `Label` renders icon-only on macOS, which would
                        // leave an unlabelled dial. `limited` governs red; otherwise each window steps
                        // GREEN through ORANGE by its own load (see `usageText(for:)`).
                        //
                        // `.title3` because the deck's home is an 8.8" strip read at a glance, arm's
                        // length or further.
                        Self.usageText(for: usage)
                            .font(.title3.weight(.semibold))
                            .monospacedDigit()
                            .accessibilityLabel(usage.spokenDescription)
                            .help(usage.limited ? "The account is at its usage limit" : "Account usage")
                    }
                }
            }
            // The full-strip takeover, last in the chain on purpose: it is layered over
            // everything above (fleet, status line, connection banner), so a previewed
            // question OWNS the strip, as the terminal's own dialog owns the screen. The band
            // is coverable content, so a selection needs no special case; the band is also
            // simply not COMPOSED while staged (`bandShown`), belt-and-braces alongside the
            // overlay. The toolbar is native window chrome above the content view, so it
            // alone stays reachable.
            .overlay {
                // At most one is non-nil (`stageMirror`): this chooses between two data sources
                // for one overlay slot, not two overlays that could stack.
                if let stageDecision {
                    QuestionStage(decision: stageDecision, sessionName: stageSessionName,
                                 runtime: runtime) {
                        dismissedStage = stageDecision.hold
                    }
                } else if let stageMirror {
                    QuestionMirrorStage(mirror: stageMirror, sessionName: stageSessionName,
                                       runtime: runtime) {
                        dismissedStage = stageMirror.hold
                    }
                }
            }
            // The root minimum. `.windowResizability(.contentSize)` (`DeckScene.swift`)
            // enforces the window's resize FLOOR from the content's MINIMUM size. The band's
            // uncompressible interior (fixed rows, every `.touchTarget()`'s
            // `.frame(minWidth:minHeight:)`) reports a minimum that depends on the
            // composition, and `DetailBand.body`'s `.frame(maxWidth:maxHeight:)` cap bounds
            // only the IDEAL size. Live symptom: open the band, close it, then try to shrink
            // the window: it snaps back to the size it had when the band opened.
            //
            // The fix is an explicit `.frame(minWidth:minHeight:)` at the outermost point,
            // after every other modifier so nothing above can smuggle a larger demand past
            // it, sourced from `DeckPrefs.minWindow`, the same constant the settings pane and
            // the prefs decoder clamp to. No `maxWidth`/`maxHeight`: only the floor is fixed.
            // An outer min frame raises a smaller interior demand to the floor and leaves a
            // larger one alone for the ideal query, while the minimum query `.contentSize`
            // consults reports exactly the floor either way
            // (`RenderSweepTests.bandedDeckWindowMinimumIsTheConstantFloorRegardlessOfComposition`).
            .frame(minWidth: Double(DeckPrefs.minWindow.width),
                   minHeight: Double(DeckPrefs.minWindow.height))
    }

    /// Whether the band is actually composed right now: the one flag the HStack
    /// reads. `bandShown` and its pure-function tests are the single source of truth,
    /// so the built view and the testable rule cannot drift.
    private var banded: Bool {
        Self.bandShown(for: frame, dismissedStage: dismissedStage, layout: layout,
                       usableWidth: fleetSize.width, usableHeight: fleetSize.height)
    }

    /// What is left of the content region for the band once the fleet
    /// (`OverviewLayout.bandFleetWidth`) and the ticks seam
    /// (`OverviewLayout.bandSeamWidth`) have taken their share — computed
    /// here rather than measured inside `DetailBand`, so the width the
    /// zone-drop rule (`OverviewLayout.bandZones(for:)`) decides from and
    /// the width the band actually renders at are the SAME number by
    /// construction, not two readings of one layout that could drift.
    private var bandWidth: Double {
        max(0, fleetSize.width - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth)
    }

    /// Exposed for tests: whether a live `DeckWindow`, built with an
    /// explicit `layout`/`fleetSize`, actually composes the band rather
    /// than merely computing that the pure rule says it should. The
    /// identical `banded` `body` itself reads — a test asserting this is
    /// asserting what actually got composed, not a parallel recomputation
    /// that could drift from it.
    var bandShownForTesting: Bool { banded }

    /// What the details button does, as a value: a rule rather than a branch in a
    /// `Button` closure, so it is testable. Deselecting a macOS `List` takes a
    /// command-click, so without an explicit control the fleet was unreachable.
    enum DetailToggle: Equatable {
        /// Nothing is selected; opening picks a session to open ON.
        case open(SessionID)
        case close
        /// No sessions at all, so there is nothing to inspect.
        case unavailable

        var help: String {
            switch self {
            case .open: "Show session details"
            case .close: "Back to all sessions"
            case .unavailable: "No sessions yet"
            }
        }
    }

    static func detailToggle(for frame: Frame) -> DetailToggle {
        if frame.selection != nil { return .close }
        // The waiting one first, searched over EVERY lane rather than the drawn ones.
        // `mastNeedsYou` counts hidden lanes on purpose (a concealed request for a human
        // is what this deck exists not to swallow), so searching only `visibleLanes`
        // produced a subtitle saying "1 needs you" and an enabled button that silently
        // opened some other quiet session.
        let target = frame.lanes.first { $0.state == .needsYou }
            ?? frame.visibleLanes.first
            ?? frame.lanes.first
        return target.map { .open($0.session) } ?? .unavailable
    }

    /// The toolbar usage readout's `Text`, pulled out of the toolbar closure because
    /// LIMITED decides between one colour and many.
    ///
    /// - limited: the whole label, including the "— resets in…" suffix `usage.windows`
    ///   never carries, is governed by one deadline fact, so it wears one colour,
    ///   `.red`.
    /// - not limited: each window gets its own `Load.tint`, at any age. Two windows
    ///   are two facts, and a five-hour window idling at 3 % must not borrow the
    ///   colour a seven-day window earned at 81 %.
    ///
    /// Falls back to the plain label in `.secondary` when `usage.windows` is empty.
    /// The projection always populates it, but the view states its precondition
    /// rather than drawing nothing.
    static func usageText(for usage: UsageIndicator) -> Text {
        guard !usage.limited else {
            return Text(usage.label).foregroundStyle(.red)
        }
        guard !usage.windows.isEmpty else {
            return Text(usage.label).foregroundStyle(.secondary)
        }
        let pieces = usage.windows.map {
            Text("\($0.shortName):\($0.percent)%").foregroundStyle($0.load.tint)
        }
        // Joined by INTERPOLATING each `Text` into the next rather than
        // `+`-concatenating them: `Text`'s own `+` is deprecated on this
        // SDK in favour of exactly this — a nested `Text` inside another
        // `Text`'s string interpolation keeps each piece's own style,
        // the same guarantee `+` gave, without the deprecation.
        return pieces.dropFirst().reduce(pieces[0]) { joined, next in
            Text("\(joined) \(next)")
        }
    }

    /// Which session a newly-arrived decision should bring up, or none.
    ///
    /// Decisions live in the band, and a band only opens for a selected session, so
    /// something has to make the selection or the deck's one job depends on the user
    /// having already picked the right session.
    ///
    /// Declines while a LIVE session is selected: yanking the pane away from a
    /// session somebody is reading, on every unrelated hook, would make the deck
    /// unusable when it is busiest. The waiting card is still tinted, chipped and
    /// glyphed, so a request is never silent.
    ///
    /// An `.ended` selection yields the pane like no selection, since nobody is
    /// reading an ended session (a selection parked on one blocked two live
    /// questions). `.errored` does NOT yield: an error is still news, and
    /// `Projection` keeps an errored lane on the strip until dismissed, where an
    /// ended one retires after `endedGrace` (Frame.swift). A selection whose lane
    /// cannot be found is not known to be ended either, so it declines: the safe
    /// default.
    static func autoOpen(for frame: Frame) -> SessionID? {
        if let selection = frame.selection,
           frame.lanes.first(where: { $0.session == selection })?.state != .ended {
            return nil
        }
        return frame.decisions.first?.hold.session
    }

    /// Exposed for tests: the sentence is this file's decision, and a
    /// decision worth making is worth asserting.
    var subtitleForTesting: String { subtitle }

    private var subtitle: String {
        let count = frame.lanes.count
        let noun = count == 1 ? "session" : "sessions"
        guard frame.mastNeedsYou > 0 else { return "\(count) \(noun)" }
        return "\(count) \(noun) · \(frame.mastNeedsYou) needs you"
    }
}

// ----------------------------------------------------------- the status line

/// The deck saying it is alive, along the bottom edge, always.
///
/// This is not chrome. An always-on device that has stopped receiving looks
/// exactly like one with nothing to report — both quiet, both apparently fine
/// — and this deck's entire claim is that it will speak up when a session
/// needs a human. The claim rests on a bound socket, so the socket gets a
/// permanent line.
struct StatusLine: View {
    let status: HookServerStatus

    var body: some View {
        HStack(spacing: 6) {
            // A glyph as well as a colour: a red line and a green one differ
            // by hue alone otherwise, and this is a readout somebody checks by
            // glancing rather than by reading.
            Image(systemName: symbolName)
                .font(.caption2)
                .foregroundStyle(status.severity.tint)
            Text(status.message)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(status.spokenDescription)
    }

    private var symbolName: String {
        switch status {
        case .notStarted, .stopped: "circle.dotted"
        case .listening: "antenna.radiowaves.left.and.right"
        case .failed: "exclamationmark.triangle.fill"
        }
    }
}
