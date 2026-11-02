//
//  ContextMeterTests.swift · Tests/DeckCoreTests
//
//  Which way the context meter runs, held at the layer that decides it.
//
//  The deck relays one integer — `context_window.used_percentage`, the same
//  number Claude Code prints on the user's own statusline — and for a while it
//  showed the complement instead: a bar that emptied as the window filled, and
//  a red-state label reading `9% left` for the session whose terminal said
//  `ctx:91%`. Two surfaces, two numbers, one fact, and the arithmetic left to
//  the reader.
//
//  That was the fuel-gauge rule (UX_DESIGN §2) applied to the wrong instrument.
//  A fuel tank is a budget you spend down and "how much is left" is the
//  question; a context window is a thing that fills, reported as filled, and
//  the deck has no licence to reinterpret a number it did not compute. So the
//  direction is a rule now rather than a habit, and this is where it is kept:
//  the view layer reads `Meter` and cannot disagree with it.
//

import Testing
import DeckCore

struct ContextMeterTests {

    private func hook(_ session: SessionID, at ms: Int64) -> DeckEvent {
        .hook(HookEvent(id: EventID("start-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                        kind: .sessionStart, session: session, cwd: nil,
                        tool: nil, toolUseID: nil, held: .absent))
    }

    /// **The number, unaltered.** A meter built from 91 reads 91 — not 9, and
    /// not "9% left". The falsifier for the inversion is exactly this: any
    /// reading whose meter carries `100 - used`.
    @Test("the meter carries what the statusline sent, never its complement")
    func theMeterIsNotInverted() {
        #expect(Meter.context(usedPercent: 91).used == 91)
        #expect(Meter.context(usedPercent: 9).used == 9)
        #expect(Meter.context(usedPercent: 0).used == 0)
        #expect(Meter.context(usedPercent: 100).used == 100)

        // And it says so in the idiom of the statusline it came from, so the
        // deck and the terminal beside it read alike.
        #expect(Meter.context(usedPercent: 91).reading == "ctx:91%")
        #expect(Meter.context(usedPercent: 3).reading == "ctx:3%")
    }

    /// UX_DESIGN §3's threshold, expressed in the units it is now measured in.
    /// It used to read "≤ 10 % remaining", which is the same boundary said
    /// backwards — and saying it backwards is how the inversion survived a
    /// review in the first place.
    @Test("red begins at 90 % consumed, and the red is labelled")
    func alarmAtNinetyPercentUsed() {
        #expect(Meter.context(usedPercent: 89).severity == .normal)
        #expect(Meter.context(usedPercent: 90).severity == .alarm)
        #expect(Meter.context(usedPercent: 100).severity == .alarm)

        // The labelled-red rule: red never appears without text saying why,
        // and the text is the same reading the bar is drawn from.
        #expect(Meter.context(usedPercent: 90).label == "ctx:90%")
        #expect(Meter.context(usedPercent: 89).label == nil)
    }

    /// The payload is untrusted. A percentage outside 0…100 is bounded rather
    /// than believed — a bar wider than its own track is a layout bug, and a
    /// negative one is a crash waiting for a `GeometryReader`.
    @Test("an out-of-range reading is clamped at the meter, not at each caller")
    func readingsAreClamped() {
        #expect(Meter.context(usedPercent: 140).used == 100)
        #expect(Meter.context(usedPercent: -5).used == 0)
        #expect(Meter.context(usedPercent: -5).severity == .normal)
    }

    /// The frame's own meters run the same way, and a stale lane still
    /// contributes none: the gauge may go on showing an old reading, but an
    /// ALARM raised on one would be the labelled-red rule's red with a cause
    /// the deck can no longer vouch for.
    @Test("the frame's meters read used, and a stale lane raises none")
    func frameMetersFollowTheSameRule() {
        let session = SessionID("s1")
        let feed = StatuslinePayload(session: session, contextPercent: .value(91),
                                     costUSD: .absent, model: nil, version: nil)
        let state = Reducer.run([hook(session, at: 0),
                                 .statusline(feed, at: Instant(sinceStart: Millis(1_000)),
                                             id: EventID("sl-1"))])

        func frame(atMillis ms: Int64) -> Frame {
            Projection.frame(from: state, at: Instant(sinceStart: Millis(ms)), maxAges: .proposed)
        }

        #expect(frame(atMillis: 2_000).meters.map(\.used) == [91])
        #expect(frame(atMillis: 2_000).unlabelledAlarms.isEmpty)

        // Past the max age the lane keeps its reading and loses its meter.
        #expect(frame(atMillis: 600_000).lanes.first?.contextPercent == 91)
        #expect(frame(atMillis: 600_000).meters.isEmpty)
    }

    // ------------------------------------------------------------ ContextLoad

    /// **`ContextLoad(percent:)`'s own worked table — every boundary named
    /// in its own doc comment, held to literal cases.** 50 IS caution, 75
    /// IS alarm — both inclusive on the HIGHER side, checked at the exact
    /// boundary and one point either side of it, the same "not roughly
    /// right" discipline this file already holds `Meter`'s own 90% line
    /// to (`alarmAtNinetyPercentUsed`, above) — a DIFFERENT threshold, on
    /// purpose (`ContextLoad`'s own doc comment states why the two rules
    /// are not the same judgment call).
    @Test("ContextLoad worked table", arguments: [
        (0, ContextLoad.calm, "the floor"),
        (49, ContextLoad.calm, "one point under the caution line"),
        (50, ContextLoad.caution, "the caution line — inclusive"),
        (74, ContextLoad.caution, "one point under the alarm line"),
        (75, ContextLoad.alarm, "the alarm line — inclusive"),
        (100, ContextLoad.alarm, "the ceiling"),
    ])
    func contextLoadWorkedTable(_ percent: Int, _ expected: ContextLoad, _ what: String) {
        let got = ContextLoad(percent: percent)
        #expect(got == expected, Comment(rawValue: "\(what) (\(percent)%) got \(got), expected \(expected)"))
    }

    @Test("ContextLoad's own thresholds are pinned literals — 50 and 75")
    func contextLoadThresholdsArePinned() {
        #expect(ContextLoad.cautionThreshold == 50)
        #expect(ContextLoad.alarmThreshold == 75)
    }

    /// An out-of-range percent (the untrusted-payload case `Meter`'s own
    /// `readingsAreClamped` above holds one layer down) still answers
    /// honestly rather than trapping — `ContextLoad`'s own doc comment
    /// states why this type does not re-clamp what `Meter.context
    /// (usedPercent:)` already bounds where the payload actually enters.
    @Test("out-of-range percents still answer, at whichever end they overshoot")
    func outOfRangePercentsStillAnswer() {
        #expect(ContextLoad(percent: -20) == .calm)
        #expect(ContextLoad(percent: 250) == .alarm)
    }
}
