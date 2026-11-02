//
//  DeckState.swift · DeckCore/Reducer
//
//  (State, Event) -> State. Pure, synchronous, total.
//
// Two invariants:
// - Lane order comes from each session's EARLIEST event time, not arrival
//   order. An append-on-first-sight list breaks order-insensitivity under
//   permuted replay.
// - Which event decides a lane's state is settled by WHEN IT HAPPENED, not
//   when it arrived (see `dominates`). Letting the last-applied event win made
//   replaying the same recorded events in a different order produce a
//   different deck.

public enum LaneState: String, Equatable, Codable, Sendable, CaseIterable {
    case idle
    case working
    case needsYou
    /// Two producers, one state: a background session the fleet feed reports as
    /// failed (only values in the KNOWN failure set, never an unforeseen one), or
    /// a session whose own transcript recorded an API-error message as its last
    /// word (`DeckEvent.apiError`, `TranscriptTail.apiErrorLastWord(fromJSONL:)`).
    /// Unlike `needsYou`, nobody is being asked for a decision. The transcript
    /// producer carries its text (`LaneRecord.apiError`); the fleet producer never
    /// does.
    case errored
    case ended
}

/// A displayed value together with the event that supplied it and when that
/// event happened.
///
/// Makes the provenance rule a type: every rendered value traces to a received
/// event, and a value cannot be written without naming its source (this
/// replaces three parallel fields that could be updated two at a time).
///
/// `decidedAt` is the *event's* timestamp, never arrival, because `dominates`
/// resolves precedence by when something happened.
public struct Sourced<Value: Equatable & Sendable>: Equatable, Sendable {
    public var value: Value
    public var source: EventID
    public var decidedAt: Instant
    public init(value: Value, source: EventID, decidedAt: Instant) {
        self.value = value; self.source = source; self.decidedAt = decidedAt
    }
}

public struct LaneRecord: Equatable, @unchecked Sendable {
    /// The one place the bound lives.
    public static let historyCap = 8

    public let session: SessionID
    public var firstSeenAt: Instant
    public var lastEventAt: Instant

    public var state: LaneState
    /// Provenance of `state`. Never nil: a lane exists because an
    /// event created it, and the frame says which one.
    public var stateSource: EventID
    /// When the event that *decided* `state` happened. nil means no event has
    /// decided it yet — a lane created by an event the deck does not recognise
    /// holds `.idle` and must still yield to the first event that does decide.
    public var stateDecidedAt: Instant?

    /// The session's own last recorded word, when it was an API-error message.
    /// Written only by the `DeckEvent.apiError` handler, gated by the same
    /// dominance check as the hook-transition gate. The text is Claude Code's
    /// verbatim (the deck relays, never reinterprets).
    ///
    /// Cleared everywhere `state` moves off `.errored` (hook transition gate,
    /// `acknowledge(_:as:)`, fleet apply), so an unrelated later `.errored` never
    /// wears a stale message.
    public var apiError: Sourced<Redacted>?
    /// The last thing the fleet feed said about this session, and when. For
    /// background sessions the fleet feed owns the light bar, so a deck-side
    /// auto-deny never colours it. Kept apart from `state` because precedence
    /// needs both claims present.
    public var fleetState: Fed<String>
    /// What the fleet says a human is being asked, verbatim (`claude agents
    /// --json`'s `waitingFor`: "permission prompt", "dialog open", "input needed",
    /// "sandbox request", "worker request"). Like `fleetState`, an absent value
    /// CLEARS the slot on every poll whose roster carries the row, so a closed
    /// dialog stops showing. A roster that omits the session's row entirely
    /// leaves the last value standing. Consumers read it only while the lane's
    /// state still justifies it; demotion is driven by row status plus hold state
    /// alone (`movable` in the fleet apply never reads this field).
    public var waitingFor: Fed<String>
    public var isBackground: Bool
    /// The lane's recent actions, newest first, capped at `historyCap` so memory
    /// stays bounded under sustained events. Ordered by timestamp, not arrival,
    /// so permuted replay lands on one list.
    public var activity: [(at: Instant, what: String)] = []
    public var contextPercent: Fed<Int>
    /// Provenance of `contextPercent`, present exactly when a value is.
    public var contextSource: EventID?
    public var contextDecidedAt: Instant?

    // ------------------------------------------------------- who this lane is
    // Fields that answer "is this one mine?", fastest first.
    //
    // None has a max age, deliberately. Staleness empties slots fed by a sampled
    // feed; these are facts (directory, title, last prompt) that stay true until
    // changed, and blanking them after quiet would make a quiet lane unfindable.

    /// `cwd`. The fastest identifier; the Claude Code statusline shows the same
    /// value.
    public var cwd: Sourced<Redacted>?
    /// `payload.transcript_path`, fed like `cwd` (`absorb`, in
    /// `apply(_:HookEvent)`). Never read by `DeckCore` (no filesystem I/O); only
    /// carried and projected to `LaneView.transcriptPath` (`Frame.swift`) so the
    /// app layer knows which file to read for backfill.
    public var transcriptPath: Sourced<Redacted>?
    /// `session_title`, computed by Claude Code and sent unasked.
    public var title: Sourced<Redacted>?
    /// `UserPromptSubmit.prompt`. What the session was last *told*, as opposed
    /// to what it is *named* — a resumed session has a stale title and a fresh
    /// prompt, so both earn their space.
    public var prompt: Sourced<Redacted>?
    /// The recent prompts, newest first, capped at `historyCap`. Same discipline
    /// as `activity`: ordered by event time, deduplicated on (instant, text),
    /// each entry provenanced.
    public var prompts: [Sourced<Redacted>] = []
    /// `permission_mode`. Whether a user should expect this session to stop.
    public var permissionMode: Sourced<String>?
    /// The most recent tool name. What it is doing now, rather than what it was
    /// asked to do.
    public var lastTool: Sourced<String>?
    /// Derived; fails to nothing. Never computed here: a port answers, and a
    /// `cwd` that is not a worktree yields no branch rather than a placeholder.
    ///
    /// Doubly optional: outer `nil` means nobody has asked yet; inner `nil` means
    /// asked, and the answer was "not a worktree". The latter must be able to
    /// overwrite a previously shown branch (a session that `cd`s out of a repo
    /// loses its branch).
    public var branch: Sourced<Redacted?>?
    /// Where the host says this session lives, fed like the other identity slots
    /// and re-fed by every payload. A lane without one can be watched but not
    /// spoken to, and the frame says so instead of offering dead controls.
    public var host: Sourced<HostAddress>?
    /// When this session last took a prompt, and last finished a turn.
    ///
    /// The pair IS the idle predicate: busy means `lastStopAt <
    /// lastPromptAt`. `lane.state` cannot answer it — a `Notification` moves a
    /// long-idle lane to needs-you, and a long-idle session is exactly the one
    /// a person queues "Continue" on.
    public var lastPromptAt: Instant?
    public var lastStopAt: Instant?

    /// The transcript-well ledger: real terminal prompts and deck sends merged
    /// chronologically. Newest first, capped and deduplicated like `prompts`.
    /// Written by `rememberTranscript` (fresh `.terminal` row, or fresh `.deck`
    /// row at `.sent`) and `confirmTranscript` (upgrades a `.deck` row to
    /// `.confirmed` in place). Queued-not-yet-sent rows are never stored here;
    /// they are projected at render time from `state.pending`.
    public var transcript: [TranscriptEntry] = []
    /// The SEND instant of the most recent `.actionSent` per `QuickAction.id`,
    /// updated unconditionally (even for payload-less actions like Escape, which
    /// write no transcript row). A pill stays dark exactly while
    /// `lane.lastEventAt` has not moved past the recorded instant.
    public var lastSentAt: [String: Instant] = [:]
    /// One-shot guard for `.transcriptSeeded`: a second seed for this lane is a
    /// no-op. The reducer does not trust callers' discipline, since re-seeding
    /// could re-insert entries already scrolled past or double-count against the
    /// merged ledger (see `Reducer.apply(_:for:.transcriptSeeded)`).
    public var transcriptSeeded: Bool = false

    /// Feed one identity slot, respecting precedence.
    ///
    /// An absent value leaves the slot alone: a `PreToolUse` carries no prompt,
    /// and a lane must not forget what it was told because the next event was
    /// about something else. That is the difference between *this event says
    /// nothing about the slot* and *this event says the slot is empty*, which is
    /// the same distinction `Fed` draws one layer down.
    mutating func absorb<V>(_ path: WritableKeyPath<LaneRecord, Sourced<V>?>,
                            _ incoming: V?, at: Instant, id: EventID) {
        guard let incoming else { return }
        let held = self[keyPath: path].map { ($0.decidedAt, $0.source) }
        guard dominates(at, id, over: held) else { return }
        self[keyPath: path] = Sourced(value: incoming, source: id, decidedAt: at)
    }

    /// Feed a slot where **nil is an answer rather than a silence**.
    ///
    /// The distinction `absorb` cannot express, and the same one `Fed` draws at
    /// ingest: *this event says nothing about the slot* and *this event says the
    /// slot is empty* are different facts, and only the second may erase what is
    /// on screen. Used for branch, where "not a worktree" has to be able to
    /// overwrite a branch name and keep its provenance while doing it.
    mutating func decide(_ path: WritableKeyPath<LaneRecord, Sourced<Redacted?>?>,
                         _ incoming: Redacted?, at: Instant, id: EventID) {
        let held = self[keyPath: path].map { ($0.decidedAt, $0.source) }
        guard dominates(at, id, over: held) else { return }
        self[keyPath: path] = Sourced(value: incoming, source: id, decidedAt: at)
    }

    /// Newest-first, capped, and deduplicated on (instant, what) so a
    /// re-delivered event does not lengthen the list.
    mutating func remember(_ what: String, at: Instant) {
        if activity.contains(where: { $0.at == at && $0.what == what }) { return }
        activity.append((at, what))
        activity.sort { $0.at == $1.at ? $0.what > $1.what : $0.at > $1.at }
        if activity.count > Self.historyCap { activity.removeLast(activity.count - Self.historyCap) }
    }

    /// `remember`, for the prompt history — same ordering, same cap, same
    /// idempotence, plus provenance because prompts reach the frame and the
    /// activity line's strings do not (yet).
    mutating func rememberPrompt(_ text: Redacted, at: Instant, id: EventID) {
        if prompts.contains(where: { $0.decidedAt == at && $0.value == text }) { return }
        prompts.append(Sourced(value: text, source: id, decidedAt: at))
        prompts.sort {
            $0.decidedAt == $1.decidedAt
                ? $0.source.raw > $1.source.raw
                : $0.decidedAt > $1.decidedAt
        }
        if prompts.count > Self.historyCap { prompts.removeLast(prompts.count - Self.historyCap) }
    }

    /// `rememberPrompt`, for the merged transcript ledger — same newest-
    /// first order, same cap, same (instant, text) idempotence, plus the two
    /// fields the ledger adds over a plain prompt: `origin` (which door) and
    /// `deckStatus` (`nil` for `.terminal`, `.sent` for a fresh `.deck` row —
    /// `confirmTranscript` is the only path to `.confirmed`, never this one).
    mutating func rememberTranscript(_ text: Redacted, origin: TranscriptEntry.Origin,
                                     deckStatus: QueuedAction.Status?, actionID: String?,
                                     at: Instant, source: EventID) {
        if transcript.contains(where: {
            $0.at == at && $0.text == text && $0.origin == origin && $0.actionID == actionID
        }) { return }
        transcript.append(TranscriptEntry(text: text, origin: origin, deckStatus: deckStatus,
                                          at: at, source: source, actionID: actionID))
        transcript.sort {
            $0.at == $1.at ? $0.source.raw > $1.source.raw : $0.at > $1.at
        }
        if transcript.count > Self.historyCap { transcript.removeLast(transcript.count - Self.historyCap) }
    }

    /// Upgrade the OLDEST still-`.sent` `.deck` row for this action id and text
    /// to `.confirmed`, in place. Mirrors the send queue's oldest-first receipt
    /// match: a receipt confirms the longest-waiting send, because the same
    /// action can be queued twice before the first receipt lands.
    ///
    /// Matched by action id AND text. `transcript` is newest-first, so
    /// `lastIndex` finds the oldest match. Id alone is not enough: a button can
    /// be re-authored (same id, new payload) between two sends, and if the first
    /// send's receipt is lost the second's would confirm the wrong row. Both
    /// values are in hand at the call site, so the tighter predicate never misses
    /// a legitimate confirm.
    mutating func confirmTranscript(actionID: String, text: Redacted) {
        guard let index = transcript.lastIndex(where: {
            $0.origin == .deck && $0.deckStatus == .sent && $0.actionID == actionID && $0.text == text
        }) else { return }
        transcript[index].deckStatus = .confirmed
    }

    public static func == (a: LaneRecord, b: LaneRecord) -> Bool {
        a.session == b.session && a.firstSeenAt == b.firstSeenAt && a.lastEventAt == b.lastEventAt
            && a.state == b.state && a.stateSource == b.stateSource
            && a.stateDecidedAt == b.stateDecidedAt && a.apiError == b.apiError
            && a.fleetState == b.fleetState
            && a.waitingFor == b.waitingFor
            && a.isBackground == b.isBackground && a.contextPercent == b.contextPercent
            && a.contextSource == b.contextSource && a.contextDecidedAt == b.contextDecidedAt
            && a.cwd == b.cwd && a.transcriptPath == b.transcriptPath
            && a.title == b.title && a.prompt == b.prompt
            && a.prompts == b.prompts
            && a.host == b.host
            && a.lastPromptAt == b.lastPromptAt && a.lastStopAt == b.lastStopAt
            && a.permissionMode == b.permissionMode && a.lastTool == b.lastTool
            && a.branch == b.branch
            && a.activity.count == b.activity.count
            && zip(a.activity, b.activity).allSatisfy { $0.at == $1.at && $0.what == $1.what }
            && a.transcript == b.transcript && a.lastSentAt == b.lastSentAt
            && a.transcriptSeeded == b.transcriptSeeded
    }
}

/// Does an event supersede whatever currently holds a slot?
///
/// The wire gives no ordering guarantee (SG5) — independent HTTP POSTs with no
/// sequence field — but every event carries a timestamp, so precedence is a
/// property of the events rather than of the network.
///
/// The tie-break on event id is not decoration: two events can share a
/// millisecond, and without a total order the outcome would depend on
/// dictionary iteration (stable within a process, not across). A slot nobody
/// has decided (`nil`) is dominated by everything.
///
/// This also gives idempotence, so no `seen` set is needed: re-delivering an
/// event cannot change a slot it does not dominate over itself.
func dominates(_ at: Instant, _ id: EventID, over held: (at: Instant, id: EventID)?) -> Bool {
    guard let held else { return true }
    return at == held.at ? id.raw > held.id.raw : at > held.at
}

public struct DeckState: Equatable, Sendable {
    /// The count past which resolved holds are swept, raised whenever a sweep
    /// finds nothing to reclaim. See `sweepHolds`.
    internal var holdSweepAbove: Int = HoldPolicy.sweepAbove

    // `internal(set)`: the reducer is the only writer and lives in this module;
    // everything outside DeckCore (the renderer above all) gets a read-only
    // view, which keeps the renderer a pure function of the frame.
    public internal(set) var lanes: [SessionID: LaneRecord] = [:]
    // There is deliberately no map of superseded surface spellings used to
    // retire surface-keyed preferences (`hidden`, `autoContinue`). It cannot
    // work: every reader looks preferences up by the LIVE lane's current
    // spelling, so a key some live lane uses must stay (or that session silently
    // loses its setting), and a key no live lane uses is a preference for a pane
    // that is simply not running, which must also stay (outliving the session is
    // why they are keyed on the surface). Neither class may be deleted.
    //
    // Instead, `followSurfaceRename` carries a preference ACROSS a re-spelling,
    // and duplicates are avoided at the source: an ENDED session no longer holds
    // a spelling open (`holdsSurface`), which covers `/exit` and a fresh session
    // in the same tab.
    //
    // Known residual: while two sessions are live in one pane and one was
    // re-spelled, the pane is named twice, and if cmux reuses the short ref an
    // unrelated pane can inherit the setting. The real fix is upstream:
    // canonicalise the host's spelling at ingest.

    /// Sessions that started while the standing default was on but before the
    /// deck could address them: the default's one chance, held open.
    ///
    /// `seedAutoContinue` keys on the SURFACE, and a `SessionStart` can arrive
    /// without one (`HostAddress` is failable on either half). Without this the
    /// default would be forfeited for that session, since no later hook or
    /// `.located` retried it, leaving "Continue new sessions automatically" on
    /// above a session that was not armed.
    ///
    /// Transient, not persisted. Readable outside `DeckCore` (the runtime counts
    /// it so "Turn Off for All Sessions" stays reachable while an offer is
    /// outstanding); `internal(set)` rather than `private(set)` because the
    /// reducer is a separate type.
    public internal(set) var awaitingAutoContinue: [SessionID: Instant] = [:]
    /// Open and resolved holds. A resolved hold is kept rather than removed:
    /// The exactly-once rule needs to know that this hold has already ended,
    /// and a forgotten hold is a hold that can be resolved a second time.
    public internal(set) var holds: [HoldID: Hold] = [:]
    public var policy: HoldPolicy = .spec
    /// The diff a preview is currently showing, if any. The preview-then-commit rule's memory.
    public internal(set) var pendingWrite: ConfigDiff?
    /// Every rule the deck created, in creation order. The revocable-rules rule's list.
    public internal(set) var rules: [PermissionRule] = []
    public internal(set) var questions: [HoldID: QuestionCall] = [:]
    /// How far through each open question call the user has got. Reducer
    /// state rather than view state — see `AnswerProgress`, and the
    /// no-state-in-DeckUI rule.
    public internal(set) var answering: [HoldID: AnswerProgress] = [:]
    /// A question call's own mirror, keyed like its `Hold` but OUTLIVING the
    /// hold's resolution, which is why it is a separate dictionary: it carries a
    /// copy of the call (see `QuestionMirror`) because `forgetQuestion` clears
    /// `questions[id]` the instant the hold resolves. Swept alongside `holds`
    /// (`sweepHolds`), never independently, so the two never disagree about which
    /// calls the deck remembers.
    public internal(set) var mirrors: [HoldID: QuestionMirror] = [:]
    /// A `ForwardPlan` in flight — at most one per hold, `nil` once it
    /// finishes, is cancelled, or its own mirror is swept. Swept alongside
    /// `holds`/`mirrors` for the identical reason (`sweepHolds`): a plan
    /// cannot outlive the call it is answering.
    public internal(set) var forwarding: [HoldID: ForwardPlan] = [:]
    /// The hold the user promoted to the front, if any. Display
    /// state: it decides what is *shown*, never what is resolved,
    /// and a stale id — its hold since closed — simply stops mattering, which
    /// is `displayedFront`'s openness check rather than cleanup code.
    public internal(set) var promoted: HoldID?
    /// The lane the right-hand panel is about. Display state, like
    /// `promoted`, and a different question from it: `promoted` decides which
    /// takeover is up, `selected` decides which session is being acted on.
    public internal(set) var selected: SessionID?
    /// Actions waiting per session. **Per session, not per selection** — a
    /// queue that stopped draining because somebody looked elsewhere would be
    /// the deck silently dropping work it was asked to do.
    public internal(set) var pending: [SessionID: [QueuedAction]] = [:]
    /// Why sending is blocked **for every session** — the host refusing the
    /// connection is not a fact about one lane. No socket, no sends,
    /// and the deck says why; a dark control with no reason is the failure this
    /// slot exists to prevent.
    public internal(set) var hostBlock: ActionBlock?
    /// Why sending is blocked for ONE session: no route to it, or a composer
    /// somebody else is using. Cleared by a send that succeeds, because a send
    /// that reached the wire is the only proof the deck ever gets.
    public internal(set) var blocked: [SessionID: ActionBlock] = [:]
    /// When the displayed front last changed identity from one open hold to
    /// **another**. nil → X is a takeover opening and its own
    /// `armedAt` covers it; X → nil is it closing; only X → Y re-arms. The
    /// 400 ms re-arm window for decisions and picks measures from here —
    /// stamped ONLY on a real change, which is what keeps a same-instant
    /// promote-the-front-then-decide sequence legal (P1.23 relies on it).
    public internal(set) var frontChangedAt: Instant?
    /// Account-scoped usage, from the statusline's `rate_limits` (LV19: healthy
    /// 96 %, the hook-silent refusal at 100 %, the reset). ONE slot, not a lane
    /// field: every session's statusline reports the same account, so the newest
    /// report wins by `dominates` like any other fed value.
    public internal(set) var usage: Sourced<[RateWindow]>?

