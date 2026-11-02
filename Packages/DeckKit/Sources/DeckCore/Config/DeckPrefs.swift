//
//  DeckPrefs.swift · DeckCore/Config
//
//  The deck's own preferences, as a value.
//
//  Decoded by hand from `JSONValue`, the same way every wire decoder here is:
//  total, lossless, unknown-tolerant. The lossless half matters most: **a
//  downgrade must not eat an upgrade's settings**, so keys this version does
//  not understand ride along in `retained` and are written back verbatim.
//  Codable synthesis silently drops them.
//
//  None of this touches `~/.claude`. The own-container and strip-never-writes
//  rules are about the *user's* Claude config; these are the deck's own, and
//  the storage location is named only inside the prefs adapter.
//

import Foundation

/// full / reduced / off — ordered, because the accessibility meet clamps
/// downward and "at most reduced" needs an order to mean something.
public enum MotionLevel: String, Equatable, Codable, Sendable, Comparable {
    case off, reduced, full
    private var rank: Int { self == .off ? 0 : self == .reduced ? 1 : 2 }
    public static func < (a: MotionLevel, b: MotionLevel) -> Bool { a.rank < b.rank }
}

/// How long an open hold waits for a human before the deck lets it go.
///
/// Everything else derives from this one value by construction — the
/// one-source countdown rule: `HoldPolicy.budget`, `Hold.expiresAt`, the
/// `frame.decisions` filter, the installed hooks' curl `--max-time` and the
/// engine's own per-command `timeout`, and `timeoutDrift`'s expected number.
/// Changing it here and nowhere else is the whole point of the type.
///
/// `.untilAnswered` is a legitimate supervision mode, not an edge case: the
/// engine's OWN terminal dialog already waits forever for an answer. The enum
/// has a case with no number in it rather than a sentinel duration.
public enum HoldBudget: Equatable, Hashable, Codable, Sendable {
    case seconds(Int)
    /// No deck-side timer at all. The engine's own per-command fallback
    /// (`SettingsMerge`'s 24-hour ceiling) is the only net once this is chosen.
    case untilAnswered

    /// The default.
    public static let standard = HoldBudget.seconds(120)

    /// The floor at the prefs boundary. Under it a hold expires before a human
    /// can finish reading what it is about.
    public static let floorSeconds = 10

    /// The ceiling at the prefs boundary. Seconds-mode is for humans; the true
    /// forever is `.untilAnswered`. A week-scale ceiling keeps every downstream
    /// sum and conversion (openedAt+budget, nanoseconds, the written n+5/n+10)
    /// far from overflow: a bare `openedAt + budget` in `Hold.expiresAt` and
    /// DeckRuntime's `UInt64(budgetMs.raw) * 1_000_000` conversion both trap near
    /// Int64.max/1000. Keep the millis saturation as belt-and-braces.
    public static let ceilingSeconds = 604_800  // 7 days

    /// Clamped, never refused (the same total-decoding posture as
    /// `DeckPrefs.decode`): a hand-edited "3" becomes the floor, "9e18" the ceiling.
    public static func clamped(seconds: Int) -> HoldBudget {
        .seconds(min(max(seconds, floorSeconds), ceilingSeconds))
    }

    /// **The default for `AskUserQuestion` holds: 8s, not `standard`'s 120s.**
    /// A released permission hold is gone (answered `{}`, no second surface),
    /// so its floor protects the human's reading window. A released QUESTION
    /// hold is not gone: the mirror stays rendered ("released", not "retired";
    /// see `Resolution`'s `.release`) and the CLI's own picker takes over
    /// within its measured ~7s ramp (`LV38-question-mirror-PROVENANCE.md`,
    /// PermissionRequest to Notification gap). A present user gets an 8s
    /// instant-answer window; an absent one sees a ~15s worst case (8 + the
    /// CLI ramp) instead of 120s of dead terminal.
    public static let questionStandard = HoldBudget.seconds(8)

