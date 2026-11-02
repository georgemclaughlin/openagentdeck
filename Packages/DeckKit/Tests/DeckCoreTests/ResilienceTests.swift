//
//  ResilienceTests.swift · Tests/DeckCoreTests
//
//  Cases P1.45–P1.48. Four invariants that turned out to be pure after all — I
//  had them filed under "needs a running app" and "needs an adapter", and three
//  of the four only needed the rule stated as a function.
//

import Testing
import Foundation
import DeckCore

struct ResilienceTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }
    private func hook(_ kind: HookKind, _ session: String, _ ms: Int64,
                      tool: String? = nil, use: String? = nil, held: Fed<Int> = .absent) -> DeckEvent {
        .hook(HookEvent(id: EventID("\(kind)-\(session)-\(ms)"), at: at(ms), kind: kind,
                        session: SessionID(session), cwd: Redacted("/w"), tool: tool,
                        toolUseID: use, held: held))
    }

    /// Restart recovers from feeds, never from cache.
    @Test("a restart keeps nothing that no post-restart event supplied")
    func restartRecoversFromFeedsOnly() {
        let before: [DeckEvent] = [
            hook(.sessionStart, "a", 0), hook(.userPromptSubmit, "a", 10),
            hook(.sessionStart, "b", 20),
            .statusline(StatuslinePayload(session: SessionID("a"), contextPercent: .value(42),
                                          costUSD: .absent, model: nil, version: nil),
                        at: at(30), id: EventID("sl")),
        ]
        var state = Reducer.run(before)
        #expect(state.lanes.count == 2)
        #expect(state.lanes[SessionID("a")]?.contextPercent.value == 42)

        Reducer.reduce(&state, .restart(at: at(100)))
        #expect(state.lanes.isEmpty, "a lane survived a restart with nothing to re-supply it")

        // Only what a feed says afterwards comes back.
        Reducer.reduce(&state, hook(.sessionStart, "b", 200))
        #expect(state.lanes.count == 1)
        #expect(state.lanes[SessionID("a")] == nil)
        #expect(state.lanes[SessionID("b")]?.contextPercent.value == nil,
                "a cached percentage reappeared after a restart")
    }

    /// Held hooks fail **closed to the terminal**.
    ///
    /// S13 proved this once, for one failure mode, at one version: the server
    /// was killed mid-hold and the session still completed with `is_error:
    /// false`. As a permanent property it has to survive every future refactor
    /// of the hold logic, which means the rule is "a deck that stops holding
    /// releases", not "a deck that stops holding is a scenario we ran once".
    @Test("a deck that dies mid-hold releases rather than leaving the call hanging")
    func degradesToStockBehaviour() {
        var state = DeckState()
        Reducer.reduce(&state, hook(.preToolUse, "a", 0, tool: "Bash", use: "t1", held: .value(8002)))
        Reducer.reduce(&state, hook(.preToolUse, "b", 10, tool: "Bash", use: "t2", held: .value(3000)))
        #expect(state.holds.values.filter(\.isOpen).count == 2)

        let effects = Reducer.reduce(&state, .restart(at: at(50)))
        let released = effects.compactMap(\.resolution)
        #expect(released.count == 2, "an open hold was dropped instead of released")
        #expect(released.allSatisfy { $0.1 == .release },
                "a dying deck denied on the user's behalf — that is worse than not existing")
        #expect(state.holds.isEmpty)

        // A deck that dies with nothing held owes nothing.
        var quiet = DeckState()
        #expect(Reducer.reduce(&quiet, .restart(at: at(1))).isEmpty)
    }

    /// Redacted by construction.
    @Test("exported diagnostics cannot contain a command, a path or a prompt")
    func diagnosticsAreRedacted() {
        let secret = "curl https://example.com/exfil?token=hunter2 /Users/someone/private.txt"
        let events: [DeckEvent] = [
            hook(.sessionStart, "a", 0),
            hook(.preToolUse, "a", 10, tool: "Bash", use: "t1", held: .value(1)),
            hook(.unrecognised(secret), "a", 20),
            .decision(HoldID(session: SessionID("a"), toolUseID: "t1"), .deny, at: at(300)),
        ]
        // A closure, not the bare `DiagnosticExport.record` reference this
        // replaced: `record` grew an `effects:` parameter (defaulted, but
        // a bare function VALUE still carries the full parameter list —
        // Swift does not partially apply a default at that point), and
        // this stream never resolves anything through `.holdExpired`
        // (its `.decision(... .deny ...)` already carries its own outcome
        // directly, needing no `effects` lookup), so `[]` is the correct
        // input here, not a shortcut around a real one.
        let log = DiagnosticExport.export(events.compactMap { DiagnosticExport.record($0) })

        #expect(!log.isEmpty)
        for leak in ["curl", "example.com", "hunter2", "private.txt", "/Users/", "?token="] {
            #expect(!log.contains(leak), "the export leaked \(leak)")
        }
        // What it does carry: the shape of what happened, which is the point of
        // having a log at all.
        #expect(log.contains("holdOpened"))
        #expect(log.contains("tool=Bash"))
        #expect(log.contains("outcome=deny"))
        #expect(log.contains("decodeUnrecognised"))
    }

    /// Derived fields fail to nothing.
    @Test("a non-git working directory renders no branch, never a placeholder")
    func derivedFieldsFailToNothing() {
        #expect(Derived.branch(cwd: "/w", head: "main", gitRoot: "/w") == "main")
        #expect(Derived.branch(cwd: "/w", head: "feature/x", gitRoot: "/w") == "feature/x")

        // Every way of not being a worktree renders nothing.
        #expect(Derived.branch(cwd: "/tmp", head: nil, gitRoot: nil) == nil)
        #expect(Derived.branch(cwd: "/tmp", head: "main", gitRoot: nil) == nil)
        #expect(Derived.branch(cwd: nil, head: "main", gitRoot: "/w") == nil)
        #expect(Derived.branch(cwd: "/w", head: "", gitRoot: "/w") == nil)
    }
}

