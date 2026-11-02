//
//  Connection.swift · DeckCore/Config
//
//  Whether Claude Code can reach this deck, as one value.
//
//  The deck's whole claim rests on two things being true at once: a socket is
//  bound, and `~/.claude/settings.json` points at it. Either alone is silence.
//  A deck listening on 8766 with hooks aimed at 8765 looks exactly like a deck
//  nobody has started a session against — an empty fleet, no error, nothing to
//  read — and the user has no way to tell those apart.
//
//  So the two facts are combined here rather than in a view. The empty state
//  asks this one question and gets one answer, and every answer knows what it
//  would take to fix it.
//
//  Deliberately COMPUTED, never remembered. A stored "installed: true" goes
//  stale the moment somebody edits the file by hand, and a stale "Connected"
//  badge is a lie.
//

import Foundation

public enum Connection: Equatable, Sendable {

    /// The settings file cannot be parsed, so the deck will not merge into it.
    /// Carries why: this ends with a person opening an editor.
    case unreadable(reason: String)

    /// No deck hook in the file. Nothing will ever arrive.
    case notConnected

    /// Hooks point at a port this deck is not listening on. **The dangerous
    /// one**: everything looks installed and no session will ever appear.
    case wrongPort(installed: Int, listening: Int)

    /// Hooks are right, the socket is bound, and nothing has arrived yet.
    /// `running` is how many sessions the fleet feed can see WITHOUT hooks —
    /// which is what turns "nothing here" into "restart these three".
    case waiting(running: Int)

    /// Connected, and a session has actually spoken.
    case connected

    /// Hooks are ARRIVING and the settings file shows nothing the deck
    /// recognises as its own. Claude Code rewrites `settings.json` on its own
    /// saves and strips keys it does not know, including the deck's marker.
    /// Runtime truth outranks file truth: a hook that arrived is a
    /// connection, whatever the file says about it.
    /// `candidates` is how many unsigned loopback `/hook` entries are in the
    /// file — the difference between "adopt this one" and "the hook is gone,
    /// new sessions won't connect".
    case unlisted(candidates: Int)

    /// Another deck already owns the port. Not an error and not this deck's
    /// problem to fix: the sessions are connected, just not to this window.
    case superseded(port: Int)

    // -------------------------------------------------------------- deciding

    /// Everything the answer depends on, in one place, so the rule is a
    /// function of facts rather than a branch inside a view.
    public static func decide(document: ConfigReadout,
                              listeningOn: Int?,
                              bindFailed: Bool,
                              installedPort: Int?,
                              attemptedPort: Int,
                              lanesSeen: Int,
                              hooksHeard: Bool,
                              candidatesSeen: Int) -> Connection {
        if case .unreadable(let why) = document { return .unreadable(reason: why) }
        // A bind failure on a machine whose config already names this port is
        // a second deck, not a broken one — the deck surrenders the port and
        // says who has it, rather than reporting itself broken.
        //
        // The port comes from what this deck TRIED to bind, falling back to
        // what the config names. Falling back to 0 would read "A deck already
        // owns 127.0.0.1:0" on a fresh machine.
        if bindFailed { return .superseded(port: installedPort ?? attemptedPort) }
        guard let listening = listeningOn else { return .notConnected }
        guard let installed = installedPort else {
            // An arrived hook outranks an empty file: reporting `notConnected`
            // would deny a live session. The file's silence only means the
            // deck cannot vouch for NEW sessions, which `unlisted` says.
            return hooksHeard ? .unlisted(candidates: candidatesSeen) : .notConnected
        }
        if installed != listening { return .wrongPort(installed: installed, listening: listening) }
        if hooksHeard { return .connected }
        return .waiting(running: lanesSeen)
    }

    /// Whether the deck is in a state a person is expected to act on.
    public var needsAttention: Bool {
        switch self {
        case .connected, .waiting: false
        case .unreadable, .notConnected, .wrongPort, .superseded, .unlisted: true
        }
    }

    /// Whether connecting would do anything. `superseded` and `unreadable` are
    /// the two states where the button must not be offered at all — one has
    /// nothing to fix, the other must not be written to.
    public var isConnectable: Bool {
        switch self {
        case .notConnected, .wrongPort, .waiting, .connected, .unlisted: true
        case .unreadable, .superseded: false
        }
    }

    // ------------------------------------------------------------ what it says

    public var title: String {
        switch self {
        case .unreadable: "Can't read your Claude Code settings"
        case .notConnected: "Not connected yet"
        case .wrongPort: "Connected to the wrong port"
        case .waiting(let running):
            running > 0 ? "\(running) session\(running == 1 ? "" : "s") haven't connected"
                        : "Waiting for your first session"
        case .connected: "Connected"
        case .unlisted: "Connected, but not in your settings"
        case .superseded: "Another deck is already running"
        }
    }

    /// What is happening and what to do about it — in that order, because a
    /// message that explains without telling somebody their next move is a
    /// message they have to think about.
    public var detail: String {
        switch self {
        case .unreadable(let why):
            "~/.claude/settings.json \(why). Fix it and the deck will pick it up."
        case .notConnected:
            "The deck's hooks in ~/.claude/settings.json connect Claude Code to it. "
            + "Tool calls that need permission will wait for you here instead of in the terminal."
        case .wrongPort(let installed, let listening):
            "Your hooks post to port \(installed) and this deck is listening on \(listening), "
            + "so nothing will ever arrive. Connecting again points them at \(listening)."
        case .waiting(let running) where running > 0:
            "New sessions connect on their own. These were already running when the hooks "
            + "were added — restart them to bring them in."
        case .waiting:
            "Start Claude Code and its sessions appear here."
        case .connected:
            "Claude Code is posting to this deck."
        case .unlisted(let candidates) where candidates > 0:
            "Sessions are posting to this deck, but the hook in ~/.claude/settings.json "
            + "isn't one the deck recognises — another tool may have rewritten the file. "
            + "Connecting lets you adopt it, so the deck can keep it current."
        case .unlisted:
            "Sessions that are already running keep posting, but ~/.claude/settings.json "
            + "no longer has a deck hook — new sessions won't connect. Connecting adds it back."
        case .superseded(let port):
            "A deck already owns 127.0.0.1:\(port). Your sessions are connected to that one."
        }
    }
}

/// What was found at the settings path, without the document itself.
///
/// `DeckCore` decides the connection state and may not hold a file's contents
/// to do it — the adapter reads, the core judges. This is the judgement-shaped
/// half of `ConfigDocument`.
public enum ConfigReadout: Equatable, Sendable {
    case absent
    case present
    case unreadable(String)
}