    /// **The question budget's floor: 3, lower than `floorSeconds`' 10.**
    /// Releasing a question hold early is not the last chance to answer, since
    /// the mirror stays rendered and the terminal's picker takes over, so there
    /// is no vanishing-dialog hazard to protect against.
    public static let questionFloorSeconds = 3

    /// `clamped(seconds:)` at the question floor. Shares `ceilingSeconds` for
    /// the same overflow reasons.
    public static func clampedForQuestion(seconds: Int) -> HoldBudget {
        .seconds(min(max(seconds, questionFloorSeconds), ceilingSeconds))
    }

    /// What `HoldPolicy.budget` carries. `nil` is `.untilAnswered`, not a
    /// sentinel duration. See `HoldPolicy.budget` for why `Millis?`.
    ///
    /// Saturating rather than a bare `Int64(n) * 1_000`: decode is the only
    /// writer of `.seconds` today, but it is a public case, and a bare
    /// multiply overflowing would crash the process when `.prefsChanged` next
    /// reads it.
    public var millis: Millis? {
        switch self {
        case .seconds(let n):
            let (product, overflowed) = Int64(n).multipliedReportingOverflow(by: 1_000)
            return Millis(overflowed ? .max : product)
        case .untilAnswered: return nil
        }
    }
}

public struct DeckPrefs: Equatable, Sendable {

