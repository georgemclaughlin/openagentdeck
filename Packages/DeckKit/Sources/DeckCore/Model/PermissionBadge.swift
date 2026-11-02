//
//  PermissionBadge.swift · DeckCore/Model
//
//  Whether this session will ask you before it acts.
//
//  `permissionMode` is the most consequential field the deck carries, so it
//  is a badge on every card rather than something you have to select a session
//  to find. The rule for what a badge SAYS lives here, not in the view,
//  because severity is a judgement about risk and worth testing without
//  rendering.
//
//  The absent case matters as much as the present ones. `default` is the mode
//  almost every session runs in, and a "Default" badge on every card would be
//  ignored, taking the one that says BYPASSING with it. Silence is what earns
//  the alarm its volume.
//

/// What to say about a session's permission mode, or nothing.
public struct PermissionBadge: Equatable, Sendable {
    /// Sentence case, and phrased as what the session is DOING rather than as
    /// the raw mode name. `bypassPermissions` is an API token; "Bypassing
    /// permissions" is the fact it stands for, and the fact is what somebody
    /// glancing at a deck needs.
    public let label: String
    public let severity: Severity

    public init(label: String, severity: Severity) {
        self.label = label; self.severity = severity
    }

    /// The modes Claude Code names. Kept as raw strings rather than an enum
    /// with a fallible init because the deck does not own this vocabulary —
    /// a mode added upstream must reach the glass, not fail to parse.
    public static let bypass = "bypassPermissions"
    public static let acceptEdits = "acceptEdits"
    public static let plan = "plan"
    public static let normal = "default"

    /// What to show for a raw mode, or nil when there is nothing worth saying.
    ///
    /// The unknown case is `caution`, never `alarm` and never silence: the
    /// deck may not call something a failure it has merely never seen, but
    /// staying quiet about an unrecognised mode would vouch for it. It is
    /// shown verbatim, marked as worth a look.
    public static func forMode(_ raw: String?) -> PermissionBadge? {
        guard let raw, !raw.isEmpty, raw != normal else { return nil }
        switch raw {
        case bypass:
            return PermissionBadge(label: "Bypassing permissions", severity: .alarm)
        case acceptEdits:
            return PermissionBadge(label: "Auto-accepting edits", severity: .caution)
        case plan:
            return PermissionBadge(label: "Plan mode", severity: .normal)
        default:
            return PermissionBadge(label: raw, severity: .caution)
        }
    }

    /// What a screen reader hears. The label alone reads as a noun phrase
    /// floating beside a session name; this says whose it is and what it means.
    public var spokenDescription: String {
        switch severity {
        case .alarm: "\(label) — this session acts without asking"
        case .caution: "\(label) — this session does not ask for everything"
        case .normal: label
        }
    }
}
