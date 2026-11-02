//
//  VirtualClockTests.swift · Tests/DeckCoreTests
//
//  The first executing test in the product, and its job is smaller than it
//  looks: it exists so that `swift test` is not vacuous.
//
//  An early version shipped a support predicate that returned `all([])` over a file its
//  parser could not read — True over an empty sequence, green over 14 of 29
//  corpus files, proving nothing. A test suite with no tests reports the same
//  green as one that runs, which is why what these assert matters more than
//  that they exist.
//

import Testing
import DeckCore

struct VirtualClockTests {

    /// Designated test for mutation `clock advance becomes a no-op`.
    @Test("advancing moves the clock by exactly the requested amount")
    func advanceIsExact() {
        var clock = VirtualClock()
        #expect(clock.now == .start)

        clock.advance(by: Millis(250))                  // the arm delay
        #expect(clock.now == Instant(sinceStart: Millis(250)))

        clock.advance(by: Millis(120_000))              // the hold budget
        #expect(clock.now == Instant(sinceStart: Millis(120_250)))
    }

    /// Designated test for mutation `advance stops accumulating`.
    ///
    /// Separate from `advanceIsExact` on purpose: a clock that resets to the
    /// last duration rather than accumulating passes any single-step assertion,
    /// and single-step is how a clock test is usually written.
    @Test("time only moves forward, and accumulates")
    func monotonicAndAccumulating() {
        var clock = VirtualClock()
        var seen: [Instant] = [clock.now]

        for step in [Millis(1), Millis(0), Millis(400), Millis(90_000)] {
            clock.advance(by: step)
            seen.append(clock.now)
        }

        #expect(seen == seen.sorted())
        #expect(clock.now == Instant(sinceStart: Millis(90_401)))
    }
}
