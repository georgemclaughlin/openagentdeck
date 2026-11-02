//
//  Diagnostics.swift · DeckCore/Model
//
//  Diagnostics are redacted **by construction**, not filtered
//  afterwards.
//
//  Any artefact the app can emit must be designed to exclude payload content
//  (a past screen recording captured an unrelated private window).
//
//  A filter is a list of things someone remembered. A type that cannot hold the
//  payload in the first place is not a list — there is no field to forget.
//

/// Something worth recording about a session, carrying no payload.
///
/// Every field here is either an identifier the deck already displays, an enum,
/// or a number. There is deliberately no `String` field a caller could pass a
/// command, a path or a prompt into: the falsifier is "exported diagnostics
/// containing a payload command string", and the way to make that unobservable
/// is to leave nowhere for one to go.
public struct Diagnostic: Equatable, Sendable {
    public enum Kind: String, Equatable, Codable, Sendable {
        case sessionOpened, sessionClosed
        case holdOpened, holdResolved, holdExpired
        case feedStalled, decodeUnrecognised
        case configPreviewed, configCommitted
        /// Question-mirror diagnostics, so a mirror stuck `.released` leaves a
        /// line of its own instead of an absence a reader has to notice.
        ///
        /// `forwardUnconfirmed`, not `forwardDidNotLand`: the deck can confirm a
        /// landing (`PostToolUse`) but never a non-landing, since absence of
        /// proof is not proof of absence. A "didn't land" claim once invited a
        /// duplicate tap on an answer that had landed.
        case mirrorReadinessElapsed, mirrorObservedLive, forwardUnconfirmed
    }
    public let kind: Kind
    public let at: Instant
    public let session: SessionID?
    /// The tool's *name* — `Bash`, `Read` — never its input. The name is on
    /// screen already; the input is the thing the takeover exists to show once
    /// and never store.
    public let toolName: String?
    public let outcome: Resolution?

    public init(kind: Kind, at: Instant, session: SessionID? = nil,
                toolName: String? = nil, outcome: Resolution? = nil) {
        self.kind = kind; self.at = at; self.session = session
        self.toolName = toolName; self.outcome = outcome
    }

    /// One line, and it can only be built from the fields above.
    public var line: String {
        var parts = ["\(at.sinceStart.raw)ms", kind.rawValue]
        if let session { parts.append("session=\(session.raw)") }
        if let toolName { parts.append("tool=\(toolName)") }
        if let outcome { parts.append("outcome=\(outcome.logWord)") }
        return parts.joined(separator: " ")
    }
}

public enum DiagnosticExport {
    /// The whole exportable artefact. Built only from `Diagnostic`, so there is
    /// no path by which a command string reaches it.
    public static func export(_ entries: [Diagnostic]) -> String {
        entries.map(\.line).joined(separator: "\n")
    }

