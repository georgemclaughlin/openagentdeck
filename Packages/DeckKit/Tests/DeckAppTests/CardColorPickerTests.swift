//
//  CardColorPickerTests.swift · Tests/DeckAppTests
//
//  The picker's own view-level facts — seeding, selection state, and that
//  it builds for every starting colour a lane can actually hold. The pure
//  HSB<->RGB conversion itself is `CardColorTests` (`DeckCoreTests`), which
//  owns the algorithm; this file is what sits on top of it in DeckApp: the
//  seam where a lane's stored `CardColor` becomes three slider positions,
//  and the swatch grid that reads a lane's current choice back.
//

import Testing
import SwiftUI
import AppKit
import DeckCore
@testable import DeckApp

@MainActor
struct CardColorPickerTests {

    private func measured(_ view: some View, width: Double) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// `cwd` — a colour preference is keyed on the DIRECTORY now, not the
    /// surface, so any test that means to exercise `setCardColor`/the
    /// picker's own write path needs a lane that actually has one.
    private func runtime(hosting session: SessionID, surface: String, cwd: String) -> DeckRuntime {
        let r = DeckRuntime()
        r.markStartedForTesting()
        r.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("start-\(session.raw)"), at: Instant(sinceStart: Millis(0)),
                            kind: .sessionStart, session: session, cwd: Redacted(cwd), tool: nil,
                            toolUseID: nil, held: .absent, host: HostAddress(workspace: "w", surface: surface))),
            .sessionSelected(session, at: Instant(sinceStart: Millis(1))),
        ]))
        return r
    }

    // -------------------------------------------------------------- seeding

    /// `.custom` seeds EXACTLY — `CardColor.hsb` answers directly, no
    /// platform conversion involved, so this is a hard equality (materialized
    /// epsilon), not an approximation.
    @Test("seedHSB reads a .custom lane's own HSB exactly")
    func seedHSBIsExactForCustom() {
        let color = CardColor.custom(red: 0.2, green: 0.6, blue: 0.9)
        guard let expected = color.hsb else {
            Issue.record("the fixture's own premise: a .custom colour has an .hsb")
            return
        }
        let seeded = CardColorPicker.seedHSB(for: color)
        let epsilon = 0.000_001
        #expect(abs(seeded.hue - expected.hue) < epsilon)
        #expect(abs(seeded.saturation - expected.saturation) < epsilon)
        #expect(abs(seeded.brightness - expected.brightness) < epsilon)
    }

    /// `.slot` has no HSB in the core at all (`CardColor.hsb` answers nil
    /// for it) — this reaches into the slot's rendered `tint` through
    /// `NSColor` instead, "approximate on purpose" per the function's own
    /// doc comment. What is pinned here is the CONTRACT, not an exact
    /// value this file has no business demanding of a system colour: every
    /// component lands inside 0...1, for every slot in the palette, so a
    /// slider seeded from one never starts off its own track.
    @Test("seedHSB stays within 0...1 for every palette slot", arguments: 0..<CardColor.paletteCount)
    func seedHSBStaysInRangeForEverySlot(_ index: Int) {
        let seeded = CardColorPicker.seedHSB(for: .slot(index))
        #expect(seeded.hue >= 0 && seeded.hue <= 1, "hue \(seeded.hue) for slot \(index)")
        #expect(seeded.saturation >= 0 && seeded.saturation <= 1, "saturation \(seeded.saturation) for slot \(index)")
        #expect(seeded.brightness >= 0 && seeded.brightness <= 1, "brightness \(seeded.brightness) for slot \(index)")
    }

    // -------------------------------------------------------------- swatch

    /// The current choice carries the checkmark, and only the current
    /// choice — `CardColorPicker.swatch`'s own `isCurrent` parameter is
    /// what a real render decides from `lane.color == color`; this pins
    /// that comparison directly rather than trusting it silently.
    @Test("exactly one swatch is current, for a lane on a named slot")
    func exactlyOneSlotReadsAsCurrent() {
        let lane = LaneView(session: SessionID("aaaaaaaa-0001"), state: .idle, isExpanded: false,
                            contextPercent: nil, sources: [:], color: .slot(4),
                            host: HostAddress(workspace: "w", surface: "s"))
        let currentCount = (0..<CardColor.paletteCount).filter { lane.color == .slot($0) }.count
        #expect(currentCount == 1, "a lane pinned to slot 4 should read as current on exactly one swatch")
        #expect(lane.color == .slot(4))
    }

    /// A `.custom` lane's colour matches none of the eleven named slots —
    /// the swatch grid draws no checkmark at all, which is correct (the
    /// picker's own custom preview swatch is what carries that fact
    /// instead, not a slot pretending to be the nearest match).
    @Test("no slot reads as current for a lane on a custom colour")
    func noSlotReadsAsCurrentForACustomLane() {
        let lane = LaneView(session: SessionID("aaaaaaaa-0002"), state: .idle, isExpanded: false,
                            contextPercent: nil, sources: [:],
                            color: .custom(red: 0.5, green: 0.5, blue: 0.5),
                            host: HostAddress(workspace: "w", surface: "s"))
        let currentCount = (0..<CardColor.paletteCount).filter { lane.color == .slot($0) }.count
        #expect(currentCount == 0)
    }

    // --------------------------------------------------------------- build

    /// The picker builds and measures at a real, sized natural height —
    /// across a spread of starting colours, so a crash or a zero-sized
    /// render specific to one seeding path (a slot near either end of the
    /// palette, a custom colour at the wheel's own extremes) cannot hide
    /// behind a single fixture.
    @Test("the picker renders for every starting colour a lane can hold",
          arguments: [CardColor.slot(0), .slot(5), .slot(CardColor.paletteCount - 1),
                     .custom(red: 0, green: 0, blue: 0), .custom(red: 1, green: 1, blue: 1),
                     .custom(red: 0.3, green: 0.7, blue: 0.1)])
    func pickerRendersForEveryStartingColour(_ color: CardColor) {
        let session = SessionID("aaaaaaaa-0003")
        let dir = "/w/picker-build"
        let runtime = runtime(hosting: session, surface: "SURF-PICKER-BUILD", cwd: dir)
        var next = runtime.prefs
        next.directoryColors[dir] = color
        runtime.setPrefs(next)
        guard let lane = runtime.frame.lanes.first(where: { $0.session == session }) else {
            Issue.record("the fixture's own premise: the hosted session has a lane")
            return
        }
        #expect(lane.color == color, "the fixture's own premise: the lane actually carries the colour under test")

        let size = measured(CardColorPicker(lane: lane, runtime: runtime), width: 280)
        #expect(size.height > 0, "the picker rendered as nothing for \(color)")
        #expect(size.width > 0, "the picker rendered as nothing for \(color)")
    }

    // -------------------------------------------------------------- worn set
    //
    // `CardColorPicker.wornSlots(directoryColors:ownDirectory:)` — the
    // quiet-dot indicator's own pure fact, pinned directly (the same
    // test-seam posture `seedHSB` above already takes) rather than reading
    // it back off a rendered swatch's own drawing.

    @Test("another directory's recorded slot reads as worn")
    func anotherDirectorysSlotReadsAsWorn() {
        let directoryColors: [String: CardColor] = ["/w/other": .slot(3)]
        let worn = CardColorPicker.wornSlots(directoryColors: directoryColors, ownDirectory: "/w/mine")
        #expect(worn.contains(3))
    }

    @Test("this lane's own directory never reads as worn by itself")
    func ownDirectorysSlotDoesNotReadAsWorn() {
        let directoryColors: [String: CardColor] = ["/w/mine": .slot(3), "/w/other": .slot(7)]
        let worn = CardColorPicker.wornSlots(directoryColors: directoryColors, ownDirectory: "/w/mine")
        #expect(!worn.contains(3), "the lane's own recorded slot read as worn by itself")
        #expect(worn.contains(7))
    }

    @Test("a .custom entry never marks a swatch as worn")
    func customEntryNeverReadsAsWorn() {
        let directoryColors: [String: CardColor] = ["/w/other": .custom(red: 0.2, green: 0.4, blue: 0.6)]
        let worn = CardColorPicker.wornSlots(directoryColors: directoryColors, ownDirectory: "/w/mine")
        #expect(worn.isEmpty, ".custom holds no named slot and should never mark one worn")
    }

    /// The a11y label carries the fact VoiceOver has no dot to see —
    /// `CardColorPicker.swatch`'s own doc comment states why the checkmark
    /// wins when a swatch is both current and worn; this pins the OTHER
    /// side: a swatch that is worn and NOT current appends the suffix.
    /// Pinned against `CardColorPicker.accessibilityLabel(for:isCurrent:
    /// worn:)` directly — that function's own doc comment states why: a
    /// `.accessibilityLabel` modifier value has no supported way to be
    /// read back off a built SwiftUI view in this test target.
    @Test("a worn, non-current swatch's accessibility label names the collision")
    func wornSwatchAccessibilityLabelNamesTheCollision() {
        let label = CardColorPicker.accessibilityLabel(for: .slot(2), isCurrent: false, worn: true)
        #expect(label == "green, worn by another project")
    }

    @Test("a worn swatch that is ALSO current keeps the plain, unworn label")
    func currentAndWornSwatchKeepsThePlainLabel() {
        let label = CardColorPicker.accessibilityLabel(for: .slot(2), isCurrent: true, worn: true)
        #expect(label == "green")
    }

    @Test("an un-worn swatch carries no collision suffix")
    func unwornSwatchCarriesNoSuffix() {
        let label = CardColorPicker.accessibilityLabel(for: .slot(2), isCurrent: false, worn: false)
        #expect(label == "green")
    }
}

