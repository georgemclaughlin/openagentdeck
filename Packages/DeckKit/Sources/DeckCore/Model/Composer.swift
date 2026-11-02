//
//  Composer.swift · DeckCore/Model
//
//  The deck never types into a composer it did not empty.
//
//  Sending blind splices onto whatever the person half-typed (measured, LV23:
//  `MYDRAFT reply with exactly LV23D` arrived as one prompt), and clearing the
//  composer first destroys a draft the deck never saw. The host can be READ,
//  so the deck looks, and refuses unless the composer is empty.
//
//  The predicate is calibrated on a RECORDING, not on a memory of what the
//  REPL looks like. `fixtures/live/LV30-multitab/screen-B.txt` is a live
//  Claude Code session's screen as the host reported it:
//
//      ────────────────────────────────────────────
//      ❯
//      ────────────────────────────────────────────
//        main  |  /Users/…/project  |  ctx:3%
//        ⏸ manual mode on · ← 1 agent
//
//  and `screen-A.txt`, from the same run, shows a surface whose session had
//  never started: a SHELL with no `❯` at all, where sending costs
//  `zsh: command not found: reply` (LV30). So "not a session" is a distinct
//  answer from "a session with a draft", and both refuse.
//
//  Pure text in, one enum out. The adapter fetches the screen; the core
//  judges it; the screen is dropped on the spot and never stored, logged or
//  encoded (the redaction rule: a session's screen is the densest payload in
//  this system).
//

public enum Composer {

    /// What the surface is showing, as far as sending is concerned.
    public enum Reading: String, Equatable, Codable, Sendable {
        /// A prompt, with nothing typed at it. The only state the deck may send
        /// into.
        case empty
        /// A prompt with text at it. Somebody is mid-thought; the composer-ownership rule refuses.
        case holdingText
        /// No prompt found. A shell, a pager, a session that has not started —
        /// anything, and the deck may not guess which.
        case notASession
    }

    /// Claude Code's REPL prompt. One glyph, and the reason the check is a
    /// glyph rather than a regex over the whole screen: the composer is the
    /// LAST prompt on the surface, and a transcript above it may quote earlier
    /// ones.
    static let prompt: Character = "❯"

    /// Claude Code 2.1.231's queued-state placeholder, measured live:
    /// `fixtures/live/LV39-queued-composer/screen-queued.txt` carries the
    /// recorded composer line byte-for-byte (the surrounding screen is
    /// synthesized; see its `PROVENANCE.md`). A session mid-turn with one
    /// message queued draws this sentence where an idle one draws nothing.
    /// Matched as the WHOLE sentence after trimming Unicode whitespace on both
    /// ends, not a prefix or substring. Anything else after the glyph (one more
    /// character, a different case) still reads as `holdingText`.
    static let queuedPlaceholder = "Press up to edit queued messages"

    /// Read the surface. Whatever the host handed over, newest last.
    ///
    /// **Unicode whitespace, not ASCII.** The empty composer in `screen-B.txt`
    /// is `e2 9d af c2 a0`: the prompt glyph followed by U+00A0, a NO-BREAK
    /// SPACE. An ASCII-only trim reads that as text and would silently refuse
    /// every send.
    public static func read(_ screen: String) -> Reading {
        var atPrompt: Substring?
        for line in screen.split(separator: "\n", omittingEmptySubsequences: false) {
            let rest = line.drop(while: \.isWhitespace)
            guard rest.first == prompt else { continue }
            // The last one wins: the composer is at the bottom, and a
            // transcript above it may quote earlier prompts.
            atPrompt = rest.dropFirst()
        }
        guard let atPrompt else { return .notASession }
        // Trim both ends Unicode-aware with `drop(while:)`, never
        // `CharacterSet` (this file stays Foundation-free), so the
        // placeholder matches however the host pads it.
        let leading = atPrompt.drop(while: \.isWhitespace)
        let trimmed = String(leading.reversed().drop(while: \.isWhitespace).reversed())
        if trimmed.isEmpty { return .empty }
        return trimmed == queuedPlaceholder ? .empty : .holdingText
    }

    /// May the deck type here? **Fails closed**, with one measured exception:
    /// Claude Code 2.1.231's queued-state placeholder (`queuedPlaceholder`,
    /// LV39) is read as empty, because sending in that state queues cleanly.
    /// Every other string after the glyph still refuses.
    ///
    /// Accepted trade: a draft that is verbatim "Press up to edit queued
    /// messages" is misread as empty. A pty screen carries characters, not
    /// styling, so placeholder chrome and typed text are indistinguishable.
    /// The collision is contrived; refusing to type is recoverable, typing
    /// over a draft is not.
    public static func maySend(into reading: Reading) -> Bool {
        reading == .empty
    }

    /// The block a refusal reports. One mapping, so the panel's reason and the
    /// send's refusal cannot disagree. One block per READING: a shell prompt
    /// must not be reported as a full composer.
    public static func block(for reading: Reading) -> ActionBlock? {
        switch reading {
        case .empty: nil
        case .holdingText: .composerBusy
        case .notASession: .surfaceNotASession
        }
    }
}
