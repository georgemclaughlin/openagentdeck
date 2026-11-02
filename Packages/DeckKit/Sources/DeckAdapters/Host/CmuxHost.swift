//
//  CmuxHost.swift · DeckAdapters/Host
//
//  The one place in this program that knows what cmux is.
//
//  Everything here is backed by live probes (see Tests/FIXTURES.md): `LV28-cmux-host`
//  (11 workspaces, 15 surfaces, four holding more than one tab), `LV29-coexist`,
//  `LV30-multitab` and `LV31-userlayer`.
//
//  Why a CLI and not the socket directly: the socket speaks a JSON protocol
//  whose method list is 200 entries long and versioned by the app, while the
//  CLI is the documented surface and ships inside the same bundle. A future
//  adapter may talk the socket; this one shells out, and the port above is
//  what makes that swap a one-file change.
//

import Foundation
import DeckCore
import DeckPorts

public struct CmuxHost: SessionHostPort {

    /// The CLI inside cmux's own bundle. `CMUX_BUNDLED_CLI_PATH` is exported
    /// into every surface, so a deck launched from one inherits the right
    /// path; the bundle location is the fallback for a deck launched from
    /// Finder, which is the ordinary case.
    public static let bundledPath = "/Applications/cmux.app/Contents/Resources/bin/cmux"

    private let executable: String
    private let timeout: TimeInterval

    public init(executable: String? = nil, timeout: TimeInterval = 5) {
        self.executable = executable
            ?? ProcessInfo.processInfo.environment["CMUX_BUNDLED_CLI_PATH"]
            ?? Self.bundledPath
        self.timeout = timeout
    }

    // ------------------------------------------------------------ inventory
    /// `--id-format both` is required. cmux gives one surface two names, a short
    /// ref (`surface:27`) and a UUID, and exports the UUID into the session's
    /// environment while printing the ref in its inventory (LV32). The hook
    /// reports the UUID pair, so without both forms the live-surface membership
    /// check compares UUIDs to refs and every send is refused as unroutable.
    ///
    /// The flag is global, so it precedes the subcommand. It is a named constant
    /// so a test can assert on it: `inventory()` launches a process, and a
    /// parser fallback that quietly became the only path would bring the defect
    /// back without a test failing.
    static let inventoryArguments = ["--id-format", "both", "tree", "--all"]

    public func inventory() async -> Result<[HostSession], PortFailure> {
        switch await run(Self.inventoryArguments) {
        case .failure(let f): return .failure(f)
        case .success(let text): return .success(Self.parseTree(text))
        }
    }

