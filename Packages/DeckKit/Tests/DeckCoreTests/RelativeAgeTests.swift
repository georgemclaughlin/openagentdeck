//
//  RelativeAgeTests.swift · Tests/DeckCoreTests
//
//  `RelativeAge.label(of:now:)` — every threshold and every boundary named
//  rather than waited for, which is the property `DeckCore`'s own
//  no-clock rule buys.
//

import Testing
@testable import DeckCore

struct RelativeAgeTests {

    /// Two instants `millis` apart, the later one being "now".
    private static func label(after millis: Int64) -> String {
        RelativeAge.label(of: Instant(sinceStart: Millis(0)),
                          now: Instant(sinceStart: Millis(millis)))
    }

    @Test("under a minute reads just now")
    func underAMinute() {
        #expect(Self.label(after: 0) == "just now")
        #expect(Self.label(after: 59_999) == "just now")
    }

    @Test("the minute boundary flips exactly at 60s, not near it")
    func minuteBoundary() {
        #expect(Self.label(after: RelativeAge.minute - 1) == "just now")
        #expect(Self.label(after: RelativeAge.minute) == "1m ago")
    }

    @Test("minutes, truncated — never rounded up, so an age is never overstated")
    func minutesTruncate() {
        #expect(Self.label(after: 5 * RelativeAge.minute) == "5m ago")
        #expect(Self.label(after: 5 * RelativeAge.minute + 59_999) == "5m ago",
                "59.999s past the 5m mark is still 5m — rounding to 6m would tell a person the summary is older than it is")
        #expect(Self.label(after: RelativeAge.hour - 1) == "59m ago")
    }

    @Test("the hour boundary flips exactly at 60m")
    func hourBoundary() {
        #expect(Self.label(after: RelativeAge.hour) == "1h ago")
        #expect(Self.label(after: 2 * RelativeAge.hour) == "2h ago")
    }

    @Test("hours truncate too, right up to the day boundary")
    func hoursTruncate() {
        #expect(Self.label(after: 2 * RelativeAge.hour + 59 * RelativeAge.minute) == "2h ago")
        #expect(Self.label(after: RelativeAge.day - 1) == "23h ago")
    }

    @Test("the day boundary flips exactly at 24h")
    func dayBoundary() {
        #expect(Self.label(after: RelativeAge.day) == "1d ago")
        #expect(Self.label(after: 3 * RelativeAge.day + 5 * RelativeAge.hour) == "3d ago")
    }

    @Test("a future instant — clock skew between the transcript's wall time and the runtime's own base — reads just now, never a negative age")
    func futureInstantClamps() {
        #expect(RelativeAge.label(of: Instant(sinceStart: Millis(10_000)),
                                  now: Instant(sinceStart: Millis(0))) == "just now")
    }
}
