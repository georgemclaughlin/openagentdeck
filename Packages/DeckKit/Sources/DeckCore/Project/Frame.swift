//
//  Frame.swift · DeckCore/Project
//
//  State -> Frame. Pure, and the reason most of this product's UX rules are
//  assertions instead of screenshots.
//
// A Frame is a complete declarative description of what should be on screen.
// It is Codable and Equatable, it holds no view objects, no closures and no
// platform types, and every field carrying a value names the event that
// supplied it. That last part is the provenance rule made structural: the
// frame cannot render a number without saying where the number came from.
//

public struct LaneView: Equatable, Codable, Sendable {
    public let session: SessionID
    public let state: LaneState
    public let isExpanded: Bool
    /// nil renders an **empty slot**, never `0%` (a gauge nobody has fed
    /// claims nothing). Once fed, the last-known value stays here.
    public let contextPercent: Int?
    /// **True when the reading is older than its max age. No renderer draws a
    /// stale reading differently from a fresh one, on any surface, and that
    /// is deliberate.** A context percentage does not decay with time: an
    /// idle session's context is exactly what it was, and the last reading a
    /// statusline sent stays true until the next turn moves it. (The account
    /// usage gauge likewise does not mark its age in paint, for a different
    /// reason: sometimes dimming it was more confusing than the rot.) The one
    /// place age still matters is an ALARM raised on an old reading, a red the
    /// deck can no longer vouch for. `meters`, below, reads this field to gate
    /// exactly that. The frame still carries the fact so the gate is testable
    /// without pixels.
    public let contextStale: Bool
    /// field name -> the event that supplied it. The provenance rule's
    /// falsifier is a non-empty value with no entry here.
    ///
    /// **Excluded from `==` below.** Every `Sourced` field the reducer tracks
    /// (`LaneRecord.absorb`/`.decide`) re-stamps its source on every event
    /// that dominates the one already held, whether or not the value changed.
    /// A session that keeps reporting the same `cwd` and `tool` still moves
    /// this dictionary on every hook. Comparing it would make two lanes that
    /// read identically on screen unequal, the same class of false difference
    /// `Frame.at`'s exclusion prevents. Nothing renders this field.
    public let sources: [String: EventID]

    // --------------------------------------------------------------- identity
    //
    // What lets a person say "that one is mine" without reading a hex string.
    // Ordered by how fast each answers that question, which is not the order
    // they were easy to implement in.

    /// This card's identity colour: a slot in the deck's palette, or a custom
    /// one. It is assigned once PER DIRECTORY (see the reducer's
    /// `recordCardColorIfNeeded`) and read back the same across a relaunch.
    /// A colour is a fact about the project a session is open on, so every
    /// session sharing a working directory reads the same value. It is the
    /// fastest identity cue: legible before a directory name is read.
    /// **Codable landmine, same shape as `UsageIndicator.windows`'s.**
    /// Synthesized `Decodable` ignores this init's default, so bytes encoded
    /// before this field existed would fail `keyNotFound`. Nothing in the
    /// product decodes `Frame` or `LaneView` today (the conformance is only
    /// encoded), so there is nothing to break yet. When something does, write
    /// a custom `init(from:)` with `decodeIfPresent`.
    public let color: CardColor
    public let directory: Redacted?
    /// `LaneRecord.transcriptPath`'s projection: the file the transcript-well
    /// backfill (in `DeckApp`) reads from, once, the first time a lane
    /// carries one. `DeckCore` never opens it; this is the address, not the
    /// content (the same distinction `host` draws).
    public let transcriptPath: Redacted?
    public let title: Redacted?
    public let prompt: Redacted?
    /// The last N prompts, newest first. N is the projection's cut of the
    /// lane's capped history (the user's `promptHistory` preference), because
    /// the renderer decides nothing, including how much history to show.
    /// `prompt` stays the newest.
    public let prompts: [Redacted]
    /// The transcript-well ledger: real terminal prompts and deck sends,
    /// merged in two parts. First the persisted history
    /// (`LaneRecord.transcript`, capped, `.sent`/`.confirmed` only) oldest
    /// first, then the pending tail: this session's still-queued,
    /// payload-bearing actions from `state.pending`, synthesized fresh on
    /// every projection as `.queued` rows, in drain order.
    ///
    /// **Timestamps are NOT globally monotone across that seam; do not sort
    /// globally.** A queued action can sit out a closed usage window while a
    /// human keeps talking, so its `queuedAt` predates a later history row;
    /// and a second queued action's `queuedAt` can predate the first one's
    /// send row. The tail is the future (what drains next), not a
    /// continuation of history's clock, so interleaving by timestamp would
    /// show something that has not happened yet as though it had. Within
    /// each half the order is chronological.
    public let transcript: [TranscriptEntry]
    /// Absent off a worktree, never a placeholder.
    public let branch: Redacted?
    public let lastTool: String?
    /// `default`, `acceptEdits`, `plan`, `bypassPermissions`.
    public let permissionMode: String?
    /// Where the host says this session lives — the address an action would be
    /// sent to. nil means the deck can watch this session but not speak to it,
    /// which is a fact the surface must show rather than hide behind a control
    /// that silently does nothing.
    public let host: HostAddress?
    /// Off the strip, but not out of the frame.
    ///
    /// The conservation rule: a hidden lane keeps its state and is still
    /// counted by the mast, including scrolled-off ones, because a hidden
    /// session that needs you is exactly what this deck exists not to
    /// conceal. The strip declines to draw it; the rail says it is there.
    public let isHidden: Bool
    /// What the fleet says a human is being shown: `rec.waitingFor.value`,
    /// projected only while `state == .needsYou`. A roster that omits the
    /// session's row leaves the last value standing, so the record can carry
    /// a STALE reason on a lane that has moved on. Gating on `state` keeps
    /// that from reaching a surface.
    public let waitingFor: String?
    /// The session's last recorded word, when it was an API-error message:
    /// `LaneRecord.apiError`'s projection, Claude Code's text verbatim (the
    /// dialog-parity rule: the deck relays, never reinterprets).
    ///
    /// **Gated on `rec.state == .errored`**, for the same staleness reason as
    /// `waitingFor`: the record keeps a stale `apiError` until the next write
    /// that touches it, so a lane that is not `.errored` renders none.
    public let apiError: Redacted?
    /// Whether any hold the deck still remembers, open or resolved, has
    /// existed for this session. Projected from `state.holds` and read only
    /// where there is no live decision to show.
    ///
    /// **"Still remembers", not "ever existed".** `sweepHolds` forgets a
    /// resolved hold once it is older than `HoldPolicy.memory`, so a session
    /// whose one hold aged out reads `false` even though a hold did open.
    /// That decay is safe: it can understate custody (falling back to the
    /// never-held copy) but never manufacture a false claim.
    ///
    /// `HandedBackNotice`'s copy is the one consumer: a lane raised straight
    /// to needs-you by a holdless Notification or a hookless fleet discovery
    /// was never the deck's to hand back, and this tells that case apart from
    /// a hold that really did expire.
    public let sawAHold: Bool

    public init(session: SessionID, state: LaneState, isExpanded: Bool,
                contextPercent: Int?, sources: [String: EventID],
                contextStale: Bool = false,
                color: CardColor = .slot(0),
                directory: Redacted? = nil, transcriptPath: Redacted? = nil, title: Redacted? = nil,
                prompt: Redacted? = nil, prompts: [Redacted] = [],
                transcript: [TranscriptEntry] = [],
                branch: Redacted? = nil,
                lastTool: String? = nil, permissionMode: String? = nil,
                host: HostAddress? = nil,
                isHidden: Bool = false,
                waitingFor: String? = nil,
                apiError: Redacted? = nil,
                sawAHold: Bool = false) {
        self.session = session; self.state = state; self.isExpanded = isExpanded
        self.contextPercent = contextPercent; self.contextStale = contextStale
        self.sources = sources
        self.color = color
        self.directory = directory; self.transcriptPath = transcriptPath
        self.title = title; self.prompt = prompt
        self.prompts = prompts
        self.transcript = transcript
        self.branch = branch; self.lastTool = lastTool
        self.permissionMode = permissionMode
        self.host = host
        self.isHidden = isHidden
        self.waitingFor = waitingFor
        self.apiError = apiError
        self.sawAHold = sawAHold
    }

