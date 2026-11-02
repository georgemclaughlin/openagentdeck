//
//  CrashRecoveryTests.swift · Tests/DeckAppTests
//
//  `CrashRecovery.watchdogScript`, RUN — the same lesson as
//  `StatuslineRelayTests` and `HookCommandTests`: a shell command is a claim
//  about what a shell will do with it, and only a real `/bin/sh` can settle
//  that claim. Every scenario below launches a real short-lived "app"
//  process, ends it the way a crash actually ends one (`SIGKILL`, never a
//  graceful terminate), and lets a real watchdog render its verdict; nothing
//  here asserts on the STRING.
//
//  Every sandbox's own temp directory carries a SPACE in its name
//  (`"crash recovery-<uuid>"`) — the one thing about this script that no
//  other test in the suite exercises and the one thing production cannot
//  rule out (`Bundle.main.bundleURL` can live anywhere a user or an
//  installer chose, including a path with one). Every positional argument
//  the script quotes (`"$BUNDLE"`, `"$SENTINEL"`, `"$CRASHLOG"`, `"$OPEN"`)
//  is exercised through that space on every test below, so there is no
//  separate "spacey paths" test — there is nothing left for one to cover.
//
//  `open` itself is never invoked. The script takes it as `$6` (default
//  `/usr/bin/open`, `CrashRecovery.watchdogScript`'s own doc comment carries
//  the reason for the indirection) precisely so a test can substitute
//  something observable — a tiny stub that records the one argument it was
//  called with rather than actually relaunching anything.
//
//  The sentinel is PID-stamped, not a bare marker (`CrashRecovery
//  .sentinelURL`'s own doc comment carries why: the state directory is
//  shared by every deck instance on the machine, and a bare marker cannot
//  say WHICH instance's exit it recorded — a real bug once, fixed here).
//  `aCleanExitStaysDown` and `aWrongPidSentinelStillRelaunches` are that
//  fix's positive and negative claims, in the same shape a review would ask
//  for: "a sentinel naming ME keeps me down" is only half a proof without
//  "a sentinel naming SOMEONE ELSE does not."
//
//  Every wait below is `Process.waitUntilExit()` — process semantics, not
//  timer synchronization — and the poll interval is 0.1s, so the whole
//  suite's added wall time stays a small fraction of a second. No
//  `Task.sleep` anywhere.
//

import Testing
import Foundation
@testable import DeckApp

struct CrashRecoveryTests {

    /// What one run of the watchdog left behind, for a test to read.
    private struct Verdict {
        /// The sandbox itself — kept so the caller can clean it up AFTER
        /// its own assertions run; `exercise` cannot remove it first
        /// without deleting the very files those assertions check for.
        let sandbox: URL
        let recorder: URL
        let log: [String]
    }

