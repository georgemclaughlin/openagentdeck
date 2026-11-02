//
//  HookEvent.swift · DeckCore/Ingest
//

/// What Claude Code called the hook.
///
/// `unrecognised` is the whole point of the type. Unknown is not error.
/// A future Claude Code that adds a hook must produce a lane that holds its
/// prior state, not a lane that turns red — the degraded behaviour has to be
/// *the deck says nothing new*, never *the deck says something false*.
public enum HookKind: Equatable, Sendable {
    case sessionStart
    case userPromptSubmit
    case preToolUse
    /// The engine announcing that it is about to show a permission dialog, i.e.
    /// that it wants a human.
    case permissionRequest
    case postToolUse
    case notification
    case stop
    case sessionEnd
    case unrecognised(String)

    /// Total. Every string maps to a value.
    ///
    /// Do not turn this into a switch with an erroring default. S18 is the
    /// reason: the real failure value was `blocked`, not the assumed `failed`,
    /// and an erroring default would turn an unforeseen-but-harmless value
    /// into a lane the user cannot trust.
    public init(name: String) {
        switch name {
        case "SessionStart":     self = .sessionStart
        case "UserPromptSubmit": self = .userPromptSubmit
        case "PreToolUse":       self = .preToolUse
        case "PermissionRequest": self = .permissionRequest
        case "PostToolUse":      self = .postToolUse
        case "Notification":     self = .notification
        case "Stop":             self = .stop
        case "SessionEnd":       self = .sessionEnd
        default:                 self = .unrecognised(name)
        }
    }

    public var isRecognised: Bool {
        if case .unrecognised = self { return false }
        return true
    }
}

/// One hook delivery, as the deck sees it.
public struct HookEvent: Equatable, Sendable {
    public let id: EventID
    public let at: Instant
    public let kind: HookKind
    public let session: SessionID
    /// A filesystem path. The redaction rule names file paths alongside commands
    /// and prompts as things no exportable artefact may carry, so it is
    /// `Redacted`: in-process readers (branch derivation) use `.value`, and
    /// nothing can write it out.
    public let cwd: Redacted?
    /// `payload.transcript_path`: a filesystem path, `Redacted` like `cwd`.
    /// Every hook payload carries it (see `Fixtures/live/*/payloads.ndjson`).
    /// The transcript backfill's file adapter (`DeckApp`) reads it to find the
    /// session's transcript on disk, so a freshly launched deck can fill the
    /// well for sessions it never witnessed live.
    public let transcriptPath: Redacted?
    public let tool: String?
    public let toolUseID: String?
    /// Where this session lives, as its host names it. Present when the hook
    /// reported it (the installed hook does, from the environment its parent
    /// session gave it). Absent means the deck cannot address that session,
    /// and it says so instead of guessing.
    public let host: HostAddress?
    /// How long the relay held this call. Absent, null and 0 are kept apart —
    /// see `Fed`. In the corpus all three occur.
    public let held: Fed<Int>

    // ------------------------------------------------------- what it is about
    /// What a `PreToolUse` is asking to do. The decision surface's subject.
    public let subject: Subject?
    /// An `AskUserQuestion`'s questions, decoded. Empty for everything else, and
    /// also when the call was unreadable; `questionsUnreadable` tells the two
    /// apart.
    public let questions: [Question]
    /// True when `tool == AskUserQuestion` and the raw `questions` array failed
    /// the all-or-nothing decode in `QuestionReader.questions(from:)` (one bad
    /// row, or none readable). `questions` is `[]` either way. Decoding must be
    /// all-or-nothing: dropping a bad row would open a takeover that submits an
    /// answer set missing a question, and a fully failed decode would fall
    /// through to Allow/Deny on a question. `false` for every other tool.
    public let questionsUnreadable: Bool
    /// `tool_input["questions"]`, value-verbatim, kept beside the decoded
    /// `questions`: the decoded model is lossy (unknown keys do not survive),
    /// and `HookResponse.answered` must echo the tool's own input back. `nil`
    /// for other tools, and for an `AskUserQuestion` with no `questions` key.
    public let rawQuestions: JSONValue?
    /// A `PostToolUse`'s own answers to a question call, decoded. Empty for other
    /// tools, and when `AnswerReader.answers(from:)` could not read them
    /// (all-or-nothing, like `questions`). `Answer.question` is the question's
    /// text, matching `Question.text`; the wire keys the answer map by it.
    public let answers: [Answer]
    /// A `PermissionRequest`'s `permission_suggestions`: Claude Code's option 2,
    /// "Yes, and don't ask again for: X". Kept verbatim, as the engine sent it,
    /// rather than decoded: the shape is engine-owned and partly undocumented
    /// (taken from the CLI 2.1.223 binary), and the deck only echoes an element
    /// back (see `HookResponse.decision`). A typed model would be a second
    /// schema for one wire shape, which drifts. The human-readable label is
    /// decoded lazily at the projection layer (`SuggestionLabel`, `Frame.swift`).
    public let permissionSuggestions: JSONValue?
    /// A `Notification`'s reason, in the engine's vocabulary (from the CLI 2.1.223
    /// binary): `permission_prompt`, `idle_prompt`, `auth_success`,
    /// `elicitation_accepted`, `elicitation_rejected`, `agent_needs_input`,
    /// `agent_completed`. One hook kind carries several distinct facts;
    /// `idle_prompt` ("Claude finished, waiting for the next prompt") is the
    /// wire's own definition of idle. Only `idle_prompt` and `permission_prompt`
    /// move lane state; every other value, and absence, holds the prior state,
    /// as `HookKind.unrecognised` does.
    public let notificationType: String?