    /// The actions the panel offers. **User-definable**; the shipped set is a
    /// starting point.
    ///
    /// This text persists to disk deliberately: the redaction rule governs
    /// content that arrived FROM a session (prompts, commands, paths), while a
    /// quick action's words are typed INTO the deck by the user, like a theme
    /// id. The export ban still holds: they may never reach a `Diagnostic`, a
    /// log line, or a crash report.
    public var quickActions: [QuickAction]
    /// Surfaces whose sessions continue themselves when a usage window resets.
    ///
    /// **Keyed on the SURFACE, not the session.** A session id is per
    /// invocation — `/exit` and relaunch in the same tab and it is a different
    /// UUID — so a preference keyed on one evaporates the first time somebody
    /// restarts a session, which is the moment they would least expect to lose
    /// it. A tab is the thing a person points at and means.
    public var autoContinue: Set<String>
    /// **Whether a session the deck has never seen before starts armed (the
    /// standing default, distinct from the per-surface answers in
    /// `autoContinue`).**
    ///
    /// Off by default: arming means the deck will type into somebody's
    /// terminal unprompted, which is something to opt into.
    ///
    /// **Applied at WRITE time, once per surface, never re-applied.** A
    /// read-time fallback for any surface `autoContinue` does not name cannot
    /// represent "I turned this one off" (absence would mean both "never
    /// decided" and "declined"), so the next render would re-arm a session the
    /// user just disarmed. `autoContinueRefused` makes the write-time reading
    /// total.
    ///
    /// It also matches what the setting SAYS: "New sessions" is about sessions
    /// that arrive after the switch is thrown. A read-time default would
    /// retroactively arm every session already on the deck, which is what the
    /// separate "Turn On for All Sessions" button is for.
    public var autoContinueByDefault: Bool
    /// **Panes the user has explicitly REFUSED ("never auto-continue this
    /// tab"), the only direction that needs remembering.**
    ///
    /// Recording hand-set answers in both directions forced readers to infer
    /// direction from elsewhere (a decided pane that was armed must have been
    /// decided on). That is false once anything else arms a pane: "Turn On for
    /// All Sessions" arms without recording a decision, so a refused tab that
    /// was bulk-armed then bulk-disarmed came out re-armable.
    ///
    /// Keeping only refusals removes the inference. A pane decided ON needs no
    /// record (it is in `autoContinue`); a pane decided OFF is the one case the
    /// default must not overrule.
    ///
    /// Cleared for a pane by turning it back on, by hand or by "Turn On for All
    /// Sessions". NOT cleared by "Turn Off for All Sessions", which is an
    /// opinion about the sessions in front of you, not a standing rule about
    /// their tabs.
    public var autoContinueRefused: Set<String>
    /// Surfaces whose lanes are off the strip.
    ///
    /// Keyed on the surface for the same reason as `autoContinue`: a tab is what
    /// a person points at, and it survives the `/exit` that gives a session a
    /// new id.
    ///
    /// **A hidden lane is still a lane.** It stays in the frame, keeps its
    /// state, and is still counted by the mast: conservation holds over every
    /// lane including scrolled-off ones, and a hidden session that needs you
    /// must not be concealed. Hiding takes it off the strip, not out of the count.
    public var hidden: Set<String>
    /// The user's manual fleet order: SURFACES, most significant first.
    ///
    /// Keyed on the SURFACE like `hidden`: a session id lasts one CLI
    /// invocation, and the pane a person dragged outlives it.
    ///
    /// **Array order IS the payload.** No rank field or timestamp; readers
    /// (`Projection.manualOrder`, the merge at `Frame.swift`) use the index as
    /// the sort key.
    ///
    /// **Absent and empty mean the same thing, like `directoryColors` and
    /// unlike `hidden`:** nothing clears a manual order as a distinct action
    /// from removing every card one at a time.
    public var cardOrder: [String]
    /// The identity colour each PROJECT's cards wear, once assigned.
    ///
    /// **Keyed on the DIRECTORY, not the surface.** Two sessions on the same
    /// working directory are the same project and must share one colour. `cwd`
    /// survives an `/exit`, a relaunch, and a tab closing and a fresh one
    /// opening on the same directory; a surface id does not.
    ///
    /// **Entries are retained for absent directories on purpose; there is no
    /// GC.** A project reopened next week keeps its colour. What keeps a parked
    /// entry from starving a fresh arrival is `CardColor.assign`'s three-tier
    /// rule (a RECORDED entry outranks an unrecorded one, and exhausting the
    /// named tiers GENERATES a fresh colour). Growth is bounded by the number of
    /// working trees someone opened a session in, unlike `deleted`'s UUIDs.
    public var directoryColors: [String: CardColor]
    /// The OLD surface-keyed colour map, carried forward only long enough for
    /// the reducer to drain it into `directoryColors`.
    ///
    /// This is a MIGRATION field. A stored `"cardColors"` object decodes HERE,
    /// and `Reducer.recordCardColorIfNeeded` consumes one entry per lane, by the
    /// lane's SURFACE, once that lane's directory is learned, adopting the old
    /// colour onto the new key when it is spread far enough from the colours
    /// already worn (`CardColor.minimumAssignedHueSeparation`; `.custom` is
    /// exempt). Nothing writes a NEW entry into it, only removes one; an
    /// abandoned tab's entry rides along harmlessly.
    ///
    /// `encoded()` re-serialises this under `"cardColors"` while non-empty, so
    /// quitting mid-drain does not lose the rest (draining may take more than
    /// one boot), and omits the key once empty.
    public var legacyCardColors: [String: CardColor]
    /// Sessions removed from the deck entirely. **Session ids, not surfaces.**
    ///
    /// Delete is about the INSTANCE, which is what makes "nothing happens to
    /// the Claude Code process" honest: `/exit` and start a fresh session in the
    /// same tab and it appears normally, because it is a different session. A
    /// tombstone that outlived its subject would become "why will my new
    /// session not show up?" — a trap with no visible cause.
    ///
    /// Persisted, or delete would evaporate on every relaunch. Garbage-collected
    /// when the id stops appearing in the fleet: at that point it can never
    /// recur, so the tombstone is dead weight, and without the rule this grows
    /// UUIDs forever.
    public var deleted: Set<String>
    /// The window size the deck opens at when macOS has no remembered frame,
    /// and the size the settings pane's "Apply now" resizes to.
    ///
    /// nil is not a number, exactly as `panelWidth` below: "never chose"
    /// follows the product default (`DeckPrefs.defaultWindow`), which may
    /// evolve with the product; a chosen size is a fact about the user's
    /// monitors and survives it. Stored as a `Canvas` because that is what a
    /// window IS to this app — the thing the layout is asked to fill.
    public var windowSize: Canvas?
    /// What a fresh deck opens at: sized so the whole window — content plus
    /// title bar — fits the 480 pt strip with room to spare, and wide enough
    /// that two lanes and a panel are legible on a normal monitor.
    public static let defaultWindow = Canvas(width: 1280, height: 300)
    /// The smallest window the deck will lay out in: the declared floor plus
    /// the status line. The scene enforces it as the window's minimum; the
    /// decoder clamps to it so a stored number the window would refuse never
    /// survives to be displayed back as if it were in force.
    public static let minWindow = Canvas(width: 960, height: 270)

