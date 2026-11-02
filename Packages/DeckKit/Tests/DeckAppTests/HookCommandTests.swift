//
//  HookCommandTests.swift · Tests/DeckAppTests
//
//  The installed hook command, RUN rather than read.
//
//  Three defects have now shipped in this one line, and every one of them was
//  invisible to a test that inspected the string:
//
//    - `--data-binary @-` was missing, so curl posted an empty body and every
//      session the deck installed was invisible to it;
//    - the runtime rebuilt the arrived event without its host address;
//    - the URL was wrapped in SINGLE quotes, so `${CMUX_SURFACE_ID:-}` never
//      expanded and every lane was unroutable.
//
//  The third passed a test asserting the command *contained*
//  `surface=${CMUX_SURFACE_ID:-}`. It did. Single quotes meant the shell handed
//  that text to curl verbatim. A substring check on a shell command says nothing
//  about what a shell does with it, so this file gives the command to a real
//  shell with a stub on `PATH` in place of curl, and reads back the URL that
//  actually got requested.
//

import Testing
import Foundation
import DeckCore

struct HookCommandTests {

    /// Run the installed command under `/bin/sh` with a fake `curl` that records
    /// its arguments, and hand back what curl was asked to fetch.
    ///
    /// `event` defaults to `PreToolUse`; the held variant of this same test
    /// passes `PermissionRequest` — the command differs only in `--max-time`,
    /// but the shell-quoting hazards that made this file's whole point are
    /// identical, and duplicating the harness would be the thing to get out
    /// of sync when only one copy gets fixed.
    private func urlRequested(surface: String, workspace: String,
                              event: String = "PreToolUse") throws -> String {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hookcmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A stub curl: print every argument on its own line and exit. The real one
        // would need a listener, and what is under test is the URL, not the POST.
        let stub = dir.appendingPathComponent("curl")
        try #"""
        #!/bin/sh
        for a in "$@"; do printf '%s\n' "$a"; done
        """#.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: stub.path)

        // The command exactly as it is installed, out of the diff the deck writes.
        let installed = SettingsMerge.install(into: .object([:]), port: 8765).after
        let entry = installed["hooks"]?[event]?.arrayValue?.first
        let command = entry?["hooks"]?.arrayValue?.first?["command"]?.stringValue
        #expect(command != nil, "no hook command was installed for \(event)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command ?? ""]
        process.environment = ["PATH": dir.path,
                               "CMUX_SURFACE_ID": surface,
                               "CMUX_WORKSPACE_ID": workspace]
        let out = Pipe()
        process.standardOutput = out
        process.standardInput = Pipe()          // stdin closes immediately
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n").map(String.init)
            .first { $0.hasPrefix("http") } ?? ""
    }

    /// **The hook reports the surface it is actually running in.**
    @Test("the installed hook command expands the host identity when a shell runs it")
    func hookCommandExpandsTheHostIdentity() throws {
        let url = try urlRequested(surface: "surface:18", workspace: "workspace:14")
        #expect(!url.isEmpty, "curl was never invoked with a URL")
        #expect(url.contains("surface=surface:18"),
                "the surface did not expand — the URL requested was \(url)")
        #expect(url.contains("workspace=workspace:14"),
                "the workspace did not expand — the URL requested was \(url)")
        // The failure mode this file exists for, named so a regression reads
        // plainly rather than as a mismatch.
        #expect(!url.contains("CMUX_SURFACE_ID"),
                "the variable reached curl unexpanded — the URL is quoted wrong")
    }

    /// **The held variant is a different literal command — a wider
    /// `--max-time` — built by the same hand, quoted the same way.** A
    /// single-quote regression in `heldHookCommand` would be exactly as
    /// invisible to a string-only test as the original PreToolUse defect was;
    /// this runs it under a real shell for the same reason that one does.
    @Test("the held hook command expands the host identity, with a widened --max-time")
    func heldHookCommandExpandsTheHostIdentity() throws {
        let installed = SettingsMerge.install(into: .object([:]), port: 8765).after
        let command = installed["hooks"]?["PermissionRequest"]?.arrayValue?.first?["hooks"]?
            .arrayValue?.first?["command"]?.stringValue ?? ""
        #expect(command.contains("--max-time 125 "),
                "the held command kept the 5 s floor sized for an event that is never held")

        let url = try urlRequested(surface: "surface:18", workspace: "workspace:14",
                                   event: "PermissionRequest")
        #expect(!url.isEmpty, "curl was never invoked with a URL")
        #expect(url.contains("surface=surface:18"),
                "the surface did not expand in the held command — requested \(url)")
        #expect(url.contains("workspace=workspace:14"),
                "the workspace did not expand in the held command — requested \(url)")
        #expect(!url.contains("CMUX_SURFACE_ID"),
                "the variable reached curl unexpanded in the held command")
    }

    /// Outside cmux the fields are EMPTY, not an error and not a guess.
    /// Unknown is not error, and `HostAddress` refuses half an address, so
    /// a session with no host simply cannot be spoken to and the panel says so.
    @Test("outside cmux the hook reports empty halves rather than failing")
    func outsideCmuxTheHookStillPosts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("hookcmd-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stub = dir.appendingPathComponent("curl")
        try #"""
        #!/bin/sh
        for a in "$@"; do printf '%s\n' "$a"; done
        """#.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                              ofItemAtPath: stub.path)

        let installed = SettingsMerge.install(into: .object([:]), port: 8765).after
        let command = installed["hooks"]?["PreToolUse"]?.arrayValue?.first?["hooks"]?
            .arrayValue?.first?["command"]?.stringValue ?? ""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.environment = ["PATH": dir.path]        // no CMUX vars at all
        let out = Pipe()
        process.standardOutput = out
        process.standardInput = Pipe()
        try process.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let url = text.split(separator: "\n").map(String.init).first { $0.hasPrefix("http") } ?? ""

        #expect(url.contains("surface=&") || url.hasSuffix("surface="),
                "outside cmux the surface should be empty, and the URL was \(url)")
        #expect(!url.contains("CMUX_"), "an unexpanded variable reached curl")
    }
}
