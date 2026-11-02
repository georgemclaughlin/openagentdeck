//
//  OverviewLayout.swift · DeckCore
//
//  Which way the fleet enumerates, given the glass it was handed.
//
//  One rule underlies all three cases: SPEND THE ABUNDANT AXIS ON THE LIST AND
//  GIVE THE SCARCE ONE TO EACH CARD. A deck is normally wide and short (1920 x
//  480 on the strip it was designed for), so width is spare and height is what
//  each session needs for its gauge, badge and prompt. Listing sessions
//  downward there would spend the scarce axis enumerating.
//
//  On an iPad over Sidecar (roughly 1366 x 1024) there is enough of both to
//  show everything at once, which is a grid. In a narrow window neither holds,
//  which is a column.
//
//  The decision lives here rather than in the view because it is a rule, and a
//  rule is worth a test. The view's only job is to measure and obey.
//

import Foundation

/// How the overview arranges sessions for the space it has.
public enum OverviewLayout: String, Equatable, Sendable, CaseIterable {
    /// Cards abreast, scrolling sideways. The strip's shape: wide enough for
    /// several sessions side by side and too short to stack them.
    case row
    /// A grid, filling the width with as many columns as fit and the height
    /// with as many rows as there are sessions. Wants both axes, and only a
    /// tall surface has them.
    case grid
    /// One session per row, scrolling down. For a window too narrow to put two
    /// cards side by side, where a row would be one card with a scrollbar
    /// under it and a grid would be a column wearing the wrong name.
    case column

    /// The height at which stacking cards beats lining them up.
    ///
    /// Below this there is room for about one row of cards once the pinned
    /// bars and the window chrome have taken their share, so a grid would be a
    /// row with worse alignment. Above it there is room for three, which is
    /// the point at which seeing everything at once beats seeing it in order.
    ///
    /// 760 rather than a round 800: a 1024-point Sidecar iPad and a maximised
    /// window on a laptop display both clear it, and the deck's own default
    /// 620-point window does not.
    public static let gridMinimumHeight: Double = 760

    /// Below this width nothing fits beside anything, so both the grid and the
    /// row degrade to single file and the column is the honest name for it.
    public static let multiCardMinimumWidth: Double = 620

    /// The narrowest a session card may be before the grid stops adding
    /// columns. Wide enough for a directory tail and a branch without
    /// truncating either into uselessness.
    public static let cardMinimumWidth: Double = 260

    /// What a card takes in `row`, where nothing stretches it to fit.
    ///
    /// Wider than the minimum because a row has width to spend and the prompt
    /// block is what it should be spent on: three lines at 260 pt is about a
    /// dozen words, and at 300 it is closer to twenty.
    ///
    /// `cardIdealWidth` is read only by `.row`; `.grid` stretches each cell to
    /// fill and `.column` stretches to the full row width. A `.row` selection
    /// narrows the fleet to `bandFleetWidth` instead and hands the rest of the
    /// strip to the detail band (see that constant's doc for the arithmetic).
    /// With nothing selected, `.row` spends the whole strip on cards at this
    /// width: 1920 pt holds six (24 pt outer padding + 6 x 300 + 5 x 12 =
    /// 1884; a seventh would need 312 more). `bandLeavesTheFleetOneCard`
    /// (`RenderSweepTests.swift`) holds the band-selected arithmetic.
    public static let cardIdealWidth: Double = 300

    /// What to draw for a given content size.
    ///
    /// Width is checked first because it is the axis that can rule out every
    /// multi-card layout at once; only then does height decide between
    /// stacking cards and lining them up.
    public static func forSize(width: Double, height: Double) -> OverviewLayout {
        guard width >= multiCardMinimumWidth else { return .column }
        return height >= gridMinimumHeight ? .grid : .row
    }

    /// Whether this layout puts more than one card abreast.
    ///
    /// This is the predicate the MONOTONICITY rule is stated in terms of —
    /// widening a window may never take cards away — and that is all it is
    /// for. It is deliberately not what the view uses to size a card: the
    /// sizing split is `row` against everything else, because only `row` pins
    /// a card to a fixed width, and a view that reached for this instead would
    /// wrongly stop the grid from stretching.
    public var isMultiCard: Bool { self != .column }

    // -------------------------------------------------------- the fleet rows
    //
    // `.row`'s internal shape: how many rows of cards it stacks given the
    // height it actually has. `banded` collapses to the header pose (the
    // selected card alone, full height); otherwise two half-height rows are
    // used only if both clear a card's worst-realistic content.

    /// The padding `SessionOverview` puts around its whole fleet `Group`:
    /// 12 pt, every side. Named here so `fleetRows(usableHeight:banded:)`
    /// subtracts the same number production pads with.
    public static let fleetOuterPadding: Double = 12

    /// The gap between the two rows a `.row` fleet stacks vertically, and also
    /// the gap between cards horizontally (`LazyHGrid`'s `spacing:` governs
    /// both axes together).
    public static let fleetRowSpacing: Double = 12

    /// **MEASURED:** a worst-realistic card's height at `cardIdealWidth` with
    /// NO prompt block: a tags row (branch and permission badge both present),
    /// the footer, and the gauge. This is everything a card draws except the
    /// one field it can shed. `fleetRows(usableHeight:banded:)` checks each
    /// row's share of `usableHeight` against it.
    ///
    /// The prompt block is the one field a card sheds, rather than falling
    /// back to one row: the band answers "what is it doing" once a card is
    /// selected, and the walk-over facts (state, name, branch, badge, tool,
    /// context, id) never leave the card. `fleetPromptBlockCost` is the
    /// reading that separates this card from the 1-line card (154).
    ///
    /// The boundary this floor draws: usableHeight = 2 x 113 + 2 x
    /// `fleetOuterPadding` + `fleetRowSpacing` = 226 + 24 + 12 = 262 pt usable
    /// (a 323 pt window). A 324 pt window shares 113.5 pt per row, half a point
    /// of slack, which `aFullCardFitsTheTwoRowBudget` (`RenderSweepTests.swift`)
    /// exists to keep from silently inverting if the card grows another field.
    public static let fleetRowMinimumHeight: Double = 113

    /// **MEASURED:** the whole prompt BLOCK's cost: the 1-line card (154) minus
    /// the promptless card (113, `fleetRowMinimumHeight`) at the same
    /// `cardIdealWidth`. Itemized: 13 pt for the "LAST USER PROMPT" caption
    /// line, 3 pt gap below it (`SessionCard.promptBlock`'s `VStack(spacing:
    /// 3)`), 15 pt for one line of prompt text (`fleetPromptLinePitch`), and
    /// 10 pt for the interior stack's gap that only appears once the block is
    /// present (`SessionCard.body`'s `VStack(spacing: 10)`): 13 + 3 + 15 + 10 =
    /// 41. `promptLineLimit(usableHeight:rows:)` adds it to
    /// `fleetRowMinimumHeight` to recover the 1-line card's cost rather than
    /// restating 154. `aFullCardFitsTheTwoRowBudget` (`RenderSweepTests.swift`)
    /// is the live arbiter.
    public static let fleetPromptBlockCost: Double = 41

    /// **MEASURED:** the card's growth per additional prompt line at
    /// `cardIdealWidth`: 154 pt at 1 line, 169 at 2, 184 at 3, an exact 15 pt
    /// per line. `fleetRowMinimumHeight` plus `fleetPromptBlockCost` pins the
    /// 1-line end; this is the slope off it, read by `promptLineLimit` to
    /// decide how many lines a row's share can afford.
    /// `aFullCardFitsTheTwoRowBudget` pins both ends and the slope together.
    public static let fleetPromptLinePitch: Double = 15

    /// The per-row share of `usableHeight` a two-row `.row` fleet gets:
    /// `usableHeight`, minus `fleetOuterPadding` twice (top and bottom) and one
    /// `fleetRowSpacing` between the rows, split in two.
    ///
    /// `fleetRows` (1 row vs 2) and `promptLineLimit(usableHeight:rows:)`
    /// (how many lines) both read this one fact; both must call it rather than
    /// carry their own copy of the arithmetic.
    public static func fleetRowShare(usableHeight: Double) -> Double {
        (usableHeight - 2 * fleetOuterPadding - fleetRowSpacing) / 2
    }

    /// How many rows a `.row` fleet stacks into, given the usable height it
    /// was handed.
    ///
    /// `banded` always answers 1: the selected card's header pose
    /// (`SessionOverview.lanes` has already narrowed the fleet to that one
    /// card) is that card alone at full height; there is nothing to stack.
    ///
    /// Otherwise: 2 once `fleetRowShare(usableHeight:)` clears
    /// `fleetRowMinimumHeight`; 1 below that. The floor is the promptless card
    /// (113), so the strip's two budgets clear it easily: 419 pt (banner down)
    /// shares 191.5 pt per row, 359 pt (banner up) shares 161.5. A 324 pt window
    /// (263 pt usable) shares 113.5 per row: still two rows, with the prompt
    /// block dropped rather than a whole row lost. The exact boundary:
    /// usableHeight = 2 x `fleetRowMinimumHeight` + 2 x `fleetOuterPadding` +
    /// `fleetRowSpacing` = 226 + 24 + 12 = 262 (a 323 pt window, adding back
    /// the 40 pt titlebar + 21 pt status line).
    public static func fleetRows(usableHeight: Double, banded: Bool) -> Int {
        guard !banded else { return 1 }
        return fleetRowShare(usableHeight: usableHeight) >= fleetRowMinimumHeight ? 2 : 1
    }

    /// How many lines the prompt block shows, for a fleet stacked into
    /// `rows` rows at `usableHeight`: 0 through 3 (0 meaning the card draws no
    /// prompt block at all), or up to 8 for a single row.
    ///
    /// Below two rows there is nothing to flex against, so `rows < 2` answers 8
    /// unconditionally. Each line past the first costs `fleetPromptLinePitch`
    /// off the 1-line card's baseline (`fleetRowMinimumHeight +
    /// fleetPromptBlockCost` = 154), so 8 lines lands exactly at 154 + 7 x 15 =
    /// 259 pt, under the tightest single-row card container (the banner-up
    /// strip: 359 - 2 x `fleetOuterPadding` = 335 pt).
    /// `anEightLinePromptCardFitsTheTightestSingleRowCard`
    /// (`RenderSweepTests.swift`) is the live arbiter.
    ///
    /// At two rows, the line count flexes with `fleetRowShare(usableHeight:)`,
    /// the same share `fleetRows` checks against the promptless floor. Below
    /// the 1-line card's cost (`oneLine` = `fleetRowMinimumHeight +
    /// fleetPromptBlockCost` = 154) the share cannot afford the prompt block
    /// at all: 0, the promptless tier. At or above `oneLine`, 1 line costs
    /// `oneLine`, 2 cost `oneLine + fleetPromptLinePitch` (169), 3 cost
    /// `oneLine + 2 x fleetPromptLinePitch` (184), so `(share - oneLine) /
    /// fleetPromptLinePitch`, floored, is how many pitches past the first line
    /// the share has room for. `min(3, ...)` is the tight cap `.grid` and
    /// `.column` use. A negative or vanishingly small `usableHeight` falls into
    /// the 0 branch harmlessly.
    ///
    /// Worked examples: usable 262 (the `fleetRows` boundary) shares 113: 0
    /// lines. 344 shares 154: 1 line. 374 shares 169: 2. 404 shares 184: 3. The
    /// strip banner-down, 419, shares 191.5: 3 (capped). The strip banner-up,
    /// 359, shares 161.5: 1 line, not 0, so the banner costs prompt lines, not
    /// the whole block. The everyday 432 pt desktop window (371 pt usable,
    /// measured by `fleetRowsStacksAtTheBoundary`) shares 167.5: 1 line.
    ///
    /// **`banded: true` is a third tier.** A banded `.row` fleet is always
    /// exactly one card (`SessionOverview.lanes(from:banded:selection:)`) that
    /// renders through the same `LazyHGrid`. The flat 8 of the unbanded single
    /// row would demand a natural height that the horizontal `ScrollView`
    /// reports upward as its own minimum, and a fixed floor anywhere inside a
    /// `.windowResizability(.contentSize)` tree drags the whole window's floor
    /// up (the same propagation `DetailBand`'s doc describes for its interior).
    /// So the banded row flexes with its share like a two-row fleet's rows do.
    ///
    /// **The arithmetic is the same `(share - oneLine) / fleetPromptLinePitch`;
    /// only what `share` means changes.** A banded row's share is the whole of
    /// `usableHeight` minus `fleetOuterPadding` top and bottom (no
    /// `fleetRowSpacing`, since there is no neighbour): `usableHeight - 2 x
    /// fleetOuterPadding`. The same 0-tier promptless floor applies below
    /// `oneLine`. The cap differs: `min(8, ...)`, because a banded row is still
    /// one row with the whole fleet region to itself.
    ///
    /// Worked examples. The reachable floor is usable 189, banner up:
    /// `DeckPrefs.minWindow` height (270) is already a content height (no
    /// titlebar to subtract), minus 60 for the connection banner
    /// (`RenderSweepTests.measuredBannerHeight`, measured, and unchanged at the
    /// minimum window's 960 pt width) and 21 for the status line; banner-down
    /// usable is 249. At the floor, share = 189 - 24 = 165, at or past
    /// `oneLine`: 1 line. The 0-tier boundary (178 usable) sits just under
    /// what production can reach, so it is defensive depth. Usable 149, below
    /// the floor and kept because the pure function must still answer
    /// honestly, shares 125: 0 lines (the card's total height is 113 + 24 = 137,
    /// under the 149 pt offered). 209 shares 185: `(185-154)/15 = 2.06`, so 1 +
    /// 2 = 3 lines. 262 shares 238: `(238-154)/15 = 5.6`, so 6 lines. 344 shares
    /// 320: `(320-154)/15 = 11.06`, so 12, capped at 8; the strip's two real
    /// budgets (419, 359) and everything above 344 all cap at 8, the same
    /// ceiling the unbanded single row draws. `promptLineLimitFlexesBandedWithShare`
    /// (`OverviewLayoutTests`) pins this table.
    public static func promptLineLimit(usableHeight: Double, rows: Int, banded: Bool = false) -> Int {
        let oneLine = fleetRowMinimumHeight + fleetPromptBlockCost   // 154 — the 1-line card, derived not restated
        if banded {
            let share = usableHeight - 2 * fleetOuterPadding
            guard share >= oneLine else { return 0 }
            return min(8, 1 + Int((share - oneLine) / fleetPromptLinePitch))
        }
        guard rows >= 2 else { return 8 }
        let share = fleetRowShare(usableHeight: usableHeight)
        guard share >= oneLine else { return 0 }
        return min(3, 1 + Int((share - oneLine) / fleetPromptLinePitch))
    }

