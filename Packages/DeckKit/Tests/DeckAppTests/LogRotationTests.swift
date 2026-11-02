//
//  LogRotationTests.swift · Tests/DeckAppTests
//
//  `DeckRuntime.note`'s two side channels, both gated for the first time.
//
//  The on-disk log (`~/Library/Logs/OpenAgentDeck.log` in production,
//  `markStartedForTesting()`'s own throwaway path here) used to be
//  append-only with no cap: a deck left running for months would grow it
//  forever. `LogRotationTests` is the rotation `note` now performs — driven
//  through the REAL production entry point, `handle(_:)` (the same seam
//  `PrefsPersistenceTests` drives hook events through), never by calling
//  `note` directly, which is `private`.
//
//  `note`'s OTHER unconditional write was to stderr — a syscall per
//  diagnostic line, on every launch, for a stream nobody has attached
//  unless they asked for it by name. `StderrGateTests` cannot assert
//  against the stream itself (there is no headless way to attach one and
//  read it back), so it arbiters the FLAG that decides whether the write
//  happens at all: `DeckRuntime.stderrEnabled`, and the environment lookup
//  that derives it.
//

import Testing
import Foundation
import DeckCore
@testable import DeckApp

@MainActor
struct LogRotationTests {

    private func started(_ session: SessionID, _ n: Int) -> HookEvent {
        HookEvent(id: EventID("start-\(n)"), at: Instant(sinceStart: Millis(Int64(n))),
                 kind: .sessionStart, session: session, cwd: nil, tool: nil,
                 toolUseID: nil, held: .absent)
    }

    /// Reads a log file back as lines, tolerating one it does not have yet.
    private func lines(_ path: String) -> [String] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// **The single-rotation case: nothing lost at the boundary itself.**
    ///
    /// "One `.old` generation only" (see `rotateLog`'s own doc comment)
    /// means data older than 2x the cap is EXPECTED to fall off — that is
    /// the feature, not a bug this file should chase. What must never
    /// happen is losing or corrupting a line at the MOMENT the boundary is
    /// crossed, which is a claim only a SINGLE crossing can test cleanly: a
    /// fixture that crosses several times (see
    /// `aSecondRotationReplacesTheFirst` below) legitimately loses its
    /// oldest lines, and asserting total-count preservation against one
    /// would be asserting the wrong thing.
    ///
    /// So this drives events ONE AT A TIME and stops the INSTANT `.old`
    /// first appears, rather than hand-computing how many `note` lines fit
    /// in how many bytes — a byte count this test does not control (the
    /// millisecond stamp's own digit width moves it) and does not need to:
    /// whatever the line size turns out to be, "every event sent so far is
    /// accounted for, split across the two files, the moment the boundary
    /// is crossed" is the same claim either way.
    @Test("the log rotates to .old once it crosses its cap, losing nothing at the boundary")
    func rotatesPastCapLosingNothingAtTheBoundary() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()   // its own throwaway logPath — never the developer's log
        let livePath = runtime.logPathForTesting
        let oldPath = livePath + ".old"
        try? FileManager.default.removeItem(atPath: oldPath)   // a clean start, belt-and-braces

        // Small enough to cross after a handful of lines, generous enough
        // that a `note` line of ordinary width (a millisecond stamp twice
        // over, `sessionOpened`, a short session id) never needs more than
        // a couple of them to trip it.
        runtime.logCapBytes = 150

        let session = SessionID("deck")
        var sent = 0
        var crossed = false
        for i in 0 ..< 40 {   // a generous ceiling; the loop exits far earlier
            _ = await runtime.handle(started(session, i))
            sent += 1
            if FileManager.default.fileExists(atPath: oldPath) { crossed = true; break }
        }
        #expect(crossed, "the cap was never crossed in \(sent) events — nothing below is measured")

        let oldLines = lines(oldPath)
        let liveLines = lines(livePath)
        #expect(!oldLines.isEmpty, "the .old generation exists but is empty")

