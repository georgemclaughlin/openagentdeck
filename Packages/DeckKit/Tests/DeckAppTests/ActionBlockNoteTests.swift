//
//  ActionBlockNoteTests.swift · Tests/DeckAppTests
//
//  B1's own regression guard: every `drain()` branch that darkens a control
//  with a non-nil `ActionBlock` must also `note` why, in the log at
//  `DeckRuntime.logPathForTesting` — guarding a refusal that was
//  undiagnosable because four of those branches said nothing to the
//  log while `Diagnostics.swift` already promised the runtime would.
//
//  Against the SAME `RecordingHost` (`PanelDrainTests.swift`, this target) and
//  `ScriptedFleet` (`FleetDiscoveryTests.swift`, this target) the sibling
//  suites already built — this file drives no process of its own, only the
//  real `queue`/`drain`/`select`/`pollFleet` seams those two files already
//  proved out.
//

import Testing
import Foundation
import DeckCore
import DeckPorts
@testable import DeckApp

@MainActor
struct ActionBlockNoteTests {

    private let address = HostAddress(workspace: "workspace:14", surface: "surface:18")!
    private let session = SessionID("s-note")

    private func hook(_ kind: HookKind, _ id: String,
                      host: HostAddress? = nil, prompt: String? = nil) -> HookEvent {
        HookEvent(id: EventID(id), at: .start, kind: kind, session: session,
                  cwd: Redacted("/work/project"), tool: nil, toolUseID: nil,
                  held: .absent, prompt: Redacted(optional: prompt), host: host)
    }

    /// A started, idle, routable session with the panel open on it — the
    /// same shape `PanelDrainTests.armed(_:host:)` builds, copied rather than
    /// shared because that helper is `private` to its own file.
    private func armed(_ runtime: DeckRuntime, host: RecordingHost) async {
        runtime.markStartedForTesting()
        runtime.host = host
        _ = await runtime.handle(hook(.sessionStart, "start", host: address))
    }

    private func inventoryHolding(_ addresses: [HostAddress]) -> Result<[HostSession], PortFailure> {
        .success(addresses.map { HostSession(address: $0, title: "probe", isSelected: false) })
    }

    /// Reads the note log back as one string — a fresh, empty file reads as
    /// empty rather than throwing, same tolerance `LogRotationTests.lines(_:)`
    /// gives a log that has not been written to yet.
    private func logText(_ path: String) -> String {
        (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
    }

    /// Let the runtime's detached `drain()`/`probeHost()` `Task`s finish.
    /// Yields only — no clock — the identical instrument `PanelDrainTests
    /// .settle()` already uses and states the reasoning for.
    private func settle() async {
        for _ in 0 ..< 500 { await Task.yield() }
    }

    // ---------------------------------------------------------- composer refusal

    /// **The privacy pin, asserted both ways.** The note must say WHICH
    /// `Composer.Reading` case refused the send (`holdingText`) so a person
    /// debugging a dark Continue button knows why without guessing — and it
    /// must say NOTHING ELSE about what was actually on the screen. The
    /// marker string below stands in for anything a real draft could hold;
    /// if it ever reached the log the privacy absolute broke, so this test
    /// fails loudly on that alone even if the diagnostic line itself is
    /// otherwise perfect.
    @Test("a composer refusal notes the reading, never the screen")
    func composerRefusalNotes() async {
        let runtime = DeckRuntime()
        let marker = "MARKERDRAFT-9F3B21"
        let screen = "────────\n❯ \(marker)\n────────\n"
        let host = RecordingHost(inventory: inventoryHolding([address]), screen: .success(screen))
        await armed(runtime, host: host)
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])          // Continue — a .prompt action
        await settle()

