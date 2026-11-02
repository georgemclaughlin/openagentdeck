//
//  PermissionWireTests.swift · Tests/DeckAppTests
//
//  Chunk 3's headline path, end to end: `DeckRuntime.handle` opens the hold,
//  `openHold` threads the hold's `permission_suggestions` onto it, a tap
//  picks one, and `decide` reads the suggestion back off the hold to answer
//  the HTTP response `handle` is still holding open.
//
//  Every other test of this feature stops short of that seam. `HoldTests`
//  and `RenderSweepTests` seed a hold through the reducer directly —
//  `Reducer.reduce`/`Reducer.run` — or through `replaceStateForTesting`, both
//  of which bypass `handle` and `openHold` entirely. `HookServerTests` checks
//  the wire form `HookResponse.decision` produces, given a `suggestions`
//  argument it was handed by hand. None of them would notice if `openHold`
//  stopped threading `permissionSuggestions` onto the hold it opens, or if
//  `decide` stopped reading them back off it before resuming the response —
//  and one of those two was true, silently, in one working tree:
//  `handle`'s own re-stamping constructor (see its doc comment) named every
//  field of the arrived event but that one, so a real permission request
//  reached `openHold` with its suggestions already gone.
//

import Testing
import Foundation
import DeckCore
@testable import DeckApp

@MainActor
struct PermissionWireTests {

    /// **Poll-with-deadline — the fix for a flake this file's own comment
    /// used to admit and accept.** `handle`'s own child task (`async let
    /// body` at each call site below) is SCHEDULED the instant it is
    /// declared but not RUN until something yields to it, and `handle`
    /// itself does not return until `decide` resolves the hold — so
    /// there is no `pendingXTask`-class handle here to `await` the way
    /// `TranscriptBackfillTests`/`ForwardPlanRuntimeTests` do for their
    /// own fire-and-forget work. A single `await Task.yield()` assumed
    /// exactly one scheduling step was always enough to run `handle` up
    /// to its own `withCheckedContinuation`, and under an UNLOADED
    /// process that assumption held — until a full-suite run, where
    /// `decide(hold, ...)` occasionally resumed BEFORE that one yield
    /// had actually let `handle`'s child task register the hold at all:
    /// `decide` no-oped against a hold that did not exist yet
    /// (`Hold.resolve`'s own guard refuses a decision with nothing to
    /// resolve), and `handle` then waited out its full 120s budget with
    /// nobody left to answer it — the exact shape of the failure this
    /// polls against instead of assuming away. This loops on the ACTUAL
    /// condition (`decisions.first?.hold == hold`) rather than a fixed
    /// step count, so it costs nothing extra when one yield genuinely
    /// was enough (the ordinary case, still typically sub-millisecond)
    /// and survives the case where it was not, up to a wall deadline no
    /// real scheduling delay should ever approach.
    private func waitForHold(_ hold: HoldID, in runtime: DeckRuntime, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while runtime.frame.decisions.first?.hold != hold, Date() < deadline {
            await Task.yield()
        }
    }

    /// Row 4 of `LVV-permission/payloads.ndjson`'s own `permission_suggestions`
    /// element — the same literal `HookServerTests` and `RenderSweepTests`
    /// use, reconstructed by hand rather than read off `Corpus`: that helper
    /// lives in the `DeckCoreTests` target only (`Package.swift`'s per-target
    /// `Fixtures`), and this suite has no dependency on it.
    private func lvvShapedSuggestions() throws -> JSONValue {
        try #require(JSONValue.parse(
            #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"}]"#))
    }

