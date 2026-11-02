//
//  ReadinessGateRuntimeTests.swift · Tests/DeckAppTests
//
//  The readiness gate's runtime half — `DeckRuntime.scheduleReadinessWatch()`,
//  `attemptScreenObservation`, and `scheduleForwardLandingWatch`, driven
//  against a `RecordingHost` (`PanelDrainTests`'s own fake) the same way
//  `ForwardPlanRuntimeTests` already drives the forwarding half. `DeckState`'s
//  own `QuestionMirrorTests` (DeckCoreTests) already proves the PROMOTION
//  events are correct in isolation; this is the proof the RUNTIME actually
//  schedules and fires them.
//
//  Every scheduled wait here runs against a SHORTENED `HoldPolicy` — the
//  test seams (`pendingReadinessTask`, `pendingScreenObservationTask`,
//  `pendingForwardLandingTask`) are `await`ed directly, `pendingForwardTask`'s
//  own doctrine, so nothing here guesses how long a real sleep needs; the
//  sleep itself stays real and short (milliseconds), never a virtual clock
//  jump and never several real seconds either.
//

import Testing
import Foundation
import DeckCore
import DeckPorts
import DeckAdapters
@testable import DeckApp

@MainActor
struct ReadinessGateRuntimeTests {

    private let address = HostAddress(workspace: "workspace:44", surface: "surface:9")!
    private let session = SessionID("s-readiness")

    private func inventoryHolding(_ addresses: [HostAddress]) -> Result<[HostSession], PortFailure> {
        .success(addresses.map { HostSession(address: $0, title: "probe", isSelected: false) })
    }

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// A shortened policy — every readiness-gate allowance collapsed to a
    /// few milliseconds, so awaiting the real scheduled `Task` costs
    /// nothing a test suite would notice. `HoldPolicy.spec`'s own values
    /// are what production actually runs; this file exists to prove the
    /// WIRING fires, not to re-measure the numbers `QuestionMirrorTests`
    /// (DeckCoreTests) and `HoldPolicy`'s own doc comments already derive.
    private func shortPolicy() -> HoldPolicy {
        var policy = HoldPolicy.spec
        policy.noSignalAllowance = Millis(30)
        policy.permissionRequestAllowance = Millis(30)
        policy.forwardLandingAllowance = Millis(30)
        policy.screenObservationRetryDelay = Millis(20)
        policy.resolvedMirrorLinger = Millis(40)
        return policy
    }

    /// Poll-with-deadline — `PermissionWireTests.waitForHold`'s own
    /// doctrine, applied to the OPPOSITE condition: waiting for a hold
    /// to LEAVE the frame rather than arrive in it. Two assertions, two
    /// instruments: this poll targets the FRAME condition (the card is
    /// gone from the glass), while `scheduledMirrorLingerDeadline` —
    /// `internal`, the `pendingReadinessTask` seam precedent — targets
    /// the FIELD condition afterwards (the sweep settled and never
    /// re-arms), because the CPU-spin defect that seam pins is invisible
    /// to any frame-only assertion: the visible behavior was already
    /// correct while the runtime spun.
    ///
    /// **15s, not `waitForHold`'s 5 — this wait's condition is uniquely
    /// backlog-bound.** Every `@MainActor` test body in the whole run
    /// shares the one main actor with `RenderSweepTests`' synchronous
    /// `NSHostingView` layouts, and the mirror leaves the frame only
    /// when the linger sleeper's post-sleep continuation gets a main-
    /// actor slot — a slot that sat queued behind seconds of render
    /// jobs when the suite's hosted-render weight grew (armed at `Instant(340)`, wake still queued at the 5s deadline,
    /// twice in a row under full parallel load; instant pass isolated).
    /// 15 outlives any full-suite backlog by construction — the other
    /// tests finish and free the actor well inside it — so the budget
    /// bounds only a GENUINE never-fires regression, which pays it
    /// once, loudly. The uncontended pass is still ~0.4s.
    private func waitForMirrorToAgeOut(_ hold: HoldID, in runtime: DeckRuntime, timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while runtime.frame.mirrors.contains(where: { $0.hold == hold }), Date() < deadline {
            await Task.yield()
        }
    }

    /// The deck-time `releasedRuntime` releases the mirror at — pulled out
    /// so a caller passing `testClockMS:` below can align `now()` to the
    /// SAME instant without a second copy of the literal to keep in sync.
    private static let releaseInstantMS: Int64 = 8_000