    /// Sessions armed to continue themselves when the account's window reopens,
    /// each holding the DEADLINE of the window that stalled it.
    ///
    /// The deadline is the episode's identity, and that is the loop guard: one
    /// automatic continue per window instance. A fresh window burned by the
    /// continue the deck just sent is a new deadline and a new decision, not a
    /// machine that continues forever.
    public internal(set) var autoLatch: [SessionID: Instant] = [:]

    /// The session a delete has been ASKED for but not confirmed.
    ///
    /// A mode, and modes live here rather than in a view: the panel has
    /// to draw a different thing while it is set, and a `@State` flag in the
    /// renderer would be a piece of the deck's behaviour no test could reach.
    public internal(set) var confirmingDelete: SessionID? = nil
    /// Theme, alpha, motion — the user's, via `.prefsChanged`, for the same
    /// reason `type` lives here: the renderer is a pure function of the frame
    /// and the settings window owns nothing.
    public internal(set) var prefs: DeckPrefs = .firstRun

    public init() {}

    /// The hold a takeover would be showing, if any. Earliest first — the
    /// one-takeover rule allows exactly one, and the
    /// demotion-preserves-the-hold rule says promoting another away from this
    /// one releases nothing.
    public var frontHold: HoldID? {
        openHoldsInOrder.first?.id
    }

    /// The open holds in front order — (openedAt, id), the one ordering both
    /// the front rule and `promoteNext`'s cyclic walk read, so "next" always
    /// means "next-oldest waiter after the one showing".
    var openHoldsInOrder: [Hold] {
        holds.values.filter(\.isOpen).sorted { (a: Hold, b: Hold) -> Bool in
            if a.openedAt == b.openedAt { return a.id.description < b.id.description }
            return a.openedAt < b.openedAt
        }
    }

    /// The one definition of "which takeover is up": the promoted hold while it
    /// is still open, else the earliest waiter. Used by the reducer (re-arm
    /// stamping, demotion clearing), the projection (expanded lane, decision
    /// order) and, through that order, the renderer, which draws
    /// `decisions.first`.
    public var displayedFront: HoldID? {
        if let promoted, holds[promoted]?.isOpen == true { return promoted }
        return frontHold
    }

    /// Session-start order, computed rather than stored (see the file header).
    /// Ties break on the session id so the order is total and reproducible.
    public var order: [SessionID] {
        lanes.values
            .sorted { a, b in
                a.firstSeenAt == b.firstSeenAt
                    ? a.session.raw < b.session.raw
                    : a.firstSeenAt < b.firstSeenAt
            }
            .map(\.session)
    }

    /// Idle CPU is ~0 with no sessions and no motion.
    ///
    /// Sampling a process is L4's and needs one running. The rule underneath is
    /// that an idle deck **asks for no work**: no timers, no polls, nothing
    /// scheduled. A deck that schedules a tick per frame while nothing is
    /// happening burns a battery whatever the profiler says afterwards.
    public var scheduledWork: [TimerID] {
        var timers: [TimerID] = []
        // A forever hold (`budget == nil`, `HoldBudget.untilAnswered`) has no
        // wall-clock expiry and `DeckRuntime.handle` schedules no `Task` for it, so
        // it is not scheduled work; listing it would falsify idle-CPU accounting.
        for hold in holds.values where hold.isOpen && hold.budget != nil {
            timers.append(TimerID("hold-\(hold.id)"))
        }
        // Motion: only a lane asking for a human pulses. `.working` is a steady
        // wash (no frame clock for a constant opacity) and `.errored` is still, so
        // `.needsYou` is the only state left here.
        if lanes.values.contains(where: { $0.state == .needsYou }) {
            timers.append(TimerID("motion"))
        }
        // While a window reads limited, ONE timer flips the dot green when the
        // deadline passes: the feed goes quiet at the limit, so no event will do it.
        if usage?.value.contains(where: { $0.usedPercentage >= 100 }) == true {
            timers.append(TimerID("usage-reset"))
        }
        // A queue waiting on a mid-turn session needs one wake: the stall notice is
        // derived from the clock, and a wedged session emits no further hooks. A
        // deck holding work somebody asked for is not idle. No queue, or an idle
        // session about to take it: no timer.
        if pending.contains(where: { session, queue in
            queue.contains { $0.sentAt == nil } && !isIdle(session)
        }) {
            timers.append(TimerID("stall-watch"))
        }
        return timers
    }

    /// Everything the deck is holding on to, counted. The bounded-memory rule's observable.
    ///
    /// Counts every per-hold and per-session side table, not a chosen few: an
    /// observable that omits a collection only covers the collections somebody
    /// remembered (`questions` and `answering` once leaked unseen).
    public var retainedItems: Int {
        lanes.values.reduce(0) {
            $0 + $1.activity.count + $1.prompts.count + $1.transcript.count + $1.lastSentAt.count
        }
            + holds.count + rules.count
            + questions.count + answering.count + autoLatch.count
            // `mirrors` is swept alongside `holds`, so it needs no line in
            // `sweepHolds`'s bookkeeping.
            + mirrors.count
            // `forwarding`: likewise swept alongside `holds`/`mirrors`.
            + forwarding.count
            + pending.values.reduce(0) { $0 + $1.count }
            + blocked.count
    }

    /// How long a queue may sit with the session neither finishing nor
    /// starting anything before the deck calls it stalled and says so.
    /// Five minutes, not one: LV21 recorded a routine turn at ~57 s, so a
    /// one-minute grace would call ordinary work stalled.
    public static let stallGrace = Millis(300_000)

    /// The usage window that is currently refusing work, if any.
    ///
    /// One definition, read by the send gate AND by the projection, so two
    /// copies of "is the account at its limit" cannot disagree about the moment
    /// it ends.
    ///
    /// Rules measured off LV19: a limited reading outlives its freshness because
    /// the feed goes quiet at the limit, and **the clock beats the feed**:
    /// `at >= resetsAt` ends it whatever the last reading said (a stale 100 %
    /// rendered one turn into the new window).
    public func bindingUsageWindow(at now: Instant) -> RateWindow? {
        usage?.value
            .filter { $0.usedPercentage >= 100 && now < $0.resetsAt }
            .min { $0.resetsAt < $1.resetsAt }
    }

    /// Should this session be armed to continue itself, right now?
    ///
    /// Measured (`fixtures/live/LV19-usage-limit`). A turn refused for budget
    /// leaves this mark on the wire:
    ///     04:10:29  UserPromptSubmit
    ///     04:10:30  statusline  five_hour = 100 %
    ///     04:10:41  UserPromptSubmit
    ///     04:10:42  statusline  five_hour = 100 %
    ///     04:11:41  Notification  idle_prompt
    ///
    /// No `Stop` for either prompt; a healthy turn gets one within seconds. So
    /// "was it mid-work" is this deck's idle predicate inverted (a prompt with no
    /// `Stop` after it), and "was it idle when the limit hit" is a `Stop` newer
    /// than the last prompt, which arms nothing.
    ///
    /// Evaluated continuously while the window binds, not sampled once at its
    /// start: the second prompt above was submitted when the account was ALREADY
    /// at 100 %. That session was idle when the limit bit, then tried to work and
    /// was refused, which is exactly the case to continue; a one-shot snapshot at
    /// the transition misses it.
    func shouldArmAutoContinue(_ session: SessionID, at now: Instant) -> Bool {
        guard let window = bindingUsageWindow(at: now) else { return false }
        guard autoLatch[session] != window.resetsAt else { return false }
        guard let lane = lanes[session], let surface = lane.host?.value.surface,
              prefs.autoContinue.contains(surface) else { return false }
        return !isIdle(session)
    }

    /// Is this session between turns? The wire's own definition — a `Stop`
    /// STRICTLY newer than the last prompt. `lane.state` cannot answer it.
    ///
    /// Strictly: both stamps come from event time, so two events in the same
    /// millisecond are indistinguishable by design, and `>=` would call that tie
    /// idle and let the deck type into a turn that had just started. Busy is the
    /// fail-closed answer; the turn's own `Stop` arrives later and the queue
    /// drains then.
    public func isIdle(_ session: SessionID) -> Bool {
        guard let lane = lanes[session] else { return false }
        guard let prompt = lane.lastPromptAt else { return true }
        guard let stop = lane.lastStopAt else { return false }
        return stop > prompt
    }

    /// A turn that DIED is over even though no `Stop` ever said so: the second
    /// half of the idle question.
    ///
    /// `isIdle` is right for a turn that ENDS and wrong for one that DIES, because
    /// nothing speaks when a turn dies. LV19 records it: every healthy turn gets
    /// a `Stop` within seconds, while the two prompts refused at the limit get a
    /// `Notification` and nothing else, ever.
    ///
    /// Without this, auto-continue deadlocks. `shouldArmAutoContinue` requires
    /// `!isIdle(session)` (only a session MID-TURN when the limit refused it gets
    /// a Continue) while `nextSend` requires `isIdle(session)` before sending a
    /// prompt. The condition that queues the Continue is the one that blocks it,
    /// and a dead turn emits no `Stop` to clear it; the Continue sat "Waiting"
    /// past its reset deadline until a human typed into the session (LV19 row 23).
    ///
    /// The evidence is the lane's own state, not an inference from silence:
    /// `.errored` has exactly one door in (`DeckEvent.apiError`'s handler), where
    /// the transcript's last word was the engine's own refusal.
    ///
    /// Deliberately NOT folded into `isIdle`: the two callers want opposite
    /// answers about a dead turn (arming asks "was there work the limit refused":
    /// yes; sending asks "is there a live turn to protect": no). A turn still
    /// running is not `.errored`, so it still waits for its own `Stop`.
    func turnDied(_ session: SessionID) -> Bool {
        lanes[session]?.state == .errored
    }

    /// The next thing the RUNTIME should put on the wire, if anything. The
    /// reducer emits no sends; it answers this question and the runtime acts.
    ///
    /// Escape and a dialog key are exceptions to idleness. Escape exists to
    /// interrupt work in flight. A dialog key answers a terminal prompt that is
    /// BLOCKING the turn, so its session reads not-idle by construction (`isIdle`
    /// needs a `Stop` newer than the last prompt, and the tool call the dialog
    /// holds open has not produced one).
    ///
    /// A dialog key is exempt only while its dialog still is. Scenario: an
    /// automatic Continue queued at the usage limit heads the queue, a digit
    /// queues behind it, the human answers the dialog in the terminal, the window
    /// reopens, the Continue drains, and the digit is left with nothing to
    /// answer. `isReadyAnswerKey` is the guard: a `.dialogKey` is a candidate
    /// only while `lane.state == .needsYou` AND `lane.waitingFor` still carries a
    /// value. A stale key is dropped from the queue by
    /// `Reducer.cullStaleDialogKeys`.
    ///
    /// Scanned, not just the head. A dialog key queued behind a gated prompt
    /// (mid-turn, or at the usage limit) would starve under a head-only check:
    /// the prompt waits for idle, idle waits for the dialog, and the dialog waits
    /// for the key. So every unsent item is scanned in order for the first ready
    /// answer key before the head's own gates are consulted. An answer overtakes
    /// the prompts ahead of it without discarding them; everything else waits its
    /// turn.
    public func nextSend(at now: Instant) -> (session: SessionID, action: QuickAction)? {
        // The account is out of budget: a prompt sent now is refused by the engine,
        // and the deck has a deadline it can wait for. So it WAITS: the tap is
        // accepted, the action stays queued, and it goes when the window opens.
        //
        // An INTERRUPT and a DIALOG KEY are exempt, like the idle gate below:
        // neither spends budget. Escape stops running work; a dialog key is a
        // keystroke into a terminal UI answering a prompt already shown. A slash
        // command is NOT exempt: `/compact` costs tokens, so at the limit it fails
        // like any prompt.
        let limited = bindingUsageWindow(at: now) != nil
        for (session, queue) in pending.sorted(by: { $0.key.raw < $1.key.raw }) {
            let unsent = queue.filter { $0.sentAt == nil }
            guard let head = unsent.first else { continue }

            // The gate scan (see the doc comment above): an answer key anywhere in this
            // session's queue overtakes whatever is ahead of it, so a gated prompt at
            // the head can never wedge one behind it.
            if let answer = unsent.first(where: { isReadyAnswerKey($0, session: session) }) {
                return (session, answer.action)
            }

            // Nothing in the queue answered the scan, so a `.dialogKey` at the head is
            // stale (its dialog closed) and MUST NOT fall into the prompt gates: the
            // idle check would never pass for a key answering a still-open dialog,
            // wedging it at the head forever instead of letting the sweep remove it.
            // `.escape` never reaches here; it always satisfies the scan.
            guard case .prompt = head.action.kind else { continue }
            if limited { continue }
            if isIdle(session) || turnDied(session) { return (session, head.action) }
        }
        return nil
    }

    /// Is this queued action sendable RIGHT NOW as an answer key — exempt
    /// from every gate `nextSend` applies to an ordinary prompt? Escape
    /// always is. A dialog key is, only while `hasOpenDialog` says the
    /// session's dialog is still the deck's own evidence-backed belief.
    private func isReadyAnswerKey(_ queued: QueuedAction, session: SessionID) -> Bool {
        switch queued.action.kind {
        case .escape: return true
        case .dialogKey: return hasOpenDialog(session)
        case .prompt: return false
        }
    }

    /// Does the deck still believe THIS session has a dialog open for a
    /// `.dialogKey` to answer? Requires `state == .needsYou` (a human is still
    /// wanted) AND `waitingFor` still carrying a value (the fleet still
    /// corroborates a dialog on screen): a roster that stops naming the session's
    /// row leaves `waitingFor` standing on an otherwise unmoved lane, and a key
    /// sent into a dialog nothing confirms answers an unverified screen.
    ///
    /// One predicate, two readers: `nextSend`'s gate scan uses it to decide what
    /// to OFFER, `Reducer.cullStaleDialogKeys` to decide what to DROP. Internal
    /// rather than private because the reducer is a separate type in this
    /// module; a second copy of the conjunction could disagree.
    func hasOpenDialog(_ session: SessionID) -> Bool {
        lanes[session]?.state == .needsYou && lanes[session]?.waitingFor.value != nil
    }

    /// Is this session's queue waiting for the account's usage window rather than
    /// for the session itself? A different fact from stalled, and the surface says
    /// so differently: this one has a deadline the deck can name.
    public func awaitsUsageWindow(_ session: SessionID, at now: Instant) -> Bool {
        guard bindingUsageWindow(at: now) != nil,
              let queue = pending[session] else { return false }
        return queue.contains { $0.sentAt == nil && $0.action.payload != nil }
    }

    /// Queues that have waited without the session moving. Surfaced, never
    /// silently dropped and never sent anyway — the deck says "waiting on the
    /// session" and the person decides.
    public func stalledQueues(at now: Instant) -> [SessionID] {
        pending.compactMap { session, queue in
            guard let oldest = queue.first(where: { $0.sentAt == nil }) else { return nil }
            // A queue held by the USAGE window is not stalled: that wait has a
            // published deadline, and labelling it a problem would report a fault where
            // the deck is correctly patient.
            guard bindingUsageWindow(at: now) == nil else { return nil }
            guard !isIdle(session) else { return nil }
            let waited = now.sinceStart - oldest.queuedAt.sinceStart
            return waited >= Self.stallGrace ? session : nil
        }.sorted { $0.raw < $1.raw }
    }

    public var needsYouCount: Int {
        lanes.values.filter { $0.state == .needsYou }.count
    }
}

