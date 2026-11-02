//
//  PromptProvenance.swift · DeckCore/Model
//
//  Whether a UserPromptSubmit's own text was TYPED by a person or INJECTED by
//  the machine — and why the wire alone cannot say so honestly.
//
//  Claude Code fires UserPromptSubmit for MACHINE-injected turns exactly as it
//  does for a person: a background-task completion arrives as a user-role
//  message whose entire text is a `<task-notification>…` envelope, with NO
//  distinguishing metadata on the wire (no `isMeta` flag, no separate hook
//  kind), only the text's own shape. Absorbing `h.prompt` verbatim would make
//  a robot wake-up the card's LAST USER PROMPT, a fact nobody said.
//
//  **The fix is a CLOSED set of EXACT leading-envelope prefixes, matched
//  after whitespace trim — never a substring, never a generic "starts with
//  `<`" heuristic.**
//
//    - NEVER a substring. Matching "somewhere in the text" instead of "is the
//      text" lets false positives through: a person's own words merely
//      CONTAINING an envelope tag are a real prompt.
//    - NEVER a generic prefix heuristic. A person pasting a snippet of XML
//      starts with `<` and must not vanish from the card because it LOOKS
//      like an envelope. Only the SEVEN shapes below, byte-exact, count.
//
//  **An envelope this set does not yet know FAILS OPEN.** A future injection
//  shape renders verbatim, as if a person had typed it: a rare, visible miss.
//  Failing CLOSED (hiding anything unrecognised) would trade that for a
//  silent, permanent one.
//

/// A `PromptProvenance` value is the answer to one question: does this
/// text belong to the person, or to the machine? `classify(_:)` is the only
/// way to get one — there is no public initializer, because the answer is
/// always derived, never asserted.
public enum PromptProvenance: Equatable, Sendable {
    /// A person typed this, or nothing in the closed set below says
    /// otherwise. The default a classifier that fails open always reaches.
    case human
    /// The leading bytes, after trimming, match one of the seven recorded
    /// envelope shapes exactly.
    case machine

    /// **The closed set: seven shapes, each an EXACT leading prefix after
    /// whitespace trim.**
    ///
    /// - `<task-notification>`: a background task's completion, wrapping
    ///   `<task-id>`, `<tool-use-id>` and further fields. The shape that
    ///   motivated the classifier (`PromptHistoryTests.taskNotificationFixture`
    ///   carries the recorded shape).
    /// - `<teammate-message>`: a relay from another agent in the same team.
    /// - `<local-command-caveat>`, `<command-name>`, `<local-command-stdout>`:
    ///   the envelope pieces a LOCAL slash command echoes into the transcript
    ///   as a synthetic user turn; which one leads depends on which piece of
    ///   output landed first.
    /// - `[Request interrupted`: not XML, but the terminal's plain-text notice
    ///   that a turn was cut off; just as much the machine narrating to itself.
    /// - "This session is being continued from a previous conversation that
    ///   ran out of context.": the context-compaction summary the harness
    ///   injects after compacting. Confirmed against real transcripts
    ///   (`PromptHistoryTests.contextCompactionSummaryFixture`). The common
    ///   prefix across occurrences was 165 bytes before wording varied by
    ///   Claude Code version; this entry uses the first 87, the whole leading
    ///   sentence, inside that stable span.
    ///
    /// This is a set, not a priority list: no caller may rely on WHICH prefix
    /// matched, only THAT one did.
    static let machineEnvelopePrefixes: [String] = [
        "<task-notification>",
        "<teammate-message>",
        "<local-command-caveat>",
        "<command-name>",
        "<local-command-stdout>",
        "[Request interrupted",
        "This session is being continued from a previous conversation that ran out of context.",
    ]

    /// The one place this decision gets made. Pure: the question is entirely
    /// about the BYTES. What a caller does with `.machine` (bar it from
    /// becoming an identity fact, still let the turn move the lane to
    /// `.working`) is the reducer's job.
    public static func classify(_ text: String) -> PromptProvenance {
        let trimmed = text.trimmed
        return machineEnvelopePrefixes.contains { trimmed.hasPrefix($0) } ? .machine : .human
    }
}