    /// **Hand-written; see `sources` for why `==` cannot be synthesized.**
    /// Every field below is rendered screen content; `sources` is
    /// bookkeeping that moves on every confirming touch. Comparing it would
    /// make this `==`, and `Frame`'s which walks `lanes`, disagree with the
    /// screen.
    public static func == (lhs: LaneView, rhs: LaneView) -> Bool {
        lhs.session == rhs.session
            && lhs.state == rhs.state
            && lhs.isExpanded == rhs.isExpanded
            && lhs.contextPercent == rhs.contextPercent
            && lhs.contextStale == rhs.contextStale
            && lhs.color == rhs.color
            && lhs.directory == rhs.directory
            && lhs.transcriptPath == rhs.transcriptPath
            && lhs.title == rhs.title
            && lhs.prompt == rhs.prompt
            && lhs.prompts == rhs.prompts
            && lhs.transcript == rhs.transcript
            && lhs.branch == rhs.branch
            && lhs.lastTool == rhs.lastTool
            && lhs.permissionMode == rhs.permissionMode
            && lhs.host == rhs.host
            && lhs.isHidden == rhs.isHidden
            && lhs.waitingFor == rhs.waitingFor
            && lhs.apiError == rhs.apiError
            && lhs.sawAHold == rhs.sawAHold
    }

    /// The last two path components, which is what a person actually reads a
    /// directory by. `/Users/h/workspace/openagentdeck` -> `workspace/openagentdeck`.
    ///
    /// In the core rather than the view, and computed rather than stored
    /// (architecture §1): a shortening rule inside a SwiftUI body can only be
    /// checked by rendering it. The frame keeps the whole path, so nothing
    /// downstream has to reconstruct what was dropped.
    ///
    /// Two components rather than one because a single one collides
    /// constantly: many directories are called `src`, `app` or `web`.
    public var directoryTail: String? {
        guard let directory else { return nil }
        let parts = directory.value.split(separator: "/").map(String.init)
        guard !parts.isEmpty else { return "/" }
        return parts.suffix(2).joined(separator: "/")
    }

    /// What to call this lane in a list.
    ///
    /// Title, then the tail of the directory, then the session id. A person
    /// navigates by the name they gave the work and falls back to where it is
    /// happening; the raw id is the last resort and is meant to look like one.
    ///
    /// `"/"` is what `directoryTail` yields for a path with no components, and
    /// it names nothing — a row labelled with it is a row nobody can pick out
    /// of a list, so it falls through to the id like any other empty value.
    public var name: String {
        if let title = title?.value, !title.isEmpty { return title }
        if let tail = directoryTail, !tail.isEmpty, tail != "/" { return tail }
        return session.raw
    }

    /// The legibility falsifier, computed rather than argued about: a lane whose
    /// **only** identifying mark is an opaque session id.
    ///
    /// The session id is not removed — it is the one thing that survives a
    /// `--resume`, so it stays as the identity of record. What it may not be is
    /// the identity on *display*, alone.
    public var isIdentifiedOnlyByID: Bool {
        directory == nil && title == nil && prompt == nil && branch == nil
    }
}

/// A decision the frame is offering, **with the thing it decides**.
///
/// The pairing is the point, and why this is one type rather than a hold
/// list beside a subject lookup: a live session once showed ALLOW and DENY
/// over a command the user could not see, because the frame was asked
/// whether it was truthful and never whether it was answerable. One type
/// that carries both cannot disagree with itself.
public struct Decision: Equatable, Codable, Sendable {
    public let hold: HoldID
    /// What is about to happen. `nil` only when the payload was unreadable, and
    /// then the surface must say so in as many words.
    public let subject: Subject?
    /// A question call's questions, if this is one. Empty otherwise —
    /// A question call's questions, if this is one. Empty otherwise,
    /// including for an `AskUserQuestion` the deck could not decode: "never
    /// hold what you cannot answer" (see `HoldPolicy.needsAHuman`) means no
    /// hold, and so no `Decision`, is ever built for one.
    public let questions: [Question]
    /// Which question is showing and what is selected on it. In the frame
    /// rather than in the view because the pure-renderer rule makes the
    /// renderer a pure function of this value.
    public let progress: AnswerProgress?
    /// One label per element of the hold's `permission_suggestions` (Claude
    /// Code's option 2, "Yes, and don't ask again for: X"), derived by
    /// `SuggestionLabel`. Usually zero or one entry; never dropped or
    /// reordered, because **index alignment with the hold's raw `suggestions`
    /// array is the contract the response encoder relies on**: `DecisionBar`
    /// sends back the tapped index and `HookResponse.decision` reads that
    /// index out of `Hold.suggestions`. Empty when the engine sent no
    /// suggestions.
    public let suggestionLabels: [String]

    public init(hold: HoldID, subject: Subject?, questions: [Question] = [],
                progress: AnswerProgress? = nil, suggestionLabels: [String] = []) {
        self.hold = hold; self.subject = subject
        self.questions = questions; self.progress = progress
        self.suggestionLabels = suggestionLabels
    }

    /// The question on screen right now, if this decision is a question call.
    public var currentQuestion: Question? {
        let step = progress?.step ?? 0
        return questions.indices.contains(step) ? questions[step] : nil
    }

    /// True when the CURRENT step carries at least one option with a
    /// preview, which decides whether this decision's home is the full-strip
    /// `QuestionStage` takeover rather than `DetailBand`'s pinned
    /// `QuestionTakeover`. A bare question stays in the band; the stage
    /// exists for the room a preview needs. Lives beside `currentQuestion`
    /// so callers do not re-derive it.
    public var currentQuestionHasPreview: Bool {
        currentQuestion?.hasPreview ?? false
    }

    /// **Whether this decision's home is the full-strip `QuestionStage`
    /// takeover, not `DetailBand`'s pinned `QuestionTakeover`.**
    ///
    /// `DeckWindow` (which raises the overlay) and `DetailBand` (which must
    /// suppress its own takeover for the same hold while the overlay owns
    /// it) must agree, so the rule is decided once, here.
    ///
    /// True only for a question call whose current step carries a preview
    /// and only while the user has not dismissed the stage for THIS hold.
    /// Dismissal is per-hold, view-local state kept by `DeckWindow`
    /// (`dismissedStage`), passed in as a plain value so the rule stays pure.
    public func showsStage(dismissedStage: HoldID?) -> Bool {
        currentQuestionHasPreview && hold != dismissedStage
    }

    /// True when this frame can tell the user what they are agreeing to.
    /// A question is its own subject; a tool call needs its detail.
    public var namesItsSubject: Bool {
        if !questions.isEmpty { return currentQuestion != nil }
        guard let subject else { return false }
        return subject.detail != nil
    }
}

/// A question mirror, projected: the stages `Decision` cannot carry,
/// because `decisions` (below) is filtered to holds that are still
/// `isActionable`, and `.released`/`.terminalLive`/`.resolved` exist only on
/// a hold that has stopped being open.
///
/// **Not a second cache.** Built fresh off `state.mirrors` on every
/// projection, like `decisions` against `state.holds`; nothing is retained
/// longer than `state.mirrors` itself (`DeckState.retainedItems`,
/// `sweepHolds`). `questions` is `[Question]`, never `QuestionCall`, because
/// `QuestionCall` carries a raw `JSONValue` and is not `Codable`.
public struct MirrorView: Equatable, Codable, Sendable, Identifiable {
    public let hold: HoldID
    public let stage: MirrorStage
    public let questions: [Question]
    /// True while `state.forwarding[hold]` names an in-flight plan (the pill
    /// bar's `Frame.debouncingActionIDs` pattern). A mirror's options render
    /// disabled while a tap cannot mean anything new: the terminal is already
    /// receiving a scripted sequence this tap would duplicate or race.
    public let forwarding: Bool
    /// The awaiting-confirmation window: true while
    /// `QuestionMirror.forwardSentAt` is set and `stage` is still
    /// `.terminalLive`. A plan was sent in full and nothing has resolved the
    /// mirror yet. Not the same as `forwardUnconfirmed` below ("elapsed with
    /// nothing to show"); this is "sent, still waiting, allowance not up".
    /// Both surfaces disable option rows on `forwarding ||
    /// awaitingConfirmation`, extending the `forwarding` reasoning past the
    /// moment cmux reports `.sent` to the moment something confirms it, which
    /// closes a double-send window seen live.
    public let awaitingConfirmation: Bool
    /// True while `QuestionMirror.forwardUnconfirmedAt` is set: a plan was
    /// sent and `HoldPolicy.forwardLandingAllowance` elapsed with no
    /// confirmation. The deck can confirm a landing but never confirm its
    /// absence, hence "unconfirmed". Read by `MirrorStatusLabel.status(for:
    /// forwardUnconfirmed:)` to say "No confirmation yet" with a "Send again"
    /// control, on both surfaces that read it.
    public let forwardUnconfirmed: Bool

    public init(hold: HoldID, stage: MirrorStage, questions: [Question], forwarding: Bool = false,
               awaitingConfirmation: Bool = false, forwardUnconfirmed: Bool = false) {
        self.hold = hold; self.stage = stage; self.questions = questions
        self.forwarding = forwarding
        self.awaitingConfirmation = awaitingConfirmation
        self.forwardUnconfirmed = forwardUnconfirmed
    }