    // ------------------------------------------------------- the detail band
    //
    // What a selection does to the strip. Every layout gets the same detail
    // band at whatever size it is given; `.inspector` is never used. The strip
    // wants a band because it is short and wide, exactly what a 380-760 pt
    // column beside the content cannot use well (see the file doc, "SPEND THE
    // ABUNDANT AXIS"). So a `.row` selection narrows the fleet to the selected
    // card alone and hands the rest to the band.

    /// **The fleet's viewport width once a `.row` selection has narrowed it
    /// for the band: exactly one card, no sliver.**
    ///
    /// `SessionOverview` filters the fleet to the selected lane alone while
    /// banded (`SessionOverview.lanes(from:banded:selection:)`). Don't
    /// enumerate the other cards under the band or show a sliver of the next
    /// one: the band covers the rest of the strip the instant a selection
    /// lands, so a card behind it can never be scrolled into view. The "there
    /// is another one here" cue is carried by `Ticks` (`SessionOverview.swift`)
    /// at the seam instead.
    ///
    /// 12 (outer padding, one side) + 300 (`cardIdealWidth`) + 12 (trailing
    /// padding; no inter-card spacing since there is no second card) = 324.
    public static let bandFleetWidth: Double = 324

    /// The seam `Ticks` occupies between the fleet and the band: a real
    /// `HStack` sibling, not an overlay, so it costs this many points of the
    /// content region. It lives here, not on `Ticks` (`DeckApp`), because
    /// `bandZones(for:)`'s pure tests (`OverviewLayoutTests`) need production's
    /// exact subtraction (`bandWidth = totalWidth - bandFleetWidth -
    /// bandSeamWidth`) and `DeckCoreTests` cannot import `DeckApp`.
    public static let bandSeamWidth: Double = 8

    /// What a selection does to the strip.
    ///
    /// **Answers `.band` whenever `hasSelection`, for every layout at every
    /// size.** The band is never a fallback surface behind a sidebar: opening a
    /// session commits to it, and a surface too small for the full recipe
    /// shrinks the recipe (`bandSqueezed(usableHeight:)` and its readers in
    /// `DetailBand.swift`) rather than switching to a different surface.
    /// `.fleetOnly` when nothing is selected. `layout`, `usableWidth` and
    /// `usableHeight` are parameters kept for call-site symmetry; only
    /// `hasSelection` decides. `.grid` and `.column` selections get the same
    /// band a strip does, at whatever height they are given
    /// (`bandWellHeight(usableHeight:)` simply flexes large there).
    ///
    /// Don't route a selection to a different surface (such as a sidebar
    /// inspector) when the window is small. Switching composition on a
    /// min-size change was implicated in the display-cycle crash that
    /// `CrashRecovery` (`DeckApp`) documents; `forSize`'s row/grid flip is the
    /// one remaining such flip. `bandMinimumHeight` and `bandMinimumWidth` are
    /// no longer routing floors: the first is the full/squeezed recipe
    /// boundary, the second states the band's true minimum content width (see
    /// their docs).
    ///
    /// Pure, so the routing decision `DeckWindow` makes is testable without a
    /// window (`OverviewLayoutTests`), the same reason `forSize` is.
    public enum Presentation: Equatable, Sendable {
        /// The detail band, for any layout, selected, at any size: the full
        /// recipe at `bandMinimumHeight` and above, the squeezed one strictly
        /// below it (`bandSqueezed(usableHeight:)` is a strict `<`;
        /// `bandSqueezedBoundary` pins both sides).
        case band
        /// Nothing is selected; the fleet is the whole picture.
        case fleetOnly
    }

    public static func presentation(for layout: OverviewLayout, hasSelection: Bool,
                                    usableWidth: Double, usableHeight: Double) -> Presentation {
        hasSelection ? .band : .fleetOnly
    }

    /// The boundary between DetailBand's FULL recipe (at or above it) and its
    /// SQUEEZED one (below it). `bandSqueezed(usableHeight:)` is the one place
    /// that boundary is asked about; every squeezed-recipe reader (the decision
    /// buttons' height and width, `SubjectWell`'s compact row, the three
    /// notices' compact shape, the title fold, the actions/Controls height
    /// folds) goes through it rather than this constant.
    ///
    /// Derived from the worst RECORDED act-zone content the full recipe ships
    /// without clipping (recorded, not reachable: a synthesised
    /// three-suggestion decision measures ~690 pt and no band budget survives
    /// it; capping the suggestion stack with the house overflow affordance is
    /// the filed follow-on). That worst case is the canonical worst-case
    /// decision (a suggestion beside Allow/Deny, on a subject long enough to
    /// need a well; see `DetailBand.wellExpandedMaxHeight`), measured whole at
    /// the strip's width and EXPANDED (the taller state: 358 pt against 357
    /// collapsed). `bandFitsTheStripWorstCaseDecision` (`RenderSweepTests.swift`)
    /// is the live arbiter. 358 is that measurement exactly, with no margin to
    /// spare; it is the tightest number in this feature.
    ///
    /// The strip's two budgets (`QuestionOptionsBand.usableStripHeight` 419,
    /// and 419 minus the measured connection-banner height, 359) both clear
    /// this boundary, so the strip always renders the full recipe
    /// (`presentationClearsTheFloorOnTheStrip`). The default desktop window
    /// (`DeckPrefs.defaultWindow`, 1280x300 -> 239 pt usable) renders the
    /// squeezed recipe, and the narrower 1254x394 window does only with the
    /// banner up (394 >= 358; 334 is not): `defaultWindowGetsTheBandNow` and
    /// `presentationRoutesToTheBandAtEveryHeight` hold both. That banner flip is
    /// geometry, not a bug: `usableHeight` simply reports 60 pt less room when
    /// the banner is up, and the recipe shrinks to match.
    ///
    /// Three floors must all be cleared by this value: the well's
    /// (`bandFixedChrome + bandWellMinimum`), Controls' folded floor, and the
    /// Quick Actions column's: `bandHeaderHeight + 2 x
    /// bandColumnsVerticalPadding + bandQuickActionsNaturalHeight`. The actions
    /// column does not fold (it clips; see `QuickActionsColumn` in
    /// `DecisionBar.swift`), so its full natural height counts. Today the third
    /// governs at 357, one point under this constant.
    /// `bandMinimumHeightClearsTheYieldedRendersOwnFloor` (`OverviewLayoutTests`)
    /// reads each floor live rather than restating them as literals.
    public static let bandMinimumHeight: Double = 358

    /// **`squeezed <=> usableHeight < bandMinimumHeight`: the one place that
    /// comparison is made, so every squeezed-recipe reader agrees where the line
    /// is.** Strict `<`: AT the boundary the full recipe's worst recorded
    /// content (`bandFitsTheStripWorstCaseDecision`) still fits by measurement,
    /// so 358 itself renders the full recipe. The strip's two budgets (419, 359)
    /// both answer `false`, so `squeezed` is only ever true on a desktop window.
    /// That matters because the squeezed recipe's 44 pt button floors
    /// (`TouchTarget.minimum`, not `.decision`) are acceptable only where a
    /// mouse pointer, not a thumb, is implied.
    public static func bandSqueezed(usableHeight: Double) -> Bool {
        usableHeight < bandMinimumHeight
    }

    /// **The decision buttons' height step:** `TouchTarget.decision` (64) in
    /// the full recipe, `TouchTarget.minimum` (44) squeezed. `DecisionBar
    /// .buttonHeight` is the reader. A direct step off
    /// `bandSqueezed(usableHeight:)`, not a second threshold.
    public static func bandDecisionButtonHeight(usableHeight: Double) -> Double {
        bandSqueezed(usableHeight: usableHeight) ? TouchTarget.minimum : TouchTarget.decision
    }

    /// **MEASURED:** the squeezed decision buttons' floor width, a margin move
    /// rather than a pass/fail one. At the narrowest reachable act zone (604 pt:
    /// the 960 pt minimum window bands to 628 pt, `.actOnly`, minus 2 x
    /// `bandColumnsHorizontalPadding` (12)), the recorded worst-case suggestion
    /// ("2. Yes, and don't ask again for: git push *", beside "1. Yes" and "3.
    /// No") already stays on one row at the full recipe's 140 pt floor: the row
    /// is 577 pt against 600 pt of content room (604 minus 2 x the squeezed
    /// outer padding, `DetailBand.squeezedDecisionBarOuterPadding`, 2), 23 pt of
    /// slack. What 110 buys is margin for a longer suggestion (an `addRules`
    /// suggestion's length is unbounded): only the two short flanking buttons
    /// narrow, widening the slack from 23 pt to 83 pt (row 517 against 600).
    /// `bandActMinWidth` (620, the full recipe's wrap threshold at the 140 pt
    /// floor) does not apply: this is a different budget (604) and purpose.
    /// `theSqueezedDecisionRowStaysHorizontalAtTheNarrowestActZone`
    /// (`RenderSweepTests.swift`) is the live arbiter.
    public static let bandSqueezedButtonMinWidth: Double = 110

    /// **The decision buttons' floor-width step:** `bandSqueezedButtonMinWidth`
    /// (110) squeezed, 140 full; the same `bandSqueezed(usableHeight:)` step
    /// `bandDecisionButtonHeight(usableHeight:)` takes. Factored out so
    /// `DetailBand.actZone(for:)` and `RenderSweepTests`' content-driven matrix
    /// read the identical derivation rather than two independently drifting
    /// `squeezed ? bandSqueezedButtonMinWidth : 140` ternaries; a test oracle
    /// that re-derives a selection production also derives is a drift risk.
    public static func bandDecisionButtonMinWidth(usableHeight: Double) -> Double {
        bandSqueezed(usableHeight: usableHeight) ? bandSqueezedButtonMinWidth : 140
    }

    /// **MEASURED:** 116, the squeezed bar's natural height WITH the title row,
    /// at the canonical worst-case decision at the narrowest reachable act zone
    /// (604 pt). Below it the "Waiting for you" title row folds; at or above it
    /// the squeezed recipe shows the title. `DecisionBar.showsTitle` is the
    /// reader.
    ///
    /// The squeezed bar holds four pieces when everything is present: the title,
    /// the compact well's one row (48 pt measured alone; the overflow chip's
    /// `TouchTarget.minimum` square sets this floor), the 44 pt buttons, and the
    /// bar's squeezed chrome (`squeezedDecisionBarOuterPadding` and
    /// `squeezedDecisionBarContentSpacing`, 2/2, in `DetailBand.swift`). When
    /// `columnsHeightBudget` cannot hold all four, the title folds first: the
    /// orange card and the buttons already announce "a decision is waiting",
    /// and the buttons never fold. Title folded, the same shape measures 98,
    /// which fits a 101 pt budget (usable 149) with 3 pt to spare. At the real
    /// floor's 141 pt budget the title shows (141 > 116), so this fold is
    /// defensive depth, not something production engages.
    ///
    /// Stated on `usableHeight` (via `columnsHeightBudget`, `usableHeight -
    /// bandHeaderHeight`), the input every caller has, like
    /// `bandSqueezed(usableHeight:)`. `bandShowsDecisionTitleThresholdBothSides`
    /// (`OverviewLayoutTests`) holds the boundary (inclusive);
    /// `squeezedWorstCaseDecisionSurvivesEverySampleHeight` and
    /// `theDecisionRowMatrixNeverClipsAndHonoursHonestRoomForTheWell`
    /// (`RenderSweepTests`) hold the composed render.
    public static let bandDecisionTitleThreshold: Double = 116

