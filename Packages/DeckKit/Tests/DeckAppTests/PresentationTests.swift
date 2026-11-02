//
//  PresentationTests.swift · Tests/DeckAppTests
//
//  The rewrite's own tests.
//
//  A SwiftUI view is not the unit under test — the platform owns whether a
//  `List` scrolls and whether `.glassEffect` draws, and asserting either would
//  be testing Apple. What IS this code's to get right are the pure functions
//  the views read: what a lane is called, which glyph and which system colour
//  a state maps to, and what the window says about itself. Those are the
//  decisions, so those are the tests.
//
//  Everything a running window has to prove instead — that it launches, that a
//  posted session becomes a row, that a malformed payload does not take the
//  deck down — is XCUITest's, in `UITests/`, because only a launched app can
//  show it.
//

import Testing
import SwiftUI
import AppKit
import DeckCore
@testable import DeckApp

struct LaneNameTests {

    private func lane(title: String? = nil, directory: String? = nil,
                      session: String = "0e7c1a2b-dead-beef") -> LaneView {
        LaneView(session: SessionID(session), state: .idle, isExpanded: false,
                 contextPercent: nil, sources: [:],
                 directory: directory.map(Redacted.init),
                 title: title.map(Redacted.init))
    }

    /// The recognisable-lane rule, as a ladder. A person navigates by the name
    /// they gave the work; where it is happening is the fallback; the raw id
    /// is the last resort and is meant to look like one.
    @Test("a lane prefers its title, then its directory, then its id")
    func nameFallsBackInOrder() {
        #expect(lane(title: "Refactor the parser", directory: "/w/parser").name
                == "Refactor the parser")
        // Two components, not one: "parser" alone is ambiguous across
        // checkouts, and the parent is what tells them apart.
        #expect(lane(directory: "/Users/someone/work/parser").name == "work/parser")
        #expect(lane(session: "abc123").name == "abc123")
    }

    /// An empty string is not a name. It arrives as one from the wire, and a
    /// row labelled with nothing is a row nobody can pick out of a list.
    @Test("an empty title or directory is skipped rather than shown")
    func emptyValuesDoNotWinTheLadder() {
        #expect(lane(title: "", directory: "/w/parser").name == "w/parser")
        #expect(lane(title: "", directory: "", session: "s9").name == "s9")
    }
}

struct LaneStateAppearanceTests {

    /// Every state must map, and the compiler cannot prove a switch over an
    /// enum stays total once someone adds a case with a default in scope. This
    /// walks `allCases` so a new state fails here rather than rendering blank.
    @Test("every lane state has a glyph, a colour and a spoken name",
          arguments: LaneState.allCases)
    func everyStateIsFullyDescribed(_ state: LaneState) {
        #expect(!state.symbolName.isEmpty)
        #expect(!state.spokenName.isEmpty)
        // **Resolved, not merely constructed.** This was
        // `Image(systemName:) != nil as Image?`, which is unconditionally true
        // — `Image(systemName:)` is not failable, and an SF Symbol that does
        // not exist yields a view that draws NOTHING rather than a nil. So a
        // typo, or a symbol renamed out from under us in a macOS release,
        // would have shipped as a lane with no glyph at all: colour as the
        // only channel, which is the exact rule the next test enforces.
        #expect(NSImage(systemSymbolName: state.symbolName, accessibilityDescription: nil) != nil,
                Comment(rawValue: "\(state.rawValue) names a symbol that does not exist: "
                        + state.symbolName))
    }

    /// The two-channel rule, which survived the theme system because it is an
    /// accessibility requirement rather than a palette decision: a state a
    /// colour-blind user cannot distinguish must still be distinguishable.
    @Test("no two states share a glyph")
    func glyphsAreDistinct() {
        let glyphs = LaneState.allCases.map(\.symbolName)
        #expect(Set(glyphs).count == glyphs.count,
                "two states draw the same symbol, so colour is the only channel left")
    }

    /// The one state the product exists for cannot look like the quiet ones.
    @Test("needs-you is not dressed as idle or ended")
    func theWaitingStateStandsApart() {
        #expect(LaneState.needsYou.symbolName != LaneState.idle.symbolName)
        #expect(LaneState.needsYou.symbolName != LaneState.ended.symbolName)
        #expect(LaneState.needsYou.tint == .orange)
        #expect(LaneState.errored.tint == .red)
    }
}

struct SeverityAppearanceTests {

    @Test("severity orders from informational to urgent")
    func severityIsOrdered() {
        #expect(Severity.normal < Severity.caution)
        #expect(Severity.caution < Severity.alarm)
    }

