//
//  HoldBudgetTests.swift · Tests/DeckCoreTests
//
//  The user-configurable hold budget, at the two layers `HoldTests` and
//  `HoldLifecycleTests` do not reach: the wire from `DeckPrefs.holdBudget` to
//  `HoldPolicy.budget` (`.prefsChanged`, in the reducer), and what a `nil`
//  budget — `HoldBudget.untilAnswered` — does to every consumer of
//  `Hold.expiresAt` once it stops being a number.
//
//  Deliberately reducer- and projection-only. The actual wall-clock timer
//  lives in `DeckRuntime.handle` (`DeckApp`), and racing it with a real sleep
//  is the worst kind of flake; `DeckState.scheduledWork` is the deterministic
//  seam that answers the same question — "is anything counting this down" —
//  without a clock. `HoldBudgetRuntimeTests` (`DeckAppTests`) is the one test
//  that drives the real seam, the same way `PermissionWireTests` does for
//  chunk 3.
//

import Testing
// `@testable` for the same reason `HoldTests` and `ConformanceTests` need
// it: seeding a hold directly into `state.holds` to get a shape no single
// event produces (a forever hold's `budget` frozen at open time) is honest
// about the engine having no headless arrival path for one, same as those two.
@testable import DeckCore

struct HoldBudgetTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    // -------------------------------------------------------- policy rebuild

    /// The one-source countdown rule's write site. `armDelay`/`reArmDelay`/
    /// `longPress` are specs, not preferences, and `.prefsChanged` must not
    /// disturb them even though it rebuilds `budget` on every single call —
    /// changing a quick action must not quietly reset the arm delay back to
    /// its `.spec` value if some future refactor ever made that easy to do.
    @Test("prefsChanged rebuilds the policy's budget and leaves the specs alone")
    func prefsChangedRebuildsBudget() {
        var state = DeckState()
        #expect(state.policy.budget == Millis(120_000), "the default policy is not .spec's own budget")

        var prefs = DeckPrefs()
        prefs.holdBudget = .seconds(300)
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(0)))

        #expect(state.policy.budget == Millis(300_000))
        #expect(state.policy.armDelay == HoldPolicy.spec.armDelay)
        #expect(state.policy.reArmDelay == HoldPolicy.spec.reArmDelay)
        #expect(state.policy.longPress == HoldPolicy.spec.longPress)

        // And back to nil for untilAnswered — the rebuild reads the CURRENT
        // preference every time, not the first one it ever saw.
        prefs.holdBudget = .untilAnswered
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(1)))
        #expect(state.policy.budget == nil)
        #expect(state.policy.armDelay == HoldPolicy.spec.armDelay,
                "changing the budget disturbed a spec that has nothing to do with it")
    }

    /// A hold already open when the preference changes keeps ITS OWN budget —
    /// `Hold.budget` is copied from `state.policy.budget` at the instant the
    /// hold opened, not re-read live. Only a hold opened AFTER the change
    /// sees the new number, which is what makes "applies to new sessions
    /// after Connect updates the hooks" (the Settings caption) true of the
    /// in-app countdown too, not just the installed file.
    @Test("an open hold keeps the budget it opened with; a later hold gets the new one")
    func openHoldsAreUnaffectedByALaterPrefsChange() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pre-1"), at: at(0),
                                               kind: .preToolUse, session: SessionID("s1"),
                                               cwd: nil, tool: "Bash", toolUseID: "t1",
                                               held: .value(1))))
        let firstHold = HoldID(session: SessionID("s1"), toolUseID: "t1")
        #expect(state.holds[firstHold]?.budget == Millis(120_000))

        var prefs = DeckPrefs()
        prefs.holdBudget = .untilAnswered
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(10)))
        #expect(state.holds[firstHold]?.budget == Millis(120_000),
                "an already-open hold's budget moved under it")

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("pre-2"), at: at(20),
                                               kind: .preToolUse, session: SessionID("s2"),
                                               cwd: nil, tool: "Bash", toolUseID: "t2",
                                               held: .value(1))))
        let secondHold = HoldID(session: SessionID("s2"), toolUseID: "t2")
        #expect(state.holds[secondHold]?.budget == nil,
                "a hold opened after the change did not pick up the new budget")
    }

    // ------------------------------------------------------- question budget
    //
    // The question-mirror arc's own split: `AskUserQuestion` reads
    // `HoldPolicy.questionBudget`, everything else keeps reading `.budget`
    // — the SAME `h.tool == SubjectReader.questionTool` gate `needsAHuman`
    // already asks, at the ONE reducer site (`apply(_:HookEvent)`'s
    // hold-open branch) live code actually opens a question hold through.

    /// `.spec`'s own two numbers, at the two hold-opening sites this
    /// reducer has — a question call gets 8s, an ordinary tool call
    /// (Bash, standing in for "everything else") keeps the unchanged 120s.
    @Test("a question hold opens with the question budget; an ordinary tool hold keeps the permission budget")
    func questionHoldsGetTheQuestionBudget() {
        var state = DeckState()
        #expect(state.policy.questionBudget == Millis(8_000),
                "the default policy is not .spec's own question budget")

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("q1"), at: at(0),
                                               kind: .preToolUse, session: SessionID("s1"),
                                               cwd: nil, tool: SubjectReader.questionTool, toolUseID: "t1",
                                               held: .value(1))))
        let questionHold = HoldID(session: SessionID("s1"), toolUseID: "t1")
        #expect(state.holds[questionHold]?.budget == Millis(8_000),
                "a question hold did not pick up HoldPolicy.questionBudget")

        Reducer.reduce(&state, .hook(HookEvent(id: EventID("b1"), at: at(1),
                                               kind: .preToolUse, session: SessionID("s2"),
                                               cwd: nil, tool: "Bash", toolUseID: "t2",
                                               held: .value(1))))
        let bashHold = HoldID(session: SessionID("s2"), toolUseID: "t2")
        #expect(state.holds[bashHold]?.budget == Millis(120_000),
                "an ordinary tool hold picked up the QUESTION budget instead of the permission one")
    }

    /// `questionHoldBudget`'s own write site, the identical rule
    /// `prefsChangedRebuildsBudget` already holds `holdBudget` to — a
    /// SEPARATE preference, rebuilt independently, `armDelay`/`reArmDelay`/
    /// `longPress` undisturbed by either.
    @Test("prefsChanged rebuilds the question budget independently of the permission one")
    func prefsChangedRebuildsQuestionBudgetIndependently() {
        var state = DeckState()
        var prefs = DeckPrefs()
        prefs.questionHoldBudget = .seconds(20)
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(0)))

        #expect(state.policy.questionBudget == Millis(20_000))
        #expect(state.policy.budget == HoldPolicy.spec.budget,
                "changing the QUESTION budget moved the permission one too")
        #expect(state.policy.armDelay == HoldPolicy.spec.armDelay)

        // And back to nil for untilAnswered, read fresh each time, the same
        // "not merely the first value it ever saw" property `holdBudget`'s
        // own rebuild test holds itself to.
        prefs.questionHoldBudget = .untilAnswered
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(1)))
        #expect(state.policy.questionBudget == nil)
        #expect(state.policy.budget == HoldPolicy.spec.budget,
                "the permission budget moved when only the question one changed")
    }

    /// `.questionOpened`'s own hold-construction site (`DeckState.swift`) —
    /// unconditional `questionBudget`, no `h.tool ==` gate needed, since a
    /// `QuestionCall` is by construction always about the question tool.
    /// Not the live path (`DeckRuntime.openHold` always re-drives through
    /// `.hook`), but held to the same rule as a matter of internal
    /// consistency — a second construction site reading the WRONG budget
    /// would be invisible to every test exercising only the live path.
    @Test("questionOpened's own hold-construction site also reads the question budget")
    func questionOpenedEventAlsoReadsQuestionBudget() {
        var state = DeckState()
        let hold = HoldID(session: SessionID("s1"), toolUseID: "t1")
        let call = QuestionCall(hold: hold,
                                questions: [Question(text: Redacted("Pick?"), header: Redacted("H"),
                                                     options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                                                     multiSelect: false)],
                                rawQuestions: nil)
        Reducer.reduce(&state, .questionOpened(call, at: at(0)))
        #expect(state.holds[hold]?.budget == Millis(8_000))
    }

    // ------------------------------------------------------------- forever

    @Test("a nil budget has no expiry")
    func nilBudgetHasNoExpiry() {
        let hold = Hold(id: HoldID(session: SessionID("s"), toolUseID: "t"),
                        openedAt: at(0), budget: nil, frontendOwned: true, armDelay: Millis(250))
        #expect(hold.expiresAt == nil)
    }

    /// The fall-through rule's filter, over a hold with nothing to fall
    /// through TO. `at` is pushed absurdly far — far past any real seconds
    /// budget this deck will ever offer — and the hold is still there,
    /// because `nil` means "always actionable while open", not "expires at
    /// some very large number".
    @Test("a forever hold stays actionable no matter how far the clock advances")
    func foreverHoldStaysActionablePastAnyClockAdvance() {
        var state = DeckState()
        state.holds[HoldID(session: SessionID("s"), toolUseID: "t")] = Hold(
            id: HoldID(session: SessionID("s"), toolUseID: "t"),
            openedAt: at(0), budget: nil, frontendOwned: true, armDelay: Millis(250))

        let farFuture = at(Int64.max / 2)
        let decisions = Projection.frame(from: state, at: farFuture).decisions
        #expect(decisions.map(\.hold) == [HoldID(session: SessionID("s"), toolUseID: "t")],
                "the decisions filter dropped a hold with no expiry to be past")
    }

    /// `DeckState.scheduledWork` is the deterministic stand-in for "is a
    /// timer actually counting this down" — `DeckRuntime.handle` schedules a
    /// real `Task` only when a hold's OWN budget is non-nil, and this is the
    /// reducer-level fact that decision is made from. A seconds hold is
    /// scheduled work; a forever hold is not, because nothing wakes up on
    /// its own account to do anything about it.
    @Test("a forever hold schedules no expiry timer; a seconds hold does")
    func foreverHoldSchedulesNoExpiryTimer() {
        var state = DeckState()
        let id = HoldID(session: SessionID("s"), toolUseID: "t")
        state.holds[id] = Hold(id: id, openedAt: at(0), budget: nil,
                               frontendOwned: true, armDelay: Millis(250))
        #expect(!state.scheduledWork.contains(TimerID("hold-\(id)")),
                "a forever hold reported scheduled work nothing will ever fire")

        var timed = DeckState()
        timed.holds[id] = Hold(id: id, openedAt: at(0), budget: Millis(120_000),
                               frontendOwned: true, armDelay: Millis(250))
        #expect(timed.scheduledWork.contains(TimerID("hold-\(id)")),
                "a budgeted hold's own expiry timer went missing from the idle-CPU accounting")
    }

    /// **Replay safety.** A `.holdExpired` recorded before the user ever
    /// chose `.untilAnswered` — or fabricated by a buggy client, or simply
    /// stale — arriving against a hold that has none must not crash. The
    /// unknown-is-not-error rule: `Hold.resolve` never reads `budget` or
    /// `expiresAt` at all, so this is inert by construction rather than by a
    /// special case written for it, and the assertion is that it stays that
    /// way — the hold resolves exactly as any other frontend-owned hold
    /// would, via `.release`, and the deck moves on.
    @Test("a replayed holdExpired against a forever-policy hold is inert, not a crash")
    func replayedHoldExpiredAgainstAForeverHoldIsInert() {
        var state = DeckState()
        let id = HoldID(session: SessionID("s"), toolUseID: "t")
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("open"), at: at(0),
                                               kind: .preToolUse, session: id.session,
                                               cwd: nil, tool: "Bash", toolUseID: id.toolUseID,
                                               held: .value(1))))
        var prefs = DeckPrefs()
        prefs.holdBudget = .untilAnswered
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(1)))
        // The hold already open keeps its ORIGINAL (seconds) budget per
        // `openHoldsAreUnaffectedByALaterPrefsChange` above — so this is
        // reseated directly to exercise a hold that is ACTUALLY forever,
        // the shape a fresh hold opened after the change would have.
        state.holds[id] = Hold(id: id, openedAt: .start, budget: nil,
                               frontendOwned: true, armDelay: Millis(250))

        let effects = Reducer.reduce(&state, .holdExpired(id, at: at(999_999_999)))
        #expect(effects.compactMap(\.resolution).first?.1 == .release)
        #expect(state.holds[id]?.isOpen == false)
        #expect(Projection.frame(from: state, at: at(1_000_000_000)).decisions.isEmpty,
                "a resolved hold still offered a decision")
    }
}
