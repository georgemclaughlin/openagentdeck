//
//  CardColor.swift · DeckCore/Model
//
//  What identity a card wears: a fact the core names, not a colour it paints.
//
//  `Signal.swift` draws the same line for readings: the core hands out a
//  severity, not a named colour. This type does it for IDENTITY rather than
//  urgency. What slot a lane holds is a fact about the lane, assigned once,
//  stored, and read back the same across a relaunch. What PIXELS that slot
//  paints is the view's business.
//

import Foundation

/// A card's identity colour: a slot in the deck's own palette, or a colour a
/// person chose outright.
///
/// `Codable` conformance is for `LaneView`'s synthesized coding only — see
/// that type's own doc comment for the Codable-landmine this inherits from
/// `UsageIndicator.windows`. The wire/disk contract is the hand-rolled
/// `JSONValue` codec below, not this derived one.
public enum CardColor: Equatable, Hashable, Codable, Sendable {
    /// An index into `paletteNames`. Out of range is not a decode error —
    /// see `spokenName`'s own comment for why a stored file gets clamped
    /// rather than refused.
    case slot(Int)
    /// A resolved sRGB triple the user chose outright, holding no NAMED slot:
    /// `assign`'s `heldRecorded` (the set a NAME is excluded on) reads only
    /// `.slot` entries, so a custom colour never removes a palette NAME from the
    /// pool somebody else can win.
    ///
    /// A custom colour does still occupy a point on the hue wheel, in two places.
    /// `generate` reads every `.custom` entry's hue so a freshly generated colour
    /// steers clear of it. `assign` counts that hue as worn ground for tier 2's
    /// spread scoring (and for the migration-adoption floor in
    /// `Reducer.recordCardColorIfNeeded`), so a custom parked on teal drags every
    /// named slot near teal down to a losing score, as an actual `.slot(4)`
    /// would. The hue is read regardless of the custom's saturation and
    /// brightness. This is deliberately conservative: it can only make assignment
    /// avoid more, never hand out a duplicate or a lookalike.
    case custom(red: Double, green: Double, blue: Double)

    // ---------------------------------------------------------------- palette

    /// The identity palette's VOCABULARY: names, not colours. DeckApp is the one
    /// place a name becomes a system `Color`; the core only says which slot a
    /// card holds, the division `Signal.swift` draws for severity.
    ///
    /// The system palette minus two: `red` stays reserved for `.errored` — a
    /// red IDENTITY card would read as a dying one, the same reading a
    /// severity would give it — and minus `accent`, which is selection's own
    /// channel, so a selected orange card and an assigned accent card stay
    /// visually distinct rather than colliding on the one thing selection
    /// already owns. Seeded at `orange`, the deck's founding hue.
    public static let paletteNames: [String] = [
        "orange", "yellow", "green", "mint", "teal",
        "cyan", "blue", "indigo", "purple", "pink", "brown",
    ]

    /// `paletteNames.count` — 11 — named separately because `assign` and
    /// `fallbackSlot` both need "how many slots" without spelling out the
    /// list, and a palette that grows must only have to change one array.
    public static var paletteCount: Int { paletteNames.count }

    /// Where each named slot SITS on the hue wheel: MEASURED, not derived. Each
    /// value is the sRGB hue read off the real `NSColor` system colour behind
    /// each name in `SessionOverview`'s `paletteTints` (light appearance, `.sRGB`,
    /// `NSAppearance.performAsCurrentDrawingAppearance`).
    /// `CardColorHueTableTests` in DeckAppTests resolves the same eleven colours
    /// at test time and pins this table against them in both appearances, so an
    /// OS change that nudges a system colour's hue fails loudly. In palette
    /// order, index-for-index with `paletteNames` and
    /// `SessionOverview.paletteTints`.
    ///
    /// A MODELING coordinate, not a pixel promise: it gives `generate` something
    /// to measure distance from. The view still paints the system colour itself.
    ///
    /// Dark appearance drifts from each value by at most 0.030 (indigo is the
    /// worst: 0.6792 in `.aqua` versus 0.6495 in `.darkAqua`), which is the
    /// tolerance `CardColorHueTableTests` checks; it is close enough for
    /// `generate`'s keep-out math to read the right neighbourhood.
    private static let paletteHues: [Double] = [
        0.0783,   // orange
        0.1333,   // yellow
        0.3753,   // green
        0.4825,   // mint
        0.5104,   // teal
        0.5287,   // cyan
        0.5778,   // blue
        0.6792,   // indigo
        0.8134,   // purple
        0.9683,   // pink
        0.0705,   // brown
    ]