    /// The whole claim, driven for real: a `PermissionRequest` arrives on
    /// `handle`, carrying suggestions; a tap on the middle button resolves it
    /// through `decide`; and the HTTP response `handle` was still holding
    /// echoes the exact element the tap named — not a placeholder, not a
    /// plain allow.
    ///
    /// `testClockMS` supplies deck time rather than a real sleep, the same
    /// seam `PanelDrainTests.drainsOnStop` uses and for the same reason: the
    /// arm delay is a comparison between two event stamps, and racing a real
    /// 250 ms clock is the worst kind of flake. Between opening the hold and
    /// resolving it, `waitForHold` (this file's own doc comment states why
    /// a fixed `Task.yield()` used to stand here instead, and what a
    /// full-suite run eventually caught about it) lets `handle`'s child
    /// task actually run and register the hold before the tap lands.
    @Test("allowAndRemember, driven through handle end to end, echoes the tapped suggestion")
    func allowAndRememberReachesTheWireEndToEnd() async throws {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        let session = SessionID("s-perm-e2e")
        let hold = HoldID(session: session, toolUseID: "toolu-perm-e2e")
        let suggestions = try lvvShapedSuggestions()

        let event = HookEvent(id: EventID("perm-e2e"), at: .start, kind: .permissionRequest,
                              session: session, cwd: nil, tool: "Bash",
                              toolUseID: hold.toolUseID, held: .absent,
                              subject: Subject(tool: "Bash",
                                               detail: Redacted("git push origin main"),
                                               field: nil),
                              permissionSuggestions: suggestions)

        runtime.testClockMS = 0
        async let body = runtime.handle(event)

        await waitForHold(hold, in: runtime)

        #expect(runtime.frame.decisions.first?.hold == hold,
                "the hold never reached the frame, so nothing below is exercising handle at all")
        #expect(runtime.frame.decisions.first?.suggestionLabels == ["Don't ask again for: git push *"],
                "the suggestion did not survive from the arrived event to the projected decision")

        runtime.testClockMS = 1_000   // past the 250 ms arm delay
        runtime.decide(hold, .allowAndRemember(suggestionIndex: 0))

        let response = await body
        let parsed = try #require(JSONValue.parse(response),
                                  Comment(rawValue: "handle's response was not valid JSON: \(response)"))
        let decision = try #require(parsed["hookSpecificOutput"]?["decision"])
        #expect(decision["behavior"]?.stringValue == "allow")
        let updated = try #require(decision["updatedPermissions"]?.arrayValue,
                                   Comment(rawValue: "no updatedPermissions on the wire — "
                                           + "allowAndRemember fell through to a plain allow"))
        #expect(updated.first == suggestions.arrayValue?.first,
                "the wire's echoed suggestion does not match the one the event carried in")
    }

    /// The negative half of the same path: a `PermissionRequest` with NO
    /// suggestions still opens and resolves normally through `handle`, and a
    /// plain `.allow` on it carries no `updatedPermissions` at all. Guards
    /// against a fix to the defect above overcorrecting into always attaching
    /// an array, even an empty one, which is a different lie than the one it
    /// replaces.
    @Test("a permission request with no suggestions still resolves through handle")
    func plainAllowReachesTheWireWithNoSuggestions() async throws {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        let session = SessionID("s-perm-e2e-none")
        let hold = HoldID(session: session, toolUseID: "toolu-perm-e2e-none")
        let event = HookEvent(id: EventID("perm-e2e-none"), at: .start, kind: .permissionRequest,
                              session: session, cwd: nil, tool: "Bash",
                              toolUseID: hold.toolUseID, held: .absent,
                              subject: Subject(tool: "Bash", detail: Redacted("ls"), field: nil))

        runtime.testClockMS = 0
        async let body = runtime.handle(event)
        // `waitForHold`'s own doc comment states why this polls rather
        // than trusting a single `Task.yield()` — the identical flake
        // the other test in this file already names, reachable here too
        // since `decide` below would no-op against the same not-yet-open
        // hold under the same suite-load scheduling.
        await waitForHold(hold, in: runtime)
        #expect(runtime.frame.decisions.first?.hold == hold,
                "the hold never reached the frame, so nothing below is exercising handle at all")
        #expect(runtime.frame.decisions.first?.suggestionLabels.isEmpty == true)

        runtime.testClockMS = 1_000
        runtime.decide(hold, .allow)

        let response = await body
        let parsed = try #require(JSONValue.parse(response))
        let decision = try #require(parsed["hookSpecificOutput"]?["decision"])
        #expect(decision["behavior"]?.stringValue == "allow")
        #expect(decision["updatedPermissions"] == nil)
    }
}
