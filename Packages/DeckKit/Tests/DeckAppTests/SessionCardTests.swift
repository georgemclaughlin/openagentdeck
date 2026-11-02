//
//  SessionCardTests.swift · Tests/DeckAppTests
//
//  The card, measured as it actually renders and read as it actually speaks.
//
//  The card is the deck's whole information budget for one session, so what is
//  asserted here is what it CARRIES rather than what it looks like. Two kinds
//  of claim:
//
//  - what it says — the spoken description is the card's content in one
//    string, and a field missing from it is a field missing from the card;
//  - what it measures — `NSHostingView.fittingSize` lays the view out for
//    real, with no window and no screen, so "a card with a prompt is taller
//    than one without" is a fact about what SwiftUI drew rather than about
//    what this code intended.
//
//  That second kind is how the DENSITY-IS-THE-SIGNAL property gets tested at
//  all. A fleet is triaged by silhouette before a word of it is read, and a
//  layout where the busy session and the idle one are the same size has
//  thrown that away. It is not a matter of taste and it does not need eyes.
//

import Testing
import SwiftUI
import AppKit
import DeckCore
@testable import DeckApp

@MainActor
struct SessionCardTests {

    private func measured(_ view: some View) -> CGSize {
        NSHostingView(rootView: view).fittingSize
    }

    /// A card at a fixed width, which is how both multi-card layouts hand it
    /// out — the grid stretches it to a column and the row pins it to
    /// `cardIdealWidth`. Measuring unconstrained would measure a shape the
    /// product never draws.
    private func measuredCard(_ lane: LaneView, name: String = "work/parser",
                              isSelected: Bool = false,
                              width: Double = OverviewLayout.cardIdealWidth) -> CGSize {
        measured(SessionCard(lane: lane, name: name, isSelected: isSelected)
                    .frame(width: width))
    }

    private func lane(state: LaneState = .working,
                      contextPercent: Int? = nil,
                      contextStale: Bool = false,
                      prompt: String? = nil,
                      branch: String? = "main",
                      lastTool: String? = nil,
                      permissionMode: String? = nil,
                      routable: Bool = true,
                      color: CardColor = .slot(0)) -> LaneView {
        LaneView(session: SessionID("0ba90d07-1111-2222"), state: state,
                 isExpanded: false, contextPercent: contextPercent, sources: [:],
                 contextStale: contextStale,
                 color: color,
                 directory: Redacted("/Users/you/work/parser"),
                 prompt: prompt.map(Redacted.init),
                 branch: branch.map(Redacted.init),
                 lastTool: lastTool,
                 permissionMode: permissionMode,
                 host: routable ? HostAddress(workspace: "w1", surface: "s1") : nil)
    }

    private func card(_ lane: LaneView, disambiguator: String? = nil,
                      isSelected: Bool = false) -> SessionCard {
        SessionCard(lane: lane, name: "work/parser",
                    disambiguator: disambiguator, isSelected: isSelected)
    }

    // ------------------------------------------------ density is the signal

