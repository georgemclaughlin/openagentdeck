//
//  HoldTests.swift · Tests/DeckCoreTests
//
//  Cases P1.23–P1.29 — class D, the class where a bug is expensive in a way no
//  other class is.
//
// All of it is assertions over a list of effects, because the reducer
// returns actions instead of performing them. That is what
// lets the exactly-once rule's "exactly once, over every interleaving" be a
// loop rather than a concurrency test, and it is why these run in
// microseconds with no mocks.
//

import Testing
// `@testable` for one reason, named so it does not spread: P1.26 needs a
// HEADLESS hold, and the engine has no headless arrival path — every hold in the
// corpus came from an interactive session. Seeding one through the module's
// internal setter is honest about that; adding a public "make me a hold" API to
// production code so a test can call it is not.
@testable import DeckCore

struct HoldTests {

    let session = SessionID("s1")
    var hold: HoldID { HoldID(session: session, toolUseID: "toolu_01") }
    var other: HoldID { HoldID(session: SessionID("s2"), toolUseID: "toolu_02") }

    /// A held PreToolUse, as the corpus records one.
    private func held(_ id: HoldID, at ms: Int64, heldMs: Int = 8002) -> DeckEvent {
        .hook(HookEvent(id: EventID("pre-\(id)-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                        kind: .preToolUse, session: id.session, cwd: nil,
                        tool: "Bash", toolUseID: id.toolUseID, held: .value(heldMs)))
    }
    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// **The engine decides who needs a human, not a list in here.**
    ///
    /// This case used to assert a set of tool names, and a real session
    /// measured what that set cost: of 389.7 s the deck spent blocking a
    /// person, 366.9 s — 94 % — went on `pwd`, `ls`, `ls -a`, `find`, `git
    /// log` and `git show`. Every one is a read-only command Claude Code
    /// auto-approves and would never have shown a dialog for. The deck was
    /// not supervising them; it was inventing a gate, and the
    /// graceful-degradation rule says no session is ever worse off because
    /// the deck exists.
    ///
    /// The commands below are the ones it actually blocked on, read out of
    /// `fixtures/live/LV14-plan/payloads.ndjson` rather than imagined.
    @Test("a call is taken over when the engine asks for a human, and not otherwise")
    func onlySupervisedToolsAreHeld() {
        let policy = HoldPolicy.spec

        // The engine is about to show a dialog. That IS the deck's subject —
        // for every permission_mode except the one the engine already
        // answered itself. `nil` means the payload named none, which reads
        // as "not bypass" rather than as an unknown the deck must refuse.
        #expect(policy.needsAHuman(kind: .permissionRequest, tool: "Bash", permissionMode: nil))
        #expect(policy.needsAHuman(kind: .permissionRequest, tool: "Write", permissionMode: "default"))
        // Even for a tool nobody listed, because the list is gone.
        #expect(policy.needsAHuman(kind: .permissionRequest, tool: "SomeToolInventedNextMonth",
                                   permissionMode: "acceptEdits"))
        #expect(policy.needsAHuman(kind: .permissionRequest, tool: nil, permissionMode: "plan"))