public enum DeckEvent: Equatable, Sendable {
    case hook(HookEvent)
    case statusline(StatuslinePayload, at: Instant, id: EventID)
    case fleet([FleetRow], at: Instant, id: EventID)
    /// A human tapped something. Carries the hold it was aimed at, which is
    /// what makes the correlation rule checkable: the decision names its
    /// target rather than referring to "the current takeover".
    case decision(HoldID, Resolution, at: Instant)
    /// The hold budget ran out. Which outcome that produces is the
    /// release-is-not-deny rule's job, not the timer's.
    case holdExpired(HoldID, at: Instant)
    /// Another request is promoted to the front. This releases nothing.
    case promote(HoldID, at: Instant)
    /// A question call arrived.
    case questionOpened(QuestionCall, at: Instant)
    /// The user submitted. Partial submissions are refused here rather than
    /// prevented by a view that might one day be rewritten.
    case questionSubmitted(HoldID, answers: [Answer], at: Instant)
    /// An option row was tapped. On a single-select question this also commits
    /// it — one tap, one answer — which is why the view emits one event for
    /// both and the reducer decides what a tap means. A view that decided would
    /// be a view holding the question's `multiSelect` flag as behaviour.
    case questionPicked(HoldID, label: Redacted, at: Instant)
    /// The user typed an answer instead of tapping an offered option (the
    /// terminal's own "Other…" escape, mirrored). `step` is the question the text
    /// was typed against, read off the VIEW's copy when the field was opened;
    /// `DeckRuntime.answerFreely` takes it as a parameter because reading it
    /// fresh off live state would compare the reducer's guard to itself. `text`
    /// is `Redacted` and refused-if-blank by construction (`Redacted(optional:)`,
    /// in `answerFreely`), so the reducer never checks for empty text. A mismatch
    /// with the live `progress.step` (a stale submit racing a step change) is
    /// refused. Deliberately bypasses `questionPicked`'s offered-label guard; see
    /// the reducer case.
    case questionAnsweredFreely(HoldID, step: Int, text: Redacted, at: Instant)
    /// The user finished a multi-select question. Commits the current picks and
    /// advances, or submits everything if that was the last question.
    case questionCommitted(HoldID, at: Instant)
    /// The user stepped the question takeover back one question (the back
    /// button). Free, total, silent: no effect is emitted, nothing reaches the
    /// wire, and the popped answer returns as the live selection.
    case questionSteppedBack(HoldID, at: Instant)
    /// The mast counter's tap: bring the next-oldest waiter forward. The cyclic
    /// choice is the reducer's; the view reports a gesture, never a computation.
    case promoteNext(at: Instant)

    // ------------------------------------------------- quick actions
    /// A lane was selected, or selection was cleared. Display only.
    case sessionSelected(SessionID?, at: Instant)
    /// A person tapped an action. It joins that session's queue; an escape
    /// jumps the queue and empties it, because an interrupt held behind two
    /// pending prompts would be absurd and a queue that survived one would
    /// resume the work the person just stopped.
    case actionQueued(SessionID, QuickAction, at: Instant)
    /// A person tapped an action that is already waiting. **Cancels it**, the
    /// inverse of the tap that armed it. Without it the only way to stop a
    /// mis-tapped Continue was an interrupt, which is worse than the mistake; and
    /// during an hours-long usage hold a queue accepting duplicates would fire
    /// every impatient tap when the window opens.
    case actionCancelled(SessionID, actionID: String, at: Instant)
    /// Everything not yet on the wire, discarded. What has already been sent is
    /// kept: it cannot be recalled, and forgetting it would stop the deck matching
    /// the receipt that proves it landed.
    case queueCleared(SessionID, at: Instant)
    /// The RUNTIME reports what it put on the wire. **The reducer never emits a
    /// send**: a send effect produced by a wire event would make the output
    /// depend on arrival order, and `ReplayTests` compares whole states across
    /// every permutation. So the runtime reads the frame, decides, acts, and
    /// tells the core what it did (same shape as `frontChangedAt`).
    case actionSent(SessionID, actionID: String, at: Instant)
    /// The runtime reports that sending is blocked, or is no longer blocked —
    /// the same direction of travel as `actionSent`, for the same reason. A
    /// **nil session** means the host itself is refusing and no session can be
    /// sent to; a **nil block** clears, which is what a probe finding the host
    /// reachable again has to be able to say.
    ///
    /// The darkened-control rule lives on this event: a control the deck has
    /// darkened must carry the reason it darkened, and a reason that cannot
    /// reach the reducer is a reason the frame cannot show.
    case actionBlocked(SessionID?, ActionBlock?, at: Instant)
    /// Esc / ⌘[ — one binding, precedence decided here rather than in a view
    /// that cannot know what is open.
    case dismissRequested(at: Instant)
    /// Delete asked for, then confirmed or abandoned. Three events because the
    /// confirmation IS the feature: a delete reachable in a single tap would be
    /// an ALLOW with worse consequences.
    case deleteRequested(SessionID, at: Instant)
    case deleteConfirmed(SessionID, at: Instant)
    case deleteAbandoned(at: Instant)
    /// A port answered "what branch is this session's `cwd` on?". Branch is
    /// **derived** (reading `.git/HEAD` is filesystem I/O, which `DeckCore` may
    /// not do), so the answer arrives as an event with a timestamp and id, and
    /// `nil` is a real answer meaning *not a worktree* rather than *not asked
    /// yet*.
    case worktree(SessionID, branch: String?, at: Instant, id: EventID)
    /// The transcript-well band's backfill. A file adapter (`DeckApp`; this
    /// package does no filesystem I/O) read the tail of a session's transcript,
    /// ran it through `TranscriptTail` (human prompts only, oldest-first, capped
    /// at `LaneRecord.historyCap`), and reports once, the way `.actionSent`
    /// reports a send; the core only places the entries. `at` is the runtime's
    /// arrival instant for THIS event and is NOT used to place the seeded
    /// entries: `Reducer.apply(_:for:.transcriptSeeded)` uses a synthetic
    /// "backfill era" that sorts before every real instant.
    case transcriptSeeded(SessionID, texts: [Redacted], at: Instant)
    /// The session's own transcript, learned to be recording an API error as its
    /// last word (recency rule: `TranscriptTail.apiErrorLastWord(fromJSONL:)`).
    /// No hook fires at the abort moment (see `DeckRuntime`'s trigger-set doc),
    /// so the deck goes LOOKING on the hook arrivals it already receives.
    /// `at`/`id` are the TRIGGERING hook's `(at, id)`, restamped: the peek
    /// establishes "as of that hook's moment, the session's last word was an API
    /// error". That lets `dominates` resolve every race: a later hook (a retry)
    /// already holding a NEWER `(at, id)` beats a slow peek.
    ///
    /// A peek carries its trigger hook's OWN `(at, id)`: a tie against the anchor
    /// that same hook's synchronous transition planted, and a tie is not always a
    /// loss (full rule in `reduceCore`'s `.apiError` handler). A hook whose
    /// verdict was `.idle` (`SessionStart`, `Stop`, an `idle_prompt`
    /// `Notification`) said so out of silence, and the transcript's last word is
    /// the missing WHY, so this is the one tie the peek wins. Every other tie
    /// loses: `.working` (`UserPromptSubmit`) is a hard new fact and a peek
    /// racing it is the flush-lag case (a stale file read must never overturn a
    /// retry); `.ended`/`.needsYou` stand for the same reason.
    case apiError(SessionID, text: Redacted, at: Instant, id: EventID)
    /// Arm or disarm every named pane in one act (the Settings bulk buttons), as
    /// a state transition rather than a preferences write: disarming must cancel
    /// the held-open offers in `awaitingAutoContinue`, which is reducer state the
    /// runtime cannot reach. Inferring intent from the resulting preferences
    /// ("nothing is armed, so the user pressed Turn Off for All") is wrong both
    /// ways: any unrelated preference write would wipe every held offer while
    /// nothing happened to be armed, and a genuine bulk OFF that left an entry
    /// for a non-running pane would not cancel them.
    ///
    /// `surfaces` is supplied by the caller because only the runtime knows which
    /// panes it can address and offer Continue to.
    ///
    /// The two directions are asymmetric in three places. ON arms only the
    /// surfaces it was handed (writing a promise `Reducer.arm` will skip would be
    /// a lie in the file) but clears EVERY refusal, since removing one adds no
    /// promise and a refusal on an unaddressable pane is otherwise unclearable.
    /// OFF clears every armed pane, running or not (the only reading that reaches
    /// what the standing default armed in a tab since gone quiet), cancels offers
    /// held for unplaced sessions, and leaves refusals alone, because a button
    /// labelled Turn Off must never arm a tab.
    case autoContinueSetForAll(on: Bool, surfaces: [String], at: Instant, id: EventID)
    /// A recap the session wrote about itself, found by the same peek and off
    /// the same bytes as an API error (measured shape:
    /// `TranscriptTail.latestRecap(fromJSONL:)`).
    ///
    /// `at` is the RECAP's own moment, the opposite of `.apiError`. An API error
    /// is a claim about NOW (hence restamped with the trigger's `(at, id)` so
    /// `dominates` can resolve races); a recap is a claim about THEN, which
    /// nothing later contradicts: a newer recap simply joins an older one in the
    /// chronological ledger. So the case writes no lane state, only a transcript
    /// row, and cannot lose a race because it enters none.
    ///
    /// `id` is SYNTHESIZED from the recap's ISO timestamp
    /// (`EventID("recap:<session>@<iso>")`, at the one call site), like
    /// `TranscriptEntry.source` for a `.deck` row: the same recap re-found on a
    /// later peek must produce the same id, or a ledger keyed on `source.raw`
    /// would render it twice.
    case recap(SessionID, text: Redacted, at: Instant, id: EventID)
    /// Where a discovered session lives, resolved from its pid by the host. A
    /// fleet row can open a lane but cannot address it; this turns a lane the
    /// deck can watch into one it can speak to.
    case located(SessionID, host: HostAddress, at: Instant, id: EventID)
    /// The user walked away. The all-or-nothing rule's other branch: none is a valid outcome.
    case questionAbandoned(HoldID, at: Instant)
    /// V2 forwarding's three events: the send-plan state machine. `DeckRuntime`
    /// steps a plan and reports back; it never decides what happens next. A tap
    /// on a `.terminalLive` mirror builds a `ForwardPlan`
    /// (`ForwardPlanBuilder.build`, pure) and starts it.
    case forwardPlanStarted(ForwardPlan, at: Instant)
    /// One step actually reached the wire — advances the plan's own
    /// cursor. The runtime reports this AFTER a real send, never before:
    /// the reducer's own copy of "how far along" must never claim a step
    /// happened that a host failure or a mid-plan cancellation caught
    /// first.
    case forwardStepSent(HoldID, at: Instant)
    /// Aborted before every step ran — `PostToolUse` landing mid-plan (the
    /// `cullStaleDialogKeys` class, extended: the SAME "the thing this was
    /// aimed at no longer exists" fact, one surface over), or the runtime
    /// itself giving up (`ActionBlock`, the host gone). Silent for a plan
    /// that already finished — cancelling nothing is not an error.
    case forwardPlanCancelled(HoldID, at: Instant)
    /// The readiness gate's two timer-driven signals (derivation:
    /// `HoldPolicy.permissionRequestAllowance`/`.noSignalAllowance`). Fired by
    /// `DeckRuntime.scheduleReadinessWatch()`'s clock, never derived here, as
    /// with `.holdExpired` and `Hold.budget`. A no-op once the mirror has left
    /// `.released` by any OTHER door first (ceremony pair completing, a
    /// resolution, `.mirrorObservedLive`), so whichever proof arrives first
    /// counts.
    case mirrorReadinessElapsed(HoldID, at: Instant)
    /// The readiness gate's strongest signal: `DeckRuntime` read the terminal
    /// screen (`SessionHostPort.read`, the same call `drain()`'s composer check
    /// uses) and saw the question's text directly. Evidence over inference; same
    /// promotion and once-only guard as `.mirrorReadinessElapsed`.
    case mirrorObservedLive(HoldID, at: Instant)
    /// What makes the two promotions above safe to be aggressive about
    /// (reasoning: `HoldPolicy.forwardLandingAllowance`). A no-op once the mirror
    /// has resolved: the watchdog and an on-time `PostToolUse` race the same
    /// clock, and a `PostToolUse` that wins needs no notice.
    ///
    /// Named `forwardUnconfirmed`, not `forwardDidNotLand`: the deck can confirm
    /// a landing (`PostToolUse`) but never the ABSENCE of one; the allowance
    /// elapsing proves only that no confirmation arrived IN TIME. (Live incident:
    /// option 2 had landed, the deck kept it answerable, and a second tap sent
    /// "2" again.) This event does not re-arm the mirror by itself; see
    /// `MirrorView.awaitingConfirmation`/`.forwardRearmed`: the mirror stays
    /// non-interactive until the person explicitly asks to send again.
    case forwardUnconfirmed(HoldID, at: Instant)
    /// The deliberate re-arm. The awaiting-confirmation window
    /// (`MirrorView.awaitingConfirmation`) and the unconfirmed state both leave a
    /// `.terminalLive` mirror's OPTIONS disabled, closing the double-send window
    /// (the same digit sent twice). This is the one door back to tappable: an
    /// explicit "Send again", never an automatic re-arm and never a replay of the
    /// original plan. The person re-taps an option deliberately (which also
    /// covers a changed mind), as an ordinary NEW `.forwardPlanStarted`.
    case forwardRearmed(HoldID, at: Instant)
    /// A finger went down and came up. The sustained-gesture rule decides
    /// whether that was long enough to mean anything.
    case gesture(tool: String, down: Instant, up: Instant, origin: WriteOrigin)
    /// The user revoked a rule from the list. The revocable-rules rule's other half.
    case revokeRule(String)
    /// The user changed a preference — theme, alpha, motion — or the prefs
    /// adapter loaded them at launch. One event for the whole value: the
    /// settings window owns no state the core doesn't, so
    /// every control writes the whole `DeckPrefs` through here.
    case prefsChanged(DeckPrefs, at: Instant)
    /// The deck came back. It recovers what it can **from feeds**,
    /// never from cache, and held hooks fail closed to the terminal.
    case restart(at: Instant)
    /// Someone asked for a config change. Carries where the ask came from,
    /// which is the whole of the strip-never-writes rule.
    case configRequested(WriteOrigin, ConfigDiff)
    /// The human read the preview and said yes.
    case configConfirmed(ConfigDiff)
}

public enum Reducer {

    /// The transcript-well backfill's dedicated instant range (reasoning:
    /// `DeckEvent.transcriptSeeded` and `case .transcriptSeeded` below). Strictly
    /// negative, so it sorts before EVERY real `Instant` (`Instant.start` is
    /// `Millis(0)`); one day of milliseconds below zero is not a tuned number,
    /// any negative value works.
    private static let backfillEraBase: Int64 = -86_400_000

    @discardableResult
    public static func reduce(_ state: inout DeckState, _ event: DeckEvent) -> [Effect] {
        // The front re-arm stamp is a before/after comparison around every **user
        // or timer** reduce. Only X → Y with both non-nil stamps: nil → X is a
        // takeover opening (covered by its own `armedAt`); X → nil is it closing.
        // Internal recursion (pick → commit → submit) stamps the same instant
        // twice, which is the same stamp.
        //
        // Wire events never stamp. A replayed permutation must land on one state,
        // and "did the front pass through X on the way" is an arrival-order fact.
        // And live, a wire event cannot move the front between two open holds: the
        // runtime stamps every arrival with `now()` (`DeckRuntime.handle`), so a
        // newly arriving hold is always the LATEST waiter. A late arrival with an
        // earlier openedAt exists only in replay, where no finger is present.
        let frontBefore = state.displayedFront
        let effects = reduceCore(&state, event)
        arm(&state, at: Replay.timestamp(of: event))
        cullStaleDialogKeys(&state)
        if !isWire(event), let before = frontBefore,
           let after = state.displayedFront, before != after {
            state.frontChangedAt = Replay.timestamp(of: event)
        }
        return effects
    }

    /// Drop every unsent `.dialogKey` whose dialog the deck no longer believes is
    /// open (`!hasOpenDialog(session)`, the predicate `nextSend`'s gate scan uses
    /// to decide what to offer). Left in place, a queue view would keep showing a
    /// button for an answered dialog forever: a `.dialogKey` has no receipt, so
    /// it cannot confirm itself away like a prompt.
    ///
    /// Run after EVERY event, at the same choke point as `arm`: `hasOpenDialog`
    /// can go false from four writers (`acknowledge`, the hook `transition` table
    /// in `apply(_:HookEvent)`, the fleet apply's `lane.state` write, and,
    /// separately, its unconditional `waitingFor` clear on any poll whose roster
    /// still names the session). A sweep inside any one would miss the other
    /// three. A post-reduce sweep keyed to the CURRENT state is the one choke
    /// point every path flows through.
    ///
    /// Sent items are untouched: they are receipts, not offers
    /// (`QueuedAction.status`), and culling one would erase a send already made.
    private static func cullStaleDialogKeys(_ state: inout DeckState) {
        for session in state.pending.keys.sorted(by: { $0.raw < $1.raw }) {
            guard let queue = state.pending[session] else { continue }
            if state.hasOpenDialog(session) { continue }
            let kept = queue.filter { entry in
                guard entry.sentAt == nil, case .dialogKey = entry.action.kind else { return true }
                return false
            }
            if kept.count != queue.count {
                state.pending[session] = kept.isEmpty ? nil : kept
            }
        }
    }

    /// Arm, or disarm, the sessions that continue themselves.
    ///
    /// Run after EVERY event rather than the ones that look relevant: the arming
    /// condition is a conjunction of three independently fed facts (account
    /// window from the statusline, session turn from hooks, surface preference
    /// from prefs), any of which can arrive last. Looking only on usage changes
    /// would miss the LV19 case, a prompt submitted while the account was
    /// already at its limit.
    ///
    /// The queue it writes into is the ordinary one, so an automatic continue
    /// obeys every refusal a tapped one does: the idle gate, the composer read
    /// that will not type over a draft, the inventory check, and the usage gate
    /// that holds it until the window reopens. It stays visible and cancellable
    /// while it waits.
    private static func arm(_ state: inout DeckState, at now: Instant) {
        let window = state.bindingUsageWindow(at: now)
        for session in state.lanes.keys.sorted(by: { $0.raw < $1.raw }) {
            // A `Stop` means the turn finished after all, so an automatic continue not
            // yet sent is one nobody needs. Only UNSENT ones: once on the wire the
            // session produces its own `Stop`, and cancelling on that would retract
            // something already done.
            if state.isIdle(session), let queue = state.pending[session] {
                let kept = queue.filter { !($0.isAutomatic && $0.sentAt == nil) }
                state.pending[session] = kept.isEmpty ? nil : kept
            }
            // The episode is over (a different window, or none): forget it so the next
            // is a fresh decision.
            if let latched = state.autoLatch[session], latched != window?.resetsAt {
                state.autoLatch[session] = nil
            }
            guard let window, state.shouldArmAutoContinue(session, at: now) else { continue }
            // The latch is set BEFORE the queue write and makes this idempotent:
            // `shouldArmAutoContinue` refuses a session already latched to this
            // deadline, so a repeated feed cannot stack a second Continue.
            state.autoLatch[session] = window.resetsAt
            // THIS session's own offered set, not the global one. A Continue scoped to
            // a folder that does not name this session's `cwd` must not arm here (a
            // Continue dragged past position ten disarms auto-continue, see
            // `QuickActionTests.continuePastTheCapDisarmsAutoContinue`);
            // `Frame.swift`'s `autoContinuable` reads the same per-session set so the
            // checkbox and the arming decision agree. `cwd?.value.value` is the raw
            // `String?` under `Sourced<Redacted>?`, read in-process and never encoded
            // (see `Redacted.swift`).
            guard let action = QuickAction.offerable(
                state.prefs.quickActions, in: state.lanes[session]?.cwd?.value.value
            ).first(where: { $0.id == QuickAction.continueID }) else { continue }
            state.pending[session] = (state.pending[session] ?? [])
                + [QueuedAction(action: action, queuedAt: now, isAutomatic: true)]
        }
    }