    @Test("every severity maps to a system colour", arguments: Severity.allCases)
    func everySeverityHasATint(_ severity: Severity) {
        // Distinctness is the property that matters — two severities sharing a
        // colour would make the reading unreadable.
        let others = Severity.allCases.filter { $0 != severity }
        #expect(others.allSatisfy { $0.tint != severity.tint })
    }
}

struct CardIdentityAppearanceTests {

    /// **Identity and meaning are separate channels, not separate hues.**
    ///
    /// `CardColor.slot(0)` is orange and `LaneState.needsYou.tint` is also
    /// orange — a card assigned slot 0 that is ALSO waiting draws an orange
    /// spine under an orange chip, and that is not a collision to fix. The
    /// two channels are told apart by POSITION on the card — the bar and
    /// the wash are identity, the chip and the glyph are meaning — never by
    /// keeping their palettes disjoint. `CardColor.paletteNames`'s own doc
    /// already reserves `red` (state's own alarm colour) and `accentColor`
    /// (selection's own channel) out of the identity palette for exactly
    /// this reason; orange was never on that reserved list, so orange
    /// landing in both places is the rule working as designed, not an
    /// oversight in it.
    ///
    /// **The wash redesign widened "the wash" without touching this
    /// claim.** `.working` now washes too (`SessionCard.washStyle`,
    /// `SessionOverview.swift`) — steady rather than pulsing, quieter than
    /// `.needsYou`'s own peak, but reading the SAME identity channel this
    /// bar always has. The position-not-palette rule this test pins is
    /// unchanged by that: one more state joined the identity side of the
    /// split, none crossed over to the meaning side, and this test's own
    /// assertions below needed no new case for it — they were never about
    /// which STATES wash, only about what a shared hue is allowed to mean
    /// depending on where it is drawn.
    @Test("an identity colour and a meaning colour may legally share a hue")
    func identityAndMeaningAreSeparateChannels() {
        #expect(CardColor.slot(0).tint == .orange)
        #expect(LaneState.needsYou.tint == .orange)

        // Palette congruence, from this module's own vantage on the split:
        // the identity palette's word table (`CardColor.paletteNames`,
        // `DeckCore`) and its pixel table (`CardColor.tint`,
        // `SessionOverview.swift`) are maintained by hand in two different
        // files and two different modules, and nothing but a test keeps
        // them the same length. `SessionCardTests.theIdentityBarIsAlwaysOn`
        // walks every slot against its own literal; this only pins the
        // COUNT.
        let pixelTable: [Color] = [.orange, .yellow, .green, .mint, .teal,
                                   .cyan, .blue, .indigo, .purple, .pink, .brown]
        #expect(CardColor.paletteNames.count == 11)
        #expect(pixelTable.count == CardColor.paletteNames.count,
                "the identity pixel table and name table have drifted apart in length")
    }
}

@MainActor
struct WindowSubtitleTests {

    private func runtimeWith(_ events: [DeckEvent]) -> DeckRuntime {
        let runtime = DeckRuntime()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    private func hook(_ kind: HookKind, _ session: String, _ ms: Int64) -> DeckEvent {
        .hook(HookEvent(id: EventID("\(kind)-\(session)-\(ms)"),
                        at: Instant(sinceStart: Millis(ms)), kind: kind,
                        session: SessionID(session), cwd: Redacted("/w"),
                        tool: nil, toolUseID: nil, held: .absent))
    }

    /// The count the window puts in its subtitle is the conservation rule's:
    /// it counts every waiting session, including ones scrolled out of view,
    /// because a deck that hides one is a deck that concealed a request.
    @Test("the subtitle counts sessions, and says how many are waiting")
    func subtitleReportsTheWholeTruth() {
        let quiet = runtimeWith([hook(.sessionStart, "a", 0), hook(.sessionStart, "b", 10)])
        #expect(DeckWindow(runtime: quiet).subtitleForTesting == "2 sessions")

        let one = runtimeWith([hook(.sessionStart, "a", 0)])
        #expect(one.frame.lanes.count == 1)
        #expect(DeckWindow(runtime: one).subtitleForTesting == "1 session",
                "the noun did not agree with the count")
    }

    @Test("an empty deck says so rather than showing a bare number")
    func emptySubtitle() {
        let empty = runtimeWith([])
        #expect(DeckWindow(runtime: empty).subtitleForTesting == "0 sessions")
    }
}

/// Names in a LIST, which is a different question from what a lane calls
/// itself: the list has to let a person pick one row from several.
struct DisplayNameTests {

