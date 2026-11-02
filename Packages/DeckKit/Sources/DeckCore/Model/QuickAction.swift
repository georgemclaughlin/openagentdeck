//
//  QuickAction.swift · DeckCore/Model
//
//  What a person can say to a session that did not ask.
//
// Unlike every other control, which answers a question the engine asked,
// a quick action types into a session that did not ask. The
// graceful-degradation rule (no session is ever worse off because the deck
// exists) is easiest to break here. Each rule below was measured:
//
//    - a send that lands mid-turn is not lost but is INVISIBLE until the turn
//      ends (LV21: it arrived 68 ms after the running turn's Stop), so the
//      deck waits for idle, for honesty rather than safety;
//    - a composer that already holds text SPLICES the deck's send onto it
//      (LV23: 'MYDRAFT reply with exactly LV23D' arrived as one prompt), so
//      the deck reads before it writes;
//    - a slash command produces no UserPromptSubmit at all (LV21, LV23, both
//      mechanisms), so it can be sent and never confirmed.
//

// `Foundation`, not a platform framework: `IndexSet` (used by
// `moved(_:fromOffsets:toOffset:)` below) lives there.
import Foundation

/// One thing a person can send. User-definable: the shipped set is a starting
/// point, not a vocabulary.
public struct QuickAction: Equatable, Codable, Sendable, Identifiable {
    public enum Kind: Equatable, Codable, Sendable {
        /// Text, typed and submitted.
        case prompt(String)
        /// Interrupt. Sent as a key, never as text.
        case escape
        /// A single key that answers a terminal dialog the deck did not open
        /// and cannot describe — cmux `send-key`, no composer read, no
        /// enter. Like `.escape` it has no payload-typing semantics: the
        /// associated string names the KEY ("1", "2", "3"), not text to
        /// splice onto a composer. Built only by `QuickAction.dialogAnswers`
        /// — never user-authored, never offered in the editor.
        case dialogKey(String)
    }

    /// Where this action is offered. Matched with a glob, not a regex: a
    /// user-authored pattern is re-evaluated on every frame projection, and a
    /// regex can throw or hang where a glob cannot (see `Glob.swift`).
    public enum Scope: Equatable, Codable, Sendable {
        /// Offered to every session. Rows stored without a scope decode to this.
        case everywhere
        /// Offered only to a session whose `cwd` matches this glob
        /// (`Glob.matches(pattern:path:)`, read by `shows(in:)` below). Holds the
        /// PATTERN string, not a compiled matcher; matching a plain string on every
        /// projection is affordable because `Glob` is linear.
        case folders(String)

