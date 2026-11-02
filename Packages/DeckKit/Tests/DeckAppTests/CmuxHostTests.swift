//
//  CmuxHostTests.swift · Tests/DeckAppTests
//
//  The parser is checked against a real cmux tree —
//  `fixtures/live/LV28-cmux-host/tree.txt`, 11 workspaces and 15 surfaces with
//  four workspaces holding more than one tab — rather than against a tidy
//  example, because the shape that broke every earlier design was the shape a
//  real machine has.
//

import Testing
import Foundation
import DeckCore
import DeckPorts
@testable import DeckAdapters

struct CmuxHostTests {

    /// The recordings, as resources of this target.
    private var fixtures: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures")
    }

    private func realTree() -> String {
        (try? String(contentsOf: fixtures
            .appendingPathComponent("live/LV28-cmux-host/tree.txt"), encoding: .utf8)) ?? ""
    }

    /// A real topology parses, and every surface keeps the
    /// workspace it belongs to. The pairing is the whole point: cmux's short
    /// refs are workspace-scoped, so a surface without its workspace is a
    /// surface the deck cannot address (measured — `--surface` alone fails).
    @Test("the real tree parses into addressable sessions")
    func realTreeParses() {
        let text = realTree()
        #expect(!text.isEmpty, "the LV28 fixture is missing — the parser has no real input")
        let sessions = CmuxHost.parseTree(text)

        #expect(sessions.count >= 14,
                Comment(rawValue: "parsed \(sessions.count) surfaces from a tree that recorded 15"))
        #expect(sessions.allSatisfy { $0.address.workspace.hasPrefix("workspace:") },
                "a surface lost its workspace, and an unpaired surface is unaddressable")
        #expect(sessions.allSatisfy { $0.address.surface.hasPrefix("surface:") })

        // Four workspaces held more than one tab on the day this was recorded.
        // That is the case every earlier design got wrong, so it is the case
        // the parser is pinned to.
        let byWorkspace = Dictionary(grouping: sessions, by: { $0.address.workspace })
        let multiTab = byWorkspace.filter { $0.value.count > 1 }
        #expect(multiTab.count == 4,
                Comment(rawValue: "expected 4 multi-tab workspaces, parsed \(multiTab.count)"))

        // Every address is unique: two surfaces sharing an address would be
        // two sessions the deck could not tell apart.
        #expect(Set(sessions.map(\.address)).count == sessions.count)
    }

    /// Titles survive, because users navigate by them. cmux shows
    /// each session's self-chosen name, which is richer identity than the deck
    /// has ever had from a hook.
    @Test("session titles are carried through")
    func titles() {
        let sessions = CmuxHost.parseTree(realTree())
        let titled = sessions.filter { !$0.title.isEmpty }
        #expect(titled.count >= sessions.count - 1,
                Comment(rawValue: "only \(titled.count) of \(sessions.count) surfaces kept a title"))
        #expect(sessions.contains { $0.isSelected }, "no surface was marked selected")
    }

    /// A missing cmux is `unavailable` with a reason, never a crash
    /// and never a silent nothing. The deck has to be able to say why a
    /// control is dark.
    @Test("a missing cmux reports unavailable rather than failing mute")
    func missingCLI() async {
        let host = CmuxHost(executable: "/nonexistent/cmux")
        let address = SessionAddress(workspace: "workspace:1", surface: "surface:1")

        switch await host.inventory() {
        case .success: Issue.record("a missing CLI reported success")
        case .failure(let f):
            guard case .unavailable(let why) = f else {
                Issue.record("expected .unavailable, got \(f)"); return
            }
            #expect(why.contains("not installed"))
        }

        let sent = await host.send("hello", to: address)
        guard case .unavailable = sent else {
            Issue.record("send reported \(sent) with no CLI present"); return
        }
        let keyed = await host.sendKey("escape", to: address)
        guard case .unavailable = keyed else {
            Issue.record("sendKey reported \(keyed) with no CLI present"); return
        }
    }

    /// The address is the SURFACE. `CMUX_TAB_ID` equals
    /// `CMUX_WORKSPACE_ID` even in a two-tab workspace (measured,
    /// `LV30-multitab`), so a design keyed on "tab" would collapse both tabs
    /// of a workspace into one target. This asserts the type cannot express
    /// that mistake: two sessions in one workspace differ, and they differ in
    /// the surface.
    @Test("two tabs of one workspace are distinct addresses")
    func tabsAreDistinct() {
        let sessions = CmuxHost.parseTree(realTree())
        let byWorkspace = Dictionary(grouping: sessions, by: { $0.address.workspace })
        guard let pair = byWorkspace.first(where: { $0.value.count > 1 })?.value else {
            Issue.record("the fixture has no multi-tab workspace to check"); return
        }
        #expect(pair[0].address != pair[1].address)
        #expect(pair[0].address.workspace == pair[1].address.workspace,
                "two tabs of one workspace should share a workspace")
        #expect(pair[0].address.surface != pair[1].address.surface,
                "two tabs of one workspace must differ in their SURFACE — the only per-tab identity there is")
    }

    // ------------------------------------------------- the host's two names
    //
    // cmux calls one surface both `surface:27` and a
    // UUID, and it exports the UUID into the session's environment while
    // printing the ref in its inventory. The deck learns the address from the
    // hook — the session's own environment — and checks membership against
    // the inventory, so the two halves of the live-surface rule spoke
    // different languages and the check failed closed on every lane the deck
    // has ever had. The panel said "the deck has no route to this session"
    // and it was the deck's own doing, for the second time in this program's
    // life.

    private func bothTree() -> String {
        (try? String(contentsOf: fixtures
            .appendingPathComponent("live/LV32-host-identity/tree-both.txt"), encoding: .utf8)) ?? ""
    }

    /// `--id-format both` parses, and the UUID is kept as a second name
    /// rather than swallowing the ref. Routing stays on the refs: one naming
    /// system on the wire.
    @Test("the both-ids tree keeps the ref for routing and the UUID for matching")
    func bothIdsParse() {
        let text = bothTree()
        #expect(!text.isEmpty, "the LV32 fixture is missing — the parser has no real input")
        let sessions = CmuxHost.parseTree(text)

        #expect(sessions.count >= 14,
                Comment(rawValue: "parsed \(sessions.count) surfaces from the both-ids tree"))
        #expect(sessions.allSatisfy { $0.address.surface.hasPrefix("surface:") },
                "a UUID displaced the ref the deck routes by")
        #expect(sessions.allSatisfy { $0.address.workspace.hasPrefix("workspace:") })

        let withUUID = sessions.filter { $0.surfaceNames.count > 1 }
        #expect(withUUID.count == sessions.count,
                Comment(rawValue: "only \(withUUID.count) of \(sessions.count) surfaces learned their UUID"))
        #expect(sessions.allSatisfy { $0.workspaceNames.count > 1 },
                "a workspace UUID was dropped, so a hook's workspace half cannot match")

        // The second name is a UUID and not the next token that happened to sit
        // there. `[terminal]` follows the ref in the ref-only shape, and a
        // parser trusting position would hand that to the router as an identity.
        let extras = sessions.flatMap { $0.surfaceNames.subtracting([$0.address.surface]) }
        #expect(extras.allSatisfy(CmuxHost.isUUID),
                Comment(rawValue: "a non-UUID token became a surface name: \(extras.prefix(3))"))
    }

    /// **The defect, as a test.** An address in the form the HOOK
    /// reports it — the pair of UUIDs out of `CMUX_SURFACE_ID` and
    /// `CMUX_WORKSPACE_ID` — is recognised by the session the inventory
    /// reported in refs. This is the exact comparison `DeckRuntime.drain` used
    /// to make with `==`.
    ///
    /// The UUIDs below are read out of LV32's own rows rather than pasted, so
    /// the test cannot drift from the fixture it is about.
    @Test("a session is found by the UUID pair the hook reports")
    func uuidAddressResolves() {
        let sessions = CmuxHost.parseTree(bothTree())
        guard let session = sessions.first(where: {
            $0.surfaceNames.count > 1 && $0.workspaceNames.count > 1
        }) else {
            Issue.record("no surface in the fixture carries both of its names"); return
        }
        guard let surfaceUUID = session.surfaceNames.first(where: CmuxHost.isUUID),
              let workspaceUUID = session.workspaceNames.first(where: CmuxHost.isUUID) else {
            Issue.record("the fixture's second names are not UUIDs"); return
        }

        let asTheHookReportsIt = SessionAddress(workspace: workspaceUUID, surface: surfaceUUID)
        #expect(session.identifies(asTheHookReportsIt),
                "the host did not recognise its own surface by the name it exports to the session")
        #expect(session.identifies(session.address),
                "the host did not recognise its own surface by the name it printed")
        // What shipped, kept visible: the two names are genuinely different
        // strings, so `==` could never have matched and the failure was total.
        #expect(session.address != asTheHookReportsIt)

        // Case is not identity here — the two forms come from different
        // alphabets, and a fold cannot collide a ref with a UUID.
        #expect(session.identifies(SessionAddress(workspace: workspaceUUID.lowercased(),
                                                  surface: surfaceUUID.lowercased())))
    }

    /// And it must still be SPECIFIC. A matcher that says yes to
    /// anything routes every action to whichever surface answered first, which
    /// is a worse failure than refusing to send: the deck would be typing into
    /// somebody's other session.
    @Test("the host recognises only its own surface")
    func identityIsSpecific() {
        let sessions = CmuxHost.parseTree(bothTree())
        guard sessions.count >= 2 else { Issue.record("need two surfaces"); return }
        let a = sessions[0], b = sessions[1]

        #expect(!a.identifies(b.address), "a surface claimed another surface's address")
        #expect(!b.identifies(a.address))
        // Half a match is not a match: the same workspace, a foreign surface.
        #expect(!a.identifies(SessionAddress(workspace: a.address.workspace,
                                             surface: "surface:99999")))
        #expect(!a.identifies(SessionAddress(workspace: "workspace:99999",
                                             surface: a.address.surface)))
        // A surface that never learned its UUID must not match a UUID.
        let refOnly = HostSession(address: a.address, title: "", isSelected: false)
        #expect(!refOnly.identifies(SessionAddress(
            workspace: "53CC87D4-D5CD-449C-826C-4D496C368C2A",
            surface: "7BB88BAA-6151-4BED-950D-81A33DFA27C6")))
    }

    /// At the parser: a cmux that does not know `--id-format`
    /// still yields a routable inventory. The ref-only tree is LV28's, and the
    /// failure this guards against is worse than the one it replaced — an empty
    /// inventory blocks every send with no address to blame.
    @Test("a ref-only tree still parses, with one name each")
    func refOnlyTreeStillWorks() {
        let sessions = CmuxHost.parseTree(realTree())
        #expect(!sessions.isEmpty, "the ref-only tree stopped parsing")
        #expect(sessions.allSatisfy { $0.surfaceNames == [$0.address.surface] },
                "a ref-only row invented a second name for a surface")
        #expect(sessions.allSatisfy { $0.workspaceNames == [$0.address.workspace] })
        #expect(sessions.allSatisfy { $0.identifies($0.address) },
                "a surface stopped recognising the only name it has")
    }

    /// The deck ASKS for both names. The parser above tolerates a
    /// refs-only tree on purpose, which means a deck that stopped
    /// passing `--id-format both` would still parse, still route by ref, and
    /// still refuse every hook-reported UUID — the original defect, restored,
    /// with every other test in this file green.
    ///
    /// The flag is global, so it must precede the subcommand: `cmux
    /// --id-format both tree --all`. Verified against the real CLI while
    /// recording LV32.
    @Test("the inventory asks cmux for both of its names")
    func inventoryAsksForBothNames() {
        let args = CmuxHost.inventoryArguments
        #expect(args.contains("--id-format") && args.contains("both"),
                Comment(rawValue: "the inventory would be answered in refs alone: \(args)"))
        guard let flag = args.firstIndex(of: "--id-format"),
              let tree = args.firstIndex(of: "tree") else {
            Issue.record(Comment(rawValue: "the inventory no longer asks for a tree: \(args)")); return
        }
        #expect(flag < tree, "the flag is global — after the subcommand cmux does not read it")
        #expect(args.contains("--all"), "the inventory would see only the current window")
    }
}