        // A question is a request for the user by definition, and arrives on
        // PreToolUse rather than as a permission dialog. permission_mode does
        // not matter to it — see `bypassPermissionsNeedsNoHuman` for why not.
        #expect(policy.needsAHuman(kind: .preToolUse, tool: SubjectReader.questionTool,
                                   permissionMode: "bypassPermissions"))

        // And everything the engine did NOT ask about is waved through — every
        // one of these was really blocked on, for a really measured 366.9 s.
        for tool in ["Bash", "Write", "Edit", "NotebookEdit", "WebFetch",
                     "Read", "Glob", "Grep", "Agent", "ToolSearch"] {
            #expect(!policy.needsAHuman(kind: .preToolUse, tool: tool, permissionMode: "default"),
                    "\(tool) was gated without the engine asking")
        }
        #expect(!policy.needsAHuman(kind: .preToolUse, tool: nil, permissionMode: nil))
        #expect(!policy.needsAHuman(kind: .postToolUse, tool: "Bash", permissionMode: nil))
        #expect(!policy.needsAHuman(kind: .stop, tool: nil, permissionMode: nil))

        // The recorded run, replayed: exactly one of its 13 PreToolUse calls
        // should reach a human, and it is the question. LV14 ran in `plan`
        // mode throughout, which this also pins as not reading like bypass.
        let held = Corpus.liveRun().filter {
            policy.needsAHuman(kind: $0.kind, tool: $0.tool, permissionMode: $0.permissionMode)
        }
        #expect(held.count == 1, "the live run would still gate \(held.count) calls")
        #expect(held.first?.tool == SubjectReader.questionTool)
    }

    /// **The second false positive `needsAHuman` had.** The first was a tool
    /// list that gated `pwd`; this one is the opposite shape — an event that
    /// looked like it always meant a human, until a `bypassPermissions`
    /// session measured otherwise: `PermissionRequest` fires on every tool
    /// call with the engine auto-allowing every one — measured in the
    /// deck's own log: **2,515 bogus holds
    /// opened on one such session**. Pinned at both call
    /// sites the policy question reaches — the policy method itself, and the
    /// reducer's own `opensAHold`, which used to hardcode `true` here
    /// independently — because a `permission_mode` that reaches one and not
    /// the other reopens exactly this gap.
    @Test("bypassPermissions answers its own PermissionRequest — the deck holds nothing")
    func bypassPermissionsNeedsNoHuman() {
        #expect(!HoldPolicy.spec.needsAHuman(kind: .permissionRequest, tool: "Bash",
                                             permissionMode: "bypassPermissions"))
        // A real question still outranks bypass: bypass auto-answers
        // permissions, not the user's own question.
        #expect(HoldPolicy.spec.needsAHuman(kind: .preToolUse, tool: SubjectReader.questionTool,
                                            permissionMode: "bypassPermissions"))

        // The reducer's own hold-opening agrees.
        var state = DeckState()
        Reducer.reduce(&state, .hook(HookEvent(
            id: EventID("bypass"), at: at(0), kind: .permissionRequest,
            session: session, cwd: Redacted("/w"), tool: "Bash", toolUseID: "toolu_bp",
            held: .absent, permissionMode: "bypassPermissions")))
        #expect(state.holds.isEmpty, "a bypass session opened a hold nobody will ever answer")
        #expect(state.lanes[session]?.state == .working,
                "a bypass PermissionRequest is still evidence the session is doing something")

        // Absent, or any other mode, still opens one — this is a narrowing,
        // not a removal.
        var normal = DeckState()
        Reducer.reduce(&normal, .hook(HookEvent(
            id: EventID("normal"), at: at(0), kind: .permissionRequest,
            session: session, cwd: Redacted("/w"), tool: "Bash", toolUseID: "toolu_ok",
            held: .absent)))
        #expect(normal.holds.count == 1)
        #expect(normal.lanes[session]?.state == .needsYou)
    }

    /// **Fix 3's ruling, replayed.** "Never hold what you cannot answer" is
    /// not only `DeckRuntime.handle`'s live guard (`QuestionWireTests`
    /// covers that one end to end) — the reducer's own `opensAHold` for
    /// `.preToolUse` trusts `held_ms` as already-decided for every OTHER
    /// tool (replay must not re-litigate what a historical relay recorded),
    /// so the unreadable case needed its own exception carved out of that
    /// trust rather than inheriting one for free. This pins the exception
    /// directly at the reducer: a `held_ms > 0` row for an unreadable
    /// `AskUserQuestion` — exactly what a pre-fix relay, or an old recorded
    /// fixture, could still hand this reducer — must not open a hold in
    /// REPLAY either, while an ordinary held tool call and a normal,
    /// readable question call are both unaffected.
    @Test("a held, unreadable question row opens no hold in the reducer; ordinary held rows are unaffected")
    func unreadableQuestionRowOpensNoHoldInReplay() {
        let unreadableUse = "toolu_q_bad"
        var unreadable = DeckState()
        Reducer.reduce(&unreadable, .hook(HookEvent(
            id: EventID("q-bad"), at: at(0), kind: .preToolUse,
            session: session, cwd: nil, tool: SubjectReader.questionTool,
            toolUseID: unreadableUse, held: .value(8_002), questionsUnreadable: true)))
        #expect(unreadable.holds[HoldID(session: session, toolUseID: unreadableUse)] == nil,
                "an unreadable question opened a hold nobody could ever answer through the deck")

        let readableUse = "toolu_q_ok"
        var readable = DeckState()
        Reducer.reduce(&readable, .hook(HookEvent(
            id: EventID("q-ok"), at: at(0), kind: .preToolUse,
            session: session, cwd: nil, tool: SubjectReader.questionTool,
            toolUseID: readableUse, held: .value(8_002))))
        #expect(readable.holds[HoldID(session: session, toolUseID: readableUse)] != nil,
                "the fix over-refused: a normal, readable question call must still open a hold")

        // And the trust-`held_ms` path for every OTHER tool is untouched:
        // `held(_:at:)` below is exactly this shape for Bash, and the rest
        // of this suite depends on it opening a hold on `held_ms` alone.
        var ordinary = DeckState()
        Reducer.reduce(&ordinary, held(hold, at: 0))
        #expect(ordinary.holds[hold]?.isOpen == true,
                "gating the question tool's held_ms also gated an unrelated one")
    }

    /// The video scenario's finding, pinned to its recorded row: CLI 2.1.220
    /// sends `PermissionRequest` with NO `tool_use_id`, and a hold gate that
    /// requires one waves through the deck's whole subject — filmed happening,
    /// the terminal asking in the deck's place. The ingest synthesizes the
    /// identity, idempotently; this test is the row's decode, the policy's
    /// verdict, and the composed open the runtime seeds, end to end from the
    /// fixture.
    @Test("a PermissionRequest with no tool_use_id still gets a hold identity")
    func permissionRequestWithoutIDOpensAHold() {
        let events = Corpus.permissionRun()
        guard let request = events.first(where: { $0.kind == .permissionRequest }) else {
            Issue.record("the fixture lost its PermissionRequest row"); return
        }
        guard let use = request.toolUseID else {
            Issue.record("no identity was synthesized — the engine sent none and the deck kept none")
            return
        }
        // Idempotent: the same recorded row decodes to the same identity.
        #expect(Corpus.permissionRun()
            .first { $0.kind == .permissionRequest }?.toolUseID == use)
        // And distinct from the PreToolUse that preceded it — two events, two
        // holds, or a resolution for one would answer the other.
        #expect(events.first { $0.kind == .preToolUse }?.toolUseID != use)
        #expect(HoldPolicy.spec.needsAHuman(kind: request.kind, tool: request.tool,
                                            permissionMode: request.permissionMode))

        // Composed as the runtime composes it: observe the run, then seed the
        // synthetic open for the call the engine wants a human for.
        var state = DeckState()
        for event in events { Reducer.reduce(&state, .hook(event)) }
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("open-perm"), at: request.at,
                                               kind: .preToolUse, session: request.session,
                                               cwd: nil, tool: request.tool, toolUseID: use,
                                               held: .value(1), subject: request.subject)))
        let hold = HoldID(session: request.session, toolUseID: use)
        #expect(state.holds[hold]?.isOpen == true)
        #expect(Projection.frame(from: state, at: request.at).decisions.contains { $0.hold == hold },
                "the recorded request opened no armed decision — the takeover is still dead")
    }

    /// Chunk 3, end to end off the same recorded row: the composed open now
    /// threads `permission_suggestions` too (the runtime's real `openHold`
    /// does the identical composition — see its own comment on the host-
    /// address defect this is the same shape of), so the hold carries the
    /// suggestion and the frame's `Decision` carries its label.
    @Test("the recorded PermissionRequest's suggestion reaches the frame as a label")
    func recordedSuggestionBecomesALabel() {
        let events = Corpus.permissionRun()
        guard let request = events.first(where: { $0.kind == .permissionRequest }),
              let use = request.toolUseID else {
            Issue.record("the fixture lost its PermissionRequest row or its identity")
            return
        }

        var state = DeckState()
        for event in events { Reducer.reduce(&state, .hook(event)) }
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("open-perm-label"), at: request.at,
                                               kind: .preToolUse, session: request.session,
                                               cwd: nil, tool: request.tool, toolUseID: use,
                                               held: .value(1), subject: request.subject,
                                               permissionSuggestions: request.permissionSuggestions)))
        let hold = HoldID(session: request.session, toolUseID: use)
        #expect(state.holds[hold]?.suggestions != nil,
                "the hold lost the suggestion the recorded row carried")

        let decision = Projection.frame(from: state, at: request.at).decisions.first { $0.hold == hold }
        #expect(decision?.suggestionLabels == ["Don't ask again for: git push *"])
    }

    /// Exactly one resolution, over every ordering.
    ///
    /// The fuzz is a finite set of orderings on one queue rather than an
    /// unbounded set of thread schedules — architecture §5's trade paying off.
    @Test("every hold terminates in exactly one outcome, over every interleaving")
    func exactlyOnceResolution() {
        let after = at(1_000)
        let inputs: [DeckEvent] = [
            .decision(hold, .allow, at: after),
            .decision(hold, .deny, at: after),
            .holdExpired(hold, at: at(120_001)),
            .promote(hold, at: after),
            .promote(other, at: after),
        ]

        // Every ordering of every non-empty subset, each preceded by the arrival.
        var checked = 0
        for mask in 1 ..< (1 << inputs.count) {
            let subset = inputs.indices.filter { mask & (1 << $0) != 0 }.map { inputs[$0] }
            for ordering in permutations(subset) {
                let (state, effects) = Reducer.effects([held(hold, at: 0)] + ordering)
                let resolutions = effects.filter { $0.resolves(hold) }

                // The exactly-once rule's falsifier, verbatim: "two
                // resolution effects emitted for one hold ID, **or zero at
                // hold close**". So never two — over every ordering — and
                // exactly one whenever the ordering contains something that
                // ends the hold. A subset of nothing but promotions ends
                // nothing, and asserting 1 there would be asserting the
                // demotion-preserves-the-hold rule is broken.
                #expect(resolutions.count <= 1, "\(resolutions.count) resolutions for one hold")
                let terminating = ordering.contains {
                    if case .decision(let h, _, _) = $0 { return h == hold }
                    if case .holdExpired(let h, _) = $0 { return h == hold }
                    return false
                }
                #expect(resolutions.count == (terminating ? 1 : 0))
                #expect(state.holds[hold]?.isOpen == !terminating)
                checked += 1
            }
        }
        #expect(checked == 207, "the fuzz covered \(checked) orderings")
    }

    /// A decision is written to the hold it was aimed at.
    @Test("a decision resolves the hold it names and no other")
    func correlation() {
        let (_, effects) = Reducer.effects([
            held(hold, at: 0), held(other, at: 10),
            .decision(other, .deny, at: at(1_000)),
        ])
        let resolved = effects.compactMap(\.resolution)
        #expect(resolved.count == 1)
        #expect(resolved.first?.0 == other)
        #expect(resolved.first?.1 == .deny)
        #expect(!effects.contains { $0.resolves(hold) })
    }

    /// Nothing lands before the arm delay.
    @Test("a decision before the arm delay cannot land")
    func armDelay() {
        #expect(HoldPolicy.spec.armDelay == Millis(250))

        for tooEarly in [Int64(0), 1, 249] {
            let (state, effects) = Reducer.effects([held(hold, at: 0),
                                                    .decision(hold, .allow, at: at(tooEarly))])
            #expect(effects.filter { $0.resolves(hold) }.isEmpty, "landed at \(tooEarly) ms")
            #expect(state.holds[hold]?.isOpen == true)
        }
        // ...and does land once armed, or the assertion above is satisfied by a
        // deck that never accepts anything.
        let (_, ok) = Reducer.effects([held(hold, at: 0), .decision(hold, .allow, at: at(250))])
        #expect(ok.filter { $0.resolves(hold) }.count == 1)
    }

    /// Release is not deny.
    @Test("a frontend timeout releases; a headless one denies")
    func releaseIsNotDeny() {
        var frontend = DeckState()
        Reducer.reduce(&frontend, held(hold, at: 0))
        let released = Reducer.reduce(&frontend, .holdExpired(hold, at: at(120_001)))
        #expect(released.compactMap(\.resolution).first?.1 == .release)

        // The same event on a headless hold is a different outcome. Built by
        // hand because the engine has no headless arrival path — the *rule* is
        // what is under test, and it is one branch.
        var headless = DeckState()
        headless.holds[hold] = Hold(id: hold, openedAt: .start, budget: Millis(120_000),
                                    frontendOwned: false, armDelay: Millis(250))
        let denied = Reducer.reduce(&headless, .holdExpired(hold, at: at(120_001)))
        #expect(denied.compactMap(\.resolution).first?.1 == .deny)

        // Seven now, not six: `answeredElsewhere` joined the previous six for
        // the question-mirror arc's own retirement path — see `Resolution`'s
        // own doc comment for why a terminal answering directly is a
        // distinct outcome from `.updatedInput` (the deck decided) and from
        // `.release` (the deck never found out what happened next).
        //
        // The literal `7` is not derived from anything — Swift has no cheap
        // way to ask "how many arms does `logWord`'s switch have" at either
        // compile time or runtime, only the compiler's own exhaustiveness
        // check, which `allCases`'s hand-rolled array does not share (see
        // its own doc comment, directly above the array, for the pin this
        // number is standing in for). So this is the same manual count that
        // comment warns about, checked here rather than left implicit: a
        // case added to `Resolution` without updating BOTH `logWord` and
        // `allCases` would still compile, and this assertion is the only
        // thing in the suite that would notice `allCases` stopped growing.
        #expect(Resolution.allCases.count == 7)
    }

    /// No actionable control after fall-through.
    @Test("a hold past expiry offers no decision, ever again")
    func noControlAfterFallThrough() {
        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 0))
        #expect(Projection.frame(from: state, at: at(1_000)).actionableHolds == [hold])

        Reducer.reduce(&state, .holdExpired(hold, at: at(120_001)))
        #expect(Projection.frame(from: state, at: at(120_002)).actionableHolds.isEmpty)

        // And a late tap changes nothing — the terminal is sole authority.
        let late = Reducer.reduce(&state, .decision(hold, .allow, at: at(130_000)))
        #expect(late.filter { $0.resolves(hold) }.isEmpty)
        #expect(Projection.frame(from: state, at: at(130_000)).actionableHolds.isEmpty)
    }

    /// Demotion preserves the hold.
    @Test("promoting another request releases nothing")
    func demotionPreservesTheHold() {
        let (state, effects) = Reducer.effects([
            held(hold, at: 0), held(other, at: 10),
            .promote(other, at: at(1_000)),
            .promote(hold, at: at(2_000)),
            .promote(other, at: at(3_000)),
        ])
        #expect(effects.compactMap(\.resolution).isEmpty)
        #expect(state.holds[hold]?.isOpen == true)
        #expect(state.holds[other]?.isOpen == true)
        #expect(state.frontHold == hold)      // earliest first, unmoved by promotion
    }

    /// The acknowledgement is the response write.
    @Test("only a written response acknowledges a hold")
    func ackIsTheResponseWrite() {
        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 0))
        #expect(state.lanes[session]?.state == .needsYou)

        // S12b measured PostToolUse arriving 12 142 ms after the response, and a
        // deny produces none at all. Anything that treats it as confirmation
        // shows a lane frozen for twelve seconds, and forever on deny.
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("post"), at: at(12_142),
                                               kind: .postToolUse, session: session, cwd: nil,
                                               tool: "Bash", toolUseID: hold.toolUseID,
                                               held: .absent)))
        #expect(state.holds[hold]?.isOpen == true, "PostToolUse resolved a hold")

        let effects = Reducer.reduce(&state, .decision(hold, .allow, at: at(20_000)))
        #expect(effects.filter { $0.resolves(hold) }.count == 1)
        #expect(state.holds[hold]?.outcome == .allow)
    }

    /// Chunk 3's whole claim about the reducer: `allowAndRemember` needed no
    /// special-casing in `.decision` or in `Hold.resolve` because both
    /// already read "every outcome but release and expire" rather than
    /// naming `.allow`. This is that claim, checked — arm-delay refuses an
    /// early tap exactly as it does for `.allow`, an armed one lands,
    /// acknowledges the lane out of needs-you the same write `.allow`
    /// produces, and the outcome recorded is the exact case tapped — index
    /// included, not collapsed to plain `.allow`.
    @Test("allowAndRemember acknowledges the lane like allow, and still respects the arm delay")
    func allowAndRememberBehavesLikeAllow() {
        let (early, earlyEffects) = Reducer.effects([
            held(hold, at: 0),
            .decision(hold, .allowAndRemember(suggestionIndex: 0), at: at(100)),
        ])
        #expect(earlyEffects.filter { $0.resolves(hold) }.isEmpty, "landed before the arm delay")
        #expect(early.holds[hold]?.isOpen == true)

        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 0))
        #expect(state.lanes[session]?.state == .needsYou)

        let effects = Reducer.reduce(&state, .decision(
            hold, .allowAndRemember(suggestionIndex: 2), at: at(250)))
        #expect(effects.filter { $0.resolves(hold) }.count == 1)
        #expect(state.holds[hold]?.outcome == .allowAndRemember(suggestionIndex: 2))
        #expect(state.lanes[session]?.state == .working)
    }
}

/// Small and deliberate: `Array.permutations` is not in the stdlib, and a
/// shuffle would make the fuzz unreproducible against a failure.
private func permutations(_ items: [DeckEvent]) -> [[DeckEvent]] {
    guard items.count > 1 else { return [items] }
    guard items.count <= 4 else {                    // 4! = 24; the subset loop
        return [items, items.reversed()]             // supplies the breadth
    }
    var out: [[DeckEvent]] = []
    for (i, item) in items.enumerated() {
        var rest = items; rest.remove(at: i)
        for tail in permutations(rest) { out.append([item] + tail) }
    }
    return out
}
