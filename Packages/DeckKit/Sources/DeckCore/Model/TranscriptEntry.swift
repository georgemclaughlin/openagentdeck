//
//  TranscriptEntry.swift · DeckCore/Model
//
//  One row of what a session has been told, through either door.
//
//  The card shows the last thing said through ANY door: a real terminal
//  prompt typed by a human, or an action the deck itself sent. A slash command
//  fires no `UserPromptSubmit` (so a tapped `/compact` would otherwise show
//  nothing), and an unconfirmable action retires from the queue the instant it
//  is sent (`DeckState.apply`'s `.actionSent` case).
//
//  `TranscriptEntry` is the well's ledger: ONE merged, chronological, per-lane
//  list of terminal prompts and deck sends, each deck row carrying what the
//  deck itself witnessed (sent, or confirmed by a matching receipt).
//  `LaneRecord.transcript` holds it, capped and idempotent like `prompts`
//  (see `LaneRecord.rememberPrompt`); `rememberTranscript` and
//  `confirmTranscript` are its two writers.
//
//  `deckStatus` deliberately reuses `QueuedAction.Status`: a deck row passes
//  through the same `.queued`/`.sent`/`.confirmed` states as `state.pending`
//  entries. The projected transcript a lane's view exposes
//  (`LaneView.transcript`, `Frame.swift`) synthesizes `.queued` rows from
//  `state.pending` at render time and never stores one here:
//  `rememberTranscript` runs only at `.actionSent` (already `.sent`) and at a
//  real `UserPromptSubmit` receipt (`.confirmed`, via `confirmTranscript`).
//

/// One row: a real prompt a person typed, or an action the deck sent —
/// what it said, when, and (for a deck row) what the deck has witnessed
/// about it since.
public struct TranscriptEntry: Equatable, Codable, Sendable {
    public enum Origin: Equatable, Codable, Sendable {
        /// A human typed this — a real `UserPromptSubmit`, the same text
        /// `LaneRecord.prompts` carries. Kept as its own origin-tagged copy
        /// because the well needs both doors interleaved in one list and
        /// `prompts` cannot say which rows were typed and which were sent.
        case terminal
        /// The deck sent this — a tapped quick action, with a payload.
        case deck
        /// An `AskUserQuestion` call got an answer, via the deck's mirror or
        /// at the terminal directly (`PostToolUse`). One origin for both: the
        /// ledger shows WHAT was chosen; `Hold.outcome` keeps which door it
        /// came through. `text` is the composed "question: chosen label(s)"
        /// line from `DeckState.describeAnswers`, `Redacted` like every other
        /// row.
        case answeredQuestion
        /// **Claude Code's own recap: the only row nobody said.** The session
        /// summarizing ITSELF, an `away_summary` row Claude Code writes into
        /// its transcript, which `TranscriptTail.latestRecap(fromJSONL:)`
        /// looks for because no hook carries it.
        ///
        /// **Its `at` is the recap's OWN moment**, converted from the
        /// transcript row's wall-clock timestamp, not the moment it was found.
        /// A recap can be hours old when the deck reads it, and stamping it
        /// at discovery would make it read as current. It also makes
        /// re-finding idempotent: the same recap carries the identical
        /// `(at, text, origin)` that `rememberTranscript` refuses to duplicate.
        case recap
    }

    public let text: Redacted
    public let origin: Origin
    /// `nil` for `.terminal`: a real prompt has nothing "the deck witnessed"
    /// about it. Present for `.deck`, starting at `.sent` and upgraded in
    /// place to `.confirmed` by `confirmTranscript`. Never `.queued` here: a
    /// queued action is not history yet and appears only as a PROJECTED row.
    public var deckStatus: QueuedAction.Status?
    /// The event time. For `.deck`, the SEND instant, held fixed when
    /// `confirmTranscript` upgrades the status, so a row never jumps position
    /// when its receipt lands.
    public let at: Instant
    /// Provenance, as for `Sourced<Value>`. A `.terminal` row carries the real
    /// `HookEvent`'s id. `.actionSent` has no `EventID` (it is a runtime
    /// command, not a wire event; see `DeckEvent.actionSent`), so a `.deck`
    /// row's source is SYNTHESIZED deterministically from the action id and
    /// send instant (`EventID("action:\(id)@\(at)")`, at the one call site):
    /// reproducible under replay, unique enough to tie-break a
    /// same-millisecond sort, and never mistaken for a wire event's id.
    public let source: EventID
    /// The `QuickAction`'s id, for `.deck` rows only (`nil` for `.terminal`).
    /// An alternative to text matching for `confirmTranscript`, and the key
    /// for the per-action debounce.
    public let actionID: String?

    public init(text: Redacted, origin: Origin, deckStatus: QueuedAction.Status?,
               at: Instant, source: EventID, actionID: String?) {
        self.text = text; self.origin = origin; self.deckStatus = deckStatus
        self.at = at; self.source = source; self.actionID = actionID
    }
}