    /// **The shared option-row disable predicate**, one derivation for both
    /// `QuestionMirrorCard` and `QuestionMirrorStage`. `forwarding` alone
    /// stops covering the gap once `.forwardStepSent` marks the plan
    /// complete: a `.terminalLive` mirror between that instant and a real
    /// confirmation or an explicit "Send again" is where a live double-send
    /// landed. `true` for the unconfirmed phase too, since
    /// `awaitingConfirmation` stays true (the reducer never clears
    /// `forwardSentAt` when it sets `forwardUnconfirmedAt`).
    public var optionsDisabled: Bool { forwarding || awaitingConfirmation }

    /// `ForEach`'s key. `HoldID` is `Hashable` and never reused across two
    /// calls (session + tool_use_id), so this satisfies the
    /// snapshot-coherence rule (never an array offset) by construction.
    public var id: HoldID { hold }

    /// The question on screen: always the first. A mirror never steps
    /// through a multi-question call (no deck-side stepper once the hold has
    /// fallen through), so no `progress` field is needed.
    public var question: Question? { questions.first }

    /// `.resolved`'s preview truth: previewed options still matter for a
    /// resolved review. Named like `Decision.currentQuestionHasPreview`:
    /// one rule, not re-derived at call sites.
    public var currentQuestionHasPreview: Bool { question?.hasPreview ?? false }

    /// **`Decision.showsStage(dismissedStage:)`'s twin: the mirror is another
    /// input to the SAME rule, not a second one.** True for
    /// `released`/`terminalLive`/`resolved` alike: a preview earned the
    /// full-strip treatment while the hold was open, and the hold falling
    /// through or the call finishing does not change that. Dismissal is
    /// per-hold; `DeckWindow`'s `dismissedStage` is a single `HoldID?`
    /// shared across both sources.
    public func showsStage(dismissedStage: HoldID?) -> Bool {
        currentQuestionHasPreview && hold != dismissedStage
    }
}

/// Turns one raw `permission_suggestions` element into a sentence a person
/// can read on a button. This is the only place the engine's shape is read
/// field by field: `HookEvent.permissionSuggestions` and `Hold.suggestions`
/// carry it as an untyped `JSONValue`.
/// **Unknown is not error.** A `type` this deck has never seen still gets a
/// label (its own name) rather than being dropped, because dropping it would
/// desynchronise `Decision.suggestionLabels` from `Hold.suggestions`: the
/// encoder indexes the raw array by the tapped label position, so a short
/// label list would echo back the wrong suggestion.
public enum SuggestionLabel {
    /// Every suggestion on a hold, labelled, in the same order (the index
    /// alignment `Decision.suggestionLabels` documents).
    public static func labels(from suggestions: JSONValue?) -> [String] {
        (suggestions?.arrayValue ?? []).map(label(for:))
    }

    /// One suggestion, labelled.
    ///
    /// The branches are the three shapes the LVV-permission fixture and the
    /// CLI 2.1.223 schema name for `permission_suggestions[]`. `setMode` has
    /// not been recorded live; its field name (`mode`) comes from the schema
    /// prose, so re-check it against a live capture.
    public static func label(for suggestion: JSONValue) -> String {
        switch suggestion["type"]?.stringValue {
        case "addRules":
            let rules = suggestion["rules"]?.arrayValue ?? []
            let names = rules.map { rule in
                rule["ruleContent"]?.stringValue ?? rule["toolName"]?.stringValue ?? "?"
            }
            return "Don't ask again for: \(names.joined(separator: ", "))"
        case "setMode":
            return "Switch mode to \(suggestion["mode"]?.stringValue ?? "?")"
        case let other:
            // Unknown-is-not-error: render the type the wire sent rather
            // than a placeholder that pretends the deck recognised it.
            return "Apply: \(other ?? "unknown")"
        }
    }
}

/// The usage dot: each window tinted by its own load while the account
/// reads fine, red with the reset time while one is at its limit. The rules
/// come from the LV19 recording:
///
///   - the statusline's `rate_limits` is the only machine-readable source;
///     no hook speaks at the refusal, so no event drives this;
///   - LIMITED is a deadline fact and outlives the feed (the feed goes quiet
///     at the limit): it renders until `resetsAt` passes, staleness be
///     damned. `at >= resetsAt` ends limited whatever the last reading said
///     (a stale 100 rendered one turn into the new window, so the clock has
///     to beat the feed);
///   - a FINE reading wears its per-window load colour at any age, never
///     dimmed to grey, matching the context gauge ("a context reading does
///     not rot"). Red is reserved for the deadline alarm above.
///
/// Two channels, the token and the label, and the label is non-optional the
/// way `Meter`'s is for red (the labelled-red rule).
public struct UsageIndicator: Equatable, Codable, Sendable {
    public let label: String
    public let limited: Bool
    /// The binding window's deadline while limited: what the runtime's one
    /// sanctioned timer (the idle-CPU rule, `usage-reset`) sleeps until. nil
    /// when fine.
    public let resetsAt: Instant?
    /// The windows `label` was built from, in the same order (soonest
    /// deadline first), so the view can colour each by ITS OWN percentage.
    /// Two facts are two facts, not one number: one colour on the
    /// concatenated label would let "5h:3% 7d:81%" collapse back into a
    /// single reading through paint, since a reader cannot tell which window
    /// earned the colour. Every projected indicator populates it.
    ///
    /// Codable landmine, not yet armed: nothing DECODES this type today, but
    /// synthesized `Decodable` ignores the init's `= []` default, so decoding
    /// bytes encoded before this field existed will throw `keyNotFound`.
    /// When decoding starts, write a custom `init(from:)` with
    /// `decodeIfPresent`.
    public let windows: [Window]

    public init(label: String, limited: Bool, resetsAt: Instant? = nil,
                windows: [Window] = []) {
        self.label = label
        self.limited = limited; self.resetsAt = resetsAt
        self.windows = windows
    }
}

public extension UsageIndicator {
    /// One rate-limit window as the indicator renders it: the same token and
    /// capped percentage the label carries, so a view can colour off ONE
    /// window's number.
    struct Window: Equatable, Codable, Sendable {
        /// The wire's short token ("5h", "7d"), the same one `label` shows.
        public let shortName: String
        /// Capped at 100, the same value `label` shows. The projection is the
        /// one place this number is decided; a view must not apply its own cap.
        public let percent: Int

        public init(shortName: String, percent: Int) {
            self.shortName = shortName; self.percent = percent
        }
    }
}

public extension UsageIndicator.Window {
    /// A stepped judgment on one window's load rather than a continuous hue
    /// ramp: the deck uses a handful of named system colours (see
    /// DecisionBar.swift), so the ramp is a small enum, not a blend.
    ///
    /// The thresholds are judgment, not measurement: under half is quiet
    /// enough to ignore, and 80 is roughly where a window's remainder starts
    /// to govern what you dare queue against it.
    enum Load: Equatable, Codable, Sendable {
        case easy, busy, heavy
    }

    var load: Load {
        switch percent {
        case ..<50: .easy
        case ..<80: .busy
        default: .heavy
        }
    }
}

public extension UsageIndicator {
    /// What this reading says out loud.
    ///
    /// A tooltip is not an answer here: `help` needs a pointer, and the
    /// surfaces this app is for (a touchscreen strip, an iPad over Sidecar)
    /// have none. The condition goes in the accessibility label, which a
    /// screen reader reads and a tooltip can repeat for the mouse.
    var spokenDescription: String {
        limited ? "Account is at its usage limit. \(label)"
                : "Account usage, \(label)"
    }
}

/// A resource meter — the context bar, and anything else that fills.
/// Resource red never appears without its text label: a red bar with no
/// number beside it is an alarm without a cause. The label is non-optional
/// whenever the token is red, and `unlabelledAlarms` computes the
/// falsifier.
public struct Meter: Equatable, Codable, Sendable {
    public let name: String
    /// **Used, exactly as Claude Code reports it.** The wire field is
    /// `context_window.used_percentage` and this is that integer, unaltered.
    ///
    /// Don't invert it to "remaining": the fuel-gauge rule (UX_DESIGN §2)
    /// is for the ACCOUNT USAGE gauge, and on context it contradicted the
    /// terminal (`ctx:91%` drawn as a nearly empty bar labelled `9% left`).
    /// The deck does not reinterpret a number it only relays. The bar fills
    /// as context is consumed (UX_DESIGN §3: "red >= 90 %").
    public let used: Int
    public let severity: Severity
    public let label: String?
    public init(name: String, used: Int, severity: Severity, label: String?) {
        self.name = name; self.used = used
        self.severity = severity; self.label = label
    }

    /// The one place this number is turned into words, so the bar, the
    /// card's footer and the labelled-red rule phrase it the same way. The
    /// idiom is the terminal statusline's own.
    public var reading: String { Meter.reading(used) }