    /// A JSON number as an Int, or nil when it is not one.
    ///
    /// `Int(_: Double)` TRAPS on NaN, infinity and anything past Int64, and
    /// this decoder runs on the scene-construction path, before there is a
    /// window, a log or any recovery. `{"windowSize":{"width":1e30}}` would take
    /// the app down at launch. Total by construction is the rule this file opens with.
    static func whole(_ value: Double) -> Int? { Int(exactly: value.rounded()) }
    /// The settings window's remembered pane. It goes through the reducer like
    /// everything else, because the pane may hold no storage of its own.
    public var lastPane: String?
    /// How many recent prompts the panel shows. Clamped at decode to
    /// 1…`LaneRecord.historyCap`: the lane retains no more than the cap, so
    /// a larger ask would be a number the deck cannot honour.
    public var promptHistory: Int
    public static let defaultPromptHistory = 3
    /// How long an open hold waits before the deck lets it go. `HoldPolicy`
    /// is rebuilt from this on every `.prefsChanged` — see
    /// `Reducer.reduce`'s own case — which is what keeps it the one source
    /// the countdown, the installed hooks and `Hold.expiresAt` all read.
    public var holdBudget: HoldBudget
    /// `holdBudget`'s twin for `AskUserQuestion` holds: independently
    /// configurable, same shape. `HoldBudget.questionStandard` explains the
    /// shorter default (8s vs 120s). `.untilAnswered` means the same as for
    /// `holdBudget`: never released early.
    public var questionHoldBudget: HoldBudget
    /// Keys this version does not understand, written back verbatim.
    var retained: [String: JSONValue]

    public init(quickActions: [QuickAction] = QuickAction.shipped,
                autoContinue: Set<String> = [],
                autoContinueByDefault: Bool = false,
                autoContinueRefused: Set<String> = [],
                hidden: Set<String> = [],
                cardOrder: [String] = [],
                directoryColors: [String: CardColor] = [:],
                legacyCardColors: [String: CardColor] = [:],
                deleted: Set<String> = [],
                windowSize: Canvas? = nil,
                lastPane: String? = nil,
                promptHistory: Int = DeckPrefs.defaultPromptHistory,
                holdBudget: HoldBudget = .standard,
                questionHoldBudget: HoldBudget = .questionStandard,
                retained: [String: JSONValue] = [:]) {
        self.quickActions = quickActions
        self.autoContinue = autoContinue
        self.autoContinueByDefault = autoContinueByDefault
        self.autoContinueRefused = autoContinueRefused
        self.hidden = hidden
        self.cardOrder = cardOrder
        self.directoryColors = directoryColors
        self.legacyCardColors = legacyCardColors
        self.deleted = deleted
        self.windowSize = windowSize
        self.lastPane = lastPane
        self.promptHistory = promptHistory
        self.holdBudget = holdBudget
        self.questionHoldBudget = questionHoldBudget
        self.retained = retained
    }

    public static let firstRun = DeckPrefs()

    /// The set of keys this version writes — everything else in a decoded
    /// object is somebody else's and survives.
    static let knownKeys: Set<String> = [
        "themeID", "lastGoodID", "lastGoodMap",
        "motionLevel", "motionSpeed", "lastPane", "quickActions", "panelWidth",
        "windowSize",
        // `"cardColors"` stays listed: it is the migration key `legacyCardColors`
        // decodes from and re-encodes to while draining, and a key `encoded()`
        // can still write must never fall into `retained`.
        "autoContinue", "autoContinueByDefault", "autoContinueRefused",
        // Retired: `autoContinueDecided` (hand-set answers in both directions)
        // was replaced by the refusals alone. Listed so a leftover key is
        // consumed rather than carried in `retained` forever. It IS migrated on
        // the way in; see `decode`.
        "autoContinueDecided",
        "hidden", "cardOrder", "cardColors", "directoryColors", "deleted",
        "readoutColours", "promptHistory", "holdBudget", "questionHoldBudget",
        // Retired: the transparency feature is gone (see `Color(token:in:)`).
        // Listed so a leftover key is not carried forward in `retained` forever.
        "surfaceAlpha",
    ]

