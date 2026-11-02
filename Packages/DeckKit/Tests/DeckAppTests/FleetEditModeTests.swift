//
//  FleetEditModeTests.swift · Tests/DeckAppTests
//
//  The edit-reorder arc's own DeckApp-side vocabulary, pinned directly:
//  `SessionOverview.draftApplied` (the draft-order projection the `cards`
//  `ForEach` iterates), `SessionOverview.commitOrder` (the drop's own
//  hosted-lanes-only surface derivation), and `DeckRuntime.reorder` (the
//  one-write-per-drop persistence, the `hide`/`setCardColor` shape
//  `PrefsPersistenceTests` already arbiters for its siblings).
//
//  **What this file deliberately does NOT try to test.** The live wiggle
//  motion and a real finger-driven drag are exactly the mechanism the
//  approved prototype's own probes already covered
//  (`WigglePrototype.swift`'s `FINDINGS.md`, scratchpad) — a headless
//  XCTest-style run cannot drive a real `DragGesture` or judge whether a
//  tilt reads as organic, and re-deriving synthetic evidence for a
//  question the prototype already closed empirically would only manufacture
//  a fake. Live feel is a strip judgement, recorded there, not here.
//  `RenderSweepTests` (this same target) is where an editing fleet is
//  proven to RENDER and to hold its layout height — the render-level half
//  this file's own pure/runtime half does not reach.
//

import Testing
import Foundation
import DeckCore
import DeckAdapters
@testable import DeckApp

@MainActor
struct FleetEditModeTests {

    /// A minimal lane — a session id and, optionally, a host surface.
    /// Everything else defaults exactly as `LaneView.init` already does;
    /// nothing below reads state, context, or any other field.
    private func lane(_ id: String, host: String? = "h", isHidden: Bool = false) -> LaneView {
        LaneView(session: SessionID(id), state: .idle, isExpanded: false,
                 contextPercent: nil, sources: [:],
                 host: host.map { HostAddress(workspace: "w", surface: $0) },
                 isHidden: isHidden)
    }

    // --------------------------------------------------------- draftApplied

    @Test("a nil draft is the identity — the ordinary browse order, untouched")
    func nilDraftIsIdentity() {
        let lanes = [lane("a"), lane("b"), lane("c")]
        #expect(SessionOverview.draftApplied(lanes, draft: nil) == lanes)
    }