        // ------------------------------------------------ the encoder seam
        //
        // The pattern is `Redacted`-class text: a folder rule names a project
        // (e.g. `*/alpha*`), the same class of fact as `LaneView.directory`, which
        // is wrapped in `Redacted`. `Frame.actions` is `[QuickAction]` and `Frame`
        // is `Codable`, so a synthesized conformance would put the pattern one
        // `JSONEncoder` away from a leak. Encoding therefore writes
        // `Redacted.placeholder`, and decoding returns the placeholder, not the
        // original (a round trip that restored the bytes would mean they had
        // survived the write).
        //
        // This does not touch persistence: prefs round-trip through the
        // hand-written `encoded`/`decode` below (`JSONValue`, called by
        // `DeckPrefs`), never through `Codable`, so the real pattern stays in the
        // person's settings file.
        //
        // Codable landmine (same shape as `LaneView.color` and
        // `UsageIndicator.windows`): `scope` is non-optional, so `QuickAction`'s
        // synthesized `Decodable` calls `decode`, not `decodeIfPresent`, and bytes
        // written without a scope would fail `keyNotFound`. The hand-written
        // `decode(_:)` below maps an absent "folders" key to `.everywhere`; only
        // that path is the migration contract. Nothing in the product decodes
        // `Frame` or `QuickAction` through `Codable` today; if that changes, add a
        // custom `init(from:)` with `decodeIfPresent`.

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .everywhere: try container.encodeNil()
            case .folders: try container.encode(Redacted.placeholder)
            }
        }

        public init(from decoder: any Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .everywhere }
            else { self = .folders(try container.decode(String.self)) }
        }
    }

    /// Stable across renames, because prefs and the queue both refer to it —
    /// and because a target's accessibility label is built from it rather than
    /// from the title, which a user may duplicate.
    public let id: String
    /// `nil` means "derive the label from the message". This is the word the
    /// person typed, if any, never what a button shows (that is `displayTitle`).
    /// A new button (`ActionRowEditor`'s Add, `SettingsView.swift`) is born `nil`,
    /// so label and message are the same until someone deliberately splits them.
    ///
    /// Absent from the wire entirely when `nil` (`encoded`/`decode`, below), the
    /// same absent-means-unset rule `DeckPrefs.directoryColors`/`cardOrder` use.
    /// Rows stored with an explicit `"title"` decode unchanged.
    public let title: String?
    public let kind: Kind
    /// Absent from the wire when `.everywhere`; otherwise stored under the key
    /// `"folders"` as the pattern string alone. Rows with no such key decode to
    /// `.everywhere` (`encoded`/`decode`, below).
    public let scope: Scope

    /// `scope` defaults to `.everywhere` so call sites that predate it keep
    /// compiling with the same meaning.
    public init(id: String, title: String?, kind: Kind, scope: Scope = .everywhere) {
        self.id = id; self.title = title; self.kind = kind; self.scope = scope
    }

    /// Does this action belong on a session working in `directory`?
    ///
    /// `.everywhere` always says yes. `.folders(pattern)` against a `nil`
    /// directory says NO: a rule that says "only here" cannot be satisfied by a
    /// lane that cannot say where "here" is. Fail closed: the button that might
    /// type into the wrong project is the one that stays hidden.
    public func shows(in directory: String?) -> Bool {
        switch scope {
        case .everywhere: return true
        case .folders(let pattern):
            guard let directory else { return false }
            return Glob.matches(pattern: pattern, path: directory)
        }
    }

    /// What every surface shows; the reader anything outside this type should
    /// use. `title` is an authoring fact ("did somebody type a label"); this is
    /// the display fact, and the only one safe to assume is never blank.
    /// A blank explicit title falls through to the derived one: `decode` accepts
    /// any string under `"title"`, `""` included, and no rule rejects an empty
    /// label, so a stored `"title": ""` would otherwise produce a blank button.
    /// `nil` and `""` resolve the same way, as in `Redacted.init?(optional:)`.
    public var displayTitle: String {
        if let title, !title.trimmed.isEmpty { return title }
        return Self.derivedTitle(from: kind)
    }

    /// `displayTitle`'s fallback when nobody typed a label: the first line of a
    /// prompt that has text on it, trimmed and clamped to `editorTitleCap` (64),
    /// the same clamp an explicit title gets (`commitTitle`). First line only,
    /// because messages can be multi-line and a label should not be a paragraph.
    ///
    /// `.escape` and `.dialogKey` have no message to derive from, so they return
    /// a constant. Both are unreachable in practice (`.escape` ships with the
    /// explicit "Escape Key"; `.dialogKey` never joins `prefs.quickActions`).
    /// They are spelled out rather than folded into `default:` so a new `Kind`
    /// case is a compile error here.
    static func derivedTitle(from kind: Kind) -> String {
        switch kind {
        case .prompt(let text):
            // The first line with something on it, not simply the first line: a message
            // that opens with a blank line would otherwise derive an empty label.
            let firstWritten = text.split(separator: "\n")
                .first { !String($0).trimmed.isEmpty }
                .map(String.init) ?? ""
            return String(firstWritten.trimmed.prefix(editorTitleCap))
        case .escape: return "Escape"
        case .dialogKey: return "Answer"
        }
    }

    /// Can the deck ever know this landed?
    ///
    /// A prompt comes back as a `UserPromptSubmit` carrying the same bytes —
    /// that is the receipt. A slash command does not (measured on both
    /// mechanisms), and neither does an interrupt (an interrupted turn emits
    /// no `Stop` at all). For those the deck says **sent**, never **done**,
    /// because sent is the only thing it witnessed.
    public var isConfirmable: Bool {
        guard case .prompt(let text) = kind else { return false }
        return !text.hasPrefix("/")
    }

    /// What actually goes to the host.
    public var payload: String? {
        if case .prompt(let text) = kind { return text }
        return nil
    }

    /// The colour this action wears, as a rail rather than a fill.
    ///
    /// Green and red fills already mean ALLOW and DENY (answers to a question the
    /// engine asked); a filled quick action would give that idiom a second
    /// meaning. A 4 pt leading rail on a `lane`-filled cell is unmistakably not
    /// that button, keeps the label at `ink` on `lane` (13.6:1 rather than
    /// 1.7:1), and still reads as colour from across a room.
    ///
    ///   - an INTERRUPT is `red`: it stops work in flight, discards the rest of
    ///     the queue, and is the only action whose meaning the deck is certain of.
    ///   - a slash COMMAND is `instrumentBlue`, the "work in flight" colour; the
    ///     deck is operating the session rather than talking to it.
    ///   - anything else is a person's own words: `green`, the colour of go.
    ///
    /// Deliberately not user-configurable (a colour picker would let a user make
    /// "Escape" green).
    ///
    /// `.dialogKey` never reaches `QuickActionBar`, the surface that reads this;
    /// `DialogAnswerPanel` styles its buttons off the key itself.
    public var rail: Severity {
        switch kind {
        case .escape: .alarm
        case .prompt, .dialogKey: .normal
        }
    }

    // ------------------------------------------------------------ persistence
    //
    // Hand-written rather than `Codable`-derived, because the stored shape is a
    // contract with a file on somebody's disk and a synthesised one changes
    // whenever the type does. `Kind` in particular would encode as a nested
    // discriminated object; two strings survive a refactor.

    public var encoded: JSONValue {
        var o: [String: JSONValue] = ["id": .string(id)]
        // Absent, not `.string("")`, when nil: an explicit title and "never had
        // one, derive it" are different facts, and an empty string would collapse
        // them.
        if let title { o["title"] = .string(title) }
        // Absent for `.everywhere`; `scope`'s doc comment explains why.
        if case .folders(let pattern) = scope { o["folders"] = .string(pattern) }
        switch kind {
        case .prompt(let text): o["prompt"] = .string(text)
        case .escape:           o["escape"] = .bool(true)
        // Reachable only for exhaustiveness: `dialogAnswers` never joins
        // `prefs.quickActions`, so nothing in this codebase ever calls
        // `.encoded` on one. Written anyway, rather than a `default` that
        // would silently swallow the NEXT case this enum grows.
        case .dialogKey(let key): o["dialogKey"] = .string(key)
        }
        return .object(o)
    }

    /// nil for anything this version cannot make sense of. A malformed row is
    /// DROPPED rather than defaulted: an action whose text did not survive would
    /// send something the user never wrote, and a button that does the wrong
    /// thing is worse than a button that is missing.
    ///
    /// `title` decodes best-effort and is never by itself a reason to drop the
    /// row. Absent means derived (`nil`), and a present-but-wrong-type title (a
    /// hand-edit mistake) is treated as absent: an unreadable title affects only
    /// the label, not whether the button works.
    ///
    /// Never produces `.dialogKey`: the deck's fixed dialog answers do not come
    /// from a settings file, so a row carrying that key is dropped like any
    /// other unrecognised row.
    public static func decode(_ json: JSONValue) -> QuickAction? {
        guard case .object(let o) = json,
              case .string(let id)? = o["id"], !id.isEmpty else { return nil }
        let title: String?
        if case .string(let t)? = o["title"] { title = t } else { title = nil }
        // Absent means `.everywhere`. A present-but-wrong-type "folders" value is
        // treated like an absent key (the same best-effort rule as `title`): a scope
        // nobody can read falls back to the more permissive default rather than
        // dropping the row.
        let scope: Scope
        if case .string(let pattern)? = o["folders"] { scope = .folders(pattern) } else { scope = .everywhere }
        if case .bool(true)? = o["escape"] {
            return QuickAction(id: id, title: title, kind: .escape, scope: scope)
        }
        guard case .string(let text)? = o["prompt"], !text.isEmpty else { return nil }
        return QuickAction(id: id, title: title, kind: .prompt(text), scope: scope)
    }

    /// First entry wins; a later row sharing its id is dropped. Order is
    /// preserved for everything kept.
    ///
    /// Reachable only by hand-editing the file: `user(title:message:among:)`
    /// already de-duplicates ids when authoring. Left undeduped, a shared id
    /// would make id-keyed lookups (`ActionRowEditor`'s commit and remove,
    /// `SettingsView.swift`) ambiguous. Called from `DeckPrefs.decode` so "first
    /// wins" is settled once, at the boundary.
    public static func dedupedByID(_ actions: [QuickAction]) -> [QuickAction] {
        var seen = Set<String>()
        return actions.filter { seen.insert($0.id).inserted }
    }

    // -------------------------------------------------------------- authoring
    //
    // The rules an editor has to enforce, expressed here so the editor cannot
    // hold a different opinion from the layout. `editorTitleCap` is the one
    // length rule: a sanity ceiling the EDITOR enforces at input, not a reason
    // to reject an already-stored row. Pills hug their label up to
    // `OverviewLayout.actionPillMaxWidth` (320); longer titles truncate.

    /// A historical sizing reference (16 characters), no longer a gate or a
    /// layout input. A longer title is legal and truncates on the glass
    /// (`lineLimit(1)` / `.truncationMode(.tail)`).
    /// `OverviewLayout.actionPillMaxWidth`'s doc comment cites its worst case
    /// ("Regenerate token", 204pt) as evidence the 320pt cap has room to spare.
    public static let titleBudget = 16

    /// A sanity cap the EDITOR enforces at input, not a rejection rule:
    /// `rejection(at:among:)` never checks it, because
    /// `user(title:message:among:)` has already clamped. 64 is four times
    /// `titleBudget`, more than any button label needs.
    public static let editorTitleCap = 64

    /// `user(title:message:among:)`'s slug cap, deliberately smaller than
    /// `editorTitleCap`. Ids are never rendered, only compared (`dedupedByID`,
    /// the de-duplication loop, id-keyed lookups), so a message-derived label
    /// (up to a sentence) must not slug into the sentence with dashes for
    /// spaces. 24 keeps two different short titles from colliding by prefix;
    /// the de-duplication loop breaks any tie that survives.
    static let idSlugCap = 24

    /// The id of the shipped Continue. Named because the auto-continue feature
    /// has to find it in a set the user may have renamed, reordered, or removed
    /// — and a session whose panel no longer offers a Continue simply never
    /// arms, rather than the deck inventing a button nobody kept.
    public static let continueID = "continue"

    /// The most the deck ever offers at once: twice the band's Quick Actions
    /// sub-column cap. `OverviewLayout.bandActionsRowCap` (5) is how many rows
    /// one sub-column holds before a second opens
    /// (`QuickActionsColumn.columnMajorSplit(_:)`, `DecisionBar.swift`), so a
    /// 2x5 grid is the full column. A literal here rather than a read of that
    /// constant, so `QuickAction` need not import layout vocabulary;
    /// `actionsCapAgreesWithTheColumnGrid` (`OverviewLayoutTests`) holds the two
    /// equal.
    public static let maxOffered = 10

    /// Why this action cannot be saved, or nil when it can. One list, so the
    /// editor's message and the set's validity are the same judgement.
    ///
    /// Three rules:
    ///   - a prompt needs a message. `title` is optional (`displayTitle` derives
    ///     it from the message), so a button with nothing to show is one with no
    ///     message;
    ///   - a `.folders` action needs a non-blank pattern. An empty pattern is not
    ///     "everywhere" (`.everywhere` spells that), and `Glob.matches` answers
    ///     "matches nothing" for it, so an unfinished rule would save and then
    ///     silently never show on any session;
    ///   - no earlier row may show the same label.
    ///
    /// There is no title-length rule: a longer title is legal and truncates on
    /// the glass (`editorTitleCap` is enforced at the editor, not here).
    /// Rejecting a person's own words as too long would be the wrong authority
    /// for a display constraint.
    ///
    /// Position matters. A duplicate-title check over the whole set would reject
    /// BOTH copies, so typing a second "Continue" would hide the original. Only
    /// earlier rows can invalidate a row, so the duplicate is the problem and the
    /// original is left alone.
    ///
    /// The comparison uses `displayTitle`, not `title`. Comparing the optionals
    /// misses an explicit "Ship it" beside a derived row that also renders "Ship
    /// it" (`Optional("Ship it") != nil`), and falsely flags two derived rows
    /// with different messages (`nil == nil`).
    ///
    /// The offered-count cap is not enforced here. "Past the cap" depends on
    /// which session's directory is asking, so it lives in `offerable(_:in:)`,
    /// applied after these static rules and after `shows(in:)`.
    /// `offerable(_:)` shows the editor every finished row, with no cap.
    ///
    /// This function never calls itself or anything that counts its answers, so
    /// each check is O(1) or one linear scan of `set`, and the driving loop in
    /// `offerable(_:)` is O(n^2) worst case. (A cap rule that counted earlier
    /// valid rows through `rejection` would recurse exponentially, T(n) ~
    /// 2*T(n-1), reachable from a stored prefs blob past the cap:
    /// `PrefsTests.storedRowsPastTheCapSurviveDecode`.)
    public func rejection(at index: Int, among set: [QuickAction]) -> String? {
        if case .prompt(let text) = kind, text.trimmed.isEmpty {
            return "a button needs a message to send"
        }
        if case .folders(let pattern) = scope, pattern.trimmed.isEmpty {
            return "a folder rule needs a pattern"
        }
        // Both sides trimmed: `displayTitle` trims a derived label but returns an
        // explicit one verbatim, so comparing raw would treat " Continue " and
        // "Continue" as different though they render identically.
        let label = displayTitle.trimmed
        if set.prefix(max(index, 0)).contains(where: { $0.displayTitle.trimmed == label }) {
            return "an earlier button already says that"
        }
        return nil
    }

    /// The set as the EDITOR shows it: every finished row, in order, with no
    /// session, directory or cap. `offerable(_:in:)` is the per-session view
    /// built from this one.
    /// FROM this one.
    public static func offerable(_ set: [QuickAction]) -> [QuickAction] {
        set.enumerated().filter { $0.element.rejection(at: $0.offset, among: set) == nil }
            .map(\.element)
    }

    /// The set as ONE SESSION's panel may offer it: `offerable(_:)` filtered to
    /// rows that `shows(in: directory)`, THEN capped at `maxOffered`. The order
    /// matters: filtering first makes `maxOffered` a per-session ceiling, so
    /// twelve stored rows of which eight show for a directory offer all eight.
    /// Capping first would withhold rows this session was never competing for.
    ///
    /// `directory` is read in-process only; neither the pattern nor the
    /// directory travels further than the returned value. `Frame.swift`'s
    /// projection is the one caller that reads a `Redacted`'s `.value` to produce
    /// one, and states why that in-process read is legal.
    public static func offerable(_ set: [QuickAction], in directory: String?) -> [QuickAction] {
        Array(offerable(set).filter { $0.shows(in: directory) }.prefix(maxOffered))
    }

    /// Trim, then clamp to `editorTitleCap` (64): the rule a title passes through
    /// whenever raw keystrokes become a stored title. Used both when authoring a
    /// new action (`user(title:message:among:)`) and when the editor commits an
    /// existing action's title (`ActionRowEditor`, `SettingsView.swift`), so the
    /// two cannot drift.
    public static func commitTitle(_ title: String) -> String {
        String(title.trimmed.prefix(editorTitleCap))
    }

    /// A new action from what a person typed. The id is derived from the display
    /// title (explicit if typed, else derived from the message) and de-duplicated
    /// against the set. Ids are what the queue, the prefs file and every target
    /// label refer to, so a rename must not retarget a queued send.
    ///
    /// An explicit title is clamped to `editorTitleCap` (64) first, so the slug,
    /// the id and the stored title all come from the same string. `title: nil`
    /// skips the clamp and passes straight through: a new button is born this
    /// way, so its label derives from the message. The message is never clamped:
    /// truncating it would change what the button sends.
    ///
    /// The slug is capped at `idSlugCap` (24), smaller than `editorTitleCap`,
    /// because a derived label can be a sentence and a sentence-length id is not
    /// a stable identifier.
    public static func user(title: String?, message: String,
                           among others: [QuickAction]) -> QuickAction {
        // A blank title collapses to nil here, not just at display time:
        // `title.map(commitTitle)` yields nil only for a nil title, and `??` fires on
        // nil rather than on empty, so `""` or `" "` would produce a row whose id
        // slugs from nothing and a stored `Optional("")`.
        let committed = title.map(commitTitle)
        let clampedTitle = (committed?.isEmpty ?? true) ? nil : committed
        // The slug's source is the same resolution `displayTitle` performs (explicit
        // wins, else derive from the message), so id and label agree.
        let label = clampedTitle ?? derivedTitle(from: .prompt(message))
        let slug = label.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        // The de-duplication suffix hangs off the same base as the first attempt,
        // `"action"` fallback included. Appending to the raw slug (empty for a button
        // added before anything is typed) produced ids like "action", "-2", "-3".
        let clampedSlug = String(slug.prefix(idSlugCap))
        let base = clampedSlug.isEmpty ? "action" : clampedSlug
        var id = base
        var n = 2
        while others.contains(where: { $0.id == id }) { id = "\(base)-\(n)"; n += 1 }
        return QuickAction(id: id, title: clampedTitle, kind: .prompt(message))
    }

    // -------------------------------------------------------------- reorder
    //
    // Order is load-bearing: `QuickActionBar` fills its rows in this order, and
    // the overflow menu (`OverviewLayout.actionPillLayout`'s `hiddenCount`) hides
    // from the END, so the first action is always reachable. A drag in the editor
    // must move the same array the bar reads.

    /// The row-order arithmetic a drag reorder needs, with the semantics of
    /// SwiftUI's `move(fromOffsets:toOffset:)`, reimplemented in plain Swift
    /// because `DeckCore` imports no platform framework and so it can be tested
    /// headlessly (`QuickActionTests`). `SettingsView.swift`'s `.onMove` handler
    /// calls this directly.
    ///
    /// `destination` is in terms of the ORIGINAL array ("insert before this
    /// offset"), matching `onMove(perform:)`. Removing the moved elements shifts
    /// later indices down, so the insertion point is corrected by how many
    /// removed offsets sat before it. Out-of-range offsets in `source` are
    /// ignored rather than trapping: a stale `IndexSet` should move nothing, not
    /// crash the app.
    public static func moved(_ actions: [QuickAction], fromOffsets source: IndexSet,
                             toOffset destination: Int) -> [QuickAction] {
        let validSource = source.filter { actions.indices.contains($0) }
        guard !validSource.isEmpty else { return actions }
        let moving = validSource.sorted().map { actions[$0] }
        var result = actions
        for index in validSource.sorted(by: >) { result.remove(at: index) }
        let adjustment = validSource.filter { $0 < destination }.count
        let insertAt = max(0, min(result.count, destination - adjustment))
        result.insert(contentsOf: moving, at: insertAt)
        return result
    }

    /// The shipped set. `/clear` is deliberately not here: it erases a session's
    /// context irreversibly, and a one-tap wipe beside "Continue" is the
    /// accidental-authority defect the arm delays exist to prevent. A user may
    /// add it; the deck does not ship it armed.
    ///
    /// Titles say what will actually happen. `/compact` is the text sent to the
    /// session; a button labelled "Compact" left readers guessing whether the
    /// deck types a slash command or a sentence (and the deck cannot confirm the
    /// first: a slash command emits no `UserPromptSubmit`, LV21/LV23). "Escape
    /// Key" says a KEY is sent, which separates it from every other button here.
    ///
    /// The first two use `title: nil`: `derivedTitle` yields the same word
    /// ("Continue", "/compact"), so the display is unchanged
    /// (`QuickActionTests.shippedSetDisplayTitlesAreUnchanged`). `escape` stays
    /// explicit because `Kind.escape` has no payload to derive a title from.
    public static let shipped: [QuickAction] = [
        QuickAction(id: "continue", title: nil, kind: .prompt("Continue")),
        QuickAction(id: "compact", title: nil, kind: .prompt("/compact")),
        QuickAction(id: "escape", title: "Escape Key", kind: .escape),
    ]

    // ---------------------------------------------------------- dialog answers
    // Claude Code's own permission dialog, as digits the deck can send when it
    // can see one is open (`LaneView.waitingFor`) but never opened a hold for it
    // (a released hold, or a lane raised to needs-you by a holdless Notification
    // or hookless fleet discovery). Never joins `prefs.quickActions`: these are
    // the fixed three answers a terminal dialog offers, not a user's buttons to
    // rename, reorder or delete. `DialogAnswerPanel` is the one surface that
    // renders them.

    /// The three answers, in the order and wording of Claude Code's own dialog
    /// ("1. Yes", "2. Yes, and don't ask again for: X", "3. No"), with the
    /// middle-dot and abbreviation dropped. Option 2 is offered whether or not
    /// this dialog has a second option, since the deck sees only that a dialog is
    /// open (`waitingFor`); `DialogAnswerPanel`'s caption says so. It cannot say
    /// "for: X" (nothing decoded to name), so the clause stops where the deck's
    /// knowledge does.
    public static let dialogAnswers: [QuickAction] = [
        QuickAction(id: "dialog-1", title: "1. Yes", kind: .dialogKey("1")),
        QuickAction(id: "dialog-2", title: "2. Yes, and don't ask again", kind: .dialogKey("2")),
        QuickAction(id: "dialog-3", title: "3. No", kind: .dialogKey("3")),
    ]

    /// Titles the deck itself used to ship, by id.
    ///
    /// A stored action carries its title as saved, so renaming a shipped button
    /// would never reach anyone who has already run the deck. A stored row still
    /// carrying one of these was never edited, so it moves forward; any other
    /// title is the user's own and is left alone.
    public static let supersededTitles: [String: Set<String>] = [
        "compact": ["Compact"],
        "escape": ["Escape"],
    ]

    /// A stored action with a superseded default title brought forward. Only the
    /// TITLE moves: the message is the user's to edit.
    ///
    /// Keys on the explicit title only: a derived row (`title == nil`) has no
    /// string the deck once wrote. A row storing the exact old default migrates
    /// to the current shipped row's own title, derived or not (now `nil` for
    /// "compact").
    public static func migrated(_ action: QuickAction) -> QuickAction {
        guard let title = action.title,
              let old = supersededTitles[action.id], old.contains(title),
              let current = shipped.first(where: { $0.id == action.id })
        else { return action }
        // `scope:` must be carried forward explicitly. It is defaulted in `init`, so
        // omitting it still compiles but silently rebuilds every migrated row as
        // `.everywhere`, turning a folder-restricted button global. `migrated` runs
        // over every decoded row (`DeckPrefs.decode`). Any code that rebuilds a
        // `QuickAction` from parts must do the same (`ActionRowEditor.candidate` and
        // `.pendingCommit` in `SettingsView.swift` do).
        return QuickAction(id: action.id, title: current.title,
                           kind: action.kind, scope: action.scope)
    }
}

