//
//  PrefsTests.swift · Tests/DeckCoreTests
//
//  Preferences round-trip, and stay home.
//
//  The codec is total in both directions on purpose: a preferences file can be
//  wrong — hand-edited, written by a newer build, truncated by a full disk —
//  and none of those may stop the deck starting. What it must never do is
//  quietly lose something, so the properties here are "decode∘encode is the
//  identity" and "a key this version has never heard of survives it".
//

import Testing
import Foundation
@testable import DeckCore

struct PrefsTests {

    @Test("encoding and decoding a preference set returns exactly what went in")
    func codecRoundTripsExactly() {
        let original = DeckPrefs(
            quickActions: [QuickAction(id: "a", title: "Continue", kind: .prompt("continue")),
                           QuickAction(id: "b", title: "Stop", kind: .escape)],
            autoContinue: ["s1", "s2"],
            hidden: ["s3"],
            directoryColors: ["/w/proj-a": .slot(3), "/w/proj-b": .custom(red: 0.2, green: 0.4, blue: 0.6)],
            legacyCardColors: ["SURF-OLD": .slot(7)],
            deleted: ["s4"],
            windowSize: Canvas(width: 1100, height: 620),
            lastPane: "Actions",
            promptHistory: 5,
            holdBudget: .seconds(300))

        #expect(DeckPrefs.decode(original.encoded()) == original,
                "the round trip changed the value — a field was eaten or invented")
    }

    // ---------------------------------------------------------- hold budget
    //
    // `HoldPolicy.budget` derives from `holdBudget` on every `.prefsChanged`
    // (`Reducer.reduce`), so a codec defect here is a defect in the one
    // number the countdown, the installed hooks and `Hold.expiresAt` all
    // trace back to.

    /// Both `HoldBudget` shapes, not just the numeric one — `.untilAnswered`
    /// has no seconds to round-trip losslessly by accident.
    @Test("holdBudget round-trips both shapes", arguments: [
        HoldBudget.seconds(120), .seconds(300), .seconds(600), .untilAnswered,
    ])
    func holdBudgetRoundTrips(_ budget: HoldBudget) {
        var prefs = DeckPrefs()
        prefs.holdBudget = budget
        #expect(DeckPrefs.decode(prefs.encoded()).holdBudget == budget)
    }

    /// A missing key is "never edited", and the shipped default is 120 s —
    /// `HoldBudget.standard` — same reading `DeckPrefs()` gives it before any
    /// key is even looked at.
    @Test("a prefs file with no holdBudget key decodes to the standard budget")
    func missingHoldBudgetKeyDecodesToStandard() {
        #expect(DeckPrefs.decode(.object([:])).holdBudget == .standard)
        #expect(DeckPrefs.decode(.object(["promptHistory": .number(4)])).holdBudget == .standard)
    }

    /// The guard rail at the prefs boundary: a hand-edited file (or a future
    /// build with a lower floor) asking for less than ten seconds is clamped
    /// UP rather than honoured or refused — the same total-decoding posture
    /// `windowSize` and `promptHistory` already take, documented on
    /// `HoldBudget.clamped(seconds:)` itself.
    @Test("a holdBudget under the floor is clamped up, never refused", arguments: [
        (0, 10), (1, 10), (9, 10), (10, 10), (11, 11), (-50, 10),
    ])
    func holdBudgetClampsToTheFloor(_ pair: (asked: Int, expected: Int)) {
        let decoded = DeckPrefs.decode(.object(["holdBudget": .number(Double(pair.asked))]))
        #expect(decoded.holdBudget == .seconds(pair.expected))
    }

    /// A malformed value — neither a number nor the one recognised string —
    /// leaves the default standing, the same total-decoding rule every other
    /// field in this file follows: a prefs file can be wrong, and the deck
    /// still starts.
    @Test("an unrecognised holdBudget value is ignored rather than crashing the decode")
    func malformedHoldBudgetIsIgnored() {
        #expect(DeckPrefs.decode(.object(["holdBudget": .string("forever-ish")])).holdBudget == .standard)
        #expect(DeckPrefs.decode(.object(["holdBudget": .bool(true)])).holdBudget == .standard)
        #expect(DeckPrefs.decode(.object(["holdBudget": .number(.infinity)])).holdBudget == .standard,
                "an out-of-range Double reached Int(_:) and would have trapped the process")
    }

    /// **The ceiling, at the boundary a floor alone does not guard.**
    /// `9e18` is small enough to survive `Self.whole` (`Int(exactly:)`
    /// accepts it — 9e18 is still under `Int64.max`), and under the old
    /// constant `Int(Int64.max / 1_000)` the decoded milliseconds value would
    /// have overflowed even in the `millis` saturation. Under 604_800 (7 days),
    /// downstream arithmetic — `openedAt + budget` and the nanosecond
    /// conversions — also survives without trapping. Decoding must land on the
    /// ceiling and applying it through `.prefsChanged` must not trap.
    @Test("a holdBudget of 9e18 decodes to the ceiling and applies without trapping")
    func hugeHoldBudgetClampsToTheCeilingAndLaunches() {
        let decoded = DeckPrefs.decode(.object(["holdBudget": .number(9e18)]))
        #expect(decoded.holdBudget == .seconds(604_800),
                Comment(rawValue: "got \(decoded.holdBudget), want the 7-day ceiling"))

        var state = DeckState()
        Reducer.reduce(&state, .prefsChanged(decoded, at: Instant(sinceStart: Millis(0))))
        #expect(state.policy.budget != nil, "a seconds budget decoded to .untilAnswered's nil")
        #expect(state.policy.budget == Millis(Int64(604_800) * 1_000))

        // Open a hold under the ceiling budget. The event construction follows
        // the pattern from HoldBudgetTests: a permission request with a toolUseID
        // and held status.
        let sessionID = SessionID("s-huge")
        let toolUseID = "t-huge"
        let holdOpenAt = Instant(sinceStart: Millis(1000))
        Reducer.reduce(&state, .hook(HookEvent(id: EventID("open-huge"), at: holdOpenAt,
                                               kind: .permissionRequest, session: sessionID,
                                               cwd: nil, tool: "Bash", toolUseID: toolUseID,
                                               held: .value(1))))

        // Assert the hold exists and is open.
        let holdID = HoldID(session: sessionID, toolUseID: toolUseID)
        #expect(state.holds[holdID] != nil, "hold did not open")
        #expect(state.holds[holdID]?.isOpen == true)
        #expect(state.holds[holdID]?.budget == Millis(Int64(604_800) * 1_000),
                "hold did not pick up the ceiling budget from policy")

        // Project a frame at a later instant. This path exercises `openedAt +
        // budget` addition (Int64 + in Millis.+) and the decisions filter's
        // `expiresAt` comparison — the arithmetic that SIGTRAP'd under the old
        // Int64.max/1000 ceiling.
        let laterInstant = Instant(sinceStart: Millis(2000))
        let frame = Projection.frame(from: state, at: laterInstant)
        #expect(frame.decisions.count == 1, "the open hold did not appear in decisions")
        #expect(frame.decisions[0].hold == holdID, "the wrong hold appeared in decisions")
        // The test spans decode → prefsChanged → hold open → frame projection,
        // the full path the Int64.max/1000 ceiling used to trap on at the last step.
    }

    // ---------------------------------------------------- question hold budget
    //
    // `questionHoldBudget`'s own twin of the `holdBudget` suite just above —
    // the question-mirror arc's own preference, same shape, same total-
    // decoding posture, a DIFFERENT floor (`questionFloorSeconds`, 3, not
    // `floorSeconds`'s 10 — `HoldBudget.questionFloorSeconds`'s own doc
    // comment states why the two floors differ) and a different default
    // (`.questionStandard`, 8s).

    @Test("questionHoldBudget round-trips both shapes", arguments: [
        HoldBudget.seconds(3), .seconds(8), .seconds(60), .untilAnswered,
    ])
    func questionHoldBudgetRoundTrips(_ budget: HoldBudget) {
        var prefs = DeckPrefs()
        prefs.questionHoldBudget = budget
        #expect(DeckPrefs.decode(prefs.encoded()).questionHoldBudget == budget)
    }

    @Test("a prefs file with no questionHoldBudget key decodes to the question-standard budget")
    func missingQuestionHoldBudgetKeyDecodesToQuestionStandard() {
        #expect(DeckPrefs.decode(.object([:])).questionHoldBudget == .questionStandard)
        #expect(DeckPrefs.decode(.object(["promptHistory": .number(4)])).questionHoldBudget == .questionStandard)
    }

    /// The question budget's own guard rail — clamped UP to 3, not 10,
    /// the permission floor a hand-edited low question budget must NOT be
    /// held to (`HoldBudget.questionFloorSeconds`'s own doc comment states
    /// why a lower floor is deliberate here).
    @Test("a questionHoldBudget under the question floor is clamped up to 3, never to the permission floor", arguments: [
        (0, 3), (1, 3), (2, 3), (3, 3), (4, 4), (9, 9), (-50, 3),
    ])
    func questionHoldBudgetClampsToItsOwnFloor(_ pair: (asked: Int, expected: Int)) {
        let decoded = DeckPrefs.decode(.object(["questionHoldBudget": .number(Double(pair.asked))]))
        #expect(decoded.questionHoldBudget == .seconds(pair.expected))
    }

    @Test("an unrecognised questionHoldBudget value is ignored rather than crashing the decode")
    func malformedQuestionHoldBudgetIsIgnored() {
        #expect(DeckPrefs.decode(.object(["questionHoldBudget": .string("forever-ish")])).questionHoldBudget == .questionStandard)
        #expect(DeckPrefs.decode(.object(["questionHoldBudget": .bool(true)])).questionHoldBudget == .questionStandard)
        #expect(DeckPrefs.decode(.object(["questionHoldBudget": .number(.infinity)])).questionHoldBudget == .questionStandard,
                "an out-of-range Double reached Int(_:) and would have trapped the process")
    }

    /// `holdBudget` and `questionHoldBudget` decode INDEPENDENTLY — a file
    /// carrying one but not the other must not let either default leak
    /// into the wrong slot, and a file carrying both must decode both.
    @Test("holdBudget and questionHoldBudget decode independently of each other")
    func theTwoBudgetsDecodeIndependently() {
        let onlyPermission = DeckPrefs.decode(.object(["holdBudget": .number(300)]))
        #expect(onlyPermission.holdBudget == .seconds(300))
        #expect(onlyPermission.questionHoldBudget == .questionStandard)

        let onlyQuestion = DeckPrefs.decode(.object(["questionHoldBudget": .number(15)]))
        #expect(onlyQuestion.holdBudget == .standard)
        #expect(onlyQuestion.questionHoldBudget == .seconds(15))

        let both = DeckPrefs.decode(.object(["holdBudget": .string("untilAnswered"),
                                             "questionHoldBudget": .number(30)]))
        #expect(both.holdBudget == .untilAnswered)
        #expect(both.questionHoldBudget == .seconds(30))
    }

    /// **Belt and braces, tested separately.** `clamped(seconds:)` keeps
    /// `.seconds` from ever CARRYING more than the ceiling in practice, but
    /// `HoldBudget.seconds(_:)` is a public initialiser on a public case —
    /// nothing stops a future caller from building one directly, the same
    /// way `clamped(seconds:)` itself does not stop `DeckPrefs.holdBudget`
    /// from being set by hand in a test or a migration. `.millis` saturates
    /// rather than traps regardless of how its value arrived, so this drives
    /// it with `Int.max` directly — well past the ceiling, and RAW, with no
    /// clamp in between — rather than through `decode`.
    @Test("HoldBudget.seconds(Int.max).millis saturates instead of trapping")
    func rawIntMaxSecondsSaturatesInMillis() {
        let raw = HoldBudget.seconds(Int.max)
        #expect(raw.millis == Millis(.max),
                Comment(rawValue: "got \(String(describing: raw.millis)), want Millis(Int64.max)"))

        // And the ceiling-clamped path, which is what decode actually
        // produces, stays comfortably inside `Int64` without needing the
        // saturate at all — the two layers guard different distances.
        let clamped = HoldBudget.clamped(seconds: Int.max)
        #expect(clamped == .seconds(HoldBudget.ceilingSeconds))
        #expect(clamped.millis == Millis(Int64(HoldBudget.ceilingSeconds) * 1_000))
    }

    /// A newer build's key must come back out untouched, or upgrading and then
    /// downgrading silently destroys settings the newer build still needs.
    @Test("a key this version does not understand survives the round trip")
    func unknownKeysAreRetained() {
        let stored = JSONValue.object([
            "promptHistory": .number(4),
            "somethingFromTheFuture": .string("keep me"),
            "aNestedFutureThing": .object(["depth": .number(2)]),
        ])

        guard case .object(let out) = DeckPrefs.decode(stored).encoded() else {
            Issue.record("prefs did not round-trip as an object")
            return
        }
        #expect(out["somethingFromTheFuture"] == .string("keep me"))
        #expect(out["aNestedFutureThing"] == .object(["depth": .number(2)]))
    }

    /// Total decoding: the deck cannot refuse to start over a bad file.
    @Test("anything that is not an object decodes as first-run", arguments: [
        JSONValue.null,
        JSONValue.string("not prefs at all"),
        JSONValue.number(42),
        JSONValue.array([.string("nope")]),
    ])
    func malformedPrefsDecodeAsFirstRun(_ junk: JSONValue) {
        #expect(DeckPrefs.decode(junk) == .firstRun)
    }

    /// Absent is not the same fact as empty. "Never edited" must yield the
    /// shipped set; "removed them all" must yield none.
    @Test("an absent action list means never edited, an empty one means emptied")
    func absentAndEmptyActionListsAreDifferentFacts() {
        #expect(DeckPrefs.decode(.object([:])).quickActions == QuickAction.shipped)
        #expect(DeckPrefs.decode(.object(["quickActions": .array([])])).quickActions.isEmpty)
    }

    // ------------------------------------------- label ⟂ message
    //
    // `QuickAction.title` became `String?` — absent means derived, the same
    // absent-vs-empty posture `directoryColors`/`cardOrder` already take
    // (their own tests above and below this one). These pin the wire shape
    // directly, one layer above `QuickActionTests`' own pure-function tests.

    /// **A stored `"title"` key decodes explicit; an absent one decodes
    /// derived — present vs. absent, not present-but-empty.** Round-tripped
    /// both ways: a derived row's re-encoding must omit the key again, not
    /// write it back out as `""`.
    @Test("a stored title key decodes explicit; an absent one decodes derived, and re-encodes absent again")
    func quickActionTitleRoundTripsExplicitOrDerived() {
        let stored = JSONValue.object(["quickActions": .array([
            .object(["id": .string("explicit"), "title": .string("My Label"), "prompt": .string("do a thing")]),
            .object(["id": .string("derived"), "prompt": .string("Ship it")]),   // no "title" key at all
        ])])
        let decoded = DeckPrefs.decode(stored)
        #expect(decoded.quickActions.map(\.id) == ["explicit", "derived"])
        #expect(decoded.quickActions[0].title == "My Label")
        #expect(decoded.quickActions[1].title == nil,
                "a row with no stored \"title\" key should decode with title == nil, not an empty string")
        #expect(decoded.quickActions[1].displayTitle == "Ship it")

        guard case .object(let reencoded) = decoded.encoded(),
              case .array(let rows)? = reencoded["quickActions"] else {
            Issue.record("prefs did not re-encode quickActions as an array")
            return
        }
        for row in rows {
            guard case .object(let o) = row, case .string(let id)? = o["id"] else {
                Issue.record("a re-encoded row lost its id")
                continue
            }
            if id == "explicit" {
                #expect(o["title"] == .string("My Label"))
            } else if id == "derived" {
                #expect(o["title"] == nil,
                        "a derived row's re-encoding wrote a \"title\" key that was never stored")
            }
        }
    }

    /// **The migration-is-nothing claim, pinned.** Every row a person had
    /// stored before this feature shipped carries an explicit `"title"` —
    /// the only shape the wire format ever wrote. Decoding that exact blob
    /// today must produce the identical label on every row, byte for byte:
    /// nobody's buttons change just because the type underneath grew a
    /// `nil` case.
    @Test("a prefs blob written in today's format — every row titled — decodes with every label unchanged")
    func priorFormatBlobDecodesWithLabelsUnchanged() {
        let stored = JSONValue.object(["quickActions": .array([
            .object(["id": .string("continue"), "title": .string("Continue"), "prompt": .string("Continue")]),
            .object(["id": .string("compact"), "title": .string("/compact"), "prompt": .string("/compact")]),
            .object(["id": .string("escape"), "title": .string("Escape Key"), "escape": .bool(true)]),
            .object(["id": .string("mine"), "title": .string("Ship it"), "prompt": .string("commit and push")]),
        ])])
        let decoded = DeckPrefs.decode(stored)
        #expect(decoded.quickActions.map(\.displayTitle) == ["Continue", "/compact", "Escape Key", "Ship it"],
                Comment(rawValue: "got \(decoded.quickActions.map(\.displayTitle)) — an old-format row's label "
                        + "moved"))
        // And every one of them decoded EXPLICIT, not derived — the wire
        // never omitted the key before this feature, so nothing here should
        // read as nil.
        #expect(decoded.quickActions.allSatisfy { $0.title != nil },
                "an old-format row with an explicit \"title\" key decoded as derived")
    }

    /// **The migration-is-nothing claim.** The identical blob
    /// `priorFormatBlobDecodesWithLabelsUnchanged` just above already pins
    /// for titles carries no `"folders"` key on any row — nothing before
    /// `QuickAction.Scope` existed ever wrote one — so decoding it today
    /// must produce `.everywhere` on every row, exactly as an absent key
    /// decodes for a brand-new one.
    @Test("a prefs blob written before Scope existed decodes with every action .everywhere")
    func priorFormatBlobDecodesWithEveryActionEverywhere() {
        let stored = JSONValue.object(["quickActions": .array([
            .object(["id": .string("continue"), "title": .string("Continue"), "prompt": .string("Continue")]),
            .object(["id": .string("compact"), "title": .string("/compact"), "prompt": .string("/compact")]),
            .object(["id": .string("escape"), "title": .string("Escape Key"), "escape": .bool(true)]),
            .object(["id": .string("mine"), "title": .string("Ship it"), "prompt": .string("commit and push")]),
        ])])
        let decoded = DeckPrefs.decode(stored)
        #expect(decoded.quickActions.allSatisfy { $0.scope == .everywhere },
                "a row stored before Scope existed decoded as anything other than .everywhere")
    }

    /// **`QuickAction.maxOffered` (10) is enforced by `offerable(_:)`, not
    /// by the codec — a stored row past the cap is a row the PANEL never
    /// shows, not a row that stopped existing.** Encoding twelve rows and
    /// decoding them back must round-trip all twelve, byte for byte —
    /// the same "decode∘encode is the identity" property this file's own
    /// doc states for every other field, held here specifically against a
    /// cap that lives one layer up, in `QuickAction.rejection(at:among:)`,
    /// which this codec never calls.
    @Test("stored rows past the offered cap survive encode/decode unchanged")
    func storedRowsPastTheCapSurviveDecode() {
        let twelve = (0..<12).map { QuickAction(id: "a\($0)", title: "Title \($0)", kind: .prompt("go")) }
        var prefs = DeckPrefs()
        prefs.quickActions = twelve
        let decoded = DeckPrefs.decode(prefs.encoded())
        #expect(decoded.quickActions == twelve,
                Comment(rawValue: "got \(decoded.quickActions.count) rows back, expected all 12 — the cap "
                        + "must not reach into the codec"))
    }

    // ---------------------------------------------------------- directoryColors
    //
    // Unlike `quickActions`, there is no user action in this phase that
    // CLEARS an assigned colour — only ones that add one — so absent and
    // empty carry the same fact here: nothing assigned yet. `encoded()`
    // chose to omit the key rather than write `{}`, and this is what pins
    // that choice against a regression that starts writing it.

    @Test("an absent directoryColors key decodes to an empty map, which encodes back to no key at all")
    func absentDirectoryColorsKeyRoundTripsThroughOmission() {
        #expect(DeckPrefs.decode(.object([:])).directoryColors.isEmpty)

        var prefs = DeckPrefs()
        prefs.directoryColors = [:]
        guard case .object(let encoded) = prefs.encoded() else {
            Issue.record("prefs did not encode as an object")
            return
        }
        #expect(encoded["directoryColors"] == nil,
                "an empty map wrote the key — there is no chosen-vs-cleared fact to preserve for it")
    }

    /// One bad row drops that directory's entry, not the whole map — the
    /// same total-decode posture every other field in this file takes.
    @Test("a malformed directoryColors entry is dropped, the rest of the map survives")
    func directoryColorsEntryWiseTolerance() {
        let stored = JSONValue.object([
            "directoryColors": .object([
                "/good/dir": .object(["slot": .number(3)]),
                "/bad/dir": .object(["slot": .string("not a number")]),
                "/also/good": .object(["custom": .object([
                    "red": .number(0.1), "green": .number(0.2), "blue": .number(0.3),
                ])]),
            ]),
        ])
        let decoded = DeckPrefs.decode(stored)
        #expect(decoded.directoryColors["/good/dir"] == .slot(3))
        #expect(decoded.directoryColors["/bad/dir"] == nil, "a malformed entry survived the decode")
        let alsoGood = decoded.directoryColors["/also/good"]
        let expectedCustom = CardColor.custom(red: 0.1, green: 0.2, blue: 0.3)
        #expect(alsoGood == expectedCustom)
    }

    @Test("an unknown key inside a directoryColors entry is ignored rather than failing the whole entry")
    func directoryColorsEntryIgnoresUnknownKeys() {
        let stored = JSONValue.object([
            "directoryColors": .object([
                "/d1": .object(["slot": .number(2), "fromTheFuture": .string("keep me out")]),
            ]),
        ])
        #expect(DeckPrefs.decode(stored).directoryColors["/d1"] == .slot(2))
    }

    /// `directoryColors` is a Dictionary, not a Set-derived array, so it
    /// needs no explicit `.sorted()` the way `autoContinue`/`hidden`/`deleted`
    /// do at `encoded()` (:313–317's own churn doctrine) — `PrefsStore
    /// .data(from:)` serialises every `.object` with `JSONSerialization`'s
    /// `.sortedKeys` option, which fixes the byte order on disk regardless
    /// of this Dictionary's own iteration order. That serialiser lives in
    /// `DeckAdapters`, outside this target's reach, so what this test can
    /// actually prove is the half of "no churn" visible from here:
    /// `encoded()` is a pure function of the value, and the same prefs
    /// produce an equal `JSONValue` tree every time it is called.
    @Test("encoding the same directoryColors twice produces the identical JSONValue tree")
    func directoryColorsEncodingIsDeterministic() {
        var prefs = DeckPrefs()
        prefs.directoryColors = ["/z": .slot(2), "/a": .custom(red: 0.1, green: 0.2, blue: 0.3), "/m": .slot(9)]
        #expect(prefs.encoded() == prefs.encoded())
    }

    // ---------------------------------------------------------------- cardOrder
    //
    // `cardOrder`'s own doc comment states the shape: a `[String]` of
    // surfaces where ORDER is the payload, and absent/empty carry the same
    // fact (like `directoryColors` just above, unlike `hidden`/`autoContinue`).

    @Test("cardOrder round-trips in order")
    func cardOrderRoundTripsInOrder() {
        var prefs = DeckPrefs()
        prefs.cardOrder = ["surf-C", "surf-A", "surf-B"]
        #expect(DeckPrefs.decode(prefs.encoded()).cardOrder == ["surf-C", "surf-A", "surf-B"])
    }

    /// Entry-wise tolerant, the same posture every other array field in this
    /// file takes: one bad row drops only itself.
    @Test("a non-string cardOrder entry is dropped, the rest of the order survives")
    func cardOrderDropsNonStringEntriesEntryWise() {
        let stored = JSONValue.object([
            "cardOrder": .array([.string("surf-A"), .number(42), .string("surf-B"), .bool(true)]),
        ])
        #expect(DeckPrefs.decode(stored).cardOrder == ["surf-A", "surf-B"])
    }

    /// A duplicate surface is a malformed fact, not a legitimate repeat —
    /// resolved once at decode, keeping the FIRST occurrence, so a merge
    /// that reads position as rank never has to reason about which one won.
    @Test("a duplicate cardOrder entry is deduped, keeping the first occurrence")
    func cardOrderDedupesKeepingFirstOccurrence() {
        let stored = JSONValue.object([
            "cardOrder": .array([.string("surf-A"), .string("surf-B"), .string("surf-A")]),
        ])
        #expect(DeckPrefs.decode(stored).cardOrder == ["surf-A", "surf-B"])
    }

    @Test("an absent cardOrder key decodes to an empty order")
    func absentCardOrderKeyDecodesToEmpty() {
        #expect(DeckPrefs.decode(.object([:])).cardOrder.isEmpty)
    }

    @Test("an empty cardOrder encodes back to no key at all — absent and empty are the same fact")
    func emptyCardOrderEncodesToAbsence() {
        var prefs = DeckPrefs()
        prefs.cardOrder = []
        guard case .object(let encoded) = prefs.encoded() else {
            Issue.record("prefs did not encode as an object")
            return
        }
        #expect(encoded["cardOrder"] == nil,
                "an empty order wrote the key — there is no chosen-vs-cleared fact to preserve for it")
    }

    /// Adding `cardOrder` to `knownKeys` must not disturb retention of a key
    /// this version still does not understand — the same falsifier
    /// `unknownKeysAreRetained` already pins for the type generally, held
    /// here specifically against the new key's own arrival.
    @Test("a stored cardOrder key is consumed, not retained, and an unrelated unknown key still survives beside it")
    func cardOrderIsKnownAndDoesNotDisplaceOtherRetention() {
        let stored = JSONValue.object([
            "cardOrder": .array([.string("surf-A")]),
            "somethingFromTheFuture": .string("keep me"),
        ])
        let decoded = DeckPrefs.decode(stored)
        #expect(decoded.cardOrder == ["surf-A"])
        guard case .object(let out) = decoded.encoded() else {
            Issue.record("prefs did not round-trip as an object")
            return
        }
        #expect(out["somethingFromTheFuture"] == .string("keep me"))
        #expect(out["cardOrder"] == .array([.string("surf-A")]))
    }

    // ------------------------------------------------------- legacyCardColors
    //
    // The migration map: a stored `"cardColors"` object — the OLD,
    // surface-keyed shape — must decode into `legacyCardColors` rather than
    // `directoryColors`, and must keep re-encoding under the OLD key while
    // it still has an entry, so a person who quits before the reducer has
    // drained every lane does not lose the rest of the migration on the
    // next launch.

    @Test("a legacy cardColors object decodes into legacyCardColors, not directoryColors")
    func legacyCardColorsDecodesUnderTheOldKey() {
        let stored = JSONValue.object([
            "cardColors": .object(["SURF-OLD": .object(["slot": .number(4)])]),
        ])
        let decoded = DeckPrefs.decode(stored)
        #expect(decoded.legacyCardColors["SURF-OLD"] == .slot(4))
        #expect(decoded.directoryColors.isEmpty,
                "a surface-keyed legacy entry landed directly in the directory-keyed map")
    }

    /// While `legacyCardColors` still has something in it, `encoded()`
    /// writes it back out under the OLD `"cardColors"` key — not
    /// `"directoryColors"` — so a launch that has not yet re-seen every
    /// legacy surface does not silently drop what is left of the migration.
    @Test("a non-empty legacyCardColors re-encodes under the old cardColors key")
    func legacyCardColorsReencodesUnderTheOldKeyWhileNonEmpty() {
        var prefs = DeckPrefs()
        prefs.legacyCardColors = ["SURF-OLD": .slot(4)]
        guard case .object(let encoded) = prefs.encoded() else {
            Issue.record("prefs did not encode as an object")
            return
        }
        #expect(encoded["cardColors"] == .object(["SURF-OLD": .object(["slot": .number(4)])]))
        #expect(encoded["directoryColors"] == nil,
                "a legacy entry leaked into the new key before ever being adopted")
    }

    /// The drain's own endpoint: once `legacyCardColors` is empty — every
    /// entry adopted or discarded — `encoded()` stops mentioning the old
    /// key entirely, the same absent-vs-empty posture `directoryColors`
    /// itself takes. A fully migrated prefs file has no reason to keep
    /// naming a scheme that no longer has any entries.
    @Test("an emptied legacyCardColors omits the old cardColors key")
    func emptiedLegacyCardColorsOmitsTheOldKey() {
        var prefs = DeckPrefs()
        prefs.legacyCardColors = [:]
        guard case .object(let encoded) = prefs.encoded() else {
            Issue.record("prefs did not encode as an object")
            return
        }
        #expect(encoded["cardColors"] == nil)
    }

    /// Both maps round-trip independently through one prefs file that
    /// carries both keys at once — the mid-migration state a real user's
    /// disk is in for however many launches the drain takes.
    @Test("directoryColors and legacyCardColors decode independently from one stored object")
    func bothColorMapsDecodeIndependently() {
        let stored = JSONValue.object([
            "directoryColors": .object(["/w/new": .object(["slot": .number(1)])]),
            "cardColors": .object(["SURF-OLD": .object(["slot": .number(2)])]),
        ])
        let decoded = DeckPrefs.decode(stored)
        #expect(decoded.directoryColors["/w/new"] == .slot(1))
        #expect(decoded.legacyCardColors["SURF-OLD"] == .slot(2))
    }
}
