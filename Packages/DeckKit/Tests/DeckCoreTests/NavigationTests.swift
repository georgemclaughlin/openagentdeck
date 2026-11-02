//
//  NavigationTests.swift · Tests/DeckCoreTests
//
//  The core of navigation: the back button, promotion, and the
//  arm windows extended to picks and fronts. All of it is assertions
//  over reducer state and effect lists — the same shape as HoldTests, for the
//  same reason: navigation that resolves something is the defect class here,
//  and effects-as-data is what makes "it resolved nothing" a property of a
//  list.
//
//  The multi-question walks use `Corpus.bannerFontDensity` — the one real
//  three-question `AskUserQuestion` ever recorded (S10) — so the stepper is
//  exercised against questions a session actually asked. The multi-select
//  restore has no recorded fixture (every corpus question is single-select);
//  its case below is L0-only evidence, and the goal doc says so.
//

import Testing
@testable import DeckCore

struct NavigationTests {

    let session = SessionID("nav-s1")
    var hold: HoldID { HoldID(session: session, toolUseID: "toolu_nav_01") }
    var other: HoldID { HoldID(session: SessionID("nav-s2"), toolUseID: "toolu_nav_02") }
    var third: HoldID { HoldID(session: SessionID("nav-s3"), toolUseID: "toolu_nav_03") }

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// A held PreToolUse, as the corpus records one.
    private func held(_ id: HoldID, at ms: Int64) -> DeckEvent {
        .hook(HookEvent(id: EventID("pre-\(id)-\(ms)"), at: at(ms),
                        kind: .preToolUse, session: id.session, cwd: nil,
                        tool: "Bash", toolUseID: id.toolUseID, held: .value(8002)))
    }

    /// The recorded three-question call, opened as a hold for `hold`.
    private func questionCall(at ms: Int64 = 0) -> DeckEvent {
        .hook(HookEvent(id: EventID("q-\(ms)"), at: at(ms), kind: .preToolUse,
                        session: session, cwd: Redacted("/w"),
                        tool: SubjectReader.questionTool, toolUseID: hold.toolUseID,
                        held: .value(1), questions: Corpus.bannerFontDensity))
    }

    private func pick(_ label: String, _ ms: Int64) -> DeckEvent {
        .questionPicked(hold, label: Redacted(label), at: at(ms))
    }

    // ------------------------------------------------------------ the free-step-back rule

    /// A step back is free, total, and silent: no effect,
    /// `gathered.count == step` preserved, the popped answer restored as the
    /// live selection, and step 0 a no-op rather than an underflow.
    @Test("stepping back is silent, restores the answer, and cannot underflow")
    func backIsFreeTotalSilent() {
        var state = Reducer.run([questionCall()])

        // Answer question 1, land on question 2.
        _ = Reducer.reduce(&state, pick("Teal", 1_000))
        #expect(state.answering[hold]?.step == 1)
        #expect(state.answering[hold]?.gathered.count == 1)

        // Back: silent, and the answer is *shown selected* again.
        let effects = Reducer.reduce(&state, .questionSteppedBack(hold, at: at(2_000)))
        #expect(effects.isEmpty, "a step back emitted \(effects.count) effect(s)")
        #expect(state.answering[hold]?.step == 0)
        #expect(state.answering[hold]?.picked.map(\.value) == ["Teal"],
                "the reopened question forgot what it said")
        #expect(state.answering[hold]?.gathered.isEmpty == true)

        // Total at the floor: back at step 0 changes nothing and emits nothing.
        let underflow = Reducer.reduce(&state, .questionSteppedBack(hold, at: at(3_000)))
        #expect(underflow.isEmpty)
        #expect(state.answering[hold]?.step == 0)
        #expect(state.answering[hold]?.picked.map(\.value) == ["Teal"])

