//
//  ReorderMathTests.swift · Tests/DeckCoreTests
//
//  The edit-mode reorder's pure arithmetic, isolated from any gesture, view,
//  or clock — `ReorderMath.swift`'s own file doc states why none of that
//  belongs here. Four things get exercised: the drag glue's self-canceling
//  algebra, the midline-hysteresis retarget table, `Array.moveElement`'s
//  final-index contract, and `wiggleSeed`'s determinism/bounds/distinctness
//  (plus one exact-value pin, the same doctrine `CardColorTests
//  .fallbackSlotIsPinned` already applies to `CardColor.fallbackSlot`).
//

import Testing
import DeckCore
import Foundation

struct ReorderMathTests {

    // -------------------------------------------------------- drag glue

    @Test("dragRenderOffset is self-canceling: the rendered position is always finger minus the original grab offset, whatever the live slot currently is")
    func dragRenderOffsetIsSelfCanceling() {
        let grabOffset = CGSize(width: 12, height: 30)
        // Three frames, each with a different finger position AND a
        // different live slot origin — the second and third simulate the
        // slot having just jumped because the array moved (a retarget
        // landed) and because a reorder crossed a row, not merely a
        // continuous drag.
        let frames: [(finger: CGPoint, slot: CGRect)] = [
            (CGPoint(x: 100, y: 60), CGRect(x: 20, y: 20, width: 300, height: 200)),
            (CGPoint(x: 250, y: 90), CGRect(x: 332, y: 20, width: 300, height: 200)),
            (CGPoint(x: 400, y: 130), CGRect(x: 20, y: 232, width: 300, height: 200)),
        ]
        for (finger, slot) in frames {
            let offset = ReorderMath.dragRenderOffset(finger: finger, liveSlotFrame: slot,
                                                       grabOffsetInCard: grabOffset)
            let rendered = CGPoint(x: slot.origin.x + offset.width, y: slot.origin.y + offset.height)
            #expect(rendered.x == finger.x - grabOffset.width,
                    "frame with slot \(slot) did not cancel to finger.x - grabOffset.width")
            #expect(rendered.y == finger.y - grabOffset.height,
                    "frame with slot \(slot) did not cancel to finger.y - grabOffset.height")
        }
    }

    // ------------------------------------------------------------ retarget

    /// Two slots side by side, centers at (50,50) and (150,50) — the
    /// midline between them sits at x=100.
    private var twoSlotOrder: [String] { ["a", "b"] }
    private var twoSlots: [String: CGRect] {
        ["a": CGRect(x: 0, y: 0, width: 100, height: 100),
         "b": CGRect(x: 100, y: 0, width: 100, height: 100)]
    }

    @Test("crossing the midline toward a neighbor retargets; stopping short of it does not — both directions")
    func retargetRespectsTheMidline() {
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 80, y: 50)) == nil,
                "short of the midline retargeted anyway")
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 120, y: 50)) == 1,
                "past the midline did not retarget")

        // The same boundary, dragged the other way.
        #expect(ReorderMath.retargetIndex(currentIndex: 1, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 120, y: 50)) == nil,
                "short of the midline retargeted anyway, dragging right to left")
        #expect(ReorderMath.retargetIndex(currentIndex: 1, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 80, y: 50)) == 0,
                "past the midline did not retarget, dragging right to left")
    }

    @Test("the equidistant boundary itself does not retarget — no flapping right at the midline")
    func retargetDoesNotFlapAtTheExactMidline() {
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 100, y: 50)) == nil)
    }

    @Test("the finger sitting over its own current slot answers nil, not its own index")
    func retargetAtSameIndexIsNil() {
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 50, y: 50)) == nil)
    }

    @Test("an out-of-bounds currentIndex answers nil rather than crashing — the caller's index into a draft that just shrank")
    func retargetWithOutOfBoundsCurrentIndexIsNil() {
        #expect(ReorderMath.retargetIndex(currentIndex: 5, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 150, y: 50)) == nil)
        #expect(ReorderMath.retargetIndex(currentIndex: -1, order: twoSlotOrder, slots: twoSlots,
                                          finger: CGPoint(x: 150, y: 50)) == nil)
    }

    @Test("a missing slot entry answers nil rather than crashing — whichever side has not reported a frame yet")
    func retargetWithMissingSlotEntryIsNil() {
        // "b" never reported a frame — onGeometryChange has not fired for
        // it yet.
        let candidateMissing: [String: CGRect] = ["a": CGRect(x: 0, y: 0, width: 100, height: 100)]
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: twoSlotOrder, slots: candidateMissing,
                                          finger: CGPoint(x: 150, y: 50)) == nil)

        // Neither side has reported yet.
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: twoSlotOrder, slots: [:],
                                          finger: CGPoint(x: 150, y: 50)) == nil)
    }

    /// **The wedge, as a test: one unrendered card used to kill every
    /// retarget in the fleet.**
    ///
    /// `nearestID` used to score a missing slot as `slots[id]?.center ??
    /// finger` — the finger's own position, so distance ZERO, so an
    /// unmeasured card won every comparison it entered. `retargetIndex`
    /// then asked that winner for the centre it does not have (not having
    /// one is exactly why it won) and returned nil. The card lifted, glued
    /// to the finger, and nothing ever moved.
    ///
    /// The fleet is a `LazyHGrid`, so every card past the fold is precisely
    /// this: unrendered, no `.onGeometryChange`, no slot. Any fleet wider
    /// than the window had at least one, which is the fleet this deck was
    /// built for — twenty sessions on a strip that shows three or four.
    /// "c" below is that card.
    @Test("a card past the fold, with no slot of its own, does not hijack the retarget — the drag still reorders the cards that ARE on the glass")
    func retargetIgnoresUnrenderedCards() {
        let order = ["a", "b", "c"]
        // Only "a" and "b" have been laid out; "c" is off the fold.
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: order, slots: twoSlots,
                                          finger: CGPoint(x: 120, y: 50)) == 1,
                "an unrendered card swallowed the retarget — the drag cannot reorder at all")
        // And the hysteresis it protects still holds with that card present.
        #expect(ReorderMath.retargetIndex(currentIndex: 0, order: order, slots: twoSlots,
                                          finger: CGPoint(x: 80, y: 50)) == nil,
                "short of the midline retargeted anyway")
    }

    @Test("nearestID considers only ids that actually reported a frame")
    func nearestIDSkipsSlotlessIDs() {
        #expect(ReorderMath.nearestID(finger: CGPoint(x: 140, y: 50),
                                      order: ["a", "b", "c"], slots: twoSlots) == "b")
        #expect(ReorderMath.nearestID(finger: CGPoint(x: 10, y: 50),
                                      order: ["c", "a", "b"], slots: twoSlots) == "a")
        // Nothing measured at all is genuinely no answer, not an arbitrary id.
        #expect(ReorderMath.nearestID(finger: .zero, order: ["a", "b"], slots: [String: CGRect]()) == nil)
    }

    // ---------------------------------------------------------- moveElement

    @Test("moveElement(from:0,to:3) on [1,2,3,4,5] gives [2,3,4,1,5] — the pin the prototype's own selftest caught a real defect against")
    func moveElementPinnedCase() {
        var array = [1, 2, 3, 4, 5]
        array.moveElement(from: 0, to: 3)
        #expect(array == [2, 3, 4, 1, 5])
    }

    @Test("moveElement is a no-op when from equals to")
    func moveElementIdentityWhenFromEqualsTo() {
        var array = [1, 2, 3, 4, 5]
        array.moveElement(from: 2, to: 2)
        #expect(array == [1, 2, 3, 4, 5])
    }

    @Test("moveElement no-ops on an out-of-bounds index rather than crashing", arguments: [
        (from: -1, to: 2), (from: 5, to: 2), (from: 2, to: -1), (from: 2, to: 6),
        // `to == count` is REJECTED, not clamped — the doc's "ends up AT
        // index `to`" promise holds literally for every accepted input.
        // An earlier clamp landed this at 4.
        (from: 0, to: 5),
    ])
    func moveElementOutOfBoundsIsANoOp(_ pair: (from: Int, to: Int)) {
        var array = [1, 2, 3, 4, 5]
        array.moveElement(from: pair.from, to: pair.to)
        #expect(array == [1, 2, 3, 4, 5])
    }

    // ------------------------------------------------------------ wiggleSeed

    @Test("wiggleSeed answers the same personality twice, for the same identity")
    func wiggleSeedIsDeterministicForTheSameIdentity() {
        #expect(ReorderMath.wiggleSeed(for: "surface-A") == ReorderMath.wiggleSeed(for: "surface-A"))
    }

    @Test("wiggleSeed periods stay within the half-cycle's own ± variance, and phases stay in [0,1), across a spread of identities")
    func wiggleSeedStaysInBounds() {
        let rotationRange = (ReorderMath.wiggleRotationHalfCycle - ReorderMath.wiggleTimingVariance) * 2
            ... (ReorderMath.wiggleRotationHalfCycle + ReorderMath.wiggleTimingVariance) * 2
        let bounceRange = (ReorderMath.wiggleBounceHalfCycle - ReorderMath.wiggleTimingVariance) * 2
            ... (ReorderMath.wiggleBounceHalfCycle + ReorderMath.wiggleTimingVariance) * 2
        for i in 0..<200 {
            let seed = ReorderMath.wiggleSeed(for: "fixture-surface-\(i)")
            #expect(rotationRange.contains(seed.rotationPeriod),
                    "fixture-surface-\(i) rotation period \(seed.rotationPeriod) out of bounds")
            #expect(bounceRange.contains(seed.bouncePeriod),
                    "fixture-surface-\(i) bounce period \(seed.bouncePeriod) out of bounds")
            #expect((0..<1).contains(seed.rotationPhase),
                    "fixture-surface-\(i) rotation phase \(seed.rotationPhase) outside [0,1)")
            #expect((0..<1).contains(seed.bouncePhase),
                    "fixture-surface-\(i) bounce phase \(seed.bouncePhase) outside [0,1)")
        }
    }

    @Test("nine invented surfaces draw at least eight distinct rotation phases — the seeding is not degenerate")
    func wiggleSeedDrawsDistinctPhasesAcrossNineIdentities() {
        let seeds = (0..<9).map { ReorderMath.wiggleSeed(for: "fixture-surface-\($0)") }
        #expect(Set(seeds.map(\.rotationPhase)).count >= 8,
                "nine identities drew fewer than eight distinct rotation phases; seeding is degenerate")
    }

    /// Pinned against a real run, not derived from the algorithm's own
    /// description — a hash-implementation change (a different constant, a
    /// different algorithm entirely) must fail this loudly rather than
    /// silently reshuffle every card's wiggle rhythm on the next relaunch,
    /// which a test that re-derives the expectation from the same code
    /// could never catch. Values recorded from one real run of
    /// `ReorderMath.wiggleSeed(for: "surface-A")`, the same pinning
    /// doctrine `CardColorTests.fallbackSlotIsPinned` already applies to
    /// `CardColor.fallbackSlot`.
    @Test("wiggleSeed is pinned for a known identity")
    func wiggleSeedIsPinned() {
        let seed = ReorderMath.wiggleSeed(for: "surface-A")
        #expect(seed.rotationPeriod == 0.23219684608074379)
        #expect(seed.bouncePeriod == 0.33340520288902065)
        #expect(seed.rotationPhase == 0.31179785027341367)
        #expect(seed.bouncePhase == 0.5826774498429557)
    }
}
