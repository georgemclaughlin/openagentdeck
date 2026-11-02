//
//  FleetDiscoveryTests.swift · Tests/DeckAppTests
//
//  The runtime's side of discovery — what a poll DOES with a row, beyond what
//  the reducer decides about it. Against scripted ports: the point of
//  `FleetPort` and `WorktreePort` is that this file never launches a process.
//
//  These exist because the live deck shipped without them and a person found
//  every gap at once: a lane stuck on the state the launch-time poll saw, and
//  a git repository rendering no branch — the fleet row carried the directory
//  and nobody was looking at it.
//

import Testing
import Foundation
import DeckCore
import DeckPorts
@testable import DeckApp

/// One scripted answer per poll; the last repeats.
actor ScriptedFleet: FleetPort {
    private var script: [[FleetRow]]
    init(_ script: [[FleetRow]]) { self.script = script }
    func poll() async -> [FleetRow] {
        script.count > 1 ? script.removeFirst() : script[0]
    }
}

/// Every directory asked about, in order, and one scripted answer for all.
actor RecordingWorktree: WorktreePort {
    private(set) var asked: [String] = []
    private let answer: String?
    init(answer: String?) { self.answer = answer }
    func branch(at path: String) async -> String? {
        asked.append(path)
        return answer
    }
}

@MainActor
struct FleetDiscoveryTests {

    private let session = SessionID("disc-1")

    private func row(status: String?, cwd: String = "/w/repo") -> FleetRow {
        FleetRow(session: session, name: "disc", kind: "interactive",
                 state: .absent, status: status.map(Fed.value) ?? .absent,
                 pid: nil, cwd: cwd)
    }

    /// A later poll moves the lane. The launch-time poll answered
    /// "idle" and the lane froze there; the runtime now polls on a heartbeat,
    /// and this is the per-poll half of that fix: each poll's rows reach the
    /// reducer and move the state.
    @Test("a second poll refreshes a discovered lane's state")
    func aSecondPollRefreshes() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.fleet = ScriptedFleet([[row(status: "idle")], [row(status: "busy")]])
        runtime.worktree = RecordingWorktree(answer: nil)

