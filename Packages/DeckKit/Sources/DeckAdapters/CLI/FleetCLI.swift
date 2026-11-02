//
//  FleetCLI.swift · DeckAdapters/CLI
//
//  `claude agents --json`, run as a process.
//
//  Total by construction: a missing binary, a non-zero exit and unparseable
//  output all produce an empty fleet rather than a throw. A session the deck
//  cannot hear is absent, never synthesised, and the same rule applies to a
//  feed the deck cannot reach.
//
//  Locating `claude`: `/usr/bin/env claude` walks `PATH`, but a GUI app
//  launched from Finder or Xcode gets only the bare system `PATH`
//  (`/usr/bin:/bin:/usr/sbin:/sbin`), which has no `claude` on a normal
//  install:
//
//      env -i PATH=/usr/bin:/bin /usr/bin/env claude agents --json
//      env: claude: No such file or directory
//
//  Because `poll()` is total, that failure looked like an empty fleet, and
//  discovery of sessions that had not fired a hook since launch died
//  silently. So this file tries a short list of well-known install
//  locations, then one bounded login-shell probe (for nvm, asdf, hand-rolled
//  `PATH`s), and finally falls back to the bare-name `env` call. A `claude`
//  that none of these find is reported as an absent fleet, not guessed at.
//  `CmuxHost` (Host/CmuxHost.swift) uses the same absolute-path approach for
//  `cmux`.
//

import Foundation
import DeckCore
import DeckPorts

public struct FleetCLI: FleetPort {
    public let executable: String
    public init(executable: String = "claude") { self.executable = executable }

    /// How long the fleet CLI gets before the deck stops waiting on it.
    ///
    /// This runs on a heartbeat, so a hung `claude agents` would otherwise
    /// wedge one cooperative-pool thread per beat until every `await` in the
    /// app stopped progressing, including ones answering a hook. The
    /// login-shell probe below uses the same deadline and runs at most once.
    static let timeout: TimeInterval = 10

    public func poll() async -> [FleetRow] {
        guard let output = await Self.run(executable, arguments: ["agents", "--json"]),
              let json = JSONValue.parse(output)
        else { return [] }
        return FleetIngest.rows(from: json)
    }

    /// Runs the CLI and returns its stdout, or nil on any failure. `poll`
    /// returns `[]` for every kind of failure (an unreadable fleet is not an
    /// empty one to guess about).
    static func run(_ executable: String, arguments: [String]) async -> String? {
        let result: Result<BoundedProcess.Output, PortFailure>
        if let resolved = await resolve(executable) {
            // A resolved path, or an explicit one from the caller (never
            // probed), is exec'd directly: no shell, no `PATH` lookup.
            result = await BoundedProcess.run(executable: resolved, arguments: arguments,
                                              timeout: timeout)
        } else {
            // Last rung: nothing matched a well-known location and the
            // login-shell probe came up empty. `env` still finds `claude` on
            // a launch that inherits a usable `PATH` (a terminal, or cmux);
            // otherwise the empty fleet that results is the intended
            // "absent, not guessed" outcome.
            result = await BoundedProcess.run(executable: "/usr/bin/env",
                                              arguments: [executable] + arguments, timeout: timeout)
        }
        guard case .success(let output) = result, output.status == 0 else { return nil }
        return output.stdout
    }

    // ------------------------------------------------------------- resolve

    /// A path to exec verbatim, or nil to fall back to the bare-name `env`
    /// call in `run`.
    ///
    /// An explicit path (one containing `/`) is a decision made outside this
    /// file, such as a test fixture, and is used exactly as given: no
    /// probing, no existence check, no normalisation. A relative path would
    /// exec against the app's working directory; the caller owns that.
    /// Everything past that point answers the question a bare name like
    /// `"claude"` cannot answer once there is no shell `PATH` to walk.
    static func resolve(_ executable: String) async -> String? {
        if executable.contains("/") { return executable }
        return await resolvedExecutables.value(for: executable) { await probe(executable) }
    }

    /// Where `claude` actually gets installed, checked in order; only if none
    /// hit, one login shell is asked where it thinks `claude` is.
    static func probe(_ name: String) async -> String? {
        // The list and shell probe answer one question, "where is
        // `claude`", so any other bare name goes straight to the `env` rung.
        // Without this guard `FleetCLI(executable: "claude-beta")` would
        // silently exec a different program than it was asked for.
        guard name == "claude" else { return nil }
        if let found = pick(from: candidates(home: NSHomeDirectory()),
                             isExecutable: FileManager.default.isExecutableFile(atPath:)) {
            return found
        }
        // Login-shell rung, for nvm, asdf and other setups that put `claude`
        // only on a login shell's `PATH`. `-lic` (interactive + login) is
        // needed because it sources `~/.zshrc`, where those installers put
        // their hooks; plain `-l` does not. An interactive rc file may print
        // noise (motd, banner) first, so only the LAST non-empty stdout line
        // is read. Two backstops reject a misbehaving shell: the line must
        // start with `/`, and the path must be executable on disk. There is
        // no TTY, so a shell that hangs or fails yields a bad last line and
        // falls through to nil (the `env` rung). Bounded by `timeout` and
        // memoised below, so a hung shell costs one wait, not one per beat.
        let probed = await BoundedProcess.run(executable: "/bin/zsh",
                                              arguments: ["-lic", "command -v claude"],
                                              timeout: timeout)
        guard case .success(let output) = probed, output.status == 0 else { return nil }
        let path = output.stdout
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last(where: { !$0.isEmpty }) ?? ""
        guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// The well-known places `claude` gets installed, most-specific first.
    /// Pure and home-parameterised so a test can assert on the order without
    /// touching the real filesystem or the real `$HOME`.
    static func candidates(home: String) -> [String] {
        [
            home + "/.claude/local/claude", // Claude Code's own local install
            home + "/.local/bin/claude",    // the native installer
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            // The CLI cmux bundles, beside the `cmux` binary `CmuxHost`
            // hardcodes; derived from that constant so the paths cannot drift.
            (CmuxHost.bundledPath as NSString).deletingLastPathComponent + "/claude",
        ]
    }

    /// The first candidate the predicate accepts, or nil. Pure — the
    /// filesystem check is injected, so `pick` itself needs no disk to test.
    static func pick(from candidates: [String], isExecutable: (String) -> Bool) -> String? {
        candidates.first(where: isExecutable)
    }

    /// Resolving `claude`'s path can cost a filesystem walk and a
    /// login-shell spawn, so it is done once per process, not per heartbeat.
    /// A miss is cached too: a `claude` installed after launch is found at
    /// the next launch. Re-probing on nil would respawn a login shell every
    /// five seconds on machines with no `claude`.
    private static let resolvedExecutables = ResolvedExecutableCache()
}

/// A cache of one in-flight or completed resolution per bare command name.
///
/// An actor rather than a plain dictionary, defensively: nothing in
/// `FleetCLI`'s contract forbids concurrent `poll()`s, even though today's
/// only caller (`DeckRuntime`) awaits each poll before the next. Storing the
/// `Task` itself means a second caller arriving mid-probe awaits the same
/// task instead of starting another.
fileprivate actor ResolvedExecutableCache {
    private var tasks: [String: Task<String?, Never>] = [:]

    func value(for name: String, resolve: @escaping @Sendable () async -> String?) async -> String? {
        if let existing = tasks[name] { return await existing.value }
        let task = Task { await resolve() }
        tasks[name] = task
        return await task.value
    }
}
