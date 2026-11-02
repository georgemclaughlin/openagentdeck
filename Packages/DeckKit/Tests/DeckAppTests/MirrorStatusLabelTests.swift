//
//  MirrorStatusLabelTests.swift · Tests/DeckAppTests
//
//  `MirrorStatusLabel.status(for:)`'s own doc comment names this suite as
//  the reason the switch was pulled apart from the view in the first
//  place — pinned here so a future edit to `QuestionMirrorCard` or
//  `QuestionMirrorStage` cannot drift the copy either surface reads
//  without failing loudly. The risk: two independent
//  copies of this four-case switch, same three `ResolvedOrigin` sentences,
//  same icons, same dimming, with nothing but a doc comment on one side
//  claiming they would never disagree. This is the one test pinning the
//  three sentences, plus the other two cases for
//  completeness.
//

import Testing
import DeckCore
@testable import DeckApp

@MainActor
struct MirrorStatusLabelTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    // ------------------------------------------------------- deckWindow

    /// `.deckWindow` never reaches a mirror surface — `Projection.frame
    /// .mirrors` and `DeckWindow.stageMirror` both exclude it — so the
    /// label has nothing honest to say and renders nothing.
    @Test("a mirror still on the deck window has no status label")
    func deckWindowHasNoLabel() {
        #expect(MirrorStatusLabel.status(for: .deckWindow) == nil)
    }

    // --------------------------------------------------- released / live

    /// **A state in motion, not a dead end.** The copy names what it is
    /// waiting FOR, rather than reading as a flat, finished fact — the
    /// exact copy a stuck mirror used to render before
    /// this stage's duration was bounded.
    @Test("a released mirror reads 'Terminal is opening the question…', dimmed")
    func releasedReadsTerminalIsOpeningTheQuestion() {
        let status = MirrorStatusLabel.status(for: .released(at: at(0)))
        #expect(status?.text == "Terminal is opening the question…")
        #expect(status?.icon == "terminal")
        #expect(status?.dimmed == true)
    }

    @Test("a forwardable mirror reads 'Answerable from here', undimmed")
    func terminalLiveReadsAnswerableFromHere() {
        let status = MirrorStatusLabel.status(for: .terminalLive(at: at(0)))
        #expect(status?.text == "Answerable from here")
        #expect(status?.icon == "terminal.fill")
        #expect(status?.dimmed == false)
    }

    /// **D5's own branch — the awaiting-confirmation window.** Set the
    /// instant a plan completes, before anything has had a chance to
    /// confirm or fail to confirm it. Undimmed (the mirror is not
    /// grayed out, options are merely disabled via `optionsDisabled`,
    /// which this label does not itself control), paperplane rather than
    /// a plain terminal glyph — the send genuinely happened.
    @Test("a terminalLive mirror awaiting confirmation reads 'Answer sent — waiting for the terminal', undimmed")
    func terminalLiveAwaitingConfirmationReadsSo() {
        let status = MirrorStatusLabel.status(for: .terminalLive(at: at(0)), awaitingConfirmation: true)
        #expect(status?.text == "Answer sent — waiting for the terminal")
        #expect(status?.icon == "paperplane")
        #expect(status?.dimmed == false)
    }

    /// **D4's own branch — renamed from `forwardDidNotLand`: the deck can confirm
    /// a landing but never truly confirm its absence, and the old copy
    /// claimed the latter.** Undimmed, still interactive (the row-level
    /// guards read `mirror.optionsDisabled`, not this label), with
    /// `MirrorSendAgainRow` as the literal instruction rather than a dead
    /// end — never a claim that the tap failed.
    @Test("a terminalLive mirror with no confirmation yet reads so, undimmed")
    func terminalLiveWithForwardUnconfirmedReadsSo() {
        let status = MirrorStatusLabel.status(for: .terminalLive(at: at(0)), forwardUnconfirmed: true)
        #expect(status?.text == "No confirmation yet")
        #expect(status?.icon == "exclamationmark.triangle")
        #expect(status?.dimmed == false)
    }

    /// **Precedence — `forwardUnconfirmed` wins when both are true.** The
    /// reducer never clears `forwardSentAt` (which `awaitingConfirmation`
    /// reads) when it sets `forwardUnconfirmedAt` — both are legitimately
    /// true at once once the allowance elapses — and "no confirmation
    /// yet" is the more specific, more actionable claim of the two.
    @Test("forwardUnconfirmed takes precedence over awaitingConfirmation when both are true")
    func forwardUnconfirmedTakesPrecedenceOverAwaitingConfirmation() {
        let status = MirrorStatusLabel.status(for: .terminalLive(at: at(0)),
                                              awaitingConfirmation: true, forwardUnconfirmed: true)
        #expect(status?.text == "No confirmation yet")
    }

    /// The default — both flags default to `false` on the view and the
    /// static function — so every EXISTING call site (the plain
    /// `.terminalLive` case above, and every one of the
    /// `resolved`/`released` tests) keeps reading the ordinary copy
    /// unless it explicitly opts in.
    @Test("awaitingConfirmation and forwardUnconfirmed both default to false and change nothing by themselves")
    func bothD5FlagsDefaultToFalse() {
        let bare = MirrorStatusLabel.status(for: .terminalLive(at: at(0)))
        let explicit = MirrorStatusLabel.status(for: .terminalLive(at: at(0)),
                                                awaitingConfirmation: false, forwardUnconfirmed: false)
        #expect(bare?.text == explicit?.text)
        #expect(bare?.text == "Answerable from here")
    }

    // ----------------------------------------------------- the drift arbiter

    /// **Extended for D4/D5 — every distinguishable state this label can
    /// render, one sentence apiece, no two alike.** `resolvedOriginsAreAllDistinct`
    /// below already proved this for the three `resolved` origins in
    /// isolation; this is the WHOLE label, every stage and every
    /// `.terminalLive` sub-state together, so a future case that
    /// happens to reuse an existing sentence fails here rather than
    /// shipping two states a glance cannot tell apart.
    @Test("no two states of the whole label share a sentence")
    func noTwoWholeLabelStatesShareASentence() {
        let answers = [Answer(question: Redacted("Race"), labels: [Redacted("Skip this question")])]
        let sentences = [
            MirrorStatusLabel.status(for: .released(at: at(0)))?.text,
            MirrorStatusLabel.status(for: .terminalLive(at: at(0)))?.text,
            MirrorStatusLabel.status(for: .terminalLive(at: at(0)), awaitingConfirmation: true)?.text,
            MirrorStatusLabel.status(for: .terminalLive(at: at(0)), forwardUnconfirmed: true)?.text,
            MirrorStatusLabel.status(for: .resolved(answers: answers, origin: .deck, at: at(0)))?.text,
            MirrorStatusLabel.status(for: .resolved(answers: answers, origin: .terminal, at: at(0)))?.text,
            MirrorStatusLabel.status(for: .resolved(answers: answers, origin: .movedOn, at: at(0)))?.text,
        ]
        #expect(Set(sentences).count == sentences.count, "\(sentences)")
    }

    // ------------------------------------------------------- resolved ×3

    /// The App delivery's own explicit requirement: "answered-elsewhere
    /// copy distinct from deck-answered." All three sentences pinned
    /// together so the distinction stays visible in one place, not just
    /// asserted piecemeal.
    @Test("each resolved origin reads its own distinct sentence",
          arguments: [
            (ResolvedOrigin.deck, "Answered on the deck", "checkmark.circle.fill"),
            (ResolvedOrigin.terminal, "Answered in the terminal", "checkmark.circle"),
            (ResolvedOrigin.movedOn, "The session moved on", "xmark.circle"),
          ])
    func resolvedOriginsReadDistinctSentences(_ origin: ResolvedOrigin, _ text: String, _ icon: String) {
        let answers = [Answer(question: Redacted("Race"), labels: [Redacted("Skip this question")])]
        let status = MirrorStatusLabel.status(for: .resolved(answers: answers, origin: origin, at: at(0)))
        #expect(status?.text == text)
        #expect(status?.icon == icon)
    }

    /// No two of the three resolved sentences may collapse into the same
    /// string — the whole point of carrying `origin` as its own field
    /// rather than inferring it from `answers == nil` (`MirrorStage
    /// .resolved`'s own doc comment states why that inference already
    /// fails once).
    @Test("no two resolved origins share a sentence")
    func resolvedOriginsAreAllDistinct() {
        let answers = [Answer(question: Redacted("Race"), labels: [Redacted("Skip this question")])]
        let sentences = [ResolvedOrigin.deck, .terminal, .movedOn].map {
            MirrorStatusLabel.status(for: .resolved(answers: answers, origin: $0, at: at(0)))?.text
        }
        #expect(Set(sentences).count == sentences.count, "\(sentences)")
    }

    /// `dimmed` reads `answers == nil`, not the origin — a `resolved`
    /// mirror with nothing chosen dims regardless of which origin
    /// produced it, the same as `.released` above.
    @Test("a resolved mirror with nothing chosen still reads dimmed")
    func resolvedWithNoAnswersIsDimmed() {
        let status = MirrorStatusLabel.status(for: .resolved(answers: nil, origin: .movedOn, at: at(0)))
        #expect(status?.dimmed == true)
    }

    @Test("a resolved mirror with a real answer reads undimmed")
    func resolvedWithAnswersIsNotDimmed() {
        let answers = [Answer(question: Redacted("Race"), labels: [Redacted("Skip this question")])]
        let status = MirrorStatusLabel.status(for: .resolved(answers: answers, origin: .deck, at: at(0)))
        #expect(status?.dimmed == false)
    }
}
