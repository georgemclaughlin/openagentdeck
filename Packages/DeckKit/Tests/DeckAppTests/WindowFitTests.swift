//
//  WindowFitTests.swift · Tests/DeckAppTests
//
//  The window-fit machinery — `DeckRuntime.fitted(_:in:)` and
//  `DeckRuntime.fitDecision(frame:visible:isFitting:)` — held to the deck's
//  own product law: the deck never changes its own window SIZE on its own,
//  not on a screen change, not to "fit", never; no hard caps ever. A user
//  action (dragging, Settings → "Apply Now") is the only thing allowed to
//  resize it. What these two ARE still allowed to do is nudge the window's
//  ORIGIN — position, not size — and only when the part of the title bar
//  that lets the user pick the window up at all has actually gone
//  unreachable; a frame that still offers a grabbable corner is left alone,
//  wherever it sits.
//
//  Both functions are pure (no `NSWindow`, no display cycle), which is the
//  whole reason the re-entrancy crash this machinery also guards against
//  could be reproduced here at all — see `DeckRuntime.fitDecision`'s own
//  doc comment for the crash it exists to prevent.
//

import Testing
import Foundation
@testable import DeckApp

@MainActor
struct WindowFitTests {

    /// A stand-in for the strip's own display — offset from the origin on
    /// purpose, so a test that only passes when `visible.origin == .zero`
    /// cannot hide in here. `maxX == 2020`, `maxY == 530`.
    private let visible = CGRect(x: 100, y: 50, width: 1920, height: 480)

    // ---------------------------------------------------------- size, never

