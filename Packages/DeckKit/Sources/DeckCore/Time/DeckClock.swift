//
//  DeckClock.swift · DeckCore/Time
//
//  One clock, injected, virtual in tests.
//
//  Every duration in this product is a specification (250 ms arm, 400 ms
//  re-arm, 600 ms long-press, 120 s hold, 90 s lights-out, 3.6 s breathe). If
//  any of them read the system clock, its test would take real time or not
//  get written. This file is the mechanism, so no core type needs the wall
//  clock.
//
//  Named `DeckClock` rather than `Clock` to avoid shadowing the stdlib
//  protocol.
//

/// A duration in whole milliseconds.
///
/// Milliseconds rather than `Double` seconds: every spec duration is whole
/// milliseconds or seconds, so an integer clock makes "the arm delay is
/// 250 ms" an exact equality instead of one with a tolerance.
public struct Millis: Hashable, Comparable, Codable, Sendable {
    public var raw: Int64

    public init(_ raw: Int64) { self.raw = raw }

    public static let zero = Millis(0)

    public static func < (a: Millis, b: Millis) -> Bool { a.raw < b.raw }
    public static func + (a: Millis, b: Millis) -> Millis { Millis(a.raw + b.raw) }
    public static func - (a: Millis, b: Millis) -> Millis { Millis(a.raw - b.raw) }
}

/// A point on the deck's own timeline, measured from the moment the core
/// started.
///
/// There is deliberately no initialiser that reads the host clock. `Instant`
/// therefore cannot carry wall time into the core even by accident, which
/// makes the injected-clock rule a property of the type rather than a rule
/// people remember.
public struct Instant: Hashable, Comparable, Codable, Sendable {
    public let sinceStart: Millis

    public init(sinceStart: Millis) { self.sinceStart = sinceStart }

    public static let start = Instant(sinceStart: .zero)

    public static func < (a: Instant, b: Instant) -> Bool { a.sinceStart < b.sinceStart }

    public func advanced(by d: Millis) -> Instant {
        Instant(sinceStart: sinceStart + d)
    }
}

/// The only source of time `DeckCore` may read.
public protocol DeckClock: Sendable {
    var now: Instant { get }
}

/// The clock the core runs on in tests, in replay, and everywhere inside
/// `DeckCore` (which may not read wall time). A real clock exists only in
/// `DeckAdapters`, where reading `Date()` is legal.
public struct VirtualClock: DeckClock {
    public private(set) var now: Instant

    public init(now: Instant = .start) { self.now = now }

    /// Advance by a non-negative duration.
    ///
    /// A clock that can move backwards would let a "not before settle +
    /// 250 ms" assertion pass by rewinding rather than by waiting.
    public mutating func advance(by d: Millis) {
        precondition(d >= .zero, "virtual time does not move backwards")
        now = now.advanced(by: d)
    }
}
