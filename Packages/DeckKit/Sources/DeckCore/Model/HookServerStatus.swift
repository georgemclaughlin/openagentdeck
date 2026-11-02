//
//  HookServerStatus.swift · DeckCore/Model
//
//  Whether the deck is actually listening, in a form a view can render.
//
//  The deck is an always-on ambient device whose whole claim is that it will
//  tell you when a session needs you. That rests on a socket being bound, so
//  "is it connected" is a first-order question and the answer belongs on
//  screen permanently; otherwise a deck that failed to bind looks exactly like
//  a deck with nothing to report.
//
//  One value rather than a message beside a flag: a view wanting to colour a
//  `String` would have to parse English, and two fields that must agree can
//  disagree.
//

/// What the hook server is doing.
public enum HookServerStatus: Equatable, Sendable {
    /// Before `start`. Distinct from failure: nothing has been attempted.
    case notStarted
    case listening(port: UInt16)
    /// Loopback refused the bind. Carries what went wrong, because a status
    /// line saying only "failed" sends somebody to the console to find out.
    case failed(reason: String)
    /// Shut down deliberately. Its own case rather than a return to
    /// `notStarted`, because "never tried" and "was listening and is not any
    /// more" are different facts about a deck, and only one of them means
    /// something changed.
    case stopped

    /// The sentence the status line shows.
    public var message: String {
        switch self {
        case .notStarted: "not started"
        case .listening(let port): "listening on 127.0.0.1:\(port)"
        case .failed(let reason): "could not bind — \(reason)"
        case .stopped: "stopped"
        }
    }

    /// How much attention this state is asking for. A deck that cannot bind is
    /// not a diagnostic detail — every hook the sessions fire is going
    /// nowhere, so nothing on the glass will ever update again.
    public var severity: Severity {
        switch self {
        case .notStarted, .stopped: .caution
        case .listening: .normal
        case .failed: .alarm
        }
    }

    public var isListening: Bool {
        if case .listening = self { return true }
        return false
    }

    /// What a screen reader hears. The message alone is a fragment; this says
    /// what it means for the deck.
    public var spokenDescription: String {
        switch self {
        case .notStarted: "The deck is not listening yet."
        case .listening(let port): "The deck is listening on port \(port)."
        case .failed(let reason):
            "The deck could not listen, so no session can reach it. \(reason)"
        case .stopped: "The deck has stopped listening. No session can reach it."
        }
    }
}
