//
//  Identifiers.swift · DeckCore/Model
//

/// A Claude Code session. The deck's lane identity, and nothing else.
public struct SessionID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// Provenance. Every value the deck renders names the event it came from.
///
/// A frame field with a non-empty value must have a non-nil `sourceEventID`,
/// which is only checkable if the identifier is real, i.e. resolvable back to
/// something in the received log. The recorded envelope carries no id, so one
/// is derived from the fields that make a row unique. Derived, not invented:
/// two identical rows are the same event, which idempotence needs.
public struct EventID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let raw: String
    public init(_ raw: String) { self.raw = raw }
    public var description: String { raw }
}

/// Where a session lives, as its host names it.
///
/// On the wire because the deck's own hook reports it: a hook is a child of
/// the session, so it inherits the host's identifiers from the environment and
/// posts them alongside the payload. The deck never infers this — measured
/// alternatives (tty matching, `lsof`, process-tree walks) all failed on a
/// real machine, where two ttys were already duplicated across live surfaces.
///
/// **The surface is the identity.** cmux's own `CMUX_TAB_ID` equals
/// `CMUX_WORKSPACE_ID` even in a workspace with two tabs
/// (`fixtures/live/LV30-multitab`), so a "tab" cannot be addressed and this
/// type does not offer one. The workspace rides along because the host's short
/// refs are workspace-scoped.
public struct HostAddress: Equatable, Hashable, Codable, Sendable {
    public let workspace: String
    public let surface: String
    public init(workspace: String, surface: String) {
        self.workspace = workspace; self.surface = surface
    }
    /// Absent unless BOTH halves arrived. Half an address addresses nothing,
    /// and a half-filled value would be a lane claiming it can be reached.
    public init?(workspace: String?, surface: String?) {
        guard let workspace, !workspace.isEmpty, let surface, !surface.isEmpty else { return nil }
        self.init(workspace: workspace, surface: surface)
    }
}