    /// The feeds — events whose ordering the wire does not promise (SG5), and
    /// whose replay must therefore be order-independent. Everything
    /// else on the inbox is a user's gesture or the deck's own timer, where
    /// order IS the history.
    private static func isWire(_ event: DeckEvent) -> Bool {
        switch event {
        case .hook, .statusline, .fleet, .worktree: return true
        default: return false
        }
    }

    /// The manual order follows a pane through a RE-SPELLING of its own address.
    ///
    /// `DeckPrefs.cardOrder` keys on `host.surface`, but the host reports one
    /// pane under two names, and `LaneRecord.host` is re-fed by every payload, so
    /// the name a lane holds depends on which feeder spoke last:
    ///   - the HOOK reports the pair from `CMUX_SURFACE_ID` /
    ///     `CMUX_WORKSPACE_ID`, which cmux exports as UUIDs;
    ///   - `DeckRuntime.locate` resolves a pid through `cmux tree`, which answers
    ///     in short refs (`surface:27`).
    /// Comparing them with `==` matches nothing (`HostSession.identifies(_:)`
    /// exists for that; see `PanelDrainTests.theHookAddressResolvesToTheHostsOwn`).
    ///
    /// So a lane discovered by the fleet poll is stored as `surface:27`, the user
    /// arranges the fleet, and the lane's first hook re-feeds the UUID:
    /// `Projection.manualOrder`'s `rank` no longer names it and the arrangement
    /// comes apart one card at a time (symptom: a `cardOrder` holding both
    /// shapes).
    ///
    /// Renaming IN PLACE is the repair, and belongs here rather than at either
    /// reader: the pane did not move, only the host's word for it did.
    /// Deliberately NOT solved by making `host` sticky: a lane whose session
    /// genuinely moves panes must still be able to say so.
    ///
    /// Total under any input: no old name, no new name, or an unchanged name does
    /// nothing; a rename onto a spelling the list ALREADY carries keeps the
    /// renamed entry's earlier position and drops the duplicate, preserving
    /// `DeckPrefs.decode`'s invariant that `cardOrder` never names one surface
    /// twice. Called AFTER the lane has been written back, so `state.lanes`
    /// already carries the new spelling and "does anyone still answer to the old
    /// name" means OTHER lanes only.
    ///
    /// Renames across EVERY surface-keyed preference, not just the order:
    /// `autoContinue`, `hidden` and `legacyCardColors` use the same key and would
    /// otherwise silently lose entries (a re-spelled session quietly stops being
    /// armed, which nothing reports until the usage limit arrives).
    static func followSurfaceRename(_ state: inout DeckState, from old: String?, to new: String?) {
        guard let old, let new, old != new else { return }

        // Nothing to carry, nothing to compute. Checked FIRST with set lookups
        // only: most renames concern a pane nobody has a preference about, and the
        // shared-pane scan below is linear in the fleet.
        let dependsOnOld = state.prefs.autoContinue.contains(old)
            || state.prefs.autoContinueRefused.contains(old)
            || state.prefs.hidden.contains(old)
            || state.prefs.legacyCardColors[old] != nil
        guard dependsOnOld || state.prefs.cardOrder.contains(old) else { return }

        // Two sessions CAN share one pane (`Projection.manualOrder`'s rule 1: a
        // relaunch mid-frame, `/exit` and a fresh session in the same tab) and only
        // one may have been re-spelled. While another lane still answers to the old
        // name the old entry must STAY. An ENDED session does not hold a spelling
        // open: `state.lanes` keeps a lane for the life of the process (removed only
        // by a user tombstone or `.restart`), so an `/exit`ed session's surface would
        // otherwise read as live forever and every re-spelling would leave a stale
        // duplicate in three persisted sets (the cmux short-ref reuse hazard).
        let shared = state.lanes.values.contains(where: Self.holdsSurface(old))

        // Sets: the new name joins; the old one leaves unless still somebody's.
        // Idempotent.
        func rename(_ set: inout Set<String>) {
            guard set.contains(old) else { return }
            set.insert(new)
            if !shared { set.remove(old) }
        }
        rename(&state.prefs.autoContinue)
        rename(&state.prefs.autoContinueRefused)
        rename(&state.prefs.hidden)

        // A dictionary, same rule, carrying its value across.
        if let colour = state.prefs.legacyCardColors[old] {
            state.prefs.legacyCardColors[new] = colour
            if !shared { state.prefs.legacyCardColors[old] = nil }
        }

        // The ORDER is positional, so it renames in place: the card keeps the slot
        // the user dragged it to. When the old name is still live the new one is
        // INSERTED beside it, so both rank adjacently and neither lane is stranded
        // at the untouched tail.
        if let index = state.prefs.cardOrder.firstIndex(of: old) {
            var order = state.prefs.cardOrder
            if shared { order.insert(new, at: index) } else { order[index] = new }
            var seen = Set<String>()
            state.prefs.cardOrder = order.filter { seen.insert($0).inserted }
        }
    }

    /// Whether a lane is still holding a surface spelling open, in the only
    /// sense `followSurfaceRename` cares about. An ENDED session does not:
    /// `state.lanes` keeps a lane for the life of the process (removed only by a
    /// user tombstone or `.restart`), so an `/exit`ed session's surface would
    /// read as live forever and each `/exit` plus fresh session in the same tab
    /// would write a second spelling into three persisted preferences that
    /// nothing can remove. Avoiding the duplicate here is why no retirement sweep
    /// exists.
    static func holdsSurface(_ surface: String) -> (LaneRecord) -> Bool {
        { $0.state != .ended && $0.host?.value.surface == surface }
    }

    /// How long a held offer stays good.
    ///
    /// An offer exists because a session STARTED before the deck could work out
    /// which pane it was in; placement normally follows within a fleet poll. Five
    /// minutes is far past that and far short of "forever" (otherwise the footer
    /// claims sessions are "still being placed" long after they ended, and "Turn
    /// Off for All Sessions" could never settle to disabled).
    ///
    /// Expiry by DEADLINE rather than by watching for the session to end, which
    /// is load-bearing: dropping the offer on the `.sessionEnd` hook made two
    /// orderings of the same events land differently (place the lane before the
    /// end and the pane is armed for good, after and it never is), and the relay
    /// and the fleet poll race to decide. A deadline compares the events' own
    /// timestamps, so every permutation gets the same answer.
    public static let autoContinueOfferBudget = Millis(5 * 60 * 1000)

    /// Arm a pane when a session actually STARTS in it, if the standing default
    /// says to and the user has not decided that pane themselves.
    ///
    /// The trigger is a `SessionStart` hook, which makes the other cases come out
    /// right:
    ///   - Not retroactive: sessions already on the deck never fire another
    ///     `SessionStart`, so they are not armed (leaving
    ///     `setAutoContinueForAllSessions(_:)` a job of its own).
    ///   - Survives a relaunch: a restarted deck re-discovers sessions through
    ///     `.located` and ordinary hooks, never a fresh `SessionStart`, so it does
    ///     not arm everything it finds.
    ///   - Covers the common case: `/exit` and a new session in the same tab DOES
    ///     fire `SessionStart`, so it is armed.
    ///
    /// A fleet-discovered session gets no `SessionStart` and is never armed by
    /// the default: it was running before the deck knew it, which is not what
    /// "new session" means to the person reading the label.
    ///
    /// Deliberately does NOT record the pane in `autoContinueRefused`: that set
    /// is the USER's opinions, and a pane the deck armed itself must stay
    /// eligible for the next session in it.
    static func seedAutoContinue(_ state: inout DeckState, session: SessionID, surface: String?,
                                 at: Instant) {
        // Cleared FIRST, before the flag is consulted: the offer is spent or
        // discarded on every visit, never left lying. Otherwise: start a session the
        // deck cannot place (offer held), turn the default OFF, locate the session
        // (nothing armed, offer still held), turn the default back on hours later,
        // and the next hook from that old session arms it, which is the retroactive
        // arming this design forbids.
        state.awaitingAutoContinue[session] = nil
        guard state.prefs.autoContinueByDefault else { return }
        guard let surface, !surface.isEmpty else {
            // Not addressable yet. Hold the offer open rather than spending it on
            // nothing (see `awaitingAutoContinue`).
            state.awaitingAutoContinue[session] = at
            return
        }
        guard !state.prefs.autoContinueRefused.contains(surface) else { return }
        state.prefs.autoContinue.insert(surface)
    }

    /// Redeem a held-open offer once the deck can finally address the
    /// session — called from every host feeder, since either of them may be
    /// the one that places it.
    static func redeemAwaitedAutoContinue(_ state: inout DeckState, session: SessionID,
                                          at: Instant) {
        guard let offered = state.awaitingAutoContinue[session] else { return }
        let expired = at.sinceStart.raw - offered.sinceStart.raw > autoContinueOfferBudget.raw
        // An expired but unplaceable offer is LEFT ALONE, deliberately. Reaping it
        // here would cost the order-freedom the deadline exists to provide: destroy
        // the entry on an event stamped past the budget and a `.located` stamped
        // INSIDE it, applied afterwards, finds nothing to redeem, while the other
        // order arms the pane. Production stamps every feeder at arrival so the
        // orders cannot diverge today, but a future feeder stamping from a payload
        // clock would break it silently.
        //
        // Known leak: this function is called from two sites, and the second fires
        // on every non-`SessionStart` hook, so a session the deck can never place
        // (tmux, VS Code's terminal, `OAD_NO_FLEET_DISCOVERY=1`) keeps emitting
        // hooks. Its one `SessionID: Instant` entry persists until a tombstone, the
        // default being switched off, or a restart.
        // `setAutoContinueForAllSessions(false)` counts only LIVE offers and its
        // button is disabled on the same count, so expired entries cannot be cleared
        // that way. The entry is invisible (both read-time consumers filter on the
        // deadline) and a few dozen bytes; that is the accepted trade.
        guard let surface = state.lanes[session]?.host?.value.surface, !surface.isEmpty else {
            // Still not placeable, and the offer keeps its ORIGINAL instant. Re-holding
            // it via `seedAutoContinue` would stamp the CURRENT event, so every ordinary
            // hook would push the deadline out and the offer would never expire while a
            // session kept talking; it would also reintroduce order dependence (an end
            // hook arriving first would refresh the stamp).
            return
        }
        // Placeable, so the offer is spent either way; an expired one must not
        // claim a session is still being placed.
        state.awaitingAutoContinue[session] = nil
        // Measured from when the offer was MADE to when the deck could act on it.
        // Both are event timestamps, so arrival order cannot change the answer.
        guard !expired else { return }
        guard state.prefs.autoContinueByDefault,
              !state.prefs.autoContinueRefused.contains(surface) else { return }
        state.prefs.autoContinue.insert(surface)
    }
    /// Records this session's card colour the instant its DIRECTORY resolves.
    /// The ONE place `state.prefs` mutates outside an explicit user action,
    /// deliberately.
    ///
    /// The colour is a fact about the PROJECT, not the tab: two cards of one
    /// colour mean "same project". The directory (`cwd`) survives `/exit`, a
    /// relaunch, and two tabs on one working tree. "Assigned automatically on
    /// boot; never reassigned on restart" is a stability promise, so the
    /// assignment is written down the moment it is made; a colour computed fresh
    /// on every projection would change when a neighbouring project closed and
    /// freed its slot.
    ///
    /// Migration and adoption: every surface-keyed entry a person earned under
    /// the old scheme (`legacyCardColors`) gets a chance to survive. Whichever
    /// lane's SURFACE matches a legacy entry drains it from `legacyCardColors`
    /// the moment this runs for that lane, REGARDLESS of whether the directory is
    /// already coloured, so a second session of an adopted directory cannot
    /// strand its legacy entry. What the drained colour is GRANTED depends on
    /// spread: `.custom` adopts outright (a person's own pick); a `.slot` adopts
    /// only when its hue sits at least `CardColor.minimumAssignedHueSeparation`
    /// from every OTHER recorded directory's hue, so migration cannot create a
    /// near-collision (exact match is the distance-0 case). A legacy colour that
    /// cannot adopt is discarded and the directory falls through to the ordinary
    /// `assign` path.
    ///
    /// Called from every funnel that can be the FIRST to learn a lane's `cwd`
    /// (hooks `apply(_:HookEvent)`, fleet rows `apply(_:[FleetRow])`, and
    /// `.located`, where the directory guard simply declines), since which wins
    /// depends on whether a hook or the fleet poll sees the lane first. Guarded
    /// on `directoryColors[dir] == nil`, so a re-fed `cwd` never overwrites an
    /// earned colour.
    private static func recordCardColorIfNeeded(_ state: inout DeckState, session: SessionID) {
        guard let dir = state.lanes[session]?.cwd?.value.value, !dir.isEmpty else { return }

        // Consume this lane's legacy surface entry REGARDLESS of whether the
        // directory is already coloured, so the migration map drains even for a
        // second session of an adopted directory.
        var legacy: CardColor? = nil
        if let surface = state.lanes[session]?.host?.value.surface {
            legacy = state.prefs.legacyCardColors.removeValue(forKey: surface)
        }

        guard state.prefs.directoryColors[dir] == nil else { return }

        if let legacy {
            // Adopt unless the slot reads as the same colour as one a RECORDED
            // directory already wears: adoption may not create the collision this
            // feature exists to close. Distance, not exact match (two different slots
            // can be indistinguishable; see `CardColor.minimumAssignedHueSeparation` for
            // the measured derivation). Exact match is the distance-0 case.
            //
            // `.custom` holds no NAMED slot and adopts UNCONDITIONALLY: a person's own
            // pick, carried forward by migration, is not the deck's call to second-guess
            // (same sovereignty as `CardColor.assign` gives a hand-picked colour).
            let wornHues: [Double] = state.prefs.directoryColors.values.map { color in
                switch color {
                case .slot(let s): return CardColor.paletteHue(s)
                case .custom(let r, let g, let b): return CardColor.rgbToHSB(red: r, green: g, blue: b).hue
                }
            }
            let adoptable: Bool = {
                guard case .slot(let s) = legacy else { return true }
                let legacyHue = CardColor.paletteHue(s)
                return wornHues.allSatisfy {
                    CardColor.hueDistance(legacyHue, $0) >= CardColor.minimumAssignedHueSeparation
                }
            }()
            if adoptable {
                state.prefs.directoryColors[dir] = legacy
                return
            }
        }

        let preferred = CardColor.fallbackSlot(for: dir)
        // No `live` fleet to compute: exhausting the named palette generates a fresh
        // colour (see `CardColor.assign`), so starvation is impossible and reuse is
        // forbidden, not merely deprioritised.
        state.prefs.directoryColors[dir] = CardColor.assign(existing: state.prefs.directoryColors,
                                                             preferred: preferred)
    }