    private static func reading(_ used: Int) -> String { "ctx:\(used)%" }

    /// UX_DESIGN §3: red at 90 % or more of the window consumed.
    ///
    /// The clamp is here, not at the callers: `used_percentage` arrives in
    /// an untrusted statusline payload, and derivations that bound their
    /// input differently would disagree.
    public static func context(usedPercent: Int) -> Meter {
        let used = max(0, min(100, usedPercent))
        let red = used >= 90
        return Meter(name: "context", used: used,
                     severity: red ? .alarm : .normal,
                     label: red ? reading(used) : nil)
    }
}

/// **A stepped judgment on a session's context percent, the sibling of
/// `UsageIndicator.Window.Load`: a small enum of system colours (see
/// `DecisionBar.swift`), not a blend.**
///
/// **One rule everywhere ctx renders** (the fleet card's footer text and the
/// band's big-number readout), never two drifting colour ladders for the
/// same number. 50 is caution, 75 is alarm, both boundaries inclusive on
/// the HIGHER side, so a session exactly on a line already reads as the
/// state it is about to become. This is deliberately different from
/// `Meter.context(usedPercent:)`'s single 90% red line: that meter answers
/// "is this worth a LABELLED alarm on the bar" (two-state); this answers
/// "what colour is this number" (a three-state ramp).
public enum ContextLoad: Equatable, Codable, Sendable {
    case calm, caution, alarm

    /// 50 — below this, `.calm`; at or above, at least `.caution`.
    public static let cautionThreshold = 50
    /// 75 — below this, at most `.caution`; at or above, `.alarm`.
    public static let alarmThreshold = 75

    /// Not clamped. The feed does NOT bound it: `Statusline` parses the
    /// integer raw, the reducer stores it raw, and
    /// `LaneView.contextPercent` projects it raw. The one clamp is
    /// render-side, `Meter.context(usedPercent:)`, and every surface that
    /// draws or speaks the number derives it from that meter. This type
    /// stays unclamped because its answer is already honest at every
    /// integer (below 0 is `.calm`, above 100 is `.alarm`), and bounding
    /// rules belong to the meter.
    public init(percent: Int) {
        switch percent {
        case ..<Self.cautionThreshold: self = .calm
        case ..<Self.alarmThreshold: self = .caution
        default: self = .alarm
        }
    }
}

/// One entry of the selected session's queue, as the panel shows it.
///
/// Carries the TITLE rather than leaving the panel to look it up in
/// `actions`: an action deleted while a copy is queued would otherwise
/// render as a blank row. The id rides along because the badge on a cell
/// must know which cell it belongs on, and two actions may share a title.
public struct QueuedView: Equatable, Codable, Sendable {
    public let actionID: String
    public let title: String
    public let status: QueuedAction.Status
    public init(actionID: String, title: String, status: QueuedAction.Status) {
        self.actionID = actionID; self.title = title; self.status = status
    }
}

public struct Frame: Equatable, Codable, Sendable {
    /// The projection instant: WHEN this frame was built, not a fact drawn
    /// from state. It is deliberately **not** part of `==` below (see that
    /// hand-written conformance).
    public let at: Instant
    /// In session-start order, UNLESS the user has hand-ordered the fleet.
    /// Prefs `cardOrder` is the one sanctioned reordering (see
    /// `Projection.manualOrder` for the merge rule). State and urgency never
    /// reorder lanes.
    public let lanes: [LaneView]
    /// Equals the number of needs-you lanes, including any that are
    /// scrolled off. Conservation, not a visible-window count.
    public let mastNeedsYou: Int
    /// The lanes off the strip, and how many of them are asking for a human.
    ///
    /// Separate from `mastNeedsYou` rather than derived by the renderer: the
    /// rail says *where* the concealed request is, the mast says *how many*.
    /// What to call a lane in THIS frame.
    ///
    /// `LaneView.name` is what a lane calls itself, and two sessions in one
    /// directory call themselves the same thing. A list of identical rows
    /// cannot be picked from, so a colliding name earns the short form of its
    /// session id, the one thing that is always distinct.
    public func displayName(for lane: LaneView) -> String { lane.name }

    /// The short id that tells two same-named lanes apart, or nil when the
    /// name already stands alone.
    ///
    /// Kept OFF the name: appended, it made the name longer than a sidebar
    /// and middle-truncation ate the part that identified the lane. It
    /// belongs on the second line, beside the branch.
    public func disambiguator(for lane: LaneView) -> String? {
        let base = lane.name
        guard base != lane.session.raw,
              lanes.contains(where: { $0.session != lane.session && $0.name == base })
        else { return nil }
        return String(lane.session.raw.prefix(6))
    }

    // Partitioned ONCE, at construction, rather than on every read: a
    // renderer reads all three every draw, and SwiftUI renders far more
    // often than events arrive. A frame is built once and read many times.
    public let visibleLanes: [LaneView]
    public let hidden: [LaneView]
    public let hiddenNeedsYou: Int
    /// Under Reduce Motion every motion becomes one static two-step opacity
    /// change, and **no information is removed**: the same tokens and glyphs.
    /// Dropping a glyph with its animation would signal by colour alone,
    /// breaking the two-channel rule.
    public let reduceMotion: Bool
    /// The decisions this frame offers, each carrying what it decides.
    ///
    /// The fall-through rule's falsifier is "an armed Allow/Deny in a frame
    /// for a hold past expiry", so the list lives in the frame. After
    /// fall-through the terminal is sole authority and this list is empty
    /// for that hold, permanently.
    public let decisions: [Decision]

    /// The holds alone, for rules that only care about identity. Computed
    /// from `decisions` rather than stored beside it: one list makes an armed
    /// control with a missing subject unrepresentable.
    public var actionableHolds: [HoldID] { decisions.map(\.hold) }
    /// Question mirrors past `.deckWindow`: `released`, `terminalLive` and
    /// `resolved`, the stages a hold stops being `isActionable` for and so
    /// never reach `decisions`. `.resolved` projects only within
    /// `HoldPolicy.resolvedMirrorLinger` of its resolution
    /// (`Projection.projectsMirror`). Sorted oldest-stage-first
    /// (`MirrorStage.at`), tie-broken on the hold's description, so a
    /// `ForEach` never reorders a card out from under a finger mid-tap.
    public let mirrors: [MirrorView]
    public let meters: [Meter]
    /// How many rules the deck can see are muting PreToolUse for it.
    ///
    /// A **floor**, and the frame says so: the deck cannot enumerate
    /// pre-existing `permissions.allow` entries, project-layer settings, or a
    /// `PATH` wrapper's injected set (SG10), so the true number is larger. A
    /// bare count would break the provenance rule.
    public let mutedFloor: Int
    public let mutedIsFloor: Bool
    /// The usage dot, or nothing — absence means the deck has not heard
    /// recently enough to claim anything, which is the honest default.
    public let usage: UsageIndicator?
    /// The session the right-hand panel is about, **validated**: a
    /// selection whose lane is gone selects nothing, and the projection is
    /// where that is noticed rather than the reducer holding a stale id.
    public let selection: SessionID?
    /// The actions the panel offers, in the user's own order. Empty when
    /// nothing is selected — the panel does not exist to be empty.
    public let actions: [QuickAction]
    /// What the selected session's queue is doing, oldest first. The surface
    /// shows what is in it and what each entry's status is; it never claims
    /// more than the core knows.
    public let queued: [QueuedView]
    /// Why the panel's cells are dark, or nil when they are live. A
    /// disabled control carries its reason in the same frame that disables it,
    /// so "an enabled cell while the socket refuses" and "a mute failure" are
    /// both falsifiable from one value.
    public let actionBlock: ActionBlock?
    /// **The debounce fact.** Which of the selected session's action ids
    /// render dark, independent of `actionBlock`: a tapped pill stays dark
    /// until the session's OWN next lifecycle event, so a second tap cannot
    /// re-arm what the first has not yet been answered by. Per action, not
    /// per bar: `Continue` beside a dark `Escape` stays live.
    ///
    /// An id is dark iff EITHER it has a pending entry (queued, or sent and
    /// not yet confirmed; `state.pending[selection]`), OR its most recent
    /// send (`LaneRecord.lastSentAt`) has no session event strictly newer
    /// (`lane.lastEventAt <= sentAt`). The second clause re-arms an
    /// UNCONFIRMABLE send like `/compact` or Escape, which never earns a
    /// pending receipt, once the session's next event proves it moved.
    public let debouncingActionIDs: Set<String>
    /// **The sentence the panel shows about a wait, built where the facts are.**
    ///
    /// It names the ACTIONS, because "waiting for the usage window" does not
    /// say what will happen when it opens. It lives in the frame, not the
    /// view, and goes in the reason BANNER rather than the footer because at
    /// 447 pt the footer holds about 22 characters and this needs fifty.
    public var holdNotice: String? {
        guard queueAwaitsUsage else { return nil }
        let waiting = queued.filter { $0.status == .queued }.map(\.title)
        guard !waiting.isEmpty else { return nil }
        let names: String
        switch waiting.count {
        case 1: names = waiting[0]
        case 2: names = "\(waiting[0]) and \(waiting[1])"
        default:
            names = waiting.dropLast().joined(separator: ", ") + " and " + waiting[waiting.count - 1]
        }
        return "\(names) will be sent when the usage limit resets."
    }

