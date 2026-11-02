//
//  ForwardPlanRuntimeTests.swift · Tests/DeckAppTests
//
//  V2 forwarding's own runtime half — `DeckRuntime.forward`/`runForwardPlan`,
//  driven against a `RecordingHost` (`PanelDrainTests`'s own fake) rather than
//  a real terminal, the identical discipline that file states for itself.
//  `DeckState`'s own `QuestionMirrorTests` already proves the send-plan STATE
//  MACHINE is correct in isolation; this is the proof the RUNTIME actually
//  calls `CmuxHost.send`/`sendKey` in the right order, to the right address,
//  and stops calling them the instant a plan is cancelled.
//
//  Mirrors are driven to `.terminalLive` through `runtime.apply(_:)` directly
//  — `internal`, not `private`, for exactly this reason (its own doc comment
//  states it) — rather than through `handle(_:)` and a REAL question-budget
//  timer: `openHold`'s own expiry `Task.sleep` is decoupled from
//  `testClockMS` and would cost several real seconds per test for no
//  proportional gain, the same trade `handle`'s own visibility already made
//  for the identical reason.
//

import Testing
import Foundation
import DeckCore
import DeckPorts
@testable import DeckApp

@MainActor
struct ForwardPlanRuntimeTests {

    private let address = HostAddress(workspace: "workspace:30", surface: "surface:38")!
    private let session = SessionID("s-forward")

    private func inventoryHolding(_ addresses: [HostAddress]) -> Result<[HostSession], PortFailure> {
        .success(addresses.map { HostSession(address: $0, title: "probe", isSelected: false) })
    }

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// A started session, its mirror driven all the way to `.terminalLive`
    /// — `openQuestionMirror`'s own sequence (`QuestionMirrorTests`,
    /// `DeckCoreTests`) replayed through `runtime.apply(_:)` directly.
    private func terminalLiveRuntime(host: RecordingHost, question: Question,
                                     use: String = "t1") async -> DeckRuntime {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.host = host
        _ = await runtime.handle(HookEvent(id: EventID("start"), at: .start, kind: .sessionStart,
                                           session: session, cwd: Redacted("/work"), tool: nil,
                                           toolUseID: nil, held: .absent, host: address))
        let hold = HoldID(session: session, toolUseID: use)
        runtime.apply(.hook(HookEvent(id: EventID("pre"), at: at(0), kind: .preToolUse,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: use,
                                     held: .value(1), questions: [question])))
        runtime.apply(.holdExpired(hold, at: at(8_000)))
        runtime.apply(.hook(HookEvent(id: EventID("pr"), at: at(20_000), kind: .permissionRequest,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: nil, held: .absent)))
        runtime.apply(.hook(HookEvent(id: EventID("nt"), at: at(26_000), kind: .notification,
                                     session: session, cwd: nil, tool: nil, toolUseID: nil,
                                     held: .absent, notificationType: "permission_prompt")))
        return runtime
    }

    private func settle() async {
        for _ in 0 ..< 500 { await Task.yield() }
    }