    /// **The property the sidebar could not have.**
    ///
    /// A busy session's card is full and an idle one is nearly empty, and that
    /// difference reads from across a desk before any word on either has been
    /// read. Equal-height rows carry no such signal: triage requires reading
    /// every one of them.
    @Test("a working session's card is visibly denser than an idle one")
    func densityTracksActivity() {
        let idle = measuredCard(lane(state: .idle, branch: nil))
        let busy = measuredCard(lane(state: .working, contextPercent: 40,
                                     prompt: "use l9 rigor to address blocking bugs then continue",
                                     lastTool: "Bash",
                                     permissionMode: PermissionBadge.bypass))
        #expect(busy.height > idle.height,
                Comment(rawValue: "a busy card measured \(busy.height) and an idle one "
                        + "\(idle.height) — the fleet cannot be triaged by silhouette"))
    }

    /// The prompt block is the single largest thing the card can gain, because
    /// it is the field that answers "what is this session doing".
    @Test("the last prompt takes real room when there is one")
    func thePromptIsGivenRoom() {
        let without = measuredCard(lane())
        let with = measuredCard(lane(prompt: "rewrite the layout so the fleet is the primary object"))
        #expect(with.height > without.height + 20,
                Comment(rawValue: "the prompt added \(with.height - without.height) pt — "
                        + "it is being clipped rather than shown"))
    }

    // ------------------------------------------------------ what it carries

    /// Every live field reaches the card. The spoken description is the card's
    /// content as one string, so a field absent from it is a field the card
    /// dropped — which is exactly what the sidebar row did to seven of them.
    @Test("the card carries every field that changes")
    func theCardCarriesTheLiveFields() {
        let card = SessionCard(lane: lane(state: .working, contextPercent: 40,
                                          prompt: "address blocking bugs",
                                          branch: "main", lastTool: "Bash",
                                          permissionMode: PermissionBadge.bypass),
                               name: "work/parser", isSelected: false)
        let said = card.spokenDescription

        for (field, needle) in [("name", "work/parser"), ("state", "Working"),
                                ("permission mode", "Bypassing"), ("branch", "main"),
                                ("context", "40%"), ("last tool", "Bash"),
                                ("prompt", "address blocking bugs"),
                                ("session id", "0ba90d07")] {
            #expect(said.contains(needle),
                    Comment(rawValue: "the card does not carry its \(field): \(said)"))
        }
    }

    /// **The empty-slot rule, at the card.**
    ///
    /// A gauge nobody has fed claims nothing. `0%` and "no reading yet" are
    /// different facts about a session and drawing them alike is the failure
    /// the rule exists to prevent.
    @Test("an unfed gauge does not claim a reading")
    func anUnfedGaugeIsSilent() {
        let card = SessionCard(lane: lane(contextPercent: nil), name: "work/parser",
                               isSelected: false)
        #expect(!card.spokenDescription.contains("context"),
                "a session with no context reading was described as having one")

        let fed = SessionCard(lane: lane(contextPercent: 0), name: "work/parser",
                              isSelected: false)
        #expect(fed.spokenDescription.contains("0%"),
                "a real reading of zero was suppressed along with the absent one")
    }

    /// **A stale reading keeps its own number and its own load colour on
    /// BOTH surfaces the card draws it on — the footer's own text AND the
    /// bar along the card's top edge — unmarked by age, on either one,
    /// deliberately.** `ReadingInk`/`contextInkRole` (footer, retired the
    /// round `SessionCard.contextTint`'s own doc comment carries) and
    /// `ContextBar.fill(for:)`'s own retired `isStale` branch (bar, a
    /// live follow-on found it greying too — that function's own doc
    /// comment carries the full account: a 30 s max age against a feed
    /// that only renders during active turns greyed most cards most of
    /// the time on a supervision deck) are BOTH gone now. This is the
    /// genuine "never grey" pin for the bar: a version that still
    /// branched on `isStale` would fail the bar's own third assertion
    /// below outright — `.tertiary` (grey) does not equal
    /// `ContextLoad(percent: 63).tint` (orange).
    @Test("a stale reading keeps its own number and its own load colour on both the footer and the bar, unmarked by age")
    func staleReadingsAreUnmarkedByAge() {
        let stale = card(lane(contextPercent: 63, contextStale: true))
        let fresh = card(lane(contextPercent: 63))

        #expect(stale.visibleContextReading == "ctx:63%",
                "the stale reading was thrown away, or annotated on the one line it has")
        #expect(stale.visibleContextReading == fresh.visibleContextReading,
                "age changed the words")
        #expect(stale.contextTint == fresh.contextTint,
                Comment(rawValue: "age changed the footer's own colour (\(stale.contextTint) vs "
                        + "\(fresh.contextTint)) — the load rule must not vary with staleness"))
        #expect(stale.contextTint == ContextLoad(percent: 63).tint,
                "63% is caution range (50...74) — the reading should read orange regardless of staleness")

        // The bar's own twin — `ContextBar.fill(for:)` is the real
        // control's own rule, called directly rather than rendered to
        // pixels, the same "measure the real thing, not a lookalike"
        // posture the assertions above already take for the footer.
        guard let staleMeter = stale.contextMeter, let freshMeter = fresh.contextMeter else {
            Issue.record("the fixture's own premise: a fed meter on both lanes")
            return
        }
        let staleBar = ContextBar.fill(for: staleMeter)
        let freshBar = ContextBar.fill(for: freshMeter)
        #expect(staleBar == freshBar,
                Comment(rawValue: "age changed the bar's own colour (\(staleBar) vs \(freshBar)) — the load "
                        + "rule must not vary with staleness on the bar either"))
        #expect(staleBar == ContextLoad(percent: 63).tint,
                Comment(rawValue: "the bar measured \(staleBar) at 63%, stale — expected "
                        + "\(ContextLoad(percent: 63).tint) (caution/orange), never grey"))

        // And no longer spoken either: "stale" is deck plumbing in both channels.
        #expect(!stale.spokenDescription.lowercased().contains("stale"))
        #expect(stale.spokenDescription.contains("63% used"))
    }

    /// **`ContextBar.fill(for:)` follows `ContextLoad` exhaustively — 63%
    /// is the case that DISCRIMINATES this from the retired ladder.** 91%
    /// reads red under BOTH the old rule (`meter.severity == .alarm` at
    /// the meter's own 90% line) and the new one (`ContextLoad`'s own 75%
    /// alarm line) — a bar that still ran the old rule would pass at 91%
    /// by COINCIDENCE. 63% is where they diverge: the old rule reads
    /// `.tint` (blue-ish, the system accent) below 90% regardless of how
    /// far below; `ContextLoad` reads `.orange` (caution) from 50%. Only
    /// 63% actually proves which rule is running.
    @Test("ContextBar.fill follows ContextLoad exhaustively", arguments: [
        (40, Color.blue), (63, Color.orange), (91, Color.red),
    ])
    func contextBarFillFollowsContextLoad(_ percent: Int, _ expected: Color) {
        let got = ContextBar.fill(for: Meter.context(usedPercent: percent))
        #expect(got == expected,
                Comment(rawValue: "\(percent)% got \(got), expected \(expected)"))
    }

    /// **Used, never inverted — and the labelled-red rule on top of it.**
    ///
    /// The bar fills with what has been CONSUMED, because that is the number
    /// Claude Code reports and the only direction anybody thinks about a
    /// context window in. This card drew the inverse: `ctx:91%` beside a
    /// nearly empty bar, which flipped to `9% left` the moment the session
    /// crossed into the red — one session, two numbers, neither of them the
    /// one on the user's own statusline.
    @Test("an alarming gauge quotes what Claude Code sent, in the deck's idiom")
    func anAlarmingGaugeQuotesUsed() {
        let critical = card(lane(contextPercent: 91))
        let reading = critical.visibleContextReading

        #expect(reading == "ctx:91%",
                Comment(rawValue: "a red gauge reads \(reading ?? "nothing") — the alarm "
                        + "reinterpreted the reading instead of colouring it"))
        #expect(critical.contextTint == .red,
                "91% is past the ContextLoad alarm line (75) — the footer's own number should read red")

        // A calmer gauge draws the identical shape, in its own load colour.
        let healthy = card(lane(contextPercent: 40))
        #expect(healthy.visibleContextReading == "ctx:40%")
        #expect(healthy.contextTint == .blue,
                "40% is calm range (below 50) — the footer's own number should read blue, never grey")
    }

    // -------------------------------------------------------- ctx load colour

    /// **The pure rule, exhaustively — `ContextLoad`'s own worked table
    /// (`ContextMeterTests`) restated here at the point `SessionCard`
    /// actually reads it, the same double-coverage `washStyleIsAPureRuleOfStateAndReduceMotion`'s
    /// own doc comment argues for: a rule tested once where it is DEFINED
    /// and once where it is CONSUMED catches the two independently — a
    /// consumer that reads the wrong field, or maps the right enum to the
    /// wrong colour, fails HERE even if the enum's own thresholds are
    /// still exactly right.**
    @Test("SessionCard.contextTint follows ContextLoad exhaustively", arguments: [
        (0, Color.blue), (49, Color.blue), (50, Color.orange),
        (74, Color.orange), (75, Color.red), (100, Color.red),
    ])
    func contextTintFollowsContextLoad(_ percent: Int, _ expected: Color) {
        let got = card(lane(contextPercent: percent)).contextTint
        #expect(got == expected, Comment(rawValue: "\(percent)% got \(got), expected \(expected)"))
    }

    /// **The render-smoke half — a hosted card costs no EXTRA layout for
    /// carrying its own colour, the same `washStyle...` pure-table +
    /// render-smoke PAIR this file already holds the wash rule to.** Two
    /// cards, identical but for `contextPercent` landing on opposite ends
    /// of the ramp (blue vs. red) — colour is drawn, not laid out, so
    /// nothing about the card's own measured size may move because of it.
    @Test("a card's own load colour costs no layout")
    func contextColorCostsNoLayout() {
        let calm = measuredCard(lane(contextPercent: 10))
        let alarming = measuredCard(lane(contextPercent: 95))
        #expect(calm == alarming,
                Comment(rawValue: "a calm (\(calm)) and an alarming (\(alarming)) reading measured "
                        + "differently — colour must not be reflowing the card"))
    }

    // -------------------------------------------------- band-open ctx removal

    /// **The selected card's own footer reading drops out while banded —
    /// ONLY the selected card, `SessionCard.hidesContext`'s own doc
    /// comment states why `isSelected && banded` and neither alone is the
    /// right gate.** The band's own big-number readout
    /// (`DetailBand.header`) is showing the identical fact already; this
    /// is the other half of that move.
    @Test("the selected card's own ctx reading hides while the band is open; an unselected one keeps it")
    func selectedCardHidesContextWhileBanded() {
        let selectedUnbanded = SessionCard(lane: lane(contextPercent: 55), name: "work/parser",
                                           isSelected: true, banded: false)
        #expect(selectedUnbanded.visibleContextReading != nil,
                "the fixture's own premise: a real reading to hide")
        #expect(!selectedUnbanded.hidesContext,
                Comment(rawValue: "selected but NOT banded (e.g. .grid/.column's sidebar, or .row below the "
                        + "band's own floor) must keep showing its own reading — nothing else on screen "
                        + "repeats it there"))

        let selectedBanded = SessionCard(lane: lane(contextPercent: 55), name: "work/parser",
                                         isSelected: true, banded: true)
        #expect(selectedBanded.hidesContext,
                "selected AND banded must hide — the band's own header is showing this same fact now")

        let unselectedBanded = SessionCard(lane: lane(contextPercent: 55), name: "work/parser",
                                           isSelected: false, banded: true)
        #expect(!unselectedBanded.hidesContext,
                Comment(rawValue: "an UNSELECTED card must keep its own reading even while banded — only "
                        + "the selected card's own reading is redundant with the band's header"))
    }

    /// The bar's fill and the footer's number are one derivation, so they can
    /// never come to disagree about which way the meter runs. A card at 91 %
    /// is nearly full; a card at 9 % is nearly empty.
    @Test("the bar fills as the window is consumed")
    func theBarFillsWithUsedContext() {
        #expect(card(lane(contextPercent: 91)).contextMeter?.used == 91)
        #expect(card(lane(contextPercent: 9)).contextMeter?.used == 9)
        // Out-of-range readings are bounded rather than trusted: the payload
        // is untrusted and a bar wider than its track is a layout bug.
        #expect(card(lane(contextPercent: 140)).contextMeter?.used == 100)
        #expect(card(lane(contextPercent: -5)).contextMeter?.used == 0)
    }

    /// **A lane the deck cannot speak to says so on the card.**
    ///
    /// `LaneView.host` is documented as "a fact the surface must show rather
    /// than hide behind a control that silently does nothing", and it reached
    /// the glass only after selecting the lane — one selection too late for
    /// somebody scanning the fleet for a session they can actually act on.
    @Test("an unroutable session is marked before it is selected")
    func anUnroutableSessionSaysSoOnTheCard() {
        let stranded = card(lane(routable: false))
        #expect(stranded.spokenDescription.contains("no route"),
                "a session the deck cannot send to is indistinguishable from one it can")

        let reachable = card(lane(routable: true))
        #expect(!reachable.spokenDescription.contains("no route"),
                "a reachable session is described as stranded")

        // And DRAWN, not only spoken.
        //
        // Measuring cannot see this one. The glyph rides inside a
        // baseline-aligned row and adds no height, so a stranded card and a
        // reachable one come back the same size — a size comparison here
        // would pass whether or not the mark existed, which is the vacuous
        // assertion this replaces. What is checkable is the card's own
        // decision to draw it, so the card exposes that rather than leaving a
        // test to infer it from a number that does not move.
        #expect(stranded.routeMarkSymbol != nil,
                "no visible mark is drawn for a lane the deck cannot reach")
        #expect(reachable.routeMarkSymbol == nil,
                "a reachable lane is drawn with the no-route mark")
    }

    /// The id is on every card. What a name collision changes is how legibly
    /// it is drawn — it stops being a footnote exactly when it becomes the
    /// only thing telling two cards apart.
    @Test("a colliding name promotes the session id out of the footnotes")
    func theIDIsPromotedWhenItIsLoadBearing() {
        let alone = card(lane(), disambiguator: nil)
        let colliding = card(lane(), disambiguator: "0ba90d")

        // Both carry it — the id is the identity of record either way.
        #expect(alone.spokenDescription.contains("0ba90d07"))
        #expect(colliding.spokenDescription.contains("0ba90d07"))

        // And the collision changes how it is DRAWN.
        //
        // Not measurable either: the footer's height is set by the state chip
        // beside the id, so escalating `.caption2` to `.caption.semibold`
        // leaves the card exactly the same size. A height assertion here
        // passed on equality and would have gone on passing with the
        // escalation deleted. The font itself is the thing being claimed, so
        // the font itself is what is asserted.
        #expect(alone.idFont != colliding.idFont,
                "the id is drawn identically whether or not it is the only differentiator")
    }

    /// The permission badge appears only on a deviation — and when it does, it
    /// says what it means rather than repeating the API token.
    @Test("the permission badge speaks only when there is something to say")
    func thePermissionBadgeIsQuietByDefault() {
        let ordinary = SessionCard(lane: lane(permissionMode: PermissionBadge.normal),
                                   name: "work/parser", isSelected: false)
        #expect(!ordinary.spokenDescription.lowercased().contains("permission"),
                "an ordinary session is announcing its permission mode")

        let bypassing = SessionCard(lane: lane(permissionMode: PermissionBadge.bypass),
                                    name: "work/parser", isSelected: false)
        #expect(bypassing.spokenDescription.contains("without asking"),
                "a bypassing session does not say what bypassing means")
    }

    // ------------------------------------------------------- the two channels

    /// **Selection may not paint over state.**
    ///
    /// The sidebar's filled blue row rendered a needs-you glyph and its
    /// Waiting badge in white — the less important signal destroying the more
    /// important one. Selection is an outline here, which is a channel of its
    /// own, and the falsifier is geometric: an outline cannot change what the
    /// card is, so it cannot change what the card measures.
    @Test("selecting a card changes nothing about what it shows",
          arguments: LaneState.allCases)
    func selectionIsItsOwnChannel(_ state: LaneState) {
        let l = lane(state: state, contextPercent: 55, prompt: "do the thing", lastTool: "Edit")
        let unselected = measuredCard(l, isSelected: false)
        let selected = measuredCard(l, isSelected: true)
        #expect(unselected == selected,
                Comment(rawValue: "\(state.rawValue): selection reflowed the card "
                        + "(\(unselected) -> \(selected)) — it is not on a channel of its own"))

        let said = SessionCard(lane: l, name: "work/parser", isSelected: true).spokenDescription
        #expect(said.contains(state.spokenName),
                "selection swallowed the state the card was reporting")
    }

    // ------------------------------------------------------------- the sizes

    /// The card renders at every state without collapsing or running away, at
    /// the narrowest width any layout will hand it.
    @Test("a card is sane at the narrowest width a layout will give it",
          arguments: LaneState.allCases)
    func theCardSurvivesItsNarrowestWidth(_ state: LaneState) {
        let size = measuredCard(lane(state: state, contextPercent: 91,
                                     prompt: "a prompt long enough to need every one of its "
                                           + "three lines and then some more besides",
                                     lastTool: "Bash",
                                     permissionMode: PermissionBadge.bypass),
                                width: OverviewLayout.cardMinimumWidth)
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "\(state.rawValue) card is \(size.height) pt tall"))
        // Three lines of prompt, a heading, a tag row and a footer. Past this
        // the card is not wrapping, it is growing without limit.
        #expect(size.height < 320,
                Comment(rawValue: "\(state.rawValue) card grew to \(size.height) pt — "
                        + "a line limit is not holding"))
    }

    /// A waiting session must be loud on the card itself. Decisions live in
    /// the band, which only opens for a selection — so the fleet is the only
    /// thing that can say WHERE the request is when nothing is selected to
    /// say what it asks.
    @Test("a waiting card names its own state")
    func aWaitingCardSaysSo() {
        let card = SessionCard(lane: lane(state: .needsYou), name: "work/parser",
                               isSelected: false)
        #expect(card.spokenDescription.contains(LaneState.needsYou.spokenName))
    }

    // ------------------------------------------------------ identity colour

    /// **The wash reads identity, except when danger overrides it.**
    ///
    /// Every state washes in the lane's own colour now — `.working`
    /// joined `.needsYou` on the identity channel in the wash redesign
    /// (`washColor`'s own doc comment carries the full reasoning, and this
    /// is the NEW row this rewrite adds). `.errored` stays `.red`
    /// regardless of what colour the lane holds, because danger outranks
    /// identity — checked here against BOTH a named slot and a near-red
    /// custom pick, since a custom colour is exactly the case the old
    /// doc comment on this rule worried a fixed exception could miss.
    /// `idle`/`ended` carry the identity colour too — `washColor` is
    /// non-optional now, deliberately — but their STYLE gates visibility
    /// at opacity 0 (`washStyleIsAPureRuleOfStateAndReduceMotion`, below,
    /// is where that half of the claim is pinned); colour is moot for a
    /// wash nobody can see. `washColor`/`washStyle` are exposed at
    /// `internal` for exactly this test — the same posture `contextTint`
    /// already takes, for the same reason.
    @Test("the wash follows the lane's own colour, except errored which stays red")
    func washFollowsTheCardsOwnColor() {
        let slotted = card(lane(state: .needsYou, color: .slot(4)))
        #expect(slotted.washColor == CardColor.slot(4).tint)
        #expect(slotted.washColor == .teal, "slot 4 is teal in the palette's own order")

        let custom = CardColor.custom(red: 0.2, green: 0.4, blue: 0.6)
        let customCard = card(lane(state: .needsYou, color: custom))
        #expect(customCard.washColor == custom.tint)

        // The new row: a working card's wash reads identity too now.
        let working = card(lane(state: .working, color: .slot(4)))
        #expect(working.washColor == .teal,
                "a working card's wash must read the lane's own colour, same as needsYou")

        let errored = card(lane(state: .errored, color: .slot(4)))
        #expect(errored.washColor == .red, "danger outranks identity")
        let erroredCustom = card(lane(state: .errored, color: custom))
        #expect(erroredCustom.washColor == .red,
                "danger outranks identity even against a near-red custom pick")

        // Idle/ended carry the colour too — moot, since their style is
        // `.none` — but `washColor` itself must not go optional-nil on them.
        #expect(card(lane(state: .idle, color: .slot(4))).washColor == .teal)
        #expect(card(lane(state: .ended, color: .slot(4))).washColor == .teal)
    }

    /// **The pure rule, pinned exhaustively.** `SessionCard.washStyle` is a
    /// function of state and Reduce Motion alone — no view, no runtime — so
    /// every one of the ten (state × reduceMotion) combinations is checked
    /// against an independently-built expectation, not against the
    /// production switch re-run on itself.
    ///
    /// The individual values alone cannot catch two constants moving
    /// TOGETHER and still satisfying every case, so four relational claims
    /// follow the table: needs-you's peak must exceed working's steady
    /// level (there has to be room for needs-you to read louder); Reduce
    /// Motion's needs-you level must equal the pulse's own high (the
    /// static two-step's loud step IS the pulse's peak); a needs-you
    /// pulse's own low must equal working's steady level BY CONSTRUCTION
    /// (needs-you may never read quieter than working, at any instant);
    /// and errored must read exactly 0.22 — today's only shipped wash
    /// opacity, unmoved — on BOTH sides of the Reduce Motion switch, since
    /// errored never moves for either reason ("errors don't dance").
    @Test("washStyle is a pure rule of state and reduceMotion")
    func washStyleIsAPureRuleOfStateAndReduceMotion() {
        for state in LaneState.allCases {
            for reduceMotion in [false, true] {
                let style = SessionCard.washStyle(state: state, reduceMotion: reduceMotion)
                let expected: SessionCard.WashStyle
                switch (state, reduceMotion) {
                case (.idle, _), (.ended, _):
                    expected = .none
                case (.working, _):
                    expected = .steady(opacity: SessionCard.workingWashOpacity)
                case (.needsYou, false):
                    expected = .pulsing(low: SessionCard.workingWashOpacity,
                                        high: SessionCard.needsYouWashPeak,
                                        period: SessionCard.washPulsePeriod)
                case (.needsYou, true):
                    expected = .steady(opacity: SessionCard.needsYouWashPeak)
                case (.errored, _):
                    expected = .steady(opacity: SessionCard.erroredWashOpacity)
                }
                #expect(style == expected, Comment(rawValue:
                        "\(state.rawValue)/reduceMotion=\(reduceMotion): got \(style), expected \(expected)"))
            }
        }

        // Relational pins — see this test's own doc comment for why the
        // exhaustive table above cannot catch these on its own.
        #expect(SessionCard.needsYouWashPeak > SessionCard.workingWashOpacity,
                "a needs-you card must be able to read louder than a working one, at its peak")

        #expect(SessionCard.washStyle(state: .needsYou, reduceMotion: true)
                    == .steady(opacity: SessionCard.needsYouWashPeak),
                "Reduce Motion's needs-you level must equal the pulse's own high")

        #expect(SessionCard.washStyle(state: .working, reduceMotion: false)
                    == .steady(opacity: SessionCard.workingWashOpacity))
        if case .pulsing(let low, _, _) = SessionCard.washStyle(state: .needsYou, reduceMotion: false) {
            #expect(low == SessionCard.workingWashOpacity, Comment(rawValue:
                    "a needs-you card's quietest instant must equal a working card's steady " +
                    "level, by construction — needsYou must never read quieter than working"))
        } else {
            Issue.record("needsYou with motion NOT reduced must produce a pulsing style")
        }

        #expect(SessionCard.erroredWashOpacity == 0.22, "today's only shipped wash opacity must not move")
        #expect(SessionCard.washStyle(state: .errored, reduceMotion: false) == .steady(opacity: 0.22))
        #expect(SessionCard.washStyle(state: .errored, reduceMotion: true) == .steady(opacity: 0.22),
                "errored reads identically whichever way motion goes — errors don't dance either way")
    }

    /// The card speaks its colour last — an identity trim, not a
    /// triage-critical fact (`spokenDescription`'s own doc comment).
    @Test("the card speaks its colour, last")
    func theCardSpeaksItsColor() {
        let named = card(lane(color: .slot(4)))
        #expect(named.spokenDescription.hasSuffix("color teal"),
                Comment(rawValue: "said: \(named.spokenDescription)"))

        let custom = card(lane(color: .custom(red: 0.1, green: 0.2, blue: 0.3)))
        #expect(custom.spokenDescription.hasSuffix("color custom color"),
                Comment(rawValue: "said: \(custom.spokenDescription)"))
    }

    /// **The identity bar is always on.**
    ///
    /// Not measurable by `NSHostingView.fittingSize` — the bar is an
    /// overlay by design (`identityBarWidth`'s own doc comment: "costs zero
    /// height and zero width"), so a size comparison here would be the
    /// vacuous assertion `anUnroutableSessionSaysSoOnTheCard`'s own comment
    /// already named for a different invisible-to-measurement mark. What
    /// IS checkable headlessly is the constant itself, pinned, and the
    /// colour table behind every card's spine, walked slot by slot against
    /// a literal of its own — so a palette that grows in one file and not
    /// the other fails here rather than drawing a card under the wrong hue.
    @Test("the identity bar's width is pinned and its colour table stays congruent with the palette")
    func theIdentityBarIsAlwaysOn() {
        // Materialized rather than compared inline: `identityBarWidth` is a
        // `Double`, and a local binding is what a failure message can
        // actually print a value for.
        let barWidth = SessionCard.identityBarWidth
        #expect(barWidth == 5)

        let expected: [Color] = [.orange, .yellow, .green, .mint, .teal,
                                 .cyan, .blue, .indigo, .purple, .pink, .brown]
        #expect(expected.count == CardColor.paletteNames.count,
                "the pixel table and the name table have drifted apart in length")
        for index in 0..<CardColor.paletteCount {
            #expect(CardColor.slot(index).tint == expected[index],
                    Comment(rawValue: "slot \(index) (\"\(CardColor.paletteNames[index])\") "
                            + "does not paint \(expected[index])"))
        }
    }
}
