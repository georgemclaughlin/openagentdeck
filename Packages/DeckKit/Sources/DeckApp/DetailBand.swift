//
//  DetailBand.swift · DeckApp
//
// One session's detail, taking the strip rather than a sidebar.
//
// **The band is what a selection always gets.** A selection never falls back
// to an `.inspector` sidebar, at any layout or size (see
// `OverviewLayout.presentation(...)`). When the surface is too small for the
// full recipe, the response is to SHRINK the recipe (the squeezed one, see
// `DecisionBar`'s squeezed parameters), never to switch idiom.
//
// Why a band: a sidebar is right for a tall or narrow window, but 380-760 pt of
// sidebar on a 1920 x 480 strip stacks its content until it scrolls, and a
// decision that scrolls is a decision somebody can miss. So a selection narrows
// the fleet to the selected card alone (`OverviewLayout.bandFleetWidth`) and
// hands the rest of the strip to this band. The selected card IS the band's
// header: nothing here repeats the session's name, branch, state or current
// prompt, because a fact rendered twice can disagree with itself. The dedup
// table at the bottom of this file is the rule.
//
// **No scroll at the layout level.** Every zone has a measured budget and a
// declared way to say "there is more" (`SubjectWell`'s chip,
// `QuestionOptionsBand`'s marker, this file's "▾ N more"). A zone-internal
// capped well is fine; a `ScrollView` around the whole band is not.
//
// **The band never DEMANDS height.** `body`'s outer containment
// (`.frame(minHeight: 0, maxHeight: usableHeight)`, split from the width cap)
// keeps the band from dragging `.windowResizability(.contentSize)`'s resize
// floor up to whatever height it opened at, which would deadlock a shrinking
// window. See `body` for the live signature.

import SwiftUI
import DeckCore

/// The name `DetailBand.body`'s `.coordinateSpace` and its frame-measuring
/// probes share. A top-level constant rather than a `View` member, so a
/// `Sendable` `onGeometryChange` closure can read it without actor isolation.
/// `internal`, not `private`: `QuestionTakeover`'s probes read the same name so
/// a test sees all frames in one coordinate space.
let detailBandRootSpace = "DetailBand.root"

struct DetailBand: View {
    let runtime: DeckRuntime
    /// The band's width: everything to the right of the fleet and the ticks seam.
    /// Assigned by `DeckWindow`, not measured here, because
    /// `OverviewLayout.bandZones(for:)` is a pure function of this number and must
    /// see the value the layout actually gives the band.
    let width: Double
    /// The same height `DeckWindow`'s geometry probe decides
    /// `OverviewLayout.presentation(...)`/`.bandMinimumHeight` from: the
    /// safe-area-squeezed content region's real height. Threaded through rather than
    /// measured here, for the same reason as `width`:
    /// `OverviewLayout.bandWellHeight(usableHeight:)` is a pure function of it.
    /// Drives `wellExpandedMaxHeight`/`wellCollapsedLines` below.
    let usableHeight: Double
    /// Threaded straight through from `DeckWindow`: this band and the full-strip
    /// `QuestionStage` overlay must read the identical
    /// `Decision.showsStage(dismissedStage:)` rule, so one hold is never answered by
    /// both at once.
    let dismissedStage: HoldID?
    /// Asks the window to open `SessionActionsPanel` for this session; the `⋯`
    /// control's whole job.
    ///
    /// Reported upward rather than presented here: the panel's scrim has to cover
    /// the whole window so a tap "away" dismisses it. A scrim inside this view would
    /// leave the fleet live behind it, and a tap outside the panel would select a
    /// different session instead of closing the panel. Optional and `nil` by default
    /// so a bare `DetailBand` (render-sweep tests) compiles and gets a `⋯` that does
    /// nothing.
    var onOpenSessionActions: ((SessionID) -> Void)?
    /// Test seam only. Production never passes this, so a real band's
    /// `DecisionBar` starts collapsed. Threads to `DecisionBar.initiallyExpanded` so
    /// `bandFitsTheStripWorstCaseDecision` can measure the expanded worst case on
    /// the composed band.
    var wellInitiallyExpanded: Bool = false
    /// Test seam only (`RenderSweepTests.controlsColumnRendersAtItsOwnDeclaredWidth`).
    /// Uses `onGeometryChange` rather than a `PreferenceKey`, because a preference
    /// value never arrived in the single-pass headless harness (`measured(_:width:)`).
    /// The closure is called with whatever width SwiftUI actually laid the controls
    /// column out at.
    var onControlsColumnWidthMeasured: ((Double) -> Void)?
    /// Test seam only (`RenderSweepTests.theQuickActionsColumnNeverClipsInTheLiveRecordedShape`).
    /// Reports `QuickActionsColumn`'s frame in the band's UNCLIPPED coordinate space
    /// (`.coordinateSpace(name: detailBandRootSpace)`, set on the content that
    /// `.frame(maxWidth:maxHeight:).clipped()` contains), so a test reading
    /// `frame.maxY` sees exactly what `.clipped()` would trim. The column is budgeted
    /// through the same `columnsHeightBudget` the act zone and Controls share.
    var onQuickActionsFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only; same coordinate space as `onQuickActionsFrameMeasured`
    /// (`RenderSweepTests.theAutoContinueToggleNeverClipsInTheLiveRecordedShape`).
    /// Proves `autoContinueReservedHeight`'s reservation reaches the glass instead
    /// of trusting the arithmetic.
    var onAutoContinueFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only, threaded to `DecisionBar.onButtonsFrameMeasured`, which
    /// reads into `detailBandRootSpace` like the probes above
    /// (`RenderSweepTests.theAllowDenyRowNeverClipsInTheWorstCaseShape`).
    var onDecisionButtonsFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only, threaded to `DecisionBar.onWellFrameMeasured`. Lets
    /// `RenderSweepTests`' decision-row matrix tell "the subject well rendered" from
    /// "this budget's `showsWell` answered `false`" without reaching into
    /// `DecisionBar`'s private state.
    var onDecisionWellFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only, the `DecisionBar` `wellInitiallyExpanded` counterpart for
    /// `QuestionTakeover.otherFieldInitiallyExpanded`: measures a bare question's
    /// "Other…" field expanded on the composed band.
    var otherFieldInitiallyExpanded: Bool = false
    /// Test seam only, threaded to `QuestionTakeover.onOtherFieldFrameMeasured`.
    /// The takeover's interior (`OtherAnswerField`, `QuestionControls`) has no
    /// reservation like the action bar and auto-continue toggle, so a bare
    /// question's "Other…" field could clip while typed into
    /// (`RenderSweepTests.theTakeoverInteriorNeverClipsInTheLiveRecordedShape`).
    var onOtherFieldFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only, threaded to `QuestionTakeover.onControlsFrameMeasured`.
    /// Which of this and `onOtherFieldFrameMeasured` is the takeover's bottom-most
    /// interactive element depends on the question's shape (`QuestionControls` draws
    /// nothing on a single-select question's first step), so tests need both.
    var onControlsFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only: the band's OUTERMOST rendered frame in
    /// `detailBandRootSpace`, attached via `probingRootFrame` at the end of `body`'s
    /// modifier chain (after containment and `.clipped()`), so it reads what was
    /// actually laid out, not the pre-clip ideal
    /// (`RenderSweepTests.theBandFillsItsFullCommandedWidthEvenSqueezed`).
    /// `measured(_:width:)` wraps content in an exact `.frame(width:)`, so reading
    /// `fittingSize.width` back through it is a tautology; this probe reads the real
    /// width from a host whose proposal is the only thing setting the size.
    var onRootFrameMeasured: ((CGRect) -> Void)?

    /// The zone plan (`OverviewLayout.bandZonePlan(bandWidth:actionCount:usableHeight:minimumActWidth:)`),
    /// STORED so there is exactly one call per `DetailBand` value. A computed
    /// `private var` is re-evaluated on every access (six real calls per layout
    /// pass, each repeating `decisionMinimumActWidth`'s scan), and a `struct View`
    /// cannot memoize. `init` is the only place this is computed;
    /// `actZoneWidth`, `controlsShown`, `columns(for:)` and `yieldedHeaderFold` read
    /// the stored value.
    private let zonePlan: OverviewLayout.BandZonePlan

