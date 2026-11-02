//
//  TouchTargetTests.swift · Tests/DeckAppTests
//
//  Every control a finger is meant to hit, measured as it actually renders.
//
//  `NSHostingView.fittingSize` lays a view out for real and reports what came
//  back, with no window and no screen — so the thing under test is the control
//  SwiftUI draws rather than a number this code computed about it. That is the
//  stronger form of a rule the deleted layout engine used to enforce against
//  rectangles of its own making: an engine can only ever prove its own
//  arithmetic is self-consistent, and what ships is what the framework draws.
//
//  This suite exists because going native regressed touch. A stock SwiftUI
//  button on macOS measures 24 points tall — correct for a pointer, useless
//  for a thumb — and this deck's hardware is a touchscreen.
//

import Testing
import SwiftUI
import AppKit
import DeckCore
@testable import DeckApp

@MainActor
struct TouchTargetTests {

    /// The size a view settles at when laid out for real.
    private func measured(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    // ------------------------------------------------------ the regression

    /// The measurement that started this: the platform's own default is below
    /// the platform's own guideline for touch. Pinned so nobody "simplifies"
    /// the explicit floors away on the grounds that the defaults look fine.
    @Test("a stock button is too small to touch, which is why the floors exist")
    func theUnadornedDefaultIsTooSmall() {
        let stock = measured(Button("Allow") {}.buttonStyle(.glass))
        #expect(stock.height < TouchTarget.minimum,
                Comment(rawValue: "a stock button now measures \(stock.height); if the "
                        + "platform has fixed this, the explicit floors can be revisited"))
    }

    // ------------------------------------------------------------ decisions