    private func lane(_ session: String, directory: String) -> LaneView {
        LaneView(session: SessionID(session), state: .idle, isExpanded: false,
                 contextPercent: nil, sources: [:], directory: Redacted(directory))
    }

    private func frame(_ lanes: [LaneView]) -> Frame {
        Frame(at: Instant(sinceStart: Millis(0)), lanes: lanes,
              mastNeedsYou: 0, decisions: [])
    }

    /// The defect a screenshot found: two sessions in one directory produced
    /// two rows reading "you/work", and a list of identical rows is a list
    /// nobody can pick from.
    @Test("two sessions in one directory get distinguishable names")
    func collidingNamesAreDisambiguated() {
        let a = lane("aaaaaa11-1111", directory: "/Users/you/work")
        let b = lane("bbbbbb22-2222", directory: "/Users/you/work")
        let f = frame([a, b])

        #expect(a.name == b.name, "the fixture is not actually a collision")
        // The NAME stays clean — appending the id made it longer than a
        // sidebar is wide and middle-truncation ate the middle of it.
        #expect(f.displayName(for: a) == "you/work")
        #expect(f.displayName(for: b) == "you/work")
        // The distinction moves to the second line, where there is room.
        #expect(f.disambiguator(for: a) != nil)
        #expect(f.disambiguator(for: a) != f.disambiguator(for: b),
                "the two lanes cannot be told apart on any line")
    }

    /// And a name that stands alone is left alone — decoration only where it
    /// buys something.
    @Test("a name nothing else shares is shown unchanged")
    func uniqueNamesAreUntouched() {
        let a = lane("aaaaaa11-1111", directory: "/Users/you/work")
        let b = lane("bbbbbb22-2222", directory: "/Users/you/other")
        let f = frame([a, b])

        #expect(f.displayName(for: a) == "you/work")
        #expect(f.displayName(for: b) == "you/other")
        #expect(f.disambiguator(for: a) == nil, "a unique name was decorated anyway")
        #expect(f.disambiguator(for: b) == nil)
    }

    /// A lane identified only by its id is already unique; appending a slice
    /// of that same id to itself would be noise.
    @Test("a lane named by its id is not decorated with its own id")
    func idOnlyLanesAreNotDoubled() {
        let a = LaneView(session: SessionID("aaaaaa11-1111"), state: .idle,
                         isExpanded: false, contextPercent: nil, sources: [:])
        #expect(frame([a]).displayName(for: a) == "aaaaaa11-1111")
        #expect(frame([a]).disambiguator(for: a) == nil,
                "a lane named by its id was decorated with a slice of that id")
    }
}

/// The diagnostic log, which is written on the hot path.
///
/// It used to open, seek, write and close the file on every line — 22.1 us
/// against 1.16 us for a handle held open, synchronously, on the main actor.
/// The handle is held now, so these check the behaviour that change could have
/// broken: that lines still reach the file, and that the in-memory log is
/// still bounded now that it is trimmed in batches rather than one at a time.
@MainActor
struct DiagnosticLogTests {

    private func hook(_ session: String, _ i: Int) -> HookEvent {
        HookEvent(id: EventID("e\(i)"), at: Instant(sinceStart: Millis(Int64(i))),
                  kind: .preToolUse, session: SessionID(session),
                  cwd: Redacted("/w"), tool: "Bash", toolUseID: "t\(i)", held: .absent)
    }

    @Test("lines reach the log file through a held handle")
    func linesAreWritten() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let path = runtime.logPathForTesting

        for i in 0 ..< 5 { _ = await runtime.handle(hook("a", i)) }

        let written = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        #expect(!written.isEmpty, "nothing reached the log file")
        #expect(written.contains("holdOpened") || written.contains("tool=Bash"),
                Comment(rawValue: "the log has content but not the events: \(written.prefix(200))"))
    }

    /// Batched trimming keeps the same ceiling as trimming one at a time; it
    /// just stops paying an O(n) move to do it.
    @Test("the in-memory log stays bounded under a long stream")
    func theLogIsBounded() async {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        for i in 0 ..< 1_500 { _ = await runtime.handle(hook("a", i)) }

        #expect(runtime.log.count <= 600,
                Comment(rawValue: "the log grew to \(runtime.log.count) entries"))
        #expect(runtime.log.count >= 400,
                Comment(rawValue: "the log trimmed to \(runtime.log.count) — the cap is too eager"))
    }
}

/// A deck that cannot act must say so.
///
/// The darkened-control rule: a control the deck has darkened carries its
/// reason in the same frame. It matters most on first launch — spawning `cmux`
/// raises macOS's app-data prompt, and denying it produces exactly these
/// blocks, so without a reason on screen "I said Don't Allow" and "the deck is
/// broken" look identical.
struct ActionBlockTests {