    /// The explicit `init` that computing `zonePlan` once requires. Parameters and
    /// defaults replicate the synthesized memberwise init, so every existing call
    /// site compiles unchanged. A stored property's default expression cannot read
    /// other instance properties, hence a real `init` body. `Self.decisionMinimumActWidth(runtime:usableHeight:)`
    /// and `Self.lane(runtime:)` are STATIC so `init` can call them before every
    /// stored property is set; the plan's inputs come from the raw parameters (which
    /// shadow the properties) rather than `self`.
    init(runtime: DeckRuntime, width: Double, usableHeight: Double, dismissedStage: HoldID?,
         onOpenSessionActions: ((SessionID) -> Void)? = nil,
         wellInitiallyExpanded: Bool = false,
         onControlsColumnWidthMeasured: ((Double) -> Void)? = nil,
         onQuickActionsFrameMeasured: ((CGRect) -> Void)? = nil,
         onAutoContinueFrameMeasured: ((CGRect) -> Void)? = nil,
         onDecisionButtonsFrameMeasured: ((CGRect) -> Void)? = nil,
         onDecisionWellFrameMeasured: ((CGRect) -> Void)? = nil,
         otherFieldInitiallyExpanded: Bool = false,
         onOtherFieldFrameMeasured: ((CGRect) -> Void)? = nil,
         onControlsFrameMeasured: ((CGRect) -> Void)? = nil,
         onRootFrameMeasured: ((CGRect) -> Void)? = nil) {
        self.runtime = runtime
        self.width = width
        self.usableHeight = usableHeight
        self.dismissedStage = dismissedStage
        self.onOpenSessionActions = onOpenSessionActions
        self.wellInitiallyExpanded = wellInitiallyExpanded
        self.onControlsColumnWidthMeasured = onControlsColumnWidthMeasured
        self.onQuickActionsFrameMeasured = onQuickActionsFrameMeasured
        self.onAutoContinueFrameMeasured = onAutoContinueFrameMeasured
        self.onDecisionButtonsFrameMeasured = onDecisionButtonsFrameMeasured
        self.onDecisionWellFrameMeasured = onDecisionWellFrameMeasured
        self.otherFieldInitiallyExpanded = otherFieldInitiallyExpanded
        self.onOtherFieldFrameMeasured = onOtherFieldFrameMeasured
        self.onControlsFrameMeasured = onControlsFrameMeasured
        self.onRootFrameMeasured = onRootFrameMeasured
        self.zonePlan = OverviewLayout.bandZonePlan(
            bandWidth: width, actionCount: runtime.frame.actions.count, usableHeight: usableHeight,
            minimumActWidth: Self.decisionMinimumActWidth(runtime: runtime, usableHeight: usableHeight))
    }

    /// Instance-side reader for `Self.lane(runtime:)`. Only `init` and the static
    /// `decisionMinimumActWidth` call the static form directly.
    private var lane: LaneView? { Self.lane(runtime: runtime) }

    /// Static so `init` can call it before `self` exists; `lane` above is a
    /// one-line wrapper around it.
    private static func lane(runtime: DeckRuntime) -> LaneView? {
        runtime.frame.selection.flatMap { id in
            runtime.frame.lanes.first { $0.session == id }
        }
    }

    /// The ONE direct read of `OverviewLayout.bandSqueezed(usableHeight:)` in this
    /// file. Every squeezed-recipe reader below (`actZoneFallback`'s notices, well
    /// compaction, `controlsShown`, `columns(for:)`'s actions-column fold) reads
    /// this, so a second copy cannot drift from it.
    ///
    /// Two exceptions: the `DecisionBar` call site (`actZone(for:)`) passes
    /// `OverviewLayout.bandDecisionButtonHeight(usableHeight:)` and
    /// `bandShowsDecisionTitle(usableHeight:stackedRowExtra:)`, which re-derive
    /// `bandSqueezed` from the same `usableHeight`. That is a second call of the same
    /// pure function on the same input, so the answers cannot disagree.
    private var squeezed: Bool { OverviewLayout.bandSqueezed(usableHeight: usableHeight) }