// --------------------------------------------------------------------- privacy

/// `DeckPrefs`'s own `CustomStringConvertible`/`CustomDebugStringConvertible`
/// — schematic, never a key or a value (`DeckPrefs.swift`'s own doc comment
/// for the conformance states the derivation: `Redacted`'s leak-closing
/// posture, extended to the struct that holds a whole file's worth of paths
/// and titles). Pinned here rather than `DeckCoreTests` because this is
/// an app-privacy hardening item, which lives beside the picker's other
/// hardening rather than beside the codec tests.
@MainActor
struct DeckPrefsPrivacyTests {
    @Test("DeckPrefs' description is schematic — counts, never a path or a title")
    func descriptionNeverLeaksAPathOrATitle() {
        var prefs = DeckPrefs()
        let secretDirectory = "/Users/someone/secret-project"
        prefs.directoryColors[secretDirectory] = .slot(3)
        let secretTitle = "Deploy to prod-only-cluster"
        prefs.quickActions.append(QuickAction(id: "custom-1", title: secretTitle,
                                              kind: .prompt("do the thing")))

        let description = prefs.description
        let debugDescription = prefs.debugDescription

        #expect(!description.contains("secret"), "description leaked the directory path: \(description)")
        #expect(!description.contains(secretTitle), "description leaked the action title: \(description)")
        #expect(!debugDescription.contains("secret"), "debugDescription leaked the directory path")
        #expect(!debugDescription.contains(secretTitle), "debugDescription leaked the action title")
        #expect(description.contains("directoryColors: 1"), "description dropped the directoryColors count")
        #expect(description.contains("quickActions:"), "description dropped the quickActions count")
    }
}
