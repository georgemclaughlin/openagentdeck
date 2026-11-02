//
//  Ports.swift · DeckPorts
//
//  Protocols only, zero implementations — architecture §2.
//
//  The point of the layer is not indirection for its own sake. It is that every
//  place the app touches the world is named here, in one file, so "what can this
//  program actually do to my machine?" is a question with a short answer: open a
//  loopback socket, run one CLI, read and write one config file. Anything a
//  future adapter wants to do that is not on this list has to add a line here
//  first, in a diff someone reads.
//

import DeckCore

/// Receives hook calls and answers them. The deck's whole reason to exist.
public protocol HookServerPort: Sendable {
    /// Begin listening on loopback. Throws rather than falling back to a
    /// different address — the no-egress rule is not a preference.
    func start(port: UInt16) async throws
    func stop() async
}

/// `claude agents --json`, polled.
public protocol FleetPort: Sendable {
    func poll() async -> [FleetRow]
}

/// "What branch is this directory on?"
///
/// Branch is a derived field, and deriving it means reading `.git/HEAD`,
/// which is filesystem access `DeckCore` must not acquire.
///
/// `nil` is a real answer and the only one permitted off a worktree: not a
/// placeholder, not the directory's last component, and not the previous
/// answer left on screen. A guessed branch is an invented fact.
public protocol WorktreePort: Sendable {
    func branch(at path: String) async -> String?
}

/// "What does this session's own on-disk transcript say, near the end?" The
/// transcript-well backfill's read: like `WorktreePort`, a fact that needs the
/// filesystem, so `DeckCore` never sees this type.
///
/// `nil` is a real answer and not split further: a missing file and a
/// permission denial mean the same to the one caller
/// (`DeckRuntime.seedTranscript(for:path:)`), which seeds nothing.
///
/// Invalid UTF-8 is not a `nil` case. `maxBytes` means a read can start
/// mid-character, and a strict decode would fail the whole tail for any
/// non-ASCII session. A lossy decode returns replacement characters in the
/// affected line, and `TranscriptTail` skips malformed lines.
public protocol TranscriptFilePort: Sendable {
    /// The last `maxBytes` of the file at `path`, decoded as lossy UTF-8 (a
    /// split leading character becomes replacement characters, never a failed
    /// read), or `nil` if the file could not be read at all. The tail may begin
    /// mid-line; the caller's parser (`TranscriptTail`) tolerates that.
    func tail(of path: String, maxBytes: Int) async -> String?

    /// The file's current byte size, or `nil` when it cannot be determined. This
    /// is the backfill ladder's first read, before any content. As with
    /// `tail(of:maxBytes:)`, a missing file and a permission denial answer
    /// identically: the one caller (`DeckRuntime.seedTranscript(for:path:)`, via
    /// `TranscriptTail.backfillWindows(fileSize:)`) falls back to the un-clamped
    /// ladder either way. Not a substitute for `tail` failing independently: a
    /// file can be `stat`ed and then fail to `read` (permissions race, device
    /// gone), so neither a `nil` nor a size here predicts whether `tail`
    /// succeeds.
    /// call will succeed either.
    func size(of path: String) async -> Int?
}

/// The only writer of `~/.claude`, and the only reader of it.
/// What was found at the settings path.
///
/// `absent` and `unreadable` are different facts, and the difference is the
/// user's configuration. Collapsing both into an empty document would merge
/// into nothing and write back a file holding only the deck's hooks, replacing
/// everything the user had. The backup preserves the bytes, but in a file they
/// have no reason to look for.
public enum ConfigDocument: Equatable, Sendable {
    /// No file. A fresh machine, and installing writes a new one.
    case absent
    case present(JSONValue)
    /// A file the deck cannot parse. Installing is REFUSED: the deck will not
    /// merge into a document it could not read, because the merge would be
    /// into nothing.
    case unreadable(String)

    /// The document to reason about, or nil when there is nothing safe to
    /// reason about. `absent` is an empty document on purpose — that is what a
    /// fresh install merges into — and `unreadable` is not.
    public var document: JSONValue? {
        switch self {
        case .absent: .object([:])
        case .present(let value): value
        case .unreadable: nil
        }
    }
}

public protocol ConfigPort: Sendable {
    func read() async -> ConfigDocument
    /// Executes a plan, never a document: the ordering the atomic-write rule
    /// checks is the thing that gets handed across the boundary.
    func apply(_ steps: [WriteStep]) async throws
}

/// What an adapter hands back to the core. One case per thing that can go
/// wrong at a boundary, so a caller cannot ignore the difference between "the
/// CLI is missing" and "the CLI said something I could not parse".
public enum PortFailure: Error, Equatable, Sendable {
    case unavailable(String)
    case refused(String)
    case malformed(String)
}

