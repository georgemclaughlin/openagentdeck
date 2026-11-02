//
//  DecisionBar.swift · DeckApp
//
//  The one surface that must never be missed, and never be mistaken.
//
//  It names its subject — a decision offering Allow and Deny without showing
//  what is being allowed means nothing — and sits in the window's top safe
//  area, so it is present at every size and cannot be scrolled past.
//  `ViewThatFits` reflows the buttons under the text when the window is too
//  narrow to hold them beside it: nothing is dropped, only rearranged. When
//  that reflow stacks the row taller, `DetailBand.actZone(for:)` gives ground
//  FIRST, by shrinking or omitting the well (`showsWell`,
//  `wellExpandedMaxHeight`) and folding this bar's title (`showsTitle`).
//  The buttons themselves never fold. That is a design law, not an absolute
//  guarantee: at five narrow, content-extreme combinations
//  (`RenderSweepTests.knownBareButtonsHardFloors` names each) even title and
//  well fully folded is not enough, and the Deny button is clipped (up to
//  +65 pt).
//
//  Whether the row stacks is read off `DecisionRowMeasurer.rowWidth(titles:
//  buttonMinWidth:)`: the REAL horizontal row, hosted once per distinct
//  (titles, floor) pair and cached (the same idiom as `ActionPillMeasurer`),
//  compared against the real act width.
//  - Don't predict it from a width constant tuned to one label: stacking
//    width depends on content length (`git push *` stacks up to act width
//    592, a long `addRules` path glob up to 1053).
//  - Don't use a `ViewThatFits(in: .vertical)` ladder: it lays out every
//    candidate, including the costly `SubjectWell`, and the MainActor
//    contention starved unrelated timing-sensitive tests.
//
//  Cost: a decision never composed before pays one `NSHostingView`
//  host-and-layout (about 2-3 ms) the first time it is measured, once per
//  distinct `buttonMinWidth` floor. The process's very first `NSHostingView`
//  also pays ~55 ms of framework warm-up. Every later ask for the same
//  (titles, floor) pair is a dictionary lookup.
//
//  It is Liquid Glass, and it is the right surface for it: glass is for the
//  layer that floats ABOVE content, which is exactly what a pinned bar does.
//  The two controls share one `GlassEffectContainer` so the system blends them
//  as a single piece of glass rather than two competing lenses — the difference
//  is visible the moment they sit side by side.
//

import SwiftUI
import AppKit
import Foundation
import DeckCore

struct DecisionBar: View {
    let decision: Decision
    let runtime: DeckRuntime