    /// The selected session's queue is waiting for the account's usage window
    /// to reset, not for the session. The mast's dot already carries the
    /// time, so the panel only says which wait it is.
    public let queueAwaitsUsage: Bool
    /// **Whether the selected session continues itself, and whether it can.**
    ///
    /// Two facts: `autoContinueOn` is the preference; `autoContinuable` is
    /// whether the deck could honour it (it needs a surface to key the
    /// preference on and a Continue in the offered set). A checkbox for a
    /// lane the deck cannot route to would be the mute-failure class the
    /// darkened-control rule exists for.
    public let autoContinueOn: Bool
    public let autoContinuable: Bool
    /// Whether Hide could be honoured for the selected lane.
    ///
    /// The hidden-lanes preference is keyed on the SURFACE (it must survive a
    /// session restart; a session id lasts one invocation), so a lane with no
    /// address has nothing to key it on and the runtime's `hide` declines it.
    /// A Hide button for such a lane would be a mute failure. It is its own
    /// flag because `autoContinuable` also needs a Continue action; a
    /// routable lane with no Continue still gets Hide, and only Delete
    /// (which tombstones the session id) needs no surface.
    public let hidable: Bool
    /// The delete the panel is asking about, with the sentence it must show.
    ///
    /// **The copy is the feature.** SG9: supervision loss is invisible, and
    /// a delete is that arriving deliberately. So the confirmation says what
    /// will happen rather than asking "are you sure": the session keeps
    /// running and asking, where the deck cannot relay it.
    public let confirmingDelete: Bool
    public static let deleteConfirmation =
        "It keeps running and keeps asking for permission — in its own terminal, "
        + "where you will have to answer. The deck stops showing it and stops "
        + "counting it, including when it needs you."
    /// The selected session's queue has waited without the session moving.
    /// A fact about the clock, which the renderer does not have.
    public let queueStalled: Bool

    public init(at: Instant, lanes: [LaneView], mastNeedsYou: Int,
                reduceMotion: Bool = false,
                decisions: [Decision],
                mirrors: [MirrorView] = [],
                meters: [Meter] = [], mutedFloor: Int = 0,
                usage: UsageIndicator? = nil,
                selection: SessionID? = nil,
                actions: [QuickAction] = [],
                queued: [QueuedView] = [],
                actionBlock: ActionBlock? = nil,
                debouncingActionIDs: Set<String> = [],
                queueAwaitsUsage: Bool = false,
                autoContinueOn: Bool = false,
                autoContinuable: Bool = false,
                hidable: Bool = false,
                confirmingDelete: Bool = false,
                queueStalled: Bool = false) {
        self.at = at; self.lanes = lanes; self.mastNeedsYou = mastNeedsYou
        // One pass for the partition and the count the rail needs.
        var visible: [LaneView] = [], concealed: [LaneView] = []
        visible.reserveCapacity(lanes.count)
        var concealedWaiting = 0
        for lane in lanes {
            if lane.isHidden {
                concealed.append(lane)
                if lane.state == .needsYou { concealedWaiting += 1 }
            } else {
                visible.append(lane)
            }
        }
        self.visibleLanes = visible
        self.hidden = concealed
        self.hiddenNeedsYou = concealedWaiting
        self.reduceMotion = reduceMotion
        self.decisions = decisions
        self.mirrors = mirrors
        self.meters = meters
        self.mutedFloor = mutedFloor
        self.mutedIsFloor = true
        self.usage = usage
        self.selection = selection
        self.actions = actions
        self.queued = queued
        self.actionBlock = actionBlock
        self.debouncingActionIDs = debouncingActionIDs
        self.queueAwaitsUsage = queueAwaitsUsage
        self.autoContinueOn = autoContinueOn
        self.autoContinuable = autoContinuable
        self.hidable = hidable
        self.confirmingDelete = confirmingDelete
        self.queueStalled = queueStalled
    }

    // No `hasTakeover` / `isSelectable`: decisions live in the band, so a tap
    // on a card is always a select.

    /// **Hand-written, and deliberately not the synthesized conformance.**
    ///
    /// `DeckRuntime.refresh` publishes a fresh frame only when it differs
    /// from the one showing (`@Observable` fires on SET, not on CHANGE), so
    /// a poll that finds the world unchanged must not repaint a twelve-card
    /// fleet. That guard only works if two frames projected from the same
    /// state compare EQUAL, and a synthesized `==` could not: `at` is the
    /// projection instant, so it differs on every call
    /// (`PerformanceTests.frameEqualityIgnoresTheProjectionInstant`).
    ///
    /// `at` is the only field excluded at this level. `LaneView.contextStale`
    /// is a comparison against a max age, not a copy of the clock, so it
    /// moves only at a threshold crossing; excluding it too would hide a
    /// real staleness flip. `lhs.lanes == rhs.lanes` carries its own
    /// exclusion one level down (`LaneView.==` leaves out `sources`, which a
    /// hook stream churns on nearly every event; `InvalidationTests`
    /// drives real events through `DeckRuntime` to cover it).
    ///
    /// `visibleLanes`, `hidden`, `hiddenNeedsYou` and `mutedIsFloor` are
    /// also left out: all four are pure functions of `lanes` (and
    /// `mutedFloor`) computed once in `init`, so comparing them cannot
    /// disagree. If one ever becomes independent of `lanes`, add it here.
    public static func == (lhs: Frame, rhs: Frame) -> Bool {
        lhs.lanes == rhs.lanes
            && lhs.mastNeedsYou == rhs.mastNeedsYou
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.decisions == rhs.decisions
            && lhs.mirrors == rhs.mirrors
            && lhs.meters == rhs.meters
            && lhs.mutedFloor == rhs.mutedFloor
            && lhs.usage == rhs.usage
            && lhs.selection == rhs.selection
            && lhs.actions == rhs.actions
            && lhs.queued == rhs.queued
            && lhs.actionBlock == rhs.actionBlock
            && lhs.debouncingActionIDs == rhs.debouncingActionIDs
            && lhs.queueAwaitsUsage == rhs.queueAwaitsUsage
            && lhs.autoContinueOn == rhs.autoContinueOn
            && lhs.autoContinuable == rhs.autoContinuable
            && lhs.hidable == rhs.hidable
            && lhs.confirmingDelete == rhs.confirmingDelete
            && lhs.queueStalled == rhs.queueStalled
    }

    /// The labelled-red rule's falsifier: a red meter fill with no adjacent label token.
    public var unlabelledAlarms: [Meter] {
        meters.filter { $0.severity == .alarm && ($0.label?.trimmed.isEmpty ?? true) }
    }

}

/// How long a fed value stays on screen after the receipt that supplied it.
///
/// "A feed that stops feeding empties its slot... past it, the slot
/// renders empty, never the last known value." The recorded statusline
/// payload carries no emission timestamp (12 top-level keys; the only
/// temporal values are future `resets_at` deadlines), so staleness is
/// measured from **deck receipt**, which is why the reducer stamps arrival.
///
/// The durations are proposals and **not ratified** (SG1); only the
/// mechanism is enforced, and changing one is a one-line diff.
public struct MaxAges: Equatable, Sendable {
    public var contextPercent: Millis
    public init(contextPercent: Millis) {
        self.contextPercent = contextPercent
    }
    /// Statusline cadence is per-render, so 30 s is several missed renders.
    public static let proposed = MaxAges(contextPercent: Millis(30_000))
}

/// When a finished lane stops taking up space.
///
/// UX_DESIGN: *"Normal SessionEnd - lane holds 60 s (green if it just
/// finished), then collapses - but only while the strip is untouched for >= 5 s
/// and no takeover is active."* A deck left running showed finished lanes
/// forever, so this implements the collapse.
///
/// **Retirement is a projection decision, not a reducer one.** The lane
/// record stays in state (a session that speaks again must get its lane
/// back; a lane exists because an event created it, not because a timer
/// spared it). The frame simply stops including it.
///
/// The "untouched for >= 5 s" half is **not** implemented: the deck has no
/// touch state. The grace period and the takeover suspension are, so a lane
/// never collapses out from under a decision somebody is reading.
public struct LanePolicy: Equatable, Sendable {
    public var endedGrace: Millis
    public init(endedGrace: Millis) { self.endedGrace = endedGrace }
    public static let spec = LanePolicy(endedGrace: Millis(60_000))
    /// For replaying a recorded stream, where every session ended hours ago and
    /// the question is about ingest, not housekeeping.
    public static let neverRetire = LanePolicy(endedGrace: Millis(Int64.max))
}