    // ------------------------------------------------------------------ codec

    /// Total: anything that is not an object decodes as first-run, a missing
    /// or malformed field decodes as its default. A prefs file can be wrong;
    /// the deck cannot refuse to start over it.
    public static func decode(_ json: JSONValue) -> DeckPrefs {
        guard case .object(let o) = json else { return .firstRun }
        var prefs = DeckPrefs()
        if case .string(let s)? = o["lastPane"] { prefs.lastPane = s }
        // An ABSENT `quickActions` key means "never edited" and yields the
        // shipped set; an explicitly EMPTY array means "the user removed them
        // all" and yields an empty panel. The codec keeps those apart, for the
        // same reason `Fed` distinguishes silence from an empty answer.
        //
        // `windowSize` is clamped HERE, not in the settings pane: a hand-edited
        // 400×100 would decode to a size the window refuses (AppKit silently
        // raises it to its floor) while the pane kept displaying 400×100. The
        // floor is the scene's.
        if case .object(let w)? = o["windowSize"],
           case .number(let width)? = w["width"],
           case .number(let height)? = w["height"],
           let cols = Self.whole(width), let rows = Self.whole(height) {
            prefs.windowSize = Canvas(width: max(cols, minWindow.width),
                                      height: max(rows, minWindow.height))
        }
        if case .array(let rows)? = o["autoContinue"] {
            prefs.autoContinue = Set(rows.compactMap { $0.stringValue })
        }
        // Absent decodes as OFF: the first-run value, and the conservative one;
        // a prefs file from a version that predates this must not start typing
        // into terminals on upgrade.
        if case .bool(let on)? = o["autoContinueByDefault"] { prefs.autoContinueByDefault = on }
        if case .array(let rows)? = o["autoContinueRefused"] {
            prefs.autoContinueRefused = Set(rows.compactMap { $0.stringValue })
        } else if case .array(let rows)? = o["autoContinueDecided"] {
            // **One-shot migration from the retired two-direction record.**
            //
            // `autoContinueDecided` held hand-set answers BOTH ways. Which
            // entries were refusals is answerable exactly: the old bulk-OFF did
            // `decided.subtract(autoContinue)` before clearing, so a decided
            // entry whose surface is NOT armed is a refusal. Dropping them would
            // re-arm, on upgrade, tabs a person told the deck to leave alone.
            //
            // Read only when the new key is absent, so a newer file is never
            // second-guessed. Nothing writes the old key back (`knownKeys`
            // claims it, `encoded()` does not emit it), so this runs once.
            let decided = Set(rows.compactMap { $0.stringValue })
            prefs.autoContinueRefused = decided.subtracting(prefs.autoContinue)
        }
        if case .array(let rows)? = o["hidden"] {
            prefs.hidden = Set(rows.compactMap { $0.stringValue })
        }
        // Entry-wise tolerant, like every array field here: a non-string row
        // drops just itself. DEDUPED, preserving first occurrence: a duplicate
        // surface is a malformed fact, not a legitimate state for a merge that
        // reads position as rank, so the clamp-at-decode doctrine resolves it
        // once, here. NO `.sorted()`: unlike the `Set<String>` fields above, this
        // is the one array where the decoded ORDER is the fact.
        if case .array(let rows)? = o["cardOrder"] {
            var seen = Set<String>()
            var order: [String] = []
            for row in rows {
                guard let surface = row.stringValue, !seen.contains(surface) else { continue }
                seen.insert(surface)
                order.append(surface)
            }
            prefs.cardOrder = order
        }
        // Entry-wise total: one malformed colour drops that entry rather than
        // the whole map (as for `quickActions` below). A dropped entry only loses
        // the RECORD of a colour; the key earns a fresh `fallbackSlot` next projection.
        if case .object(let entries)? = o["directoryColors"] {
            var colors: [String: CardColor] = [:]
            for (directory, value) in entries {
                if let color = CardColor.decode(value) { colors[directory] = color }
            }
            prefs.directoryColors = colors
        }
        // The migration half: an OLD prefs file's surface-keyed `"cardColors"`
        // decodes into `legacyCardColors`, never into `directoryColors`
        // directly, so a surface is never read as a directory until the reducer
        // adopts each entry onto its lane's actual directory. Same entry-wise
        // tolerance as above.
        if case .object(let entries)? = o["cardColors"] {
            var colors: [String: CardColor] = [:]
            for (surface, value) in entries {
                if let color = CardColor.decode(value) { colors[surface] = color }
            }
            prefs.legacyCardColors = colors
        }
        if case .array(let rows)? = o["deleted"] {
            prefs.deleted = Set(rows.compactMap { $0.stringValue })
        }
        if case .array(let rows)? = o["quickActions"] {
            // Migrated on the way in, so a shipped button the deck has since
            // renamed reaches people who already have it stored.
            //
            // `dedupedByID` runs last: migration changes a title, never an id,
            // so the order cannot change which rows collide. Two rows sharing an
            // id only arise in a hand-edited file (`dedupedByID`): first wins,
            // so every id-keyed lookup downstream has exactly one row to find.
            prefs.quickActions = QuickAction.dedupedByID(
                rows.compactMap(QuickAction.decode).map(QuickAction.migrated))
        }
        if case .number(let n)? = o["promptHistory"] {
            prefs.promptHistory = min(max(Int(n), 1), LaneRecord.historyCap)
        }
        // A missing key decodes to `.standard` (already set by `DeckPrefs()`).
        // `.string("untilAnswered")` is checked FIRST so any other string falls
        // through and leaves the default standing instead of being clamped as a number.
        if case .string("untilAnswered")? = o["holdBudget"] {
            prefs.holdBudget = .untilAnswered
        } else if case .number(let n)? = o["holdBudget"], let seconds = Self.whole(n) {
            // `Self.whole`, not `Int(n)`: `Int(_: Double)` aborts on NaN,
            // infinity or anything past Int64, and this decoder runs before
            // there is a window or a log.
            //
            // Clamped HERE, not in the settings pane: a hand-edited "3" must
            // not reach a deck that expires a hold before a human can read it.
            prefs.holdBudget = .clamped(seconds: seconds)
        }
        // `questionHoldBudget`'s twin of the block above, with
        // `clampedForQuestion(seconds:)` so a low number clamps to the
        // QUESTION floor (3), not the permission one (10). A missing key
        // decodes to `.questionStandard` (8s).
        if case .string("untilAnswered")? = o["questionHoldBudget"] {
            prefs.questionHoldBudget = .untilAnswered
        } else if case .number(let n)? = o["questionHoldBudget"], let seconds = Self.whole(n) {
            prefs.questionHoldBudget = .clampedForQuestion(seconds: seconds)
        }
        prefs.retained = o.filter { !knownKeys.contains($0.key) }
        return prefs
    }

