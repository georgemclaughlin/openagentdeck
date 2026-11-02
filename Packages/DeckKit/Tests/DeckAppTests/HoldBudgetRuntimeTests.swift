//
//  HoldBudgetRuntimeTests.swift · Tests/DeckAppTests
//
//  The user-configurable hold budget, driven through the real seam:
//  `DeckRuntime.handle` schedules its own expiry `Task` only when the hold it
//  just opened carries a budget (`Hold.budget != nil`). `HoldBudgetTests`
//  (`DeckCoreTests`) pins the deterministic half of this claim —
//  `DeckState.scheduledWork` no longer lists a forever hold as scheduled
//  work — because racing the real `Task.sleep` this schedules against a
//  virtual clock is the worst kind of flake, and `scheduledWork` answers the
//  same question without one. This is the one test that goes through
//  `handle` itself, the same seam `PermissionWireTests` drives for chunk 3's
//  own headline path.
//

import Testing
import Foundation
import DeckCore
@testable import DeckApp

@MainActor
struct HoldBudgetRuntimeTests {

    /// `testClockMS` supplies deck time for the arm-delay gate, the same
    /// seam `PermissionWireTests` and `PanelDrainTests.drainsOnStop` use —
    /// but the claim under test here is about a REAL `Task`, which reads the
    /// wall clock regardless of what `testClockMS` says, so the middle of
    /// this test waits on an actual (short) sleep rather than moving the
    /// virtual one.
    @Test("a hold opened under .untilAnswered schedules no expiry")
    func untilAnsweredHoldSchedulesNoExpiry() async throws {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        var prefs = runtime.prefs
        prefs.holdBudget = .untilAnswered
        runtime.setPrefs(prefs)

        let session = SessionID("s-forever")
        let hold = HoldID(session: session, toolUseID: "toolu-forever")
        // `.permissionRequest`, not `.preToolUse`: `handle`'s own gate
        // (`HoldPolicy.spec.needsAHuman`) only holds a `.preToolUse` HTTP
        // response open for the question tool specifically — a real
        // `.preToolUse` hold is always an `AskUserQuestion` call. A plain
        // `Bash` tool call that wants a human arrives on `PermissionRequest`.
        let event = HookEvent(id: EventID("forever"), at: .start, kind: .permissionRequest,
                              session: session, cwd: nil, tool: "Bash",
                              toolUseID: hold.toolUseID, held: .absent,
                              subject: Subject(tool: "Bash", detail: Redacted("ls"), field: nil))

        runtime.testClockMS = 0
        async let body = runtime.handle(event)
        await Task.yield()
        #expect(runtime.frame.decisions.first?.hold == hold,
                "the hold never reached the frame, so nothing below exercises handle at all")

        // A real wait, not a virtual-clock jump. The mistake this guards
        // against is the easy one — nil-coalescing a forever budget to
        // ZERO instead of skipping the schedule entirely, which would fire
        // almost immediately rather than never. Every real budget this deck
        // offers floors at ten seconds (`HoldBudget.floorSeconds`), so
        // nothing correctly implemented could resolve the hold in this
        // window regardless of which budget were somehow active instead.
        try? await Task.sleep(for: .milliseconds(200))
        #expect(runtime.frame.decisions.first?.hold == hold,
                "the hold closed on its own — something scheduled an expiry for a forever budget")

        runtime.testClockMS = 1_000   // past the 250 ms arm delay
        runtime.decide(hold, .allow)
        let response = await body
        let parsed = try #require(JSONValue.parse(response))
        #expect(parsed["hookSpecificOutput"]?["decision"]?["behavior"]?.stringValue == "allow",
                "the hold did not resolve the way the tap asked it to — it may already be resolved")
    }
}