public enum Projection {

    /// The surface a selected lane lives in, or nil.
    ///
    /// The preference is keyed on the surface rather than the session (see
    /// `DeckPrefs.autoContinue`), so every question about it hops through the
    /// surface first. A lane with no address cannot answer, which
    /// `autoContinuable` reports rather than showing an unticked box.
    static func surfaceOf(_ selection: SessionID?, in lanes: [LaneView]) -> String? {
        guard let selection else { return nil }
        return lanes.first { $0.session == selection }?.host?.surface
    }


    /// Whether a mirror is still shown past `.deckWindow`.
    ///
    /// Every stage but `.resolved` projects unconditionally: `.released` and
    /// `.terminalLive` are waiting on something. `.resolved` is DONE; left
    /// alone it would sit in the band's act zone (hiding the transcript well,
    /// which already carries the same answer as a ledger row) until
    /// `sweepHolds`'s 20-minute `HoldPolicy.memory`, which bounds
    /// `state.mirrors`, not the glass. See `HoldPolicy.resolvedMirrorLinger`.
    ///
    /// `<=`, not `<`: the boundary instant still projects, the inclusive
    /// convention `Hold.expiresAt` comparisons use. Applies to every
    /// `ResolvedOrigin` alike; only the stage is read, never the origin.
    static func projectsMirror(_ mirror: QuestionMirror, at: Instant, policy: HoldPolicy) -> Bool {
        switch mirror.stage {
        case .deckWindow: return false
        case .released, .terminalLive: return true
        case .resolved(_, _, let resolvedAt):
            let age = at.sinceStart.raw - resolvedAt.sinceStart.raw
            return age <= policy.resolvedMirrorLinger.raw
        }
    }

    /// The one sanctioned reordering: the user's own hand, via prefs
    /// `cardOrder` (keyed on the surface; see `DeckPrefs.cardOrder`).
    /// `derived` is `DeckState.order` (session-start order, ties on session
    /// id), which this function never touches; it only re-sorts its OUTPUT.
    ///
    /// **Total and deterministic, three rules:**
    ///   1. A session whose surface appears in `stored` sorts by that
    ///      surface's INDEX in `stored`. Sessions sharing one surface (a
    ///      relaunch mid-frame, `/exit` and a fresh session in the same tab)
    ///      tie and keep their relative `derived` order.
    ///   2. A session with no host, or a surface `stored` does not name,
    ///      sorts AFTER every stored session, in `derived` order.
    ///   3. A stored surface with no live session contributes no entry; it
    ///      stays in `stored` for when the pane returns.
    ///
    /// One sort gets all three: `stored` is only looked UP by surface, never
    /// walked (rule 3); unmatched sessions share the key `stored.count`
    /// (rule 2); the key is the index (rule 1). Ties break explicitly on
    /// `derived`'s index rather than leaning on `sorted(by:)` stability.
    ///
    /// `rank` keeps the FIRST index for a repeated surface. `DeckPrefs.decode`
    /// already dedupes, but this stays total under any input.
    static func manualOrder(derived: [SessionID], surfaces: [SessionID: String],
                            stored: [String]) -> [SessionID] {
        guard !stored.isEmpty else { return derived }
        var rank: [String: Int] = [:]
        for (index, surface) in stored.enumerated() where rank[surface] == nil {
            rank[surface] = index
        }
        let tail = stored.count
        return derived.enumerated()
            .sorted { a, b in
                let ai = surfaces[a.element].flatMap { rank[$0] } ?? tail
                let bi = surfaces[b.element].flatMap { rank[$0] } ?? tail
                return ai == bi ? a.offset < b.offset : ai < bi
            }
            .map(\.element)
    }