    /// `cmux tree --all` prints an indented topology. Parsed with a scanner
    /// because the fact that matters, which workspace a surface belongs to, is
    /// carried by order, and refs are workspace-scoped (`--surface` alone fails;
    /// `--workspace` beside it succeeds).
    ///
    /// Both output shapes parse: a cmux without `--id-format` would otherwise
    /// leave an empty inventory and no sends, instead of sends routed by ref
    /// alone. The UUID is an extra name when present.
    static func parseTree(_ text: String) -> [HostSession] {
        var sessions: [HostSession] = []
        var workspace: String?
        var workspaceUUID: String?
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let row = String(line)
            if let ws = capture(row, after: "workspace ", upTo: " ") , ws.hasPrefix("workspace:") {
                workspace = ws
                workspaceUUID = uuid(row, after: "workspace \(ws) ")
                continue
            }
            guard let surface = capture(row, after: "surface ", upTo: " "),
                  surface.hasPrefix("surface:"), let ws = workspace else { continue }
            sessions.append(HostSession(
                address: SessionAddress(workspace: ws, surface: surface),
                title: Self.quoted(row) ?? "",
                isSelected: row.contains("[selected]"),
                workspaceNames: workspaceUUID.map { [$0] } ?? [],
                surfaceNames: uuid(row, after: "surface \(surface) ").map { [$0] } ?? []))
        }
        return sessions
    }

    private static func capture(_ line: String, after: String, upTo: String) -> String? {
        guard let start = line.range(of: after) else { return nil }
        let rest = line[start.upperBound...]
        guard let end = rest.range(of: upTo) else { return String(rest) }
        return String(rest[..<end.lowerBound])
    }

    /// The UUID that follows a ref, or nil when the row carries only the ref.
    ///
    /// Shape-checked rather than taken by position: the next token is a UUID with
    /// `--id-format both`, but `[terminal]` or a quoted title otherwise, and
    /// `[terminal]` must not become a second name for the surface.
    private static func uuid(_ line: String, after prefix: String) -> String? {
        guard let token = capture(line, after: prefix, upTo: " "), isUUID(token) else { return nil }
        return token
    }

    static func isUUID(_ token: String) -> Bool {
        let groups = token.split(separator: "-", omittingEmptySubsequences: false)
        guard groups.map(\.count) == [8, 4, 4, 4, 12] else { return false }
        return token.allSatisfy { $0.isHexDigit || $0 == "-" }
    }

    private static func quoted(_ line: String) -> String? {
        guard let open = line.firstIndex(of: "\""),
              let close = line[line.index(after: open)...].firstIndex(of: "\"") else { return nil }
        return String(line[line.index(after: open)..<close])
    }

    // ------------------------------------------------------------- discovery
    /// Where the process with this pid is running.
    ///
    /// This is the join that finds sessions nobody told the deck about.
    /// `claude agents --json` lists every session and its pid without a hook;
    /// cmux exports `CMUX_CLAUDE_PID` and `CMUX_SURFACE_ID` into each surface's
    /// environment, so the session's own process knows where it lives. Inference
    /// (tty matching, `lsof`, process-tree walks) failed on real machines, where
    /// ttys are duplicated across live surfaces.
    ///
    /// The environment is read with `ps eww`, the same-user-only read macOS
    /// allows. A pid the deck cannot inspect yields nil, and a lane with no
    /// address can be watched but not spoken to.
    public func address(ofPID pid: Int) async -> SessionAddress? {
        guard let environment = processEnvironment(pid) else { return nil }
        guard let surface = environment["CMUX_SURFACE_ID"],
              let workspace = environment["CMUX_WORKSPACE_ID"] else { return nil }
        // The env holds UUIDs and the CLI's inventory answers in short refs, so
        // resolve the address through the inventory rather than trusting it
        // (as `DeckRuntime.drain` does); comparing the two with `==` never matches.
        guard case .success(let sessions) = await inventory() else { return nil }
        // Both halves or nothing. The non-failable initialiser takes two
        // non-optional strings, so the emptiness check is explicit.
        guard !workspace.isEmpty, !surface.isEmpty else { return nil }
        let reported = SessionAddress(workspace: workspace, surface: surface)
        return sessions.first { $0.identifies(reported) }?.address
    }

    /// A process's environment, or nil when it cannot be read.
    private func processEnvironment(_ pid: Int) -> [String: String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["eww", String(pid)]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        var found: [String: String] = [:]
        for token in String(decoding: data, as: UTF8.self).split(separator: " ") {
            guard let split = token.firstIndex(of: "="), token.hasPrefix("CMUX_") else { continue }
            found[String(token[..<split])] =
                String(token[token.index(after: split)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return found.isEmpty ? nil : found
    }

    // ----------------------------------------------------------------- read
    public func read(_ address: SessionAddress, lines: Int) async -> Result<String, PortFailure> {
        await run(["read-screen", "--workspace", address.workspace,
                   "--surface", address.surface, "--lines", String(lines)])
    }

    // ---------------------------------------------------------------- write
    public func send(_ text: String, to address: SessionAddress) async -> SendOutcome {
        // The text is an argument, never interpolated into a script. LV26: a
        // title containing `" & (do shell script "echo PWNED") & "` executed.
        // Here there is no shell and no script; `Process` takes an argv array.
        outcome(await run(["send", "--workspace", address.workspace,
                           "--surface", address.surface, "--", text]))
    }

    public func sendKey(_ key: String, to address: SessionAddress) async -> SendOutcome {
        outcome(await run(["send-key", "--workspace", address.workspace,
                           "--surface", address.surface, "--", key]))
    }

    private func outcome(_ result: Result<String, PortFailure>) -> SendOutcome {
        switch result {
        case .success: return .sent
        case .failure(.unavailable(let why)): return .unavailable(why)
        case .failure(.refused(let why)): return .unavailable(why)
        case .failure(.malformed(let why)): return .failed(why)
        }
    }

    // ------------------------------------------------------------------ CLI
    /// One process, one answer, with a deadline. Stdout and stderr are drained
    /// concurrently (draining one to EOF first deadlocks when the child fills
    /// the other pipe). See `BoundedProcess`.
    private func run(_ arguments: [String]) async -> Result<String, PortFailure> {
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            return .failure(.unavailable("cmux is not installed at \(executable)"))
        }
        let result = await BoundedProcess.run(executable: executable, arguments: arguments,
                                              timeout: timeout)
        let output: BoundedProcess.Output
        switch result {
        case .success(let o): output = o
        case .failure(let f): return .failure(f)
        }
        let stdout = output.stdout
        let error = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard output.status == 0 else {
            // The socket refusal is a first-class state, not a failure: a process
            // cmux did not spawn (a deck launched from Finder) gets "Failed to
            // write to socket", because cmux's default access mode admits only
            // its own descendants. The deck must say that, with the setting that
            // changes it, rather than show a dead control.
            // Match cmux's own sentence, not the word "socket": any stderr
            // mentioning a socket would otherwise be diagnosed as a refusal.
            //
            // Every message keeps cmux's own words appended: the narrow enum that
            // reaches the frame exists to keep paths out of an encoded frame, but
            // the log needs the original text.
            let detail = error.isEmpty ? "cmux exited \(output.status)" : error
            if error.contains("Failed to write to socket") {
                return .failure(.unavailable(
                    "cmux is not accepting connections from the deck — set its socket access to "
                        + "allow local processes (cmux said: \(detail))"))
            }
            if error.contains("not found") {
                return .failure(.refused("that session is no longer open (cmux said: \(detail))"))
            }
            return .failure(.malformed("\(arguments.first ?? "cmux") failed: \(detail)"))
        }
        return .success(stdout)
    }
}