    /// Allow and Deny carry the larger floor: every other mis-hit in this app
    /// is recoverable, and refusing a tool call on somebody's behalf is not.
    ///
    /// **Measured on the control the bar actually builds.** The version this
    /// replaces constructed its own
    /// `Button(title).buttonStyle(.glassProminent).touchTarget(...)` and
    /// measured that — a lookalike with the floor reattached by hand, which
    /// clears the floor by construction whatever production does. It passed
    /// for the entire life of a `DecisionBar` whose real Allow and Deny
    /// rendered 57 x 24 pt.
    /// The third leaf — `prominent: false` — is `allowAndRemember`'s button:
    /// same decision floor, `.glass` rather than `.glassProminent`. Added
    /// per this test's own doctrine above — a control the bar can actually
    /// render and this suite never measured is the exact gap that let Allow
    /// and Deny ship at 24 pt in the first place.
    @Test("the decision buttons clear the decision floor",
          arguments: [("1. Yes", false, true), ("3. No", true, true),
                      ("2. Yes, and don't ask again for: git push *", false, false)])
    func decisionButtonsAreBigEnough(_ title: String, _ destructive: Bool, _ prominent: Bool) {
        let size = measured(DecisionBar.control(title, destructive: destructive,
                                                 prominent: prominent) {})
        #expect(size.height >= TouchTarget.decision,
                Comment(rawValue: "\(title) is \(size.height) pt tall, floor is \(TouchTarget.decision)"))
        #expect(size.width >= TouchTarget.minimum,
                Comment(rawValue: "\(title) is \(size.width) pt wide"))
    }

    /// The overflow chip — not a decision control (it toggles what the well
    /// shows, it does not resolve the hold), so the general 44 pt floor
    /// applies rather than the 64 pt decision one. `SubjectWell
    /// .overflowChip` is the one place it is built, the same reason
    /// `DecisionBar.control` exists for Allow/Deny/suggestion — a lookalike
    /// button here would clear the floor by construction and prove nothing
    /// about the one that ships.
    @Test("the subject overflow chip clears the general touch floor",
          arguments: ["▾ 8 more lines", "▴ collapse"])
    func overflowChipIsBigEnough(_ title: String) {
        let size = measured(SubjectWell.overflowChip(title) {})
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "\"\(title)\" is \(size.height) pt tall, floor is \(TouchTarget.minimum)"))
        #expect(size.width >= TouchTarget.minimum,
                Comment(rawValue: "\"\(title)\" is \(size.width) pt wide"))
    }

    /// The auto-continue switch, on the band's own no-scroll strip. A stock
    /// `.switch` toggle renders 24 pt tall — a pointer's target, not a
    /// thumb's — and this one measured 229 x 24 before it was given a floor.
    @Test("the auto-continue switch clears the general floor")
    func theAutoContinueSwitchIsBigEnough() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("s1"), at: Instant(sinceStart: Millis(0)),
                            kind: .sessionStart, session: SessionID("alpha"),
                            cwd: Redacted("/w/alpha"), tool: nil, toolUseID: nil,
                            held: .absent,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .sessionSelected(SessionID("alpha"), at: Instant(sinceStart: Millis(1))),
        ]))
        #expect(runtime.frame.autoContinuable,
                "the fixture does not produce a toggle, so nothing below is measured")

        let size = measured(AutoContinueToggle(runtime: runtime))
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "the switch is \(size.height) pt tall"))
    }

    /// A palette swatch in the card-colour picker — measured on
    /// `CardColorPicker.swatch`, the exact static builder production
    /// composes (that function's own doc comment states the doctrine this
    /// follows: a lookalike built inside the test would clear the floor by
    /// construction and prove nothing).
    @Test("a card colour swatch clears the general touch floor", arguments: [false, true])
    func cardColorSwatchesAreBigEnough(_ isCurrent: Bool) {
        let size = measured(CardColorPicker.swatch(for: .slot(0), isCurrent: isCurrent) {})
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "a swatch is \(size.height) pt tall"))
        #expect(size.width >= TouchTarget.minimum,
                Comment(rawValue: "a swatch is \(size.width) pt wide"))
    }

    /// The worn-swatch dot sits INSIDE the swatch's own fixed
    /// 32×32 circle — `.touchTarget()` pads the frame up from whatever is
    /// drawn inside it, so a small indicator drawn at the bottom edge must
    /// not be the thing that quietly shrinks the floor back down. Both
    /// `worn` states measured, same doctrine as the `isCurrent` spread
    /// just above.
    @Test("a worn card colour swatch still clears the general touch floor", arguments: [false, true])
    func wornCardColorSwatchesAreBigEnough(_ worn: Bool) {
        let size = measured(CardColorPicker.swatch(for: .slot(0), isCurrent: false, worn: worn) {})
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "a worn=\(worn) swatch is \(size.height) pt tall"))
        #expect(size.width >= TouchTarget.minimum,
                Comment(rawValue: "a worn=\(worn) swatch is \(size.width) pt wide"))
    }

    /// A quick action is a pill now, not a fixed cell — but it still has to
    /// clear a real touch floor, and the floor is `OverviewLayout
    /// .actionPillHeight` (64), the strip-physics floor the whole pill
    /// retune exists for, not the general 44.
    ///
    /// Measured on `QuickActionBar.control`, the recipe `SettingsView`'s own
    /// live quick-action preview builds a real pill from. The version this
    /// replaces made its own
    /// `Button("Continue").buttonStyle(.glass).touchTarget(minWidth: 88)` —
    /// the same lookalike mistake that let Allow and Deny ship at 24 pt, in a
    /// second place, found only because somebody stripped the floor off the
    /// real control and watched the test go on passing.
    ///
    /// **Height is `== actionPillHeight` exactly, width `==` the imposed
    /// measured width exactly — not merely `>=` either.** `control` imposes
    /// both dimensions exactly now (`OverviewLayout.actionPillHeight`'s own
    /// doc comment, and `control`'s own, state why: truncation needs a real
    /// constraint to truncate against, and the rendered pill and the layout
    /// arithmetic have to agree on the identical number). `measuredWidth` is
    /// read through `ActionPillMeasurer.width(for:)` — the SAME measurer
    /// `SettingsView`'s own call reads — so this test measures the real
    /// control at the real number, not a width invented for the test alone.
    @Test("a quick action clears the pill's own touch floor", arguments: [false, true])
    func quickActionsAreBigEnough(_ alarming: Bool) {
        let measuredWidth = ActionPillMeasurer.width(for: "Continue")
        let size = measured(QuickActionBar.control("Continue", alarming: alarming, measuredWidth: measuredWidth) {})
        // `Double(size.height)`, not a bare `==` — `CGFloat == Double` is
        // the real, surprising `#expect` macro trap `bandFitsTheStripWorstCaseDecision`'s
        // own comment (`RenderSweepTests.swift`) already names: the plain
        // operator returns `true`, but swift-testing's expression capture
        // for a mixed-type `==` reports the expectation FAILED anyway.
        #expect(Double(size.height) == OverviewLayout.actionPillHeight,
                Comment(rawValue: "a quick action is \(size.height) pt tall — expected the fixed "
                        + "\(OverviewLayout.actionPillHeight) pt pill height"))
        #expect(Double(size.width) == measuredWidth,
                Comment(rawValue: "a quick action cell is \(size.width) pt wide — expected the imposed "
                        + "\(measuredWidth) pt measured width"))
    }

    /// **The Quick Actions column's own row FRAMES — not the glass drawn
    /// inside them — flexed by `OverviewLayout.bandActionsRowHeight
    /// (columnBudget:rowCount:)` between the general touch floor (44) and
    /// the pinned bar's own full pill height (64), never below the
    /// floor.** This is a FRAME arithmetic check, an integration-level
    /// echo of `bandActionsRowHeight`'s own floor guarantee holding
    /// through the real, composed render (`column(_:rowHeight:)` actually
    /// receiving and applying the value, not merely the pure function
    /// answering it in isolation) — it is NOT a claim that this is where
    /// the real touch target lives. `QuickActionBar.bareControl`'s own
    /// Liquid Glass holds a FIXED 46pt intrinsic height regardless of the
    /// frame around it, comfortably clearing `TouchTarget.minimum` (44) at
    /// every frame this row ever imposes — that fact belongs to the glass,
    /// not the frame, and `RenderSweepTests
    /// .thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight` is
    /// where it is measured directly, on the button's own geometry, and
    /// pinned. This test measures the WORST real shape the FRAME ever has
    /// to survive — five actions (`bandActionsRowCap`, the left
    /// sub-column's own cap), at the routing floor's own tightest live
    /// `columnBudget` (`bandMinimumHeight − bandHeaderHeight`, 310) — the
    /// one live shape where `bandActionsRowHeight` itself answers the
    /// floor rather than flexing above it.
    ///
    /// **Measured by DIFFERENCE no longer — the technique this test used
    /// through the plain-button era does not survive the row-recipe
    /// retune, and pretending otherwise would silently prove nothing.**
    /// That technique compared a one-action column against a two-action
    /// one and subtracted, banking on every row sharing one FIXED height so
    /// the two columns would differ by exactly one row plus a gap. Rows no
    /// longer share a fixed height independent of row count —
    /// `bandActionsRowHeight` divides the SAME interior budget by
    /// `rowCount`, so moving from one action to two does not merely ADD a
    /// row, it also RESHAPES the existing one (a wider budget spread over
    /// fewer rows, both clamped to `actionPillHeight` at the top end,
    /// masked the effect there — but a tight budget where the floor
    /// actually binds would make a from-scratch difference read a false
    /// row height, the exact silent-proof-of-nothing this comment warns
    /// against). Measured DIRECTLY instead: one hosted column, five rows,
    /// the total height backed down to a per-row FRAME figure by
    /// subtracting the KNOWN chrome and inter-row gaps (`OverviewLayout
    /// .bandQuickActionsChrome`, `.actionGridSpacing` — the same constants
    /// `bandActionsRowHeight`'s own doc comment decomposes the whole from)
    /// rather than by differencing two renders against each other.
    @Test("a Quick Actions column row's own FRAME clears the general touch floor at the worst live budget")
    func quickActionsColumnRowsAreBigEnough() {
        let rowCount = OverviewLayout.bandActionsRowCap
        let events: [DeckEvent] = [
            .hook(HookEvent(id: EventID("s1"), at: Instant(sinceStart: Millis(0)), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .sessionSelected(SessionID("alpha"), at: Instant(sinceStart: Millis(1))),
            .prefsChanged(DeckPrefs(quickActions: (0..<rowCount).map {
                QuickAction(id: "a\($0)", title: "Action \($0)", kind: .prompt("go"))
            }), at: Instant(sinceStart: Millis(2))),
        ]
        let r = DeckRuntime()
        r.markStartedForTesting()
        r.replaceStateForTesting(Reducer.run(events))

        let worstBudget = OverviewLayout.bandMinimumHeight - OverviewLayout.bandHeaderHeight
        let plan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandSideColumnWidth,
                                                  subColumns: 1, rows: rowCount)
        let size = measured(QuickActionsColumn(runtime: r, budget: worstBudget, plan: plan)
            .frame(width: OverviewLayout.bandSideColumnWidth))
        let rowFrameHeight = (Double(size.height) - OverviewLayout.bandQuickActionsChrome
                          - Double(rowCount - 1) * OverviewLayout.actionGridSpacing) / Double(rowCount)
        #expect(rowFrameHeight >= TouchTarget.minimum,
                Comment(rawValue: "a Quick Actions column row's own FRAME measured \(rowFrameHeight) pt tall "
                        + "at the worst live budget (\(worstBudget)) — floor is \(TouchTarget.minimum). The "
                        + "glass drawn inside holds a fixed intrinsic height regardless of this frame — see "
                        + "RenderSweepTests.thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight for that "
                        + "fact measured directly"))
    }

    /// **The pill-styled overflow chip — the retired self-rendering bar's
    /// own cell shape for a hidden run of actions, held to its touch floor
    /// even though nothing composes it in production any more.** Not a
    /// decision control, so the pill floor applies the same way an
    /// ordinary action's does, the same reason `SubjectWell.overflowChip`
    /// claims the general 44 pt floor below (a `.plain` chip, a different
    /// affordance entirely). `QuickActionBar.overflowControl` has no
    /// production caller left — the bar it once completed retired with
    /// `.inspector` (`QuickActionBar`'s own doc comment, `DecisionBar.swift`,
    /// states the history in full) — kept, and measured here directly, for
    /// the same reason `ActionPillMeasurer` itself still measures it: a
    /// real, live-styled control worth holding to a floor even as a pure
    /// recipe, the same "measure the real control" doctrine
    /// `quickActionsAreBigEnough`'s own doc comment states, at its own
    /// measured width (`ActionPillMeasurer.chipWidth(hiding:)`).
    @Test("the quick action bar's overflow chip clears the pill's own touch floor")
    func quickActionOverflowChipIsBigEnough() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let hidden = [QuickAction(id: "a1", title: "Action One", kind: .prompt("go")),
                      QuickAction(id: "a2", title: "Action Two", kind: .prompt("go"))]
        let measuredWidth = ActionPillMeasurer.chipWidth(hiding: hidden.count)
        let size = measured(QuickActionBar.overflowControl(hidden: hidden, runtime: runtime,
                                                            measuredWidth: measuredWidth))
        #expect(Double(size.height) == OverviewLayout.actionPillHeight,
                Comment(rawValue: "the overflow chip is \(size.height) pt tall — expected the fixed "
                        + "\(OverviewLayout.actionPillHeight) pt pill height"))
        #expect(Double(size.width) == measuredWidth,
                Comment(rawValue: "the overflow chip is \(size.width) pt wide — expected the imposed "
                        + "\(measuredWidth) pt measured width"))
    }

    /// **`DetailBand.header`'s own full-yield fold, measured directly —
    /// every OTHER tappable control in
    /// this app is pinned here, and the folded header's own chip was not.**
    /// `QuickActionBar.headerOverflowControl`'s own doc comment claims the
    /// GENERAL touch floor (`TouchTarget.minimum`, 44), not the pill's own
    /// 64 — the house chip idiom `SubjectWell.overflowChip` already
    /// claims, matched down to the chrome. `>=`, not `==`, on both axes —
    /// unlike the bar's own pill chip, this control imposes no exact
    /// frame of its own; it hugs its own label at the floor, so the floor
    /// is a MINIMUM here, the same discipline `quickActionOverflowChipIsBigEnough`
    /// above already holds `SubjectWell.overflowChip`'s own sibling to.
    @Test("the header's own full-yield fold clears the general touch floor")
    func headerOverflowControlIsBigEnough() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let hidden = [QuickAction(id: "a1", title: "Action One", kind: .prompt("go")),
                      QuickAction(id: "a2", title: "Action Two", kind: .prompt("go")),
                      QuickAction(id: "a3", title: "Action Three", kind: .prompt("go"))]
        let size = measured(QuickActionBar.headerOverflowControl(hidden: hidden, runtime: runtime))
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "the header's own fold is \(size.height) pt tall"))
        #expect(size.width >= TouchTarget.minimum,
                Comment(rawValue: "the header's own fold is \(size.width) pt wide"))
    }

    // ---------------------------------------------------------------- rows

    /// A card is how a session gets selected — the only way, since the sidebar
    /// it replaced is gone — so it is a touch target like any other.
    @Test("a session card clears the general floor", arguments: LaneState.allCases)
    func sessionCardsAreBigEnough(_ state: LaneState) {
        let lane = LaneView(session: SessionID("aaaaaa11-1111"), state: state,
                            isExpanded: false, contextPercent: 63, sources: [:],
                            directory: Redacted("/Users/you/work/parser"),
                            branch: Redacted("main"))
        let size = measured(SessionCard(lane: lane, name: "work/parser", isSelected: false)
                                .frame(width: OverviewLayout.cardIdealWidth))
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "\(state.rawValue) card is \(size.height) pt tall"))
    }

    /// A waiting card is the one somebody reaches for without looking, so it
    /// gets checked on its own rather than only as one of the states above.
    @Test("a waiting card clears the general floor")
    func waitingCardsAreBigEnough() {
        let lane = LaneView(session: SessionID("aaaaaa11-1111"), state: .needsYou,
                            isExpanded: false, contextPercent: 63, sources: [:],
                            directory: Redacted("/Users/you/work/parser"),
                            branch: Redacted("main"))
        let size = measured(SessionCard(lane: lane, name: "work/parser", isSelected: false)
                                .frame(width: OverviewLayout.cardIdealWidth))
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "a card is \(size.height) pt tall"))
    }

    /// The floors themselves: the decision class must actually be the larger
    /// one, or the distinction is decorative.
    @Test("the decision floor is above the general floor")
    func theFloorsAreOrdered() {
        #expect(TouchTarget.decision > TouchTarget.minimum)
        #expect(TouchTarget.minimum >= 44, "44 is Apple's own guideline; below it is not a floor")
    }
}

