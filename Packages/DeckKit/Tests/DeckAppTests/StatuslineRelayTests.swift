//
//  StatuslineRelayTests.swift · Tests/DeckAppTests
//
//  The installed statusline relay, RUN rather than read.
//
//  Two defects have now shipped in this one line and neither was visible to a
//  test that inspected the string:
//
//    - it was `original | tee >(curl …)`, which relays the RENDERED LINE. The
//      `rate_limits` object exists only on the statusline's stdin, so the deck
//      received text it could not parse and the usage dot had no data;
//    - the corrected shape was `tee >(curl …) | original`, which is bash.
//      Claude Code runs statusline commands under `/bin/sh` (LV33), and bash as
//      sh rejects `>(…)` at PARSE time — so nothing ran at all, and the fix
//      delivered exactly as much as the bug it replaced.
//
//  `SettingsTests` asserted the composed command CONTAINED the original and
//  that the copy was upstream of it. Both were true of a string that no shell
//  would execute. So this file hands the command to a real `/bin/sh` with a stub
//  on `PATH` in place of curl, and reads back two things: what the deck was
//  posted, and what the terminal was shown.
//
//  Same lesson as `HookCommandTests`, one command line over: a substring check
//  on a shell command says nothing about what a shell does with it.
//

import Testing
import Foundation
import DeckCore

struct StatuslineRelayTests {

    /// What a real shell made of the relay.
    private struct Run {
        /// stdout — what Claude Code would paint as the statusline.
        let rendered: String
        /// The bytes the stub curl was asked to POST, or nil if it never ran.
        let posted: String?
        /// The URL curl was given.
        let url: String?
        let exitCode: Int32
        let stderr: String
    }