/// Why an action cannot go, in the deck's own words, from a closed set.
///
/// An enum rather than the adapter's message, as part of the redaction rule:
/// a host adapter's failure carries the host's stderr, which can contain a
/// path, and a `String` frame field would carry it into every encoded frame.
/// `Diagnostic` solves the same problem the same way.
///
/// Host-neutral too: `DeckCore` does not know which terminal app hosts the
/// sessions, so it describes the class of failure; the adapter's richer
/// sentence reaches the runtime's log.
public enum ActionBlock: String, Equatable, Codable, Sendable {
    /// The host refused the connection. Measured: cmux's default socket mode
    /// admits only processes it spawned, and a deck launched from Finder is not
    /// one (`fixtures/live/LV28-cmux-host`).
    case hostUnavailable
    /// No address for this session, or an address the host no longer lists —
    /// The live-surface rule. A lane the deck can watch and cannot speak to.
    case unroutable
    /// The composer is not the deck's to type into: it holds text somebody else
    /// put there, or the surface is not showing a session at all.
    /// LV30 recorded what the second costs — a prompt sent to a surface whose
    /// session had not started ran in the SHELL (`zsh: command not found:
    /// reply`).
    case composerBusy
    /// The surface has no Claude Code prompt on it at all — a shell, a pager,
    /// a session that has not started.
    ///
    /// The surface has no Claude Code prompt on it at all (a shell, a pager, a
    /// session that has not started).
    ///
    /// Split from `composerBusy`: `Composer` answers `notASession` and
    /// `holdingText` separately, and mapping both to one block told a user
    /// pointed at a zsh prompt that their composer was not empty. They need
    /// different sentences because they need different actions: finish your
    /// thought vs. the deck is looking at the wrong pane.
    case surfaceNotASession
    /// The host answered and the deck could not make sense of the answer.
    case hostError

