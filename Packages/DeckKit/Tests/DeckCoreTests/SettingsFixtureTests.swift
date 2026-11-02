//
//  SettingsFixtureTests.swift · Tests/DeckCoreTests
//
//  The settings files this repo already had, run through the code that edits
//  settings files.
//
//  `Fixtures/settings` has held four recorded documents for the whole life of
//  this feature — a bare machine, a machine with foreign hooks, one with a
//  statusline, and one with the deck already installed — and nothing in the
//  connect path ever read them. Five rounds of adversarial review argued about
//  invented strings instead, and every one of them missed what one run of
//  these found in a second:
//
//    already-installed: isInstalled=true  installedPort=nil
//
//  The deck reported "Not connected yet" over a working installation, because
//  the recorded hook — `curl -s -X POST http://127.0.0.1:8765/hook` — carries
//  no query, and the rule written to keep the deck from claiming a STRANGER's
//  hook was being applied to one the deck had signed itself.
//

import Testing
import Foundation
import DeckCore

struct SettingsFixtureTests {

    private static let port = 8765

    private func fixture(_ name: String) throws -> JSONValue {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/settings/\(name).json")
        return try #require(JSONValue.parse(Data(contentsOf: url)))
    }

    /// **The one that was broken.** A signed hook is readable whatever shape
    /// its command is in, because the deck wrote it and the marker says so.
    @Test("an installed deck reads its own port back")
    func anInstalledDeckKnowsItsPort() throws {
        let document = try fixture("already-installed")
        #expect(SettingsMerge.isInstalled(document))
        #expect(SettingsMerge.installedPort(document) == Self.port,
                Comment(rawValue: "read \(SettingsMerge.installedPort(document).map(String.init) ?? "nothing")"
                        + " — the deck reports itself unconnected over a working install"))
    }

    /// And that reading is what the whole connection state hangs on.
    @Test("an installed deck does not report itself unconnected")
    func anInstalledDeckIsNotReportedUnconnected() throws {
        let state = Connection.decide(document: .present,
                                      listeningOn: Self.port, bindFailed: false,
                                      installedPort: SettingsMerge.installedPort(
                                        try fixture("already-installed")),
                                      attemptedPort: Self.port,
                                      lanesSeen: 0, hooksHeard: false,
                                      candidatesSeen: 0)
        #expect(state != .notConnected,
                Comment(rawValue: "a connected machine is told to connect: \(state.title)"))
    }

    // --------------------------------------------- the Claude Code rewrite

    /// **The second real machine that read as unconnected.** Recorded from a
    /// real machine: Claude Code saved a model default to `settings.json`
    /// and re-serialised the file, dropping every key outside its schema —
    /// the deck's `x-openagentdeck` marker, the entry-level `timeout`, and
    /// the statusline's `x-openagentdeck-original`. The hooks kept working
    /// (their commands are untouched), a session was posting live, and the
    /// banner said "Not connected yet". Marker-only identification cannot
    /// survive sharing a file with a writer that strips markers, so an entry
    /// whose commands are byte-identical to the deck's own writing counts as
    /// the deck's.
    @Test("a marker-stripped installation still reads its port back")
    func aStrippedInstallIsStillRecognised() throws {
        let document = try fixture("marker-stripped")
        #expect(SettingsMerge.isInstalled(document))
        #expect(SettingsMerge.installedPort(document) == Self.port,
                Comment(rawValue: "read \(SettingsMerge.installedPort(document).map(String.init) ?? "nothing")"
                        + " — a Claude Code save disconnects the deck's display"))
    }

    /// With the port read back, the machine reports `connected`, not a state
    /// that asks the user to fix anything — nothing observable is broken.
    @Test("a marker-stripped machine with live hooks reads as connected")
    func aStrippedMachineIsConnected() throws {
        let state = Connection.decide(document: .present,
                                      listeningOn: Self.port, bindFailed: false,
                                      installedPort: SettingsMerge.installedPort(
                                        try fixture("marker-stripped")),
                                      attemptedPort: Self.port,
                                      lanesSeen: 1, hooksHeard: true,
                                      candidatesSeen: 0)
        #expect(state == .connected,
                Comment(rawValue: "a working machine is asked to fix itself: \(state.title)"))
    }

    /// The stripped entries are IDENTIFIED, not merely surfaced as a question:
    /// an entry that is byte-for-byte the deck's own writing has nothing to
    /// ask a person about.
    @Test("the deck's own stripped hooks are not offered for adoption")
    func strippedHooksAreNotCandidates() throws {
        let document = try fixture("marker-stripped")
        #expect(SettingsMerge.reconcile(document, port: Self.port).candidates.isEmpty,
                "the deck asks permission to adopt its own hook")
    }

    /// **Reconnecting must not wrap the wrap.** The stripped statusline lost
    /// its marker, so it used to read as the user's own command — and the
    /// reconcile would compose a relay around a relay, nesting one more on
    /// every Claude Code save. Recognised by equality with its writer, the
    /// stripped relay needs no work at all, so it gets none.
    @Test("reconnecting a stripped file does not nest the statusline relay")
    func reconnectingDoesNotDoubleWrap() throws {
        let document = try fixture("marker-stripped")
        let after = SettingsMerge.reconcile(document, port: Self.port).diff.after

        let composed = try #require(after["statusLine"]?["command"]?.stringValue)
        #expect(composed == document["statusLine"]?["command"]?.stringValue,
                "a relay that was already right was rewritten")
        #expect(composed.components(separatedBy: "mktemp").count == 2,
                "the relay is nested inside itself")
        #expect(SettingsMerge.wrapsOriginal(after, original: "sh ~/.claude/statusline-command.sh"),
                "the user's statusline stopped rendering")
    }

    /// Disconnecting a stripped file still removes the deck entirely — a
    /// marker-stripped hook left behind would post to a dead port forever —
    /// and gives the user back the statusline the relay was carrying.
    @Test("disconnecting a stripped file leaves no trace of the deck")
    func disconnectingAStrippedFileRemovesTheDeck() throws {
        let document = try fixture("marker-stripped")
        let restored = SettingsMerge.uninstall(from: document).after

        #expect(restored["hooks"] == nil, "the stripped hooks survived the disconnect")
        #expect(restored["statusLine"]?["command"]?.stringValue
                == "sh ~/.claude/statusline-command.sh",
                "the user's statusline did not come back out of the relay")
        #expect(restored["model"] == document["model"], "a key the deck never owned moved")
    }

    /// Every recorded document converges, and converges to a fixed point.
    @Test("every recorded settings file converges", arguments: [
        "bare", "foreign-hooks", "existing-statusline", "already-installed",
        "marker-stripped",
    ])
    func everyFixtureConverges(_ name: String) throws {
        let document = try fixture(name)
        let once = SettingsMerge.reconcile(document, port: Self.port).diff.after
        #expect(SettingsMerge.isInstalled(once), "connecting left \(name) unconnected")
        #expect(SettingsMerge.installedPort(once) == Self.port)

        let twice = SettingsMerge.reconcile(once, port: Self.port)
        #expect(twice.isNoOp,
                Comment(rawValue: "\(name) still wants work on a second pass: \(twice.steps)"))
    }

    /// Nothing else in the file moves. These are somebody's real settings.
    @Test("connecting preserves everything it did not come for", arguments: [
        "foreign-hooks", "existing-statusline", "already-installed", "marker-stripped",
    ])
    func nothingElseIsDisturbed(_ name: String) throws {
        let document = try fixture(name)
        let after = SettingsMerge.reconcile(document, port: Self.port).diff.after

        guard case .object(let before) = document, case .object(let result) = after else {
            Issue.record("a fixture is not an object")
            return
        }
        for (key, value) in before where key != "hooks" && key != "statusLine" {
            #expect(result[key] == value,
                    Comment(rawValue: "\(name) lost or changed \(key)"))
        }
    }

    /// A foreign hook is neither adopted nor disturbed — and is not even
    /// offered for adoption, because it does not mention the deck's route.
    @Test("foreign hooks survive and are not mistaken for the deck's")
    func foreignHooksAreUntouched() throws {
        let document = try fixture("foreign-hooks")
        let result = SettingsMerge.reconcile(document, port: Self.port)

        #expect(result.candidates.isEmpty,
                Comment(rawValue: "offered to adopt somebody else's hooks: \(result.candidates)"))
        guard case .array(let after)? = result.diff.after["hooks"]?["PreToolUse"],
              case .array(let before)? = document["hooks"]?["PreToolUse"] else {
            Issue.record("the hook arrays are gone")
            return
        }
        for entry in before {
            #expect(after.contains(entry), "a foreign hook was rewritten")
        }
        // SessionStart is now an observer event the deck manages too — so
        // their SessionStart hook survives as a SIBLING, exactly like the
        // PreToolUse one above, with the deck's own observer entry added
        // alongside it rather than the foreign entry being replaced.
        guard case .array(let sessionStartAfter)? = result.diff.after["hooks"]?["SessionStart"],
              case .array(let sessionStartBefore)? = document["hooks"]?["SessionStart"] else {
            Issue.record("the SessionStart hook array is gone")
            return
        }
        for entry in sessionStartBefore {
            #expect(sessionStartAfter.contains(entry), "a foreign SessionStart hook was rewritten")
        }
        #expect(sessionStartAfter.count == sessionStartBefore.count + 1,
                "the deck did not add its own SessionStart hook alongside the foreign one")
    }

    /// An existing statusline keeps rendering, verbatim.
    @Test("an existing statusline is wrapped and kept")
    func anExistingStatuslineIsKept() throws {
        let document = try fixture("existing-statusline")
        let original = try #require(document["statusLine"]?["command"]?.stringValue)
        let after = SettingsMerge.reconcile(document, port: Self.port).diff.after

        #expect(SettingsMerge.wrapsOriginal(after, original: original),
                "the user's statusline stopped rendering")
        #expect(after["statusLine"]?[SettingsMerge.original]?.stringValue == original,
                "the original was not kept, so disconnecting cannot restore it")
    }

    /// And disconnecting puts each of them back the way it was found.
    @Test("disconnecting restores every recorded file", arguments: [
        "foreign-hooks", "existing-statusline",
    ])
    func disconnectingRestores(_ name: String) throws {
        let document = try fixture(name)
        let connected = SettingsMerge.reconcile(document, port: Self.port).diff.after
        let restored = SettingsMerge.uninstall(from: connected).after
        #expect(restored == document,
                Comment(rawValue: "\(name) did not come back as it was found"))
    }
}
