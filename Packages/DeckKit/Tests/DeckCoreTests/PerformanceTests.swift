//
//  PerformanceTests.swift · Tests/DeckCoreTests
//
//  What the deck costs, per event and per lane.
//
//  A deck runs for days beside somebody's work. The two ways that goes wrong
//  are a reducer whose cost grows with the history it has already seen, and a
//  projection that allocates a whole frame more often than the screen can show
//  one. Neither shows up in a suite of small cases — every one of them is fast
//  — so they are measured here at sizes the product will actually meet.
//
//  These assert SHAPE, not milliseconds. A wall-clock threshold on a shared
//  machine is a test that fails when somebody else's build starts, and this
//  project has already deleted one suite for depending on the machine it ran
//  on. What is asserted instead is that doubling the work does not
//  quadruple the time, and that retained memory stops growing.
//

import Testing
import Foundation
import DeckCore

struct PerformanceTests {

    private static func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// A stream shaped like a real one: several sessions, prompts, tool calls
    /// and statusline readings interleaved.
    private static func stream(events: Int, sessions: Int) -> [DeckEvent] {
        var out: [DeckEvent] = []
        out.reserveCapacity(events + sessions)
        for s in 0 ..< sessions {
            out.append(.hook(HookEvent(id: EventID("start-\(s)"), at: at(Int64(s)),
                                       kind: .sessionStart, session: SessionID("s\(s)"),
                                       cwd: Redacted("/w/p\(s)"), tool: nil,
                                       toolUseID: nil, held: .absent)))
        }
        for i in 0 ..< events {
            let s = i % sessions
            // **Two seconds apart, not one millisecond.**
            //
            // The generator packed four thousand events into four seconds of
            // virtual time, which is not a deck — it is a deck's whole day
            // replayed at ten thousand times speed. Anything the reducer does
            // on a clock (a retention window, a grace period, a stall watch)
            // is unreachable at that spacing, so the test could not see the
            // housekeeping it was written to check.
            let ms = Int64(1_000 + i * 2_000)
            // **Every fifth event opens a HOLD, and every twentieth opens a
            // question call.**
            //
            // The generator this replaces emitted only `userPromptSubmit` and
            // `postToolUse`, all with `held: .absent` — so it never opened a
            // single hold, `state.holds.count` was 0 for the whole run, and
            // `retainedStateIsBounded` asserted that zero had not grown. It
            // passed while `questions` and `answering` leaked an entry per
            // timed-out call, which is exactly the growth it was written to
            // catch.
            if i.isMultiple(of: 5) {
                let asks = i.isMultiple(of: 20)
                out.append(.hook(HookEvent(id: EventID("h\(i)"), at: at(ms),
                                           kind: .preToolUse,
                                           session: SessionID("s\(s)"), cwd: Redacted("/w/p\(s)"),
                                           tool: asks ? SubjectReader.questionTool : "Bash",
                                           toolUseID: "u\(i)", held: .value(120_000),
                                           questions: asks ? [Self.question] : [])))
                // Half get answered, half time out — the two ways a hold ends
                // in real use, and the two the cleanup used to miss.
                let hold = HoldID(session: SessionID("s\(s)"), toolUseID: "u\(i)")
                out.append(i.isMultiple(of: 10)
                           ? .decision(hold, .allow, at: at(ms + 5_000))
                           : .holdExpired(hold, at: at(ms + 130_000)))
                continue
            }
            out.append(.hook(HookEvent(id: EventID("e\(i)"), at: at(ms),
                                       kind: i.isMultiple(of: 3) ? .userPromptSubmit : .postToolUse,
                                       session: SessionID("s\(s)"), cwd: Redacted("/w/p\(s)"),
                                       tool: "Bash", toolUseID: "t\(i)", held: .absent)))
        }
        return out
    }

