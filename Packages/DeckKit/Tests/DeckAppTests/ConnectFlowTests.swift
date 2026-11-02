//
//  ConnectFlowTests.swift · Tests/DeckAppTests
//
//  Connecting the deck, driven end to end against a real file.
//
//  `SettingsMerge` was fully implemented and heavily tested for the whole life
//  of this project and had ZERO production callers. So did `ConfigFile`, and
//  so did the `configRequested`/`configConfirmed` events. Every piece worked;
//  nothing was wired to anything; a new user launched the app, read "Start
//  Claude Code and its sessions appear here", and waited forever.
//
//  These tests exist to keep that from being true again. They drive the
//  runtime's own `connect`/`disconnect` against a scratch file, which is the
//  seam a user actually presses.
//

import Testing
import Foundation
import DeckCore
import DeckPorts
import DeckAdapters
@testable import DeckApp

@MainActor
struct ConnectFlowTests {

    private func scratch() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("deck-connect-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("settings.json").path
    }

    /// A runtime that believes it is listening, pointed at a disposable file.
    private func runtime(at path: String, port: UInt16 = 8765) -> DeckRuntime {
        let r = DeckRuntime()
        r.markStartedForTesting()
        r.configPath = path
        r.config = ConfigFile(path: path)
        r.setStatusForTesting(.listening(port: port))
        return r
    }

    private func read(_ path: String) -> JSONValue {
        guard let data = FileManager.default.contents(atPath: path) else { return .null }
        return JSONValue.parse(data) ?? .null
    }

    // -------------------------------------------------------- the happy path