    @Test("fitted never shrinks a window bigger than the screen — regression guard for the deleted min(size, visible) call")
    func fittedNeverShrinksAnOversizedWindow() {
        let oversized = CGRect(x: 500, y: 500, width: 2200, height: 900)
        let result = DeckRuntime.fitted(oversized, in: visible)
        #expect(result.width == oversized.width,
                "width must never shrink to fit — the deck does not resize its own window, ever")
        #expect(result.height == oversized.height,
                "height must never shrink to fit — the deck does not resize its own window, ever")
    }

    @Test("a frame already smaller than the screen and fully on it is returned unchanged")
    func smallerOnScreenFrameIsUntouched() {
        let frame = CGRect(x: 200, y: 100, width: 800, height: 400)
        #expect(DeckRuntime.fitted(frame, in: visible) == frame)
    }

    // ------------------------------------------------ reachable stays put

    // An earlier draft clamped origin unconditionally
    // whenever a frame did not fit `visible` exactly, so an oversized window
    // whose grabbable corner was already on-glass got yanked to a corner it
    // never asked to touch — and since `fitTriggers` fires on every dock
    // toggle, that yank would have been re-fought forever. These two cases
    // are the probes that caught it, reproduced exactly.

    @Test("an overtall window whose title bar is already on-glass is left alone — probe (maxY 400 inside [50, 530])")
    func overtallWindowWithReachableTitleBarIsLeftAlone() {
        // height (900) exceeds visible.height (480), so this frame does NOT
        // fit `visible` — but its top edge (maxY = -500 + 900 = 400) sits
        // comfortably inside [visible.minY 50, visible.maxY 530], nowhere
        // near either tolerance boundary.
        let frame = CGRect(x: 100, y: -500, width: 800, height: 900)
        #expect(frame.maxY == 400)
        #expect(DeckRuntime.fitted(frame, in: visible) == frame)
    }

    @Test("an overwide window ten points in from the left edge is left alone — probe (minX + 10)")
    func overwideWindowTenPointsInFromLeftIsLeftAlone() {
        // width (2200) exceeds visible.width (1920), so this frame does NOT
        // fit `visible` either — but its left edge sits 10 pt onto the
        // glass, nowhere near either tolerance boundary.
        let frame = CGRect(x: visible.minX + 10, y: 100, width: 2200, height: 300)
        #expect(DeckRuntime.fitted(frame, in: visible) == frame)
    }

    // -------------------------------------------------------- origin nudges

    @Test("a frame dragged off every edge slides back until its grabbable corner is reachable, without resizing")
    func offScreenFrameSlidesInWithoutResizing() {
        // Off to the left and above the top: the corner point itself is off
        // both edges, so both axes hit their zero-tolerance branch and land
        // exactly at the screen's own top-left.
        let aboveLeft = CGRect(x: -900, y: 900, width: 800, height: 300)
        let nudgedAboveLeft = DeckRuntime.fitted(aboveLeft, in: visible)
        #expect(nudgedAboveLeft.size == aboveLeft.size)
        #expect(nudgedAboveLeft.origin.x == visible.minX)
        #expect(nudgedAboveLeft.maxY == visible.maxY)

        // Off to the right and below the bottom: nudged only as far as the
        // grab tolerance requires, NOT flush to the opposite edge — the
        // window's own bulk (past `grabWidth`/`grabHeight`) is left hanging
        // off-screen on purpose.
        let belowRight = CGRect(x: 9000, y: -900, width: 500, height: 200)
        let nudgedBelowRight = DeckRuntime.fitted(belowRight, in: visible)
        #expect(nudgedBelowRight.size == belowRight.size)
        #expect(nudgedBelowRight.origin.x == visible.maxX - DeckRuntime.grabWidth)
        #expect(nudgedBelowRight.maxY == visible.minY + DeckRuntime.grabHeight)
    }

    @Test("a window wider than the screen with its corner genuinely off the left edge is pulled in to minX, not shrunk")
    func oversizedWidthWithUnreachableCornerLeftAligns() {
        // origin.x (-500) is off the left edge outright — the zero-tolerance
        // branch — so the corner lands exactly at visible.minX; the right
        // portion (2200 wide against a 1920-wide screen) is left hanging.
        let frame = CGRect(x: -500, y: 100, width: 2200, height: 300)
        let result = DeckRuntime.fitted(frame, in: visible)
        #expect(result.width == frame.width)
        #expect(result.origin.x == visible.minX,
                "an overwide window with its corner off the left edge should be pulled in to minX")
    }

    @Test("a window wider than the screen whose corner has slid past the grab tolerance on the right is pulled back to the tolerance boundary")
    func oversizedWidthWithCornerPastToleranceRealignsToBoundary() {
        let frame = CGRect(x: 9999, y: 100, width: 2200, height: 300)
        let result = DeckRuntime.fitted(frame, in: visible)
        #expect(result.width == frame.width)
        #expect(result.origin.x == visible.maxX - DeckRuntime.grabWidth,
                "the corner should land exactly at the tolerance boundary, not flush at minX")
    }

    @Test("a window taller than the screen with its top genuinely off the top edge is pulled down to the screen's top, not shrunk")
    func oversizedHeightWithUnreachableTopAligns() {
        // origin.y (2000) puts maxY (2900) off the top edge outright — the
        // zero-tolerance branch — so the top lands exactly at visible.maxY;
        // the bottom portion (900 tall against a 480-tall screen) is left
        // hanging.
        let frame = CGRect(x: 100, y: 2000, width: 800, height: 900)
        let result = DeckRuntime.fitted(frame, in: visible)
        #expect(result.height == frame.height)
        #expect(result.maxY == visible.maxY,
                "an overtall window with its top off the top edge should be pulled down to the screen's top")
    }

    @Test("a window taller than the screen whose top has sunk past the grab tolerance is pulled back up to the tolerance boundary")
    func oversizedHeightWithTopPastToleranceRealignsToBoundary() {
        let frame = CGRect(x: 100, y: -5000, width: 800, height: 900)
        let result = DeckRuntime.fitted(frame, in: visible)
        #expect(result.height == frame.height)
        #expect(result.maxY == visible.minY + DeckRuntime.grabHeight,
                "the top should land exactly at the tolerance boundary, not flush at visible.maxY")
    }

    @Test("a window bigger than the screen in both dimensions, genuinely off both edges, pins its top-left corner to the screen's")
    func oversizedInBothDimensionsWithUnreachableCornerPinsTopLeft() {
        let frame = CGRect(x: -500, y: 2000, width: 2200, height: 900)
        let result = DeckRuntime.fitted(frame, in: visible)
        #expect(result.size == frame.size)
        #expect(result.origin.x == visible.minX)
        #expect(result.maxY == visible.maxY)
    }

    // ------------------------------------------------------------ boundary

    @Test("the tolerance boundaries themselves are the last reachable position, not the first unreachable one — a strict inequality, not <=/>=")
    func toleranceBoundariesAreReachable() {
        // x, at exactly the left edge: reachable, left alone.
        let atMinX = CGRect(x: visible.minX, y: 100, width: 2200, height: 300)
        #expect(DeckRuntime.fitted(atMinX, in: visible) == atMinX)

        // x, at exactly the right-hand tolerance boundary: reachable, left alone.
        let atGrabWidthBoundary = CGRect(x: visible.maxX - DeckRuntime.grabWidth, y: 100,
                                         width: 2200, height: 300)
        #expect(DeckRuntime.fitted(atGrabWidthBoundary, in: visible) == atGrabWidthBoundary)

        // y, at exactly the top edge (maxY == visible.maxY): reachable, left alone.
        let atMaxY = CGRect(x: 100, y: visible.maxY - 900, width: 800, height: 900)
        #expect(atMaxY.maxY == visible.maxY)
        #expect(DeckRuntime.fitted(atMaxY, in: visible) == atMaxY)

        // y, at exactly the lower tolerance boundary (maxY == visible.minY + grabHeight):
        // reachable, left alone.
        let atGrabHeightBoundary = CGRect(x: 100, y: visible.minY + DeckRuntime.grabHeight - 900,
                                          width: 800, height: 900)
        #expect(atGrabHeightBoundary.maxY == visible.minY + DeckRuntime.grabHeight)
        #expect(DeckRuntime.fitted(atGrabHeightBoundary, in: visible) == atGrabHeightBoundary)
    }

    // ------------------------------------------------------------ algebra

    @Test("fitted is idempotent — a second pass over an already-nudged frame changes nothing")
    func fittedIsIdempotent() {
        let frames = [
            CGRect(x: -900, y: 900, width: 800, height: 300),
            CGRect(x: 9000, y: -900, width: 500, height: 200),
            CGRect(x: -500, y: 2000, width: 2200, height: 900),
        ]
        for frame in frames {
            let once = DeckRuntime.fitted(frame, in: visible)
            let twice = DeckRuntime.fitted(once, in: visible)
            #expect(twice == once,
                    Comment(rawValue: "fitted(fitted(\(frame), in: visible)) should equal "
                            + "fitted(\(frame), in: visible)) — got \(twice) vs \(once)"))
        }
    }

    @Test("fitted is translation-invariant — sliding both the window and the screen by the same vector slides the answer by the same vector")
    func fittedIsTranslationInvariant() {
        let frame = CGRect(x: 9000, y: -900, width: 500, height: 200)
        let dx: CGFloat = 4000
        let dy: CGFloat = -1200
        let direct = DeckRuntime.fitted(frame, in: visible)
        let translated = DeckRuntime.fitted(frame.offsetBy(dx: dx, dy: dy),
                                            in: visible.offsetBy(dx: dx, dy: dy))
        #expect(translated == direct.offsetBy(dx: dx, dy: dy))
    }

    // ------------------------------------------------------------ decision

    @Test("fitDecision leaves an already-fitting frame alone")
    func fitDecisionLeavesFittingFrameAlone() {
        let frame = CGRect(x: 200, y: 100, width: 800, height: 300)
        #expect(DeckRuntime.fitDecision(frame: frame, visible: visible, isFitting: false) == .leaveAlone)
    }

    @Test("fitDecision leaves an oversized-but-reachable frame alone too — the same probe, through the decision layer")
    func fitDecisionLeavesReachableOversizedFrameAlone() {
        let frame = CGRect(x: visible.minX + 10, y: 100, width: 2200, height: 300)
        #expect(DeckRuntime.fitDecision(frame: frame, visible: visible, isFitting: false) == .leaveAlone)
    }

    @Test("fitDecision reports a reposition for a frame that needs nudging, and the target's size matches the input exactly")
    func fitDecisionRepositionsWhenNeeded() {
        let frame = CGRect(x: -500, y: 100, width: 800, height: 300)
        let decision = DeckRuntime.fitDecision(frame: frame, visible: visible, isFitting: false)
        guard case .reposition(let target) = decision else {
            Issue.record("expected .reposition, got \(decision)")
            return
        }
        #expect(target.size == frame.size, "a reposition must never change size — that is the whole law")
        #expect(target.origin.x == visible.minX)
    }

    @Test("a second fitDecision over an already-repositioned frame answers .leaveAlone — the fitter does not fight the user after the first nudge")
    func secondFitDecisionOverRepositionedFrameLeavesAlone() {
        let frame = CGRect(x: -500, y: 100, width: 800, height: 300)
        guard case .reposition(let target) = DeckRuntime.fitDecision(
            frame: frame, visible: visible, isFitting: false) else {
            Issue.record("expected the first fitDecision to reposition")
            return
        }
        #expect(DeckRuntime.fitDecision(frame: target, visible: visible, isFitting: false) == .leaveAlone)
    }

    @Test("fitDecision's isFitting guard blocks a second fit while one is already in flight — the re-entrancy fix")
    func fitDecisionGuardsReentrancy() {
        // Same frame `fitDecisionRepositionsWhenNeeded` proves WOULD reposition
        // when not guarded — the guard is what's under test here, not the frame.
        let frame = CGRect(x: -500, y: 100, width: 800, height: 300)
        #expect(DeckRuntime.fitDecision(frame: frame, visible: visible, isFitting: true) == .leaveAlone,
                "mid-fit, fitDecision must answer .leaveAlone regardless of the frame — reentering AppKit's layout is the crash this guards against")
    }
}
