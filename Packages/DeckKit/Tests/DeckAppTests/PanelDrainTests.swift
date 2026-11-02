//
//  PanelDrainTests.swift · Tests/DeckAppTests
//
//  In the app target: the runtime's side of a send.
//
//  The reducer answers *what next* and this layer *acts*, so everything that can
//  go wrong on the way to the wire is only observable here — the inventory check
//  before a send, the composer read before a write, the two-step type-then-submit,
//  and the reporting back that makes a dark control say why.
//
//  Against a RECORDING host rather than cmux: the point of `SessionHostPort` is
//  that this file never launches a process. What the fake returns, though, is
//  what the real one returned when it was measured — the composer screens are the
//  bytes `fixtures/live/LV30-multitab` recorded, U+00A0 padding and all.
//

import Testing
import Foundation
import DeckCore
import DeckPorts
@testable import DeckApp

/// Every call, in order, and whatever answer the test wants.
actor RecordingHost: SessionHostPort {
    struct Call: Equatable {
        let kind: String
        let argument: String
        let address: SessionAddress?
    }

    private(set) var calls: [Call] = []
    private var inventoryResult: Result<[HostSession], PortFailure>
    private var screen: Result<String, PortFailure>
    private var sendResult: SendOutcome
    private var keyResult: SendOutcome
    private var addresses: [Int: SessionAddress]

    init(inventory: Result<[HostSession], PortFailure>,
         screen: Result<String, PortFailure> = .success("❯\u{00A0}\n"),
         send: SendOutcome = .sent, key: SendOutcome = .sent,
         addresses: [Int: SessionAddress] = [:]) {
        self.addresses = addresses
        self.inventoryResult = inventory
        self.screen = screen
        self.sendResult = send
        self.keyResult = key
    }

    func inventory() async -> Result<[HostSession], PortFailure> {
        calls.append(Call(kind: "inventory", argument: "", address: nil))
        return inventoryResult
    }

    func read(_ address: SessionAddress, lines: Int) async -> Result<String, PortFailure> {
        calls.append(Call(kind: "read", argument: "\(lines)", address: address))
        return screen
    }

    func send(_ text: String, to address: SessionAddress) async -> SendOutcome {
        calls.append(Call(kind: "send", argument: text, address: address))
        return sendResult
    }

    func sendKey(_ key: String, to address: SessionAddress) async -> SendOutcome {
        calls.append(Call(kind: "key", argument: key, address: address))
        return keyResult
    }

    /// Where a pid runs. The recording host answers from a table the test sets,
    /// so discovery is checkable without a terminal or a process to inspect.
    func address(ofPID pid: Int) async -> SessionAddress? {
        calls.append(Call(kind: "locate", argument: String(pid), address: nil))
        return addresses[pid]
    }

    func record() -> [Call] { calls }
    func kinds() -> [String] { calls.map(\.kind) }
}

@MainActor
struct PanelDrainTests {

    private let address = HostAddress(workspace: "workspace:14", surface: "surface:18")!
    private let session = SessionID("s-drain")

    private func recordedScreen(_ name: String) -> String {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/live/LV30-multitab/\(name)")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func hook(_ kind: HookKind, _ id: String,
                      host: HostAddress? = nil, prompt: String? = nil) -> HookEvent {
        HookEvent(id: EventID(id), at: .start, kind: kind, session: session,
                  cwd: Redacted("/work/project"), tool: nil, toolUseID: nil,
                  held: .absent, prompt: Redacted(optional: prompt), host: host)
    }

    /// A started, idle, routable session with the panel open on it.
    private func armed(_ runtime: DeckRuntime, host: RecordingHost) async {
        runtime.markStartedForTesting()
        runtime.host = host
        _ = await runtime.handle(hook(.sessionStart, "start", host: address))
    }

    private func inventoryHolding(_ addresses: [HostAddress]) -> Result<[HostSession], PortFailure> {
        .success(addresses.map { HostSession(address: $0, title: "probe", isSelected: false) })
    }