    private static func reduceCore(_ state: inout DeckState, _ event: DeckEvent) -> [Effect] {
        switch event {
        case .hook(let h):                       return apply(&state, h)
        case .statusline(let p, let at, let id): apply(&state, p, at: at, id: id); return []
        case .fleet(let rows, let at, let id):   apply(&state, rows, at: at, id: id); return []

        case .decision(let id, let r, let at):
            guard var hold = state.holds[id] else { return [] }      // the correlation rule
            // The arm-delay rule extended: a decision inside the re-arm window of a
            // front change is a tap aimed at the takeover that was just replaced, and is
            // refused, as `armedAt` refuses one aimed before settle. Release and expire
            // are not touches and are exempt. The guard lives in the reducer because
            // `Hold` cannot see the front.
            if r != .release, r != .expire, let t = state.frontChangedAt,
               at.sinceStart - t.sinceStart < state.policy.reArmDelay { return [] }
            let effect = hold.resolve(r, at: at)
            state.holds[id] = hold
            // The acknowledgement IS the response write, and the only exit a decision
            // produces synchronously. Dominance-based exits are the asynchronous healing
            // path (a later PostToolUse, S12b measured 12 s; an `idle_prompt`
            // notification; an idle fleet row against a holdless needs-you lane).
            // (holdExpired's headless-deny branch also acknowledges to .errored, but is
            // unreachable in production since every hold is frontendOwned.)
            if effect != nil {
                acknowledge(&state, id, at: at)
                forgetQuestion(&state, id)
                // A deliberate `.release` decision (a "hand this to the terminal" tap) falls
                // through like a timeout does, mirror included. Every other outcome is the
                // deck itself deciding, which `.questionSubmitted` already resolves the
                // mirror for.
                if r == .release { releaseMirrorIfAny(&state, id, at: at) }
                sweepHolds(&state, at: at)
            }
            return [effect].compactMap { $0 }

        case .holdExpired(let id, let at):
            guard var hold = state.holds[id], hold.isOpen else { return [] }
            // Frontend-owned holds release and fall through to engine policy; headless
            // ones deny. Two outcomes, never one.
            let outcome: Resolution = hold.frontendOwned ? .release : .deny
            let effect = hold.resolve(outcome, at: at)
            state.holds[id] = hold
            if effect != nil {
                // An auto-deny is the deck refusing a tool on its own authority, and the
                // user should see it. It is the ONLY deck-side claim on a lane's colour,
                // which the fleet-owns-the-light-bar rule overrules for background sessions.
                //
                // A RELEASE IS NOT AN ANSWER, AND MAY NOT BE DRAWN AS ONE. Every hold is
                // `frontendOwned: true`, so expiry always releases, and the terminal owns the
                // call from then on: a human is still needed, somewhere the deck cannot
                // reach. Acknowledging the lane to `.working` would drop the card from the
                // loudest treatment to one of the quietest (and `mastNeedsYou` down) just
                // when the deck stops being able to help, concealing a session waiting for a
                // human. So a release leaves the lane where it is; it heals when the prompt
                // is answered in the terminal and the next PostToolUse moves the lane to
                // working.
                if outcome == .deny {
                    acknowledge(&state, id, at: at, as: .errored)
                }
                forgetQuestion(&state, id)
                // The realistic path into `.released` (`outcome` is always `.release` in
                // production since every hold is `frontendOwned`); checked anyway, like the
                // `.decision` case, rather than assumed from a fact about callers.
                if outcome == .release { releaseMirrorIfAny(&state, id, at: at) }
                sweepHolds(&state, at: at)
            }
            return [effect].compactMap { $0 }

        case .questionOpened(let call, let at):
            state.questions[call.hold] = call
            if state.holds[call.hold] == nil {
                // Unconditionally `questionBudget`, not the `h.tool ==` gate of the generic
                // `apply(_:HookEvent)` hold-open site: a `QuestionCall` is always about the
                // question tool.
                state.holds[call.hold] = Hold(id: call.hold, openedAt: at,
                                              budget: state.policy.questionBudget, frontendOwned: true,
                                              armDelay: state.policy.armDelay)
            }
            return []

        case .located(let session, let host, let at, let id):
            guard var lane = state.lanes[session] else { return [] }   // the no-synthesised-lane rule
            // `absorb`, so a hook's own report of the address (from the session's
            // environment, the more direct source) is never overwritten by an older
            // resolution.
            let previousSurface = lane.host?.value.surface
            lane.absorb(\.host, host, at: at, id: id)
            state.lanes[session] = lane
            // The inventory names this pane in short refs and the hook in UUIDs; the
            // manual order must follow the pane across the change.
            followSurfaceRename(&state, from: previousSurface, to: lane.host?.value.surface)
            redeemAwaitedAutoContinue(&state, session: session, at: at)
            recordCardColorIfNeeded(&state, session: session)
            return []

        case .worktree(let session, let branch, let at, let id):
            guard var lane = state.lanes[session] else { return [] }   // the no-synthesised-lane rule
            // `decide`, not `absorb`: the port answering "not a worktree" is an answer
            // and must be able to take a stale branch off the screen. `Derived.branch`
            // returns nil at the adapter, nil arrives here as a decision, and the lane
            // renders no branch rather than the last one it saw.
            lane.decide(\.branch, Redacted(optional: branch), at: at, id: id)
            state.lanes[session] = lane
            return []

        case .transcriptSeeded(let session, let texts, _):
            guard var lane = state.lanes[session] else { return [] }   // the no-synthesised-lane rule
            // Idempotent by construction: `lane.transcriptSeeded` gates the WHOLE case.
            // A second seed (the runtime re-reading a file it already backfilled, a
            // replay, the adapter racing itself) is a no-op; the reducer does not trust
            // the caller's "once per launch" discipline (see
            // `LaneRecord.transcriptSeeded`).
            guard !lane.transcriptSeeded else { return [] }
            lane.transcriptSeeded = true

            // Dedup: seeded entries go under the oldest existing entry, and any seeded
            // text equal to an existing entry's text is dropped. This closes the overlap
            // where the file's newest lines and the first LIVE hooks race at launch (a
            // prompt sent before the async file read completed would otherwise appear
            // twice).
            let existingTexts = Set(lane.transcript.map { $0.text.value })
            let toSeed = texts.filter { !existingTexts.contains($0.value) }

            // Ordering: backfill fills the past, never the present. Seeded entries get
            // a DEDICATED, synthetic era strictly below EVERY real instant, not "below
            // the lane's earliest live entry at the moment this case runs". The latter
            // depends on which other events were already applied, so under
            // `ReplayTests`' permutation bar two orderings could hand the seeded entries
            // different instants, breaking the "order is event time, never arrival" law.
            // `Self.backfillEraBase` fixes it: every real `Instant` is `>= 0`, so a
            // negative range sorts before all of them regardless of processing order.
            // Position comes from the seeded texts' own index; `enumerated()` over
            // `toSeed` (not `texts`) keeps the file's relative order among what survived
            // dedup, oldest first (pinned by `TranscriptTailTests` and
            // `TranscriptSeedTests`).
            for (index, text) in toSeed.enumerated() {
                let syntheticAt = Instant(sinceStart: Millis(Self.backfillEraBase + Int64(index)))
                let source = EventID("transcript-seed:\(session.raw)@\(index)")
                lane.rememberTranscript(text, origin: .terminal, deckStatus: nil, actionID: nil,
                                        at: syntheticAt, source: source)
            }
            state.lanes[session] = lane
            return []

        case .autoContinueSetForAll(let on, let surfaces, _, _):
            if on {
                for surface in surfaces where !surface.isEmpty {
                    state.prefs.autoContinue.insert(surface)
                }
                // Every refusal, not merely those of the panes being armed. Arming is
                // narrow (writing a promise `Reducer.arm` will skip would be a lie in the
                // file), but that says nothing about removing an entry. Kept narrow, a
                // refusal on a pane the deck cannot address would be unclearable: the
                // per-session switch needs a live lane and this button never saw the
                // surface. "Turn On for All Sessions" explicitly asks for what they once
                // refused.
                state.prefs.autoContinueRefused.removeAll()
            } else {
                // Everything, not merely what is addressable now. A pane the standing
                // default armed at `SessionStart` keeps its entry after its session ends
                // (surface keys outlive sessions), and a narrow sweep would miss it,
                // silently re-arming the next session started there while the footer read
                // "No sessions on the deck will continue automatically".
                state.prefs.autoContinue.removeAll()
                // The refusals are left alone: that is the whole asymmetry. This button
                // disarms the sessions in front of you; it is not a standing rule about
                // their tabs, so it adds no refusal and must not REMOVE one, or Turn Off
                // would arm a tab the user had refused. (Clearing selectively by inferring
                // each decision from whether its pane was armed breaks as soon as anything
                // else arms a pane, e.g. Turn On for All.)
                //
                // Offers held for sessions the deck cannot address yet are cancelled too.
                // Explicit, because this is the one place that knows a disarm was ASKED FOR
                // rather than inferred from its result.
                state.awaitingAutoContinue.removeAll()
            }
            return []

        case .apiError(let session, let text, let at, let id):
            guard var lane = state.lanes[session] else { return [] }   // the no-synthesised-lane rule
            // The same dominance gate shape as `apply(_:HookEvent)`'s hook-transition
            // write (`dominates(...)` against the same `lane.stateDecidedAt`/
            // `stateSource`), because a peek is one more claim on who decides this
            // lane's state, arriving through a different door. A dominated peek is stale
            // end to end: nothing is recorded, not even the text.
            //
            // The one addition: `dominates` ORed with "this peek's trigger is the lane's
            // current anchor, and that anchor is `.idle`". A strict tie against the hook
            // that scheduled this peek is the ORDINARY outcome (the hook's synchronous
            // transition write ran first), so without the clause a peek could never win
            // a tie against its own trigger. That is too strong for `.idle`
            // (`SessionStart`, `Stop`, `idle_prompt`), a verdict reached out of silence
            // rather than evidence; the peek exists to supply the WHY (`DeckRuntime`'s
            // trigger-set doc has the live probe; `ApiErrorTests` pins it).
            //
            // Scoped to `.idle` alone: every other tie still loses. `.working`
            // (`UserPromptSubmit`) is a hard new fact, and a peek racing its own trigger
            // is the flush-lag case (`ApiErrorTests.tiedPeekLosesToItsOwnTriggeringHook`):
            // the file's last word is staler than the retry that caused the read.
            // `.ended` stands because a closed session is truthfully ended however its
            // last turn died; `.needsYou` (`permission_prompt`) because a live dialog is
            // newer news than any recorded last word. `lane.stateSource == id` keeps the
            // clause narrow the other way: an anchor this peek's own trigger did not
            // write is untouched.
            guard dominates(at, id, over: lane.stateDecidedAt.map { ($0, lane.stateSource) })
                || (lane.stateSource == id && lane.state == .idle) else { return [] }
            lane.apiError = Sourced(value: text, source: id, decidedAt: at)
            lane.state = .errored
            lane.stateSource = id
            lane.stateDecidedAt = at
            state.lanes[session] = lane
            return []

        case .recap(let session, let text, let at, let id):
            guard var lane = state.lanes[session] else { return [] }   // the no-synthesised-lane rule
            // No dominance gate and no lane-state write: the difference from
            // `.apiError` above. A recap decides nothing; it is one row in a
            // chronological ledger stamped with its own moment, so there is no race to
            // arbitrate. Adding the gate would silently DROP recaps whenever a newer
            // hook had anchored the lane (the ordinary case, since a recap is older than
            // the peek that found it).
            //
            // Idempotence is `rememberTranscript`'s `(at, text, origin, actionID)`
            // guard: `at` and `id` derive from the recap's OWN timestamp (see
            // `DeckEvent.recap`), so re-finding the same recap reproduces the identical
            // row and the guard refuses it.
            lane.rememberTranscript(text, origin: .recap, deckStatus: nil, actionID: nil,
                                    at: at, source: id)
            state.lanes[session] = lane
            return []

        case .questionSubmitted(let id, let answers, let at):
            // Fewer answers than questions is not a partial submission, it is not a
            // submission. `isComplete` rather than a count: answers are keyed by
            // question text, so two answers to one question and none to another has the
            // right count and is still partial.
            guard let call = state.questions[id], call.isComplete(answers),
                  var hold = state.holds[id] else { return [] }
            guard hold.resolve(.updatedInput, at: at) != nil else { return [] }
            state.holds[id] = hold
            state.questions[id] = nil
            state.answering[id] = nil
            acknowledge(&state, id, at: at)
            // The mirror closes the SAME instant the hold does: a deck answer goes
            // straight `.deckWindow` → `.resolved` (see `MirrorStage`).
            if state.mirrors[id] != nil {
                state.mirrors[id]?.stage = .resolved(answers: answers, origin: .deck, at: at)
            }
            // The ledger row (the same "what was chosen" fact a terminal answer earns
            // in `apply(_:HookEvent)`'s `.postToolUse` handling), written here because
            // `PostToolUse` for a deck-answered call echoes the same answers and would
            // double the row if both paths wrote it. `EventID` is synthesized since
            // `.questionSubmitted` carries none (as for an `.actionSent` row, see
            // `TranscriptEntry.source`).
            if var lane = state.lanes[id.session] {
                lane.rememberTranscript(describeAnswers(answers), origin: .answeredQuestion,
                                        deckStatus: nil, actionID: nil, at: at,
                                        source: EventID("question-answered:\(id)@\(at.sinceStart.raw)"))
                state.lanes[id.session] = lane
            }
            return [.updatedInput(id, answers: answers), .resolveHold(id, .updatedInput)]

        case .questionPicked(let id, let label, let at):
            guard let call = state.questions[id] else { return [] }
            // The arm-delay rule extended to picks: the takeover's own arm, the 400 ms
            // after a step change in either direction, and the 400 ms after a front
            // change all refuse the tap. Back is exempt: its slot never moves or
            // changes meaning.
            guard settled(state, id, at: at) else { return [] }
            var progress = state.answering[id] ?? AnswerProgress()
            guard call.questions.indices.contains(progress.step) else { return [] }
            let question = call.questions[progress.step]
            // A label the call never offered is not a selection. A reducer trusting the
            // view would let a rewritten view answer with text the user never saw (the
            // byte-identical-command rule on the return path).
            guard question.options.contains(where: { $0.label == label }) else { return [] }

            if question.multiSelect {
                if let existing = progress.picked.firstIndex(of: label) {
                    progress.picked.remove(at: existing)
                } else {
                    progress.picked.append(label)
                }
                state.answering[id] = progress
                return []
            }
            progress.picked = [label]
            state.answering[id] = progress
            return reduce(&state, .questionCommitted(id, at: at))

        case .questionAnsweredFreely(let id, let step, let typed, let at):
            guard let call = state.questions[id] else { return [] }
            guard settled(state, id, at: at) else { return [] }
            var progress = state.answering[id] ?? AnswerProgress()
            // A stale submit (the view sent this against a question the stepper has
            // moved past) is refused. `step` is carried because the text was typed
            // against whichever question was on screen when the field opened; a step
            // change in between must not attach it to the wrong one.
            guard progress.step == step,
                  call.questions.indices.contains(progress.step) else { return [] }
            let question = call.questions[progress.step]

            // The one narrow door through the offered-label guard above. That guard
            // refuses a label the DECK invented. A human-typed answer is the terminal's
            // own "Other…" affordance (UX_DESIGN §4.1), mirrored; refusing it would make
            // the deck a stricter gate than the session it supervises. So this path
            // never consults `question.options`; the guard is not weakened, just not
            // this path's to enforce.
            if question.multiSelect {
                // The terminal treats Other as one selectable answer: the typed text joins
                // `picked` as a single member like an option label, and resubmitting the
                // identical string takes it back, like re-tapping a picked option. A
                // DIFFERENT typed string first evicts any out-of-options label already in
                // `picked` (editing "Custom" to "Custom2" REPLACES the Other entry). The
                // terminal has exactly one Other slot, and this makes that true of `picked`
                // rather than "true in practice" of whatever the view sends.
                if let existing = progress.picked.firstIndex(of: typed) {
                    progress.picked.remove(at: existing)
                } else {
                    if let stale = progress.picked.firstIndex(where: { label in
                        !question.options.contains { $0.label == label }
                    }) {
                        progress.picked.remove(at: stale)
                    }
                    progress.picked.append(typed)
                }
                state.answering[id] = progress
                return []
            }
            progress.picked = [typed]
            state.answering[id] = progress
            return reduce(&state, .questionCommitted(id, at: at))

        case .questionCommitted(let id, let at):
            guard let call = state.questions[id], var progress = state.answering[id],
                  !progress.picked.isEmpty,
                  call.questions.indices.contains(progress.step),
                  settled(state, id, at: at) else { return [] }
            let question = call.questions[progress.step]
            progress.gathered.append(Answer(question: question.text,
                                            labels: inOptionOrder(progress.picked, question)))
            progress.picked = []
            progress.step += 1
            // The stepper advanced: the next question's controls re-arm (UX_DESIGN
            // §4.1). Stamped after `settled` so the internal pick → commit recursion at
            // one instant is not refused by its own stamp.
            progress.stepChangedAt = at
            state.answering[id] = progress
            // Not the last question: nothing reaches the wire, which is the
            // all-or-nothing rule stated as the absence of an effect rather
            // than as a guard a view is trusted to respect.
            guard progress.step >= call.questions.count else { return [] }
            return reduce(&state, .questionSubmitted(id, answers: progress.gathered, at: at))

        case .questionSteppedBack(let id, let at):
            // Free, total, silent. Total: step 0 is a no-op, never an underflow.
            // Silent: no effect, since nothing reaches the wire until the last answer,
            // which is what makes back safe. The popped answer returns as the live
            // selection, revisable, never blanked.
            guard state.questions[id] != nil, var progress = state.answering[id],
                  progress.step > 0, !progress.gathered.isEmpty else { return [] }
            progress.step -= 1
            progress.picked = progress.gathered.removeLast().labels
            // Stepping back is a step change like any other: the reopened
            // question's options re-arm. Back itself never consults this
            // stamp — its event is not a pick.
            progress.stepChangedAt = at
            state.answering[id] = progress
            return []

        case .questionAbandoned(let id, let at):
            guard var hold = state.holds[id] else { return [] }
            let effect = hold.resolve(.release, at: at)
            state.holds[id] = hold
            state.questions[id] = nil
            state.answering[id] = nil
            // A dismissal falls through exactly like a timeout — the same
            // `.release` outcome, the same mirror transition.
            if effect != nil { releaseMirrorIfAny(&state, id, at: at) }
            return [effect].compactMap { $0 }

        case .forwardPlanStarted(let plan, _):
            // Only `.terminalLive` may start a plan: the readiness gate is what makes
            // forwarding honest (`MirrorStage.terminalLive`: "proof the terminal picker
            // actually exists"). A plan already running refuses a second: `ForwardPlan`
            // is a single cursor, not a queue, and starting over mid-plan would re-send
            // steps the terminal already received.
            //
            // `forwardSentAt == nil` is the reducer-level guard against a double send,
            // never trusted to the view alone. The incident: tap 2 landed and set
            // `forwardSentAt`, the surface still read "Answerable from here", and tap 3
            // reached `DeckRuntime.forward` and re-sent the same digit. `.forwardRearmed`
            // is the only door that clears `forwardSentAt`, so a plan starts fresh (no
            // prior attempt) or after an EXPLICIT send-again.
            guard case .terminalLive? = state.mirrors[plan.hold]?.stage,
                  state.forwarding[plan.hold] == nil,
                  state.mirrors[plan.hold]?.forwardSentAt == nil,
                  !plan.steps.isEmpty
            else { return [] }
            state.forwarding[plan.hold] = plan
            // A fresh attempt immediately clears the previous one's unconfirmed notice
            // (see `QuestionMirror.forwardUnconfirmedAt`). `forwardSentAt` is already
            // `nil` here by the guard above.
            state.mirrors[plan.hold]?.forwardUnconfirmedAt = nil
            return []

        case .forwardStepSent(let id, let at):
            guard var plan = state.forwarding[id] else { return [] }
            plan.cursor += 1
            // A finished plan does not linger waiting for a cancellation that will never
            // come (the "nothing outlives what it is answering" discipline of
            // `sweepHolds`).
            state.forwarding[id] = plan.isComplete ? nil : plan
            // Starts the awaiting-confirmation window the INSTANT the plan completes,
            // never before: a mid-flight plan already disables its options through
            // `mirror.forwarding` (`MirrorView`), and a second disabled-reason would
            // make the two windows hard to tell apart. `DeckRuntime
            // .scheduleForwardLandingWatch` fires from the same completion, one layer
            // up.
            if plan.isComplete { state.mirrors[id]?.forwardSentAt = at }
            return []

        case .forwardPlanCancelled(let id, _):
            state.forwarding[id] = nil
            return []

        case .mirrorReadinessElapsed(let id, let at), .mirrorObservedLive(let id, let at):
            promoteMirrorIfStillReleased(&state, id, at: at)
            return []

        case .forwardUnconfirmed(let id, let at):
            // `forwardSentAt != nil`: still genuinely awaiting the confirmation this
            // watchdog asks about. `nil` means `.forwardRearmed` already cleared it (the
            // person hit "Send again" first); whichever runs first wins, and a late
            // watchdog must not stamp an unconfirmed notice onto an attempt the person
            // moved past.
            guard case .terminalLive? = state.mirrors[id]?.stage,
                  state.mirrors[id]?.forwardSentAt != nil
            else { return [] }
            state.mirrors[id]?.forwardUnconfirmedAt = at
            return []

        case .forwardRearmed(let id, _):
            // The deliberate re-arm, never a replay. Clears BOTH the
            // awaiting-confirmation window and the unconfirmed mark, the entire door
            // back to tappable (`MirrorView.awaitingConfirmation` reads `forwardSentAt`;
            // the "unconfirmed" copy reads `forwardUnconfirmedAt`; `.forwardPlanStarted`
            // refuses until `forwardSentAt` is nil). No ledger write and no answer
            // content: a pure "let them try again", like `questionSteppedBack`.
            guard case .terminalLive? = state.mirrors[id]?.stage else { return [] }
            state.mirrors[id]?.forwardSentAt = nil
            state.mirrors[id]?.forwardUnconfirmedAt = nil
            return []

        case .gesture(let tool, let down, let up, let origin):
            // A tap creates nothing. The threshold is the spec's 600 ms
            // and it is read from the policy, not written here twice.
            guard up.sinceStart - down.sinceStart >= state.policy.longPress else { return [] }
            // From the strip the rule is session-scoped, and creating
            // it is not a config write at all.
            let scope: PermissionRule.Scope = origin == .strip ? .session : .durable
            let rule = PermissionRule(id: "\(tool)|\(up.sinceStart.raw)", tool: tool,
                                      scope: scope, createdAt: up)
            state.rules.append(rule)
            return [.log("rule \(rule.id) scope=\(scope.rawValue)")]

        case .revokeRule(let id):
            state.rules.removeAll { $0.id == id }
            return [.log("revoked \(id)")]

        case .prefsChanged(let prefs, _):
            // Newly tombstoned sessions are removed NOW, with everything the
            // deck was holding about them: the lane, its prompts, its queue, its
            // selection, and any open hold. The runtime releases the hold's
            // waiting caller separately — the reducer owns no continuations.
            for id in prefs.deleted.subtracting(state.prefs.deleted) {
                let session = SessionID(id)
                state.lanes[session] = nil
                state.pending[session] = nil
                state.blocked[session] = nil
                state.autoLatch[session] = nil
                // The held-open auto-continue offer goes with the lane. It is
                // the vehicle for arming, and a deleted session must not be
                // holding one — the same reason its queue and its holds go.
                state.awaitingAutoContinue[session] = nil
                state.holds = state.holds.filter { $0.key.session != session }
                if state.selected == session { state.selected = nil }
            }
            // A default that is OFF holds no offers. `seedAutoContinue` discards them
            // lazily at the next host report, but a session that never sends another
            // would keep its entry, and an entry outliving the switch is how a session
            // got armed hours later by a flag it never saw. The bulk act cancels them
            // through its own event (`.autoContinueSetForAll`), not by inference from
            // the resulting preferences here (which misfired on every unrelated
            // `setPrefs`).
            if !prefs.autoContinueByDefault { state.awaitingAutoContinue.removeAll() }
            // No flip-time bookkeeping, deliberately. Marking every live pane as
            // already-offered when the default is switched on made a pane permanently
            // ineligible, so `/exit` and a NEW session in the same tab was never armed.
            // Because the trigger is `SessionStart` (`seedAutoContinue`),
            // non-retroactivity falls out of the wire: a running session fires no
            // further `SessionStart`, so there is nothing to prevent here.
            state.prefs = prefs
            // The one-source countdown rule's write site: `HoldPolicy.budget` is
            // rebuilt from `prefs.holdBudget` on every preference change and set
            // nowhere else, so a hold opened after this event carries the user's chosen
            // budget by construction. `questionBudget` is `prefs.questionHoldBudget`'s
            // write site, the same rule. armDelay/reArmDelay/longPress are specs, not
            // preferences.
            state.policy = HoldPolicy(budget: prefs.holdBudget.millis,
                                      questionBudget: prefs.questionHoldBudget.millis,
                                      armDelay: state.policy.armDelay,
                                      reArmDelay: state.policy.reArmDelay,
                                      longPress: state.policy.longPress)
            return []

        case .restart:
            // Everything the deck knew came from a feed, so everything it
            // knows after a restart must come from a feed too. Keeping lanes
            // across a restart is the cache the recover-from-feeds rule
            // forbids: it looks like resilience and it is the deck asserting
            // a fact nothing has re-supplied.
            let open = state.holds.values.filter(\.isOpen).map(\.id)
            state.lanes = [:]
            // The two transient rename/auto-continue sets go with the lanes
            // they describe — both of their own doc comments say a restarted
            // deck has none outstanding, and this is what makes that true.
            state.awaitingAutoContinue = [:]
            state.holds = [:]
            // Display state dies with the holds it displayed — a promoted id
            // surviving a restart would be the cache the recover-from-feeds
            // rule forbids, wearing navigation clothes. So does the usage
            // reading: it came from a feed and the next statusline
            // re-supplies it.
            state.promoted = nil
            state.selected = nil
            state.pending = [:]
            // A remembered failure is a cache, and the recover-from-feeds
            // rule does not make an exception for bad news: the probe runs
            // again after a restart.
            state.hostBlock = nil
            state.blocked = [:]
            state.frontChangedAt = nil
            state.usage = nil
            state.pendingWrite = nil
            // Session-scoped rules die with the session. Durable ones were
            // written to a file and are re-read, not remembered.
            state.rules = []
            // Fail CLOSED to the terminal, not silently: an unanswered hold
            // is released so the engine's own policy decides. The
            // graceful-degradation rule is the same principle — no session is
            // ever worse off because the deck exists.
            return open.map { .resolveHold($0, .release) }

        case .configRequested(let origin, let diff):
            // A long-press on the strip creates a session-scoped rule
            // held in the deck's own memory. It never reaches ~/.claude, so it
            // never becomes a preview of a config write either — the fast
            // gesture is not a config write at all, which is what lets both
            // the preview-then-commit rule and UX_DESIGN §4 be true at once.
            if origin == .strip { return [.log("session-scoped rule from strip")] }
            state.pendingWrite = diff
            return [.previewConfigWrite(diff)]

        case .configConfirmed(let diff):
            // The confirmation must name the diff that was previewed.
            // A confirmation for anything else is a user agreeing to something
            // they were not shown.
            guard state.pendingWrite == diff else { return [] }
            state.pendingWrite = nil
            return [.commitConfigWrite(diff)]

        case .promote(let id, _):
            // Promotion is a display decision and emits no resolution ("demotion
            // preserves the hold"). The open hold becomes the displayed front, and the
            // demoted question call's stepper clears at demotion, observably (the
            // declared divergence from UX_DESIGN §4.1's letter). A closed hold promotes
            // nothing.
            guard let hold = state.holds[id] else { return [] }
            if hold.isOpen, let front = state.displayedFront, front != id {
                state.answering[front] = nil
                state.promoted = id
            }
            return [.log("promoted \(id)")]

        case .sessionSelected(let session, _):
            // Validated at projection rather than here: a lane can disappear
            // between selecting it and rendering, and the frame is where that
            // is noticed. Emits nothing.
            state.selected = session
            return []

        case .actionQueued(let session, let action, let at):
            // A session the deck has never heard of is not a session it may
            // type into (the no-synthesised-lane rule's rule, arriving on a
            // new surface).
            guard state.lanes[session] != nil else { return [] }
            if case .escape = action.kind {
                state.pending[session] = [QueuedAction(action: action, queuedAt: at)]
                return []
            }
            // Idempotent. An action already waiting is not queued twice: two Continues
            // in a row are one intention, and during a usage hold the extras would all
            // arrive at once when the window opens. Different actions still stack (a
            // compact then a continue).
            if state.pending[session]?.contains(where: {
                $0.action.id == action.id && $0.sentAt == nil
            }) == true { return [] }
            state.pending[session, default: []].append(QueuedAction(action: action, queuedAt: at))
            return []

        case .actionCancelled(let session, let actionID, _):
            guard var queue = state.pending[session] else { return [] }
            // Only what has NOT gone. A sent action is beyond recall, and pretending
            // otherwise would be the deck claiming an authority it does not have.
            guard let index = queue.firstIndex(where: {
                $0.action.id == actionID && $0.sentAt == nil
            }) else { return [] }
            queue.remove(at: index)
            state.pending[session] = queue.isEmpty ? nil : queue
            return []

        case .queueCleared(let session, _):
            guard let queue = state.pending[session] else { return [] }
            let sent = queue.filter { $0.sentAt != nil }
            state.pending[session] = sent.isEmpty ? nil : sent
            return []

        case .actionSent(let session, let actionID, let at):
            guard var queue = state.pending[session] else { return [] }
            guard let index = queue.firstIndex(where: { $0.action.id == actionID && $0.sentAt == nil })
            else { return [] }
            let action = queue[index].action
            // A send that reached the wire is proof the host is talking to the
            // deck, so it clears what the last failure claimed — for this
            // session AND globally. Otherwise a socket that came back would
            // leave every control dark behind a stale reason, and the person
            // would have to relaunch the deck to be believed.
            state.hostBlock = nil
            state.blocked[session] = nil
            queue[index].sentAt = at
            // An action the deck can never confirm retires on the send, and says "sent"
            // rather than "done" (a slash command fires no UserPromptSubmit; an
            // interrupt fires no Stop).
            if !action.isConfirmable { queue.remove(at: index) }
            state.pending[session] = queue.isEmpty ? nil : queue

            // The debounce fact: recorded UNCONDITIONALLY, even for a payload-less
            // action like Escape. A pill stays dark until the session's next lifecycle
            // event, whether or not this send left text behind. Per ACTION (keyed by
            // id), not per bar.
            state.lanes[session]?.lastSentAt[actionID] = at

            // The card shows the last thing a person said through ANY door. A
            // payload-bearing send becomes the lane's prompt fact AT WIRE TIME, not at a
            // later receipt: an unconfirmable send (`/compact`) never gets one and would
            // otherwise show nothing. `.escape`/`.dialogKey` carry no payload and touch
            // neither slot.
            //
            // The `EventID` is SYNTHESIZED deterministically from the action id and send
            // instant, since `.actionSent` is a runtime-reported command, not a wire
            // event. Reproducible under replay; a confirmable action's receipt later
            // matches by ITS OWN ACTION ID at the top of the hook apply, which upgrades
            // rather than re-writes it.
            if let payload = action.payload {
                let text = Redacted(payload)
                let id = EventID("action:\(actionID)@\(at.sinceStart.raw)")
                state.lanes[session]?.absorb(\.prompt, text, at: at, id: id)
                state.lanes[session]?.rememberPrompt(text, at: at, id: id)
                state.lanes[session]?.rememberTranscript(text, origin: .deck, deckStatus: .sent,
                                                          actionID: actionID, at: at, source: id)
            }
            return []

        case .actionBlocked(let session, let block, _):
            guard let session else {
                // The host, not a lane. Recorded even with nothing selected —
                // the probe that found it runs on selection, and a block the
                // reducer refused to remember would be a panel that had to ask
                // again every time it opened.
                state.hostBlock = block
                return []
            }
            // The no-synthesised-lane rule's rule again: the deck holds no
            // fact about a session it has never heard of, not even a bad one.
            guard state.lanes[session] != nil else { return [] }
            state.blocked[session] = block
            return []

        case .deleteRequested(let session, _):
            // Only for a lane that exists. A confirmation about a session the
            // deck has already lost would offer to remove nothing.
            guard state.lanes[session] != nil else { return [] }
            state.confirmingDelete = session
            return []

        case .deleteAbandoned:
            state.confirmingDelete = nil
            return []

        case .deleteConfirmed(let session, _):
            // The removal itself rides on `prefsChanged`, which is where the
            // tombstone is written and every deck-owned record of the session is
            // dropped. This event only closes the question.
            guard state.confirmingDelete == session else { return [] }
            state.confirmingDelete = nil
            return []

        case .dismissRequested(let at):
            // Innermost first, decided where the state is. A view cannot know
            // whether a stepper is open, and duplicating that predicate
            // outside the reducer is how three places came to disagree about
            // the front.
            if let front = state.displayedFront, state.questions[front] != nil,
               (state.answering[front]?.step ?? 0) > 0 {
                return reduceCore(&state, .questionSteppedBack(front, at: at))
            }
            if state.selected != nil { state.selected = nil; return [] }
            return []

        case .promoteNext:
            // The mast counter's tap. The cyclic walk lives here, over the same
            // (openedAt, id) order the front rule reads, so "next" means "next-oldest
            // waiter after the one showing" and the last wraps to the first. One open
            // hold cycles to itself, a no-op rather than a refusal (the control only
            // renders with a queue, but the reducer stays total).
            let open = state.openHoldsInOrder
            guard open.count > 1, let front = state.displayedFront,
                  let index = open.firstIndex(where: { $0.id == front }) else { return [] }
            let next = open[(index + 1) % open.count].id
            state.answering[front] = nil
            state.promoted = next
            return [.log("promoted \(next)")]
        }
    }