// ---------------------------------------------------------------- the host
//
// The deck's sessions run inside a terminal application; the supported host
// is cmux, a native app with a Unix socket API, vertical tabs and split panes.
//
// Three capabilities (fixtures and live probes LV28-LV31): the host can be asked what sessions
// exist, a surface can be read, and a surface can be written to without taking
// the screen. The last is why this port exists rather than keyboard
// automation: `fixtures/live/LV30-multitab` records text delivered to a
// background tab of a background workspace with focus unmoved.

/// Where a session lives, as the host names it.
///
/// The surface is the identity. `CMUX_TAB_ID` equals `CMUX_WORKSPACE_ID` even
/// in a workspace with two tabs (LV30-multitab), so routing by tab would send
/// every action for a workspace to whichever tab answered last. The workspace
/// rides along because the host's short refs are workspace-scoped.
///
/// Defined in `DeckCore` (`HostAddress`) because it travels on the wire: the
/// hook reports it, ingest decodes it, and a lane carries it. The port layer
/// only names it.
public typealias SessionAddress = HostAddress

/// One session the host knows about, whether or not it has ever spoken to the
/// deck. Without this channel a session exists only once it emits a hook.
public struct HostSession: Equatable, Sendable {
    /// The name the deck routes by: the one the host's inventory printed.
    public let address: SessionAddress
    /// The host's own title for the surface; on cmux, the session's self-chosen
    /// name.
    public let title: String
    public let isSelected: Bool
    /// Every name the host gave this workspace, and every name it gave this
    /// surface. A host may call one object several things, and the deck learns
    /// the address from a different source than the inventory: the hook reads
    /// the session's environment, `inventory()` reads the host's listing. On
    /// cmux those are a UUID and a short ref for one surface (LV32), so
    /// comparing them with `==` fails closed on every lane.
    public let workspaceNames: Set<String>
    public let surfaceNames: Set<String>

    public init(address: SessionAddress, title: String, isSelected: Bool,
                workspaceNames: Set<String> = [], surfaceNames: Set<String> = []) {
        self.address = address; self.title = title; self.isSelected = isSelected
        self.workspaceNames = workspaceNames.union([address.workspace])
        self.surfaceNames = surfaceNames.union([address.surface])
    }

    /// Is this the session that address names?
    ///
    /// The host answers, not the caller: only the adapter knows how many names
    /// its host hands out for one object, and a caller holding `==` is wrong in
    /// a way no care at the call site fixes.
    ///
    /// Case-insensitive because the two forms use different alphabets
    /// (lowercase refs, uppercase hex) that cannot collide by folding case.
    public func identifies(_ other: SessionAddress) -> Bool {
        func has(_ names: Set<String>, _ name: String) -> Bool {
            names.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
        }
        return has(workspaceNames, other.workspace) && has(surfaceNames, other.surface)
    }
}

/// What happened to a send. Three cases, not a Bool, as with `PortFailure`: the
/// deck must be able to say why a control is dark. `unavailable` is the state
/// when the host refuses its socket to a program it did not spawn (a process
/// reparented to launchd gets "Failed to write to socket"; so does a deck
/// launched from Finder).
public enum SendOutcome: Equatable, Sendable {
    case sent
    case unavailable(String)
    case failed(String)
}

/// Talking to the terminal application that hosts the sessions.
///
/// `DeckCore` never sees this type. The core queues an action and decides
/// whether it may go; the adapter is the only thing that knows what a surface
/// is: the core imports no platform framework and opens no socket.
public protocol SessionHostPort: Sendable {
    /// Every session the host currently has, or a failure explaining why the
    /// deck cannot ask.
    func inventory() async -> Result<[HostSession], PortFailure>
    /// What that surface shows right now. The deck reads **before** it writes:
    /// a composer holding text the deck did not put there is a session the
    /// deck must not type into.
    func read(_ address: SessionAddress, lines: Int) async -> Result<String, PortFailure>
    /// Text, delivered to that surface. Never submitted by itself — the caller
    /// sends the key, so "type" and "submit" stay two decisions.
    func send(_ text: String, to address: SessionAddress) async -> SendOutcome
    /// A named key: `enter`, `escape`, `ctrl+u`. Works on a background surface
    /// without moving focus.
    func sendKey(_ key: String, to address: SessionAddress) async -> SendOutcome
    /// Where the process with this pid is running, or nil if the host cannot say.
    ///
    /// This makes an always-running deck possible. `claude agents --json` lists
    /// every session with its pid and needs no hook, so a deck launched after
    /// its sessions can find them; but a session the deck cannot route to can
    /// only be watched. The host knows how a pid maps to a place: on cmux the
    /// surface exports `CMUX_CLAUDE_PID` into the session's environment. Seven
    /// of seven live sessions resolved this way (LV34).
    func address(ofPID pid: Int) async -> SessionAddress?
}