    public static func frame(from state: DeckState, at: Instant,
                             maxAges: MaxAges = .proposed,
                             lanePolicy: LanePolicy = .spec,
                             reduceMotion: Bool = false) -> Frame {
        // A takeover suspends collapsing entirely: a lane vanishing while
        // somebody reads the decision above it would move every target on the
        // strip mid-glance (the no-moving-targets rule).
        let takeoverActive = state.holds.values.contains(where: \.isOpen)
        // The manual-order merge lives HERE, at the projection seam, not
        // stored pre-merged: `DeckState.order` stays exactly what `ReplayTests`
        // pins (session-start, ties on session id), and since prefs are part
        // of `state`, the same `(state, at)` always projects the same order.
        // `surfaces` is built once, not per lane.
        let surfaces = state.lanes.compactMapValues { $0.host?.value.surface }
        let ordered = manualOrder(derived: state.order, surfaces: surfaces, stored: state.prefs.cardOrder)

        // At most one takeover is expanded in any frame: the displayed
        // front's lane (promoted-if-open, else the earliest waiter), one
        // definition shared with the reducer and the renderer. A needs-you
        // lane with no open hold keeps the earliest-waiter expansion; nothing
        // renders a takeover for it (no decisions).
        let expanded = state.displayedFront?.session
            ?? ordered.first { state.lanes[$0]?.state == .needsYou }

        let lanes: [LaneView] = ordered.compactMap { id in
            guard let rec = state.lanes[id] else { return nil }
            // Finished long enough ago that the space is worth more than the
            // record. Only from `.ended`: an errored lane persists until
            // dismissed, because a failure nobody saw must not vanish.
            // The SELECTED lane is exempt too (somebody is reading it): the
            // band is bound to the selection, so retiring the lane would
            // collapse the band mid-sentence and reflow the fleet.
            if rec.state == .ended, !takeoverActive, id != state.selected,
               let decided = rec.stateDecidedAt,
               at.sinceStart - decided.sinceStart >= lanePolicy.endedGrace {
                return nil
            }
            // The gauge keeps its last-known reading and the frame MARKS its
            // age instead of erasing it.
            let gauge = rec.contextPercent.value
            var gaugeStale = false
            if gauge != nil, let decided = rec.contextDecidedAt {
                gaugeStale = at.sinceStart - decided.sinceStart > maxAges.contextPercent
            }

            var sources = ["state": rec.stateSource]
            if let cs = rec.contextSource, gauge != nil { sources["contextPercent"] = cs }
            // For a background session the **fleet feed owns the light bar**.
            // The deck's only own-authority colouring is an auto-deny, and a
            // feed still reporting `working` overrules it: the deck may not
            // say a background session failed when the thing that sees it
            // says otherwise.
            var shown = rec.state
            if rec.isBackground, rec.fleetState.value == "working", shown == .errored {
                shown = .working
            }

            // Provenance: a slot reaches the frame only together with the id
            // of the event that filled it.
            if let v = rec.cwd { sources["directory"] = v.source }
            if let v = rec.transcriptPath { sources["transcriptPath"] = v.source }
            if let v = rec.title { sources["title"] = v.source }
            if let v = rec.prompt { sources["prompt"] = v.source }
            if let v = rec.lastTool { sources["lastTool"] = v.source }
            if let v = rec.permissionMode { sources["permissionMode"] = v.source }
            if let v = rec.host { sources["host"] = v.source }
            // Only a branch that exists gets a provenance entry; a lane off a
            // worktree carries neither value nor source.
            if let v = rec.branch, v.value != nil { sources["branch"] = v.source }
            // The window the user asked for, from the capped history. The
            // newest entry's event stands for the list (each entry keeps its
            // own provenance in state).
            let window = Array(rec.prompts.prefix(max(1, state.prefs.promptHistory)))
            if let newest = window.first { sources["prompts"] = newest.source }

            // The transcript ledger in two parts (see `LaneView.transcript`
            // for why not one global sort). The persisted half
            // (`rec.transcript`) is stored newest-first (like `prompts`, for
            // capping/dedup), so it is reversed to lead with OLDEST. The
            // still-queued, payload-bearing tail is synthesized fresh from
            // `state.pending`, never stored, in DRAIN order (oldest-queued
            // first).
            let queuedTail: [TranscriptEntry] = (state.pending[id] ?? [])
                .filter { $0.sentAt == nil && $0.action.payload != nil }
                .sorted { $0.queuedAt < $1.queuedAt }
                .map { q in
                    TranscriptEntry(text: Redacted(q.action.payload!), origin: .deck,
                                    deckStatus: .queued, at: q.queuedAt,
                                    source: EventID("action:\(q.action.id)@\(q.queuedAt.sinceStart.raw)"),
                                    actionID: q.action.id)
                }
            let transcript = Array(rec.transcript.reversed()) + queuedTail
            // Cite the chronologically newest row across BOTH halves: a queued
            // tail entry can postdate the persisted rows.
            if let newest = transcript.max(by: { $0.at < $1.at }) { sources["transcript"] = newest.source }

            return LaneView(session: id,
                            state: shown,
                            isExpanded: id == expanded,
                            contextPercent: gauge,
                            sources: sources,
                            contextStale: gaugeStale,
                            // The stored choice for this lane's DIRECTORY, if recorded
                            // (`Reducer.recordCardColorIfNeeded`); otherwise a fallback
                            // that hashes the directory, so lanes sharing one directory
                            // read as the same colour before either has a recorded
                            // assignment (a session-id hash could not promise that).
                            // The session-id hash is the LAST resort, for a lane with no
                            // directory yet, so it still renders some stable colour.
                            color: {
                                if let dir = rec.cwd?.value.value, !dir.isEmpty {
                                    if let chosen = state.prefs.directoryColors[dir] {
                                        return chosen
                                    }
                                    return .slot(CardColor.fallbackSlot(for: dir))
                                }
                                return .slot(CardColor.fallbackSlot(for: id.raw))
                            }(),
                            directory: rec.cwd?.value,
                            transcriptPath: rec.transcriptPath?.value,
                            title: rec.title?.value,
                            prompt: rec.prompt?.value,
                            prompts: window.map(\.value),
                            transcript: transcript,
                            branch: rec.branch?.value ?? nil,
                            lastTool: rec.lastTool?.value,
                            permissionMode: rec.permissionMode?.value,
                            host: rec.host?.value,
                            // Hidden is a property of the SURFACE, so a lane the deck
                            // has no address for can never be hidden.
                            isHidden: {
                                guard let surface = rec.host?.value.surface else { return false }
                                return state.prefs.hidden.contains(surface)
                            }(),
                            // Gated on `rec.state`, not `shown` (they agree whenever
                            // either is `.needsYou`; the fleet override only turns
                            // `.errored` into `.working`). A roster that omits this
                            // session's row leaves the field standing after the lane
                            // moved on; this is where that staleness is stopped.
                            waitingFor: rec.state == .needsYou ? rec.waitingFor.value : nil,
                            // Gated on `rec.state` like `waitingFor` above: a lane that
                            // is not `.errored` must never surface a stale `apiError`.
                            apiError: rec.state == .errored ? rec.apiError?.value : nil,
                            // Any hold at all, open or resolved. Read only where there is
                            // no live decision, so it answers "was there ever one that
                            // has since closed".
                            sawAHold: state.holds.values.contains { $0.id.session == id })
        }

        // The usage dot, from the account slot: limited by deadline, the
        // clock over the feed at that deadline's edge; a fine reading is fine
        // at any age (see UsageIndicator).
        var usage: UsageIndicator? = nil
        if let read = state.usage {
            // `DeckState.bindingUsageWindow` is the answer the send gate reads too;
            // two implementations of "is the account at its limit" would let the
            // dot and the queue disagree about when it ends.
            let binding = state.bindingUsageWindow(at: at)
            // **Every window, each one named**, never a `max()` under a bare
            // "% Usage": at five-hour 3 % and seven-day 81 % that read "81%
            // Usage" beside a nearly empty five-hour window, a different fact.
            // Spelled like the context gauge (`5h:3%`) and ordered by DEADLINE,
            // so the window that resets soonest leads.
            let sortedWindows = read.value.sorted { $0.resetsAt < $1.resetsAt }
            // Built once; `reading` is derived FROM `indicatorWindows` so the
            // label and the per-window array cannot drift apart (separate maps
            // would each round and cap on their own).
            let indicatorWindows = sortedWindows.map {
                UsageIndicator.Window(shortName: $0.shortName, percent: min($0.usedPercentage, 100))
            }
            let reading = indicatorWindows
                .map { "\($0.shortName):\($0.percent)%" }
                .joined(separator: " ")
            // **The reading outlives its feed, UNMARKED**, like the context
            // gauge. A figure that vanished when stale looked like a deck that
            // never heard one, and the statusline only speaks while a session
            // is working. Keeping it says the one true thing (the last
            // reading) without dimming it to a different-looking state.
            if let window = binding {
                let leftMs = window.resetsAt.sinceStart.raw - at.sinceStart.raw
                let minutes = Int((leftMs + 59_999) / 60_000)
                let resets = minutes >= 60
                    ? "resets in \(minutes / 60)h \(minutes % 60)m"
                    : "resets in \(minutes)m"
                // An em dash, not a middot: the dot beside this label is already
                // a round mark, and a second made the row read as three bullets.
                usage = UsageIndicator(label: "\(reading) — \(resets)",
                                       limited: true, resetsAt: window.resetsAt,
                                       windows: indicatorWindows)
            } else {
                usage = UsageIndicator(label: reading, limited: false,
                                       windows: indicatorWindows)
            }
        }


        // Each actionable hold arrives with its subject attached: the hold
        // stored it at open time, so there is no second lookup that could
        // come back empty.
        //
        // **The displayed front is FIRST** (the promotion-navigates rule's
        // frame half): the renderer draws `decisions.first`, so the expanded
        // lane and the rendered subject name the same hold by construction.
        // The rest follow in front order, (openedAt, id).
        let front = state.displayedFront
        let decisions = state.holds.values
            // A `nil` `expiresAt` is a forever hold (`HoldBudget.untilAnswered`):
            // always actionable while open. The fall-through falsifier has
            // nothing to test against a hold with no expiry.
            .filter { $0.isActionable && ($0.expiresAt.map { at <= $0 } ?? true) }
            .sorted { (a: Hold, b: Hold) -> Bool in
                if a.id == front { return true }
                if b.id == front { return false }
                if a.openedAt == b.openedAt { return a.id.description < b.id.description }
                return a.openedAt < b.openedAt
            }
            .map { Decision(hold: $0.id, subject: $0.subject,
                            questions: state.questions[$0.id]?.questions ?? [],
                            progress: state.answering[$0.id],
                            suggestionLabels: SuggestionLabel.labels(from: $0.suggestions)) }

        // **The stages `decisions` above cannot carry.** `.deckWindow` mirrors
        // are excluded: that stage's hold is still `isActionable`, already
        // showing through `decisions` and the `QuestionTakeover`/`QuestionStage`
        // path; carrying it here too would be a second surface for the same
        // hold. See `MirrorView` for why this is not a second cache.
        let mirrors = state.mirrors.values
            .filter { projectsMirror($0, at: at, policy: state.policy) }
            .sorted { (a: QuestionMirror, b: QuestionMirror) -> Bool in
                let (aAt, bAt) = (a.stage.at ?? .start, b.stage.at ?? .start)
                return aAt == bAt ? a.call.hold.description < b.call.hold.description : aAt < bAt
            }
            .map { mirror in
                let isTerminalLive: Bool
                if case .terminalLive = mirror.stage { isTerminalLive = true } else { isTerminalLive = false }
                return MirrorView(hold: mirror.call.hold, stage: mirror.stage,
                                  questions: mirror.call.questions,
                                  forwarding: state.forwarding[mirror.call.hold] != nil,
                                  awaitingConfirmation: isTerminalLive && mirror.forwardSentAt != nil,
                                  forwardUnconfirmed: isTerminalLive && mirror.forwardUnconfirmedAt != nil)
            }

        // A meter per lane that has a FRESH percentage. An empty slot
        // contributes no meter, and neither does a stale one: the gauge may
        // keep an old reading, but an ALARM raised on it would be a red the
        // deck can no longer vouch for.
        let meters = lanes.compactMap { lane -> Meter? in
            guard let used = lane.contextPercent, !lane.contextStale else { return nil }
            return Meter.context(usedPercent: used)
        }

        // A selection whose lane is gone selects nothing; validated here so a
        // stale id cannot outlive its session (like `displayedFront`).
        let selection = state.selected.flatMap { id in
            lanes.contains(where: { $0.session == id }) ? id : nil
        }
        let queue = selection.flatMap { state.pending[$0] } ?? []

        // The SELECTED lane's directory, read once for the scope-aware
        // questions below (`QuickAction.offerable(_:in:)`). Reading a
        // `Redacted` in-process is fine (it exists to keep text out of
        // ENCODERS and logs); neither the directory nor a folder-scoped
        // pattern reaches a `Diagnostic` or the encoded frame.
        let selectedDirectory = selection.flatMap { id in
            lanes.first(where: { $0.session == id })?.directory?.value
        }

        // Why the cells are dark, most global first: the host refusing
        // outranks everything, then what the last attempt on THIS session
        // found, then the standing fact that the deck has no address for it.
        // `unroutable` is derived, not remembered: a lane's host arrives on
        // every payload, so "no route" is a property of the lane as it stands.
        var block = state.hostBlock
        if block == nil, let selection { block = state.blocked[selection] }
        if block == nil, let selection,
           lanes.first(where: { $0.session == selection })?.host == nil {
            block = .unroutable
        }

        // The debounce fact, **derived here in the projection, not the view**,
        // per action, keyed by `QuickAction.id`. `queue` covers "has a pending
        // entry" (queued or sent-and-unconfirmed both live in `state.pending`
        // until a receipt or cancel). The second half re-arms an UNCONFIRMABLE
        // send (`/compact`, Escape), which leaves `state.pending` the instant
        // it is sent: `lane.lastEventAt <= sentAt` reads "no session event
        // since", from the raw `LaneRecord` because `lastSentAt` is not a
        // rendered field.
        // **This session's offerable set, resolved ONCE** for `actions`,
        // `autoContinuable` and the debounce.
        let offered = selection == nil ? []
            : QuickAction.offerable(state.prefs.quickActions, in: selectedDirectory)

        let debouncing: Set<String> = {
            guard let selection else { return [] }
            var ids = Set(queue.map(\.action.id))
            if let rec = state.lanes[selection] {
                // **Deliberately NOT special-cased on `isConfirmable`.** A slash
                // command emits no submission (LV21/LV23), so no receipt will
                // ever arrive, but this clause waits for the session's next
                // LIFECYCLE EVENT of any kind, and a slash command makes the
                // session work. Carving it out broke
                // `debounceHoldsUntilNextSessionEvent` (`TranscriptLedgerTests`).
                for (actionID, sentAt) in rec.lastSentAt where rec.lastEventAt <= sentAt {
                    ids.insert(actionID)
                }
            }
            return ids
        }()

        return Frame(at: at,
                     lanes: lanes,
                     // **Over EVERY lane, hidden ones included**: conservation holds
                     // "including scrolled-off ones". A counter that dropped what
                     // the strip declines to draw would let the deck conceal a
                     // session asking for a human.
                     mastNeedsYou: lanes.filter { $0.state == .needsYou }.count,
                     reduceMotion: reduceMotion,
                     decisions: decisions,
                     mirrors: mirrors,
                     meters: meters,
                     mutedFloor: state.rules.count,
                     usage: usage,
                     selection: selection,
                     // Only actions that are FINISHED (`rejection(at:among:)`'s
                     // static rules) AND `shows(in: selectedDirectory)`, capped at
                     // `maxOffered` per session (filtering happens before the cap;
                     // see `QuickAction.offerable(_:in:)`). A button still being
                     // edited (no message, label too long, duplicate, empty folder
                     // pattern) lives in prefs for the editor and must never reach
                     // a surface where a finger can send it.
                     actions: offered,
                     queued: queue.map { QueuedView(actionID: $0.action.id,
                                                    title: $0.action.displayTitle,
                                                    status: $0.status) },
                     actionBlock: selection == nil ? nil : block,
                     debouncingActionIDs: debouncing,
                     queueAwaitsUsage: selection.map { state.awaitsUsageWindow($0, at: at) } ?? false,
                     autoContinueOn: surfaceOf(selection, in: lanes)
                         .map(state.prefs.autoContinue.contains) ?? false,
                     // **The SAME per-session set `actions` above reads, not the raw
                     // stored one.** A Continue scoped to a folder that does not
                     // name this session's directory must disarm the toggle, as one
                     // dragged past the cap does
                     // (`QuickActionTests.continuePastTheCapDisarmsAutoContinue`);
                     // otherwise the checkbox would promise a Continue this panel
                     // does not offer.
                     autoContinuable: surfaceOf(selection, in: lanes) != nil
                         && offered.contains { $0.id == QuickAction.continueID },
                     hidable: surfaceOf(selection, in: lanes) != nil,
                     confirmingDelete: state.confirmingDelete != nil
                         && state.confirmingDelete == selection,
                     queueStalled: selection.map { state.stalledQueues(at: at).contains($0) } ?? false)
    }
}