    /// A private sandbox per test, its name carrying a space on purpose —
    /// see the file header. UUID-scoped so parallel test runs never share
    /// a directory.
    private func sandbox() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("crash recovery-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// A stub standing in for `/usr/bin/open`: records the single argument
    /// it was called with (the bundle path) rather than doing anything a
    /// real relaunch would do. This is the only way the watchdog's LAST
    /// line — `exec "$OPEN" "$BUNDLE"` — is observable from a test at all.
    private func writeOpenStub(in dir: URL, recorder: URL) throws -> URL {
        let stub = dir.appendingPathComponent("open-stub")
        try """
        #!/bin/sh
        printf '%s\\n' "$1" > "\(recorder.path)"
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    /// Reads a file back as lines, tolerating one that was never written —
    /// "the crash log does not exist" and "the crash log has zero lines"
    /// are the same claim from a test's point of view.
    private func lines(_ url: URL) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    /// Runs the real `watchdogScript` against a real short-lived "app"
    /// process (`/bin/sleep 30`), kills it with `SIGKILL`, and waits for
    /// the watchdog to finish before returning what it left behind.
    ///
    /// `seed` runs BEFORE the kill, with the fake app's REAL pid already
    /// in hand — the PID-stamped sentinel (`CrashRecovery.sentinelURL`'s
    /// own doc comment) means a seed that wants to simulate "this
    /// instance already quit cleanly" has to know that pid to write it,
    /// the same way the real `willTerminateNotification` handler does.
    private func exercise(
        seed: (_ pid: Int32, _ sentinel: URL, _ crashLog: URL) throws -> Void = { _, _, _ in }
    ) throws -> Verdict {
        let dir = try sandbox()
        let sentinel = dir.appendingPathComponent("clean-exit")
        let crashLog = dir.appendingPathComponent("crash-relaunches")
        let recorder = dir.appendingPathComponent("recorded-open")
        let openStub = try writeOpenStub(in: dir, recorder: recorder)

        let fakeApp = Process()
        fakeApp.executableURL = URL(fileURLWithPath: "/bin/sleep")
        fakeApp.arguments = ["30"]
        fakeApp.standardOutput = FileHandle.nullDevice
        fakeApp.standardError = FileHandle.nullDevice
        try fakeApp.run()

        try seed(fakeApp.processIdentifier, sentinel, crashLog)

        let watchdog = Process()
        watchdog.executableURL = URL(fileURLWithPath: "/bin/sh")
        watchdog.arguments = [
            "-c", CrashRecovery.watchdogScript, "watchdog",
            String(fakeApp.processIdentifier),
            dir.appendingPathComponent("Bundle.app").path,
            sentinel.path,
            crashLog.path,
            "0.1",
            openStub.path,
        ]
        watchdog.standardOutput = FileHandle.nullDevice
        watchdog.standardError = FileHandle.nullDevice
        try watchdog.run()

        // A crash, not a quit: the process disappears with no chance to
        // run its own shutdown path — which SIGKILL simulates and a
        // graceful terminate would not.
        kill(fakeApp.processIdentifier, SIGKILL)
        fakeApp.waitUntilExit()
        watchdog.waitUntilExit()

        return Verdict(sandbox: dir, recorder: recorder, log: lines(crashLog))
    }

    @Test("a crash with no sentinel relaunches, and the crash log gains exactly one line")
    func aCrashWithNoSentinelRelaunches() throws {
        let verdict = try exercise()
        defer { try? FileManager.default.removeItem(at: verdict.sandbox) }
        let recorded = try? String(contentsOf: verdict.recorder, encoding: .utf8)
        #expect(recorded?.contains("Bundle.app") == true,
                Comment(rawValue: "the open stub recorded: \(recorded ?? "<nothing>")"))
        #expect(verdict.log.count == 1,
                Comment(rawValue: "expected exactly one crash-log line, found \(verdict.log)"))
    }

    /// The primary claim of the PID-stamp fix: a sentinel naming THIS
    /// watchdog's OWN pid keeps the deck down.
    @Test("a clean exit's sentinel, naming the app's own pid, keeps the deck down")
    func aCleanExitStaysDown() throws {
        let verdict = try exercise(seed: { pid, sentinel, _ in
            try Data("\(pid)".utf8).write(to: sentinel)
        })
        defer { try? FileManager.default.removeItem(at: verdict.sandbox) }
        #expect(!FileManager.default.fileExists(atPath: verdict.recorder.path),
                "the watchdog relaunched despite a clean-exit sentinel naming its own pid")
        #expect(verdict.log.isEmpty,
                Comment(rawValue: "expected no crash-log line after a clean exit, found \(verdict.log)"))
    }

    /// The negative twin, and the one that actually pins the multi-instance
    /// fix: a sentinel that exists but names SOME OTHER pid —
    /// exactly what a second deck instance sharing the same state
    /// directory leaves behind after ITS OWN clean exit — must NOT be
    /// mistaken for this instance's own clean exit. Before the PID stamp,
    /// this shape (any file present ⇒ stay down) was the fail-closed bug:
    /// a stranger's leftover marker could swallow a real crash silently.
    @Test("a sentinel naming a different pid does not keep the deck down")
    func aWrongPidSentinelStillRelaunches() throws {
        let verdict = try exercise(seed: { pid, sentinel, _ in
            // Some other instance's pid — deliberately not `pid`, and not
            // a value `/bin/sleep` could ever actually be assigned here.
            try Data("\(pid + 1)".utf8).write(to: sentinel)
        })
        defer { try? FileManager.default.removeItem(at: verdict.sandbox) }
        let recorded = try? String(contentsOf: verdict.recorder, encoding: .utf8)
        #expect(recorded?.contains("Bundle.app") == true, Comment(rawValue:
            "a sentinel naming a foreign pid should not have kept the deck down; open stub recorded: " +
            "\(recorded ?? "<nothing — the watchdog never relaunched>")"))
        #expect(verdict.log.count == 1,
                Comment(rawValue: "expected exactly one crash-log line, found \(verdict.log)"))
    }

    @Test("three recent crashes trip the loop guard and relaunching stops")
    func aCrashLoopStopsRelaunching() throws {
        let verdict = try exercise(seed: { _, _, crashLog in
            let now = Int(Date().timeIntervalSince1970)
            let seeded = (0 ..< 3).map { String(now - $0) }.joined(separator: "\n") + "\n"
            try seeded.write(to: crashLog, atomically: true, encoding: .utf8)
        })
        defer { try? FileManager.default.removeItem(at: verdict.sandbox) }
        #expect(!FileManager.default.fileExists(atPath: verdict.recorder.path),
                "the watchdog relaunched past the crash-loop budget")
        #expect(verdict.log.count == 3, Comment(rawValue:
            "expected the 3 seeded, still-recent crashes to survive pruning untouched, found \(verdict.log)"))
    }

    /// Pins the `-ge 3` boundary from the OTHER side: `aCrashLoopStopsRelaunching`
    /// proves 3 recent crashes stop a relaunch, and on its own that would
    /// pass just as well with a regression to `-ge 2`. Seeding exactly TWO
    /// recent stamps and requiring a relaunch — with the log then holding
    /// the 2 seeded plus the 1 just-written, exactly 3 — is the case that
    /// tells `-ge 2` and `-ge 3` apart.
    @Test("two recent crashes still relaunch, leaving three lines in the log")
    func twoRecentCrashesStillAllowRelaunch() throws {
        let verdict = try exercise(seed: { _, _, crashLog in
            let now = Int(Date().timeIntervalSince1970)
            let seeded = (0 ..< 2).map { String(now - $0) }.joined(separator: "\n") + "\n"
            try seeded.write(to: crashLog, atomically: true, encoding: .utf8)
        })
        defer { try? FileManager.default.removeItem(at: verdict.sandbox) }
        let recorded = try? String(contentsOf: verdict.recorder, encoding: .utf8)
        #expect(recorded?.contains("Bundle.app") == true, Comment(rawValue:
            "two recent crashes should still have allowed a relaunch; open stub recorded: " +
            "\(recorded ?? "<nothing — the watchdog did not relaunch>")"))
        #expect(verdict.log.count == 3, Comment(rawValue:
            "expected the 2 seeded crashes plus 1 fresh line, found \(verdict.log)"))
    }

    @Test("crashes older than the 10-minute budget age out and relaunching resumes")
    func staleCrashesAgeOutOfTheBudget() throws {
        let verdict = try exercise(seed: { _, _, crashLog in
            let stale = Int(Date().timeIntervalSince1970) - 900   // 15 minutes: past the 600s budget
            let seeded = (0 ..< 3).map { String(stale - $0) }.joined(separator: "\n") + "\n"
            try seeded.write(to: crashLog, atomically: true, encoding: .utf8)
        })
        defer { try? FileManager.default.removeItem(at: verdict.sandbox) }
        #expect(FileManager.default.fileExists(atPath: verdict.recorder.path),
                "stale crashes should have aged out, letting the watchdog relaunch")
        #expect(verdict.log.count == 1, Comment(rawValue:
            "expected the 3 stale entries pruned and one fresh line written, found \(verdict.log)"))
    }
}
