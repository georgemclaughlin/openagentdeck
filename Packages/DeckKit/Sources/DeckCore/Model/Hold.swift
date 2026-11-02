//
//  Hold.swift · DeckCore/Model
//
//  The approval hold, as data.
//
//  The reducer never performs an action, it returns a list of them. That is
//  what makes the hold's invariants properties of a list rather than of thread
//  schedules:
//
//    exactly-once          effects.filter { $0.resolves(hold) }.count == 1
//    correlation           the effect names the hold that was tapped
//    release is not deny   two distinct cases in one enum
//
//  No mocks, no async, no flakiness: a fuzz over arrival/tap/timeout orderings
//  is a finite set of orderings on one queue.
//

/// A hold is identified by the pair the wire gives us, and by nothing else.
///
/// The correlation rule's falsifier is "a resolution effect whose hold ID ≠ the
/// ID of the tapped takeover". A value type carrying both halves means a
/// decision cannot be written to the wrong hold through an index that moved (an
/// early prototype overwrote a decision timestamp when a second `applyHook`
/// arrival came in).
public struct HoldID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let session: SessionID
    public let toolUseID: String
    public init(session: SessionID, toolUseID: String) {
        self.session = session; self.toolUseID = toolUseID
    }
    public var description: String { "\(session.raw)/\(toolUseID)" }
}

/// The ways a hold can end.
///
/// **`allowAndRemember` is not a synonym for `.allow`.** Claude Code's
/// permission dialog offers three answers ("1. Yes", "2. Yes, and don't ask
/// again for: X", "3. No"), and this is the middle one. It carries the INDEX of
/// the chosen suggestion into `Hold.suggestions`, the raw array recorded at
/// open time: `Resolution` is reducer-owned data, the suggestion is
/// engine-owned, and `HookResponse.decision`'s `suggestions` parameter reunites
/// them. `Hold.resolve`'s arm-delay guard names the outcomes it exempts
/// (release, expire, answeredElsewhere) rather than `.allow`, so this case
/// needs no special handling there.
///
/// The associated value rules out a `String` raw type and synthesised
/// `CaseIterable`; `CaseIterable` is written by hand below with a
/// representative index, which is all anything reading `allCases` needs (a
/// count of outcomes, or one instance per case).
///
/// **Release-without-decision is not deny.** A frontend-owned timeout releases
/// the call and lets the engine's own policy decide; a headless one denies. The
/// spike measured both (S5, S5b). Collapsing them into one "timed out" is a
/// one-word change that silently turns "I did not answer" into "I said no".
///
/// **Not `Codable`.** Nothing persists a `Resolution`; it lives on
/// `Hold.outcome` in memory and travels as an `Effect`, and neither is
/// `Codable`. Synthesised `Codable` for a case with an associated value
/// encodes `{"allowAndRemember":{"suggestionIndex":N}}`, a shape nobody chose
/// that would become a wire format by default the day something persists a
/// `Resolution`.
public enum Resolution: Equatable, Sendable {
    case allow
    case deny
    case updatedInput
    /// The deck stops holding; the terminal owns the call from that instant.
    case release
    /// The budget ran out with no frontend to fall through to.
    case expire
    /// Allow, plus "apply suggestion N" — echoing `permission_suggestions[N]`
    /// back on the wire as `updatedPermissions` IS clicking Claude Code's own
    /// option 2. Reachable only through `DecisionBar`'s suggestion buttons,
    /// which only render when the hold's suggestions are non-empty — so this
    /// case never arrives for a `PreToolUse`-kind hold in production (those
    /// are `AskUserQuestion` calls, which carry no suggestions at all).
    case allowAndRemember(suggestionIndex: Int)
    /// A question hold retired by the terminal's own answer rather than the
    /// deck's: a `PostToolUse` for this hold's `tool_use_id` arrived carrying the
    /// chosen answers while the hold was still open. Without it, a call answered
    /// at the terminal sat in `state.holds` until its budget expired and the answer
    /// went nowhere. Distinct from `.updatedInput` (the deck's own mirror chose)
    /// and from `.release` (the deck gave up): the deck did not decide, and it is
    /// not blind either. The answers travel via `Effect.updatedInput` alongside the
    /// `.resolveHold` this produces, not as an associated value; see `DeckState`'s
    /// `.postToolUse` handling.
    case answeredElsewhere
}