/// The deck finds sessions nobody told it about.
///
/// It was push-only: a lane existed once a session had emitted a hook, so
/// launching the deck after your sessions meant it knew nothing about them
/// until they next spoke. The no-synthesised-lane rule has always allowed the
/// other way in — "no lane exists without >= 1 received event OR FLEET ROW" —
/// and the code declined to use it. `fixtures/live/LV34-discovery` is the
/// shape it reads.
struct DiscoveryTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private func recordedRows() -> [FleetRow] {
        let text = Corpus.text("live/LV34-discovery/agents.json")
        return FleetIngest.rows(from: JSONValue.parse(text) ?? .null)
    }

    /// The real document decodes, with the two keys discovery needs.
    /// `pid` is the join to the terminal; `cwd` is the only thing a discovered
    /// lane can say about itself before a hook arrives.
    @Test("the recorded agents document carries a pid and a cwd for every session")
    func theFixtureDecodes() {
        let rows = recordedRows()
        #expect(rows.count >= 8, Comment(rawValue: "decoded \(rows.count) rows"))
        let interactive = rows.filter { $0.kind == "interactive" }
        #expect(!interactive.isEmpty)
        #expect(interactive.allSatisfy { $0.pid != nil },
                "a session with no pid cannot be joined to a terminal")
        #expect(rows.allSatisfy { $0.cwd != nil },
                "a session with no cwd gives a discovered lane nothing to show")
        #expect(rows.allSatisfy { $0.session != nil })
    }

    /// **The change.** A fleet row alone opens a lane, so a deck started
    /// after its sessions is complete immediately rather than after they next
    /// speak.
    @Test("a fleet row opens a lane with no hook involved")
    func aFleetRowOpensALane() {
        var state = DeckState()
        #expect(state.lanes.isEmpty)
        Reducer.reduce(&state, .fleet(recordedRows(), at: at(100), id: EventID("f1")))
        #expect(state.lanes.count >= 8,
                Comment(rawValue: "\(state.lanes.count) lanes from 8 discovered sessions"))

        let frame = Projection.frame(from: state, at: at(110))
        #expect(frame.lanes.allSatisfy { $0.directory != nil },
                "a discovered lane cannot say where it is working")
        // Every slot arrives with the id of the event that filled it.
        #expect(frame.lanes.allSatisfy { $0.sources["directory"] != nil },
                "a discovered directory has no provenance")
    }

    /// And it is still the no-synthesised-lane rule, not a lane
    /// invented from nothing. A row with no session id names nobody and opens
    /// nothing.
    @Test("a row that names no session opens no lane")
    func stillNoInvention() {
        var state = DeckState()
        Reducer.reduce(&state, .fleet(
            [FleetRow(session: nil, name: "ghost", kind: "interactive",
                      state: .absent, status: .absent, pid: 999, cwd: "/w/nowhere")],
            at: at(100), id: EventID("f1")))
        #expect(state.lanes.isEmpty, "a nameless row invented a lane")
    }

    /// Discovery does not resurrect a deleted session. The fleet keeps
    /// listing it, because the process is still running — that is the whole
    /// point of delete — so this is the third door that had to be closed.
    @Test("discovery respects a deletion")
    func deletionOutranksDiscovery() {
        let rows = recordedRows()
        guard let first = rows.first?.session else { Issue.record("no rows"); return }
        var state = DeckState()
        var prefs = DeckPrefs.firstRun
        prefs.deleted = [first.raw]
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(10)))
        Reducer.reduce(&state, .fleet(rows, at: at(100), id: EventID("f1")))
        #expect(state.lanes[first] == nil, "the fleet poll resurrected a deleted session")
        #expect(state.lanes.count == rows.count - 1)
    }

    /// A located address reaches the lane, and a hook's own report wins.
    /// The hook reads the session's own environment, which is the more direct
    /// source; a resolution is the deck working it out from outside.
    @Test("a located address reaches the lane and yields to a hook's own")
    func locatingAndPrecedence() {
        let rows = recordedRows()
        guard let session = rows.first?.session else { Issue.record("no rows"); return }
        var state = DeckState()
        Reducer.reduce(&state, .fleet(rows, at: at(100), id: EventID("f1")))
        #expect(state.lanes[session]?.host == nil, "a fleet row invented an address")

        let found = HostAddress(workspace: "workspace:1", surface: "surface:9")!
        Reducer.reduce(&state, .located(session, host: found, at: at(110), id: EventID("loc")))
        #expect(state.lanes[session]?.host?.value == found, "the located address never landed")

        // A hook arriving later carries the session's own answer and supersedes.
        let own = HostAddress(workspace: "workspace:1", surface: "surface:42")!
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("h"), at: at(120), kind: .userPromptSubmit, session: session,
            cwd: Redacted("/w/p"), tool: nil, toolUseID: nil, held: .absent, host: own)))
        #expect(state.lanes[session]?.host?.value == own,
                "the session's own report lost to a resolution the deck made for it")

        // **And the case that only `absorb` gets right.** A resolution
        // stamped EARLIER but arriving later must lose — the poll and the
        // hook race, and the deck resolves a pid on its own schedule. Direct
        // assignment is newest-by-ARRIVAL and would clobber the session's own
        // answer with a stale one; `absorb` is newest-by-EVENT-TIME, which is
        // what the order-insensitivity rule requires of anything a replayed
        // permutation touches.
        let stale = HostAddress(workspace: "workspace:1", surface: "surface:99")!
        Reducer.reduce(&state, .located(session, host: stale, at: at(115),
                                        id: EventID("late-but-older")))
        #expect(state.lanes[session]?.host?.value == own,
                Comment(rawValue: "a resolution stamped before the hook overwrote it: "
                        + "\(String(describing: state.lanes[session]?.host?.value))"))
    }

    /// Locating a session the deck has no lane for changes nothing.
    /// The no-synthesised-lane rule again: an address is not an origin.
    @Test("an address for an unknown session opens no lane")
    func anAddressIsNotAnOrigin() {
        var state = DeckState()
        let found = HostAddress(workspace: "workspace:1", surface: "surface:9")!
        Reducer.reduce(&state, .located(SessionID("nobody"), host: found,
                                        at: at(100), id: EventID("loc")))
        #expect(state.lanes.isEmpty, "an address invented a lane")
    }

    private func interactiveRow(_ id: String, status: Fed<String>) -> FleetRow {
        FleetRow(session: SessionID(id), name: id, kind: "interactive",
                 state: .absent, status: status, pid: 4242, cwd: "/w/app")
    }

    /// The interactive pair moves a discovered lane. `state` speaks
    /// for background rows and `status` for interactive ones, and only the
    /// first was mapped — so a hook-less lane read "idle" while its session
    /// ran a build, frozen at whatever the launch-time poll saw. Busy moves
    /// it to working, idle brings it back, and a value outside the measured
    /// pair moves nothing.
    @Test("busy moves a discovered lane to working, idle brings it back")
    func statusMovesADiscoveredLane() {
        var state = DeckState()
        let s = SessionID("disc")
        Reducer.reduce(&state, .fleet([interactiveRow("disc", status: .value("busy"))],
                                      at: at(100), id: EventID("f1")))
        #expect(state.lanes[s]?.state == .working,
                "a busy session's lane reads \(String(describing: state.lanes[s]?.state))")
        Reducer.reduce(&state, .fleet([interactiveRow("disc", status: .value("idle"))],
                                      at: at(200), id: EventID("f2")))
        #expect(state.lanes[s]?.state == .idle, "an idle session's lane did not come back")
        Reducer.reduce(&state, .fleet([interactiveRow("disc", status: .value("cogitating"))],
                                      at: at(300), id: EventID("f3")))
        #expect(state.lanes[s]?.state == .idle,
                "a status nobody has seen moved the lane")
    }

    /// The poll is polite, **through every key** — while a hold is actually
    /// open. .needsYou belonging to a feed that knows more (a hook holding a
    /// real question) used to be argued from the fleet's total blindness: it
    /// could not see a dialog at all, so no row from it could be trusted to
    /// move a lane off amber, ever.
    ///
    /// Both keys, deliberately. The first version of this case tested only an
    /// interactive `status` row, and the guard it was pinning sat inside the
    /// interactive branch — leaving the background `state` key an unguarded
    /// path to the same erasure, on a five-second heartbeat. The case that
    /// checks one arm of a rule is the case that lets the other arm ship.
    ///
    /// **Narrowed since.** The fleet now reports `waitingFor` (LV36,
    /// LV34's `project4-a4`), so "the fleet cannot tell a waiting human from
    /// a working process" stopped being true of every poll. What is still
    /// true, and still worth a whole case, is that an OPEN hold outranks any
    /// poll regardless — a human mid-decision on the deck may not have the
    /// card pulled from under them because a scheduler's five-second guess
    /// disagreed. This case pins exactly that half; `DialogTests` below pins
    /// the other — a poll correcting needs-you residue once the hold is
    /// gone — and the block appended to `byStatus` here is the seam between
    /// them: the identical poll that could not move the lane while its hold
    /// was open moves it the instant that hold closes.
    @Test("a poll never stomps a waiting lane with an open hold, by either key")
    func aPollNeverStompsAWaitingLane() {
        func held(_ id: String) -> DeckState {
            var state = DeckState()
            Reducer.reduce(&state, .hook(HookEvent(
                id: EventID("perm"), at: at(100), kind: .permissionRequest,
                session: SessionID(id), cwd: Redacted("/w/app"),
                tool: "Bash", toolUseID: "u1", held: .absent)))
            #expect(state.lanes[SessionID(id)]?.state == .needsYou,
                    "the hold did not raise the lane")
            return state
        }

        // The interactive key.
        var byStatus = held("held")
        Reducer.reduce(&byStatus, .fleet([interactiveRow("held", status: .value("busy"))],
                                         at: at(200), id: EventID("f1")))
        #expect(byStatus.lanes[SessionID("held")]?.state == .needsYou,
                "an interactive row erased a waiting human's signal")

        // **The narrowing, made concrete.** An idle poll sent while the hold
        // is open cannot touch the lane at all; the SAME poll, resent once
        // the hold has closed, corrects it — not because the fleet became
        // more trustworthy, but because there is no longer a human's open
        // decision left to protect. `.decision(.allow)` cannot stand in for
        // "the hold closed" here: the acknowledgement moves the lane to
        // `.working` on its own, before any poll runs, so asserting
        // `.working` afterward would pass under the OLD blanket rule too —
        // verified by reverting the narrowing and rerunning this case
        // unchanged. `.holdExpired` is the release path instead: release is
        // not an answer, so the lane STAYS at `.needsYou` (DeckState.swift
        // ~848) — real residue, with nothing open, for the second poll to
        // correct.
        let heldHold = HoldID(session: SessionID("held"), toolUseID: "u1")
        Reducer.reduce(&byStatus, .fleet([interactiveRow("held", status: .value("idle"))],
                                         at: at(300), id: EventID("f1-still-open")))
        #expect(byStatus.lanes[SessionID("held")]?.state == .needsYou,
                "an idle poll moved the lane while its hold was still open")

        Reducer.reduce(&byStatus, .holdExpired(heldHold, at: at(400)))
        #expect(byStatus.holds[heldHold]?.isOpen == false,
                "the hold is still open — this fixture proves nothing")
        #expect(byStatus.lanes[SessionID("held")]?.state == .needsYou,
                "expiry alone moved the lane — this fixture proves nothing")

        Reducer.reduce(&byStatus, .fleet([interactiveRow("held", status: .value("idle"))],
                                         at: at(500), id: EventID("f1-after-release")))
        #expect(byStatus.lanes[SessionID("held")]?.state == .idle,
                "the same poll could not correct needs-you residue once the hold had closed")

        // The background key — the arm the first guard missed.
        var byState = held("bg")
        Reducer.reduce(&byState, .fleet(
            [FleetRow(session: SessionID("bg"), name: "bg", kind: "background",
                      state: .value("working"), status: .absent, pid: nil, cwd: "/w/app")],
            at: at(200), id: EventID("f2")))
        #expect(byState.lanes[SessionID("bg")]?.state == .needsYou,
                "a background row erased a waiting human's signal")

        // And the one direction the fleet still owns: the
        // fleet-owns-the-light-bar rule makes it the feed that reports a
        // background failure, so `blocked` may RAISE a lane off amber — the
        // deck learning something worse, not something staler.
        var failing = held("dead")
        Reducer.reduce(&failing, .fleet(
            [FleetRow(session: SessionID("dead"), name: "dead", kind: "background",
                      state: .value("blocked"), status: .absent, pid: nil, cwd: "/w/app")],
            at: at(200), id: EventID("f3")))
        #expect(failing.lanes[SessionID("dead")]?.state == .errored,
                "the fleet could not report a failure over a hold")
    }
}

