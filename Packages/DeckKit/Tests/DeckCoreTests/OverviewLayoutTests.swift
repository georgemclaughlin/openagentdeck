//
//  OverviewLayoutTests.swift · Tests/DeckCoreTests
//
//  Which way the fleet enumerates, at the sizes it will actually meet.
//  A threshold nobody tests is a threshold that drifts.
//
//  The suite this replaces asserted `.column` for a 1920 x 480 strip and
//  called it correct. It was correct about the code and wrong about the
//  product: the deck's own hardware was getting the one shape that fits it
//  worst, and the test agreed because it had been written from the
//  implementation rather than from the surface. The `reachability` case at the
//  bottom is what stops that recurring.
//

import Testing
import DeckCore

struct OverviewLayoutTests {

    /// The sizes this app is really put at, named so a failure says which
    /// surface broke rather than which number changed.
    @Test("real surfaces get the layout they should", arguments: [
        // width, height, expected, what it is
        (1920.0, 480.0, OverviewLayout.row, "the strip display the deck was designed for"),
        (1100.0, 620.0, OverviewLayout.row, "the deck's own default window"),
        (1366.0, 1024.0, OverviewLayout.grid, "an iPad Pro over Sidecar"),
        (1512.0, 982.0, OverviewLayout.grid, "a 14-inch MacBook Pro, maximised"),
        (700.0, 900.0, OverviewLayout.grid, "a tall narrow window"),
        (500.0, 1000.0, OverviewLayout.column, "too narrow for two cards, however tall"),
        (400.0, 300.0, OverviewLayout.column, "dragged down to nothing"),
    ])
    func layoutForRealSurfaces(_ width: Double, _ height: Double,
                               _ expected: OverviewLayout, _ what: String) {
        #expect(OverviewLayout.forSize(width: width, height: height) == expected,
                Comment(rawValue: "\(what) (\(Int(width))x\(Int(height)))"))
    }

    /// **The regression that started this.**
    ///
    /// The strip is the hardware this product exists for, and under the old
    /// two-case rule it got a vertical column: sessions enumerated down 480
    /// points of scarce height while 1920 points of width sat empty beside
    /// them. Whatever else changes, the strip may never enumerate downward.
    @Test("the strip enumerates along its abundant axis")
    func theStripDoesNotStack() {
        let strip = OverviewLayout.forSize(width: 1920, height: 480)
        #expect(strip == .row,
                Comment(rawValue: "the strip got \(strip.rawValue) — it has width to spare "
                        + "and almost no height, so a downward list spends the wrong axis"))
    }

    /// Width alone can rule every multi-card layout out; height alone can
    /// never earn one. A grid one column wide is a list wearing the wrong name.
    @Test("height alone does not produce a multi-card layout")
    func widthIsAlsoRequired() {
        let tallAndNarrow = OverviewLayout.forSize(
            width: OverviewLayout.multiCardMinimumWidth - 1,
            height: OverviewLayout.gridMinimumHeight * 2)
        #expect(tallAndNarrow == .column)
        #expect(!tallAndNarrow.isMultiCard)
    }

    /// Exactly at a threshold is over it — a boundary that excludes its own
    /// value is a boundary somebody has to look up.
    @Test("the thresholds are inclusive")
    func thresholdsAreInclusive() {
        #expect(OverviewLayout.forSize(width: OverviewLayout.multiCardMinimumWidth,
                                       height: OverviewLayout.gridMinimumHeight) == .grid)
        #expect(OverviewLayout.forSize(width: OverviewLayout.multiCardMinimumWidth,
                                       height: OverviewLayout.gridMinimumHeight - 0.5) == .row)
        #expect(OverviewLayout.forSize(width: OverviewLayout.multiCardMinimumWidth - 0.5,
                                       height: OverviewLayout.gridMinimumHeight) == .column)
    }

    /// The deck's default window must NOT open as a grid — the grid is what a
    /// big surface earns, not the everyday shape.
    @Test("the shipped default window is not a grid")
    func theDefaultWindowIsNotAGrid() {
        let d = DeckPrefs.defaultWindow
        let layout = OverviewLayout.forSize(width: Double(d.width), height: Double(d.height))
        #expect(layout != .grid,
                Comment(rawValue: "the default \(d.width)x\(d.height) window opens as a grid"))
    }

    /// **Every layout must be reachable at some size somebody will really use.**
    ///
    /// This is the falsifier for the bug that motivated the rewrite: the grid
    /// was implemented, tested, and unreachable on the deck's own hardware,
    /// and nothing in the suite noticed because every test asked "what does
    /// this size produce" and none asked "does anything produce this case".
    @Test("no layout is unreachable")
    func everyLayoutIsReachable() {
        // A generous but realistic sweep: phone-ish through a large display.
        var seen: Set<OverviewLayout> = []
        for width in stride(from: 320.0, through: 2560.0, by: 20.0) {
            for height in stride(from: 240.0, through: 1600.0, by: 20.0) {
                seen.insert(OverviewLayout.forSize(width: width, height: height))
            }
        }
        for layout in OverviewLayout.allCases {
            #expect(seen.contains(layout),
                    Comment(rawValue: "no window size in the realistic range produces "
                            + "\(layout.rawValue) — it is dead code"))
        }
    }

    /// Growing a window never takes a multi-card layout away. The rule is
    /// monotone in both dimensions, so a drag cannot flicker between shapes.
    @Test("the rule is monotone, so dragging cannot flicker")
    func growingNeverTakesCardsAway() {
        for height in stride(from: 300.0, through: 1400.0, by: 25.0) {
            var wasMultiCard = false
            for width in stride(from: 320.0, through: 2000.0, by: 25.0) {
                let isMultiCard = OverviewLayout.forSize(width: width, height: height).isMultiCard
                #expect(!(wasMultiCard && !isMultiCard),
                        Comment(rawValue: "widening to \(Int(width)) at \(Int(height)) tall "
                                + "dropped back to a single column"))
                wasMultiCard = isMultiCard
            }
        }
    }

    /// A card in a row must be at least as wide as the grid's own floor, or
    /// the row is showing a cramped card on the surface with the most width.
    @Test("the row's card is no narrower than the grid's floor")
    func theIdealWidthClearsTheFloor() {
        #expect(OverviewLayout.cardIdealWidth >= OverviewLayout.cardMinimumWidth)
    }

    // ------------------------------------------------------- the detail band

    /// **RETOLD — "commit to band always" (a standing design directive) retires
    /// the layout-gated fallback this table used to hold `presentation
    /// (...)` to.** Every layout answers `.band` the instant something is
    /// selected now — `.grid`/`.column` included, never only `.row` — and
    /// `.fleetOnly` with nothing selected is unchanged: there is nothing
    /// to show detail for, so that question is still asked and still
    /// answered the same way. `usableHeight: .infinity` here is "always
    /// enough room" — `presentationRoutesToTheBandAtEveryHeight`/
    /// `AtEveryWidth` below are the ones that sweep sizes, including the
    /// cases that used to fall back below either floor.
    @Test("selection routes to the band for EVERY layout now, with room to spare", arguments: OverviewLayout.allCases)
    func everyLayoutRoutesToTheBandWhenSelected(_ layout: OverviewLayout) {
        #expect(OverviewLayout.presentation(for: layout, hasSelection: false,
                                            usableWidth: .infinity, usableHeight: .infinity) == .fleetOnly,
                Comment(rawValue: "\(layout.rawValue) with nothing selected offered a detail surface"))
        #expect(OverviewLayout.presentation(for: layout, hasSelection: true,
                                            usableWidth: .infinity, usableHeight: .infinity) == .band,
                Comment(rawValue: "\(layout.rawValue), selected, with room to spare, did not route to the band"))
    }

    /// **RETOLD — the band's own former height floor.** Below `bandMinimumHeight`, `.row` used to fall
    /// back to `.inspector`; now it stays banded, SQUEEZED
    /// (`OverviewLayout.bandSqueezed(usableHeight:)` answers `true` in
    /// exactly this range) — DetailBand's own squeezed recipe is what
    /// answers "not enough room" now, never a different surface. Swept
    /// across EVERY layout, not only `.row` — the old table gated `.grid`/
    /// `.column` out because the floor used to only ever matter to `.row`;
    /// now every layout reads the identical rule. `usableWidth: .infinity`
    /// isolates the HEIGHT term specifically —
    /// `presentationRoutesToTheBandAtEveryWidth` below is the width term's
    /// own counterpart.
    @Test("row stays banded below the band's own height floor too, and every other layout does the same",
          arguments: OverviewLayout.allCases,
          [OverviewLayout.bandMinimumHeight, OverviewLayout.bandMinimumHeight - 0.5, 149.0, 0.0])
    func presentationRoutesToTheBandAtEveryHeight(_ layout: OverviewLayout, _ usableHeight: Double) {
        #expect(OverviewLayout.presentation(for: layout, hasSelection: true, usableWidth: .infinity,
                                            usableHeight: usableHeight) == .band,
                Comment(rawValue: "\(layout.rawValue) at \(usableHeight) pt usable height, selected, did not "
                        + "route to the band — there is no floor left for it to fall back below"))
    }

    /// **RETOLD — the band's own former width floor.** Below `bandMinimumWidth`, `.row` used to
    /// fall back to `.inspector` for the exact symmetric reason the height
    /// floor did: the act zone's own button row could not be honoured
    /// without overdrawing. That overdraw concern is answered differently
    /// now — `DecisionBar`'s own `ViewThatFits` reflow handles a genuinely
    /// narrow act zone regardless, and the squeezed recipe's own narrower
    /// button `minWidth` (`OverviewLayout.bandSqueezedButtonMinWidth`)
    /// keeps the worst-case three-button row on one line at the narrowest
    /// reachable act zone — `RenderSweepTests
    /// .theSqueezedDecisionRowStaysHorizontalAtTheNarrowestActZone` is the
    /// render-level arbiter for THAT claim; this stays the routing-level
    /// proof that nothing falls back below this width any more, for every
    /// layout.
    @Test("row stays banded below the band's own width floor too, and every other layout does the same",
          arguments: OverviewLayout.allCases,
          [OverviewLayout.bandMinimumWidth + OverviewLayout.bandFleetWidth + OverviewLayout.bandSeamWidth,
           OverviewLayout.bandMinimumWidth + OverviewLayout.bandFleetWidth + OverviewLayout.bandSeamWidth - 0.5,
           OverviewLayout.multiCardMinimumWidth])
    func presentationRoutesToTheBandAtEveryWidth(_ layout: OverviewLayout, _ usableWidth: Double) {
        #expect(OverviewLayout.presentation(for: layout, hasSelection: true, usableWidth: usableWidth,
                                            usableHeight: .infinity) == .band,
                Comment(rawValue: "\(layout.rawValue) at \(usableWidth) pt usable width, selected, did not "
                        + "route to the band — there is no floor left for it to fall back below"))
    }

    /// **The strip clears both floors at both banner states — no longer a
    /// meaningful distinction (nothing routes away below either any more,
    /// `presentationRoutesToTheBandAtEveryHeight`/`AtEveryWidth` above
    /// hold that generally), kept as the STRIP's own end-to-end proof
    /// specifically.** 60 pt is `RenderSweepTests.measuredBannerHeight`'s
    /// own MEASURED figure (`ConnectionBanner` at the strip's 1920 pt
    /// width); restated as a literal here rather than imported, because
    /// `DeckAppTests` — where that constant lives — depends on THIS
    /// module, not the other way round, and a pure `DeckCore` rule has to
    /// be checkable without a `DeckApp` import to prove it. `usableWidth:
    /// 1920` — the strip's own full width nets 1588 (1920 −
    /// `bandFleetWidth` 324 − `bandSeamWidth` 8), comfortably past
    /// `bandMinimumWidth` (628, since the mandatory actions column —
    /// `bandMinimumWidth`'s own doc comment carries the retelling) — so
    /// this test holds the STRIP
    /// specifically, not "some sufficiently wide window," and both strip
    /// budgets (419, 359) are ABOVE `bandMinimumHeight` (358) — the strip
    /// never reaches the squeezed recipe, `OverviewLayout.bandSqueezed
    /// (usableHeight:)`'s own doc comment states why that matters (a mouse
    /// pointer, not a thumb, is what a squeezed window implies).
    @Test("the strip's own usable width and height clear both band floors, banner up or down")
    func presentationClearsTheFloorOnTheStrip() {
        let measuredBannerHeight = 60.0
        #expect(OverviewLayout.presentation(for: .row, hasSelection: true, usableWidth: 1920,
                                            usableHeight: QuestionOptionsBand.usableStripHeight) == .band,
                "the strip with no banner should always get the band")
        #expect(OverviewLayout.presentation(for: .row, hasSelection: true, usableWidth: 1920,
                                            usableHeight: QuestionOptionsBand.usableStripHeight - measuredBannerHeight) == .band,
                "the strip WITH the connection banner up should still get the band")
        #expect(!OverviewLayout.bandSqueezed(usableHeight: QuestionOptionsBand.usableStripHeight))
        #expect(!OverviewLayout.bandSqueezed(usableHeight: QuestionOptionsBand.usableStripHeight - measuredBannerHeight))
    }

    /// **RETOLD — the shipped default window does NOT clear the height
    /// floor, but that no longer means a fallback — a real, desktop-only
    /// SQUEEZE, not a hypothetical one.** `DeckPrefs.defaultWindow` is
    /// 1280×300; 300 − 40 (titlebar) − 21 (status line, `QuestionOptionsBand
    /// .usableStripHeight`'s own arithmetic) = 239 pt usable, well under
    /// `bandMinimumHeight`. A `.row` selection on the deck's own
    /// out-of-the-box window gets the band, squeezed — the very FIRST
    /// window most installs ever show a selection in is a squeezed one,
    /// which is exactly why the squeezed recipe has to be production-grade
    /// and not an edge case. `usableWidth: Double(d.width)` (1280, netting
    /// 948 — past `bandMinimumWidth`) is the REAL width, not `.infinity` —
    /// this test is end-to-end for the shipped default, and the height
    /// term alone is what it means to prove.
    @Test("the shipped default window gets the band, squeezed, not a fallback")
    func defaultWindowGetsTheBandNow() {
        let d = DeckPrefs.defaultWindow
        let titlebar = 40.0
        let statusLine = 21.0
        let usable = Double(d.height) - titlebar - statusLine
        #expect(usable < OverviewLayout.bandMinimumHeight,
                Comment(rawValue: "the default window's own usable height (\(usable) pt) now clears the "
                        + "floor (\(OverviewLayout.bandMinimumHeight) pt) — the fixture or the floor moved"))
        #expect(OverviewLayout.forSize(width: Double(d.width), height: Double(d.height)) == .row,
                "the fixture's own premise: the default window should be .row, or nothing below tests the floor")
        #expect(OverviewLayout.presentation(for: .row, hasSelection: true,
                                            usableWidth: Double(d.width), usableHeight: usable) == .band,
                "the default window's own selection should get the band")
        #expect(OverviewLayout.bandSqueezed(usableHeight: usable),
                "the default window's own usable height should land in the squeezed recipe, not the full one")
    }

    /// **The zone-drop rule, SIMPLIFIED — two tiers now, not three.**
    /// `TranscriptWell` retired the Queue/Earlier column outright
    /// (`OverviewLayout.BandZones`'s own doc comment states why `.full`
    /// and `.compact` collapsed into one shape, `.withControls`), so the
    /// strip's own full width and the deck's narrower desktop window
    /// (1920 pt and 1254 pt, both minus `bandFleetWidth` AND
    /// `bandSeamWidth` — production's own exact subtraction,
    /// `DeckWindow.bandWidth`) now read the SAME zone; only a truly narrow
    /// `.row` window still drops to `.actOnly`.
    @Test("the band keeps Controls at the strip's own width and at the deck's narrower desktop one, and folds it at a genuinely narrow row width")
    func bandZonesDropAtTheThreshold() {
        func bandWidth(_ totalWidth: Double) -> Double {
            totalWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        }
        #expect(OverviewLayout.bandZones(for: bandWidth(1920)) == .withControls,
                "the strip's own width should hold the act zone and Controls")
        #expect(OverviewLayout.bandZones(for: bandWidth(1254)) == .withControls,
                "the narrower desktop window has no second column left to drop — TranscriptWell replaced it")
        // `.row` itself needs no more than `multiCardMinimumWidth` (620) of
        // TOTAL width — `.actOnly`'s own reachability, held in
        // `bandCompactThresholdIsInclusive` and `actOnlyIsReachableAtRows
        // OwnMinimumWidth` below.
        #expect(OverviewLayout.bandZones(for: bandWidth(700)) == .actOnly,
                "a narrow row window, selected, should fold controls into the act zone too")
    }

    /// `.actOnly`'s own boundary — the band's only remaining threshold,
    /// held to the same inclusive-boundary discipline `thresholdsAreInclusive`
    /// above holds `forSize` to. `bandZoneThreshold` (1128, the old `.full`
    /// boundary) retired along with `.full` itself — nothing left to pin.
    @Test("the compact-zone threshold is inclusive")
    func bandCompactThresholdIsInclusive() {
        #expect(OverviewLayout.bandZones(for: OverviewLayout.bandCompactThreshold) == .withControls)
        #expect(OverviewLayout.bandZones(for: OverviewLayout.bandCompactThreshold - 0.5) == .actOnly)
    }

    /// **`.actOnly` is genuinely reachable — `.row`'s own 620 pt width
    /// floor nets a positive act-only band width, not a negative one
    /// nothing could ever produce.** `bandCompactThreshold`'s own doc
    /// comment makes this claim in prose; this is the arithmetic proof.
    @Test("row's own minimum width still leaves the band something to render")
    func actOnlyIsReachableAtRowsOwnMinimumWidth() {
        let bandWidth = OverviewLayout.multiCardMinimumWidth
            - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        #expect(bandWidth > 0,
                Comment(rawValue: "row's own minimum width (\(OverviewLayout.multiCardMinimumWidth)) leaves "
                        + "a non-positive band width (\(bandWidth)) once the fleet and the seam take theirs"))
        #expect(OverviewLayout.bandZones(for: bandWidth) == .actOnly)
    }

    /// **The threshold's own arithmetic, held to INDEPENDENT numbers — gate
    /// review's MINOR 7(i).** The prior version of this test compared
    /// `bandZoneThreshold` to a sum built from the SAME three constants
    /// production's own formula reads, which cannot fail no matter which
    /// of the four values (the three constants, or the threshold) drifts
    /// from the others — a widen-one-constant mutation and a
    /// widen-the-threshold-to-match mutation both leave the equation
    /// balanced. Literal numbers are the fix: each constant is checked
    /// against its own measured/derived value (see each one's own doc
    /// comment for where it comes from), and the threshold against the sum
    /// of THOSE literals, restated rather than recomputed.
    @Test("the zone constants and thresholds hold their own measured values")
    func bandZoneConstantsHoldTheirLiteralValues() {
        #expect(OverviewLayout.bandActMinWidth == 620,
                "the button-wrap threshold this constant is derived from was measured at 620")
        #expect(OverviewLayout.bandSideColumnWidth == 230)
        #expect(OverviewLayout.bandZoneGutter == 24)
        #expect(OverviewLayout.bandCompactThreshold == 874,
                Comment(rawValue: "620 + 230 + 24 = 874 — got \(OverviewLayout.bandCompactThreshold)"))
        // The Quick Actions column's own grid — independent literals, the
        // same MINOR 7(i) discipline the rest of this test already holds
        // every other zone constant to. `bandActionsSingleThreshold`/
        // `bandActionsWideThreshold` retired with the mandatory-column
        // redesign (`OverviewLayout.bandZonePlan`'s own doc comment carries
        // why) — nothing left to pin here.
        #expect(OverviewLayout.bandActionsRowCap == 5,
                "one sub-column's own row cap before a second sub-column opens")
        #expect(OverviewLayout.bandActionsWideColumnWidth == 468,
                Comment(rawValue: "2 × 230 + 8 = 468 — got \(OverviewLayout.bandActionsWideColumnWidth)"))
    }

    /// **The narrow pair's own identity, pinned directly — `2 ×
    /// bandActionsNarrowColumnWidth + actionGridSpacing ==
    /// bandSideColumnWidth`, the fact `bandActionsNarrowColumnWidth`'s own
    /// doc comment argues the whole fix rests on.** Checked as the
    /// EXPRESSION, not merely the literal both sides happen to equal today
    /// (111 and 230) — the same "state it as the derivation, not the
    /// number" discipline `bandActFloorWidthIsDerivedNotChosen` already
    /// holds `bandActFloorWidth` to — so this survives anyone retuning
    /// `bandSideColumnWidth` or `actionGridSpacing`: the identity has to
    /// keep holding algebraically, not merely happen to hold at today's
    /// two numbers. If this ever fails, the narrow pair no longer costs the
    /// act zone exactly what one ordinary sub-column does, and the whole
    /// "free" premise the ladder's own new rung is built on needs
    /// re-deriving, not silently re-pinning to a new pair of numbers.
    @Test("the narrow pair's own footprint identity holds exactly: two narrow sub-columns cost what one ordinary one does")
    func theNarrowPairIdentityHoldsExactly() {
        #expect(2 * OverviewLayout.bandActionsNarrowColumnWidth + OverviewLayout.actionGridSpacing
                == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "2 × \(OverviewLayout.bandActionsNarrowColumnWidth) + "
                        + "\(OverviewLayout.actionGridSpacing) should equal bandSideColumnWidth "
                        + "(\(OverviewLayout.bandSideColumnWidth)) exactly — got "
                        + "\(2 * OverviewLayout.bandActionsNarrowColumnWidth + OverviewLayout.actionGridSpacing)"))
        #expect(OverviewLayout.bandActionsNarrowColumnWidth == 111,
                Comment(rawValue: "(230 − 8) / 2 = 111 — got \(OverviewLayout.bandActionsNarrowColumnWidth)"))
    }

    // -------------------------------------------------------- the well's flex

    /// **`bandFixedChrome` and `bandWellMinimum`, held to LITERAL numbers —
    /// the same MINOR 7(i) discipline `bandZoneConstantsHoldTheirLiteralValues`
    /// above applies to the zone thresholds.** `bandFixedChrome`'s own live
    /// arbiter is `RenderSweepTests.bandFixedChromeArbiter`, which measures
    /// it fresh off a real render — this is the pure half, pinning what that
    /// measurement is supposed to equal so a mutation to the constant alone
    /// (leaving the render untouched) has two independent tests to fail, not
    /// one. **232, not the transcript-well-band-era 292** — re-measured for
    /// the Quick Actions column's move, which removed the pinned action bar
    /// from the band's own vertical chrome entirely (`bandFixedChrome`'s
    /// own doc comment carries the fresh measurement and what changed).
    @Test("the well's flex constants hold their own measured values")
    func bandWellFlexConstantsHoldTheirLiteralValues() {
        #expect(OverviewLayout.bandWellMinimum == 16,
                "the expanded well's own floor — DetailBand's former fixed constant, carried forward")
        #expect(OverviewLayout.bandFixedChrome == 232,
                Comment(rawValue: "measured live by RenderSweepTests.bandFixedChromeArbiter — got "
                        + "\(OverviewLayout.bandFixedChrome), re-measure rather than editing this literal"))
    }

    /// **`bandWellHeight(usableHeight:)`'s own boundary tests — DROPPED the
    /// `actionRows` parameter with the Quick Actions column's move, so the
    /// strip's own two real samples are now the SAME formula at two plain
    /// heights, not two samples straddling a row-yield boundary that no
    /// longer exists.** `bandFixedChrome`'s own doc comment carries the
    /// fresh measurement (232) this rests on: 187 pt at 419 (419 − 232),
    /// 127 pt at 359 (359 − 232) — MORE room at both real budgets than the
    /// pinned-bar era ever gave the well, since nothing competes with it
    /// for this row's own vertical chrome any more.
    @Test("bandWellHeight flexes above its floor, and holds the floor inclusive")
    func bandWellHeightFlexesWithUsableHeight() {
        #expect(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight) == 187,
                Comment(rawValue: "419 pt usable should flex the well to 187 pt — got "
                        + "\(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight))"))
        #expect(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight - 60) == 127,
                Comment(rawValue: "359 pt usable should flex the well to 127 pt — got "
                        + "\(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight - 60))"))

        // The floor's own threshold — `bandFixedChrome + bandWellMinimum`
        // (232 + 16 = 248).
        let floorHeight = OverviewLayout.bandFixedChrome + OverviewLayout.bandWellMinimum
        #expect(OverviewLayout.bandWellHeight(usableHeight: floorHeight) == OverviewLayout.bandWellMinimum,
                "exactly at the floor's own threshold the well should sit at its floor, not below it")
        #expect(OverviewLayout.bandWellHeight(usableHeight: floorHeight - 0.5) == OverviewLayout.bandWellMinimum,
                "half a point under the floor's own threshold should still floor, never go negative")
        #expect(OverviewLayout.bandWellHeight(usableHeight: floorHeight + 0.5) == OverviewLayout.bandWellMinimum + 0.5,
                "half a point over the floor's own threshold should already be flexing")
    }

    /// **`bandWellCollapsedLines(usableHeight:)`'s own boundary — a
    /// CONTINUOUS rule, `1 + floor(slack / 20)`, capped at
    /// `SubjectOverflow.collapsedLines` (4), floored at 1: a well sitting
    /// at its tightest single line right up until a cliff wastes every
    /// point of slack under it, and this formula spends it instead.**
    ///
    /// **DROPPED the `actionRows` parameter with the Quick Actions
    /// column's move — the well's own slack no longer varies with a bar
    /// row count that no longer exists (`bandWellHeight`'s own doc comment
    /// carries the same simplification for the function this one is built
    /// on).** Both real strip heights land at the cap (4) either way,
    /// `collapsedLinesAtBothRealStripHeights`, below, pins that directly;
    /// this table pins the formula's own boundaries (20, 40, 60 pt of
    /// slack) at a slack value derived directly rather than from either
    /// real height, so the boundary itself stays legible independent of
    /// whichever height happens to produce it.
    @Test("bandWellCollapsedLines grows continuously with slack, in 20pt steps, capped at SubjectOverflow.collapsedLines",
          arguments: [
            (0.0, 1, "no slack at all — the tightest 1 line"),
            (19.5, 1, "just under the first 20pt step"),
            (20.0, 2, "the first step — inclusive"),
            (39.5, 2, "just under the second step"),
            (40.0, 3, "the second step — inclusive"),
            (59.5, 3, "just under the cap's own boundary"),
            (60.0, 4, "the cap's own boundary — inclusive, the exact threshold the retired binary rule once used"),
            (100.0, 4, "well past the cap — stays at 4, never grows past the inspector's own figure"),
          ])
    func collapsedLinesWorkedTable(_ slack: Double, _ expected: Int, _ what: String) {
        let usableHeight = OverviewLayout.bandFixedChrome + OverviewLayout.bandWellMinimum + slack
        let got = OverviewLayout.bandWellCollapsedLines(usableHeight: usableHeight)
        #expect(got == expected, Comment(rawValue: "\(what) (\(slack) pt of slack) got \(got), expected \(expected)"))
    }

    /// **The strip's own two real budgets, pinned directly.** 419 gives the
    /// well 171 pt of slack past its floor (187 − 16), 359 gives it 111
    /// (127 − 16) — both comfortably past the 60 pt cap, so both show the
    /// full 4 collapsed lines.
    @Test("both real strip heights show the full 4 collapsed lines")
    func collapsedLinesAtBothRealStripHeights() {
        #expect(OverviewLayout.bandWellCollapsedLines(usableHeight: QuestionOptionsBand.usableStripHeight) == 4,
                "419 pt usable (171 pt of slack) should show the full 4 collapsed lines")
        #expect(OverviewLayout.bandWellCollapsedLines(usableHeight: QuestionOptionsBand.usableStripHeight - 60) == 4,
                "359 pt usable (111 pt of slack) should show the full 4 collapsed lines")
    }

    /// **RETOLD, stays green — 358 is no longer a routing floor (nothing
    /// routes away below it any more, `OverviewLayout.presentation(...)`'s
    /// own doc comment states the directive), it is the boundary between
    /// DetailBand's FULL recipe and its SQUEEZED one.** This test's own
    /// claim does not weaken for that: it still has to be true that the
    /// FULL recipe — the one 358 and above actually renders — comfortably
    /// clears what every column genuinely needs at minimum, because that
    /// is exactly the promise the strip's own two real budgets (419, 359,
    /// both above 358) depend on. Below 358, the SQUEEZED recipe owns the
    /// room instead — a DIFFERENT set of floors entirely (`bandSqueezed
    /// (usableHeight:)`'s own readers: `bandDecisionButtonHeight`,
    /// `bandShowsDecisionTitle`, `bandControlsShown`, the height-aware
    /// `bandActionsColumn` overload), none of which this test is about.
    ///
    /// **The old IDENTITY (`bandMinimumHeight == bandFixedChrome +
    /// bandWellMinimum`) stays retired — it held only by Q1-era
    /// construction, and two chrome re-measurements since have left the
    /// two numbers with no reason left to agree exactly.** What has to be
    /// true — and IS the property `bandMinimumHeight`'s own doc comment
    /// claims — is the weaker, safety-relevant one: the routing floor
    /// comfortably clears what a render genuinely needs at minimum,
    /// whichever of this band's THREE columns needs the most.
    ///
    /// **A third floor joins the ledger with the Quick Actions column's
    /// move, and it is the one that now BINDS.** `wellFloor`
    /// (`bandFixedChrome + bandWellMinimum`, 248) and `controlsFloor`
    /// (`bandHeaderHeight + 2 × bandColumnsVerticalPadding +
    /// bandControlsFoldedMinimum`, 300) are the same two floors this test
    /// has always checked; `actionsFloor` is new — the SAME shape as
    /// `controlsFloor`, but built from `bandQuickActionsNaturalHeight`
    /// rather than a folded minimum, because the actions column has no
    /// fold to floor at (`bandQuickActionsNaturalHeight`'s own doc comment
    /// states why). At ten offered actions this is the STRICTEST of the
    /// three — `bandMinimumHeight` (358) clears it by exactly ONE point
    /// at the current measured numbers (`bandQuickActionsNaturalHeight`'s
    /// own doc comment states the margin just as plainly), so the margin
    /// is now this floor's, not `controlsFloor`'s: a re-measurer who
    /// reads "comfortable" anywhere near this ledger should re-read it —
    /// any chrome growth at all sends this test red, which is that
    /// growth's decision point, not an arbiter tolerance to widen.
    @Test("the band's height floor comfortably clears what every column actually needs")
    func bandMinimumHeightClearsTheYieldedRendersOwnFloor() {
        let wellFloor = OverviewLayout.bandFixedChrome + OverviewLayout.bandWellMinimum
        let controlsFloor = OverviewLayout.bandHeaderHeight + 2 * OverviewLayout.bandColumnsVerticalPadding
            + OverviewLayout.bandControlsFoldedMinimum
        let actionsFloor = OverviewLayout.bandHeaderHeight + 2 * OverviewLayout.bandColumnsVerticalPadding
            + OverviewLayout.bandQuickActionsNaturalHeight
        let bindingFloor = max(wellFloor, max(controlsFloor, actionsFloor))
        #expect(OverviewLayout.bandMinimumHeight > bindingFloor,
                Comment(rawValue: "bandMinimumHeight (\(OverviewLayout.bandMinimumHeight)) should comfortably "
                        + "clear what every column needs at minimum (\(bindingFloor) — well \(wellFloor), "
                        + "controls \(controlsFloor), actions \(actionsFloor)) — if it does not, `.row` could "
                        + "route to a band too short for one of them"))
    }

    // ------------------------------------------------------ the squeezed recipe

    /// **`bandSqueezed(usableHeight:)`'s own boundary — strict `<`, the
    /// same inclusive-at-the-floor discipline `thresholdsAreInclusive`
    /// above holds every other threshold in this file to: AT
    /// `bandMinimumHeight` the FULL recipe still renders (`bandFitsTheStripWorstCaseDecision`'s
    /// own exact-fill identity is the proof it fits there), so `false` is
    /// the correct answer exactly at the boundary, `true` only strictly
    /// below it.**
    @Test("bandSqueezed answers false at the floor itself, true half a point under it",
          arguments: [
            (OverviewLayout.bandMinimumHeight, false, "exactly at the floor — the full recipe"),
            (OverviewLayout.bandMinimumHeight - 0.1, true, "a tenth of a point under — squeezed"),
            (357.9, true, "the mission's own worked boundary sample"),
            (358.0, false, "the mission's own worked boundary sample, the other side"),
          ])
    func bandSqueezedBoundary(_ usableHeight: Double, _ expected: Bool, _ what: String) {
        #expect(OverviewLayout.bandSqueezed(usableHeight: usableHeight) == expected,
                Comment(rawValue: "\(what) (\(usableHeight) pt) — got \(OverviewLayout.bandSqueezed(usableHeight: usableHeight)), expected \(expected)"))
    }

    /// **`bandDecisionButtonHeight(usableHeight:)`'s own worked table —
    /// the 64/44 step, at and around `bandMinimumHeight`.**
    @Test("bandDecisionButtonHeight steps from 64 to 44 exactly where bandSqueezed does",
          arguments: [
            (419.0, 64.0, "the strip, banner down — full recipe"),
            (359.0, 64.0, "the strip, banner up — still full recipe"),
            (OverviewLayout.bandMinimumHeight, 64.0, "exactly at the floor — still full recipe"),
            (OverviewLayout.bandMinimumHeight - 0.1, 44.0, "a tenth of a point under — squeezed"),
            (149.0, 44.0, "well below the reachable floor (usable 189, banner up) — defensive depth, squeezed"),
          ])
    func bandDecisionButtonHeightWorkedTable(_ usableHeight: Double, _ expected: Double, _ what: String) {
        #expect(OverviewLayout.bandDecisionButtonHeight(usableHeight: usableHeight) == expected,
                Comment(rawValue: "\(what) (\(usableHeight) pt) — got \(OverviewLayout.bandDecisionButtonHeight(usableHeight: usableHeight)), expected \(expected)"))
    }

    /// **`bandDecisionButtonMinWidth(usableHeight:)`'s own worked table —
    /// the 140/110 step, at and around `bandMinimumHeight`, the SAME
    /// boundary `bandDecisionButtonHeightWorkedTable` just above already
    /// holds `bandDecisionButtonHeight` to.** This function was promoted from an inline `squeezed ? … :
    /// 140` ternary (duplicated at `DetailBand.actZone(for:)` and
    /// `RenderSweepTests`' own test oracle) into a named public API,
    /// specifically to close a drift risk between those two call
    /// sites — but nothing pinned the function's OWN two return values,
    /// so collapsing it to always answer the squeezed floor left every
    /// test in the suite green. A load-bearing number that was just
    /// factored into an API of its own deserves the identical worked
    /// table its sibling already gets, the same rationale.
    @Test("bandDecisionButtonMinWidth steps from 140 to 110 exactly where bandSqueezed does",
          arguments: [
            (419.0, 140.0, "the strip, banner down — full recipe"),
            (359.0, 140.0, "the strip, banner up — still full recipe"),
            (OverviewLayout.bandMinimumHeight, 140.0, "exactly at the floor — still full recipe"),
            (OverviewLayout.bandMinimumHeight - 0.1, 110.0, "a tenth of a point under — squeezed"),
            (149.0, 110.0, "well below the reachable floor (usable 189, banner up) — defensive depth, squeezed"),
          ])
    func bandDecisionButtonMinWidthWorkedTable(_ usableHeight: Double, _ expected: Double, _ what: String) {
        #expect(OverviewLayout.bandDecisionButtonMinWidth(usableHeight: usableHeight) == expected,
                Comment(rawValue: "\(what) (\(usableHeight) pt) — got \(OverviewLayout.bandDecisionButtonMinWidth(usableHeight: usableHeight)), expected \(expected)"))
    }

    /// **`bandShowsDecisionTitle(usableHeight:)`'s own boundary, both
    /// sides — inclusive at the threshold, the same discipline every
    /// other boundary in this file holds to.** The threshold is stated on
    /// `usableHeight`, so the boundary itself is `bandDecisionTitleThreshold
    /// + bandHeaderHeight` (116 + 48 = 164), not the bare constant.
    @Test("bandShowsDecisionTitle folds exactly below its own threshold, inclusive at the boundary",
          arguments: [
            (OverviewLayout.bandDecisionTitleThreshold + OverviewLayout.bandHeaderHeight, true,
             "exactly at the boundary — the title still shows"),
            (OverviewLayout.bandDecisionTitleThreshold + OverviewLayout.bandHeaderHeight - 0.5, false,
             "half a point under — the title has already folded"),
            (149.0, false, "well below the reachable floor (usable 189, banner up) — the title folds here as "
             + "defensive depth; at the real floor's own 141 pt budget it shows instead (141 > 116)"),
            (419.0, true, "the strip, banner down — comfortably past the threshold"),
          ])
    func bandShowsDecisionTitleThresholdBothSides(_ usableHeight: Double, _ expected: Bool, _ what: String) {
        #expect(OverviewLayout.bandShowsDecisionTitle(usableHeight: usableHeight) == expected,
                Comment(rawValue: "\(what) (\(usableHeight) pt) — got \(OverviewLayout.bandShowsDecisionTitle(usableHeight: usableHeight)), expected \(expected)"))
    }

    // ---------------------------------------------------------------------
    // A pure-arithmetic trio used to live here too —
    // `bandDecisionRowStackConstantsHoldTheirLiteralValues`,
    // `bandDecisionRowStackThresholdSelectsByRecipe`,
    // `bandDecisionRowStacksWorkedTable` — pinning
    // `bandDecisionRowStackThreshold`/`bandSqueezedDecisionRowStackThreshold`/
    // `bandDecisionRowStacks(actWidth:buttonCount:usableHeight:)`. All
    // three retired with the production code they held accountable:
    // whether the button row stacks is MEASURED now
    // (`DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`,
    // `DecisionBar.swift`), never predicted from a width constant —
    // `OverviewLayout.bandWellMinimum`'s own doc comment carries the full
    // three-shape history. `bandDecisionRowExtraHeightWorkedTable`, below,
    // and `RenderSweepTests`' own content-driven matrix are what hold the
    // MEASURED answer accountable now; there is no pure "does it stack"
    // arithmetic left in this file to test, because `DeckCore` no longer
    // decides that question at all.
    // ---------------------------------------------------------------------

    /// **`bandDecisionRowExtraHeight(stacks:buttonCount:usableHeight:)`'s
    /// own worked table — the mission's own three cases: 0 (not stacked),
    /// 144 (full recipe, stacked), 104 (squeezed recipe, stacked).** 144 =
    /// 2 × (`bandDecisionButtonHeight(419)` 64 + `bandDecisionRowStackSpacing`
    /// 8); 104 = 2 × (`bandDecisionButtonHeight(300)` 44 + 8) — both direct
    /// readings off the SAME functions the render measured against, not a
    /// restated arithmetic that could quietly drift from them. `stacks` is
    /// now a bare `Bool` the caller supplies (`DetailBand.actZone(for:)`'s
    /// own measured comparison, in production) rather than something this
    /// function derives from a width — this table's own job is only the
    /// arithmetic AFTER that answer is known.
    @Test("bandDecisionRowExtraHeight worked table — 0, 144 (full, stacked), 104 (squeezed, stacked)",
          arguments: [
            (false, 2, 419.0, 0.0, "not stacked — no reservation, whatever the button count"),
            (false, 3, 419.0, 0.0, "three buttons, but not stacked — no reservation"),
            (true, 3, 419.0, 144.0, "three buttons, full recipe, stacked"),
            (true, 3, 300.0, 104.0, "three buttons, squeezed recipe, stacked"),
          ])
    func bandDecisionRowExtraHeightWorkedTable(_ stacks: Bool, _ buttonCount: Int, _ usableHeight: Double,
                                               _ expected: Double, _ what: String) {
        let got = OverviewLayout.bandDecisionRowExtraHeight(stacks: stacks, buttonCount: buttonCount, usableHeight: usableHeight)
        #expect(got == expected,
                Comment(rawValue: "\(what) (stacks \(stacks), \(buttonCount) buttons, \(usableHeight) pt usable) "
                        + "— got \(got), expected \(expected)"))
    }

    /// **`bandStackedDecisionButtonHeight`'s own worked table — the fold
    /// order corrected, at exactly the band where it changes the answer.**
    ///
    /// Four options (Yes, two engine suggestions, No) is the shape hit
    /// live: at the full 64 pt the stacked row reserves
    /// 3 × (64 + 8) = 216, and `bandWellFits` needs
    /// `usableHeight − 232 − extra ≥ 16`, so the subject well is evicted
    /// below **464**. At 44 the reservation is 3 × (44 + 8) = 156 and the
    /// well survives from **404**. That gives three regimes, all pinned
    /// below:
    ///
    ///   - `≥ 464` — the well already fits, so nothing changes: **64**.
    ///   - `404 ..< 464` — the comfort height is the ONLY thing costing the
    ///     question its place, so the row steps to **44** and the well
    ///     draws. The strip's own 419 pt budget lives here.
    ///   - `< 404` — stepping would not save the well either, so the recipe
    ///     is left exactly as it was: **64** (or 44 already, once
    ///     `bandSqueezed` has taken it there on its own account below 358).
    ///
    /// Three buttons never reaches the reduced branch at any real band —
    /// 2 × 72 = 144 leaves the well room at every height that is not
    /// already squeezed — which is why the table above this one still reads
    /// 144 unchanged.
    @Test("bandStackedDecisionButtonHeight worked table — the question outranks the buttons' comfort height, and only where that changes the answer",
          arguments: [
            (true, 4, 470.0, 64.0, "the well already fits at 64 — untouched"),
            (true, 4, 464.0, 64.0, "exactly at the well's own boundary — untouched"),
            (true, 4, 463.0, 44.0, "one point under it — steps, and the well is saved"),
            (true, 4, 419.0, 44.0, "the strip's own budget — steps, and the well is saved"),
            (true, 4, 404.0, 44.0, "the lowest height stepping still saves the well"),
            (true, 4, 403.0, 64.0, "stepping would not save it either — recipe left alone"),
            (true, 4, 300.0, 44.0, "already squeezed — 44 on bandSqueezed's own account"),
            (false, 4, 419.0, 64.0, "not stacked — a horizontal row costs one button's height"),
            (true, 2, 419.0, 64.0, "two buttons — stepping buys nothing, so it is not taken"),
          ])
    func bandStackedDecisionButtonHeightWorkedTable(_ stacks: Bool, _ buttonCount: Int, _ usableHeight: Double,
                                                    _ expected: Double, _ what: String) {
        let got = OverviewLayout.bandStackedDecisionButtonHeight(
            usableHeight: usableHeight, stacks: stacks, buttonCount: buttonCount)
        #expect(got == expected,
                Comment(rawValue: "\(what) (stacks \(stacks), \(buttonCount) buttons, \(usableHeight) pt usable) "
                        + "— got \(got), expected \(expected)"))
    }

    /// The point of the step, stated as the thing the user actually
    /// reported: four options at a real desktop band used to render with no
    /// question above them at all.
    @Test("four stacked options keep their subject well at a band height where the comfort height alone would have evicted it")
    func fourStackedOptionsKeepTheirQuestion() {
        let usableHeight = 419.0
        let atComfort = OverviewLayout.bandDecisionRowExtraHeight(
            stacks: true, buttonCount: 4, buttonHeight: OverviewLayout.bandDecisionButtonHeight(usableHeight: usableHeight))
        #expect(!OverviewLayout.bandWellFits(usableHeight: usableHeight, stackedRowExtra: atComfort),
                "the comfort height no longer evicts the well, so this test is no longer about anything")

        let chosen = OverviewLayout.bandStackedDecisionButtonHeight(
            usableHeight: usableHeight, stacks: true, buttonCount: 4)
        let reserved = OverviewLayout.bandDecisionRowExtraHeight(
            stacks: true, buttonCount: 4, buttonHeight: chosen)
        #expect(OverviewLayout.bandWellFits(usableHeight: usableHeight, stackedRowExtra: reserved),
                "four options still render with no question above them")
        #expect(chosen >= TouchTarget.minimum,
                "the step went below the HIG's own general touch floor")
    }

    /// **`bandWellFits(usableHeight:stackedRowExtra:)`'s own boundary —
    /// the SAME `>=` gate `bandWellHeight`'s own `max(...)` floor takes,
    /// checked directly rather than only through the flex.** At
    /// `stackedRowExtra: 0` this is exactly `bandWellHeightFlexesWithUsableHeight`'s
    /// own floor threshold (`bandFixedChrome + bandWellMinimum`, 248),
    /// restated as a boolean; a non-zero `stackedRowExtra` shifts the SAME
    /// boundary upward by exactly its own value, since it is subtracted
    /// alongside `bandFixedChrome` in the identical arithmetic.
    @Test("bandWellFits answers true at its own boundary, false half a point under it",
          arguments: [
            (248.0, 0.0, true, "exactly at the floor's own threshold, no stacked row"),
            (247.5, 0.0, false, "half a point under, no stacked row"),
            (348.0, 100.0, true, "exactly at the threshold, shifted by 100 pt of stacked row"),
            (347.5, 100.0, false, "half a point under the shifted threshold"),
          ])
    func bandWellFitsBoundary(_ usableHeight: Double, _ stackedRowExtra: Double, _ expected: Bool, _ what: String) {
        let got = OverviewLayout.bandWellFits(usableHeight: usableHeight, stackedRowExtra: stackedRowExtra)
        #expect(got == expected,
                Comment(rawValue: "\(what) (\(usableHeight) pt usable, \(stackedRowExtra) pt stacked row extra) "
                        + "— got \(got), expected \(expected)"))
    }

    /// **`bandWellHeight(usableHeight:stackedRowExtra:)`'s own default —
    /// `stackedRowExtra: 0` reproduces the EXACT pre-existing formula, so
    /// every caller that has nothing to say about a stacked row (every
    /// caller before this parameter existed) is unaffected.** Restates
    /// `bandWellHeightFlexesWithUsableHeight`'s own two strip samples at
    /// the explicit default, and adds the non-zero case: 100 pt of stacked
    /// row extra comes straight off the SAME budget the well would
    /// otherwise have flexed to.
    @Test("bandWellHeight's default stackedRowExtra reproduces the un-narrowed flex; a non-zero one subtracts directly")
    func bandWellHeightStackedRowExtraSubtractsDirectly() {
        #expect(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight)
                == OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight, stackedRowExtra: 0),
                "the default should reproduce the explicit stackedRowExtra: 0 call exactly")
        #expect(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight, stackedRowExtra: 100) == 87,
                Comment(rawValue: "419 − 232 (bandFixedChrome) − 100 = 87 — got "
                        + "\(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight, stackedRowExtra: 100))"))
        #expect(OverviewLayout.bandWellHeight(usableHeight: 300, stackedRowExtra: 1000) == OverviewLayout.bandWellMinimum,
                "an extra so large it would go negative should still floor at bandWellMinimum, never below it")
    }

    /// **`bandControlsShown(bandWidth:usableHeight:)`'s own height-fold
    /// boundary — `bandControlsFoldedMinimum` (244) via `usableHeight −
    /// bandHeaderHeight`, inclusive at the boundary.** `bandWidth` held
    /// fixed at a value comfortably `.withControls` by width (the strip's
    /// own 1588), so this isolates the HEIGHT term specifically —
    /// `controlsFoldsByWidthToo` below is the width term's own companion.
    @Test("bandControlsShown folds by height at bandControlsFoldedMinimum, inclusive",
          arguments: [
            (244.0 + 48.0, true, "exactly at the boundary — Controls still shows"),
            (244.0 + 48.0 - 0.5, false, "half a point under — height-folded"),
            (243.0 + 48.0, false, "the mission's own worked boundary sample"),
            (244.0 + 48.0, true, "the mission's own worked boundary sample, the other side"),
          ])
    func controlsFoldsByHeightAtItsOwnBoundary(_ usableHeight: Double, _ expected: Bool, _ what: String) {
        let wideBandWidth = 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        #expect(OverviewLayout.bandZones(for: wideBandWidth) == .withControls,
                "the fixture's own premise: the strip's own band width should be .withControls")
        #expect(OverviewLayout.bandControlsShown(bandWidth: wideBandWidth, usableHeight: usableHeight) == expected,
                Comment(rawValue: "\(what) (\(usableHeight) pt usable) — got "
                        + "\(OverviewLayout.bandControlsShown(bandWidth: wideBandWidth, usableHeight: usableHeight)), "
                        + "expected \(expected)"))
    }

    /// **`bandControlsShown`'s own WIDTH term — unchanged, `bandZones(for:)`
    /// alone, held here so the two terms are each pinned by their own
    /// dedicated test rather than only ever exercised together.**
    @Test("bandControlsShown still folds by width too, at a comfortably tall height")
    func controlsFoldsByWidthToo() {
        let narrowBandWidth = 700.0
        #expect(OverviewLayout.bandZones(for: narrowBandWidth) == .actOnly,
                "the fixture's own premise: this band width should be .actOnly")
        #expect(!OverviewLayout.bandControlsShown(bandWidth: narrowBandWidth, usableHeight: 900),
                "a narrow band should fold Controls by width even at a generous height")
    }

    /// **RETIRED — `actionsColumnFoldsByHeightPerActionCount` used
    /// to live here, pinning the retired three-argument `bandActionsColumn
    /// (bandWidth:actionCount:usableHeight:)`'s own height term: the
    /// floor-case natural height against `usableHeight − bandHeaderHeight`,
    /// at 1/3/5/10 actions, and — a found property, not an assumed one —
    /// the fact that at 1 and 3 actions Controls' own fold bound FIRST,
    /// since that function required `bandControlsShown` outright before it
    /// would show the column at all.** The mandatory-column redesign
    /// retires that requirement along with the function: `bandZonePlan
    /// (bandWidth:actionCount:usableHeight:)` never lets the actions
    /// column wait on Controls, so "the column folds by height at the
    /// STRICTER of its own floor case and Controls' own fold" is no longer
    /// a fact this file has a code path left to produce.
    /// `bandZonePlanRowsBoundaryTable`, below, pins the equivalent height
    /// boundary against the surviving function — `usable 357 → 5 rows, 305
    /// → 4, 253 → 3, 201 → 2, 149 → 1`, the identical floor-case arithmetic
    /// this retired test once worked by hand, now read directly off
    /// `rows` rather than a nil/non-nil presence check.

    /// **`bandQuickActionsChrome` is DERIVED from the measured natural
    /// height, not summed independently — two DIFFERENT staleness risks,
    /// caught by two DIFFERENT assertions, neither one redundant.** Gate
    /// review's own MINOR: an earlier draft of this comment claimed the
    /// first assertion catches "`bandQuickActionsNaturalHeight` changed
    /// with `bandQuickActionsChrome` left stale" — impossible, since
    /// `bandQuickActionsChrome` is a COMPUTED property built FROM
    /// `bandQuickActionsNaturalHeight` (`OverviewLayout.swift`'s own
    /// declaration: `bandQuickActionsNaturalHeight − Double
    /// (bandActionsRowCap) × TouchTarget.minimum − …`), so it recomputes
    /// automatically the instant its input moves — there is no code path
    /// where the two could disagree with each other.
    ///
    /// What the two assertions actually catch, correctly stated: the
    /// FIRST — `bandQuickActionsChrome == bandQuickActionsNaturalHeight −
    /// 5 × 44 − 4 × 8` — restates the formula's own TERMS as independent
    /// literals (5 for `bandActionsRowCap`, 44 for `TouchTarget.minimum`,
    /// 8 for `actionGridSpacing`), so a drift in any ONE of those three
    /// real constants (the row cap changes, the touch floor changes, the
    /// grid spacing changes) shows up here even though the production
    /// formula would still compute internally consistently with itself.
    /// The SECOND — `== 49`, the literal twin — is what actually catches a
    /// move in `bandQuickActionsNaturalHeight` itself: since
    /// `bandQuickActionsChrome` recomputes automatically when that moves,
    /// watching the LITERAL 49 (which does not recompute) is the only way
    /// to notice. Together: the first assertion holds the formula's own
    /// TERMS to independent literals, the same two-tests-per-fact
    /// discipline `bandZoneConstantsHoldTheirLiteralValues` above already
    /// holds every other derived threshold to; the second holds the
    /// RESULT to one.
    @Test("bandQuickActionsChrome is derived from the measured natural height, not summed independently")
    func bandQuickActionsChromeIsDerivedFromTheNaturalHeight() {
        #expect(OverviewLayout.bandQuickActionsChrome == OverviewLayout.bandQuickActionsNaturalHeight - 5 * 44 - 4 * 8,
                Comment(rawValue: "301 − 220 − 32 should hold as the derivation's own TERMS (bandActionsRowCap, "
                        + "TouchTarget.minimum, actionGridSpacing restated as literals), not merely as an "
                        + "answer — got \(OverviewLayout.bandQuickActionsChrome)"))
        #expect(OverviewLayout.bandQuickActionsChrome == 49,
                Comment(rawValue: "the literal twin — the one assertion that actually catches "
                        + "bandQuickActionsNaturalHeight moving, since bandQuickActionsChrome recomputes "
                        + "automatically alongside it — got \(OverviewLayout.bandQuickActionsChrome)"))
    }

    /// **`bandActionsRowHeight(columnBudget:rowCount:)`'s own worked table
    /// — the strip's two real budgets and the routing floor's own tightest,
    /// at the column's LEFT sub-column (the taller of the two whenever a
    /// set spills into a second), plus both clamp ends and every degenerate
    /// input the function's own doc comment promises a direct floor for.**
    /// `bandActionsRowHeight`'s own doc comment carries the full derivation
    /// this table exercises — worth restating here as the function's own
    /// live arbiter rather than trusting the doc comment's arithmetic
    /// unchecked.
    @Test("bandActionsRowHeight worked table — rows flex between the general floor and the pill's own full height",
          arguments: [
            (371.0, 1, 64.0, "banner down, one row — plenty of room, clamps at the ceiling (actionPillHeight)"),
            (371.0, 3, 64.0, "banner down, three rows — still clamps at the ceiling"),
            (371.0, 5, 56.0, "banner down, five rows — the left sub-column's own tightest packed case"),
            (311.0, 3, 64.0, "banner up, three rows — still clears the ceiling"),
            (311.0, 5, 44.0, "banner up, five rows — down at the general floor"),
            (310.0, 5, 44.0, "bandMinimumHeight's own columnBudget, five rows — the floor itself, not one "
                + "point above it: the natural height clears this exact budget by exactly one point, leaving "
                + "no slack to hand a row"),
            (0.0, 5, 44.0, "a zero column budget answers the floor directly rather than through the arithmetic"),
            (-40.0, 5, 44.0, "a negative column budget — DetailBand.columnsHeightBudget's own max(0, …) floor "
                + "should prevent this in production, but the function still answers the floor rather than a "
                + "negative or nonsensical row height"),
            (1000.0, 0, 44.0, "zero rows — nothing to divide by, answers the floor directly rather than "
                + "dividing by zero"),
          ])
    func bandActionsRowHeightWorkedTable(_ columnBudget: Double, _ rowCount: Int, _ expected: Double,
                                         _ what: String) {
        let got = OverviewLayout.bandActionsRowHeight(columnBudget: columnBudget, rowCount: rowCount)
        #expect(got == expected,
                Comment(rawValue: "\(what) — columnBudget \(columnBudget), rowCount \(rowCount) got \(got), "
                        + "expected \(expected)"))
    }

    // ------------------------------------------------------- the fleet rows

    /// **`fleetRows(usableHeight:banded:)`'s own boundary — the strip's two
    /// real budgets on either side of it, the exact boundary itself, and
    /// `banded` overriding both.** 419 (banner down) and 359 (banner up)
    /// are `fleetRows`'s own doc comment restated as literals, the same
    /// discipline `bandWellHeightFlexesWithUsableHeight` above holds itself
    /// to rather than recomputing what it is checking. **All land on two
    /// rows now — the floor has moved twice: 184 (3-line card) → 154
    /// (1-line card) → 113 (the promptless card,
    /// `fleetRowMinimumHeight`'s own doc comment carries the full
    /// history).** 371 is a LIVE observation, not a constant: the desktop
    /// window the deck was actually running in when the 154 floor shipped
    /// (AX-measured 1511 × 432; 432 − 40 titlebar − 21
    /// status line = 371) — kept as a data point because it is the
    /// everyday hand-sized case, and it clears the widened floor with room
    /// to spare. 262 is the NEW exact boundary (`fleetRows`'s own doc
    /// comment: 2×113+24+12, a 323 pt window); inclusive, the same
    /// boundary discipline every other threshold in this file holds to,
    /// and half a point under it falls back to one row.
    @Test("fleetRows stacks two rows once usableHeight clears the boundary, one below it or while banded",
          arguments: [
            (419.0, false, 2, "the strip, banner down"),
            (359.0, false, 2, "the strip, banner up"),
            (371.0, false, 2, "a desktop-sized window, measured live (432 pt tall) when the 154 floor shipped"),
            (262.0, false, 2, "the exact boundary — inclusive"),
            (261.9, false, 1, "half a point under the boundary"),
            (419.0, true, 1, "banded collapses to the header pose regardless of height"),
          ])
    func fleetRowsStacksAtTheBoundary(_ usableHeight: Double, _ banded: Bool, _ expected: Int, _ what: String) {
        #expect(OverviewLayout.fleetRows(usableHeight: usableHeight, banded: banded) == expected,
                Comment(rawValue: "\(what) (\(usableHeight) pt, banded: \(banded)) got "
                        + "\(OverviewLayout.fleetRows(usableHeight: usableHeight, banded: banded)) rows, "
                        + "expected \(expected)"))
    }

    /// **`promptLineLimit(usableHeight:rows:)`'s own table — the flex at
    /// two rows, boundary-inclusive on both sides, the promptless 0 tier
    /// below the 1-line threshold, and the unconditional 8 at one row.**
    /// 419 → share 191.5, at or past the 3-line cost (184) → 3. 404 is the
    /// share-184 boundary itself (`(404−24−12)/2 = 184` exactly) → still
    /// 3; half a point under, 403.9, drops to 2 — share 183.95, under 184.
    /// 374 is the share-169 boundary (2-line cost) → 2; half a point
    /// under, 373.9, drops to 1. 359 (the banner-up strip, share 161.5)
    /// and 344 (the exact OLD `fleetRows` boundary, share exactly
    /// `fleetRowMinimumHeight + fleetPromptBlockCost` = 154) both land on
    /// 1 — the 1-line threshold buys only the first line, nothing past
    /// it. 371 (the everyday desktop window, share 167.5) lands on 1 too.
    /// Below 154: 343.9 (share 153.95, a twentieth of a point under the
    /// threshold) drops to 0 — the promptless tier — and 262 (the NEW
    /// exact `fleetRows` boundary, share exactly `fleetRowMinimumHeight` =
    /// 113) lands on 0 as well, since 113 is the promptless floor itself,
    /// nowhere near affording the block. `rows < 2` ignores `usableHeight`
    /// entirely and always answers 8 — the one-row flex
    /// `fleetRowMinimumHeight`'s own doc comment derives against the
    /// banner-up strip's own tightest single-row budget.
    @Test("promptLineLimit flexes with the row's own share of usableHeight, and ignores it below two rows",
          arguments: [
            (419.0, 2, 3), (404.0, 2, 3), (403.9, 2, 2),
            (374.0, 2, 2), (373.9, 2, 1),
            (359.0, 2, 1), (344.0, 2, 1), (371.0, 2, 1),
            (343.9, 2, 0), (262.0, 2, 0),
            (419.0, 1, 8),
          ])
    func promptLineLimitFlexesWithShare(_ usableHeight: Double, _ rows: Int, _ expected: Int) {
        #expect(OverviewLayout.promptLineLimit(usableHeight: usableHeight, rows: rows) == expected,
                Comment(rawValue: "\(usableHeight) pt at \(rows) row(s) got a prompt line limit of "
                        + "\(OverviewLayout.promptLineLimit(usableHeight: usableHeight, rows: rows)), "
                        + "expected \(expected)"))
    }

    /// **`promptLineLimit(usableHeight:rows:banded:)`'s own `banded: true`
    /// table — the fleet's own half of the deadlock-breaker, the worked
    /// ladder that function's own doc comment carries as prose, pinned
    /// here directly.** 149 is BELOW the corrected reachable floor (usable
    /// 189, banner up — `promptLineLimit`'s own doc comment, `OverviewLayout
    /// .swift`, carries the corrected derivation), kept as a defensive-
    /// depth sample — 0 lines, the promptless tier. 189 itself lands on 1
    /// line (share 165, at or past `oneLine`), so this 0-tier is not a
    /// state production reaches. 358+ all cap at the full 8 — the same
    /// ceiling the unbanded single row has always drawn.
    @Test("promptLineLimit(banded: true) flexes with the whole fleet region, capped at 8, not 3",
          arguments: [
            (149.0, 0), (209.0, 3), (262.0, 6), (344.0, 8), (358.0, 8), (419.0, 8),
          ])
    func promptLineLimitFlexesBandedWithShare(_ usableHeight: Double, _ expected: Int) {
        let got = OverviewLayout.promptLineLimit(usableHeight: usableHeight, rows: 1, banded: true)
        #expect(got == expected,
                Comment(rawValue: "\(usableHeight) pt banded got a prompt line limit of \(got), expected \(expected)"))
        // The unbanded one-row case at the SAME heights must stay the
        // flat 8 it always has — `anEightLinePromptCardFitsTheTightestSingleRowCard`
        // (`RenderSweepTests`) is the render-level arbiter for that
        // constant; this pins the pure function's own side of it.
        #expect(OverviewLayout.promptLineLimit(usableHeight: usableHeight, rows: 1, banded: false) == 8,
                Comment(rawValue: "\(usableHeight) pt unbanded, rows: 1 should stay the flat 8 — "
                        + "banded: true must not have changed the unbanded branch"))
    }

    /// **`fleetRowShare(usableHeight:)`'s own two pinned readings —
    /// `fleetRows` and `promptLineLimit` both above read this rather than
    /// their own copy of the arithmetic, so pinning it here catches either
    /// reader drifting from it independently of catching them drift from
    /// each other.**
    @Test("fleetRowShare halves usableHeight after the outer padding and row spacing")
    func fleetRowShareMatchesItsReaders() {
        let atBannerDown = OverviewLayout.fleetRowShare(usableHeight: 419.0) == 191.5
        #expect(atBannerDown, Comment(rawValue: "fleetRowShare(419) was "
                + "\(OverviewLayout.fleetRowShare(usableHeight: 419.0)), expected 191.5"))
        let atBoundary = OverviewLayout.fleetRowShare(usableHeight: 344.0) == 154.0
        #expect(atBoundary, Comment(rawValue: "fleetRowShare(344) was "
                + "\(OverviewLayout.fleetRowShare(usableHeight: 344.0)), expected 154.0"))
    }

    // -------------------------------------------------------- the action grid
    //
    // Q3's pill retune: `actionPillLayout(widths:chipWidths:barWidth:
    // maxRows:)` replaces the fixed-cell grid's four functions
    // (`actionColumns(width:)`, `actionRows(count:columns:)`,
    // `visibleActionSlots(count:columns:maxRows:)`, and the retired
    // `actionCellWidth`/`actionCellHeight` constants they read) with one
    // pure function over MEASURED pill widths rather than a shared
    // constant. `QuickActionBar`, this section's own subject, is a
    // namespace of pill recipes now, not a view — the Quick Actions column
    // (`bandZonePlanAtEveryRealGeometry` and its neighbours, below) is what
    // the band itself reads; `maxActionRows(usableHeight:)`, `actionBarHeight
    // (rows:)`'s own row-cost pair with `bandFixedChrome(actionRows:)`, and
    // `bandFixedChromeBase` all retired along with the pinned bar they
    // existed to budget — `actionBarHeight` itself, and its own
    // `actionBarVerticalPadding` constant, retired a second time, later,
    // when the inspector's own site (`actionBarHeight`'s last production
    // caller) retired too (`OverviewLayout.swift`'s own doc comment on the
    // action-grid section states both retirements in full).

    /// The pill world's own flat constants, held to literal values the
    /// same MINOR 7(i) discipline `bandZoneConstantsHoldTheirLiteralValues`
    /// above already applies to the zone thresholds — a mutation to any one
    /// of them, alone, has to fail here independently of failing whatever
    /// reads it.
    @Test("the action grid's own constants hold their stated values")
    func actionGridConstantsHoldTheirLiteralValues() {
        #expect(OverviewLayout.actionPillHeight == 64,
                Comment(rawValue: "candidate G's own measured height — got \(OverviewLayout.actionPillHeight)"))
        #expect(OverviewLayout.actionPillMinWidth == 64,
                Comment(rawValue: "\"Go\" lands exactly here — got \(OverviewLayout.actionPillMinWidth)"))
        #expect(OverviewLayout.actionPillMaxWidth == 320,
                Comment(rawValue: "the runaway-title cap — got \(OverviewLayout.actionPillMaxWidth)"))
        #expect(OverviewLayout.actionGridSpacing == 8,
                "QuickActionsColumn.body's own HStack(alignment: .top, spacing:) between its two sub-columns")
        #expect(OverviewLayout.bandControlsNaturalHeight == 279,
                Comment(rawValue: "controlsZone(for:budget:)'s own full natural content — re-measured for "
                        + "the close-out's own 12 → 8 pt row-spacing retune (was 295; "
                        + "bandControlsNaturalHeight's own doc comment carries the fresh measurement) — got "
                        + "\(OverviewLayout.bandControlsNaturalHeight)"))
        #expect(OverviewLayout.bandControlsFoldedMinimum == 244,
                Comment(rawValue: "the same column, footnote folded — re-measured for the SAME retune (was "
                        + "256) — got \(OverviewLayout.bandControlsFoldedMinimum)"))
        #expect(OverviewLayout.bandColumnsVerticalPadding == 4,
                "DetailBand.columns(for:)'s own top-and-bottom padding, restated once here")
    }

    /// **All pills fit within `maxRows` — the common case, one row, no
    /// chip.** Three pills small enough together (166 pt) to sit well
    /// under a 200 pt bar, at `maxRows: 2` (never binds) — the baseline
    /// every other test below deviates from one dimension at a time.
    @Test("actionPillLayout: every pill fits, one row, no chip")
    func actionPillLayoutAllFitsNoChip() {
        let layout = OverviewLayout.actionPillLayout(widths: [50, 60, 40], chipWidths: [],
                                                      barWidth: 200, maxRows: 2)
        #expect(layout.rows == [[.action(0), .action(1), .action(2)]], Comment(rawValue: "got \(layout.rows)"))
        #expect(layout.hiddenCount == 0)
    }

    /// **The greedy row's own boundary, exact to the point — a pill that
    /// fits AT `barWidth` joins, one point over wraps.** Two 100 pt pills:
    /// `100 + actionGridSpacing (8) + 100 = 208` is the exact width one
    /// row needs. At 208 both join; at 207 the second wraps to its own row.
    @Test("actionPillLayout: a pill joins its row at exactly barWidth, wraps one point over",
          arguments: [(208.0, 1, "exactly enough — one row"),
                      (207.0, 2, "one point short — wraps to a second row")])
    func actionPillLayoutRowBoundaryIsExact(_ barWidth: Double, _ expectedRowCount: Int, _ what: String) {
        let layout = OverviewLayout.actionPillLayout(widths: [100, 100], chipWidths: [],
                                                      barWidth: barWidth, maxRows: nil)
        #expect(layout.rows.count == expectedRowCount,
                Comment(rawValue: "\(what) (\(barWidth) pt) got \(layout.rows.count) row(s)"))
        #expect(layout.hiddenCount == 0, "maxRows: nil never hides anything")
    }

    /// **`maxRows: nil` — the inspector's own unbounded case.** However
    /// little room each pill leaves the next (no two of these 100 pt
    /// pills fit together in a 50 pt bar, so each stands alone), every
    /// action is still visible and there is no chip — the sidebar it sits
    /// in scrolls past however many rows that draws.
    @Test("actionPillLayout: maxRows nil never hides, however many rows it takes")
    func actionPillLayoutUncappedNeverHides() {
        let layout = OverviewLayout.actionPillLayout(widths: [100, 100, 100], chipWidths: [],
                                                      barWidth: 50, maxRows: nil)
        #expect(layout.rows == [[.action(0)], [.action(1)], [.action(2)]], Comment(rawValue: "got \(layout.rows)"))
        #expect(layout.hiddenCount == 0)
    }

    /// Empty `widths` answers the empty layout — nothing to lay out, the
    /// same "empty is not degenerate" answer the retired `actionRows
    /// (count: 0, columns:)` used to give explicitly.
    @Test("actionPillLayout: an empty action set lays out to nothing")
    func actionPillLayoutEmptyWidths() {
        let layout = OverviewLayout.actionPillLayout(widths: [], chipWidths: [], barWidth: 200, maxRows: 2)
        #expect(layout.rows.isEmpty, Comment(rawValue: "got \(layout.rows)"))
        #expect(layout.hiddenCount == 0)
    }

    /// **A transient zero `barWidth` — the self-measuring seam's own state
    /// before the first `onGeometryChange` firing — must not crash or
    /// loop.** The "first cell in a row always joins" floor answers it:
    /// one pill per row, every row.
    @Test("actionPillLayout: a zero barWidth places one pill per row rather than trapping")
    func actionPillLayoutZeroBarWidthNeverTraps() {
        let layout = OverviewLayout.actionPillLayout(widths: [50, 50, 50], chipWidths: [],
                                                      barWidth: 0, maxRows: nil)
        #expect(layout.rows == [[.action(0)], [.action(1)], [.action(2)]], Comment(rawValue: "got \(layout.rows)"))
        #expect(layout.hiddenCount == 0)
    }

    /// **`maxRows == 0` is its own case, not the old floor-at-one.** The
    /// bar YIELDS entirely: `(rows: [], hiddenCount: widths.count)`, no
    /// chip either. The old clamp floored every non-positive `maxRows` at
    /// 1, silently granting a starved row a caller explicitly could not
    /// afford — a live bug the retired `maxActionRows(usableHeight:)` used
    /// to hit on the strip's own banner-up budget, before the Quick
    /// Actions column retired the function along with the pinned bar it
    /// budgeted; the fix answers the honest "nothing" instead, short-
    /// circuiting before it ever reads `widths`/`chipWidths` for a fit —
    /// the specific widths below do not matter for this test, only that
    /// they never get consulted.
    @Test("actionPillLayout: maxRows 0 yields the whole bar, hiding every action with no chip")
    func actionPillLayoutZeroMaxRowsYieldsEntirely() {
        let layout = OverviewLayout.actionPillLayout(widths: [30, 30, 30], chipWidths: [0, 999, 999],
                                                      barWidth: 40, maxRows: 0)
        #expect(layout.rows.isEmpty, Comment(rawValue: "got \(layout.rows)"))
        #expect(layout.hiddenCount == 3, Comment(rawValue: "got \(layout.hiddenCount)"))
    }

    /// `maxRows` is clamped to `>= 0` before anything else runs — a caller
    /// that passes a NEGATIVE row cap gets exactly the same full-yield
    /// answer `maxRows: 0` does, never a degenerate negative-row layout.
    @Test("actionPillLayout: a negative maxRows clamps to the same full yield maxRows 0 gives",
          arguments: [-1, -5, -100])
    func actionPillLayoutClampsNegativeMaxRowsToZero(_ maxRows: Int) {
        let clamped = OverviewLayout.actionPillLayout(widths: [30, 30, 30], chipWidths: [0, 999, 999],
                                                       barWidth: 40, maxRows: maxRows)
        let explicit = OverviewLayout.actionPillLayout(widths: [30, 30, 30], chipWidths: [0, 999, 999],
                                                        barWidth: 40, maxRows: 0)
        #expect(clamped == explicit,
                Comment(rawValue: "maxRows: \(maxRows) produced \(clamped), expected the same full-yield layout "
                        + "maxRows: 0 does (\(explicit))"))
        #expect(clamped.rows.isEmpty, Comment(rawValue: "got \(clamped.rows)"))
        #expect(clamped.hiddenCount == 3)
    }

    /// **The overflow fixed point — the chip's own width can force hiding
    /// ONE MORE action than the previous guess, so the scan must check
    /// every step rather than assume the fit only improves as more hide.**
    /// Four 20 pt pills in a 100 pt, one-row bar: hiding 1 needs a 30 pt
    /// chip that still does not fit beside the other three (`20×3 + 8×2 +
    /// 30 = 114 pt > 100 pt`); hiding 2 needs a WIDER 50 pt chip
    /// (`chipWidths` deliberately non-monotonic) that fits even less
    /// (`20×2 + 8 + 50 = 106 pt > 100 pt`); only hiding 3 — down to a 10 pt
    /// chip — actually fits (`20 + 8 + 10 = 38 pt`), and only a full
    /// downward scan finds that: assuming "hiding more only ever helps"
    /// would have kept re-trying a wider chip against fewer pills and never
    /// noticed the width could grow past what an EARLIER, less-hidden guess
    /// already failed at.
    @Test("actionPillLayout: the scan settles at the true fixed point, not the first guess")
    func actionPillLayoutSettlesAtTheOverflowFixedPoint() {
        let layout = OverviewLayout.actionPillLayout(widths: [20, 20, 20, 20], chipWidths: [0, 30, 50, 10],
                                                      barWidth: 100, maxRows: 1)
        #expect(layout.hiddenCount == 3,
                Comment(rawValue: "got hiddenCount \(layout.hiddenCount), rows \(layout.rows)"))
        #expect(layout.rows == [[.action(0), .chip]], Comment(rawValue: "got \(layout.rows)"))
    }

    /// **The chip is placed by the SAME greedy rule as a pill — it may
    /// wrap to its own row rather than trailing onto the last one with
    /// room.** Five 30 pt pills in a 100 pt bar capped at 2 rows: hiding
    /// down to 2 visible actions leaves them sharing one row (`30 + 8 + 30
    /// = 68 pt`) with no room left for a 90 pt chip beside them (`68 + 8 +
    /// 90 = 166 pt > 100 pt`), so the chip starts a second row of its own
    /// — two rows total, within the cap.
    @Test("actionPillLayout: the chip wraps to its own row when it does not fit beside the visible pills")
    func actionPillLayoutChipWrapsToItsOwnRow() {
        let layout = OverviewLayout.actionPillLayout(widths: [30, 30, 30, 30, 30], chipWidths: [0, 90, 90, 90],
                                                      barWidth: 100, maxRows: 2)
        #expect(layout.hiddenCount == 3,
                Comment(rawValue: "got hiddenCount \(layout.hiddenCount), rows \(layout.rows)"))
        #expect(layout.rows == [[.action(0), .action(1)], [.chip]], Comment(rawValue: "got \(layout.rows)"))
    }

    /// **The degenerate capacity — a bar so narrow even ONE pill's own
    /// width leaves no room for anything else, real action or chip alike.**
    /// Three 200 pt pills in a 50 pt bar, capped at 1 row: every visible
    /// count from 2 down to 1 still needs a second row (a lone 200 pt pill
    /// already exceeds the bar on its own), so only hiding all three — the
    /// chip alone, the bar's one cell — fits. The chip's own width (1000
    /// pt, deliberately absurd) never matters here: the "first cell in a
    /// row always joins" floor places it regardless of how wide it is,
    /// because it is alone.
    @Test("actionPillLayout: the degenerate one-cell capacity hides every action behind the chip alone")
    func actionPillLayoutDegenerateCapacityIsChipOnly() {
        let layout = OverviewLayout.actionPillLayout(widths: [200, 200, 200], chipWidths: [0, 1000, 1000, 1000],
                                                      barWidth: 50, maxRows: 1)
        #expect(layout.rows == [[.chip]], Comment(rawValue: "got \(layout.rows)"))
        #expect(layout.hiddenCount == 3)
    }

    /// **An empty `chipWidths` — a caller that measured no chip widths at
    /// all — falls back to `actionPillMinWidth` (64) exactly, not merely
    /// "some safe default."** Two 90 pt pills: together they need 188 pt,
    /// too wide for either bar below; one pill plus a 64 pt fallback chip
    /// needs exactly 162 pt (`90 + 8 + 64`). At 162 pt of bar the chip
    /// joins — the same inclusive-boundary exactness
    /// `actionPillLayoutRowBoundaryIsExact` holds a real pill to.
    @Test("actionPillLayout: an empty chipWidths falls back to actionPillMinWidth exactly — joins at the boundary")
    func actionPillLayoutEmptyChipWidthsJoinsAtTheFloorBoundary() {
        let layout = OverviewLayout.actionPillLayout(widths: [90, 90], chipWidths: [], barWidth: 162, maxRows: 1)
        #expect(layout.hiddenCount == 1, Comment(rawValue: "got \(layout.hiddenCount), rows \(layout.rows)"))
        #expect(layout.rows == [[.action(0), .chip]], Comment(rawValue: "got \(layout.rows)"))
    }

    /// `actionPillLayoutEmptyChipWidthsJoinsAtTheFloorBoundary`'s own twin,
    /// one point narrower: the 64 pt fallback chip no longer joins, and
    /// wraps alone — proof the boundary sits exactly at 64, not some other
    /// number that would move it either direction.
    @Test("actionPillLayout: an empty chipWidths falls back to actionPillMinWidth exactly — wraps one point narrower")
    func actionPillLayoutEmptyChipWidthsWrapsJustBelowTheFloorBoundary() {
        let layout = OverviewLayout.actionPillLayout(widths: [90, 90], chipWidths: [], barWidth: 161, maxRows: 1)
        #expect(layout.hiddenCount == 2, Comment(rawValue: "got \(layout.hiddenCount), rows \(layout.rows)"))
        #expect(layout.rows == [[.chip]], Comment(rawValue: "got \(layout.rows)"))
    }

    /// **A `chipWidths` shorter than the action set could ever hide falls
    /// back to its own LAST entry, not straight to `actionPillMinWidth` —
    /// a caller's under-provisioning degrades to a slightly mis-sized
    /// chip, never a silent jump to a default that ignores what WAS
    /// measured.** Three 50 pt pills, `chipWidths: [0, 20]` (only
    /// hiding-1 measured); the scan reaches hidden-2 (index 2, out of
    /// range) and reads `chipWidths[1]` (20) again rather than 64 — a lone
    /// visible pill plus a 20 pt chip fits a 100 pt bar (`50 + 8 + 20 =
    /// 78`) where a 64 pt fallback would NOT have (`50 + 8 + 64 = 122 >
    /// 100`), so the two fallbacks are DISTINGUISHABLE by their outcome
    /// here, not merely by an implementation detail this test could not
    /// otherwise see.
    @Test("actionPillLayout: an out-of-range chipWidths index falls back to the last measured entry")
    func actionPillLayoutShortChipWidthsFallsBackToTheLastEntry() {
        let layout = OverviewLayout.actionPillLayout(widths: [50, 50, 50], chipWidths: [0, 20],
                                                      barWidth: 100, maxRows: 1)
        #expect(layout.hiddenCount == 2,
                Comment(rawValue: "got hiddenCount \(layout.hiddenCount), rows \(layout.rows) — a fallback to "
                        + "actionPillMinWidth (64) here would have failed to join and hidden a third action"))
        #expect(layout.rows == [[.action(0), .chip]], Comment(rawValue: "got \(layout.rows)"))
    }

    // ------------------------------------------------- the quick actions column
    //
    // `bandActionsColumnWidth(actionCount:)` and both overloads of
    // `bandActionsColumn(bandWidth:actionCount:[usableHeight:])` — the
    // three legacy functions this section used to pin directly
    // (`bandActionsColumnWidthRule`, `bandActionsThresholdsAreInclusive`,
    // `bandActionsColumnFitsTheStripBothShapes`) — since retired;
    // `OverviewLayout.swift`'s own "the quick actions column" section doc
    // comment carries why. `bandZonePlanAtEveryRealGeometry`, in "the
    // band's plan" section below, already holds the surviving function to
    // the identical width/count facts those three used to pin (0/1/5/6/10
    // actions, the strip's own both shapes, the desktop window's own
    // narrower one) — nothing here re-derives them a second time.

    /// **INVERTED — `bandActionsColumnDropsAtTheDesktopWindow`
    /// used to live here, asserting the OPPOSITE of this test's own name:
    /// that the legacy `bandActionsColumn(bandWidth:actionCount:)`
    /// answered nil at the desktop window's own band width (922, under
    /// that function's own 1152 pt single-column threshold), and Controls
    /// alone survived beside the act zone.** The mandatory-column redesign
    /// is built to stop that from happening — the desktop window is
    /// exactly the shape it targets, a real, production-reachable band
    /// width where the OLD rule dropped a useful column rather than
    /// shrinking it. `bandZonePlanAtEveryRealGeometry` already holds this
    /// same geometry (1254×455, 3 and 10 actions both) to its own full
    /// worked answer; this test exists as a focused, named regression
    /// guard for the ONE fact that inverted — the column shows, Controls
    /// folds — easier to find by name than as two rows of a ten-row table.
    ///
    /// **SCOPE, stated honestly: this pins the
    /// CASCADE alone (`bandZonePlan`'s own default `minimumActWidth: 0`),
    /// never `DetailBand.decisionMinimumActWidth`'s own guard, because
    /// `DeckCore` cannot build a `Decision` with real button titles to
    /// feed it (the no-platform-framework rule this whole file lives
    /// under).** `actionCount: 3` here is a bare COUNT, not a real
    /// suggestion-bearing decision — the guard needs the latter to have
    /// anything to compute `minimumActWidth` from at all, so this test's
    /// own "survives" claim is unconditionally true regardless of content,
    /// which the wired, `DeckApp`-side story is NOT: at this SAME band
    /// width, real content wide enough that folding could not reach the
    /// row's own `needed` width leaves the column standing for a
    /// DIFFERENT reason (folding evaluated and found futile, not simply
    /// "the cascade never drops it") — `RenderSweepTests
    /// .theActionsColumnSurvivesAFutileFold` is that live arbiter, and the
    /// content matrix's own "three suggestions" cells (`decisionRowCases`)
    /// hold the guard accountable at real suggestion-bearing content
    /// generally. Both live in `DeckAppTests`, the one place a real
    /// `DetailBand` can be hosted and measured.
    @Test("the actions column survives the desktop window's own band width now — Controls folds instead")
    func theActionsColumnSurvivesAtTheDesktopWindow() {
        let bandWidth = 1254.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        #expect(bandWidth == 922, "the fixture's own premise — got \(bandWidth)")
        let usableHeight = 434.0
        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 3, usableHeight: usableHeight)
        #expect(plan.actions != nil,
                "the actions column should survive at the desktop window's own band width, not drop")
        #expect(plan.actions?.columnWidth == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "got \(String(describing: plan.actions?.columnWidth)) — expected the "
                        + "narrow, single sub-column shape"))
        #expect(!plan.controlsShown,
                "Controls should fold here — freeing its own share is exactly what lets the column survive")
        #expect(OverviewLayout.bandZones(for: bandWidth) == .withControls,
                Comment(rawValue: "the fixture's own premise: bandZones(for:)'s bare WIDTH answer is still "
                        + ".withControls at 922 pt — it is bandZonePlan's own height-aware ladder, not this "
                        + "width-only rule, that folds Controls to make room for the column"))
    }

    /// **`QuickAction.maxOffered` (10) and the column's own 2×5 grid must
    /// agree — one number stated in two files (`QuickAction.maxOffered`'s
    /// own doc comment states why it is an independent literal rather than
    /// a cross-module read), held to the same fact here rather than
    /// trusted to stay in sync by construction.**
    @Test("QuickAction.maxOffered agrees with the actions column's own 2×5 grid")
    func actionsCapAgreesWithTheColumnGrid() {
        #expect(QuickAction.maxOffered == 2 * OverviewLayout.bandActionsRowCap,
                Comment(rawValue: "maxOffered (\(QuickAction.maxOffered)) should be exactly twice "
                        + "bandActionsRowCap (\(OverviewLayout.bandActionsRowCap))"))
    }

    // ---------------------------------------------------------- the band's plan

    /// **`bandZonePlan(bandWidth:actionCount:usableHeight:)`'s own width
    /// cascade, worked at every real geometry this deck composes — 3 and
    /// 10 actions both, so the ladder's own fallback (wide → narrow pair →
    /// squeezed) is exercised at every one of them, not merely asserted
    /// about in prose.** Every row states `contentWidth`/`contentHeight`
    /// rather than `bandWidth`/`usableHeight` directly, and does the SAME
    /// subtraction production does (`bandFleetWidth`/`bandSeamWidth` for
    /// the band; 21 pt of status line and, when noted, 60 pt of connection
    /// banner for usable height — `presentationClearsTheFloorOnTheStrip`'s
    /// own local literals, restated here for the identical reason) — so a
    /// change to either subtraction is caught here too, not only in the
    /// constants' own dedicated tests.
    ///
    /// **RETUNED, the narrow-pair fix — two of ten rows changed shape, not
    /// number.** The narrower desktop window (922) and the shipped default
    /// (948) both sit in `[898, 1136)` — past the narrow pair's own folded
    /// threshold (898) but short of the wide entry's (1136) — so at 10
    /// actions each now takes `bandActionsNarrowColumnWidth`'s own rung
    /// instead of falling to a lone sub-column: `columnWidth` and `actWidth`
    /// are UNCHANGED (230 and 644/670 — the whole point of the identity,
    /// `bandActionsNarrowColumnWidth`'s own doc comment states it in full),
    /// only `subColumns` moves, 1 → 2, doubling capacity for free. The
    /// narrower desktop window now shows all 10 offered actions (was 5 of
    /// 10); the default window, height-limited to 3 rows regardless, now
    /// shows 6 of 10 (was 3 of 10). Every other row is untouched — 3
    /// actions never leaves the single-entry, `actionCount <=
    /// bandActionsRowCap` ladder this fix does not touch, and the strip and
    /// minimum-window rows sit outside `[898, 1136)` entirely (the strip
    /// clears the wide entry's own shown threshold; the minimum window sits
    /// in the untouched squeezed range below 898 — `theSqueezedRangeStillHidesActionsPastFive_knownGap`,
    /// below, is where that second, out-of-scope gap is named).
    @Test("bandZonePlan's own width cascade at every real geometry, 3 and 10 actions both",
          arguments: [
            // contentWidth, contentHeight, bannerUp, actionCount, expectedBandWidth,
            // expectedActWidth, expectedColumnWidth, expectedSubColumns, expectedRows,
            // expectedControlsShown, what
            (1920.0, 440.0, false, 3, 1588.0, 1056.0, 230.0, 1, 5, true,
             "the strip, 3 actions — Controls shown, single sub-column"),
            (1920.0, 440.0, false, 10, 1588.0, 818.0, 468.0, 2, 5, true,
             "the strip, 10 actions — Controls shown, the wide ladder entry"),
            (1254.0, 455.0, false, 3, 922.0, 644.0, 230.0, 1, 5, false,
             "the narrower desktop window, 3 actions — Controls folds so the column can keep 620"),
            (1254.0, 455.0, false, 10, 922.0, 644.0, 230.0, 2, 5, false,
             "the narrower desktop window, 10 actions — the narrow pair now, 10 of 10 shown (was 230×1, 5 of 10, "
             + "before the narrow-pair fix)"),
            (1280.0, 300.0, false, 3, 948.0, 670.0, 230.0, 1, 3, false,
             "the shipped default window, 3 actions — Controls folds by height"),
            (1280.0, 300.0, false, 10, 948.0, 670.0, 230.0, 2, 3, false,
             "the shipped default window, 10 actions — same fold, the narrow pair now, 6 of 10 shown (was 230×1, "
             + "3 of 10, before the narrow-pair fix)"),
            (960.0, 270.0, false, 3, 628.0, 350.0, 230.0, 1, 2, false,
             "the minimum window, 3 actions — the squeezed step, act at its derived floor"),
            (960.0, 270.0, false, 10, 628.0, 350.0, 230.0, 1, 2, false,
             "the minimum window, 10 actions — still squeezed to 230×1, never wide"),
            (960.0, 270.0, true, 3, 628.0, 350.0, 230.0, 1, 1, false,
             "the minimum window with the connection banner up, 3 actions — one row"),
            (960.0, 270.0, true, 10, 628.0, 350.0, 230.0, 1, 1, false,
             "the minimum window with the connection banner up, 10 actions — one row, still 230×1"),
          ])
    func bandZonePlanAtEveryRealGeometry(_ contentWidth: Double, _ contentHeight: Double, _ bannerUp: Bool,
                                         _ actionCount: Int, _ expectedBandWidth: Double, _ expectedActWidth: Double,
                                         _ expectedColumnWidth: Double, _ expectedSubColumns: Int, _ expectedRows: Int,
                                         _ expectedControlsShown: Bool, _ what: String) {
        let statusLine = 21.0
        let bannerHeight = 60.0
        let bandWidth = contentWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        #expect(bandWidth == expectedBandWidth,
                Comment(rawValue: "\(what) — band width got \(bandWidth), expected \(expectedBandWidth)"))
        let usableHeight = contentHeight - statusLine - (bannerUp ? bannerHeight : 0)

        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
        #expect(plan.actWidth == expectedActWidth,
                Comment(rawValue: "\(what) — act width got \(plan.actWidth), expected \(expectedActWidth)"))
        #expect(plan.controlsShown == expectedControlsShown,
                Comment(rawValue: "\(what) — controlsShown got \(plan.controlsShown), expected \(expectedControlsShown)"))
        guard let actions = plan.actions else {
            Issue.record(Comment(rawValue: "\(what) — expected an actions plan, got nil"))
            return
        }
        #expect(actions.columnWidth == expectedColumnWidth,
                Comment(rawValue: "\(what) — columnWidth got \(actions.columnWidth), expected \(expectedColumnWidth)"))
        #expect(actions.subColumns == expectedSubColumns,
                Comment(rawValue: "\(what) — subColumns got \(actions.subColumns), expected \(expectedSubColumns)"))
        #expect(actions.rows == expectedRows,
                Comment(rawValue: "\(what) — rows got \(actions.rows), expected \(expectedRows)"))
    }

    /// **`bandZonePlan`'s own `rows` boundary — 149/201/253/305/357, either
    /// side of each, purely a function of `usableHeight`.** A generous,
    /// fixed `bandWidth` (the strip's own 1588) and a small, fixed
    /// `actionCount` (3, the single-sub-column ladder) hold every other
    /// input still, so this table isolates the HEIGHT term alone —
    /// `bandZonePlan`'s own doc comment confirms the same table against the
    /// existing floor-case arithmetic it generalises; this is the
    /// independent, boundary-by-boundary check of it. `nil` at 148.5 — half
    /// a point under the lowest boundary — is its own claim: `rows`
    /// reaching 0 is the ONE way this plan answers `actions: nil` for a
    /// reason other than `actionCount == 0`.
    @Test("bandZonePlan's own rows boundary, either side of 149/201/253/305/357",
          arguments: [
            (148.5, nil, "half a point under the lowest boundary — rows would be 0, so actions is nil"),
            (149.0, 1, "the lowest boundary itself"),
            (149.5, 1, "half a point over"),
            (200.5, 1, "half a point under the next boundary"),
            (201.0, 2, "the next boundary itself"),
            (201.5, 2, "half a point over"),
            (252.5, 2, "half a point under the next boundary"),
            (253.0, 3, "the next boundary itself"),
            (253.5, 3, "half a point over"),
            (304.5, 3, "half a point under the next boundary"),
            (305.0, 4, "the next boundary itself"),
            (305.5, 4, "half a point over"),
            (356.5, 4, "half a point under the top boundary"),
            (357.0, 5, "the top boundary itself — the row cap"),
            (357.5, 5, "half a point over — still capped at the row cap"),
          ] as [(Double, Int?, String)])
    func bandZonePlanRowsBoundaryTable(_ usableHeight: Double, _ expectedRows: Int?, _ what: String) {
        let bandWidth = 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 3, usableHeight: usableHeight)
        #expect(plan.actions?.rows == expectedRows,
                Comment(rawValue: "\(what) (\(usableHeight) pt usable) — got \(String(describing: plan.actions?.rows)), "
                        + "expected \(String(describing: expectedRows))"))
    }

    /// **The ladder falls BACK to the narrow PAIR rather than dropping the
    /// whole column past `bandActionsRowCap` actions — this is what makes
    /// "6-10 actions get 10 of them shown, never merely 5, wherever the
    /// lone entry could already show 5" true rather than aspirational.**
    /// RETOLD for the narrow-pair fix (`bandActionsNarrowColumnWidth`'s own
    /// doc comment carries the fix in full): through the ladder that
    /// existed before it, this window's own fallback was a lone
    /// `bandSideColumnWidth` sub-column — `subColumns: 1`, capacity capped
    /// at `rows` (≤ 5) even though 6 to 10 actions were offered, which was
    /// this arc's OWN motivating defect, not a different one this test
    /// merely failed to catch. Both rows still sit at 10 actions, in the
    /// identical window `[898, 1136)` where the WIDE entry fails the
    /// cascade's own `act >= bandActMinWidth` check in EITHER posture — but
    /// the narrow PAIR entry, tried next, clears it folded at the SAME
    /// `actWidth` the lone entry always produced there (the identity
    /// `bandActionsNarrowColumnWidth` is built from is exactly why: the
    /// pair's own reserved footprint is bit-identical to the lone column's)
    /// — at a generous height so `rows` is never the binding constraint,
    /// `subColumns: 2` now, capacity doubled for free.
    ///
    /// **`controlsShown` is `false` in BOTH rows, not merely by choice of
    /// example — re-derived after the ladder-major, Controls-minor
    /// fix landed, and unchanged by the
    /// narrow-pair fix since it touches no threshold, only the capacity a
    /// clearing entry reports.** The narrow pair's own Controls-SHOWN
    /// threshold is 1152 (identical to the retired lone entry's, since
    /// `columnWidth` — the one figure `candidate(...)` reserves against —
    /// did not move); the wide entry's own Controls-FOLDED one is 1136 —
    /// and since the wide entry is tried, in both postures, before the
    /// narrow pair is ever considered, band width 1136 always resolves to
    /// the wide entry FIRST, 16 pt before the narrow pair's shown threshold
    /// would even have been reached. "Controls shown, narrow pair,
    /// `actionCount` > 5" is not a rare case this test merely failed to
    /// hit — it is structurally unreachable, and an earlier draft of this
    /// test (before an ordering fix) asserted exactly that unreachable
    /// combination at band width 1200, which is why it broke the moment the
    /// ordering was corrected.
    @Test("the ladder falls back to the narrow pair rather than dropping past bandActionsRowCap actions",
          arguments: [
            (1000.0, 722.0, "mid-range — the wide entry fails both postures, the narrow pair clears 620 folded"),
            (1130.0, 852.0, "just short of the wide entry's own folded threshold (1136) — still the narrow pair, still folded"),
          ])
    func ladderFallsBackRatherThanDroppingPastFiveActions(_ bandWidth: Double, _ expectedActWidth: Double, _ what: String) {
        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 10, usableHeight: 419)
        #expect(plan.controlsShown == false, Comment(rawValue: what))
        #expect(plan.actions?.columnWidth == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "\(what) — got columnWidth \(String(describing: plan.actions?.columnWidth)) "
                        + "— the narrow pair's own footprint is bit-identical to bandSideColumnWidth, by "
                        + "construction (bandActionsNarrowColumnWidth's own doc comment)"))
        #expect(plan.actions?.subColumns == 2,
                Comment(rawValue: "\(what) — got subColumns \(String(describing: plan.actions?.subColumns)) — "
                        + "the narrow-pair fix means this window offers 2 sub-columns now, not 1, at the "
                        + "identical actWidth"))
        #expect(plan.actions?.capacity == 10,
                Comment(rawValue: "\(what) — got capacity \(String(describing: plan.actions?.capacity)), all 10 "
                        + "offered actions should now be showable, none hidden behind the header's overflow chip"))
        #expect(plan.actWidth == expectedActWidth,
                Comment(rawValue: "\(what) — act width got \(plan.actWidth), expected \(expectedActWidth) — "
                        + "UNCHANGED from the lone-column era, the whole point of the identity"))
    }

    /// **THE central claim of the mandatory-column redesign, made explicit
    /// and named: a narrow band alone NEVER drops the actions column — only
    /// `actionCount == 0` or a geometry so starved nothing could possibly
    /// fit does.** Swept from `bandMinimumWidth` (628 — the narrowest band
    /// width ANY real window composes, and
    /// also the exact width the squeezed step's own floor guard
    /// (`bandActFloorWidth`) reduces to algebraically — `bandZonePlan`'s
    /// own doc comment carries the identity) up through every width this
    /// deck's own windows compose and well past them, at a generous height
    /// (900 pt usable — never the binding constraint here): `actions`
    /// stays present the entire way. **Deliberately starts AT the
    /// production floor, not below it** — an earlier draft of this sweep
    /// started at 278 (`span` exactly 254) and asserted `actions != nil`
    /// there too, which was true only because the squeezed step used to
    /// accept ANY non-negative `actWidth` — at 278 that meant an act zone
    /// of exactly 0 pt, annihilated rather than squeezed, asserted as a
    /// success. `actionsIsNilOnlyForTheStatedReasons` below is where that
    /// narrower, now-nil range is checked instead.
    @Test("the actions column is never dropped for width alone — only actionCount 0 or a genuinely impossible geometry drops it",
          arguments: [628.0, 700.0, 800.0, 900.0, 1000.0,
                      1136.0, 1152.0, 1200.0, 1390.0, 1588.0, 1600.0, 1920.0, 2000.0])
    func theActionsColumnIsNeverDroppedForWidthAlone(_ bandWidth: Double) {
        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 3, usableHeight: 900)
        #expect(plan.actions != nil,
                Comment(rawValue: "bandWidth \(bandWidth) dropped the actions column despite generous height "
                        + "and a positive action count — width alone should never do that"))
    }

    /// **The real, and only real, ways `actions` answers nil — stated as
    /// their own explicit cases rather than left to the sweep above to
    /// imply.** Two are genuinely reachable in production (`actionCount ==
    /// 0`; `usableHeight` too starved for even one row); the third (a
    /// `bandWidth` narrower than `bandMinimumWidth`, 628) is not, at any
    /// window this deck's own root clamp permits — kept honest anyway, the
    /// same defensive-depth practice this file applies to every other
    /// below-the-reachable-floor case. The minimum window's own band width
    /// closes the loop: the narrowest band any real window composes still
    /// shows the column, exactly AT the boundary, not merely above it.
    @Test("actions is nil exactly at zero actions, a starved height, and a starved width — nothing else")
    func actionsIsNilOnlyForTheStatedReasons() {
        let noActions = OverviewLayout.bandZonePlan(bandWidth: 1588, actionCount: 0, usableHeight: 419)
        #expect(noActions.actions == nil, "zero actions should never produce a plan")

        let noHeight = OverviewLayout.bandZonePlan(bandWidth: 1588, actionCount: 3, usableHeight: 100)
        #expect(noHeight.actions == nil, "usableHeight this starved should leave no honest room for even one row")

        let noWidth = OverviewLayout.bandZonePlan(bandWidth: 200, actionCount: 3, usableHeight: 900)
        #expect(noWidth.actions == nil,
                Comment(rawValue: "a bandWidth this starved should leave no honest room for even the narrowest "
                    + "sub-column — unreachable in production, but the pure function should still answer honestly"))

        let minimumWindow = OverviewLayout.bandZonePlan(bandWidth: OverviewLayout.bandMinimumWidth,
                                                         actionCount: 3, usableHeight: 249)
        #expect(minimumWindow.actions != nil,
                "the minimum window's own band width should still show the actions column")
    }

    /// **`bandMinimumWidth` (628) is the EXACT boundary the squeezed
    /// step's own `bandActFloorWidth` guard reduces to — checked here as
    /// its own inclusive pair.** Half a point
    /// under, the act zone would sit thinner than its own derived floor
    /// (`bandActFloorWidth`, 350) and the column drops rather than show an
    /// annihilated act zone; at or above it, the squeezed step's own
    /// worked value (350, exactly at `bandMinimumWidth` itself) holds.
    @Test("the squeezed step's own floor guard is inclusive at exactly bandMinimumWidth",
          arguments: [
            (628.0, 350.0, "exactly at bandMinimumWidth — the minimum window's own worked value"),
          ])
    func squeezedStepFloorGuardIsInclusive(_ bandWidth: Double, _ expectedActWidth: Double, _ what: String) {
        let atFloor = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 3, usableHeight: 249)
        #expect(atFloor.actions != nil, Comment(rawValue: "\(what) — should still show the column"))
        #expect(atFloor.actWidth == expectedActWidth,
                Comment(rawValue: "\(what) — got actWidth \(atFloor.actWidth), expected \(expectedActWidth)"))

        let belowFloor = OverviewLayout.bandZonePlan(bandWidth: bandWidth - 0.5, actionCount: 3, usableHeight: 249)
        #expect(belowFloor.actions == nil,
                Comment(rawValue: "half a point under bandMinimumWidth should drop the column entirely, not "
                    + "show an act zone thinner than bandActFloorWidth — got \(String(describing: belowFloor.actWidth))"))
    }

    /// **Step 2 ("Controls folded") is load-bearing on its own — deleting
    /// it survives unless something actually exercises the one geometry
    /// where the WIDE ladder entry can ONLY succeed folded.** `bandWidth` 1140 sits inside `[1136, 1390)` — past the
    /// wide entry's own folded threshold (1136) but short of its shown one
    /// (1390) — so `468×2` is reachable ONLY by trying Controls folded at
    /// that entry; a mutant that deleted the folded attempt would fall
    /// through to the narrower entry's own squeezed answer (`230×1`)
    /// instead, which this test's exact `columnWidth`/`subColumns`
    /// assertions catch directly.
    @Test("Controls folding is load-bearing at the wide ladder entry, in the window only it can reach")
    func foldedControlsPathIsLoadBearingAtTheWideLadderEntry() {
        let plan = OverviewLayout.bandZonePlan(bandWidth: 1140, actionCount: 10, usableHeight: 419)
        #expect(plan.controlsShown == false, Comment(rawValue: "got \(plan.controlsShown)"))
        #expect(plan.actions?.columnWidth == OverviewLayout.bandActionsWideColumnWidth,
                Comment(rawValue: "got \(String(describing: plan.actions?.columnWidth))"))
        #expect(plan.actions?.subColumns == 2,
                Comment(rawValue: "got \(String(describing: plan.actions?.subColumns))"))
        #expect(plan.actWidth == 624, Comment(rawValue: "1116 (span) − 492 (wide entry + gutter) = 624 — got \(plan.actWidth)"))
    }

    /// **The cascade's own `act >= bandActMinWidth` boundary, held
    /// inclusive.** At `bandWidth` 1152, actions 3
    /// (a single-entry ladder, so no wide-vs-narrow ambiguity), the ONE
    /// entry's own Controls-shown attempt lands on `act == 620` to the
    /// point and must still win — a `>` mutant would reject it and fall
    /// through to Controls folded instead, which this test's
    /// `controlsShown`/`actWidth` pair together catch: the mutant would
    /// report `controlsShown == false, actWidth == 874`, not `true, 620`.
    /// Half a point under, `act == 619.5` genuinely fails, and the SAME
    /// entry's own Controls-folded attempt (872.5 pt) legitimately wins
    /// instead — the observable flip this boundary is checked against.
    @Test("the cascade's own act >= bandActMinWidth check is inclusive, at exactly 620",
          arguments: [
            (1152.0, true, 620.0, "exactly at the boundary — Controls shown, act == bandActMinWidth exactly"),
            (1151.5, false, 873.5, "half a point under — Controls folds, act clears 620 with room to spare"),
          ])
    func cascadeActWidthBoundaryIsInclusive(_ bandWidth: Double, _ expectedControlsShown: Bool,
                                            _ expectedActWidth: Double, _ what: String) {
        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 3, usableHeight: 419)
        #expect(plan.controlsShown == expectedControlsShown,
                Comment(rawValue: "\(what) — got controlsShown \(plan.controlsShown)"))
        #expect(plan.actWidth == expectedActWidth,
                Comment(rawValue: "\(what) — got actWidth \(plan.actWidth)"))
    }

    /// **`actionCount == rows` exactly must still take the single-entry
    /// ladder, not the wide one — `needsTwo = actionCount > rows`, never
    /// `>=`.** A `>=` mutant would hand this set the
    /// two-entry ladder `[(2, 468), (2, 230)]`; at the strip's own generous
    /// band width the wide entry would then succeed too, reporting `468×2`
    /// for a count that only ever needs one sub-column's worth of rows.
    /// **This fixture's own `actionCount` (`bandActionsRowCap`, 5) and
    /// `rows` (also 5, at this `usableHeight`, 419) happen to coincide —
    /// RETOLD after the row-cap fix, since `needsTwo` reads `rows`, not
    /// `bandActionsRowCap`, directly: this test is really pinning the
    /// `actionCount == rows` boundary, and only reads as "at
    /// `bandActionsRowCap`" because the strip's own generous height is
    /// exactly where the two agree (`bandActionsRowCap`'s own doc comment
    /// carries the full account of where they do not).** Every other test
    /// in this section uses 3 or 10 — this is the one that actually sits ON
    /// the boundary.
    @Test("actionCount exactly at rows (here, also bandActionsRowCap) still takes the single-entry ladder, not the wide one")
    func actionCountAtRowCapTakesTheSingleEntryLadder() {
        let plan = OverviewLayout.bandZonePlan(bandWidth: 1588, actionCount: OverviewLayout.bandActionsRowCap, usableHeight: 419)
        #expect(plan.actions?.columnWidth == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "got \(String(describing: plan.actions?.columnWidth))"))
        #expect(plan.actions?.subColumns == 1,
                Comment(rawValue: "got \(String(describing: plan.actions?.subColumns))"))
    }

    /// **The zeroth case (`actionCount == 0`) must read the FULL
    /// `bandControlsShown(bandWidth:usableHeight:)` rule, never the
    /// height-only half (`bandControlsHeightClears(usableHeight:)`) the
    /// width cascade gates its OWN shown-attempt with.** A 960×340 window nets a band of 628 pt — under
    /// `bandCompactThreshold` (874), so Controls cannot fit by width at
    /// all — at a height generous enough that the height-only half alone
    /// would answer `true` (usable 319, `319 − 48 = 271 ≥ bandControlsFoldedMinimum`
    /// 244). Reading the wrong helper here would claim `controlsShown:
    /// true` for a band that cannot hold it.
    @Test("the zeroth case reads the full bandControlsShown rule, not the height-only half the cascade gates its own ladder with")
    func theZerothCaseReadsTheFullControlsShownRuleNotTheHeightHalfAlone() {
        let bandWidth = 628.0
        let usableHeight = 319.0
        #expect(OverviewLayout.bandZones(for: bandWidth) == .actOnly,
                "the fixture's own premise — this band width should not fit Controls by width at all")
        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 0, usableHeight: usableHeight)
        #expect(plan.controlsShown == false,
                Comment(rawValue: "a band this narrow should never claim Controls shown, whatever the height "
                    + "— got \(plan.controlsShown)"))
        #expect(plan.actWidth == 604, Comment(rawValue: "628 − 24 = 604, no Controls reserve subtracted — got \(plan.actWidth)"))
    }

    /// **The squeezed step actually fires — not merely implied by the
    /// ladder-loop tests above: an earlier draft
    /// cited a step-3 test that never reached step 3 at all.** `bandWidth`
    /// 700 clears `bandMinimumWidth` (628) but sits under EVERY ladder
    /// threshold (898 — even the single-entry ladder's own folded one), so
    /// both `actionCount` 3 and 10 fall all the way through the ladder
    /// loop to the squeezed step, landing on the identical `230×1` answer
    /// either way (the squeezed step never reads `actionCount` past
    /// deciding `rows`).
    @Test("the squeezed step actually triggers below every ladder threshold, above bandMinimumWidth",
          arguments: [3, 10])
    func squeezedStepActuallyTriggers(_ actionCount: Int) {
        let plan = OverviewLayout.bandZonePlan(bandWidth: 700, actionCount: actionCount, usableHeight: 419)
        #expect(plan.controlsShown == false, Comment(rawValue: "got \(plan.controlsShown)"))
        #expect(plan.actions?.columnWidth == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "got \(String(describing: plan.actions?.columnWidth))"))
        #expect(plan.actions?.subColumns == 1,
                Comment(rawValue: "got \(String(describing: plan.actions?.subColumns))"))
        #expect(plan.actWidth == 422, Comment(rawValue: "700 − 24 − 254 = 422 — got \(plan.actWidth)"))
    }

    /// **`bandZonePlan` never traps: `Int(Double)`
    /// crashes (`SIGTRAP`, uncatchable in-process, exit 133) on
    /// `.infinity`/`-.infinity`/`.nan` or anything outside `Int`'s own
    /// representable range, and `rawRows` (the `rows` formula's own raw,
    /// pre-clamp value) can be any of those: an unbounded `usableHeight`
    /// is a real SwiftUI layout offer, not a hypothetical one, and this
    /// very file already tests `presentation(...)` with `usableHeight:
    /// .infinity`.** `.infinity` and a huge finite value (`1e300`) both
    /// cap `rows` at `bandActionsRowCap` — "always tall enough"; `.nan`
    /// degrades to the same `rows == 0` (`actions: nil`) answer a starved
    /// finite height already gives, never a crash.
    @Test("bandZonePlan never traps on an unbounded or non-finite usableHeight, and degrades sensibly",
          arguments: [
            (Double.infinity, 5, "an unbounded offer caps rows at bandActionsRowCap, never traps"),
            (1e300, 5, "a huge finite offer behaves identically to unbounded, never traps"),
            (Double.nan, nil, "NaN degrades to the same rows == 0 answer a starved finite height gives, never traps"),
          ] as [(Double, Int?, String)])
    func bandZonePlanNeverTrapsOnUnboundedOrNonFiniteHeight(_ usableHeight: Double, _ expectedRows: Int?, _ what: String) {
        let plan = OverviewLayout.bandZonePlan(bandWidth: 1588, actionCount: 3, usableHeight: usableHeight)
        #expect(plan.actions?.rows == expectedRows,
                Comment(rawValue: "\(what) — got \(String(describing: plan.actions?.rows))"))
    }

    /// **The real invariant — capacity never shrinks as
    /// `bandWidth` grows, at any fixed `usableHeight`.** Swept at
    /// half-point resolution through `1100...1450` (the exact geometry
    /// 1151.5 → 1152.0 lived in) and 4 pt resolution either side of it,
    /// from 278 up to 2000, both `actionCount` 3 and 10, at eight
    /// representative usable heights spanning the reachable range —
    /// including 291.5/292.0, `bandControlsFoldedMinimum + bandHeaderHeight`'s
    /// own boundary, the SECOND geometry that mattered. Fine
    /// enough to have caught both halvings this test exists to close out,
    /// not merely asserted about in the doc comment.
    @Test("capacity never decreases as bandWidth grows, at every usable height this deck reaches",
          arguments: [149.0, 189.0, 249.0, 279.0, 291.5, 292.0, 358.0, 419.0])
    func capacityNeverShrinksAsBandWidthGrows(_ usableHeight: Double) {
        let sweep = stride(from: 278.0, to: 1100.0, by: 4.0).map { $0 }
            + stride(from: 1100.0, through: 1450.0, by: 0.5).map { $0 }
            + stride(from: 1450.0, through: 2000.0, by: 4.0).map { $0 }
        for actionCount in [3, 10] {
            var previousCapacity = 0
            var previousBandWidth = sweep.first ?? 0
            for bandWidth in sweep {
                let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
                let capacity = plan.actions?.capacity ?? 0
                #expect(capacity >= previousCapacity,
                        Comment(rawValue: "usableHeight \(usableHeight), actionCount \(actionCount): capacity dropped "
                            + "from \(previousCapacity) (bandWidth \(previousBandWidth)) to \(capacity) (bandWidth \(bandWidth))"))
                previousCapacity = capacity
                previousBandWidth = bandWidth
            }
        }
    }

    /// **`capacity` (`subColumns × rows`) is an internal SHAPE number, not
    /// the property that matters — RETOLD after a real correction.** An
    /// earlier round of this arc named this test the deck's own protection
    /// against "something hides as the window grows taller," swept it,
    /// found a break, and pinned that break as `capacityCanDropAsUsableHeightGrows_knownDefect`.
    /// That framing was wrong: worked through the arithmetic
    /// (`theColumnConsolidatesAtTheRowsCrossingWithNothingHidden`'s own doc
    /// comment carries the proof), the one crossing where `capacity` drops
    /// is exactly the crossing where one column's own capacity reaches
    /// `actionCount` precisely — nothing hides there, ever. `capacity`
    /// itself was never the load-bearing fact; `min(actionCount, capacity)`
    /// — how many pills actually show — is, and
    /// `nothingHidesAsUsableHeightGrows` below is what actually protects
    /// it, swept with NO carve-out, because it needs none.
    ///
    /// **What THIS test still earns its place checking: the raw `capacity`
    /// NUMBER's own shape, as an internal fact worth pinning on its own
    /// terms** — a caller reading `capacity` directly (not through
    /// `min(actionCount, capacity)`) should still be able to reason about
    /// when and why it moves, and the one place it drops should stay
    /// exactly as narrow as `theColumnConsolidatesAtTheRowsCrossingWithNothingHidden`
    /// says it is, not silently widen. Swept at half-point resolution from
    /// 100 through 500 pt usable, both `actionCount` 3 and 10, at eight
    /// representative band widths spanning every ladder regime this
    /// cascade has: below `bandMinimumWidth` is deliberately excluded
    /// (`actions` is nil there regardless of height, by construction — a
    /// separate claim, not this one), squeezed-only (700), the
    /// entry(1,230)-folded-only window (922, 948), the wide-entry-only-
    /// folded window (1140), and both fully-clear geometries (1588, 1920).
    /// The carve-out excludes exactly the crossing
    /// `theColumnConsolidatesAtTheRowsCrossingWithNothingHidden` pins,
    /// `actionCount ∈ 3...5` at the exact `usableHeight` boundary where
    /// `rows` crosses from `actionCount − 1` to `actionCount`, wherever the
    /// two-column ladder is width-reachable (`bandWidth ≥ 898`) — nothing
    /// wider, so a regression anywhere else this SHAPE fact still holds
    /// fails here.
    @Test("capacity (the internal shape number) never decreases as usableHeight grows, at every band width this deck reaches, except the documented consolidation",
          arguments: [700.0, 922.0, 948.0, 1140.0, 1152.0, 1200.0, 1588.0, 1920.0])
    func capacityNeverShrinksAsUsableHeightGrows(_ bandWidth: Double) {
        let sweep = stride(from: 100.0, through: 500.0, by: 0.5).map { $0 }
        for actionCount in [3, 10] {
            var previousCapacity = 0
            var previousRows = 0
            var previousUsableHeight = sweep.first ?? 0
            for usableHeight in sweep {
                let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
                let capacity = plan.actions?.capacity ?? 0
                let rows = plan.actions?.rows ?? 0
                // The one documented consolidation —
                // `theColumnConsolidatesAtTheRowsCrossingWithNothingHidden`'s
                // own doc comment carries the full account of why this is
                // a shape change, not something to protect against.
                let isTheDocumentedRowsCrossing = (3...5).contains(actionCount)
                    && previousRows == actionCount - 1 && rows == actionCount
                    && bandWidth >= 898
                if !isTheDocumentedRowsCrossing {
                    #expect(capacity >= previousCapacity,
                            Comment(rawValue: "bandWidth \(bandWidth), actionCount \(actionCount): capacity dropped "
                                + "from \(previousCapacity) (usableHeight \(previousUsableHeight)) to \(capacity) "
                                + "(usableHeight \(usableHeight)) — outside the documented consolidation"))
                }
                previousCapacity = capacity
                previousRows = rows
                previousUsableHeight = usableHeight
            }
        }
    }

    /// **The property that actually matters — nothing offered is hidden,
    /// wherever the plan offers a column at all, as `usableHeight` grows.**
    /// Stated directly on `min(actionCount, capacity)` — the number of
    /// pills a person actually sees, capped at what was offered — rather
    /// than on `capacity` itself, the internal shape number
    /// `capacityNeverShrinksAsUsableHeightGrows` (above) still pins on its
    /// own terms. **Swept with NO carve-out — the full realistic range,
    /// `bandWidth` and `actionCount` and `usableHeight` all three, not
    /// merely the two representative lists the shape check above uses —
    /// because it needs none: run against every point `sweepEveryGeometry`
    /// visits, this holds everywhere.** That is not an assumption; a
    /// version of this test with the SAME sweep but comparing raw
    /// `capacity` instead of `min(actionCount, capacity)` is exactly
    /// `capacityNeverShrinksAsUsableHeightGrows` (narrower lists) and DOES
    /// need its one carve-out — the difference between the two tests is
    /// the live proof that capping at `actionCount` is what actually
    /// closes the gap a raw-capacity comparison leaves open.
    @Test("nothing offered hides as usableHeight grows — the property capacity was only ever a proxy for")
    func nothingHidesAsUsableHeightGrows() {
        func walk(_ bandWidth: Double, _ actionCount: Int) {
            var previousShown = 0
            var previousUsableHeight = Self.fineUsableHeightSweep().first ?? 0
            for usableHeight in Self.fineUsableHeightSweep() {
                let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
                let shown = min(actionCount, plan.actions?.capacity ?? 0)
                #expect(shown >= previousShown,
                        Comment(rawValue: "bandWidth \(bandWidth), actionCount \(actionCount): the number of "
                            + "actions actually shown dropped from \(previousShown) (usableHeight "
                            + "\(previousUsableHeight)) to \(shown) (usableHeight \(usableHeight)) — this is what "
                            + "would actually mean a button hides as the window grows taller"))
                previousShown = shown
                previousUsableHeight = usableHeight
            }
        }
        for bandWidth in Self.fineBandWidthSweep() {
            for actionCount in 0...QuickAction.maxOffered { walk(bandWidth, actionCount) }
        }
    }


    /// `BandActionsPlan.capacity` is `subColumns × rows` — the trivial
    /// arithmetic pinned directly, since every other test in this section
    /// exercises it only indirectly through `bandZonePlan`'s own output.
    @Test("BandActionsPlan.capacity is subColumns times rows")
    func bandActionsPlanCapacityMultipliesSubColumnsAndRows() {
        let plan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandActionsWideColumnWidth,
                                                   subColumns: 2, rows: 5)
        #expect(plan.capacity == 10, Comment(rawValue: "got \(plan.capacity)"))
    }

    /// **The act zone's own derived floor, and the band's own width floor
    /// built from it — both held to the EXPRESSION they are defined as, not
    /// to a bare literal, so a change to `DeckPrefs.minWindow`, the fleet
    /// width, or the side column moves this test's own expectation right
    /// along with production rather than needing a second, manual update.**
    /// `bandActFloorWidth`'s own doc comment states why the number is 350;
    /// this is the test that would fail FIRST if it silently stopped being
    /// so.
    @Test("the act zone's derived floor and the band's minimum width move together with the constants they're built from")
    func bandActFloorWidthIsDerivedNotChosen() {
        let expectedFloor = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
            - 2 * OverviewLayout.bandColumnsHorizontalPadding - OverviewLayout.bandZoneGutter - OverviewLayout.bandSideColumnWidth
        #expect(OverviewLayout.bandActFloorWidth == expectedFloor,
                Comment(rawValue: "got \(OverviewLayout.bandActFloorWidth), expected \(expectedFloor)"))
        #expect(OverviewLayout.bandActFloorWidth == 350,
                Comment(rawValue: "960 − 324 − 8 − 24 − 24 − 230 = 350 — got \(OverviewLayout.bandActFloorWidth)"))

        let expectedMinimum = OverviewLayout.bandActFloorWidth + OverviewLayout.bandZoneGutter
            + OverviewLayout.bandSideColumnWidth + 2 * OverviewLayout.bandColumnsHorizontalPadding
        #expect(OverviewLayout.bandMinimumWidth == expectedMinimum,
                Comment(rawValue: "got \(OverviewLayout.bandMinimumWidth), expected \(expectedMinimum)"))
        #expect(OverviewLayout.bandMinimumWidth == 628,
                Comment(rawValue: "350 + 24 + 230 + 24 = 628 — got \(OverviewLayout.bandMinimumWidth)"))

        // The collapse this constant's own doc comment claims algebraically
        // — `bandMinimumWidth` now equals the minimum window's own band
        // width EXACTLY, not merely close to it.
        let minWindowBandWidth = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        #expect(OverviewLayout.bandMinimumWidth == minWindowBandWidth,
                Comment(rawValue: "bandMinimumWidth (\(OverviewLayout.bandMinimumWidth)) should equal the minimum "
                        + "window's own band width (\(minWindowBandWidth)) exactly"))
    }

    // ---------------------------------------------------------- the sweep
    //
    // Per-session action counts changed a fact this cascade's own layout was designed around:
    // the visible action COUNT used to be global — a fixed shape read once
    // at launch — and is now per-session, so merely SELECTING a different
    // session can hand `bandZonePlan` a different `actionCount` at an
    // otherwise UNCHANGED `bandWidth`/`usableHeight`. Every sweep above
    // this point holds `actionCount` to one of two fixed values (3, 10)
    // and sweeps `bandWidth`/`usableHeight` instead — exactly the axis
    // the ordering fix needed swept, and exactly the axis that change did not touch.
    // This section sweeps the THIRD axis, `actionCount` itself, 0 through
    // `QuickAction.maxOffered` (10), against real `bandWidth`/`usableHeight`
    // grids — the band arc's own recorded lesson, verbatim: "Sweep
    // invariants beat sampled geometries — the prototype AND the worked
    // table both missed the monotonicity bug because all four snap sizes
    // sit far from band 1152." A sweep run in anger found exactly that
    // shape of bug again, on this new axis — `theActWidthCanWidenAsActionsGrow_knownDefect`
    // below is where that finding is pinned, precisely, rather than
    // smoothed over.

    /// The three real canvases this deck actually composes, restated as
    /// `(contentWidth, contentHeight, bannerUp)` triples — the SAME three
    /// inputs `bandZonePlanAtEveryRealGeometry` (above) already reduces to
    /// a `bandWidth`/`usableHeight` pair, and the SAME local
    /// `statusLine`/`bannerHeight` subtraction that test's own doc comment
    /// argues for restating here rather than importing: "so a change to
    /// either subtraction is caught here too, not only in the constants'
    /// own dedicated tests." `theSweepIncludesTheRealCanvasesAsExplicitPoints`
    /// below is what makes "points ON the sweep, not the whole of it" (job
    /// 2's own invariant 4) a checked fact rather than a claim resting on
    /// the fine sweeps below happening to land on one of these five by
    /// coincidence of stride.
    private static let realCanvases: [(contentWidth: Double, contentHeight: Double, bannerUp: Bool, what: String)] = [
        (1920.0, 440.0, false, "the strip, banner down"),
        (1920.0, 440.0, true, "the strip, banner up"),
        (1280.0, 300.0, false, "the shipped default window"),
        (960.0, 270.0, false, "the minimum window, banner down"),
        (960.0, 270.0, true, "the minimum window, banner up"),
    ]

    private static func bandWidthAndUsableHeight(contentWidth: Double, contentHeight: Double,
                                                  bannerUp: Bool) -> (bandWidth: Double, usableHeight: Double) {
        let statusLine = 21.0
        let bannerHeight = 60.0
        let bandWidth = contentWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let usableHeight = contentHeight - statusLine - (bannerUp ? bannerHeight : 0)
        return (bandWidth, usableHeight)
    }

    /// The fine `bandWidth` sweep every invariant below runs against —
    /// `capacityNeverShrinksAsBandWidthGrows`'s own stride, unchanged:
    /// coarse (4 pt) through most of the range, half-point resolution
    /// through `1100...1450`, the exact window the earlier ordering bug and
    /// the finding below live in.
    private static func fineBandWidthSweep() -> [Double] {
        stride(from: 278.0, to: 1100.0, by: 4.0).map { $0 }
            + stride(from: 1100.0, through: 1450.0, by: 0.5).map { $0 }
            + stride(from: 1450.0, through: 2000.0, by: 4.0).map { $0 }
    }

    /// The fine `usableHeight` sweep every invariant below runs against —
    /// `capacityNeverShrinksAsUsableHeightGrows`'s own stride, unchanged:
    /// half-point resolution end to end, since the height axis has no
    /// single expensive region the way `bandWidth` does near 1152/1390.
    private static func fineUsableHeightSweep() -> [Double] {
        stride(from: 100.0, through: 500.0, by: 0.5).map { $0 }
    }

    /// Representative `usableHeight`s, paired with the fine `bandWidth`
    /// sweep — `capacityNeverShrinksAsBandWidthGrows`'s own eight, plus
    /// 359 (the strip banner-up usable height, missing from that set
    /// because that test never needed a banner-up canvas by name).
    private static let representativeUsableHeights: [Double] = [149.0, 189.0, 249.0, 279.0, 291.5, 292.0, 358.0, 359.0, 419.0]

    /// Representative `bandWidth`s, paired with the fine `usableHeight`
    /// sweep — `capacityNeverShrinksAsUsableHeightGrows`'s own eight, plus
    /// 628 (`bandMinimumWidth`, the narrowest band any real window
    /// composes) and 1390 (`bandActionsWideColumnWidth`'s own shown
    /// threshold — the upper edge of this phase's own finding, below).
    private static let representativeBandWidths: [Double] = [628.0, 700.0, 922.0, 948.0, 1140.0, 1152.0, 1200.0, 1390.0, 1588.0, 1920.0]

    /// **The shared enumeration every per-point invariant below walks —
    /// `actionCount` 0 through `QuickAction.maxOffered` (10) at every
    /// point of two geometry sweeps (fine `bandWidth` × representative
    /// `usableHeight`, and fine `usableHeight` × representative
    /// `bandWidth`) plus the five real canvases by name, explicitly.**
    /// Folded into ONE walk so every per-point invariant (1 and 3 below;
    /// monotonicity, invariant 2, needs consecutive `actionCount` state
    /// and keeps its own loop instead) pays the enumeration cost once
    /// rather than each writing a slightly different copy of it.
    private static func sweepEveryGeometry(_ check: (_ bandWidth: Double, _ usableHeight: Double, _ actionCount: Int) -> Void) {
        for usableHeight in representativeUsableHeights {
            for bandWidth in fineBandWidthSweep() {
                for actionCount in 0...QuickAction.maxOffered { check(bandWidth, usableHeight, actionCount) }
            }
        }
        for bandWidth in representativeBandWidths {
            for usableHeight in fineUsableHeightSweep() {
                for actionCount in 0...QuickAction.maxOffered { check(bandWidth, usableHeight, actionCount) }
            }
        }
        for canvas in realCanvases {
            let (bandWidth, usableHeight) = bandWidthAndUsableHeight(contentWidth: canvas.contentWidth,
                                                                      contentHeight: canvas.contentHeight,
                                                                      bannerUp: canvas.bannerUp)
            for actionCount in 0...QuickAction.maxOffered { check(bandWidth, usableHeight, actionCount) }
        }
    }

    /// **Invariant 1 (job 2's own numbering) — the act zone never falls
    /// below `bandActMinWidth` while `actions` is present, UNLESS the
    /// cascade has already folded Controls to buy that room (the squeezed
    /// step, accepted down to `bandActFloorWidth` — never merely `>= 0`,
    /// `squeezedStepFloorGuardIsInclusive` above already holds that
    /// boundary on its own).** Restated as its own swept claim rather than
    /// trusted to the five worked rows `bandZonePlanAtEveryRealGeometry`
    /// pins, because per-session counts made `actionCount` a THIRD axis this promise
    /// has to survive, not merely `bandWidth`/`usableHeight` — the same
    /// reason the two capacity sweeps above exist rather than trusting
    /// their own worked table. Every point where `actions == nil` is
    /// skipped outright — nothing to starve when there is no column.
    @Test("invariant 1 — the act zone never starves below its own floor while actions is present, across actionCount × geometry")
    func actZoneNeverStarvesBelowItsFloor() {
        Self.sweepEveryGeometry { bandWidth, usableHeight, actionCount in
            let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
            guard let actions = plan.actions else { return }
            let clearsTheOrdinaryFloor = plan.actWidth >= OverviewLayout.bandActMinWidth
            let clearsTheSqueezedFloor = !plan.controlsShown && plan.actWidth >= OverviewLayout.bandActFloorWidth
            #expect(clearsTheOrdinaryFloor || clearsTheSqueezedFloor,
                    Comment(rawValue: "bandWidth \(bandWidth), usableHeight \(usableHeight), actionCount "
                        + "\(actionCount): actWidth \(plan.actWidth) cleared neither bandActMinWidth "
                        + "(\(OverviewLayout.bandActMinWidth)) nor the squeezed floor bandActFloorWidth "
                        + "(\(OverviewLayout.bandActFloorWidth)) with controlsShown \(plan.controlsShown) — "
                        + "capacity \(actions.capacity), columnWidth \(actions.columnWidth)"))
        }
    }

    /// **Invariant 3 — the column's own natural height, at the plan's own
    /// `rows`, never overruns `usableHeight − bandHeaderHeight` — the
    /// EXACT budget `DetailBand.columns(for:)` hands `QuickActionsColumn`
    /// as `budget` (`columnsHeightBudget`'s own doc comment, `DetailBand.swift`).**
    /// Rebuilds `bandActionsRowHeight(columnBudget:rowCount:)`'s own
    /// arithmetic — the SAME function `QuickActionsColumn.body` calls to
    /// size a real row — rather than re-deriving a second formula, so this
    /// invariant is checked against the thing that actually renders, not
    /// a paraphrase of it. `rows` is independent of `actionCount` by
    /// construction (`bandZonePlan`'s own doc comment), so this is really
    /// a height-only claim — but it is swept across `actionCount` anyway,
    /// at every point `sweepEveryGeometry` visits, since a `rows` this
    /// invariant has not seen at this exact `usableHeight` is a `rows`
    /// this test has not actually checked.
    @Test("invariant 3 — the column's own natural height never overruns usableHeight − bandHeaderHeight, across actionCount × geometry")
    func columnHeightNeverOverrunsItsBudget() {
        Self.sweepEveryGeometry { bandWidth, usableHeight, actionCount in
            let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
            guard let actions = plan.actions else { return }
            let columnBudget = usableHeight - OverviewLayout.bandHeaderHeight
            let rowHeight = OverviewLayout.bandActionsRowHeight(columnBudget: columnBudget, rowCount: actions.rows)
            let naturalHeight = 2 * OverviewLayout.bandColumnsVerticalPadding + OverviewLayout.bandQuickActionsChrome
                + Double(actions.rows) * rowHeight + Double(actions.rows - 1) * OverviewLayout.actionGridSpacing
            #expect(naturalHeight <= columnBudget + 1e-9,
                    Comment(rawValue: "bandWidth \(bandWidth), usableHeight \(usableHeight), actionCount "
                        + "\(actionCount): naturalHeight \(naturalHeight) overran columnBudget \(columnBudget) "
                        + "at rows \(actions.rows), rowHeight \(rowHeight)"))
        }
    }

    /// **Invariant 5 — NOT the same "invariant 4" `realCanvases`' own doc
    /// comment and `theSweepIncludesTheRealCanvasesAsExplicitPoints` cite
    /// (job 2's own numbering, "points ON the sweep, not the whole of it,"
    /// a check about sweep COVERAGE, unrelated to this one) — this phase's
    /// own local sequence (invariants 1 through 3, above) simply continues
    /// past that separately-numbered reference rather than colliding with
    /// it.** The narrow-pair fix's own invariant: wherever the plan offers
    /// an actions column at all, its capacity is at least `min(actionCount,
    /// 2 × rows)` — a second sub-column is taken whenever taking it would
    /// actually help. Swept at every point `sweepEveryGeometry` visits,
    /// job 2's own instruction followed exactly: run it, and where it
    /// cannot hold, report precisely where and why rather than silently
    /// weakening the claim or widening a carve-out to make a failure go
    /// away.
    ///
    /// **RETOLD — this used to carry TWO exceptions; the row-cap fix closed
    /// one of them, and the sweep is what proved it closed rather than
    /// merely moved.** The first draft of this invariant, checked only for
    /// `actionCount > bandActionsRowCap` (the narrow-pair fix's own
    /// original scope), needed a carve-out for `actionCount <=
    /// bandActionsRowCap`: that single-entry ladder never opened a second
    /// sub-column at all, so wherever a squeezed HEIGHT left `rows <
    /// actionCount` at a LOW `actionCount` (the deck's own shipped default
    /// window, `rows` 3, exactly `bandActionsRowCap` offered actions,
    /// showing only 3), the invariant failed for a reason outside that
    /// round's own stated scope. **The row-cap fix — `needsTwo = actionCount
    /// > rows`, `bandActionsRowCap`'s own doc comment carries the fix in
    /// full — closes exactly that gap, and this invariant is what confirms
    /// it: swept over the FULL `actionCount` range (2 through
    /// `QuickAction.maxOffered`, no longer restricted to `>
    /// bandActionsRowCap`) with ONLY the squeezed-fallback carve-out below
    /// still in place, this invariant holds everywhere.** Before the
    /// row-cap fix, that same full-range sweep failed broadly — every
    /// `actionCount` from 2 up, at every `bandWidth`, wherever a squeezed
    /// height left `rows < actionCount` — confirming the closed gap was
    /// real and not merely re-scoped away.
    /// `theDefaultWindowShowsAllFiveConfiguredActions`, below, pins the
    /// single most important point on that now-closed surface as its own
    /// live arbiter, the same "reported, not fixed" pattern
    /// `theActWidthCanWidenAsActionsGrow_knownDefect` still follows for the
    /// ONE exception below, which the row-cap fix does not touch.
    ///
    /// **The one remaining exception — the untouched squeezed fallback,
    /// reachable whenever `needsTwo` (`actionCount > rows`), `bandWidth` in
    /// `[bandMinimumWidth (628), 898)`.** This is the corner
    /// `bandActionsNarrowColumnWidth`'s own doc comment already names as
    /// out of scope by direct instruction ("Do not touch the squeezed
    /// fallback") — the squeezed step re-tries the SAME lone-column
    /// arithmetic the ladder loop's own narrow-pair rung would, at a LOWER
    /// acceptance floor (`bandActFloorWidth`, 350, rather than
    /// `bandActMinWidth`, 620), and never gained the pair's own doubled
    /// capacity because doubling it there was never asked for. Distinguished
    /// from the geometry the fix DOES cover by `plan.actWidth <
    /// bandActMinWidth` — exactly the condition that separates "the ladder
    /// loop already succeeded, so `needsTwo` is guaranteed `subColumns: 2`"
    /// from "the loop failed and fell to the squeezed step," verified as
    /// the precise boundary a sweep at this file's own fine `bandWidth`
    /// stride actually finds, not merely asserted by construction.
    ///
    /// **Nothing outside this one — verified by the sweep itself, not
    /// merely by its own derivation.** A version of this test run without
    /// the carve-out fails 10,055 times, entirely inside `needsTwo`,
    /// `bandWidth` in `[628, 894]` (the coarse stride's own last sampled
    /// point below the true 898 boundary) — precisely this exception, and
    /// nothing past it. Removing the carve-out here should be expected to
    /// un-skip real, counted failures, not zero — a change to this test
    /// that stops finding them is worth treating as a hint the fix itself
    /// moved, not merely that the exception window did.
    @Test("invariant 5 — capacity is at least min(actionCount, 2×rows) wherever the plan offers a column, except the one remaining out-of-scope exception")
    func capacityTakesTheSecondSubColumnWheneverItWouldHelp() {
        var failures: [(Double, Double, Int, Int, Int)] = []
        Self.sweepEveryGeometry { bandWidth, usableHeight, actionCount in
            let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
            guard let actions = plan.actions else { return }
            // Carve-out (b) — the untouched squeezed fallback (brief:
            // "do not touch"), reachable only when needsTwo.
            guard !(actionCount > actions.rows && plan.actWidth < OverviewLayout.bandActMinWidth) else { return }
            let want = min(actionCount, 2 * actions.rows)
            if actions.capacity < want {
                failures.append((bandWidth, usableHeight, actionCount, actions.capacity, want))
            }
        }
        if !failures.isEmpty {
            let bandWidths = Set(failures.map { $0.0 }).sorted()
            let usableHeights = Set(failures.map { $0.1 }).sorted()
            let actionCounts = Set(failures.map { $0.2 }).sorted()
            Issue.record(Comment(rawValue: "FAILURES: \(failures.count) — bandWidth range "
                + "\(bandWidths.first!)...\(bandWidths.last!) (\(bandWidths.count) distinct), usableHeight range "
                + "\(usableHeights.first!)...\(usableHeights.last!) (\(usableHeights.count) distinct), "
                + "actionCounts \(actionCounts)"))
            for f in failures.prefix(20) {
                Issue.record(Comment(rawValue: "bandWidth \(f.0), usableHeight \(f.1), actionCount \(f.2): "
                    + "capacity \(f.3), want \(f.4)"))
            }
        }
    }

    /// **FIXED, formerly a known gap — the row-cap fix's own live arbiter,
    /// pinned to the exact real, shipped geometry that exposed it.** The
    /// deck's own `DeckPrefs.defaultWindow` (1280×300, `bandWidth` 948,
    /// usable 279) lands on `rows: 3` (`bandZonePlanRowsBoundaryTable`'s own
    /// boundary: usable 279 sits in `[253, 305)`) — a squeezed HEIGHT, not
    /// width. Before the row-cap fix, the ladder split on `actionCount >
    /// bandActionsRowCap` — a static comparison against the row CEILING (5)
    /// standing in for "does the set fit in one sub-column" — which agreed
    /// with the true test, `actionCount > rows`, only where `rows` happened
    /// to equal 5. At exactly `bandActionsRowCap` (5) offered actions, this
    /// geometry's own `rows` (3) meant the set genuinely did not fit, but
    /// the old condition (`5 > 5`, false) never noticed, and the
    /// single-entry ladder showed 3 of 5, two folded into the header's own
    /// overflow chip, on a 948 pt band that could easily afford
    /// `bandActionsNarrowColumnWidth`'s own pair. `bandActionsRowCap`'s own
    /// doc comment carries the account of the bug in full — this is that
    /// account's own live, geometry-level proof, not merely the doc
    /// comment's prose.
    ///
    /// **Fixed by `needsTwo = actionCount > rows`
    /// (`bandZonePlanCascade`'s own local, already in scope where the OLD
    /// condition used to read `bandActionsRowCap` directly) — no width
    /// change, no new ladder rung, only the CONDITION selecting which
    /// ladder a caller gets.** At `actionCount` 5, `rows` 3: `needsTwo`
    /// reads `5 > 3`, true — the two-entry ladder opens, the narrow-pair
    /// rung clears `bandActMinWidth` here exactly the way it does at
    /// `actionCount` 6 and up (`bandActionsNarrowColumnWidth`'s own
    /// identity is unmoved; only which `actionCount`s reach for it changed)
    /// — `subColumns` 2, capacity `2 × 3 = 6`, all 5 configured actions
    /// show. Renamed from `theDefaultWindowStillHidesActionsAtTheRowCap_knownGap`
    /// — the "KNOWN GAP" pin is retired along with the bug it pinned, the
    /// same way a fixed defect's own test earns a name that says so rather
    /// than one still describing the failure.
    @Test("the shipped default window shows all five configured actions at exactly bandActionsRowCap, the row-cap fix's own live arbiter")
    func theDefaultWindowShowsAllFiveConfiguredActions() {
        let bandWidth = 1280.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        // The SAME contentWidth/contentHeight-minus-status-line convention
        // `bandZonePlanAtEveryRealGeometry`'s own "shipped default window"
        // row already uses (that row's own doc comment: no titlebar term,
        // since it states `bandZonePlan`'s inputs directly) — kept
        // consistent with the sibling test this case is a variant of, not
        // re-derived. (Elsewhere in this file, `defaultWindowGetsTheBandNow`
        // subtracts an ADDITIONAL 40 pt titlebar for the SAME 1280×300
        // figure when testing `presentation(...)` instead of `bandZonePlan`
        // directly — confirmed, not merely noted, to be THAT test's own
        // bug: `DeckScene.swift`'s own `.defaultSize(...)` sits under
        // `.windowResizability(.contentSize)`, the identical mechanism
        // `DeckPrefs.minWindow`'s own `.frame(minWidth:minHeight:)` reading
        // already establishes as titlebar-free throughout this file —
        // `DeckPrefs.defaultWindow` is a CONTENT size, the same as
        // `DeckPrefs.minWindow`, so subtracting a titlebar from it is
        // over-subtracting. Left unfixed here — `defaultWindowGetsTheBandNow`
        // is outside this test's own scope, and its own conclusion
        // (squeezed either way, 239 or 279 both land under `bandMinimumHeight`)
        // does not change either way, so nothing routes wrongly today; it
        // is flagged for its own separate correction, not bundled into
        // this one.)
        let usableHeight = 300.0 - 21.0
        #expect(bandWidth == 948, "the fixture's own premise — got \(bandWidth)")
        #expect(usableHeight == 279, "the fixture's own premise — got \(usableHeight)")

        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: OverviewLayout.bandActionsRowCap,
                                               usableHeight: usableHeight)
        #expect(plan.actions?.rows == 3,
                Comment(rawValue: "the fixture's own premise — got \(String(describing: plan.actions?.rows))"))
        #expect(plan.actions?.subColumns == 2,
                Comment(rawValue: "the row-cap fix should open a second sub-column here — 5 actions offered "
                        + "exceeds this geometry's own 3 rows — got \(String(describing: plan.actions?.subColumns))"))
        #expect(plan.actions?.columnWidth == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "the narrow pair's own footprint is bit-identical to bandSideColumnWidth, by "
                        + "construction — got \(String(describing: plan.actions?.columnWidth))"))
        #expect(plan.actions?.capacity == 6,
                Comment(rawValue: "2 × 3 rows — got \(String(describing: plan.actions?.capacity))"))
        #expect((plan.actions?.capacity ?? 0) >= OverviewLayout.bandActionsRowCap,
                Comment(rawValue: "this IS the fix — all 5 configured actions must now fit (capacity "
                        + "\(String(describing: plan.actions?.capacity)) >= 5), none folded into the header's "
                        + "overflow chip on this otherwise generous 948 pt band"))
        #expect(plan.actWidth == 670,
                Comment(rawValue: "UNCHANGED from before either fix — got \(plan.actWidth) — the whole point: "
                        + "showing all 5 actions costs the act zone nothing it was not already giving up"))
    }

    /// **The real canvases actually land IN the sweeps above, not merely
    /// near them — job 2's own invariant 4, checked as its own fact rather
    /// than assumed from `sweepEveryGeometry`'s own third loop.** Cheap on
    /// its own (five canvases × 11 action counts), and it is what turns
    /// "the sweep includes the real canvases" from a claim about how
    /// `sweepEveryGeometry` happens to be written into something that
    /// fails loudly if a future edit ever drops that third loop.
    @Test("the sweep's own real-canvas loop actually produces a plan at every canvas, banner posture, and actionCount")
    func theSweepIncludesTheRealCanvasesAsExplicitPoints() {
        for canvas in Self.realCanvases {
            let (bandWidth, usableHeight) = Self.bandWidthAndUsableHeight(contentWidth: canvas.contentWidth,
                                                                          contentHeight: canvas.contentHeight,
                                                                          bannerUp: canvas.bannerUp)
            for actionCount in 1...QuickAction.maxOffered {
                let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
                #expect(plan.actions != nil,
                        Comment(rawValue: "\(canvas.what), actionCount \(actionCount) (band \(bandWidth), usable "
                            + "\(usableHeight)) — a real canvas should never drop the actions column"))
            }
        }
    }

    /// **Invariant 2, capacity half — adding one more action must never
    /// make the column's own capacity go DOWN, at any FIXED `bandWidth`/
    /// `usableHeight`.** `capacityNeverShrinksAsBandWidthGrows`/
    /// `capacityNeverShrinksAsUsableHeightGrows` (above) already provably
    /// hold this walking `bandWidth`/`usableHeight` at two fixed
    /// `actionCount`s (3, 10) — this is the transposed sweep that
    /// was needed: `actionCount` walked at every fixed geometry point instead.
    /// Swept at every point `sweepEveryGeometry` visits — this holds
    /// everywhere it was checked; no exception window, unlike this
    /// invariant's own other half immediately below.
    @Test("invariant 2, capacity half — capacity never decreases as actionCount grows, at any fixed bandWidth/usableHeight")
    func capacityNeverDecreasesAsActionCountGrows() {
        Self.sweepEveryGeometryMonotonic { bandWidth, usableHeight, previous, actionCount, plan in
            let capacity = plan.actions?.capacity ?? 0
            let previousCapacity = previous.actions?.capacity ?? 0
            #expect(capacity >= previousCapacity,
                    Comment(rawValue: "bandWidth \(bandWidth), usableHeight \(usableHeight): capacity dropped from "
                        + "\(previousCapacity) (actionCount \(actionCount - 1)) to \(capacity) (actionCount "
                        + "\(actionCount))"))
        }
    }

    /// **Invariant 2, act-width half — adding one more action must never
    /// WIDEN the act zone, at any fixed `bandWidth`/`usableHeight` —
    /// checked everywhere EXCEPT the documented crossing where it is
    /// currently, confirmedly, false.** `theActWidthCanWidenAsActionsGrow_knownDefect`
    /// immediately below is where that crossing is named, pinned to exact
    /// numbers, and explained — this test excludes exactly it, nothing
    /// wider, so a regression ANYWHERE else this invariant is supposed to
    /// hold still fails here.
    ///
    /// **RETOLD — the row-cap fix, `needsTwo = actionCount > rows`, moved
    /// the crossing this excludes from a fixed number to a per-geometry
    /// one, and the sweep is what found that out, not assumption.** Through
    /// the narrow-pair fix alone, the ladder only ever gained its wider
    /// first rung crossing `actionCount == bandActionsRowCap + 1` (6) —
    /// `needsTwo` agreed with the static condition at every geometry that
    /// round's own sweep visited, because every one of them had `rows == 5`.
    /// The row-cap fix's whole point is that `rows` is not always 5 — and
    /// the SAME widening mechanism (`theActWidthCanWidenAsActionsGrow_knownDefect`'s
    /// own doc comment carries the root cause: folding Controls frees more
    /// than the wide entry costs, at a `bandWidth` where the single-entry
    /// ladder's own SHOWN attempt was still winning) fires at ANY crossing
    /// where `needsTwo` flips from false to true, which is `actionCount ==
    /// rows + 1` for whatever `rows` this specific geometry has, not only
    /// at `rows == bandActionsRowCap`. Run without this correction — the
    /// static `actionCount == bandActionsRowCap + 1` condition, unmodified
    /// — this test fails 736 times, entirely at `actionCount` crossings 3→4
    /// and 4→5 (the sweep's own report), on top of the already-excluded
    /// 5→6: `rows` 3 and 4 respectively, both reachable at `bandWidth` in
    /// `[1152, 1390)` with `usableHeight` generous enough to clear
    /// `bandControlsHeightClears` (292) — `rows` 1 and 2 never combine with
    /// that height floor at all (`bandZonePlanRowsBoundaryTable`'s own
    /// boundaries: `rows` 2 tops out at usable 252.9, `bandControlsHeightClears`
    /// needs usable ≥ 292), which is why crossings 2→3 and lower never
    /// appear, empirically, not merely by construction.
    @Test("invariant 2, act-width half — the act zone never widens as actionCount grows, except the documented ladder-crossing")
    func actZoneNeverWidensAsActionCountGrowsExceptTheDocumentedWindow() {
        // The exception window's own two width edges, as plain literals
        // rather than new `OverviewLayout` constants invented just to name
        // them — `cascadeActWidthBoundaryIsInclusive`/
        // `foldedControlsPathIsLoadBearingAtTheWideLadderEntry` (above)
        // already hold 1152/1140 the identical way, bare numbers checked
        // directly against a live-derived boundary rather than a second
        // constant that could drift from the cascade's own arithmetic.
        let narrowEntryShownThreshold = 1152.0
        let wideEntryShownThreshold = 1390.0
        Self.sweepEveryGeometryMonotonic { bandWidth, usableHeight, previous, actionCount, plan in
            guard let actions = plan.actions, let previousActions = previous.actions else { return }
            // The one known, confirmed, unfixed exception — see this
            // test's own doc comment and `theActWidthCanWidenAsActionsGrow_knownDefect`
            // for the full account of why it is excluded rather than
            // fixed or silently weakened. `previousActions.rows ==
            // actions.rows` always (rows is a pure function of usableHeight,
            // independent of actionCount) — reading either is the SAME
            // fact; `previousActions.rows` is used since it is the plan
            // whose own `needsTwo` just flipped.
            let isTheDocumentedCrossing = actionCount == previousActions.rows + 1
                && bandWidth >= narrowEntryShownThreshold
                && bandWidth < wideEntryShownThreshold
                && usableHeight - OverviewLayout.bandHeaderHeight >= OverviewLayout.bandControlsFoldedMinimum
            guard !isTheDocumentedCrossing else { return }
            #expect(plan.actWidth <= previous.actWidth + 1e-9,
                    Comment(rawValue: "bandWidth \(bandWidth), usableHeight \(usableHeight): actWidth widened from "
                        + "\(previous.actWidth) (actionCount \(actionCount - 1), capacity \(previousActions.capacity)) "
                        + "to \(plan.actWidth) (actionCount \(actionCount), capacity \(actions.capacity)) — outside "
                        + "the documented exception crossing"))
        }
    }

    /// **The shared enumeration invariant 2's own two halves walk —
    /// `actionCount` 1 through `QuickAction.maxOffered`, PAIRED with the
    /// plan one action fewer produced, at every fixed geometry point the
    /// per-point sweeps above visit.** A separate walk from
    /// `sweepEveryGeometry`, not a reuse of it: monotonicity is a claim
    /// about CONSECUTIVE `actionCount`s at the SAME geometry, so this
    /// needs the previous plan carried between iterations — a per-point
    /// check has no "previous" to carry. Same three sources as
    /// `sweepEveryGeometry` (fine bandWidth × representative usableHeight;
    /// fine usableHeight × representative bandWidth; the five real
    /// canvases by name) so both halves of invariant 2 are checked
    /// against the identical geometry footprint invariants 1 and 3 are.
    private static func sweepEveryGeometryMonotonic(
        _ check: (_ bandWidth: Double, _ usableHeight: Double, _ previous: OverviewLayout.BandZonePlan,
                  _ actionCount: Int, _ plan: OverviewLayout.BandZonePlan) -> Void
    ) {
        func walk(_ bandWidth: Double, _ usableHeight: Double) {
            var previous = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 0, usableHeight: usableHeight)
            for actionCount in 1...QuickAction.maxOffered {
                let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: actionCount, usableHeight: usableHeight)
                check(bandWidth, usableHeight, previous, actionCount, plan)
                previous = plan
            }
        }
        for usableHeight in representativeUsableHeights {
            for bandWidth in fineBandWidthSweep() { walk(bandWidth, usableHeight) }
        }
        for bandWidth in representativeBandWidths {
            for usableHeight in fineUsableHeightSweep() { walk(bandWidth, usableHeight) }
        }
        for canvas in realCanvases {
            let (bandWidth, usableHeight) = bandWidthAndUsableHeight(contentWidth: canvas.contentWidth,
                                                                      contentHeight: canvas.contentHeight,
                                                                      bannerUp: canvas.bannerUp)
            walk(bandWidth, usableHeight)
        }
    }

    /// **THE finding this phase's own sweep exists to surface — reported,
    /// not papered over, per job 2's own instruction.** Crossing
    /// `actionCount` from 5 to 6 (`bandActionsRowCap` to one past it) can
    /// WIDEN the act zone rather than narrow or hold it, at any `bandWidth`
    /// in `[1152, 1390)` with `usableHeight` generous enough for Controls
    /// to be shown at all (`>= 292`) — the strip's own banner-down usable
    /// height (419) is squarely inside that range, so this is not a
    /// geometry no real window reaches.
    ///
    /// **Root cause, confirmed against this exact function, not merely
    /// argued from its doc comment.** At `actionCount` 5, the ladder has
    /// only `[(1, 230)]` to try, and — ladder-major, Controls-minor —
    /// tries it SHOWN first: at `bandWidth` 1200, that succeeds
    /// (`reserved` 508, `actWidth` 668, `controlsShown` true). At
    /// `actionCount` 6, the ladder gains a wider FIRST entry, `(2, 468)`,
    /// tried in both postures before `(1, 230)` ever gets a look — its own
    /// FOLDED attempt succeeds at this `bandWidth` too (`reserved` 492,
    /// `actWidth` 684, `controlsShown` false), and wins because it is
    /// tried first, being the wider entry. `492 < 508`: folding Controls
    /// (−254) frees more than widening the column to 468 costs (+238),
    /// netting the act zone 16 pt WIDER even though the column got
    /// PHYSICALLY WIDER and Controls disappeared — both changes a reader
    /// would expect to cost the act zone room, not hand it back.
    ///
    /// **RETOLD — the row-cap fix's own follow-on revealed this is a
    /// CLASS of defect, not a single crossing, though the pinned numbers
    /// below are untouched by that discovery.** Through the narrow-pair
    /// fix alone, `needsTwo` (then still `actionCount > bandActionsRowCap`)
    /// could only flip at `actionCount` 5→6, because every geometry that
    /// round's own sweep reached had `rows == bandActionsRowCap` (5). The
    /// row-cap fix's whole point is that `rows` is not always 5 — and the
    /// identical mechanism this paragraph documents (folding Controls frees
    /// more than the wider entry costs) fires at ANY crossing where
    /// `needsTwo` flips, `actionCount == rows + 1`, not only at `rows == 5`.
    /// `actZoneNeverWidensAsActionCountGrowsExceptTheDocumentedWindow`'s own
    /// sweep, re-run after the row-cap fix, found it live at `rows` 3 and 4
    /// too (crossings 3→4 and 4→5), both reachable at the SAME `bandWidth ∈
    /// [1152, 1390)` with `usableHeight` clearing `bandControlsHeightClears`
    /// — that test's own carve-out now reads `actionCount == rows + 1`
    /// rather than the static `bandActionsRowCap + 1` for exactly this
    /// reason. `rows` 1 and 2 never combine with `bandControlsHeightClears`
    /// at all (`bandZonePlanRowsBoundaryTable`'s own boundaries put `rows`
    /// 2's own ceiling at usable 252.9, short of the 292 pt floor Controls
    /// needs to clear by height), so crossings 2→3 and below are
    /// structurally unreachable, not merely unswept — this is the FULL
    /// extent of the class, confirmed by the sweep rather than assumed from
    /// the mechanism alone. The fix for the class is the identical fix this
    /// paragraph already declines to make for the single crossing, for the
    /// identical reason — see immediately below.
    ///
    /// **Why this is reported and left, not fixed here.** A real fix
    /// changes WHICH candidate wins at this crossing — a product
    /// judgment sits behind every existing branch of this ladder
    /// (`bandZonePlanCascade`'s own doc comment: "ladder-major,
    /// Controls-minor... a live, judged directive"), and
    /// several review passes were needed to get the EXISTING
    /// ordering right for the `bandWidth`/`usableHeight` axes alone
    /// (`capacityNeverShrinksAsBandWidthGrows`'s own doc comment carries
    /// that history). Re-deriving the ordering yet again, across a
    /// THIRD axis, without a live product call on which of "Controls
    /// stays visible" or "the act zone never widens on session switch"
    /// should win when they conflict, is exactly the kind of change to
    /// leave flagged rather than patch unreviewed: if the fix is not
    /// contained, report it precisely with the failing coordinates.
    ///
    /// **Pinned to the exact numbers a live probe against this function
    /// confirmed** (not merely derived by hand): `bandWidth` 1200,
    /// `usableHeight` 419 (the strip, banner down) — `actionCount` 5 gives
    /// `actWidth` 668, `controlsShown` true, `capacity` 5; `actionCount` 6
    /// gives `actWidth` 684, `controlsShown` false, `capacity` 10. The
    /// window's own two edges, also confirmed directly: `bandWidth` 1152
    /// exactly (the narrow entry's own shown threshold) widens by the
    /// full 16 pt already (`620` → `636`); `bandWidth` 1390 exactly (the
    /// wide entry's own shown threshold) no longer widens at all (`858` →
    /// `620`, a NARROWING, since `actionCount` 6 can now also show
    /// Controls at the wide entry).
    @Test("KNOWN DEFECT, reported not fixed — the act zone can widen crossing actionCount 5→6, bandWidth [1152,1390), usableHeight >= 292")
    func theActWidthCanWidenAsActionsGrow_knownDefect() {
        let five = OverviewLayout.bandZonePlan(bandWidth: 1200, actionCount: 5, usableHeight: 419)
        let six = OverviewLayout.bandZonePlan(bandWidth: 1200, actionCount: 6, usableHeight: 419)
        #expect(five.actWidth == 668, Comment(rawValue: "got \(five.actWidth)"))
        #expect(five.controlsShown == true, Comment(rawValue: "got \(five.controlsShown)"))
        #expect(five.actions?.capacity == 5, Comment(rawValue: "got \(String(describing: five.actions?.capacity))"))
        #expect(six.actWidth == 684, Comment(rawValue: "got \(six.actWidth)"))
        #expect(six.controlsShown == false, Comment(rawValue: "got \(six.controlsShown)"))
        #expect(six.actions?.capacity == 10, Comment(rawValue: "got \(String(describing: six.actions?.capacity))"))
        #expect(six.actWidth > five.actWidth,
                Comment(rawValue: "this IS the defect — actWidth should not have grown from \(five.actWidth) to "
                    + "\(six.actWidth); if this assertion ever fails, the cascade changed shape and this whole "
                    + "pinned test (and the exception window in actZoneNeverWidensAsActionCountGrowsExceptTheDocumentedWindow) "
                    + "needs to be re-examined, not merely deleted"))

        // The window's own two edges, held to the exact flip either side of them.
        let atLeftEdge5 = OverviewLayout.bandZonePlan(bandWidth: 1152.0, actionCount: 5, usableHeight: 419)
        let atLeftEdge6 = OverviewLayout.bandZonePlan(bandWidth: 1152.0, actionCount: 6, usableHeight: 419)
        #expect(atLeftEdge6.actWidth - atLeftEdge5.actWidth == 16,
                Comment(rawValue: "at bandWidth 1152 exactly (the window's own left edge), got a widening of "
                    + "\(atLeftEdge6.actWidth - atLeftEdge5.actWidth), expected exactly 16"))

        let atRightEdge5 = OverviewLayout.bandZonePlan(bandWidth: 1390.0, actionCount: 5, usableHeight: 419)
        let atRightEdge6 = OverviewLayout.bandZonePlan(bandWidth: 1390.0, actionCount: 6, usableHeight: 419)
        #expect(atRightEdge6.actWidth <= atRightEdge5.actWidth,
                Comment(rawValue: "at bandWidth 1390 exactly (the window's own right edge, the wide entry's own "
                    + "shown threshold), the widening should already be gone — got actionCount 5 actWidth "
                    + "\(atRightEdge5.actWidth), actionCount 6 actWidth \(atRightEdge6.actWidth)"))
    }

    /// **NOT A DEFECT — a shape change, pinned so nobody mistakes the raw
    /// `capacity` NUMBER dropping for something hiding.** At the exact
    /// `usableHeight` where `rows` crosses from `actionCount − 1` to
    /// `actionCount` (`actionCount ∈ {3, 4, 5}`, wherever the two-column
    /// ladder is width-reachable, `bandWidth ≥ 898`), the column
    /// CONSOLIDATES from two narrow sub-columns to one wide one — `capacity`
    /// (`subColumns × rows`) falls, but the SET actually shown does not,
    /// because the new one-column capacity lands on `actionCount` exactly.
    ///
    /// **The arithmetic, worked, is the whole proof.** Before the crossing,
    /// `rows == actionCount − 1`, `needsTwo` (`actionCount > rows`) true:
    /// two sub-columns, capacity `2 × (actionCount − 1)`. One point of
    /// usable height later, `rows` reaches `actionCount` exactly, `needsTwo`
    /// flips false, one sub-column: capacity `1 × rows`, and `rows ==
    /// actionCount` AT THIS EXACT POINT BY THE CROSSING'S OWN DEFINITION —
    /// so the new capacity is `actionCount`, not merely close to it.
    /// `min(actionCount, capacity)` — the actual number of pills a person
    /// sees — is `actionCount` on BOTH sides: `2 × (actionCount − 1) ≥
    /// actionCount` for every `actionCount ≥ 2` (the two-column side was
    /// never showing fewer than the full set either), and the one-column
    /// side hits it exactly. Nothing hides at this crossing, ever — the
    /// EARLIER round's "KNOWN DEFECT #2" framing mistook a drop in an
    /// internal intermediate (`capacity`, the column's own reserved
    /// headroom) for a drop in what the property that actually matters —
    /// `capacity >= actionCount`, nothing offered goes unshown — protects.
    /// `capacityNeverShrinksAsUsableHeightGrows`'s own doc comment carries
    /// the correction of the invariant this test used to be a carve-out
    /// against; this test is what that correction rests on, worked and
    /// pinned rather than merely asserted.
    ///
    /// **Arguably the RIGHT behaviour, not a tolerated one.** Given more
    /// vertical room, one column already holds the whole set — splitting
    /// it across two narrow ones anyway would buy nothing (the same
    /// `actionCount` pills show either way) and cost the pills their own
    /// full width for no reason. Consolidating to one wide column the
    /// moment it can hold everything is the more honest shape, not a
    /// regression this arc merely failed to close.
    ///
    /// **Pinned to the exact numbers a live probe against this function
    /// confirmed**, at `bandWidth` 1200 (comfortably inside every ladder
    /// rung's own reach, so nothing about the pinned numbers is an
    /// artifact of a width boundary), for all three affected `actionCount`s
    /// and their own exact `rows`-crossing `usableHeight` pair:
    /// - `actionCount` 3: usable 252.5 (`rows` 2) → capacity 4, `468×2`;
    ///   usable 253.0 (`rows` 3) → capacity 3, `230×1`. Capacity falls,
    ///   3 of 3 shown both sides.
    /// - `actionCount` 4: usable 304.5 (`rows` 3) → capacity 6, `468×2`;
    ///   usable 305.0 (`rows` 4) → capacity 4, `230×1`. Capacity falls,
    ///   4 of 4 shown both sides.
    /// - `actionCount` 5: usable 356.5 (`rows` 4) → capacity 8, `468×2`;
    ///   usable 357.0 (`rows` 5) → capacity 5, `230×1`. Capacity falls,
    ///   5 of 5 shown both sides.
    @Test("the column consolidates from a narrow pair to one wide column at the rows crossing — capacity falls, nothing shown does")
    func theColumnConsolidatesAtTheRowsCrossingWithNothingHidden() {
        let cases: [(actionCount: Int, beforeUsable: Double, afterUsable: Double,
                     beforeCapacity: Int, afterCapacity: Int, beforeColumnWidth: Double, afterColumnWidth: Double)] = [
            (3, 252.5, 253.0, 4, 3, OverviewLayout.bandActionsWideColumnWidth, OverviewLayout.bandSideColumnWidth),
            (4, 304.5, 305.0, 6, 4, OverviewLayout.bandActionsWideColumnWidth, OverviewLayout.bandSideColumnWidth),
            (5, 356.5, 357.0, 8, 5, OverviewLayout.bandActionsWideColumnWidth, OverviewLayout.bandSideColumnWidth),
        ]
        for testCase in cases {
            let before = OverviewLayout.bandZonePlan(bandWidth: 1200, actionCount: testCase.actionCount,
                                                      usableHeight: testCase.beforeUsable)
            let after = OverviewLayout.bandZonePlan(bandWidth: 1200, actionCount: testCase.actionCount,
                                                     usableHeight: testCase.afterUsable)
            #expect(before.actions?.capacity == testCase.beforeCapacity,
                    Comment(rawValue: "actionCount \(testCase.actionCount), usable \(testCase.beforeUsable) — got "
                        + "\(String(describing: before.actions?.capacity)), expected \(testCase.beforeCapacity)"))
            #expect(before.actions?.columnWidth == testCase.beforeColumnWidth,
                    Comment(rawValue: "actionCount \(testCase.actionCount), usable \(testCase.beforeUsable) — got "
                        + "columnWidth \(String(describing: before.actions?.columnWidth))"))
            #expect(after.actions?.capacity == testCase.afterCapacity,
                    Comment(rawValue: "actionCount \(testCase.actionCount), usable \(testCase.afterUsable) — got "
                        + "\(String(describing: after.actions?.capacity)), expected \(testCase.afterCapacity)"))
            #expect(after.actions?.columnWidth == testCase.afterColumnWidth,
                    Comment(rawValue: "actionCount \(testCase.actionCount), usable \(testCase.afterUsable) — got "
                        + "columnWidth \(String(describing: after.actions?.columnWidth))"))
            // The shape genuinely changes — pinned so a future edit that
            // quietly stops consolidating (e.g. an over-eager "fix" for
            // the retired "known defect" framing) is caught here.
            #expect((after.actions?.capacity ?? 0) < testCase.beforeCapacity,
                    Comment(rawValue: "actionCount \(testCase.actionCount): expected capacity to fall from "
                        + "\(testCase.beforeCapacity) (usable \(testCase.beforeUsable)) to less at usable "
                        + "\(testCase.afterUsable) — got \(String(describing: after.actions?.capacity)); if this "
                        + "assertion fails, the cascade stopped consolidating and this pinned test needs "
                        + "re-examining"))
            // The property that actually matters — pinned on BOTH sides of
            // the crossing, not merely asserted in prose: nothing offered
            // is hidden, before the consolidation or after it.
            #expect((before.actions?.capacity ?? 0) >= testCase.actionCount,
                    Comment(rawValue: "actionCount \(testCase.actionCount), usable \(testCase.beforeUsable): "
                        + "nothing should hide before the crossing — capacity "
                        + "\(String(describing: before.actions?.capacity)) should be >= \(testCase.actionCount)"))
            #expect((after.actions?.capacity ?? 0) >= testCase.actionCount,
                    Comment(rawValue: "actionCount \(testCase.actionCount), usable \(testCase.afterUsable): "
                        + "nothing should hide after the crossing either — capacity "
                        + "\(String(describing: after.actions?.capacity)) should be >= \(testCase.actionCount)"))
        }
    }

    /// **KNOWN GAP, real, reported and pinned, not fixed — `needsTwo`'s own
    /// ceiling is `2 × rows`, never `actionCount` itself, so a set LARGER
    /// than that ceiling still hides, whenever `rows < bandActionsRowCap`
    /// (5).** `nothingHidesAsUsableHeightGrows`, immediately above,
    /// protects the property that "growing the window never hides more" —
    /// it says nothing about whether a STARTING point already hides some
    /// of a large set, which this gap is. Two sub-columns cap the column's
    /// own capacity at `2 × rows` regardless of `actionCount` — the
    /// narrow-pair fix's whole point was making that ceiling reachable
    /// wherever a single column already would have been, never raising the
    /// ceiling itself past two sub-columns' worth of rows. Whenever
    /// `actionCount > 2 × rows`, the excess — `actionCount − 2 × rows` — is
    /// exactly as hidden as it always was, folded into the header's own
    /// overflow chip, the honest declared-shortfall path
    /// `DetailBand.yieldedHeaderFold` already exists for.
    ///
    /// **Real, not hypothetical — the deck's own shipped default window,
    /// at `QuickAction.maxOffered` (10) configured actions.** `bandWidth`
    /// 948, usable 279 → `rows` 3 (`bandZonePlanRowsBoundaryTable`'s own
    /// boundary, and `theDefaultWindowShowsAllFiveConfiguredActions`'s own
    /// fixture, restated here at the FULL offered count rather than
    /// `bandActionsRowCap` itself): capacity `2 × 3 = 6`, four of the ten
    /// configured actions hidden. `QuickAction.maxOffered ==
    /// 2 × bandActionsRowCap` (`actionsCapAgreesWithTheColumnGrid`, above)
    /// is exactly why this gap closes ENTIRELY at `rows == bandActionsRowCap`
    /// (5) — the strip's own two real budgets (419, 359) both land there,
    /// `rows` 5, capacity `2 × 5 = 10 == maxOffered` exactly, nothing ever
    /// hidden by this ceiling on the deck's own primary hardware. The gap
    /// is real only below that ceiling — a desktop-window-and-narrower
    /// concern, the same framing `bandSqueezed(usableHeight:)`'s own doc
    /// comment already gives the squeezed recipe generally.
    ///
    /// **Why this is reported and left, not fixed here — a design
    /// call, not a contained bug fix.** Closing it means either (a)
    /// spilling into a THIRD sub-column (a design this column has never
    /// drawn, and `columnMajorSplit`'s own column-major fill, the row
    /// height flex, and the narrow-pair identity would all need
    /// re-deriving for), or (b) letting a sub-column grow past
    /// `bandActionsRowCap` (5) rows by shrinking `TouchTarget.minimum`
    /// (44) itself — already, by this file's own file-doc measurement
    /// (`the action grid`'s own header comment above), close to the
    /// smallest a thumb can reliably hit on the strip's own ~225 ppi glass
    /// (≈5.0mm at 44pt, against the HIG's own ≈6.9mm assumption). Either
    /// is a real trade against the deck's home hardware, not a pure
    /// arithmetic fix — a deliberate call, the same "report it precisely
    /// and leave it" discipline this file's other two known items
    /// (`theActWidthCanWidenAsActionsGrow_knownDefect`,
    /// `capacityNeverShrinksAsUsableHeightGrows`'s own documented
    /// consolidation) already follow.
    @Test("KNOWN GAP, reported not fixed — capacity caps at 2×rows, so actionCount > 2×rows still hides below the row ceiling")
    func largeActionSetsCanStillHideBelowFiveRows_knownGap() {
        let bandWidth = 1280.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let usableHeight = 300.0 - 21.0
        #expect(bandWidth == 948, "the fixture's own premise — got \(bandWidth)")
        #expect(usableHeight == 279, "the fixture's own premise — got \(usableHeight)")

        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: QuickAction.maxOffered,
                                               usableHeight: usableHeight)
        #expect(plan.actions?.rows == 3,
                Comment(rawValue: "the fixture's own premise — got \(String(describing: plan.actions?.rows))"))
        #expect(plan.actions?.subColumns == 2,
                Comment(rawValue: "got \(String(describing: plan.actions?.subColumns))"))
        #expect(plan.actions?.capacity == 6,
                Comment(rawValue: "2 × 3 rows — got \(String(describing: plan.actions?.capacity))"))
        let hidden = QuickAction.maxOffered - (plan.actions?.capacity ?? 0)
        #expect(hidden == 4,
                Comment(rawValue: "this IS the real, unfixed gap — \(QuickAction.maxOffered) configured, only "
                    + "\(String(describing: plan.actions?.capacity)) showable, \(hidden) folded into the "
                    + "header's overflow chip on the deck's own shipped default window"))

        // The ceiling closes entirely at rows == bandActionsRowCap (5) —
        // the strip's own real budgets both land there — worked
        // explicitly so the gap's own boundary is pinned, not merely
        // asserted to exist "somewhere below 5."
        let atTheCeiling = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: QuickAction.maxOffered,
                                                        usableHeight: QuestionOptionsBand.usableStripHeight)
        #expect(atTheCeiling.actions?.rows == OverviewLayout.bandActionsRowCap,
                Comment(rawValue: "the fixture's own premise — got \(String(describing: atTheCeiling.actions?.rows))"))
        #expect(atTheCeiling.actions?.capacity == QuickAction.maxOffered,
                Comment(rawValue: "at rows == bandActionsRowCap the ceiling exactly meets maxOffered — got "
                    + "\(String(describing: atTheCeiling.actions?.capacity)), expected \(QuickAction.maxOffered) "
                    + "— nothing hidden on the strip's own real budgets"))
    }
}
