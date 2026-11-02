//
//  ReorderMath.swift · DeckCore/Model
//
//  The edit-mode reorder's pure vocabulary: drag glue, midline-hysteresis
//  retargeting, the final-index array move, and the per-card wiggle
//  personality. Lanes are keyed by a generic `ID: Hashable` (the deck uses
//  `SessionID`), and the wiggle seed's identity is a STRING (a surface or
//  session id) folded through FNV-1a 64 before a SplitMix64 draw chain.
//
//  Nothing here touches SwiftUI, a gesture, or a view (`DragGesture`,
//  `onGeometryChange`, `TimelineView` live in DeckApp). This file is the
//  arithmetic underneath, tested directly rather than through a live gesture.
//
//  The wiggle timing constants (`wiggleRotationHalfCycle`,
//  `wiggleBounceHalfCycle`, `wiggleTimingVariance`) are the reverse-engineered
//  SpringBoard numbers: rotation ±2° at a 0.14s half-cycle and a vertical
//  0→2pt bounce at a 0.18s half-cycle, each duration independently
//  randomized ±0.025s PER ICON. Two incommensurate, per-card-randomized
//  oscillators drifting against each other give the organic look; one synced
//  circular motion (same period, different phase) reads as home-made. Purely
//  visual constants (corner travel, rotation cap, ramp-in, frame rate, lift,
//  springs) live in the view layer, not here.
//

import Foundation
import CoreGraphics

/// Pure reorder math — grab/drag glue, midline-hysteresis retargeting,
/// distance, and the wiggle seed. Every function here is a formula, not a
/// policy: none of them read a clock, none of them touch a view, and every
/// one is exercised directly by `ReorderMathTests` rather than through a
/// simulated drag.
public enum ReorderMath {

    // ---------------------------------------------------------------- drag

    /// Fixed at grab: where inside the card the finger first touched down.
    public static func grabOffset(startLocation: CGPoint, cardFrame: CGRect) -> CGSize {
        CGSize(width: startLocation.x - cardFrame.origin.x,
               height: startLocation.y - cardFrame.origin.y)
    }

    /// Recomputed every frame from the LIVE slot map — never accumulated.
    /// This is the glue: `liveSlotFrame` changes the instant the array
    /// moves, and this formula absorbs that jump so the card stays under
    /// the finger regardless of where its native grid slot currently is.
    ///
    /// Self-canceling by construction: `nativeOrigin + offset` reduces
    /// algebraically to `finger - grabOffsetInCard` regardless of what
    /// `nativeOrigin` currently is, so the RENDERED position stays pinned
    /// at the finger throughout a reorder, even mid-retarget, even if an
    /// ambient animation happens to also catch the offset's own recompute.
    public static func dragRenderOffset(finger: CGPoint, liveSlotFrame: CGRect,
                                        grabOffsetInCard: CGSize) -> CGSize {
        CGSize(width: finger.x - (liveSlotFrame.origin.x + grabOffsetInCard.width),
               height: finger.y - (liveSlotFrame.origin.y + grabOffsetInCard.height))
    }

    /// The id whose slot CENTER is nearest the finger. Generic over `ID`;
    /// the math reads nothing about an identity beyond its identity.
    ///
    /// **An id with NO slot is skipped, never treated as a slot sitting
    /// under the finger.** Defaulting a missing frame to the finger's own
    /// position scores it at distance zero, so the unmeasured card wins every
    /// comparison; `retargetIndex` then finds no centre for it and returns
    /// `nil`, and NOTHING ever reorders. The fleet is a `LazyHGrid`, so every
    /// card past the fold is such an id (unrendered, hence no
    /// `.onGeometryChange`, hence no slot). Skipping them restricts reordering
    /// to the cards actually on screen.
    public static func nearestID<ID: Hashable>(finger: CGPoint, order: [ID],
                                               slots: [ID: CGRect]) -> ID? {
        var best: (id: ID, distance: CGFloat)?
        for id in order {
            guard let slot = slots[id] else { continue }
            let candidate = distance(finger, slot.center)
            // `>=`, so an exact tie keeps the EARLIER id: the midline
            // hysteresis in `retargetIndex` needs a stable choice at the
            // boundary.
            if let best, candidate >= best.distance { continue }
            best = (id, candidate)
        }
        return best?.id
    }