    /// A fresh machine connects, and the file it writes is one the deck
    /// recognises afterwards.
    @Test("connecting a fresh machine writes hooks the deck then recognises")
    func aFreshMachineConnects() async {
        let path = scratch()
        let r = runtime(at: path)

        await r.refreshConnection()
        #expect(r.connection == .notConnected, "a bare machine did not report itself unconnected")

        let result = await r.connect(addStatusline: false)
        guard case .success = result else {
            Issue.record("connect failed on a bare machine")
            return
        }
        #expect(SettingsMerge.isInstalled(read(path)), "nothing reached the file")
        #expect(SettingsMerge.installedPort(read(path)) == 8765)
        // Written, but not yet proven — no hook has arrived.
        #expect(r.connection == .waiting(running: 0),
                Comment(rawValue: "reported \(r.connection) rather than waiting for proof"))
    }

    /// **Connecting twice writes once.** The second press has nothing to do,
    /// which is what lets the same control be the repair button.
    @Test("connecting twice is idempotent on disk")
    func connectingTwiceChangesNothing() async {
        let path = scratch()
        let r = runtime(at: path)
        await r.connect(addStatusline: false)
        let first = read(path)

        await r.connect(addStatusline: false)
        #expect(read(path) == first, "a second connect rewrote the file")
    }

    /// A user's existing configuration survives, untouched.
    @Test("connecting keeps everything already in the file")
    func existingSettingsSurvive() async throws {
        let path = scratch()
        try Data(#"{"model":"opus","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"~/bin/audit.sh"}]}]}}"#.utf8)
            .write(to: URL(fileURLWithPath: path))

        let r = runtime(at: path)
        await r.connect(addStatusline: false)

        let after = read(path)
        #expect(after["model"]?.stringValue == "opus", "an unrelated key was lost")
        guard case .array(let entries)? = after["hooks"]?["PreToolUse"] else {
            Issue.record("the hook array is gone")
            return
        }
        #expect(entries.count == 2, "somebody else's hook was replaced rather than kept")
    }

    // ------------------------------------------------------------ the refusal

    /// **The data-loss guard, at the seam a user presses.**
    ///
    /// A settings file that cannot be parsed must never be written over. The
    /// adapter refuses to offer a document; this asserts the runtime honours
    /// that instead of merging into nothing.
    @Test("connecting refuses to write over a file it could not read")
    func anUnreadableFileIsNotOverwritten() async throws {
        let path = scratch()
        let original = #"{"model": "opus", oops"#
        try Data(original.utf8).write(to: URL(fileURLWithPath: path))

        let r = runtime(at: path)
        await r.refreshConnection()
        #expect(!r.connection.isConnectable, "the deck offered to write over an unreadable file")

        let result = await r.connect(addStatusline: false)
        guard case .failure = result else {
            Issue.record("connect wrote over a settings file it could not parse")
            return
        }
        let onDisk = String(decoding: FileManager.default.contents(atPath: path) ?? Data(),
                            as: UTF8.self)
        #expect(onDisk == original, "the user's settings file was modified")
    }

    /// **A file that parses but is not the shape the deck edits.**
    ///
    /// `objectOf`/`arrayOf` coerce anything unexpected to an empty container,
    /// so a `hooks` that is a string would have been silently replaced by the
    /// deck's own entries. Same overwrite the unreadable case refuses, one
    /// level down.
    @Test("connecting refuses a settings file whose shape it does not recognise",
          arguments: [#"{"hooks":"please"}"#,
                      #"{"hooks":{"PreToolUse":{"matcher":"*"}}}"#])
    func aMisshapenFileIsRefused(_ contents: String) async throws {
        let path = scratch()
        try Data(contents.utf8).write(to: URL(fileURLWithPath: path))

        let result = await runtime(at: path).connect(addStatusline: false)
        guard case .failure(let why) = result else {
            Issue.record("connect rewrote a settings file whose shape it does not understand")
            return
        }
        #expect(why.sentence.contains("not recognise"), "the refusal gives no reason")
        let onDisk = String(decoding: FileManager.default.contents(atPath: path) ?? Data(),
                            as: UTF8.self)
        #expect(onDisk == contents, "the user's settings file was modified")
    }

    // ------------------------------------------------------------- repairing

    /// A deck listening somewhere else repairs the config with the same call
    /// that installed it.
    @Test("a deck on a different port repairs the hooks that point elsewhere")
    func portDriftIsRepairedByConnecting() async {
        let path = scratch()
        await runtime(at: path, port: 8765).connect(addStatusline: false)
        #expect(SettingsMerge.installedPort(read(path)) == 8765)

        let moved = runtime(at: path, port: 8766)
        await moved.refreshConnection()
        #expect(moved.connection == .wrongPort(installed: 8765, listening: 8766),
                Comment(rawValue: "reported \(moved.connection)"))

        await moved.connect(addStatusline: false)
        #expect(SettingsMerge.installedPort(read(path)) == 8766, "the repair did not land")
        await moved.refreshConnection()
        #expect(moved.connection == .waiting(running: 0))
    }

    /// **A repair does not inherit the old route's proof.**
    ///
    /// `heardAHook` is what separates "the file was written" from "the
    /// connection works", and it was sticky — cleared only by `disconnect`. So
    /// repairing a drifted port went straight back to Connected on the
    /// strength of a hook that had arrived on the port nothing was listening
    /// on any more.
    @Test("repairing a drifted port waits for proof on the new one")
    func repairDoesNotInheritTheOldProof() async {
        let path = scratch()
        let first = runtime(at: path, port: 8765)
        await first.connect(addStatusline: false)

        // A session speaks on the original route.
        _ = await first.handle(HookEvent(id: EventID("h1"), at: Instant(sinceStart: Millis(0)),
                                         kind: .sessionStart, session: SessionID("alpha"),
                                         cwd: Redacted("/w/alpha"), tool: nil,
                                         toolUseID: nil, held: .absent))
        await first.refreshConnection()
        #expect(first.connection == .connected, "the fixture never proved the connection")

        // The deck comes back on a different port and repairs the hooks.
        first.setStatusForTesting(.listening(port: 8766))
        await first.refreshConnection()
        #expect(first.connection == .wrongPort(installed: 8765, listening: 8766))

        await first.connect(addStatusline: false)
        await first.refreshConnection()
        #expect(first.connection != .connected,
                "the deck claims a connection on a route nothing has ever used")
    }

    /// And a write that does NOT move the route keeps it. Opting into a
    /// statusline on the same port dropped a proven connection back to
    /// waiting, over a change the hook route never saw — the overcorrection
    /// for the bug above.
    @Test("a write that leaves the route alone keeps the proof")
    func anUnrelatedWriteKeepsTheProof() async {
        let path = scratch()
        let r = runtime(at: path)
        await r.connect(addStatusline: false)
        _ = await r.handle(HookEvent(id: EventID("h1"), at: Instant(sinceStart: Millis(0)),
                                     kind: .sessionStart, session: SessionID("alpha"),
                                     cwd: Redacted("/w/alpha"), tool: nil,
                                     toolUseID: nil, held: .absent))
        await r.refreshConnection()
        #expect(r.connection == .connected, "the fixture never proved the connection")

        // Same port, different write: add the statusline.
        await r.connect(addStatusline: true)
        await r.refreshConnection()
        #expect(r.connection == .connected,
                Comment(rawValue: "a statusline write on the same port dropped the connection "
                        + "to \(r.connection)"))
    }

    // ---------------------------------------------------------- disconnecting

    /// Disconnect removes what was added and leaves the rest.
    @Test("disconnecting restores the file it found")
    func disconnectingRestores() async throws {
        let path = scratch()
        let original = #"{"model":"opus"}"#
        try Data(original.utf8).write(to: URL(fileURLWithPath: path))

        let r = runtime(at: path)
        await r.connect(addStatusline: false)
        #expect(SettingsMerge.isInstalled(read(path)))

        await r.disconnect()
        #expect(!SettingsMerge.isInstalled(read(path)), "the deck's hooks survived a disconnect")
        #expect(read(path)["model"]?.stringValue == "opus")
        await r.refreshConnection()
        #expect(r.connection == .notConnected)
    }

    // ------------------------------------------------------------ the offer

    /// The statusline offer is only shown when it would do something. A tick
    /// beside "add a statusline" for somebody who already has one is a control
    /// lying about what pressing the button does.
    @Test("the statusline offer tracks whether the user has one")
    func theStatuslineOfferIsConditional() async throws {
        let bare = scratch()
        let r1 = runtime(at: bare)
        await r1.refreshConnection()
        #expect(r1.hasNoStatusline, "a bare machine is not offered a statusline")

        let existing = scratch()
        try Data(#"{"statusLine":{"type":"command","command":"~/bin/mine.sh"}}"#.utf8)
            .write(to: URL(fileURLWithPath: existing))
        let r2 = runtime(at: existing)
        await r2.refreshConnection()
        #expect(!r2.hasNoStatusline, "somebody with a statusline is offered another one")
    }

    /// And when taken, it writes one — which is the only path by which the
    /// deck ever creates a key the user did not have.
    @Test("the statusline is created only when the offer is accepted")
    func theStatuslineIsOptIn() async {
        let declined = scratch()
        await runtime(at: declined).connect(addStatusline: false)
        #expect(read(declined)["statusLine"] == nil,
                "the deck invented a statusline nobody asked for")

        let accepted = scratch()
        await runtime(at: accepted).connect(addStatusline: true)
        #expect(read(accepted)["statusLine"] != nil, "the accepted offer did nothing")
    }

    // ------------------------------------------------------ two presses at once

    /// **Three surfaces can start a write.**
    ///
    /// The empty state's card, the banner's sheet and the Settings pane all
    /// call `connect`, and it awaits a read before it awaits a write. Two
    /// presses that both read before either writes would both compute the same
    /// diff and both apply it — two writes, two backups, and the second one
    /// backing up the first one's output.
    @Test("a second write while one is in flight is refused, not interleaved")
    func concurrentWritesAreRefused() async {
        let path = scratch()
        let r = runtime(at: path)

        async let first = r.connect(addStatusline: false)
        async let second = r.connect(addStatusline: false)
        let results = await [first, second]

        // **Exactly one**, not at most one.
        //
        // `<= 1` was the first version, and it passed with the guard deleted:
        // two unguarded presses both succeed, which is zero refusals, which is
        // also `<= 1`. The assertion could not fail for the reason it was
        // written. The guard's actual signature is that the second press is
        // TURNED AWAY, so that is what is asserted.
        let refused = results.filter { if case .failure = $0 { return true }; return false }
        #expect(refused.count == 1,
                Comment(rawValue: "\(refused.count) of two simultaneous presses were refused — "
                        + "with none refused, both wrote"))
        #expect(SettingsMerge.isInstalled(read(path)), "neither press connected")
    }

    /// And the write stamp moves, so two writes cannot share a backup path.
    /// It used to be the fleet-poll count, which does not change between two
    /// presses a second apart.
    @Test("successive writes do not share a backup path")
    func writeStampsAreMonotonic() async throws {
        let path = scratch()
        try Data(#"{"model":"opus"}"#.utf8).write(to: URL(fileURLWithPath: path))
        let r = runtime(at: path)

        await r.connect(addStatusline: false)
        await r.disconnect()
        await r.connect(addStatusline: true)

        let siblings = (try? FileManager.default.contentsOfDirectory(
            atPath: (path as NSString).deletingLastPathComponent)) ?? []
        let backups = siblings.filter { $0.hasSuffix(".bak") }
        #expect(backups.count == 3,
                Comment(rawValue: "three writes produced \(backups.count) backups: \(backups)"))
    }

    // -------------------------------------------------- what the preview says

    /// The card shows sentences before it shows JSON, and they come from the
    /// same reconciliation the button will apply.
    @Test("the preview explains itself without writing anything")
    func thePreviewDoesNotWrite() async {
        let path = scratch()
        let r = runtime(at: path)
        let preview = await r.connectionPreview(addStatusline: false)

        #expect(preview?.steps.isEmpty == false, "the preview explains nothing")
        #expect(!FileManager.default.fileExists(atPath: path),
                "previewing what would change changed it")
    }
}