        await runtime.pollFleet()
        #expect(runtime.frame.lanes.first { $0.session == session }?.state == .idle)
        await runtime.pollFleet()
        #expect(runtime.frame.lanes.first { $0.session == session }?.state == .working,
                "the second poll's busy row did not move the lane")
    }

    /// **The collision, as a test.**
    ///
    /// The event id was `fleet-<rowCount>-<milliseconds>`, and the reducer is
    /// idempotent per (session, event id) — so two polls in the same
    /// millisecond carrying the same number of rows were one event as far as
    /// the deck was concerned, and the second was dropped as the duplicate it
    /// was not. The lane held whatever the first poll saw.
    ///
    /// Ten polls back to back is far inside one millisecond on any machine
    /// this runs on, so under the old id every one after the first vanished.
    /// The state has to follow the last row regardless of how fast they come.
    @Test("polls in the same millisecond are separate events")
    func rapidPollsAreNotMistakenForDuplicates() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        // idle, busy, idle, busy … ending busy, so a dropped poll shows up as
        // the wrong final state rather than as a lucky match.
        let script = (0 ..< 10).map { [row(status: $0.isMultiple(of: 2) ? "idle" : "busy")] }
        runtime.fleet = ScriptedFleet(script)
        runtime.worktree = RecordingWorktree(answer: nil)

        for _ in 0 ..< 10 { await runtime.pollFleet() }

        #expect(runtime.frame.lanes.first { $0.session == session }?.state == .working,
                "a poll was discarded as a duplicate of one it only shared a millisecond with")
    }

    /// A discovered lane gets a branch, from the fleet row's own
    /// directory, resolved once per directory rather than once per poll. The
    /// hook path already did this; the fleet path carried the cwd and never
    /// looked, so a discovered lane in a git worktree rendered no branch.
    @Test("a discovered lane resolves its branch from the fleet row's cwd")
    func discoveredLaneGetsABranch() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.fleet = ScriptedFleet([[row(status: "idle")]])
        let worktree = RecordingWorktree(answer: "feature/payments")
        runtime.worktree = worktree

        await runtime.pollFleet()
        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane?.branch?.value == "feature/payments",
                "the branch is \(String(describing: lane?.branch)) — the row's cwd was never resolved")
        #expect(lane?.sources["branch"] != nil, "the branch arrived with no provenance")

        // The dedupe: an unchanged directory is not re-walked on every beat.
        await runtime.pollFleet()
        let askedTwice = await worktree.asked
        #expect(askedTwice == ["/w/repo"],
                Comment(rawValue: "asked \(askedTwice.count) time(s) for one unchanged cwd"))
    }

    /// At the runtime seam: a directory that is not a git
    /// worktree yields NO branch row — not a placeholder, not the previous
    /// answer. The port answering nil must leave the lane exactly branchless.
    @Test("a non-repository cwd renders no branch")
    func noRepositoryNoBranch() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.fleet = ScriptedFleet([[row(status: "idle", cwd: "/tmp/plain")]])
        runtime.worktree = RecordingWorktree(answer: nil)

        await runtime.pollFleet()
        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane != nil, "the row opened no lane at all")
        #expect(lane?.branch == nil,
                "a plain directory grew a branch: \(String(describing: lane?.branch))")
    }

    /// **A pid the host cannot place is asked about once.**
    ///
    /// `locate` skipped sessions that already had an address, which bounded
    /// the successful case and silently did nothing for the failing one: a
    /// failure sets no address, so the ask repeated on every beat. Free when
    /// the poll ran once at launch; at a five-second heartbeat on a machine
    /// with no cmux — or a cmux refusing the socket, both measured states —
    /// it is a process launch per session per beat, forever.
    @Test("an unplaceable pid is asked about once, not on every beat")
    func anUnplaceablePidIsAskedOnce() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let withPID = FleetRow(session: session, name: "disc", kind: "interactive",
                               state: .absent, status: .value("idle"), pid: 4242, cwd: "/w/repo")
        runtime.fleet = ScriptedFleet([[withPID]])
        runtime.worktree = RecordingWorktree(answer: nil)
        // A host that places nobody — `addresses` is empty, so `address(ofPID:)`
        // answers nil, exactly as a machine without cmux does.
        let host = RecordingHost(inventory: .success([]))
        runtime.host = host

        for _ in 0 ..< 4 { await runtime.pollFleet() }
        let locates = await host.kinds().filter { $0 == "locate" }.count
        #expect(locates == 1,
                Comment(rawValue: "four polls asked the host \(locates) time(s) about one "
                        + "unplaceable pid — a retry storm at the heartbeat's cadence"))
    }

    /// **A tombstone survives a roster that merely blinked.**
    ///
    /// The collector defended the EMPTY roster (the CLI failing) and said
    /// nothing about a partial one — a roster listing other sessions while
    /// omitting this one. Collecting on that single miss drops the tombstone,
    /// and the next poll re-admits the session as a brand-new discovery: the
    /// deck silently resuming supervision of a session the user removed. At
    /// launch-only cadence this needed a relaunch; at five seconds it is
    /// sampled seven hundred times an hour.
    @Test("one missing poll does not collect a tombstone")
    func aTombstoneSurvivesABlink() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let other = FleetRow(session: SessionID("other"), name: "other", kind: "interactive",
                             state: .absent, status: .value("idle"), pid: nil, cwd: "/w/other")
        // Present, then absent from a roster that still lists somebody else.
        runtime.fleet = ScriptedFleet([[row(status: "idle"), other], [other]])
        runtime.worktree = RecordingWorktree(answer: nil)

        await runtime.pollFleet()
        runtime.delete(session)
        #expect(runtime.prefs.deleted.contains(session.raw), "the delete did not take")

        await runtime.pollFleet()          // the blink
        #expect(runtime.prefs.deleted.contains(session.raw),
                "one partial roster collected the tombstone — the session can walk back in")
        #expect(runtime.frame.lanes.allSatisfy { $0.session != session },
                "the deleted session came back")

        // Gone for good, and the tombstone is dead weight: it goes.
        for _ in 0 ..< DeckRuntime.tombstoneMisses { await runtime.pollFleet() }
        #expect(!runtime.prefs.deleted.contains(session.raw),
                "a session gone for good kept its tombstone forever")
    }
}