    // ------------------------------------------------------- who is asking
    /// `UserPromptSubmit.prompt` — what this session was last told to do.
    public let prompt: Redacted?
    /// `session_title`, which Claude Code computes and sends on `SessionStart`
    /// and every `UserPromptSubmit`; use it instead of deriving a name from the
    /// prompt.
    public let title: Redacted?
    /// `permission_mode` — `default`, `acceptEdits`, `plan`, `bypassPermissions`.
    /// A fixed vocabulary rather than payload content, so it is a plain `String`:
    /// redacting an enum would hide a fact the user needs and protect nothing.
    public let permissionMode: String?
    /// `SessionStart`'s `source` (`startup`, `resume`, `clear`, `compact`): the
    /// only wire evidence that distinguishes a session that began from one that
    /// merely re-announced itself. Present on every recorded `SessionStart`.
    /// `Reducer.seedAutoContinue` reads it: the standing auto-continue default
    /// must arm a new session, not a resumed one, and an in-memory "seen this
    /// session id" test cannot tell them apart across a deck relaunch. `nil`
    /// for other kinds or a payload without one; the caller then falls back to
    /// the in-memory test.
    public let source: String?

    public init(id: EventID, at: Instant, kind: HookKind, session: SessionID,
                cwd: Redacted?, transcriptPath: Redacted? = nil,
                tool: String?, toolUseID: String?, held: Fed<Int>,
                subject: Subject? = nil, questions: [Question] = [],
                questionsUnreadable: Bool = false, rawQuestions: JSONValue? = nil,
                answers: [Answer] = [],
                permissionSuggestions: JSONValue? = nil,
                prompt: Redacted? = nil, title: Redacted? = nil,
                permissionMode: String? = nil, source: String? = nil,
                host: HostAddress? = nil,
                notificationType: String? = nil) {
        self.id = id; self.at = at; self.kind = kind; self.session = session
        self.cwd = cwd; self.transcriptPath = transcriptPath
        self.tool = tool; self.toolUseID = toolUseID; self.held = held
        self.host = host
        self.subject = subject; self.questions = questions
        self.questionsUnreadable = questionsUnreadable; self.rawQuestions = rawQuestions
        self.answers = answers
        self.permissionSuggestions = permissionSuggestions
        self.prompt = prompt; self.title = title; self.permissionMode = permissionMode
        self.source = source
        self.notificationType = notificationType
    }
}

public enum HookIngest {

