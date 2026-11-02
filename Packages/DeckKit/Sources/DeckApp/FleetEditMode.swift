//
//  FleetEditMode.swift · DeckApp
//
//  The edit-mode wiggle and drag chrome. `ReorderMath` (`DeckCore`) holds
//  the pure arithmetic and the wiggle's TIMING constants; this file is the
//  render half: the VISUAL tuning knobs (`EditTune`), the `GeometryEffect`
//  that tilts a card (`IconWiggle`), the driver that ticks it
//  (`WiggleDriver`), and the view-local drag state `SessionOverview`
//  threads a gesture through (`CardDrag`).
//
//  Why a `GeometryEffect` ticked by `TimelineView`, not `withAnimation` or
//  `repeatForever`: SwiftUI's animation lifecycle is unreliable ground for
//  a persistent ambient motion that must survive re-mounts (a drag drop)
//  and re-entries (edit mode off, then on).
//    - A shared `repeatForever` clock froze solid on re-mount: a freshly
//      inserted animated modifier reads its TARGET value with no animation
//      attached, with no compile error or warning.
//    - A per-card `repeatForever` restarted from `onAppear` was left dead
//      at a re-created attribute position on every edit-mode re-entry.
//  `WiggleDriver` avoids the animation system: `TimelineView(.periodic)`
//  ticks at `EditTune.wiggleFrameRate`, and each tick computes the pose as
//  a pure function of the date. Nothing starts, cancels or leaks.
//

import SwiftUI
import DeckCore

// MARK: - Tune

/// Every wiggle/drag VISUAL constant in one block, for live tuning. The
/// TIMING constants (`ReorderMath.wiggleRotationHalfCycle` /
/// `.wiggleBounceHalfCycle` / `.wiggleTimingVariance`) live in `DeckCore`
/// and are tested there; never restate those numbers here.
enum EditTune {

    // ------------------------------------------------------------ wiggle

    /// pt of corner-arc travel a wiggling card's corner sweeps through.
    /// The angle is derived FROM this size-independent constant (see
    /// `IconWiggle.effectValue`). A fixed +-2 degrees is fine for a 60pt icon
    /// (~1.5pt at the corners) but throws a 300x202pt card's corners ~7pt,
    /// which reads as violent and mechanical. Holding the travel constant
    /// keeps a big card's tilt subtle while its bounce stays full-throw.
    static let wiggleCornerTravel: Double = 1.5
    /// degrees, ceiling for the derived angle, so a very small view never
    /// over-rotates (defensive floor).
    static let wiggleRotationCap: Double = 2.0
    /// pt, bounce amplitude: oscillates 0...this, upward only (a card lifts
    /// toward the reader, it never sinks).
    static let wiggleBouncePoints: Double = 2.0
    /// seconds, ramp from rest to full amplitude on mount, so entering edit
    /// mode (or a dropped card's re-mount) swells in instead of snapping.
    static let wiggleRampIn: Double = 0.15
    /// Hz, the wiggle's tick rate and THE CPU LEVER. Measured: ~12-15% of
    /// one core for nine glass cards at 30Hz, versus ~45-50% when the
    /// animation system interpolates at the display's full rate (120Hz).
    /// The display rate is irrelevant to how fast a wiggle must tick to
    /// read as organic.
    static let wiggleFrameRate: Double = 30

    // -------------------------------------------------------- lift (drag)

    /// The dragged card's scale-up (the "picked up" read).
    static let liftScale: CGFloat = 1.06
    static let liftShadowRadius: CGFloat = 12
    static let liftShadowOpacity: Double = 0.35
    /// The dragged card's z-index; lifts cleanly above neighbors across
    /// `LazyHGrid` column boundaries (no clipping, no overlay fallback).
    static let liftZIndex: Double = 100

    // ----------------------------------------------------------- gesture

    /// pt, the `DragGesture`'s minimum distance: short enough to feel
    /// immediate, long enough that an ordinary tap never starts a drag.
    static let dragMinimumDistance: CGFloat = 4

    // ------------------------------------------------------- reduce motion

    /// pt, the border a dragged card wears INSTEAD of the scale+shadow lift
    /// under Reduce Motion.
    static let reducedMotionBorderWidth: CGFloat = 2

    // ---------------------------------------------------------- springs

    /// Neighbors reflowing around a retargeted drag.
    static let slide = Animation.spring(response: 0.35, dampingFraction: 0.8)
    /// A dropped card settling into its final slot.
    static let settle = Animation.spring(response: 0.30, dampingFraction: 0.8)
}