    /// A multi-select answer ships in OPTION order, never tap order.
    /// `progress.picked` accumulates in tap order (option 3 before option 1 leaves
    /// `[3, 1]`), and nothing between a tap and `Answer.labels` would reorder it.
    /// The terminal's options are a numbered list a person answers into, not a
    /// queue of taps, so an answer whose order depends on which option the finger
    /// reached first would differ from the terminal's own answer. Free text
    /// (`questionAnsweredFreely`) carries no option index and sorts to the end, in
    /// typing order, where "Other…" renders.
    ///
    /// Written by hand rather than trusting `Array.sorted`'s documented stability:
    /// a manual `offset` tiebreaker costs one line and states its own guarantee.
    private static func inOptionOrder(_ picked: [Redacted], _ question: Question) -> [Redacted] {
        picked.enumerated().sorted { a, b in
            let ia = question.options.firstIndex(where: { $0.label == a.element }) ?? Int.max
            let ib = question.options.firstIndex(where: { $0.label == b.element }) ?? Int.max
            if ia != ib { return ia < ib }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// May a pick or commit land on this call right now? Three windows refuse
    /// it: before the hold's own arm (the arm-delay rule, extended off
    /// `Hold.resolve` which picks never reach), within `reArmDelay` of a step
    /// change in either direction, and within `reArmDelay` of a front change.
    /// Timeout paths never come here; back has its own event.
    private static func settled(_ state: DeckState, _ id: HoldID, at: Instant) -> Bool {
        if let hold = state.holds[id], at < hold.armedAt { return false }
        if let t = state.answering[id]?.stepChangedAt,
           at.sinceStart - t.sinceStart < state.policy.reArmDelay { return false }
        if let t = state.frontChangedAt,
           at.sinceStart - t.sinceStart < state.policy.reArmDelay { return false }
        return true
    }

    /// A resolved hold takes its question call and its half-finished answer with
    /// it.
    ///
    /// Expiry is the commonest end a question call meets (the commonest thing a
    /// person does with a question they did not want is nothing), so without this
    /// a long-running deck gathered a permanent `questions` entry per ignored
    /// call, plus an `answering` entry for every one somebody started and
    /// abandoned.
    ///
    /// It also closes a smaller hole: `settled` gates taps on the arm delay but
    /// not on the hold still being OPEN, so a pick in flight when the budget ran
    /// out would mutate `answering` for a finished hold. (`Hold.resolve` refuses
    /// twice, so the effect layer was safe; the bookkeeping was not.) With the
    /// call gone, the pick finds nothing and does nothing.
    private static func forgetQuestion(_ state: inout DeckState, _ id: HoldID) {
        state.questions[id] = nil
        state.answering[id] = nil
    }

    /// Advances this hold's mirror from `.deckWindow` to `.released`, called from
    /// every site whose OWN resolution just became `.release` (`.decision`,
    /// `.holdExpired`, `.questionAbandoned`) so the mirror's transition cannot
    /// drift from the hold's. A no-op for a non-question hold (no mirror) and for
    /// a mirror already past `.deckWindow`: `.release` is produced once per hold
    /// (the exactly-once rule), so a repeat is harmlessly silent.
    private static func releaseMirrorIfAny(_ state: inout DeckState, _ id: HoldID, at: Instant) {
        guard var mirror = state.mirrors[id], mirror.stage == .deckWindow else { return }
        mirror.stage = .released(at: at)
        state.mirrors[id] = mirror
    }

    /// Shared by both readiness-gate promotions, `.mirrorReadinessElapsed` (the
    /// bounded-timer path) and `.mirrorObservedLive` (the screen-read path), with
    /// the same "one function makes the move" discipline as `releaseMirrorIfAny`.
    /// A no-op once the mirror has left `.released` by any door (the ceremony
    /// pair finishing, a resolution arriving, or the other signal winning the
    /// race), so whichever proof reaches this hold first counts and nothing can
    /// promote a call twice or walk a later stage backward.
    private static func promoteMirrorIfStillReleased(_ state: inout DeckState, _ id: HoldID, at: Instant) {
        guard case .released? = state.mirrors[id]?.stage else { return }
        state.mirrors[id]?.stage = .terminalLive(at: at)
    }

    /// One ledger line for an answered question: `"Pick: Option A"` for a
    /// single-select, `"Pick: Option A, Option B"` for a multi-select, one line
    /// per question, newline-joined for a multi-question call. Built from
    /// `[Answer]` alone (`Answer.question` already carries the question's text),
    /// because in the realistic `PostToolUse` timeline `state.questions[id]` has
    /// already been cleared by the hold's natural expiry (`forgetQuestion`).
    ///
    /// The whole composed string is wrapped in ONE `Redacted`, built from `.value`
    /// read back out of each answer's `Redacted` fields. Not a re-leak: this is
    /// in-process composition for a ledger row that is itself `Redacted` end to
    /// end (see `Redacted`'s file doc).
    private static func describeAnswers(_ answers: [Answer]) -> Redacted {
        Redacted(answers.map { answer in
            "\(answer.question.value): \(answer.labels.map(\.value).joined(separator: ", "))"
        }.joined(separator: "\n"))
    }

    /// Forget resolved holds old enough that no retry will ever arrive for them.
    /// See `HoldPolicy.memory` for why they are kept at all.
    ///
    /// Amortised, and it has to be. Sweeping whenever the map is over the
    /// threshold re-filters every hold on every resolution during a busy stretch
    /// when nothing is old enough to remove, turning a linear reducer quadratic
    /// (doubling the stream multiplied the time by 291). So a fruitless sweep
    /// raises its own bar: the threshold moves to twice what survived, the next
    /// sweep waits until the map has doubled again, and the cost is amortised to
    /// a constant per event.
    private static func sweepHolds(_ state: inout DeckState, at: Instant) {
        guard state.holds.count > state.holdSweepAbove else { return }
        let cutoff = at.sinceStart.raw - state.policy.memory.raw
        state.holds = state.holds.filter { _, hold in
            // A forever hold (`expiresAt == nil`) has no expiry to anchor the retry
            // window on, so `openedAt` (when the call the retry would duplicate arrived)
            // stands in. `isOpen` alone keeps every hold still waiting.
            hold.isOpen || (hold.expiresAt ?? hold.openedAt).sinceStart.raw >= cutoff
        }
        state.holdSweepAbove = max(HoldPolicy.sweepAbove, state.holds.count * 2)
        // A mirror never outlives its hold's bookkeeping: every id this filter
        // dropped gets its mirror dropped in the SAME pass, triggered by `holds`
        // crossing its own threshold (see `QuestionMirror` for why the two are swept
        // together).
        state.mirrors = state.mirrors.filter { id, _ in state.holds[id] != nil }
        // A forward plan answers ONE mirror and cannot outlive it: the same paired
        // sweep, one collection further along the chain.
        if !state.forwarding.isEmpty {
            state.forwarding = state.forwarding.filter { id, _ in state.holds[id] != nil }
        }
    }

    private static func acknowledge(_ state: inout DeckState, _ id: HoldID, at: Instant,
                                    as next: LaneState = .working) {
        guard var lane = state.lanes[id.session] else { return }
        lane.state = next
        lane.stateSource = EventID("decision|\(id)")
        lane.stateDecidedAt = at
        // `LaneRecord.apiError`'s clearing rule: a lane that moved OFF `.errored`
        // has no API error left to report. `next == .errored` only on the
        // headless-deny branch (unreachable in production), where it is left
        // untouched: clear only on a write to a non-errored value, like the hook
        // transition gate and the fleet apply.
        if next != .errored { lane.apiError = nil }
        state.lanes[id.session] = lane
    }

    public static func run(_ events: [DeckEvent], from start: DeckState = DeckState()) -> DeckState {
        var s = start
        for e in events { reduce(&s, e) }
        return s
    }

    /// Every effect the stream produced, in order. The exactly-once rule and
    /// the correlation rule are assertions over this list and nothing else.
    public static func effects(_ events: [DeckEvent],
                               from start: DeckState = DeckState()) -> (DeckState, [Effect]) {
        var s = start
        var out: [Effect] = []
        for e in events { out += reduce(&s, e) }
        return (s, out)
    }

    // ------------------------------------------------------------------ hooks
    @discardableResult
    private static func apply(_ state: inout DeckState, _ h: HookEvent) -> [Effect] {
        // A deleted session leaves no trace here. Removal happens at the REDUCER,
        // not the projection: suppressing it at the frame would mean the deck still
        // held every prompt, tool name and path and merely declined to draw them,
        // which is not a delete.
        //
        // The runtime answers its held calls with no opinion so the session falls
        // through to its own permission prompt (see `DeckRuntime.handle`); silence
        // would hang it at the next request.
        guard !state.prefs.deleted.contains(h.session.raw) else { return [] }
        // Effects: only `.postToolUse`'s handling below produces one.
        var effects: [Effect] = []
        // Whether this event is the deck's FIRST sight of this session, read before
        // the lane is created: the auto-continue default uses it to tell a new
        // session from a `SessionStart` the same session fires again on resume or
        // `/clear`.
        let sessionIsNew = state.lanes[h.session] == nil
        var lane = state.lanes[h.session] ?? LaneRecord(
            session: h.session, firstSeenAt: h.at, lastEventAt: h.at,
            state: .idle, stateSource: h.id, stateDecidedAt: nil,
            fleetState: .absent, waitingFor: .absent, isBackground: false,
            contextPercent: .absent, contextSource: nil, contextDecidedAt: nil)

        lane.firstSeenAt = min(lane.firstSeenAt, h.at)
        lane.lastEventAt = max(lane.lastEventAt, h.at)
        lane.remember(h.tool ?? "\(h.kind)", at: h.at)

        // The remembered block dies at the session's own next lifecycle event: a
        // cache must not outlive the condition it describes. `.actionBlocked` writes
        // `state.blocked[session]`; other clearers are session deletion
        // (`.prefsChanged`), `.restart`, and a send that reached the wire
        // (`.actionSent`). That last path only fires if the queue still holds
        // something to retry, so a person who withdraws the queued action after a
        // block (cancels it, or empties the composer by hand) leaves the block
        // standing: controls stay dark, the banner asserts a composer that is no
        // longer full, and only relaunching clears it (observed live with
        // `composerBusy`).
        //
        // Clearing only when a queue empties was rejected: a block can go stale for
        // reasons unrelated to the queue (the person clears a draft the deck never
        // queued against, or keeps typing past whatever made the host answer
        // `hostError`). So the trigger is every hook this session fires, the same
        // "session's OWN next lifecycle event of any kind" contract as
        // `Frame.debouncingActionIDs` (`lane.lastEventAt` is unconditional across
        // every `HookKind`). The debounce fact is DERIVED at projection time instead
        // of cleared by the reducer; deriving `blocked` the same way would need a
        // timestamp on `ActionBlock` and a comparison in `Frame.swift`, so `blocked`
        // stays a remembered fact with a fourth clear site.
        //
        // Trade accepted: this can clear a reason that still holds for one frame,
        // until the next tap re-probes. Re-probing and failing with a FRESH reason
        // beats a control that stays dark for a condition that may no longer be
        // true.
        state.blocked[h.session] = nil

        // A RECEIPT is checked FIRST, before the provenance classification below. A
        // confirmable deck send (`.actionSent`) already wrote its text into
        // `lane.prompt`/`.prompts`/`.transcript` at SEND time; this hook is that
        // send's receipt, the same bytes echoed back, and must UPGRADE the existing
        // row rather than duplicate it. A receipt's text ("Continue", say) is
        // deck-originated, human-intent by construction, so matching it must not
        // depend on `PromptProvenance` calling it human. Matched EXACTLY,
        // oldest-unretired first, once.
        //
        // The indistinguishable case, by design: a human who genuinely retypes the
        // SAME bytes while an earlier send sits unconfirmed reads as that send's
        // receipt. No wire signal separates the two, and recording it once is honest
        // about what the deck knows.
        var isReceiptForPendingSend = false
        if h.kind == .userPromptSubmit, let text = h.prompt?.value,
           var queue = state.pending[h.session] {
            if let index = queue.firstIndex(where: {
                $0.sentAt != nil && $0.confirmedAt == nil && $0.action.payload == text
            }) {
                queue[index].confirmedAt = h.at
                let confirmedActionID = queue[index].action.id
                queue.remove(at: index)
                state.pending[h.session] = queue.isEmpty ? nil : queue
                isReceiptForPendingSend = true
                lane.confirmTranscript(actionID: confirmedActionID, text: Redacted(text))
            }
        }

        // Machine-injected turns (see `PromptProvenance`'s file doc). Claude Code
        // fires UserPromptSubmit for a background-task wake-up exactly like a
        // person's words, with no distinguishing metadata on the wire; only the
        // text's shape says otherwise. A REAL turn either way (the idle pair and the
        // `.working` transition below fire regardless), but only HUMAN text may
        // become an identity fact.
        let isMachineTurn = h.prompt.map { PromptProvenance.classify($0.value) == .machine } ?? false

        // Identity, from whatever this payload carried. Each slot is fed
        // independently with its own provenance, because they arrive on different
        // events at different rates (`cwd` on nearly all, `prompt` only on
        // UserPromptSubmit, `permission_mode` on tool events); one shared "last
        // updated" would make a fresh directory look as old as a stale prompt.
        lane.absorb(\.cwd, h.cwd, at: h.at, id: h.id)
        lane.absorb(\.transcriptPath, h.transcriptPath, at: h.at, id: h.id)
        lane.absorb(\.title, h.title, at: h.at, id: h.id)
        // Barred for a MACHINE turn (not anybody's words) and for a RECEIPT (the
        // text is already `lane.prompt` from send time; re-absorbing would only move
        // its provenance).
        if !isMachineTurn && !isReceiptForPendingSend {
            lane.absorb(\.prompt, h.prompt, at: h.at, id: h.id)
        }
        // The history rides beside the newest-of-record. Only a real, HUMAN,
        // non-receipt submission joins it: other hook kinds echo no prompt, a
        // machine turn is not a thing anybody said, and a receipt joined at send
        // time.
        if h.kind == .userPromptSubmit, let text = h.prompt, !isMachineTurn && !isReceiptForPendingSend {
            lane.rememberPrompt(text, at: h.at, id: h.id)
            lane.rememberTranscript(text, origin: .terminal, deckStatus: nil, actionID: nil,
                                    at: h.at, source: h.id)
        }
        lane.absorb(\.permissionMode, h.permissionMode, at: h.at, id: h.id)
        lane.absorb(\.lastTool, h.tool, at: h.at, id: h.id)
        // The manual order keys on the surface, and this feeder re-spells it (the
        // fleet poll stores short refs like `surface:27`; the hook inherits the UUID
        // pair from its environment). `followSurfaceRename`, called once the lane is
        // written back, keeps the user's arrangement pinned to the pane.
        let previousSurface = lane.host?.value.surface
        lane.absorb(\.host, h.host, at: h.at, id: h.id)
        let renamedSurface = (from: previousSurface, to: lane.host?.value.surface)
        // The idle pair, by event time rather than arrival — `max` so a
        // replayed permutation lands on one answer.
        switch h.kind {
        case .userPromptSubmit: lane.lastPromptAt = max(lane.lastPromptAt ?? h.at, h.at)
        case .stop, .sessionEnd, .sessionStart:
            lane.lastStopAt = max(lane.lastStopAt ?? h.at, h.at)
        default: break
        }

        // The unknown-is-not-error rule: an unrecognised kind holds the prior state
        // and does not update the provenance either, since nothing displayed came
        // from it. A PreToolUse carrying a tool_use_id opens a hold. Whether the
        // deck *held* it is the relay's `held_ms` in replay and the deck's own
        // budget live; either way the identity comes from the wire.
        let opensAHold: Bool
        switch h.kind {
        case .preToolUse:
            // Trusted as already-decided for every tool but the question one: `held_ms`
            // records whether a human was actually blocked on this call, and replay
            // trusts what happened rather than re-litigating it. The exception is the
            // question tool: "never hold what you cannot answer" (`HoldPolicy
            // .needsAHuman`) means an unreadable `AskUserQuestion` must not open a hold
            // in REPLAY either, or a historical `held_ms > 0` would resurrect a hold
            // this build can only render as a broken Allow/Deny. So this tool re-asks
            // the same policy `DeckRuntime.handle`'s live guard asks, with
            // `questionsUnreadable`.
            opensAHold = (h.held.value ?? 0) > 0
                && (h.tool != SubjectReader.questionTool
                    || state.policy.needsAHuman(kind: h.kind, tool: h.tool,
                                                permissionMode: h.permissionMode,
                                                questionsUnreadable: h.questionsUnreadable))
        // `.permissionRequest` asks `state.policy` rather than assuming the engine
        // only sends it when it wants a human: a bypassPermissions session falsified
        // that premise (2,515 bogus holds on one such session). `transition(on:)`,
        // which decides the LANE's state, takes the same `policy` and asks the same
        // question, so the two readings cannot drift. `DeckRuntime`'s hold-opening
        // check asks `HoldPolicy.spec` directly; that is safe because `needsAHuman`
        // reads only `kind`, `tool` and `permissionMode`, never a stored budget, so
        // the answer does not depend on which policy value is asked
        // (`.prefsChanged` rebuilds `state.policy`'s budget).
        //
        // `h.permissionMode` is THIS event's claim, and a `PermissionRequest`
        // payload may omit it. `needsAHuman` would then read
        // `nil != "bypassPermissions"` as true and hold a human bypass mode never
        // asked. So fall back to `lane.permissionMode`, absorbed above from every
        // event that ever carried the field (nil leaves the slot alone): this
        // event's value when present, else the last known one, never a hardcode.
        case .permissionRequest:
            opensAHold = state.policy.needsAHuman(kind: h.kind, tool: h.tool,
                                                  permissionMode: h.permissionMode
                                                      ?? lane.permissionMode?.value)
        default:                 opensAHold = false
        }
        if let use = h.toolUseID, opensAHold {
            let id = HoldID(session: h.session, toolUseID: use)
            if state.holds[id] == nil {
                // Question budget split: the only tool `opensAHold` lets through on
                // `.preToolUse` besides the general case is `AskUserQuestion`, so this is
                // the one narrow gate `HoldPolicy.questionBudget` is read through (the same
                // `h.tool` test as `needsAHuman`). `PermissionRequest` never reaches this
                // branch with the question tool, so `state.policy.budget` is untouched for
                // every other hold.
                let budget = h.tool == SubjectReader.questionTool
                    ? state.policy.questionBudget : state.policy.budget
                state.holds[id] = Hold(id: id, openedAt: h.at, budget: budget,
                                       frontendOwned: true, armDelay: state.policy.armDelay,
                                       subject: h.subject, suggestions: h.permissionSuggestions)
                // A question call opens its takeover from the same event that opened the
                // hold. `h.questions` is empty both for an ordinary tool call and for an
                // `AskUserQuestion` the ingest layer could not fully decode
                // (`h.questionsUnreadable`): either way no `QuestionCall` opens, so a call
                // this reducer cannot populate in full never opens a takeover it can only
                // populate in part.
                if !h.questions.isEmpty {
                    let call = QuestionCall(hold: id, questions: h.questions,
                                            rawQuestions: h.rawQuestions)
                    state.questions[id] = call
                    // The mirror is born from the same event under the same guard
                    // (`state.holds[id] == nil`), so a mirror exists for every question call
                    // that opens a hold and no other. It carries a copy of the call (see
                    // `QuestionMirror`).
                    state.mirrors[id] = QuestionMirror(call: call, stage: .deckWindow)
                }
            }
        }

        // Readiness gate, first half: `released` plus a `PermissionRequest` seen.
        // `PermissionRequest` for `AskUserQuestion` carries NO `tool_use_id`
        // (confirmed across LV38), so the key is "the session this arrived on".
        // Claude Code never runs two `AskUserQuestion` calls concurrently in a
        // session, so there is at most one `.released` mirror per session. A stream
        // that violates that (hand-built or replayed only) binds to the MOST
        // RECENTLY released one and strands the older; it never binds across
        // SESSIONS.
        if h.kind == .permissionRequest, h.tool == SubjectReader.questionTool {
            let candidates = state.mirrors.filter { id, mirror in
                id.session == h.session && mirror.stage.releasedAt != nil
            }
            if let newest = candidates.max(by: { ($0.value.stage.releasedAt ?? .start) < ($1.value.stage.releasedAt ?? .start) }) {
                var mirror = newest.value
                mirror.permissionRequestSeenAt = h.at
                state.mirrors[newest.key] = mirror
            }
        }

        // Readiness gate, second half: promotes `released` to `terminalLive`. Same
        // session-scoped bound, additionally gated on `permissionRequestSeenAt`
        // being set (both halves of the pair). `notificationType` uses the same
        // `"permission_prompt"` vocabulary as `transition(on:)`; `Notification`
        // carries no `tool_name` (confirmed against LV38), so the session bound is
        // all there is.
        if h.kind == .notification, h.notificationType == "permission_prompt" {
            let candidates = state.mirrors.filter { id, mirror in
                id.session == h.session && mirror.stage.releasedAt != nil
                    && mirror.permissionRequestSeenAt != nil
            }
            if let newest = candidates.max(by: {
                ($0.value.permissionRequestSeenAt ?? .start) < ($1.value.permissionRequestSeenAt ?? .start)
            }) {
                var mirror = newest.value
                mirror.stage = .terminalLive(at: h.at)
                state.mirrors[newest.key] = mirror
            }
        }

        // `PostToolUse` retires an open question hold immediately and always closes
        // out its mirror and ledger. Two defects this fixes: an "inert hold" (a call
        // answered at the terminal sat in `state.holds` doing nothing until its
        // budget's natural expiry, the answer read by nobody) and "missing
        // resolution bookkeeping" (nothing recorded WHAT was chosen). Gated on the
        // same `SubjectReader.questionTool` fact as every other question-specific
        // branch.
        if h.kind == .postToolUse, h.tool == SubjectReader.questionTool,
           let use = h.toolUseID, !h.answers.isEmpty {
            let id = HoldID(session: h.session, toolUseID: use)
            // Origin attribution: a deck-forwarded plan, once completed, echoes back as
            // `PostToolUse` indistinguishably from a hand-typed terminal answer. The wire
            // cannot tell them apart; `forwardSentAt` is the deck's OWN record (set when
            // it completed its plan's last step). Non-nil means "a forward plan finished
            // sending and nothing has resolved this mirror since". Captured HERE, before
            // anything below touches the mirror state, so an auditor need not prove the
            // negative about every line between here and the `.resolved(...)`
            // construction.
            //
            // The one race this can lose: a hand-typed answer arriving right behind a
            // completed forward is read as the deck's. That mislabels at worst one ORIGIN
            // WORD on the card, never the answer or the chosen option (the ledger row
            // carries no origin claim).
            let wasForwardedFromTheDeck = state.mirrors[id]?.forwardSentAt != nil
            // V2 forwarding cancellation (the `cullStaleDialogKeys` class): the thing an
            // in-flight plan was aimed at no longer exists, so remaining steps must not
            // run. Unconditional on `existingHold`'s state and on
            // `mirrorAlreadyResolved` (which governs only the LEDGER's idempotency):
            // however the call got answered, a plan still mid-flight is aimed at a
            // picker Claude Code has moved past (the LV38 `race` fixture reproduces this
            // for a stray second keystroke).
            if state.forwarding[id] != nil { state.forwarding[id] = nil }
            if let existingHold = state.holds[id] {
                // The hold half is silently refused when already resolved; that is
                // `Hold.resolve`'s exactly-once rule holding, not a bug. In production this
                // is the common case: the terminal's picker cannot render until
                // `PreToolUse`'s hold has fallen through (LV38 latency-control finding), so
                // `state.holds[id]` is very likely `.release`d by the time a human answers.
                // The LV38 golden tests exercise the other branch (still open) because a
                // reducer-only test feeds no wall-clock expiry.
                if existingHold.isOpen {
                    var hold = existingHold
                    if let effect = hold.resolve(.answeredElsewhere, at: h.at) {
                        state.holds[id] = hold
                        forgetQuestion(&state, id)
                        effects.append(.updatedInput(id, answers: h.answers))
                        effects.append(effect)
                        sweepHolds(&state, at: h.at)
                    }
                }
                // Skipped when the DECK already answered this call, or when the mirror is
                // ALREADY `.resolved`. A deck answer's own `PostToolUse` echoes the identical
                // answers back, and `.questionSubmitted` already resolved the mirror and
                // wrote the ledger row. And a transport retry (`PostToolUse` twice for the
                // same call) would double the row, since the hold's outcome staying
                // `.answeredElsewhere` says nothing about whether THIS block already ran;
                // the mirror's stage is what remembers.
                //
                // Hidden dependency: this idempotency only works if a mirror exists for
                // `id`. A question hold opened without a paired mirror (impossible today:
                // the only `PreToolUse` branch that opens one also constructs one) would
                // leave `mirrorAlreadyResolved` forever false and double the row on every
                // retry (`repeatedPostToolUseIsInert` guards this). If `opensAHold` ever
                // loosens, this guard silently stops working.
                var mirrorAlreadyResolved = false
                if case .resolved? = state.mirrors[id]?.stage { mirrorAlreadyResolved = true }
                if existingHold.outcome != .updatedInput, !mirrorAlreadyResolved {
                    if state.mirrors[id] != nil {
                        state.mirrors[id]?.stage = .resolved(
                            answers: h.answers,
                            origin: wasForwardedFromTheDeck ? .deck : .terminal,
                            at: h.at)
                    }
                    lane.rememberTranscript(describeAnswers(h.answers), origin: .answeredQuestion,
                                            deckStatus: nil, actionID: nil, at: h.at, source: h.id)
                }
            }
        }

        // Retirement must not depend on `PostToolUse` alone. A session STARTED
        // before the deck asked for `PostToolUse` snapshotted its hook list at
        // launch and will never fire one (observed live: `holdExpired` release, then
        // no retirement event ever). So any hook event that PROVES the session's
        // turn moved past the question retires every mirror still
        // `.released`/`.terminalLive` for it, the same "moved on" resolution
        // `.sessionEnd` produces below.
        //
        // Qualifying: `.preToolUse` (ANY tool; see the bound below), `.postToolUse`
        // for a call that is NOT the mirror's own (different `toolUseID` or tool),
        // `.userPromptSubmit`, `.stop`, `.sessionStart` (a fresh CLI run: the old
        // picker's process is gone). Excluded: `.permissionRequest`/`.notification`
        // (the ceremony pair on a `.released` mirror PROVES a picker exists, the
        // opposite claim), and the mirror's OWN `PreToolUse` and `PostToolUse`,
        // matched by `toolUseID` and the question tool.
        //
        // The `PreToolUse` exclusion: the event that CREATED the question must never
        // be read as evidence the session moved past it. A duplicate or retried
        // `PreToolUse` with the same `toolUseID` is the same call resent; without the
        // exclusion it would retire the question's own mirror to `.movedOn`. The
        // `PostToolUse` exclusion is needed because the dedicated block above
        // resolves WITH real answers while this door only produces `answers: nil`
        // and must never race it; the tool check is redundant with the `toolUseID`
        // match today but keeps the guard from needing re-derivation if mirrors ever
        // attach to other holds.
        //
        // The bound: Claude Code batches sibling tool calls, so a `PreToolUse` for a
        // different tool can arrive within about a second of the question's, well
        // inside the 8s question budget; then the mirror is still `.deckWindow`,
        // which this block never touches. The residual: a batch straggler arriving
        // more than 8s late, after release, reads as "moved on" and resolves the
        // mirror early. Accepted: graceful degradation prefers a mirror resolved a
        // little early over one stuck answerable forever.
        let movesPastAPendingQuestion: Bool
        switch h.kind {
        case .preToolUse, .userPromptSubmit, .stop, .sessionStart:
            movesPastAPendingQuestion = true
        // Narrowed per-mirror below: the mirror's own `PreToolUse`/`PostToolUse`
        // must be excluded, and that identity is only known per hold.
        case .postToolUse:
            movesPastAPendingQuestion = true
        default:
            movesPastAPendingQuestion = false
        }
        if movesPastAPendingQuestion {
            for (id, mirror) in state.mirrors where id.session == h.session {
                if h.kind == .postToolUse, id.toolUseID == h.toolUseID,
                   h.tool == SubjectReader.questionTool {
                    continue   // the mirror's own PostToolUse — handled above
                }
                if h.kind == .preToolUse, id.toolUseID == h.toolUseID,
                   h.tool == SubjectReader.questionTool {
                    continue   // a retry of the PreToolUse that CREATED this mirror — not evidence of anything
                }
                switch mirror.stage {
                case .released, .terminalLive:
                    state.mirrors[id]?.stage = .resolved(answers: nil, origin: .movedOn, at: h.at)
                    // A plan mid-flight, or awaiting/unconfirmed, is now aimed at a picker the
                    // session has left: the same cleanup the mirror's own `PostToolUse` block
                    // performs above.
                    state.forwarding[id] = nil
                    state.mirrors[id]?.forwardSentAt = nil
                    state.mirrors[id]?.forwardUnconfirmedAt = nil
                case .deckWindow, .resolved:
                    break
                }
            }
        }

        // "The session moved on", the fourth way `MirrorStage.resolved` is reached
        // (`answers: nil`). A session that ended never answers anything further; a
        // mirror still `.released` or `.terminalLive` would claim "live in the
        // terminal" forever about a terminal that is gone. Other mirrors (already
        // `.resolved`, or `.deckWindow`, which has its own abandon path) are left
        // alone.
        //
        // Kept separate from the block above because `.sessionEnd` is not one of its
        // qualifying kinds. Resolving the mirror while leaving `state.forwarding`
        // populated would let a plan mid-flight keep typing at an ended session's
        // pane, hence the forward-state cleanup.
        if h.kind == .sessionEnd {
            for (id, mirror) in state.mirrors where id.session == h.session {
                switch mirror.stage {
                case .released, .terminalLive:
                    state.mirrors[id]?.stage = .resolved(answers: nil, origin: .movedOn, at: h.at)
                    // A plan mid-flight is aimed at a pane whose session has ENDED; without
                    // this, `runForwardPlan` re-reads a still-populated `state.forwarding` and
                    // keeps sending keystrokes at it.
                    state.forwarding[id] = nil
                    state.mirrors[id]?.forwardSentAt = nil
                    state.mirrors[id]?.forwardUnconfirmedAt = nil
                case .deckWindow, .resolved:
                    break
                }
            }
        }

        // The receipt match lives at the top of this function
        // (`isReceiptForPendingSend`); the ordering there is load-bearing.

        // Same fallback as `opensAHold`'s `.permissionRequest` case, so the two
        // verdicts cannot disagree (`transition` takes `state.policy` as a parameter
        // rather than re-reading it).
        if let next = transition(on: h, policy: state.policy,
                                 permissionMode: h.permissionMode ?? lane.permissionMode?.value),
           dominates(h.at, h.id, over: lane.stateDecidedAt.map { ($0, lane.stateSource) }) {
            lane.state = next
            lane.stateSource = h.id
            lane.stateDecidedAt = h.at
            // `LaneRecord.apiError`'s clearing rule: `transition(on:)` never RETURNS
            // `.errored` (that state arrives only via `.apiError`), so every write from
            // this gate is a move OFF it. Guarded anyway, like `acknowledge(_:as:)` and
            // the fleet apply, rather than leaning on a sibling function's behaviour.
            if next != .errored { lane.apiError = nil }
        }
        state.lanes[h.session] = lane
        followSurfaceRename(&state, from: renamedSurface.from, to: renamedSurface.to)
        // Only a session actually STARTING, and only one the deck has never seen
        // (see `seedAutoContinue` for why this trigger makes non-retroactivity,
        // relaunch safety and `/exit`-in-the-same-tab all come out right).
        //
        // `source` first, `sessionIsNew` only as a fallback. `SessionStart` fires on
        // `startup`, `resume`, `clear` and `compact`, and only the first is a
        // session beginning. "Has the deck seen this id" cannot tell them apart
        // across a RELAUNCH, where every running session is new to the deck:
        // relaunch, `claude --resume` a session a bulk "Turn Off for All Sessions"
        // had disarmed, and the default would arm it although nothing started. Every
        // recorded `SessionStart` in the live corpus carries `source`. `sessionIsNew`
        // also stops a resume or `/clear` of the same session from undoing a bulk
        // Turn Off. A payload with no `source` falls back to it rather than refusing
        // to arm.
        let began = h.source.map { $0 == "startup" } ?? sessionIsNew
        if h.kind == .sessionStart, began {
            seedAutoContinue(&state, session: h.session, surface: renamedSurface.to, at: h.at)
        } else {
            // A session placed by a LATER hook than the one it started on
            // still gets the offer it was holding.
            redeemAwaitedAutoContinue(&state, session: h.session, at: h.at)
        }
        recordCardColorIfNeeded(&state, session: h.session)
        return effects
    }

    /// nil means "hold the prior state". Absolute per kind rather than a
    /// transition table, because the recorded stream is unordered: a rule that
    /// reads the current state would reintroduce the arrival dependence that
    /// `dominates` exists to remove.
    ///
    /// `permissionMode` is the caller's resolved value (this event's, else the
    /// lane's last absorbed one), the same fallback as `opensAHold`'s
    /// `.permissionRequest` case, so a payload that omits the field cannot make
    /// the two disagree about a bypass session (see
    /// `HoldPolicy.permissionRequestAllowance`).
    ///
    /// Deliberately no `.errored` anywhere below. That state has exactly one door
    /// in, `DeckEvent.apiError`, because no hook fires when a turn dies on an API
    /// error (`DeckRuntime`'s trigger-set doc has the live probe); a hook can
    /// only move a lane OFF `.errored`.
    static func transition(on h: HookEvent, policy: HoldPolicy, permissionMode: String?) -> LaneState? {
        switch h.kind {
        case .sessionStart:     return .idle
        case .userPromptSubmit: return .working
        case .preToolUse:
            // A call the relay held is a call that waited on a human. In replay
            // that is what `held_ms` records; live, the deck decides. Absent,
            // null and 0 are kept apart at the decoder rather than here.
            return (h.held.value ?? 0) > 0 ? .needsYou : .working
        // Not always needs-you. `permission_mode` rides every payload
        // (`HookIngest.event`), and a `bypassPermissions` session gets a
        // `PermissionRequest` for every tool call while the engine auto-allows each
        // (2,515 bogus holds measured on one such session). This calls
        // `policy.needsAHuman` directly, the same call `opensAHold` makes, so the
        // two verdicts cannot disagree about one event. The event still proves the
        // session is doing something, so it moves the lane to `.working` rather than
        // holding it.
        case .permissionRequest:
            return policy.needsAHuman(kind: h.kind, tool: h.tool, permissionMode: permissionMode)
                ? .needsYou : .working
        case .postToolUse:      return .working
        // `notification_type` decides, not the hook kind. `Notification` is one wire
        // KIND for several FACTS (see `HookEvent.notificationType`); treating all as
        // needs-you lit the lamp on `idle_prompt` ("Claude finished, waiting for the
        // next prompt", the wire's own definition of idle) on every ordinary turn
        // end. Only these two values move a lane; every other value, INCLUDING
        // ABSENCE, holds the prior state (the S18 doctrine of
        // `HookKind.unrecognised`, one field down).
        case .notification:
            switch h.notificationType {
            case "idle_prompt":       return .idle
            case "permission_prompt": return .needsYou
            default:                  return nil
            }
        case .stop:             return .idle
        case .sessionEnd:       return .ended
        case .unrecognised:     return nil
        }
    }

    // ------------------------------------------------------------- statusline
    private static func apply(_ state: inout DeckState, _ p: StatuslinePayload,
                              at: Instant, id: EventID) {
        // The no-synthesised-lane rule admits a statusline as a lane's origin, so
        // it must refuse a deleted one too or the lane walks back in through a
        // second door.
        guard !state.prefs.deleted.contains(p.session.raw) else { return }
        // A statusline for a session the deck never heard start is still a received
        // record, so the lane is real, not synthesised from nothing.
        var lane = state.lanes[p.session] ?? LaneRecord(
            session: p.session, firstSeenAt: at, lastEventAt: at,
            state: .working, stateSource: id, stateDecidedAt: at,
            fleetState: .absent, waitingFor: .absent, isBackground: false,
            contextPercent: .absent, contextSource: nil, contextDecidedAt: nil)

        lane.firstSeenAt = min(lane.firstSeenAt, at)
        lane.lastEventAt = max(lane.lastEventAt, at)

        // A null or missing percentage says NOTHING: it neither fabricates a zero
        // nor erases the last-known reading, and does not touch the staleness clock
        // (`contextDecidedAt` stays the value's own event time), so a chatty but
        // null feed cannot keep a dead reading looking fresh. Only a payload
        // CARRYING a value writes the slot.
        if p.contextPercent.isPresent,
           dominates(at, id, over: lane.contextDecidedAt.map { ($0, lane.contextSource ?? id) }) {
            lane.contextPercent = p.contextPercent
            lane.contextSource = id
            lane.contextDecidedAt = at
        }
        state.lanes[p.session] = lane

        // The account's rate windows. A payload with none says nothing about the
        // slot (the absent-vs-empty rule `absorb` holds); one with windows
        // supersedes by event time like every fed value.
        if !p.rateLimits.isEmpty,
           dominates(at, id, over: state.usage.map { ($0.decidedAt, $0.source) }) {
            state.usage = Sourced(value: p.rateLimits, source: id, decidedAt: at)
        }
    }

    // ------------------------------------------------------------------ fleet
    private static func apply(_ state: inout DeckState, _ rows: [FleetRow],
                              at: Instant, id: EventID) {
        for row in rows {
            guard let session = row.session else { continue }   // the no-synthesised-lane rule
            guard !state.prefs.deleted.contains(session.raw) else { continue }
            // A fleet row OPENS a lane. The no-synthesised-lane rule admits a fleet row
            // as an origin, which is what makes the deck pull-capable: started after
            // your sessions, it knows them before they next speak. The lane carries the
            // row's own provenance and nothing invented; `cwd` comes with it, the one
            // thing a discovered lane can say before a hook arrives.
            let discovered = state.lanes[session] == nil
            var lane = state.lanes[session] ?? LaneRecord(
                session: session, firstSeenAt: at, lastEventAt: at,
                state: .idle, stateSource: id, stateDecidedAt: at,
                fleetState: .absent, waitingFor: .absent, isBackground: row.kind == "background",
                contextPercent: .absent, contextSource: nil, contextDecidedAt: nil)
            // `Redacted(optional:)`, not the raw initialiser: a row whose `cwd` is empty
            // or whitespace must yield NO directory, as the hook path does. A
            // non-nil-but-empty directory would pass every `!= nil` gate (the
            // card-colour row's, say) while failing every `!dir.isEmpty` write guard
            // behind it, a control that renders but cannot act.
            if lane.cwd == nil, let cwd = Redacted(optional: row.cwd) {
                lane.cwd = Sourced(value: cwd, source: id, decidedAt: at)
            }
            lane.lastEventAt = max(lane.lastEventAt, at)
            lane.fleetState = row.state
            // Unconditional, like `fleetState`, but only for a session this poll names:
            // absent CLEARS the slot, because a closed dialog stops being reported. A
            // roster that omits the session's row ENTIRELY never reaches this line and
            // leaves the last value standing (the partial-roster reality the tombstone
            // code guards with three consecutive misses, see DeckRuntime). So a consumer
            // of `waitingFor` may only trust it while the lane still holds the state
            // that justified it.
            lane.waitingFor = row.waitingFor.map { Fed<String>.value($0) } ?? .absent
            lane.isBackground = lane.isBackground || row.kind == "background"
            // The fleet feed moves a background lane, and is the only thing that can
            // move a lane whose session has no hooks installed. `state` speaks for
            // background rows and `status` for interactive ones (S7/S9/S18: two optional
            // keys, one shape). A state nobody has seen moves nothing.
            // `isWaitingOnHuman` outranks working/busy: it is the more specific fact (a
            // session can read "busy" with a spinner while a permission dialog sits on
            // top).
            let proposed: LaneState? = row.isFailing ? .errored
                : row.isWaitingOnHuman ? .needsYou
                : (row.isWorking || row.isBusy) ? .working
                : row.isIdle ? .idle : nil
            // A poll may not carry a lane off .needsYou over an OPEN hold, whatever key
            // said so. The guard sits on the OUTCOME so no future key can bypass it
            // (l19_8 exercises both keys). The fleet cannot see a dialog on every poll,
            // so a hold that IS open keeps a needs-you lane immune: a human mid-decision
            // on the deck must not have the card pulled away by a five-second guess. But
            // needs-you residue left by an expired hold, a terminal answer, or no hold
            // at all (a lane discovered already amber, or raised holdless by a
            // Notification `permission_prompt`) is what the poll may correct, now that
            // it reads `waitingFor` (LV36; LV34 shows the key alone suffices).
            //
            // The correction is narrower than the raise: a holdless needs-you lane may
            // be demoted only by an IDLE row, never a busy one. `idle` is the fleet's
            // definition of "the turn ended", which excludes an open dialog. `busy` is
            // the ambiguity `waiting`/`waitingFor` exists to resolve (a spinner with a
            // dialog on top), and a fleet CLI predating that vocabulary (S7/S9-era) must
            // not erase a real dialog's amber every five seconds. Idle and working lanes
            // keep full movability.
            //
            // .errored is exempt in one direction only: the fleet owns a background
            // failure, so `blocked` may raise a lane but not lower one.
            let openHold = state.holds.values.contains { $0.id.session == session && $0.isOpen }
            let holdlessNeedsYou = lane.state == .needsYou && !openHold
            let movable = lane.state == .idle || lane.state == .working
                || (holdlessNeedsYou && proposed == .idle)
            let next: LaneState? = (movable || proposed == .errored) ? proposed : nil
            // `discovered ||` because the row that OPENED the lane is its origin, and
            // the .idle it was constructed with is a placeholder, not a decided state;
            // same-instant dominance would refuse it and a session discovered mid-build
            // would read idle until the next beat (l19_7).
            if let next,
               discovered || dominates(at, id, over: lane.stateDecidedAt.map { ($0, lane.stateSource) }) {
                lane.state = next
                lane.stateSource = id
                lane.stateDecidedAt = at
                // `LaneRecord.apiError`'s clearing rule, the fleet path's copy of the guard
                // the hook gate and `acknowledge(_:as:)` hold to. The one direction that
                // leaves text standing: `next == .errored` (the fleet's own failure report)
                // writes over whatever `apiError` held, safe because the other two sites
                // guarantee it is `nil` by the time a fleet failure reaches a lane that
                // moved on from a transcript-learned one.
                if next != .errored { lane.apiError = nil }
            }
            state.lanes[session] = lane
            // A discovered lane's `cwd` is often the FIRST directory learned for it
            // (found by the fleet poll before any hook). `recordCardColorIfNeeded`'s own
            // guard makes this free for rows that carry nothing new.
            recordCardColorIfNeeded(&state, session: session)
        }
    }
}
