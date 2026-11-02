//
//  FleetCLIResolveTests.swift · Tests/DeckAdaptersTests
//
//  The Finder-PATH defect's fix, exercised without needing a
//  particular machine layout to reproduce it. `candidates` and `pick` are the pure half
//  of resolution and are asserted directly; the explicit-path test proves a
//  caller-supplied path is trusted rather than probed; the stub-executable
//  test below pins the branch that IS the fix end-to-end, through `poll()`
//  and a real (fake) process; and the real-filesystem `pick` test pins the
//  predicate under test to `FileManager.isExecutableFile`, not a stand-in
//  for it.
//
//  What is NOT here: a test of the resolved-BARE-name branch — the
//  well-known-location scan against the real home directory, or the
//  login-shell probe. Both read the machine this suite happens to run on
//  (whether `claude` is actually installed, where, and what a real
//  interactive `/bin/zsh -lic` says), so a test of that branch would be a
//  test of the machine, not of this file. `candidates` and `pick` are
//  pinned instead, pure and home-parameterised, because they are the part
//  of that branch this file controls.
//

import Testing
import Foundation
import DeckCore
@testable import DeckAdapters

struct FleetCLIResolveTests {

    @Test("candidates lists the five well-known claude locations in the documented order, home-relative ones rooted at the given home")
    func candidatesOrder() {
        let home = "/Users/example"
        let expected = [
            "/Users/example/.claude/local/claude",
            "/Users/example/.local/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Applications/cmux.app/Contents/Resources/bin/claude",
        ]
        #expect(FleetCLI.candidates(home: home) == expected)
    }

    @Test("pick returns the first candidate the predicate accepts")
    func pickFirstMatch() {
        let accepted: Set<String> = ["b", "c"]
        let result = FleetCLI.pick(from: ["a", "b", "c"], isExecutable: { accepted.contains($0) })
        #expect(result == "b")
    }

    @Test("pick returns nil when no candidate is accepted")
    func pickNoMatch() {
        let result = FleetCLI.pick(from: ["a", "b"], isExecutable: { _ in false })
        #expect(result == nil)
    }

    /// A path is an explicit choice made outside this file — a test fixture
    /// or a person typing a path into Settings — and resolution must not
    /// second-guess it. If this were probed instead of trusted, `resolve`
    /// would return nil for a path that (correctly, for this test) does not
    /// exist.
    @Test("an explicit path containing a slash is used verbatim, unprobed")
    func explicitPathShortCircuits() async {
        let path = "/nonexistent/somewhere/claude"
        let resolved = await FleetCLI.resolve(path)
        #expect(resolved == path)
    }

    /// `pick`, driven by the real `FileManager` predicate, against a list
    /// where the first entry does not exist and the second is a real
    /// executable file this test creates. The well-known-location scan in
    /// `probe` is exactly this call with a different list — this is the part
    /// of it worth pinning to a real filesystem rather than a fake predicate.
    @Test("pick against the real filesystem finds a real executable behind a missing candidate")
    func picksRealExecutableOverMissingCandidate() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleetcli-resolve-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let stub = dir.appendingPathComponent("claude")
        try "#!/bin/sh\necho fake\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let missing = dir.appendingPathComponent("does-not-exist").path
        let result = FleetCLI.pick(from: [missing, stub.path],
                                   isExecutable: FileManager.default.isExecutableFile(atPath:))
        #expect(result == stub.path,
                "the real executable did not win over the missing candidate ahead of it")
    }

    /// The branch that IS the fix, end to end: an explicit path reaches
    /// `poll()`, `resolve` returns it verbatim (no probe, no well-known
    /// list), and `BoundedProcess` execs it directly — no shell, no `PATH`
    /// lookup, nothing left for the Finder-launch defect to reproduce. The
    /// stub prints one row of `agents --json` shaped by `FleetRow.swift`
    /// (`FleetIngest.rows`), with a `sessionId` so the assertion is about a
    /// real round trip through `JSONValue.parse` and not just "something
    /// came back".
    @Test("an explicit executable is exec'd directly and its fleet is read")
    func explicitExecutableIsExecedAndItsFleetIsRead() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("fleetcli-stub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sessionId = "11111111-2222-3333-4444-555555555555"
        let payload = #"[{"pid":12345,"cwd":"/tmp/stub","kind":"interactive","sessionId":"\#(sessionId)","name":"stub-session","status":"idle"}]"#
        let stub = dir.appendingPathComponent("claude")
        try "#!/bin/sh\nprintf '%s' '\(payload)'\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: stub.path)

        // MEASURED, not assumed: this test is the one place in the suite that
        // asks a real child process to answer inside a hard deadline
        // (`BoundedProcess`'s 10s, via `FleetCLI.poll`), and the full suite's
        // startup is the one moment several OTHER suites — `StatuslineRelayTests`,
        // `HookCommandTests` — are also spawning real shells at once, on however
        // many cores the machine hands the test binary. Instrumented directly
        // against `BoundedProcess` (bypassing `poll`'s total-by-construction
        // empty-array collapse, which is what made this flake unreadable from a
        // row count alone): the dispatch to `BoundedProcess`'s own queue was
        // never the delay (sub-10ms every time); the wait was spent entirely
        // inside the pipe read, blocked on the STUB CHILD ITSELF not getting
        // scheduled — under a 4-6x oversubscribed 14-core machine, this file's
        // first spawn measured 5.1-7.5s before the child so much as ran its
        // `printf` and exited, occasionally enough (observed elsewhere, ~4/13
        // loaded runs) to clear the 10s deadline outright and come back as the
        // same empty array `poll()` returns for a genuinely absent fleet. A
        // second spawn, moments later once that startup burst has passed,
        // measured 90-160ms every time — so this is a one-time scheduling
        // pile-up at suite start, not a persistent defect, and a bounded retry
        // only ever pays for the pile-up: a real defect in `FleetCLI` or
        // `BoundedProcess` would return the same empty array on every attempt,
        // retried or not.
        var rows: [FleetRow] = []
        for attempt in 1...3 {
            rows = await FleetCLI(executable: stub.path).poll()
            if !rows.isEmpty { break }
            if attempt < 3 { try await Task.sleep(for: .milliseconds(200)) }
        }
        #expect(rows.count == 1,
                Comment(rawValue: "expected exactly one row from the stub, got \(rows.count)"))
        #expect(rows.first?.session == SessionID(sessionId),
                "the stub's sessionId did not round-trip through poll()")
    }

    /// The now-free deterministic half of the guard in (1): a name that is
    /// not `"claude"` never reaches the well-known-location scan or the
    /// login-shell probe, so this needs neither a real filesystem nor a real
    /// process to assert on — the guard short-circuits before either would
    /// run.
    @Test("resolve returns nil for a bare name that is not claude, without touching disk or spawning anything")
    func resolveGuardsNonClaudeBareNames() async {
        let resolved = await FleetCLI.resolve("definitely-not-claude")
        #expect(resolved == nil)
    }
}
