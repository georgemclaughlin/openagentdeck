//
//  FleetRow.swift · DeckCore/Ingest
//
//  One row of `claude agents --json`.
//
//  This is **one shape with optional keys**, not two disjoint row shapes.
//  `state` accompanies background rows, `status` accompanies interactive ones,
//  and the induced-failure row `spike-fail` carries *both*. Explicit `null`
//  appears for neither anywhere in the corpus.
//
//  So the decoder tolerates absent, null and present, and the *display* rule
//  below is negative: not in the known-failure set means not a failure.
//

public struct FleetRow: Equatable, Sendable {
    public let session: SessionID?
    public let name: String?
    public let kind: String?
    public let state: Fed<String>
    public let status: Fed<String>
    /// The session's process, and the join key to the terminal that hosts it.
    ///
    /// cmux exports `CMUX_CLAUDE_PID` into every surface, so a pid is enough to
    /// find which tab a session is in, with no hook involved (LV34). That is
    /// what lets the deck know about a session that has never spoken to it.
    public let pid: Int?
    /// Where the session is working. Present on every row of `agents --json`,
    /// and the only thing a discovered lane can say about itself before a hook
    /// arrives.
    public let cwd: String?
    /// The dialog itself, when `status` is `waiting` — recorded live as
    /// "permission prompt" (LV36); the binary's vocabulary also includes
    /// "dialog open", "input needed", "sandbox request" and "worker request".
    /// A plain optional rather than `Fed`: nothing needs null and absent kept
    /// apart for a descriptive string, and LV34 shows `status: "waiting"` can
    /// arrive with no text at all.
    public let waitingFor: String?

    public init(session: SessionID?, name: String?, kind: String?,
                state: Fed<String>, status: Fed<String>,
                pid: Int? = nil, cwd: String? = nil, waitingFor: String? = nil) {
        self.session = session; self.name = name; self.kind = kind
        self.state = state; self.status = status
        self.pid = pid; self.cwd = cwd; self.waitingFor = waitingFor
    }

    /// The unknown-is-not-error rule, in its load-bearing negative form.
    ///
    /// A value the code has never seen is **not** a failure. Don't reverse this
    /// into a positive match ("failure unless known fine"): the next unforeseen
    /// enum would turn a lane red for no explainable reason (S18). The worst
    /// case here is a lane that never turns red, which beats a lane that lies.
    public static let knownFailureStates: Set<String> = ["blocked", "failed", "error"]

    public var isFailing: Bool {
        guard let s = state.value else { return false }
        return Self.knownFailureStates.contains(s)
    }

    public var isWorking: Bool { state.value == "working" }

    /// Interactive rows: `status` is one of `busy`, `idle`, `waiting`, measured
    /// at S7/S9 (first two) and LV36/LV34 (`waiting`; LV34 has no
    /// `waitingFor`, so the KEY alone is the evidence, never the text beside
    /// it). A value outside this triple answers false to all three predicates
    /// (unknown moves nothing).
    public var isBusy: Bool { status.value == "busy" }
    public var isIdle: Bool { status.value == "idle" }
    /// A human is being asked something, by the fleet's own report rather
    /// than the deck's inference: a dialog is open right now. Reads `status`,
    /// not `state`; a background row has no dialog to report.
    public var isWaitingOnHuman: Bool { status.value == "waiting" }
}

public enum FleetIngest {

    /// Decode a whole `agents --json` document. Total: a row that is not an
    /// object is skipped rather than fatal, and a row missing every key still
    /// decodes.
    public static func rows(from doc: JSONValue) -> [FleetRow] {
        guard let arr = doc.arrayValue else { return [] }
        return arr.map { row in
            FleetRow(session: row["sessionId"]?.stringValue.map(SessionID.init),
                     name:    row["name"]?.stringValue,
                     kind:    row["kind"]?.stringValue,
                     state:   row.fedString("state"),
                     status:  row.fedString("status"),
                     pid:     row["pid"]?.intValue,
                     cwd:     row["cwd"]?.stringValue,
                     waitingFor: row["waitingFor"]?.stringValue)
        }
    }
}