// MARK: - Wiggle

/// The wiggle as a render-layer transform: two independent sine
/// oscillators (rotation about the card's center, an upward bounce)
/// evaluated on every `WiggleDriver` tick from a plain clock value.
///
/// Deliberately NO `animatableData` override: the pose is a pure function
/// of `clock`, applied as a jump. Leaving `animatableData` at its default
/// (`EmptyAnimatableData`) makes the transform impossible to animate, even
/// by an ambient transaction, so it cannot be smoothed back into the
/// animation-lifecycle bugs described in the file header.
///
/// Don't wrap this in `.ignoredByLayout()`: `_IgnoredByLayoutEffect` does
/// not forward `animatableData`, so a wrapped, animated `GeometryEffect`
/// evaluates once at its TARGET value and freezes, with no warning. The
/// unwrapped effect is safe for the slot map (`SessionOverview`'s
/// `onGeometryChange`): a `GeometryEffect` transform is render-side and
/// never feeds back into a `proxy.frame(in:)` read, same as `.offset`.
struct IconWiggle: GeometryEffect {
    /// Oscillator time, seconds — any stable epoch; `WiggleDriver` folds
    /// wall-clock time into this before it ever reaches here.
    var clock: Double
    /// 0…1, the mount ramp's own amplitude scale.
    var ramp: Double
    let seed: WiggleSeed

    func effectValue(size: CGSize) -> ProjectionTransform {
        let ramp = min(1, max(0, self.ramp))
        // Size-derived amplitude, corner travel held constant (see
        // `EditTune.wiggleCornerTravel`).
        let halfDiagonal = max(1, hypot(size.width, size.height) / 2)
        let amplitude = min(EditTune.wiggleRotationCap,
                            EditTune.wiggleCornerTravel / halfDiagonal * 180 / .pi)
        let rotation = sin((clock / seed.rotationPeriod + seed.rotationPhase) * 2 * .pi)
            * amplitude * ramp
        let bounce = (sin((clock / seed.bouncePeriod + seed.bouncePhase) * 2 * .pi) + 1) / 2
            * EditTune.wiggleBouncePoints * ramp
        var t = CGAffineTransform(translationX: size.width / 2, y: size.height / 2)
        t = t.rotated(by: rotation * .pi / 180)
        t = t.translatedBy(x: -size.width / 2, y: -size.height / 2)
        t = t.translatedBy(x: 0, y: -bounce)
        return ProjectionTransform(t)
    }
}

/// Drives `IconWiggle` from wall-clock time via `TimelineView` (see the
/// file header for why).
///
/// Fixed shared epoch, not `.now`: every wiggling card's `TimelineView`
/// schedules against the SAME grid (`gridEpoch`), so ticks land on the same
/// instant and the runloop coalesces them into ONE commit per frame.
///
/// Ramp and oscillator phase are SEPARATE inputs from different clocks.
/// `rampEpoch` is `@State`, set once per mount, so a re-mount ramps back in
/// over `EditTune.wiggleRampIn`. Deriving the ramp from the shared clock
/// produced a visible pose-snap at the ramp boundary.
struct WiggleDriver: ViewModifier {
    let seed: WiggleSeed
    /// Set once at mount; any re-mount (drag drop, edit re-entry) gets a
    /// fresh ramp.
    @State private var rampEpoch = Date()

    private static let gridEpoch = Date(timeIntervalSinceReferenceDate: 0)

    func body(content: Content) -> some View {
        TimelineView(.periodic(from: Self.gridEpoch, by: 1 / EditTune.wiggleFrameRate)) { context in
            // Folded before it ever reaches the trig — keeps the argument
            // small and precise across a run that may last hours.
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 3600)
            let ramp = context.date.timeIntervalSince(rampEpoch) / EditTune.wiggleRampIn
            content.modifier(IconWiggle(clock: phase, ramp: ramp, seed: seed))
        }
    }
}

// MARK: - Drag

/// One card's in-flight drag, view-local to `SessionOverview`. Not stored
/// in `DeckCore`: only the DROP's final order (`DeckRuntime.reorder(_:)`)
/// is a fact the reducer or a replay needs.
struct CardDrag: Equatable {
    var session: SessionID
    /// Fixed at grab: where inside the card the finger first touched down
    /// (`ReorderMath.grabOffset(startLocation:cardFrame:)`).
    var grabOffsetInCard: CGSize
    /// Updated every drag frame, in the `"fleet"` named coordinate space.
    var finger: CGPoint
}