    /// The sentence the panel shows. Two lines of meta type at the smallest
    /// zoom, which is what the footer reserves.
    public var message: String {
        switch self {
        case .hostUnavailable:
            return "the terminal app is refusing local connections — allow them in its settings"
        case .unroutable:
            return "the deck has no route to this session"
        case .composerBusy:
            return "this session's composer is not empty — the deck will not type over it"
        case .surfaceNotASession:
            return "this surface is not showing a Claude Code session — the deck has nothing to type into"
        case .hostError:
            return "the terminal app could not be reached"
        }
    }
}

/// An action a person asked for, waiting its turn.
///
/// Queued per SESSION rather than per selection: a queue that froze because
/// somebody looked at another lane would be the deck quietly dropping what it
/// was asked to do.
public struct QueuedAction: Equatable, Sendable {
    public let action: QuickAction
    public let queuedAt: Instant
    /// When the deck put it on the wire. nil while it waits.
    public var sentAt: Instant?
    /// Set when a receipt matched — only ever for a confirmable action.
    public var confirmedAt: Instant?
    /// **Nobody tapped this one.** The deck queued it itself, because the
    /// session was mid-turn when the account ran out of budget and the surface
    /// asked to be continued when the window reopens.
    ///
    /// Carried so the two can be told apart where it matters: the surface says
    /// which is which rather than presenting the deck's decision as the user's,
    /// and a `Stop` arriving while it waits cancels an automatic one — the turn
    /// finished after all — where a tapped one is the user's to withdraw.
    public let isAutomatic: Bool

    public init(action: QuickAction, queuedAt: Instant,
                sentAt: Instant? = nil, confirmedAt: Instant? = nil,
                isAutomatic: Bool = false) {
        self.action = action; self.queuedAt = queuedAt
        self.sentAt = sentAt; self.confirmedAt = confirmedAt
        self.isAutomatic = isAutomatic
    }

    /// What the surface may say about it, and nothing more.
    public enum Status: String, Equatable, Codable, Sendable {
        case queued
        /// On the wire. For an unconfirmable action this is where it ends.
        case sent
        /// A receipt arrived carrying the deck's own bytes.
        case confirmed
    }

    public var status: Status {
        if confirmedAt != nil { return .confirmed }
        return sentAt == nil ? .queued : .sent
    }
}