    @Test("a draft orders its own ids first, in draft order")
    func draftOrdersItsOwnIDsFirst() {
        let a = lane("a"); let b = lane("b"); let c = lane("c")
        let lanes = [a, b, c]
        let result = SessionOverview.draftApplied(lanes, draft: [c.session, a.session])
        #expect(result.map(\.session) == [c.session, a.session, b.session], Comment(rawValue:
                "expected the draft's own two ids first (c, a), then b — the lane the draft " +
                "did not name — appended after; got \(result.map(\.session))"))
    }

    @Test("a lane the draft does not name appends in projection order")
    func unnamedLanesAppendInProjectionOrder() {
        let a = lane("a"); let b = lane("b"); let c = lane("c"); let d = lane("d")
        let lanes = [a, b, c, d]
        let result = SessionOverview.draftApplied(lanes, draft: [b.session])
        #expect(result.map(\.session) == [b.session, a.session, c.session, d.session], Comment(rawValue:
                "a, c, d were not in the draft and should append in their ORIGINAL projection " +
                "order (a, c, d), not the draft's own order or any other; got \(result.map(\.session))"))
    }

    @Test("a draft id absent from the lanes contributes nothing")
    func draftIDAbsentFromLanesIsSkipped() {
        let a = lane("a"); let b = lane("b")
        let result = SessionOverview.draftApplied([a, b], draft: [SessionID("ghost"), b.session])
        #expect(result.map(\.session) == [b.session, a.session], Comment(rawValue:
                "a draft id with no matching lane (a retired-mid-drag session) should be " +
                "skipped, not invent a placeholder or shift the real lanes; got \(result.map(\.session))"))
    }

    @Test("a duplicate id in the draft is applied once, at its first occurrence")
    func duplicateDraftIDAppliesOnce() {
        let a = lane("a"); let b = lane("b")
        let result = SessionOverview.draftApplied([a, b], draft: [a.session, a.session, b.session])
        #expect(result.map(\.session) == [a.session, b.session], Comment(rawValue:
                "a duplicated draft id should place its lane once, not twice; got \(result.map(\.session))"))
    }

    @Test("an empty lane set with a non-empty draft produces nothing, not a crash")
    func emptyLanesWithDraftProducesNothing() {
        #expect(SessionOverview.draftApplied([], draft: [SessionID("ghost")]) == [])
    }

    // ---------------------------------------------------------- commitOrder

    @Test("commit order reads the draft's own hosted lanes' surfaces, in draft order")
    func commitOrderReadsHostedLaneSurfacesInDraftOrder() {
        let a = lane("a", host: "SURF-A")
        let b = lane("b", host: "SURF-B")
        let order = SessionOverview.commitOrder([b.session, a.session], lanes: [a, b])
        #expect(order == ["SURF-B", "SURF-A"])
    }

    @Test("a hostless lane in the draft contributes no surface")
    func hostlessLaneContributesNoSurface() {
        let a = lane("a", host: "SURF-A")
        let hostless = lane("b", host: nil)
        let order = SessionOverview.commitOrder([hostless.session, a.session], lanes: [a, hostless])
        #expect(order == ["SURF-A"], Comment(rawValue:
                "a hostless lane's order cannot persist (DeckPrefs.cardOrder keys on the " +
                "surface) — it should contribute nothing rather than a placeholder or an " +
                "empty string; got \(order)"))
    }

    @Test("a draft id absent from lanes contributes no surface either")
    func commitOrderSkipsUnmatchedDraftIDs() {
        let a = lane("a", host: "SURF-A")
        let order = SessionOverview.commitOrder([SessionID("ghost"), a.session], lanes: [a])
        #expect(order == ["SURF-A"])
    }

    // ---------------------------------------------------------- DeckRuntime.reorder

    @Test("reorder writes the surfaces, in order, exactly once")
    func reorderWritesSurfacesOnce() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let spy = SpyDefaults(suiteName: "spy-\(UUID().uuidString)")!
        runtime.prefsDefaults = spy

        runtime.reorder(["SURF-B", "SURF-A"])

        #expect(spy.writeCount == 1, Comment(rawValue:
                "reorder wrote \(spy.writeCount) times, not exactly once"))
        #expect(runtime.prefs.cardOrder == ["SURF-B", "SURF-A"])
        let onDisk = PrefsStore.load(from: spy)
        #expect(onDisk.cardOrder == ["SURF-B", "SURF-A"],
                "the new order did not reach the throwaway suite's actual bytes")
    }

    @Test("reordering to the identical order writes nothing")
    func reorderNoOpGuardWritesNothing() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.reorder(["SURF-A", "SURF-B"])
        let spy = SpyDefaults(suiteName: "spy-\(UUID().uuidString)")!
        runtime.prefsDefaults = spy

        runtime.reorder(["SURF-A", "SURF-B"])

        #expect(spy.writeCount == 0, Comment(rawValue:
                "an unchanged reorder wrote \(spy.writeCount) time(s) — the `next != state.prefs` " +
                "guard did not hold"))
    }

    @Test("a duplicate surface in the drop dedupes, preserving the first occurrence")
    func reorderDedupesPreservingFirstOccurrence() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let spy = SpyDefaults(suiteName: "spy-\(UUID().uuidString)")!
        runtime.prefsDefaults = spy

        runtime.reorder(["SURF-A", "SURF-B", "SURF-A"])

        #expect(runtime.prefs.cardOrder == ["SURF-A", "SURF-B"], Comment(rawValue:
                "expected the duplicate SURF-A collapsed to its first occurrence; got " +
                "\(runtime.prefs.cardOrder)"))
        #expect(spy.writeCount == 1, "the deduped write should still be exactly one disk write")
    }

    /// A past data-loss defect, pinned: a drop names only the lanes
    /// that were on screen — a collapsed shelf's hidden lanes are not
    /// among them — and a wholesale replace would silently erase every
    /// unnamed surface's entry, breaking `hide`/`unhide`'s promise that
    /// hiding a card does not forget where it goes. `reorder`'s own doc
    /// comment carries the merge rule this asserts: named surfaces first,
    /// every previously-stored unnamed surface after them, prior relative
    /// order intact.
    @Test("a reorder that does not name a stored surface preserves its entry after the named ones")
    func reorderPreservesSurfacesTheDropCouldNotSee() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        // The stored order interleaves two surfaces (H1, H2 — think: on
        // the shelf during the next drag) among the ones about to be
        // rearranged.
        runtime.reorder(["SURF-A", "SURF-H1", "SURF-B", "SURF-H2"])

        // The next drop saw only A and B, and swapped them.
        runtime.reorder(["SURF-B", "SURF-A"])

        #expect(runtime.prefs.cardOrder == ["SURF-B", "SURF-A", "SURF-H1", "SURF-H2"], Comment(rawValue:
                "expected the unnamed surfaces preserved after the named ones, prior relative " +
                "order intact; got \(runtime.prefs.cardOrder)"))
    }
}