extension Resolution: CaseIterable {
    /// **Pinned to `logWord`'s switch by hand, with no help from the compiler.**
    /// `logWord` has no `default:`, so a case added to `Resolution` without an arm
    /// there is a compile error. This list is data, not a switch: a case added
    /// without also adding it HERE compiles cleanly and `allCases` silently
    /// under-counts. Update both on every new case. `suggestionIndex: 0` is a
    /// representative value, not a meaningful one.
    public static let allCases: [Resolution] = [
        .allow, .deny, .updatedInput, .release, .expire,
        .allowAndRemember(suggestionIndex: 0), .answeredElsewhere,
    ]
}

public extension Resolution {
    /// A word for logs and comments. Never the wire's own vocabulary — that
    /// lives in `HookResponse.decision`, which answers a narrower question
    /// (the wire's `behavior`/`permissionDecision`, not the reducer's
    /// outcome) and does not agree with this one for `allowAndRemember`.
    var logWord: String {
        switch self {
        case .allow: "allow"
        case .deny: "deny"
        case .updatedInput: "updatedInput"
        case .release: "release"
        case .expire: "expire"
        case .allowAndRemember(let index): "allowAndRemember(\(index))"
        case .answeredElsewhere: "answeredElsewhere"
        }
    }
}

public struct TimerID: Hashable, Codable, Sendable {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
}

/// What the reducer asks the world to do. Data, never an action.
public enum Effect: Equatable, Sendable {
    case resolveHold(HoldID, Resolution)
    case schedule(TimerID, after: Millis)
    case cancel(TimerID)
    /// The preview-then-commit rule is an ordering rule over these two: no
    /// commit may appear without a preceding *confirmed* preview of the same
    /// diff.
    case previewConfigWrite(ConfigDiff)
    case commitConfigWrite(ConfigDiff)
    /// The answers to a question call, all of them. The all-or-nothing rule's
    /// falsifier is an `updatedInput` whose answers do not cover the call's
    /// questions with the call not abandoned, so the answers travel with the
    /// effect.
    ///
    /// `[Answer]` rather than `[Int]`: the wire keys each answer by the
    /// question's own text and values it with the selected option's label, and a
    /// multi-select question takes several labels. Positional indices could
    /// express neither. See `Answer`.
    case updatedInput(HoldID, answers: [Answer])
    case log(String)

    public func resolves(_ id: HoldID) -> Bool {
        if case .resolveHold(let h, _) = self { return h == id }
        return false
    }

    public var resolution: (HoldID, Resolution)? {
        if case .resolveHold(let h, let r) = self { return (h, r) }
        return nil
    }
}

public struct Hold: Equatable, Sendable {
    public let id: HoldID
    public let openedAt: Instant
    /// How long this hold waits before the deck lets it go. `nil` is
    /// `HoldBudget.untilAnswered` carried down from `HoldPolicy` at the
    /// instant this hold opened — not a duration nobody chose, an honest
    /// "no limit" that `expiresAt` below reads the same way.
    public let budget: Millis?
    /// True when a terminal is waiting on the other end. Decides which of
    /// the release-is-not-deny rule's two outcomes a timeout produces.
    public let frontendOwned: Bool
    /// Nothing can land before the takeover has settled. The arm-delay rule
    /// measures the arm delay from *animation settle*, not from event
    /// arrival, so this is a stored instant rather than a duration added at
    /// the point of decision.
    public let armedAt: Instant
    public private(set) var outcome: Resolution?
    /// What this hold is **about** — the thing the user is being asked to allow
    /// or deny. Carried on the hold rather than looked up beside it, because a
    /// decision control and its subject appearing in the same frame is the whole
    /// content of the legibility rule, and two parallel dictionaries are two
    /// things that can disagree.
    ///
    /// Optional because a hold can be opened by a payload the deck could not
    /// read. That case renders as an explicit "subject unavailable" — never as
    /// an armed control with a blank well.
    public let subject: Subject?
    /// `permission_suggestions`, verbatim, from the event that opened this
    /// hold — Claude Code's own option 2, one element per standing-permission
    /// offer. `HookEvent.permissionSuggestions`'s doc comment is the reason
    /// this is a raw `JSONValue?` and not a typed array: the shape is
    /// engine-owned, and the deck's only use of an element is echoing it back
    /// unmodified. nil for a `PreToolUse` hold (an `AskUserQuestion` call),
    /// and for a `PermissionRequest` the engine sent with none.
    public let suggestions: JSONValue?

    public init(id: HoldID, openedAt: Instant, budget: Millis?,
                frontendOwned: Bool, armDelay: Millis, subject: Subject? = nil,
                suggestions: JSONValue? = nil) {
        self.id = id
        self.openedAt = openedAt
        self.budget = budget
        self.frontendOwned = frontendOwned
        self.armedAt = openedAt.advanced(by: armDelay)
        self.outcome = nil
        self.subject = subject
        self.suggestions = suggestions
    }