    /// `paletteHues[index]`, folded exactly the way `spokenName` folds `index`
    /// (modulo, positive first, since Swift's `%` keeps the sign of its left
    /// operand), so a name, its pixels (`SessionOverview.tint`), and its hue
    /// can never disagree about which palette entry a wild stored index lands on.
    /// `public` because `CardColorHueTableTests` (DeckAppTests) calls it from a
    /// different module.
    public static func paletteHue(_ index: Int) -> Double {
        let count = paletteCount
        let clamped = ((index % count) + count) % count
        return paletteHues[clamped]
    }

    /// What a person calls this colour. `slot` names the palette entry;
    /// `custom` has no name to give back beyond what it is.
    ///
    /// **Slots clamp via modulo rather than trap or refuse.** A stored index
    /// this version has no name for — a downgrade from a future build whose
    /// palette grew past 11 — must still resolve to SOME word rather than
    /// crash the smaller palette it landed on. Modulo (folded positive first,
    /// since Swift's `%` keeps the sign of its left operand) is what keeps
    /// every `Int`, however it got here, inside `paletteNames`' bounds.
    public var spokenName: String {
        switch self {
        case .slot(let index):
            let count = Self.paletteCount
            let clamped = ((index % count) + count) % count
            return Self.paletteNames[clamped]
        case .custom:
            return "custom color"
        }
    }

    // -------------------------------------------------------------- fallback