    /// Build the log from what actually happened. The events carry payload —
    /// this is the boundary where it stops.
    ///
    /// `effects` carries what the reducer actually decided, alongside the event
    /// that asked it. Some outcomes (`.release` vs `.deny`, from
    /// `hold.frontendOwned`) are not on the triggering `DeckEvent`, only in what
    /// the reducer returned, so without `effects` the line could not say which
    /// happened. Defaulted to `[]` so a bare function reference to this method
    /// still compiles; Swift does not partially apply default arguments.
    public static func record(_ event: DeckEvent, effects: [Effect] = []) -> Diagnostic? {
        switch event {
        // Silent: `Diagnostic` has no free-text field, and no kind fits "a
        // setting changed"; the log is about sessions and holds.
        case .autoContinueSetForAll: return nil
        case .hook(let h):
            switch h.kind {
            case .sessionStart: return Diagnostic(kind: .sessionOpened, at: h.at, session: h.session)
            case .sessionEnd:   return Diagnostic(kind: .sessionClosed, at: h.at, session: h.session)
            case .preToolUse:
                return Diagnostic(kind: .holdOpened, at: h.at, session: h.session, toolName: h.tool)
            case .postToolUse:
                // Only when this `PostToolUse` actually retired a hold (the
                // question-mirror's `.answeredElsewhere` path). Every other
                // `PostToolUse` touches nothing here, matching the reducer.
                guard let use = h.toolUseID else { return nil }
                let id = HoldID(session: h.session, toolUseID: use)
                guard let outcome = effects.first(where: { $0.resolves(id) })?.resolution?.1
                else { return nil }
                return Diagnostic(kind: .holdResolved, at: h.at, session: h.session,
                                  toolName: h.tool, outcome: outcome)
            case .unrecognised:
                // Not even the unrecognised *value* — an arbitrary string from
                // the wire is exactly the kind of thing that turns out to have
                // been a path.
                return Diagnostic(kind: .decodeUnrecognised, at: h.at, session: h.session)
            default: return nil
            }
        case .decision(let id, let r, let at):
            return Diagnostic(kind: .holdResolved, at: at, session: id.session, outcome: r)
        case .holdExpired(let id, let at):
            // Read the resolution the reducer actually produced (`.release` for
            // every hold built here, `.deny` for the headless branch;
            // `Hold.resolve` documents both) off `effects`.
            let outcome = effects.first(where: { $0.resolves(id) })?.resolution?.1
            return Diagnostic(kind: .holdExpired, at: at, session: id.session, outcome: outcome)
        case .configRequested:  return Diagnostic(kind: .configPreviewed, at: .start)
        case .configConfirmed:  return Diagnostic(kind: .configCommitted, at: .start)
        case .restart(let at):  return Diagnostic(kind: .sessionClosed, at: at)
        case .mirrorReadinessElapsed(let id, let at):
            return Diagnostic(kind: .mirrorReadinessElapsed, at: at, session: id.session)
        case .mirrorObservedLive(let id, let at):
            return Diagnostic(kind: .mirrorObservedLive, at: at, session: id.session)
        case .forwardUnconfirmed(let id, let at):
            return Diagnostic(kind: .forwardUnconfirmed, at: at, session: id.session)
        case .questionSubmitted(let id, _, let at):
            return Diagnostic(kind: .holdResolved, at: at, session: id.session, outcome: .updatedInput)
        case .questionAbandoned(let id, let at):
            // As `.holdExpired`: a dismissal resolves its hold to `.release`
            // (`DeckState`), and that outcome is read off `effects`.
            let outcome = effects.first(where: { $0.resolves(id) })?.resolution?.1
            return Diagnostic(kind: .holdResolved, at: at, session: id.session, outcome: outcome)
        case .statusline, .fleet, .promote, .promoteNext, .gesture, .revokeRule,
             .worktree,
             // An address is a path through somebody's terminal, so it never
             // reaches a diagnostic (as `host` does not from a hook).
             .located,
             .questionOpened,
             // A pick, a commit and a step back are steps through a takeover,
             // not outcomes. Only the submission that reaches the wire earns a
             // line, and the redaction rule keeps it from naming the option.
             .questionPicked, .questionCommitted, .questionSteppedBack,
             // A typed answer carries a person's own words verbatim, which a
             // diagnostic line may never quote.
             .questionAnsweredFreely,
             // `ForwardPlan.steps` is literal keystroke bytes, including typed
             // "Other" text verbatim. The forward step/cancel events name no
             // content but stay out with their sibling: "something moved" is
             // not a useful export line.
             .forwardPlanStarted, .forwardStepSent, .forwardPlanCancelled,
             // A display move: it clears a mark and names no content.
             .forwardRearmed,
             // Selection and dismissal are display moves. A queued or sent action
             // carries the user's own words (quick-action text may reach the
             // frame and screen but never a log or export), so the whole event
             // stays out. `.transcriptSeeded`, `.apiError` and `.recap` carry
             // text read off a session's transcript (a recap is Claude Code's
             // prose about the conversation); the export stays payload-free by
             // construction, with no exception for payload that happens to be
             // safe.
             .sessionSelected, .actionQueued, .actionSent, .transcriptSeeded, .apiError, .recap, .dismissRequested,
             // A delete does nothing to a session (the process keeps running), and
             // the export records what the deck did to sessions. The runtime
             // notes it in its own log.
             .deleteRequested, .deleteConfirmed, .deleteAbandoned,
             .actionCancelled, .queueCleared,
             // A block carries no payload (`ActionBlock` is a closed enum) but
             // is not something the deck did to a session. The runtime notes it
             // in its own log.
             .actionBlocked,
             // A preference change carries a theme id, and a user theme's id
             // derives from a user-chosen file name, so the whole event stays
             // out.
             .prefsChanged: return nil
        }
    }
}

/// Derived fields are marked derived and fail to nothing.
public enum Derived {
    /// The branch shown beside a lane.
    ///
    /// `gitRoot` is what a port answered — nil means "this `cwd` is not a git
    /// worktree". The rule is that a non-worktree renders **no branch**, never
    /// a placeholder, never the directory name standing in for one. A
    /// placeholder here is the deck inventing a fact about the user's machine,
    /// which is class T's whole subject.
    public static func branch(cwd: String?, head: String?, gitRoot: String?) -> String? {
        guard cwd != nil, gitRoot != nil, let head, !head.isEmpty else { return nil }
        return head
    }
}
