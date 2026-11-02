//
//  ShellTests.swift · Tests/DeckAppTests
//
//  The window around the fleet: what opens the detail, what closes it, and
//  whether the deck can be seen to be alive.
//
//  These guard the defect that motivated the whole rewrite. The old shell put
//  the fleet behind `selection == nil` and then offered no way to reach that
//  state — deselecting a macOS `List` takes a command-click — so the overview
//  was, in normal use, unreachable. Nothing in the suite noticed, because
//  every test asked what a component rendered and none asked whether anything
//  could get to it.
//

import Testing
import SwiftUI
import AppKit
import DeckCore
@testable import DeckApp

@MainActor
struct ShellTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    private func lane(_ id: String, state: LaneState = .idle) -> LaneView {
        LaneView(session: SessionID(id), state: state, isExpanded: false,
                 contextPercent: nil, sources: [:],
                 directory: Redacted("/w/\(id)"),
                 host: HostAddress(workspace: "w", surface: id))
    }

    private func frame(_ lanes: [LaneView], selection: SessionID? = nil) -> Frame {
        Frame(at: at(0), lanes: lanes,
              mastNeedsYou: lanes.filter { $0.state == .needsYou }.count,
              decisions: [], selection: selection)
    }

    // ------------------------------------------------- getting to the detail

    /// **There is a way in and a way back.**
    ///
    /// The control that did not exist. With nothing selected the button opens
    /// a session; with one selected it returns to the fleet. Both directions,
    /// from one control, because a toggle that only goes one way is how the
    /// overview became unreachable in the first place.
    @Test("the details control opens and closes")
    func theDetailControlGoesBothWays() {
        let lanes = [lane("alpha"), lane("beta")]

        let closed = DeckWindow.detailToggle(for: frame(lanes))
        #expect(closed == .open(SessionID("alpha")),
                "with nothing selected the control does not open anything")

        let open = DeckWindow.detailToggle(for: frame(lanes, selection: SessionID("alpha")))
        #expect(open == .close,
                "with a session selected there is no way back to the fleet")
    }

    /// Opening lands on the session that is asking for a human, not on
    /// whichever happens to be first. Somebody opening the detail while a
    /// request is waiting meant that request.
    @Test("opening the detail lands on the session that is waiting")
    func openingPrefersTheWaitingSession() {
        let lanes = [lane("quiet"), lane("waiting", state: .needsYou), lane("also-quiet")]
        #expect(DeckWindow.detailToggle(for: frame(lanes)) == .open(SessionID("waiting")),
                "the control opened a quiet session while another was asking for a human")
    }

    /// With no sessions there is nothing to inspect, and the control says so
    /// rather than opening an empty pane.
    @Test("an empty deck offers no detail to open")
    func anEmptyDeckHasNothingToInspect() {
        #expect(DeckWindow.detailToggle(for: frame([])) == .unavailable)
    }

    /// **The conservation rule, at the routing layer.**
    ///
    /// `mastNeedsYou` counts hidden lanes deliberately — concealing a request
    /// for a human is the one thing this deck exists not to do — so a control
    /// that searched only the DRAWN lanes produced a deck whose subtitle
    /// truthfully read "1 needs you", whose details button was enabled and
    /// looked like the way there, and which then opened a different, quiet
    /// session instead. Silently. The mute failure this product refuses at the
    /// send layer, committed at the navigation layer.
    @Test("a hidden session that needs a human is still where the control goes")
    func aHiddenWaiterIsStillReachable() {
        var hidden = lane("stashed", state: .needsYou)
        hidden = LaneView(session: hidden.session, state: .needsYou, isExpanded: false,
                          contextPercent: nil, sources: [:],
                          directory: Redacted("/w/stashed"),
                          host: HostAddress(workspace: "w", surface: "stashed"),
                          isHidden: true)
        let f = frame([lane("quiet"), hidden])

        #expect(f.hiddenNeedsYou == 1, "the fixture does not hide a waiting lane")
        #expect(f.mastNeedsYou == 1, "the frame is not counting the hidden waiter")
        #expect(DeckWindow.detailToggle(for: f) == .open(SessionID("stashed")),
                "the control opened a quiet session while a hidden one asked for a human")
    }

    /// **`SessionOverview.showsConnectCard`, pinned pure.** `frame.lanes` (the UNFILTERED set) is the
    /// only honest signal for "has this deck ever heard from a session" —
    /// a lane that is merely hidden is a lane the deck knows about, and
    /// the CONNECTION SETUP card must never claim otherwise. The incident:
    /// hiding the one visible lane used to leave `SessionOverview`'s own
    /// (filtered) `lanes` empty, and the overlay read THAT instead.
    @Test("the connection-setup card shows only on true emptiness, never a filtered-empty view")
    func connectCardShowsOnlyOnTrueEmptiness() {
        #expect(SessionOverview.showsConnectCard(for: frame([])) == true,
                "a genuinely empty deck should show the connection card")

        let hidden = LaneView(session: SessionID("beta"), state: .idle, isExpanded: false,
                              contextPercent: nil, sources: [:],
                              host: HostAddress(workspace: "w", surface: "beta"), isHidden: true)
        #expect(SessionOverview.showsConnectCard(for: frame([hidden])) == false,
                "a deck with one hidden lane is connected — hiding must never read as disconnected")

        #expect(SessionOverview.showsConnectCard(for: frame([lane("alpha")])) == false,
                "an ordinary populated deck should never show the connection card")
    }

    // ------------------------------------------------------- the full-strip stage

    private func questionWithPreview() -> Question {
        Question(text: Redacted("Which?"), header: Redacted("Q"),
                options: [QuestionOption(label: Redacted("A"), detail: Redacted(""),
                                         preview: Redacted("mockup"))],
                multiSelect: false)
    }

    /// **`DeckWindow.stageDecision` — the pure rule the overlay reads, held
    /// to the same standard `detailToggle` above already is.** Two mistakes
    /// this guards against: raising the stage for a decision that belongs to
    /// a session other than the one selected (a takeover offered under the
    /// wrong name — the exact class of bug `DetailBand`'s own
    /// `first(where:)` comment names), and raising it at all with nothing
    /// selected.
    @Test("the stage shows only the selected lane's own previewed decision")
    func stageDecisionShowsOnlyTheSelectedLanesPreviewedCall() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let decision = Decision(hold: hold, subject: nil, questions: [questionWithPreview()])
        let lanes = [lane("alpha"), lane("beta")]

        let selected = Frame(at: at(0), lanes: lanes, mastNeedsYou: 0,
                             decisions: [decision], selection: SessionID("alpha"))
        #expect(DeckWindow.stageDecision(for: selected, dismissedStage: nil) == decision,
                "a previewed question on the selected lane should raise the stage")

        let unselected = Frame(at: at(0), lanes: lanes, mastNeedsYou: 0,
                               decisions: [decision], selection: nil)
        #expect(DeckWindow.stageDecision(for: unselected, dismissedStage: nil) == nil,
                "nothing is selected, so nothing should own the strip")

        let otherSelected = Frame(at: at(0), lanes: lanes, mastNeedsYou: 0,
                                  decisions: [decision], selection: SessionID("beta"))
        #expect(DeckWindow.stageDecision(for: otherSelected, dismissedStage: nil) == nil,
                "the decision belongs to alpha, not the selected beta")
    }

    /// Dismissal is per-hold, not per-session or global — a NEW hold (a
    /// fresh call, even on the same session) is never suppressed by a
    /// dismissal that named a different one.
    @Test("dismissing a hold suppresses only that hold's own stage")
    func stageDecisionRespectsDismissalByHoldIdentity() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let decision = Decision(hold: hold, subject: nil, questions: [questionWithPreview()])
        let f = Frame(at: at(0), lanes: [lane("alpha")], mastNeedsYou: 0,
                      decisions: [decision], selection: SessionID("alpha"))

        #expect(DeckWindow.stageDecision(for: f, dismissedStage: hold) == nil,
                "the dismissed hold should not re-show the stage")

        let other = HoldID(session: SessionID("alpha"), toolUseID: "t2")
        #expect(DeckWindow.stageDecision(for: f, dismissedStage: other) == decision,
                "dismissing a DIFFERENT hold must not suppress this one")
    }

    /// A question with no preview on any option stays exactly where it
    /// always has — `DetailBand`'s own pinned `QuestionTakeover` — because
    /// `QuestionStage`'s whole reason to exist is the room a preview needs.
    @Test("a bare question never raises the stage")
    func stageDecisionIgnoresBareQuestions() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let bare = Question(text: Redacted("Which?"), header: Redacted("Q"),
                            options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                            multiSelect: false)
        let decision = Decision(hold: hold, subject: nil, questions: [bare])
        let f = Frame(at: at(0), lanes: [lane("alpha")], mastNeedsYou: 0,
                      decisions: [decision], selection: SessionID("alpha"))
        #expect(DeckWindow.stageDecision(for: f, dismissedStage: nil) == nil)
    }

    /// **RETIRED — `inspectorNeverOpensAnyMore` and
    /// `inspectorNeverOpensRegardlessOfSelection` used to live here.** Both
    /// held `DeckWindow.inspectorShown(for:dismissedStage:)` to `false`
    /// across staging, dismissal and every selection shape — the routing
    /// table once installed, back when
    /// `.inspector` presented in its own split region a content-view
    /// `.overlay` could neither reach nor cover. "Commit to band always"
    /// (`OverviewLayout.presentation(...)`'s own doc comment states the
    /// directive in full) reduced `inspectorShown` to an unconditional
    /// `false` first; this file's own machinery-removal commit deletes the
    /// function itself (`DeckWindow.swift`'s own top doc comment states the
    /// removal in full), so there is nothing left to hold to `false` — the
    /// case these two tests existed to guard against cannot be expressed
    /// any more, not merely disproven. `RenderSweepTests
    /// .deckWindowSuppressesBandWhileStaged` and `theBandTracksTheSelectionInRow`
    /// (this suite) are where the SAME two properties — no double surface
    /// while staged, selection-driven otherwise — live now, held against
    /// `bandShown` instead.

    // --------------------------------------------- the stage, keyed off a mirror

    /// **`DeckWindow.stageMirror` — the mirror's own DATA SOURCE for the
    /// SAME rule `stageDecision` already reads, not a second routing
    /// regime.** `stageDecisionShowsOnlyTheSelectedLanesPreviewedCall`'s
    /// exact three cases, replayed against a `MirrorView` instead of a
    /// `Decision`: a preview-bearing mirror on the selected lane raises the
    /// stage, an unselected one does not, and a mirror belonging to a
    /// DIFFERENT session than the one selected must never raise it either.
    @Test("the stage shows only the selected lane's own previewed mirror")
    func stageMirrorShowsOnlyTheSelectedLanesPreviewedMirror() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let mirror = MirrorView(hold: hold, stage: .released(at: at(0)),
                                questions: [questionWithPreview()])
        let lanes = [lane("alpha"), lane("beta")]

        let selected = Frame(at: at(0), lanes: lanes, mastNeedsYou: 0,
                             decisions: [], mirrors: [mirror], selection: SessionID("alpha"))
        #expect(DeckWindow.stageMirror(for: selected, dismissedStage: nil) == mirror,
                "a previewed mirror on the selected lane should raise the stage")

        let unselected = Frame(at: at(0), lanes: lanes, mastNeedsYou: 0,
                               decisions: [], mirrors: [mirror], selection: nil)
        #expect(DeckWindow.stageMirror(for: unselected, dismissedStage: nil) == nil,
                "nothing is selected, so nothing should own the strip")

        let otherSelected = Frame(at: at(0), lanes: lanes, mastNeedsYou: 0,
                                  decisions: [], mirrors: [mirror], selection: SessionID("beta"))
        #expect(DeckWindow.stageMirror(for: otherSelected, dismissedStage: nil) == nil,
                "the mirror belongs to alpha, not the selected beta")
    }

    /// The identical by-hold dismissal rule `stageDecisionRespectsDismissalByHoldIdentity`
    /// already pins for a `Decision` — one `dismissedStage` binding, shared
    /// by construction across both sources.
    @Test("dismissing a hold suppresses only that hold's own mirror stage")
    func stageMirrorRespectsDismissalByHoldIdentity() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let mirror = MirrorView(hold: hold, stage: .terminalLive(at: at(0)),
                                questions: [questionWithPreview()])
        let f = Frame(at: at(0), lanes: [lane("alpha")], mastNeedsYou: 0,
                      decisions: [], mirrors: [mirror], selection: SessionID("alpha"))

        #expect(DeckWindow.stageMirror(for: f, dismissedStage: hold) == nil,
                "the dismissed hold should not re-show the mirror stage")

        let other = HoldID(session: SessionID("alpha"), toolUseID: "t2")
        #expect(DeckWindow.stageMirror(for: f, dismissedStage: other) == mirror,
                "dismissing a DIFFERENT hold must not suppress this one")
    }

    /// A mirror with no preview on any option stays off the stage, exactly
    /// like a bare `Decision` — `stageDecisionIgnoresBareQuestions`'s own
    /// twin.
    @Test("a bare mirror never raises the stage")
    func stageMirrorIgnoresBareQuestions() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let bare = Question(text: Redacted("Which?"), header: Redacted("Q"),
                            options: [QuestionOption(label: Redacted("A"), detail: Redacted(""))],
                            multiSelect: false)
        let mirror = MirrorView(hold: hold, stage: .released(at: at(0)), questions: [bare])
        let f = Frame(at: at(0), lanes: [lane("alpha")], mastNeedsYou: 0,
                      decisions: [], mirrors: [mirror], selection: SessionID("alpha"))
        #expect(DeckWindow.stageMirror(for: f, dismissedStage: nil) == nil)
    }

    /// **`resolved` still raises the stage — an explicit
    /// design decision.** A preview mattered for CHOOSING; nothing about the call
    /// having finished makes the mockup that justified the room in the
    /// first place retroactively not have needed it, and a mirror that
    /// was already full-strip should not suddenly vanish out from under
    /// someone reading the resolved answer.
    @Test("a resolved mirror with a preview still raises the stage")
    func stageMirrorResolvedStillShows() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let answers = [Answer(question: Redacted("Which?"), labels: [Redacted("A")])]
        let mirror = MirrorView(hold: hold, stage: .resolved(answers: answers, origin: .terminal, at: at(0)),
                                questions: [questionWithPreview()])
        let f = Frame(at: at(0), lanes: [lane("alpha")], mastNeedsYou: 0,
                      decisions: [], mirrors: [mirror], selection: SessionID("alpha"))
        #expect(DeckWindow.stageMirror(for: f, dismissedStage: nil) == mirror)
    }

    /// **RETIRED — `inspectorNeverOpensForAMirrorStage` used to live
    /// here, the retired `inspectorNeverOpensAnyMore`'s own twin (this
    /// file's own retired-tests note, above, carries that history).** It
    /// held the now-deleted `DeckWindow.inspectorShown(for:dismissedStage:)`
    /// to `false` for a MIRROR-owned stage exactly as its twin did for a
    /// `Decision`-owned one. `bandClosesWhileMirrorStaged` (below) is where
    /// the real suppression property now lives, on the band.

    /// `bandShown`'s own identical extension — the `.row` layout's version
    /// of the same suppression the retired `inspectorNeverOpensForAMirrorStage`
    /// used to prove for `.inspector`, back when a mirror stage's own
    /// dismissal still reopened one.
    @Test("the band closes exactly while a mirror stage owns the selected lane")
    func bandClosesWhileMirrorStaged() {
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let mirror = MirrorView(hold: hold, stage: .released(at: at(0)),
                                questions: [questionWithPreview()])
        let f = Frame(at: at(0), lanes: [lane("alpha")], mastNeedsYou: 0,
                      decisions: [], mirrors: [mirror], selection: SessionID("alpha"))
        // `presentation(for:...)` compares `bandWidth = usableWidth -
        // bandFleetWidth - bandSeamWidth` against `bandMinimumWidth`, not
        // `usableWidth` directly — so clearing the floor takes the fleet
        // column and the seam back out first.
        let usableWidth = OverviewLayout.bandFleetWidth + OverviewLayout.bandSeamWidth
            + OverviewLayout.bandMinimumWidth + 1
        let usableHeight = OverviewLayout.bandMinimumHeight + 1

        #expect(DeckWindow.bandShown(for: f, dismissedStage: nil, layout: .row,
                                     usableWidth: usableWidth, usableHeight: usableHeight) == false,
                "the band must close while a mirror's own stage owns this hold")
        #expect(DeckWindow.bandShown(for: f, dismissedStage: hold, layout: .row,
                                     usableWidth: usableWidth, usableHeight: usableHeight) == true,
                "dismissing the mirror's stage should reopen the band")
    }

    // ---------------------------------------------------- keyboard traversal

    /// A `List` gave arrow-key traversal for free and a grid of buttons gives
    /// only Tab, so the traversal is written rather than lost with the list
    /// that used to provide it.
    @Test("arrow keys walk the fleet and stop at its ends")
    func arrowKeysWalkTheFleet() {
        let ids = ["a", "b", "c"].map(SessionID.init)

        // Nothing focused yet: the first arrow lands somewhere rather than
        // swallowing the keystroke.
        #expect(SessionOverview.nextFocus(from: nil, in: ids, .right) == ids[0])

        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .right) == ids[1])
        #expect(SessionOverview.nextFocus(from: ids[1], in: ids, .left) == ids[0])
        // Down and right are the same move: the fleet is one sequence whichever
        // way it is laid out.
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .down) == ids[1])
        #expect(SessionOverview.nextFocus(from: ids[1], in: ids, .up) == ids[0])

        // Clamped, not wrapped. Focus leaping from the last card back to the
        // first reads as focus getting lost.
        #expect(SessionOverview.nextFocus(from: ids[2], in: ids, .right) == ids[2])
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .left) == ids[0])

        #expect(SessionOverview.nextFocus(from: nil, in: [], .right) == nil)
        // A focused session that has since ended does not strand the keyboard.
        #expect(SessionOverview.nextFocus(from: SessionID("gone"), in: ids, .right) == ids[0])
    }

    /// **`rows: 1` (the default) is EXACTLY `arrowKeysWalkTheFleet`'s own
    /// behaviour — restated here as its own case so a future edit to the
    /// `rows > 1` branch cannot silently change the one-row path without a
    /// test noticing.**
    @Test("rows: 1 behaves exactly like the pre-existing flat traversal")
    func rowsOneMatchesTheFlatTraversal() {
        let ids = ["a", "b", "c"].map(SessionID.init)
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .right, rows: 1) == ids[1])
        #expect(SessionOverview.nextFocus(from: ids[1], in: ids, .left, rows: 1) == ids[0])
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .down, rows: 1) == ids[1])
        #expect(SessionOverview.nextFocus(from: ids[1], in: ids, .up, rows: 1) == ids[0])
        #expect(SessionOverview.nextFocus(from: ids[2], in: ids, .right, rows: 1) == ids[2])
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .left, rows: 1) == ids[0])
    }

    /// **Column-major traversal, the two-row fleet's own shape.** Six
    /// cards, `rows: 2`, laid out the way a `LazyHGrid` with two row
    /// tracks actually fills them: column 0 is `[a, b]`, column 1 is
    /// `[c, d]`, column 2 is `[e, f]` — index `i`'s own column is `i / 2`,
    /// its own row within that column is `i % 2`.
    @Test("rows: 2 walks the fleet column-major, the shape a two-row LazyHGrid actually fills")
    func rowsTwoWalksColumnMajor() {
        let ids = ["a", "b", "c", "d", "e", "f"].map(SessionID.init)

        // Down inside a column: a (row 0, col 0) → b (row 1, col 0).
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .down, rows: 2) == ids[1],
                "down from the top of a column should reach the bottom of the same column")
        // Down blocked at the column's own bottom track: b is already row 1.
        #expect(SessionOverview.nextFocus(from: ids[1], in: ids, .down, rows: 2) == ids[1],
                "down from the bottom of a column should hold, not spill into the next column")
        // Up blocked at the column's own top track: a is already row 0.
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .up, rows: 2) == ids[0],
                "up from the top of a column should hold, not reach into the previous column")
        // Up inside a column: d (row 1, col 1) → c (row 0, col 1).
        #expect(SessionOverview.nextFocus(from: ids[3], in: ids, .up, rows: 2) == ids[2],
                "up from the bottom of a column should reach the top of the same column")
        // Right strides a whole column (2): a (col 0) → c (col 1).
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .right, rows: 2) == ids[2],
                "right should stride a full column, not step by one card")
        // Left strides back a column: e (col 2) → c (col 1).
        #expect(SessionOverview.nextFocus(from: ids[4], in: ids, .left, rows: 2) == ids[2],
                "left should stride back a full column")
        // Left blocked in the first column: a and b both hold.
        #expect(SessionOverview.nextFocus(from: ids[0], in: ids, .left, rows: 2) == ids[0],
                "left from the first column should hold")
        #expect(SessionOverview.nextFocus(from: ids[1], in: ids, .left, rows: 2) == ids[1],
                "left from the first column's own second row should also hold")
    }

    /// **A partial last column — an odd card count — lands on the last
    /// card rather than doing nothing.** Five cards, `rows: 2`: column 0 is
    /// `[a, b]`, column 1 is `[c, d]`, column 2 is the partial `[e]` alone
    /// (no row 1). `d` (column 1, row 1) is the case that actually
    /// exercises the overrun: a same-row stride (`i + rows` = 5) is not a
    /// valid index at all (`n` = 5), yet a later column genuinely exists
    /// (`e`'s own partial one) — `c` (row 0) would reach `e` through the
    /// ordinary in-bounds stride instead, which is not the same code path.
    @Test("rows: 2 lands on the last card when right strides past a partial final column")
    func rowsTwoLandsOnTheLastCardInAPartialColumn() {
        let ids = ["a", "b", "c", "d", "e"].map(SessionID.init)
        #expect(SessionOverview.nextFocus(from: ids[3], in: ids, .right, rows: 2) == ids[4],
                "right from the last full column's own bottom row should land on the partial column's only card")
        // From e (col 2, row 0) there is no further column at all.
        #expect(SessionOverview.nextFocus(from: ids[4], in: ids, .right, rows: 2) == ids[4],
                "right from the partial column's own card should hold — nothing further exists")
    }

    // -------------------------------------------------------- the card tap

    /// **Collapse ≡ deselect, one of the band's three doors.** A tap on
    /// whichever card is already the selection collapses the band rather
    /// than re-selecting it, in `.row` only — `.grid`/`.column` route to the
    /// identical band now too ("commit to band always") but keep the plain
    /// re-select every other tap has always been: this is `.row`'s own
    /// door, where the header card doubles as the band's own header, not a
    /// general re-tap rule invented for every layout (`SessionOverview
    /// .CardTap`'s own doc comment states why).
    @Test("tapping the already-selected row card collapses; every other tap selects",
          arguments: OverviewLayout.allCases)
    func cardTapCollapsesOnlyInRow(_ layout: OverviewLayout) {
        let selected = SessionID("alpha")
        let other = SessionID("beta")

        let sameCard = SessionOverview.cardTap(layout: layout, selection: selected, tapped: selected)
        let expected: SessionOverview.CardTap = layout == .row ? .collapse : .select(selected)
        #expect(sameCard == expected,
                Comment(rawValue: "tapping the selected card in \(layout.rawValue) gave \(sameCard)"))

        // A different card always selects, in every layout — only a tap on
        // the ALREADY-selected card is special.
        #expect(SessionOverview.cardTap(layout: layout, selection: selected, tapped: other) == .select(other))
        // And with nothing selected, any tap selects.
        #expect(SessionOverview.cardTap(layout: layout, selection: nil, tapped: other) == .select(other))
    }

    // ------------------------------------------------------------- the ticks

    /// **The seam's own honesty: every off-viewport needs-you lane, hidden
    /// included, and never the selected one.** With the fleet narrowed to
    /// the selected card alone (`SessionOverview.lanes(from:banded:selection:)`),
    /// every non-selected lane is off-viewport by construction — filtered
    /// out entirely, not merely scrolled past — so `Ticks.offViewportNeedsYou`
    /// is the whole rule, and
    /// `Frame.mastNeedsYou`'s own conservation discipline is why hidden
    /// lanes count too.
    @Test("ticks project every off-viewport needs-you lane and never the selection")
    func ticksProjectOffViewportNeedsYou() {
        let selected = lane("alpha", state: .needsYou)
        let waitingHidden = LaneView(session: SessionID("hidden-waiter"), state: .needsYou,
                                     isExpanded: false, contextPercent: nil, sources: [:],
                                     isHidden: true)
        let quiet = lane("quiet")
        let lanes = [selected, waitingHidden, quiet, lane("also-waiting", state: .needsYou)]

        let marks = Ticks.offViewportNeedsYou(lanes: lanes, selection: selected.session)
        let gotSessions = Set(marks.map(\.session))
        let expectedSessions: Set<SessionID> = [waitingHidden.session, SessionID("also-waiting")]
        #expect(gotSessions == expectedSessions,
                Comment(rawValue: "expected the hidden waiter and the other needs-you lane, "
                        + "got \(marks.map(\.session.raw))"))
        #expect(!marks.contains { $0.session == selected.session },
                "the selected lane is on the glass — it should never get a tick of its own")

        // Nothing needs-you at all: no marks, and the view says so.
        let calm = Ticks.offViewportNeedsYou(lanes: [selected, quiet], selection: selected.session)
        #expect(calm.isEmpty)
    }

    // -------------------------------------------------------- the animation

    /// **The zero-`withAnimation` doctrine's one exception, pinned as a
    /// value.** `SessionOverview.scrollToSelection`'s own doc comment
    /// records the scope; this is the rule that scope reduces to.
    ///
    /// **Direction-aware.** Live feedback split into two complaints — opening felt uncoordinated,
    /// closing felt laggy — and the design that answers both is
    /// asymmetric: `banded: true` (opening) animates, `banded: false`
    /// (closing) is always a hard cut, and Reduce Motion still wins over
    /// both, collapsing every combination to `nil`. All four combinations
    /// of direction × Reduce Motion are exercised here because the whole
    /// point of a direction-aware rule is that the two directions must
    /// disagree — a render sweep cannot observe the live motion this
    /// governs (SwiftUI transitions are not something a headless
    /// `NSHostingView` snapshot can see mid-flight), so this pure function
    /// is the only place the asymmetry itself is checked at all; the feel
    /// is judged on the strip.
    @Test("the band's transition is asymmetric: it animates opening, cuts hard on closing, and reduce motion always wins")
    func bandTransitionRespectsReduceMotion() {
        #expect(DeckWindow.bandTransitionAnimation(banded: true, reduceMotion: false) != nil,
                "opening (banded: true) should animate the band's own geometry")
        #expect(DeckWindow.bandTransitionAnimation(banded: true, reduceMotion: true) == nil,
                "reduce motion should fall back to a hard cut on open too, not a slower animation")
        #expect(DeckWindow.bandTransitionAnimation(banded: false, reduceMotion: false) == nil,
                Comment(rawValue: "closing (banded: false) is a hard cut even with motion allowed — "
                        + "the ask was \"no delay\" on collapse"))
        #expect(DeckWindow.bandTransitionAnimation(banded: false, reduceMotion: true) == nil,
                "closing under reduce motion is still a hard cut — both guards agree, neither is redundant")
    }

    /// **The zero-`withAnimation` doctrine's SECOND sanctioned exception,
    /// pinned the same shape as the band's own above** —
    /// `CardWash`'s intensity transitions
    /// (`SessionCard.washTransitionAnimation`). An ordinary change eases (a
    /// swell, never a flash); Reduce Motion always wins, falling back to a
    /// hard cut rather than a slower one — the identical asymmetry
    /// `bandTransitionRespectsReduceMotion` above pins for the band's own
    /// geometry. A render sweep cannot observe the live motion this
    /// governs either (SwiftUI transitions are not something a headless
    /// `NSHostingView` snapshot can see mid-flight), so this pure function
    /// is the only place the rule itself is checked; the feel is
    /// judged live on the strip.
    @Test("a wash's own transition animates with motion allowed and cuts hard under reduce motion")
    func washTransitionRespectsReduceMotion() {
        #expect(SessionCard.washTransitionAnimation(reduceMotion: false) != nil,
                "an ordinary wash change should ease — a swell, not a flash")
        #expect(SessionCard.washTransitionAnimation(reduceMotion: true) == nil,
                "reduce motion must fall back to a hard cut, the same as every other motion this deck offers")
    }

    // ------------------------------------------------------------- the shelf

    /// What is hidden is stated even while it is not drawn, and a concealed
    /// request for a human is stated loudly. `Frame.hiddenNeedsYou` exists for
    /// exactly this and had no consumer at all once the sidebar's Hidden
    /// section was deleted.
    @Test("the shelf announces a concealed request for a human")
    func theShelfAnnouncesWhatItConceals() {
        let quiet = HiddenShelf(count: 3, needsYou: 0, revealed: .constant(false), layout: .row)
        #expect(quiet.spokenDescription.contains("3 hidden"))
        #expect(!quiet.spokenDescription.contains("waiting"))

        let loud = HiddenShelf(count: 3, needsYou: 2, revealed: .constant(false), layout: .row)
        #expect(loud.spokenDescription.contains("2"),
                "a hidden session asking for a human is not announced")
        #expect(loud.spokenDescription.contains("waiting"))

        // Singular reads as English, because a deck says "1 hidden session".
        let one = HiddenShelf(count: 1, needsYou: 0, revealed: .constant(false), layout: .row)
        #expect(one.spokenDescription.contains("1 hidden session"))

        // And it says which way it is currently pointing.
        let open = HiddenShelf(count: 1, needsYou: 0, revealed: .constant(true), layout: .row)
        #expect(open.spokenDescription != one.spokenDescription,
                "the shelf reads the same open as closed")
    }

    @Test("the shelf renders in every layout", arguments: OverviewLayout.allCases)
    func theShelfRendersEverywhere(_ layout: OverviewLayout) {
        let size = NSHostingView(rootView: HiddenShelf(count: 2, needsYou: 1,
                                                       revealed: .constant(false),
                                                       layout: layout)).fittingSize
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "the shelf is \(size.height) pt tall in \(layout.rawValue) — "
                        + "below the touch floor on a touchscreen deck"))
    }

    /// Every branch of the control explains itself. A toolbar button whose
    /// tooltip does not change with its meaning is a button that lies in one
    /// of its two states.
    @Test("each direction of the control describes itself differently")
    func theHelpTextTracksTheDirection() {
        let helps = Set([DeckWindow.DetailToggle.open(SessionID("a")).help,
                         DeckWindow.DetailToggle.close.help,
                         DeckWindow.DetailToggle.unavailable.help])
        #expect(helps.count == 3, "two states of the control describe themselves the same way")
    }

    // ------------------------------------------------------- the band tracks

    /// **History — this file used to hold `DeckWindow.inspectorShown`'s own
    /// GET/SET binding accountable here, including a `.grid`-specific
    /// variant of the property this test now proves.** "Commit to band
    /// always" (`OverviewLayout.presentation(...)`'s own doc comment states
    /// the directive in full) reduced the binding's GET half to an
    /// unconditional `false` first; this file's own machinery-removal
    /// commit deletes the binding itself (`DeckWindow.swift`'s own top doc
    /// comment states the removal in full). What survives, retargeted, is
    /// the fact that actually mattered: `.grid` opens the BAND on a
    /// selection too, "commit to band always" reaching every layout, not
    /// only `.row` — `theBandTracksTheSelectionInRow` (below) is `.row`'s
    /// own version of the identical property.
    @Test("the band is shown exactly when a session is selected, in grid")
    func theBandTracksTheSelectionInGrid() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("s1"), at: at(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent)),
        ]))
        let window = DeckWindow(runtime: runtime, layout: .grid,
                                fleetSize: CGSize(width: 1920, height: OverviewLayout.bandMinimumHeight))

        #expect(window.bandShownForTesting == false,
                "the band is open with nothing selected")

        runtime.select(SessionID("alpha"))
        #expect(window.bandShownForTesting == true,
                Comment(rawValue: "selecting a session in .grid did not bring the band up — .grid should "
                        + "route here exactly as .row does"))

        runtime.dismiss()
        #expect(runtime.frame.selection == nil,
                "dismissing left the session selected, so the two disagree")
        #expect(window.bandShownForTesting == false)
    }

    /// The band's own counterpart, in `.row` — the layout `DeckWindow`
    /// actually defaults to. Same shape as `theBandTracksTheSelectionInGrid`
    /// above, exercised through `runtime.dismiss()`/`runtime.select(_:)`
    /// directly — the band has no binding of its own to set (there is
    /// nothing SwiftUI presents for it to bind to; it is ordinary content,
    /// composed or not).
    @Test("the band is shown exactly when a session is selected, in row")
    func theBandTracksTheSelectionInRow() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("s1"), at: at(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent)),
        ]))
        // `fleetSize` explicit and above `OverviewLayout.bandMinimumHeight`
        // — this test is about SELECTION routing, not the full-vs-squeezed
        // recipe boundary (`presentationRoutesToTheBandAtEveryHeight`,
        // `DeckCoreTests.OverviewLayoutTests`, is where that lives — and
        // proves the band shows EITHER side of it now), and a bare
        // `DeckWindow` with no geometry pass carries `fleetSize == .zero`
        // forever, which reads as squeezed-or-smaller — harmless to
        // `bandShownForTesting` today (nothing routes away any more), but
        // still not what this test is about.
        let window = DeckWindow(runtime: runtime, layout: .row,
                                fleetSize: CGSize(width: 1920, height: OverviewLayout.bandMinimumHeight))

        #expect(window.bandShownForTesting == false,
                "the band is open with nothing selected")

        runtime.select(SessionID("alpha"))
        #expect(window.bandShownForTesting == true,
                "selecting a session in row did not bring the band up")

        runtime.dismiss()
        #expect(window.bandShownForTesting == false,
                "dismissing left the band open on a cleared selection")
    }

    /// **Hide-while-banded = dismiss-on-hide — the routing consequence,
    /// GUARDED.** `DeckRuntime.hide`'s own doc comment states the design
    /// law and where it lives (the runtime/action layer, not view state);
    /// this is the proof that the ROUTING a hide actually produces matches
    /// it. Two cases, not one: hiding the SELECTED lane must deselect —
    /// the band has nothing left to filter its own fleet column down to
    /// (`SessionOverview.lanes(from:banded:selection:)`), so leaving the
    /// selection pointed at a lane `visibleLanes` no longer carries is
    /// exactly what let `ConnectCard` show beside a band still answering
    /// for a hidden lane (`SessionOverview.body`'s own overlay comment
    /// names the incident). Hiding a DIFFERENT lane must NOT touch the
    /// selection or collapse a band that is showing someone else entirely
    /// — the guard `hide`'s own `if state.selected == session` is there
    /// to keep true.
    @Test("hiding the selected lane deselects and collapses the band; hiding a different lane leaves it open")
    func hidingTheSelectedLaneDeselectsAndCollapsesTheBand() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("s1"), at: at(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "alpha"))),
            .hook(HookEvent(id: EventID("s2"), at: at(1), kind: .sessionStart,
                            session: SessionID("beta"), cwd: Redacted("/w/beta"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "beta"))),
        ]))
        // Same fleetSize convention `theBandTracksTheSelectionInRow` above
        // uses — above `bandMinimumHeight`, or every band-shown assertion
        // below reads `false` for the wrong reason.
        let window = DeckWindow(runtime: runtime, layout: .row,
                                fleetSize: CGSize(width: 1920, height: OverviewLayout.bandMinimumHeight))

        runtime.select(SessionID("alpha"))
        #expect(window.bandShownForTesting == true,
                "the fixture's own premise: a selection should open the band")

        // Hiding a DIFFERENT lane — the band answers for "alpha" and stays
        // open on it, untouched by a hide that was never about it.
        runtime.hide(SessionID("beta"))
        #expect(runtime.frame.selection == SessionID("alpha"),
                "hiding a lane that is not the selection should not touch the selection")
        #expect(window.bandShownForTesting == true,
                Comment(rawValue: "hiding a lane that is not the selection should leave the band open on "
                        + "the one it was already showing"))

        // Hiding the SELECTED lane — dismiss-on-hide.
        runtime.hide(SessionID("alpha"))
        #expect(runtime.frame.selection == nil,
                "hiding the currently-selected lane should deselect it — \"done with this one on my glass\"")
        #expect(window.bandShownForTesting == false,
                "the band should collapse — there is nothing left for it to be showing")
        #expect(OverviewLayout.presentation(for: .row, hasSelection: runtime.frame.selection != nil,
                                            usableWidth: 1920, usableHeight: OverviewLayout.bandMinimumHeight)
                    == .fleetOnly,
                "the pure routing rule should agree with the live window: nothing selected routes to .fleetOnly")
    }

    /// **The single-composition invariant, GUARDED.** An earlier defect was a
    /// `DeckWindow.body` that branched `if bandShown { bandComposition }
    /// else { fleetAndInspector }`, each building its OWN `SessionOverview`
    /// — two different positions in the view tree for what should have
    /// been one identity. SwiftUI diffs `@ViewBuilder` branches by
    /// POSITION: a selection that flipped the branch TORE DOWN one
    /// `SessionOverview` and built a fresh one, silently resetting
    /// `revealingHidden`, `@FocusState` and the fleet's own scroll
    /// position, and `onChange(of: runtime.frame.selection)` — the trigger
    /// `scrollToSelection` needs — fired against a view that had not
    /// existed a frame earlier. On the strip: tap card 4, and the
    /// (then-)352 pt viewport kept showing card 1, unringed, while the
    /// band beside it answered for card 4's own decision (`bandFleetWidth`
    /// has since retired its own sliver and reads 324 — `DeckWindow.body`'s
    /// own doc comment states both this fix's history and that later one).
    /// `DeckWindow.body`'s own doc
    /// comment recorded the fix in PROSE only, and a review
    /// re-introduced the two-branch mutation and found every one of
    /// 588 tests still green — a comment is not a guard. This is the
    /// guard: `type(of:)` on a live `DeckWindow.body` reports its REAL,
    /// concrete (opaque-erased) type at runtime, and a `SessionOverview`
    /// built at two different tree positions — one per `_ConditionalContent`
    /// arm — shows up TWICE in that type's own generic parameter list,
    /// where the single, always-present HStack child this file's own
    /// composition relies on shows up once. Verified by mutation, not
    /// merely argued: reverting `DeckWindow.body` to the
    /// two-branch shape (a targeted edit, `git diff` reviewed before
    /// restoring) turned this assertion red — 2 occurrences, not 1 — and a
    /// second targeted edit restored the single composition, both without
    /// `git checkout --`.
    @Test("SessionOverview appears exactly once in DeckWindow's own composition")
    func sessionOverviewAppearsExactlyOnceInTheComposition() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let window = DeckWindow(runtime: runtime, layout: .row,
                                fleetSize: CGSize(width: 1920, height: OverviewLayout.bandMinimumHeight))
        let typeName = String(describing: type(of: window.body))
        let occurrences = typeName.components(separatedBy: "SessionOverview").count - 1
        #expect(occurrences == 1,
                Comment(rawValue: "SessionOverview appears \(occurrences) times in DeckWindow.body's own "
                        + "composed type — a two-branch composition (the original defect: a branch "
                        + "that re-roots the fleet destroys scroll/focus/selection identity and shows the "
                        + "wrong card as the band's header) builds it at two tree positions instead of one. "
                        + "Type: \(typeName)"))
    }

    /// **RETOLD — "commit to band always" retires the fallback this table
    /// used to prove, at the `DeckWindow` level.** `OverviewLayoutTests`
    /// (`DeckCoreTests`) already holds the PURE rule (`OverviewLayout
    /// .presentation`) to always answering `.band` for a selection,
    /// whatever the height; this is the proof the REAL `DeckWindow` — the
    /// one whose `banded` actually reads `fleetSize.height` — agrees, built
    /// the same way `theBandTracksTheSelectionInRow` above proves the
    /// ordinary selection-driven case. Below `bandMinimumHeight`, `.row`
    /// now stays banded — SQUEEZED (`OverviewLayout.bandSqueezed
    /// (usableHeight:)`), not the classic sidebar — at every height this
    /// deck's own window floor (`DeckPrefs.minWindow`) can reach. There is
    /// no `.inspector` left to fall back to at all any more (`DeckWindow
    /// .swift`'s own top doc comment states the removal in full).
    @Test("row stays banded below the band's own height floor too — squeezed, never a fallback")
    func rowStaysBandedBelowTheHeightFloor() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("s1"), at: at(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent)),
        ]))
        runtime.select(SessionID("alpha"))

        let below = DeckWindow(runtime: runtime, layout: .row,
                               fleetSize: CGSize(width: 1920, height: OverviewLayout.bandMinimumHeight - 1))
        #expect(below.bandShownForTesting == true,
                "a row selection below the height floor should still compose the band, squeezed")

        let atFloor = DeckWindow(runtime: runtime, layout: .row,
                                 fleetSize: CGSize(width: 1920, height: OverviewLayout.bandMinimumHeight))
        #expect(atFloor.bandShownForTesting == true,
                "at the height floor the band shows too, full recipe now rather than squeezed")
    }

    /// **RETOLD — the shipped default window, end to end.**
    /// `DeckPrefs.defaultWindow` itself, not a synthetic height — the same
    /// fixture `OverviewLayoutTests.defaultWindowGetsTheBandNow` holds the
    /// pure rule to, proven here through the real `DeckWindow` a launch
    /// actually builds. The default window's own usable height (239 pt)
    /// is well under `bandMinimumHeight` (358), so this is the SQUEEZED
    /// recipe's own out-of-the-box arbiter: the very first window most
    /// installs ever show a selection in is a squeezed one.
    @Test("the shipped default window's own selection gets the squeezed band")
    func defaultWindowSelectionGetsTheSqueezedBand() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("s1"), at: at(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent)),
        ]))
        runtime.select(SessionID("alpha"))
        let d = DeckPrefs.defaultWindow
        #expect(OverviewLayout.forSize(width: Double(d.width), height: Double(d.height)) == .row,
                "the fixture's own premise: the default window should be .row")
        let window = DeckWindow(runtime: runtime, layout: .row,
                                fleetSize: CGSize(width: Double(d.width), height: Double(d.height)))
        #expect(window.bandShownForTesting == true,
                "the shipped default window should compose the band, squeezed, rather than falling back")
    }

    // ------------------------------------------------------- saying it is alive

    /// The status line renders every state at a size somebody can see. It is
    /// the deck's only claim that it is still receiving, and a line that
    /// collapses to nothing is a deck that has gone quiet about going quiet.
    @Test("the status line renders every state",
          arguments: [HookServerStatus.notStarted, .listening(port: 8765),
                      .failed(reason: "address in use"), .stopped])
    func theStatusLineRendersEveryState(_ status: HookServerStatus) {
        let size = NSHostingView(rootView: StatusLine(status: status)
                                    .frame(width: 600)).fittingSize
        #expect(size.height > 0,
                Comment(rawValue: "\(status.message) renders as nothing"))
        #expect(size.height < 60,
                Comment(rawValue: "\(status.message) takes \(size.height) pt of a 480 pt "
                        + "strip — a status line is a line"))
    }

    /// A deck that has not started is not a deck that is fine. The runtime's
    /// initial value has to be one the status line will draw as unhealthy,
    /// because that is the state a launch failure leaves it in.
    @Test("a deck reports itself unhealthy before it binds")
    func aFreshRuntimeIsNotClaimingHealth() {
        let runtime = DeckRuntime()
        #expect(!runtime.status.isListening)
        #expect(runtime.status.severity > .normal,
                "a deck that has never bound reports itself as healthy")
    }
}