    public func encoded() -> JSONValue {
        var o: [String: JSONValue] = retained          // unknown keys first — known keys win collisions
        if let lastPane { o["lastPane"] = .string(lastPane) }
        // Same rule: "never chose" stays absent, so the product default can
        // evolve for everyone who never overrode it.
        if let windowSize {
            o["windowSize"] = .object(["width": .number(Double(windowSize.width)),
                                       "height": .number(Double(windowSize.height))])
        }
        o["quickActions"] = .array(quickActions.map(\.encoded))
        // Sorted, so the stored file is a function of the set and not of the
        // order a hash happened to produce — a preferences file that churns on
        // every save is a preferences file nobody can diff.
        o["autoContinue"] = .array(autoContinue.sorted().map(JSONValue.string))
        // Absent when false/empty, so an unconfigured deck writes no trace of
        // an unused feature (as `cardOrder` does; `autoContinue`/`hidden` are
        // always written because "cleared" and "never set" differ for them).
        if autoContinueByDefault { o["autoContinueByDefault"] = .bool(true) }
        if !autoContinueRefused.isEmpty {
            o["autoContinueRefused"] = .array(autoContinueRefused.sorted().map(JSONValue.string))
        }
        o["hidden"] = .array(hidden.sorted().map(JSONValue.string))
        // Absent when empty, as for `directoryColors` below: nothing
        // distinguishes "never ordered" from "cleared". NO `.sorted()`: `hidden`
        // above is a `Set` whose order is an accident of storage, but
        // `cardOrder`'s order IS the payload, and the array is already the
        // deterministic representation.
        if !cardOrder.isEmpty {
            o["cardOrder"] = .array(cardOrder.map(JSONValue.string))
        }
        // Absent when empty, unlike `autoContinue`/`hidden` above (Sets, which
        // always write an array and need `.sorted()` for deterministic order).
        // `directoryColors` is a dictionary and `PrefsStore.data(from:)`
        // serialises every `.object` with `.sortedKeys`, so no sort is needed.
        // Absent vs. `{}` is decided as for `quickActions`
        // (`absentAndEmptyActionListsAreDifferentFacts`): nothing empties the
        // map, only adds to it, so an empty map has one meaning and omitting it
        // keeps a fresh prefs file free of `"directoryColors":{}`.
        if !directoryColors.isEmpty {
            let entries = directoryColors.mapValues { $0.encoded() }
            o["directoryColors"] = .object(entries)
        }
        // The migration map re-encodes under the OLD key while non-empty, so
        // quitting mid-drain loses nothing (see `legacyCardColors`), and stops
        // being written once the reducer has drained it.
        if !legacyCardColors.isEmpty {
            let entries = legacyCardColors.mapValues { $0.encoded() }
            o["cardColors"] = .object(entries)
        }
        o["deleted"] = .array(deleted.sorted().map(JSONValue.string))
        o["promptHistory"] = .number(Double(promptHistory))
        switch holdBudget {
        case .seconds(let n):  o["holdBudget"] = .number(Double(n))
        case .untilAnswered:   o["holdBudget"] = .string("untilAnswered")
        }
        switch questionHoldBudget {
        case .seconds(let n):  o["questionHoldBudget"] = .number(Double(n))
        case .untilAnswered:   o["questionHoldBudget"] = .string("untilAnswered")
        }
        return .object(o)
    }
}