    /// Test seam only: seeds `SubjectWell`'s expanded state, because a
    /// headless render has no tap to drive `@State`. Production leaves it
    /// `false`, so the well opens collapsed.
    var initiallyExpanded: Bool = false
    /// Forwarded to `SubjectWell`'s parameter of the same name. `DetailBand`
    /// always passes its own computed value.
    var wellExpandedMaxHeight: Double = SubjectOverflow.expandedMaxHeight
    /// Forwarded to `SubjectWell.collapsedLines`.
    var wellCollapsedLines: Int = SubjectOverflow.collapsedLines
    /// Whether the well draws at all; `true` by default. `DetailBand` passes
    /// `false` when a stacked decision row leaves no room for it
    /// (`OverviewLayout.bandWellFits(usableHeight:stackedRowExtra:)`): a
    /// squeezed well would grow the band past its budget and clip the
    /// Allow/Deny row. `stackedRowExtra` is measured via `DecisionRowMeasurer`.
    ///
    /// Omit the view with an `if`; don't use a zero-height `.frame`. The
    /// collapsed well cannot compress past the overflow chip's 44 pt
    /// `TouchTarget.minimum`, so a zero-height frame would still draw ~60 pt
    /// of glass and clip the buttons.
    var showsWell: Bool = true
    /// The bar's outer padding. 16 pt equals the system default
    /// (`outerPaddingDefaultMatchesSystemDefault` in `RenderSweepTests.swift`
    /// pins that). `DetailBand` passes 8 under band-budget pressure.
    var outerPadding: Double = 16
    var contentSpacing: Double = 12
    /// The decision buttons' height: `TouchTarget.decision` (64) by default,
    /// the floor for the one control class whose mis-hit cannot be recovered.
    /// `DetailBand` passes `TouchTarget.minimum` (44) when
    /// `OverviewLayout.bandSqueezed(usableHeight:)` says there is no room for
    /// the full recipe, chosen by `OverviewLayout.bandDecisionButtonHeight
    /// (usableHeight:)`. Applied to every button alike, so the squeezed recipe
    /// never leaves one button taller than its neighbours.
    var buttonHeight: Double = TouchTarget.decision
    /// The decision buttons' minimum width: 140 pt by default; `DetailBand`
    /// passes `bandSqueezedButtonMinWidth` when squeezed. The floor only
    /// governs SHORT titles ("1. Yes", "3. No"); the widest suggestion label
    /// is already wider than either floor.
    var buttonMinWidth: Double = 140
    /// Whether the "Waiting for you" title row draws; `true` by default.
    /// `DetailBand` passes `OverviewLayout.bandShowsDecisionTitle
    /// (usableHeight:stackedRowExtra:)`. The title folds first because the
    /// orange "Waiting for you" card beside this bar and the buttons already
    /// announce the state. The buttons never fold.
    var showsTitle: Bool = true
    /// Forwarded to `SubjectWell.compact`; `DetailBand` passes
    /// `bandSqueezed(usableHeight:)`.
    var compactWell: Bool = false
    /// Test seam only: reports the Allow/Deny row's frame in the caller's
    /// named coordinate space (`DetailBand.detailBandRootSpace`). The band's
    /// total-height test cannot see buttons clipped internally, because
    /// `body`'s outer `.frame(maxHeight:).clipped()` pins the total; this
    /// probe closes that gap. Production leaves it `nil`, so no geometry
    /// observer is attached.
    var onButtonsFrameMeasured: ((CGRect) -> Void)?
    /// Test seam only: like `onButtonsFrameMeasured`, for the subject well.
    /// Fires only when the well renders, so a test can tell "rendered" from
    /// "omitted". Production never sets it.
    var onWellFrameMeasured: ((CGRect) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: contentSpacing) {
            // Not a parity violation: the header is narration ABOUT the
            // decision, not one of the OPTIONS a person chooses between, which
            // is what the parity rule governs (`buttons`, below). The terminal
            // has no separate headline; this chip is the deck's announcement
            // that something is on screen.
            //
            // `showsTitle` folds this one row at the tightest budgets
            // (`OverviewLayout.bandShowsDecisionTitle`); the buttons never fold.
            if showsTitle {
                Label("Waiting for you", systemImage: "exclamationmark.triangle.fill")
                    .font(.headline)
                    .foregroundStyle(.orange)
            }

            if showsWell, let subject = decision.subject {
                // Keyed by `decision.hold`: `SubjectWell.expanded` is `@State`
                // that must NOT survive to the next decision. Otherwise a
                // short next subject (no collapse chip) would render
                // pre-expanded with no way back. Same idiom as
                // `QuestionTakeover.swift`'s `OtherAnswerField`.
                probingWell(
                    SubjectWell(subject: subject, initiallyExpanded: initiallyExpanded,
                               expandedMaxHeight: wellExpandedMaxHeight, collapsedLines: wellCollapsedLines,
                               compact: compactWell)
                        .id(decision.hold))
            }

            probingButtons(
                // `bandDecisionRowSpacing`, not a bare `12`:
                // `DecisionRowMeasurer.bareRow` must build the IDENTICAL
                // arrangement, and two independent literals would drift.
                // `GlassEffectContainer`'s `spacing: 12` only coordinates
                // glass RENDERING, not layout, so it stays a literal.
                GlassEffectContainer(spacing: 12) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: OverviewLayout.bandDecisionRowSpacing) { buttons }
                        VStack(alignment: .leading, spacing: OverviewLayout.bandDecisionRowStackSpacing) { buttons }
                    }
                })
        }
        .padding(outerPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 0))
        .overlay(alignment: .bottom) { Divider() }
    }

    /// Attaches `onButtonsFrameMeasured` only when set, so no modifier exists
    /// in the view tree when nothing is listening (as `DetailBand.probingRootFrame`).
    @ViewBuilder
    private func probingButtons(_ content: some View) -> some View {
        if let onButtonsFrameMeasured {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(detailBandRootSpace)) }
                action: { onButtonsFrameMeasured($0) }
        } else {
            content
        }
    }

    /// `probingButtons` twin for `onWellFrameMeasured`.
    @ViewBuilder
    private func probingWell(_ content: some View) -> some View {
        if let onWellFrameMeasured {
            content.onGeometryChange(for: CGRect.self) { $0.frame(in: .named(detailBandRootSpace)) }
                action: { onWellFrameMeasured($0) }
        } else {
            content
        }
    }

    /// The decision controls, built through `control(...)` so a test measures
    /// the one that ships.
    ///
    /// Numbering matches Claude Code's own dialog: Yes is always 1, each
    /// suggestion takes the next number in order, and No takes the last. Built
    /// from `buttonTitles` so this view cannot drift from the numbering
    /// `DecisionBarNumberingTests` pins.
    @ViewBuilder
    private var buttons: some View {
        let titles = Self.buttonTitles(for: decision)
        let denyNumber = titles.suggestions.count + 2

        Self.control(titles.yes, destructive: false, height: buttonHeight, minWidth: buttonMinWidth) {
            runtime.decide(decision.hold, .allow)
        }
        .modifier(DigitShortcut(number: 1))

        // Claude Code's dialog offers "1. Yes", "2. Yes, and don't ask again
        // for: X", "3. No"; this renders the middle one. `suggestionLabels` is
        // usually empty or one entry; `ForEach` covers the general case.
        //
        // Tap by index into `decision.suggestionLabels`, not by value: the
        // response encoder resolves `allowAndRemember` against
        // `Hold.suggestions`, the raw array the labels derive from (see
        // `Decision.suggestionLabels`). The displayed number is display only.
        //
        // This tap creates a standing rule that the engine writes into Claude
        // Code's settings (`destination`, `localSettings` in every recorded
        // case), not into `PermissionRule` (the deck's own store). The deck
        // deliberately does not mirror it: a rule lives where it can be
        // revoked, which here is Claude Code's `/permissions`, and a mirrored
        // entry could be silently invalidated there.
        ForEach(Array(decision.suggestionLabels.enumerated()), id: \.offset) { index, label in
            // A quieter variant of Allow: same tint family, `.glass` rather
            // than `.glassProminent`. It also writes a standing rule, so it
            // must never outrank the button beside it.
            Self.control(titles.suggestions[index], destructive: false, prominent: false,
                        height: buttonHeight, minWidth: buttonMinWidth) {
                runtime.decide(decision.hold, .allowAndRemember(suggestionIndex: index))
            }
            .modifier(DigitShortcut(number: index + 2))
        }

        Self.control(titles.no, destructive: true, height: buttonHeight, minWidth: buttonMinWidth) {
            runtime.decide(decision.hold, .deny)
        }
        .modifier(DigitShortcut(number: denyNumber))
    }

    /// The titled, numbered sequence for a decision: Yes, one entry per
    /// suggestion, then No, matching Claude Code's numbering. A pure function
    /// so a test can pin the numbering without rendering.
    static func buttonTitles(for decision: Decision)
        -> (yes: String, suggestions: [String], no: String) {
        let suggestions = decision.suggestionLabels.enumerated().map { index, label in
            Self.suggestionTitle(number: index + 2, label: label)
        }
        let denyNumber = decision.suggestionLabels.count + 2
        return (yes: "1. Yes", suggestions: suggestions, no: "\(denyNumber). No")
    }

    /// One suggestion label as numbered button text. Only the `addRules`
    /// shape ("Don't ask again for: X") is rewritten into the terminal's
    /// "Yes, and don't ask again for: X"; other shapes (`setMode`'s "Switch
    /// mode to X", an unknown type's "Apply: X") have no recorded terminal
    /// rendering, so they are numbered and left otherwise alone.
    static func suggestionTitle(number: Int, label: String) -> String {
        let dontAskPrefix = "Don't ask again for: "
        if label.hasPrefix(dontAskPrefix) {
            let target = label.dropFirst(dontAskPrefix.count)
            return "\(number). Yes, and don't ask again for: \(target)"
        }
        return "\(number). \(label)"
    }

    /// One place a decision control is built, so a test measures the one that ships.
    ///
    /// `prominent: false` is the suggestion button: Allow's tint family (no
    /// destructive role, no `.tint`) at `.glass` weight like Deny, so it never
    /// looks lighter or heavier than its neighbours.
    ///
    /// `height`/`minWidth` default to the full-recipe values
    /// (`TouchTarget.decision`, 140); `DetailBand` always passes both
    /// explicitly. `RenderSweepTests` measures this function at the defaults.
    ///
    /// The label is greedy (`fillingLabel`) so the button style draws its
    /// background out to the floored frame. Don't just wrap a natural-size
    /// Button in `.touchTarget(...)`: the glass capsule keeps drawing at its
    /// natural ~57 x 24 pt, floating inside a 140 x 64 box, and the hit
    /// region is not the button's.
    @ViewBuilder
    static func control(_ title: String, destructive: Bool, prominent: Bool = true,
                        height: Double = TouchTarget.decision, minWidth: Double = 140,
                        action: @escaping () -> Void) -> some View {
        if destructive {
            floored(Button(role: .destructive, action: action) { fillingLabel(title) }
                        .buttonStyle(.glass),
                    height: height, minWidth: minWidth)
        } else if prominent {
            floored(Button(action: action) { fillingLabel(title) }
                        .buttonStyle(.glassProminent),
                    height: height, minWidth: minWidth)
        } else {
            floored(Button(action: action) { fillingLabel(title) }
                        .buttonStyle(.glass),
                    height: height, minWidth: minWidth)
        }
    }

    /// The label every `control(...)` branch shares: greedy in both axes so
    /// the style's background fills the floored rectangle. See `floored`,
    /// which contains the greed.
    private static func fillingLabel(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Applies the size floor so the DRAWN control lands exactly on it.
    ///
    /// The frame stays outside the button, which keeps every budget in this
    /// file intact: ideal width is `max(minWidth, text)` per button, natural
    /// height is `2 × outerPadding + height`. Don't put the floor on the
    /// label instead: the glass style pads outside whatever it is given (a
    /// 140 × 64 label drew 164 × 72), which broke the strip budget.
    ///
    /// `.fixedSize(horizontal: true, vertical: false)` is load-bearing. A
    /// horizontally greedy label in an `HStack` would make `ViewThatFits`
    /// find the row always fits, so labels would truncate instead of the row
    /// stacking. Fixing the horizontal size makes the button adopt its ideal
    /// width. Vertical stays free: height comes from the frame above.
    private static func floored(_ button: some View, height: Double, minWidth: Double) -> some View {
        button
            .frame(minWidth: minWidth, minHeight: height)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(.rect)
    }
}

/// Digit keyboard shortcuts for the decision buttons. Claude Code's own dialog
/// is driven by typing the number beside an option, so the digit in a button's
/// "N." prefix IS its shortcut.
///
/// Deliberately NOT Return/Escape. Both are reflex keys with no selection model
/// behind them (a terminal's Enter acts on a row the user highlighted first),
/// so a stray keystroke could approve a force-push, and refusing a tool call is
/// the deck's one unrecoverable action. Digits cannot be pressed by resting a
/// hand on Return. Hidden zero-size `.defaultAction`/`.cancelAction` siblings
/// would compose in SwiftUI; that was declined on purpose.
///
/// A `ViewModifier`, like `QuestionTakeover`'s `GatedShortcut`. The safety is a
/// WINDOW invariant: `performKeyEquivalent` walks the whole hierarchy, so any
/// TextField anywhere can steal a keystroke from a `.keyboardShortcut` planted
/// elsewhere. The window's one TextField (`QuestionTakeover`'s
/// `OtherAnswerField`) is mutually exclusive with `DecisionBar` by
/// `DeckWindow`'s if/else, and Settings is a separate scene window. A future
/// TextField in the deck window must gate these digits the way `GatedShortcut`
/// does. Mirrors `QuestionTakeover`'s `index < 9` guard; no recorded hold
/// carries enough suggestions to reach it.
private struct DigitShortcut: ViewModifier {
    let number: Int
    @ViewBuilder
    func body(content: Content) -> some View {
        if (1...9).contains(number) {
            content.keyboardShortcut(KeyboardShortcut(KeyEquivalent(Character("\(number)")), modifiers: []))
        } else {
            content
        }
    }
}