    /// Nearest-slot retargeting with hysteresis: only cross when the finger
    /// passes the MIDLINE between the current slot's center and the
    /// candidate slot's center — a naive "always nearest" flips back and
    /// forth right at equidistant boundaries, this does not.
    public static func retargetIndex<ID: Hashable>(currentIndex: Int, order: [ID],
                                                    slots: [ID: CGRect], finger: CGPoint) -> Int? {
        guard order.indices.contains(currentIndex) else { return nil }
        guard let nearest = nearestID(finger: finger, order: order, slots: slots),
              let candidateIndex = order.firstIndex(of: nearest),
              candidateIndex != currentIndex,
              let currentCenter = slots[order[currentIndex]]?.center,
              let candidateCenter = slots[order[candidateIndex]]?.center
        else { return nil }

        let midpoint = CGPoint(x: (currentCenter.x + candidateCenter.x) / 2,
                               y: (currentCenter.y + candidateCenter.y) / 2)
        let axis = CGVector(dx: candidateCenter.x - currentCenter.x, dy: candidateCenter.y - currentCenter.y)
        let toFinger = CGVector(dx: finger.x - midpoint.x, dy: finger.y - midpoint.y)
        let dot = axis.dx * toFinger.dx + axis.dy * toFinger.dy
        return dot > 0 ? candidateIndex : nil
    }

    public static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    // ------------------------------------------------------------- wiggle

    /// seconds, rotation half-cycle (full cycle 0.28); see the file header.
    public static let wiggleRotationHalfCycle: Double = 0.14
    /// seconds, bounce half-cycle (full cycle 0.36); the other oscillator.
    public static let wiggleBounceHalfCycle: Double = 0.18
    /// ± per-card half-cycle randomization (seeded, stable). Each
    /// oscillator gets its OWN draw, so no two cards beat together and a
    /// card's rotation never locks to its own bounce.
    public static let wiggleTimingVariance: Double = 0.025

    /// Deterministic per-card wiggle personality, seeded from the card's
    /// STRING identity (a surface or session id) through FNV-1a 64 (the same
    /// hash and constants as `CardColor.fallbackSlot`) and then SplitMix64.
    /// NOT `Hashable.hashValue`, which is per-process seeded by design and
    /// would reshuffle every card's rhythm on every launch. MUST be stable
    /// across launches and platforms.
    public static func wiggleSeed(for identity: String) -> WiggleSeed {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325       // FNV-1a 64-bit offset basis
        for byte in identity.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3        // FNV-1a 64-bit prime
        }
        var state = hash &+ 0x9E37_79B9_7F4A_7C15
        func draw() -> Double {   // uniform in [0, 1)
            state = splitmix64(state)
            return Double(state >> 11) * (1.0 / 9_007_199_254_740_992.0)
        }
        let rotationHalf = wiggleRotationHalfCycle + (draw() * 2 - 1) * wiggleTimingVariance
        let bounceHalf = wiggleBounceHalfCycle + (draw() * 2 - 1) * wiggleTimingVariance
        return WiggleSeed(rotationPeriod: rotationHalf * 2,
                          bouncePeriod: bounceHalf * 2,
                          rotationPhase: draw(),
                          bouncePhase: draw())
    }

    /// One SplitMix64 step — tiny, allocation-free, and good enough
    /// statistics for four draws per card.
    static func splitmix64(_ x: UInt64) -> UInt64 {
        var z = x &+ 0x9E37_79B9_7F4A_7C15
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// One card's wiggle personality: two independent oscillator periods and
/// two independent starting phases, all derived deterministically from the
/// card's identity. Equatable so a caller diffing state can see it never
/// changes mid-session.
public struct WiggleSeed: Equatable {
    public let rotationPeriod: Double   // full cycle, seconds — 0.28 ± up to 0.05
    public let bouncePeriod: Double     // full cycle, seconds — 0.36 ± up to 0.05
    public let rotationPhase: Double    // 0..<1 of a cycle
    public let bouncePhase: Double      // 0..<1 of a cycle
}

extension Array {
    /// Move the element at `from` so it ends up AT index `to` in the
    /// resulting array. Deliberately NOT
    /// `RangeReplaceableCollection.move(fromOffsets:toOffset:)`, whose
    /// pre-removal-index convention is easy to get off by one; this reads as
    /// "final index".
    public mutating func moveElement(from: Int, to: Int) {
        // BOTH indices must be valid FINAL positions: `to == count` is
        // rejected, not clamped (clamping would land it at `count - 1` and
        // break the "ends up AT index `to`" promise). A move never changes
        // the element count, so after the removal `to` is at most the
        // trimmed array's count and the insert is always valid; no
        // from<->to adjustment is needed (`ReorderMathTests` pins this).
        guard from != to, indices.contains(from), indices.contains(to) else { return }
        let element = remove(at: from)
        insert(element, at: to)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