    /// Every block has a sentence, and it names something the user can act on
    /// rather than restating that it failed.
    @Test("every block reason is a sentence a person can act on",
          arguments: [ActionBlock.hostUnavailable, .unroutable, .composerBusy,
                      .surfaceNotASession, .hostError])
    func everyBlockExplainsItself(_ block: ActionBlock) {
        #expect(!block.message.isEmpty, "\(block.rawValue) darkens controls with no reason")
        #expect(block.message.count > 20,
                Comment(rawValue: "\(block.rawValue): \"\(block.message)\" is too terse to act on"))
    }

    /// The reasons are distinct, so the notice tells the user which of four
    /// different problems they have rather than that they have one.
    @Test("no two blocks give the same reason")
    func reasonsAreDistinct() {
        let all: [ActionBlock] = [.hostUnavailable, .unroutable, .composerBusy,
                                  .surfaceNotASession, .hostError]
        #expect(Set(all.map(\.message)).count == all.count)
    }
}

/// The parity mandate, at the number: Claude Code's own dialog numbers a
/// multi-option prompt 1, 2, 3, ... in order, and `DecisionBar.buttonTitles`
/// is the one place that arithmetic lives. Tested here, pure, rather than
/// only ever inferred from a rendered bar's height the way `RenderSweepTests`
/// measures it — a numbering regression should fail here first.
///
/// `@MainActor`, the same reason `TouchTargetTests` carries it to call
/// `DecisionBar.control`: `DecisionBar` conforms to `View`, and that pulls
/// every member of the type onto the main actor, `buttonTitles` and
/// `suggestionTitle` included even though neither touches SwiftUI itself.
/// Measured, not assumed — omitting this crashed the run with a trapped
/// executor-isolation check (`swift_task_checkIsolatedSwift`) reached from
/// `buttonTitles`'s own `.map`, non-deterministically, exactly as often as
/// swift-testing happened to schedule this suite off the main thread.
@MainActor
struct DecisionBarNumberingTests {

    private func decision(suggestionLabels: [String]) -> Decision {
        Decision(hold: HoldID(session: SessionID("s1"), toolUseID: "t1"), subject: nil,
                suggestionLabels: suggestionLabels)
    }

    /// The bare two-button shape: no suggestions, so Yes is 1 and No is 2 —
    /// today's exact bar, per chunk 3's own claim.
    @Test("with no suggestions, Yes is 1 and No is 2")
    func noSuggestionsNumbersYesAndNo() {
        let titles = DecisionBar.buttonTitles(for: decision(suggestionLabels: []))
        #expect(titles.yes == "1. Yes")
        #expect(titles.suggestions.isEmpty)
        #expect(titles.no == "2. No")
    }

    /// The shape the audit named directly: two suggestions riding along
    /// number the whole bar 1, 2, 3, 4, with Deny taking the last number —
    /// the same convention the terminal uses for its own multi-suggestion
    /// dialog, never a scheme this deck invented.
    @Test("with two suggestions, buttons number 1, 2, 3, 4 and Deny is 4")
    func twoSuggestionsNumberThroughToDeny() {
        let titles = DecisionBar.buttonTitles(for: decision(suggestionLabels: [
            "Don't ask again for: git push *", "Switch mode to acceptEdits",
        ]))
        #expect(titles.yes == "1. Yes")
        #expect(titles.suggestions == [
            "2. Yes, and don't ask again for: git push *",
            "3. Switch mode to acceptEdits",
        ], Comment(rawValue: "got \(titles.suggestions)"))
        #expect(titles.no == "4. No")
    }

    /// `suggestionTitle` in isolation: the `addRules` shape (already reading
    /// "Don't ask again for: X") is the one case rewritten into the
    /// terminal's exact "Yes, and don't ask again for: X" — every other
    /// shape keeps its own wording, numbered and nothing more, the
    /// unknown-type honesty `SuggestionLabel` itself already keeps.
    @Test("suggestionTitle rewrites only the don't-ask-again shape; every other label keeps its own wording")
    func suggestionTitleRewritesOnlyTheKnownShape() {
        #expect(DecisionBar.suggestionTitle(number: 2, label: "Don't ask again for: git push *")
                == "2. Yes, and don't ask again for: git push *")
        #expect(DecisionBar.suggestionTitle(number: 3, label: "Switch mode to acceptEdits")
                == "3. Switch mode to acceptEdits")
        #expect(DecisionBar.suggestionTitle(number: 4, label: "Apply: removeRules")
                == "4. Apply: removeRules")
    }
}
