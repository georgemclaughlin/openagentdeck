//
//  AttentionTests.swift · Tests/DeckCoreTests
//
//  Cases P1.40–P1.44. Five invariants that each needed one earlier piece to
//  exist before they could be stated at all: the fleet feed for T5, Layout's
//  geometry for A4 and L6, the frame's motion channel for A6, and the config
//  merge for T9.
//

import Testing
import DeckCore

struct AttentionTests {

    private func lane(_ i: Int, _ state: LaneState) -> LaneView {
        LaneView(session: SessionID("s\(i)"), state: state, isExpanded: false,
                 contextPercent: nil, sources: ["state": EventID("e\(i)")])
    }
    private func frame(_ states: [LaneState], reduceMotion: Bool = false) -> Frame {
        let views = states.enumerated().map { lane($0.offset, $0.element) }
        return Frame(at: .start, lanes: views,
                     mastNeedsYou: views.filter { $0.state == .needsYou }.count,
                     reduceMotion: reduceMotion, decisions: [])
    }

    /// The unknown-is-not-error rule at the fleet layer, and the
    /// fleet-owns-the-light-bar rule's *precondition*.
    ///
    /// Not the fleet-owns-the-light-bar rule itself. T5's falsifier is "bar
    /// red in a frame where the last fleet row reported `working`", and
    /// producing it needs a **deck-side** claim to overrule — a denial that
    /// colours the bar on the deck's own authority. No such path exists: the
    /// fleet feed is the only thing that can make a background lane red, so
    /// the precedence rule has nothing to arbitrate and a projection-side
    /// override for it was dead code the moment it was written. The mutation
    /// harness said so — NOT CAUGHT on a test that had just gone green — and
    /// the override is deleted rather than kept.
    @Test("only the fleet feed moves a background lane, and only known values")
    func fleetOwnsTheLightBar() {
        let session = SessionID("bg")
        let start = DeckEvent.hook(HookEvent(id: EventID("start"), at: .start,
                                             kind: .sessionStart, session: session, cwd: nil,
                                             tool: nil, toolUseID: nil, held: .absent))
        let failing = FleetRow(session: session, name: "spike-fail", kind: "background",
                               state: .value("blocked"), status: .value("idle"))
        let working = FleetRow(session: session, name: "spike-fail", kind: "background",
                               state: .value("working"), status: .absent)

        // A feed that reports a failure does colour the lane — the invariant is
        // about *authority*, not about never showing red.
        var state = Reducer.run([start, .fleet([failing], at: Instant(sinceStart: Millis(1)),
                                               id: EventID("f1"))])
        #expect(Projection.frame(from: state, at: Instant(sinceStart: Millis(2)))
                    .lanes.first?.state == .errored)

        // A later `working` row moves it back.
        state = Reducer.run([start,
                             .fleet([failing], at: Instant(sinceStart: Millis(1)), id: EventID("f1")),
                             .fleet([working], at: Instant(sinceStart: Millis(2)), id: EventID("f2"))])
        #expect(state.lanes[session]?.fleetState.value == "working")
        #expect(Projection.frame(from: state, at: Instant(sinceStart: Millis(3)))
                    .lanes.first?.state == .working)

        // And a state nobody has seen moves nothing, at the layer the
        // spike's S18 induced its failure in.
        let unforeseen = FleetRow(session: session, name: "spike-fail", kind: "background",
                                  state: .value("hibernating"), status: .absent)
        let held = Reducer.run([start,
                                .fleet([failing], at: Instant(sinceStart: Millis(1)), id: EventID("f1")),
                                .fleet([unforeseen], at: Instant(sinceStart: Millis(2)), id: EventID("f3"))])
        #expect(Projection.frame(from: held, at: Instant(sinceStart: Millis(3)))
                    .lanes.first?.state == .errored)

        // **From a lane the fleet is allowed to move**, which is where the
        // unknown-is-not-error rule has teeth. The case above starts at
        // `.errored`, and the guard that keeps a poll from carrying a lane
        // off a state a better-informed feed decided ALSO refuses the
        // unforeseen row — so the lane holds for a reason that has nothing to
        // do with the rule being tested, and a decoder that mapped every
        // unknown state to "working" would pass it. An idle lane is the
        // honest subject: unknown must leave it idle.
        let fresh = Reducer.run([start,
                                 .fleet([unforeseen], at: Instant(sinceStart: Millis(1)),
                                        id: EventID("f4"))])
        #expect(fresh.lanes[session]?.state != .working,
                Comment(rawValue: "an unforeseen state moved an idle lane to "
                        + "\(String(describing: fresh.lanes[session]?.state))"))
    }

    /// The countdown and the installed timeout have one SOURCE — the budget —
    /// even though the number on disk is no longer that budget's own digits.
    ///
    /// `installedTimeoutMillis` reads the PermissionRequest entry's
    /// per-command `timeout`, in seconds, and scales it back to millis; what
    /// gets written is `ceil(budget/1000) + 10` seconds, not the raw
    /// millisecond budget — the ten seconds are the engine's own slack, so
    /// its "proceed anyway" fallback fires last, after curl's own wider
    /// `--max-time` and after the deck's own prompt `{}` at expiry. 120 000 ms
    /// therefore installs as 130 000, not 120 000; that is still ONE source,
    /// because both numbers are computed from the same `policy.budget` and
    /// nothing here restates either literal independently.
    @Test("the installed hook timeout is the deck's own hold budget, engine-slack included")
    func oneSourceForTheTimeout() {
        let bare = JSONValue.object([:])
        let installed = SettingsMerge.install(into: bare, port: 8765).after

        #expect(SettingsMerge.installedTimeoutMillis(installed) == 130_000,
                "a 120 000 ms budget should install a 130 s per-command timeout")
        #expect(SettingsMerge.timeoutDrift(installed, policy: .spec) == nil)

        // A different budget writes a different timeout — one value,
        // followed: 15 s rounds to 15 s, plus the same 10 s of engine slack.
        let short = HoldPolicy(budget: Millis(15_000), armDelay: Millis(250), reArmDelay: Millis(400))
        let shortDoc = SettingsMerge.install(into: bare, port: 8765, policy: short).after
        #expect(SettingsMerge.installedTimeoutMillis(shortDoc) == 25_000)

        // And drift is surfaced rather than rounded away — `expected` is
        // computed the same way, so a genuine drift and the budget-derived
        // slack are never confused for each other.
        let drift = SettingsMerge.timeoutDrift(shortDoc, policy: .spec)
        #expect(drift != nil)
        #expect(drift?.installed == 25_000)
        #expect(drift?.expected == 130_000)
        // A document with no deck hook at all drifts too — "not installed" is
        // not "agrees".
        #expect(SettingsMerge.timeoutDrift(bare, policy: .spec)?.installed == nil)
    }
}
