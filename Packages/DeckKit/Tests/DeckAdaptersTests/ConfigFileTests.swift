//
//  ConfigFileTests.swift · Tests/DeckAdaptersTests
//
//  The write path, exercised against a real temporary directory — the half
//  the atomic-write rule could not reach while everything was a plan.
//

import Testing
import Foundation
import DeckAdapters
import DeckPorts
import DeckCore

struct ConfigFileTests {

    private func scratch() -> String {
        let dir = NSTemporaryDirectory() + "deck-test-\(UInt64.random(in: 0 ..< .max))"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir + "/settings.json"
    }

    /// The atomic-write rule's live half: a real backup, a real temp, a real rename.
    @Test("applying a plan backs up the original and lands the new document atomically")
    func planExecutesAndBacksUp() async throws {
        let target = scratch()
        try Data(#"{"model":"claude-opus-5"}"#.utf8).write(to: URL(fileURLWithPath: target))

        let config = ConfigFile(path: target)
        let read = await config.read()
        #expect(read == .present(.object(["model": .string("claude-opus-5")])),
                "a readable file did not come back as present")
        let diff = SettingsMerge.install(into: read.document ?? .null, port: 8765)
        let plan = WritePlan.plan(diff, target: target, stamp: 1)
        #expect(WritePlan.violations(plan, target: target).isEmpty)

        try await config.apply(plan)

        let after = await config.read().document ?? .null
        #expect(SettingsMerge.isInstalled(after))
        #expect(after["model"]?.stringValue == "claude-opus-5", "a pre-existing key was lost")
        #expect(FileManager.default.fileExists(atPath: "\(target).1.bak"), "no backup was retained")
        // The temp is gone: a rename moves it, it does not copy it.
        #expect(!FileManager.default.fileExists(atPath: "\(target).1.tmp"))
    }

    /// A boundary that trusts its caller stops being one after a refactor.
    @Test("a truncating write is refused at the boundary as well as in the plan")
    func truncatingWriteIsRefused() async {
        let target = scratch()
        let config = ConfigFile(path: target)
        await #expect(throws: PortFailure.self) {
            try await config.apply([.truncateAndWrite(path: target, contents: "{}")])
        }
    }

    /// Installing onto a machine that has never configured Claude Code is the
    /// commonest case, and a missing original is not a failure to back up.
    @Test("a bare machine installs without a backup and without an error")
    func bareMachineInstalls() async throws {
        let target = scratch()
        let config = ConfigFile(path: target)
        let diff = SettingsMerge.install(into: .object([:]), port: 8765)
        try await config.apply(WritePlan.plan(diff, target: target, stamp: 2))
        #expect(SettingsMerge.isInstalled(await config.read().document ?? .null))
    }

    // ------------------------------------------------- absent is not unreadable

    /// **The data-loss guard.**
    ///
    /// A settings file the deck cannot parse used to read back as an EMPTY
    /// document, identical to no file at all. Merging into that and writing it
    /// back replaces everything the user had with a document containing only
    /// the deck's own hooks. The backup preserves the bytes — silently, in a
    /// file they have no reason to look for.
    @Test("a settings file that cannot be parsed is refused, not treated as empty")
    func anUnparseableFileIsRefused() async throws {
        let target = scratch()
        try Data(#"{"model": "opus", oops"#.utf8).write(to: URL(fileURLWithPath: target))

        let read = await ConfigFile(path: target).read()
        guard case .unreadable(let why) = read else {
            Issue.record("an unparseable file was not refused; connecting would overwrite settings")
            return
        }
        #expect(!why.isEmpty, "the refusal gives no reason")
        #expect(read.document == nil, "an unreadable file offered a document to merge into")
    }

    /// A file that is not there is a fresh machine, which is the commonest
    /// install there is — and must stay installable.
    @Test("a missing file is absent, and absent is installable")
    func aMissingFileIsAbsent() async {
        let read = await ConfigFile(path: scratch()).read()
        #expect(read == .absent)
        #expect(read.document == .object([:]), "a fresh machine has nothing to merge into")
    }

    /// `touch ~/.claude/settings.json` is a thing people do. An empty file is
    /// not a corrupt one, and refusing it would refuse a safe install.
    @Test("an empty file is absent rather than broken")
    func anEmptyFileIsNotCorrupt() async throws {
        let target = scratch()
        try Data("   \n".utf8).write(to: URL(fileURLWithPath: target))
        #expect(await ConfigFile(path: target).read() == .absent)
    }
}

/// The density of the panel the deck was designed for, against an EDID
/// that lies about it.
///
/// Measured on the real hardware: an HSD088IPW1-A reports 677 × 169 mm, which
/// would be a 26.6-inch-wide panel. It is 8.8 inches. The derived 72 points per
/// inch lands inside the sanity band — exactly what a large TV would report —
/// so nothing caught it, and the deck would have shifted its type ten steps
/// down on the one display it exists for.
struct DesignPanelDensityTests {
}
