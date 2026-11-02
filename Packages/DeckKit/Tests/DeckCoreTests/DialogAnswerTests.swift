//
//  DialogAnswerTests.swift · Tests/DeckCoreTests
//
//  Chunk 4: the frame-level half of the terminal-dialog answer path — the
//  facts `DialogAnswerPanel` and the corrected `HandedBackNotice` are driven
//  by, gated at the PROJECTION so a stale or absent signal cannot reach a
//  surface that would act on it.
//

import Testing
import DeckCore

struct DialogAnswerTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private func hook(_ session: SessionID, _ kind: HookKind, _ ms: Int64,
                      tool: String? = nil, use: String? = nil,
                      notificationType: String? = nil) -> DeckEvent {
        .hook(HookEvent(id: EventID("\(kind)-\(session.raw)-\(ms)"), at: at(ms), kind: kind,
                        session: session, cwd: Redacted("/w"), tool: tool, toolUseID: use,
                        held: .absent, notificationType: notificationType))
    }

    private func waitingRow(_ session: SessionID, name: String = "s") -> FleetRow {
        FleetRow(session: session, name: name, kind: "interactive",
                 state: .absent, status: .value("waiting"), waitingFor: "permission prompt")
    }

    // ------------------------------------------------------------ waitingFor

    /// The raise: a fleet row corroborating a dialog projects straight
    /// through to the panel's own input. A fleet row is enough to OPEN the
    /// lane too (the no-synthesised-lane rule's fleet-origin clause) — no
    /// hook required, which is the hookless-session case the directive names.
    @Test("waitingFor surfaces on a needs-you lane the fleet raised")
    func waitingForSurfacesOnNeedsYou() {
        let session = SessionID("s1")
        let state = Reducer.run([.fleet([waitingRow(session)], at: at(10), id: EventID("f1"))])
        let frame = Projection.frame(from: state, at: at(20))
        let lane = frame.lanes.first { $0.session == session }
        #expect(lane?.state == .needsYou)
        #expect(lane?.waitingFor == "permission prompt",
                Comment(rawValue: "projected \(String(describing: lane?.waitingFor))"))
    }

    /// The gate: a lane that is not needs-you never shows a `waitingFor`,
    /// whatever the record still holds. Built by demoting the lane through a
    /// path that never TOUCHES `waitingFor` — only a `.fleet` event writes
    /// that field (`DeckState.swift`'s fleet apply) — so the record is left
    /// holding a value the lane has moved past. That is exactly
    /// `LaneRecord.waitingFor`'s own partial-roster caveat, and this is the
    /// projection honouring it.
    @Test("a stale waitingFor on a demoted lane does not render")
    func staleWaitingForDoesNotRender() {
        let session = SessionID("s2")
        var state = Reducer.run([.fleet([waitingRow(session)], at: at(10), id: EventID("f1"))])
        #expect(state.lanes[session]?.waitingFor.value == "permission prompt")
        #expect(state.lanes[session]?.state == .needsYou)

        // Demoted by a HOOK, not a fleet row — `idle_prompt` never touches
        // `waitingFor` at all, so the record is left holding stale text.
        Reducer.reduce(&state, hook(session, .notification, 30, notificationType: "idle_prompt"))
        #expect(state.lanes[session]?.state == .idle, "the demotion itself did not land")
        #expect(state.lanes[session]?.waitingFor.value == "permission prompt",
                "the record's own field changed — this fixture proves nothing about the projection")

        let frame = Projection.frame(from: state, at: at(40))
        let lane = frame.lanes.first { $0.session == session }
        #expect(lane?.waitingFor == nil,
                "a stale dialog reason rendered on a lane that had moved on")
    }

    // -------------------------------------------------------------- sawAHold

    /// True the moment ANY hold exists for the session — open or resolved —
    /// because the copy it feeds only has one question to answer: was this
    /// lane ever the deck's to hand back.
    @Test("sawAHold is true once a hold has ever existed for the session, open or resolved")
    func sawAHoldTracksAnyHold() {
        let session = SessionID("s3")
        var state = DeckState()
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("perm"), at: at(0), kind: .permissionRequest, session: session,
            cwd: Redacted("/w"), tool: "Bash", toolUseID: "u1", held: .absent)))
        var frame = Projection.frame(from: state, at: at(10))
        #expect(frame.lanes.first { $0.session == session }?.sawAHold == true,
                "an OPEN hold did not register")

        let hold = HoldID(session: session, toolUseID: "u1")
        Reducer.reduce(&state, .holdExpired(hold, at: at(200_000)))
        #expect(state.holds[hold]?.isOpen == false, "the hold is still open — this fixture proves nothing")
        frame = Projection.frame(from: state, at: at(200_010))
        #expect(frame.lanes.first { $0.session == session }?.sawAHold == true,
                "a RESOLVED hold stopped counting")
    }

    /// False for a lane no hold has ever protected — the case a holdless
    /// Notification or a hookless fleet discovery both produce, and the case
    /// the old fixed copy used to claim a custody the deck never had.
    @Test("sawAHold is false for a lane no hold ever opened")
    func sawAHoldFalseWithoutAHold() {
        let session = SessionID("s4")
        let state = Reducer.run([hook(session, .notification, 0, notificationType: "permission_prompt")])
        #expect(state.holds.isEmpty, "a Notification opened a hold — this fixture proves nothing")
        let frame = Projection.frame(from: state, at: at(10))
        #expect(frame.lanes.first { $0.session == session }?.sawAHold == false,
                "a holdless lane read as having been held")
    }

    // --------------------------------------------------- LV36, at the frame

    /// **The integration.** LV36's `alpha-b5` row, replayed through the
    /// reducer and projected, lands on exactly the two facts
    /// `DialogAnswerPanel` needs: needs-you, and the dialog's own text, with
    /// no live decision competing for the same slot. `ResilienceTests`'
    /// `DialogTests` already pins this at the RECORD (`state.lanes[…]`);
    /// this pins it at the FRAME, which is the layer the surface reads.
    @Test("the LV36 waiting row projects to the panel's own inputs")
    func lv36ProjectsToThePanelInputs() {
        let rows = FleetIngest.rows(from: Corpus.fleetDialogOpen)
        guard let waiting = rows.first(where: { $0.name == "alpha-b5" }),
              let session = waiting.session else {
            Issue.record("LV36 lost its alpha-b5 row"); return
        }
        let state = Reducer.run([.fleet(rows, at: at(100), id: EventID("f1"))])
        let frame = Projection.frame(from: state, at: at(200))
        let lane = frame.lanes.first { $0.session == session }
        #expect(lane?.state == .needsYou,
                Comment(rawValue: "alpha-b5 projected as \(String(describing: lane?.state))"))
        #expect(lane?.waitingFor == "permission prompt",
                Comment(rawValue: "projected \(String(describing: lane?.waitingFor))"))
        // No live decision either — nothing opened a hold for a row the
        // fleet alone discovered — the second half of the gate
        // `DeckWindow.swift` reads to choose the panel over the notice.
        #expect(!frame.decisions.contains { $0.hold.session == session },
                "a fleet-only discovery somehow produced a decision")
    }
}