public extension Frame {
    /// Fields carrying a value with no provenance entry. The provenance
    /// rule's falsifier, computed over a frame rather than argued about in
    /// review.
    var unprovenancedFields: [String] {
        var bad: [String] = []
        for lane in lanes {
            if lane.sources["state"] == nil { bad.append("\(lane.session).state") }
            if lane.contextPercent != nil, lane.sources["contextPercent"] == nil {
                bad.append("\(lane.session).contextPercent")
            }
            // The identity block is held to the same rule as the numbers: a
            // directory on screen with no event behind it is the same defect.
            for (name, present) in [("directory", lane.directory != nil),
                                    ("title", lane.title != nil),
                                    ("prompt", lane.prompt != nil),
                                    ("prompts", !lane.prompts.isEmpty),
                                    ("transcript", !lane.transcript.isEmpty),
                                    ("transcriptPath", lane.transcriptPath != nil),
                                    ("branch", lane.branch != nil),
                                    ("lastTool", lane.lastTool != nil),
                                    ("permissionMode", lane.permissionMode != nil),
                                    ("host", lane.host != nil)]
            where present && lane.sources[name] == nil {
                bad.append("\(lane.session).\(name)")
            }
        }
        return bad
    }

    var expandedCount: Int { lanes.filter(\.isExpanded).count }

    /// The legibility falsifier for a lane: nothing on it a person recognises.
    var lanesIdentifiedOnlyByID: [SessionID] {
        lanes.filter(\.isIdentifiedOnlyByID).map(\.session)
    }
}

/// Recorded events in, frames out. Nothing else — no files, no clock, no I/O.
/// The harness that reads `events.ndjson` lives in the test target, because
/// reading a file is exactly the kind of thing `DeckCore` is not allowed to do.
public enum Replay {
    public static func run(_ events: [DeckEvent],
                           from start: DeckState = DeckState(),
                           lanePolicy: LanePolicy = .neverRetire) -> (state: DeckState, frames: [Frame]) {
        var state = start
        var frames: [Frame] = []
        for event in events {
            Reducer.reduce(&state, event)
            frames.append(Projection.frame(from: state, at: timestamp(of: event),
                                           lanePolicy: lanePolicy))
        }
        return (state, frames)
    }

    static func timestamp(of event: DeckEvent) -> Instant {
        switch event {
        case .hook(let h):                 return h.at
        case .statusline(_, let at, _):    return at
        // A user gesture, so its own instant is the history (unlike `.recap`).
        case .autoContinueSetForAll(_, _, let at, _): return at
        case .fleet(_, let at, _):         return at
        case .decision(_, _, let at):      return at
        case .holdExpired(_, let at):      return at
        case .promote(_, let at):          return at
        // A config change is not a moment on the deck's timeline; it projects
        // no frame of its own.
        case .configRequested, .configConfirmed: return .start
        case .restart(let at):             return at
        case .prefsChanged(_, let at):     return at
        case .gesture(_, _, let up, _):    return up
        case .revokeRule:                  return .start
        case .worktree(_, _, let at, _):   return at
        case .transcriptSeeded(_, _, let at): return at
        case .apiError(_, _, let at, _):      return at
        // **`.start`, NOT the event's own `at`.** A recap's `at` says where
        // its ROW sits in a ledger sorted by event time (see `DeckEvent.recap`),
        // not what moment the deck is at, and is routinely NEGATIVE (a summary
        // written before this runtime started rebases before `Instant.start`).
        // Returning it would stamp a replayed frame at a moment the deck was
        // never at. A constant, like `.configRequested`/`.revokeRule`, cannot
        // depend on arrival order (`ReplayTests`' permutation-stability bar).
        case .recap:                          return .start
        case .located(_, _, let at, _):    return at
        case .questionOpened(_, let at):   return at
        case .questionSubmitted(_, _, let at): return at
        case .questionPicked(_, _, let at):    return at
        case .questionAnsweredFreely(_, _, _, let at): return at
        case .questionCommitted(_, let at):    return at
        case .questionSteppedBack(_, let at):  return at
        case .questionAbandoned(_, let at):    return at
        case .forwardPlanStarted(_, let at):   return at
        case .forwardStepSent(_, let at):      return at
        case .forwardPlanCancelled(_, let at): return at
        case .mirrorReadinessElapsed(_, let at): return at
        case .mirrorObservedLive(_, let at):     return at
        case .forwardUnconfirmed(_, let at):     return at
        case .forwardRearmed(_, let at):         return at
        case .promoteNext(let at):             return at
        case .sessionSelected(_, let at):      return at
        case .actionQueued(_, _, let at):      return at
        case .actionSent(_, _, let at):        return at
        case .actionBlocked(_, _, let at):     return at
        case .actionCancelled(_, _, let at):   return at
        case .queueCleared(_, let at):         return at
        case .dismissRequested(let at):        return at
        case .deleteRequested(_, let at):      return at
        case .deleteConfirmed(_, let at):      return at
        case .deleteAbandoned(let at):         return at
        }
    }
}