    public var isOpen: Bool { outcome == nil }
    /// `nil` when this hold's budget is `.untilAnswered` — the fall-through
    /// rule's "no expiry" reading, not `.distantFuture` wearing a number.
    /// `frame.decisions`'s filter treats a `nil` here as always-actionable
    /// while the hold is open; `DeckRuntime` schedules no expiry timer for
    /// one at all rather than sleeping on a sentinel duration.
    public var expiresAt: Instant? { budget.map(openedAt.advanced(by:)) }

    /// The single place an outcome is ever written.
    ///
    /// Returns the effect to emit, or nil when nothing should happen — an
    /// already-resolved hold, or a decision that arrived before the arm delay.
    /// The exactly-once rule is this method: there is no second writer.
    mutating func resolve(_ r: Resolution, at: Instant) -> Effect? {
        guard outcome == nil else { return nil }        // the exactly-once rule
        // A touch beginning before settle cannot land. Timeouts are not touches and
        // are exempt, and so is `.answeredElsewhere`: it is a fact arriving from the
        // TERMINAL, not a tap on a not-yet-settled takeover. The LV38 race fixture
        // shows a second keystroke landing well inside one armDelay of the first, so
        // an answer that fast is real.
        if r != .release, r != .expire, r != .answeredElsewhere, at < armedAt { return nil }
        outcome = r
        return .resolveHold(id, r)
    }

    /// After fall-through the deck never renders an actionable control
    /// for this hold again. The terminal is sole authority from that instant.
    public var isActionable: Bool { isOpen }
}

/// A standing permission rule the deck created.
///
/// Rules are enumerable and revocable **in-app**, with their scope
/// shown — "a rule the user cannot find is a rule they cannot revoke". So the
/// store is deck state rather than a fact about a file, and `scope` is a field
/// rather than a convention.
public struct PermissionRule: Equatable, Sendable, Identifiable {
    public enum Scope: String, Equatable, Codable, Sendable {
        /// Created by a long-press on the strip. Lives in the deck's own memory
        /// and dies with the session.
        case session
        /// Made in the settings window under preview-then-commit.
        case durable
    }
    public let id: String
    public let tool: String
    public let scope: Scope
    public let createdAt: Instant
    public init(id: String, tool: String, scope: Scope, createdAt: Instant) {
        self.id = id; self.tool = tool; self.scope = scope; self.createdAt = createdAt
    }
}

/// Durations that are specifications, gathered so that changing one is a diff
/// rather than a search.
public struct HoldPolicy: Equatable, Sendable {
    /// `nil` is `HoldBudget.untilAnswered` — the user-configurable other end of
    /// the picker in Settings, where `.seconds(n)` becomes `Millis`.
    ///
    /// **`Millis?` over a `Millis` plus a `holdsForever: Bool`.** The two-field
    /// shape needs a placeholder `budget` while holding forever, and the two could
    /// disagree. `nil` IS the answer "no limit". Every consumer (`Hold.expiresAt`,
    /// the countdown, curl's `--max-time`, the engine's per-command `timeout`)
    /// already branches on "budget or no budget", so the optional costs nothing at
    /// call sites.
    public var budget: Millis?
    /// **`budget`'s twin for `AskUserQuestion` holds**, read at the same
    /// hold-construction sites and gated on the same
    /// `h.tool == SubjectReader.questionTool` fact `needsAHuman` asks. `nil` is
    /// `.untilAnswered` here too (see `budget`). Defaulted to `nil` in `init` so
    /// existing `HoldPolicy(budget:armDelay:reArmDelay:)` call sites that are not
    /// about question holds keep compiling; `.spec` sets it explicitly.
    public var questionBudget: Millis?
    public var armDelay: Millis
    public var reArmDelay: Millis
    /// Standing policy requires a **sustained** gesture. A single tap
    /// can never create a rule of any kind, and the boundary is a number rather
    /// than a feeling.
    public var longPress: Millis