    /// Attaches a frame probe (the actions column's or the auto-continue toggle's)
    /// only when a closure is listening. Production never sets either closure, so
    /// attaching `.onGeometryChange` unconditionally would run its coordinate-space
    /// conversion on every layout pass of every real band only to discard the result.
    /// With `if let`, the modifier is absent from the view tree when nothing listens.
    @ViewBuilder
    private func probingRootFrame(_ content: some View, when probe: ((CGRect) -> Void)?) -> some View {
        if let probe {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(detailBandRootSpace)) }
                action: { probe($0) }
        } else {
            content
        }
    }

    /// `probingRootFrame`'s twin for `onControlsColumnWidthMeasured`, which reads a
    /// plain `Double` (the controls column's rendered width) rather than a `CGRect`.
    /// Same `if let` gate and reasoning.
    @ViewBuilder
    private func probingWidth(_ content: some View, when probe: ((Double) -> Void)?) -> some View {
        if let probe {
            content.onGeometryChange(for: Double.self) { $0.size.width } action: { probe($0) }
        } else {
            content
        }
    }

    /// The columns row's height budget: `usableHeight` minus the header's height
    /// (`OverviewLayout.bandHeaderHeight`). The act zone, Controls and the actions
    /// column all cap themselves to this one number, so none of them can become the
    /// thing deciding the row's height (see `controlsZone(for:budget:)` for the
    /// non-affine-chrome finding). `QuickActionsColumn` sits beside the act zone and
    /// Controls and reads this budget as its own `maxHeight`.
    ///
    /// Do not also subtract `columns(for:)`'s vertical padding: the
    /// `.frame(maxHeight:)` this feeds is applied AFTER that padding, so subtracting
    /// it again starves the row by 8 pt (`RenderSweepTests.bandFixedChromeArbiter`).
    /// Applied as a MAXIMUM on `columns(for:)`, so the row compresses
    /// (`.top`-aligned, like the band's outer containment) to leave the reserved
    /// slice, whatever the act zone's content wants to be.
    private var columnsHeightBudget: Double { Self.columnsHeightBudget(usableHeight: usableHeight) }

    /// Static form of `columnsHeightBudget`, callable from the static
    /// `decisionMinimumActWidth` (itself called from `init`) without a second copy
    /// of the formula.
    private static func columnsHeightBudget(usableHeight: Double) -> Double {
        max(0, usableHeight - OverviewLayout.bandHeaderHeight)
    }

    /// `columns(for:)`'s top-and-bottom padding. Reads
    /// `OverviewLayout.bandColumnsVerticalPadding` rather than restating the literal,
    /// as `bandColumnsHorizontalPadding` does for the horizontal pair.
    private static let columnsVerticalPadding: Double = OverviewLayout.bandColumnsVerticalPadding

    var body: some View {
        // Wraps the ENTIRE chain below, not one interior child: the root probe must
        // sit after every other modifier so it reads what actually got laid out
        // (see `onRootFrameMeasured`).
        probingRootFrame(rootContent, when: onRootFrameMeasured)
    }

    private var rootContent: some View {
        Group {
            if let lane {
                VStack(spacing: 0) {
                    header
                    columns(for: lane)
                        // Both paddings read `OverviewLayout` / `Self.columnsVerticalPadding`
                        // rather than bare literals: `OverviewLayout.bandMinimumWidth` adds the same
                        // horizontal number on both sides of the act zone's minimum, and the height
                        // budget math (`bandFitsTheStripWorstCaseDecision`) subtracts the same vertical
                        // padding production actually spends, so the pure arithmetic and the view
                        // cannot disagree.
                        .padding(.horizontal, OverviewLayout.bandColumnsHorizontalPadding)
                        .padding(.vertical, Self.columnsVerticalPadding)
                        // `maxHeight: columnsHeightBudget`, not `.infinity` (see that property).
                        // `.clipped()` makes `.topLeading` real: without it the row's overflow still
                        // PAINTS past this boundary even though it is no longer reported upward.
                        .frame(maxWidth: .infinity, maxHeight: columnsHeightBudget, alignment: .topLeading)
                        .clipped()
                }
            } else {
                // Unreachable in production (`DeckWindow` composes this band only when
                // `frame.selection` is non-nil), but a view should state what happens when its
                // precondition fails.
                ContentUnavailableView("No Session Selected",
                                       systemImage: "square.dashed",
                                       description: Text("Choose a session to see its detail."))
            }
        }
        .coordinateSpace(name: detailBandRootSpace)
        // **Containment.** `DeckScene`'s `.windowResizability(.contentSize)` sizes the
        // WINDOW to whatever this view reports as its ideal/minimum size. Without a cap,
        // content the zones do not budget (a bare `QuestionTakeover`'s options grid, the
        // queue column's earlier-prompts GroupBox, `AutoContinueToggle`) grows the
        // window instead of clipping. Live arbiters:
        // `RenderSweepTests.bandFitsTheLiveRecordedShapeAtItsOwnHeightFloor` and
        // `.bandedDeckWindowFitsTheStripWithoutGrowingIt`.
        //
        // Use `maxWidth`/`maxHeight`, never exact `width`/`height`: a maximum still
        // reports a smaller natural size when the content is smaller (the exact-fill
        // assertions in `bandFitsTheStripWorstCaseDecision` stay meaningful). `.top`,
        // not `.center`: when content truly does not fit (rare, since
        // `columnsHeightBudget` already caps every column), the header and the decision
        // stay visible and the excess is trimmed from the bottom. `.clipped()` is what
        // enforces that alignment; a `.frame(maxHeight:)` alone caps the reported size
        // but still paints overflow into whatever sits below the band.
        //
        // **Deadlock-breaker (height).** `.frame(maxWidth:maxHeight:)` caps the REPORTED
        // IDEAL size but not the REPORTED MINIMUM, which is the number
        // `.windowResizability(.contentSize)` uses as the window's resize floor (see
        // `measuredMinimum(_:)` in `RenderSweepTests.swift`). Any fixed floor inside the
        // band (a `.touchTarget()` `.frame(minHeight:)`, a titled card that will not
        // compress) propagates up through a bare `maxHeight` as the band's minimum, and
        // `DeckWindow`'s outer `.frame(minWidth:minHeight:)` only floors at
        // `DeckPrefs.minWindow`; it does not stop a taller interior demand from winning.
        // Live signature: two stable window floors at the same size, depending on whether
        // the height was walked down in steps or jumped, i.e. a minimum tracking
        // composition history. Fix: state `minHeight: 0` on its own `.frame`, separate
        // from the width cap, so the band reports no minimum of its own.
        // `RenderSweepTests.detailBandNeverDemandsHeight` is the arbiter.
        //
        // **Deadlock-breaker (width).** Same bug one axis over. `actZoneWidth`'s EXACT
        // `.frame(width:)` is a hard min-and-max demand on the act zone; with no floor
        // on this outer frame it propagated up as the band's minimum width. Live
        // signature: band at 1600x480, window resized to 960x320 in one step;
        // `DeckWindow.bandWidth` derived from the stale `fleetSize.width`, so the exact
        // width became the window's enforced minimum, wider than the window frame. The
        // content was pushed off the left edge and further resize requests were ignored.
        // `minWidth: 0` makes the window's own root clamp (`DeckPrefs.minWindow`) govern
        // the floor; the interior is laid out at the stale width for at most one
        // transient pass, `.clipped()` hides the overspill, and it self-corrects when
        // `DeckWindow`'s geometry probe fires. `RenderSweepTests.detailBandNeverDemandsWidth`
        // is the arbiter, including the stale-input case.
        .frame(minHeight: 0, maxHeight: usableHeight, alignment: .top)
        .frame(minWidth: 0, maxWidth: width, alignment: .top)
        .clipped()
    }

    // ------------------------------------------------------------- header

    /// Overflow-honesty declaration for the Quick Actions column: the actions the
    /// column could not show. The column survives down to the window's floor and may
    /// show SOME actions without room for all, so this answers the tail:
    /// `runtime.frame.actions.dropFirst(plan.capacity)` when the column is present
    /// (empty when everything fits), or the WHOLE list when it is absent
    /// (`zonePlan.actions == nil`: no actions offered, or the geometry is too starved
    /// for the narrowest shape; see `OverviewLayout.BandZonePlan.actions`). The chip
    /// names exactly what the column could not show. `zonePlan`'s single ladder folds
    /// width AND height into one `rows`/`capacity` answer, so this never needs to know
    /// which reason shrank the column.
    ///
    /// A designed absence, not a crash, on a width this cannot honestly fit. It uses
    /// `ActionPillMeasurer.chipWidth(hiding:)`, the real-control measurement of
    /// `QuickActionBar.bareOverflowControl(hiddenCount:)`, as a conservative proxy:
    /// that pill-styled chip is taller and wider than this header's own chip
    /// (`QuickActionBar.headerOverflowControl`), so if it fits the smaller one does.
    /// `required` adds the collapse button's `TouchTarget.minimum` square, an 8 pt
    /// gap, and the header's 12 pt horizontal padding on both sides. The min window
    /// legitimately composes a 628 pt band (under the old 644 pt routing floor), so
    /// this guard matters in production. `theBandFillsItsFullCommandedWidthEvenSqueezed`'s
    /// discrimination case (`RenderSweepTests.swift`) holds a genuinely narrow band
    /// accountable.
    ///
    /// It also counts the folded-controls menu whenever `!controlsShown`: the same
    /// header row seats it (`compactControlsMenu`) beside this chip, and a band narrow
    /// enough to fold both could otherwise under-count
    /// (`RenderSweepTests.headerCarriesBothFoldsTogether`). The ctx readout is
    /// deliberately NOT counted: it is a reading, not a control, absent whenever the
    /// lane feeds none (`LaneView.contextPercent`), and compressing by a few points
    /// loses nothing. This guard protects CONTROLS from silently disappearing.
    private var yieldedHeaderFold: [QuickAction] {
        let plan = zonePlan
        // The tail beyond what the column can hold when it is present; the whole list
        // when it is absent (see `BandZonePlan.actions`).
        let hidden = plan.actions.map { Array(runtime.frame.actions.dropFirst($0.capacity)) }
            ?? runtime.frame.actions
        guard !hidden.isEmpty else { return [] }
        let chipWidth = ActionPillMeasurer.chipWidth(hiding: hidden.count)
        let menuShare = plan.controlsShown ? 0 : TouchTarget.minimum + 8
        let required = chipWidth + 8 + TouchTarget.minimum + 2 * 12 + menuShare
        guard required <= width else { return [] }
        return hidden
    }

    /// The header row: the collapse button and the selected session's ctx
    /// reading. The selected card IS the header, so no title, name or state appears
    /// here. Two more items sit at the leading edge: `yieldedHeaderFold` (a chip for
    /// actions the Quick Actions column could not show) and the folded-controls menu
    /// (`compactControlsMenu`), shown whenever `!controlsShown` (width and height both
    /// feed that boolean; see `OverviewLayout.bandControlsShown(bandWidth:usableHeight:)`).
    /// The menu lives here, not in the act zone's footer, because the footer sits
    /// below the decision and clipped exactly when the fold was needed; the header
    /// always has its own fixed 48 pt row, so a folded-away control is guaranteed
    /// reachable.
    ///
    /// The ctx reading is `ctx:NN%` (the idiom of `Meter.reading`, read via
    /// `Meter.context(usedPercent:)`) at `.title3.weight(.semibold)` with
    /// `.monospacedDigit()`, the family `DeckWindow`'s toolbar usage readout uses for
    /// "the strip, not the desk": legible at arm's length. Coloured by
    /// `ContextLoad(percent:).tint`, the one rule shared with `SessionCard.contextTint`.
    /// Absent entirely when `lane?.contextPercent` is nil: a gauge nobody has fed
    /// claims nothing (`LaneView.contextPercent`). `SessionCard.hidesContext` drops the
    /// selected card's own footer reading while banded, so the fact appears once.
    ///
    /// This does not grow the header: `bandHeaderHeight` (48) is governed by the
    /// collapse button's `TouchTarget.minimum` (44) plus 2 pt top and bottom padding;
    /// the tallest string ("ctx:100%") sits under 44. `headerShowsCtxExactlyWhenFed`
    /// (`RenderSweepTests`) pins the fed header at 48 through the wire path, and
    /// `bandHeaderAndAutoContinueMatchTheirNamedHeights` pins the unfed one.
    ///
    /// Not `private`: `RenderSweepTests` measures this directly, like
    /// `QuestionStage.header`.
    var header: some View {
        HStack(spacing: 8) {
            let hiddenForFold = yieldedHeaderFold
            if !hiddenForFold.isEmpty {
                QuickActionBar.headerOverflowControl(hidden: hiddenForFold, runtime: runtime)
            }
            if !controlsShown, let lane {
                compactControlsMenu(for: lane)
            }
            Spacer(minLength: 0)
            if let percent = lane?.contextPercent {
                // ONE clamped derivation feeds the drawn string, the colour, and the SPOKEN
                // value. `Meter.context(usedPercent:)` holds the render-side clamp (the feed
                // stores the statusline's raw integer); speaking the raw value would say
                // "context 140 percent" while drawing "ctx:100%".
                let meter = Meter.context(usedPercent: percent)
                Text(meter.reading)
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ContextLoad(percent: meter.used).tint)
                    .accessibilityLabel("context \(meter.used) percent")
            }
            Button {
                runtime.dismiss()
            } label: {
                Image(systemName: "sidebar.trailing")
                    .font(.body.weight(.semibold))
            }
            .buttonStyle(.glass)
            .touchTarget(minHeight: TouchTarget.minimum, minWidth: TouchTarget.minimum)
            .accessibilityLabel("Collapse, back to the fleet")
            .help("Back to all sessions")
        }
        .padding(.horizontal, 12)
        // 2, not 6: the touch floor is the button's own `TouchTarget.minimum`,
        // unaffected by trimming the chrome around it.
        .padding(.vertical, 2)
        .overlay(alignment: .bottom) { Divider() }
    }

    // ------------------------------------------------------------ columns

    /// The one input to `zonePlan` that is not already inside `OverviewLayout`.
    /// It is content-driven, not act-width-driven, so asking before the plan exists
    /// is not circular. Rule: the actions column yields when, and only when, the
    /// alternative is a clipped Allow/Deny row, never for width alone (that is
    /// `bandZonePlanCascade` in `OverviewLayout.swift`). Two facts decide it, neither
    /// a function of the act width:
    ///
    ///     needed  = DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)
    ///               + 2 × outerPadding      // stays on one line above this
    ///     stacked = buttonCount × buttonHeight
    ///               + (buttonCount − 1) × bandDecisionRowStackSpacing
    ///               + barChrome             // the row's own worst-case total
    ///
    /// `needed` is the row's natural width plus its bar's padding, the same
    /// `rowWidth + 2 × outerPaddingValue` `actZone(for:)`'s `stacks` check computes
    /// from the same cached `DecisionRowMeasurer.rowWidth`. `stacked` is the row's
    /// height once it can only stack, matching `OverviewLayout.bandDecisionRowExtraHeight(stacks:buttonCount:usableHeight:)`.
    ///
    /// `barChrome` is `decisionBarOuterPadding(squeezed:) + OverviewLayout.bandColumnsVerticalPadding`:
    /// the floor-case chrome above the button row with title and well folded. Title
    /// and well ARE folded whenever this guard could fire: `bandShowsDecisionTitle`
    /// and `bandWellFits` fold at 116 pt / 200 pt of budget past `stackedRowExtra`,
    /// while this guard's threshold is `stackedRowExtra + buttonHeight + barChrome`,
    /// where `buttonHeight + barChrome` is 50 squeezed (44 + 6) or 76 full (64 + 12),
    /// both under 116 and 200. Confirmed against a live render: a bare `DecisionBar`
    /// with `showsTitle: false, showsWell: false` measures `2 × outerPadding +
    /// buttonHeight` (48 pt squeezed), and the composed band measures 6 pt above the
    /// button row at every squeezed geometry this guard folds (band 628 usable
    /// 189/209/249/149, band 874 usable 250).
    ///
    /// The one question asked: does `stacked + barChrome > columnsHeightBudget`
    /// (`usableHeight − bandHeaderHeight`)? If so, `needed` is the width `zonePlan` is
    /// told to demand of the actions column; otherwise 0, as if this guard did not
    /// exist. What `zonePlan` does with the demand is its own decision
    /// (`OverviewLayout.bandZonePlan`): it folds the column only when folding actually
    /// reaches the demanded width.
    ///
    /// Returns 0 when no decision is on screen and no `DialogAnswerPanel` either, or
    /// when the hold carries QUESTIONS (`QuestionTakeover` owns that shape; no button
    /// row to protect). The lane/decision lookup mirrors `actZone(for:)`'s
    /// `DecisionBar` branch, recomputed here because this runs from `init`, before
    /// `actZone(for:)` and before `self.lane` is safe to read.
    ///
    /// `DialogAnswerPanel` uses the same arithmetic with a second source of `titles`.
    /// Its three titles are FIXED text (`QuickAction.dialogAnswers`), so nothing here
    /// can give ground. Measured (`DecisionRowMeasurer.rowWidth`): 490 pt at the full
    /// 140 pt button floor, 430 pt squeezed, both over the 350 pt (`bandActFloorWidth`)
    /// the min window's band leaves with the column present, so that row always
    /// stacked and clipped. The condition mirrors `actZoneFallback(for:budget:)`'s
    /// `.needsYou` branch exactly (`lane.state == .needsYou`, no mirror claiming the
    /// hold, `DialogAnswerPanel.answers(lane.waitingFor)`): a looser one would demand
    /// room for a row never drawn when `HandedBackNotice` renders.
    ///
    /// STATIC because `init` needs it before any stored property is safe to touch
    /// (see `zonePlan`); `runtime`/`usableHeight` are the raw parameters.
    private static func decisionMinimumActWidth(runtime: DeckRuntime, usableHeight: Double) -> Double {
        guard let lane = Self.lane(runtime: runtime) else { return 0 }
        let squeezed = OverviewLayout.bandSqueezed(usableHeight: usableHeight)
        let outerPaddingValue = Self.decisionBarOuterPadding(squeezed: squeezed)
        let titles: [String]
        let buttonCount: Int
        // `rowlessChrome`: everything the floor-case render still draws above and
        // below the row, per branch. `DecisionBar`'s is `outerPaddingValue` alone (title
        // and well are already folded). `DialogAnswerPanel` does not fold
        // (`dialogAnswerPanelChrome(squeezed:)`), and reusing `DecisionBar`'s smaller
        // figure undercounted its chrome by 3-6 pt
        // (`RenderSweepTests.theDialogAnswerPanelObeysTheSameHeightBudgetAsItsSibling`).
        let rowlessChrome: Double
        if let decision = runtime.frame.decisions.first(where: { $0.hold.session == lane.session }),
           decision.questions.isEmpty {
            let decisionTitles = DecisionBar.buttonTitles(for: decision)
            titles = [decisionTitles.yes] + decisionTitles.suggestions + [decisionTitles.no]
            buttonCount = decisionTitles.suggestions.count + 2
            rowlessChrome = outerPaddingValue
        } else if lane.state == .needsYou,
                  runtime.frame.mirrors.first(where: { $0.hold.session == lane.session }) == nil,
                  DialogAnswerPanel.answers(lane.waitingFor) {
            titles = QuickAction.dialogAnswers.map(\.displayTitle)
            buttonCount = titles.count
            rowlessChrome = Self.dialogAnswerPanelChrome(squeezed: squeezed)
        } else {
            return 0
        }
        let buttonMinWidth = OverviewLayout.bandDecisionButtonMinWidth(usableHeight: usableHeight)
        let buttonHeight = OverviewLayout.bandDecisionButtonHeight(usableHeight: usableHeight)
        let needed = DecisionRowMeasurer.rowWidth(titles: titles, buttonMinWidth: buttonMinWidth) + 2 * outerPaddingValue
        let barChrome = rowlessChrome + OverviewLayout.bandColumnsVerticalPadding
        let stacked = Double(buttonCount) * buttonHeight
            + Double(buttonCount - 1) * OverviewLayout.bandDecisionRowStackSpacing
        return (stacked + barChrome > Self.columnsHeightBudget(usableHeight: usableHeight)) ? needed : 0
    }

    /// The act zone's width, computed from `zonePlan.actWidth` rather than left to
    /// a SwiftUI `.frame(minWidth:)` negotiation. A hard `.frame(minWidth:)` on the
    /// act zone would make the whole band, and everything above it up to `DeckScene`'s
    /// `.windowResizability(.contentSize)`, demand that width no matter what `width`
    /// offered. An EXACT `.frame(width:)` makes the act zone render AT the width it is
    /// given, letting `DecisionBar`/`QuestionTakeover`'s `ViewThatFits` button-wrap
    /// work at every reachable width. `.windowResizability(.contentSize)` reads the
    /// content tree's hard constraints directly, never routing state;
    /// `RenderSweepTests.bandNeverDemandsMoreWidthThanItIsGiven` is the arbiter.
    ///
    /// At the min window's 628 pt band with even one quick action, `zonePlan.actWidth`
    /// lands on 350 (`bandActFloorWidth`), the mandatory column's squeezed step (see
    /// `bandZonePlan`), not 604.
    ///
    /// This exact frame bounds the width against a live `width` only. If `width` is
    /// stale (a fast single-step window resize before `DeckWindow`'s geometry probe
    /// re-fires), the exact frame's demand would propagate up as the band's minimum
    /// width; `body`'s outer `.frame(minWidth: 0, maxWidth: width)` refuses that.
    /// See `detailBandNeverDemandsWidth` (`RenderSweepTests.swift`).
    ///
    /// Not `private`: `RenderSweepTests`' decision-row matrix needs the REAL act width
    /// a composed `DetailBand` hands `DecisionRowMeasurer`, instead of re-deriving the
    /// formula by hand.
    var actZoneWidth: Double { zonePlan.actWidth }

    /// Whether Controls draws at all, read off `zonePlan`, the one derivation
    /// shared with `actZoneWidth`, `columns(for:)` and `header`. It is a field read,
    /// not a second call to `OverviewLayout.bandControlsShown(bandWidth:usableHeight:)`.
    private var controlsShown: Bool { zonePlan.controlsShown }

    /// The shared reflow key. `QuickActionsColumn` easing its own width alone, with
    /// no animation in the act zone's or Controls' ancestry, read as a column
    /// DETACHING from its neighbours mid-transition (act zone snapping, Controls
    /// vanishing). The key covers every `zonePlan` field that moves more than one
    /// column: `actWidth`, `actions?.columnWidth` (sub-column flip), `actions?.rows`
    /// (taller or shorter at unchanged width) and `controlsShown`. `columns(for:)`'s
    /// trailing `.animation(...)` on the `HStack` reads it, so a change to any one
    /// eases the whole row as one event. `QuickActionsColumn`'s own narrower
    /// `ReflowKey` (`DecisionBar.swift`) covers the one case this key cannot see: a
    /// row appearing or disappearing at an unchanged plan.
    private struct ReflowKey: Equatable {
        let actWidth: Double
        let actionsColumnWidth: Double?
        let actionsRows: Int?
        let controlsShown: Bool
    }

    /// Built from `zonePlan`'s stored fields; it does NOT re-invoke
    /// `OverviewLayout.bandZonePlan(...)`.
    private var reflowKey: ReflowKey {
        ReflowKey(actWidth: zonePlan.actWidth, actionsColumnWidth: zonePlan.actions?.columnWidth,
                 actionsRows: zonePlan.actions?.rows, controlsShown: zonePlan.controlsShown)
    }

    /// Every zone crossing costs exactly one `OverviewLayout.bandZoneGutter`, split
    /// evenly around the hairline. The outer `HStack`'s `spacing` is 0 because
    /// `spacing:` applies between EVERY adjacent pair, so a bare `Divider()` child
    /// would cost two gutters per crossing instead of the one `bandZoneThreshold`
    /// budgets. `zoneDivider` carries the gutter as its own padding.
    @ViewBuilder
    private func columns(for lane: LaneView) -> some View {
        HStack(alignment: .top, spacing: 0) {
            actZone(for: lane)
                .frame(width: actZoneWidth, alignment: .topLeading)
                .frame(maxHeight: .infinity, alignment: .topLeading)
            // Reading order matches a glance: what is happening (act), what you can say
            // to it (actions), what you can do to the session (controls).
            // `zonePlan.actions` is the same stored plan read above; the full
            // `BandActionsPlan` is needed because `QuickActionsColumn` draws only the
            // `subColumns`/`rows` the plan says fit.
            if let actionsPlan = zonePlan.actions {
                zoneDivider
                // `QuickActionsColumn` imposes its OWN width inside its `body` (see its
                // `plan`). The trailing `.animation(...)` below wraps the whole `HStack`, so it
                // reaches the column either way.
                probingRootFrame(QuickActionsColumn(runtime: runtime, budget: columnsHeightBudget, plan: actionsPlan)
                                    .frame(maxHeight: .infinity, alignment: .topLeading),
                                 when: onQuickActionsFrameMeasured)
            }
            // `!controlsShown` drops Controls when width OR height folded (see
            // `OverviewLayout.bandControlsShown(bandWidth:usableHeight:)`);
            // `compactControlsMenu(for:)` in the header is where Controls survives. The
            // transcript well renders inside the act zone at every width, so there is no
            // Queue/Earlier column here.
            if controlsShown {
                // `Group { … }.transition(.opacity)`: Controls is an animated participant in
                // the row's reflow (`reflowKey`), so a hard cut when `controlsShown` flips would
                // read as broken beside the easing act zone and actions column. The `Group`
                // covers the divider too, so both fade as one unit.
                Group {
                    zoneDivider
                    // Reports the column's rendered width to `onControlsColumnWidthMeasured`
                    // (`probingWidth` attaches only when a test asks). `budget: columnsHeightBudget`
                    // is the same number the act zone caps itself to, so neither column decides the
                    // row's height (see `controlsZone(for:budget:)`).
                    probingWidth(controlsZone(for: lane, budget: columnsHeightBudget)
                                    .frame(width: OverviewLayout.bandSideColumnWidth, alignment: .topLeading)
                                    .frame(maxHeight: .infinity, alignment: .topLeading),
                                when: onControlsColumnWidthMeasured)
                }
                .transition(.opacity)
            }
        }
        // The ONE reflow animation for all three columns, scoped to this `HStack`:
        // not higher (`body`'s outer chain) and not lower (inside one column).
        // `QuickActionsColumn.reflowAnimation(reduceMotion:)` is the single authority for
        // the curve and the Reduce Motion gate.
        //
        // Unrelated content cannot inherit this ease: `.animation(_:value:)` arms only
        // when the keyed value changes. A question surface swapping or a transcript
        // growing moves none of `actWidth`, `actions?.columnWidth`, `actions?.rows` or
        // `controlsShown`, so the modifier does nothing to them, even though they render
        // inside this `HStack`.
        //
        // Exception: a DECISION ARRIVING. `decisionMinimumActWidth` feeds a
        // content-dependent width into `bandZonePlan`'s `minimumActWidth` post-filter.
        // Where that filter engages (a narrow act zone), a decision with longer
        // suggestion text can yield `actions: nil` and a re-derived `controlsShown`, so
        // the key moves on new decision text alone. That is left animated on purpose: it
        // is the actions column folding, which is a reflow. Question surfaces stay exempt
        // (`decisionMinimumActWidth` returns 0 for holds with questions).
        //
        // Nothing on this path re-invokes `bandZonePlan`, `ActionPillMeasurer`,
        // `DecisionRowMeasurer` or any `NSHostingView` measurement; `reflowKey` reads the
        // stored `zonePlan` and the animation interpolates already-resolved frames.
        .animation(QuickActionsColumn.reflowAnimation(reduceMotion: runtime.frame.reduceMotion), value: reflowKey)
    }

    private var zoneDivider: some View {
        Divider().padding(.horizontal, OverviewLayout.bandZoneGutter / 2)
    }

    // ---------------------------------------------------------- act zone

    /// The band's tuning of `DecisionBar`/`SubjectWell`: additive parameters,
    /// defaulted on those types to the full-recipe value. This file is the one
    /// production caller and always passes its own computed values.
    ///
    /// All were MEASURED together: `RenderSweepTests.bandFitsTheStripWorstCaseDecision`
    /// holds the canonical worst case (a suggestion beside Allow/Deny, on a subject
    /// long enough to need a well; the same shape as
    /// `decisionBarWithSuggestionAndExpandedPlanFitsTheStrip` on the strip's fuller
    /// 480 pt budget) to the band's tighter one: 419 pt with the connection banner
    /// down, 359 pt with it up (the binding constraint, since the strip is the
    /// primary hardware). The same shape against the narrower desktop window's 334 pt
    /// budget (banner up) does not fit; see that test for why this is a reported
    /// limit.
    ///
    /// The well's two figures are not fixed: `wellExpandedMaxHeight` and
    /// `wellCollapsedLines` come from `usableHeight` via
    /// `OverviewLayout.bandWellHeight(usableHeight:)` and `.bandWellCollapsedLines(usableHeight:)`,
    /// pure arithmetic rather than a `GeometryReader` negotiation, so a
    /// `fittingSize` render test can derive them. A fixed 16 pt expanded sliver and
    /// a 1-line collapsed well suit only the tightest budget (359 pt).
    ///
    /// `wellExpandedMaxHeight`/`showsWell`/`showsTitle` take a `stackedRowExtra` so
    /// they give ground when a narrow act zone's button row stacks taller than
    /// `bandFixedChrome` assumed. It is a MEASURED value: `DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`
    /// (`DecisionBar.swift`) answers whether the row stacks, computed once at
    /// `actZone(for:)`. Two alternatives failed: a predicted act-width threshold was
    /// wrong in both directions at reachable content ("git push *" vs "git push
    /// origin *" moved the real flip by 290 pt; see `OverviewLayout.bandWellMinimum`),
    /// and a `ViewThatFits(in: .vertical)` ladder in `DecisionBar.body` cost 1.5-1.8x
    /// layout, enough to starve a timing-sensitive test under full-suite contention.
    ///
    /// These functions take no `actionRows` parameter: no pinned action bar competes
    /// for the row's vertical chrome (see `bandFixedChrome`). The constants below are
    /// the bar's own chrome, not the well's content.
    static let decisionBarOuterPadding: Double = 8
    static let decisionBarContentSpacing: Double = 4

    /// The squeezed recipe's further trim (`squeezed ? squeezedDecisionBarOuterPadding
    /// : decisionBarOuterPadding` at the call site). At the defensive-depth sample
    /// (usable 149, `columnsHeightBudget` 101, below the reachable floor of usable 189
    /// banner up / budget 141), the worst-case squeezed decision (title folded, compact
    /// well, 44 pt buttons at `OverviewLayout.bandSqueezedButtonMinWidth`) measures
    /// 112 pt at 8/4 chrome, 11 pt past budget, which `.frame(maxHeight:).clipped()`
    /// would silently trim. At the real 141 pt floor it fits with 29 pt spare, so the
    /// trim is not load-bearing there. Kept anyway: 2/2 fits the defensive sample with
    /// 3 pt to spare (98 against 101) and reads no worse. Applied unconditionally
    /// whenever `squeezed`: one squeezed pair, not a second flex function (see
    /// `bandDecisionTitleThreshold`).
    /// `theSqueezedDecisionRowStaysHorizontalAtTheNarrowestActZone`
    /// (`RenderSweepTests.swift`) measures this pair alongside `bandSqueezedButtonMinWidth`.
    static let squeezedDecisionBarOuterPadding: Double = 2
    static let squeezedDecisionBarContentSpacing: Double = 2

    /// The `squeezed ? squeezedDecisionBarOuterPadding : decisionBarOuterPadding`
    /// selection, factored out so `actZone(for:)` and `RenderSweepTests`' content
    /// matrix read one derivation. The room `ViewThatFits`' horizontal arm measures
    /// the row against is `actWidth − 2 ×` this.
    static func decisionBarOuterPadding(squeezed: Bool) -> Double {
        squeezed ? squeezedDecisionBarOuterPadding : decisionBarOuterPadding
    }

    /// Twin of `decisionBarOuterPadding(squeezed:)` for the content-spacing pair.
    /// `DecisionBar`'s call site and `DialogAnswerPanel`'s
    /// (`actZoneFallback(for:budget:)`) both need it, so the ternary is not duplicated.
    static func decisionBarContentSpacing(squeezed: Bool) -> Double {
        squeezed ? squeezedDecisionBarContentSpacing : decisionBarContentSpacing
    }

    /// MEASURED: `DialogAnswerPanel`'s floor-case chrome, i.e. everything it draws
    /// except the button row (title line, both captions, outer padding, content
    /// spacing). `decisionMinimumActWidth` needs this figure as it does for
    /// `DecisionBar`, but `DecisionBar`'s `barChrome` is small only because
    /// `showsTitle`/`showsWell` have already folded by the time that guard fires.
    /// `DialogAnswerPanel`'s title ("Waiting on: …") and captions (`SessionActions.swift`)
    /// are fixed text drawn at every squeeze level. Reusing `DecisionBar`'s figure
    /// undercounted by about 45 pt and let two cells overrun by 3-6 pt
    /// (`RenderSweepTests.theDialogAnswerPanelObeysTheSameHeightBudgetAsItsSibling`).
    ///
    /// Measured as a bare panel's natural height minus its button row's height
    /// (`buttonCount × buttonHeight + (buttonCount − 1) × bandDecisionRowStackSpacing`
    /// when stacked) at two widths: 350 (`bandActFloorWidth`, row stacks) and 604
    /// (`.actOnly`, row does not). Both land on the same remainder at both squeeze
    /// levels, confirming it is width-independent (neither caption wraps): 69 pt
    /// unsqueezed (277 − 208, and 133 − 64), 51 pt squeezed (199 − 148, and 95 − 44).
    ///
    /// `RenderSweepTests.dialogAnswerPanelChromeMatchesItsOwnMeasuredConstant` is the
    /// live arbiter, so a drifted constant cannot pass with a green suite. It
    /// re-derives the quantity from the wide, unstacked half of the cross-check, so
    /// an arithmetic mistake in either derivation is caught.
    static let dialogAnswerPanelChrome: Double = 69
    static let squeezedDialogAnswerPanelChrome: Double = 51

    /// Twin of `decisionBarOuterPadding(squeezed:)` for the chrome pair above;
    /// `decisionMinimumActWidth` is the one reader.
    static func dialogAnswerPanelChrome(squeezed: Bool) -> Double {
        squeezed ? squeezedDialogAnswerPanelChrome : dialogAnswerPanelChrome
    }

    /// The flexed expanded-well ceiling:
    /// `OverviewLayout.bandWellHeight(usableHeight:stackedRowExtra:)` applied to this
    /// band's `usableHeight`. The strip's two real budgets give 187 pt at 419 and
    /// 127 pt at 359 (see that function), at `stackedRowExtra: 0` (the strip's act
    /// zone never stacks).
    ///
    /// `stackedRowExtra` is a parameter, not folded into `usableHeight`, because only
    /// `actZone(for:)`'s `DecisionBar` branch has a button count and a measured row
    /// width to derive it from; a `QuestionTakeover` or fallback notice has no
    /// decision row. That caller computes it once and shares it with
    /// `showsWell(stackedRowExtra:)`, so the height the well flexes to and the choice
    /// to build it cannot disagree.
    private func wellExpandedMaxHeight(stackedRowExtra: Double) -> Double {
        OverviewLayout.bandWellHeight(usableHeight: usableHeight, stackedRowExtra: stackedRowExtra)
    }

    /// The flexed collapsed-well line count:
    /// `OverviewLayout.bandWellCollapsedLines(usableHeight:)`. 4 once the expanded
    /// well has real slack, 1 otherwise (see that function for the 60 pt threshold);
    /// both of the strip's real budgets give 4.
    ///
    /// It does not read `stackedRowExtra`: `SubjectWell.body` (`DecisionBar.swift`)
    /// reads `expandedMaxHeight` only in its expanded branch. The collapsed branch is
    /// bounded purely by `collapsedLines`, so narrowing the expanded ceiling never
    /// touches what the collapsed well draws.
    private var wellCollapsedLines: Int {
        OverviewLayout.bandWellCollapsedLines(usableHeight: usableHeight)
    }

    /// Whether the well draws at all: `OverviewLayout.bandWellFits(usableHeight:stackedRowExtra:)`.
    /// Sibling of `wellExpandedMaxHeight(stackedRowExtra:)`; both read the one
    /// `stackedRowExtra` computed by `actZone(for:)`'s `DecisionBar` branch, so they
    /// cannot disagree about which reservation is binding.
    private func showsWell(stackedRowExtra: Double) -> Bool {
        OverviewLayout.bandWellFits(usableHeight: usableHeight, stackedRowExtra: stackedRowExtra)
    }

    /// The act zone: `ActionBlockNotice` first (the reason a control below it may be
    /// dark), then the live decision or the needs-you branch, then
    /// `AutoContinueToggle`. Idle and working sessions with no decision get a quiet
    /// placeholder line rather than an empty column. Ended and errored sessions get
    /// their own notices: an errored lane is news somebody may still be reading
    /// (`Frame` doctrine).
    ///
    /// Not `private`, like `header`: `RenderSweepTests`' budget-math tests measure it
    /// directly, unwrapped by `columns(for:)`'s width-splitting.
    @ViewBuilder
    func actZone(for lane: LaneView) -> some View {
        // 6, not the columns' 12 (`QueueSection`'s precedent, tightened from 8): the
        // act zone shares its budget with the header (see
        // `bandFitsTheStripWorstCaseDecision`).
        VStack(alignment: .leading, spacing: 6) {
            // Nothing here is capped below `columnsHeightBudget`. `DecisionBar`'s well is
            // tuned against `OverviewLayout.bandFixedChrome`, a flat constant, which lands
            // `DecisionBar`'s natural total height exactly at `columnsHeightBudget`.
            //
            // This is a real `VStack(alignment: .leading, spacing: 6)`, not a `Group`.
            // `Group` is layout-transparent, so the `.frame(maxHeight:).clipped()` below
            // would apply to each child independently. At a generous budget (a 900 pt window
            // bands to a ~739 pt `columnsHeightBudget`), `ActionBlockNotice` and
            // `DecisionBar` each got top-aligned and capped separately, spreading apart
            // (notice at the very top, decision bar floating mid-column) instead of stacking.
            // A real container applies the cap once. `spacing: 6` matches the outer
            // `VStack`, reproducing the spacing the transparent `Group` gave.
            VStack(alignment: .leading, spacing: 6) {
                if let block = runtime.frame.actionBlock {
                    ActionBlockNotice(block: block, compact: squeezed)
                }
                if let decision = runtime.frame.decisions.first(where: { $0.hold.session == lane.session }) {
                    // THIS session's decision, matched by hold, never `decisions.first` (same
                    // pairing discipline as the mirror branch below).
                    if decision.questions.isEmpty {
                        // `titles`/`buttonCount` repeat `DecisionBar.buttons`' `denyNumber` derivation
                        // (`decision.suggestionLabels.count + 2`: Yes, one per suggestion, No), so the
                        // well's reservation cannot drift from the row drawn beside it.
                        // `stackedRowExtra` is computed once and shared by every reader below.
                        //
                        // MEASURED, not predicted (`DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`
                        // in `DecisionBar.swift`). The comparison is against the content room
                        // `ViewThatFits`' horizontal arm uses: `actZoneWidth` minus the bar's outer
                        // padding on both sides (`DecisionBar.body` wraps `buttons` in
                        // `GlassEffectContainer` with no padding, but the bar's whole `VStack` carries
                        // `.padding(outerPadding)` above `ViewThatFits`).
                        let titles = DecisionBar.buttonTitles(for: decision)
                        let buttonCount = titles.suggestions.count + 2
                        let buttonMinWidth = OverviewLayout.bandDecisionButtonMinWidth(usableHeight: usableHeight)
                        let outerPaddingValue = Self.decisionBarOuterPadding(squeezed: squeezed)
                        let rowWidth = DecisionRowMeasurer.rowWidth(
                            titles: [titles.yes] + titles.suggestions + [titles.no], buttonMinWidth: buttonMinWidth)
                        let stacks = rowWidth > actZoneWidth - 2 * outerPaddingValue
                        // One height, chosen once, then both RESERVED for and DRAWN at (see
                        // `bandStackedDecisionButtonHeight`): a stacked row may step to the 44 pt floor,
                        // because at four options the comfort height pushes the subject well out of the
                        // band, and a numbered option with no question above it is unanswerable. The
                        // same value feeds `bandDecisionRowExtraHeight` and `DecisionBar.buttonHeight`.
                        let buttonHeight = OverviewLayout.bandStackedDecisionButtonHeight(
                            usableHeight: usableHeight, stacks: stacks, buttonCount: buttonCount)
                        let stackedRowExtra = OverviewLayout.bandDecisionRowExtraHeight(
                            stacks: stacks, buttonCount: buttonCount, buttonHeight: buttonHeight)
                        DecisionBar(decision: decision, runtime: runtime,
                                   initiallyExpanded: wellInitiallyExpanded,
                                   wellExpandedMaxHeight: wellExpandedMaxHeight(stackedRowExtra: stackedRowExtra),
                                   wellCollapsedLines: wellCollapsedLines,
                                   showsWell: showsWell(stackedRowExtra: stackedRowExtra),
                                   outerPadding: outerPaddingValue,
                                   contentSpacing: Self.decisionBarContentSpacing(squeezed: squeezed),
                                   buttonHeight: buttonHeight,
                                   buttonMinWidth: buttonMinWidth,
                                   showsTitle: OverviewLayout.bandShowsDecisionTitle(usableHeight: usableHeight,
                                                                                     stackedRowExtra: stackedRowExtra),
                                   compactWell: squeezed,
                                   onButtonsFrameMeasured: onDecisionButtonsFrameMeasured,
                                   onWellFrameMeasured: onDecisionWellFrameMeasured)
                    } else if !decision.showsStage(dismissedStage: dismissedStage) {
                        QuestionTakeover(decision: decision, runtime: runtime,
                                         otherFieldInitiallyExpanded: otherFieldInitiallyExpanded,
                                         onOtherFieldFrameMeasured: onOtherFieldFrameMeasured,
                                         onControlsFrameMeasured: onControlsFrameMeasured)
                    }
                    // Else `QuestionStage` owns this hold, so the band draws nothing for it
                    // rather than risk a second answer surface under the takeover. Both surfaces
                    // read the identical `showsStage` rule (see `DeckWindow.bandShown`).
                } else if let mirror = runtime.frame.mirrors.first(where: { $0.hold.session == lane.session }) {
                    // No `Decision` exists for this hold (`Projection.frame`'s `decisions` filter
                    // excludes every stage a mirror covers), so this is the only place
                    // `released`/`terminalLive`/`resolved` reach the band. Matched by the hold's own
                    // session, never the frame's first mirror.
                    QuestionMirrorCard(mirror: mirror, runtime: runtime,
                                      otherFieldInitiallyExpanded: otherFieldInitiallyExpanded,
                                      onOtherFieldFrameMeasured: onOtherFieldFrameMeasured)
                } else {
                    actZoneFallback(for: lane, budget: columnsHeightBudget)
                }
            }
            .frame(maxHeight: columnsHeightBudget, alignment: .top)
            .clipped()
            // The folded-controls menu lives in the header, not here: this footer sits
            // BELOW the decision and clips exactly when the fold is needed (a tall decision
            // at a squeezed, height-folded budget leaves no room for a footer row).
            Spacer(minLength: 0)
        }
    }

    /// What the act zone shows when there is no live decision to answer.
    /// `.needsYou` shows the evidenced panel or a notice; the well does not reach
    /// into this branch, `budget` is unread there. `.idle`/`.working` show
    /// `TranscriptWell`, whose empty-state fallback is the quiet placeholder.
    /// `.ended`/`.errored` keep their designed notice (an errored lane is news
    /// somebody may still be reading) with the well BENEATH it whenever `budget`
    /// leaves room (`transcriptWellBeneathNotice(budget:)`).
    @ViewBuilder
    private func actZoneFallback(for lane: LaneView, budget: Double) -> some View {
        switch lane.state {
        case .needsYou:
            if let waitingFor = lane.waitingFor, DialogAnswerPanel.answers(waitingFor) {
                // The same four reads `actZone(for:)`'s `DecisionBar` branch makes, off the same
                // `usableHeight`/`squeezed` (see `DialogAnswerPanel` in `SessionActions.swift`
                // for the bug this closes).
                DialogAnswerPanel(waitingFor: waitingFor, runtime: runtime,
                                  outerPadding: Self.decisionBarOuterPadding(squeezed: squeezed),
                                  contentSpacing: Self.decisionBarContentSpacing(squeezed: squeezed),
                                  buttonHeight: OverviewLayout.bandDecisionButtonHeight(usableHeight: usableHeight),
                                  buttonMinWidth: OverviewLayout.bandDecisionButtonMinWidth(usableHeight: usableHeight))
            } else {
                HandedBackNotice(sawAHold: lane.sawAHold, waitingFor: lane.waitingFor, compact: squeezed)
            }
        case .ended:
            VStack(alignment: .leading, spacing: 6) {
                Self.endedNotice(compact: squeezed)
                transcriptWellBeneathNotice(for: lane, budget: budget, compact: squeezed)
            }
        case .errored:
            VStack(alignment: .leading, spacing: 6) {
                // `lane.apiError` is the session's transcript recording an API-error message
                // as its last word (`LaneRecord.apiError`); when present, the deck says what
                // it was instead of pointing at the terminal.
                if let apiError = lane.apiError {
                    Self.apiErroredNotice(detail: apiError.value, compact: squeezed)
                } else {
                    Self.erroredNotice(compact: squeezed)
                }
                transcriptWellBeneathNotice(for: lane, budget: budget, compact: squeezed)
            }
        case .idle, .working:
            // The well replaces the old placeholder sentence: `TranscriptWell`'s
            // empty-state fallback carries the same words for a lane with nothing said and
            // nothing queued.
            TranscriptWell(lane: lane, runtime: runtime, maxHeight: budget)
        }
    }

    /// The `.ended` notice, hoisted so `RenderSweepTests.bandStateNoticeHeightMatchesItsNamedConstant`
    /// builds the exact thing production renders: a hand-re-typed copy could drift
    /// while the arbiter stayed green and the real render outgrew the reservation
    /// `transcriptWellBeneathNotice(for:budget:)` budgets against. Not `private`, like
    /// `BandStateNotice`. `compact:` (default `false`) is the same flag
    /// `BandStateNotice` reads, threaded here so the bytes and that bit are assembled
    /// in one place.
    static func endedNotice(compact: Bool = false) -> BandStateNotice {
        BandStateNotice(title: "Session ended", symbol: "checkmark.circle", tint: .secondary,
                        detail: "This session finished. Its controls are still here if you want "
                            + "to remove it from the deck.", compact: compact)
    }

    /// The `.errored` notice (see `endedNotice`). The generic pointer, for the
    /// producer of `.errored` that comes with no message of its own: a fleet-reported
    /// background failure (`LaneState.errored` names both producers).
    /// `apiErroredNotice(detail:compact:)` serves the session's own transcript.
    static func erroredNotice(compact: Bool = false) -> BandStateNotice {
        BandStateNotice(title: "This session errored", symbol: "xmark.octagon.fill", tint: .red,
                        detail: "The deck has no decision to offer for it — check the session's "
                            + "own terminal for what happened.", compact: compact)
    }

    /// The same state as `erroredNotice`, carrying the message Claude Code itself
    /// produced. Same title, symbol and tint; only the DETAIL differs, relayed
    /// verbatim (dialog parity: same wording as Claude Code's own surfaces). `detail`
    /// is `LaneView.apiError`'s value; `actZoneFallback(for:budget:)` falls back to
    /// `erroredNotice` when there is none. `detailLineLimit: 3` bounds the measured
    /// reservation `OverviewLayout.bandApiErrorNoticeHeight`.
    static func apiErroredNotice(detail: String, compact: Bool = false) -> BandStateNotice {
        BandStateNotice(title: "This session errored", symbol: "xmark.octagon.fill", tint: .red,
                        detail: detail, compact: compact, detailLineLimit: 3)
    }

    /// Room-permitting well placement for `.ended`/`.errored`. `BandStateNotice` is
    /// a fixed, MEASURED shape (`OverviewLayout.bandStateNoticeHeight`); what is left
    /// of `budget` after it and this VStack's 6 pt spacing goes to the well. Below
    /// `Self.transcriptWellMinimumRoom` (not even a stall sentence and one legible
    /// row) the well does not render rather than show an unreadable sliver, the same
    /// judgment as `bandWellMinimum`'s 16 pt floor for `DecisionBar`'s well.
    ///
    /// Not `private`: `RenderSweepTests`' 60/59 boundary test calls it directly.
    ///
    /// `compact:` (default `false`) selects `OverviewLayout.bandStateNoticeCompactHeight`
    /// instead of `bandStateNoticeHeight`. Using the wrong constant for the notice on
    /// screen would either waste room (full constant against a shorter compact notice)
    /// or over-grant the well and clip the notice (compact constant against a taller
    /// full one), so `actZoneFallback(for:budget:)` passes the same `compact` it built
    /// the notice with.
    ///
    /// When `lane.apiError` is non-nil, `OverviewLayout.bandApiErrorNoticeHeight` is
    /// read: `apiError` is non-nil only while `rec.state == .errored`
    /// (`LaneView.apiError`), the condition `apiErroredNotice(detail:compact:)` is
    /// chosen under, so no separate flag can disagree with the notice drawn. Compact
    /// uses one shared constant for both titled variants
    /// (`bandStateNoticeCompactHeight`).
    @ViewBuilder
    func transcriptWellBeneathNotice(for lane: LaneView, budget: Double, compact: Bool = false) -> some View {
        let noticeHeight = compact ? OverviewLayout.bandStateNoticeCompactHeight
            : (lane.apiError != nil ? OverviewLayout.bandApiErrorNoticeHeight : OverviewLayout.bandStateNoticeHeight)
        let remaining = budget - noticeHeight - 6
        if remaining >= Self.transcriptWellMinimumRoom {
            TranscriptWell(lane: lane, runtime: runtime, maxHeight: remaining)
        }
    }

    /// The floor under which `transcriptWellBeneathNotice(for:budget:)` hides the
    /// well: a judgment, not a measurement. Enough for one `.caption` stall sentence
    /// plus one `.callout.monospaced()` row with something left to scroll, the order
    /// of magnitude of `bandWellCollapsedLines`' 60 pt threshold. Not `private`: the
    /// boundary test reads it instead of restating 60.
    static let transcriptWellMinimumRoom: Double = 60

    private func compactControlsMenu(for lane: LaneView) -> some View {
        // A button that opens `SessionActionsPanel`, not a `Menu`. An `NSMenu` has
        // ~22 pt rows and shows "Continue automatically" as a 10 pt tick in a leading
        // gutter; both are pointer decisions, and this deck's primary surface is a
        // touchscreen (like `SessionControls`' note on `.contextMenu` being a secondary
        // click). See `SessionActionsPanel.swift`, including why the scrim is attached
        // in `DeckWindow`. `onOpenSessionActions` is optional, so a bare `DetailBand` in
        // a render-sweep test gets a button that does nothing.
        Button { onOpenSessionActions?(lane.session) } label: {
            Image(systemName: "ellipsis.circle")
        }
        .touchTarget(minHeight: TouchTarget.minimum, minWidth: TouchTarget.minimum)
        .accessibilityLabel("Session controls")
        // The tooltip names everything the panel holds: auto-continue (once Controls
        // itself can fold away, `autoContinuable`) and Card Color, not only Hide/Remove.
        .help("Session controls: hide, remove, auto-continue, card color")
    }

    // ----------------------------------------------------- controls zone

    /// `SessionControls`, capped to the column, then `AutoContinueToggle` (a
    /// standing preference about the session belongs beside its other standing
    /// controls, not competing with whatever decision is showing), then the one
    /// footnote the dedup table spares: the full directory path, which the card does
    /// not show. The session id is not repeated: the card's short id is already a
    /// legible prefix.
    ///
    /// Budget-capped, with the footnote as its declared overflow. The column's natural
    /// content (three buttons, a divider, the toggle, one directory line) is a FIXED
    /// height (`OverviewLayout.bandControlsNaturalHeight`, pinned by
    /// `RenderSweepTests.controlsZoneNaturalHeightMatchesItsOwnMeasuredConstant`) that
    /// CAN exceed the columns row's shared budget. Uncapped, this column rather than
    /// the budget would decide `columns(for:)`'s height (non-affine chrome: two
    /// comparable samples measuring different columns as the "tall" one). So every
    /// column derives its height from the same budget: `budget` caps this VStack
    /// (`.frame(maxHeight: budget).clipped()`) and the Directory footnote, the one
    /// informational (non-control) row, folds first whenever the full natural height
    /// does not fit; `OverviewLayout.bandControlsFoldedMinimum` names what survives.
    ///
    /// The natural height (279 pt, row spacing 8) clears the strip's banner-down
    /// budget of 291 with 12 pt to spare, so the footnote shows there; the fold
    /// engages only at a genuine sub-419 squeeze (400 pt usable; see
    /// `controlsZoneFitsBothRealBudgetsFoldingWhenItMust`). It is a declared, tested
    /// overflow rather than a silent clip. See the body comment for why this is a fold
    /// and not a `ScrollView`.
    ///
    /// Not `private`, like `header`/`actZone(for:)`: `RenderSweepTests`' budget-math
    /// tests measure it directly, unwrapped by `columns(for:)`.
    @ViewBuilder
    func controlsZone(for lane: LaneView, budget: Double) -> some View {
        // Declared overflow, NOT a `ScrollView`. A `ScrollView` here (as in
        // `TranscriptWell`) broke `measuredMinimum(_:)`'s Auto-Layout-constraint
        // technique: `DetailBand`'s reported window-resize floor stopped tracking
        // `usableHeight`, reporting the same minimum for two instances with different
        // `usableHeight` (the sticky-window signature `detailBandNeverDemandsHeight`
        // guards). `NSScrollView`'s compression-resistance differs from a plain
        // `VStack`'s under that technique; a bare `.frame(maxHeight:).clipped()` does not
        // have the same effect (confirmed by swapping one for the other, all else
        // constant). `TranscriptWell`'s own `ScrollView` gets away with it because
        // `actZone(for:)` wraps its fallback `Group` in
        // `.frame(maxHeight: columnsHeightBudget).clipped()` first, so an ancestor
        // already reports a fixed height. This column had no such ancestor: its
        // `ScrollView` WAS the outermost frame, so its hugging reached `DetailBand`'s
        // root query. Instead the overflow folds: the Directory footnote first (the one
        // informational row; Hide/Remove/Card Color/the toggle always stay, since the
        // darkened-control rule never hides a CONTROL silently).
        // `OverviewLayout.bandControlsNaturalHeight` is the measured full-content height;
        // below it the footnote folds rather than the column silently clipping.
        let showsFootnote = budget >= OverviewLayout.bandControlsNaturalHeight
        VStack(alignment: .leading, spacing: 8) {
            // `showsColorPicker: true`: the band's no-scroll strip is where the picker's
            // `.popover` can anchor cleanly (see `SessionControls.showsColorPicker`).
            SessionControls(lane: lane, runtime: runtime, emphasizeRemove: lane.state == .ended,
                            showsColorPicker: true)
            if runtime.frame.autoContinuable {
                Divider()
                probingRootFrame(AutoContinueToggle(runtime: runtime), when: onAutoContinueFrameMeasured)
            }
            if showsFootnote {
                identityFootnote(for: lane)
            }
            // Load-bearing, not decorative: a plain trailing `Spacer(minLength: 0)`.
            // Removing it left `measuredMinimum(_:)` reporting a `DetailBand` minimum stuck
            // at the first sample's `usableHeight`, identical for a second sample with a
            // different one (the sticky-window signature). The mechanism is not fully traced
            // beyond "restores the compression/hugging signal a bare `VStack` gets from a
            // trailing `Spacer`"; the arbiter passing proves it.
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: budget, alignment: .topLeading)
        .clipped()
    }

    /// The one fact not already on the card: the full directory path (branch, last
    /// tool and the short id are on the card). The full session UUID is not shown
    /// anywhere on the deck.
    @ViewBuilder
    private func identityFootnote(for lane: LaneView) -> some View {
        if let directory = lane.directory?.value {
            footnoteField("Directory", directory)
        }
    }

    private func footnoteField(_ name: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.caption.monospaced())
                .lineLimit(2)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .copyable(value)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(value)")
    }
}

