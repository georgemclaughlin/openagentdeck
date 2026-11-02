//
//  CardColorPicker.swift · DeckApp
//
//  The in-band colour picker: a popover, deliberately not a `ColorPicker`
//  or `NSColorPanel`.
//
//  `ColorPicker` and `NSColorPanel` are the SAME shared floating panel, kept
//  on the MAIN display. The deck's primary surface is an 8.8" strip that is
//  normally not the main display, so that panel would open on the wrong
//  screen. A `.popover` is anchored to the control that opened it, on
//  whichever screen that control lives on.
//
//  A popover also dismisses itself on an outside click or tap, and goes
//  away when the band it lives in closes (see `SessionControls`).
//
//  Platform default styling: a popover gets the glass treatment natively,
//  so this file does not style the popover's chrome.
//

import SwiftUI
import DeckCore

/// The picker's content: the eleven-slot palette, Automatic, and a custom
/// HSB well — everything a card's colour can be, in one popover.
struct CardColorPicker: View {
    let lane: LaneView
    let runtime: DeckRuntime

    /// Local slider state, seeded at INIT (not `.onAppear`) from the lane's
    /// current colour. `onChange` never fires for a `State`'s initial value,
    /// so seeding cannot trigger `applyCustom()`.
    @State private var hue: Double
    @State private var saturation: Double
    @State private var brightness: Double

    init(lane: LaneView, runtime: DeckRuntime) {
        self.lane = lane
        self.runtime = runtime
        let seed = Self.seedHSB(for: lane.color)
        _hue = State(initialValue: seed.hue)
        _saturation = State(initialValue: seed.saturation)
        _brightness = State(initialValue: seed.brightness)
    }

    /// Where the sliders start. `CardColor.hsb` answers directly for a
    /// `.custom` lane (round-trip epsilon pinned by `CardColorTests`). A
    /// `.slot` lane has no HSB in the core, so this reads the hue back from
    /// the slot's rendered `tint` via `NSColor`: approximate on purpose, it
    /// only needs to start near the hue already on screen.
    ///
    /// `internal` as a test seam for `CardColorPickerTests`.
    static func seedHSB(for color: CardColor) -> (hue: Double, saturation: Double, brightness: Double) {
        if let hsb = color.hsb { return hsb }
        let resolved = NSColor(color.tint).usingColorSpace(.deviceRGB)
        guard let resolved else { return (0, 1, 1) }
        return (Double(resolved.hueComponent), Double(resolved.saturationComponent),
               Double(resolved.brightnessComponent))
    }