    /// A stable slot for an id, before any assignment has been recorded.
    ///
    /// Swift's `Hashable` is seed-randomized per launch BY DESIGN — hash
    /// values are documented to not survive a process boundary — so
    /// `id.hashValue % paletteCount` answers a *different* question on every
    /// relaunch. This needed to answer "the same colour after relaunch",
    /// which is a STABLE-hash question, and needs a hash actually built for
    /// one. FNV-1a 64-bit is the smallest hash with adequate spread that is:
    /// a single xor-then-multiply pass over the bytes, no seed, no table, no
    /// dependency.
    ///
    /// Deterministic even for a lane with no directory yet: a session whose
    /// `cwd` has not resolved still has an id (the same hole `Frame.hidable`'s
    /// doc names for Hide), and that lane's card shows a colour derived from it,
    /// stable across projections until a directory arrives and a real assignment
    /// (`assign`) can be recorded. A lane whose directory is known but not yet
    /// recorded hashes the DIRECTORY here instead (the projection's comment says
    /// why that makes same-directory lanes match before any assignment lands).
    public static func fallbackSlot(for id: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325       // FNV-1a 64-bit offset basis
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3        // FNV-1a 64-bit prime
        }
        return Int(hash % UInt64(paletteCount))
    }

    // ---------------------------------------------------------------- assign

    /// The floor under which two hues stop counting as spread apart, for every
    /// automatic-assignment purpose: `assign`'s tier 2 and the migration-adoption
    /// guard in `Reducer.recordCardColorIfNeeded`. It exists because mint
    /// (0.4825) beside a worn teal (0.5104), 0.0279 apart, is indistinguishable
    /// at 5 pt spine width, yet an exact-slot-match rule treats them as different.
    ///
    /// Derivation, measured against the shipped palette: four pairs sit under
    /// 0.05: teal-cyan (0.018), mint-teal (0.028), cyan-blue (0.049) and
    /// mint-cyan (0.046), the confusable blue-green cluster. The nearest pair
    /// that clears the floor is orange-yellow at 0.055, so 0.05 sits just under
    /// the tightest pair anyone should be asked to tell apart and just above the
    /// loosest one measured as confusable. (Green-mint, 0.107, is a second data
    /// point, not the binding one.)
    ///
    /// Exception: brown (0.0705) sits 0.008 from orange (0.0783) in hue alone, so
    /// the floor blocks the pair, although saturation and brightness tell them
    /// apart on screen. Blocking it is conservative, an accepted cost of
    /// measuring only one axis.
    static let minimumAssignedHueSeparation: Double = 0.05

    /// Circular hue distance: the shorter of the two ways around the wheel,
    /// `min(|a − b|, 1 − |a − b|)`.
    ///
    /// Circular, unlike `generate`'s keep-out interval: `generate` cuts the wheel
    /// at red so it never needs wrap math when PLACING a colour, but SCORING needs
    /// the honest number. Pink (0.9683) and orange (0.0783) are ~0.11 apart
    /// through red, and a scorer that refused to look through forbidden ground
    /// would call them 0.89 apart. Looking through red and standing on it are
    /// different acts; only the second is off limits.
    static func hueDistance(_ a: Double, _ b: Double) -> Double {
        let diff = abs(a - b)
        return min(diff, 1 - diff)
    }

    /// The pure assignment rule: which colour a NEW key gets, given who else is
    /// already wearing one. Key-agnostic: `existing` maps any key that can hold a
    /// colour (currently directories) to its colour.
    ///
    /// Three tiers, run in order; the order is the whole rule.
    ///
    ///   1. `preferred`, but only while nothing else has been recorded yet. Once
    ///      `existing` holds even one entry, `preferred` is never consulted
    ///      again; it survives only as the very first directory's seed.
    ///   2. The FREE named slot (one no recorded `.slot` entry holds) whose hue
    ///      sits FARTHEST from every worn hue, where "worn" means every recorded
    ///      entry's hue, `.slot` via `paletteHue` and `.custom` via `rgbToHSB`
    ///      alike. Ties break toward the lower index, the same rule `generate`'s
    ///      largest-gap tie-break uses, so identical input gives a deterministic
    ///      answer. If that best score clears `minimumAssignedHueSeparation`, it
    ///      is assigned.
    ///   3. `generate(avoiding: existing.values)`: a fresh `.custom` colour,
    ///      whenever no free named slot clears the floor, EVEN THOUGH named slots
    ///      remain free.
    ///
    /// Tier 2 spreads rather than picking "the lowest free slot": a slot being
    /// free says nothing about how close its hue reads to what is already worn
    /// (mint was once handed out 0.0279 from a worn teal). It asks how far apart
    /// two projects' colours will actually READ.
    ///
    /// Tier 2 not clearing the floor is not tier 2 failing; it is tier 2
    /// reporting the truth. Once teal is worn, mint and cyan go dormant for
    /// automatic assignment: both remain free (a person can still hand-pick
    /// either through the picker), but neither can win against a worn neighbour
    /// that close, so the rule moves on to tier 3 rather than hand out a
    /// lookalike. The deck would rather MAKE a new colour than hand out one it
    /// already knows will be mistaken for another project's.
    ///
    /// `generate` is exempt from this floor, which is not an inconsistency.
    /// Largest-gap midpoint placement is already the best a single hue dimension
    /// can do once the wheel is crowded: no ordering of insertions keeps every
    /// pair `minimumAssignedHueSeparation` apart forever on a bounded interval
    /// (the limit `generate`'s doc comment states). The floor governs which
    /// EXISTING, NAMED colour gets reused; refusing a hue that fails the floor
    /// while assigning one `generate` produces that also fails it would apply two
    /// standards to the same number.
    ///
    /// A `.custom` entry never competes for HOLDING a name (only `.slot` entries
    /// enter `heldRecorded`; see `.custom`'s doc), but it does compete in the
    /// SCORING: its hue counts as worn ground like a `.slot` entry's, so a
    /// person's own custom pick suppresses a lookalike NAME going out
    /// automatically.
    ///
    /// A person choosing a colour through the picker is exempt from all of this:
    /// `setCardColor(_:for:)` writes a chosen `.custom` colour straight through,
    /// never routing it through `assign`. This function is what the deck does on
    /// ITS OWN initiative; a knowing, hand-picked duplicate or near-duplicate is
    /// the person's call, not something the rule protects them from.
    public static func assign(existing: [String: CardColor],
                              preferred: Int) -> CardColor {
        var heldRecorded = Set<Int>()
        var wornHues: [Double] = []
        for color in existing.values {
            switch color {
            case .slot(let index):
                heldRecorded.insert(index)
                wornHues.append(paletteHue(index))
            case .custom(let red, let green, let blue):
                wornHues.append(rgbToHSB(red: red, green: green, blue: blue).hue)
            }
        }
        guard !wornHues.isEmpty else { return .slot(preferred) }

        var bestSlot: Int?
        var bestScore = -Double.infinity
        for slot in 0..<paletteCount where !heldRecorded.contains(slot) {
            let slotHue = paletteHue(slot)
            let score = wornHues.map { hueDistance(slotHue, $0) }.min() ?? .infinity
            // Strict `>`, not `>=`: ascending iteration means the first slot to reach
            // a given score is the lowest index, and a later equally-scored slot must
            // not overwrite it. `generate`'s largest-gap tie-break uses the same rule.
            if score > bestScore {
                bestScore = score
                bestSlot = slot
            }
        }
        if let bestSlot, bestScore >= minimumAssignedHueSeparation {
            return .slot(bestSlot)
        }
        return generate(avoiding: existing.values)
    }

    // --------------------------------------------------------------- generate
    //
    // What `assign` reaches for once the named palette is exhausted:
    // fresh, GENERATED colours rather than a twelfth reuse of one of the
    // first eleven. Everything below is arithmetic on a single dimension —
    // hue — because saturation and brightness are fixed constants
    // (`generatedSaturation`/`generatedBrightness`) chosen once to sit
    // inside the named palette's own envelope, not a second axis this rule
    // searches.

    /// Above vermillion, the reddish-orange a hue just past true red still reads
    /// as. `.errored`'s reserved channel is `systemRed`, measured (as in
    /// `paletteHue`'s doc) at hue 0.9966 in `.aqua` and 0.9974 in `.darkAqua`. A
    /// generated identity near that hue would read as a DYING card, the confusion
    /// that is why red was pulled from the named palette (`paletteNames`). 0.03
    /// rather than 0.00 because the wheel wraps at 0/1: a value near 0.00 is near
    /// 0.9966 by the short way around.
    static let generatedHueFloor = 0.03

    /// Below red's measured 0.9966 with room to spare, so a hue this close to the
    /// ceiling is still unambiguously NOT the reserved channel after HSB-to-RGB
    /// rounding. 0.985 rather than hugging 0.9966: pink, the palette's reddest
    /// NAMED colour, measures 0.9683 and must stay legal ground for `generate`
    /// to reason about, and 0.985 clears it while keeping a margin below red.
    static let generatedHueCeiling = 0.985

    /// **Cutting the circle at the keep-out turns the wheel into a LINE.**
    /// A hue wheel is a circle, and the "largest gap" question on a circle
    /// ordinarily needs wrap-around distance math — the gap from pink
    /// (0.9683) back around through red to orange (0.0783) is a real gap
    /// on the true circle, and computing its width means subtracting
    /// through the 1.0/0.0 seam. Excluding `[generatedHueFloor,
    /// generatedHueCeiling]` outright removes that gap from consideration
    /// entirely — there is no "around through red" candidate left to
    /// measure, because red's whole neighbourhood is forbidden ground
    /// rather than merely unoccupied. What remains is a plain closed
    /// INTERVAL with two hard walls, and every gap inside it is an
    /// ordinary subtraction between two points on a line. That is the
    /// reason `generate`, below, contains no modular or wrap-around
    /// arithmetic anywhere: the keep-out is not only a safety rule, it is
    /// what makes the rest of the function allowed to be simple.

    /// The fixed saturation every generated colour is built at — 0.80,
    /// inside the named palette's own measured envelope (system colours in
    /// `.aqua` range roughly 0.45–1.0 saturation across the eleven names),
    /// so a generated swatch reads as a peer of the named ones rather than
    /// a washed-out or oversaturated outlier sitting among them.
    static let generatedSaturation = 0.80

    /// The fixed brightness every generated colour is built at — 0.92,
    /// inside the named palette's own measured envelope (roughly 0.68–1.0
    /// across the eleven names) for the same reason `generatedSaturation`
    /// is: a generated colour has to look like it belongs to the same
    /// family, not like a placeholder wearing the family's hue alone.
    static let generatedBrightness = 0.92

    /// A fresh `.custom` colour, distinct from every hue already in play.
    ///
    /// **The largest-gap rule.** Every occupied hue — a named slot's own
    /// `paletteHue`, or a `.custom` entry's own `rgbToHSB(...).hue` —
    /// is collected, filtered to the legal interval (a caller's `.custom`
    /// parked outside `[generatedHueFloor, generatedHueCeiling]`, e.g. a
    /// person who deliberately chose something reddish, is already excluded
    /// by the walls themselves and needs no separate handling here), and
    /// sorted. That sorted list, together with the two walls, cuts the
    /// interval into consecutive candidate gaps — floor-to-first,
    /// each-point-to-its-successor, last-to-ceiling — and this returns the
    /// MIDPOINT of the LARGEST one. Ties (two gaps of identical width)
    /// break toward the gap with the lower start, so the same `existing`
    /// collection always generates the same colour — determinism a person
    /// re-reading two decks with identical history would expect and a test
    /// (`generateIsDeterministic`) pins directly.
    ///
    /// **Why this is a NEVER-duplicate guarantee, not a best-effort one.**
    /// A midpoint sits strictly between its gap's two endpoints by
    /// construction — `(start + end) / 2` cannot equal `start` or `end`
    /// unless the gap has zero width, which a gap between two DISTINCT
    /// occupied hues never does. So the returned hue can never equal an
    /// hue already in `existing`, full stop, for as long as there is any
    /// gap left to bisect — and the interval is continuous, so there always
    /// is one. Combined with `assign` never reaching this function while a
    /// NAMED slot remains free, that is what makes "never assign the same
    /// colour to two different directories" an exact promise rather than a
    /// probabilistic one.
    ///
    /// **The honest limit, stated rather than hidden.** Exact non-equality
    /// is not the same claim as "visually distinguishable." Past roughly
    /// two dozen recorded projects, successive largest-gap insertions crowd
    /// hues closer together than a person can tell apart at a glance on a
    /// 5 pt swatch — and largest-gap insertion is the BEST a single hue
    /// dimension can do about that; there is no ordering of insertions that
    /// keeps every pair maximally far apart forever on a bounded interval.
    /// The named palette itself already lives with a milder version of the
    /// same limit — mint (0.4825) and teal (0.5104) sit only 0.0279 apart,
    /// cyan (0.5287) a further 0.0183 past that — so a generated colour
    /// crowding its neighbours after two dozen insertions is the SAME kind
    /// of visual compromise the shipped palette already makes near its own
    /// blue-green cluster, not a new failure this rule introduces.
    ///
    /// **Degenerate case.** No occupied hues at all (an empty `existing`,
    /// or one holding only entries outside the legal interval) leaves
    /// exactly one gap — the whole interval — and its midpoint is returned:
    /// `(generatedHueFloor + generatedHueCeiling) / 2`.
    static func generate(avoiding existing: some Collection<CardColor>) -> CardColor {
        var occupied = Set<Double>()
        for color in existing {
            switch color {
            case .slot(let index):
                occupied.insert(paletteHue(index))
            case .custom(let red, let green, let blue):
                occupied.insert(rgbToHSB(red: red, green: green, blue: blue).hue)
            }
        }
        let inRange = occupied
            .filter { $0 >= generatedHueFloor && $0 <= generatedHueCeiling }
            .sorted()
        let boundaries = [generatedHueFloor] + inRange + [generatedHueCeiling]

        var gapStart = generatedHueFloor
        var gapEnd = generatedHueCeiling
        var gapWidth = -Double.infinity
        for i in 0..<(boundaries.count - 1) {
            let start = boundaries[i]
            let end = boundaries[i + 1]
            let width = end - start
            // Strict `>`, not `>=` — boundaries are already in ascending
            // order, so the first gap to reach a given width is always the
            // one with the lower start, and a strict comparison is what
            // keeps a later, equally-wide gap from overwriting it. That is
            // the whole tie-break rule; there is no separate branch for it.
            if width > gapWidth {
                gapWidth = width
                gapStart = start
                gapEnd = end
            }
        }
        let hue = (gapStart + gapEnd) / 2
        return .custom(hue: hue, saturation: generatedSaturation, brightness: generatedBrightness)
    }

    // ------------------------------------------------------------- picking
    //
    // The in-band picker goes BOTH ways between a `.custom` colour's stored sRGB
    // and the hue/saturation/brightness sliders a person drags. Hand-rolled
    // core-side because the CONVERSION is a fact about numbers, not pixels, and
    // DeckApp stays free of colour math. Pure functions with no `Color` or
    // `NSColor`: the standard six-sector HSB<->RGB algorithm, checked against the
    // palette's corners (red/yellow/green/cyan/blue/magenta) in `CardColorTests`.

    /// Standard HSB -> sRGB, the six-sector algorithm. `hue` wraps modulo 1
    /// (so 1.0 and 0.0 are the same red, and a slider that somehow drifted
    /// negative still lands somewhere on the wheel rather than off it);
    /// `saturation`/`brightness` clamp to 0...1 — a slider is built to stay
    /// in range, but a caller constructing this directly (a test, a future
    /// import) gets a defined answer rather than a wedge of `Double`
    /// arithmetic escaping the wheel entirely.
    static func hsbToRGB(hue: Double, saturation: Double,
                         brightness: Double) -> (red: Double, green: Double, blue: Double) {
        let wrapped = hue.truncatingRemainder(dividingBy: 1)
        let h = (wrapped < 0 ? wrapped + 1 : wrapped) * 6
        let s = min(max(saturation, 0), 1)
        let v = min(max(brightness, 0), 1)
        let sector = Int(h.rounded(.down)) % 6
        let f = h - h.rounded(.down)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch sector {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)   // 5
        }
    }

    /// sRGB -> HSB, `hsbToRGB`'s own inverse. `hue` comes back in 0...1
    /// (matching what it takes), `0` for any fully desaturated triple
    /// (black through white) — undefined in the geometric sense, same as
    /// every HSB implementation's convention, and never read back into
    /// `hsbToRGB` in a way that would matter: a saturation of 0 zeroes the
    /// hue term in every one of that function's six branches.
    static func rgbToHSB(red: Double, green: Double,
                         blue: Double) -> (hue: Double, saturation: Double, brightness: Double) {
        let r = min(max(red, 0), 1), g = min(max(green, 0), 1), b = min(max(blue, 0), 1)
        let maxV = max(r, g, b), minV = min(r, g, b)
        let delta = maxV - minV
        let brightness = maxV
        let saturation = maxV == 0 ? 0 : delta / maxV
        guard delta != 0 else { return (0, saturation, brightness) }
        var hue: Double
        if maxV == r {
            hue = ((g - b) / delta).truncatingRemainder(dividingBy: 6)
        } else if maxV == g {
            hue = (b - r) / delta + 2
        } else {
            hue = (r - g) / delta + 4
        }
        hue /= 6
        if hue < 0 { hue += 1 }
        return (hue, saturation, brightness)
    }

    /// A `.custom` colour built from HSB rather than sRGB directly — the
    /// picker's own write path: three sliders in, one stored triple out.
    public static func custom(hue: Double, saturation: Double, brightness: Double) -> CardColor {
        let (r, g, b) = hsbToRGB(hue: hue, saturation: saturation, brightness: brightness)
        return .custom(red: r, green: g, blue: b)
    }

    /// The HSB triple behind a `.custom` colour's stored sRGB; nil for `.slot`,
    /// which carries no RGB in the core (pixels are the view's business).
    /// DeckApp's picker seeds a `.slot` selection's HSB state from `tint`'s
    /// rendered `Color` instead.
    public var hsb: (hue: Double, saturation: Double, brightness: Double)? {
        switch self {
        case .custom(let red, let green, let blue): return Self.rgbToHSB(red: red, green: green, blue: blue)
        case .slot: return nil
        }
    }

    // ----------------------------------------------------------------- codec
    //
    // Hand-written rather than the derived `Codable` above, for the same
    // reason `QuickAction`'s is: the stored shape is a contract with a file
    // on somebody's disk, and a synthesised one changes whenever the type
    // does.

    /// A JSON number as an Int, or nil when it is not one — the same trap
    /// `DeckPrefs.whole` exists to avoid: `Int(_: Double)` aborts the
    /// process on NaN, infinity or anything past `Int64`, and a malformed
    /// stored index must drop the entry, not the process. Kept local rather
    /// than shared with `DeckPrefs` — a Model type reaching into Config for
    /// one line would be the wrong direction for a dependency nobody needs.
    private static func whole(_ value: Double) -> Int? { Int(exactly: value.rounded()) }

    /// `{"slot": 3}` or `{"custom": {"red": 0.5, "green": 0.5, "blue": 0.5}}`.
    public func encoded() -> JSONValue {
        switch self {
        case .slot(let index):
            return .object(["slot": .number(Double(index))])
        case .custom(let red, let green, let blue):
            return .object(["custom": .object([
                "red": .number(red), "green": .number(green), "blue": .number(blue),
            ])])
        }
    }

    /// nil for anything this version cannot make sense of — dropped rather
    /// than defaulted, the same posture `QuickAction.decode` takes: a value
    /// nobody chose has no business surviving the decode just because a
    /// slot has to end up with SOME colour. `DeckPrefs.decode` is where that
    /// fallback actually happens, by simply not carrying the entry forward —
    /// the fleet's own `fallbackSlot` covers the surface on the very next
    /// projection.
    public static func decode(_ json: JSONValue) -> CardColor? {
        guard case .object(let o) = json else { return nil }
        if case .number(let n)? = o["slot"], let index = whole(n) {
            return .slot(index)
        }
        if case .object(let c)? = o["custom"],
           case .number(let r)? = c["red"],
           case .number(let g)? = c["green"],
           case .number(let b)? = c["blue"] {
            return .custom(red: r, green: g, blue: b)
        }
        return nil
    }
}