    /// A started, routable session with a mirror driven to `.released` —
    /// `ForwardPlanRuntimeTests.terminalLiveRuntime`'s own sequence, cut
    /// off before the ceremony pair, seeded with `policy` FIRST so
    /// `scheduleReadinessWatch()` reads the shortened allowances from the
    /// very first `apply(_:)` this drives.
    ///
    /// **`testClockMS`, optional.** `scheduleReadinessWatch`'s own `waitMs` is
    /// `deadline - now()`, and `deadline` is built from THIS event's own
    /// `Instant` (`releaseInstantMS`, a number picked for readability, not
    /// for any relationship to real time) while `now()` — absent a test
    /// clock — reads REAL wall-clock elapsed since the runtime was just
    /// constructed a few lines up, a handful of milliseconds at most. So
    /// the sleeper this function arms is really waiting out
    /// `releaseInstantMS + allowance`, not `allowance` — confirmed by
    /// instrumenting `scheduleReadinessWatch` directly: `deadline=8090
    /// now=4 waitMs=8086` for what a caller's own `policy` named an 80ms
    /// allowance. Every caller that never awaits `pendingReadinessTask` to
    /// completion never notices (the ceremony pair or a screen read
    /// resolves the mirror through a different door first, and this
    /// sleeper is left to expire, harmlessly, into a mirror that already
    /// left `.released`). A caller that DOES await it out pays the whole
    /// multi-second gap for nothing — pass `releaseInstantMS` here to
    /// collapse it back to the allowance actually named, deterministically
    /// rather than by racing however small "a handful of milliseconds"
    /// happens to be on a given run.
    private func releasedRuntime(host: RecordingHost, question: Question,
                                 policy: HoldPolicy, use: String = "t1",
                                 testClockMS: Int64? = nil) async -> DeckRuntime {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.host = host
        var seeded = DeckState()
        seeded.policy = policy
        runtime.replaceStateForTesting(seeded)
        _ = await runtime.handle(HookEvent(id: EventID("start"), at: .start, kind: .sessionStart,
                                           session: session, cwd: Redacted("/work"), tool: nil,
                                           toolUseID: nil, held: .absent, host: address))
        let hold = HoldID(session: session, toolUseID: use)
        runtime.apply(.hook(HookEvent(id: EventID("pre"), at: at(0), kind: .preToolUse,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: use,
                                     held: .value(1), questions: [question])))
        if let testClockMS { runtime.testClockMS = testClockMS }
        runtime.apply(.holdExpired(hold, at: at(Self.releaseInstantMS)))
        return runtime
    }

    private func settle() async {
        for _ in 0 ..< 500 { await Task.yield() }
    }

    // ---------------------------------------------------- design points b/c

    /// **The live incident itself, reproduced against the real scheduling
    /// wiring.** No `PermissionRequest`, no `Notification` — the live
    /// session got neither — and the mirror still reaches `.terminalLive`,
    /// through `HoldPolicy.noSignalAllowance` alone.
    ///
    /// **`testClockMS: Self.releaseInstantMS` — this test's own timing fix,
    /// not a change to what it proves.** Without it,
    /// this awaited `pendingReadinessTask` out to a real 8.3s: `waitMs` is
    /// `deadline - now()`, `deadline` is built from `releaseInstantMS`
    /// (picked for readability, decoupled from real time by construction),
    /// and `now()` reads actual wall-clock elapsed since construction —
    /// a few milliseconds — so `shortPolicy()`'s 30ms allowance was really
    /// being awaited as `releaseInstantMS + 30`. Pinning `now()` to
    /// `releaseInstantMS` for this one release collapses that back to the
    /// 30ms the policy actually names, deterministically — nothing about
    /// the CLAIM changes: no ceremony is fed, still, and the mirror still
    /// has to reach `.terminalLive` through the timer alone.
    @Test("a released mirror with no ceremony at all reaches terminalLive through the runtime's own timer")
    func noCeremonyReachesTerminalLiveThroughTheRuntime() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        let runtime = await releasedRuntime(host: host, question: question, policy: shortPolicy(),
                                            testClockMS: Self.releaseInstantMS)
        let hold = HoldID(session: session, toolUseID: "t1")