    /// Six across, so eleven slots read as two short rows (6 + 5).
    private static let swatchColumns = Array(repeating: GridItem(.fixed(32), spacing: 12), count: 6)

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // The colour change is not this session's alone. The directory
            // itself is not named: the card underneath already shows it,
            // and a duplicated fact can go stale in one place.
            Text("Shared by every session in this directory.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: Self.swatchColumns, spacing: 12) {
                ForEach(0..<CardColor.paletteCount, id: \.self) { index in
                    swatch(for: .slot(index))
                }
            }
            automaticButton
            Divider()
            customSection
        }
        .padding(16)
        .frame(width: 280)
        // Every slider drag applies live: no Done button, no staged draft.
        // The swatch in `SessionControls` reads `lane.color` off the frame,
        // so it moves with the drag.
        .onChange(of: hue) { _, _ in applyCustom() }
        .onChange(of: saturation) { _, _ in applyCustom() }
        .onChange(of: brightness) { _, _ in applyCustom() }
    }

    // ------------------------------------------------------------ swatches

    /// One palette slot, as a real `Button` (never `.onTapGesture`, which
    /// gives VoiceOver nothing to land on).
    ///
    /// "Current" is carried by two channels: a checkmark glyph (a ring would
    /// fail for Differentiate Without Color users) and the `.isSelected`
    /// trait for VoiceOver, which never sees the glyph.
    private func swatch(for color: CardColor) -> some View {
        let worn: Bool
        if case .slot(let index) = color { worn = Self.wornSlots(directoryColors: runtime.prefs.directoryColors,
                                                                 ownDirectory: lane.directory?.value).contains(index) }
        else { worn = false }
        return Self.swatch(for: color, isCurrent: lane.color == color, worn: worn) {
            runtime.setCardColor(color, for: lane.session)
        }
    }

    /// Which palette slots read as WORN: held by some OTHER directory's
    /// recorded colour. This lane's own directory is excluded, and `.custom`
    /// entries are skipped (only `.slot` occupies a named slot, see
    /// `CardColor.assign`). Informational only: every swatch stays tappable.
    ///
    /// `internal` as a test seam for `CardColorPickerTests`.
    static func wornSlots(directoryColors: [String: CardColor], ownDirectory: String?) -> Set<Int> {
        var worn = Set<Int>()
        for (directory, color) in directoryColors {
            guard directory != ownDirectory, case .slot(let index) = color else { continue }
            worn.insert(index)
        }
        return worn
    }

    /// The swatch button as a static builder, so tests measure the exact
    /// view production composes (see `TouchTargetTests`) rather than a
    /// lookalike that clears the touch floor by construction.
    ///
    /// `worn` defaults `false` so existing call sites keep compiling; the
    /// dot sits INSIDE the fixed 32x32 circle, so it does not change the
    /// touch floor.
    ///
    /// Selected wins over worn: a swatch can be both (`lane.color` reflects
    /// what Automatic would show now, which need not be this directory's
    /// recorded entry). The checkmark is what matters then, so the worn dot
    /// only appears on a swatch that is not current.
    static func swatch(for color: CardColor, isCurrent: Bool, worn: Bool = false,
                       action: @escaping () -> Void) -> some View {
        let showsWornDot = worn && !isCurrent
        return Button(action: action) {
            ZStack(alignment: .bottom) {
                Circle().fill(color.tint)
                if isCurrent {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                } else if showsWornDot {
                    // Small and quiet (4pt, secondary): informational, not
                    // actionable. Tapping a worn slot is still allowed.
                    Circle()
                        .fill(.secondary)
                        .frame(width: 4, height: 4)
                        .padding(.bottom, 3)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
        .touchTarget()
        .accessibilityLabel(accessibilityLabel(for: color, isCurrent: isCurrent, worn: worn))
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    /// The swatch's accessibility label as a pure function, so
    /// `CardColorPickerTests` can pin the string (`.accessibilityLabel`
    /// cannot be read back off a built view). The "worn" suffix appears
    /// under the same condition that draws the dot. `internal` test seam.
    static func accessibilityLabel(for color: CardColor, isCurrent: Bool, worn: Bool) -> String {
        (worn && !isCurrent) ? "\(color.spokenName), worn by another project" : color.spokenName
    }

    // ----------------------------------------------------------- automatic

    /// Shown always. Tapping it on an already-automatic lane is a no-op
    /// that `setCardColor` absorbs (`next != state.prefs` guards the write).
    private var automaticButton: some View {
        Button {
            runtime.setCardColor(nil, for: lane.session)
        } label: {
            Label("Automatic", systemImage: "wand.and.stars")
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.glass)
        .touchTarget()
        .help("Reassign the colour a fresh arrival would get today")
    }

    // -------------------------------------------------------------- custom

    private var customColor: Color {
        CardColor.custom(hue: hue, saturation: saturation, brightness: brightness).tint
    }

    private func applyCustom() {
        runtime.setCardColor(.custom(hue: hue, saturation: saturation, brightness: brightness),
                             for: lane.session)
    }

    private var customSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Custom")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 12) {
                // Decorative: the sliders carry the same values to VoiceOver.
                Circle()
                    .fill(customColor)
                    .frame(width: 28, height: 28)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    hsbSlider("Hue", $hue)
                    hsbSlider("Saturation", $saturation)
                    hsbSlider("Brightness", $brightness)
                }
            }
        }
    }

    /// One slider, labelled for a thumb and for VoiceOver alike. The caption
    /// above is decorative; the slider itself carries the accessibility
    /// label so it is announced as an adjustable element.
    private func hsbSlider(_ title: String, _ value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Slider(value: value, in: 0...1)
                .accessibilityLabel(title)
        }
    }
}