        // The invariant the register states: gathered never disagrees with step.
        #expect(state.answering[hold].map { $0.gathered.count == $0.step } == true)
    }

    /// A revised answer is what reaches the wire,
    /// once, at the end — the back-step never leaks the superseded choice.
    @Test("back then re-answer ships one submission carrying the revision")
    func backNeverReachesTheWire() {
        var state = Reducer.run([questionCall()])
        var effects: [Effect] = []

        effects += Reducer.reduce(&state, pick("Teal", 1_000))
        effects += Reducer.reduce(&state, .questionSteppedBack(hold, at: at(1_600)))
        // Revise question 1 — "Crimson" is the S10 call's other real option —
        // then walk to the end. 500 ms cadence clears the 400 ms step re-arm.
        effects += Reducer.reduce(&state, pick("Crimson", 2_100))
        effects += Reducer.reduce(&state, pick("Sans", 2_600))
        effects += Reducer.reduce(&state, pick("Roomy", 3_100))

        let submitted = effects.compactMap { effect -> [Answer]? in
            if case .updatedInput(_, let answers) = effect { return answers }
            return nil
        }
        #expect(submitted.count == 1, "the wire saw \(submitted.count) submissions")
        #expect(submitted.first?.map(\.labels.first?.value) == ["Crimson", "Sans", "Roomy"],
                "the wire carried the superseded answer, not the revision")
        #expect(effects.filter { $0.resolves(hold) }.count == 1)   // the exactly-once rule
    }

    /// The multi-select restore: a popped multi-label answer returns
    /// whole. L0-only evidence — no recorded multiSelect question exists.
    @Test("a multi-select answer steps back with every label it had")
    func multiSelectRestore() {
        let stores = Question(
            text: Redacted("Which stores?"), header: Redacted("Stores"),
            options: [QuestionOption(label: Redacted("Postgres"), detail: Redacted("")),
                      QuestionOption(label: Redacted("Redis"), detail: Redacted("")),
                      QuestionOption(label: Redacted("S3"), detail: Redacted(""))],
            multiSelect: true)
        let colour = Question(
            text: Redacted("Which colour?"), header: Redacted("Colour"),
            options: [QuestionOption(label: Redacted("Teal"), detail: Redacted("")),
                      QuestionOption(label: Redacted("Coral"), detail: Redacted(""))],
            multiSelect: false)
        var state = Reducer.run([.hook(HookEvent(
            id: EventID("m"), at: at(0), kind: .preToolUse, session: session,
            cwd: nil, tool: SubjectReader.questionTool, toolUseID: hold.toolUseID,
            held: .value(1), questions: [stores, colour]))])

        _ = Reducer.reduce(&state, pick("Postgres", 1_000))
        _ = Reducer.reduce(&state, pick("Redis", 1_100))     // toggles, no step change
        _ = Reducer.reduce(&state, .questionCommitted(hold, at: at(1_600)))
        #expect(state.answering[hold]?.step == 1)

        _ = Reducer.reduce(&state, .questionSteppedBack(hold, at: at(2_200)))
        #expect(state.answering[hold]?.step == 0)
        #expect(state.answering[hold]?.picked.map(\.value) == ["Postgres", "Redis"],
                "the multi-select restore lost labels")
    }

    // ------------------------------------------------------------ the promotion-navigates rule

    /// Promotion navigates and never resolves: the displayed
    /// front changes, the frame's first decision IS it, the demoted hold stays
    /// open, and a closed hold promotes nothing.
    @Test("promotion changes what is shown and resolves nothing")
    func promotionNavigatesNeverResolves() {
        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 0))
        Reducer.reduce(&state, held(other, at: 10))
        #expect(state.displayedFront == hold)

        let effects = Reducer.reduce(&state, .promote(other, at: at(1_000)))
        #expect(effects.compactMap(\.resolution).isEmpty, "promotion resolved something")
        #expect(state.displayedFront == other)
        #expect(state.holds[hold]?.isOpen == true)
        #expect(state.holds[other]?.isOpen == true)

        // The frame agrees with itself: expanded lane and first decision name
        // the same hold — the defect three front definitions used to allow.
        let frame = Projection.frame(from: state, at: at(1_100))
        #expect(frame.decisions.first?.hold == other)
        #expect(frame.lanes.first(where: \.isExpanded)?.session == other.session)

        // A stale promotion: once the promoted hold closes, the earliest
        // waiter rule resumes without cleanup code.
        _ = Reducer.reduce(&state, .decision(other, .allow, at: at(2_000)))
        #expect(state.displayedFront == hold)
        #expect(Projection.frame(from: state, at: at(2_100)).decisions.first?.hold == hold)

        // Promoting a closed hold changes nothing.
        _ = Reducer.reduce(&state, .promote(other, at: at(3_000)))
        #expect(state.displayedFront == hold)
    }

    /// 'S stepper half: demotion clears the demoted question
    /// call's progress, at demotion, observably (the declared divergence from
    /// UX_DESIGN §4.1's clear-on-re-promotion).
    @Test("a demoted stepper forgets its picks the moment it is demoted")
    func demotionClearsProgress() {
        var state = Reducer.run([questionCall()])
        Reducer.reduce(&state, held(other, at: 10))
        _ = Reducer.reduce(&state, pick("Teal", 1_000))
        #expect(state.answering[hold]?.step == 1)

        _ = Reducer.reduce(&state, .promote(other, at: at(2_000)))
        #expect(state.answering[hold] == nil, "the demoted stepper kept its progress")
        // The hold itself is untouched, unchanged.
        #expect(state.holds[hold]?.isOpen == true)
    }

    /// The mast counter's walk: promoteNext cycles the open holds in
    /// front order and wraps. Attack 13's designated test.
    @Test("next-waiter walks the queue in order and wraps")
    func promoteNextCycles() {
        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 0))
        Reducer.reduce(&state, held(other, at: 10))
        Reducer.reduce(&state, held(third, at: 20))
        #expect(state.displayedFront == hold)

        _ = Reducer.reduce(&state, .promoteNext(at: at(1_000)))
        #expect(state.displayedFront == other, "next from the front was not the second-oldest")
        _ = Reducer.reduce(&state, .promoteNext(at: at(2_000)))
        #expect(state.displayedFront == third)
        _ = Reducer.reduce(&state, .promoteNext(at: at(3_000)))
        #expect(state.displayedFront == hold, "the walk did not wrap")

        // And none of it resolved anything.
        #expect(state.holds.values.allSatisfy { $0.isOpen })
    }

    // ------------------------------------------------------- the arm-delay rule extended

    /// Picks obey the hold's own arm delay. A tap 10 ms after the
    /// takeover opens was the accepted defect this goal closes.
    @Test("a pick before the arm delay does not land")
    func picksObeyTheArm() {
        var state = Reducer.run([questionCall()])
        // armedAt = openedAt + 250 ms.
        _ = Reducer.reduce(&state, pick("Teal", 10))
        #expect(state.answering[hold]?.step ?? 0 == 0, "a pick landed before settle")
        _ = Reducer.reduce(&state, pick("Teal", 250))
        #expect(state.answering[hold]?.step == 1, "a pick at the arm boundary was refused")
    }

    /// The 400 ms step re-arm, both directions: a rhythm tap after an
    /// advance or a back-step dies on the unarmed columns.
    @Test("the re-opened question's options re-arm after every step change")
    func stepReArm() {
        var state = Reducer.run([questionCall()])
        _ = Reducer.reduce(&state, pick("Teal", 1_000))
        // 100 ms after the advance: refused.
        _ = Reducer.reduce(&state, pick("Sans", 1_100))
        #expect(state.answering[hold]?.step == 1, "a rhythm tap landed on the next question")
        // 400 ms after: lands.
        _ = Reducer.reduce(&state, pick("Sans", 1_400))
        #expect(state.answering[hold]?.step == 2)

        // Back is exempt — the mistap rescue arrives fast by design…
        _ = Reducer.reduce(&state, .questionSteppedBack(hold, at: at(1_450)))
        #expect(state.answering[hold]?.step == 1)
        // …but the reopened question's options re-arm like any step change.
        _ = Reducer.reduce(&state, pick("Serif", 1_500))
        #expect(state.answering[hold]?.picked.map(\.value) == ["Sans"],
                "a pick landed inside the back-step's re-arm window")
        _ = Reducer.reduce(&state, pick("Serif", 1_850))
        #expect(state.answering[hold]?.step == 2)
        #expect(state.answering[hold]?.gathered.last?.labels.map(\.value) == ["Serif"])
    }

    /// The front re-arm: after a promotion, the incoming takeover's
    /// controls refuse a decision for 400 ms — the tap was aimed at the
    /// demoted one. Timeout resolutions stay exempt. Attack 8's designated
    /// test.
    @Test("a promoted takeover refuses the tap aimed at the demoted one")
    func frontReArm() {
        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 0))
        Reducer.reduce(&state, held(other, at: 10))
        _ = Reducer.reduce(&state, .promote(other, at: at(1_000)))

        // 200 ms after the front change: the rhythm tap dies.
        let early = Reducer.reduce(&state, .decision(other, .allow, at: at(1_200)))
        #expect(early.compactMap(\.resolution).isEmpty, "a decision landed inside the front re-arm")
        #expect(state.holds[other]?.isOpen == true)

        // Release is not a touch: the timeout path is exempt.
        var expired = state
        let release = Reducer.reduce(&expired, .decision(other, .release, at: at(1_200)))
        #expect(release.compactMap(\.resolution).count == 1)

        // 400 ms on: the decision lands.
        let landed = Reducer.reduce(&state, .decision(other, .allow, at: at(1_400)))
        #expect(landed.compactMap(\.resolution).count == 1)
    }

    /// The stamp fires only on a real change of front, and **never
    /// for a wire event**. The order-insensitivity rule forced the second
    /// half: "did the front pass through X on the way" is an arrival-order
    /// fact, and a permutation of recorded rows must land on one state — the
    /// permutation test failed on the draft that stamped for hooks. Live the
    /// exemption costs nothing: the runtime stamps every arrival with
    /// `now()`, so an arriving hold is always the latest waiter and can never
    /// take the front from an open one.
    @Test("the front stamp: promote-the-front is silent, and wire arrivals never stamp")
    func frontStampOnlyOnChange() {
        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 100))
        #expect(state.frontChangedAt == nil, "a takeover opening stamped a re-arm")

        // Promoting the hold that is already the front: no change, no stamp —
        // P1.23's same-instant promote-then-decide relies on exactly this.
        _ = Reducer.reduce(&state, .promote(hold, at: at(1_000)))
        #expect(state.frontChangedAt == nil)

        // A hold whose openedAt precedes the current front's, arriving late —
        // the replay-only reordering SG5 allows. The front moves (the state
        // is a pure function of the set, the order-insensitivity rule) but
        // nothing stamps (so is the stamp).
        Reducer.reduce(&state, held(other, at: 50))
        #expect(state.displayedFront == other)
        #expect(state.frontChangedAt == nil, "a wire arrival stamped the re-arm")

        // A user event moving the front does stamp.
        _ = Reducer.reduce(&state, .promote(hold, at: at(2_000)))
        #expect(state.frontChangedAt == at(2_000))
    }

    /// Restart forgets navigation state with everything else:
    /// The recover-from-feeds rule's rule reaching the promoted id.
    @Test("restart clears the promoted id and the re-arm stamp")
    func restartClearsNavigation() {
        var state = DeckState()
        Reducer.reduce(&state, held(hold, at: 0))
        Reducer.reduce(&state, held(other, at: 10))
        _ = Reducer.reduce(&state, .promote(other, at: at(1_000)))
        #expect(state.promoted == other)

        _ = Reducer.reduce(&state, .restart(at: at(2_000)))
        #expect(state.promoted == nil)
        #expect(state.frontChangedAt == nil)
        #expect(state.displayedFront == nil)
    }
}
