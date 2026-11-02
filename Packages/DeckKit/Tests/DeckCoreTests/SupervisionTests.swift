//
//  SupervisionTests.swift · Tests/DeckCoreTests
//
//  Cases P1.50–P1.55. Six more that were filed as blocked and were not.
//

import Testing
import DeckCore

struct SupervisionTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// A tap creates nothing; a sustained gesture creates one
    /// session-scoped rule.
    @Test("only a sustained gesture creates a rule, and from the strip it is session-scoped")
    func sustainedGestureOnly() {
        #expect(HoldPolicy.spec.longPress == Millis(600))

        for tap in [Int64(0), 1, 250, 599] {
            let s = Reducer.run([.gesture(tool: "Bash", down: at(0), up: at(tap), origin: .strip)])
            #expect(s.rules.isEmpty, "a \(tap) ms gesture created a rule")
        }
        let held = Reducer.run([.gesture(tool: "Bash", down: at(0), up: at(600), origin: .strip)])
        #expect(held.rules.count == 1)
        #expect(held.rules.first?.scope == .session, "the strip created a durable rule")
        #expect(held.rules.first?.tool == "Bash")

        // The settings window is the only place a durable rule is made.
        let window = Reducer.run([.gesture(tool: "Bash", down: at(0), up: at(700),
                                           origin: .settingsWindow)])
        #expect(window.rules.first?.scope == .durable)
    }

    /// Enumerable and revocable, with the scope shown.
    @Test("every rule the deck creates is listed with its scope, and can be revoked")
    func rulesAreEnumerableAndRevocable() {
        var state = Reducer.run([
            .gesture(tool: "Bash", down: at(0), up: at(700), origin: .strip),
            .gesture(tool: "Read", down: at(1_000), up: at(1_800), origin: .settingsWindow),
        ])
        #expect(state.rules.count == 2)
        #expect(Set(state.rules.map(\.tool)) == ["Bash", "Read"])
        #expect(state.rules.allSatisfy { !$0.id.isEmpty })
        // Scope is shown, not implied — a rule whose scope the user cannot see
        // is a rule they cannot reason about revoking.
        #expect(state.rules.map(\.scope) == [.session, .durable])

        let doomed = state.rules[0].id
        Reducer.reduce(&state, .revokeRule(doomed))
        #expect(state.rules.count == 1)
        #expect(!state.rules.contains { $0.id == doomed })
    }

    /// Supervision loss is visible, and so are its limits.
    @Test("the mast reports a floor of muted rules, never a bare count")
    func supervisionLossIsAFloor() {
        let start = DeckEvent.hook(HookEvent(id: EventID("s"), at: .start, kind: .sessionStart,
                                             session: SessionID("a"), cwd: nil, tool: nil,
                                             toolUseID: nil, held: .absent))
        var state = Reducer.run([start])
        #expect(Projection.frame(from: state, at: at(1)).mutedFloor == 0)

        Reducer.reduce(&state, .gesture(tool: "Bash", down: at(0), up: at(700), origin: .strip))
        let frame = Projection.frame(from: state, at: at(800))
        #expect(frame.mutedFloor == 1)
        // The indicator is a floor and says so. A bare count would be a number
        // the deck cannot back — SG10: it cannot see pre-existing
        // `permissions.allow`, the project layer, or a PATH wrapper's set.
        #expect(frame.mutedIsFloor)

        Reducer.reduce(&state, .gesture(tool: "Read", down: at(1_000), up: at(1_800), origin: .strip))
        #expect(Projection.frame(from: state, at: at(2_000)).mutedFloor == 2)

        // And session rules die with the session.
        Reducer.reduce(&state, .restart(at: at(3_000)))
        #expect(Projection.frame(from: state, at: at(3_001)).mutedFloor == 0)
    }

    /// The relay wraps; it does not replace.
    @Test("install leaves the existing statusline rendering its own output")
    func statuslineIsWrappedNotReplaced() {
        let doc = JSONValue.parse(Corpus.text("settings/existing-statusline.json"))!
        let original = SettingsMerge.originalStatusline(doc)
        #expect(original == "npx ccusage statusline")

        let installed = SettingsMerge.install(into: doc, port: 8765).after
        #expect(SettingsMerge.wrapsOriginal(installed, original: original!),
                "the composed command does not invoke the original verbatim")
        #expect(installed["statusLine"]?["command"]?.stringValue?.contains("127.0.0.1:8765") == true)

        // Uninstall gives it back exactly.
        let removed = SettingsMerge.uninstall(from: installed).after
        #expect(SettingsMerge.originalStatusline(removed) == original)

        // A document with no statusline gets none invented for it.
        let bare = JSONValue.object([:])
        #expect(SettingsMerge.install(into: bare, port: 8765).after["statusLine"] == nil)
    }
}