// -------------------------------------------------------------------- privacy

extension DeckPrefs: CustomStringConvertible, CustomDebugStringConvertible {
    /// SCHEMATIC only: field names and counts, never a key or a value.
    /// `description`/`debugDescription` exist so `"\(subject)"` in a log
    /// statement cannot leak (see `Redacted.swift`). `directoryColors` keys are
    /// directory PATHS, `quickActions` rows carry TITLES a person typed, and
    /// `legacyCardColors` carries the same paths under their old key, so an
    /// incidental `"\(prefs)"` in a log line or crash report would leak all
    /// three.
    ///
    /// Counts only, never the collections: enough to debug "why did my prefs
    /// not save" without becoming a second path that can put a path or title
    /// where a diagnostic must never reach.
    public var description: String {
        "DeckPrefs(quickActions: \(quickActions.count), autoContinue: \(autoContinue.count), " +
        "hidden: \(hidden.count), cardOrder: \(cardOrder.count), directoryColors: \(directoryColors.count), " +
        "legacyCardColors: \(legacyCardColors.count), deleted: \(deleted.count), " +
        "windowSize: \(windowSize == nil ? "unset" : "set"), " +
        "lastPane: \(lastPane == nil ? "unset" : "set"), promptHistory: \(promptHistory), " +
        "holdBudget: \(holdBudget), questionHoldBudget: \(questionHoldBudget), retained: \(retained.count))"
    }

    public var debugDescription: String { description }
}