    /// Decode one recorded envelope. Total: returns nil only when the row
    /// carries no session at all, because a lane with no session is a lane the
    /// deck invented.
    ///
    /// `epochBase` is the millisecond stamp that becomes `Instant.start`. Time
    /// enters the core exactly here and nowhere else.
    public static func event(from row: JSONValue, epochBase: Int64) -> HookEvent? {
        let payload = row["payload"] ?? .object([:])
        guard let session = payload["session_id"]?.stringValue, !session.isEmpty
        else { return nil }

        let tsText = row["ts"]?.stringValue ?? ""
        guard let epoch = Timestamp.epochMillis(iso: tsText) else { return nil }

        // The envelope's `event` and the payload's `hook_event_name` record the
        // same fact. Prefer the payload (what Claude Code sent); fall back to
        // the envelope. The 5 `unknown` rows have only the envelope.
        let name = payload["hook_event_name"]?.stringValue
            ?? row["event"]?.stringValue
            ?? ""

        let tool = row["tool"]?.stringValue ?? payload["tool_name"]?.stringValue
        let kind = HookKind(name: name)
        // CLI 2.1.220 sends `PermissionRequest` with no `tool_use_id`. A hold
        // needs an identity, so one is synthesized from the row's unique
        // fields: replaying a row is idempotent, a second request differs by
        // its stamp.
        let useID = payload["tool_use_id"]?.stringValue
            ?? (kind == .permissionRequest
                ? "perm|\(session)|\(tool ?? "")|\(tsText)" : nil)
        let input = payload["tool_input"]

        // The subject is read for every tool call, supervised or not: decoding
        // must not depend on hold policy, or changing the supervised set would
        // silently change what ingest knows.
        let subject = SubjectReader.subject(tool: tool, input: input)
        // All-or-nothing (see `HookEvent.questionsUnreadable`). Gated on
        // `kind == .preToolUse` as well as the tool name: questions ride
        // PreToolUse only, and a `PermissionRequest` that carries the tool name
        // (CLI 2.1.220 leaves `tool` on rows it should not describe) must stay a
        // permission.
        let questions: [Question]
        let questionsUnreadable: Bool
        if kind == .preToolUse, tool == SubjectReader.questionTool {
            if let decoded = QuestionReader.questions(from: input) {
                questions = decoded
                questionsUnreadable = false
            } else {
                questions = []
                questionsUnreadable = true
            }
        } else {
            questions = []
            questionsUnreadable = false
        }
        // Verbatim `tool_input["questions"]`, kept beside the decoded array so a
        // key the decoder does not know survives ingest.
        let rawQuestions = (kind == .preToolUse && tool == SubjectReader.questionTool)
            ? input?["questions"] : nil
        // The terminal's own answer. Gated on `.postToolUse` and the question
        // tool, mirroring `questions` above: a `PostToolUse` is the only place
        // an answer rides. Read `tool_response` first (the tool's result), then
        // `tool_input`, which carries the identical value on every LV38 fixture.
        let answers: [Answer]
        if kind == .postToolUse, tool == SubjectReader.questionTool {
            let responseInput = payload["tool_response"] ?? payload["tool_input"]
            answers = AnswerReader.answers(from: responseInput) ?? []
        } else {
            answers = []
        }
        // Verbatim, per the field's doc comment.
        let permissionSuggestions = payload["permission_suggestions"]

        // Derived from the fields that make a row unique, so that replaying the
        // same row twice is idempotent and replaying two genuinely different
        // rows is not.
        let id = EventID([tsText, name, session, tool ?? "", useID ?? ""].joined(separator: "|"))

        return HookEvent(id: id,
                         at: Instant(sinceStart: Millis(epoch - epochBase)),
                         kind: kind,
                         session: SessionID(session),
                         cwd: Redacted(optional: payload["cwd"]?.stringValue),
                         transcriptPath: Redacted(optional: payload["transcript_path"]?.stringValue),
                         tool: tool,
                         toolUseID: useID,
                         held: row.fedInt("held_ms"),
                         subject: subject,
                         questions: questions,
                         questionsUnreadable: questionsUnreadable,
                         rawQuestions: rawQuestions,
                         answers: answers,
                         permissionSuggestions: permissionSuggestions,
                         prompt: Redacted(optional: payload["prompt"]?.stringValue),
                         title: Redacted(optional: payload["session_title"]?.stringValue),
                         permissionMode: payload["permission_mode"]?.stringValue,
                         source: payload["source"]?.stringValue,
                         // Both halves or nothing: half an address addresses no one.
                         host: HostAddress(workspace: row["workspace"]?.stringValue,
                                           surface: row["surface"]?.stringValue),
                         notificationType: payload["notification_type"]?.stringValue)
    }

    /// The epoch stamp of the earliest parseable row, which becomes deck zero.
    public static func epochBase(rows: [JSONValue]) -> Int64? {
        rows.compactMap { Timestamp.epochMillis(iso: $0["ts"]?.stringValue ?? "") }.min()
    }
}
