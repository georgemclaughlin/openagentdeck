//
//  ConformanceTests.swift · Tests/DeckCoreTests
//
//  Cases P1.63–P1.66. The sixth pass, and it moved four of the last six. Each
//  is enforced in the half that is a rule, with the half that needs a machine
//  named rather than implied.
//

import Testing
// `@testable` for the same reason HoldTests needs it, and no wider: a background
// session with a HEADLESS hold is a shape the engine has no arrival path for.
// Seeding one through the module's internal setter is honest about that.
@testable import DeckCore

struct ConformanceTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// The fleet feed owns the light bar, now that there is
    /// something for it to overrule.
    ///
    /// The earlier deferral was right that no deck-side claimant existed. One
    /// does now: a **headless auto-deny** is the deck refusing a tool on its
    /// own authority, and the fleet-owns-the-light-bar rule says a background
    /// session's feed outranks it.
    @Test("a deck-side auto-deny never reddens a background lane the feed calls working")
    func fleetOutranksAnAutoDeny() {
        let session = SessionID("bg")
        let hold = HoldID(session: session, toolUseID: "t1")
        var state = DeckState()
        state.lanes[session] = LaneRecord(session: session, firstSeenAt: .start, lastEventAt: .start,
                                          state: .working, stateSource: EventID("s"),
                                          stateDecidedAt: .start, fleetState: .absent,
                                          waitingFor: .absent,
                                          isBackground: true, contextPercent: .absent,
                                          contextSource: nil, contextDecidedAt: nil)
        state.holds[hold] = Hold(id: hold, openedAt: .start, budget: Millis(120_000),
                                 frontendOwned: false, armDelay: Millis(250))

        // The auto-deny colours the lane — this is the claim the fleet-owns-the-light-bar rule arbitrates.
        Reducer.reduce(&state, .holdExpired(hold, at: at(120_001)))
        #expect(state.lanes[session]?.state == .errored)
        #expect(Projection.frame(from: state, at: at(120_002)).lanes.first?.state == .errored)

        // ...and a feed still reporting `working` outranks it.
        let working = FleetRow(session: session, name: "bg", kind: "background",
                               state: .value("working"), status: .absent)
        state.lanes[session]?.fleetState = working.state
        #expect(Projection.frame(from: state, at: at(120_003)).lanes.first?.state == .working)

        // For a foreground lane the deck's own claim stands — the invariant is
        // about background sessions, and a blanket override would be a
        // different, wrong rule.
        state.lanes[session]?.isBackground = false
        #expect(Projection.frame(from: state, at: at(120_004)).lanes.first?.state == .errored)
    }

    /// In the half that is a rule.
    @Test("an idle deck asks for no work")
    func idleSchedulesNothing() {
        #expect(DeckState().scheduledWork.isEmpty)

        var quiet = DeckState()
        let s = SessionID("a")
        quiet.lanes[s] = LaneRecord(session: s, firstSeenAt: .start, lastEventAt: .start,
                                    state: .idle, stateSource: EventID("e"), stateDecidedAt: .start,
                                    fleetState: .absent, waitingFor: .absent, isBackground: false,
                                    contextPercent: .absent, contextSource: nil, contextDecidedAt: nil)
        #expect(quiet.scheduledWork.isEmpty, "an idle lane asked for a frame clock")

        // `.working` is a STEADY wash now (the wash redesign) — a constant
        // opacity needs no frame clock, so it schedules nothing, same as
        // idle and ended. Only `.needsYou` still pulses, so it alone now
        // carries the motion half of this test's own guard: something has
        // to be SHOWN to schedule work, or every `isEmpty` assertion above
        // is satisfied vacuously by a deck that never schedules anything
        // at all.
        quiet.lanes[s]?.state = .working
        #expect(quiet.scheduledWork.isEmpty)
        quiet.lanes[s]?.state = .needsYou
        #expect(!quiet.scheduledWork.isEmpty)
        quiet.lanes[s]?.state = .ended
        #expect(quiet.scheduledWork.isEmpty)
    }

    /// In the half that is a rule.
    ///
    /// The live re-record is L4's and needs the real CLI — it is by definition
    /// the check that the recording went stale. What is a rule is that any
    /// difference produces a finding rather than a silent pass.
    @Test("any shape or enum difference between recorded and live is a finding")
    func driftFailsLoudly() {
        let recorded = Corpus.fleetS18
        #expect(Conformance.drift(recorded: recorded, live: recorded).isEmpty)

        // The exact failure S18 was induced to find: a renamed enum value.
        let renamed = JSONValue.parse(Corpus.text("S18-agents.json")
                                        .replacingOccurrences(of: "\"blocked\"", with: "\"failed\""))!
        let enumDrift = Conformance.drift(recorded: recorded, live: renamed)
        #expect(!enumDrift.isEmpty, "an enum value changed and nothing noticed")
        #expect(enumDrift.contains { $0.recorded == "blocked" && $0.live == "failed" })

        // A renamed field.
        let renamedKey = JSONValue.parse(Corpus.text("S18-agents.json")
                                           .replacingOccurrences(of: "\"status\"", with: "\"state2\""))!
        #expect(!Conformance.drift(recorded: recorded, live: renamedKey).isEmpty)

        // A changed type.
        let retyped = JSONValue.parse(#"[{"pid": "97277"}]"#)!
        let original = JSONValue.parse(#"[{"pid": 97277}]"#)!
        let typeDrift = Conformance.drift(recorded: original, live: retyped)
        #expect(typeDrift.count == 1)
        #expect(typeDrift.first?.recorded == "number" && typeDrift.first?.live == "string")

        // More rows is not drift; a differently-shaped row is.
        let more = JSONValue.parse(#"[{"pid": 1}, {"pid": 2}, {"pid": 3}]"#)!
        #expect(Conformance.drift(recorded: original, live: more).isEmpty)
    }
}
