//
//  CardColorHueTableTests.swift · Tests/DeckAppTests
//
//  Pins `CardColor.paletteHue` — DeckCore's own MEASURED hue table — against
//  a REAL resolution of the system colours it claims to describe, in both
//  appearances. `paletteHue`'s own doc comment states the derivation: light
//  appearance, `.sRGB`, resolved once on the machine that measured it. This
//  file is what keeps that measurement honest from here on — a system
//  colour nudged by a future OS revision fails THIS test loudly rather than
//  leaving `CardColor.generate`'s keep-out arithmetic steering by a stale
//  number nobody re-checked. `DeckCore` has no `AppKit` of its own to do
//  this resolution itself (`CardColor.swift`'s own file doc: the core
//  names, DeckApp paints), so the arbiter lives here, one layer up, the
//  same split `SessionOverview`'s `paletteTints` already draws for the
//  pixels themselves.
//

import Testing
import AppKit
import DeckCore
@testable import DeckApp

@MainActor
struct CardColorHueTableTests {

    /// Palette order, index-for-index with `CardColor.paletteNames` and
    /// `SessionOverview.paletteTints` — the same congruence those two
    /// already hold each other to. A palette that grows in one file and
    /// not this one fails a test rather than pinning a name against the
    /// wrong system colour's hue.
    private static let systemColors: [NSColor] = [
        .systemOrange, .systemYellow, .systemGreen, .systemMint, .systemTeal,
        .systemCyan, .systemBlue, .systemIndigo, .systemPurple, .systemPink, .systemBrown,
    ]

    /// The tolerance `paletteHue`'s own doc comment names: dark appearance
    /// drifts from the light-appearance measurement the table was pinned
    /// against by at most 0.030 across all eleven names (indigo is the
    /// worst case, 0.6792 → 0.6495) — 0.035 leaves a small margin above
    /// that measured worst case rather than hugging it exactly, so a
    /// sub-ULP difference in how two machines round the same system colour
    /// cannot flip this test on a rebuild that changed nothing real.
    private static let tolerance = 0.035

    /// Wrapped, not bare `abs` — the wheel wraps at 0/1 the same way
    /// `hsbToRGB`'s own hue argument does, and a hue sitting just above
    /// 0.98 that a dark-appearance shift nudges to just under 0.02 is 0.04
    /// apart on the true wheel, not the 0.96 a bare subtraction would
    /// report. None of the eleven names sit close enough to the seam for
    /// this to matter in practice today, but the distance function should
    /// answer the real question regardless of which names happen to be in
    /// the table this year.
    private func hueDistance(_ a: Double, _ b: Double) -> Double {
        let raw = abs(a - b)
        return min(raw, 1 - raw)
    }

    /// Resolves `color`'s hue as it actually paints under `appearanceName`
    /// — `performAsCurrentDrawingAppearance` is what makes a DYNAMIC system
    /// colour (one that answers differently in light versus dark) actually
    /// evaluate against the appearance this closure names, rather than
    /// whatever appearance the test process happens to be running under.
    private func hue(of color: NSColor, in appearanceName: NSAppearance.Name) -> Double {
        guard let appearance = NSAppearance(named: appearanceName) else {
            Issue.record("could not construct NSAppearance named \(appearanceName.rawValue)")
            return 0
        }
        var result: Double = 0
        appearance.performAsCurrentDrawingAppearance {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            result = Double(resolved.hueComponent)
        }
        return result
    }

    @Test("paletteHue matches a real NSColor resolution, in light appearance",
          arguments: 0..<CardColor.paletteCount)
    func paletteHueMatchesLightAppearance(_ index: Int) {
        let resolved = hue(of: Self.systemColors[index], in: .aqua)
        let canonical = CardColor.paletteHue(index)
        #expect(hueDistance(canonical, resolved) <= Self.tolerance, Comment(rawValue:
                "slot \(index) (\(CardColor.paletteNames[index])), .aqua: canonical \(canonical) " +
                "vs resolved \(resolved), drift \(hueDistance(canonical, resolved))"))
    }

    @Test("paletteHue matches a real NSColor resolution, in dark appearance",
          arguments: 0..<CardColor.paletteCount)
    func paletteHueMatchesDarkAppearance(_ index: Int) {
        let resolved = hue(of: Self.systemColors[index], in: .darkAqua)
        let canonical = CardColor.paletteHue(index)
        #expect(hueDistance(canonical, resolved) <= Self.tolerance, Comment(rawValue:
                "slot \(index) (\(CardColor.paletteNames[index])), .darkAqua: canonical \(canonical) " +
                "vs resolved \(resolved), drift \(hueDistance(canonical, resolved))"))
    }
}
