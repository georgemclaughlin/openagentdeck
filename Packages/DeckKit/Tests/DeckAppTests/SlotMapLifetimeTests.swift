//
//  SlotMapLifetimeTests.swift · Tests/DeckAppTests
//
//  **The regression guard for the bug that made fleet reordering work
//  exactly once — kept as a SOURCE rule, because the defect lives in a
//  lifetime no value-level test can reach.**
//
//  `SessionOverview.slots` is the fleet's drag slot map: session → the
//  card's current frame in the `"fleet"` coordinate space. It is written
//  from ONE place, a `.onGeometryChange` on every card, and read by
//  `ReorderMath.nearestID`/`.retargetIndex` to decide which neighbour a
//  drag has crossed.
//
//  The shipped defect was a single line in `.onChange(of: editing)`:
//
//      slots = [:]
//
//  excused in its own comment as "harmless either way — every visible card
//  re-populates its own entry on the very next layout pass." That premise
//  is false, and falsifying it is the whole point of this file.
//  `.onGeometryChange` is EDGE-triggered: its action runs when the value it
//  computes CHANGES, not once per layout pass. Emptying the dictionary
//  changes no card's geometry, so nothing re-reports it, and the map stays
//  empty until something independently moves a card. Since the deck
//  disables scrolling while editing and a fleet at rest moves nothing, that
//  meant: forever.
//
//  The consequence was total rather than partial. With no slots
//  `nearestID` has no candidate at all, `retargetIndex` answers nil on
//  every frame, and a drag lifts the card and glues it to the finger while
//  no neighbour ever makes room. It read as "reordering works the first
//  time and then never again" because entering and leaving Edit Layout is
//  what toggles `editing`, and people naturally do that between drags.
//
//  **Measured, not argued.** With the clear removed, live instrumentation
//  over a real session recorded six `editing` toggles — every one of them
//  reporting `slots=10` where each would previously have reported 0 — and
//  255 consecutive drag frames at `slotted=10` with five retargets firing
//  across four different cards. The same instrumentation before the fix
//  recorded 114 consecutive frames at `slotted=0`, every entry absent.
//
//  **Why a source rule and not a behavioural test.** The invariant is
//  "this cache is never emptied," a statement about a `@State` property's
//  LIFETIME. A unit test cannot host a SwiftUI view's state across a
//  `.onChange`, and a UI test could only observe the symptom through a
//  real drag against the window server — slow, and it would fail for many
//  reasons other than this one. The codebase already proves rules by the
//  ABSENCE of a symbol (`PrefsStore`'s own doc comment: the storage rule
//  "stays provable by the absence of the path everywhere else"), and this
//  is that same shape: cheap, exact, and it names the reason in the
//  failure message so whoever trips it does not have to rediscover any of
//  the above.
//
//  Two eviction designs were tried and are recorded here so they are not
//  re-attempted blind:
//
//    1. `slots = [:]` on the `editing` flip — the defect itself.
//    2. `.onDisappear { slots[lane.session] = nil }` per card, meant to
//       prune cards pushed past the `LazyHGrid`'s fold. This made the fleet
//       unreorderable OUTRIGHT, worse than the staleness it targeted:
//       `card(for:)`'s three-way branch changes structural identity when
//       `editing` flips, so every card is rebuilt, and SwiftUI mounts the
//       replacement — which reports its geometry — BEFORE tearing down the
//       original, whose `.onDisappear` then deletes the entry just
//       written. The map emptied at the moment edit mode began.
//
//  Staleness is therefore left alone, deliberately. A stale frame is
//  overwritten the moment its card moves; `nearestID` only ever walks the
//  CURRENT draft order, so an entry for a retired lane is never consulted;
//  and an entry that is merely old still points at a real grid slot. That
//  is a bounded inaccuracy. An empty map is a dead feature.
//

import Testing
import Foundation

struct SlotMapLifetimeTests {

    /// `SessionOverview.swift`, read off disk rather than through a
    /// resource bundle — the same `#filePath` walk `SettingsFixtureTests`
    /// already uses to reach a fixture outside `Bundle.module`.
    private func sessionOverviewSource() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()          // DeckAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // DeckKit
            .appendingPathComponent("Sources/DeckApp/SessionOverview.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Nothing may assign a fresh, empty map over `slots`.
    ///
    /// Matches the assignment with any spacing, and only OUTSIDE a comment
    /// — this file's own header, and `SessionOverview`'s, both quote the
    /// offending line on purpose, and a guard that its own explanation
    /// trips is a guard nobody keeps.
    @Test("nothing empties the fleet's drag slot map — onGeometryChange is edge-triggered and would never refill it")
    func theSlotMapIsNeverCleared() throws {
        let offenders = try sessionOverviewSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .filter { _, line in
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { return false }
                let squashed = code.replacingOccurrences(of: " ", with: "")
                return squashed.contains("slots=[:]") || squashed.contains("slots=[SessionID:CGRect]()")
            }
            .map { "line \($0.offset + 1): \($0.element.trimmingCharacters(in: .whitespaces))" }

        #expect(offenders.isEmpty,
                Comment(rawValue: """
                    The fleet's drag slot map is being emptied — reordering will work \
                    at most once and then stop, with the card lifting and no neighbour \
                    making room. `.onGeometryChange` is EDGE-triggered: clearing this \
                    dictionary changes no card's geometry, so nothing re-reports and it \
                    stays empty. See this file's own header for the measurements. \
                    Offending line(s): \(offenders.joined(separator: "; "))
                    """))
    }

    /// The other half of the same invariant: the map must keep exactly one
    /// writer, so "it is only ever added to" stays checkable by reading one
    /// place rather than auditing the file.
    @Test("the drag slot map still has exactly one writer, so its contents can be reasoned about from one place")
    func theSlotMapHasOneWriter() throws {
        let writes = try sessionOverviewSource()
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                let code = line.trimmingCharacters(in: .whitespaces)
                guard !code.hasPrefix("//"), !code.hasPrefix("///") else { return false }
                return code.replacingOccurrences(of: " ", with: "").contains("slots[lane.session]=")
            }

        #expect(writes.count == 1,
                Comment(rawValue: "expected exactly one writer of the slot map, found \(writes.count)"
                        + " — a second one means its lifetime is no longer readable from a single site,"
                        + " which is what let the clearing bug hide in the first place"))
    }
}