    /// The pure step off `bandDecisionTitleThreshold`: `columnsHeightBudget`
    /// (`usableHeight - bandHeaderHeight`) at or above the threshold shows the
    /// title, below it folds. Stated on `usableHeight` the boundary is
    /// `bandDecisionTitleThreshold + bandHeaderHeight` = 164, under the
    /// reachable floor (usable 189, banner up), so this fold is defensive depth
    /// in production. At 189 (budget 141) this answers `true`; at usable 149
    /// (budget 101) it answers `false`, and the buttons stay whole either way.
    ///
    /// **`stackedRowExtra`** is additive and defaults to 0. The 116 threshold
    /// was measured unstacked at act width 604; a narrow act zone's stacked row
    /// (`bandDecisionRowExtraHeight(stacks:buttonCount:usableHeight:)`) grows
    /// the buttons by exactly that extra, so it is subtracted here (alongside
    /// `bandHeaderHeight`) just as it is subtracted alongside `bandFixedChrome`
    /// for the well. The title is the row shed first (see `showsTitle` in
    /// `DecisionBar.swift`), so it must fold sooner once a stacked row eats more
    /// of the same budget. Whether the row stacks at all is measured
    /// (`DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`), never predicted
    /// from a width constant; this function only does the arithmetic.
    public static func bandShowsDecisionTitle(usableHeight: Double, stackedRowExtra: Double = 0) -> Bool {
        usableHeight - bandHeaderHeight - stackedRowExtra >= bandDecisionTitleThreshold
    }

    /// **The expanded well's absolute floor: never smaller than this whatever
    /// the usable height, and the threshold below which the well is not built at
    /// all.** 16 pt is a scrollable sliver, honestly small rather than a design
    /// ideal; `bandWellHeight(usableHeight:stackedRowExtra:)` never flexes under
    /// it. `bandWellFits(usableHeight:stackedRowExtra:)` reads it for the second
    /// job: "is there honest room for a well at all". `DecisionBar.showsWell`
    /// acts on that answer: `false` omits the well outright (an `if`), because
    /// a zero-height frame cannot stand in for absence (the well's collapsed
    /// shape cannot compress past the overflow chip's 44 pt floor).
    ///
    /// Row stacking in the decision bar went through three shapes; don't
    /// reintroduce the first two.
    ///
    /// 1. **A width constant predicted from one label** (a stack threshold
    ///    measured against the canonical "git push *" suggestion). Wrong in both
    ///    directions on real content: label length alone swings the stacking
    ///    point by hundreds of points (`git push *` stacks up to act width 592,
    ///    `git push origin *` up to 629, a long `addRules` path glob up to
    ///    1053), button COUNT is a third independent axis (a two-suggestion,
    ///    four-button row overran the act zone by up to 86 pt), and a
    ///    genuinely fitting 596-599 pt act width was mispredicted as stacked,
    ///    dropping a subject well that had room to show.
    /// 2. **A `ViewThatFits(in: .vertical)` ladder.** Correct, but it lays out
    ///    every candidate, and a candidate carrying `SubjectWell` (`@State`, two
    ///    geometry probes, `.copyable`, a Liquid Glass background) is expensive
    ///    enough three or four times per pass to starve unrelated
    ///    timing-sensitive tests under the parallel suite. Unacceptable on the
    ///    surface that must stay responsive when a permission request arrives.
    /// 3. **Measured and cached (what ships).** `DecisionRowMeasurer
    ///    .rowWidth(titles:buttonMinWidth:)` (`DecisionBar.swift`) hosts the real
    ///    horizontal row once per distinct (titles, button floor) pair and caches
    ///    the width (the same idiom as `ActionPillMeasurer`);
    ///    `DetailBand.actZone(for:)` compares it to the real act width. The cost
    ///    moved rather than vanished: a novel decision pays roughly 2-3 ms once on
    ///    the main thread, then every ask is a dictionary lookup. It is correct
    ///    for any label and button count because the row measured is the row
    ///    rendered.
    public static let bandWellMinimum: Double = 16

    /// **MEASURED:** the band's fixed chrome with the well's expandable content
    /// excluded, found by the two-sample slope technique (as in
    /// `SubjectOverflow.expandedMaxHeight`): sample the same worst-case shape at
    /// two well caps 60 pt apart. The canonical worst case
    /// (`bandFitsTheStripWorstCaseDecision` in `RenderSweepTests.swift`: a
    /// suggestion beside Allow/Deny on an `ExitPlanMode` plan long enough that
    /// the well's `ScrollView` is always the binding constraint) is measured
    /// expanded and whole (`DetailBand`, not `DecisionBar` alone: the chrome must
    /// cover the header and zone padding too). The total moves by exactly 60 pt,
    /// proving the well is the only thing flexing, so `total - cap` is the same
    /// fixed number at both samples. `bandFixedChromeArbiter` (`RenderSweepTests`)
    /// reproduces both samples and pins this constant to what it measures now.
    ///
    /// The value is 232: the header, the zone padding, and the act zone's own
    /// chrome outside the well (`DecisionBar`'s outer padding and content
    /// spacing, `actZone(for:)`'s `VStack` spacing). There is no pinned action
    /// bar in the vertical chrome and so no row count for it to vary with; the
    /// Quick Actions column sits beside the act zone and shares
    /// `columnsHeightBudget`.
    ///
    /// This is not an identity with `bandMinimumHeight` (358 - 16 = 342 was the
    /// old arithmetic). The property that has to hold is weaker: the floor
    /// comfortably clears whatever a real render's worst natural height needs,
    /// which `bandMinimumHeightClearsTheYieldedRendersOwnFloor`
    /// (`OverviewLayoutTests`) checks.
    public static let bandFixedChrome: Double = 232

    /// **MEASURED:** `DetailBand.header`'s natural height at the strip's width.
    /// The other chrome constants (`bandFixedChrome`, `bandWellMinimum`,
    /// `bandMinimumHeight`) were derived against the `DecisionBar` branch of
    /// `actZone(for:)`; the `QuestionTakeover` branch (a bare, no-preview
    /// `AskUserQuestion`) is a different shape, so this is named separately
    /// rather than folded into `bandFixedChrome` (two independently measured
    /// numbers, not one restated as the other).
    /// `RenderSweepTests.bandHeaderAndAutoContinueMatchTheirNamedHeights` is the
    /// live arbiter; `bandedDeckWindowFitsTheStripWithoutGrowingIt` covers the
    /// takeover shape.
    public static let bandHeaderHeight: Double = 48

    /// **MEASURED:** `AutoContinueToggle`'s natural height (a stock `Toggle` at
    /// its touch floor). Every hidden-content affordance declares what it hides
    /// (`DetailBand.swift`'s file doc), so the toggle must never clip silently;
    /// unprotected, it clipped entirely at the strip's tightest budget (358/359
    /// pt). The toggle now lives in "This Session", outside the act zone, so
    /// nothing in `columnsHeightBudget` reserves for it. The constant stays live
    /// as the value `RenderSweepTests.theAutoContinueToggleNeverClipsInTheLiveRecordedShape`
    /// holds the toggle's frame to.
    public static let bandAutoContinueHeight: Double = 44

    /// **MEASURED:** `DetailBand`'s `BandStateNotice` (the ended/errored
    /// fallback) at the act zone's width: the taller of the two titled variants
    /// ("Session ended" and "This session errored"; 62 pt, the errored variant's
    /// wrapped detail line being taller). Named so
    /// `transcriptWellBeneathNotice(for:budget:)` can reserve it before laying
    /// out `TranscriptWell` beneath the notice.
    /// `RenderSweepTests.bandStateNoticeHeightMatchesItsNamedConstant` is the
    /// live arbiter.
    public static let bandStateNoticeHeight: Double = 62

    /// **MEASURED:** 28, `BandStateNotice`'s compact twin (`compact: true`,
    /// DetailBand's squeezed recipe). The detail line drops and the padding
    /// tightens (16 -> 6), leaving a title line and an icon, so both notices
    /// measure identically. A separate measurement, not
    /// `bandStateNoticeHeight` minus a guessed detail-line cost. Width-invariant:
    /// 28 pt at the strip's 1310 pt act zone and at the narrowest squeezed one
    /// (604 pt).
    /// `RenderSweepTests.bandStateNoticeCompactHeightMatchesItsNamedConstant` is
    /// the live arbiter. `transcriptWellBeneathNotice(for:budget:compact:)` reads
    /// whichever constant matches the notice actually rendered; reading the wrong
    /// one is the dangerous direction (see that function's doc).
    public static let bandStateNoticeCompactHeight: Double = 28

    /// **MEASURED:** 75 pt, `DetailBand.apiErroredNotice(detail:compact:)`'s
    /// worst case: the 529 specimen text ("API Error: 529 Overloaded. This is a
    /// server-side issue, usually temporary - try again in a moment. If it
    /// persists, check https://status.claude.com."), `.lineLimit(3)`-capped, at
    /// the narrowest reachable act zone (604 pt, the width
    /// `bandSqueezedButtonMinWidth` derives). Claude Code's error text is not
    /// authored to fit `bandStateNoticeHeight`'s fixed reservation, so this
    /// notice caps its own detail at 3 lines (see `BandStateNotice
    /// .detailLineLimit`) and gets its own reservation.
    /// `transcriptWellBeneathNotice(for:budget:compact:)` reads this, never
    /// `bandStateNoticeHeight`, whenever `lane.apiError` says the api-error
    /// notice is on screen; reading the wrong constant would grant the well more
    /// room than the notice leaves, clipping the notice.
    /// `RenderSweepTests.apiErrorNoticeHeightStaysWithinItsNamedConstant` is the
    /// live arbiter, a `<=` ceiling rather than an exact match, since the
    /// message is composed by Claude Code and its length is not controlled here.
    public static let bandApiErrorNoticeHeight: Double = 75

    /// **MEASURED:** `DetailBand.controlsZone(for:budget:)`'s full natural
    /// content (Hide, Remove, Card Color, the divider, the toggle, the Directory
    /// footnote) at `bandSideColumnWidth`. With the toggle permanently inside
    /// this column, its natural height can exceed the columns row's shared
    /// budget. `showsFootnote` in `controlsZone(for:budget:)` reads this to fold
    /// the one informational (non-control) row exactly when `budget` cannot
    /// afford the full height. `RenderSweepTests
    /// .controlsZoneNaturalHeightMatchesItsOwnMeasuredConstant` is the live
    /// arbiter; `bandControlsFoldedMinimum` is the folded twin, and
    /// `bandMinimumHeightClearsTheYieldedRendersOwnFloor` (`OverviewLayoutTests`)
    /// reads both as one of the three floors `bandMinimumHeight` must clear.
    ///
    /// 279 leaves 12 pt of slack under the strip's normal banner-down budget
    /// (419 pt, one action row: `columnsHeightBudget` 291), so the footnote
    /// (the one identity fact not already on the card) stays through ordinary
    /// window-resize jitter. That slack comes from the column's `VStack` row
    /// spacing of 8 pt (not 12) between every adjacent pair (SessionControls,
    /// the divider, the toggle, the footnote, the trailing `Spacer`); no
    /// control's size or touch target was reduced.
    public static let bandControlsNaturalHeight: Double = 279

    /// **MEASURED:** the same column with the footnote folded
    /// (`showsFootnote == false`), still at `bandSideColumnWidth`. Folding the
    /// footnote is not enough on its own: Hide/Remove/Card Color/the divider/the
    /// toggle together are a real floor the layout must respect.
    /// `RenderSweepTests.controlsZoneFoldedMinimumMatchesItsOwnMeasuredConstant`
    /// is the live arbiter. The column uses the same 8 pt row spacing as the
    /// unfolded one.
    /// `bandMinimumHeightClearsTheYieldedRendersOwnFloor`'s `controlsFloor` reads
    /// this directly.
    public static let bandControlsFoldedMinimum: Double = 244