    private static let question = Question(
        text: Redacted("Which one?"), header: Redacted("Pick"),
        options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                  QuestionOption(label: Redacted("B"), detail: Redacted(""))],
        multiSelect: false)

    /// Nanoseconds, as a number that survives crossing a second.
    ///
    /// **`Duration.components.attoseconds` is the SUB-SECOND REMAINDER.** Whole
    /// seconds live in `.seconds` and reading only the other half silently
    /// discards them: 4.268 s reads as 0.268 s. Every ratio in this file was
    /// built that way, so a run that grew past one second while its baseline
    /// stayed under would come back SMALLER than the baseline — a real
    /// regression reported as a speedup, by the tests written to catch it.
    /// Demonstrated with an injected quadratic: a measured 12.5x slowdown
    /// passed `reducingIsLinear` as an improvement.
    private func nanos(_ duration: Duration) -> Double {
        Double(duration / .nanoseconds(1))
    }

    private func elapsed(_ body: () -> Void) -> Duration {
        let clock = ContinuousClock()
        return clock.measure(body)
    }

    /// **The fastest of several runs, not one run.**
    ///
    /// Scheduling noise is one-directional: another process can only ever make
    /// this code slower, never faster. So the minimum of a few trials is the
    /// cleanest estimate of what the work actually costs, and a ratio built
    /// from minimums is stable on a machine doing other things.
    ///
    /// Both timing tests here were flaking without it — 3.12 against a bound
    /// of 3.0, and 4.9 against 4.0 — on a machine running builds in another
    /// window. That is the failure this file's own header calls out and the
    /// reason a previous suite was deleted for depending on its host.
    private func bestOf(_ trials: Int = 5, _ body: () -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0 ..< trials {
            best = min(best, nanos(elapsed(body)))
        }
        return best
    }

    /// Absolute cost, printed rather than asserted — the numbers a person
    /// needs to decide whether anything here is worth optimising.
    @Test("measure: what an event and a frame actually cost")
    func measureAbsoluteCost() {
        let events = Self.stream(events: 8_000, sessions: 8)
        _ = Reducer.run(Self.stream(events: 500, sessions: 8))

        let tReduce = elapsed { _ = Reducer.run(events) }
        let perEvent = nanos(tReduce) / 1_000 / Double(events.count)

        let state = Reducer.run(events)
        let tFrame = elapsed { for _ in 0 ..< 1_000 { _ = Projection.frame(from: state, at: Self.at(99_999)) } }
        let perFrame = nanos(tFrame) / 1_000 / 1_000

        // Repeated reads of the derived lane lists, which views do per render.
        let frame = Projection.frame(from: state, at: Self.at(99_999))
        let tDerived = elapsed {
            for _ in 0 ..< 10_000 {
                _ = frame.visibleLanes.count + frame.hidden.count + frame.hiddenNeedsYou
            }
        }
        let perDerived = nanos(tDerived) / 1_000 / 10_000

        print(String(format: "  reduce:  %8.2f us/event", perEvent))
        print(String(format: "  project: %8.2f us/frame  (%d lanes)", perFrame, state.lanes.count))
        print(String(format: "  derived: %8.2f us/read   (visibleLanes + hidden + hiddenNeedsYou)", perDerived))
    }

    // ------------------------------------------------------------- the cost

    /// **Reducing must be linear in the stream.**
    ///
    /// The failure this guards is a reducer that walks its own history on every
    /// event — a lane list re-sorted per arrival, a hold dictionary filtered
    /// per hook. That is invisible at ten events and fatal at ten thousand, and
    /// a deck is left running for days.
    @Test("reducing a stream costs linear time in its length")
    func reducingIsLinear() {
        // **Four times the input, not two.**
        //
        // At 2x, linear is 2 and quadratic is 4, and a busy machine can move a
        // measurement far enough to cross between them — this failed at 3.12
        // and then at 4.52 against a bound of 3.0, with nothing wrong but
        // another build running. At 4x, linear is 4 and quadratic is 16, and
        // noise would have to double a best-of-five measurement to confuse
        // them. The quadratic this guards measured 291x when it was real, so
        // the gap costs nothing in sensitivity.
        let small = Self.stream(events: 2_000, sessions: 8)
        let large = Self.stream(events: 8_000, sessions: 8)

        _ = Reducer.run(Self.stream(events: 500, sessions: 8))     // warm

        let tSmall = bestOf { _ = Reducer.run(small) }
        let tLarge = bestOf { _ = Reducer.run(large) }

        let ratio = tLarge / max(tSmall, 1)
        #expect(ratio < 8.0,
                Comment(rawValue: "quadrupling the stream multiplied the time by "
                        + String(format: "%.2f", ratio) + " — linear is 4 and quadratic is 16"))
    }

    /// **Retained memory must not grow WITHOUT BOUND as the stream grows.**
    ///
    /// Not "never grow between two samples" — `sweepHolds`'s own doc comment
    /// names the shape this measures: amortised eviction, which is a
    /// saw-tooth by construction. Growth accrues one hold at a time between
    /// sweeps and a sweep cuts it back in a single amortised step, so a count
    /// taken just before a sweep is legitimately higher than one taken just
    /// after — regardless of how long the stream has run.
    ///
    /// The two-sample form this replaces (`atFourThousand <= atThousand`)
    /// asserted monotonicity a saw-tooth cannot honestly promise. It passed
    /// for the pre-question-budget code by luck of exactly where 1,000 and
    /// 4,000 events happened to land on the cycle (199 vs 264, a falling
    /// stretch) and failed the moment the question-hold budget shortened
    /// (from a shared 120 s to 8 s) shifted the cycle's period enough to move
    /// that SAME pair onto a rising stretch instead (313 vs 264) — with nothing
    /// unbounded about it: sampled at 1k/2k/3k/4k/6k/8k/12k/16k/24k/32k events,
    /// the old code ranged 184–314 and the new code ranges 193–313, the same
    /// envelope, just out of phase. (Sampled directly against the reducer to
    /// find this, not asserted here — a saw-tooth's phase is a property of the
    /// fixture's own event spacing, not something worth pinning a test to.)
    ///
    /// What the cap actually promises — and what a broken sweep actually
    /// breaks — is an ENVELOPE independent of stream length: no peak, at any
    /// point arbitrarily far into the stream, may exceed a small, fixed
    /// multiple of the sweep's own threshold. A cap that stopped holding
    /// looks nothing like this: `sweepHolds` never firing (or firing and
    /// reclaiming nothing) grows `state.holds` at roughly one entry per five
    /// events forever — tens of thousands at the sample sizes below, not
    /// hundreds — so the envelope check below is generous against the real
    /// saw-tooth and still sharp against a genuine leak.
    @Test("retained state stops growing once the caps are reached")
    func retainedStateIsBounded() {
        // Everything the deck keeps per lane, counted. These are the lists the
        // caps govern; if a cap stops holding, this is what grows.
        func retained(afterEvents n: Int) -> Int {
            // `retainedItems` rather than a hand-picked sum, so a collection
            // added later is counted here without anybody remembering to.
            Reducer.run(Self.stream(events: n, sessions: 8)).retainedItems
        }

        // Wide enough to cross several full sweep cycles — a genuinely
        // unbounded leak keeps climbing across that span; a bounded
        // saw-tooth revisits the same envelope no matter how far it runs.
        // Capped at 16k: measured, this one test at 11.8s of a
        // 12.6s suite with the ladder run out to 64k, and the top samples
        // buy no discriminating power — a genuine leak at ~1 hold per 5
        // events is already a 4x ceiling violation by 16k, so everything
        // past it spent wall time proving what 16k had proven. The
        // fast-suite doctrine wins; the assertion loses nothing.
        let sizes = [1_000, 4_000, 8_000, 16_000]
        let samples = sizes.map { ($0, retained(afterEvents: $0)) }

        // `sweepAbove` is the threshold a sweep fires above; a peak just
        // before one cannot exceed it by more than a single hold-opening
        // batch, and the threshold itself only ever self-raises to twice
        // what last survived a sweep — bounded in turn by how much a hold
        // can accumulate within `HoldPolicy.memory`'s own retention window.
        // 3x is headroom over that structural peak (observed: at most
        // ~1.2x), not a number tuned to this run's own luck.
        let ceiling = HoldPolicy.sweepAbove * 3
        for (n, retained) in samples {
            #expect(retained <= ceiling, Comment(rawValue:
                "retained \(retained) items after \(n) events — over the sweep's own ceiling "
                + "of \(ceiling), which no event count should cross"))
        }

        // And the fixture genuinely exercises what it claims to. A generator
        // that opens no holds makes the envelope check above a comparison of
        // zero with a ceiling, which is how this suite passed through the
        // leak it exists to catch.
        let state = Reducer.run(Self.stream(events: 1_000, sessions: 8))
        #expect(!state.holds.isEmpty, "the stream opens no holds, so nothing above is measured")
    }

    /// **Projecting a frame must not grow with the history.**
    ///
    /// The projection runs on every event and on every render, so its cost is
    /// multiplied by everything. `decisions` filters `state.holds`, and holds
    /// are KEPT after they resolve — that is deliberate, it is what stops a
    /// retried hook reopening an answered call — so before `sweepHolds` this
    /// walked every permission the deck had ever granted, on every frame it
    /// ever drew. Measured at 22 us/frame with no holds and 356 us with two
    /// hundred, with nothing stopping it.
    ///
    /// Bounded is the claim, not constant. The sweep keeps a window of recent
    /// holds and raises its own threshold when it finds nothing to reclaim, so
    /// a longer run legitimately holds somewhat more than a short one — and
    /// then stops. Both halves are asserted: a loose bound against the short
    /// run catches unbounded growth, and a tight one between two long runs is
    /// what proves it plateaus.
    ///
    /// **Interleaved, paired sampling for the timing half — a fix-round
    /// finding, replacing a single ratio from two long, temporally SEPARATE
    /// blocks.** The version this replaced called `bestOf` once over the
    /// WHOLE 8k measurement (`Reducer.run` plus warm-up plus the timed loop),
    /// then once over the whole 16k measurement, and compared the two —
    /// measured at 2.062 against this test's own 2.0 bound under full-suite
    /// parallel load. Instrumented across 25 clean full-suite runs to see
    /// what that ratio actually looks like: the FIRST block (8k) came in
    /// slower than the second (16k) on every single run, by a consistent
    /// ~1.8–2.2x (ratios 0.45–0.56, the inverse of the failure direction) —
    /// a systematic ordering bias, not per-call jitter `bestOf` already
    /// filters, because it is paid once per BLOCK (state construction plus
    /// warm-up plus the first several timed calls all landing in whichever
    /// block runs first) rather than once per call. That same one-sided
    /// mechanism, hit by a contention spike landing on the SECOND block
    /// instead, is what a 2.062 run actually was: not "noise", a bias large
    /// enough that it only has to partially reverse to cross 2.0.
    ///
    /// Fixed two ways. First, `small`/`large` are built and warmed ONCE,
    /// outside every timed round, so state construction and warm-up cost
    /// stop living inside the measurement at all. Second, the remaining
    /// timing is sampled small/large back to back, several rounds, and the
    /// MEDIAN of the resulting ratios is what gets asserted — a spike now
    /// has to land inside the SAME short round on both sides to bias that
    /// round, and even then one bad round out of several is outvoted rather
    /// than deciding the result by itself, the identical one-bad-sample-
    /// cannot-win logic `bestOf`'s own doc comment already argues for a
    /// single block, applied across rounds instead.
    @Test("projecting does not grow with the history")
    func projectionDoesNotDegradeWithHistory() {
        let small = Reducer.run(Self.stream(events: 8_000, sessions: 8))
        let large = Reducer.run(Self.stream(events: 16_000, sessions: 8))

        // **The structural half, which no machine can make flaky.**
        //
        // What the timing depends on is how many holds the projection walks,
        // and that is a count. Asserting it directly says the same thing as
        // the clock without asking anything of the machine the test runs on.
        // (Reusing `small`/`large` here rather than a fresh `Reducer.run`,
        // as the version this replaces did — `Reducer.run` is a pure
        // function of the event stream, so a second call could only ever
        // reproduce the same count at the cost of reducing 24k events twice.)
        let atEight = small.holds.count
        let atSixteen = large.holds.count
        #expect(atSixteen <= atEight + 8,
                Comment(rawValue: "the projection walks \(atEight) holds after 8k events and "
                        + "\(atSixteen) after 16k — it is reading the past"))

        // Warm both once, outside every timed round — the ordering bias the
        // doc comment above found lives here, not inside `bestOf`.
        _ = Projection.frame(from: small, at: Self.at(99_999_999))
        _ = Projection.frame(from: large, at: Self.at(99_999_999))

        func frameCost(_ state: DeckState) -> Double {
            bestOf(2) {
                for _ in 0 ..< 200 { _ = Projection.frame(from: state, at: Self.at(99_999_999)) }
            }
        }

        // Nine interleaved rounds — small then large, every round — and the
        // median of the nine ratios is the canary, not any single one of them.
        let rounds = 9
        var ratios: [Double] = []
        ratios.reserveCapacity(rounds)
        for _ in 0 ..< rounds {
            let l = frameCost(small)
            let g = frameCost(large)
            ratios.append(g / max(l, 1))
        }
        ratios.sort()
        let median = ratios[rounds / 2]
        print(String(format: "  frame-cost ratio (8k\u{2192}16k): median %.3f, min %.3f, max %.3f over %d rounds",
                     median, ratios.first!, ratios.last!, rounds))
        #expect(median < 2.0,
                Comment(rawValue: "doubling an already-long history multiplied the frame cost by "
                        + String(format: "%.2f", median) + " (median of \(rounds) interleaved rounds) "
                        + "— the sweep is not bounding it"))
    }

    // --------------------------------------------------------- the equality guard

    /// **Investigation: is `Frame` equal for unchanged state across time?**
    ///
    /// `DeckRuntime.refresh` is about to grow an equality-guarded publish —
    /// project into a local, assign to `frame` only on `!=` — and that guard
    /// is only worth anything if two frames projected from the SAME state,
    /// moments apart, actually compare equal. Otherwise `!=` is true on every
    /// call and the guard never short-circuits anything.
    ///
    /// `Frame.at` is the trap. It is not derived FROM state at all — it is
    /// the projection instant echoed straight into a stored field — so by
    /// construction it differs on every distinct `at:`, trivially, and not
    /// from any threshold. The other time-sensitive field still in play,
    /// `LaneView.contextStale`, is instead a COMPARISON against a max age,
    /// so it only moves at a crossing (the usage indicator used to be a
    /// second such field; since paint was standardized it no longer
    /// derives anything from the clock while fine, so it is not one any
    /// more). That difference is why `Frame`'s own `==` (see `Frame.swift`) is a hand-written
    /// conformance that excludes `at` rather than the synthesized one, and
    /// this test is the receipt: two frames a millisecond apart, same state,
    /// no threshold crossed, come back equal even though their `.at` differs
    /// — and a frame on the far side of a crossing does not.
    @Test("investigation: two frames from unchanged state are equal across a sub-threshold time gap")
    func frameEqualityIgnoresTheProjectionInstant() {
        // A lane with a FED context percentage, so `contextStale` and
        // `meters` are actually exercised — the `stream()` fixture above
        // sends no `.statusline` event, so every lane's gauge stays the
        // permanently-unstale empty slot and this investigation would prove
        // nothing against it.
        let session = SessionID("s0")
        let state = Reducer.run([
            .hook(HookEvent(id: EventID("start"), at: Self.at(0), kind: .sessionStart,
                            session: session, cwd: Redacted("/w/p0"), tool: nil,
                            toolUseID: nil, held: .absent)),
            .statusline(StatuslinePayload(session: session, contextPercent: .value(42),
                                          costUSD: .unset, model: nil, version: nil),
                       at: Self.at(1_000), id: EventID("sl-1")),
        ])

        let a = Projection.frame(from: state, at: Self.at(20_000))
        let b = Projection.frame(from: state, at: Self.at(20_001))   // 1 ms later, well under the 30s max age
        #expect(a.at != b.at, "the fixture's own premise: the instants must differ")
        #expect(a.lanes.first?.contextStale == false,
                "the fixture's own premise: nothing is stale yet")
        #expect(a == b, Comment(rawValue:
            "two frames one millisecond apart, from IDENTICAL state, compared unequal — " +
            "the equality guard would never short-circuit"))

        // And a crossing DOES flip it — proof the field is threshold-based,
        // not continuous, so the guard still repaints the one frame that
        // actually differs.
        let stale = Projection.frame(from: state, at: Self.at(1_000 + 30_001))
        #expect(stale.lanes.first?.contextStale == true,
                "the fixture's own premise: 30.001s past the reading crosses the 30s max age")
        #expect(stale != a, "a frame past the staleness threshold must differ from one before it")
    }

    /// The guard's own price, alongside `measureAbsoluteCost`'s own frame
    /// cost above (cited rather than duplicated: `Projection.frame` is
    /// already printed there). Print-only, per this file's own doctrine —
    /// what is asserted about equality is `frameEqualityIgnoresTheProjectionInstant`
    /// above; this is only what a person needs to decide whether comparing
    /// two frames is cheap enough to run on every event.
    @Test("measure: what comparing two frames costs")
    func measureFramePublishGuard() {
        let events = Self.stream(events: 8_000, sessions: 8)
        let state = Reducer.run(events)
        let a = Projection.frame(from: state, at: Self.at(99_999))
        let b = Projection.frame(from: state, at: Self.at(99_999))

        let tEqual = elapsed { for _ in 0 ..< 10_000 { _ = (a == b) } }
        let perEqual = nanos(tEqual) / 1_000 / 10_000

        print(String(format: "  compare: %8.3f us/compare (%d lanes, equal case)",
                     perEqual, state.lanes.count))
    }
}