    /// **The readiness gate's bounded allowances.** A `.released` mirror advances
    /// to `.terminalLive` through the ceremony pair (`PermissionRequest` then
    /// `Notification`), but the ceremony is optional: the `multiselect-two-picks`
    /// fixture never sent a `Notification`, yet a human still answered it. Without
    /// a deadline such a mirror stayed "Live in the terminal" with options grayed,
    /// forever.
    ///
    /// Two allowances, because the two failure shapes carry different proof.
    /// `permissionRequestAllowance` is for a mirror that DID see half the ceremony:
    /// a `PermissionRequest` naming the question tool is strong evidence the
    /// terminal picker exists (`MirrorStage.terminalLive`). LV38
    /// `question-mirror-latency-control` recorded `PermissionRequest` at
    /// 12:06:05.407Z and `Notification` 6.021 s later; 7 s rounds that up with
    /// margin.
    ///
    /// `noSignalAllowance` is the catch-all for a `.released` mirror that has seen
    /// NEITHER half, anchored to release because there may never be a signal. The
    /// same fixture's full ceremony, release to `Notification`, took 18.054 s,
    /// rounded up to 20 s. A zero-signal mirror gets no less patience than one that
    /// eventually proved itself through the front door, and is not owed more.
    ///
    /// **Both are read together in `DeckRuntime.scheduleReadinessWatch()`: the
    /// effective deadline is the EARLIER of `releasedAt + noSignalAllowance` and
    /// (once seen) `permissionRequestSeenAt + permissionRequestAllowance`.** A late
    /// `PermissionRequest` must never grant more total patience than no signal at
    /// all; the shorter allowance is a bonus for early proof, not a second wait
    /// stacked on the first.
    ///
    /// Short allowances are safe because of `forwardLandingAllowance`: a tap that
    /// lands on a picker not yet there is recoverable, not silent.
    public var permissionRequestAllowance: Millis = Millis(7_000)
    /// See `permissionRequestAllowance`'s own doc comment for the shared
    /// derivation.
    public var noSignalAllowance: Millis = Millis(20_000)
    /// **The gap between the screen reads `DeckRuntime.attemptScreenObservation`
    /// takes** (`screenObservationAttempts` of them, 0/3/6/9 s; that constant's doc
    /// derives the count from the picker's measured ~7 s render lag). Not
    /// fixture-derived: it paces a local retry against a terminal that is about to
    /// render the picker or already has. It lives here rather than as a runtime
    /// constant so a shortened test policy can collapse it; a real 3 s wait per
    /// released mirror, multiplied across every test that reaches `.released`, is a
    /// cost `HoldBudgetRuntimeTests` accepts in one place only.
    public var screenObservationRetryDelay: Millis = Millis(3_000)

    /// **What makes the two allowances above safe to keep short: a forwarded
    /// plan's own bounded landing check.** A successfully sent step is not proof
    /// the terminal acted on it (cmux reports wire-level delivery, never the
    /// engine's reaction), so `DeckRuntime` starts this clock when the LAST step of
    /// a plan reports `.sent` (`QuestionMirror.forwardSentAt`), and if nothing has
    /// resolved the mirror when it elapses, `QuestionMirror.forwardUnconfirmedAt`
    /// records that. The deck can confirm a landing but never its absence, so it
    /// says "No confirmation yet" and offers an explicit "Send again" rather than
    /// claiming a failure; claiming "didn't land" when the tap HAD landed invited a
    /// duplicate send.
    ///
    /// **5 s, against a measured floor two orders of magnitude smaller.**
    /// `LV38-question-mirror-race` and `…-digit-answered/other-freetext` recorded
    /// keystroke-to-`PostToolUse` gaps of 0.356 s and 0.420 s once input reached a
    /// live picker. 5 s is slack, not a tuned SLA: past cmux's round trip and the
    /// engine's processing, yet short enough that an unconfirmed tap does not sit
    /// silently answerable (which made the mirror re-tappable during the window
    /// that caused the duplicate send).
    public var forwardLandingAllowance: Millis = Millis(5_000)