    /// **Whether Controls draws at all: width AND height, one boolean.**
    /// `bandZones(for:)` folds Controls by width only (into `.actOnly`), but
    /// `columnsHeightBudget` (`usableHeight - bandHeaderHeight`) can also fall
    /// below what even the folded column (`bandControlsFoldedMinimum`, 244) needs
    /// on a band that is wide enough for `.withControls` but short: a desktop
    /// window wider than `bandCompactThreshold` (874) but shorter than
    /// `bandControlsFoldedMinimum + bandHeaderHeight` (292), such as 1300x300
    /// (band width 968; usable height 239 banner-down). Below either floor
    /// Controls does not draw, and the header's folded-controls menu
    /// (`DetailBand.compactControlsMenu`) is where it survives, so this answers
    /// the one question `DetailBand` needs regardless of which floor binds.
    ///
    /// Conservative on width by design: when height alone folds Controls, the
    /// act zone's width still reserves a Controls-sized share
    /// (`DetailBand.actZoneWidth`'s sideColumns term reads this function, so the
    /// reservation and the render decision cannot drift) rather than reclaiming
    /// the width. In that one wide-but-short desktop combination the act zone is
    /// narrower than it could be, never wider than what fits; leaving points on
    /// the table is the safe direction, clipping is not.
    public static func bandControlsShown(bandWidth: Double, usableHeight: Double) -> Bool {
        bandZones(for: bandWidth) == .withControls && bandControlsHeightClears(usableHeight: usableHeight)
    }

    /// **The height half of `bandControlsShown(bandWidth:usableHeight:)`,**
    /// split out so `bandZonePlan(bandWidth:actionCount:usableHeight:)` asks the
    /// identical question (`usableHeight - bandHeaderHeight >=
    /// bandControlsFoldedMinimum`) rather than keeping a drifting copy.
    /// `bandZonePlan` reads this half alone because, once a mandatory actions
    /// column competes for the same row, "Controls shown" needs `bandWidth` past
    /// roughly 1152, not merely `bandCompactThreshold` (874); the cascade's
    /// per-candidate `act >= bandActMinWidth` check is the tighter of the two, so
    /// a bare width gate here could never bind.
    private static func bandControlsHeightClears(usableHeight: Double) -> Bool {
        usableHeight - bandHeaderHeight >= bandControlsFoldedMinimum
    }

    /// `DetailBand.columns(for:)`'s top-and-bottom padding around the whole row
    /// (`DetailBand.columnsVerticalPadding`), restated so
    /// `bandMinimumHeightClearsTheYieldedRendersOwnFloor` and production cannot
    /// drift (as `bandColumnsHorizontalPadding` guards for the horizontal pair).
    /// 4 pt each side, 8 pt total.
    public static let bandColumnsVerticalPadding: Double = 4

    // ---------------------------------------------------------- the decision row's own stack

    /// **The horizontal `ViewThatFits` branch's inter-button gap:**
    /// `DecisionBar.body`'s `HStack(spacing: bandDecisionRowSpacing)` and
    /// `DecisionRowMeasurer.bareRow`'s identical `HStack` both read this one
    /// constant. Don't give each a literal: a change to the real row's spacing
    /// alone would silently break the measurer's claim that "the row measured IS
    /// the row rendered", and the clipping that follows is not caught by
    /// anything that pins only one side. It differs from the stacked spacing
    /// (12, not 8); each branch's gap is its own constant.
    public static let bandDecisionRowSpacing: Double = 12

    /// **The vertical branch's inter-button gap:** `DecisionBar.body`'s literal
    /// `VStack(alignment: .leading, spacing: 8)`, restated here so
    /// `bandDecisionRowExtraHeight` uses the gap the STACKED branch pays (8, not
    /// the horizontal `bandDecisionRowSpacing` 12). One number for both recipes:
    /// only the button height beside it changes between full and squeezed.
    public static let bandDecisionRowStackSpacing: Double = 8

    /// **How much taller the act zone's decision row draws once it stacks:** the
    /// reservation `bandWellHeight(usableHeight:stackedRowExtra:)` subtracts
    /// alongside `bandFixedChrome`, so the well is never granted room a stacked
    /// row is spending.
    ///
    /// **`stacks` is supplied by the caller, not decided here.** Don't predict
    /// it from a width constant (see `bandWellMinimum` for why).
    /// `DetailBand.actZone(for:)` answers it by comparing
    /// `DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`
    /// (`DecisionBar.swift`), the real row's measured natural width, with the
    /// real act width. This function stays pure arithmetic (`DeckCore` cannot
    /// measure anything) and takes the one render-derived fact as data.
    ///
    /// 0 when `stacks` is `false`: `bandFixedChrome` already assumes one button
    /// row. Otherwise `(buttonCount - 1)` extra button heights, each with a
    /// `bandDecisionRowStackSpacing` gap, since the stacked branch draws
    /// `buttonCount` buttons top to bottom instead of one row.
    ///
    /// Checked against recorded measurements: full recipe, three buttons: 2 x
    /// (64 + 8) = 144, exactly the recorded stacked buttons frame (208) minus
    /// the horizontal one (64). Squeezed: 2 x (44 + 8) = 104 = 148 - 44.
    public static func bandDecisionRowExtraHeight(stacks: Bool, buttonCount: Int, usableHeight: Double) -> Double {
        bandDecisionRowExtraHeight(
            stacks: stacks, buttonCount: buttonCount,
            buttonHeight: bandStackedDecisionButtonHeight(usableHeight: usableHeight,
                                                          stacks: stacks, buttonCount: buttonCount))
    }

    /// `bandDecisionRowExtraHeight(stacks:buttonCount:usableHeight:)` with the
    /// button height passed IN rather than re-derived. The caller that has
    /// already chosen a height (`bandStackedDecisionButtonHeight`, and
    /// `DetailBand.actZone(for:)`, which threads the same height into
    /// `DecisionBar`) must reserve for the height it will draw; a second
    /// derivation is the drift this avoids.
    public static func bandDecisionRowExtraHeight(stacks: Bool, buttonCount: Int,
                                                  buttonHeight: Double) -> Double {
        guard stacks else { return 0 }
        return Double(buttonCount - 1) * (buttonHeight + bandDecisionRowStackSpacing)
    }

    /// **The question outranks the buttons' comfort height.**
    ///
    /// `bandDecisionButtonHeight(usableHeight:)` steps 64 -> 44 on the
    /// `bandSqueezed` threshold alone (how tall is the window). It does not ask
    /// how many buttons are about to be stacked. Four options (Yes, two engine
    /// suggestions, No) at the full 64 pt reserve 3 x (64 + 8) = 216 pt, and
    /// `bandWellFits` pushes the well out at any usable height under 464, so a
    /// roomy desktop band would render four options and no subject. A numbered
    /// option with no question above it is unanswerable; a smaller button is
    /// still a button with its digit shortcut.
    ///
    /// So when a stacked row's comfort height is what costs the subject its
    /// place, the row steps to `TouchTarget.minimum` (44 pt, the HIG floor the
    /// squeezed recipe already ships) and the 20 pt per button goes to the well:
    /// 60 pt at four options.
    ///
    /// **Only SHRINKS, and only when it changes the answer.** The full height
    /// is returned unless (a) the row stacks, (b) there are more than two
    /// buttons, (c) the full height evicts the well, and (d) the reduced height
    /// saves it. Otherwise the recipe is unchanged, so no geometry that already
    /// fits is disturbed.
    public static func bandStackedDecisionButtonHeight(usableHeight: Double, stacks: Bool,
                                                       buttonCount: Int) -> Double {
        let full = bandDecisionButtonHeight(usableHeight: usableHeight)
        guard stacks, buttonCount > 2, full > TouchTarget.minimum else { return full }
        let atFull = bandDecisionRowExtraHeight(stacks: true, buttonCount: buttonCount, buttonHeight: full)
        guard !bandWellFits(usableHeight: usableHeight, stackedRowExtra: atFull) else { return full }
        let reduced = TouchTarget.minimum
        let atReduced = bandDecisionRowExtraHeight(stacks: true, buttonCount: buttonCount, buttonHeight: reduced)
        return bandWellFits(usableHeight: usableHeight, stackedRowExtra: atReduced) ? reduced : full
    }

    /// **The flex rule:** pure arithmetic, not a `GeometryReader` negotiation,
    /// so a `fittingSize`-based budget test can derive its expectation from this
    /// function directly. The expanded well gets whatever slack `usableHeight`
    /// leaves once `bandFixedChrome` has taken its fixed share, never below
    /// `bandWellMinimum`.
    ///
    /// There is no `actionRows` parameter: the Quick Actions column sits beside
    /// the act zone and pays out of the shared `columnsHeightBudget`, so the
    /// number of actions does not change what is left for the well (see
    /// `bandFixedChrome`).
    ///
    /// The strip's two real budgets: `bandWellHeight(419)` = 419 - 232 =
    /// **187**; `bandWellHeight(359)` = 359 - 232 = **127**.
    /// `bandFlexGivesTheWellRoomOnTheStrip` (`RenderSweepTests.swift`) holds
    /// both.
    ///
    /// **`stackedRowExtra`** is additive and defaults to 0. A narrow act zone's
    /// stacked decision row (`bandDecisionRowExtraHeight(stacks:buttonCount:
    /// usableHeight:)`) draws taller than `bandFixedChrome` assumed; it is
    /// subtracted here so the well never gets room the buttons are spending.
    /// Callers with no button count to derive it from (every `actZoneFallback`
    /// branch: `QuestionTakeover`, a bare notice) pass the default.
    public static func bandWellHeight(usableHeight: Double, stackedRowExtra: Double = 0) -> Double {
        max(bandWellMinimum, usableHeight - bandFixedChrome - stackedRowExtra)
    }

    /// **Whether the well is built at all at this budget.**
    /// `bandWellHeight(usableHeight:stackedRowExtra:)` never returns below
    /// `bandWellMinimum` (its `max(...)`), which is right for the flex but the
    /// wrong answer to "is there honest room for a well at all". Answering "16
    /// pt" to that question lets a well nobody asked for float in a band with no
    /// room for it, silently growing the band past its budget.
    ///
    /// `usableHeight - bandFixedChrome - stackedRowExtra >= bandWellMinimum`:
    /// TRUE, the well draws at the height `bandWellHeight` computes; FALSE,
    /// `DecisionBar.showsWell` omits it outright. **An `if`, never a zero-height
    /// frame:** the well cannot compress past the overflow chip's
    /// `TouchTarget.minimum` (44 pt) floor, so a starved well draws at roughly 60
    /// pt and clips from the bottom, which would clip the Allow/Deny row itself,
    /// the one control this protects (see `showsWell` in `DecisionBar`).
    public static func bandWellFits(usableHeight: Double, stackedRowExtra: Double) -> Bool {
        usableHeight - bandFixedChrome - stackedRowExtra >= bandWellMinimum
    }

    /// **How many lines the COLLAPSED well shows before it needs the overflow
    /// chip, flexed for the same reason `bandWellHeight` is.** It gets
    /// `SubjectOverflow.collapsedLines` (4) once `bandWellHeight(usableHeight:)`
    /// clears its floor by at least 60 pt of slack, 1 line at none; between, a
    /// continuous rule spends every 20 pt of slack on one more line: `1 +
    /// floor(slack / 20)`, capped at `SubjectOverflow.collapsedLines`, floored at
    /// 1. `OverviewLayoutTests.collapsedLinesWorkedTable` pins the boundaries
    /// (20, 40, 60 pt of slack).
    ///
    /// The strip's two real budgets, `bandWellHeight(419)` (187 pt) and
    /// `bandWellHeight(359)` (127 pt), are both past 60 pt of slack (`1 +
    /// floor(171/20)` and `1 + floor(111/20)` cap at 4), so both show the full 4
    /// lines (`collapsedLinesAtBothRealStripHeights`).
    public static func bandWellCollapsedLines(usableHeight: Double) -> Int {
        let slack = bandWellHeight(usableHeight: usableHeight) - bandWellMinimum
        let lines = 1 + Int((slack / 20).rounded(.down))
        return max(1, min(lines, SubjectOverflow.collapsedLines))
    }

    /// The band's act zone: `DetailBand`'s flexible, left-most column.
    ///
    /// **MEASURED, not estimated.** Estimating it from `QuestionStage
    /// .leftColumnWidth`'s three-across-buttons arithmetic (476 pt) was wrong:
    /// at a `.compact`-zone act width of 618 pt, `DecisionBar`'s three buttons
    /// (Allow, one suggestion, Deny) still fell back to `ViewThatFits`'s vertical
    /// stack, because 476 pt is only the buttons' floor at their own
    /// `touchTarget(minWidth: 140)`, and a real suggestion label ("Don't ask
    /// again for: git push *") is wider. The row's ideal width is
    /// content-driven. Binary-searched directly: the row wraps at 600 pt and
    /// clears at 620, a 144 pt swing (one row versus three stacked
    /// `TouchTarget.decision` buttons). 620 is that threshold with no margin;
    /// `bandSideColumnWidth`'s size is what buys margin, since `.compact` mode's
    /// act width is `bandWidth - bandSideColumnWidth - bandZoneGutter`, not this
    /// floor directly (the floor almost never binds; the zone-threshold
    /// arithmetic below is derived from it).
    public static let bandActMinWidth: Double = 620