        guard case .released? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            Issue.record("the fixture's own premise: the mirror must start released")
            return
        }

        await runtime.pendingReadinessTask[hold]?.value
        await settle()

        guard case .terminalLive? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            Issue.record("the no-signal allowance elapsed and the mirror is still released")
            return
        }
    }

    // -------------------------------------------------------- design point d

    /// **The strongest signal, proven against the real port call.** The
    /// host's own screen already shows the question's text — `RecordingHost
    /// .screen` stands in for `cmux read-screen` — so the mirror reaches
    /// `.terminalLive` through `attemptScreenObservation` alone, well
    /// inside `HoldPolicy.spec`'s own ordinary (un-shortened) allowances.
    @Test("a screen already showing the question promotes the mirror without waiting on either timer")
    func screenObservationPromotesWithoutWaitingOnATimer() async {
        let question = Question(text: Redacted("Which config?"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        let host = RecordingHost(inventory: inventoryHolding([address]),
                                 screen: .success("? Which config?\n  1. A\n"))
        // The ordinary, un-shortened policy — this promotion has to beat
        // NEITHER timer to prove the point; if it only worked with both
        // shortened it would not be distinguishing the signal from them.
        let runtime = await releasedRuntime(host: host, question: question, policy: .spec)
        let hold = HoldID(session: session, toolUseID: "t1")

        await runtime.pendingScreenObservationTask[hold]?.value
        await settle()

        guard case .terminalLive? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            Issue.record("a screen already showing the question did not promote the mirror")
            return
        }
        let reads = await host.record().filter { $0.kind == "read" }
        #expect(!reads.isEmpty, "the mirror promoted some other way — the read itself never happened")
    }

    /// A screen that never shows the question exhausts its one retry and
    /// gives up silently — the fallback timers in `scheduleReadinessWatch`
    /// are what a mirror in this shape actually depends on, proven
    /// separately just above.
    @Test("a screen that never shows the question leaves the mirror released, silently")
    func screenNeverShowingTheQuestionLeavesTheMirrorReleased() async {
        let question = Question(text: Redacted("Which config?"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        let host = RecordingHost(inventory: inventoryHolding([address]),
                                 screen: .success("❯\u{00A0}\n"))
        var policy = HoldPolicy.spec
        // Long enough that neither bounded timer could fire before this
        // test's own await returns — isolates the screen-read's own
        // silent-failure behaviour from the fallback timers. The retry
        // gap itself stays short: this test's OWN subject is "gives up
        // after one retry", not the pacing between attempts.
        policy.noSignalAllowance = Millis(3_600_000)
        policy.permissionRequestAllowance = Millis(3_600_000)
        policy.screenObservationRetryDelay = Millis(20)
        let runtime = await releasedRuntime(host: host, question: question, policy: policy)
        let hold = HoldID(session: session, toolUseID: "t1")

        await runtime.pendingScreenObservationTask[hold]?.value
        await settle()

        guard case .released? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            Issue.record("a screen that never showed the question promoted the mirror anyway")
            return
        }
    }

    // ------------------------------------------------ the forward-recovery fix

    /// A ceremony-completed mirror — `ForwardPlanRuntimeTests
    /// .terminalLiveRuntime`'s own sequence, replayed here rather than
    /// imported, so this file's `policy:` seed (`releasedRuntime`'s own
    /// parameter) is what the ceremony's two hook events apply against.
    private func terminalLiveRuntime(host: RecordingHost, question: Question,
                                     policy: HoldPolicy, use: String = "t1") async -> DeckRuntime {
        let runtime = await releasedRuntime(host: host, question: question, policy: policy, use: use)
        runtime.apply(.hook(HookEvent(id: EventID("pr"), at: at(20_000), kind: .permissionRequest,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: nil, held: .absent)))
        runtime.apply(.hook(HookEvent(id: EventID("nt"), at: at(26_000), kind: .notification,
                                     session: session, cwd: nil, tool: nil, toolUseID: nil,
                                     held: .absent, notificationType: "permission_prompt")))
        return runtime
    }

    /// **What makes the two promotions above safe to be aggressive
    /// about, proven against the real scheduling.** Every step reports
    /// `.sent`, nothing resolves the mirror afterward, and the surface
    /// says so instead of sitting quietly as if the tap were never made.
    @Test("a forward plan that never lands marks the mirror, through the runtime's own watchdog")
    func forwardPlanThatNeverLandsMarksTheMirror() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: false)
        let runtime = await terminalLiveRuntime(host: host, question: question, policy: shortPolicy())
        let hold = HoldID(session: session, toolUseID: "t1")
        guard let mirror = runtime.frame.mirrors.first(where: { $0.hold == hold }) else {
            Issue.record("mirror never reached terminalLive"); return
        }

        runtime.forward(mirror, picking: [Redacted("B")])
        await runtime.pendingForwardTask[hold]?.value
        await runtime.pendingForwardLandingTask[hold]?.value
        await settle()

        #expect(runtime.frame.mirrors.first { $0.hold == hold }?.forwardUnconfirmed == true,
                "every step sent, no PostToolUse ever followed, and the mirror does not say so")
    }

    /// The watchdog and a genuine, on-time `PostToolUse` race the same
    /// clock; a `PostToolUse` that wins must not leave a stale "didn't
    /// land" notice behind it.
    @Test("a forward plan that lands on time never gets marked, even once the watchdog itself fires")
    func forwardPlanThatLandsOnTimeIsNeverMarked() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: false)
        let runtime = await terminalLiveRuntime(host: host, question: question, policy: shortPolicy())
        let hold = HoldID(session: session, toolUseID: "t1")
        guard let mirror = runtime.frame.mirrors.first(where: { $0.hold == hold }) else {
            Issue.record("mirror never reached terminalLive"); return
        }

        runtime.forward(mirror, picking: [Redacted("B")])
        await runtime.pendingForwardTask[hold]?.value

        runtime.apply(.hook(HookEvent(id: EventID("post"), at: at(27_000), kind: .postToolUse,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: "t1",
                                     held: .absent, questions: [question],
                                     answers: [Answer(question: Redacted("Pick"), labels: [Redacted("B")])])))

        await runtime.pendingForwardLandingTask[hold]?.value
        await settle()

        guard case .resolved? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            Issue.record("the fixture's own premise: the mirror must resolve on time")
            return
        }
        #expect(runtime.frame.mirrors.first { $0.hold == hold }?.forwardUnconfirmed == false,
                "an on-time PostToolUse still left a stale \"no confirmation\" notice")
    }

    // ---------------------------------------- D1: the second incident's own reds

    /// **The red this section answers — reproduces the 78ms bug's own
    /// shape.** Release arms a LONG sleeper (`noSignalAllowance`); a
    /// `PermissionRequest` shortly after arms a much SHORTER one
    /// (`permissionRequestAllowance`) and cancels the first. Before THE
    /// LAW, the cancelled sleeper's own swallowed `CancellationError`
    /// fell through its `.released` guard (still true — promotion is
    /// what was never supposed to happen yet) and fired
    /// `.mirrorReadinessElapsed` INSTANTLY rather than never — a
    /// live incident, timed to the millisecond: release 2414298ms,
    /// `PermissionRequest` ~2414370ms, a wrong promotion at 2414376ms,
    /// 78ms after release and roughly 15s before either real allowance.
    ///
    /// **Why the negative half below no longer races an 80ms window.**
    /// `releasedRuntime`'s own doc comment names the mechanism:
    /// `scheduleReadinessWatch`'s `waitMs` is `deadline - now()`, built
    /// from an event `Instant` decoupled from real time on one side and
    /// actual wall-clock elapsed on the other. Instrumented directly to
    /// check what this test's own re-arm actually scheduled: `deadline=8090
    /// now=4 waitMs=8086` — not the 80ms the policy named, an 8.09s real
    /// sleep, and the test's own measured wall time (8.587s) matched
    /// exactly. That is a WIDER margin than the "80ms" this comment used
    /// to assume, not a narrower one — and it still measured 2 reds in 41
    /// runs once the suite carried ~20% more `MainActor` work. This file's
    /// own `waitForMirrorToAgeOut` already documents full-suite backlog on
    /// this SAME actor reaching several real seconds ("wake still queued
    /// at the 5s deadline, twice in a row under full parallel load"; a
    /// sibling fixed-allowance test needed a 15s timeout for exactly that
    /// reason) — 8.09s sits inside that range, not safely above it.
    ///
    /// The fix keeps the real `Task` and the real cancellation this test
    /// exists to exercise, and removes the race by widening the margin
    /// rather than by timing anything more tightly. **Step 1** arms, then
    /// re-arms, with allowances measured in MINUTES — no plausible
    /// `Task.yield()` backlog this suite has ever produced reaches that,
    /// so "not yet promoted" is a structural fact rather than a race,
    /// while the re-arm itself still exercises THE LAW exactly as before
    /// (the two allowances are deliberately UNEQUAL, so the deadline
    /// genuinely changes and the cancellation genuinely happens — an
    /// accidental no-op here would prove nothing). **Step 2** re-arms a
    /// SECOND time — cancelling step 1's own sleeper through the identical
    /// path, so THE LAW is exercised twice, not once — this time with
    /// `testClockMS` standing in for `now()` (the same seam
    /// `releasedRuntime` now offers, and `PermissionWireTests`/
    /// `HoldBudgetRuntimeTests` already use elsewhere for arm-delay gates)
    /// so the recomputed `waitMs` comes out to exactly 80ms rather than
    /// however many real minutes happen to separate this test's synthetic
    /// timestamps from actual wall time. Nothing races that 80ms: the
    /// negative assertion is already banked by the time it is armed, and
    /// `pendingReadinessTask` is awaited to completion directly, not
    /// against a deadline of its own.
    @Test("a readiness deadline that shortens after arming does not fire before the NEW deadline")
    func shortenedReadinessDeadlineDoesNotFireEarly() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        // Minutes, not milliseconds — see the doc comment above. Unequal
        // on purpose: the phase-1 re-arm below must be a genuine deadline
        // CHANGE (`readinessDeadline[id] != deadline`), not a same-value
        // no-op that would skip the cancellation path this test exists to
        // prove safe.
        var policy = HoldPolicy.spec
        policy.noSignalAllowance = Millis(3_600_000)
        policy.permissionRequestAllowance = Millis(1_800_000)
        let runtime = await releasedRuntime(host: host, question: question, policy: policy)
        let hold = HoldID(session: session, toolUseID: "t1")
        guard case .released? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            Issue.record("the fixture's own premise: the mirror must start released")
            return
        }

        // STEP 1 — the re-arm that reproduces the live incident's own
        // shape: cancels the 3,600,000ms sleeper armed at release, arms a
        // 1,800,000ms one in its place. Both minutes long, so nothing this
        // test's own yield loop could plausibly do reaches either one.
        runtime.apply(.hook(HookEvent(id: EventID("pr"), at: at(Self.releaseInstantMS + 10),
                                     kind: .permissionRequest,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: nil, held: .absent)))

        // Deterministic yields, no sleep — every chance for a swallowed
        // cancellation to misfire, and this time genuinely none for the
        // real (minutes-long) deadline to have elapsed regardless of how
        // long the yields themselves take.
        await settle()
        guard case .released? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            let reason = "the mirror promoted before the shortened deadline — the cancelled sleeper's "
                + "own swallowed cancellation fired early, the 78ms bug"
            Issue.record(Comment(rawValue: reason))
            return
        }

        // STEP 2 — shorten the deadline for real, and prove the runtime's
        // own timer still fires once it does, without waiting out the
        // minutes step 1 deliberately armed. A second `PermissionRequest`
        // re-arms again — cancelling step 1's own sleeper through the
        // exact same path — with `testClockMS` standing in for `now()` so
        // `waitMs` comes out to exactly 80ms: `deadline` is
        // `secondSeenAt + permissionRequestAllowance`, and pinning `now()`
        // to `deadline - 80` leaves precisely that much of the real
        // allowance still to run.
        let secondSeenAt = at(Self.releaseInstantMS + 20)
        let shortWaitMs: Int64 = 80
        let deadline = secondSeenAt.sinceStart.raw + policy.permissionRequestAllowance.raw
        runtime.testClockMS = deadline - shortWaitMs
        runtime.apply(.hook(HookEvent(id: EventID("pr2"), at: secondSeenAt, kind: .permissionRequest,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: nil, held: .absent)))

        await runtime.pendingReadinessTask[hold]?.value
        await settle()
        guard case .terminalLive? = runtime.frame.mirrors.first(where: { $0.hold == hold })?.stage else {
            Issue.record("the shortened deadline never fired at all")
            return
        }
    }

    /// **The second half of D1 — the user's taps 2 and 3, 1.2s apart,
    /// both producing a `forwardDidNotLand` line.** Two plan-completion
    /// cycles for the SAME hold must leave at most ONE landing watch
    /// alive; before `scheduleForwardLandingWatch` cancelled the
    /// superseded task, a plain dictionary overwrite left the FIRST
    /// watch running unreferenced, and it fired too.
    ///
    /// **Deterministic since the 1015-test retune — the allowance is an
    /// HOUR now, not a 400ms head start this test's own body had to win
    /// under load.** The earlier draft armed real 400ms deadlines and
    /// raced them: tap 2 had to supersede watch 1 before watch 1's own
    /// clock genuinely elapsed — a premise the draft's own comment
    /// already called "an unwinnable race against real scheduling under
    /// load", and at 1015 tests the suite's shared MainActor backlog
    /// (the SAME class `waitForMirrorToAgeOut`'s 15s retune documents)
    /// lost it on EVERY full run: 6.9 observed seconds of delay against
    /// a 400ms allowance, and two verdicts logged by perfectly CORRECT
    /// code, because a watch nobody had superseded yet fired on its own
    /// merits. An allowance no test lifetime can elapse makes the
    /// premise structural rather than raced: watch 1 can never fire on
    /// its own merits, so a verdict can only appear through the exact
    /// defect this test pins. The clock-race assertion became two
    /// direct ones: the superseded task reads CANCELLED (loses the
    /// `cancel()` call — the dictionary-overwrite regression — and this
    /// reads false, deterministically), and awaiting that task to
    /// completion yields ZERO verdicts (a watch body that swallows its
    /// own cancellation — THE LAW, `scheduleReadinessWatch`'s own doc
    /// comment — would fire ON the cancel and read 1 here). Watch 2's
    /// own legitimate deadline firing is deliberately NOT re-proven at
    /// an hour: this file's other tests already await
    /// `pendingForwardLandingTask` handles directly at `shortPolicy()`'s
    /// 30ms allowance, race-free, and prove the verdict fires.
    @Test("a superseded landing watch never fires — the second plan cancels the first watch outright")
    func supersededLandingWatchNeverFires() async {
        let host = RecordingHost(inventory: inventoryHolding([address]))
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted("")),
                                          QuestionOption(label: Redacted("B"), detail: Redacted(""))],
                                multiSelect: false)
        var policy = shortPolicy()
        policy.forwardLandingAllowance = Millis(3_600_000)
        let runtime = await terminalLiveRuntime(host: host, question: question, policy: policy)
        let hold = HoldID(session: session, toolUseID: "t1")
        guard let mirror = runtime.frame.mirrors.first(where: { $0.hold == hold }) else {
            Issue.record("mirror never reached terminalLive"); return
        }

        // Tap 1 — completes immediately, arming the FIRST landing watch.
        runtime.forward(mirror, picking: [Redacted("B")])
        await runtime.pendingForwardTask[hold]?.value
        guard let firstWatch = runtime.pendingForwardLandingTask[hold] else {
            Issue.record("the fixture's own premise: tap 1's completed plan must arm a landing watch")
            return
        }

        // The person's own "Send again" — D5's own door back to
        // tappable — followed by a second tap while the first watch is
        // still counting down (structurally guaranteed now: its own
        // deadline is an hour away). Two completed plans, two calls to
        // `scheduleForwardLandingWatch`, for the SAME hold.
        runtime.rearmForward(mirror)
        runtime.forward(mirror, picking: [Redacted("B")])
        await runtime.pendingForwardTask[hold]?.value

        // A BAIL-OUT, not a plain `#expect` — a mutation
        // probe found the difference: with the `cancel()`
        // call deleted, a recorded-but-not-returned failure runs straight
        // into the `await` below, which then waits on an UN-cancelled
        // hour-long sleeper — CI stalls to its job timeout instead of
        // printing a one-line red. Failing here must also STOP here; only
        // a genuinely-cancelled watch is ever safe to await out.
        guard firstWatch.isCancelled else {
            Issue.record(Comment(rawValue: "arming the second landing watch did not cancel the first — the "
                    + "dictionary-overwrite regression scheduleForwardLandingWatch's own doc names: a "
                    + "plain write stops nothing already in flight, it only stops anything finding it"))
            return
        }

        // Run the superseded watch all the way OUT — a cancelled sleeper
        // returns without a verdict (THE LAW); a body that swallowed its
        // own cancellation would fire right here, right now, not in an
        // hour.
        await firstWatch.value
        await settle()

        // `Diagnostic`s are the observable — `runtime.log`'s own
        // sequence of everything the reducer actually decided — so this
        // counts VERDICTS, not just the final value a second firing
        // could have silently overwritten with an equally plausible one.
        let unconfirmedCount = runtime.log.filter { $0.kind == .forwardUnconfirmed }.count
        #expect(unconfirmedCount == 0,
                Comment(rawValue: "a verdict was logged for a hold whose only completed watch was the "
                        + "cancelled one — \(unconfirmedCount) forwardUnconfirmed lines; neither armed watch's "
                        + "hour-long deadline can have elapsed, so the superseded watch fired"))
    }

    // ------------------------------------------------------------ D2: auto-heal

    private func scratch() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-autoheal-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json").path
    }

    private func configRuntime(at path: String, port: UInt16 = 8765) -> DeckRuntime {
        let r = DeckRuntime()
        r.markStartedForTesting()
        r.configPath = path
        r.config = ConfigFile(path: path)
        r.setStatusForTesting(.listening(port: port))
        return r
    }

    private func read(_ path: String) -> JSONValue {
        guard let data = FileManager.default.contents(atPath: path) else { return .null }
        return JSONValue.parse(data) ?? .null
    }

    /// **D2's own live-defect fix, driven end to end against a real
    /// file.** A fully-connected 8-hook install, with `PostToolUse`
    /// stripped back out afterward — the exact shape of a machine that
    /// consented to this deck BEFORE `PostToolUse` became a managed
    /// event. `refreshConnection()`'s own startup trigger must
    /// register it without being asked again.
    @Test("auto-heal registers a missing PostToolUse hook for an already-consented install")
    func autoHealRegistersAMissingPostToolUseHook() async throws {
        let path = scratch()
        let seed = configRuntime(at: path)
        let connected = await seed.connect(addStatusline: false)
        guard case .success = connected else {
            Issue.record("the seed connect itself failed — nothing downstream of it can be trusted"); return
        }

        // Strip `PostToolUse` back out — `JSONSerialization`, not
        // `JSONValue` (which this codebase never encodes, by design —
        // `QuestionCall`'s own doc comment states the same reasoning for
        // a different type), is what round-trips a real file on disk.
        guard var root = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: path)))
                as? [String: Any],
              var hooks = root["hooks"] as? [String: Any] else {
            Issue.record("connect did not produce a shape this test can strip from"); return
        }
        hooks["PostToolUse"] = nil
        root["hooks"] = hooks
        try JSONSerialization.data(withJSONObject: root).write(to: URL(fileURLWithPath: path))
        #expect(SettingsMerge.installedPort(read(path)) == 8765,
                "stripping PostToolUse also broke the other seven managed events")
        #expect(read(path)["hooks"]?["PostToolUse"] == nil, "the fixture's own premise: PostToolUse is gone")

        // A FRESH runtime — a relaunch, `autoHealAttempted`'s own
        // per-instance scope means this is the only way to observe the
        // STARTUP trigger rather than a flag already spent.
        let relaunched = configRuntime(at: path)
        await relaunched.refreshConnection()

        guard case .array(let postToolUse)? = read(path)["hooks"]?["PostToolUse"], !postToolUse.isEmpty else {
            Issue.record("PostToolUse is still missing after the auto-heal's own startup trigger")
            return
        }
    }

    /// **The consent boundary — a candidate is not consent.** A hook that
    /// merely MENTIONS this deck's own loopback address, never signed by
    /// it, must never be auto-repaired: `installedPort` finds nothing
    /// actually installed, so the whole function is a no-op by
    /// construction, not by a runtime check that could drift from it.
    @Test("auto-heal never touches a file with only a foreign candidate hook, never an actually signed one")
    func autoHealNeverTouchesAForeignCandidateFile() async throws {
        let path = scratch()
        try Data(#"""
        {"hooks":{"PreToolUse":[{"matcher":"","hooks":[{"type":"command",
        "command":"curl -s http://127.0.0.1:8765/hook"}]}]}}
        """#.utf8).write(to: URL(fileURLWithPath: path))
        let before = read(path)

        let r = configRuntime(at: path)
        await r.refreshConnection()

        #expect(read(path) == before, "auto-heal wrote to a file it was never consented to touch")
    }

    /// **The idle case — nothing to heal, nothing written.** A file
    /// already carrying all eight managed events produces a no-op
    /// `Reconciliation`, and `autoHealSettingsIfNeeded`'s own guard
    /// refuses to call `connect` at all once `plan.isNoOp` — proven here
    /// as an absence of any file write, the same "no write, not just no
    /// visible change" standard `connectingTwiceChangesNothing`
    /// (`ConnectFlowTests`) already holds `connect` itself to.
    @Test("auto-heal makes no write against an already fully-connected file")
    func autoHealMakesNoWriteAgainstAFullyConnectedFile() async {
        let path = scratch()
        let seed = configRuntime(at: path)
        await seed.connect(addStatusline: false)
        let before = read(path)

        let relaunched = configRuntime(at: path)
        await relaunched.refreshConnection()

        #expect(read(path) == before, "auto-heal rewrote a file that was already fully connected")
    }

    // ---------------------------------------------- the resolved-mirror linger

    /// **New-mechanism red — `scheduleMirrorLingerSweep` did not exist
    /// before this fix, so failure-before-fix is definitional rather
    /// than a subtle logic bug being caught.** `QuestionMirrorTests`
    /// (DeckCoreTests) already proves `Projection.frame`'s own
    /// `projectsMirror` predicate ages a resolved mirror out correctly,
    /// PURELY; this is the proof the RUNTIME actually wakes on its own
    /// to re-render once that predicate's own answer changes underneath
    /// a QUIET session — no further hooks fed, the exact shape of
    /// a live incident (the answer landed, nothing else ever
    /// happened on that session, and the card just sat there).
    @Test("a resolved mirror ages out of the frame on its own, with no further events fed")
    func resolvedMirrorAgesOutOnItsOwnWake() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        var seeded = DeckState()
        seeded.policy = shortPolicy()
        runtime.replaceStateForTesting(seeded)

        let session = SessionID("s-linger")
        let hold = HoldID(session: session, toolUseID: "t1")
        let question = Question(text: Redacted("Pick"), header: Redacted(""),
                                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                multiSelect: false)
        runtime.apply(.hook(HookEvent(id: EventID("pre"), at: at(0), kind: .preToolUse,
                                     session: session, cwd: nil,
                                     tool: SubjectReader.questionTool, toolUseID: "t1",
                                     held: .value(1), questions: [question])))
        // Just past the hold's own 250ms arm delay — not `at(1_000)`
        // the way DeckCoreTests' own `resolvedMirror` helper can afford
        // to: THIS timestamp becomes the linger deadline's own anchor
        // (`resolvedAt.advanced(by: resolvedMirrorLinger)`), and `now()`
        // here reads real wall-clock elapsed time, not the reducer's
        // artificial timeline — a bigger anchor is a longer REAL wait
        // for `waitForMirrorToAgeOut` below, for no benefit.
        runtime.apply(.questionSubmitted(
            hold, answers: [Answer(question: Redacted("Pick"), labels: [Redacted("A")])], at: at(300)))

        guard runtime.frame.mirrors.contains(where: { $0.hold == hold }) else {
            Issue.record("the fixture's own premise: the mirror must project right after resolving")
            return
        }

        // NO further events fed from here — a quiet session, the exact
        // shape that needs a timer rather than an event to wake it.
        await waitForMirrorToAgeOut(hold, in: runtime)

        #expect(!runtime.frame.mirrors.contains(where: { $0.hold == hold }),
                "the resolved mirror never aged out of the frame — no wake fired")

        // **The settling property — the VISIBLE
        // behavior above was already correct while the runtime silently
        // spun.** `state.mirrors` keeps the aged-out mirror until the
        // 20-minute hold sweep, deliberately — so without excluding
        // PAST deadlines from the derivation, the wake that just fired
        // rediscovers that SAME mirror's own now-past deadline on its
        // own recursive re-derive and re-arms at its `+ 50` floor,
        // forever. Pinned as a property of the FIELD, not an inference
        // from CPU usage or a timing window — `scheduledMirrorLingerDeadline`
        // is the write-only seam `scheduleMirrorLingerSweep` itself
        // writes and compares (`pendingReadinessTask`'s own doctrine,
        // applied to a deadline rather than a `Task` handle).
        #expect(runtime.scheduledMirrorLingerDeadline == nil,
                "the sleeper re-armed itself against the same mirror's own now-past deadline")

        // The unambiguous half: a SECOND, explicit call — simulating
        // whatever later `apply(_:)` would have triggered it again —
        // with NOTHING in `state.mirrors` having changed since. An
        // aged-out mirror must never re-arm the sleeper no matter how
        // many times this runs, not just on the one recursive call the
        // wake itself happened to make.
        runtime.scheduleMirrorLingerSweep()
        #expect(runtime.scheduledMirrorLingerDeadline == nil,
                "a direct re-derive against an unchanged, aged-out mirror armed a new deadline anyway")
    }
}