        // The whole claim: every event sent up to and including the one
        // that triggered rotation is accounted for, split between the two
        // files, none lost and none duplicated at the boundary.
        let combined = oldLines + liveLines
        #expect(combined.count == sent, Comment(rawValue:
            "sent \(sent) events before the cap first crossed, found \(combined.count) lines " +
            "across .old (\(oldLines.count)) and the live file (\(liveLines.count)) — " +
            "rotation lost or duplicated a line at the boundary"))
        #expect(combined.allSatisfy { $0.contains("sessionOpened") && $0.contains("session=deck") },
                "a line at the rotation boundary was not the diagnostic line that should have been there")

        // And the split is honest: `.old` holds real bytes, on the order of
        // the cap that triggered it — not empty, not implausibly large.
        let oldBytes = (try? Data(contentsOf: URL(fileURLWithPath: oldPath)))?.count ?? 0
        #expect(oldBytes > 0 && Int64(oldBytes) <= runtime.logCapBytes + 256, Comment(rawValue:
            "the .old generation is \(oldBytes) bytes against a \(runtime.logCapBytes) byte cap — " +
            "either nothing rotated or it rotated implausibly late"))
    }

    /// **The live file keeps taking writes after rotating** — a rotation
    /// that closed the file and never reopened it would look identical to
    /// this suite's other assertions until the NEXT `note` call, so this
    /// pins that call separately: one more event, sent right after the
    /// boundary crossing, must land in the (now-fresh) live file rather
    /// than silently going nowhere.
    @Test("the live file keeps accepting writes immediately after rotating")
    func liveFileKeepsWritingAfterRotation() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let livePath = runtime.logPathForTesting
        let oldPath = livePath + ".old"
        try? FileManager.default.removeItem(atPath: oldPath)
        runtime.logCapBytes = 150

        let session = SessionID("deck-tail")
        for i in 0 ..< 40 {
            _ = await runtime.handle(started(session, i))
            if FileManager.default.fileExists(atPath: oldPath) { break }
        }
        let liveAtCrossing = lines(livePath).count

        // One more, after the boundary.
        _ = await runtime.handle(started(session, 999))
        let liveAfterOneMore = lines(livePath).count

        #expect(liveAfterOneMore == liveAtCrossing + 1, Comment(rawValue:
            "the live file held \(liveAtCrossing) line(s) at the crossing and \(liveAfterOneMore) " +
            "one event later — a write after rotation went missing"))
    }

    /// **One generation only.** A SECOND rotation must replace `.old`
    /// rather than pile up a `.old.old` — the doc comment's own bound
    /// (2x `logCapBytes`, by construction) depends on this, and it is also
    /// the reason older-than-2x-cap data is EXPECTED to disappear rather
    /// than a defect to chase (see the file's own header comment above).
    @Test("a second rotation replaces .old rather than keeping a third generation")
    func aSecondRotationReplacesTheFirst() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let livePath = runtime.logPathForTesting
        let oldPath = livePath + ".old"
        try? FileManager.default.removeItem(atPath: oldPath)
        runtime.logCapBytes = 100   // crosses in just a couple of lines

        let session = SessionID("deck2")
        for i in 0 ..< 12 {
            _ = await runtime.handle(started(session, i))
        }
        #expect(FileManager.default.fileExists(atPath: oldPath), "the first rotation never ran")
        let afterFirstBatch = lines(oldPath)

        for i in 12 ..< 24 {
            _ = await runtime.handle(started(session, i))
        }
        let afterSecondBatch = lines(oldPath)

        // No third file of any name — `.old.old`, `.old2`, anything —
        // exists beside the two this design promises.
        let siblings = (try? FileManager.default.contentsOfDirectory(
            atPath: (livePath as NSString).deletingLastPathComponent)) ?? []
        let stray = siblings.filter { $0.hasPrefix((livePath as NSString).lastPathComponent) && !$0.hasSuffix(".old") }
        #expect(stray.count == 1, Comment(rawValue:
            "expected exactly the live file among siblings sharing its name, found \(stray)"))
        #expect(afterFirstBatch != afterSecondBatch || afterFirstBatch.isEmpty,
                "a second rotation's .old is suspiciously identical to the first — it may not have replaced it")
    }
}

@MainActor
struct StderrGateTests {

    /// Presence-only, and off by default: an environment carrying no entry
    /// for the variable at all is exactly what an ordinary launch — from
    /// Finder, from a login item — looks like, and that launch narrates
    /// nothing to a stream nobody has attached.
    @Test("with no OPENAGENTDECK_STDERR entry, the flag reads false")
    func unsetReadsFalse() {
        #expect(DeckRuntime.stderrEnabled(in: [:]) == false)
        let runtime = DeckRuntime(environment: [:])
        #expect(runtime.stderrEnabled == false)
    }

    /// Presence, not the value, is what the doc comment promises — an empty
    /// string still counts as "set", the same as any other value, because
    /// the point is "did somebody put this variable there on purpose", not
    /// "what did they put in it".
    @Test("any value for OPENAGENTDECK_STDERR reads true, including an empty one",
          arguments: ["1", "true", "yes", ""])
    func setReadsTrue(_ value: String) {
        #expect(DeckRuntime.stderrEnabled(in: ["OPENAGENTDECK_STDERR": value]) == true)
        let runtime = DeckRuntime(environment: ["OPENAGENTDECK_STDERR": value])
        #expect(runtime.stderrEnabled == true)
    }

    /// A DIFFERENT variable being set proves the lookup is keyed on the
    /// name, not on "the environment is non-empty".
    @Test("an unrelated environment variable does not trip the flag")
    func unrelatedVariableDoesNotTrip() {
        #expect(DeckRuntime.stderrEnabled(in: ["PATH": "/usr/bin", "HOME": "/Users/x"]) == false)
    }

    /// The PRODUCTION construction — `DeckRuntime()`, `DeckScene`'s own call
    /// — reads the real process environment rather than an empty or
    /// injected one. This cannot assert a specific value (the suite's own
    /// environment is whatever CI or a developer's shell happens to set),
    /// only that it AGREES with asking `ProcessInfo` directly — the two
    /// paths must derive the same answer from the same source.
    @Test("the no-argument initializer reads the real process environment")
    func defaultConstructionMatchesProcessInfo() {
        let runtime = DeckRuntime()
        let expected = DeckRuntime.stderrEnabled(in: ProcessInfo.processInfo.environment)
        #expect(runtime.stderrEnabled == expected)
    }
}