    /// The horizontal padding `DetailBand` puts around its `columns(for:)` row:
    /// 12 pt each side. Named here, as `bandZoneGutter` is, so
    /// `bandMinimumWidth` adds the same number production pads with.
    public static let bandColumnsHorizontalPadding: Double = 12

    /// **The act zone's absolute floor, derived from the window's minimum, not
    /// chosen as a round number.** `bandZonePlan(bandWidth:actionCount:
    /// usableHeight:)` (in "the quick actions column" section below) produces
    /// this number by running the same arithmetic forward (the squeezed step of
    /// its cascade at the minimum window's band width); this constant lets
    /// `bandMinimumWidth` and other readers get the answer without replaying the
    /// cascade.
    ///
    /// At `DeckPrefs.minWindow` (960 pt wide) the band nets 628 pt
    /// (`bandFleetWidth` 324 + `bandSeamWidth` 8 subtracted first, as
    /// `DeckWindow.bandWidth` does), well under `bandCompactThreshold` (874), so
    /// Controls has already folded by width. The mandatory actions column then
    /// takes its narrowest shape (`bandSideColumnWidth` 230 plus one
    /// `bandZoneGutter` 24) and the act zone gets the rest:
    ///
    ///     960 (DeckPrefs.minWindow.width) - 324 (bandFleetWidth)
    ///       - 8 (bandSeamWidth) - 24 (2 x bandColumnsHorizontalPadding)
    ///       - 24 (bandZoneGutter) - 230 (bandSideColumnWidth) = 350
    ///
    /// **Sanity check against the act zone's content floors (an ASSUMED bound,
    /// not measured: `DeckCore` cannot host a `SwiftUI` view).** The question
    /// grid's `GridItem(.adaptive(minimum: 220))` plus 32 pt of padding (the
    /// SwiftUI default for a bare `.padding()`) needs 252 pt for a single
    /// column; the two-button decision row needs roughly 292 pt. 350 clears
    /// both, by 98 and 58 pt. `RenderSweepTests` (`DeckApp`, where a real view
    /// can be hosted) confirms against the minimum window's real composed band.
    public static let bandActFloorWidth: Double =
        Double(DeckPrefs.minWindow.width) - bandFleetWidth - bandSeamWidth
        - 2 * bandColumnsHorizontalPadding - bandZoneGutter - bandSideColumnWidth

    /// **Not a routing floor: nothing routes away on width.** It is the band's
    /// true minimum content width: the act zone's derived floor
    /// (`bandActFloorWidth`, 350) plus one gutter plus the mandatory actions
    /// column's narrowest shape (`bandZonePlan(bandWidth:actionCount:
    /// usableHeight:)` never lets that column drop). `bandZones(for:)` still
    /// folds Controls by width, but that reads `bandCompactThreshold` (874), a
    /// different threshold.
    ///
    ///     bandActFloorWidth (350) + bandZoneGutter (24)
    ///       + bandSideColumnWidth (230) + 2 x bandColumnsHorizontalPadding (24) = 628
    ///
    /// **This collapses algebraically to exactly `DeckPrefs.minWindow.width -
    /// bandFleetWidth - bandSeamWidth`, the subtraction `bandActFloorWidth` was
    /// built from, run the other way.** So the constant equals the minimum
    /// window's band width exactly (628), with no margin: the floor and the
    /// window that reaches it are the same fact stated from opposite ends. Any
    /// test of this relationship (`RenderSweepTests.bandNeverDemandsMoreWidthThanItIsGiven`
    /// in `DeckAppTests`) should assert `==`, not `>=`, so a future drift of
    /// `bandMinimumWidth` past the window's band width is caught.
    ///
    /// `bandActMinWidth` is real arithmetic, not a live SwiftUI constraint: the
    /// act zone renders at an exact computed width (`DetailBand.actZoneWidth`),
    /// never a hard `.frame(minWidth:)`, which could drag
    /// `.windowResizability(.contentSize)`'s minimum past it.
    public static let bandMinimumWidth: Double =
        bandActFloorWidth + bandZoneGutter + bandSideColumnWidth + 2 * bandColumnsHorizontalPadding

    /// The band's one remaining narrower column: Controls.
    ///
    /// 260 pt (a `SessionControls` button's comfortable width) left `.compact`
    /// mode's act zone at 618 pt, 2 pt short of the 620 pt button-wrap threshold
    /// (`bandActMinWidth`). 230 pt is what `bandCompactThreshold` needs to clear
    /// that threshold with 20 pt to spare. `SessionControls`' buttons are
    /// `maxWidth: .infinity` and the identity footnote already truncates
    /// (`.truncationMode(.middle)`), so the narrower column costs legibility at
    /// the margin, not correctness.
    public static let bandSideColumnWidth: Double = 230

    /// The gap `DetailBand` puts either side of a `Divider` between its zones,
    /// named once so the thresholds below and the view's `zoneDivider` cannot
    /// drift apart.
    public static let bandZoneGutter: Double = 24

    /// **The width below which even Controls folds into the act zone
    /// (`.actOnly`, the band's only narrower tier).** Below it there is not room
    /// for the act zone (`bandActMinWidth`) and one more column.
    ///
    /// `bandActMinWidth` (620) + one `bandSideColumnWidth` (230) + one
    /// `bandZoneGutter` (24) = 874, the arithmetic `bandZones(for:)` alone
    /// knows about.
    ///
    /// The whole range below it is reachable through `presentation(...)`: a
    /// `.row` window's 620 pt width floor nets a band width of 288 once
    /// `bandFleetWidth` and `bandSeamWidth` are subtracted, and every band width
    /// in [288, 628) renders the `.actOnly` shape rather than falling back to a
    /// different surface. The overdraw concern a width floor would guard is
    /// answered by the squeezed recipe's narrower button `minWidth`
    /// (`bandSqueezedButtonMinWidth`). `presentationRoutesToTheBandAtEveryWidth`
    /// and `actOnlyIsReachableAtRowsOwnMinimumWidth` (`OverviewLayoutTests`) and
    /// `actOnlyZoneRenders` (`RenderSweepTests`, at 700) hold real content to it.
    public static let bandCompactThreshold: Double =
        bandActMinWidth + bandSideColumnWidth + bandZoneGutter

    /// **Which of the band's columns fit at a given band width.** Two tiers:
    /// act-plus-Controls, or act alone once even Controls has to fold.
    /// `TranscriptWell` renders inside the act zone at every width, never as a
    /// side column, so there is no third (queue/history) column to distinguish
    /// further tiers.
    public enum BandZones: Equatable, Sendable {
        /// Act and Controls, each its own column.
        case withControls
        /// Act alone; Controls folds to a compact affordance in the act zone's
        /// footer (an ellipsis menu, `DetailBand.compactControlsMenu`).
        case actOnly
    }

    public static func bandZones(for bandWidth: Double) -> BandZones {
        bandWidth >= bandCompactThreshold ? .withControls : .actOnly
    }

    // ------------------------------------------------- the quick actions column
    //
    // Where a `.row` selection's quick actions live: a side column between the
    // act zone and Controls, not a bottom-pinned bar competing with the well
    // for `columnsHeightBudget`. `QuickActionsColumn` (`DecisionBar.swift`) is
    // the view; everything here is the pure arithmetic deciding whether it
    // shows and how wide it is, the same split `bandZones(for:)` keeps between
    // "what fits" (this file) and "what draws" (`DetailBand`).
    //
    // The actions column is mandatory: when the band is too narrow for all three
    // columns, Controls ("This Session", the least load-bearing, and the one
    // column every other surface already lets fold to a menu) folds first and
    // the actions column never does, width or height, down to the window's
    // floor. `bandZonePlan(bandWidth:actionCount:usableHeight:)`, at the end of
    // this section, answers what each of the three columns looks like together.

    /// **The per-sub-column row ceiling: 5, the tallest either sub-column of
    /// the 2x5 grid ever stands.** `rows` (`bandZonePlanCascade`'s local,
    /// computed from `usableHeight` alone) is clamped to `0...bandActionsRowCap`,
    /// and `QuickActionsColumn.columnMajorSplit(_:plan:)` reads this to know
    /// where the left sub-column tops out.
    ///
    /// This is only the ceiling, not the split condition. Don't decide the split
    /// with `actionCount > bandActionsRowCap`: that is correct only when `rows ==
    /// bandActionsRowCap` (5, the strip's budgets). At the default desktop
    /// window (1280x300) `rows` is 3 (a squeezed height), and exactly 5 offered
    /// actions would take the single-entry ladder and show 3 of 5. The question
    /// is "how many actions versus how many rows THIS geometry has", which is
    /// `bandZonePlanCascade`'s `needsTwo = actionCount > rows`.
    public static let bandActionsRowCap: Int = 5

    /// The two-sub-column width: two `bandSideColumnWidth` columns side by side
    /// with one `actionGridSpacing` between them, the same gap a pill row puts
    /// between cells: 2 x 230 + 8 = 468.
    public static let bandActionsWideColumnWidth: Double = 2 * bandSideColumnWidth + actionGridSpacing

    /// **The narrow sub-column pair: the same footprint as one ordinary
    /// sub-column, split in two, so taking it costs the act zone nothing.**
    ///
    /// A set that cannot fit one sub-column's worth of rows would otherwise
    /// offer only two shapes, `bandActionsWideColumnWidth` (468, comfortable) or
    /// `bandSideColumnWidth` (230, one lone sub-column), and nothing between. A
    /// band too narrow for the first but wide enough for the second would drop
    /// to ONE sub-column, halving capacity from `2 x rows` to `rows` and pushing
    /// every action past that into the header's overflow chip although the act
    /// zone had asked for none of that room back. Concretely, at `actionCount`
    /// one past `rows`, `bandWidth` in [898, 1136) cleared the lone entry's
    /// threshold (898) but not the wide entry's (1136), an ordinary
    /// desktop-window range (content width roughly 1230-1467).
    ///
    /// Two of these sub-columns plus one `actionGridSpacing` occupy exactly one
    /// `bandSideColumnWidth`:
    ///
    ///     2 x bandActionsNarrowColumnWidth + actionGridSpacing == bandSideColumnWidth
    ///     2 x 111 + 8 == 230
    ///
    /// `theNarrowPairIdentityHoldsExactly` (`OverviewLayoutTests`) pins the
    /// identity. The value is derived as `(bandSideColumnWidth -
    /// actionGridSpacing) / 2`, stated as the expression (as with
    /// `bandActFloorWidth`) so retuning either input cannot leave it stale.
    /// `bandZonePlanCascade`'s `candidate(...)` reserves the whole column's
    /// footprint (`entry.columnWidth`), so a ladder entry `(2, 2 *
    /// bandActionsNarrowColumnWidth + actionGridSpacing)` reserves exactly what
    /// the lone-column entry does: wherever that entry clears `bandActMinWidth`,
    /// the pair does too at the same `bandWidth`, with double the capacity.
    ///
    /// This is not "one wide sub-column happens to be wide enough for two".
    /// `bandActionsWideColumnWidth` (468) is a wider reservation, tried first;
    /// this pair asks the act zone for nothing extra, which is why it is the
    /// ladder's fallback entry.
    public static let bandActionsNarrowColumnWidth: Double =
        (bandSideColumnWidth - actionGridSpacing) / 2

    // `bandActionsColumnWidth(actionCount:)`, `bandActionsColumn(bandWidth:
    // actionCount:)`, `bandActionsSingleThreshold` and
    // `bandActionsWideThreshold` no longer exist. `DetailBand` reads
    // `bandZonePlan(bandWidth:actionCount:usableHeight:)` once per layout pass
    // and derives `actZoneWidth`, the actions column's width and `controlsShown`
    // from it, so there is no separate "how wide" or "does it fit beside
    // Controls" question to ask. Don't add standalone width thresholds for the
    // actions column: the plan is a cascade of ladder entries across two
    // Controls postures, so no single number could faithfully restate it.