// -------------------------------------------------------------- the subject

/// The subject surface. Renders what `Subject.swift` calls "the missing half":
/// the byte-identical detail, the caption the terminal prints dimmer underneath
/// it, and the overflow affordance UX_DESIGN §4 mandates for whatever does not
/// fit in the collapsed lines. A long command and an `ExitPlanMode` plan are
/// the two shapes that overflow.
struct SubjectWell: View {
    let subject: Subject
    /// The expanded well's height ceiling; `SubjectOverflow.expandedMaxHeight`
    /// by default. `DetailBand` always passes its own computed value.
    var expandedMaxHeight: Double = SubjectOverflow.expandedMaxHeight
    /// The COLLAPSED well's depth in lines; `SubjectOverflow.collapsedLines`
    /// (4) by default. A 20-line plan's collapsed well (lines plus overflow
    /// chip) costs height whether or not anyone expands it, so `DetailBand`
    /// passes its own computed value.
    var collapsedLines: Int = SubjectOverflow.collapsedLines
    /// The squeezed recipe's collapsed shape; `false` by default. `DetailBand`
    /// passes `OverviewLayout.bandSqueezed(usableHeight:)`. Read together with
    /// `expanded`: a compact well the person has TAPPED open keeps its full
    /// scrollable shape, otherwise the overflow chip would be a dead end.
    let compact: Bool

    /// Seeded through the initializer so a render test can measure the EXPANDED
    /// state (there is no tap to drive it).
    init(subject: Subject, initiallyExpanded: Bool = false,
        expandedMaxHeight: Double = SubjectOverflow.expandedMaxHeight,
        collapsedLines: Int = SubjectOverflow.collapsedLines, compact: Bool = false) {
        self.subject = subject
        self.expandedMaxHeight = expandedMaxHeight
        self.collapsedLines = collapsedLines
        self.compact = compact
        _expanded = State(initialValue: initiallyExpanded)
    }

    @State private var expanded: Bool

    /// The two heights a wrap-only overflow check compares (see
    /// `unconstrainedProbe` and `cappedProbe`). `nil` until the first layout
    /// pass reports them, which at worst hides the chip for one frame. A
    /// headless render (`RenderSweepTests`) forces that settle; a live window
    /// settles it one redraw later.
    @State private var fullHeight: Double?
    @State private var cappedHeight: Double?

    /// The bytes actually on screen: `detail` if the deck could name it, else
    /// the tool's display name (so `Bash`, whose `detail` is essentially never
    /// nil, never draws a name beside its command).
    private var text: String { subject.detail?.value ?? subject.displayName }

    /// Whether the text wraps past the collapsed line limit.
    /// `SubjectOverflow.lineCount` counts newlines only, so a newline-free
    /// 500-character `Bash` chain would wrap past `collapsedLines` visual rows
    /// with no chip. UX_DESIGN §4's overflow mandate has no exception for
    /// wrap-only overflow.
    private var isWrapTruncated: Bool {
        guard let fullHeight, let cappedHeight else { return false }
        // A point of slack for font-metric rounding: two heights from the same
        // text at the same width should agree when nothing is hidden, but
        // layout is not bit-identical across render passes, and a flickering
        // chip is worse than one a frame late.
        return fullHeight > cappedHeight + 1
    }

    /// The line count overflow is measured against: 1 while compact-collapsed,
    /// `collapsedLines` otherwise. The visible row is `lineLimit(1)`; checking
    /// against `collapsedLines` would silently truncate lines 2-4 with no chip
    /// to declare it.
    private var effectiveCollapsedLines: Int { compact && !expanded ? 1 : collapsedLines }

    /// The chip's title, `nil` when none is warranted.
    /// `SubjectOverflow.chipText` answers first because it can back a number;
    /// only when newline arithmetic says the text fits does the wrap-only
    /// measurement speak, and it never invents a count (see
    /// `SubjectOverflow.wrapOnlyChipText`).
    private var chipTitle: String? {
        SubjectOverflow.chipText(for: text, collapsedLines: effectiveCollapsedLines)
            ?? (isWrapTruncated ? SubjectOverflow.wrapOnlyChipText : nil)
    }