        #expect(runtime.frame.actionBlock == .composerBusy,
                "the fixture's own premise: a holding-text screen must refuse as composerBusy")

        let log = logText(runtime.logPathForTesting)
        #expect(log.contains("action blocked: composerBusy (composer read holdingText) session=\(session.raw)"),
                Comment(rawValue: "the log did not carry the composer-refusal note; full log:\n\(log)"))
        #expect(!log.contains(marker),
                "the privacy absolute broke — the screen's own text reached the log")
    }

    // ---------------------------------------------------------- inventory failure

    @Test("an inventory failure inside drain notes the adapter's own reason")
    func inventoryFailureNotes() async {
        let runtime = DeckRuntime()
        let reason = "cmux is not accepting connections from the deck"
        let host = RecordingHost(inventory: .failure(.unavailable(reason)))
        await armed(runtime, host: host)
        runtime.select(session)
        await settle()
        runtime.queue(QuickAction.shipped[0])
        await settle()

        let log = logText(runtime.logPathForTesting)
        #expect(log.contains("action blocked: hostUnavailable (inventory failed: \(reason))"),
                Comment(rawValue: "the log did not carry the inventory-failure note; full log:\n\(log)"))
    }

    // ------------------------------------------------------ address not in inventory

    @Test("a surface the host does not list notes why, by session")
    func addressNotInInventoryNotes() async {
        let runtime = DeckRuntime()
        let elsewhere = HostAddress(workspace: "workspace:2", surface: "surface:9")!
        let host = RecordingHost(inventory: inventoryHolding([elsewhere]))
        await armed(runtime, host: host)
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])
        await settle()

        #expect(runtime.frame.actionBlock == .unroutable,
                "the fixture's own premise: an inventory with no matching address must refuse as unroutable")

        let log = logText(runtime.logPathForTesting)
        #expect(log.contains("action blocked: unroutable (address not in host inventory) session=\(session.raw)"),
                Comment(rawValue: "the log did not carry the address-not-in-inventory note; full log:\n\(log)"))
    }

    // -------------------------------------------------------------- lane has no host

    /// A lane the deck has never routed at all — no hook has ever carried a
    /// host address for it. `drain()`'s FIRST guard, and the one branch a
    /// hostless deck (no `RecordingHost` even reachable yet) can still hit.
    @Test("a lane with no host address notes why before ever asking the host anything")
    func laneWithNoHostNotes() async {
        let runtime = DeckRuntime()
        // No `host:` on this hook — the lane opens with `host == nil`,
        // exactly the state a session the deck has watched but never been
        // addressed by is in.
        let host = RecordingHost(inventory: .success([]))
        runtime.markStartedForTesting()
        runtime.host = host
        _ = await runtime.handle(hook(.sessionStart, "start"))
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])
        await settle()

        // `drain()`'s own guard returns before ever calling `host.inventory()`
        // for THIS action — `select()`'s own `probeHost()` (a separate,
        // unconditional reachability check, `probeHost`'s own doc comment)
        // is the only caller of `inventory()` that fires here, so `kinds()`
        // shows exactly one "inventory" call, never a second from `drain()`.
        let inventoryCalls = (await host.kinds()).filter { $0 == "inventory" }.count
        #expect(inventoryCalls == 1, Comment(rawValue:
                "expected exactly one inventory call (from select()'s own probeHost, not drain()'s), "
                + "got \(inventoryCalls)"))
        let log = logText(runtime.logPathForTesting)
        #expect(log.contains("action blocked: unroutable (lane has no host address) session=\(session.raw)"),
                Comment(rawValue: "the log did not carry the no-host note; full log:\n\(log)"))
    }

    // -------------------------------------------------------------- read-screen failure

    /// The host answers inventory, resolves the address, and then the READ
    /// itself fails — a distinct step from the inventory failure above, and
    /// the one branch of the `.prompt` path that fails before the composer
    /// is ever judged.
    @Test("a read-screen failure on the prompt path notes the adapter's own reason")
    func readScreenFailureNotes() async {
        let runtime = DeckRuntime()
        let reason = "garbled screen bytes"
        let host = RecordingHost(inventory: inventoryHolding([address]),
                                 screen: .failure(.malformed(reason)))
        await armed(runtime, host: host)
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])          // Continue — a .prompt action, reads first
        await settle()

        #expect(runtime.frame.actionBlock == .hostError,
                "the fixture's own premise: a malformed read must refuse as hostError")

        let log = logText(runtime.logPathForTesting)
        #expect(log.contains("action blocked: hostError (read-screen failed: \(reason)) session=\(session.raw)"),
                Comment(rawValue: "the log did not carry the read-screen-failure note; full log:\n\(log)"))
    }

    // ------------------------------------------------- the hold path, same words

    /// A started session whose question mirror is driven to `.terminalLive`
    /// — `ForwardPlanRuntimeTests.terminalLiveRuntime`'s own sequence,
    /// copied rather than shared because that helper is `private` to its
    /// own file (the same trade `armed(_:host:)` above already made).
    /// `laneHost: nil` leaves the lane unrouted — no hook ever carries an
    /// address — the one shape the no-host branch below needs and the
    /// original helper cannot produce.
    private func terminalLive(_ runtime: DeckRuntime, host: RecordingHost,
                              laneHost: HostAddress?) async {
        runtime.markStartedForTesting()
        runtime.host = host
        _ = await runtime.handle(hook(.sessionStart, "start", host: laneHost))
        let hold = HoldID(session: session, toolUseID: "t1")
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: false)
        runtime.apply(.hook(HookEvent(id: EventID("pre"), at: Instant(sinceStart: Millis(0)),
                                      kind: .preToolUse, session: session, cwd: nil,
                                      tool: SubjectReader.questionTool, toolUseID: "t1",
                                      held: .value(1), questions: [question])))
        runtime.apply(.holdExpired(hold, at: Instant(sinceStart: Millis(8_000))))
        runtime.apply(.hook(HookEvent(id: EventID("pr"), at: Instant(sinceStart: Millis(20_000)),
                                      kind: .permissionRequest, session: session, cwd: nil,
                                      tool: SubjectReader.questionTool, toolUseID: nil, held: .absent)))
        runtime.apply(.hook(HookEvent(id: EventID("nt"), at: Instant(sinceStart: Millis(26_000)),
                                      kind: .notification, session: session, cwd: nil, tool: nil,
                                      toolUseID: nil, held: .absent,
                                      notificationType: "permission_prompt")))
    }

    /// Forwards the terminal-live mirror and waits the plan out. Returns
    /// the log, read after the plan's own task has finished.
    private func forwardAndSettle(_ runtime: DeckRuntime) async -> String {
        let hold = HoldID(session: session, toolUseID: "t1")
        let mirror = runtime.frame.mirrors.first { $0.hold == hold }
        #expect(mirror != nil, "the mirror never reached terminalLive — nothing to forward against")
        guard let mirror else { return logText(runtime.logPathForTesting) }
        runtime.forward(mirror, picking: [Redacted("B")])
        await runtime.pendingForwardTask[hold]?.value
        await settle()
        return logText(runtime.logPathForTesting)
    }

    /// **The drift story, closed.** `runForwardPlan`'s three
    /// refusal notes are duplicated literals of `drain()`'s, not shared
    /// constants — so nothing but these three tests holds the two paths
    /// to the SAME words. A hold-path refactor that rewords or drops one
    /// would stay green everywhere else and recreate the same
    /// failure class one path over: a dark control whose log line a
    /// format-derived grep no longer finds.
    @Test("the hold path notes an inventory failure in drain's own words")
    func holdPathInventoryFailureNotes() async {
        let runtime = DeckRuntime()
        let reason = "cmux is not accepting connections from the deck"
        let host = RecordingHost(inventory: .failure(.unavailable(reason)))
        await terminalLive(runtime, host: host, laneHost: address)

        let log = await forwardAndSettle(runtime)

        #expect(log.contains("action blocked: hostUnavailable (inventory failed: \(reason))"),
                Comment(rawValue: "the hold path did not carry the inventory-failure note; full log:\n\(log)"))
        let hold = HoldID(session: session, toolUseID: "t1")
        #expect(runtime.frame.mirrors.first { $0.hold == hold }?.forwarding != true,
                "a cancelled plan is still occupying state")
    }

    @Test("the hold path notes a surface the host does not list, by session")
    func holdPathAddressNotInInventoryNotes() async {
        let runtime = DeckRuntime()
        let elsewhere = HostAddress(workspace: "workspace:2", surface: "surface:9")!
        let host = RecordingHost(inventory: inventoryHolding([elsewhere]))
        await terminalLive(runtime, host: host, laneHost: address)

        let log = await forwardAndSettle(runtime)

        #expect(log.contains("action blocked: unroutable (address not in host inventory) session=\(session.raw)"),
                Comment(rawValue: "the hold path did not carry the address-not-in-inventory note; full log:\n\(log)"))
    }

    @Test("the hold path notes a lane with no host address before asking the host anything")
    func holdPathNoHostNotes() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: .success([]))
        await terminalLive(runtime, host: host, laneHost: nil)

        let log = await forwardAndSettle(runtime)

        #expect(log.contains("action blocked: unroutable (lane has no host address) session=\(session.raw)"),
                Comment(rawValue: "the hold path did not carry the no-host note; full log:\n\(log)"))
    }

    // -------------------------------------------------------------- fleet pid-less

    /// **`claude agents --json` (2.1.231) dropped `pid`.** A non-empty poll
    /// whose rows carry no pid on any of them starves `locate(_:)` of the
    /// one field it routes by, silently — this pins the ONE note that makes
    /// that diagnosable, and that it fires ONCE per process rather than once
    /// per poll (a five-second heartbeat would otherwise flood the log with
    /// the identical line forever).
    @Test("a fleet poll with no pid on any row notes it exactly once")
    func fleetPidlessNotesOnce() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let row = FleetRow(session: session, name: "s-note", kind: "interactive",
                           state: .absent, status: .value("idle"), pid: nil, cwd: "/w/repo")
        runtime.fleet = ScriptedFleet([[row]])
        runtime.worktree = RecordingWorktree(answer: nil)

        await runtime.pollFleet()
        await runtime.pollFleet()
        await runtime.pollFleet()

        let log = logText(runtime.logPathForTesting)
        let needle = "fleet feed carries no pid on any row; pid discovery routing unavailable " +
            "(claude agents --json 2.1.231 is known to omit the field)"
        let occurrences = log.components(separatedBy: needle).count - 1
        #expect(occurrences == 1, Comment(rawValue:
                "three polls with no pid on any row produced \(occurrences) note(s), expected exactly " +
                "one — full log:\n\(log)"))
    }

    /// The negative case beside it: a row that DOES carry a pid must never
    /// trip the warning — the fixture-only worry a looser predicate (e.g.
    /// "the first row has no pid") could pass by accident.
    @Test("a fleet poll where every row carries a pid notes nothing")
    func fleetWithPidNotesNothing() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let row = FleetRow(session: session, name: "s-note", kind: "interactive",
                           state: .absent, status: .value("idle"), pid: 4242, cwd: "/w/repo")
        runtime.fleet = ScriptedFleet([[row]])
        runtime.worktree = RecordingWorktree(answer: nil)
        let host = RecordingHost(inventory: .success([]))
        runtime.host = host

        await runtime.pollFleet()

        let log = logText(runtime.logPathForTesting)
        #expect(!log.contains("pid discovery routing unavailable"),
                Comment(rawValue: "a fleet row that DID carry a pid still tripped the pid-less warning; full log:\n\(log)"))
    }
}