    /// **The happy path — single-select, one call, no pacing delay to
    /// wait out at all** (a one-step plan's own loop returns before ever
    /// reaching `Task.sleep` — `runForwardPlan`'s own doc comment states
    /// why).
    @Test("a single-select tap sends exactly one digit, to the right surface")
    func singleSelectSendsOneDigit() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: false)
        let runtime = await terminalLiveRuntime(host: host, question: question)
        let hold = HoldID(session: session, toolUseID: "t1")

        let mirror = runtime.frame.mirrors.first { $0.hold == hold }
        #expect(mirror != nil, "the mirror never reached terminalLive — nothing to forward against")
        guard let mirror else { return }

        runtime.forward(mirror, picking: [Redacted("B")])
        await runtime.pendingForwardTask[hold]?.value
        await settle()

        let calls = await host.record()
        #expect(calls.filter { $0.kind == "send" }.map(\.argument) == ["2"],
                Comment(rawValue: "got \(calls.map { ($0.kind, $0.argument) })"))
        #expect(calls.first { $0.kind == "send" }?.address == address)
        #expect(runtime.frame.mirrors.first { $0.hold == hold }?.forwarding != true, "a completed plan is still occupying state")
    }

    /// **The full multi-select sequence, in order, to completion.** The
    /// one test in this file that genuinely waits out real pacing delays
    /// (three `180ms` gaps between the four steps) — accepted rather than
    /// avoided, because this is the only way to prove the SEQUENCE, not
    /// just the shape, actually reaches the host in order.
    @Test("a multi-select tap runs the full toggle-down-enter-review sequence, in order")
    func multiSelectRunsTheFullSequence() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: true)
        let runtime = await terminalLiveRuntime(host: host, question: question)
        let hold = HoldID(session: session, toolUseID: "t1")
        guard let mirror = runtime.frame.mirrors.first(where: { $0.hold == hold }) else {
            Issue.record("mirror never reached terminalLive"); return
        }

        runtime.forward(mirror, picking: [Redacted("A"), Redacted("B")])
        await runtime.pendingForwardTask[hold]?.value
        await settle()

        let calls = await host.record()
        let shape = calls.filter { $0.kind == "send" || $0.kind == "key" }
            .map { ($0.kind, $0.argument) }
        // 2 options, both picked: last index 1, downs = (2+1)-1 = 2 — the
        // SAME arithmetic `QuestionMirrorTests
        // .multiSelectTogglesInAscendingOrderRegardlessOfCallerOrder`
        // (DeckCoreTests) pins for the identical shape.
        let expected: [(String, String)] = [("send", "1"), ("send", "2"),
                                            ("key", "down"), ("key", "down"),
                                            ("key", "enter"), ("send", "1")]
        #expect(shape.elementsEqual(expected, by: ==),
                Comment(rawValue: "got \(shape)"))
        #expect(runtime.frame.mirrors.first { $0.hold == hold }?.forwarding != true)
    }

    /// **The cancellation, at the runtime level — the `cullStaleDialogKeys`
    /// class, proven against actual host calls rather than reducer state
    /// alone.** A `PostToolUse` lands after the FIRST step of a longer
    /// plan; the remaining steps must never reach the host at all.
    @Test("PostToolUse mid-plan stops the remaining steps from ever reaching the host")
    func postToolUseMidPlanStopsTheRemainingSends() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("C"), detail: Redacted(""))],
                                multiSelect: true)
        let runtime = await terminalLiveRuntime(host: host, question: question)
        let hold = HoldID(session: session, toolUseID: "t1")
        guard let mirror = runtime.frame.mirrors.first(where: { $0.hold == hold }) else {
            Issue.record("mirror never reached terminalLive"); return
        }

        // Picking "A" alone against 3 options is a long plan (1 toggle + 3
        // downs + enter + review-digit) — long enough that a PostToolUse
        // fired right after this call is reliably still mid-sequence when
        // it lands.
        runtime.forward(mirror, picking: [Redacted("A")])

        runtime.apply(.hook(HookEvent(id: EventID("post"), at: at(30_000), kind: .postToolUse,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: "t1",
                                     held: .absent, questions: [question],
                                     answers: [Answer(question: Redacted("Pick"), labels: [Redacted("A")])])))

        await runtime.pendingForwardTask[hold]?.value
        await settle()

        let calls = await host.record()
        let sends = calls.filter { $0.kind == "send" || $0.kind == "key" }
        #expect(sends.count <= 1,
                Comment(rawValue: "PostToolUse landed mid-plan but the host still saw \(sends.map(\.argument))"))
        #expect(runtime.frame.mirrors.first { $0.hold == hold }?.forwarding != true, "the plan is still marked running after PostToolUse")
    }

    /// **Visible cancellation — a host that refuses every send reports
    /// `actionBlock`, and stops after the failing call rather than
    /// retrying it.**
    @Test("a host failure mid-plan blocks visibly and stops sending")
    func hostFailureBlocksVisiblyAndStops() async {
        let host = RecordingHost(inventory: inventoryHolding([address]), send: .failed("refused"))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: false)
        let runtime = await terminalLiveRuntime(host: host, question: question)
        let hold = HoldID(session: session, toolUseID: "t1")
        guard let mirror = runtime.frame.mirrors.first(where: { $0.hold == hold }) else {
            Issue.record("mirror never reached terminalLive"); return
        }
        // `Frame.actionBlock` is suppressed for an unselected session
        // (`Projection.frame`: `selection == nil ? nil : block`) — the
        // panel's own "an enabled cell while the socket refuses" guard,
        // one door over. `.actionBlocked` is still applied to `state
        // .blocked[hold.session]` regardless; this is what makes it
        // VISIBLE, the same step `PanelDrainTests`' own tests take.
        runtime.select(session)

        runtime.forward(mirror, picking: [Redacted("A")])
        await runtime.pendingForwardTask[hold]?.value
        await settle()

        #expect(runtime.frame.actionBlock != nil, "a failed send left no visible reason")
        #expect(runtime.frame.mirrors.first { $0.hold == hold }?.forwarding != true, "a failed plan is still marked running")
    }
}