    /// **The address survives the runtime's re-stamping.** The
    /// regression guard for a defect that was live: `handle` rebuilds the arrived
    /// event field by field, and it omitted `host`, so every session the deck
    /// watched arrived with no route. The reducer was right, the ingest was
    /// right, the hook was right, and the deck could not have sent anything to
    /// anyone.
    @Test("a hook's host address reaches the lane")
    func addressSurvivesTheRuntime() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: inventoryHolding([address]))
        await armed(runtime, host: host)

        let lane = runtime.frame.lanes.first { $0.session == session }
        #expect(lane?.host == address,
                "the lane's address is \(String(describing: lane?.host)) — the wire carried it and the runtime dropped it")
        #expect(lane?.sources["host"] != nil, "the address arrived with no provenance")
    }

    /// The happy path, in order: ask the host what exists, read the
    /// composer, type, then submit. Four calls, and the two writes are separate
    /// because "type" and "submit" are separate decisions.
    @Test("a queued action is typed and then submitted, to the right surface")
    func theHappyPath() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: inventoryHolding([address]))
        await armed(runtime, host: host)
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])          // Continue
        await settle()

        let calls = await host.record()
        #expect(calls.map(\.kind).contains(["inventory", "read", "send", "key"]),
                Comment(rawValue: "the call order was \(calls.map(\.kind))"))
        guard let send = calls.first(where: { $0.kind == "send" }),
              let key = calls.first(where: { $0.kind == "key" }) else {
            Issue.record("nothing was sent"); return
        }
        #expect(send.argument == "Continue", "the deck sent \(send.argument.debugDescription)")
        #expect(send.address == address, "the deck sent to the wrong surface")
        #expect(key.argument == "enter")
        #expect(key.address == address)

        // And the core was told, so the panel can say "sent" rather than
        // guessing: a confirmable action stays visible until its receipt.
        #expect(runtime.frame.queued.map(\.status) == [.sent],
                "the runtime put it on the wire and never told the core")
        #expect(runtime.frame.actionBlock == nil)
    }

    /// Against the recorded shell screen. LV30 measured the
    /// cost of not doing this: a prompt sent to a surface whose session had not
    /// started ran as a shell command.
    @Test("a composer the deck did not empty refuses the send")
    func readBeforeWrite() async {
        // Each refusal must report ITSELF. Both used to report `composerBusy`,
        // so a deck pointed at a shell told the user their composer was full —
        // observed on a live session, where `/compact` refused with a reason
        // describing a draft that did not exist.
        for (name, why, expected) in [("screen-A.txt", "a shell", ActionBlock.surfaceNotASession),
                                      ("draft", "a draft", ActionBlock.composerBusy)] {
            let screen = name == "draft"
                ? "────────\n❯ MYDRAFT\n────────\n"
                : recordedScreen(name)
            #expect(!screen.isEmpty, "the recorded screen is missing")

            let runtime = DeckRuntime()
            let host = RecordingHost(inventory: inventoryHolding([address]),
                                     screen: .success(screen))
            await armed(runtime, host: host)
            runtime.select(session)
            runtime.queue(QuickAction.shipped[0])
            await settle()

            let kinds = await host.kinds()
            #expect(!kinds.contains("send"),
                    Comment(rawValue: "\(why): the deck typed into a composer it did not empty"))
            #expect(runtime.frame.actionBlock == expected,
                    Comment(rawValue: "\(why): reported \(String(describing: runtime.frame.actionBlock)) "
                            + "instead of \(expected.rawValue) — the reason names the wrong problem"))
            // Refused, not dropped: the action is still there to try again.
            #expect(runtime.frame.queued.map(\.status) == [.queued],
                    Comment(rawValue: "\(why): a refused action was thrown away"))
        }
    }

    /// : the target must still be in the host's inventory.
    /// Asked fresh every time, because a surface the person closed a moment ago
    /// is exactly the address a cached answer would send to.
    @Test("a surface the host no longer lists is not sent to")
    func inventoryGate() async {
        let runtime = DeckRuntime()
        let elsewhere = HostAddress(workspace: "workspace:2", surface: "surface:9")!
        let host = RecordingHost(inventory: inventoryHolding([elsewhere]))
        await armed(runtime, host: host)
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])
        await settle()

        let kinds = await host.kinds()
        #expect(!kinds.contains("send"), "the deck sent to a surface the host does not have")
        #expect(!kinds.contains("read"), "the deck read a surface it had already failed to find")
        #expect(runtime.frame.actionBlock == .unroutable)
    }

    /// **The host's two names, end to end.** The hook reports the
    /// address out of the session's own environment and cmux puts a UUID there;
    /// `inventory()` answers in short refs. The gate above used to join those
    /// with `==`, so it matched nothing, ever — every send this program has made
    /// was refused as unroutable and the panel blamed a route that was fine.
    ///
    /// A regression here is silent by nature: the deck keeps working, the panel
    /// keeps saying a true-sounding sentence, and nothing is sent. So this asks
    /// for the whole sequence rather than for the absence of a block.
    @Test("a lane addressed the way the hook reports it is sent to")
    func theHookAddressResolvesToTheHostsOwn() async {
        let runtime = DeckRuntime()
        // What `CMUX_SURFACE_ID` and `CMUX_WORKSPACE_ID` actually hold (LV32).
        let reported = HostAddress(workspace: "53CC87D4-D5CD-449C-826C-4D496C368C2A",
                                   surface: "7BB88BAA-6151-4BED-950D-81A33DFA27C6")!
        // What `cmux tree` prints for the same surface, and the only name the
        // deck should put on the wire.
        let canonical = HostAddress(workspace: "workspace:19", surface: "surface:27")!
        let host = RecordingHost(inventory: .success([
            HostSession(address: HostAddress(workspace: "workspace:1", surface: "surface:2")!,
                        title: "somebody else", isSelected: false,
                        workspaceNames: ["B393B27C-B157-4D88-B10D-881B6BEFD637"],
                        surfaceNames: ["218A54E9-5DDD-4FE0-BF36-D044B0A50B93"]),
            HostSession(address: canonical, title: "the target", isSelected: false,
                        workspaceNames: [reported.workspace],
                        surfaceNames: [reported.surface]),
        ]))

        runtime.markStartedForTesting()
        runtime.host = host
        _ = await runtime.handle(hook(.sessionStart, "start", host: reported))
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])
        await settle()

        #expect(runtime.frame.actionBlock == nil,
                Comment(rawValue: "blocked as \(String(describing: runtime.frame.actionBlock)) "
                        + "with a perfectly good address"))
        let calls = await host.record()
        #expect(calls.map(\.kind) == ["inventory", "inventory", "read", "send", "key"],
                Comment(rawValue: "the sequence was \(calls.map(\.kind))"))
        // **Canonical, not as-reported.** cmux happens to accept both forms, so
        // sending the UUID would have worked and left the deck speaking two
        // naming systems depending on which mouth an address came from.
        #expect(calls.filter { $0.kind != "inventory" }.allSatisfy { $0.address == canonical },
                Comment(rawValue: "the deck routed to "
                        + "\(String(describing: calls.last?.address)) rather than the host's own name"))
        #expect(runtime.frame.queued.map(\.status) == [.sent])
    }

    /// And it is still specific. A resolver that fell back to "any
    /// session will do" would type a person's words into somebody else's
    /// terminal, which is the one failure worse than not sending at all.
    @Test("an address no listed surface answers to is still unroutable")
    func resolutionIsNotAFallback() async {
        let runtime = DeckRuntime()
        let reported = HostAddress(workspace: "53CC87D4-D5CD-449C-826C-4D496C368C2A",
                                   surface: "7BB88BAA-6151-4BED-950D-81A33DFA27C6")!
        let host = RecordingHost(inventory: .success([
            HostSession(address: HostAddress(workspace: "workspace:1", surface: "surface:2")!,
                        title: "somebody else", isSelected: false,
                        workspaceNames: ["B393B27C-B157-4D88-B10D-881B6BEFD637"],
                        surfaceNames: ["218A54E9-5DDD-4FE0-BF36-D044B0A50B93"]),
        ]))

        runtime.markStartedForTesting()
        runtime.host = host
        _ = await runtime.handle(hook(.sessionStart, "start", host: reported))
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])
        await settle()

        let kinds = await host.kinds()
        #expect(!kinds.contains("send"), "the deck sent to a surface that answered to no name it had")
        #expect(!kinds.contains("key"))
        #expect(runtime.frame.actionBlock == .unroutable)
    }

    /// : no socket, no sends, and the deck says why. Measured
    /// behaviour, not hypothetical — cmux's default mode refuses a process it did
    /// not spawn, which a deck launched from Finder is.
    @Test("a refusing host darkens every control with a reason")
    func socketGate() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: .failure(.unavailable(
            "cmux is not accepting connections from the deck")))
        await armed(runtime, host: host)
        runtime.select(session)
        await settle()

        // The probe runs on SELECTION, so the panel opens telling the truth
        // rather than offering controls and finding out afterwards.
        #expect(runtime.frame.actionBlock == .hostUnavailable,
                "the panel opened with live controls over a refusing socket")

        runtime.queue(QuickAction.shipped[0])
        await settle()
        let kinds = await host.kinds()
        #expect(!kinds.contains("send"))
        #expect(runtime.frame.queued.map(\.status) == [.queued],
                "an action that never reached the wire was marked sent")
    }

    /// The interrupt is a KEY, it does not read the composer, and it
    /// does not wait for the session to be idle. Reading first would refuse it in
    /// exactly the state it is wanted; waiting for idle would make it useless.
    @Test("escape interrupts a running turn without reading the composer")
    func escape() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: inventoryHolding([address]))
        await armed(runtime, host: host)
        // Mid-turn: a prompt with no Stop after it.
        _ = await runtime.handle(hook(.userPromptSubmit, "u1", host: address, prompt: "long work"))
        runtime.select(session)
        runtime.queue(QuickAction.shipped[2])          // Escape
        await settle()

        let calls = await host.record()
        #expect(!calls.contains { $0.kind == "read" },
                "the interrupt read the composer first, which is how it gets refused when it is needed")
        #expect(!calls.contains { $0.kind == "send" }, "an interrupt was typed as text")
        guard let key = calls.first(where: { $0.kind == "key" }) else {
            Issue.record("the interrupt never reached the wire"); return
        }
        #expect(key.argument == "escape")
        #expect(key.address == address)
        // Unconfirmable — an interrupted turn emits no Stop — so it retires on
        // the send and the panel says nothing further about it.
        #expect(runtime.frame.queued.isEmpty,
                "an interrupt waited for a receipt that can never come")
    }

    /// A dialog key is a KEY too, and for a sharper reason than escape's own:
    /// what `host.read` would see is not a draft somebody typed, it IS the
    /// dialog this key answers. `Composer.read` measures "❯ 1. Yes" as
    /// `holdingText` — the same reading a real draft produces
    /// (`Composer.swift`'s glyph-and-trailing-text predicate) — so a
    /// composer gate ahead of this send would refuse it for showing exactly
    /// what it is supposed to. Mid-turn on purpose: a session parked on a
    /// dialog is not-idle by `isIdle`'s own definition (no `Stop` newer than
    /// the last prompt), which is the state a dialog key exists to answer.
    ///
    /// **Corroborated by a fleet poll, not just queued.** `DeckState
    /// .hasOpenDialog` — the drain-time guard a review added — refuses to
    /// offer a `.dialogKey` unless the lane reads `.needsYou` AND
    /// `waitingFor` still carries a value, so this fixture has to actually
    /// open the dialog the same way the fleet would, or the key the deck is
    /// meant to send is exactly the stale chip that guard exists to catch.
    @Test("a dialog key answers a parked session without reading the composer")
    func dialogKey() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: inventoryHolding([address]))
        await armed(runtime, host: host)
        // Dialog-parked: a prompt with no Stop after it — the same wire
        // shape as a running turn, and the deck need not (and cannot) tell
        // them apart to answer a key.
        _ = await runtime.handle(hook(.userPromptSubmit, "u1", host: address, prompt: "risky command"))
        // The fleet corroborating the dialog — no `pid`/`cwd`, so `locate`
        // and the branch resolver have nothing to chase; only `waitingFor`
        // and `state` matter here.
        runtime.fleet = ScriptedFleet([[FleetRow(session: session, name: "s-drain", kind: "interactive",
                                                 state: .absent, status: .value("waiting"),
                                                 waitingFor: "permission prompt")]])
        await runtime.pollFleet()
        runtime.select(session)
        let answer = QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1"))
        runtime.queue(answer)
        await settle()

        let calls = await host.record()
        #expect(!calls.contains { $0.kind == "read" },
                "the dialog key read the composer first, which is how it gets refused when it is needed")
        #expect(!calls.contains { $0.kind == "key" },
                "the deck used sendKey for a digit, which cmux rejects as invalid_params")
        guard let send = calls.first(where: { $0.kind == "send" }) else {
            Issue.record("the dialog key never reached the wire"); return
        }
        #expect(send.argument == "1", "the deck sent \(send.argument.debugDescription) instead of the digit")
        #expect(send.address == address)
        // Unconfirmable, like escape — no receipt a raw key could ever match
        // — so it retires on the send rather than waiting forever.
        #expect(runtime.frame.queued.isEmpty,
                "a dialog key waited for a receipt that can never come")
    }

    /// A prompt queued mid-turn waits, and goes when the turn ends. The
    /// idle gate is about HONESTY (LV21: text sent mid-turn is deferred until
    /// Stop, not lost), so the deck holds it until it can report what happened.
    ///
    /// The clock is SUPPLIED here. The idle gate compares two event stamps, and a
    /// tie means busy (deliberately — see `isIdle`), so against a real clock this
    /// test races the millisecond: prompt and stop inside one tick leave the queue
    /// legitimately unsent and the test fails for a reason that is not the rule.
    @Test("a prompt queued mid-turn is sent when the turn ends")
    func drainsOnStop() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: inventoryHolding([address]))
        runtime.testClockMS = 0
        await armed(runtime, host: host)
        runtime.testClockMS = 1_000
        _ = await runtime.handle(hook(.userPromptSubmit, "u1", host: address, prompt: "work"))
        runtime.select(session)
        runtime.queue(QuickAction.shipped[0])
        await settle()

        #expect(!(await host.kinds()).contains("send"),
                "the deck typed into a running turn")
        #expect(runtime.frame.queued.map(\.status) == [.queued])

        runtime.testClockMS = 2_000
        _ = await runtime.handle(hook(.stop, "stop1", host: address))
        await settle()
        #expect((await host.kinds()).contains("send"),
                "the turn ended and the queue never drained")
        #expect(runtime.frame.queued.map(\.status) == [.sent])
    }

    /// Stacking, which is what the directive asked for: a compact then a
    /// continue. `/compact` is unconfirmable (it fires no UserPromptSubmit on
    /// either mechanism), so it retires on the send and the next action follows.
    @Test("a stack of two drains in the order it was queued")
    func stacking() async {
        let runtime = DeckRuntime()
        let host = RecordingHost(inventory: inventoryHolding([address]))
        await armed(runtime, host: host)
        runtime.select(session)
        runtime.queue(QuickAction.shipped[1])          // Compact
        runtime.queue(QuickAction.shipped[0])          // Continue
        await settle()

        let sent = (await host.record()).filter { $0.kind == "send" }.map(\.argument)
        #expect(sent == ["/compact", "Continue"],
                Comment(rawValue: "the wire saw \(sent) — the stack drained out of order or not at all"))
    }

    /// Let the runtime's detached work finish. **Yields only — no clock.**
    ///
    /// The drain is a `Task` because a send is I/O and a tap must not block
    /// on it, so these tests do have to wait for it. A `Task.sleep` here
    /// would be the wrong instrument — no real elapsed time belongs in the
    /// test target — and a sleep is both slower and flakier than the thing it
    /// would stand in for. The
    /// drain runs on the main actor, so every suspension it takes is a
    /// scheduling step this loop hands back to it, and the yields are free.
    private func settle() async {
        for _ in 0 ..< 500 { await Task.yield() }
    }
}
