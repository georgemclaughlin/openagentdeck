//
//  ReduceMotionWireTests.swift · Tests/DeckAppTests
//
//  `DeckRuntime.loadPrefs()`'s own doc comment has claimed "read the
//  accessibility flags" since before there was any wiring behind the
//  words — `Frame.reduceMotion` existed, was threaded through
//  `Projection.frame`, and had no caller anywhere that ever read a real
//  value: `refresh()` always passed the parameter's own default, `false`.
//  This file arbiters the wiring that finally keeps the promise —
//  `DeckRuntime.readsReduceMotion` (the seam), `refreshAccessibility()`
//  (the one method that turns a reading into a published frame), and the
//  LAUNCH read: `loadPrefs()` calling `refreshAccessibility()` itself, so
//  a user whose Reduce Motion has been on for years gets a still deck
//  from the first frame, not from their next live toggle.
//
//  What this file deliberately does NOT arbiter: the
//  `NSWorkspace.shared.notificationCenter` observer registration in
//  `loadPrefs()` — a headless test can neither post that workspace
//  notification authentically nor observe the real setting flip, so the
//  live-toggle path is checked ON THE STRIP (System Settings → Reduce
//  Motion with the deck running), the same live-judgement boundary
//  `washTransitionRespectsReduceMotion`'s own doc comment draws for feel.
//

import Testing
import Foundation
import DeckCore
@testable import DeckApp

@MainActor
struct ReduceMotionWireTests {

    /// `refreshAccessibility()` reads `readsReduceMotion()` and republishes
    /// — both directions, so a flip back to `false` is pinned as firmly as
    /// the flip to `true` (a test that only checked one direction could
    /// pass on a method that just always sets `true`).
    @Test("refreshAccessibility reads the seam and republishes, both directions")
    func refreshAccessibilityReadsTheSeam() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        runtime.readsReduceMotion = { true }
        runtime.refreshAccessibility()
        #expect(runtime.frame.reduceMotion)

        runtime.readsReduceMotion = { false }
        runtime.refreshAccessibility()
        #expect(!runtime.frame.reduceMotion)
    }

    /// The equality guard `refresh()`'s own doc comment describes —
    /// `if next != frame { frame = next }` — exists precisely to swallow
    /// republishes that change nothing on screen. `Frame`'s own `==`
    /// includes `reduceMotion` (`Frame.swift`) so a flip of THIS flag
    /// alone, with the lane roster otherwise untouched, must still count
    /// as a real difference and reach `frame`. A test seeds a settled,
    /// non-placeholder frame first — `refresh()`'s own doc comment on why
    /// the INIT placeholder always publishes once regardless — so this is
    /// unambiguously a SECOND publish, earned by the flag alone.
    @Test("a change in only the reduceMotion flag still publishes a new frame")
    func reduceMotionAloneRepublishes() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("start"), at: .start, kind: .sessionStart,
                            session: SessionID("s"), cwd: nil, tool: nil, toolUseID: nil, held: .absent)),
        ]))
        #expect(runtime.frame.reduceMotion == false,
                "the fixture's own premise: settled on the default before the flag ever moves")

        runtime.readsReduceMotion = { true }
        runtime.refreshAccessibility()

        #expect(runtime.frame.reduceMotion, Comment(rawValue:
                "flipping ONLY the reduceMotion seam did not reach frame.reduceMotion — " +
                "either refresh() stopped threading it through, or Frame's own equality " +
                "compare swallowed a real change"))
    }

    /// **The LAUNCH read.** The two tests above call
    /// `refreshAccessibility()` by hand, so both stay green if a refactor
    /// quietly drops that call from `loadPrefs()` — and the failure that
    /// omission ships is exactly the one this arc exists to prevent: a
    /// user whose Reduce Motion has been on for YEARS launches the deck
    /// and gets pulsing cards until they happen to re-toggle the setting
    /// live. `loadPrefs()` is the sanctioned headless seam for launch
    /// behaviour (`PrefsPersistenceTests.launchWritesNothingWhenPrefsAlreadyExist`'s
    /// own precedent, spy and all), so the wire is pinned at the method
    /// production actually calls, not at the helper a refactor could
    /// orphan.
    @Test("loadPrefs itself performs the first accessibility read")
    func loadPrefsPerformsTheLaunchRead() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.prefsDefaults = SpyDefaults(suiteName: "spy-\(UUID().uuidString)")!
        runtime.readsReduceMotion = { true }

        #expect(!runtime.frame.reduceMotion,
                "the fixture's own premise: nothing has read the seam before loadPrefs runs")
        runtime.loadPrefs()
        #expect(runtime.frame.reduceMotion,
                Comment(rawValue: "loadPrefs never performed the launch accessibility read — a "
                        + "long-standing system setting would go unhonoured until the user's "
                        + "next live toggle"))
    }
}