    /// Run the composed relay under `/bin/sh`, feeding it `payload` on stdin.
    ///
    /// `original` stands in for whatever statusline the user already had. It is
    /// deliberately something with a quote and a pipe in it: the relay embeds it
    /// verbatim, and a shape that needed to re-quote the original would corrupt
    /// exactly this.
    private func relay(payload: String,
                       original: String = #"tr -d '\n' | sed 's/^/LINE:/'"#,
                       shell: String = "/bin/sh",
                       temp: String? = nil) throws -> Run {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let body = dir.appendingPathComponent("posted")
        let args = dir.appendingPathComponent("url")

        // A stub curl that understands BOTH `--data-binary @-` and
        // `--data-binary @<file>`. A stub that only read stdin would report an
        // empty body for the file form and look exactly like the empty-body
        // defect this suite exists to catch — a false alarm is as expensive here
        // as a miss.
        let stub = dir.appendingPathComponent("curl")
        try """
        #!/bin/sh
        for a in "$@"; do
          case "$a" in
            http*) printf '%s' "$a" > '\(args.path)' ;;
            @-) cat > '\(body.path)' ;;
            @*) cat "${a#@}" > '\(body.path)' ;;
          esac
        done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: stub.path)

        let command = SettingsMerge.relayCommand(wrapping: original, port: 8765)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", command]
        // PATH holds the stub FIRST but keeps the system directories: the relay
        // legitimately needs `mktemp`, `cat` and `rm`, and a PATH of only the
        // stub would fail for a reason that has nothing to do with the relay.
        var environment = ["PATH": "\(dir.path):/usr/bin:/bin"]
        // `mktemp` honours TMPDIR, so pointing it at a private directory is what
        // lets the leak check watch only this relay's own spool.
        if let temp { environment["TMPDIR"] = temp }
        process.environment = environment

        let out = Pipe(), err = Pipe(), input = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()
        let rendered = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        return Run(rendered: rendered,
                   posted: try? String(contentsOf: body, encoding: .utf8),
                   url: try? String(contentsOf: args, encoding: .utf8),
                   exitCode: process.terminationStatus,
                   stderr: errors)
    }

    /// A payload shaped like the one LV19 recorded: `rate_limits` is the field
    /// the whole usage feature reads, and it appears on stdin and nowhere else.
    private let payload = #"""
    {"session_id":"s1","cwd":"/tmp/x","context_window":{"used_percentage":17},\#
    "rate_limits":{"five_hour":{"used_percentage":76,"resets_at":1785300000}}}
    """#

    /// The command a `/bin/sh` can actually run.
    ///
    /// The falsifier that was live: `syntax error near unexpected token '('`,
    /// exit 2, nothing executed. An exit code and an empty stderr are what
    /// separate "the relay ran" from "the relay was rejected before it started",
    /// and no assertion about the string's CONTENT can tell those apart.
    @Test("the installed relay parses and runs under /bin/sh")
    func runsUnderPOSIXShell() throws {
        let run = try relay(payload: payload)
        #expect(run.exitCode == 0,
                Comment(rawValue: "the relay exited \(run.exitCode): \(run.stderr)"))
        #expect(!run.stderr.contains("syntax error"),
                Comment(rawValue: "the shell would not parse the relay: \(run.stderr)"))
    }

    /// The deck is posted the statusline's INPUT, byte for byte.
    ///
    /// This is the first defect, expressed as a measurement rather than as a
    /// direction check: `rate_limits` reaches the deck or the usage feature has
    /// no data source. Comparing the whole body rather than grepping for the key
    /// also catches a relay that posts a re-serialised or truncated copy.
    @Test("the relay posts the payload the statusline was given, unchanged")
    func postsTheInput() throws {
        let run = try relay(payload: payload)
        #expect(run.posted == payload,
                Comment(rawValue: "the deck was posted: \(run.posted ?? "<nothing>")"))
        #expect(run.posted?.contains("rate_limits") == true,
                "the one field the usage dot reads did not reach the deck")
        #expect(run.url == "http://127.0.0.1:8765/statusline",
                Comment(rawValue: "posted to \(run.url ?? "<nowhere>")"))
    }

    /// Measured on the OUTPUT rather than on the source text.
    ///
    /// The user's own statusline must receive exactly what it would have
    /// received and emit exactly what it would have emitted. `wrapsOriginal`
    /// only ever proved the original's text was present somewhere in the
    /// command; this proves the original ran and its stdout is the line.
    @Test("the original statusline still renders, from the same bytes")
    func originalIsUntouched() throws {
        let run = try relay(payload: payload)
        // The stand-in original strips newlines and prefixes `LINE:`, so its
        // output is a function of every byte it was given.
        let expected = "LINE:" + payload.replacingOccurrences(of: "\n", with: "")
        #expect(run.rendered == expected,
                Comment(rawValue: "the terminal would have shown: \(run.rendered)"))
    }

    /// Nothing is left on disk.
    ///
    /// The relay spools the payload to a file, and that payload carries `cwd`
    /// and `transcript_path` — real paths on somebody's machine. The
    /// rendered-is-not-recorded rule lets path text reach a frame and a
    /// screen and never an artefact, so a spool that outlived the render
    /// would be a new artefact holding exactly the text the invariant is
    /// about. It renders on every keystroke, so a leak here is also
    /// unbounded.
    @Test("the spooled payload does not outlive the render")
    func leavesNothingBehind() throws {
        // **Its OWN temp directory.** The first version scanned the shared one
        // for `tmp.*` and failed whenever anything else on the machine happened
        // to create one — which, under a mutation run spawning processes in
        // parallel, is often. A test that fails on somebody else's file is not
        // measuring this relay.
        let sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("spool-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: sandbox) }

        _ = try relay(payload: payload, temp: sandbox.path)
        _ = try relay(payload: payload, temp: sandbox.path)

        let left = (try? FileManager.default.contentsOfDirectory(atPath: sandbox.path)) ?? []
        #expect(left.isEmpty,
                Comment(rawValue: "the relay left \(left.count) spool file(s) behind: \(left)"))
    }

    /// The bare relay, which is what a user with no statusline of their
    /// own is offered and what the deck installs. It has no
    /// original to protect, so the only question is whether a POSIX shell runs
    /// it and the deck is posted the payload.
    @Test("the bare relay runs under /bin/sh and posts the payload")
    func bareRelayRuns() throws {
        // Composed here rather than through `relay(wrapping:)` because there is
        // nothing to wrap; the stub and the shell are the same.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("bare-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let body = dir.appendingPathComponent("posted")
        let stub = dir.appendingPathComponent("curl")
        try """
        #!/bin/sh
        for a in "$@"; do
          case "$a" in
            @-) cat > '\(body.path)' ;;
            @*) cat "${a#@}" > '\(body.path)' ;;
          esac
        done
        """.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: stub.path)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", SettingsMerge.bareRelayCommand(port: 8765)]
        process.environment = ["PATH": "\(dir.path):/usr/bin:/bin"]
        let input = Pipe(), err = Pipe()
        process.standardInput = input
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        input.fileHandleForWriting.write(Data(payload.utf8))
        try? input.fileHandleForWriting.close()
        let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()

        #expect(process.terminationStatus == 0,
                Comment(rawValue: "the bare relay exited \(process.terminationStatus): \(errors)"))
        #expect((try? String(contentsOf: body, encoding: .utf8)) == payload,
                "the bare relay did not post the payload it was given")
    }
}