// -------------------------------------------------------- designed states

/// One notice shape, shared by the act zone's ended and errored fallbacks: the
/// same `Label` + title/detail + `.quaternary` card as `ActionBlockNotice` and
/// `HandedBackNotice`.
///
/// Not `private`: `OverviewLayout.bandStateNoticeHeight`'s arbiter measures this
/// directly, since a reservation the overflow-honesty rule depends on needs a
/// real render to hold it accountable.
struct BandStateNotice: View {
    let title: String
    let symbol: String
    let tint: Color
    let detail: String
    /// The squeezed recipe's compact shape (default `false`).
    /// `DetailBand.endedNotice(compact:)`/`.erroredNotice(compact:)` thread
    /// `OverviewLayout.bandSqueezed(usableHeight:)` through. Drops the detail line and
    /// tightens the padding (16 to 6), like `ActionBlockNotice.compact`; the
    /// `accessibilityLabel` below keeps the detail.
    var compact: Bool = false
    /// Bounded-detail mode for the api-error notice (`nil` by default).
    /// `erroredNotice`/`endedNotice` carry hand-written sentences sized to
    /// `OverviewLayout.bandStateNoticeHeight`; Claude Code's own error text is not, so
    /// `DetailBand.apiErroredNotice(detail:compact:)` caps it at 3 lines
    /// (`.lineLimit` with `.fixedSize(horizontal: false, vertical: true)`), keeping
    /// `OverviewLayout.bandApiErrorNoticeHeight` finite. The full text always survives
    /// in `accessibilityLabel`: this caps what is drawn, never what is spoken.
    var detailLineLimit: Int? = nil

    var body: some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                if !compact {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(detailLineLimit)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .padding(compact ? 6 : 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title). \(detail)")
    }
}

// ---------------------------------------------------------------- dedup

// What this band must NEVER render, because the selected card beside it
// already does:
//
//   - The state chip, the permission chip, the context gauge: all on the card.
//   - Branch, last tool and the session id: on the card too (the id as a
//     legible prefix). Only the full directory path is shown, as
//     `identityFootnote`'s one field.
//   - The current prompt and everything queued or sent before it, WITH ONE
//     DELIBERATE EXCEPTION. `lane.prompt` is the card's "LAST USER PROMPT"
//     block; `TranscriptWell` shows the same merged ledger and does NOT drop
//     the newest entry to avoid repeating the card. The same fact serves two
//     jobs: the card's line is an IDENTITY fact ("what is this session about,
//     right now", at a glance from across the strip); the well's newest row is
//     a HISTORY fact ("what happened, in order, with its status"). A
//     transcript stopping one entry short of "now" would misstate the timeline
//     it exists to show, which `.defaultScrollAnchor(.bottom)` keeps in view.
//   - A name or a title anywhere in this file. The header carries a collapse
//     button and nothing else.