    /// **How long a `.resolved` mirror keeps PROJECTING.** Without a limit the
    /// resolved card sat in the band's act zone indefinitely, hiding the transcript
    /// well beneath it, which already carries the same answer as a ledger row.
    /// Previously only `sweepHolds` cleared it from `Frame.mirrors`, after
    /// `HoldPolicy.memory` (20 minutes) and only once `holds.count` crossed
    /// `sweepAbove`. The card's job is the first glance, not a standing record.
    ///
    /// Not fixture-derived; like `screenObservationRetryDelay` it is an interactive
    /// default: long enough to read a checkmark and the chosen label at a glance,
    /// short enough that the well returns before attention moves elsewhere.
    ///
    /// **Read at the PROJECTION layer only** (`Projection.frame`'s `mirrors`
    /// filter). `state.mirrors` keeps the resolved entry until `sweepHolds`
    /// reclaims it with its hold. Deleting it early would break
    /// `repeatedPostToolUseIsInert` (`mirrorAlreadyResolved` reads
    /// `state.mirrors[id]?.stage` to refuse a doubled ledger row on a transport
    /// retry): this field changes what is SHOWN, never what is REMEMBERED.
    public var resolvedMirrorLinger: Millis = Millis(5_000)
    /// **How long a resolved hold is remembered.**
    ///
    /// A resolved hold is kept rather than deleted, and that is deliberate:
    /// `state.holds[id] == nil` is the guard that stops a retried hook from
    /// reopening a call somebody has already answered, so forgetting one
    /// immediately would let the same tool call be decided twice.
    ///
    /// Keeping them FOREVER is what that turned into. `decisions` filters
    /// every hold on every projection, so a deck running for days paid for
    /// every permission it had ever answered on every frame it drew — measured
    /// at 22 us per frame with none and 356 us with two hundred, growing
    /// without bound. Memory was the smaller half.
    ///
    /// Twenty minutes is generous by orders of magnitude against the thing it
    /// guards. A transport retry arrives within seconds of the original; a
    /// duplicate arriving twenty minutes later is not a retry, it is a new
    /// call that deserves a new decision.
    public var memory: Millis = Millis(20 * 60 * 1000)

    /// The count past which resolved holds get swept. Amortised rather than
    /// per-resolution: sweeping on every decision would make each one O(holds)
    /// to save memory nobody is short of yet.
    public static let sweepAbove = 256

    public init(budget: Millis?, questionBudget: Millis? = nil, armDelay: Millis, reArmDelay: Millis,
                longPress: Millis = Millis(600)) {
        self.budget = budget; self.questionBudget = questionBudget; self.armDelay = armDelay
        self.reArmDelay = reArmDelay; self.longPress = longPress
    }

    /// **Which calls need a human — asked of the engine, not of a list here.**
    ///
    /// A fixed set of tool names (`Bash, Write, Edit, ...`) was measured to be
    /// wrong: in one real session 94 % of the 389.7 s the deck spent blocking a
    /// person was on `pwd`, `ls`, `find`, `git log` and `git show`, read-only
    /// commands Claude Code auto-approves and never shows a dialog for. The deck
    /// was inventing a gate the engine never wanted, and the graceful-degradation
    /// rule says no session is ever worse off because the deck exists. A supervisor
    /// that stops you for `pwd` is the one you learn to tap through.
    ///
    /// So the rule is a question put to the engine:
    ///
    ///   `PermissionRequest`  the engine is about to show a dialog. That IS the
    ///                        deck's whole subject, and it fires only for calls
    ///                        a human would really have been asked about.
    ///   `AskUserQuestion`    a question is a request for the user by
    ///                        definition, and arrives on `PreToolUse`.
    ///
    /// **`PermissionRequest` fires for calls nobody is asked about too.** Under
    /// `bypassPermissions` the engine still sends a `PermissionRequest` per tool
    /// call while auto-allowing each one (2,515 bogus holds on one bypass session,
    /// CLI 2.1.223). bypass auto-answers PERMISSIONS, not QUESTIONS: an
    /// `AskUserQuestion` still outranks it, since a real question has no
    /// engine-side answer to fall back on. So `PermissionRequest` also needs
    /// `permission_mode`, and the tool name still needs no list.
    ///
    /// Everything else is observed and waved through.
    ///
    /// **Never hold what you cannot answer.** An `AskUserQuestion` the ingest layer
    /// could not decode (`questionsUnreadable`) must not open a hold: the deck
    /// would block the terminal for up to the full budget and could only show a
    /// broken surface. Such a call answers `{}` instantly, so the terminal shows
    /// the question with no deck-added delay. Defaulted to `false` because only the
    /// two callers that gate a question call (the reducer's `opensAHold` for
    /// `.preToolUse`, and `DeckRuntime.handle`'s live guard) ask about a `kind`
    /// this fact can change.
    public func needsAHuman(kind: HookKind, tool: String?, permissionMode: String?,
                            questionsUnreadable: Bool = false) -> Bool {
        switch kind {
        case .permissionRequest: return permissionMode != "bypassPermissions"
        case .preToolUse:        return tool == SubjectReader.questionTool && !questionsUnreadable
        default:                 return false
        }
    }

    public static let spec = HoldPolicy(budget: Millis(120_000),
                                        questionBudget: Millis(8_000),
                                        armDelay: Millis(250),
                                        reArmDelay: Millis(400),
                                        longPress: Millis(600))
}