/// The fleet learns to read the dialog itself.
///
/// `fixtures/live/LV36-dialog-open` is a real `claude agents --json` capture
/// with a session mid permission-dialog: `status: "waiting"` carries
/// `waitingFor: "permission prompt"` (`alpha-b5`), alongside a `blocked`
/// background row, an `idle` interactive row and a `busy` one — the four
/// shapes the fleet apply's rewrite has to get right in one file. LV34's
/// `project4-a4` recorded the same `status: "waiting"` with no `waitingFor`
/// at all, which is why `isWaitingOnHuman` reads `status` alone rather than
/// requiring the text beside it.
struct DialogTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private func recordedRows() -> [FleetRow] {
        FleetIngest.rows(from: Corpus.fleetDialogOpen)
    }

    private func row(named name: String) -> FleetRow {
        guard let found = recordedRows().first(where: { $0.name == name }) else {
            preconditionFailure("LV36 lost its \(name) row")
        }
        return found
    }

    /// The real document decodes, and the row this whole feature exists for
    /// carries the text a person would actually be shown.
    @Test("the recorded LV36 document carries a waiting row with its own dialog text")
    func theFixtureDecodes() {
        let rows = recordedRows()
        #expect(rows.count == 4)
        let waiting = row(named: "alpha-b5")
        #expect(waiting.isWaitingOnHuman)
        #expect(waiting.waitingFor == "permission prompt")
        #expect(!row(named: "bravo-02").isWaitingOnHuman)
        #expect(!row(named: "openagentdeck-58").isWaitingOnHuman)
        #expect(row(named: "spike-fail").isFailing)
    }

    /// **The raise.** A working lane the deck had no other reason to
    /// suspect gets pulled to needs-you the moment the fleet reports the
    /// dialog it opened — the fact `FleetRow` dropped until now — and the
    /// dialog's own text lands on the record.
    @Test("a waiting row raises a working lane to needs-you and carries its text")
    func waitingRowRaisesTheLane() {
        var state = DeckState()
        let waiting = row(named: "alpha-b5")
        guard let session = waiting.session else { Issue.record("no session"); return }

        Reducer.reduce(&state, .fleet(
            [FleetRow(session: session, name: "alpha-b5", kind: "interactive",
                      state: .absent, status: .value("busy"))],
            at: at(100), id: EventID("f0")))
        #expect(state.lanes[session]?.state == .working, "the fixture never reached working")

        Reducer.reduce(&state, .fleet([waiting], at: at(200), id: EventID("f1")))
        #expect(state.lanes[session]?.state == .needsYou,
                "the fleet's own waiting row did not raise the lane")
        #expect(state.lanes[session]?.waitingFor.value == "permission prompt",
                "the dialog's own text never reached the record")
    }

    /// **The demotion, gated on the hold.** Needs-you residue — a lane a
    /// hold raised and then closed, releasing or expiring rather than
    /// resolving into `.working` the way a decision does — comes back down
    /// once the fleet reports the session idle again, PROVIDED nothing is
    /// open. Busy deliberately moves nothing (the ambiguity the `waiting`
    /// vocabulary exists to resolve); an open hold is a human's own undecided
    /// moment on the deck, and the fleet cannot distinguish that from an idle
    /// screen either way, so it still may not touch it.
    @Test("an idle row demotes needs-you residue with no open hold, and only then")
    func idleRowDemotesResidueOnly() {
        let idleRow = row(named: "bravo-02")
        guard let session = idleRow.session else { Issue.record("no session"); return }

        // Residue: needs-you with NOTHING open — exactly what a released or
        // expired hold leaves behind. `HoldLifecycleTests.aReleasedHoldKeepsItsLaneWaiting`
        // is the citation: expiry does not touch the lane, only the hold.
        var resolved = DeckState()
        let closedHold = HoldID(session: session, toolUseID: "u1")
        Reducer.reduce(&resolved, .hook(HookEvent(
            id: EventID("perm"), at: at(0), kind: .permissionRequest, session: session,
            cwd: Redacted("/w"), tool: "Bash", toolUseID: "u1", held: .absent)))
        #expect(resolved.lanes[session]?.state == .needsYou)
        Reducer.reduce(&resolved, .holdExpired(closedHold, at: at(130_000)))
        #expect(resolved.holds[closedHold]?.isOpen == false,
                "the hold is still open — this fixture proves nothing")
        #expect(resolved.lanes[session]?.state == .needsYou,
                "expiry already moved the lane — this fixture proves nothing")

        Reducer.reduce(&resolved, .fleet([idleRow], at: at(140_000), id: EventID("f1")))
        #expect(resolved.lanes[session]?.state == .idle,
                "an idle row could not correct needs-you residue with nothing open")

        // Same shape, hold still OPEN — the poll may not touch it.
        var stillOpen = DeckState()
        let openHold = HoldID(session: session, toolUseID: "u2")
        Reducer.reduce(&stillOpen, .hook(HookEvent(
            id: EventID("perm2"), at: at(0), kind: .permissionRequest, session: session,
            cwd: Redacted("/w"), tool: "Bash", toolUseID: "u2", held: .absent)))
        #expect(stillOpen.lanes[session]?.state == .needsYou)
        #expect(stillOpen.holds[openHold]?.isOpen == true)
        Reducer.reduce(&stillOpen, .fleet([idleRow], at: at(500), id: EventID("f2")))
        #expect(stillOpen.lanes[session]?.state == .needsYou,
                "an idle row pulled the card out from under an open hold")
    }

    /// **The demotion, narrowed further.** A holdless needs-you lane — one
    /// no hold ever protected, such as a lane raised by a Notification
    /// `permission_prompt` — may be demoted only by an IDLE row, never a
    /// busy one. `idle` is the fleet's own definition of "the turn ended",
    /// which by construction excludes an open dialog; `busy` is exactly the
    /// ambiguity the `waiting`/`waitingFor` vocabulary exists to resolve,
    /// and a fleet CLI that predates that vocabulary (S7/S9-era, `busy`/
    /// `idle` and nothing else) must not be able to erase a real dialog's
    /// amber every five seconds just because it cannot see the dialog it is
    /// standing on top of.
    @Test("a busy row does not demote a holdless needs-you lane")
    func busyRowDoesNotDemoteHoldlessNeedsYou() {
        let session = SessionID("holdless")
        var state = DeckState()
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("notif-perm"), at: at(0), kind: .notification, session: session,
            cwd: Redacted("/w"), tool: nil, toolUseID: nil, held: .absent,
            notificationType: "permission_prompt")))
        #expect(state.lanes[session]?.state == .needsYou,
                "a permission_prompt notification did not raise the lane")
        #expect(state.holds.isEmpty,
                "a Notification opened a hold — this fixture proves nothing")

        let busyRow = FleetRow(session: session, name: "holdless", kind: "interactive",
                               state: .absent, status: .value("busy"))
        Reducer.reduce(&state, .fleet([busyRow], at: at(100), id: EventID("f-busy")))
        #expect(state.lanes[session]?.state == .needsYou,
                "a busy row demoted a holdless needs-you lane with no dialog it could see")
    }

    /// **The clear.** `waitingFor` is written unconditionally, like
    /// `fleetState` beside it — a later poll that no longer carries the row
    /// (the dialog closed, and the fleet stopped reporting it) clears the
    /// slot rather than leaving stale dialog text on screen.
    @Test("a later poll with no waiting row clears waitingFor")
    func laterPollClearsWaitingFor() {
        var state = DeckState()
        let waiting = row(named: "alpha-b5")
        guard let session = waiting.session else { Issue.record("no session"); return }

        Reducer.reduce(&state, .fleet([waiting], at: at(100), id: EventID("f1")))
        #expect(state.lanes[session]?.waitingFor.value == "permission prompt")

        let idleAgain = FleetRow(session: session, name: "alpha-b5", kind: "interactive",
                                 state: .absent, status: .value("idle"))
        Reducer.reduce(&state, .fleet([idleAgain], at: at(200), id: EventID("f2")))
        #expect(state.lanes[session]?.waitingFor.value == nil,
                "a poll with no dialog left the old one showing")
    }
}