    /// **MEASURED:** `QuickActionsColumn`'s natural height at ten offered
    /// actions (`QuickAction.maxOffered`): the widest and, since every
    /// sub-column caps at `bandActionsRowCap` (5) rows, the tallest this column
    /// draws. Five rows of buttons, `actionGridSpacing` (8) between them, plus
    /// the titled card's chrome (a caption line, 10 pt padding, the
    /// `RoundedRectangle` background).
    /// `RenderSweepTests.quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant`
    /// is the live arbiter, hosting `QuickActionsColumn` with ten actions at
    /// `bandActionsWideColumnWidth` (468) in `NSHostingView`.
    ///
    /// 301 is the measured value, not a back-of-envelope `5x44 + 4x8 + ~27`
    /// (280). A `GroupBox`-based chrome measured 287 and was replaced because
    /// `GroupBox`'s AppKit-bridging Auto-Layout behaviour made the window
    /// sticky (`detailBandNeverDemandsHeight` holds that property); the
    /// titled-card replacement measures 301.
    ///
    /// **How tightly this clears the floor.**
    /// `bandMinimumHeightClearsTheYieldedRendersOwnFloor` (`OverviewLayoutTests`)
    /// checks `bandHeaderHeight + 2 x bandColumnsVerticalPadding +
    /// bandQuickActionsNaturalHeight` against `bandMinimumHeight` (358), the
    /// same shape as `controlsFloor` for Controls. At 301 that floor is 357, so
    /// `bandMinimumHeight` clears it by exactly one point. That is the tightest
    /// margin in the feature next to the worst-case decision arbiter
    /// (`bandFitsTheStripWorstCaseDecision`, which has none); re-measure either
    /// constant with that in mind. `QuickActionsColumn` clips rather than folds
    /// (see `DecisionBar.swift`), so this is its full unfolded height, not a
    /// folded minimum.
    ///
    /// This is the FLOOR-CASE height. Rows flex above the 44 pt floor toward
    /// the pill's `actionPillHeight` (64) when `bandActionsRowHeight` finds room,
    /// so 301 is what the column measures only at ten actions and a budget
    /// tight enough to floor all five left-sub-column rows. That is also the
    /// tightest shape the column must survive, so the floor ledger above stays
    /// the right one to hold `bandMinimumHeight` to.
    public static let bandQuickActionsNaturalHeight: Double = 301

    /// **The column's count-independent overhead, backed OUT of the measured
    /// whole rather than summed from guesses** (the summed estimate was already
    /// wrong twice; see `bandQuickActionsNaturalHeight`). 301 -
    /// (`bandActionsRowCap` (5) x `TouchTarget.minimum` (44)) - ((5 - 1) x
    /// `actionGridSpacing` (8)) = 301 - 220 - 32 = 49: everything the titled card
    /// spends that does not scale with row count (the caption line, the
    /// caption-to-rows spacing (`spacing: 8` in `QuickActionsColumn.body`'s inner
    /// `VStack`), the card's `.padding(10)` (20 total), and the outer `VStack`'s
    /// spacing to its trailing `Spacer` (8)).
    ///
    /// `bandActionsRowHeight(columnBudget:rowCount:)` is the one reader: it runs
    /// the same row arithmetic in reverse for whatever `rowCount` a real split
    /// has, holding this piece once.
    public static let bandQuickActionsChrome: Double =
        bandQuickActionsNaturalHeight - Double(bandActionsRowCap) * TouchTarget.minimum
        - Double(bandActionsRowCap - 1) * actionGridSpacing

    /// **The row's FRAME height, and what the visible glass drawn inside it
    /// grows to match.** Rows flex between the general touch floor
    /// (`TouchTarget.minimum`, 44) and the full pill height (`actionPillHeight`,
    /// 64), governed by how much of `columnBudget` the row count leaves free.
    /// This function sizes frame arithmetic only; `DeckCore` cannot name the
    /// glass. `QuickActionBar.bareControl`'s default recipe holds a fixed
    /// intrinsic height (46 pt, measured on macOS 26.5;
    /// `RenderSweepTests.thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight`
    /// pins it) because `.buttonSizing(.flexible)` fills the frame's width only.
    /// The one exception is `QuickActionsColumn.column(_:rowHeight:)`
    /// (`DecisionBar.swift`), which opts in to `bareControl(..., fillsHeight:
    /// true)` so the glass grows to fill this frame instead of floating,
    /// centred, in a taller row's dead space. It still cannot compress below the
    /// ~46 pt natural minimum at the 44 pt floor. `columnBudget` is the exact
    /// value `DetailBand.columns(for:)` passes as `QuickActionsColumn.budget`:
    /// `columnsHeightBudget` (`DetailBand.swift`), unadjusted.
    ///
    /// **What sits between `columnBudget` and the card** (traced in
    /// `DetailBand.swift`; a wrong guess overflows rows into
    /// `QuickActionsColumn`'s `.clipped()` backstop). `DetailBand.body` applies
    /// `.padding(.vertical, Self.columnsVerticalPadding)` to `columns(for:
    /// lane)` BEFORE the `.frame(maxWidth: .infinity, maxHeight:
    /// columnsHeightBudget)` that caps the padded whole, and `columnsHeightBudget`
    /// does not subtract that padding a second time. So the padding is real room
    /// a column never draws into: content reaching exactly `columnBudget` tall is
    /// `columnBudget + 8` overall once the row's 2 x `bandColumnsVerticalPadding`
    /// is added, and the outer `.clipped()` trims the bottom. Controls has the
    /// same fact (`controlsFloor` in
    /// `bandMinimumHeightClearsTheYieldedRendersOwnFloor`); its `actionsFloor` is
    /// the same statement with `bandHeaderHeight` added to both sides. This
    /// function solves for the row height a `rowCount` can have.
    ///
    /// `available = columnBudget - 2 x bandColumnsVerticalPadding -
    /// bandQuickActionsChrome - (rowCount - 1) x actionGridSpacing`: the
    /// interior room left once outer padding, the card's count-independent
    /// chrome and the inter-row gaps are spent. The result is `(available /
    /// Double(rowCount)).rounded(.down)`, clamped to `TouchTarget.minimum ...
    /// actionPillHeight` (44...64).
    ///
    /// `rowCount < 1` and `columnBudget <= 0` (the band has yielded past
    /// usability; `DetailBand.columnsHeightBudget` floors at 0) answer the floor
    /// directly. Degenerate shapes are `QuickActionsColumn`'s `.clipped()`
    /// backstop's to own.
    ///
    /// **Worked, for the left sub-column (the taller whenever a set spills into
    /// a second; `columnMajorSplit` puts the first `bandActionsRowCap` actions
    /// there).** `columnBudget` 371 (banner down: `usableHeight` 419 -
    /// `bandHeaderHeight` 48): rowCount 1 -> 64, 3 -> 64, 5 -> 56. 311 (banner
    /// up: 359 - 48): rowCount 3 -> 64, 5 -> 44. 310 (`bandMinimumHeight` 358 -
    /// 48, the floor's tightest shape): rowCount 5 -> 44, the floor itself. At
    /// that budget the column's floor-case content (301) clears the real
    /// interior room (310 - 8 = 302) by exactly one point, so the row answers 44
    /// because there is no slack left, not because the function rounds
    /// generously.
    public static func bandActionsRowHeight(columnBudget: Double, rowCount: Int) -> Double {
        guard rowCount >= 1, columnBudget > 0 else { return TouchTarget.minimum }
        let available = columnBudget - 2 * bandColumnsVerticalPadding - bandQuickActionsChrome
            - Double(rowCount - 1) * actionGridSpacing
        let raw = (available / Double(rowCount)).rounded(.down)
        return min(max(raw, TouchTarget.minimum), actionPillHeight)
    }

    // ---------------------------------------------------------- the band's plan
    //
    // Every function above answers one question about the band's three columns
    // (does Controls fit by width; does it also fit by height; does the actions
    // column fit beside whichever answer those gave). A caller needing the whole
    // picture would have to ask all three in the right order and stay consistent
    // across `actZoneWidth`, `controlsShown` and `columns(for:)`.
    // `bandZonePlan(bandWidth:actionCount:usableHeight:)` answers all three as one
    // value: one place in a layout pass reads this geometry, and one answer
    // exists to disagree with.

    /// One sub-column of the Quick Actions column, once
    /// `bandZonePlan(bandWidth:actionCount:usableHeight:)` has decided there is
    /// honest room for it.
    ///
    /// `rows` lets the plan say "shown, but only tall enough for three of your
    /// five rows": a starved column sheds rows rather than itself, so a caller
    /// needs to know how many it kept.
    public struct BandActionsPlan: Equatable, Sendable {
        /// `bandSideColumnWidth` (230) or `bandActionsWideColumnWidth` (468);
        /// the ladder `bandZonePlan` walks only ever reserves one of these two
        /// footprints from the act zone. Not a 1:1 read of `subColumns`: 230 can
        /// mean one lone `bandSideColumnWidth` sub-column or two
        /// `bandActionsNarrowColumnWidth` (111) sub-columns, because `2 *
        /// bandActionsNarrowColumnWidth + actionGridSpacing ==
        /// bandSideColumnWidth`. The reservation is identical either way; read
        /// `subColumns` to know how many actually draw.
        public let columnWidth: Double
        /// 1 or 2. **A second sub-column opens whenever `actionCount` exceeds
        /// `rows`** (the set does not fit one sub-column's worth of rows), not
        /// whenever it exceeds the static `bandActionsRowCap` (5), which is wrong
        /// wherever `rows` falls short of it (see that constant). It opens where
        /// the act zone can afford either shape offering a second sub-column:
        /// the comfortable `bandActionsWideColumnWidth` entry, or the narrow-pair
        /// entry that costs exactly what the lone `bandSideColumnWidth` entry
        /// does. `bandZonePlan`'s cascade falls back to 1 only once neither
        /// two-sub-column shape clears `bandActMinWidth`, and to nothing only once
        /// even the squeezed single sub-column cannot.
        public let subColumns: Int
        /// How many rows tall EACH sub-column stands: 1 through
        /// `bandActionsRowCap` (5), a function of `usableHeight` alone (see
        /// `bandZonePlan`) and never of `actionCount`. A caller with fewer
        /// actions than `capacity` leaves cells empty; one with more clips the
        /// list to `capacity`, the same overflow-honesty declaration
        /// `DetailBand`'s header fold makes when the column drops entirely.
        public let rows: Int
        /// `subColumns x rows`: the most actions the column can show at once.
        public var capacity: Int { subColumns * rows }

        /// Explicit: the synthesised memberwise initializer of a `public` struct
        /// is `internal`, and `OverviewLayoutTests` (`DeckCoreTests`, a separate
        /// module) constructs this type directly to pin `capacity`'s arithmetic.
        public init(columnWidth: Double, subColumns: Int, rows: Int) {
            self.columnWidth = columnWidth
            self.subColumns = subColumns
            self.rows = rows
        }
    }

    /// What the band's three columns look like, together, at a given
    /// `bandWidth` / `actionCount` / `usableHeight`:
    /// `bandZonePlan(bandWidth:actionCount:usableHeight:)`'s return value, which
    /// a layout pass reads once.
    public struct BandZonePlan: Equatable, Sendable {
        /// The act zone's exact width: computed, not demanded via a
        /// `.frame(minWidth:)` negotiation (see `DetailBand.actZoneWidth`).
        public let actWidth: Double
        /// `nil` exactly when there is nothing to show a column for
        /// (`actionCount == 0`) or the geometry is too starved for even the
        /// narrowest shape; never merely because the band is narrow.
        /// `theActionsColumnIsNeverDroppedForWidthAlone` (`OverviewLayoutTests`)
        /// makes that an explicit claim.
        public let actions: BandActionsPlan?
        /// Whether Controls draws at all. Folds first, by width or by height,
        /// freeing its share for the actions column and the act zone before
        /// either gives anything up.
        public let controlsShown: Bool
    }

