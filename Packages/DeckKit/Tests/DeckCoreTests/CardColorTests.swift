//
//  CardColorTests.swift · Tests/DeckCoreTests
//
//  The pure identity-colour rule, isolated from the reducer and the prefs
//  codec that carry it. `HostIdentityTests` covers the reducer's own
//  assignment site and the frame it produces; this file is only the type's
//  own arithmetic — the palette, the stable fallback, the assignment rule,
//  and the disk codec.
//

import Testing
@testable import DeckCore

struct CardColorTests {

    // ------------------------------------------------------------ palette

    @Test("the identity palette is eleven distinct, nonempty names")
    func paletteIsElevenDistinctNames() {
        #expect(CardColor.paletteCount == 11)
        #expect(CardColor.paletteNames.count == CardColor.paletteCount)
        #expect(CardColor.paletteNames.allSatisfy { !$0.isEmpty })
        #expect(Set(CardColor.paletteNames).count == CardColor.paletteNames.count,
                "two slots share a name")
    }

    // -------------------------------------------------------- fallbackSlot

    /// Pinned against a real run, not derived from the algorithm's own
    /// description — a hash-implementation change (a different constant, a
    /// different algorithm entirely) must fail this loudly rather than
    /// silently reshuffle every stored colour's meaning on the next
    /// relaunch, which a test that re-derives the expectation from the same
    /// code could never catch.
    @Test("fallbackSlot is pinned for known ids")
    func fallbackSlotIsPinned() {
        #expect(CardColor.fallbackSlot(for: "s1") == 3)
        #expect(CardColor.fallbackSlot(for: "zzz") == 2)
        #expect(CardColor.fallbackSlot(for: "11111111-1111-1111-1111-111111111111") == 9)
    }

    @Test("fallbackSlot never leaves the palette, across a spread of ids")
    func fallbackSlotStaysInRange() {
        for i in 0..<500 {
            let slot = CardColor.fallbackSlot(for: "session-\(i)")
            #expect(slot >= 0 && slot < CardColor.paletteCount)
        }
    }

    @Test("fallbackSlot answers the same question twice, for the same id")
    func fallbackSlotIsDeterministicWithinAProcess() {
        let id = "a-session-that-has-never-had-a-host"
        #expect(CardColor.fallbackSlot(for: id) == CardColor.fallbackSlot(for: id))
    }

    // ------------------------------------------------------------- assign
    //
    // `assign`'s own doc comment tells the tier story in full; these pin
    // each of the three rungs. The function is tiered: tier 1
    // is now the ONLY tier that still reads `preferred` (worn set empty —
    // the very first directory); tier 2 stopped being "the lowest free
    // slot" and became "the free slot spread farthest from everything
    // already worn," gated on `CardColor.minimumAssignedHueSeparation`;
    // tier 3 (`generate`) is unchanged, but is now also reached whenever
    // every free slot fails that floor, even though named slots remain
    // free. `generate`'s own tests follow in the next section, untouched
    // by this phase.

    @Test("a free preferred slot is taken when nothing else has been recorded yet")
    func assignTakesFreePreferred() {
        let result = CardColor.assign(existing: [:], preferred: 4)
        #expect(result == .slot(4))
    }

    /// **The headline defect, RED-FIRST.** alpha (mint, slot 3) wore a
    /// colour 0.0279 from openagentdeck's worn teal (slot 4) — indistinguishable
    /// at 5 pt spine width — because the OLD "lowest free slot" rule asked
    /// only "is slot 3 held?" and mint was free, full stop. Reproduced here
    /// exactly: worn = every named slot EXCEPT mint(3) and cyan(5) — teal(4)
    /// IS worn — preferred = 3.
    ///
    /// Run for real against the OLD algorithm (extracted verbatim from this
    /// phase's own starting commit into a standalone script, since the
    /// working tree's `assign` already carries the fix and the phase's own
    /// hard rule forbids reverting it to check): `assign` handed back
    /// `.slot(3)` — mint — 0.0279 from worn teal, confirming the live
    /// defect for real rather than by description.
    ///
    /// **Green, against the NEW rule.** Both remaining free named slots
    /// fail the floor: mint scores 0.0279 (to worn teal), cyan scores
    /// 0.0183 (to worn teal) — both under `minimumAssignedHueSeparation`
    /// (0.05). Tier 2 has nothing to hand out, so tier 3 fires and a fresh
    /// `.custom` colour comes back instead — the deck making a colour
    /// rather than handing out a lookalike it can already see coming.
    @Test("the headline defect: mint next to a worn teal no longer passes — tier 2 goes dormant and tier 3 fires")
    func exhaustionOfSpreadFallsThroughToGenerateEvenWithNamedSlotsFree() {
        var existing: [String: CardColor] = [:]
        for slot in [0, 1, 2, 4, 6, 7, 8, 9, 10] { existing["dir-\(slot)"] = .slot(slot) }
        let result = CardColor.assign(existing: existing, preferred: 3)
        guard case .custom = result else {
            let message = "mint (slot 3) or cyan (slot 5) — both under the floor — were free, " +
                          "and \(result) was handed out instead of generating"
            Issue.record(Comment(rawValue: message))
            return
        }
    }

    /// The `generate` handoff from the test directly above, checked from
    /// the other side: not just THAT tier 3 fired, but that what it
    /// produced actually clears the very floor tier 2 just failed, against
    /// EVERY worn hue in the fixture. `generate` is documented as EXEMPT
    /// from `minimumAssignedHueSeparation` (its own doc comment: largest-gap
    /// midpoint placement is already the best a crowded wheel can do) — this
    /// pins that the exemption is never actually NEEDED here: the
    /// yellow→green gap this fixture's own occupancy leaves open is wide
    /// enough (0.2420, midpoint 0.2543) that the generated colour clears the
    /// floor from every one of the nine worn hues with room to spare.
    @Test("the generated handoff itself clears the separation floor from every worn hue")
    func generatedHandoffClearsTheSeparationFloor() {
        var existing: [String: CardColor] = [:]
        for slot in [0, 1, 2, 4, 6, 7, 8, 9, 10] { existing["dir-\(slot)"] = .slot(slot) }
        let result = CardColor.assign(existing: existing, preferred: 3)
        guard let generatedHue = result.hsb?.hue else {
            Issue.record("the fixture's own premise: tier 3 generates a .custom colour")
            return
        }
        for slot in [0, 1, 2, 4, 6, 7, 8, 9, 10] {
            let worn = CardColor.paletteHue(slot)
            let distance = CardColor.hueDistance(generatedHue, worn)
            #expect(distance >= CardColor.minimumAssignedHueSeparation, Comment(rawValue:
                    "generated hue \(generatedHue) sits \(distance) from worn slot \(slot) — " +
                    "under the very floor tier 2 just failed to clear"))
        }
    }

    /// The alpha fixture, named directly: worn = teal(4), blue(6),
    /// purple(8), pink(9) — the four ports of call around the wheel that
    /// were already occupied the day mint nearly landed next to teal.
    /// `preferred` is irrelevant to the result under the new rule (tier 2
    /// never reads it — `assign`'s own doc comment states why), which this
    /// test proves directly by trying every possible value and getting the
    /// identical answer back every time.
    ///
    /// Hand-computed scores for every free slot (min circular distance to
    /// {teal 0.5104, blue 0.5778, purple 0.8134, pink 0.9683}): orange
    /// 0.110 (to pink, through red), yellow 0.165 (to pink), green 0.135
    /// (to teal), mint 0.028 (to teal), cyan 0.018 (to teal), indigo 0.101
    /// (to blue), brown 0.102 (to pink, through red). Yellow's 0.165 is the
    /// widest margin of the seven — wider than green's 0.135, its nearest
    /// rival — so yellow wins outright.
    @Test("the alpha fixture: every candidate preferred value lands on yellow, the actual farthest slot")
    func alphaFixtureLandsOnYellowRegardlessOfPreferred() {
        let existing: [String: CardColor] = ["teal-dir": .slot(4), "blue-dir": .slot(6),
                                             "purple-dir": .slot(8), "pink-dir": .slot(9)]
        for preferred in 0..<CardColor.paletteCount {
            let result = CardColor.assign(existing: existing, preferred: preferred)
            #expect(result == .slot(1), Comment(rawValue:
                    "preferred \(preferred) -> \(result), expected .slot(1) (yellow) regardless"))
        }
    }

    /// A single worn hue — orange alone — and the winner is the wheel's
    /// own antipode: every OTHER free slot's distance to orange (0.0783)
    /// tops out well short of blue's 0.4995 (blue sits at 0.5778, almost
    /// exactly `0.0783 + 0.5`). The runner-up, mint, manages only 0.4042 —
    /// blue wins by a wide margin, not a near-tie.
    @Test("a single worn hue sends the winner to the wheel's own antipode")
    func singleWornHueLandsOnTheAntipode() {
        let existing: [String: CardColor] = ["orange-dir": .slot(0)]
        let result = CardColor.assign(existing: existing, preferred: 5)
        #expect(result == .slot(6), "expected blue (slot 6), the antipode of worn orange")
    }

    /// A directory closed weeks ago still has a RECORDED entry, and a
    /// fresh arrival must not be allowed to walk into that project's own
    /// remembered slot just because the project itself is not open right
    /// now. Two unrelated directories that happen to hash to the same
    /// `preferred` slot would otherwise trade it back and forth every time
    /// one of them happened to be the one currently closed — the
    /// cross-directory collision closed for the recorded-vs-live
    /// axis, unaffected by the removal of the live tier that
    /// used to sit below this one, or by the re-tiering of tier 2.
    ///
    /// The exact slot that comes back changed under the spread rule
    /// — brown (slot 10) now, not whatever the old "lowest free" rung would
    /// have produced — because a single worn cyan (0.5287) sends tier 2
    /// hunting for the FARTHEST free slot rather than the lowest-numbered
    /// one: brown (0.0705) scores 0.4582, edging out orange (0.0783) at
    /// 0.4504, the widest margin among the ten free slots. What must stay
    /// true regardless of that number is the one thing this test exists to
    /// prove: it is never slot 5, the parked slot itself.
    @Test("a recorded but absent project still holds its slot")
    func aRecordedButAbsentProjectStillHoldsItsSlot() {
        let existing: [String: CardColor] = ["dirA": .slot(5)]
        let result = CardColor.assign(existing: existing, preferred: 5)
        #expect(result != .slot(5), Comment(rawValue:
                "a closed project's recorded slot (5) was handed to a fresh arrival"))
        #expect(result == .slot(10), "expected brown (slot 10), the farthest free slot from worn cyan")
    }

    /// The old "lowest free slot" rung, replaced. Three low-numbered
    /// slots worn (orange, yellow, green) used to send this straight to
    /// mint (slot 3, the next unheld index) — the exact shape of reasoning
    /// that let alpha's mint land next to a worn teal elsewhere in this
    /// fixture. Under the spread rule, indigo (slot 7) wins instead: its
    /// score against the three worn hues (min distance to {orange 0.0783,
    /// yellow 0.1333, green 0.3753}) is 0.3039, comfortably ahead of the
    /// runner-up, purple, at 0.2649 — mint itself scores only 0.1072, one
    /// of the worst of the eight free slots, because it sits close to the
    /// worn green. `preferred` (1, deliberately one of the WORN slots) is
    /// irrelevant to the outcome, same as the alpha fixture above.
    @Test("three low slots worn: tier 2 spreads to indigo, not the old lowest-free mint")
    func assignSpreadsToTheFarthestFreeSlotRatherThanTheLowestIndex() {
        let existing: [String: CardColor] = ["a": .slot(0), "b": .slot(1), "c": .slot(2)]
        let result = CardColor.assign(existing: existing, preferred: 1)
        #expect(result == .slot(7), "expected indigo (slot 7), the farthest free slot from {orange, yellow, green}")
    }

    /// A tie, constructed to land bit-exact rather than merely close, with
    /// only purple(8) and pink(9) left free: `anchor` is their own exact
    /// midpoint, `(0.8134 + 0.9683) / 2 == 0.89085` — an addition with no
    /// rounding at all (verified: `0.89085 - 0.8134 == 0.9683` bit-for-bit),
    /// so the midpoint is the mathematically exact one, not an
    /// approximation. Built as a `.custom(hue: 0.89085, ...)`, it survives
    /// `hsbToRGB` then `rgbToHSB` and comes back as EXACTLY `0.89085` —
    /// confirmed by running the identical round trip in Python (IEEE754
    /// double arithmetic, bit-for-bit identical to Swift's `Double` for
    /// these same operations and operands) before trusting it here — so
    /// purple and pink both score exactly `0.07745000000000002` against it,
    /// not merely equal to displayed precision.
    ///
    /// The other nine named hues are held (`.slot`, table lookups — no
    /// round trip to introduce any doubt) precisely because every one of
    /// them sits FARTHER than that tied score from BOTH purple and pink
    /// (indigo, purple's own neighbour, is the closest at 0.1342; brown,
    /// pink's neighbour the short way through the wrap, is the next
    /// closest at 0.1022) — holding them removes them from contention
    /// without disturbing the tie the anchor alone determines. The tied
    /// score, 0.07745, clears `minimumAssignedHueSeparation` (0.05), so
    /// tier 2 actually resolves this rather than falling through to
    /// `generate`. Tier 2's tie-break rule (`assign`'s own doc comment:
    /// strict `>`, so the first slot to reach a score keeps it) resolves
    /// the tie toward the LOWER index: purple (8), not pink (9).
    @Test("a tied maximum score between two free slots breaks toward the lower index")
    func tiedMaximumScoreBreaksTowardTheLowerIndex() {
        var existing: [String: CardColor] = [:]
        for slot in [0, 1, 2, 3, 4, 5, 6, 7, 10] { existing["dir-\(slot)"] = .slot(slot) }
        existing["anchor-dir"] = .custom(hue: 0.89085, saturation: 1, brightness: 1)
        let result = CardColor.assign(existing: existing, preferred: 0)
        #expect(result == .slot(8), "expected purple (slot 8), the lower-index winner of an exact tie with pink (9)")
    }

    /// `.custom` still holds no NAMED slot — `heldRecorded` only ever grows
    /// from a `.slot` entry, so all eleven names remain CANDIDATES for tier
    /// 2 no matter how many customs are in play, and the winner here IS a
    /// named `.slot` (pink), proving the pool was never shrunk. What
    /// changed with the spread rule: a custom's hue now SCORES exactly like a worn
    /// `.slot` would. A single custom parked precisely at teal's own hue
    /// (0.5104) drags mint (0.0279), cyan (0.0183), and teal's own named
    /// slot (0.0, distance to itself) all to losing scores — the same three
    /// names a worn `.slot(4)` would have suppressed — while every OTHER
    /// name stays fully in play and pink wins outright at 0.4579, comfortably
    /// ahead of brown (0.4399) and orange (0.4321).
    @Test("a lone custom parked at teal's hue blocks mint, cyan, and teal from winning, exactly as a worn teal slot would")
    func customHueScoresAsWornGroundEvenThoughItHoldsNoNamedSlot() {
        let tealHue = 0.5104
        let existing: [String: CardColor] = ["a": .custom(hue: tealHue, saturation: 0.8, brightness: 0.9)]
        let result = CardColor.assign(existing: existing, preferred: 0)
        #expect(result == .slot(9), "expected pink (slot 9), the farthest named slot from the custom's teal hue")
        #expect(result != .slot(3) && result != .slot(4) && result != .slot(5), Comment(rawValue:
                "mint (3), teal (4), or cyan (5) won despite sitting under the floor from the custom's own hue"))
    }

    // ------------------------------------------------------ hueDistance

    @Test("hueDistance measures the short way around the wheel, through the keep-out if that is shorter")
    func hueDistanceMeasuresTheShortWayAroundTheCircle() {
        let distance = CardColor.hueDistance(0.9683, 0.0783)
        #expect(abs(distance - 0.11) < 1e-9, "pink and orange measure 0.11 apart through red, got \(distance)")
    }

    @Test("hueDistance is symmetric")
    func hueDistanceIsSymmetric() {
        #expect(CardColor.hueDistance(0.2, 0.8) == CardColor.hueDistance(0.8, 0.2))
        #expect(CardColor.hueDistance(0.9683, 0.0783) == CardColor.hueDistance(0.0783, 0.9683))
    }

    @Test("hueDistance answers zero for a hue measured against itself")
    func hueDistanceOfAHueAgainstItselfIsZero() {
        #expect(CardColor.hueDistance(0.5104, 0.5104) == 0)
        #expect(CardColor.hueDistance(0, 0) == 0)
    }

    // ---------------------------------------------------- assign, tier 3 · generate
    //
    // The headline rule: once every named slot is recorded,
    // `assign` stops handing out names and starts MAKING a colour.
    // `exhaustionGeneratesRatherThanRepeats` below is the RED-FIRST test
    // for the defect this rule exists to close — run against the OLD
    // five-tier `assign` (still carrying a `live:` parameter at the time)
    // it failed: a full palette handed back `.slot(3)`, a duplicate of
    // whichever directory already held that slot, rather than a `.custom`
    // colour distinct from every one of the eleven. `generate`'s own tests
    // follow, isolated from `assign` entirely — the pure hue arithmetic
    // `assign`'s tier 3 merely delegates to.

    @Test("exhaustion generates a fresh colour rather than repeating one")
    func exhaustionGeneratesRatherThanRepeats() {
        var existing: [String: CardColor] = [:]
        for i in 0..<CardColor.paletteCount {
            existing["project-\(i)"] = .slot(i)
        }
        let result = CardColor.assign(existing: existing, preferred: 3)
        guard case .custom = result else {
            Issue.record("a full palette handed back \(result) instead of generating a fresh colour")
            return
        }
        guard let generatedHue = result.hsb?.hue else {
            Issue.record("a .custom result answered nil for .hsb — the fixture's own premise")
            return
        }
        for i in 0..<CardColor.paletteCount {
            let occupied = CardColor.paletteHue(i)
            #expect(abs(generatedHue - occupied) > 0.0001,
                    "generated hue \(generatedHue) collided with named slot \(i)'s hue \(occupied)")
        }
    }

    /// Pure `generate`, isolated from `assign`'s own tiering — these pin
    /// the hue arithmetic directly: the largest-gap rule, the hand-computed
    /// fixture, the red keep-out, custom occupancy, sequential
    /// never-duplication, and tie-break determinism. `generate`'s own doc
    /// comment tells the full derivation; these pin the numbers.

    private let generateEpsilon = 0.001

    @Test("generate is deterministic — the same collection twice returns the identical colour")
    func generateIsDeterministic() {
        let existing: [CardColor] = (0..<CardColor.paletteCount).map { .slot($0) }
        let first = CardColor.generate(avoiding: existing)
        let second = CardColor.generate(avoiding: existing)
        #expect(first == second)
    }

    /// Hand-computed: sorted, the eleven named hues are brown (0.0705),
    /// orange (0.0783), yellow (0.1333), green (0.3753), mint (0.4825),
    /// teal (0.5104), cyan (0.5287), blue (0.5778), indigo (0.6792),
    /// purple (0.8134), pink (0.9683). Every consecutive gap: floor→brown
    /// 0.0405, brown→orange 0.0078, orange→yellow 0.0550, yellow→green
    /// 0.2420, green→mint 0.1072, mint→teal 0.0279, teal→cyan 0.0183,
    /// cyan→blue 0.0491, blue→indigo 0.1014, indigo→purple 0.1342,
    /// purple→pink 0.1549, pink→ceiling 0.0167. yellow→green is the
    /// widest by a wide margin, and its midpoint is (0.1333+0.3753)/2 =
    /// 0.2543.
    @Test("avoiding exactly the eleven named slots lands in the wheel's largest void")
    func handComputedFixtureLandsInYellowGreenGap() {
        let existing: [CardColor] = (0..<CardColor.paletteCount).map { .slot($0) }
        let result = CardColor.generate(avoiding: existing)
        guard let hue = result.hsb?.hue else {
            Issue.record("generate did not return a .custom colour")
            return
        }
        #expect(abs(hue - 0.2543) < generateEpsilon, "generated hue was \(hue), expected ≈0.2543")
    }

    /// Every generated hue, across a spread of occupancy including the two
    /// edges (nothing recorded at all, and a set already crowding the
    /// ceiling), stays inside the keep-out walls — `generate` must never
    /// wander into `.errored`'s own reserved red channel regardless of
    /// what it is avoiding.
    @Test("generate never wanders past the red keep-out", arguments: [
        [], // the degenerate case: nothing occupied at all
        (0..<CardColor.paletteCount).map { CardColor.slot($0) },
        [CardColor.custom(hue: 0.97, saturation: 1, brightness: 1),
         CardColor.custom(hue: 0.96, saturation: 1, brightness: 1),
         CardColor.custom(hue: 0.94, saturation: 1, brightness: 1)],
    ])
    func generateStaysInsideTheKeepOut(_ existing: [CardColor]) {
        let result = CardColor.generate(avoiding: existing)
        guard let hue = result.hsb?.hue else {
            Issue.record("generate did not return a .custom colour")
            return
        }
        #expect(hue >= 0.03 && hue <= 0.985, "generated hue \(hue) crossed the keep-out wall")
    }

    /// Nothing occupied at all: exactly one gap, the whole interval, and
    /// its midpoint is `(0.03 + 0.985) / 2 == 0.5075`.
    @Test("generate against an empty collection lands on the midpoint of the whole interval")
    func generateDegenerateCaseIsTheWholeIntervalsMidpoint() {
        let result = CardColor.generate(avoiding: [])
        guard let hue = result.hsb?.hue else {
            Issue.record("generate did not return a .custom colour")
            return
        }
        #expect(abs(hue - 0.5075) < generateEpsilon, "generated hue was \(hue), expected ≈0.5075")
    }

    /// A `.custom` colour parked exactly at the yellow→green midpoint
    /// (0.2543, the fixture two tests above) occupies that gap, so the
    /// NEXT-largest void — purple→pink, width 0.1549 — becomes the winner.
    /// Its midpoint: (0.8134 + 0.9683) / 2 ≈ 0.8909.
    @Test("a custom colour occupies the wheel and pushes the next generation into the second-largest gap")
    func customOccupancyPushesGenerationToTheSecondLargestGap() {
        var existing: [CardColor] = (0..<CardColor.paletteCount).map { .slot($0) }
        existing.append(.custom(hue: 0.2543, saturation: 1, brightness: 1))
        let result = CardColor.generate(avoiding: existing)
        guard let hue = result.hsb?.hue else {
            Issue.record("generate did not return a .custom colour")
            return
        }
        #expect(abs(hue - 0.8909) < generateEpsilon, "generated hue was \(hue), expected ≈0.8909")
    }

    /// Fold 20 generations, each fed back into the avoid set under a fresh
    /// key before the next one runs — the exact shape repeated calls to
    /// `assign` produce as a fleet's history grows past the palette's own
    /// size. Every one of the 20 must be pairwise distinct from every
    /// other, distinct from all eleven named hues, and inside the legal
    /// interval — the never-duplicate guarantee, exercised sequentially
    /// rather than asserted once in isolation.
    @Test("twenty sequential generations never duplicate each other or a named hue")
    func sequentialGenerationsNeverDuplicate() {
        var existing: [CardColor] = (0..<CardColor.paletteCount).map { .slot($0) }
        var generatedHues: [Double] = []
        for _ in 0..<20 {
            let next = CardColor.generate(avoiding: existing)
            guard let hue = next.hsb?.hue else {
                Issue.record("generate did not return a .custom colour")
                return
            }
            #expect(hue >= 0.03 && hue <= 0.985, "generated hue \(hue) crossed the keep-out wall")
            generatedHues.append(hue)
            existing.append(next)
        }
        for i in 0..<generatedHues.count {
            for j in 0..<CardColor.paletteCount {
                let namedHue = CardColor.paletteHue(j)
                #expect(abs(generatedHues[i] - namedHue) > 0.0001,
                        "generation #\(i) (\(generatedHues[i])) collided with named slot \(j)")
            }
            for j in (i + 1)..<generatedHues.count {
                #expect(abs(generatedHues[i] - generatedHues[j]) > 0.0001,
                        "generation #\(i) and #\(j) collided at \(generatedHues[i])")
            }
        }
    }

    /// Two gaps of identical width, constructed from exact binary
    /// fractions (eighths and sixteenths, each exactly representable in a
    /// `Double` with zero rounding error at every step — hue, the
    /// `hsbToRGB`/`rgbToHSB` round trip, and the gap subtraction alike) so
    /// the tie is bit-exact rather than a decimal approximation that
    /// floating-point noise could nudge one way or the other: three
    /// occupied points at hues 0.0625, 0.5, 0.9375 split the interval into
    /// `floor→0.0625` (0.0325), `0.0625→0.5` (0.4375), `0.5→0.9375`
    /// (0.4375), `0.9375→ceiling` (0.0475) — the middle two tie for
    /// largest. The rule breaks toward the LOWER start
    /// (`generate`'s own doc comment), so the answer is the FIRST tied
    /// gap's midpoint, `(0.0625 + 0.5) / 2 == 0.28125`, not the second
    /// tied gap's `(0.5 + 0.9375) / 2 == 0.71875`.
    @Test("a tie between two equally wide gaps breaks toward the lower-start gap, deterministically")
    func tieBreaksTowardTheLowerStartGap() {
        let existing: [CardColor] = [
            .custom(hue: 0.0625, saturation: 1, brightness: 1),
            .custom(hue: 0.5, saturation: 1, brightness: 1),
            .custom(hue: 0.9375, saturation: 1, brightness: 1),
        ]
        let first = CardColor.generate(avoiding: existing)
        let second = CardColor.generate(avoiding: existing)
        #expect(first == second, "generate answered two different colours for the identical tied input")
        guard let hue = first.hsb?.hue else {
            Issue.record("generate did not return a .custom colour")
            return
        }
        #expect(abs(hue - 0.28125) < generateEpsilon, Comment(rawValue:
                "generated hue was \(hue) — expected 0.28125 (the LOWER-start tied gap's midpoint), " +
                "not 0.71875 (the higher-start one)"))
    }

    // ---------------------------------------------------------- spokenName

    @Test("spokenName reads the palette entry for an in-range slot")
    func spokenNameReadsTheSlot() {
        #expect(CardColor.slot(0).spokenName == "orange")
        #expect(CardColor.slot(10).spokenName == "brown")
    }

    @Test("spokenName clamps an out-of-range slot via modulo rather than crashing")
    func spokenNameClampsOutOfRange() {
        #expect(CardColor.slot(11).spokenName == CardColor.slot(0).spokenName)
        #expect(CardColor.slot(-1).spokenName == CardColor.slot(10).spokenName)
        #expect(CardColor.slot(24).spokenName == CardColor.slot(2).spokenName)
    }

    @Test("spokenName names a custom colour honestly rather than guessing a palette word")
    func spokenNameForCustom() {
        let custom = CardColor.custom(red: 0.1, green: 0.2, blue: 0.3)
        #expect(custom.spokenName == "custom color")
    }

    // -------------------------------------------------------------- codec

    @Test("a slot round-trips through the JSONValue codec")
    func slotCodecRoundTrips() {
        let original = CardColor.slot(7)
        let decoded = CardColor.decode(original.encoded())
        #expect(decoded == original)
    }

    /// Doubles materialized as locals before the comparison — not spelled
    /// out inline inside `#expect` — the same discipline the whole suite
    /// applies to floating-point checks.
    @Test("a custom colour round-trips through the JSONValue codec")
    func customCodecRoundTrips() {
        let original = CardColor.custom(red: 0.25, green: 0.5, blue: 0.75)
        let decoded = CardColor.decode(original.encoded())
        #expect(decoded == original)
    }

    @Test("a malformed value decodes to nil rather than inventing a colour", arguments: [
        JSONValue.object([:]),
        JSONValue.object(["slot": .string("three")]),
        JSONValue.object(["custom": .object(["red": .number(0.1)])]),
        JSONValue.string("orange"),
        JSONValue.null,
    ])
    func malformedDecodesToNil(_ junk: JSONValue) {
        #expect(CardColor.decode(junk) == nil)
    }

    // ---------------------------------------------------------------- HSB
    //
    // The picker's own conversion — `hsbToRGB`/`rgbToHSB`, and the two
    // public entry points (`custom(hue:saturation:brightness:)`, `.hsb`)
    // built on them. Pinned against the palette's own named corners —
    // red, yellow, green, cyan, blue, magenta — rather than re-deriving
    // the expectation from the algorithm under test, the same discipline
    // `fallbackSlotIsPinned` above already holds itself to.

    /// Doubles materialized as locals before every comparison below — the
    /// suite's own discipline for floating-point `#expect`s, applied here
    /// because a bare tuple destructured straight into `#expect` reads no
    /// worse but hides which component actually drifted when one does.
    private let epsilon = 0.000_001

    /// A named corner of the wheel, HSB alongside the sRGB it should
    /// produce (or should be read back from). A NOMINAL type rather than a
    /// six-`Double` tuple — the tuple form type-checked correctly but timed
    /// the compiler out building the `@Test(arguments:)` array literal
    /// (`fatalError`, not a real failure); a `struct` gives the type
    /// checker one name to unify against instead of inferring a fresh
    /// six-way structural tuple type per element.
    private struct Corner: Sendable {
        let hue: Double, saturation: Double, brightness: Double
        let red: Double, green: Double, blue: Double
    }

    private static let corners: [Corner] = [
        Corner(hue: 0, saturation: 1, brightness: 1, red: 1, green: 0, blue: 0),          // red
        Corner(hue: 1.0 / 6, saturation: 1, brightness: 1, red: 1, green: 1, blue: 0),    // yellow
        Corner(hue: 1.0 / 3, saturation: 1, brightness: 1, red: 0, green: 1, blue: 0),    // green
        Corner(hue: 0.5, saturation: 1, brightness: 1, red: 0, green: 1, blue: 1),        // cyan
        Corner(hue: 2.0 / 3, saturation: 1, brightness: 1, red: 0, green: 0, blue: 1),    // blue
        Corner(hue: 5.0 / 6, saturation: 1, brightness: 1, red: 1, green: 0, blue: 1),    // magenta
    ]

    @Test("hsbToRGB lands on the palette's own named corners", arguments: corners)
    private func hsbToRGBHitsTheNamedCorners(_ corner: Corner) {
        let (r, g, b) = CardColor.hsbToRGB(hue: corner.hue, saturation: corner.saturation,
                                           brightness: corner.brightness)
        #expect(abs(r - corner.red) < epsilon, "red component")
        #expect(abs(g - corner.green) < epsilon, "green component")
        #expect(abs(b - corner.blue) < epsilon, "blue component")
    }

    @Test("hsbToRGB answers black and white honestly regardless of hue")
    func hsbToRGBHandlesAchromaticExtremes() {
        let black = CardColor.hsbToRGB(hue: 0.4, saturation: 1, brightness: 0)
        #expect(abs(black.red) < epsilon && abs(black.green) < epsilon && abs(black.blue) < epsilon)
        let white = CardColor.hsbToRGB(hue: 0.7, saturation: 0, brightness: 1)
        #expect(abs(white.red - 1) < epsilon && abs(white.green - 1) < epsilon && abs(white.blue - 1) < epsilon)
    }

    @Test("hsbToRGB wraps a hue outside 0...1 rather than answering off the wheel")
    func hsbToRGBWrapsHue() {
        let wrapped = CardColor.hsbToRGB(hue: 1.0, saturation: 1, brightness: 1)
        let baseline = CardColor.hsbToRGB(hue: 0.0, saturation: 1, brightness: 1)
        #expect(abs(wrapped.red - baseline.red) < epsilon)
        #expect(abs(wrapped.green - baseline.green) < epsilon)
        #expect(abs(wrapped.blue - baseline.blue) < epsilon)
    }

    @Test("rgbToHSB reads the same named corners back", arguments: corners)
    private func rgbToHSBReadsTheNamedCorners(_ corner: Corner) {
        let (h, s, v) = CardColor.rgbToHSB(red: corner.red, green: corner.green, blue: corner.blue)
        #expect(abs(h - corner.hue) < epsilon, "hue")
        #expect(abs(s - corner.saturation) < epsilon, "saturation")
        #expect(abs(v - corner.brightness) < epsilon, "brightness")
    }

    @Test("HSB round-trips through RGB and back within epsilon, across a spread of colours",
          arguments: [(0.0, 1.0, 1.0), (0.15, 0.6, 0.9), (0.42, 0.3, 0.75),
                      (0.5, 1.0, 0.5), (0.9, 0.2, 0.4), (0.99, 0.8, 0.2)])
    func hsbRoundTripsWithinEpsilon(_ hue: Double, _ saturation: Double, _ brightness: Double) {
        let (r, g, b) = CardColor.hsbToRGB(hue: hue, saturation: saturation, brightness: brightness)
        let (h2, s2, v2) = CardColor.rgbToHSB(red: r, green: g, blue: b)
        #expect(abs(h2 - hue) < epsilon, "hue: \(h2) vs \(hue)")
        #expect(abs(s2 - saturation) < epsilon, "saturation: \(s2) vs \(saturation)")
        #expect(abs(v2 - brightness) < epsilon, "brightness: \(v2) vs \(brightness)")
    }

    @Test("custom(hue:saturation:brightness:) produces the expected sRGB triple")
    func customFromHSBProducesExpectedComponents() {
        let color = CardColor.custom(hue: 1.0 / 3, saturation: 1, brightness: 1)
        guard case .custom(let red, let green, let blue) = color else {
            Issue.record("custom(hue:saturation:brightness:) did not build a .custom case")
            return
        }
        #expect(abs(red - 0) < epsilon)
        #expect(abs(green - 1) < epsilon)
        #expect(abs(blue - 0) < epsilon)
    }

    @Test(".hsb answers the exact triple a .custom colour was built from")
    func hsbAccessorAnswersACustomColorsOwnTriple() {
        let color = CardColor.custom(red: 0.2, green: 0.4, blue: 0.6)
        guard let hsb = color.hsb else {
            Issue.record(".hsb answered nil for a .custom colour")
            return
        }
        let rebuilt = CardColor.hsbToRGB(hue: hsb.hue, saturation: hsb.saturation, brightness: hsb.brightness)
        #expect(abs(rebuilt.red - 0.2) < epsilon)
        #expect(abs(rebuilt.green - 0.4) < epsilon)
        #expect(abs(rebuilt.blue - 0.6) < epsilon)
    }

    @Test(".hsb answers nil for a .slot — the core has no RGB for a palette name")
    func hsbAccessorIsNilForASlot() {
        #expect(CardColor.slot(3).hsb == nil)
    }
}