/// The surfaces the first pass did not cover.
@MainActor
struct ToolbarAndSettingsTouchTests {

    private func measured(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    /// The usage badge is a READOUT, not a control — there is nothing to press,
    /// so no touch floor applies to it. What does apply is that its meaning may
    /// not depend on hover: `help` needs a pointer, and a touchscreen has none.
    @Test("a usage limit is spoken, not left to a tooltip")
    func theLimitIsInTheSpokenDescription() {
        let limited = UsageIndicator(label: "100% — resets in 1h 20m",
                                     limited: true)
        #expect(limited.spokenDescription.contains("limit"),
                "the limit is announced only on hover, which a touch surface cannot do")
        #expect(limited.spokenDescription.contains(limited.label),
                "the reading itself was dropped from what is spoken")

        let fine = UsageIndicator(label: "62%", limited: false)
        #expect(!fine.spokenDescription.contains("limit"),
                "a healthy account is described as limited")
        #expect(fine.spokenDescription.contains("62%"))
    }

    /// The one Settings control that was too small for any input device. Its
    /// glyph is still small; what grew is what responds to the press.
    @Test("the remove control has a hit area a finger can find")
    func removeControlIsHittable() {
        // The platform's own default, pinned so the enlargement can be
        // revisited if the platform ever fixes it.
        let bare = measured(
            Button { } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless))
        #expect(bare.height < TouchTarget.minimum,
                "the bare control is no longer small; the enlargement may be revisited")

        // And the one Settings actually builds.
        let shipped = measured(DeckSettingsView.removeControl {})
        #expect(shipped.height >= TouchTarget.minimum,
                Comment(rawValue: "the remove control is \(shipped.height) pt tall"))
        #expect(shipped.width >= TouchTarget.minimum)
    }
}