    var body: some View {
        if compact && !expanded {
            compactCollapsedRow
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Group {
                    if expanded {
                        ScrollView(.vertical) {
                            detailText.frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(maxHeight: expandedMaxHeight)
                    } else {
                        detailText
                            .lineLimit(collapsedLines)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .copyable(text)
                .background(alignment: .topLeading) { unconstrainedProbe }
                .background(alignment: .topLeading) { cappedProbe }

                // The caption the terminal prints dimmer. Proportional rather
                // than mono: it is prose the tool wrote about itself, not
                // payload bytes the byte-identical rule governs. Absent for
                // tools `SubjectReader.captionField` has no entry for.
                if let caption = subject.caption?.value {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let chipTitle {
                    Self.overflowChip(expanded ? SubjectOverflow.collapseChipText : chipTitle) {
                        expanded.toggle()
                    }
                }
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    /// The squeezed recipe's collapsed row (`compact && !expanded`): the detail
    /// text at `lineLimit(1)` with the overflow chip INLINE beside it. The
    /// caption is dropped so the scarcest axis goes to the one fact, what this
    /// is about. Both truncation probes stay on `detailText`, checked against
    /// `effectiveCollapsedLines` (1). `.copyable(text)` sits on the whole
    /// `HStack` here, on the text only in the full recipe; both copy the same
    /// `text`.
    private var compactCollapsedRow: some View {
        HStack(spacing: 8) {
            detailText
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(alignment: .topLeading) { unconstrainedProbe }
                .background(alignment: .topLeading) { cappedProbe }
            if let chipTitle {
                Self.overflowChip(chipTitle) { expanded.toggle() }
            }
        }
        .copyable(text)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// The detail itself, byte-identical for every tool EXCEPT `ExitPlanMode`,
    /// whose terminal dialog renders its `plan` as markdown. `subject.detail`'s
    /// `String` never changes and `copyable(text)` copies the exact, unparsed
    /// bytes; only the drawing differs.
    ///
    /// `.inlineOnlyPreservingWhitespace` consumes inline markers (`**bold**`,
    /// `` `code` ``, `*italic*` become styled runs with the markers gone) while
    /// block markers (`#`, `-`, `1.`) stay literal and newlines are preserved.
    /// It needs no dependency and falls back to the same plain `Text` if
    /// parsing fails. Full block-level markdown is not attempted.
    @ViewBuilder
    private var detailText: some View {
        if subject.tool == "ExitPlanMode",
           let attributed = try? AttributedString(
               markdown: text,
               options: AttributedString.MarkdownParsingOptions(
                   interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            Text(attributed).font(.callout.monospaced())
        } else {
            Text(text).font(.callout.monospaced())
        }
    }

    /// Hidden measurement, unconstrained half: `detailText` with no line limit
    /// at the width the visible content resolved to. A `.background` is
    /// proposed its foreground's size, so it can never inflate the well; a
    /// `ZStack` sibling would report the union of sizes and would.
    ///
    /// `.fixedSize(horizontal: false, vertical: true)` is required: without it
    /// a `Text` in a `.background` adopts the host's proposed height, reports
    /// the capped height, and `isWrapTruncated` never fires.
    ///
    /// Lives OUTSIDE the expanded/collapsed branch in `body`: if it only ran
    /// when collapsed, expanding a wrap-only subject would stop measuring,
    /// `chipTitle` would go `nil`, and the well would lose its way back to
    /// collapsed.
    @ViewBuilder
    private var unconstrainedProbe: some View {
        detailText
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { fullHeight = $0 }
    }

    /// Hidden measurement, capped half: `detailText` at the visible collapsed
    /// limit, directly comparable to `unconstrainedProbe`. A second
    /// `.background`, since each call is independently proposed the same
    /// foreground size. The two `onGeometryChange` reads are independent, so
    /// both land in the one extra layout pass a headless render forces
    /// (`RenderSweepTests.measured`).
    @ViewBuilder
    private var cappedProbe: some View {
        detailText
            .lineLimit(effectiveCollapsedLines)
            .fixedSize(horizontal: false, vertical: true)
            .hidden()
            .accessibilityHidden(true)
            .onGeometryChange(for: Double.self) { $0.size.height } action: { cappedHeight = $0 }
    }

    /// One place the overflow chip is built, so a test measures the one that
    /// ships (as `DecisionBar.control`). `.plain` rather than glass: it toggles
    /// the well, it does not answer the decision, and must not compete with
    /// Allow and Deny for the thumb.
    static func overflowChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.plain)
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .touchTarget(minHeight: TouchTarget.minimum, minWidth: TouchTarget.minimum)
            // VoiceOver reads "▾"/"▴" as "down triangle"/"up triangle". Strip
            // the glyph and the following space, never the glyph alone, so a
            // title that already reads cleanly is not mangled.
            .accessibilityLabel(Self.spokenTitle(for: title))
    }

    private static func spokenTitle(for title: String) -> String {
        for glyph in ["▾ ", "▴ "] where title.hasPrefix(glyph) {
            return String(title.dropFirst(glyph.count))
        }
        return title
    }
}

// ------------------------------------------------------------------ actions

/// The measurement seam between the pill arithmetic
/// (`OverviewLayout.actionPillLayout`) and the pill render
/// (`QuickActionBar.control`/`.overflowControl`): one derivation, two readers,
/// held to the same number by measuring the same real control. `DeckCore` has
/// no platform framework to render a real `Button` (`QuickAction.swift`'s file
/// doc), so the measurement lives here.
///
/// Measure the REAL control, not a lookalike or a font-arithmetic estimate
/// (`TouchTarget.swift`'s file doc). `QuickActionBar.bareControl` with
/// `.buttonSizing(.fitted)` and no imposed frame is the button as the framework
/// draws it; `NSHostingView.fittingSize` of that is the natural width. The
/// clamp (`actionPillMinWidth`/`actionPillMaxWidth`) is applied in code
/// afterward so both floors stay named, testable constants.
///
/// PRIVACY, absolute: action titles are prefs content and must never reach a
/// `Diagnostic`, log line, `print`, or crash report. The in-memory cache is
/// fine (it never leaves the process), but nothing here may log a title, format
/// one into an error, or hand one to anything that persists or transmits (same
/// bar as `Redacted`'s file doc).
@MainActor
enum ActionPillMeasurer {
    private static var cache: [String: Double] = [:]

    /// Real rendered natural width of the pill (`NSHostingView.fittingSize` of
    /// the fitted `bareControl`), clamped to `[actionPillMinWidth,
    /// actionPillMaxWidth]`, cached by title. `alarming` is not in the key: it
    /// only selects the label's foreground colour, never layout.
    static func width(for title: String) -> Double {
        if let cached = cache[title] { return cached }
        let host = NSHostingView(rootView: QuickActionBar.bareControl(title, alarming: false) {})
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        host.layoutSubtreeIfNeeded()
        let natural = Double(host.fittingSize.width)
        let clamped = min(max(natural, OverviewLayout.actionPillMinWidth), OverviewLayout.actionPillMaxWidth)
        cache[title] = clamped
        return clamped
    }

    /// `width(for:)` for the overflow chip: the same technique on
    /// `QuickActionBar.bareOverflowControl(hiddenCount:)`. Cached under the
    /// chip's rendered title (which carries the count), so no second cache is
    /// needed.
    static func chipWidth(hiding count: Int) -> Double {
        let title = QuickActionBar.overflowTitle(hiddenCount: count)
        if let cached = cache[title] { return cached }
        let host = NSHostingView(rootView: QuickActionBar.bareOverflowControl(hiddenCount: count))
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        host.layoutSubtreeIfNeeded()
        let natural = Double(host.fittingSize.width)
        let clamped = min(max(natural, OverviewLayout.actionPillMinWidth), OverviewLayout.actionPillMaxWidth)
        cache[title] = clamped
        return clamped
    }
}

/// Decision-row twin of `ActionPillMeasurer`: `DeckCore` cannot render a real
/// `HStack` of `Button`s, so the measurement lives here and
/// `DetailBand.actZone(for:)` reads the plain `Double` this returns instead of
/// constructing a view.
///
/// Asking once per distinct (titles, button floor) pair and caching is
/// content-correct by construction, because the row measured IS the row
/// `DecisionBar.body` renders. Don't replace it with a prediction pinned to one
/// label (`git push *` stacks up to act width 592, `git push origin *` 629, a
/// long `addRules` path glob 1053, two suggestions (four buttons) 892), or with
/// a `ViewThatFits` ladder (see this file's header). The cost is paid on the
/// first ask for a novel decision.
///
/// PRIVACY, absolute, as for `ActionPillMeasurer`, and stricter about
/// retention. A suggestion's title can carry a rule's content (a shell command,
/// a file path); it is session-derived and its `Decision` is transient, so
/// caching the raw text would outlive it for no reason. `cache` is therefore
/// keyed on a HASH of `(buttonMinWidth, titles)` (`[Int: Double]`), so no
/// session text is retained at all. Keep the key a hash: a `String` key would
/// pass every correctness check and reintroduce the retention.
@MainActor
enum DecisionRowMeasurer {
    /// Keyed on `Hasher` output, not the titles (see the type's doc for why).
    /// `Hasher`'s seed is per-process, which is fine: the cache never compares
    /// across launches, and 64-bit collision odds are negligible at the few
    /// live entries (`cacheCapacity`).
    private static var cache: [Int: Double] = [:]

    /// A MEMORY bound, not a privacy one: an `[Int: Double]` cannot retain
    /// session text at any size. The strip shows one decision at a time, so 64
    /// distinct (titles, floor) pairs is generous. `rowWidth` clears the whole
    /// dictionary at the cap rather than evicting one entry (an LRU): simpler,
    /// and entries still in use re-populate on their next ask.
    private static let cacheCapacity = 64

    /// Natural width of the REAL horizontal decision row (`HStack(spacing: 12)`
    /// of `DecisionBar.control(...)`, as `DecisionBar.body`'s horizontal
    /// `ViewThatFits` arm builds it) for these titles at this button floor.
    /// This is the number `ViewThatFits` chooses against; measuring anything
    /// else answers a different question.
    ///
    /// `titles` are in RENDER order (Yes, each suggestion, No;
    /// `DecisionBar.buttonTitles(for:)` flattened) because the role styling in
    /// `buttons` depends on POSITION.
    ///
    /// The key carries BOTH `titles` and `buttonMinWidth`. The full recipe's
    /// 140 pt floor and the squeezed 110 pt one
    /// (`OverviewLayout.bandSqueezedButtonMinWidth`) measure different widths
    /// for identical titles (`"git push origin *"`: 614 pt vs 554 pt), so a key
    /// without the floor would be wrong in whichever order the cache warmed
    /// first. `decisionRowMeasurerKeysOnButtonMinWidth`
    /// (`RenderSweepTests.swift`) pins this.
    static func rowWidth(titles: [String], buttonMinWidth: Double) -> Double {
        let key = cacheKey(titles: titles, buttonMinWidth: buttonMinWidth)
        if let cached = cache[key] { return cached }
        let host = NSHostingView(rootView: bareRow(titles: titles, buttonMinWidth: buttonMinWidth))
        host.frame = NSRect(x: 0, y: 0, width: 10, height: 10)
        host.layoutSubtreeIfNeeded()
        let natural = Double(host.fittingSize.width)
        if cache.count >= cacheCapacity { cache.removeAll(keepingCapacity: true) }
        cache[key] = natural
        return natural
    }

    /// `rowWidth`'s key, factored out so read and write cannot drift. `Hasher`
    /// folds `titles` in ORDER (the same suggestions in a different order are a
    /// different row) and combines `buttonMinWidth` in the SAME hasher,
    /// avoiding the collisions of independently hashed-then-XORed values.
    private static func cacheKey(titles: [String], buttonMinWidth: Double) -> Int {
        var hasher = Hasher()
        hasher.combine(buttonMinWidth)
        hasher.combine(titles)
        return hasher.finalize()
    }

    /// The row `rowWidth` hosts to measure. Spacing reads the same constant as
    /// the real row, `OverviewLayout.bandDecisionRowSpacing` (12), so the two
    /// cannot drift. No `GlassEffectContainer`: it coordinates glass rendering,
    /// not layout, so the bare `HStack` has the same width with less to
    /// construct.
    ///
    /// Styled by POSITION exactly as `buttons` does (prominent Allow, plain
    /// suggestions, destructive Deny) through the identical
    /// `DecisionBar.control(...)`. Styling does not change the measured width:
    /// one title measured prominent, non-prominent, destructive, and at heights
    /// 44 and 64 gave the same 310.0 pt.
    /// `theBoundaryBetweenStackedAndHorizontalMatchesTheRealViewThatFitsFlip`
    /// (`RenderSweepTests.swift`) holds the row's arrangement (spacing)
    /// accountable at the exact boundary.
    @ViewBuilder
    private static func bareRow(titles: [String], buttonMinWidth: Double) -> some View {
        HStack(spacing: OverviewLayout.bandDecisionRowSpacing) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                if index == 0 {
                    DecisionBar.control(title, destructive: false, minWidth: buttonMinWidth) {}
                } else if index == titles.count - 1 {
                    DecisionBar.control(title, destructive: true, minWidth: buttonMinWidth) {}
                } else {
                    DecisionBar.control(title, destructive: false, prominent: false, minWidth: buttonMinWidth) {}
                }
            }
        }
    }
}

/// The pill recipe every quick action on the deck is built from: a namespace of
/// static functions, not a view.
///
/// `QuickActionsColumn` draws a 2×5 grid of `bareControl` pills, budgeted by
/// row. `DetailBand.header` draws `headerOverflowControl` for the tail past the
/// column's `capacity` (`DetailBand.yieldedHeaderFold`). `SettingsView` draws
/// `control` for its live preview. `ActionPillMeasurer` measures unconstrained
/// instances of `bareControl` and `bareOverflowControl(hiddenCount:)` to size
/// cells.
///
/// Fitted Liquid Glass pills: each button is its own rounded-rectangle glass
/// shape, 64 pt tall (about 7.2 mm; the general 44 pt floor is only about 5 mm
/// of glass on the strip, not reliably tappable by thumb; see
/// `OverviewLayout.actionPillHeight`), hugging its label width, floored at a 64
/// pt square for a short title and capped before a runaway title grows past
/// use.
@MainActor
enum QuickActionBar {
    /// One place a quick action is built, like `DecisionBar.control`, so a test
    /// measures the one that ships.
    ///
    /// The measured width is imposed exactly: `bareControl` in an EXACT frame,
    /// not a minimum one. `measuredWidth` is `ActionPillMeasurer.width(for:
    /// title)`; imposing it with `.buttonSizing(.flexible)` makes the rendered
    /// pill and whatever laid it out (`QuickActionsColumn`'s row arithmetic)
    /// use the identical number, and makes
    /// `lineLimit(1)`/`.truncationMode(.tail)` bite once a title runs past
    /// `OverviewLayout.actionPillMaxWidth`.
    static func control(_ title: String, alarming: Bool, measuredWidth: Double,
                        action: @escaping () -> Void) -> some View {
        bareControl(title, alarming: alarming, sizing: .flexible, action: action)
            .frame(width: measuredWidth, height: OverviewLayout.actionPillHeight)
            // Recoverable: a title truncated on the glass is still there in
            // full on hover.
            .help(title)
    }

    /// The pill recipe, measured against the macOS 26.5 SDK: squarish and
    /// neutral.
    ///
    /// `.title` (22 pt) goes INSIDE the label closure, not as an outer
    /// `.font()` on the button: an outer `.font()` never reaches a Liquid Glass
    /// button's label. `sizing` defaults to `.fitted`, the natural hug
    /// `ActionPillMeasurer.width(for:)` measures; `control` is the one caller
    /// that passes `.flexible`, once it has a measured width to impose. One
    /// function with a sizing parameter, rather than two drifting recipes,
    /// avoids betting on the ordering of chained `.buttonSizing` modifiers.
    ///
    /// Shape: `.buttonBorderShape(.roundedRectangle(radius: 8))`, not the
    /// capsule that `.controlSize(.extraLarge)` Liquid Glass controls default
    /// to on macOS 26. The radius matches `QuickActionsColumn`'s titled card
    /// (`RoundedRectangle(cornerRadius: 8)`), one rounding vocabulary. Whether
    /// macOS honours the explicit radius or substitutes a system one is
    /// unconfirmed; either way the result is a rounded rectangle, and `radius`
    /// is the one tunable if the corner reads wrong on real glass.
    ///
    /// Colour goes on the LABEL, not the glass fill, per the HIG's Liquid Glass
    /// guidance ("apply color sparingly… Symbols or text labels on Liquid Glass
    /// controls can also have color"). Tinting every pill's fill (up to ten in
    /// one column, none more primary than the others) is the anti-pattern it
    /// names. `alarming` is a distinct red label.
    ///
    /// Vibrancy opt-out: a `Text` with no explicit `.foregroundStyle` gets
    /// Liquid Glass vibrancy, which a custom concrete foreground style disables
    /// (hierarchical styles such as `.primary` and `.secondary` stay vibrant).
    /// `Color(nsColor: .labelColor)` and `Color.red` are concrete, so this opts
    /// out on purpose: at the strip's 1x scale with grayscale-only
    /// antialiasing, the vibrancy blend over a bright fill reads as blurry
    /// text. `.labelColor` still adapts to light and dark appearance.
    ///
    /// `.weight(.medium)`: grayscale antialiasing at the strip's ~225 ppi thins
    /// regular-weight stems; `.medium` is the floor found live. With `radius`,
    /// the first number to retune.
    static func bareControl(_ title: String, alarming: Bool, sizing: ButtonSizing = .fitted,
                            fillsHeight: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            // `fillsHeight` is the one opt-in that grows the glass itself, not
            // just the frame around it
            // (`QuickActionsColumn.column(_:rowHeight:)` is the only caller
            // that passes `true`). Wrapping the LABEL in `.frame(maxWidth:
            // .infinity, maxHeight: .infinity)`, inside the button, makes the
            // glass greedy for the offered height instead of reporting its
            // fixed intrinsic height
            // (`RenderSweepTests.thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight`
            // measures both).
            if fillsHeight {
                Text(title).font(.title.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(alarming ? Color.red : Color(nsColor: .labelColor))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Text(title).font(.title.weight(.medium)).lineLimit(1).truncationMode(.tail)
                    .foregroundStyle(alarming ? Color.red : Color(nsColor: .labelColor))
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .controlSize(.extraLarge)
        .buttonSizing(sizing)
    }

    /// The overflow menu's shared dispatch: every hidden action queues through
    /// `runtime` like a visible cell and is disabled the same way, including
    /// while debouncing. `overflowControl` and `headerOverflowControl` wrap
    /// this one menu body in different chrome, so the debounce check lives
    /// here, not at either caller. `hidden` is a plain value snapshot taken by
    /// the caller (values, not offsets: see `QuickActionsColumn.body`); this
    /// closure reads only its loop variable, never an index into
    /// `runtime.frame`.
    @ViewBuilder
    private static func overflowMenuItems(hidden: [QuickAction], runtime: DeckRuntime) -> some View {
        ForEach(hidden, id: \.id) { action in
            Button(action.displayTitle) { runtime.queue(action) }
                .disabled(runtime.frame.actionBlock != nil
                          || runtime.frame.debouncingActionIDs.contains(action.id))
        }
    }

    /// The overflow chip as a pill. It has no production caller; it is a kept,
    /// tested recipe (`TouchTargetTests` measures it). Built on the same `Menu`
    /// idiom as `DetailBand.compactControlsMenu`: a platform-native popup.
    /// `measuredWidth` is imposed exactly, as `control` does.
    ///
    /// Uses the same `.roundedRectangle(radius: 8)` border shape,
    /// `.weight(.medium)` and concrete `.labelColor` as `bareControl`, so the
    /// chip reads as one family with the pills (a chip is never `alarming`).
    /// Whether `Menu` honours a border shape override like a plain `Button` is
    /// unconfirmed: border shape does not move the measured size, so a headless
    /// probe cannot tell; judge it live.
    static func overflowControl(hidden: [QuickAction], runtime: DeckRuntime, measuredWidth: Double) -> some View {
        let title = Self.overflowTitle(hiddenCount: hidden.count)
        return Menu {
            overflowMenuItems(hidden: hidden, runtime: runtime)
        } label: {
            Text(title).font(.title.weight(.medium)).lineLimit(1)
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .controlSize(.extraLarge)
        .buttonSizing(.flexible)
        .frame(width: measuredWidth, height: OverviewLayout.actionPillHeight)
        // The glyph reads as "down triangle" to VoiceOver.
        // `spokenOverflowTitle(for:)` is a named, pure transform of the same
        // string the label draws, not a second copy of the count.
        .accessibilityLabel(Self.spokenOverflowTitle(for: title))
        .help(Self.spokenOverflowTitle(for: title))
    }

    /// The overflow fallback: `DetailBand`'s header gains this when
    /// `DetailBand.yieldedHeaderFold` names a non-empty tail, i.e. the actions
    /// beyond the Quick Actions column's `capacity`
    /// (`OverviewLayout.BandZonePlan.actions`) or, rarely, every action on
    /// geometry too starved for the column. Overflow honesty
    /// (`DetailBand.swift`'s file doc: every hidden-content affordance declares
    /// what it hides) forbids hiding actions with no declaration.
    ///
    /// Built on the same `overflowMenuItems` as `overflowControl`, at the
    /// general touch floor (`TouchTarget.minimum`, 44) with
    /// `SubjectWell.overflowChip`'s chrome (`.plain`, `.caption`, accent
    /// colour), not a pill: the header row is `OverviewLayout.bandHeaderHeight`
    /// (48 pt), too tight for a 64 pt pill. No imposed frame; it hugs its label
    /// because no DeckCore arithmetic needs to agree with its width.
    static func headerOverflowControl(hidden: [QuickAction], runtime: DeckRuntime) -> some View {
        let title = Self.overflowTitle(hiddenCount: hidden.count)
        return Menu {
            overflowMenuItems(hidden: hidden, runtime: runtime)
        } label: {
            Text(title).font(.caption.weight(.semibold))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .touchTarget(minHeight: TouchTarget.minimum, minWidth: TouchTarget.minimum)
        .accessibilityLabel(Self.spokenOverflowTitle(for: title))
        .help(Self.spokenOverflowTitle(for: title))
    }

    /// `overflowControl`'s unconstrained twin,
    /// `ActionPillMeasurer.chipWidth(hiding:)`'s one caller. A `Menu`'s
    /// collapsed footprint depends on its label alone, so only the hidden COUNT
    /// is needed to render like `overflowControl`. Same chrome, font and
    /// `sizing` default as `bareControl`.
    ///
    /// The populated overload below lets
    /// `RenderSweepTests.bareOverflowControlMatchesThePopulatedChip` compare
    /// two genuinely unconstrained reads. Imposing this overload's width onto
    /// `overflowControl` would be circular.
    static func bareOverflowControl(hiddenCount: Int, sizing: ButtonSizing = .fitted) -> some View {
        Menu {
            EmptyView()
        } label: {
            Text(Self.overflowTitle(hiddenCount: hiddenCount)).font(.title.weight(.medium)).lineLimit(1)
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .controlSize(.extraLarge)
        .buttonSizing(sizing)
    }

    /// `bareOverflowControl(hiddenCount:)` built from REAL hidden actions, via
    /// the same `overflowMenuItems` `overflowControl` uses. Test-only in
    /// practice: it gives `bareOverflowControlMatchesThePopulatedChip` a
    /// populated `Menu` to compare against. `ActionPillMeasurer` reads the
    /// label-only overload because it only has a hidden count.
    static func bareOverflowControl(hidden: [QuickAction], runtime: DeckRuntime,
                                    sizing: ButtonSizing = .fitted) -> some View {
        let title = Self.overflowTitle(hiddenCount: hidden.count)
        return Menu {
            overflowMenuItems(hidden: hidden, runtime: runtime)
        } label: {
            Text(title).font(.title.weight(.medium)).lineLimit(1)
                .foregroundStyle(Color(nsColor: .labelColor))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .controlSize(.extraLarge)
        .buttonSizing(sizing)
    }

    /// The chip's visible title, named so `overflowControl` and the tests that
    /// read the string (`theHeaderFoldAppearsExactlyWhenTheColumnDrops` and the
    /// chip renders in `RenderSweepTests`) share one "▾ N more" format.
    static func overflowTitle(hiddenCount: Int) -> String {
        "▾ \(hiddenCount) more"
    }

    /// `SubjectWell.spokenTitle` twin: strips the glyph VoiceOver would read as
    /// "down triangle". A named, pure function because the headless harness
    /// cannot walk an accessibility tree, so
    /// `theHeaderFoldAppearsExactlyWhenTheColumnDrops` can hold the actual
    /// string `headerOverflowControl` sets.
    static func spokenOverflowTitle(for title: String) -> String {
        title.hasPrefix("▾ ") ? String(title.dropFirst(2)) : title
    }
}

// -------------------------------------------------- the quick actions column

/// The side column for a `.row` selection's quick actions, between the act zone
/// and Controls. `QuickActionBar` is a namespace of pill recipes, not a view.
/// `DetailBand` reads
/// `OverviewLayout.bandZonePlan(bandWidth:actionCount:usableHeight:)` (its doc
/// carries the width, height and presence cascade) and hands this view the
/// resulting `OverviewLayout.BandActionsPlan`, so this view draws only what the
/// plan says fits.
///
/// Column-major fill: the design is a `plan.subColumns` × `plan.rows` grid, 2×5
/// at most, with `plan.rows` as few as 1 at the tightest heights.
/// `plan.subColumns` is not tied to the static
/// `OverviewLayout.bandActionsRowCap` (5): a second sub-column opens once
/// `actionCount` exceeds `rows`, this geometry's actual row budget
/// (`OverviewLayout.bandZonePlanCascade`'s `needsTwo = actionCount > rows`).
/// `columnMajorSplit(_:plan:)` puts up to `plan.rows` actions in the left
/// sub-column before spilling into a second. A row-major fill would reflow
/// EVERY action's position when one more joined, since the second row of a
/// 2-wide grid holds actions 3 and 4, not the back half of the set.
/// Column-major keeps the first `plan.rows` actions pinned in place, the same
/// "first buttons show first" promise as
/// `QuickAction.moved(_:fromOffsets:toOffset:)`.
///
/// Rows use the pill recipe (`QuickActionBar.bareControl`) at a row FRAME
/// height flexed between `TouchTarget.minimum` (44) and
/// `OverviewLayout.actionPillHeight` (64) by
/// `OverviewLayout.bandActionsRowHeight(columnBudget:rowCount:)`. It gives the
/// full 64 whenever the row count leaves room and compresses toward 44 as rows
/// multiply; at the tightest shape (`columnBudget` 311, five rows) it answers
/// 44. Its doc carries the worked table and the proof that the floor case does
/// not clip. `column(_:rowHeight:)` draws at the `rowHeight` that `body`
/// computes once off the left sub-column's count.
///
/// No `ScrollView`, for the reason `DetailBand.controlsZone(for:budget:)` gives
/// (see `DetailBand.swift`): a `ScrollView` as the outermost frame of a column
/// `measuredMinimum(_:)` walks breaks the sticky-window fix's Auto-Layout
/// technique. This column sits at that outermost position (a sibling of the act
/// zone and Controls in `columns(for:)`'s `HStack`), so it is capped by a plain
/// `.frame(maxHeight:).clipped()`, like `controlsZone`.
/// `bandQuickActionsNaturalHeight` clears the routing floor at ten actions by
/// exactly one point (its doc in `OverviewLayout.swift` states the margin), so
/// the clip is a backstop, not a designed fold.
struct QuickActionsColumn: View {
    let runtime: DeckRuntime
    let budget: Double
    /// What `OverviewLayout.bandZonePlan(bandWidth:actionCount:usableHeight:)`
    /// decided for THIS geometry: `DetailBand`'s `zonePlan.actions`, passed
    /// straight through, never re-derived. `body` imposes `columnWidth`; the
    /// reflow it drives is eased by `DetailBand.columns(for:)`'s animation, not
    /// this type's, because the act zone and Controls beside this column must
    /// move with it as ONE event. `columnMajorSplit(_:plan:)` reads
    /// `subColumns` and `rows` to decide which actions draw and where;
    /// `capacity` (`subColumns × rows`) is the most this column ever shows,
    /// whatever `runtime.frame.actions` offers.
    let plan: OverviewLayout.BandActionsPlan

    /// The reflow duration, named so a retune finds it. `.snappy`, the curve
    /// family of `DeckWindow.bandTransitionAnimation`: a quick, confident
    /// settle with negligible overshoot. 0.22 s, shorter than that animation's
    /// 0.3 s, because this reflow is smaller and far more frequent (reachable
    /// on a plain session selection, not just a window resize).
    static let reflowDuration: Double = 0.22

    /// Gated on `frame.reduceMotion` (wired from `NSWorkspace` via
    /// `DeckRuntime.refreshAccessibility`), as
    /// `DeckWindow.bandTransitionAnimation`. Reduce Motion means NO animation,
    /// never a faster one.
    ///
    /// Two callers share this one function, so `reduceMotion` has one
    /// authority: this column's trailing `.animation(...)` (the row-count-only
    /// case, see `ReflowKey`) and `DetailBand.columns(for:)`'s on the shared
    /// `HStack` (the width-driven reflow). `DetailBand` calls this rather than
    /// restating `.snappy(duration: 0.22)`. Neither scopes the animation on an
    /// ancestor broad enough for unrelated content to inherit it (as
    /// `CardWash`, `SessionOverview.swift`): `.animation(_:value:)` only arms
    /// when the KEYED value changes, so a question surface swapping or a
    /// transcript growing passes through unanimated even inside the same
    /// `HStack`.
    ///
    /// A decision ARRIVING is not exempt: new suggestion text reaches
    /// `bandZonePlan` through `DetailBand.decisionMinimumActWidth`'s
    /// content-dependent `minimumActWidth`, so it can move every field
    /// `ReflowKey` tracks. See `DetailBand.columns(for:)`.
    static func reflowAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .snappy(duration: reflowDuration)
    }

    /// What this column's own trailing `.animation(...)` keys on: visible row
    /// COUNT alone. The width-driven reflow is `DetailBand.columns(for:)`'s job
    /// (its `ReflowKey` wraps the shared `HStack`, covering `actWidth`,
    /// `actions?.columnWidth`, `actions?.rows` and `controlsShown` as ONE
    /// event); animating width on this column alone would leave the act zone
    /// and Controls cutting instantly beside a gliding column.
    ///
    /// What the parent key cannot see is a row appearing or disappearing at an
    /// unchanged plan: two sessions with identical geometry but different
    /// action COUNTS add or remove a visible row while none of the parent's
    /// four fields moves (`rows` depends on `usableHeight` alone, not
    /// `actionCount`, per `bandZonePlan`). This key catches that case, scoped
    /// to the one column whose content changed.
    private struct ReflowKey: Equatable {
        let visibleRows: Int
    }

    var body: some View {
        // The ONE read of `runtime.frame.actions` this view makes; every
        // `ForEach` below draws from the split built off this local, never a
        // second read a later closure could resolve against a differently-sized
        // array.
        //
        // EXC_BREAKPOINT law: `ForEach`'s per-child closures can re-run
        // independently of `body` under fine-grained `@Observable` invalidation
        // (`ObservationCenter._withObservation`), so a closure holding an OLD
        // index can run against a NEW, shorter array before `body` rebuilds.
        // This crashed on device when a band was dismissed and `dismiss()`
        // reprojected `runtime.frame.actions` smaller (reproduced by a
        // headless render test since retired along with the index-based pill rows).
        // So: read `actions` into a LOCAL once, derive everything from that
        // local, and never let a closure capture an index or count into
        // observable state. `SessionOverview.swift`'s `ForEach(lanes, id:
        // \.session)` (closures read only their own element) follows the same
        // discipline. `≤ 10` by construction: `Frame.actions` is
        // `QuickAction.offerable(...)`, capped by `QuickAction.maxOffered`.
        let actions = runtime.frame.actions
        let split = Self.columnMajorSplit(actions, plan: plan)
        // Computed once off the LEFT sub-column's count (the taller whenever a
        // set spills; see `columnMajorSplit`). Both sub-columns draw at this
        // SAME height: a shorter right column of taller pills would read as two
        // grids stitched together. See
        // `OverviewLayout.bandActionsRowHeight(columnBudget:rowCount:)`.
        let rowHeight = OverviewLayout.bandActionsRowHeight(columnBudget: budget, rowCount: split.left.count)
        VStack(alignment: .leading, spacing: 8) {
            // A plain titled `VStack`, not `GroupBox`: `GroupBox` bridges to an
            // AppKit container with its own Auto-Layout compression resistance,
            // which broke the sticky-window fix (`detailBandNeverDemandsHeight`
            // guards it). It is the same class of interference
            // `controlsZone(for:budget:)` documents for `NSScrollView`.
            // `.quaternary` with `RoundedRectangle(cornerRadius: 8)` is
            // `BandStateNotice`'s card treatment, reused so it reads like the
            // band's other cards.
            VStack(alignment: .leading, spacing: 8) {
                Text("Quick Actions")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if split.right.isEmpty {
                    column(split.left, rowHeight: rowHeight)
                } else {
                    HStack(alignment: .top, spacing: OverviewLayout.actionGridSpacing) {
                        column(split.left, rowHeight: rowHeight).frame(maxWidth: .infinity)
                        column(split.right, rowHeight: rowHeight).frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
            // LOAD-BEARING: like `controlsZone(for:budget:)`'s trailing
            // `Spacer(minLength: 0)` (`DetailBand.swift`). A bare `VStack` with
            // no compression/hugging signal at its bottom edge leaves
            // `measuredMinimum(_:)` reporting a `DetailBand` minimum STUCK at
            // whichever `usableHeight` was measured first (the sticky-window
            // regression).
            Spacer(minLength: 0)
        }
        // `plan.columnWidth` is imposed here, not by the caller, so this column
        // is the one place that knows its own width. The caller's shared reflow
        // animation reaches this frame either way. The caller's
        // `.frame(maxHeight: .infinity)` stays at the call site.
        .frame(width: plan.columnWidth, alignment: .topLeading)
        .frame(maxHeight: budget, alignment: .topLeading)
        // This column's second-level transition driver, keyed on
        // `ReflowKey.visibleRows` alone (the width-driven reflow is the
        // parent's job). `reduceMotion` comes from the same authority as
        // `DetailBand.columns(for:)`. It does not recompute `plan` or the
        // split; it only eases the render of a shape already decided.
        .animation(Self.reflowAnimation(reduceMotion: runtime.frame.reduceMotion),
                  value: ReflowKey(visibleRows: split.left.count + split.right.count))
        .clipped()
    }

    /// One sub-column's rows, using the pill recipe
    /// (`QuickActionBar.bareControl`). `rowHeight`, computed once in `body` by
    /// `OverviewLayout.bandActionsRowHeight(columnBudget:rowCount:)`, sets the
    /// row's FRAME height between `TouchTarget.minimum` (44) and
    /// `OverviewLayout.actionPillHeight` (64).
    ///
    /// `fillsHeight: true` (this is the only caller that passes it): the glass
    /// otherwise holds a fixed ~46 pt intrinsic height at any imposed frame, so
    /// a 64 pt row would draw a small pill floating in dead space; `sizing:
    /// .flexible` fills width only. `fillsHeight: true` wraps `bareControl`'s
    /// label in `.frame(maxWidth: .infinity, maxHeight: .infinity)` inside the
    /// button, so the glass grows to the imposed frame.
    /// `RenderSweepTests.thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight`
    /// measures this at the floor and at the strip's worst-case-busy shape. The
    /// glass still will not compress below its ~46 pt natural minimum at the 44
    /// pt floor, which clears `TouchTarget.minimum` anyway.
    ///
    /// `.frame(height: rowHeight)` then `.frame(maxWidth: .infinity)`: the row
    /// claims exactly `rowHeight` by the full column width, so layout (spacing,
    /// the card's total height) is exact and predictable.
    private func column(_ actions: [QuickAction], rowHeight: Double) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Iterate the VALUES directly, never an index into `runtime.frame`
            // (the EXC_BREAKPOINT law in `body`): a closure capturing an offset
            // could read past a shrunk array when `runtime.frame` changes under
            // a still-mounted row.
            ForEach(actions) { action in
                let debouncing = runtime.frame.debouncingActionIDs.contains(action.id)
                // `.opacity`/`.disabled`/`.help` come AFTER the exact frame,
                // never before: dimming is style, never layout, so a debouncing
                // row cannot change the measured row height. No
                // `.touchTarget()`: the row height is already `>=
                // TouchTarget.minimum` (by `bandActionsRowHeight`'s floor) and
                // the visible glass IS the touch target. `fillsHeight: true` is
                // this column's own opt-in (see `column(_:rowHeight:)`).
                QuickActionBar.bareControl(action.displayTitle, alarming: action.rail == .alarm, sizing: .flexible,
                                           fillsHeight: true) {
                    runtime.queue(action)
                }
                .frame(height: rowHeight)
                .frame(maxWidth: .infinity)
                .opacity(debouncing ? 0.5 : 1)
                .disabled(runtime.frame.actionBlock != nil || debouncing)
                .help(action.displayTitle)
                // A row popping in or out (another session's action set, or
                // this one shrinking or growing) fades rather than hard-cuts.
                // `body`'s trailing `.animation(...)` keyed on
                // `ReflowKey.visibleRows` arms this; `.transition` alone is
                // inert without an ambient animation.
                .transition(.opacity)
            }
        }
    }

    /// Column-major fill off `plan`, not a fixed cap. The column can be handed
    /// more actions than the geometry has room for (`plan.capacity` can fall
    /// short of `actions.count` at a squeezed height), and drawing past the
    /// plan is the silent overflow `DetailBand.yieldedHeaderFold` exists to
    /// name. `capped` trims to `plan.capacity` FIRST, then splits column-major
    /// at `plan.rows`: the first `plan.rows` actions down the left sub-column,
    /// the remainder (at most `plan.rows`, since `capped.count <= plan.capacity
    /// == subColumns × rows`) down the right. "First buttons show first" holds
    /// for a POSITION, not merely an order (as
    /// `QuickAction.moved(_:fromOffsets:toOffset:)`). `plan.subColumns == 1` is
    /// the common case, everything in one column; `body` reads
    /// `split.right.isEmpty` to skip the `HStack`.
    static func columnMajorSplit(_ actions: [QuickAction],
                                 plan: OverviewLayout.BandActionsPlan) -> (left: [QuickAction], right: [QuickAction]) {
        let capped = Array(actions.prefix(plan.capacity))
        guard plan.subColumns > 1 else { return (capped, []) }
        return (Array(capped.prefix(plan.rows)), Array(capped.dropFirst(plan.rows)))
    }
}

// ------------------------------------------------- state, in system colours

extension LaneState {
    /// A glyph as well as a colour: the two-channel rule, kept because it is
    /// an accessibility requirement rather than because a palette said so.
    var symbolName: String {
        switch self {
        case .idle: "pause.circle"
        case .working: "circle.dotted"
        case .needsYou: "exclamationmark.circle.fill"
        case .errored: "xmark.octagon.fill"
        case .ended: "checkmark.circle"
        }
    }

    /// System colours, not a theme's. These already answer to the user's
    /// appearance, to Increase Contrast and to Reduce Transparency; a private
    /// palette never did.
    ///
    /// Identity is a second colour channel (`CardColor`; its file doc divides
    /// naming a colour from painting one). The needs-you and `.working` WASH
    /// read the identity channel (`SessionCard.washColor`,
    /// `SessionOverview.swift`), but every tint HERE, on the chip and glyph,
    /// and the ticks' orange (`DeckWindow.swift`), stays the MEANING channel:
    /// one colour, one meaning. The rule is that a theme does not get to
    /// override them, and the identity palette is drawn from this same system
    /// palette (`CardColor.paletteNames`), so it keeps the promise too.
    var tint: Color {
        switch self {
        case .idle: .secondary
        case .working: .accentColor
        case .needsYou: .orange
        case .errored: .red
        case .ended: .secondary
        }
    }

    var spokenName: String {
        switch self {
        case .idle: "Idle"
        case .working: "Working"
        case .needsYou: "Needs you"
        case .errored: "Error"
        case .ended: "Ended"
        }
    }
}

extension Severity {
    var tint: Color {
        switch self {
        case .normal: .secondary
        case .caution: .orange
        case .alarm: .red
        }
    }
}

extension UsageIndicator.Window.Load {
    /// The green→yellow→orange ramp, in the three system steps the palette
    /// doctrine allows (see `LaneState.tint`: no fourth, blended step).
    var tint: Color {
        switch self {
        case .easy: .green
        case .busy: .yellow
        case .heavy: .orange
        }
    }
}

extension ContextLoad {
    /// The blue→orange→red ramp; `ContextLoad` (`Frame.swift`) states the
    /// thresholds. `.blue`, never `.accentColor`, so a customised accent never
    /// changes what "calm" looks like (same reasoning as `LaneState.tint`;
    /// `.working` still reads `.accentColor` because it is state identity, not
    /// load). Read by every surface ctx renders on, the fleet card footer
    /// (`SessionCard.contextTint`, `SessionOverview.swift`) and the band's
    /// big-number readout (`DetailBand.header`), so the two cannot disagree
    /// about the colour for a given percent.
    var tint: Color {
        switch self {
        case .calm: .blue
        case .caution: .orange
        case .alarm: .red
        }
    }
}


// ------------------------------------------------------ the touch floor

extension View {
    /// Copyable without arming a drag.
    ///
    /// `.textSelection(.enabled)` on macOS is a plain click-and-drag gesture
    /// with no long-press gate (unlike iOS). Inside a `ScrollView` on a TOUCH
    /// deck, a finger landing on a path or a prompt and moving would plausibly
    /// be captured as a text selection rather than handed to the scroll. A
    /// context menu keeps the copy and never competes for the drag.
    func copyable(_ value: String) -> some View {
        contextMenu {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(value, forType: .string)
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
        }
    }

    /// Give a control enough of itself to be hit by a finger.
    ///
    /// `contentShape` as well as `frame`, because enlarging a button's frame
    /// does not by itself enlarge what responds to a press.
    func touchTarget(minHeight: Double = TouchTarget.minimum,
                     minWidth: Double = TouchTarget.minimum) -> some View {
        frame(minWidth: minWidth, minHeight: minHeight)
            .contentShape(.rect)
    }
}