    /// **The band's width cascade: one plan a caller reads once, in place of
    /// three separately read facts** (`bandZones(for:)`,
    /// `bandControlsShown(bandWidth:usableHeight:)`, and the actions column's
    /// own fit).
    ///
    /// **Product rule: the Quick Actions column survives to the window's
    /// minimum.** It may shrink; it may not disappear. Controls ("This Session",
    /// the least load-bearing of the three claimants, and the one column every
    /// other surface already lets fold to a menu) folds FIRST, freeing its width
    /// for the actions column and the act zone. Only once the actions column
    /// cannot afford even its narrowest shape does the act zone take the rest.
    /// By height the column never folds (`QuickActionsColumn` clips; see
    /// `DecisionBar.swift`); it sheds rows instead, the same "shrink the recipe,
    /// never swap the surface" principle as `bandSqueezed(usableHeight:)`.
    ///
    /// **Geometry used by every branch:**
    ///
    ///     span   = bandWidth - 2 x bandColumnsHorizontalPadding
    ///     usable = usableHeight (the caller has already subtracted the status
    ///              line and the connection banner)
    ///
    /// **The height half: `rows`, independent of `actionCount` by
    /// construction.** The largest `rows` whose floor-case content fits
    /// (`bandQuickActionsChrome + rows x TouchTarget.minimum + (rows - 1) x
    /// actionGridSpacing + 2 x bandColumnsVerticalPadding <= usableHeight -
    /// bandHeaderHeight`):
    ///
    ///     available = usableHeight - bandHeaderHeight
    ///                 - 2 x bandColumnsVerticalPadding - bandQuickActionsChrome
    ///     rows      = clamp(floor((available + actionGridSpacing)
    ///                             / (TouchTarget.minimum + actionGridSpacing)),
    ///                        0...bandActionsRowCap)
    ///
    /// Worked table: usable 357 -> 5 rows, 305 -> 4, 253 -> 3, 201 -> 2, 149 ->
    /// 1; every boundary lands exactly because 52 (`TouchTarget.minimum +
    /// actionGridSpacing`) divides each gap. `bandZonePlanRowsBoundaryTable`
    /// (`OverviewLayoutTests`) pins both sides of each boundary. `rows == 0`
    /// (usable below 149) is the one way this plan answers `actions: nil` for a
    /// reason other than `actionCount == 0`: no sub-column can stand one row, so
    /// the act zone takes the whole span.
    ///
    /// **The width cascade is LADDER-MAJOR, CONTROLS-MINOR: for each ladder
    /// entry, widest first, try Controls shown, then Controls folded, before a
    /// narrower entry is ever considered.** Don't try every entry with Controls
    /// shown first and Controls folded in a second pass: that is non-monotonic,
    /// and widening the window could halve the column's capacity. At 10 actions,
    /// band 1151.5 pt cleared no entry with Controls shown and so picked the wide
    /// entry folded (`468x2`, capacity 10), while band 1152.0 pt cleared the
    /// narrow entry shown exactly (act at 620) and returned it before the wide
    /// entry, which also still cleared 620 folded, got a look; capacity dropped
    /// from 10 to 5. No shipped snap size sits near 1152, which is how it went
    /// unnoticed. With ladder-major ordering, once ANY entry succeeds in either
    /// posture, capacity is fixed by that entry alone: Controls shown vs. folded
    /// changes `actWidth` and `controlsShown`, never `columnWidth`, `subColumns`
    /// or `rows`.
    /// `capacityNeverShrinksAsBandWidthGrows` and
    /// `capacityNeverShrinksAsUsableHeightGrows` (`OverviewLayoutTests`) sweep
    /// the reachable range at half-point resolution.
    ///
    /// 1. **For each ladder entry, widest first:** `[(2, 468), (2, 230)]` once
    ///    `needsTwo` (`actionCount > rows`), else `[(1, 230)]` alone. Try
    ///    `controlsShown: true`, gated on `bandControlsHeightClears(usableHeight:)`
    ///    (not the bare width gate `bandZones(for:) == .withControls`, whose 874
    ///    pt threshold is always the weaker of the two once an actions column
    ///    competes for the row), then `controlsShown: false`, each checked
    ///    against `act >= bandActMinWidth` (620). First success wins.
    ///
    ///    The second rung is `(2, 230)`, not `(1, 230)`: 230 is exactly
    ///    `bandSideColumnWidth`, so the reservation is identical, but two
    ///    `bandActionsNarrowColumnWidth` (111) sub-columns fit that footprint (see
    ///    that constant). A further `(1, 230)` rung after it would be dead code:
    ///    identical `columnWidth` tried later can only tie.
    ///
    ///    Which ladder a caller gets keys on `needsTwo = actionCount > rows`,
    ///    never on `actionCount > bandActionsRowCap` (see `bandActionsRowCap` for
    ///    the shipped-default bug that condition caused).
    ///
    ///    **Four thresholds this ladder can land on**, built only from
    ///    `columnWidth` and the width constants, never from `actionCount` or
    ///    `rows`. The single-entry ladder (`!needsTwo`) reaches the lone `(1,
    ///    230)` entry's pair: shown at `bandWidth >= 620 + 2x24 + 254 + 254 =
    ///    1152`; folded, earlier, at `>= 620 + 24 + 254 = 898`. The two-entry
    ///    ladder (`needsTwo`) tries the wide `(2, 468)` entry first in both
    ///    postures: shown at `>= 620 + 24 + 254 + 492 = 1390`; folded, earlier, at
    ///    `>= 620 + 24 + 492 = 1136`. So when `needsTwo`, the narrow-pair `(2,
    ///    230)` entry is reachable only in `[898, 1136)`, where even the wide
    ///    entry folded has not cleared. 1136 and 1152 are two different
    ///    boundaries: 1136 is the wide entry's folded threshold, and 1152 is the
    ///    narrow-pair entry's shown threshold, which never binds while `needsTwo`
    ///    because the wide entry has already succeeded 16 pt earlier.
    /// 2. **Squeezed: Controls folded, one sub-column at 230,** never the wide
    ///    entry or the narrow pair however large `actionCount` is: `act = span -
    ///    (230 + bandZoneGutter)`, accepted down to `bandActFloorWidth` (350), not
    ///    merely `>= 0` (which would answer a "squeezed" column beside a 0 pt act
    ///    zone at `bandWidth` 278). This step makes a set exceeding `rows` fall
    ///    back to `230x1` (capacity `rows`) rather than drop, in `[bandMinimumWidth
    ///    (628), 898)` (`ladderFallsBackRatherThanDroppingPastFiveActions`,
    ///    `OverviewLayoutTests`). A wider column there would only narrow the
    ///    squeezed act zone further for no reader benefit.
    ///    `[628, 898)` is a known exception to "a second sub-column is taken
    ///    whenever it would help";
    ///    `capacityTakesTheSecondSubColumnWheneverItWouldHelp`
    ///    (`OverviewLayoutTests`) sweeps and pins that gap.
    ///    `squeezed.actWidth >= bandActFloorWidth` reduces algebraically to
    ///    exactly `bandWidth >= bandMinimumWidth` (628): `squeezed.actWidth` is
    ///    `bandWidth - 2 x bandColumnsHorizontalPadding - bandSideColumnWidth -
    ///    bandZoneGutter`, which makes the guard `bandMinimumWidth`'s own
    ///    definition.
    /// 3. **Nothing fits:** `actions = nil`, the act zone takes the whole span.
    ///    Reachable only at `bandWidth < bandMinimumWidth` (628), which no
    ///    window the root clamp permits reaches (628 is that clamp's band width
    ///    exactly). Kept as defensive depth like the other below-floor cases (see
    ///    `promptLineLimit`); in practice only the `rows == 0` branch is reached.
    ///
    /// **`actions: nil` for `actionCount == 0` is the zeroth case, checked
    /// first, before `rows` is computed.** Controls answers the ordinary
    /// `bandControlsShown(bandWidth:usableHeight:)` question there, not the
    /// cascade's height-only half, because no actions column competes for width.
    /// `theZerothCaseReadsTheFullControlsShownRuleNotTheHeightHalfAlone`
    /// (`OverviewLayoutTests`) holds it to the full rule: the two disagree at a
    /// band narrow enough to fold Controls by width (under
    /// `bandCompactThreshold`, 874) but tall enough to clear the height half.
    ///
    /// **`rows == 0` is checked before the width cascade.** `heightAvailable`
    /// can hand `rawRows` a non-finite value (`.infinity`, or NaN from a caller),
    /// so it is clamped to `0...bandActionsRowCap` BEFORE the `Int` conversion:
    /// `Int(Double)` traps (uncatchable `SIGTRAP`) on a non-finite or too-large
    /// value. An unbounded `usableHeight` is a legitimate SwiftUI layout offer,
    /// and `presentation(...)`'s tests already pass `.infinity`.
    /// `bandZonePlanNeverTrapsOnUnboundedOrNonFiniteHeight` (`OverviewLayoutTests`)
    /// covers `.infinity`, `1e300` and `.nan`.
    ///
    /// **Worked, at every real geometry this deck composes** (pinned by
    /// `bandZonePlanAtEveryRealGeometry` in `OverviewLayoutTests`):
    ///
    /// - Strip, 1920x440 (usable 419): band 1588, act 1056, `230x1`, 5 rows,
    ///   Controls shown; at 10 actions, act 818, `468x2` (1588 clears the wide
    ///   entry's 1390 shown threshold outright). `rows` is 5, the ceiling, so
    ///   `needsTwo` agrees with `actionCount > bandActionsRowCap` here.
    /// - Narrow desktop, 1254x455 (usable 434): band 922, act 644, `230x1`, 5
    ///   rows, Controls folded; at 10 actions, `230x2` (the narrow pair; 922 is
    ///   inside `[898, 1136)`), all 10 shown, with `actWidth` unchanged at 644.
    /// - Default, 1280x300 (usable 279): band 948, act 670, `230x1`, 3 rows,
    ///   Controls folded, at 3 actions; at 10 actions, `230x2` (also inside
    ///   `[898, 1136)`), 6 of 10 shown (`2 x rows`), `actWidth` unchanged at
    ///   670. **At exactly `bandActionsRowCap` (5) actions, `rows` is 3 here, so
    ///   `needsTwo` reads `5 > 3`, true:** `230x2`, capacity 6, all 5 configured
    ///   actions show on the shipped default window.
    ///   `theDefaultWindowShowsAllFiveConfiguredActions` (`OverviewLayoutTests`)
    ///   pins this case.
    /// - Minimum, 960x270 (usable 249): band 628, act 350 (`bandActFloorWidth`
    ///   exactly), `230x1`, 2 rows, Controls folded: the squeezed step, with 628
    ///   below 898 (the exception named in step 2).
    /// - Minimum + banner (usable 189): 1 row, same squeezed step.
    ///
    /// **`minimumActWidth` is a post-filter on the whole cascade, not a new step
    /// inside it.** The actions column never yields for width alone (the
    /// cascade is that promise), but it does yield when the alternative is a
    /// clipped Allow/Deny row: a silently clipped decision control is the one
    /// failure this product refuses everywhere, and it outranks a folded action
    /// chip that still declares itself in the header
    /// (`DetailBand.yieldedHeaderFold`). Run the cascade, then check whether its
    /// answer is too narrow for the caller's floor. Defaulted to 0:
    /// `actWidth` is never negative, so `plan.actWidth < 0` never holds and
    /// callers who omit it read the cascade unfiltered.
    ///
    /// **"Too narrow" means: the cascade found a plan WITH an actions column at
    /// an `actWidth` below the caller's floor, AND folding the column would
    /// actually reach that floor.** Don't fold on the first condition alone. At
    /// bands 874-1150 the cascade has already folded Controls to seat the
    /// column, so folding the column too hands the same `bandSideColumnWidth +
    /// bandZoneGutter` (254) back to Controls, not to the act zone;
    /// `folded.actWidth` equals `plan.actWidth`, the column is destroyed for
    /// nothing, and the row still clips. So the fold is committed only if
    /// `folded.actWidth >= minimumActWidth`; otherwise `plan` is returned.
    /// `plan.actions == nil` is left alone: there is no column to fold.
    ///
    /// `DetailBand.decisionMinimumActWidth` documents what the caller passes and
    /// why it is safe to compute before this cascade runs (two content-driven
    /// facts, neither a function of the act width produced here).
    public static func bandZonePlan(bandWidth: Double, actionCount: Int, usableHeight: Double,
                                    minimumActWidth: Double = 0) -> BandZonePlan {
        let plan = bandZonePlanCascade(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
        guard plan.actions != nil, plan.actWidth < minimumActWidth else { return plan }
        let folded = bandZonePlanCascade(bandWidth: bandWidth, actionCount: 0, usableHeight: usableHeight)
        return folded.actWidth >= minimumActWidth ? folded : plan
    }

    /// **The cascade itself:** the logic of
    /// `bandZonePlan(bandWidth:actionCount:usableHeight:minimumActWidth:)` before
    /// its `minimumActWidth` post-filter, split out so the filter can wrap it
    /// without touching any branch. The docs above describe this function.
    private static func bandZonePlanCascade(bandWidth: Double, actionCount: Int, usableHeight: Double) -> BandZonePlan {
        let span = bandWidth - 2 * bandColumnsHorizontalPadding
        let controlsReserve = bandSideColumnWidth + bandZoneGutter

        guard actionCount > 0 else {
            let controlsShown = bandControlsShown(bandWidth: bandWidth, usableHeight: usableHeight)
            return BandZonePlan(actWidth: max(0, span - (controlsShown ? controlsReserve : 0)),
                                actions: nil, controlsShown: controlsShown)
        }

        let heightAvailable = usableHeight - bandHeaderHeight - 2 * bandColumnsVerticalPadding - bandQuickActionsChrome
        let rawRows = ((heightAvailable + actionGridSpacing) / (TouchTarget.minimum + actionGridSpacing)).rounded(.down)
        // Clamped to 0...bandActionsRowCap BEFORE the `Int` conversion, never
        // after: `Int(Double)` traps on `.infinity`, `-.infinity`, `.nan` or
        // anything outside `Int`'s range, and an unbounded `usableHeight` does
        // reach this line (a SwiftUI layout offer can be `.infinity`; see
        // `OverviewLayoutTests.everyLayoutRoutesToTheBandWhenSelected`).
        // `rawRows.isNaN` is checked directly: NaN compares false against
        // everything, so `max`/`min` alone cannot be trusted to route it into
        // range.
        let rows: Int
        if rawRows.isNaN {
            rows = 0
        } else {
            rows = Int(min(max(rawRows, 0), Double(bandActionsRowCap)))
        }

        guard rows > 0 else {
            // Height too starved for even one row: genuinely impossible, not
            // merely narrow. The act zone takes everything.
            return BandZonePlan(actWidth: max(0, span), actions: nil, controlsShown: false)
        }

        // `needsTwo`: whether a second sub-column is worth trying is a question
        // about THIS geometry's row budget, `rows`, never about the static
        // ceiling `bandActionsRowCap` alone. `actionCount > bandActionsRowCap`
        // is wrong wherever `rows < bandActionsRowCap` (the default 1280x300
        // window, `rows` 3, would show only 3 of exactly 5 actions); see
        // `bandActionsRowCap`.
        let needsTwo = actionCount > rows

        // The narrow pair joins the two-entry ladder whenever `needsTwo`; see
        // `bandActionsNarrowColumnWidth`. It is written as `2 *
        // bandActionsNarrowColumnWidth + actionGridSpacing` rather than
        // `bandSideColumnWidth` so the code shows the identity: `candidate(...)`
        // reserves `entry.columnWidth` whole, so this must tie with the lone
        // entry for the "costs the act zone nothing" claim to hold in code.
        //
        // There is deliberately no further `(1, bandSideColumnWidth)` rung.
        // `candidate(controlsShown:entry:)` computes `actWidth` from
        // `entry.columnWidth` alone, so such a rung after the narrow pair would
        // share its exact pass/fail outcome and could only ever tie. The
        // single-sub-column shape survives through the `!needsTwo` ladder.
        let ladder: [(subColumns: Int, columnWidth: Double)] =
            needsTwo
                ? [(2, bandActionsWideColumnWidth),
                   (2, 2 * bandActionsNarrowColumnWidth + actionGridSpacing)]
                : [(1, bandSideColumnWidth)]
        let controlsHeightClears = bandControlsHeightClears(usableHeight: usableHeight)

        func candidate(controlsShown: Bool, entry: (subColumns: Int, columnWidth: Double)) -> BandZonePlan {
            let reserved = (controlsShown ? controlsReserve : 0) + entry.columnWidth + bandZoneGutter
            return BandZonePlan(actWidth: span - reserved,
                                actions: BandActionsPlan(columnWidth: entry.columnWidth,
                                                         subColumns: entry.subColumns, rows: rows),
                                controlsShown: controlsShown)
        }

        // Ladder-major, Controls-minor (see the doc comment above for why): for
        // each entry, widest first, try Controls shown, then Controls folded,
        // before a narrower entry is considered.
        for entry in ladder {
            if controlsHeightClears {
                let shown = candidate(controlsShown: true, entry: entry)
                if shown.actWidth >= bandActMinWidth { return shown }
            }
            let folded = candidate(controlsShown: false, entry: entry)
            if folded.actWidth >= bandActMinWidth { return folded }
        }

        // Squeezed: Controls folded, one sub-column, whatever act is left,
        // accepted down to `bandActFloorWidth` (350) rather than merely `>= 0`.
        let squeezed = candidate(controlsShown: false, entry: (1, bandSideColumnWidth))
        guard squeezed.actWidth >= bandActFloorWidth else {
            // Genuinely impossible: not even the narrowest single sub-column
            // leaves the act zone its honest floor. This reduces to `bandWidth
            // >= bandMinimumWidth` (628) exactly, so `nil` is reached only below
            // the minimum window's band width. Kept for a pure function asked
            // about a geometry no window composes.
            return BandZonePlan(actWidth: max(0, span), actions: nil, controlsShown: false)
        }
        return squeezed
    }

    // -------------------------------------------------------- the action grid
    //
    // The pill arithmetic for quick actions. The pill recipe (every button a
    // Liquid Glass pill `actionPillHeight` tall, hugging its label width, floored
    // at a square for a short title and capped before a runaway one) replaced a
    // fixed-cell grid whose 44 pt cells were too small on the strip's glass (see
    // `actionPillHeight`). Because pill widths vary, wrap and overflow are
    // WIDTHS-based, not COUNT-based; `actionPillLayout(widths:chipWidths:barWidth:
    // maxRows:)` is the whole of it.
    //
    // **Test-only now.** `QuickActionsColumn` (`DecisionBar.swift`) replaced the
    // pinned `QuickActionBar` with a side column of fixed
    // `TouchTarget.minimum`-floored buttons in a 2x5 grid, budgeted like
    // Controls, so `actionPillLayout(...)` has no production caller. It is kept
    // because `OverviewLayoutTests` exercises both the `maxRows: nil` wrap
    // arithmetic and the `maxRows != nil` chip-cap path thoroughly (the
    // greedy-fit boundary, the chip's fixed-point search, the degenerate-capacity
    // floor), and a future wrapped, capped pill row should not have to reinvent
    // it. Routing is unaffected: `bandMinimumHeight` (358) never depended on the
    // bar's row count, and `DetailBand.columnsHeightBudget` is simply
    // `usableHeight - bandHeaderHeight`.

    /// **MEASURED against the macOS 26.5 SDK.** 64 pt, from three agreeing
    /// readings:
    ///
    /// 1. **Strip physics.** At the strip's ~225 ppi and 1x scale, one point is
    ///    about 0.113 mm. A 44 pt cell was about 5.0 mm of physical glass; the
    ///    HIG's 44 was written for displays where it means about 6.9 mm, and this
    ///    screen is denser by nearly a third. 64 pt is about 7.2 mm, restoring the
    ///    HIG's physical intent rather than its point count.
    /// 2. **`TouchTarget.decision` agrees.** 64 is already the floor for the one
    ///    class of control that earns extra size: a decision a mis-hit cannot
    ///    recover from.
    /// 3. **A live prototype on the real strip:** of five candidates, fitted pills
    ///    at this height were the one a real thumb picked.
    ///
    /// Held above the general touch floor (`TouchTarget.minimum`, 44) because the
    /// strip's physics never justified 44 for a row of buttons.
    public static let actionPillHeight: Double = 64

    /// **A short title floors to a tappable SQUARE, not a sliver.** A single
    /// glyph at the pill's `.title` (22 pt) font hugs to well under 64 pt wide;
    /// without a floor the pill would be `actionPillHeight` tall and far
    /// narrower. Measured: "X" hugs to 51 and the floor pads it back to a 64 pt
    /// square. ("Go" no longer exercises this clamp: its `.weight(.medium)`
    /// natural hug is 65, one point past the floor; see
    /// `actionPillMeasurerIsHonestAboutTheRealControl` in `RenderSweepTests`.)
    public static let actionPillMinWidth: Double = 64

    /// **The runaway-title cap:** past it, the label truncates rather than the
    /// pill growing without limit. `.help(title)` recovers the full text, as for
    /// a truncated branch name or prompt elsewhere on the deck. About 24
    /// characters at the pill's `.title` font: the 16-character worst case of
    /// `QuickAction.titleBudget`, "Regenerate token", measures 204 pt, well
    /// inside 320.
    public static let actionPillMaxWidth: Double = 320

    /// The inter-pill spacing: `QuickActionBar.body`'s `HStack(spacing: 8)` (the
    /// `GlassEffectContainer(spacing: 8)` around it agrees), restated so the
    /// wrap arithmetic reads the number production spaces pills with.
    public static let actionGridSpacing: Double = 8

    /// **A cell's position: a pill or the overflow chip, in reading order.**
    /// `.action(i)` indexes into the same `widths` array
    /// `actionPillLayout(widths:chipWidths:barWidth:maxRows:)` was called with;
    /// this type says WHERE each index lands, never what it is, and the caller
    /// owns the action list.
    public struct ActionPillLayout: Equatable {
        public enum Cell: Equatable {
            /// Index into the `widths` array this layout was computed from.
            case action(Int)
            /// The "N more" overflow pill; `hiddenCount` says how many.
            case chip
        }
        /// Every row, in draw order; each row's cells in reading (left-to-right)
        /// order.
        public let rows: [[Cell]]
        /// How many actions the chip is hiding: 0 exactly when no row contains a
        /// `.chip` cell.
        public let hiddenCount: Int
    }

    /// **Greedy first-fit in reading order**, the wrap arithmetic for pills
    /// whose width is the label's.
    ///
    /// A pill joins the current row whenever `rowWidth + actionGridSpacing +
    /// pillWidth <= barWidth`; otherwise it starts a new one. **The first pill in
    /// a row always joins, however wide it is:** a row is never empty, so a
    /// transient zero `barWidth` (the self-measuring seam's default before its
    /// first firing) produces one pill per row, never a crash or an infinite
    /// loop.
    ///
    /// `maxRows: nil` is the unbounded case: every action visible, `hiddenCount
    /// == 0`, no chip. A given `maxRows` is clamped to `>= 0`. **`maxRows == 0`
    /// is its own case: `(rows: [], hiddenCount: widths.count)`, no chip.** A
    /// caller can have no room for even one row; the bar then yields entirely
    /// rather than floor at a starved one-row layout that would clip. If the
    /// greedy partition of every pill already fits within `maxRows`, every action
    /// is visible and there is no chip.
    ///
    /// **Otherwise: the largest `visible` in `[0, count - 1]` whose greedy
    /// partition of `widths[0..<visible]`, plus one trailing chip cell, fits
    /// within `maxRows`.** A linear scan downward from `count - 1`, not a binary
    /// search, because fit is not guaranteed monotonic in `visible`:
    /// `chipWidths[k]` can grow with `k` (a wider "12 more" than "3 more"), so
    /// hiding one more action can need more room. Action counts are small, so
    /// the scan's cost is not a concern. `visible == 0` (the chip alone on its
    /// row) always fits within `maxRows >= 1` by the "first cell always joins"
    /// rule, so the scan terminates by construction.
    ///
    /// The chip is placed by the same greedy rule as a pill, so it wraps to its
    /// own row exactly when the arithmetic says it must, and the `rows` returned
    /// are the literal cells `QuickActionBar.body` draws.
    ///
    /// `chipWidths` is indexed by HIDDEN count: `chipWidths[k]` is the chip's
    /// measured width when hiding `k` actions (index 0 is never read). An
    /// out-of-range `k` reads the last entry rather than trapping (an empty
    /// `chipWidths` falls back to `actionPillMinWidth`), so under-provisioned
    /// input yields a slightly mis-sized chip, never a crash.
    ///
    /// Empty `widths` answers `(rows: [], hiddenCount: 0)`.
    ///
    /// Neither branch has a production caller now (see the section header);
    /// `OverviewLayoutTests` covers both.
    public static func actionPillLayout(widths: [Double], chipWidths: [Double],
                                        barWidth: Double, maxRows: Int?) -> ActionPillLayout {
        guard !widths.isEmpty else { return ActionPillLayout(rows: [], hiddenCount: 0) }

        func greedyRows(_ items: [(width: Double, cell: ActionPillLayout.Cell)]) -> [[ActionPillLayout.Cell]] {
            var rows: [[ActionPillLayout.Cell]] = []
            var currentRow: [ActionPillLayout.Cell] = []
            var currentWidth: Double = 0
            for item in items {
                if currentRow.isEmpty {
                    currentRow = [item.cell]
                    currentWidth = item.width
                } else if currentWidth + actionGridSpacing + item.width <= barWidth {
                    currentRow.append(item.cell)
                    currentWidth += actionGridSpacing + item.width
                } else {
                    rows.append(currentRow)
                    currentRow = [item.cell]
                    currentWidth = item.width
                }
            }
            if !currentRow.isEmpty { rows.append(currentRow) }
            return rows
        }

        func chipWidth(hiding count: Int) -> Double {
            if count < chipWidths.count { return chipWidths[count] }
            return chipWidths.last ?? actionPillMinWidth
        }

        let items = widths.enumerated().map { (width: $0.element, cell: ActionPillLayout.Cell.action($0.offset)) }

        guard let maxRows else {
            return ActionPillLayout(rows: greedyRows(items), hiddenCount: 0)
        }
        let cappedMaxRows = max(0, maxRows)
        guard cappedMaxRows > 0 else {
            return ActionPillLayout(rows: [], hiddenCount: widths.count)
        }

        let allRows = greedyRows(items)
        if allRows.count <= cappedMaxRows {
            return ActionPillLayout(rows: allRows, hiddenCount: 0)
        }

        var visible = widths.count - 1
        while visible >= 0 {
            let hidden = widths.count - visible
            let chip = (width: chipWidth(hiding: hidden), cell: ActionPillLayout.Cell.chip)
            let candidate = Array(items.prefix(visible)) + [chip]
            let candidateRows = greedyRows(candidate)
            if candidateRows.count <= cappedMaxRows {
                return ActionPillLayout(rows: candidateRows, hiddenCount: hidden)
            }
            visible -= 1
        }
        // Unreachable: `visible == 0` (the chip alone on its own row) always
        // satisfies `cappedMaxRows >= 1` by the greedy rule's "first cell in a
        // row always joins" floor, so the loop returns by then. Stated as a
        // precondition so a future change that broke the invariant fails loudly
        // rather than falling through.
        preconditionFailure("actionPillLayout: the downward scan exhausted every visible count without fitting")
    }

    // `actionBarHeight(rows:)` and `actionBarVerticalPadding` were removed with
    // the pinned bar; don't reinstate them (nothing used or tested them).
}
