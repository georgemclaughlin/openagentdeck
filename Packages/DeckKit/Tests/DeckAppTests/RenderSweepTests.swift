//
//  RenderSweepTests.swift · Tests/DeckAppTests
//
//  Every view the deck can put on screen, rendered once, at the sizes the
//  product is really used at.
//
//  Nine of the app's views had never been INSTANTIATED by any test —
//  `DecisionBar`, `QuestionTakeover`, `QueueSection`, `ActionBlockNotice`,
//  `SessionMenu`, `Chip`, `SessionInspector`, `SessionOverview`,
//  `QuickActionBar`. The suite asserted a great deal about the values behind
//  them and nothing at all about whether they could be built. That gap is how
//  a `DecisionBar` shipped with Allow and Deny at 24 pt: the values it read
//  were tested, the view was not.
//
//  These are deliberately COARSE. They do not check appearance — no test here
//  can, and this project has already deleted one suite for pretending
//  otherwise. What they check is the class of failure a headless render CAN
//  see: a view that comes back zero-sized, a view that grows past the glass it
//  has to live on, an enum case that reaches the surface as nothing at all.
//
//  The canvas that matters is 1920 x 480. That is the strip this product was
//  designed for, and it is short — 480 points is less than half a laptop
//  display — so "does this fit" is a real question here in a way it is not on
//  a normal Mac app.
//

import Testing
import SwiftUI
import AppKit
import DeckCore
import DeckAdapters
@testable import DeckApp

/// A plain reference-type box a `.onPreferenceChange` closure can write
/// into from outside the view tree — `controlsColumnRendersAtItsOwnDeclaredWidth`'s
/// own reader. `@MainActor`, the same isolation `RenderSweepTests` itself
/// carries: the closure that writes it runs during the SAME headless
/// layout pass `measured(_:width:)` forces, on the main actor either way.
@MainActor
private final class WidthCapture {
    var value: Double = 0
}

/// **`WidthCapture`'s own `CGRect` twin — for probing a control's OWN
/// resolved geometry directly, when there is no production `onGeometryChange`
/// seam to lean on the way `controlsColumnRendersAtItsOwnDeclaredWidth`
/// leans on `DetailBand.onControlsColumnWidthMeasured`.**
/// `thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight`'s own reader
/// — `QuickActionBar.bareControl` has no such seam, so the probe is wired
/// by hand, attached directly to the button inside a synthetic host, one
/// level closer to the glass than any existing seam reaches.
@MainActor
private final class RectCapture {
    var value: CGRect?
}

@MainActor
struct RenderSweepTests {

    /// The strip's height. Everything pinned to an edge competes for it.
    private static let stripHeight: Double = 480
    private static let stripWidth: Double = 1920

    /// **The `QuestionStage` overlay's own usable viewport — NOT
    /// `stripHeight` itself.** The titlebar (native window chrome, never
    /// part of the content view a `.overlay` draws into — `DeckWindow`'s
    /// own comment on where the overlay sits states this) eats real height
    /// off the strip's own 480. Retuned a live pass: measured live via the
    /// Accessibility API against the running `.unifiedCompact` build, the
    /// compact toolbar is exactly 40 pt (the ~52 pt this figure used to
    /// subtract was the STANDARD titlebar's, from before the scene shipped
    /// the compact style; ~38 was that ship's own pre-measurement
    /// estimate). 480 − 40 = 440. Unlike `QuestionOptionsBand
    /// .usableStripHeight`, the stage covers the status line rather than
    /// sitting above it (`QuestionStage`'s own doc: the overlay "owns the
    /// glass" including the status line's usual strip), so only the
    /// titlebar comes off here — the status line's own measured height has
    /// nothing to subtract in this viewport.
    private static let stageViewportHeight: Double = 440

    /// **The connection banner's own headless height, at the strip's own
    /// 1920 pt width — MEASURED, not the "~60 pt" this constant used to be
    /// approximated as.** `ConnectionBanner` is an unbudgeted top safe-area
    /// inset (`DeckWindow.swift`'s own `.safeAreaInset(edge: .top…)`), so
    /// the detail band's own budget tests have to account for it the same
    /// way `theChromeLeavesRoomForContent` already accounts for
    /// `StatusLine`'s own measured 21 pt at the bottom edge — a bar the
    /// strip may be showing at the SAME time a band budget is being spent.
    /// Measured through this file's own `measured(_:width:)` harness, a
    /// `.wrongPort` connection (any `needsAttention` case renders the same
    /// two-line layout — title, detail, the "Fix This" button — so the
    /// specific case does not matter), at `stripWidth`: came back exactly
    /// 60.0 pt, matching `theConnectionBannerIsConditional`'s own `< 120`
    /// ceiling with room to spare. That test, at its narrower 620 pt
    /// width, is NOT this constant's arbiter — the button reflows under
    /// the text at 620 (`ViewThatFits`-free but still narrower than the
    /// text needs), which costs more height than the strip's own full
    /// width does; `bandBudgetFitsAtEveryGeometryAndBannerState` below,
    /// which measures at `stripWidth` directly, is.
    private static let measuredBannerHeight: Double = 60

    /// **A narrow test width, used throughout this file wherever a
    /// component needs SOME reasonably narrow width to measure against and
    /// the exact number is not the point.** 380.
    ///
    /// **History — this used to be read directly off `DeckWindow
    /// .inspectorMinWidth`, not restated here, so this file and the
    /// `.inspector` column it measured against could not drift apart the
    /// way an earlier private copy (280, stale the moment `DeckWindow`'s
    /// own range moved to 380) already had once.** `.inspector` is retired
    /// now, machinery and all (`DeckWindow.swift`'s own top doc comment
    /// states the removal in full) — most of the call sites below were
    /// never actually measuring the inspector's own column at all, only
    /// borrowing its number as a convenient narrow fixture for an
    /// unrelated view (`ActionBlockNotice`, `SubjectWell`, `HandedBackNotice`,
    /// and others with no inspector-shaped opinion of their own), so this
    /// constant keeps the SAME 380 those measurements have always run
    /// against — unchanged behaviour, honestly named for what it actually
    /// is now: a fixture, not a live column width.
    private static let narrowPaneWidth: Double = 380

    /// **`narrowPaneWidth`'s own wider twin — 480, the SAME reason and the
    /// SAME history** (`DeckWindow.inspectorIdealWidth`, before `.inspector`
    /// retired).
    private static let mediumPaneWidth: Double = 480

    /// **Forces a real AppKit layout pass before reading a size.**
    ///
    /// A bare `NSHostingView(rootView:).fittingSize` answers off whatever
    /// SwiftUI has ALREADY resolved, and for a view like `SubjectWell` that
    /// derives part of its own body from an `onGeometryChange`-driven
    /// `@State` (item 2's wrap-truncation probe), that first resolution is
    /// necessarily stale — the state update lands, but nothing has asked
    /// AppKit to lay out again with it applied. Measured directly before
    /// this existed: a bare `.fittingSize` call, called once or even
    /// several times in a row on the same host, kept returning the
    /// PRE-update size; only giving the host an explicit `frame` and calling
    /// `layoutSubtreeIfNeeded()` — which forces AppKit to actually resolve
    /// SwiftUI's pending layout rather than hand back a cached answer — let
    /// the second pass land before `.fittingSize` was read again.
    ///
    /// The placeholder height (10) the interim frame is set to does not need
    /// to be close to the real answer; `layoutSubtreeIfNeeded` is what does
    /// the work, not the number it is seeded with.
    ///
    /// **What this measures.** This reads the
    /// content's IDEAL size at a fixed width (`view.frame(width:)` pins
    /// one axis; the other resolves naturally) — NOT the MINIMUM
    /// `.windowResizability(.contentSize)` actually enforces for the
    /// window's own resize floor. The two coincide often enough that
    /// every band-budget test in this file, built on this function, caught
    /// real bugs — but they are not the SAME measurement, and the live
    /// resize bug that survived the first containment fix (`DeckWindow.swift`'s
    /// own doc comment on `.frame(minWidth:minHeight:)` tells that story)
    /// is exactly the gap between them: this function measured the caps
    /// doing their job (ideal ≤ budget) while the window kept moving,
    /// because AppKit was consulting a DIFFERENT number — `measuredMinimum(_:)`
    /// below is that number, and its own doc comment states the
    /// correspondence THIS comment used to claim for `fittingSize` alone.
    private func measured(_ view: some View, width: Double) -> CGSize {
        let host = NSHostingView(rootView: view.frame(width: width))
        host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// **`measured(_:width:)`'s own mirror, for the WIDTH axis.** Fixes
    /// HEIGHT via `.frame(height:)` and reads back the natural WIDTH — the
    /// same IDEAL-at-a-fixed-axis reading, on the other dimension. See
    /// `measured(_:width:)`'s own doc comment  for what this
    /// does NOT measure — the enforced MINIMUM — and `measuredMinimum(_:)`
    /// below for the function that does.
    private func measuredWidth(_ view: some View, height: Double) -> CGSize {
        let host = NSHostingView(rootView: view.frame(height: height))
        host.frame = NSRect(x: 0, y: 0, width: 10, height: height)
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// **The MINIMUM `.windowResizability(.contentSize)` actually
    /// enforces — the corrected measurement, replacing
    /// `measured(_:width:)`'s mistaken claim to be this.**
    ///
    /// **The live bug this exists to catch.** reproduced on the
    /// running deck, AX-probed: open the band at some window size, close
    /// it again, then try to resize the window smaller — it snaps back to
    /// EXACTLY the size the window was when the band opened, every time,
    /// regardless of what size is requested. The first `DetailBand`
    /// containment (`.frame(maxWidth:width, maxHeight:usableHeight)`)
    /// bounds the content's IDEAL size — proven by every band-budget test
    /// in this file, all still green — but a `.frame(maxHeight:)` with no
    /// `minHeight` does not stop the CHILD's own uncompressible content
    /// (fixed rows, `.touchTarget()`'s own `.frame(minWidth:minHeight:)`
    /// floors on every button) from reporting THAT as its minimum when the
    /// cap does not bind below it — and when the cap DOES bind (the
    /// ordinary case: `usableHeight` is the live window's own current
    /// size, and the interior's uncompressed content routinely exceeds
    /// it), the reported minimum tracks the CAP instead — either way,
    /// composition-dependent, never the fixed floor the product promises.
    ///
    /// **Investigated, not assumed — three techniques tried before this
    /// one held up.** (1) `fittingSize` alone, `measured(_:width:)`'s own
    /// technique — reads IDEAL, proven wrong by the live bug surviving a
    /// fix that made every `fittingSize`-based assertion pass. (2)
    /// `NSHostingSizingOptions.minSize` read directly off `fittingSize`/
    /// `intrinsicContentSize` with no Auto Layout involved — returns
    /// `(0,0)`/`(-1,-1)` (AppKit's `noIntrinsicMetric` sentinel): this
    /// sizing option does not surface through those properties without
    /// Auto Layout resolving it. (3) **This one** — `.minSize` DOES
    /// surface, correctly and repeatably, once the hosting view is
    /// dropped into a real Auto Layout constraint graph (a container view,
    /// leading/top anchors pinning position only) and `fittingSize` is
    /// read AFTER `layoutSubtreeIfNeeded()` resolves those constraints.
    /// Verified against a synthetic view shaped like the real band
    /// (`.touchTarget()`-style rows, each its own `.frame(minWidth:
    /// minHeight:)`, wrapped in `.frame(maxHeight:)` at several different
    /// LIVE-style cap values): the reading tracked the cap exactly,
    /// reproducing the live bug's own signature in a headless harness for
    /// the first time — and wrapping that SAME content in an outer
    /// `.frame(minWidth: 960, minHeight: 270)` made the reading land on
    /// EXACTLY `(960, 270)` regardless of the cap (300, 600, 548 all
    /// tried), while the SAME wrapping measured through `measured(_:width:)`
    /// (the IDEAL reading) left a larger natural height completely
    /// unaffected (960×548 stayed 960×548, not clamped down to 270) —
    /// which is exactly the two properties the fix needs at once: the
    /// enforced MINIMUM pinned to one constant, the window's own IDEAL/
    /// current size still free to be whatever it actually is.
    ///
    /// **Why the container/constraint machinery, not a bare property
    /// read.** `NSHostingSizingOptions.minSize` is documented as feeding
    /// AUTO LAYOUT'S notion of a view's minimum — the same mechanism
    /// AppKit's own window-sizing code consults for a content view hosted
    /// via constraints, which is what a `Window` scene's own content
    /// ultimately is under `.windowResizability(.contentSize)`. A bare
    /// `.fittingSize`/`.intrinsicContentSize` read never asks Auto Layout
    /// to resolve anything, so the sizing option has nothing to feed.
    private func measuredMinimum(_ view: some View) -> CGSize {
        let host = NSHostingView(rootView: view)
        host.sizingOptions = .minSize
        host.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 5000, height: 5000))
        container.addSubview(host)
        host.leadingAnchor.constraint(equalTo: container.leadingAnchor).isActive = true
        host.topAnchor.constraint(equalTo: container.topAnchor).isActive = true
        container.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// `prompt` defaults to the fixture's original one-line text so every
    /// pre-existing call site (`lane(state)`, `lane()`) keeps reading
    /// exactly the fixture it always has — the two-row fleet's own tests
    /// below are the only callers that override it, with a prompt long
    /// enough to force a specific line count.
    private func lane(_ state: LaneState = .working, prompt: String? = nil) -> LaneView {
        LaneView(session: SessionID("0ba90d07-1111"), state: state, isExpanded: false,
                 contextPercent: 63, sources: [:],
                 directory: Redacted("/Users/you/work/parser"),
                 prompt: Redacted(prompt ?? "rewrite the layout so the fleet is the primary object"),
                 branch: Redacted("main"), lastTool: "Bash",
                 permissionMode: PermissionBadge.bypass,
                 host: HostAddress(workspace: "w", surface: "s"))
    }

    /// **`lane()`'s own promptless twin — the same worst-realistic tags/
    /// footer/gauge content, but a genuinely nil prompt rather than a
    /// short fallback string.** `lane(_:prompt:)` above cannot produce
    /// this: its own `prompt ?? "..."` fallback means passing `nil` there
    /// still yields a NON-nil `LaneView.prompt`. The two-row fleet's own
    /// promptless-tier tests (`aFullCardFitsTheTwoRowBudget`,
    /// `aZeroLineCardDrawsNoPromptBlock`) are the only callers.
    private func promptlessLane() -> LaneView {
        LaneView(session: SessionID("0ba90d07-1111"), state: .working, isExpanded: false,
                 contextPercent: 63, sources: [:],
                 directory: Redacted("/Users/you/work/parser"), prompt: nil,
                 branch: Redacted("main"), lastTool: "Bash",
                 permissionMode: PermissionBadge.bypass,
                 host: HostAddress(workspace: "w", surface: "s"))
    }

    /// The stream behind `waitingRuntime`, reusable by tests that need to push
    /// one more event onto it.
    static let fixtureEvents: [DeckEvent] = events()

    private static func events(questions: [Question] = [],
                               suggestions: JSONValue? = nil) -> [DeckEvent] {
        let t = { (ms: Int64) in Instant(sinceStart: Millis(ms)) }
        return [
            .hook(HookEvent(id: EventID("s1"), at: t(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .hook(HookEvent(id: EventID("q1"), at: t(10), kind: .preToolUse,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: questions.isEmpty ? "Bash" : SubjectReader.questionTool,
                            toolUseID: "t1", held: .value(120_000),
                            subject: Subject(tool: "Bash",
                                             detail: Redacted("rm -rf build/"), field: nil),
                            questions: questions,
                            permissionSuggestions: suggestions,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .sessionSelected(SessionID("alpha"), at: t(20)),
        ]
    }

    /// A runtime holding one session, selected, with a tool call waiting on a
    /// human. Enough to build every view the band composes for a selection,
    /// for real.
    private func waitingRuntime(questions: [Question] = [],
                                suggestions: JSONValue? = nil) -> DeckRuntime {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(
            Reducer.run(Self.events(questions: questions, suggestions: suggestions)))
        return runtime
    }

    // --------------------------------------------------- nothing renders empty

    /// **Every reason the deck can refuse reaches the glass as words.**
    ///
    /// `ActionBlock` is the type that says why a control is dark, and a dark
    /// control with no reason beside it is the mute failure this whole product
    /// is built to refuse. The enum grew a case this year — `surfaceNotASession`
    /// was split out of `composerBusy` because the two were being reported as
    /// one — and nothing rendered any of them in a test.
    @Test("every refusal renders, and says something different",
          arguments: [ActionBlock.hostUnavailable, .unroutable, .composerBusy,
                      .surfaceNotASession, .hostError])
    func everyRefusalRenders(_ block: ActionBlock) {
        let size = measured(ActionBlockNotice(block: block), width: Self.narrowPaneWidth)
        #expect(size.height > 0, Comment(rawValue: "\(block.rawValue) renders as nothing"))
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "\(block.rawValue) is \(size.height) pt — taller than the "
                        + "strip it has to be read on"))
        #expect(!block.message.isEmpty)
    }

    /// And no two of them say the same thing. Two refusals with one sentence is
    /// the bug that shipped: a deck pointed at a zsh prompt told the user their
    /// composer was not empty when nothing had been typed anywhere.
    @Test("no two refusals share a sentence")
    func refusalsAreDistinct() {
        let all: [ActionBlock] = [.hostUnavailable, .unroutable, .composerBusy,
                                  .surfaceNotASession, .hostError]
        #expect(Set(all.map(\.message)).count == all.count,
                "two different refusals give the user the same reason")
    }

    /// **The squeezed notice keeps the reason — pinned as arithmetic, not a
    /// string search.** The compact recipe used to drop `block.message`, and
    /// a live refusal (a live pass, a squeezed desktop window) showed what
    /// that costs: the headline said the deck could not send, and the one
    /// sentence saying WHY was exactly what had been cut. `compact` is a
    /// padding decision now, never a content one — so with the CONTENT
    /// width held equal, the two variants wrap identically and differ by
    /// exactly the vertical padding delta, 2 × (16 − 6) = 20 pt. (Holding
    /// content width equal means measuring the compact variant 20 pt
    /// NARROWER — padding eats width too, and at one outer width the
    /// compact caption gets 20 pt more line width, so `composerBusy`'s
    /// longer sentence wraps to one line where the full variant needs
    /// two; measured, the first draft of this pin failed on exactly
    /// that.) If compact ever cuts the caption again, its height falls
    /// short of this relation by the caption's own height, and this goes
    /// red for every block there is.
    @Test("the compact notice differs from the full one by padding alone",
          arguments: [ActionBlock.hostUnavailable, .unroutable, .composerBusy,
                      .surfaceNotASession, .hostError])
    func compactNoticeKeepsTheReason(_ block: ActionBlock) {
        let full = measured(ActionBlockNotice(block: block), width: Self.narrowPaneWidth)
        let squeezed = measured(ActionBlockNotice(block: block, compact: true),
                                width: Self.narrowPaneWidth - 20)
        #expect(squeezed.height == full.height - 20, Comment(rawValue:
                "\(block.rawValue): compact measured \(squeezed.height) pt at equal content "
                + "width against the full notice's \(full.height) pt — expected exactly the "
                + "20 pt vertical padding delta and nothing else; a shortfall past 20 means "
                + "content was cut, a regression that has already shipped once"))
    }

    // --------------------------------------------------------- the decision bar

    /// **`DecisionBar.outerPadding`'s own arbiter.** `outerPadding: Double = 16` is a restated NUMBER
    /// standing in for what `.padding()` (no argument) draws — load-
    /// bearing for the DEFAULT's own neutrality (history: this used to
    /// matter for the inspector's own already-shipped chrome specifically;
    /// `.inspector` is retired now, `DeckWindow.swift`'s own top doc
    /// comment states the removal in full, and `DetailBand` — the one
    /// production caller left — always passes its own explicit value
    /// rather than leaning on this default), and `RenderSweepTests` still
    /// measures this function directly at the bare default. Same content,
    /// both ways — a `Text` is enough; the equivalence is about the
    /// PADDING, not about `DecisionBar`'s own further content — and the
    /// heights must match exactly.
    @Test("DecisionBar.outerPadding's default (16) matches what a bare .padding() actually draws")
    func outerPaddingDefaultMatchesSystemDefault() {
        let bare = measured(Text("x").padding(), width: 200)
        let explicit = measured(Text("x").padding(16), width: 200)
        #expect(bare.height == explicit.height,
                Comment(rawValue: "bare .padding() measured \(bare.height) pt, .padding(16) measured "
                        + "\(explicit.height) pt — DecisionBar.outerPadding's own default (16) no longer "
                        + "matches what a plain .padding() draws"))
    }

    /// The decision bar, built the way `DetailBand` builds it. Never
    /// instantiated by a test until now, which is how its buttons reached
    /// production at 24 pt.
    @Test("the decision bar renders and fits the strip")
    func theDecisionBarRenders() {
        let runtime = waitingRuntime()
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no decision, so nothing below is measured")
            return
        }
        // Zero suggestions: today's exact two-button bar, per chunk 3's own
        // claim — "if there are no suggestions, the bar is exactly today's
        // two buttons".
        #expect(decision.suggestionLabels.isEmpty, "the bare fixture should carry no suggestions")
        let size = measured(DecisionBar(decision: decision, runtime: runtime),
                            width: Self.narrowPaneWidth)
        #expect(size.height > TouchTarget.decision,
                "the bar is shorter than the buttons it contains")
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the decision bar is \(size.height) pt on a 480 pt strip"))
    }

    /// The same bar with one suggestion riding along — Claude Code's own
    /// option 2, rendered as a third button between Allow and Deny. Same
    /// discipline as `theDecisionBarRenders`: a headless render is the only
    /// thing here that could catch the new button shipping under the touch
    /// floor the way the original two once did.
    @Test("the decision bar renders a suggestion button and still fits the strip")
    func theDecisionBarRendersWithASuggestion() throws {
        let suggestions = try #require(JSONValue.parse(
            #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"}]"#))
        let runtime = waitingRuntime(suggestions: suggestions)
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no decision, so nothing below is measured")
            return
        }
        #expect(decision.suggestionLabels == ["Don't ask again for: git push *"])
        let size = measured(DecisionBar(decision: decision, runtime: runtime),
                            width: Self.narrowPaneWidth)
        #expect(size.height > TouchTarget.decision,
                "the bar is shorter than the buttons it contains")
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the decision bar with a suggestion is \(size.height) pt on a "
                        + "480 pt strip"))
    }

    /// Three suggestions riding along — Allow, three suggestion buttons, and
    /// Deny, five controls in one bar. `LVV-permission` has only ever
    /// recorded one, so this shape is synthesised rather than pinned to a
    /// recording; it exists because `ForEach` over `suggestionLabels`
    /// promises to cover more than the one-element case it has actually been
    /// measured at, and a promise a headless render can check for free is
    /// one worth checking.
    ///
    /// This assertion is NOT weakened if it fails. Five 64 pt-floor buttons
    /// on a narrow test width, stacked by `ViewThatFits`'s
    /// vertical fallback, is exactly the kind of arithmetic that can outgrow
    /// a 480 pt strip — and if it does, that is a real product finding (the
    /// bar needs its own scroll, or a cap on how many suggestions render, or
    /// something else this test does not get to decide), not a threshold to
    /// widen until the test goes green.
    @Test("the decision bar renders three suggestion buttons and still fits the strip")
    func theDecisionBarRendersWithThreeSuggestions() throws {
        let suggestions = try #require(JSONValue.parse(
            #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"},"#
            + #"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git commit *"}],"behavior":"allow","destination":"localSettings"},"#
            + #"{"type":"setMode","mode":"acceptEdits"}]"#))
        let runtime = waitingRuntime(suggestions: suggestions)
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no decision, so nothing below is measured")
            return
        }
        #expect(decision.suggestionLabels == ["Don't ask again for: git push *",
                                              "Don't ask again for: git commit *",
                                              "Switch mode to acceptEdits"],
                Comment(rawValue: "got \(decision.suggestionLabels)"))
        let size = measured(DecisionBar(decision: decision, runtime: runtime),
                            width: Self.narrowPaneWidth)
        #expect(size.height > TouchTarget.decision,
                "the bar is shorter than the buttons it contains")
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the decision bar with three suggestions is \(size.height) pt "
                        + "on a 480 pt strip — five controls may not fit; if this fails, that is "
                        + "the finding, not the assertion"))
    }

    // ------------------------------------------------------- the subject well

    /// Audit item 1: `tool_input.description` binds to `Subject.caption` and
    /// has to actually add visible height under the command, never merely
    /// compile — the same discipline `handedBackNoticeRendersWaitingFor`
    /// already holds its own optional line to.
    @Test("the decision bar renders a subject's caption under its detail")
    func theDecisionBarRendersASubjectCaption() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let bare = Decision(hold: hold, subject: Subject(
            tool: "Bash", detail: Redacted("git push --force origin main"), field: "command"))
        let captioned = Decision(hold: hold, subject: Subject(
            tool: "Bash", detail: Redacted("git push --force origin main"), field: "command",
            caption: Redacted("Force push local main to origin/main")))

        let withoutCaption = measured(DecisionBar(decision: bare, runtime: runtime),
                                      width: Self.narrowPaneWidth)
        let withCaption = measured(DecisionBar(decision: captioned, runtime: runtime),
                                   width: Self.narrowPaneWidth)
        #expect(withCaption.height > 0)
        #expect(withCaption.height < Self.stripHeight,
                Comment(rawValue: "the decision bar with a caption is "
                        + "\(withCaption.height) pt on a 480 pt strip"))
        #expect(withCaption.height > withoutCaption.height,
                "the caption line added no visible height — it may not be rendering at all")
    }

    /// **Item 1's identity fix.** Two DIFFERENT holds, the SAME 20-line plan
    /// text on both — so if `expanded` ever leaked from one to the other,
    /// the gap would be exactly the large, already-proven one between
    /// `theSubjectWellCollapsesALongPlan` and `theSubjectWellExpandsALongPlan`,
    /// not a subtle few points that a short subject's own natural sizing
    /// could muddy.
    ///
    /// Without `.id(decision.hold)` on `SubjectWell`, SwiftUI treats the
    /// second `DecisionBar` render as the SAME view continuing forward —
    /// its `@State private var expanded` survives from whatever the first
    /// decision left it at, which in production means: expand a plan, tap
    /// Allow, and the NEXT decision's well renders pre-expanded — and if
    /// THAT subject is short enough to need no chip, there is no way back
    /// to collapsed at all, because the chip only exists inside `if let
    /// chipTitle`, a branch a short subject never enters.
    @Test("a new decision's subject well never inherits the previous one's expanded state")
    func subjectWellIdentityResetsAcrossDecisions() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let plan = (1...20).map { "Step \($0): do the next thing on the list" }.joined(separator: "\n")
        let firstHold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let firstDecision = Decision(hold: firstHold, subject: Subject(
            tool: "ExitPlanMode", detail: Redacted(plan), field: "plan"))
        let secondHold = HoldID(session: SessionID("alpha"), toolUseID: "t2")
        let secondDecision = Decision(hold: secondHold, subject: Subject(
            tool: "ExitPlanMode", detail: Redacted(plan), field: "plan"))

        // `.id()` only actually matters across a REBUILD of the same view
        // identity path, not two independently-constructed hosting views —
        // so this renders both through ONE `NSHostingView`, updating its
        // `rootView` in place, the same way a live window hands `DeckWindow`
        // a new `decision` without ever tearing the tree down.
        let host = NSHostingView(rootView: AnyView(
            DecisionBar(decision: firstDecision, runtime: runtime, initiallyExpanded: true)
                .frame(width: Self.narrowPaneWidth)))
        host.frame = NSRect(x: 0, y: 0, width: Self.narrowPaneWidth, height: 10)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize

        // Swap in the SECOND decision on the SAME host — this is the
        // transition `.id(decision.hold)` has to survive.
        host.rootView = AnyView(
            DecisionBar(decision: secondDecision, runtime: runtime)
                .frame(width: Self.narrowPaneWidth))
        host.layoutSubtreeIfNeeded()
        let afterSwap = host.fittingSize

        let secondAlone = measured(DecisionBar(decision: secondDecision, runtime: runtime),
                                   width: Self.narrowPaneWidth)
        #expect(abs(afterSwap.height - secondAlone.height) < 1,
                Comment(rawValue: "the second decision's bar is \(afterSwap.height) pt after "
                        + "following an expanded one on the same host, but \(secondAlone.height) pt "
                        + "measured fresh on its own — the expanded state leaked across what should "
                        + "have been an `.id()` boundary"))
    }

    /// Audit item 2/3: a 20-line `ExitPlanMode` plan, collapsed — the well
    /// shows its default four lines and the mandatory "▾ N more lines" chip
    /// UX_DESIGN §4 mandates, never a silent clip past them.
    @Test("the subject well collapses a long plan behind the overflow chip")
    func theSubjectWellCollapsesALongPlan() {
        let plan = (1...20).map { "Step \($0): do the next thing on the list" }.joined(separator: "\n")
        let subject = Subject(tool: "ExitPlanMode", detail: Redacted(plan), field: "plan")
        #expect(SubjectOverflow.chipText(for: plan) == "▾ 16 more lines",
                "the fixture itself stopped overflowing — nothing below is measuring the chip path")
        let size = measured(SubjectWell(subject: subject), width: Self.narrowPaneWidth)
        #expect(size.height > 0)
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the collapsed well is \(size.height) pt on a 480 pt strip"))
    }

    /// The same plan, expanded: taller than collapsed — there is visibly
    /// more on screen — and still bounded, so an expanded well can never
    /// itself blow out the strip the rest of the decision bar has to share.
    @Test("the subject well expands a long plan to a bounded, scrollable region")
    func theSubjectWellExpandsALongPlan() {
        let plan = (1...20).map { "Step \($0): do the next thing on the list" }.joined(separator: "\n")
        let subject = Subject(tool: "ExitPlanMode", detail: Redacted(plan), field: "plan")
        let collapsed = measured(SubjectWell(subject: subject), width: Self.narrowPaneWidth)
        let expanded = measured(SubjectWell(subject: subject, initiallyExpanded: true),
                                width: Self.narrowPaneWidth)
        #expect(expanded.height > collapsed.height,
                Comment(rawValue: "expanded (\(expanded.height) pt) is not taller than collapsed "
                        + "(\(collapsed.height) pt) — the toggle may not be wired to anything"))
        #expect(expanded.height < Self.stripHeight,
                Comment(rawValue: "the expanded well is \(expanded.height) pt on a 480 pt strip"))
    }

    /// **Item 2's own render-level proof.** UX_DESIGN §98's forbidden case,
    /// literally: a newline-free single-line `Bash` chain, long enough to
    /// wrap well past `SubjectOverflow.collapsedLines` visual rows at
    /// `narrowPaneWidth`, with `SubjectOverflow.lineCount`
    /// itself confirming it is exactly ONE line by newline arithmetic — the
    /// shape `chipTextNeverClaimsANumberForAWrapOnlyLine` proves the pure
    /// function stays silent about. Before this pass the well's chip only
    /// ever asked `lineCount`, so this text got no chip and no way to see
    /// what the collapsed four lines were hiding.
    ///
    /// **The comparison has to isolate the CHIP, not the wrap.** A first
    /// draft of this test compared the wrapped chain against a one-line
    /// command like `"git status"` and asserted the wrapped well was
    /// taller — and that passed even with the measured mechanism ripped
    /// back out, because a single line that wraps to four capped rows is
    /// ALREADY taller than a one-line command with no wrapping at all,
    /// chip or no chip. It was measuring `.lineLimit`'s own wrapping, not
    /// the chip. The fixture below fixes that: `fourLineBaseline` is FOUR
    /// newline-separated lines — exactly `SubjectOverflow.collapsedLines`,
    /// the documented no-chip boundary `noChipWithinCollapsedLines` already
    /// covers — so its capped `Text` renders the same four visual rows the
    /// wrapped chain's capped `Text` does, and needs no chip by construction
    /// (newline arithmetic alone already proves it, no measurement
    /// required). With both fixtures' TEXT portions the same height, any
    /// remaining gap is the chip row itself, not wrapping.
    @Test("a long single-line subject renders its overflow chip from measured wrap, not newlines")
    func theSubjectWellRendersAWrapOnlyChip() {
        let longChain = (1...40).map { "echo step\($0)" }.joined(separator: " && ")
        #expect(SubjectOverflow.lineCount(longChain) == 1,
                "the fixture itself gained a newline — this would exercise the N-label path, not wrap")
        #expect(SubjectOverflow.chipText(for: longChain) == nil,
                "the pure function should stay silent here — see chipTextNeverClaimsANumberForAWrapOnlyLine")
        let fourLineBaseline = (1...4).map { "line \($0)" }.joined(separator: "\n")
        #expect(SubjectOverflow.chipText(for: fourLineBaseline) == nil,
                "the baseline itself needs a chip — it would no longer isolate the wrap-only case")

        let wrapped = measured(SubjectWell(subject: Subject(
            tool: "Bash", detail: Redacted(longChain), field: "command")),
            width: Self.narrowPaneWidth)
        let baseline = measured(SubjectWell(subject: Subject(
            tool: "Bash", detail: Redacted(fourLineBaseline), field: "command")),
            width: Self.narrowPaneWidth)
        #expect(wrapped.height > baseline.height + 20,
                Comment(rawValue: "a wrap-only overflow (\(wrapped.height) pt) is barely taller than "
                        + "a chip-free four-line baseline of the SAME capped height "
                        + "(\(baseline.height) pt) — the measured chip never rendered"))
    }

    /// **Item 3's own arbiter.** The worst shape `DecisionBar` takes today:
    /// a suggestion button riding beside Allow and Deny, AND its subject
    /// well pre-expanded to a 20-line plan — both of the bar's own variable
    /// costs at once, at a narrow test width.
    /// This is the test `SubjectOverflow.expandedMaxHeight`'s own doc
    /// comment cites as the number's arbiter: if a future change to either
    /// cost pushes this over the 480 pt strip, THIS fails with the
    /// arithmetic that says why, rather than shipping a bar that scrolls
    /// itself off the surface it is pinned to.
    @Test("the decision bar with a suggestion and an expanded plan still fits the strip")
    func decisionBarWithSuggestionAndExpandedPlanFitsTheStrip() {
        let plan = (1...20).map { "Step \($0): do the next thing on the list" }.joined(separator: "\n")
        let hold = HoldID(session: SessionID("alpha"), toolUseID: "t1")
        let decision = Decision(hold: hold,
                                subject: Subject(tool: "ExitPlanMode", detail: Redacted(plan), field: "plan"),
                                suggestionLabels: ["Don't ask again for: git push *"])
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let size = measured(DecisionBar(decision: decision, runtime: runtime, initiallyExpanded: true),
                            width: Self.narrowPaneWidth)
        #expect(size.height > 0)
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the decision bar with a suggestion and an expanded plan is "
                        + "\(size.height) pt on a \(Self.stripHeight) pt strip — if this fails, "
                        + "SubjectOverflow.expandedMaxHeight needs to come down, not this assertion"))
    }

    /// The takeover, for a real question call.
    @Test("the question takeover renders and fits the strip")
    func theQuestionTakeoverRenders() {
        let question = Question(text: Redacted("Which approach?"),
                                header: Redacted("Approach"),
                                options: [QuestionOption(label: Redacted("Rewrite"),
                                                         detail: Redacted("Slower, cleaner")),
                                          QuestionOption(label: Redacted("Patch"),
                                                         detail: Redacted("Faster, riskier"))],
                                multiSelect: false)
        let runtime = waitingRuntime(questions: [question])
        guard let decision = runtime.frame.decisions.first, !decision.questions.isEmpty else {
            Issue.record("the fixture produced no question call, so nothing below is measured")
            return
        }
        let size = measured(QuestionTakeover(decision: decision, runtime: runtime),
                            width: Self.narrowPaneWidth)
        #expect(size.height > 0)
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the takeover is \(size.height) pt on a 480 pt strip"))
    }

    /// A multi-line ASCII preview, at the narrowest column the takeover ever
    /// renders at. Coarse in the same way every other test in this file is —
    /// it cannot see whether the preview WRAPPED, only whether the view came
    /// back a sane, positive, in-bounds size — but a `ScrollView(.horizontal)`
    /// around an unwrapped `Text` is exactly the shape that, if it silently
    /// stopped scrolling and started wrapping instead, would blow the strip's
    /// height out on a wide multi-line mockup: `fixedSize(horizontal: true, …)`
    /// forces the text's own intrinsic width, and a regression there reads
    /// as this test's height assertion failing rather than as a passing test
    /// that never looked.
    @Test("a question option's preview renders and still fits the strip")
    func theQuestionTakeoverRendersAPreview() {
        let question = Question(text: Redacted("Which layout?"),
                                header: Redacted("Layout"),
                                options: [QuestionOption(
                                    label: Redacted("Grid"),
                                    detail: Redacted("Three columns"),
                                    preview: Redacted(
                                        "+------+------+------+\n"
                                        + "| lane | lane | lane |\n"
                                        + "+------+------+------+")),
                                          QuestionOption(label: Redacted("List"),
                                                         detail: Redacted("One column"))],
                                multiSelect: false)
        let runtime = waitingRuntime(questions: [question])
        guard let decision = runtime.frame.decisions.first, !decision.questions.isEmpty else {
            Issue.record("the fixture produced no question call, so nothing below is measured")
            return
        }
        #expect(decision.currentQuestion?.options.first?.preview != nil,
                "the fixture lost its own preview before anything below could measure it")
        let size = measured(QuestionTakeover(decision: decision, runtime: runtime),
                            width: Self.narrowPaneWidth)
        #expect(size.height > 0)
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the takeover with a preview is \(size.height) pt on a 480 pt strip"))
    }

    /// The recorded LV37 question, read off `Fixtures/live/
    /// LV37-question-preview/lv37-previews.json` — a `jq`-extracted,
    /// byte-preserved copy of `.payload.tool_input.questions[0]` off row 3
    /// of the DeckCoreTests corpus's own `Fixtures/live/
    /// LV37-question-preview/payloads.ndjson` (the exact recording `Corpus
    /// .questionPreviewRun()` replays there — see that function's own doc
    /// comment for how it was captured). This target carries its own
    /// resource bundle and cannot reach across to DeckCoreTests's, so the
    /// question is copied rather than shared; the copy was produced by `jq
    /// '.payload.tool_input.questions[0]'` over that ndjson's third line,
    /// byte-for-byte, never hand-retyped — the FULL question object (its
    /// own `question`/`header`/`multiSelect`, and every option's `label`/
    /// `description`/`preview`), not only the three preview strings a first
    /// cut of this fixture carried: measuring the takeover's true recorded shape needs the real question text and all three options together to measure the
    /// takeover's true recorded shape, not a synthetic stand-in for it.
    private struct LV37Option: Decodable { let label: String; let description: String; let preview: String }
    private struct LV37Question: Decodable {
        let question: String; let header: String; let multiSelect: Bool
        let options: [LV37Option]
    }

    private func lv37Question() -> LV37Question? {
        let url = Bundle.module.resourceURL!
            .appendingPathComponent("Fixtures/live/LV37-question-preview/lv37-previews.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LV37Question.self, from: data)
    }

    /// The recorded question, decoded into the deck's own `Question` —
    /// `previews: false` strips every option's mockup (keeping label and
    /// detail), the bare-content counterpart the floor assertions below
    /// compare against.
    private func lv37DeckQuestion(previews: Bool) -> Question? {
        guard let recorded = lv37Question() else { return nil }
        let options = recorded.options.map { option in
            QuestionOption(label: Redacted(option.label), detail: Redacted(option.description),
                           preview: previews ? Redacted(option.preview) : nil)
        }
        return Question(text: Redacted(recorded.question), header: Redacted(recorded.header),
                        options: options, multiSelect: recorded.multiSelect)
    }

    /// One takeover, at one width, from the real recorded question —
    /// `previews: true` for the actual call, `false` for the bare-content
    /// counterpart. `optionCount` trims to fewer of the recorded options,
    /// keeping the SAME header, question text and — for whichever options
    /// remain — the same recorded label/detail/preview; used to build the
    /// floor's minimal reference below without inventing synthetic text
    /// the real chrome (header, long question sentence) would not share.
    private func lv37Takeover(previews: Bool, optionCount: Int = 3, width: Double) -> Double? {
        guard let question = lv37DeckQuestion(previews: previews) else { return nil }
        let trimmed = Question(text: question.text, header: question.header,
                               options: Array(question.options.prefix(optionCount)),
                               multiSelect: question.multiSelect)
        let runtime = waitingRuntime(questions: [trimmed])
        guard let decision = runtime.frame.decisions.first else { return nil }
        return measured(QuestionTakeover(decision: decision, runtime: runtime), width: width).height
    }

    /// **The ceiling half.**
    /// **History — found on `SessionInspector`, since retired along with
    /// `.inspector` (`DeckWindow.swift`'s own top doc comment states the
    /// removal in full).** `QuestionTakeover` used to render as a PINNED
    /// `.safeAreaInset` on `SessionInspector`'s own `ScrollView` ("Pinned,
    /// not placed") — a pinned inset is not scrolled and SwiftUI does not
    /// compress it, so before the options grid moved into its own
    /// scrollable, capped band, the takeover simply grew to its full ideal
    /// height and clipped at both ends of whatever window it was given.
    /// A snapshot measurement: the recorded LV37 question —
    /// 3 options, every one carrying a preview — came back 872 pt at 480 pt
    /// wide and 885 pt at 380, against a usable strip viewport
    /// (`QuestionOptionsBand.usableStripHeight`, 402 at the time):
    /// only options 2 and
    /// 3 were tappable, with the header, the question text, option 1, the
    /// "Other…" row and the caption all clipped off above the window's own
    /// top edge — the recorded question was UNANSWERABLE from the
    /// inspector on the product's home display.
    ///
    /// Checked at BOTH widths the retired inspector used to open to
    /// (`narrowPaneWidth`/`mediumPaneWidth` today), since they disagree
    /// (the recorded question's own sentence wraps an extra line at the
    /// narrower width) and the measurements named both.
    ///
    /// **This test's own floor was removed, not fixed here — it was vacuous.** Comparing
    /// "one option with its preview" against "the same option without one"
    /// at the TAKEOVER's exterior passed happily even with the sibling-move
    /// fix reverted, because the options band saturates to the identical
    /// capped height whichever way that cell renders — a marker row alone
    /// cleared the old floor's threshold. `theClippedCellClaimsRealHeight`
    /// below is the replacement: it measures the CELL directly, unwrapped
    /// by any band, which is the one place the regression this whole fix
    /// exists to catch actually shows up. This test keeps only the claim
    /// its own measurement can back — the exterior fits the strip.
    @Test("the recorded LV37 question (3 previewed options, pinned chrome) fits the usable strip at both narrow test widths")
    func theRecordedLV37QuestionFitsTheUsableStrip() {
        for width in [Self.mediumPaneWidth, Self.narrowPaneWidth] {
            guard let withAll3 = lv37Takeover(previews: true, width: width) else {
                Issue.record("the LV37 fixture produced no question call at \(width) pt, so nothing was measured")
                continue
            }
            #expect(withAll3 <= QuestionOptionsBand.usableStripHeight,
                    Comment(rawValue: "the recorded question is \(withAll3) pt at \(width) pt wide — past "
                            + "the strip's own \(QuestionOptionsBand.usableStripHeight) pt usable viewport, "
                            + "which means it clips, not scrolls"))
        }
    }

    /// **The content-level floor, replacing the vacuous
    /// exterior one above.** `QuestionTakeover.optionButton` is `internal`
    /// (not `private`) specifically so this test can measure ONE cell
    /// directly — the real recorded "Focused preview below" option (12
    /// lines, clips against `PreviewOverflow.visibleLines`'s 8) — with its
    /// preview and without it, UNWRAPPED by `previewedOptionsBand`'s own
    /// cap. That is the whole point: the band saturates identically whether
    /// this cell's preview renders correctly or collapses to nothing, so
    /// only a measurement that never passes through the band can tell the
    /// two apart.
    ///
    /// **Verified by mutation, not merely argued.** With `optionButton`
    /// reverted to put the preview back INSIDE `answerButton`'s own label —
    /// the exact original shape — `withPreview` measured within a few
    /// points of `bare` and this test's own floor failed, exactly as
    /// intended; the working tree was restored by a second, targeted edit
    /// afterward, not `git checkout --` (that shortcut can silently revert an unrelated
    /// in-progress edit). MEASURED, both ways: fixed, one cell came back
    /// 208 pt with its preview against 65 pt bare, a 143 pt gap
    /// (`QuestionOptionsBand.previewRowHeight`'s own doc comment cites the
    /// same 208 as its arbiter) — nothing close to what a marker row alone
    /// could clear.
    @Test("a previewed option's own cell claims real, measured height for its clipped preview")
    func theClippedCellClaimsRealHeight() {
        guard let recorded = lv37Question() else {
            Issue.record("the LV37 fixture produced no question, so nothing was measured")
            return
        }
        let focused = recorded.options[0] // "Focused preview below" — 12 recorded lines, clips.
        let withPreview = QuestionOption(label: Redacted(focused.label), detail: Redacted(focused.description),
                                         preview: Redacted(focused.preview))
        let bare = QuestionOption(label: Redacted(focused.label), detail: Redacted(focused.description))
        let question = Question(text: Redacted(recorded.question), header: Redacted(recorded.header),
                                options: [withPreview], multiSelect: false)
        let runtime = waitingRuntime(questions: [question])
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no question call, so nothing below is measured")
            return
        }
        let takeover = QuestionTakeover(decision: decision, runtime: runtime)
        let withHeight = measured(takeover.optionButton(withPreview, index: 0, of: 1),
                                  width: Self.mediumPaneWidth).height
        let bareHeight = measured(takeover.optionButton(bare, index: 0, of: 1),
                                  width: Self.mediumPaneWidth).height
        let delta = withHeight - bareHeight
        // The floor a silently collapsed preview cannot clear: a marker
        // row alone (the vacuous floor) is ~19 pt: this
        // bound sits well above that and well below the ~143 pt this fix
        // actually measures, so it fails on either a collapse OR a
        // regression to the old marker-row-only shape.
        #expect(delta > 60,
                Comment(rawValue: "one previewed cell measured \(withHeight) pt against \(bareHeight) pt "
                        + "bare — only \(delta) pt of difference, which a bare marker row alone could "
                        + "clear and is not what a working clipped preview costs"))
    }

    /// **"Same options, never a subset."** Capping the band UNCONDITIONALLY
    /// meant `TouchTarget.decision` alone (64 pt) already saturates it past
    /// one row, so bare 2/3/4-option takeovers all measured the IDENTICAL
    /// 292 pt at 380 — options past the first simply never drawn, no
    /// affordance saying so. `hasPreviews` (`QuestionTakeover.body`) is the
    /// fix: a question with no preview on any option skips the band
    /// entirely and lays out through `options(for:)`, uncapped, the shape
    /// every question had before any of this existed. That 292/292/292
    /// signature is what this test makes impossible — not just "not this
    /// exact number", every option COUNT must cost real, growing height.
    @Test("bare (preview-less) questions measure different heights by option count — never the same number twice")
    func bareQuestionsGrowWithOptionCount() {
        func bareQuestion(_ n: Int) -> Question {
            Question(text: Redacted("Which layout?"), header: Redacted("Layout"),
                    options: (0..<n).map { QuestionOption(label: Redacted("Option \($0 + 1)"), detail: Redacted("")) },
                    multiSelect: false)
        }
        for width in [Self.mediumPaneWidth, Self.narrowPaneWidth] {
            let heights = [1, 2, 3, 4].map { n -> Double in
                let runtime = waitingRuntime(questions: [bareQuestion(n)])
                guard let decision = runtime.frame.decisions.first else { return -1 }
                return measured(QuestionTakeover(decision: decision, runtime: runtime), width: width).height
            }
            #expect(Set(heights).count == heights.count,
                    Comment(rawValue: "bare 1/2/3/4-option heights at \(width) pt were \(heights) — the "
                            + "292/292/292 saturation signature is exactly a case of "
                            + "two or more of these matching"))
            #expect(zip(heights, heights.dropFirst()).allSatisfy(<),
                    Comment(rawValue: "heights \(heights) at \(width) pt did not grow monotonically with "
                            + "option count"))
        }
    }

    /// The overflow-honesty affordance itself, actually on screen — not
    /// only the pure arithmetic `SubjectTests` already covers. A 2-option
    /// previewed question (`visibleOptionCount` shows the first, hides the
    /// second) measures taller than a 1-option one (nothing hidden, no
    /// marker) by more than the marker row's own height alone could NOT
    /// explain if the marker were missing — i.e. the marker is actually
    /// costing height, not just correctly computed and never drawn.
    @Test("the band's own more-options marker actually renders when options are hidden")
    func moreOptionsMarkerRenders() {
        guard let recorded = lv37Question() else {
            Issue.record("the LV37 fixture produced no question")
            return
        }
        func question(_ optionCount: Int) -> Question {
            let options = (0..<optionCount).map { i -> QuestionOption in
                let o = recorded.options[i % recorded.options.count]
                return QuestionOption(label: Redacted("\(o.label) \(i)"), detail: Redacted(o.description),
                                      preview: Redacted(o.preview))
            }
            return Question(text: Redacted(recorded.question), header: Redacted(recorded.header),
                            options: options, multiSelect: false)
        }
        func heightFor(_ optionCount: Int) -> Double? {
            let runtime = waitingRuntime(questions: [question(optionCount)])
            guard let decision = runtime.frame.decisions.first else { return nil }
            return measured(QuestionTakeover(decision: decision, runtime: runtime),
                            width: Self.mediumPaneWidth).height
        }
        guard let one = heightFor(1), let two = heightFor(2) else {
            Issue.record("the fixture produced no question call, so nothing below is measured")
            return
        }
        #expect(QuestionOptionsBand.visibleOptionCount(hasPreview: [true]) == 1,
                "one previewed option should show fully (nothing more to hide)")
        #expect(QuestionOptionsBand.visibleOptionCount(hasPreview: [true, true]) == 1,
                "the fixture's own premise: a second previewed option should be the one hidden")
        #expect(two > one,
                Comment(rawValue: "a 2-option previewed question (\(two) pt, marker showing) was not "
                        + "taller than the 1-option one with nothing to hide (\(one) pt) — the marker row "
                        + "may not be rendering at all"))
    }

    /// end-to-end worst-case combo — the recorded 3-preview question,
    /// multi-select (so `controls` renders DONE), at both pane widths the
    /// retired inspector used to open to (kept as the historical worst
    /// cases they were measured at). This is what
    /// `QuestionOptionsBand.maxHeight`'s own doc
    /// comment cites as ITS worst-case arbiter: 372 pt at 480, 388 pt at
    /// 380 — 14 pt of margin at the binding width, the same margin
    /// `SubjectOverflow.expandedMaxHeight` holds itself to.
    @Test("the worst-case combo — multi-select, all three recorded previews, controls visible — still fits the usable strip")
    func worstCaseComboFitsTheUsableStrip() {
        guard let recorded = lv37DeckQuestion(previews: true) else {
            Issue.record("the LV37 fixture produced no question")
            return
        }
        let multi = Question(text: recorded.text, header: recorded.header,
                             options: recorded.options, multiSelect: true)
        for width in [Self.mediumPaneWidth, Self.narrowPaneWidth] {
            let runtime = waitingRuntime(questions: [multi])
            guard let decision = runtime.frame.decisions.first else {
                Issue.record("the fixture produced no question call at \(width) pt")
                continue
            }
            let height = measured(QuestionTakeover(decision: decision, runtime: runtime), width: width).height
            #expect(height <= QuestionOptionsBand.usableStripHeight,
                    Comment(rawValue: "the worst-case combo is \(height) pt at \(width) pt wide — past the "
                            + "strip's own \(QuestionOptionsBand.usableStripHeight) pt usable viewport"))
        }
    }

    // ---------------------------------------------------- the full-strip stage

    /// **a previewed question's real home.** Everything above this
    /// section proved the retired INSPECTOR fit a previewed question only
    /// by capping and marking it — `QuestionOptionsBand`'s own doc comment
    /// states the band's arithmetic (`maxHeight`, retuned a live pass to
    /// 78 pt) and why the earlier 80 pt would have shipped past the strip as
    /// it stood then. `QuestionStage` exists because capping was never the
    /// right answer for the recorded call that motivated it — a 19-line
    /// mockup behind a keyhole nowhere near tall enough for it, 61 pt or 78.
    ///
    /// **Budget math, not a bare total.**
    /// A flat "the whole stage fits under N pt" claim is what this test
    /// used to make, and it is exactly the trap the worst-case test below
    /// fell into first: it passed for this single-select shape and FAILED
    /// for the multi-select one the moment real content — three previewed
    /// options, a two-line description, a pinned controls row — actually
    /// saturated a real window's height. `leftColumn` is its own
    /// `ScrollView` deliberately: it is ALLOWED to scroll. What is not
    /// allowed to move is the chrome that never scrolls — the header and
    /// the pinned `QuestionControls` footer, the same pinned-chrome
    /// precedent `bandFitsTheStripWorstCaseDecision` and
    /// `bandBudgetFitsAtEveryGeometryAndBannerState` hold the band's own
    /// chrome to (this file's own retired-tests note, above, carries the
    /// history of the inspector-era test those two succeeded) — so this is
    /// the claim actually held: header + footer + at
    /// least one option row fit the viewport, the same arithmetic that
    /// test already trusts for `StatusLine`/`DecisionBar`/the Quick Actions
    /// column.
    @Test("the stage's pinned chrome leaves room for a scrollable question at native geometry")
    func theQuestionStageLeavesRoomAtNativeGeometry() {
        guard let question = lv37DeckQuestion(previews: true) else {
            Issue.record("the LV37 fixture produced no question")
            return
        }
        let runtime = waitingRuntime(questions: [question])
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no question call, so nothing below is measured")
            return
        }
        let stage = QuestionStage(decision: decision, sessionName: "workspace/openagentdeck",
                                  runtime: runtime, onDismiss: {})

        for (index, option) in question.options.enumerated() {
            let row = measured(stage.optionRow(option, index: index, of: question.options.count),
                               width: QuestionStage.leftColumnWidth)
            // `.decision`, not `.minimum` — cross-phase review's own finding
            // 4: this row's SECOND tap resolves a hold, `optionRow`'s own
            // doc comment on `TouchTarget.decision` states why.
            #expect(row.height >= TouchTarget.decision,
                    Comment(rawValue: "option \(index + 1)'s row is \(row.height) pt — under the "
                            + "\(TouchTarget.decision) pt decision floor"))
        }

        let header = measured(stage.header, width: Self.stripWidth).height
        let progress = decision.progress ?? AnswerProgress()
        let controls = QuestionControls(decision: decision, runtime: runtime, progress: progress,
                                        question: question, otherFieldExpanded: .constant(false))
        // The recorded call is single-select, first step: neither Back nor
        // DONE has anything to do yet — `QuestionControls.isEmpty` is true,
        // `leftColumn` skips its own `.padding` around the footer entirely
        // (no blank gap pinned for nothing), so the footer really is 0 pt
        // here, not merely small. Stated so the worst-case test's own
        // NON-zero, PADDED footer reads as the real thing it claims to be.
        #expect(controls.isEmpty,
                "the fixture stopped being single-select/first-step — nothing below is measuring an empty footer")
        let footer = measured(controls, width: QuestionStage.leftColumnWidth).height
        #expect(footer == 0, "the single-select, first-step footer should be empty — nothing to pin yet")

        let oneRow = measured(stage.optionRow(question.options[0], index: 0, of: question.options.count),
                              width: QuestionStage.leftColumnWidth).height
        let chrome = header + footer + oneRow
        #expect(chrome <= Self.stageViewportHeight,
                Comment(rawValue: "header (\(header)) + pinned footer (\(footer)) + one option row "
                        + "(\(oneRow)) = \(chrome) pt leaves no room at all at the "
                        + "\(Self.stageViewportHeight) pt viewport"))

        // The pane's own width is a LAYOUT fact, not a rendered one — the
        // left column is fixed and the pane takes what is left, the same
        // arithmetic `bandLeavesTheFleetOneCard` already holds itself
        // to for the fleet's own width budget. This is the width the stage
        // ACTUALLY receives. **RETOLD** — this used to depend on a fix
        // proven by a render-level test, `deckWindowClosesInspectorWhileStaged`
        // (retired, this file's own retired-tests note states why): the
        // inspector had to be CLOSED, not merely painted over, while a
        // stage is up, or this arithmetic described a composition the app
        // never produced (a 380–760 pt
        // inspector column left open beside the overlay ate directly into
        // this width). "Commit to band always"
        // (`OverviewLayout.presentation(...)`'s own doc comment states the
        // directive in full) means the inspector never opens at all any
        // more — it is retired outright now, machinery and all
        // (`DeckWindow.swift`'s own top doc comment states the removal in
        // full) — so this arithmetic no longer depends on anything closing
        // it — `deckWindowSuppressesBandWhileStaged` (below) is the live
        // arbiter for the surface that still matters, the band.
        let paneWidth = Self.stripWidth - QuestionStage.leftColumnWidth
        #expect(paneWidth >= 800,
                Comment(rawValue: "the preview pane would only get \(paneWidth) pt at "
                        + "\(Self.stripWidth) pt wide"))
    }

    /// **Held to its own worst case.**
    /// Multi-select (DONE always drawn, whatever the step), all three
    /// recorded previews, the pinned footer at its tallest — measured at
    /// BOTH geometries the approved design names. Not a bare total this
    /// time either, for the reason `theQuestionStageLeavesRoomAtNativeGeometry`
    /// states: the scrollable middle is free to grow past the viewport and
    /// scroll; the header and the PINNED footer are not, and this is the
    /// shape that actually saturates them — a snapshot
    /// measured this exact combination 27 pt past 1920×428 and 61 pt past
    /// 1254×394 when the footer still lived INSIDE the scrollable middle.
    @Test("the worst-case stage (multi-select, controls pinned) still leaves room for a row at both geometries")
    func theWorstCaseStageLeavesRoomAtBothGeometries() {
        guard let recorded = lv37DeckQuestion(previews: true) else {
            Issue.record("the LV37 fixture produced no question")
            return
        }
        let multi = Question(text: recorded.text, header: recorded.header,
                             options: recorded.options, multiSelect: true)
        let runtime = waitingRuntime(questions: [multi])
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no question call")
            return
        }
        let stage = QuestionStage(decision: decision, sessionName: "workspace/openagentdeck",
                                  runtime: runtime, onDismiss: {})
        let progress = decision.progress ?? AnswerProgress()

        let header = measured(stage.header, width: Self.stripWidth).height
        let controls = QuestionControls(decision: decision, runtime: runtime, progress: progress,
                                        question: multi, otherFieldExpanded: .constant(false))
        #expect(!controls.isEmpty,
                "a multi-select question's controls should never read empty — DONE always draws")
        // The EXACT view `leftColumn`'s own `safeAreaInset` pins — its own
        // `.padding(12)`, included here too, not the bare control alone —
        // so this number is the real footprint, not an undercount of it.
        let footer = measured(controls.padding(12), width: QuestionStage.leftColumnWidth).height
        // The pinned footer's own STRUCTURAL proof: DONE is a
        // `TouchTarget.decision`-floor button, drawn unconditionally for a
        // multi-select question regardless of step. If this measured 0,
        // the footer would not actually be present for the budget math
        // below to be testing anything real.
        #expect(footer >= TouchTarget.decision,
                Comment(rawValue: "the pinned footer measured \(footer) pt — DONE (floor "
                        + "\(TouchTarget.decision) pt) does not appear to be in it"))

        let oneRow = measured(stage.optionRow(multi.options[0], index: 0, of: multi.options.count),
                              width: QuestionStage.leftColumnWidth).height
        // `.decision`, not `.minimum` — same reason as the native-geometry
        // test above.
        #expect(oneRow >= TouchTarget.decision)

        for viewport in [Self.stageViewportHeight, 394.0] {
            let chrome = header + footer + oneRow
            #expect(chrome <= viewport,
                    Comment(rawValue: "header (\(header)) + pinned footer (\(footer)) + one option "
                            + "row (\(oneRow)) = \(chrome) pt leaves no room at a \(viewport) pt "
                            + "viewport — DONE would be unreachable regardless of scrolling"))
        }
    }

    /// **The stage's whole reason to exist, proven directly.** "Stacked
    /// inline" — the recorded option `QuestionPreviewFixtureTests
    /// .ingestDecodesAllThreePreviews` pins at 19 lines — is exactly the
    /// mockup this project's own history names: a 19-line preview the
    /// inspector band (`QuestionOptionsBand.maxHeight`, 78 pt as retuned
    /// a live pass — 61 pt when this test was written, and nowhere near
    /// enough either way) could only ever show through a "✂ N lines hidden"
    /// marker. `PreviewOverflow`'s own measured line height (`Subject
    /// .swift`, "1 line measured 15 pt … nothing in between disagreed") is
    /// restated here as `15.0` rather than imported, because it is
    /// `private` to that type on purpose — this test is checking the
    /// PANE's rendered height against an independently-known figure, not
    /// asking the production code to grade its own homework.
    ///
    /// **Verified by mutation, not merely argued.** Capping `previewPane`'s
    /// `ScrollView` at `QuestionOptionsBand.maxHeight` — the exact cap the
    /// band's own re-parented `QuestionTakeover` reads, 78 pt today — made
    /// this assertion fail
    /// with a measured height pinned to that cap against the ~285 pt this
    /// test expects, exactly as intended; the change was reverted
    /// immediately after by restoring the unconstrained `ScrollView`, not
    /// by `git checkout --`.
    @Test("the stage's preview pane shows a 19-line mockup uncapped, all 19 lines")
    func theQuestionStagePreviewPaneIsUncapped() {
        guard let recorded = lv37Question() else {
            Issue.record("the LV37 fixture produced no question")
            return
        }
        let stacked = recorded.options[1] // "Stacked inline" — 19 recorded lines.
        #expect(SubjectOverflow.lineCount(stacked.preview) == 19,
                "the fixture's own line count moved — nothing below is measuring a 19-line preview")
        let option = QuestionOption(label: Redacted(stacked.label), detail: Redacted(stacked.description),
                                    preview: Redacted(stacked.preview))

        guard let question = lv37DeckQuestion(previews: true) else {
            Issue.record("the LV37 fixture produced no question")
            return
        }
        let runtime = waitingRuntime(questions: [question])
        guard runtime.frame.decisions.first != nil else {
            Issue.record("the fixture produced no question call, so nothing below is measured")
            return
        }
        // `previewPane` is `static` — it reads no instance state — so
        // this no longer needs a live `QuestionStage` behind it, only the
        // option being measured. The guard above still proves the fixture
        // actually produces a question call before `option` is trusted.
        let size = measured(QuestionStage.previewPane(for: option), width: 900)

        let measuredLineHeight = 15.0
        let expected = 19 * measuredLineHeight
        #expect(size.height >= expected - 2,
                Comment(rawValue: "the 19-line preview rendered \(size.height) pt — short of the "
                        + "\(expected) pt 19 uncapped lines cost, so something is capping or "
                        + "collapsing it"))
    }

    /// **RETIRED — `inspectorSuppressesTakeoverWhileStageOwnsTheHold` and,
    /// before it, `deckWindowClosesInspectorWhileStaged` both used to live
    /// here.** Both proved a fact about `SessionInspector` — the first at
    /// render level (comparing the inspector's own measured height staged
    /// vs. dismissed), the second at the pure-rule level
    /// (`inspectorShownForTesting.wrappedValue == false`) — and both went
    /// the same way `SessionInspector` itself did: `.inspector` is retired
    /// now, machinery and all (`DeckWindow.swift`'s own top doc comment
    /// states the removal in full), so there is no render-level fact left
    /// about inspector-and-staging worth a dedicated test. The band's own
    /// version of the proof, below, is the live arbiter that still matters
    /// — the band, unlike the retired `.inspector`, still composes, so
    /// whether staging suppresses it is still a real, testable fact.

    /// **The band's own version of the proof above.** `bandShown`'s own doc
    /// comment states why this has to be true BY COMPOSITION and not merely
    /// by the overlay's own opacity: a re-parented `QuestionTakeover`
    /// carries digit shortcuts, and a control merely painted over still sits
    /// in the responder chain underneath the stage.
    @Test("the deck window does not compose its band while a previewed question stages")
    func deckWindowSuppressesBandWhileStaged() {
        guard let question = lv37DeckQuestion(previews: true) else {
            Issue.record("the LV37 fixture produced no question")
            return
        }
        let runtime = waitingRuntime(questions: [question])
        // `fleetSize` explicit and above the band's own height floor — see
        // `theBandTracksTheSelectionInRow` (`ShellTests.swift`) for why a
        // bare `DeckWindow` cannot be trusted to prove suppression is
        // about STAGING: below the floor, `bandShownForTesting` reads
        // `false` regardless, and this test would pass for the wrong
        // reason.
        let window = DeckWindow(runtime: runtime, layout: .row,
                                fleetSize: CGSize(width: 1920, height: OverviewLayout.bandMinimumHeight))
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no question call")
            return
        }
        #expect(decision.showsStage(dismissedStage: nil),
                "the fixture's own premise: a previewed question should raise the stage")
        #expect(window.bandShownForTesting == false,
                Comment(rawValue: "the band should not be composed while the stage owns this "
                        + "previewed decision"))
    }

    /// **RETIRED — `theInspectorRendersNarrow` and `theInspectorRendersEmpty`
    /// used to live here.** Both were pure existence smoke tests for
    /// `SessionInspector` — narrowest column with a decision pinned, and
    /// no selection at all — and both retired along with the component
    /// they measured (`.inspector` is retired now, machinery and all;
    /// `DeckWindow.swift`'s own top doc comment states the removal in
    /// full). `DetailBand` is the one detail surface left, and this file's
    /// many band-render tests (`actZoneFallbackStatesRender` among them)
    /// already hold it to the identical "renders something bounded"
    /// standard these two once held the inspector to.

    // ------------------------------------------------ when the deck lost the call

    /// **The lie, fixed, built the way the two cases actually arise.**
    ///
    /// Never-held: a holdless `Notification` `permission_prompt` raises the
    /// lane straight to needs-you with no hold ever opened — exactly
    /// `DialogAnswerTests.sawAHoldFalseWithoutAHold`'s fixture, replayed
    /// again here so the frame's own `sawAHold` is what drives the copy
    /// this test reads, not a hand-picked `Bool`. Expired-hold: a
    /// `PreToolUse` opens one and `.holdExpired` releases it, leaving
    /// needs-you residue with `sawAHold == true` — the case the ORIGINAL
    /// fixed sentence was written for, and the one case it is still true of.
    @Test("the handed-back notice does not claim a hold that never was")
    func handedBackNoticeCopySplit() {
        let neverHeld = SessionID("never-held")
        let neverHeldState = Reducer.run([.hook(HookEvent(
            id: EventID("notif"), at: at(0), kind: .notification, session: neverHeld,
            cwd: Redacted("/w"), tool: nil, toolUseID: nil, held: .absent,
            notificationType: "permission_prompt"))])
        #expect(neverHeldState.holds.isEmpty, "a Notification opened a hold — this fixture proves nothing")
        let neverHeldLane = Projection.frame(from: neverHeldState, at: at(10))
            .lanes.first { $0.session == neverHeld }
        #expect(neverHeldLane?.sawAHold == false)
        let neverHeldTitle = HandedBackNotice.title(sawAHold: neverHeldLane?.sawAHold ?? true)
        let neverHeldSubtitle = HandedBackNotice.subtitle(sawAHold: neverHeldLane?.sawAHold ?? true)
        #expect(neverHeldTitle == "This session is asking in its own terminal")
        #expect(!neverHeldTitle.contains("went back"),
                "the never-held copy still claims the deck once had this request")
        #expect(neverHeldSubtitle
                == "The deck never held this request — answer it in the session's own window.",
                "the never-held subtitle regressed to repeating the title")
        #expect(neverHeldSubtitle != neverHeldTitle,
                "the title and subtitle say the same thing again — the duplication a review flagged")

        let expired = SessionID("expired-hold")
        var expiredState = DeckState()
        Reducer.reduce(&expiredState, .hook(HookEvent(
            id: EventID("perm"), at: at(0), kind: .permissionRequest, session: expired,
            cwd: Redacted("/w"), tool: "Bash", toolUseID: "u1", held: .absent)))
        Reducer.reduce(&expiredState, .holdExpired(HoldID(session: expired, toolUseID: "u1"), at: at(200_000)))
        let expiredLane = Projection.frame(from: expiredState, at: at(200_010))
            .lanes.first { $0.session == expired }
        #expect(expiredLane?.sawAHold == true)
        let expiredTitle = HandedBackNotice.title(sawAHold: expiredLane?.sawAHold ?? false)
        let expiredSubtitle = HandedBackNotice.subtitle(sawAHold: expiredLane?.sawAHold ?? false)
        #expect(expiredTitle == "This request went back to the terminal")
        #expect(expiredSubtitle.contains("time ran out"), "the held-and-released copy changed")

        // And no two of them say the same thing — the failure this whole
        // split exists to prevent.
        #expect(HandedBackNotice.title(sawAHold: true) != HandedBackNotice.title(sawAHold: false))
        #expect(HandedBackNotice.subtitle(sawAHold: true) != HandedBackNotice.subtitle(sawAHold: false))
    }

    /// **Fix 5's render-sweep half.** Both copy variants, actually
    /// INSTANTIATED — `handedBackNoticeCopySplit` above pins the strings;
    /// this pins that the view built from them still fits the strip, the
    /// same floor/ceiling every other notice in this file is held to.
    @Test("the handed-back notice renders for both copy variants",
          arguments: [true, false])
    func handedBackNoticeRendersBothVariants(_ sawAHold: Bool) {
        let size = measured(HandedBackNotice(sawAHold: sawAHold), width: Self.narrowPaneWidth)
        #expect(size.height > 0,
                Comment(rawValue: "sawAHold: \(sawAHold) renders as nothing"))
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "sawAHold: \(sawAHold) is \(size.height) pt — taller than the strip"))
    }

    /// **Fix 3's third bullet.** The notice-with-`waitingFor` variant —
    /// every value the panel does NOT answer (`DialogAnswerPanel.answers`)
    /// still falls here, and the fleet's one fact ("Waiting on: …") has to
    /// actually render rather than silently grow the view by zero.
    @Test("the handed-back notice renders its waitingFor line")
    func handedBackNoticeRendersWaitingFor() {
        let withoutText = measured(HandedBackNotice(sawAHold: false), width: Self.narrowPaneWidth)
        let withText = measured(HandedBackNotice(sawAHold: false, waitingFor: "sandbox request"),
                                width: Self.narrowPaneWidth)
        #expect(withText.height > 0, "the waitingFor variant renders as nothing")
        #expect(withText.height < Self.stripHeight,
                Comment(rawValue: "the waitingFor variant is \(withText.height) pt on a 480 pt strip"))
        #expect(withText.height > withoutText.height,
                "the waitingFor line added no visible height — it may not be rendering at all")
    }

    // ------------------------------------------------ when the deck can still act

    /// **Fix 3 (MUST): the panel answers only the one evidenced
    /// `waitingFor` value.** LV36's `alpha-b5` is this repo's only
    /// recording of the field, and it reads "permission prompt" — the fixed
    /// three-digit dialog `DialogAnswerPanel` sends raw keys into. A review
    /// found the first cut reachable for ANY non-nil `waitingFor`, which
    /// means sending "1" into whatever "sandbox request" or "input needed"
    /// actually mean on screen — a guess this deck has no recording to
    /// justify. `DetailBand` reads this exact predicate to choose
    /// between this panel and `HandedBackNotice`; testing it directly, once,
    /// is what keeps the two from quietly drifting apart.
    @Test("the dialog panel answers only its one evidenced waitingFor value",
          arguments: ["dialog open", "input needed", "sandbox request", "worker request"])
    func dialogPanelAnswersOnlyPermissionPrompt(_ unevidenced: String) {
        #expect(DialogAnswerPanel.answers("permission prompt"),
                "the one evidenced value stopped being answerable")
        #expect(!DialogAnswerPanel.answers(unevidenced),
                Comment(rawValue: "\"\(unevidenced)\" is answered with no recording that it should be"))
        #expect(!DialogAnswerPanel.answers(nil))
    }

    /// A needs-you lane the fleet corroborates, selected — `waitingFor`
    /// carrying the dialog's own text, exactly `DialogAnswerTests`'
    /// `lv36ProjectsToThePanelInputs` fixture shape but built inline so the
    /// `routable` half can add a `.located` on top of it. `waitingFor`
    /// itself is parameterised so the same helper can build the
    /// panel-answerable lane ("permission prompt") and every lane that now
    /// falls to `HandedBackNotice` instead (fix 3).
    ///
    /// **`quickActions` — additive, `nil` by default: every pre-existing
    /// call site (all three, before this parameter existed) keeps reading
    /// the identical implicit default `Reducer.run(events)` already
    /// produces with no `.prefsChanged` event at all (`DeckPrefs.firstRun
    /// .quickActions`, which — confirmed directly, not assumed — already
    /// IS `QuickAction.shipped`, so a caller passing that value explicitly
    /// composes a byte-identical frame to one that never appends the event
    /// at all).** `theDialogAnswerPanelObeysTheSameHeightBudgetAsItsSibling`
    /// below is the one caller that varies it — it needs BOTH the "no
    /// actions offered" shape (`[]`, where the mandatory column never
    /// exists to fold and the act zone is `.actOnly`'s own full width) and
    /// the ordinary shipped-three shape (the real default a fresh deck
    /// actually offers), at the SAME `waitingFor`, to reproduce both
    /// reachable act widths the panel used to overrun at.
    private func dialogRuntime(routable: Bool, waitingFor: String = "permission prompt",
                               quickActions: [QuickAction]? = nil) -> DeckRuntime {
        let session = SessionID("dialog-lane")
        let row = FleetRow(session: session, name: "s", kind: "interactive",
                           state: .absent, status: .value("waiting"),
                           waitingFor: waitingFor)
        var events: [DeckEvent] = [.fleet([row], at: at(10), id: EventID("f1"))]
        if routable {
            events.append(.located(session, host: HostAddress(workspace: "w", surface: "s")!,
                                   at: at(20), id: EventID("loc1")))
        }
        events.append(.sessionSelected(session, at: at(30)))
        if let quickActions {
            events.append(.prefsChanged(DeckPrefs(quickActions: quickActions), at: at(40)))
        }
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    /// The panel the deck offers when it CAN answer: never instantiated by a
    /// test before this, so a floor regression here would have shipped the
    /// same way `DecisionBar`'s once did.
    @Test("the dialog answer panel renders and fits the strip")
    func theDialogAnswerPanelRenders() {
        let runtime = dialogRuntime(routable: true)
        #expect(runtime.frame.actionBlock == nil,
                Comment(rawValue: "the routable fixture is blocked: "
                        + "\(String(describing: runtime.frame.actionBlock))"))
        let size = measured(DialogAnswerPanel(waitingFor: "permission prompt", runtime: runtime),
                            width: Self.narrowPaneWidth)
        #expect(size.height > TouchTarget.decision,
                "the panel is shorter than the buttons it contains")
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the dialog answer panel is \(size.height) pt on a 480 pt strip"))
    }

    /// And unroutable — the darkened-control rule's own case. The panel
    /// still renders (its buttons darken; `ActionBlockNotice`, driven by the
    /// same `actionBlock`, is what says why on the pane around it), which is
    /// what this render sweep can actually see.
    @Test("the dialog answer panel renders when the lane cannot be routed to")
    func theDialogAnswerPanelRendersUnroutable() {
        let runtime = dialogRuntime(routable: false)
        #expect(runtime.frame.actionBlock == .unroutable,
                Comment(rawValue: "the unroutable fixture reads "
                        + "\(String(describing: runtime.frame.actionBlock))"))
        let size = measured(DialogAnswerPanel(waitingFor: "permission prompt", runtime: runtime),
                            width: Self.narrowPaneWidth)
        #expect(size.height > 0, "an unroutable panel renders as nothing rather than a dark control")
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "the unroutable dialog answer panel is \(size.height) pt on a "
                        + "480 pt strip"))
    }

    /// **The routing itself, end to end — retargeted to the band, `.inspector`'s
    /// own retirement (`DeckWindow.swift`'s own top doc comment states the
    /// removal in full) having retired the surface this test used to
    /// render.** `dialogPanelAnswersOnlyPermissionPrompt` above pins the
    /// predicate `DetailBand.actZoneFallback(for:budget:)` reads; this
    /// builds the whole act zone off each `waitingFor` value the fixture
    /// can carry and confirms it comes back a normal, bounded render
    /// either way — the panel for the one evidenced value, the notice (now
    /// carrying the fleet's own text) for everything else.
    @Test("the band renders the panel for the evidenced value and the notice for every other",
          arguments: ["permission prompt", "dialog open", "input needed",
                      "sandbox request", "worker request"])
    func bandRoutesOnWaitingFor(_ waitingFor: String) {
        let runtime = dialogRuntime(routable: true, waitingFor: waitingFor)
        guard let lane = runtime.frame.lanes.first else {
            Issue.record("the fixture produced no lane")
            return
        }
        let band = DetailBand(runtime: runtime, width: OverviewLayout.bandActMinWidth,
                              usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        let size = measured(band.actZone(for: lane), width: OverviewLayout.bandActMinWidth)
        #expect(size.height > 0,
                Comment(rawValue: "waitingFor \"\(waitingFor)\" renders the act zone as nothing"))
        #expect(size.height < Self.stripHeight * 3,
                Comment(rawValue: "waitingFor \"\(waitingFor)\" is \(size.height) pt — a runaway, not "
                        + "merely tall"))
    }

    /// **The three reachable band widths `theDecisionRowMatrixNeverClipsAndHonoursHonestRoomForTheWell`'s
    /// own `decisionRowGeometries` already names, restated here rather than
    /// shared — that array's own doc comment derives each one from a real
    /// composed geometry (the min window's `.actOnly` band, the
    /// `.withControls` floor, the strip), and this matrix needs the
    /// identical three to prove the fix generalises past the one band width
    /// the bug was first found at.**
    private nonisolated static let dialogPanelBandWidths: [(name: String, bandWidth: Double)] = [
        ("628 (min window, .actOnly)", 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth),
        ("874 (the .withControls floor)", OverviewLayout.bandCompactThreshold),
        ("1588 (the strip)", 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth),
    ]

    /// **The curated cells — every reachable `usableHeight` at the min
    /// window's own band (where the bug was found, at BOTH act widths the
    /// deck actually offers: no actions, and the shipped default), plus one
    /// cell per wider band width at the reachable floor, proving the fix
    /// is not an accident of the narrowest geometry alone.** `nonisolated`,
    /// the same reason `decisionRowGeometries` is.
    private nonisolated static let dialogPanelCases:
        [(geometryName: String, bandWidth: Double, actionCount: Int, usableHeight: Double)] = {
        let g628 = Self.dialogPanelBandWidths[0]
        let g874 = Self.dialogPanelBandWidths[1]
        let g1588 = Self.dialogPanelBandWidths[2]
        var cases: [(geometryName: String, bandWidth: Double, actionCount: Int, usableHeight: Double)] = []
        for usableHeight in [419.0, 359.0, 250.0, 209.0, 189.0, 149.0] {
            // No actions offered — `.actOnly`, act width 604, the shape
            // `DialogAnswerPanel`'s own doc comment measures 161 pt bare at.
            cases.append((g628.name, g628.bandWidth, 0, usableHeight))
            // The shipped default (three actions) — the mandatory column
            // squeezes the SAME band to `bandActFloorWidth` (350), where
            // this panel's fixed row has no choice but to stack.
            cases.append((g628.name, g628.bandWidth, 3, usableHeight))
        }
        cases.append((g874.name, g874.bandWidth, 3, 189.0))
        cases.append((g1588.name, g1588.bandWidth, 3, 189.0))
        return cases
    }()

    /// **Fix (the `DialogAnswerPanel` squeeze): genuine red before, green
    /// after — `DetailBand.decisionMinimumActWidth`'s own doc comment
    /// (`DetailBand.swift`) carries the guard, `DialogAnswerPanel`'s own
    /// (`SessionActions.swift`) carries the four threaded parameters.**
    ///
    /// **`DecisionBar`'s own sibling never received its squeezed recipe —
    /// `outerPadding`/`contentSpacing`/`buttonHeight`/`buttonMinWidth` all
    /// stayed at the full-recipe default (16/8/64/140) at every band
    /// height, and its three FIXED titles ("1. Yes", "2. Yes, and don't ask
    /// again", "3. No") never fold or shrink the way a plan's own well
    /// can.** Measured, BEFORE this fix, at the min window's own band (628,
    /// `g628` above): with no actions offered (act width 604, unstacked)
    /// this panel measured a bare 161 pt, and `actZone(for:)`'s own
    /// composed reading overran its ceiling at usable 209 (167 vs. 161, +6),
    /// 189 (147 vs. 141, +6) and 149 (107 vs. 101, +6) — matching the brief's
    /// own "it overruns from usable 209 downward." With the shipped default
    /// (three actions, act width squeezed to 350, `bandActFloorWidth`) the
    /// row was ALSO always stacking (490 pt needed at the full button floor,
    /// 430 pt squeezed, both past the 318–346 pt of content room 350 pt
    /// ever leaves), so the overrun started EARLIER — usable 250 (205 vs.
    /// 202, +3), 209 (167 vs. 161, +6), 189 (147 vs. 141, +6) and 149 (107
    /// vs. 101, +6).
    ///
    /// **Two judgements this test holds accountable, not merely the
    /// symptom.** (1) `decisionMinimumActWidth` now also asks for room on
    /// this panel's behalf — its three titles are a FIXED, one-time-measurable
    /// quantity (`DecisionRowMeasurer.rowWidth`, the identical cached
    /// measurer `DecisionBar` uses), so the SAME "fold the actions column
    /// only when folding actually avoids a clipped row" guard applies; the
    /// three-action cases above are what that guard is caught folding (act
    /// width jumps from 350 to 604 at usable 250 and below — `theDialogAnswerPanelWidensTheActZoneOnlyWhenFoldingHelps`,
    /// below, holds the fold ITSELF accountable, not merely its effect on
    /// height). (2) once folded, the panel's own squeezed recipe is what
    /// keeps it inside budget even at the reachable floor (189) AND at
    /// usable 149 — a defensive-depth sample below that floor, kept the
    /// same reason every other squeezed-recipe arbiter in this file keeps
    /// one. **No hard floor remains to document** — every cell in this
    /// matrix, including 149, fits after the fix (the tightest, usable
    /// 149 with no actions offered, lands exactly AT its 101 pt ceiling,
    /// not merely under it) — `DialogAnswerPanel` had no elastic content of
    /// its own to shrink (unlike `DecisionBar`'s well), and folding the
    /// actions column turned out to be enough on its own; the brief's own
    /// contingency (documenting an unfittable geometry) is reported here as
    /// checked and not needed, not silently skipped.
    @Test("the dialog answer panel obeys the same height budget as its DecisionBar sibling",
          arguments: Self.dialogPanelCases)
    func theDialogAnswerPanelObeysTheSameHeightBudgetAsItsSibling(
        _ testCase: (geometryName: String, bandWidth: Double, actionCount: Int, usableHeight: Double)
    ) {
        let what = "\(testCase.geometryName), \(testCase.actionCount) actions, "
            + "\(testCase.usableHeight) pt usable"
        let runtime = dialogRuntime(routable: true, quickActions: Self.manyActions(testCase.actionCount))
        guard let lane = runtime.frame.lanes.first else {
            Issue.record("\(what): the fixture produced no lane")
            return
        }
        // The premise: this fixture actually renders `DialogAnswerPanel`,
        // not `HandedBackNotice` — the same predicate `actZoneFallback
        // (for:budget:)` gates on, checked here BEFORE trusting a height
        // reading that would otherwise silently measure the wrong view.
        #expect(DialogAnswerPanel.answers(lane.waitingFor),
                Comment(rawValue: "\(what): the fixture's own premise — waitingFor should answer the panel"))
        #expect(runtime.frame.actions.count == testCase.actionCount,
                Comment(rawValue: "\(what): the fixture's own premise — \(testCase.actionCount) offered actions"))

        let band = DetailBand(runtime: runtime, width: testCase.bandWidth, usableHeight: testCase.usableHeight,
                              dismissedStage: nil)
        let ceiling = testCase.usableHeight - OverviewLayout.bandHeaderHeight
        let zone = measured(band.actZone(for: lane), width: band.actZoneWidth)
        #expect(Double(zone.height) <= ceiling,
                Comment(rawValue: "\(what): act width \(band.actZoneWidth) — the act zone's own composed "
                        + "height for the dialog answer panel is \(zone.height) pt against a \(ceiling) pt "
                        + "ceiling (header \(OverviewLayout.bandHeaderHeight) + columnsHeightBudget "
                        + "\(ceiling)) — it overruns and the act zone silently clips it"))
    }

    /// **Judgement (1)'s own live arbiter — the fold ITSELF, not merely its
    /// downstream effect on height.** `theDialogAnswerPanelObeysTheSameHeightBudgetAsItsSibling`
    /// above proves nothing clips; this proves WHY, and that the guard is
    /// not folding the actions column more than it has to (the requirement: "never for width alone"). At the min window's own band,
    /// three actions offered: usable 419/359 the row stacks but still fits
    /// the generous budget, so the guard must NOT fold (350 stays 350 — a
    /// destroyed actions column here would cost a real column for no
    /// height ever actually saved); usable 250 and below, the stacked row
    /// no longer fits, so the guard MUST fold (350 widens to 604,
    /// `.actOnly`'s own full width, `bandActFloorWidth`-and-back).
    @Test("the dialog answer panel's own width guard folds the actions column only when the stacked row would not fit",
          arguments: [(419.0, false), (359.0, false), (250.0, true), (209.0, true), (189.0, true), (149.0, true)])
    func theDialogAnswerPanelWidensTheActZoneOnlyWhenFoldingHelps(_ sample: (usableHeight: Double, foldsWide: Bool)) {
        let bandWidth = 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let runtime = dialogRuntime(routable: true, quickActions: QuickAction.shipped)
        #expect(runtime.frame.actions.count == QuickAction.shipped.count,
                "the fixture's own premise: the shipped three actions are offered")
        let band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: sample.usableHeight,
                              dismissedStage: nil)
        // `.actOnly`'s own full act width, once Controls and the actions
        // column both fold away entirely — the same subtraction `header`'s
        // own doc comment and `decisionMinimumActWidth`'s state this band
        // reduces to (628 − 2 × `bandColumnsHorizontalPadding` = 604), read
        // here rather than restated as a bare literal.
        let actOnlyWidth = bandWidth - 2 * OverviewLayout.bandColumnsHorizontalPadding
        let expected = sample.foldsWide ? actOnlyWidth : OverviewLayout.bandActFloorWidth
        // Stated as the two concrete, named outcomes rather than a formula
        // on `foldsWide` alone, so a reader sees the actual numbers this
        // band ever produces: 350 (`bandActFloorWidth`, the actions column
        // present) or 604 (`actOnlyWidth`, the column folded away).
        #expect(Double(band.actZoneWidth) == expected,
                Comment(rawValue: "usable \(sample.usableHeight): expected act width \(expected) "
                        + "(fold expected: \(sample.foldsWide)) — got \(band.actZoneWidth)"))
    }

    /// **`DetailBand.dialogAnswerPanelChrome`/`.squeezedDialogAnswerPanelChrome`'s
    /// own live arbiter — the same discipline `bandStateNoticeCompactHeightMatchesItsNamedConstant`/
    /// `controlsZoneFoldedMinimumMatchesItsOwnMeasuredConstant` already hold
    /// their own constants to, and the exact rule this arc's own history
    /// argues for by name: an earlier version shipped a constant no test ever
    /// re-measured, and a later mutation (600 → 560) left the whole suite
    /// green while the product was broken in both directions. A constant
    /// with no arbiter is in that identical position; this closes it.**
    ///
    /// Measures the rowless chrome the SAME way the constant's own doc
    /// comment states it was derived, the wide-and-unstacked half of that
    /// two-sample cross-check: the bare panel's own natural height at a
    /// width generous enough that its row draws as ONE horizontal line,
    /// minus that single row's own known height (`buttonHeight` —
    /// `TouchTarget.decision`/`.minimum`, the identical constant
    /// `DetailBand`'s own call site threads through, not a re-derived
    /// guess). Both recipes, since the constant is a pair.
    ///
    /// **The fixture's own premise, checked FIRST — the reason this test
    /// does not simply trust `wideWidth` to be wide enough.** Subtracting a
    /// single `buttonHeight` only measures the chrome if the row genuinely
    /// drew UNSTACKED at this width; `DecisionRowMeasurer.rowWidth` (the
    /// identical cached measurer `decisionMinimumActWidth` itself calls)
    /// against the content room `wideWidth` actually leaves is the SAME
    /// "does it stack" question production asks, answered the same way — a
    /// recipe change that grew the row (a longer title, a wider button
    /// floor) enough to start stacking here fails THIS assertion loudly,
    /// rather than silently subtracting the wrong number and reporting a
    /// "chrome" that no longer means what its own name claims.
    @Test("the dialog answer panel's own rowless chrome matches DetailBand.dialogAnswerPanelChrome, both recipes")
    func dialogAnswerPanelChromeMatchesItsOwnMeasuredConstant() {
        let runtime = dialogRuntime(routable: true)
        guard let lane = runtime.frame.lanes.first, let waitingFor = lane.waitingFor else {
            Issue.record("the fixture's own premise: a dialog-answerable lane")
            return
        }
        let wideWidth = 900.0
        for squeezed in [false, true] {
            let outerPadding = DetailBand.decisionBarOuterPadding(squeezed: squeezed)
            let contentSpacing = DetailBand.decisionBarContentSpacing(squeezed: squeezed)
            let buttonHeight = squeezed ? TouchTarget.minimum : TouchTarget.decision
            let buttonMinWidth = squeezed ? OverviewLayout.bandSqueezedButtonMinWidth : 140.0
            let rowWidth = DecisionRowMeasurer.rowWidth(titles: QuickAction.dialogAnswers.map(\.displayTitle),
                                                        buttonMinWidth: buttonMinWidth)
            #expect(rowWidth <= wideWidth - 2 * outerPadding,
                    Comment(rawValue: "squeezed \(squeezed): the row (\(rowWidth) pt) does not fit inside "
                            + "\(wideWidth) pt wide (content room \(wideWidth - 2 * outerPadding) pt) — this "
                            + "fixture's own premise that the row draws UNSTACKED here no longer holds, so "
                            + "subtracting one buttonHeight would measure the wrong shape"))

            let panel = DialogAnswerPanel(waitingFor: waitingFor, runtime: runtime,
                                          outerPadding: outerPadding, contentSpacing: contentSpacing,
                                          buttonHeight: buttonHeight, buttonMinWidth: buttonMinWidth)
            let size = measured(panel, width: wideWidth)
            let chrome = Double(size.height) - buttonHeight
            let expected = DetailBand.dialogAnswerPanelChrome(squeezed: squeezed)
            #expect(abs(chrome - expected) < 1,
                    Comment(rawValue: "squeezed \(squeezed): the panel measured \(size.height) pt at "
                            + "\(wideWidth) pt wide; minus its own \(buttonHeight) pt unstacked row leaves "
                            + "\(chrome) pt of chrome, against a declared \(expected) pt — retune the constant "
                            + "to match"))
        }
    }

    // ----------------------------------------------------------- the fleet

    /// The fleet, in every layout, with a session in every state.
    @Test("the fleet renders in every layout", arguments: OverviewLayout.allCases)
    func theFleetRenders(_ layout: OverviewLayout) {
        let runtime = waitingRuntime()
        let width = layout == .column ? 400.0 : Self.stripWidth
        let size = measured(SessionOverview(runtime: runtime, layout: layout), width: width)
        #expect(size.height > 0,
                Comment(rawValue: "the fleet renders as nothing in \(layout.rawValue)"))
    }

    // ------------------------------------------------------- edit mode: render

    /// **The edit-reorder arc's own render-level smoke test.** The wiggle
    /// is render-side and layout-free BY CONSTRUCTION (`IconWiggle`'s own
    /// doc comment, `FleetEditMode.swift` — a `GeometryEffect`'s transform
    /// never feeds back into a layout read taken outside it) — this pins
    /// that claim rather than merely asserting it in a comment: an editing
    /// fleet's own measured height must be IDENTICAL to the same fleet not
    /// editing, at the strip's own width and at the squeezed minimum
    /// (`DeckPrefs.minWindow.width`), with Reduce Motion on and off.
    ///
    /// **What this does NOT test — deliberately.** Live wiggle motion and
    /// a real finger-driven drag are exactly the mechanism the approved
    /// prototype's own probes already covered end to end
    /// (`WigglePrototype.swift`'s `FINDINGS.md`, scratchpad); a headless
    /// render pass cannot judge whether a tilt reads as organic or drive a
    /// real `DragGesture`, and manufacturing synthetic motion evidence for
    /// a question already closed empirically would be exactly the kind of
    /// fake this project's own testing doctrine refuses. Live feel is a
    /// strip judgement, recorded there — `FleetEditModeTests` (this same
    /// target) carries the identical caveat for its own pure/runtime
    /// coverage.
    @Test("an editing fleet renders and holds its non-editing layout height, at the strip width and the squeezed minimum, reduceMotion on and off",
          arguments: [
            // 1920 — `Self.stripWidth`'s own value, restated as a literal:
            // `arguments:` is evaluated outside this `@MainActor` struct's
            // own isolation, so a `Self.`-scoped static (itself
            // `@MainActor` by inference) cannot be read here directly.
            (width: 1920.0, reduceMotion: false),
            (width: 1920.0, reduceMotion: true),
            (width: Double(DeckPrefs.minWindow.width), reduceMotion: false),
            (width: Double(DeckPrefs.minWindow.width), reduceMotion: true),
          ])
    func editingFleetHoldsItsLayoutHeight(_ sample: (width: Double, reduceMotion: Bool)) {
        let runtime = multiLaneRuntime(ids: ["a", "b", "c", "d"], selected: "a")
        runtime.readsReduceMotion = { sample.reduceMotion }
        runtime.refreshAccessibility()
        #expect(runtime.frame.reduceMotion == sample.reduceMotion,
                "the fixture's own premise: reduceMotion reached the frame")

        let notEditing = measured(SessionOverview(runtime: runtime, layout: .row, editing: false),
                                  width: sample.width)
        let editing = measured(SessionOverview(runtime: runtime, layout: .row, editing: true),
                               width: sample.width)

        #expect(editing.height > 0,
                Comment(rawValue: "the editing fleet rendered as nothing at width \(sample.width)"))
        #expect(editing.height == notEditing.height, Comment(rawValue:
                "editing measured \(editing.height) pt tall against \(notEditing.height) pt not " +
                "editing, at width \(sample.width), reduceMotion \(sample.reduceMotion) — the " +
                "wiggle/drag chrome should be layout-free by construction"))
    }

    // ------------------------------------------ the band's own fleet filter

    /// Three sessions, none selected until the caller says so — the fixture
    /// `bandedSessionOverviewFiltersToTheSelectedLane`/
    /// `bandedFleetRendersOnlyTheSelectedCard` below need, and `waitingRuntime()`
    /// does not provide: that fixture is deliberately ONE lane, since every
    /// other render-sweep test only needs a decision to exist, never a fleet
    /// to pick a card out of.
    /// `ids` defaults to the original three-lane set so every pre-existing
    /// call site (`multiLaneRuntime(selected:)`) keeps reading exactly the
    /// fixture it always has — `theTwoRowFleetRenders` below is the only
    /// caller that widens it, to four lanes, enough for a two-row `LazyHGrid`
    /// to actually have a second column to stack.
    private func multiLaneRuntime(ids: [String] = ["a", "b", "c"], selected: String) -> DeckRuntime {
        let t = { (ms: Int64) in Instant(sinceStart: Millis(ms)) }
        var events: [DeckEvent] = ids.enumerated().map { index, id in
            .hook(HookEvent(id: EventID("s-\(id)"), at: t(Int64(index)), kind: .sessionStart,
                            session: SessionID(id), cwd: Redacted("/w/\(id)"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: id)))
        }
        events.append(.sessionSelected(SessionID(selected), at: t(10)))
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    /// **The sliver's replacement, at the pure-function level — live: clicking the 3rd/4th card never scrolled
    /// it into view, because the band covers the strip the instant a
    /// selection lands and the narrowed viewport's own scroll extent could
    /// never reach past what it could already show. Rather than patch the
    /// scroll math to reach a card already covered, `SessionOverview` stops
    /// enumerating every other card while banded — this is that filter,
    /// isolated from rendering the same way `Ticks.offViewportNeedsYou` is.**
    @Test("SessionOverview.lanes filters to the selected lane alone while banded")
    func bandedSessionOverviewFiltersToTheSelectedLane() {
        let a = LaneView(session: SessionID("a"), state: .idle, isExpanded: false,
                         contextPercent: nil, sources: [:])
        let b = LaneView(session: SessionID("b"), state: .idle, isExpanded: false,
                         contextPercent: nil, sources: [:])
        let c = LaneView(session: SessionID("c"), state: .idle, isExpanded: false,
                         contextPercent: nil, sources: [:])
        let base = [a, b, c]

        #expect(SessionOverview.lanes(from: base, banded: false, selection: b.session) == base,
                "unbanded should show every lane regardless of selection")
        #expect(SessionOverview.lanes(from: base, banded: true, selection: b.session) == [b],
                "banded should filter to the selected lane alone, not the whole set")
        #expect(SessionOverview.lanes(from: base, banded: true, selection: nil) == base,
                Comment(rawValue: "banded with nothing selected has nothing to filter TO — .fleetOnly never "
                        + "composes the band in the first place, so this should never actually apply, but the "
                        + "honest answer for 'filter to nothing selected' is the unfiltered set, not an "
                        + "invented empty one"))
        #expect(SessionOverview.lanes(from: base, banded: true, selection: SessionID("nowhere")) == [],
                Comment(rawValue: "a selection absent from the base set (a hidden, unrevealed selection — "
                        + "`lanes`' own caller already narrowed `base` before this runs) should filter to "
                        + "nothing, honestly, rather than silently falling back to the whole fleet"))
    }

    /// **The render-level proof — the pure filter above actually reaches
    /// the glass.** Three real lanes, one selected: banded must measure
    /// narrower than unbanded with the IDENTICAL runtime, and its own
    /// natural width must land on `bandFleetWidth` (one card's worth), not
    /// somewhere between one card and three.
    @Test("the banded fleet renders exactly the selected card, not the whole row")
    func bandedFleetRendersOnlyTheSelectedCard() {
        let runtime = multiLaneRuntime(selected: "b")
        #expect(runtime.frame.lanes.count == 3, "the fixture's own premise: three lanes to filter among")
        #expect(runtime.frame.selection == SessionID("b"), "the fixture's own premise: lane b is selected")

        let unbanded = measuredWidth(SessionOverview(runtime: runtime, layout: .row, banded: false),
                                     height: 300)
        let banded = measuredWidth(SessionOverview(runtime: runtime, layout: .row, banded: true),
                                   height: 300)
        #expect(banded.width < unbanded.width,
                Comment(rawValue: "banded measured \(banded.width) pt wide against \(unbanded.width) pt "
                        + "unbanded, the SAME three lanes either way — banded should be narrower, showing "
                        + "fewer cards, not the same row"))
        #expect(abs(banded.width - OverviewLayout.bandFleetWidth) < 4,
                Comment(rawValue: "the banded fleet's own natural width is \(banded.width) pt, not close to "
                        + "bandFleetWidth (\(OverviewLayout.bandFleetWidth) pt) — more than exactly one card "
                        + "may be rendering"))
    }

    /// **The door with
    /// nowhere to open while banded.** `shelf`'s own doc comment
    /// (`SessionOverview.swift`) states why: `revealingHidden` cannot
    /// widen a single-card banded view, so the shelf's ~150 pt half-card
    /// door used to ride beside the one selected card anyway, pushing the
    /// fleet's own content past `bandFleetWidth` — reopening a smaller
    /// version of the "content wider than its fixed viewport" shape the
    /// sliver's own retirement exists to close. Same width-measurement
    /// technique `bandedFleetRendersOnlyTheSelectedCard` above already
    /// uses, with one lane hidden this time — the shelf's own trigger
    /// condition (`!runtime.frame.hidden.isEmpty`).
    @Test("the hidden-lanes shelf does not compose while banded, even when lanes are actually hidden")
    func theShelfDoesNotComposeWhileBanded() {
        let runtime = multiLaneRuntime(selected: "a")
        runtime.hide(SessionID("c"))
        #expect(!runtime.frame.hidden.isEmpty, "the fixture's own premise: a lane is actually hidden")
        #expect(runtime.frame.selection == SessionID("a"),
                "the fixture's own premise: hiding a different lane should not disturb the selection")

        let banded = measuredWidth(SessionOverview(runtime: runtime, layout: .row, banded: true),
                                   height: 300)
        #expect(abs(banded.width - OverviewLayout.bandFleetWidth) < 4,
                Comment(rawValue: "the banded fleet measured \(banded.width) pt wide with a lane hidden — "
                        + "bandFleetWidth (\(OverviewLayout.bandFleetWidth) pt) — the shelf's own ~150 pt "
                        + "door appears to be riding along beside the one selected card"))

        // The unbanded case is the shelf's own control: it MUST still
        // compose there (a real lane really is hidden, and the fleet is
        // wide enough to scroll into), or this test would pass for the
        // wrong reason — a shelf that never renders at all rather than
        // one correctly gated on `banded`.
        let unbanded = measuredWidth(SessionOverview(runtime: runtime, layout: .row, banded: false),
                                     height: 300)
        #expect(unbanded.width > banded.width + 100,
                Comment(rawValue: "unbanded measured only \(unbanded.width) pt against banded's "
                        + "\(banded.width) pt — the shelf may not be composing even when it should"))
    }

    /// **RETIRED — `theQuickActionBarRenders` and `aDebouncingActionRendersInTheBar`
    /// used to live here.** Both instantiated `QuickActionBar` itself as a
    /// self-rendering, wrapping bar — the shape that retired along with
    /// its last production caller, the inspector's own `.safeAreaInset`
    /// (`QuickActionBar`'s own doc comment, `DecisionBar.swift`, states the
    /// history in full: `.inspector` is retired now, `DeckWindow.swift`'s
    /// own top doc comment states the removal in full). `QuickActionsColumn`
    /// is where a person's own quick actions render now, and this file's
    /// own `aDebouncingActionRendersDimInTheColumn` (below) is that
    /// column's identical debounce-safety proof — coverage moved, not
    /// merely lost.

    /// **The width-invariance the debounce fact's own contract promises —
    /// dark is style, never layout.** `QuickActionBar.body`'s own dimming
    /// (`.opacity`, chained AFTER `control(...)`'s `.frame(width:
    /// measuredWidth,…)`) must never move the pill's own measured width,
    /// the SAME number `ActionPillMeasurer`'s cache and `DetailBand
    /// .actionRows`'s own row-reservation arithmetic both read — a pill
    /// that resized itself while dark would desynchronise the reservation
    /// from the render, the exact class of bug `actionRows`'s own doc
    /// comment already warns "one derivation, two readers" exists to
    /// prevent.
    @Test("a pill's own dimming never changes its measured width")
    func darkPillKeepsItsMeasuredWidth() {
        let title = "Continue"
        let width = ActionPillMeasurer.width(for: title)
        let live = measured(QuickActionBar.control(title, alarming: false, measuredWidth: width) {},
                            width: 400)
        let dark = measured(
            QuickActionBar.control(title, alarming: false, measuredWidth: width) {}
                .opacity(0.5)
                .disabled(true),
            width: 400)
        #expect(Double(live.width) == Double(dark.width),
                Comment(rawValue: "dimming a pill changed its own measured width — \(live.width) live vs "
                        + "\(dark.width) dark"))
    }

    /// **`OverviewLayout.bandStateNoticeHeight`'s own live arbiter.**
    /// `transcriptWellBeneathNotice(for:budget:)` reserves this constant
    /// BEFORE laying out the well beneath an ended/errored notice — if the
    /// constant understates the real render, the well could be granted
    /// more room than truly exists and the OUTER `.frame(maxHeight:)
    /// .clipped()` would clip the notice itself along with it, the exact
    /// silent-clip failure overflow-honesty exists to refuse. Both titled
    /// variants measured (`.ended`/`.errored` use different title/detail
    /// text) — the constant must cover whichever is taller.
    ///
    /// **Measures `DetailBand.endedNotice`/`.erroredNotice` directly, not
    /// hand-re-authored title/detail strings.** This test used to build
    /// its own `BandStateNotice(title: "Session ended", …)` copies —
    /// bytes that could drift from production's own without this arbiter
    /// ever noticing, the lookalike trap `endedNotice`'s own doc comment
    /// now names. Calling the hoisted builders means a change to either
    /// notice's real text is exactly what this test measures, not a
    /// second, independently-typed guess at it.
    @Test("BandStateNotice's own measured height matches OverviewLayout.bandStateNoticeHeight, both variants")
    func bandStateNoticeHeightMatchesItsNamedConstant() {
        let actWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
            - 2 * OverviewLayout.bandColumnsHorizontalPadding - OverviewLayout.bandSideColumnWidth
            - OverviewLayout.bandZoneGutter
        let ended = measured(DetailBand.endedNotice(), width: actWidth)
        let errored = measured(DetailBand.erroredNotice(), width: actWidth)
        let tallest = max(Double(ended.height), Double(errored.height))
        #expect(abs(tallest - OverviewLayout.bandStateNoticeHeight) < 1,
                Comment(rawValue: "the taller notice measured \(tallest) pt against a declared "
                        + "\(OverviewLayout.bandStateNoticeHeight) pt — retune the constant to match"))
    }

    /// The 529 specimen, quoted verbatim — Claude Code's own product copy,
    /// the identical string `TranscriptTailTests`/`ApiErrorTests` pin, not
    /// user content the privacy absolute would forbid a test from
    /// carrying.
    private static let apiErrorSpecimenText =
        "API Error: 529 Overloaded. This is a server-side issue, usually temporary — try again in a moment. "
        + "If it persists, check https://status.claude.com."

    /// **`OverviewLayout.bandApiErrorNoticeHeight`'s own live arbiter — a
    /// CEILING, not an exact match** (`bandApiErrorNoticeHeight`'s own doc
    /// comment states why: this bounds a message Claude Code itself
    /// composes, not a hand-written sentence sized to fit a reservation).
    /// Measures `DetailBand.apiErroredNotice(detail:compact:)` directly
    /// with the EXACT 529 specimen text, at the narrowest reachable act
    /// zone (604 pt) — the width that leaves the LEAST room to wrap, and
    /// so produces the tallest 3-line-capped render this notice can ever
    /// draw.
    @Test("BandStateNotice's own api-error height stays within OverviewLayout.bandApiErrorNoticeHeight")
    func apiErrorNoticeHeightStaysWithinItsNamedConstant() {
        let notice = DetailBand.apiErroredNotice(detail: Self.apiErrorSpecimenText)
        let size = measured(notice, width: 604)
        #expect(Double(size.height) <= OverviewLayout.bandApiErrorNoticeHeight,
                Comment(rawValue: "the api-error notice measured \(size.height) pt against a declared ceiling "
                        + "of \(OverviewLayout.bandApiErrorNoticeHeight) pt — retune the constant to match"))
    }

    /// **Compact tier — title-only, the SAME shared constant the two
    /// hand-written notices already measure to.** Verified directly rather
    /// than assumed: `compact` drops the detail line entirely
    /// (`BandStateNotice`'s own doc comment), so nothing distinguishes the
    /// api-error notice's compact shape from `erroredNotice`'s — this
    /// confirms that rather than taking it on faith.
    @Test("the api-error notice's own compact height matches OverviewLayout.bandStateNoticeCompactHeight")
    func apiErrorNoticeCompactHeightMatchesTheSharedConstant() {
        let notice = DetailBand.apiErroredNotice(detail: Self.apiErrorSpecimenText, compact: true)
        let size = measured(notice, width: 604)
        #expect(abs(Double(size.height) - OverviewLayout.bandStateNoticeCompactHeight) < 1,
                Comment(rawValue: "the compact api-error notice measured \(size.height) pt against a declared "
                        + "\(OverviewLayout.bandStateNoticeCompactHeight) pt"))
    }

    /// **The value-level half of the "verbatim vs generic" claim.**
    /// `apiErroredNotice(detail:)` must carry the text it was HANDED,
    /// byte-for-byte — the dialog-parity rule's own receipt — while the
    /// plain `erroredNotice()` (the fleet-reported producer's own notice,
    /// which never comes with a message) still points at the terminal.
    /// This is checked at the VALUE `BandStateNotice` carries rather than
    /// by inspecting rendered pixels: this suite's own top doc states
    /// headless rendering here checks size and survival, never text
    /// content — `erroredLaneWithApiErrorRendersAndSoDoesOneWithout`
    /// below is what proves the SELECTION between the two actually reaches
    /// the glass.
    @Test("apiErroredNotice carries the verbatim message; the plain erroredNotice stays the generic pointer")
    func apiErroredNoticeCarriesVerbatimTextGenericOtherwise() {
        #expect(DetailBand.apiErroredNotice(detail: Self.apiErrorSpecimenText).detail == Self.apiErrorSpecimenText)
        #expect(DetailBand.erroredNotice().detail.contains("check the session's own terminal"),
                "the generic notice must still point at the terminal when there is no message to relay")
    }

    /// **The composition half — the errored lane WITH a transcript-learned
    /// message renders, and so does one WITHOUT.** Drives `DetailBand
    /// .actZone(for:)`'s own `.errored` branch (`actZoneFallback(for:
    /// budget:)`'s own private twin, reached the same way every other
    /// caller in this suite reaches it — `actZone(for:)` is the one not
    /// marked `private`) through a real, if minimal, `LaneView` with
    /// `apiError` set and unset, so this is the test that would catch the
    /// branch never being wired up at all — a silent crash or an empty
    /// result where a notice belongs.
    @Test("an errored lane WITH apiError renders, and so does one WITHOUT")
    func erroredLaneWithApiErrorRendersAndSoDoesOneWithout() {
        func lane(apiError: Redacted?) -> LaneView {
            LaneView(session: SessionID("s1"), state: .errored, isExpanded: true,
                     contextPercent: nil, sources: [:], apiError: apiError)
        }
        let runtime = DeckRuntime()
        let band = DetailBand(runtime: runtime, width: OverviewLayout.bandActMinWidth,
                              usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)

        let withText = measured(band.actZone(for: lane(apiError: Redacted(Self.apiErrorSpecimenText))),
                                width: OverviewLayout.bandActMinWidth)
        let withoutText = measured(band.actZone(for: lane(apiError: nil)), width: OverviewLayout.bandActMinWidth)
        #expect(withText.height > 0 && withoutText.height > 0,
                "both compositions must render as something — an empty result here would be silent, not a real test")
    }

    /// **`transcriptWellBeneathNotice(for:budget:)`'s own `>=` gate, held
    /// to BOTH edges — the boundary a single "does it show at some budget"
    /// test cannot.** `remaining = budget - bandStateNoticeHeight - 6`;
    /// the well shows at `remaining >= DetailBand.transcriptWellMinimumRoom`
    /// (60) and does not below it. Two `budget` values, chosen so
    /// `remaining` lands EXACTLY on 60 and EXACTLY on 59 — the same
    /// boundary-not-just-interior discipline `OverviewLayoutTests`'s own
    /// `fleetRowsStacksAtTheBoundary`/`actionPillLayoutRowBoundaryIsExact`
    /// already hold every OTHER yield seam in this feature to.
    @Test("transcriptWellBeneathNotice shows the well at remaining 60, not at remaining 59")
    func transcriptWellBeneathNoticeGatesAtItsOwnBoundary() {
        let runtime = Self.liveWellMountedBandShapeRuntime()
        guard let lane = runtime.frame.selection.flatMap({ id in runtime.frame.lanes.first { $0.session == id } })
        else {
            Issue.record("the well-mounted fixture produced no selected lane, so nothing below is measured")
            return
        }
        let band = DetailBand(runtime: runtime, width: 600, usableHeight: 480, dismissedStage: nil)
        let base = OverviewLayout.bandStateNoticeHeight + 6
        let present = measured(band.transcriptWellBeneathNotice(for: lane, budget: base + DetailBand.transcriptWellMinimumRoom),
                               width: 600)
        let absent = measured(band.transcriptWellBeneathNotice(for: lane, budget: base + DetailBand.transcriptWellMinimumRoom - 1),
                              width: 600)
        #expect(present.height > 0,
                Comment(rawValue: "remaining == \(DetailBand.transcriptWellMinimumRoom) (the gate's own floor, "
                        + "inclusive) rendered NOTHING (\(present.height) pt) — the well should show here"))
        #expect(absent.height < 1,
                Comment(rawValue: "remaining == \(DetailBand.transcriptWellMinimumRoom - 1) (one point under the "
                        + "gate's floor) rendered SOMETHING (\(absent.height) pt) — the well should not show here"))
    }

    // ---------------------------------------------------------- TranscriptWell

    /// **The well itself, driven through the real reducer — a confirmed
    /// terminal-origin row, a confirmed deck-sent row, and a still-queued
    /// tail row with its own cancel button, all three shapes at once.**
    /// `LaneView.transcript` merges history oldest-first with the queued
    /// tail in drain order (`Frame.swift`'s own doc comment on the field
    /// is the contract, not this test) — nothing here re-sorts it.
    @Test("TranscriptWell renders a real merged transcript — terminal, sent, and still-queued rows together")
    func transcriptWellRendersARealMergedLedger() {
        var events = Self.events()
        events.append(.hook(HookEvent(id: EventID("p1"), at: Instant(sinceStart: Millis(25)),
                                      kind: .userPromptSubmit, session: SessionID("alpha"),
                                      cwd: Redacted("/w/alpha"), tool: nil, toolUseID: nil, held: .absent,
                                      prompt: Redacted("a real terminal prompt"),
                                      host: HostAddress(workspace: "w", surface: "s"))))
        let continueAction = QuickAction.shipped[0]
        let compactAction = QuickAction.shipped[1]
        events.append(.actionQueued(SessionID("alpha"), continueAction, at: Instant(sinceStart: Millis(30))))
        events.append(.actionSent(SessionID("alpha"), actionID: continueAction.id, at: Instant(sinceStart: Millis(40))))
        events.append(.hook(HookEvent(id: EventID("p2"), at: Instant(sinceStart: Millis(50)),
                                      kind: .userPromptSubmit, session: SessionID("alpha"),
                                      cwd: Redacted("/w/alpha"), tool: nil, toolUseID: nil, held: .absent,
                                      prompt: Redacted("Continue"),
                                      host: HostAddress(workspace: "w", surface: "s"))))
        events.append(.actionQueued(SessionID("alpha"), compactAction, at: Instant(sinceStart: Millis(60))))

        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
            Issue.record("the fixture's own premise: a selected lane to build the well for")
            return
        }
        #expect(lane.transcript.count == 3,
                Comment(rawValue: "the fixture's own premise: a terminal row, a confirmed deck row and a "
                        + "queued deck row — got \(lane.transcript.count)"))
        #expect(lane.transcript.last?.deckStatus == .queued,
                "the still-queued action should sit at the tail, in drain order")

        let size = measured(TranscriptWell(lane: lane, runtime: runtime, maxHeight: 200), width: 380)
        #expect(size.height > 0, "the well renders as nothing for a real, non-empty transcript")
        #expect(size.height <= 200 + 40,
                Comment(rawValue: "the well is \(size.height) pt against a 200 pt ScrollView cap plus a "
                        + "generous allowance for the uncapped stall-sentence line"))
    }

    /// A lane with nothing said and nothing queued falls back to the exact
    /// words the old idle/working placeholder used — `TranscriptWell`'s own
    /// doc comment states why this is a deliberate carry-forward, not an
    /// oversight.
    @Test("TranscriptWell falls back to the old placeholder's own words when the transcript is empty")
    func transcriptWellEmptyStateMatchesTheOldPlaceholder() {
        let runtime = waitingRuntime()
        guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
            Issue.record("the fixture's own premise: a selected lane")
            return
        }
        #expect(lane.transcript.isEmpty, "the fixture's own premise: nothing said, nothing queued")
        let size = measured(TranscriptWell(lane: lane, runtime: runtime, maxHeight: 200), width: 380)
        #expect(size.height > 0, "the empty-state fallback rendered as nothing")
    }

    /// **The inline cancel button on a queued row clears the general touch
    /// floor** — the same class of probe `TouchTargetTests` already holds
    /// every other control on this deck to, applied to the one control
    /// `QueueSection`'s own retirement from the band could have silently
    /// dropped protection from.
    @Test("a queued row's own inline cancel clears the general touch floor")
    func queuedRowCancelClearsTheTouchFloor() {
        var events = Self.events()
        let compactAction = QuickAction.shipped[1]
        events.append(.actionQueued(SessionID("alpha"), compactAction, at: Instant(sinceStart: Millis(30))))
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
            Issue.record("the fixture's own premise: a selected lane")
            return
        }
        #expect(lane.transcript.last?.deckStatus == .queued, "the fixture's own premise: a queued row to cancel")

        // The row itself is `private` to `TranscriptWell.swift` — measured
        // through the well as a whole is the same "unwrapped by the parent's
        // own width-splitting" caveat every other coarse probe in this file
        // already carries; what is checked is that the well's own natural
        // height comfortably clears one `TouchTarget.minimum`-floored row.
        let size = measured(TranscriptWell(lane: lane, runtime: runtime, maxHeight: 200), width: 380)
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "a well with one queued, cancellable row measured \(size.height) pt — "
                        + "under the general touch floor (\(TouchTarget.minimum) pt) its own cancel button "
                        + "must clear"))
    }

    // -------------------------------------------------- what the strip holds

    /// **RETIRED — `theChromeLeavesRoomForContent` used to live here.** The
    /// premise — three things pin themselves to the strip's edges
    /// regardless of content: the status line, a decision bar at the top
    /// of the inspector, and the quick actions bar under it — described an
    /// `.inspector`-shaped strip that no longer exists (`DeckWindow.swift`'s
    /// own top doc comment states the removal in full): today's band pins
    /// no bottom actions bar at all (`QuickActionsColumn` is a side
    /// column, budgeted alongside the act zone rather than stacked under
    /// it), so measuring `DecisionBar` and `QuickActionBar` stacked
    /// vertically no longer describes anything the deck actually
    /// composes. `bandFitsTheStripWorstCaseDecision` and
    /// `bandBudgetFitsAtEveryGeometryAndBannerState` (below) are the
    /// modern equivalent — "does the chrome leave room for a session," measured
    /// against the band's own real composition rather than the retired
    /// inspector's.

    // ------------------------------------------ the inspector's width budget

    /// **RETIRED — `inspectorWidthNoLongerBoundsARowFleet` used to live
    /// here.** It held `OverviewLayout.presentation(for:hasSelection:
    /// usableWidth:usableHeight:) != .inspector` for a selected `.row`
    /// fleet — a comparison that no longer compiles now that `.inspector`
    /// is not a case of `Presentation` at all (`OverviewLayout.swift`'s own
    /// doc comment on the enum states the retelling in full: two cases,
    /// `.band` and `.fleetOnly`, `Equatable` over exactly those two).
    /// `bandLeavesTheFleetOneCard` (below) is the successor this test's own
    /// doc comment already named: the fleet-width trade this test used to
    /// police happens against `OverviewLayout.bandFleetWidth` now, not any
    /// retired range of `.inspector`'s.

    /// **`bandFleetWidth` must fit exactly one card — no wasted room, no
    /// clipped one.** The sliver retired (`bandFleetWidth`'s own doc
    /// comment tells the live-bug story: a scrolling multi-card row behind
    /// the band left the 3rd/4th card structurally unreachable, so
    /// `SessionOverview` now FILTERS to the selected lane alone while
    /// banded — `SessionOverview.lanes(from:banded:selection:)`,
    /// `bandedFleetRendersOnlyTheSelectedCard` below is that filter's own
    /// render-level proof). That filter is what makes "never two cards"
    /// a certainty regardless of width now — even a much wider
    /// `bandFleetWidth` would still show exactly one card. What THIS test
    /// still holds accountable is the WIDTH itself: too narrow and the one
    /// card clips; too wide and the fleet wastes strip real estate the
    /// band could have had instead. `fit == 1` catches both directions at
    /// once — a `bandFleetWidth` that regressed either way would fail it.
    ///
    /// The fleet's own width budget, restated from `SessionOverview.body`:
    /// `GlassEffectContainer`'s `spacing` blends the glass render and adds
    /// no layout gap of its own — the actual gap is the `LazyHStack`'s own
    /// 12 pt `spacing`, and the container sits inside a single
    /// `.padding(12)`. So `n` cards cost 12 (leading padding) + `n` ×
    /// `cardIdealWidth` + (`n` − 1) × 12 — with only one card ever drawn,
    /// `n` never exceeds 1 in practice, but the formula is stated for `n`
    /// generally so this test can prove `bandFleetWidth` could not
    /// honestly claim a second card's room even if the filter above were
    /// ever removed.
    @Test("bandFleetWidth fits exactly one card — no wasted room, no clipped one")
    func bandLeavesTheFleetOneCard() {
        func cardsFitting(fleetWidth: Double) -> Int {
            let leadingPadding = 12.0
            let cardSpacing = 12.0
            var n = 0
            while leadingPadding + Double(n + 1) * OverviewLayout.cardIdealWidth
                    + Double(n) * cardSpacing <= fleetWidth {
                n += 1
            }
            return n
        }
        let fit = cardsFitting(fleetWidth: OverviewLayout.bandFleetWidth)
        #expect(fit == 1,
                Comment(rawValue: "the band's own fleet viewport (\(OverviewLayout.bandFleetWidth) pt) "
                        + "has room for \(fit) full cards, not exactly the one it ever draws"))
    }

    /// **The fleet and the band, side by side, at a `.row` selection's own
    /// widths.** Both halves of a 1920 pt strip once a selection narrows
    /// the fleet: `OverviewLayout.bandFleetWidth` for the fleet, whatever
    /// is left (minus the ticks seam) for the band. Neither may render as
    /// nothing at the width the other's presence leaves it — the same
    /// concern `fleetAndInspectorFitSideBySideAtMinimum` held for
    /// `.inspector` before `.row` stopped sharing a surface with it.
    @Test("the fleet and the band both render at the widths a row selection gives them")
    func fleetAndBandFitSideBySideAtBandWidth() {
        let runtime = waitingRuntime()
        // `banded: true` — production never squeezes the fleet to
        // `bandFleetWidth` without ALSO filtering it (`DeckWindow.body`
        // sets both from the same flag), so measuring one without the
        // other would be a shape production never actually renders.
        let fleet = measured(SessionOverview(runtime: runtime, layout: .row, banded: true),
                             width: OverviewLayout.bandFleetWidth)
        #expect(fleet.height > 0,
                Comment(rawValue: "the fleet renders as nothing at its own band width "
                        + "(\(OverviewLayout.bandFleetWidth) pt)"))
        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let band = measured(DetailBand(runtime: runtime, width: bandWidth,
                                       usableHeight: QuestionOptionsBand.usableStripHeight,
                                       dismissedStage: nil),
                            width: bandWidth)
        #expect(band.height > 0,
                Comment(rawValue: "the band renders as nothing at \(bandWidth) pt — the width a "
                        + "1920 pt strip leaves it once the fleet and the ticks seam take theirs"))
    }

    /// **FINDING A — the fleet slot's own deadlock, reproduced live: banded with the connection banner up, walking
    /// the window down floors at ~302 pt (banner-up usable ≈185) instead
    /// of reaching the root clamp (270).** The banded selected card's own
    /// natural height (one-line-prompt 154, plus 2 × `fleetOuterPadding`
    /// = 178) used to propagate through `SessionOverview`'s horizontal
    /// `ScrollView` as a MINIMUM demand, so `promptLineLimit(usableHeight:
    /// rows:banded:)`'s own 0-tier flex — which WOULD answer 0 (promptless)
    /// at a low enough `usableHeight` — never got the chance: the demand
    /// stopped the window before `usableHeight` ever fell low enough to
    /// ask for it, a one-level-down circularity, the same shape
    /// `detailBandNeverDemandsWidth`/`Height` close one composition over.
    /// `DeckWindow.body`'s own `.frame(minHeight: 0, alignment: .top)` on
    /// the fleet slot is the fix — `bandedFleetSlotBareMinimumIsReducedByTheWrapper`
    /// and `bandedDeckWindowFleetSlotReachesTheRootClampAtTheReachableFloor`
    /// (both below) are that fix's own two arbiters, at two different
    /// altitudes, the same two-altitudes discipline `detailBandNeverDemandsWidth`'s
    /// own doc comment states for the width axis. This test holds the
    /// THIRD, independent property: that the FLEX itself
    /// (`promptLineLimit`'s own pure arithmetic) genuinely responds to a
    /// tight `usableHeight` with the promptless tier, live, through a real
    /// render — not merely provable on paper.
    ///
    /// **RENAMED — `bandedFleetSlotRendersPromptlessAtTheReachableFloor`
    /// 149 pt usable is not the reachable
    /// floor.** The reachable floor is usable 189, banner up
    /// (`DeckPrefs.minWindow` height 270 is a CONTENT height already — no
    /// titlebar to subtract — minus `measuredBannerHeight` (60,
    /// MEASURED — an earlier draft used
    /// an unsourced 68; measured directly at the min window's own 960 pt
    /// content width, `ConnectionBanner` still reads exactly 60, identical
    /// to its own 1920 pt strip reading) and 21
    /// for the status line; `promptLineLimit`'s own doc comment carries
    /// the corrected derivation). 149 sits BELOW that, and at the real
    /// floor the flex answers 1 line, not 0 — the promptless tier this
    /// test exercises is defensive depth below what production actually
    /// reaches, not a state a real window visits; kept, because the pure
    /// function must still answer honestly if it is ever asked, and this
    /// is the render-level proof that it does.
    ///
    /// **The reported NATURAL height at 149 is the promptless card's own
    /// whole, unclipped total — proven by COMPARISON, not by pinning an
    /// exact figure.** 149 shares 149 − 24 = 125 pt — under `oneLine`
    /// (154), the 0-tier. Not pinned to the exact WORST-REALISTIC figure
    /// (`fleetRowMinimumHeight`, 113 — `liveNeedsYouBandShapeRuntime`'s
    /// own lane carries neither a discovered branch nor a permission
    /// mode, so its own tags row measures genuinely shorter than the
    /// worst-realistic card that constant was measured against); instead,
    /// the SAME card is measured a second time at a generous `usableHeight`
    /// (419, where `promptLineLimit`'s own CEILING lifts to the full 8
    /// lines — this fixture's own last prompt is itself one line long, so
    /// the CEILING lifting does not by itself grow the rendered text past
    /// what the FLOOR case already draws; what does move is whether the
    /// prompt block exists AT ALL, the 0-tier's own distinction) and the
    /// tight reading must clear it by at least a whole prompt
    /// block's own cost (`fleetPromptBlockCost`, 41 pt) — proof the tight
    /// reading genuinely dropped the prompt block outright, not merely
    /// that it rendered a short one either way.
    @Test("the banded fleet slot's own flex genuinely engages the promptless tier well below the reachable floor")
    func bandedFleetSlotRendersPromptlessBelowTheReachableFloor() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard runtime.frame.selection != nil else {
            Issue.record("the live-shape fixture selected nothing, so nothing below is measured")
            return
        }

        // 149 pt — BELOW the reachable floor (usable 189, banner up), kept
        // as a defensive-depth sample: the promptless tier, ENGAGED (not
        // merely small). Not pinned to the EXACT
        // worst-realistic figure (`fleetRowMinimumHeight`, 113 — this
        // fixture's own lane carries neither a discovered branch nor a
        // permission mode, so its own tags row is genuinely shorter than
        // the worst-realistic card that constant measures); what this
        // checks instead is the FLEX itself, live: the identical card, at
        // a generous `usableHeight` where `promptLineLimit(usableHeight:
        // rows:banded:)` caps at the full 8 lines, must measure
        // MEANINGFULLY TALLER than it does at 149 pt — proof the 149 pt
        // reading is the genuinely-promptless tier responding to its own
        // tight input, not a coincidentally short card that would have
        // measured the same regardless. And, at 149 specifically: whole,
        // no clip.
        let atTightHeight = SessionOverview(runtime: runtime, layout: .row,
                                            fleetSize: CGSize(width: OverviewLayout.bandFleetWidth, height: 149),
                                            banded: true)
        let naturalHeight = measured(atTightHeight, width: OverviewLayout.bandFleetWidth)
        #expect(Double(naturalHeight.height) <= 149,
                Comment(rawValue: "the banded card at 149 pt usable measured "
                        + "\(naturalHeight.height) pt — it should fit the 149 pt budget whole, with no clip"))

        let atGenerousHeight = SessionOverview(runtime: runtime, layout: .row,
                                               fleetSize: CGSize(width: OverviewLayout.bandFleetWidth,
                                                                 height: QuestionOptionsBand.usableStripHeight),
                                               banded: true)
        let generousHeight = measured(atGenerousHeight, width: OverviewLayout.bandFleetWidth)
        #expect(Double(generousHeight.height) - Double(naturalHeight.height) >= OverviewLayout.fleetPromptBlockCost,
                Comment(rawValue: "the banded card measured \(naturalHeight.height) pt at 149 pt usable "
                        + "and \(generousHeight.height) pt at a generous 419 pt usable — expected the "
                        + "generous reading to clear the tight one by at least a whole prompt block's own cost "
                        + "(\(OverviewLayout.fleetPromptBlockCost) pt), proving the 149 pt reading is genuinely "
                        + "the promptless tier, not merely a short card either way"))
    }

    // ------------------------------------------------------- the detail band

    /// **Band budget-math — `theQuestionStageLeavesRoomAtNativeGeometry`'s
    /// own template, applied to the band.** No `ScrollView` wraps the
    /// band's own layout (`DetailBand`'s file doc: every zone has a
    /// measured budget and declares its own overflow rather than
    /// scrolling), so a zone whose natural content outgrows its budget
    /// does not scroll into view — it clips, silently, which is exactly
    /// the failure this test exists to catch before a person on the strip
    /// does.
    ///
    /// **The worst case is NOT a previewed question.** A first draft of
    /// this test reached for the LV37 previewed fixture, the inspector's
    /// own worst case (`worstCaseComboFitsTheUsableStrip` above) — and
    /// measured a suspiciously small act zone, because `actZone(for:)`'s
    /// own suppression (`decision.showsStage(dismissedStage:)`) is
    /// EXACTLY what makes a previewed question's `QuestionTakeover` never
    /// render there at all: `QuestionStage` owns it. What DOES render
    /// there for an ordinary tool call is `DecisionBar` at its plain
    /// shape — a subject well collapsed to `DetailBand.wellCollapsedLines`
    /// (1 in the band, not the inspector's own 4), no suggestion — which is what this
    /// test holds to the budget.
    ///
    /// **Closed, not tracked — the ordinary-decision half.** A first pass at this test measured the whole band at 367 pt
    /// for the plainest possible decision, missed the strip's own 359 pt
    /// banner-up budget by 8, and missed the narrower desktop window's own
    /// 334 pt by 33 — and, worse, `decisionBarWithSuggestionAndExpandedPlanFitsTheStrip`'s
    /// own canonical shape (a suggestion beside Allow/Deny, on a subject
    /// long enough to need a well) missed by far more once actually
    /// measured (`bandFitsTheStripWorstCaseDecision`, below, is that test).
    /// Both are closed the same way: `DecisionBar`/`SubjectWell` gained
    /// four ADDITIVE, band-only parameters — `wellExpandedMaxHeight`,
    /// `wellCollapsedLines`, `outerPadding`, `contentSpacing` — each
    /// defaulted to the value it always had, so every pre-existing
    /// inspector call site is untouched, and `DetailBand` alone passes the
    /// tighter, MEASURED band values (`DetailBand.wellExpandedMaxHeight`
    /// and its siblings, each constant's own doc comment states its own
    /// derivation). Retuned, this ordinary shape now measures 323 pt —
    /// comfortably inside all four combinations below, not merely the
    /// strip's.
    ///
    /// Four combinations, not one flat total. The strip's own width (1920)
    /// puts the band in `.full` zones and the deck's narrower desktop
    /// window (1254) in `.compact`
    /// (`OverviewLayoutTests.bandZonesDropAtTheThreshold` holds that split
    /// pure); each is checked with and without `ConnectionBanner` sharing
    /// the top safe area — `measuredBannerHeight`'s own doc comment states
    /// why an unbudgeted top inset has to be subtracted rather than
    /// assumed away.
    /// **`columnsHeightBudget` simplified alongside the Quick Actions
    /// column's move — `usable − 48` (`bandHeaderHeight`), no action-row
    /// term to add.** An action-count axis joins the geometry/banner axes
    /// this test already swept, at 0, `bandActionsRowCap` (5, still a
    /// single sub-column) and `QuickAction.maxOffered` (10, the wide
    /// shape) — the actions column's own presence and width are supposed
    /// to cost the band NOTHING it cannot afford, at every count it can
    /// legally hold.
    ///
    /// **`width: 960` (band 628, the min window).** The
    /// narrowest band production ever composes, where the mandatory
    /// column squeezes the act zone to its own derived floor
    /// (`bandActFloorWidth`, 350) whenever `actionCount > 0` — new
    /// territory `bandFleetWidth`/1254's own two geometries never reached
    /// (958/922 both stay well clear of the squeezed step). This holds
    /// PLAIN, ordinary decision content (`Self.events()`'s own bare,
    /// two-button shape — no suggestion) to that new floor;
    /// `bandActFloorWidth`'s own doc comment sanity-checks 350 against
    /// exactly this shape (≈292 pt needed) — this is that sanity check's
    /// own live confirmation, not a repeat of it. The canonical WORST-case
    /// decision (a suggestion, needing a well) is a harder shape this
    /// plain sweep does not cover — `theSqueezedDecisionRowStaysHorizontalAtTheNarrowestActZone`'s
    /// own doc comment names the gap that harder shape found at this same
    /// act width, a real, reported finding, not silently folded in here.
    @Test("the band's header, an ordinary decision's act zone and its columns fit at every geometry, banner state and action count",
          arguments: [
            (width: 1920.0, usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 0),
            (width: 1920.0, usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 5),
            (width: 1920.0, usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 10),
            (width: 1254.0, usableHeight: 394.0, actionCount: 0),
            (width: 1254.0, usableHeight: 394.0, actionCount: 5),
            (width: 1254.0, usableHeight: 394.0, actionCount: 10),
            (width: 960.0, usableHeight: 249.0, actionCount: 0),
            (width: 960.0, usableHeight: 249.0, actionCount: 5),
            (width: 960.0, usableHeight: 249.0, actionCount: 10),
          ])
    func bandBudgetFitsAtEveryGeometryAndBannerState(_ geometry: (width: Double, usableHeight: Double, actionCount: Int)) {
        var events = Self.events()
        events.append(.prefsChanged(DeckPrefs(quickActions: Self.manyActions(geometry.actionCount)),
                                    at: Instant(sinceStart: Millis(100))))
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        #expect(runtime.frame.decisions.first != nil,
                "the fixture produced no decision to measure the act zone against")
        #expect(runtime.frame.actions.count == geometry.actionCount,
                "the fixture's own premise: \(geometry.actionCount) offered actions")

        let bandWidth = geometry.width - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let zones = OverviewLayout.bandZones(for: bandWidth)

        // The WHOLE band, one measurement per banner state — not header,
        // act and the columns summed piecewise. `DetailBand` has no
        // internal `ScrollView` (its whole reason to exist), so its
        // unconstrained natural height IS the real, composed total — the
        // same honest reading `measured(_:width:)` already gives every
        // other non-scrolling view in this file. Measured PER banner
        // state, not once and compared against both budgets — the well
        // now flexes with `usableHeight` (`OverviewLayout
        // .bandWellHeight(usableHeight:)`), so the banner-up and
        // banner-down bands are no longer the same render.
        for bannerShown in [false, true] {
            let budget = geometry.usableHeight - (bannerShown ? Self.measuredBannerHeight : 0)
            let size = measured(DetailBand(runtime: runtime, width: bandWidth, usableHeight: budget,
                                           dismissedStage: nil),
                                width: bandWidth)
            #expect(size.height > 0, "the band renders as nothing for a selected, decided lane")
            #expect(size.height <= budget,
                    Comment(rawValue: "at \(geometry.width) pt wide (\(zones) zones), \(geometry.actionCount) "
                            + "actions, banner \(bannerShown ? "shown" : "hidden"): the whole band (an ordinary "
                            + "decision) is \(size.height) pt against a \(budget) pt budget"))
        }
    }

    /// **The canonical worst-case decision — a suggestion beside Allow/Deny,
    /// on an `ExitPlanMode` plan long enough that the well's own
    /// `ScrollView` is always the binding constraint.** Factored out once
    /// `bandFixedChromeArbiter` and `bandFlexGivesTheWellRoomOnTheStrip`
    /// needed the SAME fixture `bandFitsTheStripWorstCaseDecision` already
    /// built by hand — three tests restating twenty lines of identical
    /// `DeckEvent` construction is exactly the drift risk this file's own
    /// `waitingRuntime()` helper already exists to avoid for the ordinary
    /// case; this is that same move for the worst-case one.
    /// `quickActions` defaults to `QuickAction.shipped` — every pre-existing
    /// caller (the canonical worst-case decision, unmodified) keeps reading
    /// the identical frame it always has, since appending a `.prefsChanged`
    /// carrying the default reproduces exactly what `DeckPrefs.firstRun`
    /// already sets it to. `bandFitsTheStripWorstCaseDecision`'s own
    /// 10-action sample is the one caller that passes something else — the
    /// widest the Quick Actions column ever draws, at the SAME canonical
    /// worst-case decision this fixture already builds, so growing the
    /// action set does not also change what shape the well is fighting.
    static func worstCaseDecisionRuntime(quickActions: [QuickAction] = QuickAction.shipped) -> DeckRuntime {
        let plan = (1...20).map { "Step \($0): do the next thing on the list" }.joined(separator: "\n")
        let suggestionsJSON = JSONValue.parse(
            #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"}]"#)
        var planEvents: [DeckEvent] = [
            .hook(HookEvent(id: EventID("s1"), at: Instant(sinceStart: Millis(0)), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .hook(HookEvent(id: EventID("q1"), at: Instant(sinceStart: Millis(10)), kind: .preToolUse,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: "ExitPlanMode", toolUseID: "t1", held: .value(120_000),
                            subject: Subject(tool: "ExitPlanMode", detail: Redacted(plan), field: "plan"),
                            permissionSuggestions: suggestionsJSON,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .sessionSelected(SessionID("alpha"), at: Instant(sinceStart: Millis(20))),
        ]
        planEvents.append(.prefsChanged(DeckPrefs(quickActions: quickActions), at: Instant(sinceStart: Millis(30))))
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(planEvents))
        return runtime
    }

    /// **`worstCaseDecisionRuntime()`'s own CONTENT-parametrized sibling —
    /// the decision row's own live arbiter (`theDecisionRowMatrixNeverClipsAndHonoursHonestRoomForTheWell`,
    /// below) needs suggestion TEXT to vary, not just be present or
    /// absent, since the whole premise of this rework is that the button
    /// row's own real width — and therefore how much the well/title have
    /// to give ground to protect it — is CONTENT-driven, never a fact
    /// `actWidth` alone could predict.** Same 20-line `ExitPlanMode` plan, same
    /// three-event shape, same `QuickAction.shipped` trailer —
    /// `worstCaseDecisionRuntime()`'s own doc comment states why each of
    /// those is fixed; only the `addRules` rule text(s) actually vary.
    /// `ruleTexts.isEmpty` produces a genuinely two-button decision (no
    /// `permissionSuggestions` at all, matching `waitingRuntime()`'s own
    /// bare shape) rather than an empty-array suggestion list, so "no
    /// suggestion" and "one suggestion" differ by more than array count.
    ///
    /// **`quickActions` — defaulted to the SAME
    /// `QuickAction.shipped` every pre-existing caller already got, so
    /// nothing changes for them.** The mandatory-column redesign means a
    /// non-empty `quickActions` now genuinely competes with the act zone
    /// for width at every `bandWidth`, never dropping for width alone —
    /// exactly the fact `theBoundaryBetweenStackedAndHorizontalMatchesTheRealViewThatFitsFlip`
    /// needs to NOT be true of its own fixture, since that test's whole
    /// point is isolating the act zone's own `ViewThatFits` flip from
    /// every other column. `quickActions: []` is that one caller's own
    /// explicit override; every other caller keeps reading the unchanged
    /// default.
    static func decisionRuntime(ruleTexts: [String], quickActions: [QuickAction] = QuickAction.shipped) -> DeckRuntime {
        let plan = (1...20).map { "Step \($0): do the next thing on the list" }.joined(separator: "\n")
        let suggestionsJSON: JSONValue? = ruleTexts.isEmpty ? nil : JSONValue.parse(
            "[" + ruleTexts.map {
                #"{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"\#($0)"}],"behavior":"allow","destination":"localSettings"}"#
            }.joined(separator: ",") + "]")
        var events: [DeckEvent] = [
            .hook(HookEvent(id: EventID("s1"), at: Instant(sinceStart: Millis(0)), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .hook(HookEvent(id: EventID("q1"), at: Instant(sinceStart: Millis(10)), kind: .preToolUse,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: "ExitPlanMode", toolUseID: "t1", held: .value(120_000),
                            subject: Subject(tool: "ExitPlanMode", detail: Redacted(plan), field: "plan"),
                            permissionSuggestions: suggestionsJSON,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .sessionSelected(SessionID("alpha"), at: Instant(sinceStart: Millis(20))),
        ]
        events.append(.prefsChanged(DeckPrefs(quickActions: quickActions), at: Instant(sinceStart: Millis(30))))
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    /// **The live bug's own shape — the live screenshots, not a
    /// synthesised worst case.** `worstCaseDecisionRuntime()` above is a
    /// SUGGESTION-bearing tool decision, on purpose the canonical hardest
    /// `DecisionBar` shape; this is a DIFFERENT shape entirely — a bare
    /// (no-preview) `AskUserQuestion` on the selected lane, so `actZone(for:)`
    /// builds `QuestionTakeover`, not `DecisionBar`, and NEITHER of that
    /// view's own band-tuned parameters (`wellExpandedMaxHeight` and
    /// siblings — `DetailBand.actZone(for:)`'s own doc comment) apply to it
    /// at all. Built on `Self.events(questions:)` — the SAME sessionStart /
    /// preToolUse / sessionSelected triple `waitingRuntime(questions:)`
    /// already uses for every `QuestionTakeover` render-sweep test above —
    /// plus three real `userPromptSubmit` events spliced in right after
    /// `sessionStart`, since `waitingRuntime()`'s own fixture carries NONE
    /// (`earlierPrompts`'s "▾ N more" affordance, and the queue column's
    /// natural height, both need real rows to draw before they can cost
    /// anything). Three shipped quick actions (`QuickAction.shipped`) and
    /// `autoContinuable` (`Frame.surfaceOf`, keyed on `LaneView.host`) both
    /// ride along for free — every event below already carries the same
    /// `host` `Self.events(questions:)` does. `quickActions` defaults to
    /// `QuickAction.shipped`, and a trailing `.prefsChanged(DeckPrefs
    /// (quickActions:), …)` carries it in regardless — for the default,
    /// that is `DeckPrefs()` in every OTHER field too, which is exactly
    /// what `state.prefs` already starts at (`DeckPrefs.firstRun`, itself
    /// `DeckPrefs()`), so every pre-existing caller reads the identical
    /// frame it always has. `theQuickActionsColumnNeverClipsInTheLiveRecordedShape`
    /// and its neighbours are the callers that pass something longer —
    /// `DeckRuntime`'s own doc on `.prefsChanged` states this is the same
    /// event production emits when Settings saves a new list, so a test
    /// growing the action set this way is exercising the real path, not a
    /// shortcut around it.
    static func liveNeedsYouBandShapeRuntime(
        questionText: String = "Which lane should this land on?",
        quickActions: [QuickAction] = QuickAction.shipped,
        optionCount: Int = 3
    ) -> DeckRuntime {
        let question = Question(text: Redacted(questionText),
                                header: Redacted("Lane"),
                                options: (1...optionCount).map {
                                    QuestionOption(label: Redacted("Option \($0)"), detail: Redacted(""))
                                },
                                multiSelect: false)
        var events = Self.events(questions: [question])
        let t = { (ms: Int64) in Instant(sinceStart: Millis(ms)) }
        let prompts = ["rewrite the layout so the fleet is the primary object",
                       "add the render-sweep test that catches this",
                       "record the live-shape fixture"]
        let promptEvents: [DeckEvent] = prompts.enumerated().map { index, text in
            .hook(HookEvent(id: EventID("p\(index)"), at: t(Int64(1 + index)), kind: .userPromptSubmit,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"), tool: nil, toolUseID: nil,
                            held: .absent, prompt: Redacted(text),
                            host: HostAddress(workspace: "w", surface: "s")))
        }
        // After `sessionStart` (index 0), before the question call — order
        // among themselves is what `rememberPrompt`'s own `decidedAt` sort
        // uses, not array position, but splicing here keeps the whole
        // event list in roughly chronological order for a reader.
        events.insert(contentsOf: promptEvents, at: 1)
        // Trails everything else (t 100, past `.sessionSelected`'s own
        // t 20) — `.prefsChanged` does not interact with lane/hold
        // ordering, so appending rather than splicing keeps this diff
        // from touching the event order every pre-existing reader already
        // depends on.
        events.append(.prefsChanged(DeckPrefs(quickActions: quickActions), at: t(100)))
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    /// **A WELL-MOUNTED composition, not another needs-you one.**
    /// `liveNeedsYouBandShapeRuntime` above puts a live `DecisionBar`/
    /// `QuestionTakeover` in the act zone — neither ever reaches
    /// `TranscriptWell`, the one column with a `ScrollView` in it, the
    /// exact shape the sticky-window fix's own ScrollView-vs-
    /// `measuredMinimum` investigation was about
    /// (`detailBandNeverDemandsHeight`, this section's own live arbiter,
    /// is what samples all three act-zone branches together now — its own
    /// doc comment states why one test needed three different runtimes,
    /// not merely two heights of one). This fixture closes the
    /// `TranscriptWell` gap on its own: real prompt and deck-send history,
    /// but no open hold and no question, so `actZoneFallback(for:budget:)`'s
    /// `.idle, .working` branch renders `TranscriptWell` directly instead
    /// of `DecisionBar`/`QuestionTakeover` masking it.
    ///
    /// `.preToolUse` with `held: .absent` is the load-bearing choice —
    /// `Reducer.transition(on:policy:)` reads a zero/absent `held` as
    /// `.working`, not `.needsYou` (`(h.held.value ?? 0) > 0` is the guard),
    /// and `apply(_:HookEvent)`'s own hold-opening check reads the SAME
    /// field, so this session opens no hold either — `runtime.frame
    /// .decisions` stays empty, the premise every caller of this fixture
    /// should assert before trusting anything measured beneath it (the
    /// mirror image of `liveNeedsYouBandShapeRuntime`'s own callers, who
    /// assert the opposite).
    ///
    /// `promptCount` defaults to 3 (the same "worst-realistic" order of
    /// magnitude `liveNeedsYouBandShapeRuntime`'s own three prompts use);
    /// `detailBandNeverDemandsHeight`'s own well-
    /// mounted sample passes a larger count so the transcript's own natural
    /// height genuinely EXCEEDS both `usableHeight` samples — short enough
    /// content just reports its own natural minimum regardless of the cap
    /// (nothing forces a short column to grow to fill unused room, unlike
    /// `DecisionBar`'s well, which `bandWellHeight`'s own `max()` formula
    /// deliberately exact-fills), so a real test of whether `TranscriptWell`
    /// 's `ScrollView` correctly COMPRESSES under a shrinking ceiling —
    /// rather than getting stuck, the rejected `controlsZone` attempt's own
    /// failure — needs content long enough that the cap is the thing
    /// actually binding.
    static func liveWellMountedBandShapeRuntime(promptCount: Int = 3) -> DeckRuntime {
        let t = { (ms: Int64) in Instant(sinceStart: Millis(ms)) }
        let session = SessionID("alpha")
        let host = HostAddress(workspace: "w", surface: "s")
        var events: [DeckEvent] = [
            .hook(HookEvent(id: EventID("s1"), at: t(0), kind: .sessionStart,
                            session: session, cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent, host: host)),
        ]
        let basePrompts = ["rewrite the layout so the fleet is the primary object",
                           "add the render-sweep test that catches this",
                           "record the well-mounted fixture"]
        for index in 0..<promptCount {
            let text = "\(basePrompts[index % basePrompts.count]) (turn \(index + 1))"
            events.append(.hook(HookEvent(id: EventID("p\(index)"), at: t(Int64(10 + index)),
                                          kind: .userPromptSubmit, session: session,
                                          cwd: Redacted("/w/alpha"), tool: nil, toolUseID: nil,
                                          held: .absent, prompt: Redacted(text), host: host)))
        }
        // `held: .absent` — the `.working`, no-hold branch this fixture is
        // FOR (this doc comment's own opening paragraph states why).
        events.append(.hook(HookEvent(id: EventID("t1"), at: t(50), kind: .preToolUse,
                                      session: session, cwd: Redacted("/w/alpha"),
                                      tool: "Bash", toolUseID: "t1", held: .absent,
                                      subject: Subject(tool: "Bash", detail: Redacted("swift test"), field: nil),
                                      host: host)))
        events.append(.hook(HookEvent(id: EventID("t1done"), at: t(60), kind: .postToolUse,
                                      session: session, cwd: Redacted("/w/alpha"),
                                      tool: "Bash", toolUseID: "t1", held: .absent, host: host)))
        // A queued-then-sent deck action — `TranscriptEntry.origin == .deck`,
        // the transcript's OTHER row kind, beside the three `.terminal` rows
        // the prompts above already give it.
        events.append(.actionQueued(session, QuickAction.shipped[0], at: t(70)))
        events.append(.actionSent(session, actionID: QuickAction.shipped[0].id, at: t(80)))
        events.append(.sessionSelected(session, at: t(90)))
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    /// **The canonical-worst-case half.** The
    /// SAME shape `decisionBarWithSuggestionAndExpandedPlanFitsTheStrip`
    /// holds `DecisionBar` to against the STRIP's fuller 480 pt budget — a
    /// suggestion riding beside Allow/Deny, on an `ExitPlanMode` subject
    /// long enough to need a well — held here to the BAND's own tighter
    /// one instead, both collapsed (the default) and expanded (a real tap
    /// on the well's own overflow chip), at the strip's two budgets: 419
    /// pt (banner down) and 359 pt (banner up, the binding constraint —
    /// the framing, since the strip is this deck's primary
    /// hardware). Measured whole, not piecewise, the same discipline
    /// `bandBudgetFitsAtEveryGeometryAndBannerState` above holds itself to.
    ///
    /// **Not tested against the narrower desktop window's own budget
    /// (394/334) — deliberately, not by omission.** The requirement scopes this shape to "fits 359 (strip + banner — the
    /// binding constraint)"; 334 (desktop + banner, the single tightest
    /// combination this feature has) does not close for this canonical
    /// shape even after every safe, band-local trim available — the
    /// remaining chrome (`DecisionBar`'s own base padding around the
    /// buttons, `AutoContinueToggle`'s touch floor) is shared with the
    /// inspector and extraction-neutrality forbids retuning it further for
    /// the band alone. A suggestion-bearing decision on a subject needing
    /// a well, read on the deck's narrower desktop window with the
    /// connection banner up, may still need more room than a 334 pt band
    /// honestly has — a real, reported limit of this feature, not a
    /// threshold this test bends to hide.
    ///
    /// **The exact-fill claim below holds at every sample because
    /// `bandWellHeight(usableHeight:)` is now a plain function of
    /// `usableHeight` alone — no row count, no width, nothing the actions
    /// column's own presence or size could disturb.** `Double(expanded
    /// .height)`, not a bare `expanded.height == budget` — `CGFloat ==
    /// Double` is a real, if surprising, `#expect` macro trap: the plain
    /// `==` operator returns `true` (confirmed directly, outside the
    /// macro), but swift-testing's own expression-capture for a mixed-type
    /// `==` reports the expectation as FAILED anyway. Converting both
    /// sides to the same concrete type before comparing sidesteps it.
    ///
    /// **The `actionCount: 10` samples — the actions column at its own
    /// WIDEST, act = 818 pt, the narrowest the act zone ever gets on the
    /// strip.** `bandActionsColumn(bandWidth:actionCount:)`'s own doc
    /// comment carries the arithmetic (1588 − 24 − 254 − 492 = 818); 818
    /// still comfortably clears `bandActMinWidth` (620), so the button row
    /// stays on one line and the well's own height claim is unaffected —
    /// this is the render-level proof that a full ten-action column beside
    /// the canonical worst-case decision does not change what fits.
    /// Whether the Allow/Deny row itself ever clips while something else
    /// in the act zone silently absorbs the difference is a DIFFERENT
    /// question — `theAllowDenyRowNeverClipsInTheWorstCaseShape`, directly
    /// below, is the absolute-position probe that answers it.
    @Test("the band fits the canonical worst-case decision (a suggestion, a subject needing a well) at the strip's own budgets",
          arguments: [
            (budget: QuestionOptionsBand.usableStripHeight, actionCount: 3),
            (budget: QuestionOptionsBand.usableStripHeight - 60, actionCount: 3),
            (budget: QuestionOptionsBand.usableStripHeight, actionCount: 10),
            (budget: QuestionOptionsBand.usableStripHeight - 60, actionCount: 10),
          ])
    func bandFitsTheStripWorstCaseDecision(_ sample: (budget: Double, actionCount: Int)) {
        let budget = sample.budget
        let runtime = Self.worstCaseDecisionRuntime(quickActions: Self.manyActions(sample.actionCount))
        #expect(runtime.frame.decisions.first?.suggestionLabels.isEmpty == false,
                "the fixture produced no suggestion — nothing below measures the canonical worst case")
        #expect(runtime.frame.actions.count == sample.actionCount,
                "the fixture's own premise: \(sample.actionCount) offered actions")

        // `.full` zones — the strip's own width always resolves here; the
        // canonical shape's height does not vary by zone mode (the act
        // zone's own width comfortably clears the button-wrap threshold in
        // both `.full` and `.compact`, `bandActMinWidth`'s own doc comment
        // states that measurement), so one width stands for both.
        let bandWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth

        let collapsed = measured(DetailBand(runtime: runtime, width: bandWidth, usableHeight: budget,
                                            dismissedStage: nil),
                                 width: bandWidth)
        #expect(collapsed.height <= budget,
                Comment(rawValue: "the canonical worst-case decision, COLLAPSED, is \(collapsed.height) pt "
                        + "against a \(budget) pt budget"))

        let expanded = measured(DetailBand(runtime: runtime, width: bandWidth, usableHeight: budget,
                                           dismissedStage: nil, wellInitiallyExpanded: true),
                                width: bandWidth)
        #expect(expanded.height <= budget,
                Comment(rawValue: "the canonical worst-case decision, EXPANDED (a real tap on the well's "
                        + "own overflow chip), is \(expanded.height) pt against a \(budget) pt budget"))
        #expect(expanded.height >= collapsed.height,
                "expanding should never show LESS than collapsed did")
        #expect(Double(expanded.height) == budget,
                Comment(rawValue: "the flexed well should exactly fill the \(budget) pt budget, not merely "
                        + "fit under it — measured \(expanded.height) pt"))
    }

    /// **The filed follow-on, closed — `bandFitsTheStripWorstCaseDecision`'s
    /// own exact-fill identity could not rule out an internally-clipped
    /// Allow/Deny row (that test's own doc comment states why: an outer
    /// `.frame(maxHeight:).clipped()` pins the reported TOTAL regardless
    /// of how it is internally spent), so this reads the buttons row's
    /// own REAL, laid-out frame instead — `DecisionBar.onButtonsFrameMeasured`,
    /// threaded through `DetailBand.onDecisionButtonsFrameMeasured`, into
    /// `detailBandRootSpace` — the same coordinate space
    /// `theQuickActionsColumnNeverClipsInTheLiveRecordedShape`/
    /// `theAutoContinueToggleNeverClipsInTheLiveRecordedShape` already
    /// hold their own probes accountable in.**
    ///
    /// **The ceiling asserted against is the act zone's own, not the
    /// band's — the ledger's own tighter number, not the loose one.** The
    /// buttons sit inside `actZone(for:)`'s own `Group`, capped at
    /// `.frame(maxHeight: columnsHeightBudget, alignment: .top).clipped()`
    /// starting right after `header` — so the true ceiling anything in the
    /// act zone must clear is `bandHeaderHeight + columnsHeightBudget`,
    /// recomputed here from the same public `OverviewLayout` arithmetic
    /// production reads (`columnsHeightBudget`'s own doc comment,
    /// `DetailBand.swift` — `usableHeight − bandHeaderHeight`, no row term
    /// any more), not a looser `<= usableHeight` that would pass even if
    /// the buttons bled past the act zone's own share.
    ///
    /// Both the collapsed AND expanded well (a real tap on the overflow
    /// chip) — the SAME two shapes `bandFitsTheStripWorstCaseDecision`
    /// holds its own exact-fill identity to, since either could in
    /// principle push the buttons row differently once something above it
    /// grows.
    /// At BOTH action counts: with the shipped 3
    /// actions the act zone is 1056 pt, but ten actions open the WIDE
    /// Quick Actions column and cut it to 818 (`OverviewLayout
    /// .bandActionsColumn`'s own strip arithmetic), and this absolute-
    /// position probe is the ONE assertion that can see a decision row
    /// wrapping or growing under that narrower share — the exact-fill
    /// identity test's `== budget` stays green regardless, its outer cap
    /// masking any internal clip (that test's own history admits the
    /// masking).
    @Test("the Allow/Deny row's own real, laid-out frame never exceeds the act zone's own ceiling",
          arguments: [QuestionOptionsBand.usableStripHeight, QuestionOptionsBand.usableStripHeight - 60],
          [3, 10])
    func theAllowDenyRowNeverClipsInTheWorstCaseShape(_ usableHeight: Double, _ actionCount: Int) {
        let runtime = Self.worstCaseDecisionRuntime(quickActions: Self.manyActions(actionCount))
        #expect(runtime.frame.decisions.first?.suggestionLabels.isEmpty == false,
                "the fixture produced no suggestion — nothing below measures the canonical worst case")
        let bandWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth

        let columnsHeightBudget = max(0, usableHeight - OverviewLayout.bandHeaderHeight)
        let actZoneCeiling = OverviewLayout.bandHeaderHeight + columnsHeightBudget

        for wellExpanded in [false, true] {
            var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                                  dismissedStage: nil, wellInitiallyExpanded: wellExpanded)
            var buttonsFrame: CGRect?
            band.onDecisionButtonsFrameMeasured = { buttonsFrame = $0 }
            _ = measured(band, width: bandWidth)

            guard let buttonsFrame else {
                Issue.record("at \(usableHeight) pt usable (wellExpanded \(wellExpanded)), the Allow/Deny row's own geometry probe never fired — it may not be rendering at all")
                continue
            }
            #expect(buttonsFrame.height > 0,
                    Comment(rawValue: "at \(usableHeight) pt usable (wellExpanded \(wellExpanded)), the "
                            + "Allow/Deny row measured zero height — that is not \"unclipped\", it is invisible"))
            #expect(buttonsFrame.maxY <= actZoneCeiling,
                    Comment(rawValue: "at \(usableHeight) pt usable (wellExpanded \(wellExpanded)), the "
                            + "Allow/Deny row's own frame reaches \(buttonsFrame.maxY) pt against the act "
                            + "zone's own \(actZoneCeiling) pt ceiling (header "
                            + "\(OverviewLayout.bandHeaderHeight) + columnsHeightBudget "
                            + "\(columnsHeightBudget), origin \(buttonsFrame.origin), height "
                            + "\(buttonsFrame.height)) — it is being pushed past the visible act zone and "
                            + "clipped"))
        }
    }

    /// **`theAllowDenyRowNeverClipsInTheWorstCaseShape`'s own NARROW-ACT-ZONE
    /// sibling — RETARGETED, not merely patched, and RETOLD a second time
    /// since.** The original version of this test sampled act 350/470,
    /// widths that need a 706/826 pt window — under `DeckPrefs.minWindow
    /// .width` (960), so production can never actually offer either.
    /// `OverviewLayoutTests` had the gap; the geometry below
    /// replaces both with widths this deck genuinely reaches
    /// (`decisionRowGeometries`' own doc comment states where each of the
    /// three comes from), and the suggestion axis is CONTENT, not merely
    /// presence/absence.
    ///
    /// **The bug this closes.** `DetailBand.actZone(for:)` used to guess,
    /// from `usableHeight` and `actWidth` alone, whether `DecisionBar`'s
    /// own button row was about to stack, and reserve height for the
    /// guess (`bandDecisionRowStacks(actWidth:buttonCount:usableHeight:)`,
    /// retired — `OverviewLayout.bandWellMinimum`'s own doc comment
    /// carries the full three-shape history: predicted constant → a
    /// `ViewThatFits` ladder that asked instead of guessing, correct but
    /// a real, once-measured layout-cost multiple stated as history now
    /// (that code is gone from the tree), enough MainActor contention to
    /// starve an unrelated timing test → measured and cached, what
    /// ships). The predicted constant was wrong in both directions at
    /// production-reachable content, not merely the calibration label —
    /// measured live, through this exact test's own predecessor, before
    /// any of this: **+14 pt at usable 359 with `git push origin *`
    /// beside Allow/Deny; +20 pt at usable 250 and +81 pt at usable 189
    /// with a long path glob (an earlier draft of this comment
    /// transcribed the second figure as +31 — a slip; +81 is the re-measured number); +26 pt at usable 419 and
    /// +86 pt at usable 359 with an ordinary `git push *` suggestion
    /// ALONGSIDE a second one — two suggestions needs no exotic string at
    /// all, only a fourth button the threshold's own `buttonCount >= 3`
    /// gate never distinguished from three.** This test's job is the SAME
    /// clipping guarantee, proven against the MEASURED replacement
    /// (`DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`,
    /// `DecisionBar.swift`) rather than against the retired prediction's
    /// own arithmetic.
    ///
    /// **The well-presence assertion is new, not a restatement of the
    /// clipping one — the OTHER direction that was wrong.** The retired threshold did not only under-reserve for long
    /// content; at a genuinely-fitting 596–599 pt act width it OVER-
    /// predicted a stack that was not happening, and dropped a subject
    /// well — the plan text a person is being asked to approve — for no
    /// reason. `wellShouldFit(...)` below computes the SAME answer
    /// `DetailBand.actZone(for:)` computes in production — a REAL
    /// measured row width (the SAME `DecisionRowMeasurer` production
    /// calls, not a re-implementation of it) feeding the SAME pure
    /// `OverviewLayout.bandDecisionRowExtraHeight`/`.bandWellFits`
    /// arithmetic production calls — so this is an INTEGRATION check:
    /// it proves the wiring between the measurer, the arithmetic, and
    /// the real render agrees with itself, not merely that either half
    /// is internally consistent alone.
    ///
    /// **28 cells, not the full 75-cell cross product: the full matrix cost +20% of this file's own
    /// suite time in real MainActor work (each cell hosts a full
    /// `DetailBand`, ~12 ms), enough to measurably starve an unrelated
    /// timing-sensitive test under the full parallel suite.** Trimmed to
    /// the cells that carry INFORMATION — every geometry/content/height
    /// combination where `stacks` or `wellFits` actually FLIPS relative
    /// to a neighbour, plus one full "plain" column proving the ordinary
    /// height-fold mechanism end to end — and dropped the redundant
    /// interior, where dozens of cells were re-proving the identical
    /// unstacked, height-fold-only behaviour `decisionRowCases`' own doc
    /// comment states plainly rather than 75 times over. All five known
    /// hard floors stay, now RENDERED rather than skipped
    /// (`knownBareButtonsHardFloors`' own doc comment states why).
    @Test("the decision row never clips the Allow/Deny row, and shows the well whenever the geometry has honest room, across content-driven, production-reachable geometry",
          arguments: Self.decisionRowCases)
    func theDecisionRowMatrixNeverClipsAndHonoursHonestRoomForTheWell(
        _ testCase: (geometryName: String, bandWidth: Double, suggestionName: String, ruleTexts: [String], usableHeight: Double)
    ) {
        let usableHeight = testCase.usableHeight
        let what = "\(testCase.geometryName) × \(testCase.suggestionName), \(usableHeight) pt usable"
        let runtime = Self.decisionRuntime(ruleTexts: testCase.ruleTexts)
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("\(what): the fixture produced no decision — nothing below is measured")
            return
        }
        let bandWidth = testCase.bandWidth
        let columnsHeightBudget = max(0, usableHeight - OverviewLayout.bandHeaderHeight)
        let actZoneCeiling = OverviewLayout.bandHeaderHeight + columnsHeightBudget

        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight, dismissedStage: nil)
        var buttonsFrame: CGRect?
        var wellFrame: CGRect?
        band.onDecisionButtonsFrameMeasured = { buttonsFrame = $0 }
        band.onDecisionWellFrameMeasured = { wellFrame = $0 }
        _ = measured(band, width: bandWidth)

        guard let buttonsFrame else {
            Issue.record("\(what): the Allow/Deny row's own geometry probe never fired — it may not be rendering at all")
            return
        }
        #expect(buttonsFrame.height > 0,
                Comment(rawValue: "\(what): the Allow/Deny row measured zero height — that is not \"unclipped\", it is invisible"))

        // m1: the exclusion used to be a bare
        // `return` before any render — cheap, but silent about WHY, and
        // a future change that closed the gap would leave the entry
        // sitting in `knownBareButtonsHardFloors` unnoticed forever. Now
        // it renders, like every other cell, and asserts the OPPOSITE of
        // the usual claim: this specific cell is EXPECTED to clip, and a
        // cell that stops clipping is exactly as loud a failure as one
        // that starts.
        if Self.knownBareButtonsHardFloors.contains(where: {
            $0.geometryName == testCase.geometryName && $0.suggestionName == testCase.suggestionName
                && $0.usableHeight == usableHeight
        }) {
            #expect(buttonsFrame.maxY > actZoneCeiling,
                    Comment(rawValue: "\(what): this cell is a NAMED hard floor (`knownBareButtonsHardFloors`) — "
                            + "even the fully-folded recipe was measured NOT to fit. It just fit (\(buttonsFrame.maxY) "
                            + "pt against a \(actZoneCeiling) pt ceiling) — remove this entry, it no longer belongs "
                            + "in the exclusion list"))
            return
        }
        #expect(buttonsFrame.maxY <= actZoneCeiling,
                Comment(rawValue: "\(what): the Allow/Deny row's own frame reaches \(buttonsFrame.maxY) pt against "
                        + "the act zone's own \(actZoneCeiling) pt ceiling (header \(OverviewLayout.bandHeaderHeight) "
                        + "+ columnsHeightBudget \(columnsHeightBudget)) — it is being pushed past the visible act "
                        + "zone and clipped"))

        if wellShouldFit(decision: decision, actWidth: band.actZoneWidth, usableHeight: usableHeight) {
            #expect((wellFrame?.height ?? 0) > 0,
                    Comment(rawValue: "\(what): the real, measured row (act width \(band.actZoneWidth)) leaves "
                            + "honest room for the well at its own computed cap, so the well should have shown — "
                            + "it did not, which is the well dropped needlessly"))
        }
    }

    /// **The three band widths this matrix crosses — `nonisolated`, the
    /// same reason `driftProbes` above is: `@Test(arguments:)` evaluates
    /// this before any test body runs, off this `@MainActor` struct's own
    /// actor.** Each geometry is a real `bandWidth` this deck actually
    /// composes, not a synthetic act-only rig:
    ///
    /// - **604** — the minimum window (`DeckPrefs.minWindow.width` 960)
    ///   bands to 628 pt, `.actOnly` (628 < `bandCompactThreshold` 874),
    ///   act width 628 − 2 × `bandColumnsHorizontalPadding` = 604. The
    ///   narrowest act zone production reaches today.
    /// - **596** — `bandCompactThreshold` (874) itself, the exact floor
    ///   `bandZones(for:)` answers `.withControls` at
    ///   (`bandWidth >= bandCompactThreshold`). Act width there, height
    ///   permitting: 874 − 24 − `bandSideColumnWidth` (230) −
    ///   `bandZoneGutter` (24) = 596.
    /// - **1056** — the real strip (1920 pt) minus `bandFleetWidth`/
    ///   `bandSeamWidth`, the SAME 1588 pt band width
    ///   `theAllowDenyRowNeverClipsInTheWorstCaseShape`/
    ///   `bandFitsTheStripWorstCaseDecision` already measure, the control:
    ///   whatever act width the real strip's own Controls-plus-actions
    ///   composition produces (1056 with the shipped 3 actions —
    ///   `bandFitsExactlyAtItsOwnHeightFloor`'s own neighbours record the
    ///   same figure).
    ///
    /// **596 and 1056 do not hold their act width fixed across every
    /// usable height — a fact this matrix leans on, not a leak to paper
    /// over.** `bandControlsShown`/`bandActionsColumn` both also gate on
    /// HEIGHT (`OverviewLayout.bandControlsShown`'s own doc comment), so
    /// Controls and the actions column fold away at the squeezed usable
    /// heights this matrix samples, and the act zone widens to absorb the
    /// room they would have taken — which is exactly why the trimmed set
    /// below keeps several cells at the SAME geometry across DIFFERENT
    /// heights: the act width is not actually constant within a column.
    private nonisolated static let decisionRowGeometries: [(name: String, bandWidth: Double)] = [
        ("604 (min window, .actOnly)", 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth),
        ("596 (the .withControls floor)", OverviewLayout.bandCompactThreshold),
        ("1056 (the strip, control)", 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth),
    ]

    /// **Six suggestion shapes crossed against `decisionRowGeometries`
    /// above — content-driven, the axis the retired threshold never had.**
    /// `ruleTexts.isEmpty` is the genuine two-button decision; the middle
    /// four grow the button row exactly the way a real `addRules`
    /// suggestion can — an ordinary short rule, a longer one, an
    /// arbitrarily long path glob (rule text has no length limit this deck
    /// controls), and two rules riding together (four buttons: Yes, both
    /// suggestions, No — the shape the retired `buttonCount >= 3` guard
    /// never distinguished from three).
    ///
    /// **"three suggestions" (five buttons) — added for
    /// `DetailBand.decisionMinimumActWidth`'s own guard.** `Decision.suggestionLabels` (`Frame.swift`) is UNCAPPED
    /// — "usually zero or one entry," that property's own doc comment
    /// says, never a hard limit — so a real `permission_suggestions`
    /// payload with three rules riding together is legal content this
    /// matrix had never sampled; "two suggestions" was the widest row the
    /// whole file measured before this round. Five buttons is also the
    /// widest content the guard itself ever has to reason about — the
    /// SAME row `theActionsColumnSurvivesAFutileFold`'s own repro uses,
    /// crossed here against the matrix's own three geometries instead of
    /// one.
    private nonisolated static let decisionRowSuggestions: [(name: String, ruleTexts: [String])] = [
        ("no suggestion", []),
        ("git push *", ["git push *"]),
        ("git push origin *", ["git push origin *"]),
        ("a long path glob", ["rm -rf /Users/runner/workspace/openagentdeck/Packages/DeckKit/.build/generated/**"]),
        ("two suggestions", ["git push *", "git commit *"]),
        ("three suggestions", ["git push *", "git commit *", "git push origin *"]),
    ]

    /// **The CURATED 28-cell set — the cost of the full matrix forced it.** Every
    /// cell earns its place; none is here "for coverage" alone:
    ///
    /// - **604 × "git push *", all 5 heights** — the plain baseline
    ///   column: never stacks at this geometry, so this is the ordinary
    ///   height-fold mechanism (`wellFits` flips between usable 209 and
    ///   250) proven end to end, with no stacking to complicate reading
    ///   it. The historically canonical worst-case label, kept as the ONE
    ///   full column so a reader has one complete, simple story before
    ///   the content-driven ones.
    /// - **604 × "git push origin *", all 5 heights** — the SINGLEST most
    ///   informative column in the whole matrix: at the squeezed heights
    ///   (110 pt button floor) this row stays horizontal, but at the two
    ///   full-recipe heights (140 pt floor) the SAME content stacks —
    ///   proof that the squeezed recipe's own narrower button floor can
    ///   flip the stack answer by itself, content held fixed, which no
    ///   single width constant could ever represent.
    /// - **1056 × "no suggestion", usable 209/250** — the well-fits fold
    ///   boundary reproduced at the WIDEST geometry, confirming the fold
    ///   is a height fact, not an artifact of the narrow act zones alone.
    /// - **596/604/1056 × "two suggestions"** — the four-button axis:
    ///   604 stacks at every reachable height (2 non-excluded: 359, 419);
    ///   596 straddles a stack/no-stack boundary between 250 and 359 (the
    ///   act zone widening when Controls folds by height un-stacks it —
    ///   worth seeing directly); 1056 never stacks even at four buttons
    ///   (one sample, 419, suffices to show the control never needs to).
    /// - **596/604 × "a long path glob," usable 359/419** — **this is NOT a stack/no-stack
    ///   boundary pair — measured, the glob stacks at BOTH heights, at
    ///   BOTH geometries (1038 pt of row against 588/580 pt of content
    ///   room either way, not close).** What actually flips between 359
    ///   and 419 is `bandWellFits` — the well-fits fold boundary, reached
    ///   here from the STACKED side rather than the unstacked side
    ///   `1056 × glob` (below) reaches it from. The cells earn their
    ///   place either way (a fold boundary under real stacking pressure
    ///   is exactly the case a synthetic, non-stacking sample could not
    ///   stand in for); the reason stated for keeping them was wrong, not
    ///   the keeping. And **1056 × glob, usable 209/250** — the SAME
    ///   well-fits fold boundary reproduced at the WIDEST geometry,
    ///   reached from the UNSTACKED side (1038 pt of row against 1564/1040
    ///   pt of room — never close to stacking there), the single hardest
    ///   combination for that fold to still land correctly with the
    ///   LONGEST content this matrix samples.
    /// - **The five named hard floors** — always present; `m1`'s own fix
    ///   (`knownBareButtonsHardFloors`, and the test body above) renders
    ///   and asserts them now instead of skipping them free.
    /// - **"three suggestions" (five buttons), six cells added for
    ///   `decisionMinimumActWidth`'s own guard.** 604 × 419: the near-miss
    ///   — a stacked five-button row (252 pt) plus bar chrome (6 pt) fits
    ///   a 371 pt budget with room to spare, but the row's own real
    ///   position (measured `maxY` 412) clears a 419 pt ceiling by only
    ///   7 pt — the guard correctly asks for nothing (folding could not
    ///   reach `needed` at this band's own narrowest fold anyway, per
    ///   `bandZonePlan`'s own corrected contract), and the content
    ///   genuinely, barely fits. 604 × 359: the SAME content, SAME act
    ///   width, a shorter budget — TWO more hard floors, added to
    ///   `knownBareButtonsHardFloors` below alongside 604 × 189 (the
    ///   deepest sample) — five buttons is simply too much content for
    ///   this act width to hold at these budgets, guard or no guard. 596
    ///   × 419: the SAME near-miss story at the other narrow-but-not-
    ///   widest geometry. 1056 × 419: even the STRIP's own full width
    ///   stacks this row (`needed` exceeds 1056 − 2 × outerPadding) but
    ///   clears its own generous budget easily — proof stacking is a
    ///   content fact, not an artifact of the narrow act zones alone,
    ///   the identical point the glob cells make one tier down. 1056 ×
    ///   359: the guard's own clearest SUCCESS in this whole matrix — the
    ///   stacked row does not fit a 311 pt budget, folding actually WIDENS
    ///   the strip's own act zone (1056 → 1310, real headroom at this
    ///   band unlike 604/596's own degenerate one), and the row renders
    ///   horizontal, unclipped.
    private nonisolated static let decisionRowCases:
        [(geometryName: String, bandWidth: Double, suggestionName: String, ruleTexts: [String], usableHeight: Double)] = {
        func geometry(_ name: String) -> (name: String, bandWidth: Double) {
            Self.decisionRowGeometries.first { $0.name == name }!
        }
        func suggestion(_ name: String) -> (name: String, ruleTexts: [String]) {
            Self.decisionRowSuggestions.first { $0.name == name }!
        }
        func cell(_ geometryName: String, _ suggestionName: String, _ usableHeight: Double)
            -> (geometryName: String, bandWidth: Double, suggestionName: String, ruleTexts: [String], usableHeight: Double) {
            let g = geometry(geometryName)
            let s = suggestion(suggestionName)
            return (geometryName: g.name, bandWidth: g.bandWidth, suggestionName: s.name, ruleTexts: s.ruleTexts,
                    usableHeight: usableHeight)
        }
        let g604 = "604 (min window, .actOnly)"
        let g596 = "596 (the .withControls floor)"
        let g1056 = "1056 (the strip, control)"
        return [
            cell(g604, "git push *", 419), cell(g604, "git push *", 359), cell(g604, "git push *", 250),
            cell(g604, "git push *", 209), cell(g604, "git push *", 189),
            cell(g604, "git push origin *", 419), cell(g604, "git push origin *", 359),
            cell(g604, "git push origin *", 250), cell(g604, "git push origin *", 209),
            cell(g604, "git push origin *", 189),
            cell(g1056, "no suggestion", 250), cell(g1056, "no suggestion", 209),
            cell(g596, "two suggestions", 359), cell(g596, "two suggestions", 250),
            cell(g1056, "two suggestions", 419),
            cell(g604, "two suggestions", 359), cell(g604, "two suggestions", 419),
            cell(g596, "a long path glob", 359), cell(g596, "a long path glob", 419),
            cell(g604, "a long path glob", 359), cell(g604, "a long path glob", 419),
            cell(g1056, "a long path glob", 209), cell(g1056, "a long path glob", 250),
            // The five ORIGINAL named hard floors.
            cell(g604, "two suggestions", 250), cell(g604, "two suggestions", 209), cell(g604, "two suggestions", 189),
            cell(g604, "a long path glob", 189), cell(g596, "a long path glob", 189),
            // "three suggestions" (five buttons) — the guard's own content
            // tier, `decisionRowSuggestions`' own doc comment states why.
            cell(g604, "three suggestions", 419), cell(g596, "three suggestions", 419),
            cell(g1056, "three suggestions", 419), cell(g1056, "three suggestions", 359),
            // Two MORE named hard floors, joining the five above.
            cell(g604, "three suggestions", 359), cell(g604, "three suggestions", 189),
        ]
    }()

    /// **The five cells `theDecisionRowMatrixNeverClipsAndHonoursHonestRoomForTheWell`
    /// EXPECTS to clip — that test's own doc comment derives each number.**
    /// A real, measured limit of "the buttons never fold," not a threshold
    /// this suite bends to hide: at these specific (geometry, suggestion,
    /// usable height) combinations, the button row itself — stacked, at
    /// its narrowest squeezed floor, with nothing above it left to shed —
    /// still does not fit the offered budget: a two-suggestion decision's
    /// own four squeezed buttons, stacked, measure 206 pt of content
    /// (`buttonsFrame.maxY` 254, header 48) against a budget that never
    /// reaches it in this matrix (act 604, usable 250/209/189 all ceiling
    /// below 254); a single long-suggestion decision's own three squeezed
    /// buttons, stacked, measure 154 pt (`buttonsFrame.maxY` 202) — 13 pt
    /// PAST the 189 pt ceiling, at both act widths narrow enough to stack
    /// it: 604 (the `.actOnly` geometry, act width constant at every
    /// height) and 850 — **NOT 596.** The
    /// "596" geometry's own NAME is a `bandWidth` identity
    /// (`decisionRowGeometries`' own doc comment states where it comes
    /// from), not a promise its act width stays 596 at every height in
    /// this matrix — at usable 189, `bandControlsShown` already answers
    /// `false` (Controls folds by HEIGHT there, that constant's own doc
    /// comment states the threshold), so the act zone widens to absorb
    /// the room Controls would have taken, to 850. The glob's own 978 pt
    /// squeezed row still stacks a 850 pt act zone (978 > 850 − 4) — the
    /// entry is a real, still-correct clip; only the width cited for it
    /// was wrong. **202, not the 200 the pre-rework doc asserted
    /// from a 5 pt-step sweep that skipped 200–203** — this rework's own
    /// independent measurement lands on the identical corrected number
    /// from a completely different code path, which is corroboration, not
    /// coincidence: 148 pt of stacked-button content (3 × 44 + 2 × 8)
    /// plus 2 × 2 pt of squeezed padding (top and bottom) = 152 pt needs
    /// `usableHeight − bandHeaderHeight >= 152`, i.e. `usableHeight >=
    /// 200` by the bare arithmetic — the render's own real remainder is
    /// what pushes the true boundary to 202, exactly as measured, not
    /// assumed. These five are a real, reported limit of the
    /// buttons-never-fold law, at geometry this deck does reach — not a
    /// threshold this test bends to hide, the identical honesty the
    /// pre-rework suite already held the (unrelated) usable-149 sample
    /// to. `nonisolated`, the same reason `decisionRowGeometries` above
    /// is.
    ///
    /// **RESOLVED — three cells clipped briefly, between the
    /// mandatory-column redesign's own first landing and
    /// `DetailBand.decisionMinimumActWidth`'s own guard, and this list
    /// never grew to name them.** `decisionRuntime(ruleTexts:)` — this
    /// whole matrix's own fixture — carries `QuickAction.shipped` by
    /// default (three real, shipped actions), and once `DetailBand` read
    /// `bandZonePlan` instead of the legacy, controls-gated
    /// `bandActionsColumn`, the mandatory column no longer dropped for
    /// width alone — so at two geometries the act width these cells
    /// render at briefly went narrower than either label's own NAME still
    /// says: 350 (`bandActFloorWidth`) at "604," not 604; 596 at "596,"
    /// not the 850 Controls' own height-fold used to leave the act zone
    /// previously (wasting the freed width entirely, since the
    /// actions column back then could not claim it without Controls also
    /// showing). `("604 (min window, .actOnly)", "git push *", 189.0)`,
    /// `("604 (min window, .actOnly)", "git push origin *", 189.0)`, and
    /// `("596 (the .withControls floor)", "two suggestions", 250.0)`
    /// clipped for exactly as long as it took to land the guard — the SAME
    /// gap `theSqueezedDecisionRowStaysHorizontalAtTheNarrowestActZone`'s
    /// own doc comment names for the canonical worst case, reached here
    /// through the matrix's own, independently-built fixture — reported, not silently absorbed into this
    /// list, so the finding stayed visible until a real decision was
    /// made — held; the decision was the guard itself, and these three
    /// cells now pass without joining the list below, exactly the way
    /// every other content-driven cell in this matrix already does.
    ///
    /// **Two MORE cells join this list here — genuinely, not briefly —
    /// for "three suggestions" (five buttons), the matrix's own new
    /// content tier.** `604 × "three suggestions" × 359` and `604 ×
    /// "three suggestions" × 189`: a stacked five-button row (252 pt
    /// squeezed) plus 6 pt of bar chrome needs 258 pt, against budgets of
    /// 311 and 141 — both short, at an act width `decisionMinimumActWidth`'s
    /// own guard CORRECTLY refuses to widen (folding at band 628 can only
    /// ever reach 604, and a five-button row's own `needed` width is
    /// comfortably past that even at the squeezed floor — the identical
    /// "folding cannot reach `needed`" fact `detailBandNeverDemandsHeight`'s
    /// own two-suggestion sample already holds, one button count over).
    /// This is not a repeat of the guard's own bug — the guard is doing
    /// exactly its job, correctly declining a fold that would not have
    /// helped — it is simply more content than this act width can hold,
    /// the SAME honest "buttons never fold, but content has real limits"
    /// fact the five ORIGINAL entries below already state.
    ///
    /// **MEASURED, not reasoned — the requirement: confirm these
    /// are newly TESTED, not newly BROKEN, before the entries stand.**
    /// `DecisionRowMeasurer.rowWidth` for the three-suggestion titles: 1200
    /// pt at the full 140 pt floor, 1140 pt at the squeezed 110 pt one —
    /// both vastly past the content room EITHER width this matrix crosses
    /// could ever offer (604 − 2 × 8 = 588 full, 604 − 2 × 2 = 600
    /// squeezed; 350's own room is narrower still). A row that does not
    /// fit horizontally at 604 does not fit at 350 either, and — the fact
    /// that actually decides it — a STACKED row's own height never
    /// depended on which of those it got, so the two widths render
    /// IDENTICALLY: usable 359, `buttonsFrame.maxY` 412 pt (stacked, 352
    /// pt tall) against a 359 pt ceiling at BOTH act 604 (forced via a
    /// zero-actions fixture, the SAME technique the three earlier clip
    /// cells were confirmed with) and act 350 (the real, default
    /// shipped-actions fixture this matrix cell actually renders); usable
    /// 189, `maxY` 306 pt (stacked, 252 pt tall) against a 189 pt ceiling,
    /// again identical at both widths. The baseline
    /// drops the actions column entirely at band 628, landing act 604 —
    /// so this content already clipped there, before this phase touched
    /// anything; this phase's own act 350 clips the SAME amount, not
    /// more. Genuine content limits the old matrix never sampled (it
    /// never sampled five-button rows at all), correctly documented here
    /// rather than a regression.
    private nonisolated static let knownBareButtonsHardFloors:
        [(geometryName: String, suggestionName: String, usableHeight: Double)] = [
        ("604 (min window, .actOnly)", "two suggestions", 250.0),
        ("604 (min window, .actOnly)", "two suggestions", 209.0),
        ("604 (min window, .actOnly)", "two suggestions", 189.0),
        ("604 (min window, .actOnly)", "a long path glob", 189.0),
        ("596 (the .withControls floor)", "a long path glob", 189.0),
        ("604 (min window, .actOnly)", "three suggestions", 359.0),
        ("604 (min window, .actOnly)", "three suggestions", 189.0),
    ]

    /// **Whether the well SHOULD fit at this geometry — the SAME question
    /// `DetailBand.actZone(for:)` answers in production, answered here the
    /// SAME way: a REAL measured row width, fed into the SAME pure
    /// arithmetic, calling the SAME production derivations wherever one
    /// exists to call.** Not a lookalike, and not a re-derivation of a
    /// prediction — `DecisionRowMeasurer.rowWidth(titles:buttonMinWidth:)`
    /// is the identical cached measurer production calls;
    /// `OverviewLayout.bandDecisionButtonMinWidth(usableHeight:)` and
    /// `DetailBand.decisionBarOuterPadding(squeezed:)` are the SAME
    /// `squeezed ? … : …` selections production makes, not two
    /// independently-drifting copies of the identical ternary ); and `OverviewLayout.bandDecisionRowExtraHeight`/
    /// `.bandWellFits` are the identical pure functions production calls.
    /// The ONE input this function still has to be handed rather than
    /// deriving itself is `actWidth` — the caller passes `band
    /// .actZoneWidth`, `DetailBand`'s own (no-longer-`private`) property,
    /// for the identical reason. This is the WIRING under test, not a
    /// second opinion competing with production's own answer. (An oracle
    /// that instead measured a bare `DecisionBar`'s own natural height and
    /// compared it to budget — tried first — was WRONG here: `bandWellFits`
    /// has its own independent floor, `bandFixedChrome + bandWellMinimum`
    /// = 248, that a bare recipe's own natural height says nothing about,
    /// and every failure that oracle produced was exactly at usable
    /// heights below that floor, never a real production bug.)
    private func wellShouldFit(decision: Decision, actWidth: Double, usableHeight: Double) -> Bool {
        let squeezed = OverviewLayout.bandSqueezed(usableHeight: usableHeight)
        let titles = DecisionBar.buttonTitles(for: decision)
        let buttonCount = titles.suggestions.count + 2
        let buttonMinWidth = OverviewLayout.bandDecisionButtonMinWidth(usableHeight: usableHeight)
        let outerPadding = DetailBand.decisionBarOuterPadding(squeezed: squeezed)
        let rowWidth = DecisionRowMeasurer.rowWidth(titles: [titles.yes] + titles.suggestions + [titles.no],
                                                    buttonMinWidth: buttonMinWidth)
        let stacks = rowWidth > actWidth - 2 * outerPadding
        let stackedRowExtra = OverviewLayout.bandDecisionRowExtraHeight(stacks: stacks, buttonCount: buttonCount,
                                                                        usableHeight: usableHeight)
        return OverviewLayout.bandWellFits(usableHeight: usableHeight, stackedRowExtra: stackedRowExtra)
    }

    /// **The cache key's own `buttonMinWidth`
    /// component, previously untested — deleting it left all 1126 tests
    /// green, 3 runs.** Measured, the consequence of that gap: `git push
    /// origin *`'s own row measures 614 pt at the full recipe's 140 pt
    /// floor, 554 pt at the squeezed recipe's 110 pt one — a 60 pt gap
    /// whose DIRECTION depends on which recipe's own call happened to
    /// warm the cache first, reproducing either failure depending on order. This is the direct fix: the two floors must
    /// measure DIFFERENT widths for the identical titles, and both must
    /// survive in the cache AT ONCE — re-asking either, after the other
    /// has already been cached, must return that recipe's OWN answer, not
    /// whichever recipe warmed the cache first.
    @Test("DecisionRowMeasurer keys on buttonMinWidth — the full and squeezed recipes never collide")
    func decisionRowMeasurerKeysOnButtonMinWidth() {
        let titles = ["1. Yes", "2. Yes, and don't ask again for: git push origin *", "3. No"]
        let full = DecisionRowMeasurer.rowWidth(titles: titles, buttonMinWidth: 140)
        let squeezed = DecisionRowMeasurer.rowWidth(titles: titles, buttonMinWidth: 110)
        #expect(full != squeezed,
                Comment(rawValue: "the full recipe (\(full) pt) and the squeezed one (\(squeezed) pt) measured "
                        + "the SAME width for the identical titles — the cache key is not distinguishing the "
                        + "button floor"))
        #expect(full == 614, Comment(rawValue: "the full recipe's own measured width drifted — got \(full), expected 614"))
        #expect(squeezed == 554, Comment(rawValue: "the squeezed recipe's own measured width drifted — got \(squeezed), expected 554"))

        // Both must survive in the cache SIMULTANEOUSLY — re-asking
        // either, now that BOTH have been cached, must still return that
        // recipe's own answer, not silently return whichever the cache
        // happened to warm with last.
        #expect(DecisionRowMeasurer.rowWidth(titles: titles, buttonMinWidth: 140) == full,
                "re-asking the full recipe after the squeezed one was cached should still answer 614")
        #expect(DecisionRowMeasurer.rowWidth(titles: titles, buttonMinWidth: 110) == squeezed,
                "re-asking the squeezed recipe after the full one was re-cached should still answer 554")
    }

    /// **"Any number load-bearing enough to
    /// appear in an architectural doc deserves a test that fails when it
    /// rots."** `DecisionBar.swift`'s top doc comment, `DecisionRowMeasurer`'s
    /// own doc comment, and `OverviewLayout.bandWellMinimum`'s own doc
    /// comment all cite these four numbers as the concrete evidence for
    /// why a width constant could never represent this deck's own
    /// content — an EARLIER draft of that exhibit cited a wrong number in
    /// one place (882 for `git push origin *`, actually the two-suggestion
    /// row's own figure) that stood, uncaught, until a live check re-measured it by hand. This test is what that re-measurement
    /// should have been from the start: a "stacks up to act width N"
    /// claim is `DecisionRowMeasurer.rowWidth(...)` (the full recipe's own
    /// 140 pt floor, `DetailBand.decisionBarOuterPadding(squeezed: false)`
    /// on both sides) plus one point under the flip.
    @Test("the architectural exhibit's own figures hold the measured values three doc comments cite")
    func theArchitecturalExhibitFiguresHoldTheirMeasuredValues() {
        func lastStackedActWidth(_ titles: [String]) -> Double {
            DecisionRowMeasurer.rowWidth(titles: titles, buttonMinWidth: 140)
                + 2 * DetailBand.decisionBarOuterPadding(squeezed: false) - 1
        }
        let gitPush = ["1. Yes", "2. Yes, and don't ask again for: git push *", "3. No"]
        let gitPushOrigin = ["1. Yes", "2. Yes, and don't ask again for: git push origin *", "3. No"]
        let glob = ["1. Yes",
                    "2. Yes, and don't ask again for: rm -rf /Users/runner/workspace/openagentdeck/Packages/DeckKit/.build/generated/**",
                    "3. No"]
        let twoSuggestions = ["1. Yes", "2. Yes, and don't ask again for: git push *",
                              "3. Yes, and don't ask again for: git commit *", "4. No"]

        #expect(lastStackedActWidth(gitPush) == 592,
                Comment(rawValue: "\"git push *\" — got \(lastStackedActWidth(gitPush)), the doc exhibit says 592"))
        #expect(lastStackedActWidth(gitPushOrigin) == 629,
                Comment(rawValue: "\"git push origin *\" — got \(lastStackedActWidth(gitPushOrigin)), the doc "
                        + "exhibit says 629 (NOT 882 — that number was a two-suggestion figure misattributed "
                        + "to this axis, corrected since)"))
        #expect(lastStackedActWidth(glob) == 1053,
                Comment(rawValue: "the long path glob — got \(lastStackedActWidth(glob)), the doc exhibit says "
                        + "1053"))
        #expect(lastStackedActWidth(twoSuggestions) == 892,
                Comment(rawValue: "two suggestions — got \(lastStackedActWidth(twoSuggestions)), the doc exhibit "
                        + "says 892"))
    }

    /// **Pin measurer-to-render
    /// equivalence DIRECTLY, not by inference.** Every other test in this
    /// file's own matrix infers the equivalence — it trusts that
    /// `DecisionRowMeasurer.rowWidth(...)`'s own predicted threshold is
    /// where `DecisionBar.body`'s own REAL `ViewThatFits(in: .horizontal)`
    /// actually flips, and checks clipping/well-presence on that trust.
    /// This test is the one that actually PROVES the trust: compose the
    /// real `DetailBand` (which composes the real `DecisionBar`, which
    /// runs the real `ViewThatFits`) at act width `threshold − 1` and at
    /// `threshold + 1`, where `threshold` is the measurer's own predicted
    /// flip point, and assert the REAL row's own measured HEIGHT is the
    /// stacked shape below it and the horizontal shape above it. This is
    /// the exact check once run BY HAND to catch the spacing
    /// drift `bandDecisionRowSpacing` (`OverviewLayout.swift`) now closes
    /// structurally — a standing version of it, so a future drift of the
    /// same shape (a control's own padding, a font change that moves the
    /// real row's natural width without moving `bareRow`'s) fails loudly
    /// here even if the shared constant itself stays correct.
    ///
    /// `"git push origin *"` at the full recipe (usable 419, unsqueezed —
    /// `buttonMinWidth` 140, `outerPadding` 8): `DecisionRowMeasurer`'s
    /// own pinned figure is 614 pt, so `threshold` = 614 + 2 × 8 = 630.
    /// `bandWidth: actWidth + 2 × bandColumnsHorizontalPadding` alone
    /// (no side columns, no actions column — both widths land well under
    /// `bandCompactThreshold`, `.actOnly`) is `DetailBand.actZoneWidth`'s
    /// own identity at this zone, the same one `theAllowDenyRowNeverClipsAtANarrowActZone`'s
    /// own predecessor already relied on.
    ///
    /// **`Self.decisionRuntime`'s own `quickActions: []` override — Phase
    /// 3's own addition, load-bearing here.** The mandatory Quick Actions
    /// column never drops for width alone any more (`OverviewLayout
    /// .bandZonePlan`'s own doc comment states the redesign in full), so
    /// the "no side columns, no actions column" identity two paragraphs up
    /// is only true when the fixture itself offers none — with the
    /// default `QuickAction.shipped` trailer, the composed band at these
    /// narrow act widths would instead land the ladder's own SQUEEZED
    /// step (act 350, `bandActFloorWidth`), not the bare `actWidth` this
    /// test hands it, and the isolation this whole test exists to prove
    /// would be broken by the very column it is not testing.
    @Test("the real, composed band's own ViewThatFits flip matches the measurer's predicted boundary exactly")
    func theBoundaryBetweenStackedAndHorizontalMatchesTheRealViewThatFitsFlip() {
        // `quickActions: []` — an addition to this fixture,
        // load-bearing here specifically: `bandZonePlan`'s mandatory
        // column never drops for width alone any more, so a NON-empty
        // action set at these narrow act widths (~630 ± 1) would claim
        // real width the `bandWidth = actWidth + padding` identity below
        // assumes belongs to the act zone alone, breaking the isolation
        // this test's whole premise depends on.
        let runtime = Self.decisionRuntime(ruleTexts: ["git push origin *"], quickActions: [])
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no decision, so nothing below is measured")
            return
        }
        let usableHeight = 419.0
        let titles = DecisionBar.buttonTitles(for: decision)
        let rowWidth = DecisionRowMeasurer.rowWidth(titles: [titles.yes] + titles.suggestions + [titles.no], buttonMinWidth: 140)
        let threshold = rowWidth + 2 * DetailBand.decisionBarOuterPadding(squeezed: false)

        func realButtonsHeight(actWidth: Double) -> Double? {
            let bandWidth = actWidth + 2 * OverviewLayout.bandColumnsHorizontalPadding
            var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight, dismissedStage: nil)
            var buttonsFrame: CGRect?
            band.onDecisionButtonsFrameMeasured = { buttonsFrame = $0 }
            _ = measured(band, width: bandWidth)
            return buttonsFrame.map(\.height).map(Double.init)
        }

        guard let stackedHeight = realButtonsHeight(actWidth: threshold - 1) else {
            Issue.record("the Allow/Deny row's own geometry probe never fired at act \(threshold - 1)")
            return
        }
        guard let horizontalHeight = realButtonsHeight(actWidth: threshold + 1) else {
            Issue.record("the Allow/Deny row's own geometry probe never fired at act \(threshold + 1)")
            return
        }
        let expectedStacked = 3 * OverviewLayout.bandDecisionButtonHeight(usableHeight: usableHeight)
            + 2 * OverviewLayout.bandDecisionRowStackSpacing
        let expectedHorizontal = OverviewLayout.bandDecisionButtonHeight(usableHeight: usableHeight)
        #expect(abs(stackedHeight - expectedStacked) < 1,
                Comment(rawValue: "act \(threshold - 1) (one point BELOW the measurer's own predicted threshold "
                        + "\(threshold)) measured \(stackedHeight) pt tall — expected the STACKED shape "
                        + "(\(expectedStacked) pt); the real row is not stacking where the measurer says it should"))
        #expect(abs(horizontalHeight - expectedHorizontal) < 1,
                Comment(rawValue: "act \(threshold + 1) (one point ABOVE the measurer's own predicted threshold "
                        + "\(threshold)) measured \(horizontalHeight) pt tall — expected the HORIZONTAL shape "
                        + "(\(expectedHorizontal) pt); the real row is still stacking past where the measurer "
                        + "says it should have flipped"))
    }

    /// **Both the title AND the well folded together — production-reachable
    /// as defensive depth, and the `measuredMinimum` sample the demand-free
    /// law's own tests never took at this specific composition.** Usable
    /// 100 clears neither `bandWellFits`'s own floor (248) nor
    /// `bandShowsDecisionTitle`'s own (164), so BOTH omit regardless of
    /// whether the row stacks — a single suggestion at act 604 measures
    /// well under either row-width threshold, so this sample isolates the
    /// height folds alone, uncomplicated by a stacked row.
    /// `detailBandNeverDemandsHeight` samples a handful of usable heights,
    /// but none of them were chosen FOR being a point where both folds
    /// engage at once, so this closes that specific gap rather than
    /// trusting the general sweep to have covered it by luck.
    @Test("both the title and the well fold together at a tight enough budget, and the band still demands no height")
    func theTitleAndWellFoldTogetherWithoutClippingOrDemandingHeight() {
        let runtime = Self.decisionRuntime(ruleTexts: ["git push *"])
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the fixture produced no decision, so nothing below is measured")
            return
        }
        let actWidth = 604.0
        let usableHeight = 100.0
        let bandWidth = actWidth + 2 * OverviewLayout.bandColumnsHorizontalPadding
        let columnsHeightBudget = max(0, usableHeight - OverviewLayout.bandHeaderHeight)
        let actZoneCeiling = OverviewLayout.bandHeaderHeight + columnsHeightBudget

        #expect(OverviewLayout.bandSqueezed(usableHeight: usableHeight),
                "the fixture's own premise: this sample should be squeezed")
        #expect(!wellShouldFit(decision: decision, actWidth: actWidth, usableHeight: usableHeight),
                "the fixture's own premise: usable \(usableHeight) should clear neither fold's own floor")
        #expect(!OverviewLayout.bandShowsDecisionTitle(usableHeight: usableHeight),
                "the fixture's own premise: usable \(usableHeight) should already fold the title with no stacked row at all")

        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight, dismissedStage: nil)
        var buttonsFrame: CGRect?
        var wellFrame: CGRect?
        band.onDecisionButtonsFrameMeasured = { buttonsFrame = $0 }
        band.onDecisionWellFrameMeasured = { wellFrame = $0 }
        _ = measured(band, width: bandWidth)

        guard let buttonsFrame else {
            Issue.record("the Allow/Deny row's own geometry probe never fired — it may not be rendering at all")
            return
        }
        #expect(buttonsFrame.height > 0,
                "the Allow/Deny row measured zero height — that is not \"unclipped\", it is invisible")
        #expect(buttonsFrame.maxY <= actZoneCeiling,
                Comment(rawValue: "the buttons alone reach \(buttonsFrame.maxY) pt against a \(actZoneCeiling) pt "
                        + "ceiling — even with both folds engaged, nothing left to fold, this is expected to fit "
                        + "here; if it does not, that is a real hardware floor to report, not silently retune "
                        + "around"))
        #expect(wellFrame == nil,
                Comment(rawValue: "the well's own geometry probe fired (\(String(describing: wellFrame))) at a "
                        + "budget its own fold threshold already said it should not afford"))

        // The demand-free law's own floor, at THIS specific composition.
        let min = measuredMinimum(DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                                             dismissedStage: nil))
        #expect(min.height <= 1,
                Comment(rawValue: "with both the title and the well folded, DetailBand reported a minimum height "
                        + "of \(min.height) pt — it should never demand height, whatever it is composing"))
    }

    /// **The floor's own arbiter, re-sited to the input it is actually
    /// about.** `OverviewLayout.bandMinimumHeight` (358) is not an
    /// independent number — it IS this measurement, restated as the
    /// height floor's own value, so `.row` never opens a band too short
    /// for the worst case it is supposed to guarantee fits. Exact-fill
    /// holds unconditionally now: `bandWellHeight(usableHeight:)` has no
    /// row count to yield at any more, so there is no premise left to
    /// check before trusting what it measures.
    @Test("the canonical worst-case decision, measured at the band's own height floor, exactly fills it")
    func bandFitsExactlyAtItsOwnHeightFloor() {
        let runtime = Self.worstCaseDecisionRuntime()
        let bandWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let expanded = measured(DetailBand(runtime: runtime, width: bandWidth,
                                           usableHeight: OverviewLayout.bandMinimumHeight,
                                           dismissedStage: nil, wellInitiallyExpanded: true),
                                width: bandWidth)
        #expect(Double(expanded.height) == OverviewLayout.bandMinimumHeight,
                Comment(rawValue: "the worst case at the floor's own usableHeight "
                        + "(\(OverviewLayout.bandMinimumHeight) pt) measured \(expanded.height) pt — the "
                        + "exact-fill identity no longer holding is a real regression to chase, not to loosen "
                        + "this back to `<=` for"))
    }

    /// **`OverviewLayout.bandFixedChrome`'s own live arbiter — the same
    /// two-sample slope technique `SubjectOverflow.expandedMaxHeight`'s
    /// own doc comment used, applied to the WHOLE band rather than
    /// `DecisionBar` alone.** Sampling the SAME worst-case shape at two
    /// well-cap inputs 60 pt apart: the total moves by exactly 60 pt in
    /// step, which is what proves the well is the only thing flexing and
    /// makes `total − bandWellHeight(usableHeight:)` the SAME fixed number
    /// at both samples rather than two disagreeing guesses.
    ///
    /// **Simpler than every prior round of this arbiter — the Quick
    /// Actions column's move, not a loosened check.** There is no more row
    /// count to hold constant across samples (the pinned bar this arbiter
    /// used to have to reason about is gone), so chrome is now a flat
    /// constant checked directly against `bandFixedChrome`.
    ///
    /// **The strip's own two real budgets ARE the two slope samples now —
    /// not two generous, arbitrary heights standing in for them.**
    /// A first attempt at this arbiter used 500/560 pt, comfortably past
    /// every real height this deck ever offers — the same "past anything
    /// this deck's hardware offers" idiom earlier rounds of this arbiter
    /// used. That choice was wrong for a reason specific to THIS fixture:
    /// the canonical worst case's own `SubjectWell` (a 20-line plan)
    /// stops GROWING once its own content is fully shown, well under a
    /// 328 pt cap — the well-cap formula kept climbing past that point,
    /// but the real render did not, which silently broke the "well alone
    /// is flexing" premise this technique depends on. 359 and 419 sit
    /// well under that ceiling (127 pt and 187 pt of cap respectively),
    /// so the slope is genuine there, and pinning them directly is the
    /// more useful claim regardless — they are the only two heights this
    /// constant's own correctness actually has to hold at.
    @Test("the band's fixed chrome, measured live, matches OverviewLayout.bandFixedChrome")
    func bandFixedChromeArbiter() {
        let runtime = Self.worstCaseDecisionRuntime()
        let bandWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth

        func chrome(at usableHeight: Double) -> Double {
            let total = measured(DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                                            dismissedStage: nil, wellInitiallyExpanded: true),
                                 width: bandWidth).height
            return total - OverviewLayout.bandWellHeight(usableHeight: usableHeight)
        }

        let chromeAt359 = chrome(at: QuestionOptionsBand.usableStripHeight - 60)
        let chromeAt419 = chrome(at: QuestionOptionsBand.usableStripHeight)
        #expect(chromeAt359 == chromeAt419,
                Comment(rawValue: "fixed chrome measured \(chromeAt359) pt at 359 pt usable but \(chromeAt419) "
                        + "pt at 419 pt usable — something besides the well is flexing"))
        #expect(chromeAt419 == OverviewLayout.bandFixedChrome,
                Comment(rawValue: "the band's fixed chrome measured \(chromeAt419) pt live — "
                        + "OverviewLayout.bandFixedChrome (\(OverviewLayout.bandFixedChrome) pt) is stale, "
                        + "retune it to match"))
    }

    /// **The flex actually renders taller with more room, not merely
    /// computes a bigger number.** A pure test on `OverviewLayout
    /// .bandWellHeight` alone (`OverviewLayoutTests
    /// .bandWellHeightFlexesWithUsableHeight`) can be satisfied by the
    /// FORMULA without `DetailBand` ever reading it — this is the render-
    /// level half, the same discipline `bandFitsTheStripWorstCaseDecision`
    /// already holds the band's UPPER bound to, applied to the LOWER
    /// direction: not just "fits", but "grows".
    ///
    /// **Simplified with the Quick Actions column's move — no row count
    /// left to hold constant while isolating the collapsed-lines flex.**
    /// Every prior round of this test had to find two heights sharing the
    /// SAME row count so a height comparison isolated `bandWellCollapsedLines`
    /// alone rather than also crossing a row-yield boundary; there is no
    /// such boundary any more (`bandWellHeight(usableHeight:)`'s own doc
    /// comment states why), so any two heights with genuinely different
    /// slack isolate it now. The well's own floor (`bandFixedChrome +
    /// bandWellMinimum`, 0 pt of slack, the tightest 1 line) against
    /// `bandMinimumHeight` itself (110 pt of slack, capped at 4) is that
    /// pair.
    @Test("the expanded well renders taller at 419 pt usable than at 359 pt usable, and the collapsed one grows with slack")
    func bandFlexGivesTheWellRoomOnTheStrip() {
        let runtime = Self.worstCaseDecisionRuntime()
        let bandWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth

        let atFullBudget = measured(DetailBand(runtime: runtime, width: bandWidth,
                                               usableHeight: QuestionOptionsBand.usableStripHeight,
                                               dismissedStage: nil, wellInitiallyExpanded: true),
                                    width: bandWidth)
        let atSqueezedBudget = measured(DetailBand(runtime: runtime, width: bandWidth,
                                                   usableHeight: QuestionOptionsBand.usableStripHeight - 60,
                                                   dismissedStage: nil, wellInitiallyExpanded: true),
                                        width: bandWidth)
        #expect(atFullBudget.height > atSqueezedBudget.height,
                Comment(rawValue: "the expanded well at 419 pt usable (\(atFullBudget.height) pt) is not "
                        + "taller than at 359 pt usable (\(atSqueezedBudget.height) pt) — the flex rule is "
                        + "not actually flexing"))
        #expect(atFullBudget.height - atSqueezedBudget.height == 60,
                Comment(rawValue: "the band grew by \(atFullBudget.height - atSqueezedBudget.height) pt for "
                        + "60 pt more usable height, not 60 — the well's own floor or the controls column's "
                        + "own fold may be binding at one end"))

        // The strip's own two real budgets, pinned directly — 187 pt at
        // 419, 127 pt at 359 (`OverviewLayout.bandWellHeight`'s own doc
        // comment carries both), both comfortably clearing the collapsed-
        // lines threshold.
        #expect(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight) == 187,
                Comment(rawValue: "got \(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight))"))
        #expect(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight - 60) == 127,
                Comment(rawValue: "got \(OverviewLayout.bandWellHeight(usableHeight: QuestionOptionsBand.usableStripHeight - 60))"))
        #expect(OverviewLayout.bandWellCollapsedLines(usableHeight: QuestionOptionsBand.usableStripHeight) == 4
                && OverviewLayout.bandWellCollapsedLines(usableHeight: QuestionOptionsBand.usableStripHeight - 60) == 4,
                "both real strip budgets should show the full 4 collapsed lines")

        // The collapsed-lines flex, isolated at a genuinely different
        // slack — the well's own floor (0 pt of slack) against
        // `bandMinimumHeight` itself (110 pt, capped at 4).
        let floorHeight = OverviewLayout.bandFixedChrome + OverviewLayout.bandWellMinimum
        #expect(OverviewLayout.bandWellCollapsedLines(usableHeight: floorHeight) == 1,
                "the fixture's own premise: the well's own floor should show the tightest 1 line")
        #expect(OverviewLayout.bandWellCollapsedLines(usableHeight: OverviewLayout.bandMinimumHeight) == 4,
                "the fixture's own premise: bandMinimumHeight should show the full 4 collapsed lines")
        let collapsedAtFloorHeight = measured(DetailBand(runtime: runtime, width: bandWidth,
                                                         usableHeight: floorHeight, dismissedStage: nil),
                                              width: bandWidth)
        let collapsedAtBandMinimum = measured(DetailBand(runtime: runtime, width: bandWidth,
                                                         usableHeight: OverviewLayout.bandMinimumHeight,
                                                         dismissedStage: nil),
                                              width: bandWidth)
        #expect(collapsedAtBandMinimum.height > collapsedAtFloorHeight.height,
                Comment(rawValue: "collapsed at bandMinimumHeight (\(collapsedAtBandMinimum.height) pt, 4 "
                        + "lines) is not taller than at the well's own floor (\(collapsedAtFloorHeight.height) "
                        + "pt, 1 line) — the collapsed-lines flex is not wired to the render"))
    }

    // ------------------------------------------------- the live bug 
    //
    // The strip NEVER changes its own window size — standing law, enforced
    // for `DeckRuntime`. `DeckScene.swift`'s
    // `.windowResizability(.contentSize)` sizes the WINDOW to whatever the
    // content reports as its ideal/minimum size, and `DetailBand` had
    // nothing anywhere holding its OWN reported size to what it was given —
    // `usableHeight`/`width` were data a couple of formulas
    // (`bandWellHeight`) read, never a ceiling the view's own root was
    // capped at. Selecting a needs-you card whose decision is a bare
    // (no-preview) question — `QuestionTakeover`, not `DecisionBar`, so
    // NONE of the four band-tuned parameters `actZone(for:)`'s own doc
    // comment describes apply — made the WINDOW grow, live, on the strip: ~1000 pt and ~1360 pt tall in two screenshots, past
    // `RenderSweepTests`' own 760 pt grid threshold, so the layout even
    // flipped to `.grid` and the classic inspector appeared underneath the
    // illegal resize.
    //
    // Three tests below, all RED against the code this comment sits in:
    // two on the HEIGHT axis (`DetailBand` at its own documented floor, and
    // the composed `DeckWindow` at the strip's real budget — the literal
    // screenshot), one on the WIDTH axis (`bandFleetWidth + bandSeamWidth +
    // bandMinimumWidth` = 324 + 8 + 644 = 976, already past
    // `DeckPrefs.minWindow.width`'s own 960 — the arithmetic this brief
    // asked to be checked, confirmed to exceed even after `bandFleetWidth`'s
    // own later retune, 352 → 324, the sliver's retirement — see that
    // constant's own doc comment).
    //
    // **That 644/976 is HISTORY as of the mandatory Quick Actions column.**
    // `bandMinimumWidth` is 628 now and the sum is exactly 960, an identity
    // rather than an overshoot — `bandActFloorWidth` is derived as the room
    // the minimum window LEAVES rather than the room the act zone WANTS.
    // Left standing rather than rewritten because this paragraph is a record
    // of what was red when these three tests were written; the live
    // arithmetic and why it moved are on `bandNeverDemandsMoreWidthThanItIsGiven`
    // itself, below.

    /// **The band's own live-shape worst case, held to its own documented
    /// height floor — `bandFitsExactlyAtItsOwnHeightFloor`'s own template,
    /// applied to the NEW worst-recorded shape rather than the synthesised
    /// suggestion-bearing decision.** `OverviewLayout.bandMinimumHeight`
    /// (358) is the shortest `usableHeight` the band is ever LEGITIMATELY
    /// composed at (`presentation(...)` falls back to `.inspector` below
    /// it) — so if `DetailBand`, told it has exactly that much room,
    /// reports back MORE, the floor does not actually hold for this shape.
    ///
    /// **Measures IDEAL, not the enforced MINIMUM — stated rather than left implicit.** `measured(_:width:)`
    /// reads what `DetailBand` reports as its natural size AT a given
    /// width — a real, still-worth-holding property (does the band's own
    /// compression logic keep its content within the budget it was
    /// given?) — but NOT the number `.windowResizability(.contentSize)`
    /// actually enforces as the WINDOW's own resize floor, which a live bug proved can move even while every assertion in this
    /// file stayed green. That number is measured by `measuredMinimum(_:)`
    /// and held constant by `bandedDeckWindowMinimumIsTheConstantFloorRegardlessOfComposition`,
    /// below the width-twin test — a `DeckWindow`-level guard, since
    /// `DeckWindow`, not `DetailBand`, is the root content
    /// `.windowResizability` actually reads. This test stays as its own,
    /// narrower guard: `DetailBand`'s own compression discipline, isolated
    /// from the fix that closes the actual window-resize bug.
    @Test("the band fits the live-recorded needs-you shape at its own documented height floor")
    func bandFitsTheLiveRecordedShapeAtItsOwnHeightFloor() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the live-shape fixture produced no decision, so nothing below is measured")
            return
        }
        #expect(!decision.questions.isEmpty,
                "the fixture's own premise: a bare question, so actZone(for:) builds QuestionTakeover")
        #expect((runtime.frame.lanes.first?.prompts.count ?? 0) >= 3,
                "the fixture's own premise: real prompt history, so earlierPrompts has rows to draw")
        #expect(!runtime.frame.actions.isEmpty,
                "the fixture's own premise: the shipped quick actions pin the QuickActionBar")
        #expect(runtime.frame.autoContinuable,
                "the fixture's own premise: AutoContinueToggle actually renders")

        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let size = measured(DetailBand(runtime: runtime, width: bandWidth,
                                       usableHeight: OverviewLayout.bandMinimumHeight, dismissedStage: nil),
                            width: bandWidth)
        #expect(size.height <= OverviewLayout.bandMinimumHeight,
                Comment(rawValue: "the live-recorded shape measured \(size.height) pt against its own "
                        + "\(OverviewLayout.bandMinimumHeight) pt documented floor — the band is demanding "
                        + "more height than the one input it was told it had"))
    }

    /// **The literal screenshot, reproduced.** `.windowResizability
    /// (.contentSize)` (`DeckScene.swift`) sizes the WINDOW to whatever
    /// `DeckWindow`'s own composed content reports as its ideal height AT
    /// THE WINDOW'S CURRENT WIDTH — exactly what `measured(_:width:)`
    /// measures: width fixed via `.frame(width:)` (the axis AppKit holds
    /// fixed for this query too), height read back unconstrained. The
    /// titlebar is native window chrome, never part of the content view
    /// this measures (`DeckScene.swift`'s own comment on `.unifiedCompact`,
    /// measured live at 40 pt — the same 40 `QuestionOptionsBand
    /// .usableStripHeight`'s own 419 = 480 − 40 − 21 already subtracts), so
    /// a 480 pt strip's own content-view budget is 480 − 40 = 440. `fleetSize`
    /// is seeded to the strip's own real banner-up budget (359 =
    /// `usableStripHeight` − `measuredBannerHeight`) — the connection
    /// banner is showing because `DeckRuntime.connection` defaults to
    /// `.notConnected` and nothing here overrides it, the SAME binding-
    /// constraint state `OverviewLayout.bandMinimumHeight`'s own doc
    /// comment already treats as canonical — simulating exactly the moment
    /// before the tap: the window IS the strip, then a needs-you card is
    /// selected.
    ///
    /// **Measures IDEAL, not the enforced MINIMUM — the same distinction `bandFitsTheLiveRecordedShapeAtItsOwnHeightFloor`'s own
    /// doc comment now states.** This test's own name says "never demands
    /// more height," and that claim was true and stayed true — the live bug that survived the first fix was never about IDEAL height exceeding
    /// budget, it was about the window's own MINIMUM refusing to shrink
    /// below whatever size it was at when the band opened, a fact this
    /// measurement cannot see (`measured(_:width:)`'s own doc comment
    /// explains why). Kept, unmodified, as the IDEAL-side guard;
    /// `bandedDeckWindowMinimumIsTheConstantFloorRegardlessOfComposition`
    /// below is its MINIMUM-side counterpart.
    @Test("the composed, banded DeckWindow never demands more height than the strip's own content budget")
    func bandedDeckWindowFitsTheStripWithoutGrowingIt() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard let decision = runtime.frame.decisions.first else {
            Issue.record("the live-shape fixture produced no decision, so nothing below is measured")
            return
        }
        #expect(!decision.questions.isEmpty,
                "the fixture's own premise: a bare question, so actZone(for:) builds QuestionTakeover")
        #expect((runtime.frame.lanes.first?.prompts.count ?? 0) >= 3,
                "the fixture's own premise: real prompt history, so earlierPrompts has rows to draw")
        #expect(!runtime.frame.actions.isEmpty,
                "the fixture's own premise: the shipped quick actions pin the QuickActionBar")
        #expect(runtime.frame.autoContinuable,
                "the fixture's own premise: AutoContinueToggle actually renders")
        #expect(runtime.connection.needsAttention,
                "the fixture's own premise: the connection banner is up — the binding-constraint state")

        let bannerUpBudget = QuestionOptionsBand.usableStripHeight - Self.measuredBannerHeight // 359
        let window = DeckWindow(runtime: runtime, layout: .row,
                                fleetSize: CGSize(width: Self.stripWidth, height: bannerUpBudget))
        #expect(window.bandShownForTesting,
                "the fixture's own premise: the band actually composes at this geometry, not the inspector")

        let stripContentBudget = Self.stripHeight - 40 // 480 strip − 40 pt compact titlebar.
        let size = measured(window, width: Self.stripWidth)
        #expect(size.height <= stripContentBudget,
                Comment(rawValue: "the banded window's content measured \(size.height) pt against the strip's "
                        + "own \(stripContentBudget) pt content budget — DeckScene's own "
                        + ".windowResizability(.contentSize) would grow the WINDOW to match this, the live bug "
                        + "the live screenshots showed (~1000 pt, ~1360 pt tall) — the deck never resizes its own "
                        + "window"))
    }

    /// **The probe's own honesty check — a floor, where the test above is a
    /// ceiling.** `bandedDeckWindowFitsTheStripWithoutGrowingIt` proves the
    /// composed window's IDEAL size never exceeds the strip's content
    /// budget; it says nothing about whether the ONE number every budget
    /// downstream of `onGeometryChange` trusts (`fleetSize`, and through it
    /// `DetailBand.usableHeight`, `OverviewLayout.presentation`) is honest
    /// about what the status line and connection banner have already taken
    /// off the top and bottom. Before this fix, `.inspector` — merely
    /// ATTACHED to `DeckWindow.body`, whether or not it was ever presented
    /// — swallowed both `.safeAreaInset` calls sitting after it
    /// (`SafeAreaExperimentScratch`'s own experiments B/C, reproduced
    /// headlessly), so the probe reported the FULL region and every
    /// downstream budget over-allocated by exactly the chrome's own height.
    /// AX-probed live, a live pass: a 1000×430 deck window, content laid out
    /// to 390 pt (the window's content region minus its 40 pt titlebar
    /// ONLY — the status line's own 21 pt was never subtracted), the
    /// status line painting over the QuickActionBar's buttons mid-capsule.
    @Test("the window's own probe reports the room the status line and banner actually leave")
    func theProbeSeesOnlyTheRoomTheChromeLeaves() {
        // Any runtime works — the swallowed inset is composition-level,
        // independent of lanes or selection. The default connection state is
        // .notConnected, so the ConnectionBanner is UP in this composition.
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        var window = DeckWindow(runtime: runtime, layout: .row, fleetSize: .zero)
        var reported = CGSize.zero
        window.onContentSizeMeasured = { reported = $0 }

        let hostHeight = 390.0  // the live-probed desktop shape: a 1000×430 window minus its measured 40 pt titlebar
        let host = NSHostingView(rootView: AnyView(window))
        host.frame = NSRect(x: 0, y: 0, width: 1000, height: hostHeight)
        host.layoutSubtreeIfNeeded()

        // Measured at the SAME width the host lays the window out at
        // (1000, not `stripWidth`) so this cannot silently drift from what
        // the composition actually draws — the same reasoning
        // `measuredBannerHeightArbiter` holds `measuredBannerHeight` to,
        // applied at this test's own geometry instead.
        let status = measured(StatusLine(status: runtime.status), width: 1000).height
        let banner = measured(ConnectionBanner(runtime: runtime, showingSetup: .constant(false)),
                              width: 1000).height
        #expect(status > 0 && banner > 0, "the premise: both chrome bars actually render")
        // Bound to a `let` rather than written inline: `#expect`'s own
        // macro, in this toolchain, mis-evaluates a bare `A == B` when both
        // sides are freshly-computed `Double` expressions, reporting a
        // spurious failure with IDENTICAL values on both sides of the "→"
        // (confirmed bit-for-bit equal via `.bitPattern` while chasing this
        // down) — a macro artifact, not a real inequality. Materializing
        // the comparison first sidesteps it without weakening what is
        // actually being asserted: still exact equality, not a tolerance.
        let expectedHeight = hostHeight - status - banner
        let matchesExactly = reported.height == expectedHeight
        #expect(matchesExactly,
                Comment(rawValue: "the probe reported \(reported.height) pt of usable height in a "
                        + "\(hostHeight) pt region whose chrome takes \(status + banner) pt — every budget "
                        + "downstream (DetailBand.usableHeight, OverviewLayout.presentation) consumes this "
                        + "number, and a probe that counts the chrome's own room is exactly how the "
                        + "QuickActionBar's buttons ended up painted under the status line (AX-probed live)"))
        #expect(reported.width == 1000, "the width axis has no chrome and must be untouched")
    }

    /// **Finding C — the probe's own THIRD face of the deadlock family,
    /// live-reproduced and trace-confirmed on the strip, one level up from
    /// the two `DetailBand.body` closes.** That file's own doc comments
    /// carry (a) the band demanding HEIGHT and (b) the band demanding
    /// stale WIDTH — both the band refusing to report a floor upward. This
    /// is a ceiling problem instead: the probe used to read `$0.size` on
    /// the composition root ITSELF, which reports whatever size the
    /// composition resolved to, not what the window actually offered. On
    /// GROWTH those two can differ — a banded `HStack` with no reason to be
    /// wider than its (bounded) children's own sum stays at the SMALLER
    /// size, `bandWidth` never re-derives from the true offer, and the
    /// whole composition floats centered in the larger window with stale
    /// fold state. `DeckWindow.body`'s own doc comment on `.onGeometryChange`
    /// carries the live trace this reproduces: shrink a banded window
    /// 1600→960, then grow it back to 1600 — the probe kept reporting
    /// (960.0, 787.0) forever.
    ///
    /// **Two REAL host resizes, not a single seeded `@State` — investigated
    /// directly, and the investigation is why this is shaped the way it
    /// is.** A first draft seeded `fleetSize` at construction (960×320,
    /// `bandWidth`'s own 628 arithmetic) and hosted directly at 1600×900,
    /// expecting the probe to stay pinned near the seed. It did not: a
    /// bare `NSHostingView`'s very FIRST `layoutSubtreeIfNeeded()` resolves
    /// an internal bootstrap pass at some small proposal BEFORE it ever
    /// consults the frame just assigned — proven by instrumenting the
    /// probe directly, which showed a first firing at (332, 19) followed by
    /// a second at the real height. That bootstrap pass overwrites the
    /// SEEDED `fleetSize` before the assigned frame is ever read, so a
    /// one-shot host at 1600×900 measures the bootstrap's own artifact, not
    /// the seed. The fix: host at the SHRUNK size FIRST (960×787) and call
    /// `layoutSubtreeIfNeeded()` to let that settle for real, THEN resize
    /// the SAME host to 1600×900 and call it again — two genuine layout
    /// passes, mirroring the live shrink-then-grow sequence step for
    /// step, with no seeded value for a bootstrap pass to race.
    ///
    /// **The fixed point this settles on is 332, not the live 960 — a
    /// difference worth naming rather than hiding.** 332 is `bandFleetWidth`
    /// (324) + `bandSeamWidth` (8) alone: THIS harness's own bootstrap
    /// pass proposes something narrower than even 332 on its first firing,
    /// so `DetailBand` — proposed less than it needs — settles at 0 rather
    /// than at a positive stale width, and 332 (not 960) is the resulting
    /// self-consistent floor the first REAL resize (960×787) itself gets
    /// trapped at, before the fix. The live app's own 960 and this
    /// harness's own 332 are different NUMBERS for the same reason: both
    /// are "whatever `DetailBand` last resolved to," and the two
    /// environments hand it a different LAST proposal before the growth
    /// step. What both share, and what this test actually holds
    /// accountable, is the STRUCTURAL defect Finding C names — pre-fix,
    /// resizing the SAME host from 960×787 to 1600×900 leaves the reported
    /// width UNCHANGED at whatever it was already pinned to, on EITHER
    /// axis's own growth step; post-fix, both real resizes land on their
    /// own true offer exactly (960 after the first, 1600 after the
    /// second) — measured directly below, not asserted from memory.
    @Test("the window's own probe reports the true offer on growth, not a stale composition's own smaller size")
    func theProbeReportsTheOfferNotTheStaleCompositionOnGrowth() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard runtime.frame.selection != nil else {
            Issue.record("the live-shape fixture selected nothing, so nothing below is measured")
            return
        }

        var window = DeckWindow(runtime: runtime, layout: .row)
        var reported = CGSize.zero
        window.onContentSizeMeasured = { reported = $0 }
        #expect(window.bandShownForTesting,
                "the fixture's own premise: the band composes whenever something is selected, at any fleetSize")

        let host = NSHostingView(rootView: AnyView(window))

        // Step one — a real layout pass at the SHRUNK size, settling for
        // real rather than merely being seeded. `bandWidth`'s own 628
        // arithmetic (960 − bandFleetWidth 324 − bandSeamWidth 8) is what a
        // correct probe reports back here.
        host.frame = NSRect(x: 0, y: 0, width: 960, height: 787)
        host.layoutSubtreeIfNeeded()
        let afterShrink = reported

        // Step two — the SAME host, resized to the live trace figure (1600×900) and laid out again. A probe reading the
        // composition rather than the offer has no reason to report
        // anything different from `afterShrink` — nothing inside changed,
        // only the window did.
        host.frame = NSRect(x: 0, y: 0, width: 1600, height: 900)
        host.layoutSubtreeIfNeeded()

        #expect(Double(afterShrink.width) == 960,
                Comment(rawValue: "the probe reported \(afterShrink.width) pt wide after the FIRST real resize "
                        + "(960×787) — a probe reading the composition rather than the offer settles at some "
                        + "OTHER self-consistent width instead (332 in this harness — this test's own doc "
                        + "comment states why that number, not 960, is what a broken probe traps here), which "
                        + "would make the second assertion below true for the wrong reason if this one did not "
                        + "hold first"))
        #expect(Double(reported.width) == 1600,
                Comment(rawValue: "the probe reported \(reported.width) pt wide after growing the SAME host to "
                        + "1600×900 — a probe reading the composition's own resolved size rather than the offer "
                        + "stays pinned at whatever the first resize already settled it to, never re-deriving "
                        + "bandWidth from the true offer, the exact live signature observed: after growing "
                        + "a shrunk band back to 1600×900 the probe reported (960.0, 787.0) forever"))
    }

    /// **The width twin.** `OverviewLayout.bandFleetWidth` (324, since the
    /// sliver's own retirement — that constant's own doc comment) +
    /// `.bandSeamWidth` (8) + `.bandMinimumWidth` = exactly
    /// `DeckPrefs.minWindow.width` (960), the smallest window the deck will
    /// lay out in.
    ///
    /// **That used to be a strict inequality (644 + 332 = 976 > 960) and is
    /// now an identity, by construction rather than by luck.** Through every
    /// prior round `bandMinimumWidth` was `bandActMinWidth` (620) plus
    /// `columns(for:)`'s own padding — a number derived from what the act
    /// zone WANTED, which the minimum window could not actually supply, so
    /// the sum overshot and this premise read `>`. The mandatory Quick
    /// Actions column inverted that derivation: `bandActFloorWidth` is
    /// defined as precisely the room the minimum window LEAVES once the
    /// fleet, the seam, the padding, the gutter and the actions column have
    /// taken theirs, so `bandMinimumWidth` and the minimum window's own
    /// content width are now the same number by definition. `==`, not `>=`:
    /// a band declaring a minimum WIDER than the window can supply is the
    /// bug this file's own siblings exist to catch, and a band declaring a
    /// NARROWER one would mean the derivation had drifted and the act floor
    /// was no longer the room actually left. Either direction is a finding.
    ///
    /// The measurement below is untouched by any of that — it always asked
    /// whether the CONTENT demands more than the 628 pt it is handed, and
    /// 628 is the same 628 it always was.
    ///
    /// That arithmetic alone proves a live `DeckWindow` cannot both (a) ever
    /// legitimately compose a band with room to spare and (b) fit inside the
    /// documented minimum window —
    /// but it does not by itself prove `DetailBand` is the thing ASKING for
    /// more than it is given, so this measures that directly: below EITHER
    /// floor (`628` = `DeckPrefs.minWindow.width` − `bandFleetWidth` −
    /// `bandSeamWidth`, itself below `bandMinimumWidth`), does `DetailBand`
    /// report back more width than it was told it had? `presentation(...)`
    /// would never route `.band` here in production, but the SAME
    /// construction `bandFitsTheStripWorstCaseDecision`/
    /// `bandFitsExactlyAtItsOwnHeightFloor` already use — build `DetailBand`
    /// directly, bypassing the routing gate — is what proves the CONTENT
    /// itself, not merely the gate around it, never demands more than it is
    /// given.
    ///
    /// **Measures IDEAL (`measuredWidth`), not the enforced MINIMUM —
    /// the same distinction stated on its two siblings above.**
    /// `bandedDeckWindowMinimumIsTheConstantFloorRegardlessOfComposition`
    /// below checks both axes of the actual enforced minimum at once;
    /// this stays as `DetailBand`'s own width-side compression guard.
    @Test("the band never demands more width than it is given, even below its own routing floor")
    func bandNeverDemandsMoreWidthThanItIsGiven() {
        let arithmeticTotal = OverviewLayout.bandFleetWidth + OverviewLayout.bandSeamWidth
            + OverviewLayout.bandMinimumWidth
        #expect(arithmeticTotal == Double(DeckPrefs.minWindow.width),
                Comment(rawValue: "bandFleetWidth + bandSeamWidth + bandMinimumWidth = \(arithmeticTotal) pt is no "
                        + "longer exactly DeckPrefs.minWindow.width (\(DeckPrefs.minWindow.width) pt). Wider means "
                        + "the band declares a minimum the smallest window cannot supply; narrower means "
                        + "bandActFloorWidth has drifted from the room the minimum window actually leaves. "
                        + "Both directions are findings — this identity is by construction, not coincidence"))

        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard runtime.frame.decisions.first != nil else {
            Issue.record("the live-shape fixture produced no decision, so nothing below is measured")
            return
        }
        let width = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth
            - OverviewLayout.bandSeamWidth // 628
        let band = DetailBand(runtime: runtime, width: width, usableHeight: OverviewLayout.bandMinimumHeight,
                              dismissedStage: nil)
        let size = measuredWidth(band, height: OverviewLayout.bandMinimumHeight)
        #expect(size.width <= width,
                Comment(rawValue: "the band measured \(size.width) pt wide when told it had \(width) pt — "
                        + "DetailBand's own act zone would drag the WHOLE window's own minimum width past "
                        + "DeckPrefs.minWindow.width (\(DeckPrefs.minWindow.width) pt) the same way the height "
                        + "bug drags its minimum height"))
    }

    // -------------------------------------------------- the sticky
    // -------------------------------------------------- minimum survived

    /// **INVERTED — this test used to hold `DetailBand` to tracking
    /// `usableHeight` as its own reported MINIMUM, because the fix at the
    /// time lived at `DeckWindow`'s own root and this file's job was to
    /// prove the interior was not ALSO trying to fix it (duplicated
    /// clamping is its own bug class). "Commit to band always" retires that whole premise: a band that is never
    /// allowed to fall back to `.inspector` has to survive being asked for
    /// EVERY reachable `usableHeight`, including ones far below what any
    /// composition's own interior content naturally wants, and a band
    /// whose reported MINIMUM tracks `usableHeight` is exactly the shape
    /// that deadlocks a shrinking window: `.windowResizability
    /// (.contentSize)` reads that minimum as the floor, so a band that
    /// once opened at a generous height and reported it as its OWN minimum
    /// can never be asked to shrink below the size it happened to open
    /// at — two stable fixed points at the SAME window size, reachable by
    /// two different resize paths, exactly the live signature
    /// reproduced on glass. The STRONGER property supersedes the tracking
    /// one: a band that demands NOTHING (`DetailBand.body`'s own outer
    /// `.frame(minHeight: 0, maxHeight: usableHeight)`, split from the
    /// width cap for the identical reason) can never drag the window's
    /// floor anywhere, closing the whole sticky-window bug class harder
    /// than merely keeping the tracking honest ever could.**
    ///
    /// **Every sample below is a composition this feature has ever needed
    /// a live arbiter for — the SAME fixtures the retired
    /// `detailBandMinimumTracksItsOwnUsableHeightByDesign` used to hold to
    /// tracking, now held to reporting ~0 instead, regardless of
    /// `usableHeight`, regardless of whether that height is generous or
    /// far below anything the interior naturally wants.** A bare
    /// nine-option `QuestionTakeover` (the shape whose own natural height
    /// genuinely exceeds both real strip heights), the canonical
    /// suggestion-bearing `DecisionBar` worst case, and a well-mounted,
    /// 20-prompt `TranscriptWell` composition — three different act-zone
    /// branches, so no single branch's own shape could be hiding a
    /// residual minimum the other two do not share.
    ///
    /// **A FOURTH composition: a STACKED
    /// decision row.** The three samples above never actually exercise
    /// `DecisionRowMeasurer`'s own STACKED shape — `bandWidth` above is
    /// the wide strip's own (`.withControls`), and none of `question`/
    /// `decision`/`well`'s own content is wide enough to stack there. The
    /// law does hold at a stacked composition too (measured across 8 stacked samples at `min(height,
    /// width)` 0) — this sample is what PINS that, at `stackedBandWidth`
    /// (628, the min window's own band width) with the two-suggestion
    /// decision (four buttons, the shape this whole rework's own
    /// content-driven matrix already holds accountable for stacking
    /// there).
    ///
    /// **RETOLD — `stackedBandWidth` (628) is now ALSO the
    /// mandatory-column redesign's own new-territory shape, not merely
    /// the stacked-row one this paragraph names above.** `stackedRuntime`
    /// (`Self.decisionRuntime(ruleTexts:)`) carries the DEFAULT
    /// `QuickAction.shipped` trailer — three real, shipped actions — and
    /// at band 628 the mandatory column now claims its own share even
    /// though this composition's own act width used to be simply "604,
    /// .actOnly" previously (this paragraph's own earlier wording,
    /// before this round). The fixture's own premise, asserted below
    /// before anything is measured: `stacked.actZoneWidth` lands on
    /// `bandActFloorWidth` (350), the ladder's own squeezed step, with the
    /// actions column genuinely present — a mandatory 230pt column at
    /// band 628 is new territory this deadlock-breaker had never sampled
    /// before, `measuredMinimum(_:)` being the one helper that can even
    /// see this class of bug (a `measured(_:width:)`-based check would be
    /// a tautology, `theBandFillsItsFullCommandedWidthEvenSqueezed`'s own
    /// doc comment states why).
    @Test("DetailBand never demands height — its own reported minimum floors at ~0, whatever it is composing")
    func detailBandNeverDemandsHeight() {
        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth

        let questionRuntime = Self.liveNeedsYouBandShapeRuntime(optionCount: 9)
        guard questionRuntime.frame.decisions.first != nil else {
            Issue.record("the live-shape fixture produced no decision, so nothing below is measured")
            return
        }
        let decisionRuntime = Self.worstCaseDecisionRuntime()
        guard decisionRuntime.frame.decisions.first?.suggestionLabels.isEmpty == false else {
            Issue.record("the worst-case fixture produced no suggestion, so nothing below is measured")
            return
        }
        let wellRuntime = Self.liveWellMountedBandShapeRuntime(promptCount: 20)
        guard wellRuntime.frame.decisions.isEmpty, wellRuntime.frame.selection != nil else {
            let message: String = "the well-mounted fixture opened a decision (or selected nothing) — it no "
                + "longer renders TranscriptWell, so nothing below exercises that branch"
            Issue.record(Comment(rawValue: message))
            return
        }
        let stackedRuntime = Self.decisionRuntime(ruleTexts: ["git push *", "git commit *"])
        guard stackedRuntime.frame.decisions.first?.suggestionLabels.count == 2 else {
            Issue.record("the two-suggestion fixture produced the wrong suggestion count — nothing below exercises a stacked composition")
            return
        }
        let stackedBandWidth = 604.0 + 2 * OverviewLayout.bandColumnsHorizontalPadding

        // The strip's own two real budgets (419, 359 — never squeezed,
        // `OverviewLayout.bandSqueezed(usableHeight:)`'s own doc comment
        // states why), a generous desktop height (548), and a squeezed
        // one well below `bandMinimumHeight` (149 — BELOW the corrected
        // reachable floor, usable 189 banner up; `promptLineLimit
        // (usableHeight:rows:banded:)`'s own doc comment carries the
        // corrected derivation — kept here as defensive depth, the
        // tightest input this deadlock-breaker is still held accountable
        // at even though production cannot reach it) — the
        // full range this deadlock-breaker has to hold across, reachable
        // and defensive-depth alike.
        let heights: [Double] = [QuestionOptionsBand.usableStripHeight,
                                 QuestionOptionsBand.usableStripHeight - 60, 548, 149]
        for height in heights {
            let question = DetailBand(runtime: questionRuntime, width: bandWidth, usableHeight: height,
                                      dismissedStage: nil)
            let decision = DetailBand(runtime: decisionRuntime, width: bandWidth, usableHeight: height,
                                      dismissedStage: nil)
            let well = DetailBand(runtime: wellRuntime, width: bandWidth, usableHeight: height,
                                  dismissedStage: nil)
            let stacked = DetailBand(runtime: stackedRuntime, width: stackedBandWidth, usableHeight: height,
                                     dismissedStage: nil)
            // The fixture's own premise — RETOLD a second time,
            // the correction of the FIRST retelling, which
            // was written against an unconditional fold and is wrong in
            // its own conclusion (though right about where the threshold
            // binds). `decisionMinimumActWidth`'s own guard
            // (`DetailBand.swift`) does not merely widen whenever the act
            // zone is too narrow — it widens ONLY when folding would
            // actually REACH the width a horizontal row needs
            // (`OverviewLayout.bandZonePlan`'s own doc comment carries the
            // corrected contract). At the
            // three GENEROUS heights (419, 359, 548) a stacked four-button
            // row comfortably clears even the squeezed 44pt-class budget,
            // so the guard's own threshold never binds and demands
            // nothing. **At 149 the threshold DOES bind — a stacked
            // four-button row (200 pt) plus 6 pt of bar chrome does not
            // fit a 101 pt budget — but folding is evaluated and REJECTED
            // anyway: `actionCount: 0` at band 628 can only ever reach 604
            // (`controlsShown` stays `false` regardless of height, band
            // 628 being under `bandCompactThreshold` by width alone), and
            // a four-button row's own `needed` width — its natural width
            // plus padding — is comfortably past 604 even at the squeezed
            // recipe's own narrower floor (measured:
            // ~892 pt in the full recipe, and it does not shrink below
            // 604 squeezed).** Folding could not have helped — it would
            // have destroyed the column AND left the row exactly as
            // clipped as it already was — so the guard keeps the column,
            // and `bandActFloorWidth` (350) is the right answer at EVERY
            // height in this sweep, 149 included: the clip at 149 is
            // accepted as the honest outcome of a height below the
            // reachable floor, not fixed by sacrificing the column for
            // nothing.
            #expect(stacked.actZoneWidth == OverviewLayout.bandActFloorWidth,
                    Comment(rawValue: "the fixture's own premise at \(height) pt usable: band 628 (the min "
                            + "window's own width) with a real actions trailer should land act "
                            + "\(OverviewLayout.bandActFloorWidth) — got \(stacked.actZoneWidth)"))
            for (label, band) in [("bare question", question), ("worst-case decision", decision),
                                   ("well-mounted", well), ("stacked decision (two suggestions, min-window act width)", stacked)] {
                let min = measuredMinimum(band)
                #expect(min.height <= 1,
                        Comment(rawValue: "the \(label) composition at \(height) pt usable reported a minimum "
                                + "height of \(min.height) pt — DetailBand should never demand height, "
                                + "whatever it is composing"))
            }
        }
    }

    /// **The width axis's own twin — `detailBandNeverDemandsWidth`, the
    /// second deadlock found live the same night as the
    /// first.** `actZoneWidth`'s own EXACT `.frame(width:)` (the earlier
    /// fix — that property's own doc comment, `DetailBand.swift`, carries
    /// the retelling) is a hard demand computed from whatever `width` this
    /// band was GIVEN; without a floor on `body`'s own outer width frame,
    /// that demand propagated straight through as `DetailBand`'s own
    /// reported MINIMUM width. Live signature: band at 1600×480, then the
    /// window resized to 960×320 in ONE step — `DeckWindow.bandWidth`
    /// derived from the STALE `fleetSize.width` the geometry probe had not
    /// yet re-fired to correct, so `DetailBand` received the old, wider
    /// `width`, and that wider `actZoneWidth` won as the window's own
    /// enforced minimum — wider than the window FRAME itself, wedging
    /// AppKit (the fleet card and `Ticks` pushed off the left edge
    /// entirely, further resizes silently ignored in either direction).
    ///
    /// **Two properties, both real, held separately.** First: the
    /// ORDINARY minimum, at a range of real widths and both real act-zone
    /// shapes (`.withControls` at the strip's own width, `.actOnly` at the
    /// min window's), must still floor at ~0 — the same "whatever it is
    /// composing" sweep `detailBandNeverDemandsHeight` above holds height
    /// to. Second, and this is the live bug's own exact shape: the
    /// STALE-INPUT case — a band constructed with a LARGE `width` (1268,
    /// the live reproduction's own figure: 1600 − `bandFleetWidth` 324 −
    /// `bandSeamWidth` 8) must still report no more than a SMALLER
    /// PROPOSED width (628, the min window's own band width: 960 − 324 −
    /// 8) when that is what the host actually offers — proving the fix
    /// holds even when `actZoneWidth`'s own internal arithmetic was
    /// computed from a `width` the real window frame has already outgrown
    /// (shrunk past), not merely when `width` and the proposal agree.
    ///
    /// **RETOLD — `minWindowBandWidth`'s own ordinary sweep is
    /// ALSO the mandatory-column redesign's own new-territory sample now.**
    /// `decisionRuntime`, this test's own fixture, carries the DEFAULT
    /// `QuickAction.shipped` trailer (`worstCaseDecisionRuntime()`'s own
    /// doc comment states why it always does) — a REAL actions column, so
    /// at `minWindowBandWidth` (628) the ordinary sweep below is exactly
    /// "a mandatory 230pt column at band 628," the top risk this whole
    /// phase's own brief names, asserted as this test's own premise before
    /// anything is measured.
    @Test("DetailBand never demands width — its own minimum floors at ~0, and a stale wider width input yields to a smaller live proposal")
    func detailBandNeverDemandsWidth() {
        let decisionRuntime = Self.worstCaseDecisionRuntime()
        guard decisionRuntime.frame.decisions.first?.suggestionLabels.isEmpty == false else {
            Issue.record("the worst-case fixture produced no suggestion, so nothing below is measured")
            return
        }
        let wideBandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let minWindowBandWidth = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth
            - OverviewLayout.bandSeamWidth
        #expect(OverviewLayout.bandZones(for: wideBandWidth) == .withControls,
                "the fixture's own premise: the strip's own band width should be .withControls")
        #expect(OverviewLayout.bandZones(for: minWindowBandWidth) == .actOnly,
                "the fixture's own premise: the min window's own band width should be .actOnly")
        let minWindowPlan = OverviewLayout.bandZonePlan(bandWidth: minWindowBandWidth,
                                                        actionCount: decisionRuntime.frame.actions.count,
                                                        usableHeight: QuestionOptionsBand.usableStripHeight)
        #expect(minWindowPlan.actWidth == OverviewLayout.bandActFloorWidth && minWindowPlan.actions != nil,
                Comment(rawValue: "the fixture's own premise: band 628 with a real actions trailer should "
                        + "squeeze to bandActFloorWidth (\(OverviewLayout.bandActFloorWidth)) with the "
                        + "actions column present — got actWidth \(minWindowPlan.actWidth), actions "
                        + "\(String(describing: minWindowPlan.actions))"))

        // The ordinary sweep — both real zone shapes, a couple of usable
        // heights (full recipe and squeezed alike), reported minimum
        // width floors at ~0 either way.
        for bandWidth in [wideBandWidth, minWindowBandWidth] {
            for usableHeight in [QuestionOptionsBand.usableStripHeight, 149.0] {
                let band = DetailBand(runtime: decisionRuntime, width: bandWidth, usableHeight: usableHeight,
                                      dismissedStage: nil)
                let min = measuredMinimum(band)
                #expect(min.width <= 1,
                        Comment(rawValue: "a band built at \(bandWidth) pt wide, \(usableHeight) pt usable, "
                                + "reported a minimum width of \(min.width) pt — DetailBand should never "
                                + "demand width"))
            }
        }

        // The live bug's own exact shape: `width` stale and WIDE (1268,
        // the 1600-era band), the live proposal already narrower (628,
        // the 960-era one) — the reported size must yield to the smaller
        // live offer, not the stale internal arithmetic.
        let staleWideBand = DetailBand(runtime: decisionRuntime, width: wideBandWidth,
                                       usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        let sizeAtSmallerOffer = measured(staleWideBand, width: minWindowBandWidth)
        #expect(Double(sizeAtSmallerOffer.width) <= minWindowBandWidth,
                Comment(rawValue: "a band whose own `width` parameter (\(wideBandWidth) pt, stale) still says "
                        + "1600-era, measured at a genuinely smaller live proposal (\(minWindowBandWidth) pt), "
                        + "reported \(sizeAtSmallerOffer.width) pt — wider than what was actually offered, "
                        + "the exact live wedge (content minimum > window frame)"))
    }

    /// **NEW REQUIREMENT, pinned — the requirement, verbatim: "we need the full
    /// width of the band even on shorter heights, that is a requirement."**
    /// The interior is width-flexible by construction: the header's own
    /// `Spacer(minLength: 0)` and `columns(for:)`'s own `.frame(maxWidth:
    /// .infinity, alignment: .topLeading)` already spend whatever width
    /// the row is given rather than hugging a smaller natural size, so a
    /// squeezed HEIGHT alone should never narrow the band's own reported
    /// WIDTH — this is expected to already pass; the arbiter exists purely
    /// so it can never regress silently the way a future height-driven
    /// refactor could otherwise introduce a `.frame(maxWidth:)` that
    /// quietly stops being greedy.
    ///
    /// **REWRITTEN — the ORIGINAL version of this test was a TAUTOLOGY.** `measured(_:width:)` wraps its content in
    /// an exact `.frame(width:)` before reading `fittingSize` back — that
    /// pins the SAME axis this test was trying to prove something about, so
    /// `size.width == commandedWidth` held for ANY content whatsoever,
    /// proven or not (an empirical check: a bare 100pt-hugging
    /// child "measured" 1268 through that exact helper too). No amount of
    /// content actually collapsing to a sliver could ever have failed that
    /// assertion. Rewritten to probe the RENDERED subtree instead —
    /// `DetailBand.onRootFrameMeasured` (that property's own doc comment
    /// carries the same tautology finding), attached via `probingRootFrame`
    /// at the very END of `body`'s own modifier chain, after the width/
    /// height containment and `.clipped()` — and hosted with NO SwiftUI-side
    /// `.frame(width:)` at all: the `NSHostingView`'s own AppKit frame is
    /// the only thing proposing a size, the same relationship a real
    /// window's content region has to what it offers.
    ///
    /// **The requirement's own core:** a full commanded width (1268 pt —
    /// `DeckWindow.bandWidth`'s own arithmetic for a 1600 pt window, the
    /// same figure `detailBandNeverDemandsWidth` above reuses as its own
    /// "wide" sample) at a squeezed usable height (199 pt, under
    /// `bandMinimumHeight`), hosted at exactly that proposal — the probed
    /// rendered width must equal the commanded width EXACTLY.
    ///
    /// **The discrimination case — proves the probe follows REAL layout,
    /// not the commanded number.** The SAME band (its own `width` parameter
    /// still says 1268, unchanged) hosted inside a genuinely NARROWER
    /// proposal (960) must read back `<= 960` — `body`'s own outer
    /// `.frame(minWidth: 0, maxWidth: width)` containment means the band
    /// never demands more than a real host actually offers
    /// (`detailBandNeverDemandsWidth`'s own doc comment carries the
    /// identical live bug this containment closes). A probe that could not
    /// tell 1268 from 960 here would be exactly the tautology this rewrite
    /// exists to close — this is the case `DetailBand.yieldedHeaderFold`'s
    /// own doc comment now points at for "a real narrow-width band held
    /// accountable."
    @Test("the band fills its full commanded width even at a squeezed height — the requirement, pinned")
    func theBandFillsItsFullCommandedWidthEvenSqueezed() {
        let runtime = Self.worstCaseDecisionRuntime()
        guard runtime.frame.decisions.first?.suggestionLabels.isEmpty == false else {
            Issue.record("the worst-case fixture produced no suggestion, so nothing below is measured")
            return
        }
        let commandedWidth = 1268.0
        let usableHeight = 199.0
        #expect(OverviewLayout.bandSqueezed(usableHeight: usableHeight),
                "the fixture's own premise: this height should be squeezed")

        // The requirement's own core — hosted at the FULL commanded width,
        // no SwiftUI-side `.frame(width:)` anywhere in the way.
        var wideBand = DetailBand(runtime: runtime, width: commandedWidth, usableHeight: usableHeight,
                                  dismissedStage: nil)
        var wideFrame: CGRect?
        wideBand.onRootFrameMeasured = { wideFrame = $0 }
        let wideHost = NSHostingView(rootView: wideBand)
        wideHost.frame = NSRect(x: 0, y: 0, width: commandedWidth, height: usableHeight)
        wideHost.layoutSubtreeIfNeeded()

        guard let wideFrame else {
            Issue.record("the band's own root probe never fired at the full commanded width")
            return
        }
        #expect(Double(wideFrame.width) == commandedWidth,
                Comment(rawValue: "the band rendered \(wideFrame.width) pt wide against a \(commandedWidth) pt "
                        + "commanded width at a squeezed \(usableHeight) pt usable height — the band must fill "
                        + "the full commanded width EXACTLY, not merely fit within it"))

        // The discrimination case — the SAME band, the SAME `width`
        // parameter (1268, unchanged), hosted inside a genuinely narrower
        // proposal instead.
        var narrowBand = DetailBand(runtime: runtime, width: commandedWidth, usableHeight: usableHeight,
                                    dismissedStage: nil)
        var narrowFrame: CGRect?
        narrowBand.onRootFrameMeasured = { narrowFrame = $0 }
        let narrowHost = NSHostingView(rootView: narrowBand)
        narrowHost.frame = NSRect(x: 0, y: 0, width: 960, height: usableHeight)
        narrowHost.layoutSubtreeIfNeeded()

        guard let narrowFrame else {
            Issue.record("the band's own root probe never fired at the narrower hosting proposal")
            return
        }
        #expect(Double(narrowFrame.width) <= 960,
                Comment(rawValue: "the SAME band (commanded width 1268 unchanged) hosted inside a 960 pt "
                        + "proposal reported \(narrowFrame.width) pt wide — the probe should follow the real, "
                        + "narrower host, not the commanded width; a reading stuck at 1268 here would mean "
                        + "this test cannot actually tell a real regression from the commanded number"))
        #expect(Double(narrowFrame.width) < Double(wideFrame.width),
                Comment(rawValue: "the narrower hosting proposal's own reading (\(narrowFrame.width) pt) should "
                        + "measurably differ from the full commanded width's own reading (\(wideFrame.width) "
                        + "pt), proving the probe is sensitive to the actual host, not a constant echo of "
                        + "`width`"))
    }

    /// **The live bug that survived the first fix — reproduced on the running deck, AX-probed: open
    /// the band, close it again, then ask the window to resize smaller —
    /// it snaps back to EXACTLY the size the window was at when the band
    /// opened, every time, composition-history-dependent. The first `.frame(maxWidth:width, maxHeight:usableHeight)` containment
    /// bounds IDEAL — every test above this comment stayed green through
    /// the whole live incident — but says nothing about MINIMUM, and
    /// `.windowResizability(.contentSize)` enforces the window's resize
    /// floor from the content's MINIMUM, not its ideal.
    /// `measuredMinimum(_:)`'s own doc comment states the measurement
    /// investigation that found the number that actually moves;
    /// `detailBandNeverDemandsHeight` just above is this test's own
    /// clean, `.inspector`-artifact-free sibling — RETOLD since the
    /// deadlock-breaker: it used to prove `DetailBand` alone tracked
    /// `usableHeight` as its own composition-dependent minimum, which THIS
    /// test then showed `DeckWindow`'s own root raising to the constant
    /// floor regardless; now that `DetailBand` itself reports ~0
    /// unconditionally, the interior has nothing composition-dependent
    /// left to raise — this test's own claim is unweakened by that
    /// (`DeckWindow`'s outer `.frame(minWidth:minHeight:)` still has to
    /// raise SOMETHING, whether that something is a real sticky value or a
    /// flat 0, up to `DeckPrefs.minWindow`), but the sibling relationship
    /// changed from "same true fact, two lenses" to "the fix upstream made
    /// what this test raises trivially small before this test's own clamp
    /// ever has to do the interesting work."**
    ///
    /// **What "RED" looked like here, historically.** Before the ROOT fix
    /// (`DeckWindow.body`'s own outer `.frame(minWidth:minHeight:)`), this
    /// test's own two geometries did NOT both land on `DeckPrefs.minWindow`
    /// — measured (178, 81) regardless of which geometry, an
    /// `.inspector`-collapse-flattened reading rather than a real sticky
    /// one. The two RED signatures looked different (one flattened by a
    /// harness artifact, one genuinely sticky, back when `DetailBand`'s
    /// own interior still tracked `usableHeight` as its minimum) but
    /// asserted the SAME true fact either way — `DeckWindow`'s own root
    /// was not yet reporting the constant — and the SAME fix closes both:
    /// an outer `.frame(minWidth:minHeight:)` RAISES whatever the interior
    /// reports UP to the constant, regardless of what the interior reports.
    /// **Geometry C — the min window itself, band 628,
    /// where a real actions column now competes for width.** Neither
    /// Geometry A (the strip) nor B (the live 1439×548)
    /// nets a band width anywhere near `bandMinimumWidth` (628) —
    /// 1439×548 alone still leaves a 1107 pt band, comfortably
    /// `.withControls`. This third sample is what actually exercises the
    /// mandatory column's own tightest live territory through `DeckWindow`'s
    /// full composition, not merely through `DetailBand` directly the way
    /// `detailBandNeverDemandsWidth`'s own premise does.
    @Test("the enforced minimum is the constant floor, not the composition it happened to open at")
    func bandedDeckWindowMinimumIsTheConstantFloorRegardlessOfComposition() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard runtime.frame.decisions.first != nil else {
            Issue.record("the live-shape fixture produced no decision, so nothing below is measured")
            return
        }
        #expect(!runtime.frame.actions.isEmpty, "the fixture's own premise: real quick actions are offered")

        // Geometry A: the strip, banner down (419 — `usableStripHeight`).
        let atStrip = DeckWindow(runtime: runtime, layout: .row,
                                 fleetSize: CGSize(width: Self.stripWidth,
                                                   height: QuestionOptionsBand.usableStripHeight))
        #expect(atStrip.bandShownForTesting, "the fixture's own premise: the band composes at the strip")

        // Geometry B: the live numbers — the window
        // really was 1439×548 when the band-open reproduction stuck.
        let atLive = DeckWindow(runtime: runtime, layout: .row,
                                fleetSize: CGSize(width: 1439, height: 548))
        #expect(atLive.bandShownForTesting, "the fixture's own premise: the band composes at the live geometry")

        // Geometry C: the min window itself (960×249 usable) — band 628,
        // the mandatory column's own tightest reachable width, this
        // paragraph's own doc comment states why the other two never
        // reach it.
        let minWindowBandWidth = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth
            - OverviewLayout.bandSeamWidth
        let minWindowUsableHeight = 249.0
        let minWindowPlan = OverviewLayout.bandZonePlan(bandWidth: minWindowBandWidth,
                                                        actionCount: runtime.frame.actions.count,
                                                        usableHeight: minWindowUsableHeight)
        #expect(minWindowPlan.actWidth == OverviewLayout.bandActFloorWidth && minWindowPlan.actions != nil,
                Comment(rawValue: "the fixture's own premise: band 628 should squeeze to bandActFloorWidth "
                        + "(\(OverviewLayout.bandActFloorWidth)) with the actions column present — got "
                        + "actWidth \(minWindowPlan.actWidth), actions \(String(describing: minWindowPlan.actions))"))
        let atMinWindow = DeckWindow(runtime: runtime, layout: .row,
                                     fleetSize: CGSize(width: Double(DeckPrefs.minWindow.width),
                                                       height: minWindowUsableHeight))
        #expect(atMinWindow.bandShownForTesting, "the fixture's own premise: the band composes at the min window")

        let minAtStrip = measuredMinimum(atStrip)
        let minAtLive = measuredMinimum(atLive)
        let minAtMinWindow = measuredMinimum(atMinWindow)
        let expected = CGSize(width: Double(DeckPrefs.minWindow.width), height: Double(DeckPrefs.minWindow.height))

        #expect(minAtStrip == expected,
                Comment(rawValue: "the strip geometry's own enforced minimum measured \(minAtStrip), not the "
                        + "constant floor \(expected) — DeckPrefs.minWindow"))
        #expect(minAtLive == expected,
                Comment(rawValue: "the live (1439×548) geometry's own enforced minimum measured \(minAtLive), "
                        + "not the constant floor \(expected) — this is the live reproduction, "
                        + "measured"))
        #expect(minAtMinWindow == expected,
                Comment(rawValue: "the min-window geometry's own enforced minimum measured \(minAtMinWindow), "
                        + "not the constant floor \(expected) — the mandatory actions column's own tightest "
                        + "live territory"))
        #expect(minAtStrip == minAtLive && minAtLive == minAtMinWindow,
                Comment(rawValue: "sticky-min signature: different compositions reported DIFFERENT minimums "
                        + "(\(minAtStrip), \(minAtLive), \(minAtMinWindow)) — the enforced floor is still "
                        + "tracking the composition it happened to open at, not a fixed constant"))
    }

    /// **FINDING A, at the `DeckWindow` altitude — the SAME constant-floor
    /// property the test above holds `DetailBand`'s own composition to,
    /// now at a TIGHT `usableHeight` neither of that test's own two
    /// geometries reached.** Both of `bandedDeckWindowMinimumIsTheConstantFloorRegardlessOfComposition`'s
    /// own samples (419 and 548) sit well above the fleet card's own
    /// natural demand, so neither actually exercised the fleet slot's own
    /// deadlock — this does, at the live figures:
    /// banner-up usable ≈185, where the bug used to floor the window at
    /// ~302 pt total instead of reaching the root clamp (270).
    ///
    /// **Investigated directly, and stated honestly: this specific
    /// assertion (the WHOLE `DeckWindow`'s own reported minimum) does
    /// NOT discriminate fixed from unfixed in this headless harness — it
    /// reports the constant floor either way, tried by hand.** The live
    /// bug's own mechanism is an ITERATIVE one: a real window's geometry
    /// probe (`onGeometryChange`) re-fires every time AppKit resolves a
    /// new candidate size, feeding `fleetSize.height` back into
    /// `promptLineLimit`, which feeds the card's own natural height back
    /// into what the probe next reports — a genuine fixed-point search
    /// converging near where the card's own demand equals the room it
    /// was offered. `measuredMinimum(_:)`'s own technique probes AppKit's
    /// minSize ONCE, against a `fleetSize` baked in as plain DATA at
    /// construction time (`DeckWindow`'s own doc comment on `layout`/
    /// `fleetSize`: "a test seam... a real window overwrites both within
    /// one `onGeometryChange` regardless") — there is no re-firing loop
    /// for a single-pass probe to iterate, so the live convergence this
    /// bug depends on never happens here. This is the same category of
    /// gap `actionBlockNoticeAndDecisionBarStackDirectlyAtATallBudget`'s
    /// own doc comment already admits for the Group→VStack fix — named
    /// rather than hidden behind an assertion that happens to pass either
    /// way. `bandedFleetSlotBareMinimumIsReducedByTheWrapper` (below) is
    /// the one arbiter in this pair that DOES measurably discriminate —
    /// this one stays as a real, if currently non-discriminating,
    /// regression guard: the constant floor must hold here regardless,
    /// and a future change that broke it (in EITHER direction — a smaller
    /// OR a differently-composed interior) would still be caught the
    /// moment this headless technique became sensitive enough to see it.
    @Test("the banded DeckWindow reaches the root clamp at the reachable, banner-up-tight geometry too")
    func bandedDeckWindowFleetSlotReachesTheRootClampAtTheReachableFloor() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard runtime.frame.selection != nil else {
            Issue.record("the live-shape fixture selected nothing, so nothing below is measured")
            return
        }

        // 185 pt usable — the live figure for a
        // banner-up window sitting at the (bugged) ~302 pt total floor.
        let atTightGeometry = DeckWindow(runtime: runtime, layout: .row,
                                         fleetSize: CGSize(width: 1920, height: 185))
        #expect(atTightGeometry.bandShownForTesting,
                "the fixture's own premise: the band should still compose at this tight a geometry")

        let min = measuredMinimum(atTightGeometry)
        let expected = CGSize(width: Double(DeckPrefs.minWindow.width), height: Double(DeckPrefs.minWindow.height))
        #expect(min == expected,
                Comment(rawValue: "the banner-up-tight geometry's own enforced minimum measured \(min), not "
                        + "the constant floor \(expected) — the fleet slot's own natural card height may still "
                        + "be propagating as a window-level demand"))
    }

    /// **The arbiter that DOES measurably discriminate — `SessionOverview`
    /// alone, wrapped exactly the way `DeckWindow.body` wraps it versus
    /// bare.** Investigated directly (this doc comment's own neighbour
    /// states why the `DeckWindow`-level assertion above cannot): at the
    /// the live figure (185 pt usable), the BARE fleet slot
    /// — `SessionOverview` with no `.frame(minHeight: 0)` at all — reports
    /// a real, measured, NON-ZERO minimum height (34 pt in this harness);
    /// wrapped exactly as `DeckWindow.body` now wraps it, the SAME
    /// composition reports 0. 34 pt is far short of the live bug's own
    /// ~180 pt effective demand (this headless technique's own single-pass
    /// limitation, that neighbouring doc comment states in full) — but it
    /// is a REAL, non-tautological difference: proof that SOME interior
    /// demand genuinely propagates through the bare slot and that the
    /// wrapper genuinely defeats it, not merely a `.frame(minHeight: 0)`
    /// reporting 0 in isolation regardless of what it wraps (which would
    /// be true of ANY content and would prove nothing about production's
    /// own wiring).
    @Test("the bare fleet slot's own nonzero minimum is what the DeckWindow.body wrapper measurably defeats")
    func bandedFleetSlotBareMinimumIsReducedByTheWrapper() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard runtime.frame.selection != nil else {
            Issue.record("the live-shape fixture selected nothing, so nothing below is measured")
            return
        }
        let bareOverview = SessionOverview(runtime: runtime, layout: .row,
                                           fleetSize: CGSize(width: OverviewLayout.bandFleetWidth, height: 185),
                                           banded: true)
        let bareMin = measuredMinimum(bareOverview)
        // BOTH frames production actually composes — `DeckWindow.body`'s
        // own width frame (`.frame(width: banded ? bandFleetWidth : nil)`)
        // AND its `minHeight: 0` twin, not the height frame alone. An earlier draft of this test wrapped with
        // only the second, which was not literally what `DeckWindow.body`
        // does, even though it happened not to change the reading here.
        let wrappedMin = measuredMinimum(
            bareOverview.frame(width: OverviewLayout.bandFleetWidth).frame(minHeight: 0, alignment: .top))

        #expect(bareMin.height > 1,
                Comment(rawValue: "the BARE fleet slot reported a minimum height of \(bareMin.height) pt — "
                        + "expected a real, nonzero demand here (this test's own premise: there IS something "
                        + "for the wrapper to defeat); if this ever reads ~0 on its own, the wrapper may have "
                        + "stopped being necessary, which is worth knowing, not silently losing coverage of"))
        #expect(wrappedMin.height <= 1,
                Comment(rawValue: "wrapped exactly as `DeckWindow.body` wraps it, the fleet slot still "
                        + "reported a minimum height of \(wrappedMin.height) pt — the wrapper should floor it "
                        + "at ~0"))
        #expect(wrappedMin.height < bareMin.height,
                Comment(rawValue: "the wrapper (\(wrappedMin.height) pt) should measurably reduce the bare "
                        + "slot's own reported minimum (\(bareMin.height) pt), proving it defeats a real "
                        + "demand rather than merely asserting zero in isolation"))
    }

    /// **`Ticks`' own twin to the arbiter above — the fourth deadlock face, `DeckWindow.body`'s doc comment on the
    /// `Ticks` composition states the live signature this closes.** A bare
    /// `Ticks`, at 20 off-viewport needs-you marks — a genuinely busy
    /// fleet's own shape, not a synthetic worst case invented for this
    /// test alone — reports a REAL, measured, NON-ZERO minimum height;
    /// wrapped exactly as `DeckWindow.body` now wraps it (`.frame(minHeight:
    /// 0, maxHeight: .infinity, alignment: .center).clipped()`), the SAME
    /// composition reports ~0 — the same non-tautological proof
    /// `bandedFleetSlotBareMinimumIsReducedByTheWrapper` establishes for
    /// the fleet slot, one seam over, using the identical
    /// `measuredMinimum(_:)` technique and carrying the identical honest
    /// caveat: this single-pass harness reads whatever AppKit's own
    /// Auto-Layout resolves for a `VStack` of `n` fixed capsules in ONE
    /// pass, which is not a claim that it reproduces the live bug's own
    /// iterative convergence (`bandedFleetSlotBareMinimumIsReducedByTheWrapper`'s
    /// own doc comment states that limitation in full) — what this proves
    /// is that a real, nonzero demand exists here and that the wrapper
    /// genuinely defeats it, not merely that `.frame(minHeight: 0)` reports
    /// zero in isolation regardless of what it wraps.
    @Test("the bare Ticks stack's own nonzero minimum is what DeckWindow.body's wrapper measurably defeats")
    func theTicksSlotBareMinimumIsReducedByTheWrapper() {
        let marks = (0 ..< 20).map { i in
            LaneView(session: SessionID("needs-you-\(i)"), state: .needsYou, isExpanded: false,
                     contextPercent: nil, sources: [:])
        }
        let bareTicks = Ticks(lanes: marks, selection: nil)
        let bareMin = measuredMinimum(bareTicks)
        let wrappedMin = measuredMinimum(
            bareTicks.frame(minHeight: 0, maxHeight: .infinity, alignment: .center).clipped())

        #expect(bareMin.height > 1,
                Comment(rawValue: "the BARE Ticks stack reported a minimum height of \(bareMin.height) pt at "
                        + "20 marks — expected a real, nonzero demand here (this test's own premise: there IS "
                        + "something for the wrapper to defeat); if this ever reads ~0 on its own, the wrapper "
                        + "may have stopped being necessary, which is worth knowing, not silently losing "
                        + "coverage of"))
        #expect(wrappedMin.height <= 1,
                Comment(rawValue: "wrapped exactly as `DeckWindow.body` wraps it, the Ticks stack still "
                        + "reported a minimum height of \(wrappedMin.height) pt — the wrapper should floor it "
                        + "at ~0"))
        #expect(wrappedMin.height < bareMin.height,
                Comment(rawValue: "the wrapper (\(wrappedMin.height) pt) should measurably reduce the bare "
                        + "stack's own reported minimum (\(bareMin.height) pt), proving it defeats a real "
                        + "demand rather than merely asserting zero in isolation"))
    }

    /// **The below-min interior — the "does the floor itself hold up" check.** At `DeckPrefs.minWindow` (960×270), the
    /// content region is 249 pt tall (270 − 21 statusline — no titlebar to
    /// subtract, since `DeckPrefs.minWindow`'s own height is a CONTENT
    /// height already, an earlier draft of this comment double-counted a
    /// 40 pt titlebar that was never there) — under
    /// `OverviewLayout.bandMinimumHeight` (358), so
    /// this used to be the one reachable place `presentation(...)` fell
    /// back to `.inspector`. "Commit to band always" retires that fallback
    /// — a selection here now composes the SQUEEZED band instead
    /// (`OverviewLayout.bandSqueezed(usableHeight:)`), and `.fleetOnly`
    /// (nothing selected) is still the other reachable state at this
    /// floor. Both must ALSO report exactly the constant minimum — the fix
    /// is at `DeckWindow`'s own root, above every layout branch, so it has
    /// no reason to differ by branch, but "no reason to differ" is an
    /// assumption worth a measurement rather than a trust.
    ///
    /// **RETOLD — `squeezedBand`, below, is band 628 at its own
    /// tightest reachable height (209, well under `bandMinimumHeight`
    /// 358), and the runtime's own DEFAULT prefs (`DeckPrefs.firstRun`,
    /// `DeckPrefs()`'s own default `quickActions: QuickAction.shipped`,
    /// never overridden by a `.prefsChanged` this fixture never sends)
    /// mean a REAL actions column competes for that same width — the
    /// mandatory-column redesign's own new territory, at its single
    /// tightest live sample in this whole file.** Asserted as this test's
    /// own premise below, not merely assumed.
    @Test("the fleet-only and squeezed-band compositions also report the constant minimum below the band's own floor")
    func belowBandFloorCompositionsAlsoReportTheConstantMinimum() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("s1"), at: at(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "alpha"))),
        ]))
        let expected = CGSize(width: Double(DeckPrefs.minWindow.width), height: Double(DeckPrefs.minWindow.height))
        let belowFloorHeight = 209.0

        // `.fleetOnly` — nothing selected.
        let fleetOnly = DeckWindow(runtime: runtime, layout: .row,
                                   fleetSize: CGSize(width: Double(DeckPrefs.minWindow.width),
                                                     height: belowFloorHeight))
        #expect(!fleetOnly.bandShownForTesting, "the fixture's own premise: nothing is selected")
        #expect(measuredMinimum(fleetOnly) == expected,
                Comment(rawValue: "fleet-only at the window's own legal floor measured \(measuredMinimum(fleetOnly)) "
                        + "— not the constant \(expected)"))

        // Selected, below the band's own height floor — squeezed, not a
        // fallback to the classic sidebar any more.
        runtime.select(SessionID("alpha"))
        #expect(!runtime.frame.actions.isEmpty,
                "the fixture's own premise: the default prefs should offer real quick actions here")
        let minWindowBandWidth = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth
            - OverviewLayout.bandSeamWidth
        let squeezedPlan = OverviewLayout.bandZonePlan(bandWidth: minWindowBandWidth,
                                                        actionCount: runtime.frame.actions.count,
                                                        usableHeight: belowFloorHeight)
        #expect(squeezedPlan.actWidth == OverviewLayout.bandActFloorWidth && squeezedPlan.actions != nil,
                Comment(rawValue: "the fixture's own premise: band 628 at 209 pt usable, with real actions "
                        + "offered, should squeeze to bandActFloorWidth "
                        + "(\(OverviewLayout.bandActFloorWidth)) with the actions column still present — got "
                        + "actWidth \(squeezedPlan.actWidth), actions \(String(describing: squeezedPlan.actions))"))

        let squeezedBand = DeckWindow(runtime: runtime, layout: .row,
                                      fleetSize: CGSize(width: Double(DeckPrefs.minWindow.width),
                                                        height: belowFloorHeight))
        #expect(squeezedBand.bandShownForTesting,
                "the fixture's own premise: below bandMinimumHeight, selection should still compose the band, squeezed")
        #expect(measuredMinimum(squeezedBand) == expected,
                Comment(rawValue: "the squeezed-band composition at the window's own legal floor measured "
                        + "\(measuredMinimum(squeezedBand)) — not the constant \(expected)"))
    }

    /// **RETOLD — `.inspector`'s own pre-existing width floor no longer
    /// has a real routing path to exercise it, so this test's own claim
    /// moves to the surface that replaced it.** Historically: `DeckWindow
    /// .swift`'s own comment on `.inspectorColumnWidth` documented, before
    /// this feature existed, that raising `inspectorMinWidth` (380)
    /// "raises more than the column: `DeckScene`'s `.windowResizability
    /// (.contentSize)` folds it into the window's own minimum width WHILE
    /// the inspector is open" — a known, pre-band fold-in, the same CLASS
    /// of composition-dependent minimum the band's own bug was, just
    /// smaller (380, not 1439) and never reported as a live incident.
    /// `.grid` no longer opens `.inspector` for any selection
    /// (`OverviewLayout.presentation(for:hasSelection:usableWidth:
    /// usableHeight:)`'s own doc comment states why) — it opens the BAND
    /// now, exactly as `.row` does — so this measures THAT: `.grid`, with
    /// a real decision selected, at a window narrower than the inspector's
    /// own former ideal, proving the SAME root-level fix generalises to
    /// `.grid`'s own band composition too, not only `.row`'s.
    @Test("the root minimum clamp also defuses grid's own band composition at a narrow window")
    func theRootClampDefusesGridsOwnBandCompositionToo() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard runtime.frame.decisions.first != nil else {
            Issue.record("the live-shape fixture produced no decision, so nothing below is measured")
            return
        }
        let window = DeckWindow(runtime: runtime, layout: .grid,
                                fleetSize: CGSize(width: 900, height: 900))
        #expect(window.bandShownForTesting,
                "the fixture's own premise: .grid with a selection should open the band now, not .inspector")
        let expected = CGSize(width: Double(DeckPrefs.minWindow.width), height: Double(DeckPrefs.minWindow.height))
        let min = measuredMinimum(window)
        #expect(min == expected,
                Comment(rawValue: "the grid-selected, banded composition's own enforced minimum measured "
                        + "\(min) — not the constant \(expected)"))
    }

    /// **Requirement 4's own regression net — the QuickActionBar clipping
    /// bug that motivated it, made unable to recur silently for the view
    /// that replaced it.** `columnsHeightBudget`'s own doc comment
    /// (`DetailBand.swift`) states the mechanism: the act/controls/actions
    /// row is capped BEFORE any of the three is placed, reserving each
    /// one's own share by construction. This is the render-level proof
    /// that reservation actually holds for the live-recorded shape, at
    /// every budget the strip's own two banner states offer — the same
    /// `onGeometryChange` probe technique `controlsColumnRendersAtItsOwnDeclaredWidth`
    /// already established, reading the actions column's own frame back
    /// rather than trusting the arithmetic that is SUPPOSED to produce it
    /// — AND its own declared width, at every shape the column can draw
    /// (`OverviewLayout.bandZonePlan`'s own doc comment carries the
    /// ladder: 230 narrow, 468 wide, off the SAME `bandActionsRowCap`
    /// break the retired `bandActionsColumnWidth(actionCount:)` used to
    /// state alone).
    ///
    /// **Bands 628 and 922 — geometries this probe never
    /// reached before, because the column never rendered there before.**
    /// previously, `DetailBand` called the legacy `bandActionsColumn`,
    /// which required `bandControlsShown` outright; at band 628 (the min
    /// window's own `.actOnly` width) Controls never shows by WIDTH alone,
    /// and at band 922 (the narrower desktop window's own width, still
    /// `.actOnly`-adjacent by the OLD width-only routing this probe's own
    /// fixtures predate) the actions column answered nil either way — so
    /// this test's own samples, all at the strip's full 1588, never
    /// exercised the mandatory column's own narrower shapes at all. Both
    /// squeeze to the narrow, single sub-column width (230) regardless of
    /// action count — `bandZonePlanAtEveryRealGeometry`
    /// (`OverviewLayoutTests`) pins the identical pure fact; this is that
    /// same shape's own live, hosted, clip-checked proof.
    ///
    /// **No more "or yields cleanly" branch — the column drops by WIDTH
    /// now, never by height (`DetailBand.yieldedHeaderFold`'s own doc
    /// comment states the retirement in full).** At every band width this
    /// test samples, the column is ALWAYS present, so the probe is
    /// expected to fire every time — a genuinely simpler contract than the
    /// pinned bar's own row-yield story ever was.
    ///
    /// **Retuned for the row-recipe flex — a second assertion, a FLOOR
    /// tying the HOSTED render to the PURE frame arithmetic, not just "did
    /// it clip."** `bandActionsRowHeight`'s own row heights are imposed
    /// via an EXACT `.frame(height:)` (`QuickActionsColumn
    /// .column(_:rowHeight:)`), never a minimum — an exact frame reports
    /// precisely what it is told, unconditionally, whatever the glass
    /// painted inside it does. That means the CARD's own total measured
    /// height (`bandQuickActionsChrome` + rows × frame height + gaps,
    /// plain `VStack` arithmetic) can never be INFLATED by the glass —
    /// frames compose exactly, always; there is no "glass minimum fighting
    /// the frame" failure mode for a FRAME-level measurement like this one
    /// to catch, because the glass overdrawing past its own frame's edges
    /// never changes what that frame reports upward. That risk is real but
    /// separate, and lives entirely on the glass itself — `thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight`
    /// is the arbiter for it, probing the button's OWN geometry directly
    /// rather than a frame that could never disagree with what it was told.
    ///
    /// **A LOWER bound (`>=`), not `==` here — investigated live, not
    /// assumed — because a genuinely SHORTER total is the one direction
    /// frame arithmetic can actually produce on its own, and a TALLER one
    /// can too, for an entirely different, legitimate reason.** The
    /// three-action sample measures 24 pt TALLER than `bandQuickActionsChrome
    /// + rowCount × h + (rowCount − 1) × actionGridSpacing` predicts, and
    /// this is NOT a bug: `QuickActionsColumn` sits beside the act zone and
    /// Controls in `columns(for:)`'s own `HStack`, each wrapped in `.frame
    /// (maxHeight: .infinity, alignment: .topLeading)` — the mechanism that
    /// lets a SHORTER column stretch to the row's own resolved height
    /// (driven by whichever column is tallest) rather than leaving a gap,
    /// and `QuickActionsColumn`'s own trailing `Spacer(minLength: 0)` (this
    /// type's own "LOAD-BEARING, not decorative" comment) is exactly what
    /// absorbs that extra proposed height. At three actions the act zone's
    /// own needs-you content is taller than the actions card's own row
    /// arithmetic; at ten it is not, which is why that sample's own
    /// measured height lands EXACTLY on the pure formula with room to
    /// spare for neither direction. A `>=` floor still catches real
    /// shrinkage (rows compressed below what `bandActionsRowHeight` says
    /// they should be, or the wiring silently dropping a row's own height)
    /// — there is no corresponding "too tall" failure this frame-level
    /// test needs to guard, since frame arithmetic cannot inflate itself
    /// and sibling stretch is the only other thing that can grow it,
    /// which is legitimate by design, not a defect.
    @Test("the Quick Actions column's own measured frame never exceeds the usable height it was given, at its own declared width",
          arguments: [
            // The strip, full band width (1588) — the column's own two
            // shapes, narrow and wide.
            (bandWidth: 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 3, expectedWidth: 230.0),
            (bandWidth: 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 10, expectedWidth: 468.0),
            (bandWidth: 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight - 60, actionCount: 3, expectedWidth: 230.0),
            (bandWidth: 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight - 60, actionCount: 10, expectedWidth: 468.0),
            // Band 628 — the min window's own band width.
            // The mandatory column squeezes to the narrow shape here
            // regardless of action count (`bandZonePlanAtEveryRealGeometry`,
            // `OverviewLayoutTests`, pins the identical pure fact) —
            // `actWidth` lands at `bandActFloorWidth` (350), too narrow for
            // the wide entry to ever clear `bandActMinWidth` (620).
            (bandWidth: 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 3, expectedWidth: 230.0),
            (bandWidth: 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 10, expectedWidth: 230.0),
            (bandWidth: 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight - 60, actionCount: 3, expectedWidth: 230.0),
            (bandWidth: 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight - 60, actionCount: 10, expectedWidth: 230.0),
            // Band 922 — the narrower desktop window's own band width.
            // Controls folds (freeing its own share) so the
            // narrow column can keep `bandActMinWidth` (620) — the SAME
            // squeeze `theActionsColumnSurvivesAtTheDesktopWindow`
            // (`OverviewLayoutTests`) pins pure, at 3 and 10 actions both.
            (bandWidth: 1254.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 3, expectedWidth: 230.0),
            (bandWidth: 1254.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight, actionCount: 10, expectedWidth: 230.0),
            (bandWidth: 1254.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight - 60, actionCount: 3, expectedWidth: 230.0),
            (bandWidth: 1254.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth,
             usableHeight: QuestionOptionsBand.usableStripHeight - 60, actionCount: 10, expectedWidth: 230.0),
          ])
    func theQuickActionsColumnNeverClipsInTheLiveRecordedShape(
        _ sample: (bandWidth: Double, usableHeight: Double, actionCount: Int, expectedWidth: Double)
    ) {
        let runtime = Self.liveNeedsYouBandShapeRuntime(quickActions: Self.manyActions(sample.actionCount))
        #expect(!runtime.frame.actions.isEmpty, "the fixture's own premise: the actions column has something to pin")
        let bandWidth = sample.bandWidth
        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: sample.usableHeight,
                              dismissedStage: nil)
        var actionsFrame: CGRect?
        band.onQuickActionsFrameMeasured = { actionsFrame = $0 }
        _ = measured(band, width: bandWidth)

        guard let actionsFrame else {
            Issue.record("the actions column's own geometry probe never fired — it may not be rendering at all")
            return
        }
        #expect(actionsFrame.height > 0,
                "the actions column measured zero height — that is not \"unclipped\", it is invisible")
        #expect(actionsFrame.maxY <= sample.usableHeight,
                Comment(rawValue: "the actions column's own frame reaches \(actionsFrame.maxY) pt against a "
                        + "\(sample.usableHeight) pt budget (origin \(actionsFrame.origin), height "
                        + "\(actionsFrame.height)) — it is being pushed past the visible band and clipped"))
        #expect(Double(actionsFrame.width) == sample.expectedWidth,
                Comment(rawValue: "the actions column rendered \(actionsFrame.width) pt wide at "
                        + "\(sample.actionCount) actions — expected the declared \(sample.expectedWidth) pt"))

        let columnBudget = sample.usableHeight - OverviewLayout.bandHeaderHeight
        let rowCount = min(sample.actionCount, OverviewLayout.bandActionsRowCap)
        let rowHeight = OverviewLayout.bandActionsRowHeight(columnBudget: columnBudget, rowCount: rowCount)
        let expectedHeight = OverviewLayout.bandQuickActionsChrome + Double(rowCount) * rowHeight
            + Double(rowCount - 1) * OverviewLayout.actionGridSpacing
        #expect(Double(actionsFrame.height) >= expectedHeight - 1,
                Comment(rawValue: "the actions column measured \(actionsFrame.height) pt tall — expected AT "
                        + "LEAST \(expectedHeight) pt (chrome \(OverviewLayout.bandQuickActionsChrome) + "
                        + "\(rowCount) rows at \(rowHeight) pt + \(rowCount - 1) gaps of "
                        + "\(OverviewLayout.actionGridSpacing) pt), the floor bandActionsRowHeight's own pure "
                        + "arithmetic guarantees for this budget and row count — measuring SHORTER means rows "
                        + "compressed below what the pure rule promised"))
    }

    /// **`OverviewLayout.bandHeaderHeight`'s own live arbiter, and
    /// `AutoContinueToggle`'s own — figures that do not vary with
    /// `usableHeight` at all (both are fixed-content views), so one sample
    /// each is honest rather than a slope needing two.** The pinned
    /// action bar's own arbiter, once the third check bundled in here,
    /// moved to `quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant`
    /// below — a different view now (`QuickActionsColumn`, not the retired
    /// bottom-pinned `QuickActionBar`), worth its own test rather than a
    /// third check bolted onto this one.
    @Test("the band's header and the auto-continue toggle match their own named, measured heights")
    func bandHeaderAndAutoContinueMatchTheirNamedHeights() {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let header = measured(DetailBand(runtime: runtime, width: bandWidth, usableHeight: 419,
                                         dismissedStage: nil).header, width: bandWidth)
        // `Double(header.height)`, not a bare `==` — `CGFloat == Double` is
        // the real, surprising `#expect` macro trap `bandFitsTheStripWorstCaseDecision`'s
        // own comment already names: the plain operator returns `true`,
        // but swift-testing's expression capture for a mixed-type `==`
        // reports the expectation FAILED anyway.
        #expect(Double(header.height) == OverviewLayout.bandHeaderHeight,
                Comment(rawValue: "the header measured \(header.height) pt live — "
                        + "OverviewLayout.bandHeaderHeight (\(OverviewLayout.bandHeaderHeight) pt) is stale"))

        let actWidth = bandWidth - 2 * OverviewLayout.bandColumnsHorizontalPadding
            - 2 * (OverviewLayout.bandSideColumnWidth + OverviewLayout.bandZoneGutter)
        let autoContinue = measured(AutoContinueToggle(runtime: runtime), width: actWidth)
        #expect(Double(autoContinue.height) == OverviewLayout.bandAutoContinueHeight,
                Comment(rawValue: "AutoContinueToggle measured \(autoContinue.height) pt live — "
                        + "OverviewLayout.bandAutoContinueHeight (\(OverviewLayout.bandAutoContinueHeight) pt) "
                        + "is stale"))
    }

    /// A minimal runtime with exactly one lane, "alpha," selected — no
    /// hold, no question, nothing this test does not need. `contextPercent`
    /// nil leaves the lane genuinely UNFED (the empty-slot rule's own
    /// `nil`, never a synthetic `0`); a real value feeds it through a
    /// genuine `.statusline` event, the same wire path production reads,
    /// not a hand-built `LaneView`.
    private func minimalSelectedRuntime(contextPercent: Int? = nil) -> DeckRuntime {
        let t = { (ms: Int64) in Instant(sinceStart: Millis(ms)) }
        var events: [DeckEvent] = [
            .hook(HookEvent(id: EventID("s1"), at: t(0), kind: .sessionStart,
                            session: SessionID("alpha"), cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent,
                            host: HostAddress(workspace: "w", surface: "s"))),
            .sessionSelected(SessionID("alpha"), at: t(20)),
        ]
        if let contextPercent {
            events.append(.statusline(
                StatuslinePayload(session: SessionID("alpha"), contextPercent: .value(contextPercent),
                                  costUSD: .absent, model: nil, version: nil),
                at: t(30), id: EventID("sl1")))
        }
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    /// **The band header's own big-number readout — renders exactly when
    /// the selected lane has a fed ctx reading, never a placeholder for an
    /// absent one.** `DetailBand.header`'s own doc comment states the
    /// amended placement (beside the collapse button) and the empty-slot
    /// rule this test holds to a live render: a WIDTH contrast, the same
    /// technique `theHeaderFoldAppearsExactlyWhenTheColumnDrops` already
    /// uses to prove an optional leading element is genuinely present or
    /// genuinely absent, since two renders at the SAME fixed width both
    /// simply fill it and only the UNCONSTRAINED width tells the two
    /// shapes apart.
    @Test("the band header shows the selected session's own ctx reading exactly when it has one")
    func headerShowsCtxExactlyWhenFed() {
        let fed = minimalSelectedRuntime(contextPercent: 63)
        let unfed = minimalSelectedRuntime(contextPercent: nil)
        #expect(fed.frame.lanes.first?.contextPercent == 63,
                "the fixture's own premise: a genuinely fed reading")
        #expect(unfed.frame.lanes.first?.contextPercent == nil,
                "the fixture's own premise: a genuinely unfed reading, never a synthetic 0")

        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let fedHeader = DetailBand(runtime: fed, width: bandWidth, usableHeight: 419, dismissedStage: nil).header
        let unfedHeader = DetailBand(runtime: unfed, width: bandWidth, usableHeight: 419, dismissedStage: nil).header

        let fedWidth = measuredWidth(fedHeader, height: OverviewLayout.bandHeaderHeight).width
        let unfedWidth = measuredWidth(unfedHeader, height: OverviewLayout.bandHeaderHeight).width
        #expect(Double(fedWidth) > Double(unfedWidth),
                Comment(rawValue: "a fed ctx reading measured \(fedWidth) pt wide, unconstrained, against an "
                        + "absent one's \(unfedWidth) pt — the reading is either always drawing or never "
                        + "drawing, not conditionally on whether the lane actually has one"))

        // And it does not grow the header at the strip's own fixed width —
        // `header`'s own doc comment already measured this at "ctx:100%";
        // this confirms it again at a real, fed percent through the real
        // render rather than trusting the isolated probe alone.
        let fedHeight = measured(fedHeader, width: bandWidth)
        #expect(Double(fedHeight.height) == OverviewLayout.bandHeaderHeight,
                Comment(rawValue: "the header with a fed ctx reading measured \(fedHeight.height) pt tall — "
                        + "expected \(OverviewLayout.bandHeaderHeight), unchanged"))
    }

    /// **`OverviewLayout.bandQuickActionsNaturalHeight`'s own live arbiter
    /// — hosted directly, not through `DetailBand`, the same discipline
    /// `controlsZoneNaturalHeightMatchesItsOwnMeasuredConstant` already
    /// holds `controlsZone(for:budget:)` to.** Ten actions
    /// (`QuickAction.maxOffered`) at `bandActionsWideColumnWidth` (468) —
    /// the widest shape, and, since every sub-column caps at
    /// `bandActionsRowCap` (5) rows regardless of how many actions past
    /// five there are, also the TALLEST (`bandQuickActionsNaturalHeight`'s
    /// own doc comment states why) — at whichever `budget` makes
    /// `bandActionsRowHeight` answer the FLOOR (`TouchTarget.minimum`, 44),
    /// which `bandQuickActionsNaturalHeight`'s own updated doc comment now
    /// states plainly is the ONE case 301 still measures, since rows FLEX
    /// above it everywhere the budget leaves room.
    ///
    /// **The budget is not merely "generous" any more — a generous one
    /// would flex every row to `actionPillHeight` (64) and measure 401, not
    /// 301, silently retuning this constant to the wrong case.**
    /// `bandMinimumHeight − bandHeaderHeight` (the routing floor's own
    /// tightest live `columnBudget`) is what genuinely produces the floor
    /// answer at `bandActionsRowCap` rows — asserted as this test's own
    /// PREMISE below, not merely assumed, so a future retune that swaps in
    /// a more generous budget fails loudly on the premise rather than
    /// quietly measuring a flexed height and still passing by accident.
    @Test("the Quick Actions column's own full natural height matches OverviewLayout.bandQuickActionsNaturalHeight, at the FLOOR case bandActionsRowHeight itself produces")
    func quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant() {
        let runtime = Self.worstCaseDecisionRuntime(quickActions: Self.manyActions(10))
        #expect(runtime.frame.actions.count == 10, "the fixture's own premise: ten offered actions")

        let floorBudget = OverviewLayout.bandMinimumHeight - OverviewLayout.bandHeaderHeight
        let floorRowHeight = OverviewLayout.bandActionsRowHeight(columnBudget: floorBudget,
                                                                  rowCount: OverviewLayout.bandActionsRowCap)
        #expect(floorRowHeight == TouchTarget.minimum,
                Comment(rawValue: "this test's own premise: floorBudget (\(floorBudget)) must make "
                        + "bandActionsRowHeight answer the floor (\(TouchTarget.minimum)) at "
                        + "bandActionsRowCap rows — got \(floorRowHeight); if this fails, the budget below "
                        + "is no longer the floor case and 301 is being measured against the wrong shape"))

        // The wide, two-sub-column shape at the row cap — the plan a real
        // `bandZonePlan` would hand this geometry (ten actions, a floor
        // this generous width comfortably clears): `OverviewLayout
        // .BandActionsPlan(columnWidth: bandActionsWideColumnWidth,
        // subColumns: 2, rows: bandActionsRowCap)`.
        let plan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandActionsWideColumnWidth,
                                                  subColumns: 2, rows: OverviewLayout.bandActionsRowCap)
        let size = measured(QuickActionsColumn(runtime: runtime, budget: floorBudget, plan: plan),
                            width: OverviewLayout.bandActionsWideColumnWidth)
        #expect(abs(Double(size.height) - OverviewLayout.bandQuickActionsNaturalHeight) < 1,
                Comment(rawValue: "the Quick Actions column's own full natural height measured \(size.height) "
                        + "pt against a declared \(OverviewLayout.bandQuickActionsNaturalHeight) pt — retune "
                        + "the constant to match"))
    }

    /// **The narrow-pair fix's own live arbiter — the ONE shape that never
    /// had a render-level test before this arc, because `bandZonePlanCascade`
    /// never PRODUCED it before: `columnWidth: bandSideColumnWidth` (230)
    /// WITH `subColumns: 2`.** Every prior `subColumns: 2` render test in
    /// this file (`quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant`,
    /// above) hosts the WIDE shape (`bandActionsWideColumnWidth`, 468) —
    /// this is the narrow pair itself, the new ladder rung
    /// `OverviewLayout.bandActionsNarrowColumnWidth`'s own doc comment
    /// argues costs the act zone nothing, checked here at the one thing a
    /// PURE arithmetic test cannot see: whether `QuickActionsColumn` — a
    /// real SwiftUI view neither `DeckCore` nor `OverviewLayoutTests` can
    /// host — actually lays the two of them out inside 230 pt without
    /// crashing, clipping past its own declared width, or losing a row.
    ///
    /// **Long titles, deliberately — the "does a truncating label overflow
    /// the glass" question `QuickActionsColumn`'s own row recipe answers
    /// with `.lineLimit(1).truncationMode(.tail)` (`QuickActionBar.bareControl`'s
    /// own `Text`, `sizing: .flexible` — never `.fitted`'s own
    /// `actionPillMaxWidth` clamp, a DIFFERENT recipe entirely,
    /// `aLongTitleTruncatesInsideItsOwnCell`'s own subject), not by
    /// growing.** `manyActions(_:)`'s own "Action 1"/"Action 2" titles are
    /// short enough to fit a 101 pt half-column without truncating at all —
    /// exactly the case this test exists to NOT rely on. Every extra title
    /// here is deliberately long enough to guarantee truncation at whatever
    /// width a narrow half-column actually resolves to, so this test would
    /// fail the same way `bandBudgetFitsAtEveryGeometryAndBannerState`'s
    /// own "the whole band overruns its budget" class of failure fails, not
    /// merely happen to pass because ten short labels never had anything to
    /// truncate in the first place.
    ///
    /// **This is a COARSE check, by this whole file's own stated
    /// discipline (this file's own top doc comment: "does this view come
    /// back zero-sized, does it grow past the glass it has to live on") —
    /// it does not, and cannot, confirm a 101 pt pill is legible or hittable
    /// by a real thumb on the strip; that is the requirement at the
    /// glass, not a headless render's.**
    @Test("the narrow-pair shape — columnWidth: bandSideColumnWidth, subColumns: 2 — lays out without crashing, clipping past its own width, or losing a row, even with titles long enough to truncate")
    func theNarrowPairShapeLaysOutWithoutOverflowingItsOwnWidth() {
        let longTitledActions = [QuickAction.shipped.first { $0.id == QuickAction.continueID }!]
            + (1..<10).map {
                QuickAction(id: "extra\($0)",
                           title: "A genuinely long quick action title, number \($0), long enough to truncate",
                           kind: .prompt("do thing \($0)"))
            }
        let runtime = Self.worstCaseDecisionRuntime(quickActions: longTitledActions)
        #expect(runtime.frame.actions.count == 10, "the fixture's own premise: ten offered actions, all long-titled")

        // The narrow-pair shape itself — the SAME columnWidth the single
        // sub-column has always used, but subColumns: 2, exactly what
        // `bandZonePlanCascade`'s own new ladder rung now hands a caller in
        // `[898, 1136)` whenever `needsTwo` (`actionCount > rows`) —
        // `rows: bandActionsRowCap` here since this plan is built by hand,
        // bypassing the cascade entirely, the same way every other
        // hand-built `BandActionsPlan` fixture in this file does.
        let plan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandSideColumnWidth,
                                                  subColumns: 2, rows: OverviewLayout.bandActionsRowCap)
        let budget = OverviewLayout.bandMinimumHeight - OverviewLayout.bandHeaderHeight
        let size = measured(QuickActionsColumn(runtime: runtime, budget: budget, plan: plan),
                            width: OverviewLayout.bandSideColumnWidth)

        #expect(size.height > 0, "the narrow-pair column rendered as nothing")
        #expect(Double(size.width) <= OverviewLayout.bandSideColumnWidth + 0.5,
                Comment(rawValue: "the column's own measured width (\(size.width) pt) overran its declared "
                        + "columnWidth (\(OverviewLayout.bandSideColumnWidth) pt) — a long, truncating title "
                        + "should never grow the glass past the frame this column was given, the exact class "
                        + "of failure this file's own top doc comment names"))

        // **Height is UNAFFECTED by the width change — the brief's own
        // requirement, checked directly rather than assumed.**
        // `bandActionsRowHeight` is a HEIGHT rule; `columnWidth` never
        // enters its arithmetic at all, so the wide shape
        // (`quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant`,
        // immediately above) and this narrow-pair one, at the IDENTICAL
        // `rows`/`subColumns`/`budget`, have to measure the SAME height.
        // **No `2 × bandColumnsVerticalPadding` term here, unlike
        // `columnHeightNeverOverrunsItsBudget`'s (`OverviewLayoutTests`)
        // own pure version of this formula** — that padding is
        // `DetailBand.columns(for:)`'s own `.padding(.vertical:)`, applied
        // OUTSIDE `QuickActionsColumn` entirely (`DetailBand.swift`'s own
        // comment on `columnsHeightBudget` states why that function's
        // formula does not double-subtract it), so a bare
        // `measured(QuickActionsColumn(...), width:)` — this call, and
        // `quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant`'s
        // own — never draws it either; the pure test's own `+ 2 ×
        // bandColumnsVerticalPadding` term exists to compare against a
        // budget that has NOT yet had the padding subtracted, a
        // deliberately different comparison than this one.
        let rowHeight = OverviewLayout.bandActionsRowHeight(columnBudget: budget, rowCount: plan.rows)
        let expectedHeight = OverviewLayout.bandQuickActionsChrome
            + Double(plan.rows) * rowHeight + Double(plan.rows - 1) * OverviewLayout.actionGridSpacing
        #expect(abs(Double(size.height) - expectedHeight) < 1,
                Comment(rawValue: "the narrow pair measured \(size.height) pt tall against an expected "
                        + "\(expectedHeight) pt — columnWidth should never enter the height arithmetic; if this "
                        + "moved, the width change leaked into the height rule it is supposed to be independent of"))
        #expect(abs(Double(size.height) - OverviewLayout.bandQuickActionsNaturalHeight) < 1,
                Comment(rawValue: "at this exact floor budget (bandMinimumHeight − bandHeaderHeight, the SAME "
                        + "one quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant uses for the WIDE "
                        + "shape), the narrow pair should measure the IDENTICAL "
                        + "\(OverviewLayout.bandQuickActionsNaturalHeight) pt — got \(size.height)"))
    }

    /// **The measurement risk the row-recipe retune turns on, resolved
    /// BEFORE any wiring change — probing the GLASS itself, not the frame
    /// wrapped around it.**
    ///
    /// **Measuring
    /// `bareControl(...).frame(height: 44)`'s own REPORTED size
    /// (`measured(_:width:)`) is a tautology.** An EXACT `.frame(height:)`
    /// reports its own specified height for ANY child, unconditionally — a
    /// refusing child simply overdraws, centered, invisible to a size read
    /// off the FRAME rather than the thing inside it. That draft could not
    /// have failed no matter what the glass actually rendered, and it was
    /// certifying a false fact: the button does NOT compress to 44.
    ///
    /// **Probed directly instead — `.onGeometryChange` attached to the
    /// BUTTON itself, inside the imposed row frame, `RectCapture`'s own
    /// doc comment states why this is wired by hand rather than through an
    /// existing production seam.** `.local` coordinate space reports
    /// exactly the button's own resolved (width, height); origin is
    /// irrelevant here, only size.
    ///
    /// **What this measures, live, against the macOS 26.5 SDK — the
    /// actual contract, not the false one `.frame(height:)` alone implied:**
    /// - **Width fills the row exactly** (`bandSideColumnWidth`, 230), at
    ///   BOTH imposed heights — this is the fact that lets `.touchTarget()`
    ///   stay dropped: the glass IS the horizontal target.
    /// - **Height is 46, exactly, at BOTH the 44pt (floor) and 64pt
    ///   (ceiling) imposed frames.** `.buttonSizing(.flexible)` fills
    ///   WIDTH only — this recipe's glass never stretches vertically, at
    ///   any imposed height. Pinned as a measured LITERAL, not merely
    ///   `>= 44`, so a future SDK drift in the glass's own intrinsic
    ///   height fails LOUDLY here: a re-measurer's own job on a failure is
    ///   to re-run the overdraw envelope arithmetic below against whatever
    ///   this now reads, never to just raise the pin to make it pass.
    /// - **46 clears `TouchTarget.minimum`** (44) — the touch floor fact,
    ///   stated on the GLASS directly, not inferred from a frame that
    ///   could never have reported anything else.
    ///
    /// **The overdraw envelope — why glass 2pt taller than the 44pt floor
    /// frame is not a collision risk.** At the floor case the glass bleeds
    /// (46 − 44) / 2 = 1pt above and 1pt below the imposed 44pt row frame
    /// — into the 8pt `actionGridSpacing` gap between rows (visible gap
    /// between two glasses: 8 − 1 − 1 = 6pt, never zero; a COLLISION would
    /// need the glass's own intrinsic height to exceed 44 + 8 = 52) and,
    /// at the card's own first and last rows, into the caption-to-rows
    /// spacing (8) or the card's own bottom padding (10) — both
    /// comfortably inside the card, inside `QuickActionsColumn`'s own
    /// `.clipped()` cap. This is the arithmetic a re-measurer re-runs
    /// against a moved intrinsic before retuning the 46 above.
    ///
    /// **The retired bar's own 64pt "pills" were ALSO 46pt glass, centred
    /// in a 64pt frame — never glass filling a frame edge to edge.**
    /// Visual parity between this column's rows and the bar it replaced is
    /// exact BY CONSTRUCTION (the identical recipe, the identical
    /// intrinsic height, `QuickActionBar.control`'s own `.frame(height:
    /// actionPillHeight)` is the SAME centring this row's own frame does),
    /// not because the glass fills whatever frame it is handed —
    /// `bandActionsRowHeight`'s own doc comment, and `QuickActionsColumn
    /// .column(_:rowHeight:)`'s, both retell this honestly now.
    @Test("the pill recipe's own glass — not the frame around it — fills the row's own width and holds its own intrinsic height, unless it opts in to filling the frame's height too")
    func thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight() {
        func probedButtonSize(imposedHeight: Double, fillsHeight: Bool = false) -> CGRect {
            let capture = RectCapture()
            let host = NSHostingView(rootView:
                QuickActionBar.bareControl("Go", alarming: false, sizing: .flexible, fillsHeight: fillsHeight) {}
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .local) } action: { capture.value = $0 }
                    .frame(height: imposedHeight)
                    .frame(maxWidth: .infinity)
                    .frame(width: OverviewLayout.bandSideColumnWidth)
            )
            host.frame = NSRect(x: 0, y: 0, width: OverviewLayout.bandSideColumnWidth, height: 10)
            host.layoutSubtreeIfNeeded()
            return capture.value ?? .zero
        }

        let atFloor = probedButtonSize(imposedHeight: TouchTarget.minimum)
        let atCeiling = probedButtonSize(imposedHeight: OverviewLayout.actionPillHeight)
        let measuredIntrinsicHeight = 46.0

        #expect(Double(atFloor.width) == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "the glass measured \(atFloor.width) pt wide inside a 44pt row — expected it "
                        + "to fill the row's own \(OverviewLayout.bandSideColumnWidth) pt width exactly, the "
                        + "fact that lets .touchTarget() stay dropped"))
        #expect(Double(atFloor.height) == measuredIntrinsicHeight,
                Comment(rawValue: "the glass measured \(atFloor.height) pt tall inside a 44pt row — expected "
                        + "the recipe's own measured intrinsic height (\(measuredIntrinsicHeight)); if this "
                        + "moved, the glass's own SDK behaviour changed — re-run the overdraw envelope "
                        + "arithmetic (this test's own doc comment) against the new number before retuning "
                        + "this literal, do not just raise it to make the test pass"))
        #expect(Double(atCeiling.width) == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "the glass measured \(atCeiling.width) pt wide inside a 64pt row — expected "
                        + "the same \(OverviewLayout.bandSideColumnWidth) pt fill as the floor case"))
        #expect(Double(atCeiling.height) == measuredIntrinsicHeight,
                Comment(rawValue: "the glass measured \(atCeiling.height) pt tall inside a 64pt row — expected "
                        + "the SAME \(measuredIntrinsicHeight) pt intrinsic as the floor case: "
                        + ".buttonSizing(.flexible) fills WIDTH only, this recipe's glass never stretches "
                        + "vertically whatever height it is offered"))
        #expect(Double(atFloor.height) >= TouchTarget.minimum,
                Comment(rawValue: "the glass itself measured \(atFloor.height) pt — below TouchTarget.minimum "
                        + "(\(TouchTarget.minimum)); the touch floor fact stated directly on the glass, not "
                        + "inferred from a frame that could never have reported anything else"))

        // **`fillsHeight: true` — `QuickActionsColumn.column(_:rowHeight:)`'s
        // own opt-in, and the ONLY caller that passes it.** A pill that merely floats was rejected, centred, in a taller row's
        // own dead space ("quick actions should not be collapsed") — this
        // is the empirical proof the opt-in actually grows the GLASS, not
        // merely the frame around it, measured at the strip's own
        // worst-case-BUSY shape (`bandActionsRowHeight(columnBudget: 371,
        // rowCount: 3)` — banner down, three offered actions, the shape
        // `bandActionsRowHeight`'s own worked table names directly) — the
        // exact 64pt row a rejected screenshot showed a
        // small pill floating inside.
        let stripRowHeight = OverviewLayout.bandActionsRowHeight(columnBudget: 371, rowCount: 3)
        #expect(stripRowHeight == OverviewLayout.actionPillHeight, Comment(rawValue:
                "this test's own premise: budget 371 at 3 actions must answer the ceiling "
                + "(\(OverviewLayout.actionPillHeight)) — got \(stripRowHeight); if this fails, the strip "
                + "shape below is no longer the ceiling case and is not proving what it claims to"))

        let filledAtFloor = probedButtonSize(imposedHeight: TouchTarget.minimum, fillsHeight: true)
        let filledAtStrip = probedButtonSize(imposedHeight: stripRowHeight, fillsHeight: true)

        #expect(Double(filledAtFloor.width) == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "fillsHeight: true — the glass measured \(filledAtFloor.width) pt wide inside "
                        + "a 44pt row — expected it to still fill the row's own "
                        + "\(OverviewLayout.bandSideColumnWidth) pt width exactly; fillsHeight must not cost "
                        + "the existing width fill"))
        // **Measured, not assumed: at the 44pt FLOOR the glass holds at its
        // own \(measuredIntrinsicHeight)pt natural minimum rather than
        // compressing to 44 — `.frame(maxHeight: .infinity)` on the label
        // lets Liquid Glass GROW past its own intrinsic size when the row
        // offers more room, it does not force the control to shrink below
        // its own comfortable content size when the row offers less.** This
        // is not a regression to chase: 46 already clears `TouchTarget
        // .minimum` (44) by the SAME 1pt-per-edge overdraw this file's own
        // doc comment above already reasons is harmless, and the complaint was never about the floor case — it was the STRIP's
        // 64pt row (below) showing a pill with dead space around it.
        #expect(Double(filledAtFloor.height) == measuredIntrinsicHeight,
                Comment(rawValue: "fillsHeight: true — the glass measured \(filledAtFloor.height) pt tall "
                        + "inside a \(TouchTarget.minimum)pt row — expected it to hold at its own "
                        + "\(measuredIntrinsicHeight)pt natural minimum (unchanged from the default recipe), "
                        + "not to compress below its own comfortable content size"))
        #expect(Double(filledAtStrip.width) == OverviewLayout.bandSideColumnWidth,
                Comment(rawValue: "fillsHeight: true — the glass measured \(filledAtStrip.width) pt wide inside "
                        + "a \(stripRowHeight)pt row — expected the same \(OverviewLayout.bandSideColumnWidth) "
                        + "pt fill as the floor case"))
        #expect(Double(filledAtStrip.height) == stripRowHeight,
                Comment(rawValue: "fillsHeight: true — the glass measured \(filledAtStrip.height) pt tall "
                        + "inside a \(stripRowHeight)pt row (the strip's own budget-371/3-action shape) — "
                        + "expected the glass to fill it exactly, never a pill floating in dead space at this row height"))
    }

    /// **The FRAME growth this whole retune exists to prove happens — a
    /// genuine RED against the row recipe `QuickActionsColumn.column(_:)`
    /// drew before this arc, GREEN once rows thread `OverviewLayout
    /// .bandActionsRowHeight(columnBudget:rowCount:)` through instead.**
    /// This is frame arithmetic, not a claim about the visible glass — the
    /// glass itself sits at a fixed 46pt intrinsic height always
    /// (`thePillRecipeGlassFillsWidthAndHoldsItsOwnIntrinsicHeight`'s own
    /// doc comment measures and pins that directly); what grows here is
    /// the ROW's own frame, which is what buys the breathing room around
    /// that fixed glass that the retired bar's 64pt frames bought around
    /// the SAME glass.
    ///
    /// Three actions — well under `bandActionsRowCap` (5), so all three sit
    /// in the LEFT sub-column, none spilling into a second — at a budget
    /// generous enough (1000) that `bandActionsRowHeight` clamps every
    /// row's own FRAME to the pill's own full height (`actionPillHeight`,
    /// 64) rather than the general floor (`TouchTarget.minimum`, 44). The
    /// card's own measured NATURAL height has to grow to match:
    /// `bandQuickActionsChrome + 3 × actionPillHeight + 2 ×
    /// actionGridSpacing = 49 + 192 + 16 = 257`. Before this retune, a row
    /// was a plain `.touchTarget()`-floored button — fixed at 44 whatever
    /// the budget offered — and the SAME three actions measured
    /// `bandQuickActionsChrome + 3 × TouchTarget.minimum + 2 ×
    /// actionGridSpacing = 49 + 132 + 16 = 197`, never 257, no matter how
    /// much budget the column was given: exactly the defect a screenshot on the strip named (rows "not as big as the bar's
    /// buttons were") — a frame that never grew, wrapped around glass that
    /// was ALWAYS 46pt regardless.
    @Test("the card's own frame arithmetic grows when the row count leaves room — three actions at a generous budget give each row the pill's own full FRAME height")
    func theQuickActionsCardGrowsWhenTheCountLeavesRoom() {
        let runtime = Self.worstCaseDecisionRuntime(quickActions: Self.manyActions(3))
        #expect(runtime.frame.actions.count == 3,
                "the fixture's own premise: three actions, all in the left sub-column, none spilling")
        let plan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandSideColumnWidth,
                                                  subColumns: 1, rows: OverviewLayout.bandActionsRowCap)
        let size = measured(QuickActionsColumn(runtime: runtime, budget: 1000, plan: plan),
                            width: OverviewLayout.bandSideColumnWidth)
        let expected = OverviewLayout.bandQuickActionsChrome + 3 * OverviewLayout.actionPillHeight
            + 2 * OverviewLayout.actionGridSpacing
        #expect(abs(Double(size.height) - expected) < 1,
                Comment(rawValue: "three actions at a generous budget measured \(size.height) pt — expected "
                        + "\(expected) pt (chrome \(OverviewLayout.bandQuickActionsChrome) + 3 rows at the "
                        + "pill's own \(OverviewLayout.actionPillHeight) pt + 2 gaps of "
                        + "\(OverviewLayout.actionGridSpacing) pt) — the row height should have flexed up to "
                        + "the pill's own full height, not stayed pinned at the old fixed-floor total"))
    }

    /// **Pure — `QuickActionsColumn.columnMajorSplit(_:plan:)`'s own worked
    /// cases, at the plan's own row cap (5) — the shape a generous
    /// geometry's own `bandZonePlan` ladder actually hands this column
    /// most of the time.** `plan.rows` (5) actions or fewer: everything in
    /// the left sub-column, the right one empty. More than five (only
    /// reachable with `subColumns: 2`, since `capacity == subColumns ×
    /// rows`): the first five stay in the left sub-column, UNMOVED — the
    /// same actions, in the same positions, `manyActions`'s own
    /// deterministic ordering makes checkable directly — as the remainder
    /// spills into the right one, the column-major fill this type's own
    /// doc comment argues for over a row-major one.
    @Test("columnMajorSplit puts the first five actions in the left sub-column, unmoved as more join, at the row cap")
    func columnMajorOrderPutsTheFirstFiveLeft() {
        let narrowPlan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandSideColumnWidth,
                                                         subColumns: 1, rows: OverviewLayout.bandActionsRowCap)
        let widePlan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandActionsWideColumnWidth,
                                                       subColumns: 2, rows: OverviewLayout.bandActionsRowCap)

        let three = Self.manyActions(3)
        let splitThree = QuickActionsColumn.columnMajorSplit(three, plan: narrowPlan)
        #expect(splitThree.left.map(\.id) == three.map(\.id),
                "three actions should all land in the left sub-column")
        #expect(splitThree.right.isEmpty, "three actions should not open a right sub-column at all")

        let ten = Self.manyActions(10)
        let splitTen = QuickActionsColumn.columnMajorSplit(ten, plan: widePlan)
        #expect(splitTen.left.map(\.id) == Array(ten.prefix(5)).map(\.id),
                "the left sub-column should hold exactly the first five actions")
        #expect(splitTen.right.map(\.id) == Array(ten.suffix(5)).map(\.id),
                "the right sub-column should hold exactly the remaining five")
        #expect(splitThree.left.map(\.id) == Array(splitTen.left.prefix(3)).map(\.id),
                Comment(rawValue: "the first three actions should sit at the SAME left-column positions "
                        + "whether three or ten actions are offered"))
    }

    /// **The mandatory-column redesign's own new fact `columnMajorOrderPutsTheFirstFiveLeft`
    /// never exercises: the plan can offer FEWER than `bandActionsRowCap`
    /// rows, and the split must cap to `plan.capacity` — never draw past
    /// what the plan says fits.** A squeezed geometry hands this column
    /// `rows: 2` (`bandZonePlan`'s own doc comment carries the worked
    /// boundary table this plan value comes from); ten offered actions
    /// must still trim to the first 2 in the left sub-column and the next
    /// 2 in the right — `capacity` (4), not `actions.count` (10), is what
    /// bounds the split. `QuickActionsColumn.body` never even reads the
    /// dropped six — `DetailBand.yieldedHeaderFold`'s own tail is what
    /// declares them, a render-level fact this pure test cannot see, but
    /// the arithmetic feeding it is exactly what this pins.
    @Test("columnMajorSplit caps to the plan's own capacity, never the full action count, when rows fall below the cap")
    func columnMajorSplitCapsToTheSqueezedPlansOwnCapacity() {
        let squeezedPlan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandActionsWideColumnWidth,
                                                           subColumns: 2, rows: 2)
        #expect(squeezedPlan.capacity == 4, "the fixture's own premise — got \(squeezedPlan.capacity)")

        let ten = Self.manyActions(10)
        let split = QuickActionsColumn.columnMajorSplit(ten, plan: squeezedPlan)
        #expect(split.left.map(\.id) == Array(ten.prefix(2)).map(\.id),
                Comment(rawValue: "the left sub-column should hold exactly the first 2 actions (plan.rows) — "
                        + "got \(split.left.map(\.id))"))
        #expect(split.right.map(\.id) == Array(ten[2..<4]).map(\.id),
                Comment(rawValue: "the right sub-column should hold exactly the next 2 actions, capped at "
                        + "plan.capacity (4) — got \(split.right.map(\.id))"))
        #expect(split.left.count + split.right.count == squeezedPlan.capacity,
                Comment(rawValue: "the split's own total (\(split.left.count + split.right.count)) should equal "
                        + "the plan's own capacity (\(squeezedPlan.capacity)), never the full action count "
                        + "(\(ten.count))"))
    }

    /// **The single sub-column's own twin — `subColumns: 1` with `rows`
    /// below the cap must still cap to `plan.capacity`, never open a
    /// right sub-column it has no width budget for.**
    @Test("columnMajorSplit caps a single squeezed sub-column too, and never opens a right one")
    func columnMajorSplitCapsASingleSqueezedSubColumn() {
        let squeezedPlan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandSideColumnWidth,
                                                           subColumns: 1, rows: 2)
        let ten = Self.manyActions(10)
        let split = QuickActionsColumn.columnMajorSplit(ten, plan: squeezedPlan)
        #expect(split.left.map(\.id) == Array(ten.prefix(2)).map(\.id),
                Comment(rawValue: "the left sub-column should hold exactly the first 2 actions — got "
                        + "\(split.left.map(\.id))"))
        #expect(split.right.isEmpty, "a single sub-column plan should never open a right one")
    }

    /// **The debounce fact, driven genuinely through the reducer — no
    /// hand-built `Frame`, the same discipline the retired
    /// `aDebouncingActionRendersInTheBar` used to hold itself to for the
    /// inspector's own bar (this file's own retired-tests note, above,
    /// carries the history).** Queue and
    /// send an action with no receipt: `frame.debouncingActionIDs` should
    /// carry it, and the column built against that frame must still
    /// render without crashing, at the SAME measured height as the
    /// un-debounced column — `QuickActionsColumn.column(_:rowHeight:)`'s
    /// own `.opacity` sits OUTSIDE the button's own layout, the identical
    /// "dark is style, never layout" contract `darkPillKeepsItsMeasuredWidth`
    /// already holds `QuickActionBar.control` to.
    @Test("a debouncing action's own row renders, disabled, in a column built from a genuinely debouncing frame")
    func aDebouncingActionRendersDimInTheColumn() {
        let runtime = waitingRuntime()
        guard let action = runtime.frame.actions.first else {
            Issue.record("the fixture offers no actions to debounce")
            return
        }
        #expect(!runtime.frame.debouncingActionIDs.contains(action.id),
                "fixture premise: nothing should already be debouncing")

        var events = Self.events()
        events.append(.actionQueued(SessionID("alpha"), action, at: Instant(sinceStart: Millis(30))))
        events.append(.actionSent(SessionID("alpha"), actionID: action.id, at: Instant(sinceStart: Millis(40))))
        let debouncing = DeckRuntime()
        debouncing.markStartedForTesting()
        debouncing.replaceStateForTesting(Reducer.run(events))
        #expect(debouncing.frame.debouncingActionIDs.contains(action.id),
                "fixture's own premise: a send with no receipt should still be debouncing")

        let plan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandSideColumnWidth,
                                                  subColumns: 1, rows: OverviewLayout.bandActionsRowCap)
        let liveSize = measured(QuickActionsColumn(runtime: runtime, budget: 1000, plan: plan),
                                width: OverviewLayout.bandSideColumnWidth)
        let dimmedSize = measured(QuickActionsColumn(runtime: debouncing, budget: 1000, plan: plan),
                                  width: OverviewLayout.bandSideColumnWidth)
        #expect(dimmedSize.height > 0, "the column renders as nothing while one of its own rows is debouncing")
        #expect(Double(liveSize.height) == Double(dimmedSize.height),
                Comment(rawValue: "a debouncing row's own dim changed the column's measured height — "
                        + "\(liveSize.height) live vs \(dimmedSize.height) debouncing — dark is supposed to "
                        + "be style, never layout"))
    }

    // ---------------------------------------------------- Q2: the wrapping bar
    //
    // What remains of the pinned bar's own arbiter matrix — the bar itself
    // is inspector-only now (`QuickActionsColumn` replaced it on the band,
    // `DecisionBar.swift`'s own file doc states the move), so the row-wrap
    // arbiters that used to hold `DetailBand.columnsHeightBudget`'s
    // reservation to the bar's own live row count retired WITH the
    // reservation. `bareOverflowControlMatchesThePopulatedChip`, below, is
    // the one test in this section still about a live surface — the
    // inspector's own overflow chip, untouched by the band's own move.

    /// `manyActions`'s own action-set builder — `count` distinct, legal
    /// actions (`QuickAction.rejection` needs distinct titles and a
    /// non-empty message). Always leads with the shipped Continue action
    /// (`QuickAction.continueID`) when `count >= 1` — so `Frame
    /// .autoContinuable` reads the SAME true/false answer a shipped-action
    /// fixture already does, and a height comparison against one is not
    /// quietly corrupted by the toggle appearing in one scenario and not
    /// the other. `count` past `QuickAction.maxOffered` (10) is legal here
    /// — `manyActions` builds the RAW set a caller hands to `.prefsChanged`,
    /// same as a hand-edited prefs file might; `QuickAction.offerable(_:)`
    /// is what actually caps what `Frame.actions` ever returns from it.
    static func manyActions(_ count: Int) -> [QuickAction] {
        guard count >= 1 else { return [] }
        let continueAction = QuickAction.shipped.first { $0.id == QuickAction.continueID }!
        let extras = (1..<count).map {
            QuickAction(id: "extra\($0)", title: "Action \($0)", kind: .prompt("do thing \($0)"))
        }
        return [continueAction] + extras
    }

    /// **Cheap but real — `bareOverflowControl(hiddenCount:)`'s own
    /// label-only footprint IS a REAL, populated `Menu`'s, at the same
    /// hidden count, both read UNCONSTRAINED.**
    ///
    /// **Reworked — the previous version was circular.** It imposed the label-only build's own measured
    /// width onto `overflowControl`'s `.frame(width:)`, which forces that
    /// EXACT width for any label, then asserted the width it had just
    /// imposed — tautological, never actually comparing two independent
    /// measurements. The fix: `bareOverflowControl(hidden:runtime:)`
    /// (added alongside this retune, `bareOverflowControl`'s own doc
    /// comment states why) builds a REAL, populated `Menu` — the same
    /// `overflowMenuItems` dispatch `overflowControl` itself uses — with
    /// NO imposed frame, so both sides of this comparison are genuinely
    /// unconstrained reads, neither one derived from the other.
    @Test("bareOverflowControl's own label-only width matches a REAL, populated menu's, at the same hidden count")
    func bareOverflowControlMatchesThePopulatedChip() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let hidden = [QuickAction(id: "a1", title: "Action One", kind: .prompt("go")),
                      QuickAction(id: "a2", title: "Action Two", kind: .prompt("go")),
                      QuickAction(id: "a3", title: "Action Three", kind: .prompt("go"))]
        let bareWidth = measuredWidth(QuickActionBar.bareOverflowControl(hiddenCount: hidden.count), height: 100).width
        let populatedWidth = measuredWidth(QuickActionBar.bareOverflowControl(hidden: hidden, runtime: runtime),
                                           height: 100).width
        #expect(Double(populatedWidth) == Double(bareWidth),
                Comment(rawValue: "the REAL, populated menu measured \(populatedWidth) pt wide, unconstrained, "
                        + "against the label-only build's own \(bareWidth) pt — a Menu's own collapsed "
                        + "footprint should depend only on its label, not on whether real dispatchable items "
                        + "sit behind it"))
    }

    /// **The header fold's own render-level proof — RENAMED and REWRITTEN:
    /// `theHeaderFoldAppearsExactlyWhenTheColumnDrops` used to
    /// prove the fold appears exactly when the Quick Actions column has
    /// DROPPED, naming every hidden action.** The mandatory-column
    /// redesign INVERTS the premise that name stated — the column almost
    /// never drops any more, down to the window's own floor — so the fact
    /// worth a live render's own proof now is the TAIL: the fold appears
    /// exactly when the column's own `capacity` (`OverviewLayout
    /// .BandActionsPlan.capacity`) falls short of the offered action
    /// count, and names EXACTLY that shortfall, never the whole list.
    /// `DetailBand.yieldedHeaderFold`'s own doc comment states the
    /// mechanism; this holds it to a live render rather than trusting the
    /// arithmetic that is SUPPOSED to produce it. `header` is `internal`,
    /// not `private` — `RenderSweepTests` measures it directly the same
    /// way that property's own doc comment already states for its
    /// budget-math siblings.
    ///
    /// **Ten offered actions, two geometries — one where `capacity`
    /// covers all ten, one where it does not.** The strip's own full band
    /// width (1588) at a generous usable height (419) hands this column
    /// its widest shape, `468×2` at 5 rows (`bandZonePlanAtEveryRealGeometry`
    /// pins the identical figures) — `capacity` 10, covering every offered
    /// action, so the fold should be EMPTY. The min window's own band
    /// width (628) at a genuinely squeezed usable height (249) hands it
    /// the squeezed step — `230×1` at 2 rows, the SAME geometry that
    /// table's own "the minimum window" row pins — `capacity` 2, eight
    /// short of the ten offered, so the fold should name exactly those
    /// eight, never all ten.
    ///
    /// **Width, unconstrained (`measuredWidth(_:height:)`), not the fixed
    /// `bandWidth` `measured(_:width:)` would pin it to** — `header`'s own
    /// `.frame(maxWidth: .infinity)`-free `HStack` reports the SAME
    /// overall width at either band width when measured at a FIXED width
    /// (both simply fill it), so the fold's own presence is only visible
    /// in the header's NATURAL width: wider with the fold's own label
    /// added, narrower without it. **Height, separately, at the FIXED
    /// `bandWidth`** — a width contrast alone never proves the fold stays
    /// within `bandHeaderHeight` (48), the one thing
    /// `bandHeaderAndAutoContinueMatchTheirNamedHeights`'s own arbiter
    /// cannot, since it never renders the folded shape.
    @Test("the header's own overflow fold appears exactly when the column's own capacity falls short of the offered actions, and names exactly the shortfall")
    func theHeaderFoldAppearsExactlyWhenTheColumnFallsShortOfCapacity() {
        let runtime = Self.liveNeedsYouBandShapeRuntime(quickActions: Self.manyActions(10))
        #expect(runtime.frame.actions.count == 10, "the fixture's own premise: ten offered actions")

        let fullWidth = 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth   // 1588
        let fullHeight = 419.0
        let shortWidth = 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth   // 628
        let shortHeight = 249.0

        let fullPlan = OverviewLayout.bandZonePlan(bandWidth: fullWidth, actionCount: 10, usableHeight: fullHeight)
        let shortPlan = OverviewLayout.bandZonePlan(bandWidth: shortWidth, actionCount: 10, usableHeight: shortHeight)
        #expect(fullPlan.actions?.capacity == 10,
                Comment(rawValue: "the fixture's own premise: the strip's own full band width should hold "
                        + "every offered action — got capacity \(String(describing: fullPlan.actions?.capacity))"))
        #expect(shortPlan.actions?.capacity == 2,
                Comment(rawValue: "the fixture's own premise: the squeezed min-window geometry should hold "
                        + "only 2 of the 10 offered — got capacity \(String(describing: shortPlan.actions?.capacity))"))

        let fullHeaderWidth = measuredWidth(DetailBand(runtime: runtime, width: fullWidth,
                                                       usableHeight: fullHeight, dismissedStage: nil).header,
                                            height: 48).width
        let shortHeaderWidth = measuredWidth(DetailBand(runtime: runtime, width: shortWidth,
                                                         usableHeight: shortHeight, dismissedStage: nil).header,
                                             height: 48).width
        #expect(Double(shortHeaderWidth) > Double(fullHeaderWidth),
                Comment(rawValue: "the short-capacity header measured \(shortHeaderWidth) pt wide, no wider "
                        + "than the full-capacity one's \(fullHeaderWidth) pt — the overflow fold does not "
                        + "appear to be rendering when the column's own capacity falls short"))

        // The fold's own HEIGHT, not just its width contrast. Both the
        // fold chip and the collapse button share the identical
        // `TouchTarget.minimum` (44) floor, so adding the fold beside the
        // collapse button must NOT grow the header past `OverviewLayout
        // .bandHeaderHeight` (48).
        let shortHeaderHeight = measured(DetailBand(runtime: runtime, width: shortWidth,
                                                     usableHeight: shortHeight, dismissedStage: nil).header,
                                         width: shortWidth)
        #expect(Double(shortHeaderHeight.height) == OverviewLayout.bandHeaderHeight,
                Comment(rawValue: "the folded header measured \(shortHeaderHeight.height) pt tall — expected "
                        + "bandHeaderHeight (\(OverviewLayout.bandHeaderHeight) pt) unchanged by the fold's "
                        + "own presence"))

        // The fold's own label, built the same way `DetailBand.header`
        // itself builds it (`QuickActionBar.overflowTitle`/
        // `.spokenOverflowTitle`) — names EXACTLY the shortfall (8), never
        // the whole offered list (10).
        let shortfall = 10 - (shortPlan.actions?.capacity ?? 0)
        #expect(shortfall == 8, "the fixture's own premise — got \(shortfall)")
        let spoken = QuickActionBar.spokenOverflowTitle(for: QuickActionBar.overflowTitle(hiddenCount: shortfall))
        #expect(spoken.contains("\(shortfall)"),
                Comment(rawValue: "the fold's own accessibility text (\"\(spoken)\") does not name the "
                        + "shortfall (\(shortfall))"))
    }

    /// **Truncation, not growth.** A title far past `QuickAction
    /// .titleBudget` (16) used to be a REJECTION (Q1's own doc comment on
    /// that constant states the retired rule); now it is legal and clips
    /// on the glass instead, at `OverviewLayout.actionPillMaxWidth` (320)
    /// rather than the retired fixed-cell grid's 160. This is the
    /// render-level proof: `ActionPillMeasurer.width(for:)` clamps a long
    /// title to the pill's own max width, and the imposed, clamped `control`
    /// cell it feeds renders at exactly that width, never the title's own
    /// natural (wider) one.
    ///
    /// **History — this used to also prove a single long-titled action
    /// drew a one-row `QuickActionBar`, the self-rendering bar's own
    /// row-height arithmetic.** That bar retired along with its last
    /// production caller (`QuickActionBar`'s own doc comment,
    /// `DecisionBar.swift`, states the history in full); `QuickActionsColumn`,
    /// its replacement, sizes every row by a fixed budget
    /// (`bandActionsRowHeight`) rather than by how many actions fit a
    /// wrapped bar, so "does a long title still fit one row" is no longer
    /// a fact the column's own geometry could even ask — only the pill's
    /// own clamp, proven directly below, still applies.
    @Test("a long action title truncates at the pill's own max width rather than growing past it")
    func aLongTitleTruncatesInsideItsOwnCell() {
        let longTitle = "This Action Has An Extremely Long Title Indeed"
        #expect(longTitle.count >= 40,
                "the fixture's own premise: a title long enough to actually need truncating")
        let natural = measuredWidth(QuickActionBar.bareControl(longTitle, alarming: false) {}, height: 100).width
        #expect(Double(natural) > OverviewLayout.actionPillMaxWidth,
                Comment(rawValue: "the fixture's own premise: the natural width (\(natural) pt) must exceed "
                        + "actionPillMaxWidth (\(OverviewLayout.actionPillMaxWidth) pt) for anything below to "
                        + "prove truncation rather than an accident of a title that was not actually long enough"))

        // The cell itself, measured directly through the SAME measurer
        // `QuickActionsColumn` reads — `control`'s own imposed, clamped
        // frame is what actually proves truncation rather than wrap or
        // silent growth.
        let measuredWidthForTitle = ActionPillMeasurer.width(for: longTitle)
        #expect(measuredWidthForTitle == OverviewLayout.actionPillMaxWidth,
                Comment(rawValue: "a long title's own measured width was \(measuredWidthForTitle) pt — expected "
                        + "the clamp to land exactly at actionPillMaxWidth "
                        + "(\(OverviewLayout.actionPillMaxWidth) pt)"))
        let cellSize = measuredWidth(QuickActionBar.control(longTitle, alarming: false,
                                                            measuredWidth: measuredWidthForTitle) {}, height: 100)
        #expect(Double(cellSize.width) == OverviewLayout.actionPillMaxWidth,
                Comment(rawValue: "a long title's own cell measured \(cellSize.width) pt wide — expected the "
                        + "clamped \(OverviewLayout.actionPillMaxWidth) pt cell width"))
    }

    /// **The measurer-honesty arbiter — replaces the retired
    /// `actionCellWidthMatchesARealButton`, which held a single shared
    /// constant to a worst-case measurement.** The pill world has no
    /// shared width constant to hold accountable that way — each pill
    /// hugs its own label — so this holds the MEASURER itself accountable
    /// instead: `ActionPillMeasurer.width(for:)` IS the real, fitted
    /// `bareControl`'s own `fittingSize.width`, clamped in code, not an
    /// estimate of it, so the clamp's own two floors are what this proves,
    /// each at an exact boundary rather than "roughly right": a single
    /// glyph ("X") floors at exactly `actionPillMinWidth` (64), and a very
    /// long one caps at exactly `actionPillMaxWidth` (320) — and the
    /// imposed-frame `control` renders at EXACTLY the measured width and
    /// `actionPillHeight` (64) for real, plausible titles ("Continue",
    /// "Escape Key", "Warn My Web Team" — three Title Case words a person
    /// could plausibly name a quick action, not a synthetic wall of one
    /// letter), never merely "close enough."
    ///
    /// **The floor's own exemplar moved from "Go" to "X" for the squarish/
    /// colour/legibility retune (`bareControl`'s own doc comment) — "Go"
    /// no longer exercises the floor at all.** `.weight(.medium)` widened
    /// "Go"'s own natural hug from 64 (exactly the floor) to 65 (one point
    /// PAST it, where the clamp no longer binds) — a real consequence of
    /// the same weight change the legibility retune's own research named,
    /// not a measurement error. "X" — a single glyph, well under the floor
    /// either way — is what still proves the clamp itself works, rather
    /// than merely re-measuring whichever exemplar's own width happens to
    /// land on 64 this round.
    @Test("ActionPillMeasurer.width(for:) is the real fitted pill's own clamped natural width")
    func actionPillMeasurerIsHonestAboutTheRealControl() {
        // "X" measures 51pt natural — comfortably under the floor, so
        // max(51, 64) == 64 is a real clamp engaging, not a coincidence.
        let floorWidth = ActionPillMeasurer.width(for: "X")
        #expect(floorWidth == OverviewLayout.actionPillMinWidth,
                Comment(rawValue: "\"X\" measured \(floorWidth) pt — expected the floor, actionPillMinWidth "
                        + "(\(OverviewLayout.actionPillMinWidth) pt)"))

        let veryLongTitle = String(repeating: "Regenerate token and rotate every credential ", count: 4)
        let cappedWidth = ActionPillMeasurer.width(for: veryLongTitle)
        #expect(cappedWidth == OverviewLayout.actionPillMaxWidth,
                Comment(rawValue: "a very long title measured \(cappedWidth) pt — expected the cap, "
                        + "actionPillMaxWidth (\(OverviewLayout.actionPillMaxWidth) pt)"))

        for title in ["Continue", "Escape Key", "Warn My Web Team"] {
            let measuredWidthForTitle = ActionPillMeasurer.width(for: title)
            let rendered = measured(QuickActionBar.control(title, alarming: false,
                                                            measuredWidth: measuredWidthForTitle) {},
                                    width: measuredWidthForTitle)
            #expect(Double(rendered.width) == measuredWidthForTitle,
                    Comment(rawValue: "\"\(title)\" control rendered \(rendered.width) pt wide — expected the "
                            + "imposed, measured \(measuredWidthForTitle) pt"))
            #expect(Double(rendered.height) == OverviewLayout.actionPillHeight,
                    Comment(rawValue: "\"\(title)\" control rendered \(rendered.height) pt tall — expected "
                            + "actionPillHeight (\(OverviewLayout.actionPillHeight) pt)"))
        }
    }

    /// **RETIRED — `theActionBarSurvivesActionsShrinkingWhileMounted` used
    /// to live here.** It reproduced, headlessly, the live EXC_BREAKPOINT
    /// crash `QuickActionBar`'s own doc comment (`DecisionBar.swift`)
    /// carries the full account of — `Array._checkSubscript`, confirmed on
    /// device the moment the user DISMISSED the band, closed by
    /// snapshot-coherent `PillCell`s that carried their own `QuickAction`
    /// value rather than an index a later, independent read of
    /// `runtime.frame` could resolve differently. That machinery — `body`,
    /// `PillCell`, `PillRow`, `rows` — retired in full along with the
    /// self-rendering bar itself (`QuickActionBar`'s own doc comment states
    /// the history), so there is nothing left of the ORIGINAL bug's own
    /// surface for this reproduction to hold accountable. The twin below,
    /// for the view that replaced the bar, is the live arbiter now — it
    /// was built with the value-not-index law from the start rather than
    /// discovering it the hard way, and still pins that the law holds.

    /// **The live crash's own defensive proof, for the view that replaced
    /// the pinned bar on the band.** `DecisionBar.swift`'s own
    /// "EXC_BREAKPOINT law" (`QuickActionsColumn.body`'s doc comment
    /// states it in full) is the account of the original bug and the fix
    /// that closed it — snapshot-coherent values, never an index into
    /// `runtime.frame` a later, independent read could resolve
    /// differently. `QuickActionsColumn.column(_:rowHeight:)` was built
    /// with that law from the start (`ForEach(actions)` over VALUES)
    /// rather than discovering it the hard way; this pins that it
    /// actually holds, the same permanent-regression-test discipline the
    /// retired bar's own version once practised, rather than trusting a
    /// design intention nobody has forced to fail.
    ///
    /// Ten actions shrinking to two, not three to zero — wide enough that
    /// the shrink also crosses the column-major split's own row-cap
    /// boundary (`bandActionsRowCap`, 5) on the way down, from a two-
    /// sub-column layout to a one-sub-column one, not merely a shorter
    /// version of the same shape.
    @Test("the Quick Actions column survives runtime.frame.actions shrinking while it is still mounted")
    func theQuickActionsColumnSurvivesActionsShrinkingWhileMounted() {
        let runtime = Self.liveNeedsYouBandShapeRuntime(quickActions: Self.manyActions(10))
        #expect(runtime.frame.actions.count == 10, "the fixture's own premise: ten offered actions")
        let plan = OverviewLayout.BandActionsPlan(columnWidth: OverviewLayout.bandActionsWideColumnWidth,
                                                  subColumns: 2, rows: OverviewLayout.bandActionsRowCap)
        let host = NSHostingView(rootView: QuickActionsColumn(runtime: runtime, budget: 1000, plan: plan)
            .frame(width: OverviewLayout.bandActionsWideColumnWidth))
        host.frame = NSRect(x: 0, y: 0, width: OverviewLayout.bandActionsWideColumnWidth, height: 400)
        host.layoutSubtreeIfNeeded()
        _ = host.fittingSize

        var prefs = runtime.prefs
        prefs.quickActions = Self.manyActions(2)
        runtime.setPrefs(prefs)

        // The SAME host, laid out again with no recreation in between —
        // the exact sequence that trapped `QuickActionBar` pre-fix.
        // Reaching the assertion below at all (rather than crashing the
        // process) IS the test; the assertion itself just confirms the
        // host settled on a sane, non-negative size rather than merely
        // "didn't trap."
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        #expect(size.width >= 0 && size.height >= 0,
                Comment(rawValue: "settled at \(size) after the shrink — a nonsensical size would mean the "
                        + "view survived the trap but still rendered garbage"))
    }

    /// **RETIRED — `theSelfMeasuringBarRendersAtTheInspectorSite` and
    /// `theInspectorBarNeverOverflows` used to live here.** Both exercised
    /// `QuickActionBar`'s own `width: nil, maxRows: nil` self-measuring,
    /// unbounded-wrap shape — the inspector's own one production call
    /// site, and the ONE shape production ever actually built the retired
    /// bar at (`QuickActionBar`'s own doc comment, `DecisionBar.swift`,
    /// states the history in full). `.inspector` is retired now, and
    /// `QuickActionsColumn` — its replacement — has neither a
    /// self-measuring width nor an unbounded row count: it is handed a
    /// fixed `budget` and lays out a 2×5 grid within it, clipping as a
    /// backstop rather than wrapping or scrolling
    /// (`QuickActionsColumn`'s own doc comment states why no `ScrollView`).
    /// Neither fact has a live surface left to hold accountable;
    /// `theQuickActionsColumnNeverClipsInTheLiveRecordedShape` and
    /// `quickActionsColumnNaturalHeightMatchesItsOwnMeasuredConstant`
    /// (elsewhere in this file) are the column's own overflow-honesty
    /// arbiters now.

    /// **Overflow-honesty's own regression net — `AutoContinueToggle`
    /// clipping, the trade-off an earlier fix left behind, made unable
    /// to recur silently.** A control that clips without declaring what it
    /// hides is exactly what this file's own doc forbids (`DetailBand.swift`,
    /// "every hidden-content affordance declares what it hides"); an
    /// INTERACTIVE control that clips is worse — a switch nobody can reach
    /// is not overflow, it is a control silently going missing.
    ///
    /// **Re-sited, the transcript-well band's own toggle relocation.** The
    /// toggle moved PERMANENTLY into "This Session," out of the act zone —
    /// `autoContinueReservedHeight`, the reservation this test used to hold
    /// accountable, retired with it (`DetailBand.swift`'s own historical
    /// doc comment on that name states why). The probe
    /// (`onAutoContinueFrameMeasured`) moved with the toggle, into
    /// `controlsZone(for:)` — what this test actually proves now is
    /// simpler and just as load-bearing: the controls column, wherever the
    /// toggle sits inside it, never pushes the toggle's own frame past the
    /// band's own `usableHeight`, at every budget the live-recorded shape
    /// actually meets on the strip — the same three budgets, the same
    /// probe technique, `theQuickActionsColumnNeverClipsInTheLiveRecordedShape`'s
    /// own twin.
    @Test("the auto-continue toggle's own measured frame never exceeds the usable height it was given",
          arguments: [OverviewLayout.bandMinimumHeight,
                      QuestionOptionsBand.usableStripHeight - 60,
                      QuestionOptionsBand.usableStripHeight])
    func theAutoContinueToggleNeverClipsInTheLiveRecordedShape(_ usableHeight: Double) {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        #expect(runtime.frame.autoContinuable, "the fixture's own premise: the toggle actually renders")
        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                              dismissedStage: nil)
        var toggleFrame: CGRect?
        band.onAutoContinueFrameMeasured = { toggleFrame = $0 }
        _ = measured(band, width: bandWidth)
        guard let toggleFrame else {
            Issue.record("the toggle's own geometry probe never fired — it may not be rendering at all")
            return
        }
        #expect(toggleFrame.height > 0,
                "AutoContinueToggle measured zero height — that is not \"unclipped\", it is invisible")
        #expect(toggleFrame.maxY <= usableHeight,
                Comment(rawValue: "AutoContinueToggle's own frame reaches \(toggleFrame.maxY) pt against a "
                        + "\(usableHeight) pt budget (origin \(toggleFrame.origin), height "
                        + "\(toggleFrame.height)) — it is being pushed past the visible band and clipped, "
                        + "an interactive control going silently missing rather than merely a fact getting "
                        + "shorter"))
    }

    /// **The takeover's INTERIOR was
    /// the remaining unguarded silent-clip zone.** The action bar and the
    /// toggle are both protected (`columnsHeightBudget`/
    /// `autoContinueReservedHeight`), but nothing inside `QuestionTakeover`
    /// itself was: the toggle's own reservation caps the WHOLE "before
    /// toggle" group to one number, and a bare question's own content
    /// (question text, the options grid, `OtherAnswerField`, the caption,
    /// `QuestionControls`) simply grows or clips together within it, in
    /// document order — nothing singles out `OtherAnswerField` for
    /// protection the way the toggle singles out itself. A read-derived estimate named the field EXPANDED (a real tap on
    /// "Other…", the one moment it is being typed into) as the likely
    /// clip; this measures it directly rather than trusting the estimate.
    /// `otherFieldInitiallyExpanded` mirrors `DetailBand.wellInitiallyExpanded`'s
    /// own seam exactly, for the identical reason: the EXPANDED shape is
    /// the one worth measuring, not just the COLLAPSED default every other
    /// test in this file already exercises through `liveNeedsYouBandShapeRuntime()`.
    @Test("the takeover's own bottom-most interactive element never exceeds the usable height it was given",
          arguments: [OverviewLayout.bandMinimumHeight,
                      QuestionOptionsBand.usableStripHeight - 60,
                      QuestionOptionsBand.usableStripHeight],
          [false, true])
    func theTakeoverInteriorNeverClipsInTheLiveRecordedShape(_ usableHeight: Double,
                                                              _ otherFieldExpanded: Bool) {
        let runtime = Self.liveNeedsYouBandShapeRuntime()
        guard let decision = runtime.frame.decisions.first, !decision.questions.isEmpty else {
            Issue.record("the fixture's own premise: a bare question, so nothing below is measured")
            return
        }
        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                              dismissedStage: nil, otherFieldInitiallyExpanded: otherFieldExpanded)
        var otherFieldFrame: CGRect?
        var controlsFrame: CGRect?
        band.onOtherFieldFrameMeasured = { otherFieldFrame = $0 }
        band.onControlsFrameMeasured = { controlsFrame = $0 }
        _ = measured(band, width: bandWidth)

        guard let otherFieldFrame else {
            Issue.record("the \"Other…\" field's own geometry probe never fired — it may not be rendering")
            return
        }
        #expect(otherFieldFrame.height > 0,
                "the \"Other…\" field measured zero height — that is not \"unclipped\", it is invisible")
        #expect(otherFieldFrame.maxY <= usableHeight,
                Comment(rawValue: "the \"Other…\" field (expanded: \(otherFieldExpanded)) reaches "
                        + "\(otherFieldFrame.maxY) pt against a \(usableHeight) pt budget (origin "
                        + "\(otherFieldFrame.origin), height \(otherFieldFrame.height)) — an interactive "
                        + "field, possibly mid-type, clipped rather than merely a fact getting shorter"))

        // `QuestionControls` renders NOTHING (`.isEmpty`) on this fixture's
        // own shape — single-select, first step, neither Back nor DONE has
        // anything to do yet — so a zero-height probe here is the fixture's
        // own honest answer, not a sign the probe failed to fire. Checked
        // anyway, unconditionally: the bound costs nothing when the frame
        // is empty, and holds the day this fixture's own shape changes.
        if let controlsFrame {
            #expect(controlsFrame.maxY <= usableHeight,
                    Comment(rawValue: "QuestionControls reaches \(controlsFrame.maxY) pt against a "
                            + "\(usableHeight) pt budget (origin \(controlsFrame.origin), height "
                            + "\(controlsFrame.height))"))
        }
    }

    /// A `.terminalLive` mirror, selected — `RenderSweepTests`' own event
    /// idiom (`Self.events(questions:)`), extended past the hold's own
    /// natural expiry and the readiness gate's pair, the identical
    /// sequence `QuestionMirrorTests.terminalLiveMirror` (`DeckCoreTests`)
    /// drives at the reducer level, replayed here through `Reducer.run`
    /// and installed with `replaceStateForTesting` — the same seam
    /// `waitingRuntime` above uses, for the identical reason: a real
    /// multi-second budget timer has nothing to do with what this measures.
    private static func terminalLiveMirrorRuntime(multiSelect: Bool = false) -> DeckRuntime {
        let t = { (ms: Int64) in Instant(sinceStart: Millis(ms)) }
        let session = SessionID("alpha")
        let question = Question(text: Redacted("Which lane should this land on?"),
                                header: Redacted("Lane"),
                                options: (1...3).map {
                                    QuestionOption(label: Redacted("Option \($0)"), detail: Redacted(""))
                                },
                                multiSelect: multiSelect)
        let events: [DeckEvent] = [
            .hook(HookEvent(id: EventID("s1"), at: t(0), kind: .sessionStart,
                            session: session, cwd: Redacted("/w/alpha"), tool: nil, toolUseID: nil,
                            held: .absent, host: HostAddress(workspace: "w", surface: "s"))),
            .hook(HookEvent(id: EventID("q1"), at: t(10), kind: .preToolUse,
                            session: session, cwd: Redacted("/w/alpha"),
                            tool: SubjectReader.questionTool, toolUseID: "t1", held: .value(1),
                            questions: [question], host: HostAddress(workspace: "w", surface: "s"))),
            .holdExpired(HoldID(session: session, toolUseID: "t1"), at: t(8_000)),
            .hook(HookEvent(id: EventID("pr"), at: t(20_000), kind: .permissionRequest,
                            session: session, cwd: nil, tool: SubjectReader.questionTool,
                            toolUseID: nil, held: .absent)),
            .hook(HookEvent(id: EventID("nt"), at: t(26_000), kind: .notification,
                            session: session, cwd: nil, tool: nil, toolUseID: nil,
                            held: .absent, notificationType: "permission_prompt")),
            .sessionSelected(session, at: t(26_100)),
        ]
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        return runtime
    }

    /// **The mirror card's own arbiter — `theTakeoverInteriorNeverClipsInTheLiveRecordedShape`'s
    /// exact twin, one surface over.** `QuestionMirrorCard`'s own Other
    /// field reuses `OtherAnswerField` verbatim, which means it inherits
    /// that component's own unbounded-when-expanded shape — nothing about
    /// reuse makes the clipping risk `theTakeoverInteriorNeverClipsInTheLiveRecordedShape`
    /// exists to catch go away on this surface; it has to be checked here
    /// too, independently, because `DetailBand`'s own `.clipped()` cap
    /// does not know or care which of the two views produced the height
    /// that exceeded it.
    @Test("the mirror card's own Other field never exceeds the usable height it was given",
          arguments: [OverviewLayout.bandMinimumHeight,
                      QuestionOptionsBand.usableStripHeight - 60,
                      QuestionOptionsBand.usableStripHeight],
          [false, true])
    func theMirrorCardOtherFieldNeverClips(_ usableHeight: Double, _ otherFieldExpanded: Bool) {
        let runtime = Self.terminalLiveMirrorRuntime()
        guard runtime.frame.mirrors.first(where: { $0.hold.session == SessionID("alpha") }) != nil else {
            Issue.record("the fixture's own premise: a terminalLive mirror, so nothing below is measured")
            return
        }
        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                              dismissedStage: nil, otherFieldInitiallyExpanded: otherFieldExpanded)
        var otherFieldFrame: CGRect?
        band.onOtherFieldFrameMeasured = { otherFieldFrame = $0 }
        _ = measured(band, width: bandWidth)

        guard let otherFieldFrame else {
            Issue.record("the mirror card's own \"Other…\" field never fired its probe — it may not be rendering")
            return
        }
        #expect(otherFieldFrame.height > 0,
                "the mirror card's \"Other…\" field measured zero height — that is not \"unclipped\", it is invisible")
        #expect(otherFieldFrame.maxY <= usableHeight,
                Comment(rawValue: "the mirror card's \"Other…\" field (expanded: \(otherFieldExpanded)) reaches "
                        + "\(otherFieldFrame.maxY) pt against a \(usableHeight) pt budget (origin "
                        + "\(otherFieldFrame.origin), height \(otherFieldFrame.height))"))
    }

    /// **The unbounded field, measured directly — a read-derived concern, reproduced for real before it was fixed.**
    /// A 300-word, newline-free question text pushed `OtherAnswerField` to
    /// y ≈ 366–430 against this fixture's own 358–419 pt budgets — past
    /// every one of them — before `QuestionText` (`QuestionTakeover.swift`)
    /// existed to cap it. This is that reproduction kept as a permanent
    /// guard: the SAME probe technique `theTakeoverInteriorNeverClipsInTheLiveRecordedShape`
    /// already holds the ordinary-length live shape to, held here to the
    /// pathological one instead.
    @Test("a pathologically long question text never pushes the takeover's interactive elements past the usable height",
          arguments: [OverviewLayout.bandMinimumHeight,
                      QuestionOptionsBand.usableStripHeight - 60,
                      QuestionOptionsBand.usableStripHeight])
    func aLongQuestionTextNeverPushesInteractiveElementsOffTheBand(_ usableHeight: Double) {
        let longText = Array(repeating: "word", count: 300).joined(separator: " ")
        let runtime = Self.liveNeedsYouBandShapeRuntime(questionText: longText)
        guard runtime.frame.decisions.first != nil else {
            Issue.record("the fixture's own premise: a decision to measure the takeover against")
            return
        }
        let bandWidth = Self.stripWidth - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                              dismissedStage: nil)
        var otherFieldFrame: CGRect?
        band.onOtherFieldFrameMeasured = { otherFieldFrame = $0 }
        _ = measured(band, width: bandWidth)
        guard let otherFieldFrame else {
            Issue.record("the \"Other…\" field's own geometry probe never fired")
            return
        }
        #expect(otherFieldFrame.maxY <= usableHeight,
                Comment(rawValue: "a 300-word question text pushed the \"Other…\" field to "
                        + "\(otherFieldFrame.maxY) pt against a \(usableHeight) pt budget — the question "
                        + "text's own overflow cap (`QuestionText.collapsedLines`) did not hold"))
    }

    /// **The declared half of the fix — a long question text gets a
    /// stated overflow marker, never silent clipping.** The same
    /// mutation-resistant technique `theSubjectWellRendersAWrapOnlyChip`
    /// already proved for `SubjectWell`'s own wrap-only chip, reused here
    /// rather than re-argued: a chip-free `collapsedLines`-line baseline
    /// (newline-separated, so no measurement is needed to know it needs no
    /// chip) against a long, newline-free chain that wraps well past that —
    /// any remaining height gap past pure wrapping is the chip ROW itself,
    /// not more text.
    @Test("a long question text renders its overflow chip from measured wrap, not newlines")
    func theQuestionTextRendersAWrapOnlyChip() {
        let longChain = (1...40).map { "word\($0)" }.joined(separator: " ")
        #expect(SubjectOverflow.lineCount(longChain) == 1,
                "the fixture itself gained a newline — this would exercise the N-label path, not wrap")
        #expect(SubjectOverflow.chipText(for: longChain, collapsedLines: 3) == nil,
                "the pure function should stay silent here — the chip below has to come from measured wrap")
        let threeLineBaseline = (1...3).map { "line \($0)" }.joined(separator: "\n")
        #expect(SubjectOverflow.chipText(for: threeLineBaseline, collapsedLines: 3) == nil,
                "the baseline itself needs a chip — it would no longer isolate the wrap-only case")

        let wrapped = measured(QuestionText(text: longChain), width: Self.narrowPaneWidth)
        let baseline = measured(QuestionText(text: threeLineBaseline), width: Self.narrowPaneWidth)
        #expect(wrapped.height > baseline.height + 15,
                Comment(rawValue: "a wrap-only overflow (\(wrapped.height) pt) is barely taller than a "
                        + "chip-free three-line baseline of the same capped height (\(baseline.height) pt) "
                        + "— the measured chip never rendered"))
    }

    /// **Mutation-resistant, unlike a comparison against the same constant
    /// twice.** Nothing bound
    /// `OverviewLayout.bandSideColumnWidth` to a RENDERED width before
    /// this: every existing band test asked pure arithmetic about the
    /// number, never SwiftUI what it actually laid the controls column out
    /// at. `DetailBand.onControlsColumnWidthMeasured` reports that real
    /// geometry to this test directly; a wiring bug (a stale hardcoded
    /// literal in `columns(for:)`, the wrong constant referenced, a
    /// sibling silently stealing this column's space) would make the
    /// MEASURED width disagree with the constant, which a mutation to the
    /// constant ALONE (with the wiring intact) cannot — that would move
    /// both sides together, correctly, and this test would keep passing,
    /// as it should.
    @Test("the controls column renders at its own declared width")
    func controlsColumnRendersAtItsOwnDeclaredWidth() {
        let runtime = waitingRuntime()
        let captured = WidthCapture()
        let bandWidth = 1568.0 // `.withControls` zones — Controls is its own column here.
        #expect(OverviewLayout.bandZones(for: bandWidth) == .withControls,
                "the fixture's own premise: nothing below measures a column that .actOnly already folded away")
        var probe = DetailBand(runtime: runtime, width: bandWidth,
                               usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        probe.onControlsColumnWidthMeasured = { captured.value = $0 }
        _ = measured(probe, width: bandWidth)
        #expect(abs(captured.value - OverviewLayout.bandSideColumnWidth) < 1,
                Comment(rawValue: "the controls column rendered at \(captured.value) pt, not the declared "
                        + "\(OverviewLayout.bandSideColumnWidth) pt"))
    }

    /// **`AutoContinueToggle` genuinely reaches "This Session" — moved
    /// there PERMANENTLY, the requirement, out of the act zone it used
    /// to compete with a live decision for room in.** No accessibility-tree
    /// walk available to this harness (`bandRendersARealSessionWithoutRunningAway`'s
    /// own doc comment states that limit), so presence is proven the same
    /// way `theColorControlRendersInTheControlsZone` proves Card Color's:
    /// a real height difference between a lane that offers the toggle and
    /// one that does not, both otherwise identical.
    @Test("the controls column renders taller when the session offers auto-continue than when it does not")
    func autoContinueToggleReachesTheControlsZone() {
        let bandWidth = 1568.0
        let withToggle = Self.events()
        var withoutToggle = Self.events()
        withoutToggle.append(.prefsChanged(DeckPrefs(quickActions: []), at: Instant(sinceStart: Millis(25))))

        func controlsHeight(_ events: [DeckEvent]) -> (height: Double, autoContinuable: Bool) {
            let runtime = DeckRuntime()
            runtime.markStartedForTesting()
            runtime.replaceStateForTesting(Reducer.run(events))
            guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
                return (0, false)
            }
            let band = DetailBand(runtime: runtime, width: bandWidth,
                                  usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
            // A generous, deliberately non-binding budget — this test
            // wants the column's own NATURAL height (with vs without the
            // toggle), not a budget-capped one; `controlsZoneNaturalHeightMatchesItsOwnMeasuredConstant`
            // below is where the budget itself is held to account.
            let size = measured(band.controlsZone(for: lane, budget: 1000), width: OverviewLayout.bandSideColumnWidth)
            return (Double(size.height), runtime.frame.autoContinuable)
        }

        let with = controlsHeight(withToggle)
        let without = controlsHeight(withoutToggle)
        #expect(with.autoContinuable, "the fixture's own premise: the default action set offers Continue")
        #expect(!without.autoContinuable,
                "the fixture's own premise: an empty action set offers no Continue to auto-send")
        #expect(with.height > without.height,
                Comment(rawValue: "the controls column measured \(with.height) pt with the toggle offered and "
                        + "\(without.height) pt without — the toggle should cost real, visible room"))
    }

    /// **`OverviewLayout.bandControlsNaturalHeight`'s own live arbiter —
    /// the non-affine-chrome finding's own root-cause constant, pinned.**
    /// Measured with the toggle offered AND a directory present (the full
    /// content `controlsZone(for:budget:)` ever draws), at a deliberately
    /// non-binding budget so the fold never engages here — this is the
    /// UNFOLDED natural height the fold logic compares `budget` against.
    @Test("the controls column's own full natural height matches OverviewLayout.bandControlsNaturalHeight")
    func controlsZoneNaturalHeightMatchesItsOwnMeasuredConstant() {
        let runtime = waitingRuntime()
        guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
            Issue.record("the fixture's own premise: a selected, hosted lane")
            return
        }
        #expect(runtime.frame.autoContinuable, "the fixture's own premise: the toggle should render")
        #expect(lane.directory != nil, "the fixture's own premise: the footnote should render")
        let band = DetailBand(runtime: runtime, width: 1568,
                              usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        let size = measured(band.controlsZone(for: lane, budget: 1000), width: OverviewLayout.bandSideColumnWidth)
        #expect(abs(Double(size.height) - OverviewLayout.bandControlsNaturalHeight) < 1,
                Comment(rawValue: "the controls column's own full natural height measured \(size.height) pt "
                        + "against a declared \(OverviewLayout.bandControlsNaturalHeight) pt — retune the "
                        + "constant to match"))
    }



    /// **The controls column's own budget arbiter.** Below `OverviewLayout
    /// .bandControlsNaturalHeight`, the Directory footnote must fold
    /// rather than let the column silently clip or exceed its own budget
    /// share; at or above it, the footnote stays.
    ///
    /// **`columnsHeightBudget` simplified alongside the Quick Actions
    /// column's move — `usable − 48`, no action-row term to subtract any
    /// more.** Both real strip budgets clear the footnote's own natural
    /// height comfortably now: 419 → 371 pt budget, 359 → 311 pt, both
    /// well past 279 — the everyday state is the footnote SHOWING, not
    /// folding, at either real height. The fold branch still needs a live
    /// case behind it, so a synthetic height under 327 (`bandControlsNaturalHeight
    /// + bandHeaderHeight`, the exact budget-equals-natural boundary) is
    /// what exercises it — 320 pt, a real, reachable sub-419 squeeze (a
    /// narrower desktop window), not a hypothetical.
    @Test("the controls column fits its own budget share at both real strip heights, and folds the footnote at a genuine squeeze")
    func controlsZoneFitsBothRealBudgetsFoldingWhenItMust() {
        let runtime = waitingRuntime()
        guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
            Issue.record("the fixture's own premise: a selected, hosted lane")
            return
        }
        let bandWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        for usableHeight in [QuestionOptionsBand.usableStripHeight, QuestionOptionsBand.usableStripHeight - 60, 320.0] {
            let budget = max(0, usableHeight - OverviewLayout.bandHeaderHeight)
            let band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight, dismissedStage: nil)
            let size = measured(band.controlsZone(for: lane, budget: budget),
                                width: OverviewLayout.bandSideColumnWidth)
            #expect(Double(size.height) <= budget,
                    Comment(rawValue: "at \(usableHeight) pt usable (budget \(budget) pt), the controls column "
                            + "measured \(size.height) pt — must fit its own declared budget share"))
            let shouldFold = budget < OverviewLayout.bandControlsNaturalHeight
            if shouldFold {
                #expect(Double(size.height) < OverviewLayout.bandControlsNaturalHeight,
                        Comment(rawValue: "at \(usableHeight) pt usable, the budget (\(budget) pt) cannot afford "
                                + "the full natural height (\(OverviewLayout.bandControlsNaturalHeight) pt) — "
                                + "the footnote should have folded, but the column still measured "
                                + "\(size.height) pt"))
            } else if usableHeight == 320 {
                Issue.record("320 pt usable was chosen specifically because it SHOULD force the fold (budget \(budget) pt < natural \(OverviewLayout.bandControlsNaturalHeight) pt) — it no longer does, so this arbiter no longer exercises the fold branch at all")
            }
        }
    }

    /// **`OverviewLayout.bandControlsFoldedMinimum`'s own live arbiter.**
    /// Measured with the footnote folded away (a budget between the
    /// folded and unfolded naturals, so the fold engages without ALSO
    /// clipping what survives it).
    @Test("the controls column's own folded minimum matches OverviewLayout.bandControlsFoldedMinimum")
    func controlsZoneFoldedMinimumMatchesItsOwnMeasuredConstant() {
        let runtime = waitingRuntime()
        guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
            Issue.record("the fixture's own premise: a selected, hosted lane")
            return
        }
        let band = DetailBand(runtime: runtime, width: 1568,
                              usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        // Strictly between the folded (244) and unfolded (279) naturals —
        // forces the fold without itself clipping what remains.
        let budget = (OverviewLayout.bandControlsFoldedMinimum + OverviewLayout.bandControlsNaturalHeight) / 2
        let size = measured(band.controlsZone(for: lane, budget: budget), width: OverviewLayout.bandSideColumnWidth)
        #expect(abs(Double(size.height) - OverviewLayout.bandControlsFoldedMinimum) < 1,
                Comment(rawValue: "the folded column measured \(size.height) pt against a declared "
                        + "\(OverviewLayout.bandControlsFoldedMinimum) pt — retune the constant to match"))
    }

    /// **A smoke render, honestly named as one.** A first version of this test called itself a "render-level
    /// proof" of the dedup table while asserting only `height <
    /// stripHeight * 3` — a runaway guard, not a check that any banned
    /// field (the state chip, the permission chip, the context gauge, the
    /// current prompt) is actually ABSENT from what rendered. Proving
    /// absence needs a walk of the rendered accessibility tree this
    /// harness does not build (`NSHostingView` headless off no real
    /// window, unlike the live AX-probe technique this project's own
    /// verification notes use elsewhere) — so this is retitled to what it
    /// actually checks, and the dedup rule itself is enforced the way the
    /// bottom of `DetailBand.swift` already states: `controlsZone(for:)`
    /// and `identityFootnote(for:)` are the ONLY two fields the controls
    /// zone reads, by construction, reviewed at every future edit to
    /// those two functions — the same discipline the now-retired
    /// `SessionSummary`/`SessionIdentity`'s own split at the inspector
    /// relied on for as long as it shipped, with no render-level
    /// enforcement there either (both retired outright when `.inspector`
    /// did — `DeckWindow.swift`'s own top doc comment states the removal
    /// in full).
    @Test("the band renders a real, selected session without crashing or running away")
    func bandRendersARealSessionWithoutRunningAway() {
        let runtime = waitingRuntime()
        #expect(runtime.frame.selection != nil, "the fixture produced no selected lane")

        let band = DetailBand(runtime: runtime, width: 900,
                              usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        let size = measured(band, width: 900)
        #expect(size.height > 0, "the band renders as nothing for a selected lane")
        // A runaway guard, not a fit-strip claim — the same non-finding
        // `inspectorRoutesOnWaitingFor` already documents for a
        // `ScrollView`-bearing view measured unconstrained. `DetailBand`
        // has no `ScrollView` of its own, but `QueueSection`/`SessionControls`
        // are shared components this test does not control the internals of.
        #expect(size.height < Self.stripHeight * 3,
                Comment(rawValue: "the band is \(size.height) pt — a runaway, not merely tall"))
    }

    /// **The live arbiter — the Card Color row actually reaches
    /// the band's controls zone, not merely `SessionControls` measured in
    /// isolation.** `.withControls` zones (`controlsColumnRendersAtItsOwnDeclaredWidth`'s
    /// own 1568 pt fixture, reused rather than re-derived) so Controls is
    /// composed as its own column at all — `.actOnly` folds it away
    /// entirely (`compactControlsMenu`'s own doc comment states that scope
    /// decision).
    @Test("the color control renders in the band's controls zone")
    func theColorControlRendersInTheControlsZone() {
        let runtime = waitingRuntime()
        let bandWidth = 1568.0
        #expect(OverviewLayout.bandZones(for: bandWidth) == .withControls,
                "the fixture's own premise: nothing below composes a controls column .actOnly would fold away")
        let band = DetailBand(runtime: runtime, width: bandWidth,
                              usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        let size = measured(band, width: bandWidth)
        #expect(size.height > 0, "the band renders as nothing for a hosted, selected lane")

        // The coarse, non-crashing proof `bandRendersARealSessionWithoutRunningAway`
        // already documents as this harness's ceiling — walking the
        // rendered accessibility tree to prove the row's own text is on
        // screen is not a technique this file's headless harness has. What
        // IS checked here directly: `CardColorPicker` — the view the row's
        // own `.popover` presents — builds and measures as a real, sized
        // control, at the natural size a popover would actually show.
        let lane = runtime.frame.lanes.first { $0.session == runtime.frame.selection }
        guard let lane else {
            Issue.record("the fixture's own premise: a selected, hosted lane to build the picker for")
            return
        }
        let picker = measured(CardColorPicker(lane: lane, runtime: runtime), width: 280)
        #expect(picker.height > 0, "the picker renders as nothing")
        #expect(picker.height < Self.stripHeight,
                Comment(rawValue: "the picker is \(picker.height) pt — taller than the strip it opens on"))
    }

    /// **The hide precedent, extended to the color row — structural, the
    /// same coarse technique this file already leans on.** Proving a row
    /// is ABSENT needs a walk of the rendered accessibility tree this
    /// harness does not build (`bandRendersARealSessionWithoutRunningAway`'s
    /// own doc comment states the limit); what this measures instead is
    /// that a directory-less, host-less lane's `SessionControls` renders
    /// noticeably SHORTER than a lane carrying BOTH with the identical
    /// `showsColorPicker: true` — the only structural difference between
    /// the two calls is which rows the two INDEPENDENT gates let through
    /// (`lane.host != nil` for Hide, `lane.directory != nil` for Card
    /// Color), so a height gap on the order of two whole rows is the
    /// coarse proof available here.
    @Test("a hostless, directory-less lane's controls render with no Hide row and no Color row")
    func hostlessLaneControlsRenderShorter() {
        let hosted = LaneView(session: SessionID("aaaaaaaa-1111"), state: .idle, isExpanded: false,
                              contextPercent: nil, sources: [:],
                              directory: Redacted("/w/hosted"),
                              host: HostAddress(workspace: "w", surface: "s"))
        let hostless = LaneView(session: SessionID("bbbbbbbb-2222"), state: .idle, isExpanded: false,
                                contextPercent: nil, sources: [:])
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()

        let hostedHeight = measured(SessionControls(lane: hosted, runtime: runtime,
                                                     showsColorPicker: true), width: 320).height
        let hostlessHeight = measured(SessionControls(lane: hostless, runtime: runtime,
                                                       showsColorPicker: true), width: 320).height

        // Two whole rows' worth (Hide, Card Color), each cleared by
        // `TouchTarget.minimum` plus the `VStack`'s own 8 pt spacing —
        // comfortably inside a real gap and comfortably outside layout
        // noise from the one row (Remove) both renderings share.
        #expect(hostedHeight - hostlessHeight > TouchTarget.minimum, Comment(rawValue:
                "hosted \(hostedHeight) pt vs. hostless \(hostlessHeight) pt — the gap is too small " +
                "to be both the Hide row and the Card Color row"))
    }

    /// The runtime-side half of the same gate: `setCardColor` on a session
    /// the reducer never gave a DIRECTORY must not touch prefs at all. The
    /// view gate above and this one are independent — a future edit could
    /// pass the view's own check while the runtime call underneath it
    /// forgot its guard, or the reverse — so both are pinned rather than
    /// one standing in for the other. (The write-COUNT version of this
    /// claim, through the real spy rig, lives in `PrefsPersistenceTests
    /// .setCardColorOnADirectorylessSessionWritesNothing`; this is the
    /// value-level echo of it, cheap enough to keep beside the view test it
    /// accompanies.)
    @Test("setCardColor on a directory-less lane leaves that lane's colour exactly where it was")
    func setCardColorOnADirectorylessLaneChangesNothing() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run([
            .hook(HookEvent(id: EventID("hostless"), at: Instant(sinceStart: Millis(0)),
                            kind: .sessionStart, session: SessionID("no-host"), cwd: nil,
                            tool: nil, toolUseID: nil, held: .absent)),
        ]))
        let before = runtime.prefs.directoryColors
        runtime.setCardColor(.slot(1), for: SessionID("no-host"))
        #expect(runtime.prefs.directoryColors == before,
                "a directory-less session's colour changed even though there is no directory to key it on")
    }

    /// The ticks, actually built — not only the pure projection
    /// `ShellTests.ticksProjectOffViewportNeedsYou` already holds. One
    /// needs-you lane off the narrowed viewport, one calm lane, and the
    /// empty case, all through the real `Ticks` view this file's own
    /// mandate ("nine views had never been instantiated by any test") is
    /// about.
    @Test("the ticks render, marked or empty, and never crash on an empty fleet")
    func ticksRender() {
        let waiting = LaneView(session: SessionID("waiting"), state: .needsYou, isExpanded: false,
                               contextPercent: nil, sources: [:])
        let selected = LaneView(session: SessionID("selected"), state: .needsYou, isExpanded: false,
                                contextPercent: nil, sources: [:])
        let marked = measured(Ticks(lanes: [waiting, selected], selection: selected.session),
                              width: OverviewLayout.bandSeamWidth)
        #expect(marked.height > 0, "a tick for an off-viewport needs-you lane renders as nothing")

        let calm = measured(Ticks(lanes: [selected], selection: selected.session), width: OverviewLayout.bandSeamWidth)
        #expect(calm.height >= 0)

        let empty = measured(Ticks(lanes: [], selection: nil), width: OverviewLayout.bandSeamWidth)
        #expect(empty.height >= 0, "an empty fleet crashed or produced a negative height")
    }

    /// **`.actOnly` — the third zone tier, actually rendered.** Below
    /// `OverviewLayout.bandCompactThreshold` even Controls folds into the
    /// act zone's own footer, as `DetailBand.compactControlsMenu(for:)` —
    /// an ellipsis menu, chosen over a trailing compact strip because a
    /// menu costs one row regardless of how many controls it holds, where
    /// a strip of icon buttons costs width the narrowest band has the
    /// least of. Checked at a bandWidth in `.actOnly`'s own range
    /// (`OverviewLayoutTests.actOnlyIsReachableAtRowsOwnMinimumWidth`
    /// holds the arithmetic that range is non-empty).
    @Test("the act-only zone renders, with queue and controls both folded into its own footer")
    func actOnlyZoneRenders() {
        let runtime = waitingRuntime()
        // 700, not the .actOnly range's own narrow end: below
        // `OverviewLayout.bandActMinWidth` (620) the act zone's own
        // `.frame(minWidth:)` cannot be honoured within the band width
        // given at all — a real, separate overflow this test does not
        // conflate with the zone-drop rule it exists to check.
        let bandWidth = 700.0
        #expect(OverviewLayout.bandZones(for: bandWidth) == .actOnly,
                "the fixture's own premise: nothing below measures the .actOnly tier")
        let size = measured(DetailBand(runtime: runtime, width: bandWidth,
                                       usableHeight: QuestionOptionsBand.usableStripHeight,
                                       dismissedStage: nil),
                            width: bandWidth)
        #expect(size.height > 0, "the act-only band renders as nothing for a selected lane")
        #expect(size.height < Self.stripHeight * 3,
                Comment(rawValue: "the act-only band is \(size.height) pt — a runaway, not merely tall"))
    }

    /// **Every act-zone fallback state, actually instantiated.** With no
    /// live decision to answer, `DetailBand.actZoneFallback(for:)` draws
    /// one of four designed states — `.needsYou`'s evidenced-panel-or-notice
    /// split is already exercised elsewhere in this file; `.ended`,
    /// `.errored` and the idle/working placeholder are new to this feature
    /// and had no render coverage before this.
    @Test("the act zone's designed fallback states all render, ended and errored included",
          arguments: [LaneState.ended, .errored, .idle, .working])
    func actZoneFallbackStatesRender(_ state: LaneState) {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let lane = LaneView(session: SessionID("fallback"), state: state, isExpanded: false,
                            contextPercent: nil, sources: [:])
        let band = DetailBand(runtime: runtime, width: OverviewLayout.bandActMinWidth,
                              usableHeight: QuestionOptionsBand.usableStripHeight, dismissedStage: nil)
        let size = measured(band.actZone(for: lane), width: OverviewLayout.bandActMinWidth)
        #expect(size.height > 0,
                Comment(rawValue: "the act zone's \(state.rawValue) fallback renders as nothing"))
    }

    // ----------------------------------------------------------- card fit

    /// **The floor a container-derived height must never squeeze a card
    /// below — "bounded cards always," the ragged-bottom doctrine's
    /// successor.** A `.row` card no longer reports its own natural
    /// content height to the glass; `SessionOverview`'s call site now
    /// stretches it to fill whatever the fleet region gives it
    /// (`maxHeight: .infinity`, `SessionCard`'s own `Spacer(minLength: 0)`
    /// absorbing the difference between the prompt and the pinned footer).
    /// What THIS test still measures — the bare, unconstrained card,
    /// exactly as it always has been — is the OTHER half of that claim: the
    /// natural content itself must stay under the strip's own budget, or a
    /// region no taller than the strip would have nothing left to stretch
    /// into. A card whose own content already exceeds the region is a card
    /// bounded cards cannot save; that failure has to be caught here, at
    /// the content's own natural size, because no headless measurement of
    /// the STRETCHED card can tell an honest fill apart from a silent clip
    /// — `SessionOverview`'s own comment on the trade this test cannot
    /// make notes why the stretch itself is judged live, not here.
    @Test("a full card's own content stays under the strip's budget", arguments: LaneState.allCases)
    func aFullCardFitsTheStrip(_ state: LaneState) {
        let size = measured(SessionCard(lane: lane(state), name: "workspace/openagentdeck",
                                        disambiguator: "0ba90d", isSelected: true),
                            width: OverviewLayout.cardIdealWidth)
        #expect(size.height > 0)
        // Minus the padding the fleet puts around it and the status line below.
        #expect(size.height < Self.stripHeight - 60,
                Comment(rawValue: "a \(state.rawValue) card is \(size.height) pt and the "
                        + "strip is \(Self.stripHeight)"))
    }

    /// **The wash is background-only — proven by measurement, not merely
    /// asserted in a comment.** `CardWash` sits in `.background`, which
    /// SwiftUI never lets influence a view's own layout; one otherwise-
    /// identical lane, measured across every state — idle/ended washing
    /// nothing, working/needsYou/errored washing at three different
    /// intensities — must come back at the SAME height an idle card does,
    /// or the wash is reaching layout. `needsYou` is measured a second
    /// time with Reduce Motion off — the one combination whose wash
    /// actually animates (`SessionCard.washStyle`'s `.pulsing` case) — for
    /// a reason a height comparison alone would not catch on its own: a
    /// `phaseAnimator` node that somehow blocked or hung headless would
    /// make this MEASUREMENT ITSELF never return, so a pulsing card
    /// hosting cleanly at all is as much a part of what this test proves
    /// as the height it comes back with.
    @Test("the wash costs no layout", arguments: LaneState.allCases)
    func theWashCostsNoLayout(_ state: LaneState) {
        let baseline = measured(SessionCard(lane: lane(.idle), name: "workspace/openagentdeck",
                                            disambiguator: "0ba90d", isSelected: true),
                                width: OverviewLayout.cardIdealWidth)
        let underTest = measured(SessionCard(lane: lane(state), name: "workspace/openagentdeck",
                                             disambiguator: "0ba90d", isSelected: true,
                                             reduceMotion: false),
                                 width: OverviewLayout.cardIdealWidth)
        #expect(underTest.height == baseline.height, Comment(rawValue:
                "\(state.rawValue)'s wash measured \(underTest.height) pt against an idle card's " +
                "\(baseline.height) pt — the wash is reaching layout"))

        if state == .needsYou {
            let reduced = measured(SessionCard(lane: lane(state), name: "workspace/openagentdeck",
                                               disambiguator: "0ba90d", isSelected: true,
                                               reduceMotion: true),
                                   width: OverviewLayout.cardIdealWidth)
            #expect(reduced.height == baseline.height, Comment(rawValue:
                    "needsYou under reduce motion measured \(reduced.height) pt against " +
                    "\(baseline.height) pt — the wash is reaching layout"))
        }
    }

    // ------------------------------------------------- the two-row fleet

    /// **The footer's own live truncation bug, reproduced headlessly.**
    ///
    /// SwiftUI's fair-share allocation proposes each unprioritized child
    /// `remaining ÷ unallocated-children` while the footer's own
    /// `Spacer(minLength: 4)` still counts in that divisor, so a chip whose
    /// IDEAL width the row has real slack for can still be offered less
    /// than it needs. Measured, in THIS test's own red run before the fix:
    /// "Working"'s own state chip wants 75 pt and the footer rendered it at
    /// 71 pt — clipping "Working" to "Worki…" while the row's own content
    /// (~230 pt ideal against 276 pt available) left real slack unused;
    /// "Idle" fits under the share, which is why only busy cards clipped,
    /// and "Needs you" (~86 pt ideal) clipped worst of all.
    /// `.layoutPriority(1)` on the state chip — the SAME idiom the tags
    /// row already uses on the permission badge (`tags`'s own doc comment:
    /// a truncated badge "is the deck failing at its job") — is the fix.
    /// This measures the chip's own RENDERED width inside the real card,
    /// through the `onStateChipWidthMeasured` seam, against the chip's own
    /// unconstrained ideal, rather than trusting a screenshot — for both
    /// the state that was CAUGHT clipping and the widest chip the enum can
    /// produce, since a fix proven only on the reported case would leave
    /// the worst one to a hand-summed estimate.
    @Test("the state chip never truncates in the footer",
          arguments: [LaneState.working, .needsYou])
    func theStateChipNeverTruncatesInTheFooter(_ state: LaneState) {
        let idealChip = NSHostingView(rootView: Chip(ChipSpec.state(state))).fittingSize
        let captured = WidthCapture()
        var card = SessionCard(lane: lane(state), name: "workspace/openagentdeck",
                               disambiguator: "0ba90d", isSelected: true)
        card.onStateChipWidthMeasured = { captured.value = $0 }
        _ = measured(card, width: OverviewLayout.cardIdealWidth)
        #expect(captured.value >= idealChip.width - 1,
                Comment(rawValue: "the \(state) chip's own unconstrained ideal is \(idealChip.width) pt; "
                        + "the footer only rendered it at \(captured.value) pt — it is truncating"))
    }

    /// **`OverviewLayout.fleetRowMinimumHeight`, `fleetPromptBlockCost` and
    /// `fleetPromptLinePitch`'s own live arbiter, together — the one probe
    /// all three constants were read off.** A worst-realistic card — tags
    /// row, footer, gauge, all present, at `cardIdealWidth` — pins the
    /// PROMPTLESS floor first (`fleetRowMinimumHeight`'s own doc comment
    /// carries its full history: 3-line card → 1-line card → no prompt
    /// block at all, each retune widening the two-row range), then a 1-line prompt and a 3-line one off the SAME
    /// lane, so the block cost and the per-line pitch are both read as
    /// DIFFERENCES between real renders rather than restated as separate
    /// literals. Every prompted render uses the same hard-newline idiom
    /// `theQuestionTextRendersAWrapOnlyChip` (above) uses for its own
    /// baselines of a KNOWN line count, rather than a long run-on string
    /// whose actual wrap count would depend on font metrics this test does
    /// not control.
    @Test("a full card's own content stays under the two-row fleet's per-row budget, at both ends of the flex")
    func aFullCardFitsTheTwoRowBudget() {
        let promptless = measured(SessionCard(lane: promptlessLane(), name: "workspace/openagentdeck",
                                              disambiguator: "0ba90d", isSelected: true),
                                  width: OverviewLayout.cardIdealWidth)
        #expect(promptless.height <= OverviewLayout.fleetRowMinimumHeight,
                Comment(rawValue: "a promptless, tagged, footer-bearing card measured \(promptless.height) pt "
                        + "— over fleetRowMinimumHeight (\(OverviewLayout.fleetRowMinimumHeight) pt); "
                        + "re-measure and retune the constant"))

        let oneLinePrompt = "prompt line 1"
        let oneLine = measured(SessionCard(lane: lane(.working, prompt: oneLinePrompt),
                                           name: "workspace/openagentdeck",
                                           disambiguator: "0ba90d", isSelected: true),
                               width: OverviewLayout.cardIdealWidth)
        let oneLineBudget = OverviewLayout.fleetRowMinimumHeight + OverviewLayout.fleetPromptBlockCost
        #expect(oneLine.height <= oneLineBudget,
                Comment(rawValue: "a 1-line, tagged, footer-bearing card measured \(oneLine.height) pt — over "
                        + "fleetRowMinimumHeight + fleetPromptBlockCost (\(oneLineBudget) pt); re-measure "
                        + "and retune the constant"))

        let measuredBlockCost = oneLine.height - promptless.height
        let blockCostStillMatches = measuredBlockCost == OverviewLayout.fleetPromptBlockCost
        #expect(blockCostStillMatches,
                Comment(rawValue: "the measured cost of the whole prompt block (one-line card minus "
                        + "promptless card, \(measuredBlockCost) pt) no longer matches fleetPromptBlockCost "
                        + "(\(OverviewLayout.fleetPromptBlockCost)); re-measure and retune"))

        let threeLinePrompt = (1...3).map { "prompt line \($0)" }.joined(separator: "\n")
        let threeLine = measured(SessionCard(lane: lane(.working, prompt: threeLinePrompt),
                                             name: "workspace/openagentdeck",
                                             disambiguator: "0ba90d", isSelected: true),
                                 width: OverviewLayout.cardIdealWidth)
        let threeLineBudget = oneLineBudget + 2 * OverviewLayout.fleetPromptLinePitch
        #expect(threeLine.height <= threeLineBudget,
                Comment(rawValue: "a 3-line, tagged, footer-bearing card measured \(threeLine.height) pt — "
                        + "over fleetRowMinimumHeight + fleetPromptBlockCost + 2 × fleetPromptLinePitch "
                        + "(\(threeLineBudget) pt); re-measure and retune the pitch"))

        let measuredPitch = (threeLine.height - oneLine.height) / 2
        let pitchStillMatches = measuredPitch == OverviewLayout.fleetPromptLinePitch
        #expect(pitchStillMatches,
                Comment(rawValue: "the measured slope between the 1-line and 3-line card "
                        + "(\(measuredPitch) pt/line) no longer matches fleetPromptLinePitch "
                        + "(\(OverviewLayout.fleetPromptLinePitch)); re-measure and retune"))

        // The widened floor's whole claim: even the exact two-row boundary's
        // own per-row share — the tightest a two-row fleet is ever asked to
        // honor — carries the promptless card, the ladder's own strongest
        // claim about itself.
        let boundaryShare = OverviewLayout.fleetRowShare(usableHeight: 262.0)
        #expect(OverviewLayout.fleetRowMinimumHeight <= boundaryShare,
                Comment(rawValue: "fleetRowMinimumHeight (\(OverviewLayout.fleetRowMinimumHeight) pt) no "
                        + "longer clears the two-row boundary's own per-row share (\(boundaryShare) pt)"))
    }

    /// **`OverviewLayout.promptLineLimit(usableHeight:rows:)`'s own live
    /// arbiter for the one-row, 8-line case.** An 8-line prompt, capped at
    /// `promptLineLimit(usableHeight:rows: 1)` — `rows < 2` ignores
    /// `usableHeight` entirely, so any value stands in for it here — must
    /// still fit the TIGHTEST single-row card container the strip ever
    /// offers: the banner-up budget (359 pt) minus the fleet's own outer
    /// padding on both edges.
    @Test("an eight-line prompt card fits the tightest single-row card container")
    func anEightLinePromptCardFitsTheTightestSingleRowCard() {
        let eightLinePrompt = (1...8).map { "prompt line \($0)" }.joined(separator: "\n")
        let size = measured(SessionCard(lane: lane(.working, prompt: eightLinePrompt),
                                        name: "workspace/openagentdeck",
                                        disambiguator: "0ba90d", isSelected: true,
                                        promptLineLimit: OverviewLayout.promptLineLimit(usableHeight: 359.0,
                                                                                        rows: 1)),
                            width: OverviewLayout.cardIdealWidth)
        let tightestSingleRowBudget = 359.0 - 2 * OverviewLayout.fleetOuterPadding
        #expect(size.height <= tightestSingleRowBudget,
                Comment(rawValue: "an 8-line prompt card measured \(size.height) pt — over the banner-up "
                        + "strip's own tightest single-row budget (\(tightestSingleRowBudget) pt)"))
    }

    /// **`SessionCard`'s own promptBlock call site — proof the 0 tier
    /// actually removes the block from the render, not merely caps its
    /// line count at zero.** The SAME lane, carrying a long prompt,
    /// measured twice: once with `promptLineLimit: 0` (the call site's own
    /// `if let prompt = ..., promptLineLimit > 0` condition should
    /// suppress the block entirely) and once with `prompt: nil` on the
    /// lane instead (`promptlessLane()` — no block to suppress, since the
    /// pre-existing `if let prompt = lane.prompt?.value` half of that same
    /// condition already handled this case before the 0 tier existed).
    /// Equal heights are the proof: had the 0 tier only capped
    /// `Text(...).lineLimit(0)` rather than skipping `promptBlock(_:)`
    /// altogether, the first render would still carry the "LAST USER
    /// PROMPT" caption and the interior stack's own gap that only appears
    /// once the block is present (`fleetPromptBlockCost`'s own 13 + 3 pt
    /// of that decomposition), and the two renders would differ by
    /// exactly that amount instead of matching.
    @Test("a zero-line prompt limit draws no prompt block at all")
    func aZeroLineCardDrawsNoPromptBlock() {
        let longPrompt = (1...8).map { "prompt line \($0)" }.joined(separator: "\n")
        let zeroLimit = measured(SessionCard(lane: lane(.working, prompt: longPrompt),
                                             name: "workspace/openagentdeck",
                                             disambiguator: "0ba90d", isSelected: true,
                                             promptLineLimit: 0),
                                 width: OverviewLayout.cardIdealWidth)
        let noPromptAtAll = measured(SessionCard(lane: promptlessLane(), name: "workspace/openagentdeck",
                                                 disambiguator: "0ba90d", isSelected: true),
                                     width: OverviewLayout.cardIdealWidth)

        let heightsMatch = zeroLimit.height == noPromptAtAll.height
        #expect(heightsMatch,
                Comment(rawValue: "a promptLineLimit: 0 card (with a real, long prompt on its lane) measured "
                        + "\(zeroLimit.height) pt but the same card with no prompt on its lane at all measured "
                        + "\(noPromptAtAll.height) pt — the 0 tier is capping lines rather than removing "
                        + "the block"))

        #expect(zeroLimit.height <= OverviewLayout.fleetRowMinimumHeight,
                Comment(rawValue: "a promptLineLimit: 0 card measured \(zeroLimit.height) pt — over "
                        + "fleetRowMinimumHeight (\(OverviewLayout.fleetRowMinimumHeight) pt)"))
    }

    /// **A smoke render — the two-row `LazyHGrid` actually builds, with
    /// enough lanes to fill a second column.** `theFleetRenders` above
    /// already covers every `OverviewLayout` case at `fleetSize: .zero`
    /// (always 1 row); this is the two-row shape specifically, at the
    /// strip's own banner-down budget.
    @Test("the two-row fleet renders")
    func theTwoRowFleetRenders() {
        let runtime = multiLaneRuntime(ids: ["a", "b", "c", "d"], selected: "a")
        #expect(runtime.frame.lanes.count == 4, "the fixture's own premise: four lanes for a two-row fleet")
        let size = measured(SessionOverview(runtime: runtime, layout: .row,
                                            fleetSize: CGSize(width: 1920, height: 419), banded: false),
                            width: Self.stripWidth)
        #expect(size.height > 0, "the two-row fleet renders as nothing")
    }

    /// **RETIRED — `theQueueSectionRenders` used to live here.** It proved
    /// the queue empty and full, against `QueueSection` itself — the
    /// composed GroupBox section, silent (zero height) with nothing queued,
    /// visible with something in it. That composition retired along with
    /// its last production caller (`QueueSection`'s own doc comment,
    /// `SessionActions.swift`, states the history in full: `.inspector` is
    /// retired now, `DeckWindow.swift`'s own top doc comment states the
    /// removal in full). `TranscriptWell` is where the queue renders on the
    /// band today, merged into "This Session"'s own ledger rather than a
    /// standalone section with its own silent-when-empty rule;
    /// `transcriptWellRendersARealMergedLedger` and
    /// `transcriptWellEmptyStateMatchesTheOldPlaceholder` (above) are that
    /// surface's own empty/populated proofs now.

    /// The per-session menu. A context menu is a `ViewBuilder` of buttons
    /// rather than a laid-out view, so what is checked is that it BUILDS — the
    /// failure this catches is a menu referencing a runtime method that no
    /// longer exists, which is precisely what `unhide` was added for.
    @Test("the session menu builds for a hidden lane and a visible one")
    func theSessionMenuBuilds() {
        let runtime = waitingRuntime()
        for hidden in [false, true] {
            let l = LaneView(session: SessionID("alpha"), state: .idle, isExpanded: false,
                             contextPercent: nil, sources: [:],
                             host: HostAddress(workspace: "w", surface: "s"),
                             isHidden: hidden)
            let size = NSHostingView(rootView: VStack { SessionMenu(lane: l, runtime: runtime) })
                .fittingSize
            #expect(size.height > 0,
                    Comment(rawValue: "the menu for a \(hidden ? "hidden" : "visible") lane is empty"))
        }
    }

    /// **The session-controls panel's own live arbiter for the Card Color
    /// gate — inherited from the `Menu` this panel replaced, and now held
    /// against the surface that actually draws it.**
    ///
    /// The gate is unchanged and so is the reason for it: a colour
    /// preference is DIRECTORY-keyed (`runtime.setCardColor`), so the tile
    /// is offered on `lane.directory != nil` rather than on the
    /// `lane.host != nil` that gates Hide — a lane can have a host before
    /// its `cwd` has ever resolved, and one gate standing in for the other
    /// would open a picker with nothing to write through.
    ///
    /// Measured against a KNOWN baseline in both directions: the two lanes
    /// differ by exactly one field, `directory`, so any growth is
    /// attributable to that field alone (PRESENCE), and the directory-less
    /// panel must not grow at all (ABSENCE).
    @Test("the session controls panel offers Card Color exactly when lane.directory is known")
    func sessionActionsPanelOffersCardColorExactlyWhenDirectoryKnown() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        #expect(runtime.frame.autoContinuable == false,
                "the fixture's own premise: no selection, so no auto-continue switch to confound the gap")

        let bareLane = LaneView(session: SessionID("eeeeeeee-1111"), state: .idle, isExpanded: false,
                                contextPercent: nil, sources: [:],
                                host: HostAddress(workspace: "w", surface: "s"))
        let coloredLane = LaneView(session: SessionID("ffffffff-2222"), state: .idle, isExpanded: false,
                                   contextPercent: nil, sources: [:],
                                   directory: Redacted("/w/colorable"),
                                   host: HostAddress(workspace: "w", surface: "s"))

        // **Measured at a width that forces ONE column.** The grid is
        // `.adaptive(minimum: 210)`, so at a generous width the Card Color
        // tile shares a row with its neighbour and costs nothing in height —
        // which is how the first rewrite of this test came to assert only
        // `with >= without` and pass with the tile deleted entirely. At 240
        // pt every tile is its own row, so the gate's answer is a whole row
        // of height and the assertion can be exact in both directions.
        func height(_ lane: LaneView) -> Double {
            let view = SessionActionsPanel(lane: lane, runtime: runtime, dismiss: {}, showingColors: .constant(false))
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 240, height: 10)
            host.layoutSubtreeIfNeeded()
            return Double(host.fittingSize.height)
        }

        let without = height(bareLane)
        let with = height(coloredLane)

        // PRESENT: one more row, so at least the tile's own floor. Compared
        // against a real number rather than an inequality that a deleted
        // tile would also satisfy.
        #expect(with - without >= TouchTarget.decision, Comment(rawValue:
                "a directory-bearing panel measured \(with) pt against a directory-less \(without) pt — "
                + "too small a gap to be the Card Color tile, which should have rendered for a lane "
                + "the gate allows"))

        // **The ABSENT direction, stated as a real bound rather than a
        // tautology.** An earlier version measured `height(bareLane)` twice
        // and compared the results, which is the same pure function on the
        // same input — it could only fail if `NSHostingView` were
        // nondeterministic, and asserted nothing at all about the gate. What
        // actually holds the absent case is that the directory-less panel is
        // SHORTER than one row, i.e. the tile genuinely is not drawn.
        #expect(with - without < TouchTarget.decision * 2, Comment(rawValue:
                "the gap of \(with - without) pt is larger than the one tile the gate governs — "
                + "something other than Card Color is differing between these two lanes"))
    }

    /// **The panel must fit the strip, or scroll — never overflow it
    /// silently.**
    ///
    /// The deck's home is an 8.8" 1920x480 touchscreen, and the panel with
    /// its colour picker open wants 923 pt against 419 pt of usable height —
    /// measured, not estimated. The `.popover` this replaced was sized and
    /// positioned by AppKit; a hand-built modal has to do that work itself,
    /// and getting it wrong pushes the custom-colour sliders off the bottom
    /// with nothing to scroll.
    ///
    /// **Asserts on the SCROLLER, not on a frame.** A first version of this
    /// test set `host.frame` and then checked `host.frame.height`, which
    /// reads back the value it just assigned: `layoutSubtreeIfNeeded()` does
    /// not resize an `NSHostingView` whose `sizingOptions` are empty, so the
    /// bare panel with no fallback at all passed it. Presence of an
    /// `NSScrollView` in the hosted tree is the fact that actually
    /// distinguishes "reachable" from "clipped", and it answers in BOTH
    /// directions — which is what makes it a test rather than a formality.
    @Test("the session controls panel gains a scroller exactly when its content outgrows the strip")
    func sessionActionsPanelFitsTheStrip() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        let lane = LaneView(session: SessionID("aaaaaaaa-1111"), state: .idle, isExpanded: false,
                            contextPercent: nil, sources: [:],
                            directory: Redacted("/w/colorable"),
                            host: HostAddress(workspace: "w", surface: "s"))
        let usable = QuestionOptionsBand.usableStripHeight

        // What the presenter puts on screen, built the same way.
        func presented(colorsOpen: Bool) -> some View {
            ViewThatFits(in: .vertical) {
                SessionActionsPanel(lane: lane, runtime: runtime, dismiss: {},
                                    showingColors: .constant(colorsOpen))
                ScrollView {
                    SessionActionsPanel(lane: lane, runtime: runtime, dismiss: {},
                                        showingColors: .constant(colorsOpen))
                }
            }
        }
        func hosted(_ view: some View) -> NSHostingView<some View> {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: 1920, height: usable)
            host.layoutSubtreeIfNeeded()
            return host
        }
        func scrollers(_ view: NSView) -> Int {
            (view is NSScrollView ? 1 : 0) + view.subviews.reduce(0) { $0 + scrollers($1) }
        }

        // The hazard is real: with the picker open the panel wants far more
        // than the strip has. If this ever stops being true the fallback has
        // become dead code and should be reconsidered, not left standing.
        let wanted = NSHostingView(rootView: SessionActionsPanel(
            lane: lane, runtime: runtime, dismiss: {}, showingColors: .constant(true)))
        wanted.sizingOptions = [.intrinsicContentSize]
        wanted.frame = NSRect(x: 0, y: 0, width: 1920, height: usable)
        wanted.layoutSubtreeIfNeeded()
        #expect(Double(wanted.fittingSize.height) > usable, Comment(rawValue:
                "the open panel wants \(wanted.fittingSize.height) pt against \(usable) pt of strip — "
                + "if it now fits, this fallback is dead code"))

        #expect(scrollers(hosted(presented(colorsOpen: true))) == 1, Comment(rawValue:
                "content taller than the strip rendered with nothing to scroll — the custom-colour "
                + "sliders would be off the bottom edge with no way to reach them"))
        #expect(scrollers(hosted(presented(colorsOpen: false))) == 0, Comment(rawValue:
                "content that fits gained a scroller anyway, so the ordinary case no longer renders "
                + "as it did"))
    }

    /// **The whole point of replacing the menu, measured on the controls
    /// that ship rather than on lookalikes.**
    ///
    /// The dropdown this panel replaced was an `NSMenu`: ~22 pt rows, and
    /// auto-continue reporting ON as a ~10 pt tick in a leading gutter. Both
    /// are pointer sizes on a deck whose primary surface is a touchscreen.
    /// So the floor is the point of the change, and it is checked here the
    /// way `decisionButtonsAreBigEnough` learned to check its own — against
    /// the REAL views, built by the same initialisers production uses.
    /// `DecisionBar.control`'s own doc comment carries why that distinction
    /// is load-bearing: a lookalike with the floor reattached by hand always
    /// clears the floor, and the shipped control had been 57 x 24 pt for
    /// months underneath exactly such a test.
    @Test("every control in the session panel clears the decision touch floor")
    func sessionActionsPanelControlsAreBigEnough() {
        func measure(_ view: some View, width: Double) -> CGSize {
            let host = NSHostingView(rootView: view)
            host.frame = NSRect(x: 0, y: 0, width: width, height: 10)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize
        }

        let tile = measure(SessionActionTile(title: "Hide from the Deck",
                                             systemImage: "eye.slash", action: {}), width: 210)
        #expect(Double(tile.height) >= TouchTarget.decision, Comment(rawValue:
                "a session action tile rendered \(tile.height) pt tall, under the "
                + "\(TouchTarget.decision) pt decision floor this panel exists to impose"))

        let toggle = measure(SessionActionSwitch(title: "Continue automatically",
                                                 systemImage: "forward.fill", isOn: true,
                                                 help: "", set: { _ in }), width: 520)
        #expect(Double(toggle.height) >= TouchTarget.decision, Comment(rawValue:
                "the auto-continue switch rendered \(toggle.height) pt tall, under the "
                + "\(TouchTarget.decision) pt decision floor — the stock AppKit switch it replaces "
                + "was 24 pt, which is the entire reason it was replaced"))

        // The OFF state must be no smaller than the ON state: a control that
        // shrank when it was off would be hardest to hit exactly when it is
        // the thing you are reaching for.
        let off = measure(SessionActionSwitch(title: "Continue automatically",
                                              systemImage: "forward.fill", isOn: false,
                                              help: "", set: { _ in }), width: 520)
        #expect(Double(off.height) >= TouchTarget.decision)
        #expect(abs(Double(off.height) - Double(toggle.height)) < 1, Comment(rawValue:
                "the switch changes size with its own state (\(off.height) off vs \(toggle.height) on), "
                + "so the target moves under the finger as it is used"))
    }

    /// **`OverviewLayout.bandHeaderHeight`'s own live arbiter, extended to
    /// the shape that used to lose Card Color entirely — the folded
    /// header, for a lane the picker CAN act on.** `bandHeaderAndAutoContinueMatchTheirNamedHeights`
    /// and `headerCarriesBothFoldsTogether` (above) already hold the
    /// header to exactly `bandHeaderHeight` (48) at several geometries,
    /// but neither one states in its own name that the fixture behind it
    /// carries a directory — this does, deliberately, so the claim "the
    /// header stays 48 pt even with the new Card Color item present" has
    /// a test that says exactly that rather than one a reader has to
    /// infer it from.
    @Test("the folded header stays exactly bandHeaderHeight with the Card Color item present")
    func foldedHeaderStaysNamedHeightWithCardColorPresent() {
        let runtime = Self.liveNeedsYouBandShapeRuntime(quickActions: Self.manyActions(10))
        guard let lane = runtime.frame.lanes.first(where: { $0.session == runtime.frame.selection }) else {
            Issue.record("the fixture's own premise: a selected lane")
            return
        }
        #expect(lane.directory != nil,
                "the fixture's own premise: a directory-bearing lane, so the Card Color item is actually in play")

        // The min window's own band width at a squeezed usable height —
        // `theHeaderFoldAppearsExactlyWhenTheColumnFallsShortOfCapacity`'s
        // own fixture, `!controlsShown` there by the SAME arithmetic, so
        // the compact menu (Card Color included) is what the header
        // actually draws here.
        let bandWidth = 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let usableHeight = 249.0
        let plan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 10, usableHeight: usableHeight)
        #expect(!plan.controlsShown,
                Comment(rawValue: "the fixture's own premise: Controls folded into the compact menu — got " +
                        "controlsShown \(plan.controlsShown)"))

        let header = measured(DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                                         dismissedStage: nil).header, width: bandWidth)
        #expect(Double(header.height) == OverviewLayout.bandHeaderHeight,
                Comment(rawValue: "the folded header measured \(header.height) pt with the Card Color item " +
                        "present — expected OverviewLayout.bandHeaderHeight (\(OverviewLayout.bandHeaderHeight) " +
                        "pt), unchanged"))
    }

    // ------------------------------------------------------------- setting up

    /// **The setup surface has to fit the hardware it sets up.**
    ///
    /// The card carries an icon, a title, a paragraph, two checkboxes, a
    /// button and a disclosure that opens — on a display 480 points tall. A
    /// setup screen that clips its own Connect button on the strip would be
    /// the funniest possible version of this bug, so it scrolls, and this is
    /// what says so.
    /// The card builds and draws something at every state it can be in.
    ///
    /// **And that is all this can honestly claim.** The property somebody
    /// wants here is "it does not clip its own Connect button on a 480 pt
    /// strip", and no headless measurement can check it: the card is at its
    /// tallest only when the async preview has loaded its steps and the
    /// statusline checkboxes are showing, and neither of those exists in a
    /// render with no runtime behind it. Measured here the content comes back
    /// 203 pt at every width — a card in its shortest possible state.
    ///
    /// Two earlier versions of this test pretended otherwise. One asserted
    /// `height > 0` from `fittingSize`, which reports an unconstrained ideal
    /// and cannot observe clipping at all. The next set an explicit
    /// `.frame(height: 480)` and asserted the result was `<= 480`, which is
    /// true of any view given that frame. Both stayed green with the scroll
    /// view deleted.
    ///
    /// So: fitting is guaranteed by CONSTRUCTION — the card scrolls — and what
    /// is asserted is the part a headless render can see, which is that every
    /// state builds and draws.
    @Test("the connect card renders at every connection state", arguments: [
        Connection.notConnected, .wrongPort(installed: 8765, listening: 8766),
        .waiting(running: 3), .unreadable(reason: "is not valid JSON"),
        .superseded(port: 8765), .unlisted(candidates: 0), .unlisted(candidates: 1),
    ])
    func theConnectCardRenders(_ state: Connection) {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.setConnectionForTesting(state)
        let size = measured(ConnectCard(runtime: runtime), width: 460)
        // Above the EMPTY floor, not above zero. The card's own padding is
        // 28 points a side, so a body returning `EmptyView` still measures
        // about 66 — and `> 0` could not tell that from a card with an icon, a
        // title and a paragraph on it. Measured range for the real states is
        // 173 to 274.
        #expect(size.height > 100,
                Comment(rawValue: "\(state) measures \(size.height) pt — about the height of "
                        + "the card's own padding, so it is drawing nothing"))
    }

    /// The banner is the part that must be reachable when the fleet is NOT
    /// empty — a deck whose hooks point at a dead port still shows cards,
    /// because fleet discovery needs no hooks.
    @Test("the connection banner shows only when something needs doing")
    func theConnectionBannerIsConditional() {
        let quiet = DeckRuntime()
        quiet.markStartedForTesting()
        quiet.setStatusForTesting(.listening(port: 8765))
        quiet.setConnectionForTesting(.connected)
        #expect(measured(ConnectionBanner(runtime: quiet, showingSetup: .constant(false)),
                         width: 620).height == 0,
                "a healthy deck is nagging about its connection")

        let broken = DeckRuntime()
        broken.markStartedForTesting()
        broken.setConnectionForTesting(.wrongPort(installed: 8765, listening: 8766))
        let size = measured(ConnectionBanner(runtime: broken, showingSetup: .constant(false)),
                            width: 620)
        #expect(size.height >= TouchTarget.minimum,
                Comment(rawValue: "the banner is \(size.height) pt tall — its button is "
                        + "below the touch floor on a touchscreen deck"))
        #expect(size.height < 120, "the banner is eating the strip it warns on")
    }

    /// **`measuredBannerHeight`'s own arbiter — the number the band's budget
    /// tests build on, held to the view rather than trusted to a comment.**
    /// At the strip's own width, not the 620 pt `theConnectionBannerIsConditional`
    /// above uses — the button reflows under the text at 620, which costs
    /// more height than the banner spends on a 1920 pt strip.
    @Test("the connection banner's measured height matches its own named constant")
    func measuredBannerHeightArbiter() {
        let broken = DeckRuntime()
        broken.markStartedForTesting()
        broken.setConnectionForTesting(.wrongPort(installed: 8765, listening: 8766))
        let size = measured(ConnectionBanner(runtime: broken, showingSetup: .constant(false)),
                            width: Self.stripWidth)
        // Sub-point slack for font-metric rounding, the same tolerance
        // `subjectWellIdentityResetsAcrossDecisions` above holds two
        // renders of the same content to.
        #expect(abs(size.height - Self.measuredBannerHeight) < 0.5,
                Comment(rawValue: "the banner measures \(size.height) pt at \(Self.stripWidth) pt wide — "
                        + "measuredBannerHeight (\(Self.measuredBannerHeight)) has drifted from the view"))
    }


    // ---------------------------------------------------- settings: hold budget

    /// **Fix 4's render-sweep half.** The connection pane resists a plain
    /// headless render as a whole — it wants a live `DeckRuntime` behind
    /// `runtime.connectionDrift`, which has no test setter because it is
    /// computed only from a real config read. `HoldBudgetPicker` and
    /// `HoldTimeoutDriftNotice` (`SettingsView.swift`) are the pane's own
    /// fix: the smallest views that carry the picker and the notice, each
    /// taking a plain value instead of the runtime, so this suite can drive
    /// them directly the same way it drives everything else.
    ///
    /// A preset value and an OFF-preset one (`.seconds(45)`, which none of
    /// the four shipped rows names) both have to render — the off-preset
    /// row (fix 4(b)) exists precisely so a hand-edited budget still shows
    /// as something rather than an empty selection, and a render sweep is
    /// how a regression that made the extra row disappear again would be
    /// caught before a hand-edited machine caught it instead.
    @Test("the hold budget picker renders for a preset and an off-preset value",
          arguments: [HoldBudget.seconds(120), .seconds(300), .seconds(600), .untilAnswered, .seconds(45)])
    func holdBudgetPickerRenders(_ budget: HoldBudget) {
        let size = measured(HoldBudgetPicker(budget: budget, onChange: { _ in }),
                            width: Self.narrowPaneWidth)
        #expect(size.height > 0,
                Comment(rawValue: "\(budget) renders the picker as nothing"))
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "\(budget) is \(size.height) pt — taller than the strip"))
    }

    /// The off-preset row's own label, pinned directly — the render test
    /// above can see that something draws; it cannot read what the text
    /// says, and "Current: 45 seconds" is the whole point of the row.
    @Test("the off-preset row states the value literally, in whole seconds")
    func offPresetLabelIsLiteral() {
        #expect(HoldBudgetPicker.offPresetLabel(.seconds(45)) == "Current: 45 seconds")
        #expect(HoldBudgetPicker.offPresetLabel(.seconds(1)) == "Current: 1 second",
                "a single second was pluralised")
    }

    /// `QuestionHoldBudgetPicker`'s own twin of the two tests just above —
    /// same idiom, own preset list (`5/8/15/30 seconds`, `.untilAnswered`),
    /// own off-preset probe: `HoldBudgetPicker`'s four presets never include
    /// `.seconds(45)` or `.seconds(3)` (the question floor) either, so both
    /// exercise the identical rescue row on the sibling component.
    @Test("the question hold budget picker renders for a preset and an off-preset value",
          arguments: [HoldBudget.seconds(5), .seconds(8), .seconds(15), .seconds(30),
                      .untilAnswered, .seconds(3)])
    func questionHoldBudgetPickerRenders(_ budget: HoldBudget) {
        let size = measured(QuestionHoldBudgetPicker(budget: budget, onChange: { _ in }),
                            width: Self.narrowPaneWidth)
        #expect(size.height > 0,
                Comment(rawValue: "\(budget) renders the picker as nothing"))
        #expect(size.height < Self.stripHeight,
                Comment(rawValue: "\(budget) is \(size.height) pt — taller than the strip"))
    }

    @Test("the question picker's off-preset row states the value literally, in whole seconds")
    func questionOffPresetLabelIsLiteral() {
        #expect(QuestionHoldBudgetPicker.offPresetLabel(.seconds(3)) == "Current: 3 seconds")
        #expect(QuestionHoldBudgetPicker.offPresetLabel(.seconds(1)) == "Current: 1 second",
                "a single second was pluralised")
    }

    /// Every case `HoldTimeoutDriftNotice.drift` can actually be handed:
    /// no drift computed at all (a fresh `DeckRuntime`, or an unreadable
    /// config), a drift tuple with nothing installed to compare against
    /// (nothing connected yet), and a real mismatch. Only the last one is
    /// supposed to draw anything — the other two both read as "nothing
    /// installed", which the status line above this row already says in
    /// its own words, and the row saying it again would be noise.
    // `nonisolated`: `@Test(arguments:)` evaluates this before any test body
    // runs, off the main actor — the same reason `fixtureEvents` above is a
    // plain (non-isolated) static let rather than a computed property on
    // this `@MainActor` struct.
    private nonisolated static let driftProbes: [(label: String, drift: (installed: Int?, expected: Int)?)] = [
        ("no drift computed", nil),
        ("nothing installed to compare", (installed: nil, expected: 130_000)),
        ("a real mismatch", (installed: 310_000, expected: 130_000)),
    ]

    @Test("the hold timeout drift notice renders only when there is a real mismatch",
          arguments: driftProbes)
    func holdTimeoutDriftNoticeRenders(_ probe: (label: String, drift: (installed: Int?, expected: Int)?)) {
        let size = measured(HoldTimeoutDriftNotice(drift: probe.drift, onRepair: {}),
                            width: Self.narrowPaneWidth)
        if probe.drift?.installed == nil {
            #expect(size.height == 0,
                    Comment(rawValue: "\(probe.label): rendered \(size.height) pt with nothing to show"))
        } else {
            #expect(size.height > 0,
                    Comment(rawValue: "\(probe.label): a real drift rendered as nothing"))
            #expect(size.height < Self.stripHeight,
                    Comment(rawValue: "\(probe.label): the drift notice is \(size.height) pt — "
                            + "taller than the strip"))
        }
    }

    // ------------------------------------------------ settings: actions editor
    //
    // The master–detail editor. The commit/reorder/scope RULES are
    // pure and tested `DeckAppTests`-side (`SettingsActionsTests`) or core-
    // side (`QuickActionTests`'s own `commitTitle*`/`*moves*`/`*Offset*`
    // tests, `DeckCoreTests`); what a headless render still has to prove is
    // the geometry claims neither of those can see — a long title truncates
    // inside the preview rather than growing the detail form, the Actions
    // tab's own 720pt floor is real, and that floor does not leak into the
    // other three panes.

    /// **The preview cell's own truncation claim, one level up from
    /// `aLongTitleTruncatesInsideItsOwnCell` above.** That test pins it for
    /// the BARE `QuickActionBar.control`; this is the same claim for the
    /// `QuickActionDetailEditor` form the preview actually lives inside — a
    /// title at `editorTitleCap` (64, four times `titleBudget`) must not
    /// make the form any taller than a two-character title does. If the
    /// preview cell were wrapping instead of truncating, or if some other
    /// part of the form grew with title length, this is where it would show
    /// up. `lanes: []`/`selectedDirectory: nil` — this test has no opinion
    /// about the match count or the pre-fill, only about title-length
    /// geometry, so both take the plainest fixture that compiles.
    /// `QuickActionDraft(action:)` — the draft moved OUT of the editor's own
    /// `@State` and into an object `DeckSettingsView` owns (`QuickActionDraft`'s own doc comment states why), so
    /// this test seeds one directly rather than relying on the editor's
    /// `init` to do it.
    @Test("the detail form's height does not depend on how long its title is")
    func editorRowHeightIsUnaffectedByTitleLength() {
        let short = QuickAction(id: "a", title: "Go", kind: .prompt("go"))
        let long = QuickAction(id: "a", title: String(repeating: "X", count: QuickAction.editorTitleCap),
                               kind: .prompt("go"))
        #expect(long.displayTitle.count == QuickAction.editorTitleCap,
                "the fixture's own premise: a title at the editor's own input cap")

        func formHeight(_ action: QuickAction) -> Double {
            Double(measured(QuickActionDetailEditor(action: action, index: 0, allActions: [action], lanes: [],
                                                     selectedDirectory: nil, draft: QuickActionDraft(action: action),
                                                     focusMessageOnAppear: false,
                                                     onConsumeFocusRequest: {}, onCommit: { _ in }),
                            width: 460).height)
        }
        let shortHeight = formHeight(short)
        let longHeight = formHeight(long)
        #expect(shortHeight > 0 && longHeight > 0, "the detail form rendered as nothing")
        #expect(abs(shortHeight - longHeight) < 1,
                Comment(rawValue: "a 2-character title's form measured \(shortHeight) pt and a "
                        + "\(QuickAction.editorTitleCap)-character title's form measured \(longHeight) pt — "
                        + "the preview cell is not truncating, it is growing the form"))
    }

    /// **The pane as a whole, smoke-tested with a title at the editor's own
    /// cap, at the ACTIONS TAB'S OWN floor width — 720, not the shared
    /// window floor of 480.** `actionsPane` has no seam of its own to render
    /// directly — `private var`, the same shape `connectionPane` has — but
    /// unlike `connectionPane` (which needs a live `runtime.connectionDrift`
    /// config read, `holdBudgetPickerRenders`'s own doc comment states why
    /// that one resists a plain render) it depends on nothing a fresh
    /// `DeckRuntime` cannot answer, so the WHOLE `DeckSettingsView` renders
    /// headlessly with no extraction needed. `TabView`'s own selection
    /// binding defaults to "Actions" (`prefs.lastPane ?? "Actions"`,
    /// `DeckSettingsView.body`), so a fresh runtime opens on exactly the
    /// pane under test with no extra setup.
    ///
    /// **The ceiling is a runaway-growth smoke bound, not a strip-fit
    /// claim — `DeckScene.swift`'s own `Settings { DeckSettingsView(...) }`
    /// is a standalone macOS window, never shown on the touchscreen strip
    /// at all, so `Self.stripHeight` was never an honest number to hold it
    /// to.** Measured directly at 720 (this file's own "measured, not
    /// assumed" doctrine, stated for `measuredBannerHeight` above): the
    /// list column and the detail `Form` sit SIDE BY SIDE now rather than
    /// stacking one row per action, so overall height depends on the
    /// TALLER of the two — the detail form's own message/label/scope/
    /// pattern/preview stack — not on how many buttons are stored. 900 is a
    /// generous ceiling past that; this test's only job is "no crash, no
    /// unbounded runaway," never a claim about where the window is shown.
    @Test("the actions pane renders with a long-titled action, at its own 720pt floor width")
    func actionsPaneRendersWithALongTitledAction() {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        var prefs = runtime.prefs
        prefs.quickActions = [QuickAction(id: "long", title: String(repeating: "X", count: QuickAction.editorTitleCap),
                                          kind: .prompt("a message"))]
        runtime.setPrefs(prefs)

        let size = measured(DeckSettingsView(runtime: runtime), width: 720)
        #expect(size.height > 0, "the settings window rendered as nothing")
        #expect(size.height < 900,
                Comment(rawValue: "the actions pane measured \(size.height) pt — a smoke ceiling against "
                        + "runaway growth, not a strip-fit claim (this window is never shown on the strip)"))
    }

    /// **This phase's own width-floor requirement — "the Actions tab needs
    /// about 720pt, without making the other three panes silly" —
    /// DELIBERATELY has no render test asserting it, and that gap is
    /// reported rather than papered over with one that would not actually
    /// prove anything.** Three techniques were tried, empirically, before
    /// concluding none of them answer the question:
    ///
    ///   1. `measured(_:width:)` wraps its subject in a HARD, EXACT
    ///      `.frame(width:)`. Measuring `DeckSettingsView` (default pane:
    ///      Actions) at width 320 came back 320, not 720 — the outer exact
    ///      frame always reports back precisely the width it was given,
    ///      regardless of what a deeply nested `.frame(minWidth:)` wants.
    ///      This also means the OPPOSITE claim — "the other panes do NOT
    ///      inherit the floor" — cannot be proven this way either: a version
    ///      of `actionsPane` that wrongly put `.frame(minWidth: 720)` on the
    ///      shared `TabView` instead of its own content would ALSO measure
    ///      back exactly whatever width the test proposed, so a passing
    ///      test built on this technique would be vacuous — true whether the
    ///      bug is present or not.
    ///   2. `measuredMinimum(_:)` — validated elsewhere in this file for a
    ///      plain nested `.frame(maxHeight:)` composition
    ///      (`measuredMinimum`'s own doc comment) — measured `DeckSettingsView`'s
    ///      enforced minimum at (480, 280), the SHARED `TabView`'s own
    ///      floor, on the Actions tab. It does not see the nested pane's
    ///      own larger floor at all.
    ///   3. `measuredWidth(_:height:)` (natural width, height pinned to 400)
    ///      came back **2537pt** — nowhere near 720, and not a meaningful
    ///      reading either: it reflects `Form`/`List` content trading width
    ///      for height under a forced height shorter than the content
    ///      actually wants, not a stable "ideal width" answer.
    ///
    /// The likely explanation is that `TabView`'s real per-tab resize on
    /// macOS is a LIVE, event-driven behaviour — the window observing the
    /// newly-selected tab's content and animating to it — not a value a
    /// static Auto-Layout-constraint snapshot can compute the way
    /// `measuredMinimum` does for an ordinary nested view. **This needs a
    /// human at the window**: open Settings, confirm the Actions tab opens
    /// (or resizes to) roughly 720pt wide, and confirm switching to
    /// Connection/Sessions/Window does not carry that width along. The
    /// `.frame(minWidth: 720)` placement itself — on `actionsPane`'s own
    /// content, not the shared `TabView` — is the standard technique for
    /// this and is the usual approach; only its LIVE effect
    /// could not be confirmed here.

    // -------------------------------------------------- what goes on the wire

    /// **The reason a decision carries must survive being JSON.**
    ///
    /// `reason` was interpolated raw into the response body while every other
    /// string this server emits went through the escaping helper beside it. A
    /// quote, a newline or a backslash produced malformed JSON, which the
    /// engine treats as unrecognised — so the deck's decision would read, on
    /// the far side, as the deck having ignored the call. Latent when found:
    /// all three callers pass fixed literals. Latent is not fixed.
    @Test("a decision's reason survives characters that would break JSON",
          arguments: ["deck", "the tool said \"rm -rf\" so no", "line1\nline2",
                      "back\\slash", "tab\there", ""])
    func aDecisionReasonIsEscaped(_ reason: String) {
        for event in [HookKind.preToolUse, .permissionRequest] {
            for resolution in [Resolution.allow, .deny] {
                let body = HookResponse.decision(resolution, reason: reason, event: event)
                #expect(JSONValue.parse(Data(body.utf8)) != nil,
                        Comment(rawValue: "\(event) \(resolution.logWord) with reason "
                                + "\(reason.debugDescription) is not valid JSON: \(body)"))
            }
        }
    }

    // ------------------------------------------------------------ the chips

    /// Both chip styles render, and the loud one is not smaller than the quiet
    /// one — a filled chip that came back narrower than an unfilled one would
    /// mean the fill was being dropped.
    @Test("both chip styles render")
    func chipsRender() {
        let quiet = NSHostingView(rootView: Chip(ChipSpec.state(.idle))).fittingSize
        let loud = NSHostingView(rootView: Chip(ChipSpec.state(.needsYou))).fittingSize
        #expect(quiet.height > 0 && loud.height > 0)
        #expect(loud.height >= quiet.height)
    }

    /// Every lane state produces a chip that says something.
    @Test("every lane state has a chip with words on it", arguments: LaneState.allCases)
    func everyStateHasAChip(_ state: LaneState) {
        let spec = ChipSpec.state(state)
        #expect(!spec.title.isEmpty, "\(state.rawValue) renders a chip with no label")
        #expect(!spec.symbol.isEmpty, "\(state.rawValue) carries colour with no glyph")
        #expect(NSHostingView(rootView: Chip(spec)).fittingSize.height > 0)
    }

    /// Distinct glyphs per state, or the two-channel rule is decorative: a
    /// colour-blind user reading two states with one symbol has one channel.
    @Test("no two lane states share a glyph")
    func stateGlyphsAreDistinct() {
        let symbols = LaneState.allCases.map { ChipSpec.state($0).symbol }
        #expect(Set(symbols).count == symbols.count,
                Comment(rawValue: "two states share a glyph: \(symbols)"))
    }

    /// **Every symbol the deck names actually exists.**
    ///
    /// `Image(systemName:)` is not failable. Name a symbol that does not exist
    /// — a typo, or one Apple renames in a macOS release — and it renders
    /// NOTHING, silently. On this deck that turns a two-channel state into a
    /// colour-only one, which is the accessibility rule the suite spends most
    /// of its glyph tests enforcing. `NSImage(systemSymbolName:)` IS failable,
    /// so it is what gets asked.
    @Test("every SF Symbol the deck names resolves")
    func everySymbolResolves() {
        var names = Set(LaneState.allCases.map(\.symbolName))
        names.formUnion([PermissionBadge.bypass, PermissionBadge.acceptEdits,
                         PermissionBadge.plan].compactMap { PermissionBadge.forMode($0)?.symbolName })
        names.formUnion([QueuedAction.Status.queued, .sent, .confirmed].map(\.symbolName))
        // The literals views name directly. New ones belong here; a symbol
        // that is drawn and not listed is one this test cannot vouch for.
        names.formUnion([
            "antenna.radiowaves.left.and.right", "antenna.radiowaves.left.and.right.slash",
            "circle.dotted", "exclamationmark.triangle.fill", "eye", "eye.slash",
            "sidebar.trailing", "rectangle.3.group", "square.dashed",
            "chevron.up", "chevron.down", "chevron.left", "chevron.right",
            "doc.on.doc", "minus.circle", "trash", "tray.full", "forward.fill",
            "xmark.circle.fill", "questionmark.circle.fill", "paperplane.fill",
            "checkmark.square.fill", "largecircle.fill.circle", "square", "circle",
            // DetailBand's own: the compact zone's overflow chips, and
            // `.actOnly`'s own compact controls menu.
            "clock.arrow.circlepath", "ellipsis.circle",
            // CardColorPicker's own: the Automatic button and the current-
            // choice glyph on a swatch.
            "wand.and.stars", "checkmark",
            // `DeckSettingsView`'s own: `masterList`'s "+" (pre-existing,
            // never actually listed here before this phase), and
            // `actionRow`'s own folder-scope badge, new this phase.
            "plus", "folder",
        ])

        for name in names.sorted() {
            #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil,
                    Comment(rawValue: "\(name) is drawn by the deck and does not exist — "
                            + "it renders as nothing, leaving colour as the only channel"))
        }
    }

    /// And the permission badge's three severities do too — that is the field
    /// where colour-only encoding costs the most.
    @Test("no two permission severities share a glyph")
    func permissionGlyphsAreDistinct() {
        let modes = [PermissionBadge.bypass, PermissionBadge.acceptEdits, PermissionBadge.plan]
        let symbols = modes.compactMap { PermissionBadge.forMode($0)?.symbolName }
        #expect(symbols.count == modes.count)
        #expect(Set(symbols).count == symbols.count,
                Comment(rawValue: "two permission severities share a glyph: \(symbols)"))
    }

    // -------------------------------------------------- the squeezed recipe

    /// **`OverviewLayout.bandSqueezedButtonMinWidth`'s own live arbiter —
    /// the worst-recorded suggestion, at the narrowest reachable act zone,
    /// composed through the REAL `DetailBand` rather than a bare
    /// `DecisionBar`.** `width: 628` is the min-window band width
    /// (`DeckPrefs.minWindow.width` 960, minus `bandFleetWidth`/
    /// `bandSeamWidth`) — under `bandCompactThreshold` (874), so `zones`
    /// resolves `.actOnly`. `usableHeight: 149` is a defensive-depth
    /// sample below the corrected reachable floor (usable 189, banner up —
    /// `promptLineLimit(usableHeight:rows:banded:)`'s own doc comment
    /// carries the derivation) — both dimensions squeezed at once, still
    /// worth holding this recipe accountable to even though production
    /// cannot reach quite this tight a height.
    ///
    /// **RESOLVED — a real, reported gap through the mandatory-
    /// column redesign's own first landing, closed by `DetailBand
    /// .decisionMinimumActWidth`'s own guard (the requirement: the
    /// actions column yields when the alternative is a clipped Allow/Deny
    /// row).** `worstCaseDecisionRuntime()`'s default `QuickAction.shipped`
    /// trailer (three real, shipped actions) now genuinely competes for
    /// width at band 628 — the mandatory column never drops for width
    /// alone — so without the guard this exact fixture measured act 350
    /// (`bandActFloorWidth`) here, not the 604 this test's own name and
    /// assertions have always required: a stacked three-button row (148
    /// pt) plus 6 pt of bar chrome past a 101 pt budget, a genuine clip.
    /// The guard is exactly what `bandZonePlan` above is now asked: a
    /// stacked row that would not fit folds the actions column outright
    /// and hands the room back to the act zone, landing this fixture on
    /// 604 again — not by the OLD mechanism (a controls-gated column that
    /// happened not to compete), but because the row's own worst case
    /// provably does not fit at 350 and the column has to give way.
    /// `actionsColumnFoldsExactlyWhenAStackedRowWouldNotFit`, below, is
    /// the guard's own dedicated live arbiter — this test is back to
    /// pinning `bandSqueezedButtonMinWidth`'s own margin, its original job.
    @Test("the squeezed decision row stays horizontal and unclipped at the narrowest reachable act zone")
    func theSqueezedDecisionRowStaysHorizontalAtTheNarrowestActZone() {
        let runtime = Self.worstCaseDecisionRuntime()
        guard runtime.frame.decisions.first?.suggestionLabels.isEmpty == false else {
            Issue.record("the fixture produced no suggestion — nothing below measures the canonical worst case")
            return
        }
        let bandWidth = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        #expect(OverviewLayout.bandZones(for: bandWidth) == .actOnly,
                "the fixture's own premise: the min-window band width should be .actOnly")
        let usableHeight = 149.0
        #expect(OverviewLayout.bandSqueezed(usableHeight: usableHeight), "the fixture's own premise: squeezed")

        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight, dismissedStage: nil)
        var buttonsFrame: CGRect?
        band.onDecisionButtonsFrameMeasured = { buttonsFrame = $0 }
        _ = measured(band, width: bandWidth)

        guard let buttonsFrame else {
            Issue.record("the decision buttons' own geometry probe never fired")
            return
        }
        let columnsHeightBudget = max(0, usableHeight - OverviewLayout.bandHeaderHeight)
        #expect(buttonsFrame.maxY <= OverviewLayout.bandHeaderHeight + columnsHeightBudget,
                Comment(rawValue: "the buttons row reaches \(buttonsFrame.maxY) pt against a "
                        + "\(OverviewLayout.bandHeaderHeight + columnsHeightBudget) pt ceiling — clipped"))
        // 44-class, not 64-class — the squeezed floor, not the full
        // recipe's own decision floor. A small allowance for the glass's
        // own intrinsic height sitting inside the imposed frame
        // (`bandActionsRowHeight`'s own doc comment names the identical
        // 46 pt intrinsic-vs-frame gap for the actions column's pills).
        #expect(buttonsFrame.height < 56,
                Comment(rawValue: "the buttons row measured \(buttonsFrame.height) pt tall — expected the "
                        + "squeezed 44 pt class, not the full recipe's 64 pt one"))
        #expect(buttonsFrame.height >= 40,
                Comment(rawValue: "the buttons row measured \(buttonsFrame.height) pt tall — under even the "
                        + "general touch floor's own class"))
    }

    /// **`OverviewLayout.bandStateNoticeCompactHeight`'s own live arbiter
    /// — the same two-titled-variant technique `bandStateNoticeHeightMatchesItsNamedConstant`
    /// above uses, `compact: true` on both.** Measured WIDTH-INVARIANT, so
    /// one width stands for both the strip's own act zone and the
    /// narrowest squeezed one — `bandStateNoticeCompactHeight`'s own doc
    /// comment states why (no detail text left to wrap).
    @Test("BandStateNotice's own compact height matches OverviewLayout.bandStateNoticeCompactHeight, both variants, both widths")
    func bandStateNoticeCompactHeightMatchesItsNamedConstant() {
        let actWidth = 1920 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
            - 2 * OverviewLayout.bandColumnsHorizontalPadding - OverviewLayout.bandSideColumnWidth
            - OverviewLayout.bandZoneGutter
        for width in [actWidth, 604.0] {
            let ended = measured(DetailBand.endedNotice(compact: true), width: width)
            let errored = measured(DetailBand.erroredNotice(compact: true), width: width)
            let tallest = max(Double(ended.height), Double(errored.height))
            #expect(abs(tallest - OverviewLayout.bandStateNoticeCompactHeight) < 1,
                    Comment(rawValue: "the taller compact notice measured \(tallest) pt at \(width) pt wide "
                            + "against a declared \(OverviewLayout.bandStateNoticeCompactHeight) pt — retune "
                            + "the constant to match"))
        }
    }

    /// **`OverviewLayout.bandDecisionTitleThreshold`'s own live arbiter —
    /// the squeezed recipe's own worst-case decision, title shown vs
    /// folded, at the narrowest reachable act zone (604 pt).** Measures
    /// the SAME two shapes `OverviewLayoutTests.bandShowsDecisionTitleThresholdBothSides`
    /// reads the pure boundary from, so a drift in either the render or
    /// the constant shows up as two independent tests disagreeing, not
    /// one restating the other.
    @Test("the squeezed decision bar's own natural height, title shown and folded, matches bandDecisionTitleThreshold")
    func bandShowsDecisionTitleThresholdArbiter() {
        let runtime = Self.worstCaseDecisionRuntime()
        guard let decision = runtime.frame.decisions.first, !decision.suggestionLabels.isEmpty else {
            Issue.record("the fixture produced no suggestion — nothing below measures the canonical worst case")
            return
        }
        let withTitle = DecisionBar(decision: decision, runtime: runtime,
                                    wellExpandedMaxHeight: OverviewLayout.bandWellMinimum, wellCollapsedLines: 1,
                                    outerPadding: DetailBand.squeezedDecisionBarOuterPadding,
                                    contentSpacing: DetailBand.squeezedDecisionBarContentSpacing,
                                    buttonHeight: TouchTarget.minimum, buttonMinWidth: OverviewLayout.bandSqueezedButtonMinWidth,
                                    showsTitle: true, compactWell: true)
        let withoutTitle = DecisionBar(decision: decision, runtime: runtime,
                                       wellExpandedMaxHeight: OverviewLayout.bandWellMinimum, wellCollapsedLines: 1,
                                       outerPadding: DetailBand.squeezedDecisionBarOuterPadding,
                                       contentSpacing: DetailBand.squeezedDecisionBarContentSpacing,
                                       buttonHeight: TouchTarget.minimum, buttonMinWidth: OverviewLayout.bandSqueezedButtonMinWidth,
                                       showsTitle: false, compactWell: true)
        let titledHeight = measured(withTitle, width: 604).height
        let foldedHeight = measured(withoutTitle, width: 604).height

        #expect(abs(Double(titledHeight) - OverviewLayout.bandDecisionTitleThreshold) < 1,
                Comment(rawValue: "the titled squeezed bar measured \(titledHeight) pt against a declared "
                        + "threshold of \(OverviewLayout.bandDecisionTitleThreshold) pt"))
        // A defensive-depth sample BELOW the corrected reachable floor —
        // usable 149, columnsHeightBudget 101 (the real floor is usable
        // 189 banner up, budget 141 — comfortably clears this) — must
        // still hold the FOLDED shape with room to spare.
        let belowFloorBudget = 149.0 - OverviewLayout.bandHeaderHeight
        #expect(Double(foldedHeight) <= belowFloorBudget,
                Comment(rawValue: "the folded squeezed bar measured \(foldedHeight) pt against the "
                        + "defensive-depth \(belowFloorBudget) pt budget — the fold alone is not enough"))
    }

    /// **The squeezed worst-case decision's own render-level worked table
    /// at four sample heights the squeezed recipe was walked through — 300
    /// (a comfortably squeezed desktop sample), 249 (`DeckPrefs.minWindow`'s
    /// own no-banner/banner-down usable height, 270 − 21 — a CONTENT height
    /// already, no titlebar to subtract), 209 (a mid-range squeezed sample
    /// — an earlier draft of this comment mislabelled it as the no-banner
    /// usable height, which is actually 249, above; corrected here) and
    /// 149 (well BELOW the corrected reachable floor of usable 189 banner
    /// up, kept as defensive depth rather than a state production
    /// reaches).** At each, the composed `DetailBand`'s own decision
    /// buttons must stay unclipped, and the band's own reported minimum
    /// must still floor at ~0 — the same deadlock-breaker property
    /// `detailBandNeverDemandsHeight` holds generally, re-proven here at
    /// the specific heights this recipe was walked through live.
    ///
    /// **RETOLD — the "44-class, not stacked" assertion this test
    /// used to hold every sample to is GONE, on the requirement:
    /// it asserted a property the mandatory-column redesign deliberately
    /// gave up, not a regression.** At `bandWidth` 628 the mandatory
    /// column now claims its own share even from a band that used to be
    /// `.actOnly` outright, landing act 350 — narrower than the 604 this
    /// recipe was walked through at previously. A three-button
    /// squeezed row that no longer fits 350 pt horizontally STACKS
    /// instead (`ViewThatFits(in: .horizontal)`'s own fallback,
    /// `DecisionBar.body`) — 148 pt tall (3 × 44 +2 × 8), not the 44 pt
    /// single-row class — and the squeezed well is exactly what
    /// gives a stacked row the room to take that height FROM (`SubjectWell`
    /// yields before the button row ever clips, this file's own
    /// content-driven matrix already holds that trade accountable). What
    /// matters now is whether the row FITS, not which shape it takes to
    /// get there — so this test asserts fit alone.
    ///
    /// **Measured, not assumed: at 300/249/209 pt usable the stacked row
    /// fits — 148 pt of content against 252/201/161 pt of real budget
    /// (`usableHeight − bandHeaderHeight`) — genuinely GREEN, not merely
    /// no-longer-wrongly-red.** `DetailBand.decisionMinimumActWidth`'s own
    /// guard (the requirement, added after this paragraph was first
    /// written) checks exactly this shape — a stacked row's own worst-case
    /// total against this SAME budget — and correctly answers "no fold
    /// needed" at all three: the stacked row already fits without the
    /// actions column giving up any width.
    ///
    /// **RESOLVED — 149 pt usable used to be this test's own one
    /// remaining real gap (148 pt of stacked content against a 101 pt
    /// budget), the SAME one `theSqueezedDecisionRowStaysHorizontalAtTheNarrowestActZone`'s
    /// own doc comment named; the guard closes it the identical way.** At
    /// 149 pt, the stacked row's own worst-case total (148 + 6 pt of bar
    /// chrome) exceeds the 101 pt budget, so the guard folds the actions
    /// column outright and the row renders horizontal again (44 pt), never
    /// reaching the stacked shape this budget could not have held. The
    /// demand-free `min.height <= 1` check below holds at every height
    /// regardless (the deadlock-breaker itself was never affected by
    /// either the gap or its close).
    @Test("the squeezed worst-case decision survives every sample height the recipe was proven against live",
          arguments: [300.0, 249.0, 209.0, 149.0])
    func squeezedWorstCaseDecisionSurvivesEverySampleHeight(_ usableHeight: Double) {
        let runtime = Self.worstCaseDecisionRuntime()
        guard runtime.frame.decisions.first?.suggestionLabels.isEmpty == false else {
            Issue.record("the fixture produced no suggestion — nothing below measures the canonical worst case")
            return
        }
        #expect(OverviewLayout.bandSqueezed(usableHeight: usableHeight),
                "the fixture's own premise: every sample height here should be squeezed")
        let bandWidth = Double(DeckPrefs.minWindow.width) - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth

        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight, dismissedStage: nil)
        var buttonsFrame: CGRect?
        band.onDecisionButtonsFrameMeasured = { buttonsFrame = $0 }
        _ = measured(band, width: bandWidth)

        guard let buttonsFrame else {
            Issue.record("the decision buttons' own geometry probe never fired at \(usableHeight) pt usable")
            return
        }
        let ceiling = OverviewLayout.bandHeaderHeight + max(0, usableHeight - OverviewLayout.bandHeaderHeight)
        #expect(buttonsFrame.maxY <= ceiling,
                Comment(rawValue: "at \(usableHeight) pt usable, the buttons row reaches \(buttonsFrame.maxY) "
                        + "pt against a \(ceiling) pt ceiling — clipped"))
        // Fits, whatever shape it takes to get there — NOT "stays
        // horizontal." A stacked row is a legitimate answer now
        // (`ViewThatFits(in: .horizontal)`'s own fallback, the same
        // shape `theDecisionRowMatrixNeverClipsAndHonoursHonestRoomForTheWell`
        // already holds accountable elsewhere in this file); the only
        // floor still worth a name is the general touch one, clearing
        // EITHER the single-row class or the stacked one.
        #expect(buttonsFrame.height >= TouchTarget.minimum,
                Comment(rawValue: "at \(usableHeight) pt usable, the buttons row measured \(buttonsFrame.height) "
                        + "pt tall — under even the general touch floor's own class, whatever shape it took"))

        let min = measuredMinimum(DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight,
                                             dismissedStage: nil))
        #expect(min.height <= 1,
                Comment(rawValue: "at \(usableHeight) pt usable, DetailBand reported a minimum height of "
                        + "\(min.height) pt — it should never demand height, whatever it is composing"))
    }

    /// **`decisionMinimumActWidth`'s own guard (`DetailBand.swift`), pinned
    /// live — the whole rule, and nothing else pins it.** The rule: the actions column never yields for width alone, but it
    /// DOES yield when the alternative is a clipped Allow/Deny row. One
    /// geometry, band 628 (the min window) at usable 189 — the SAME
    /// geometry `theDecisionRowMatrixNeverClipsAndHonoursHonestRoomForTheWell`'s
    /// own two genuine clip cells live at — two contents:
    ///
    /// - **One suggestion, three buttons.** Stacked, this row measures
    ///   148 pt (3 × 44 + 2 × 8) plus 6 pt of bar chrome — 154 pt against
    ///   this budget's own 141 — past it. The guard folds the actions
    ///   column entirely (`actionsFrame` absent) and the row renders
    ///   HORIZONTAL instead (44 pt tall, not the 148 pt stacked class) —
    ///   the fold buys exactly the width the row needed to never stack at
    ///   all.
    /// - **No suggestion, two buttons.** The SAME geometry, the SAME
    ///   guard, a shorter decision: two short buttons never come close to
    ///   needing the fold — the guard answers 0, and the actions column
    ///   stays at its own squeezed floor (`bandActFloorWidth`, 350),
    ///   `actionsFrame` present.
    ///
    /// **This contrast, not either half alone, is the whole rule.** Either
    /// sample by itself would be consistent with "the column always
    /// folds" or "the column never folds" — it is the SAME geometry
    /// answering two different ways, driven ONLY by the decision's own
    /// content, that actually pins `decisionMinimumActWidth`'s own
    /// contract rather than merely a coincidence at one fixture.
    @Test("the actions column folds exactly when a stacked Allow/Deny row would not fit, and stays when it would")
    func actionsColumnFoldsExactlyWhenAStackedRowWouldNotFit() {
        let bandWidth = 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let usableHeight = 189.0

        let suggestionRuntime = Self.decisionRuntime(ruleTexts: ["git push *"])
        #expect(suggestionRuntime.frame.decisions.first?.suggestionLabels.count == 1,
                "the fixture's own premise: exactly one suggestion, three buttons")
        var suggestionBand = DetailBand(runtime: suggestionRuntime, width: bandWidth, usableHeight: usableHeight,
                                        dismissedStage: nil)
        var suggestionButtons: CGRect?
        var suggestionActions: CGRect?
        suggestionBand.onDecisionButtonsFrameMeasured = { suggestionButtons = $0 }
        suggestionBand.onQuickActionsFrameMeasured = { suggestionActions = $0 }
        _ = measured(suggestionBand, width: bandWidth)
        #expect(suggestionBand.actZoneWidth > OverviewLayout.bandActFloorWidth,
                Comment(rawValue: "a stacked three-button row does not fit this budget — the actions column "
                        + "should have folded, widening the act zone past its own squeezed floor "
                        + "(\(OverviewLayout.bandActFloorWidth)) — got \(suggestionBand.actZoneWidth)"))
        #expect(suggestionActions == nil,
                Comment(rawValue: "the actions column should not have rendered at all — it folds to protect "
                        + "the decision — got \(String(describing: suggestionActions))"))
        #expect((suggestionButtons?.height ?? 0) < 56,
                Comment(rawValue: "the decision row should render HORIZONTAL once the actions column folds "
                        + "to give it room — got \(String(describing: suggestionButtons?.height)) pt tall"))

        let bareRuntime = Self.decisionRuntime(ruleTexts: [])
        #expect(bareRuntime.frame.decisions.first?.suggestionLabels.isEmpty == true,
                "the fixture's own premise: no suggestion, two buttons")
        var bareBand = DetailBand(runtime: bareRuntime, width: bandWidth, usableHeight: usableHeight,
                                  dismissedStage: nil)
        var bareActions: CGRect?
        bareBand.onQuickActionsFrameMeasured = { bareActions = $0 }
        _ = measured(bareBand, width: bandWidth)
        #expect(bareBand.actZoneWidth == OverviewLayout.bandActFloorWidth,
                Comment(rawValue: "a two-button row's own stacked shape fits this SAME budget — the actions "
                        + "column should have STAYED at its own squeezed floor "
                        + "(\(OverviewLayout.bandActFloorWidth)) — got \(bareBand.actZoneWidth)"))
        #expect(bareActions != nil,
                "the actions column should still render here — the guard should not have engaged")
    }

    /// **The THIRD case `actionsColumnFoldsExactlyWhenAStackedRowWouldNotFit`'s
    /// own two-case contrast never sampled: the guard used to fold whenever the act zone was too narrow, full
    /// stop, never asking whether folding would actually WIDEN it.** At
    /// bands 874–1150 the cascade has already folded Controls to seat the
    /// actions column, so folding the column TOO hands the identical
    /// `bandSideColumnWidth + bandZoneGutter` (254) straight back to
    /// CONTROLS, not to the act zone — the width does not move, and the
    /// old guard destroyed the column for nothing. Band 922 (the desktop
    /// window) at usable 300 with three real suggestions (5 buttons) is
    /// a repro: folded and unfolded both land act 644 — a
    /// stacked five-button row (5 × 44 + 4 × 8 = 252, squeezed floor) plus
    /// 6 pt of bar chrome (258) against a 252 pt budget clips EITHER way
    /// — so the fixed guard refuses the fold (`OverviewLayout.bandZonePlan`'s
    /// own doc comment carries the corrected contract) and the column
    /// SURVIVES, the row clipping exactly as it always would have, not
    /// destroyed on top of it.
    @Test("the actions column survives a futile fold — one that would not widen the act zone at all")
    func theActionsColumnSurvivesAFutileFold() {
        let bandWidth = 1254.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        #expect(bandWidth == 922, "the fixture's own premise: the desktop window's own band width")
        let usableHeight = 300.0
        let runtime = Self.decisionRuntime(ruleTexts: ["git push *", "git commit *", "git push origin *"])
        #expect(runtime.frame.decisions.first?.suggestionLabels.count == 3,
                "the fixture's own premise: three suggestions, five buttons")

        // The premise: folding is genuinely futile here — the cascade has
        // already folded Controls to seat the column, so the unfolded and
        // folded act widths are the SAME number.
        let unfoldedPlan = OverviewLayout.bandZonePlan(bandWidth: bandWidth,
                                                       actionCount: runtime.frame.actions.count,
                                                       usableHeight: usableHeight, minimumActWidth: 0)
        #expect(unfoldedPlan.actions != nil, "the fixture's own premise: the actions column is offered here")
        let foldedPlan = OverviewLayout.bandZonePlan(bandWidth: bandWidth, actionCount: 0, usableHeight: usableHeight)
        #expect(foldedPlan.actWidth == unfoldedPlan.actWidth,
                Comment(rawValue: "the fixture's own premise: folding should not move the act width at all — "
                        + "unfolded \(unfoldedPlan.actWidth), folded \(foldedPlan.actWidth)"))

        var band = DetailBand(runtime: runtime, width: bandWidth, usableHeight: usableHeight, dismissedStage: nil)
        var buttonsFrame: CGRect?
        var actionsFrame: CGRect?
        band.onDecisionButtonsFrameMeasured = { buttonsFrame = $0 }
        band.onQuickActionsFrameMeasured = { actionsFrame = $0 }
        _ = measured(band, width: bandWidth)

        #expect(actionsFrame != nil,
                Comment(rawValue: "the actions column should SURVIVE — folding it would not have widened the "
                        + "act zone, so there is no benefit to destroying it"))
        #expect(band.actZoneWidth == unfoldedPlan.actWidth,
                Comment(rawValue: "the act zone should be exactly the cascade's own unfolded answer — got "
                        + "\(band.actZoneWidth)"))
        let ceiling = OverviewLayout.bandHeaderHeight + max(0, usableHeight - OverviewLayout.bandHeaderHeight)
        #expect((buttonsFrame?.maxY ?? 0) > ceiling,
                Comment(rawValue: "the fixture's own premise: this specific content genuinely does not fit "
                        + "here, with or without the column — got maxY \(String(describing: buttonsFrame?.maxY)) "
                        + "against ceiling \(ceiling); if this now fits, the fixture's own premise moved and "
                        + "this test is no longer proving what it claims to"))
    }

    /// **The compact well renders exactly one row — `SubjectWell.compact`'s
    /// own live arbiter.** A collapsed non-compact well at the same
    /// `collapsedLines` shows visibly more than one line's worth of
    /// height for a plan long enough to overflow it; the compact well,
    /// `lineLimit(1)` plus the inline chip, must not.
    @Test("the compact well renders one row, visibly shorter than the same subject's own multi-line collapsed well")
    func theCompactWellRendersOneRow() {
        let plan = (1...20).map { "Step \($0): do the next thing on the list" }.joined(separator: "\n")
        let subject = Subject(tool: "ExitPlanMode", detail: Redacted(plan), field: "plan")
        let compact = measured(SubjectWell(subject: subject, expandedMaxHeight: 16, collapsedLines: 4, compact: true),
                               width: 588)
        let ordinary = measured(SubjectWell(subject: subject, expandedMaxHeight: 16, collapsedLines: 4, compact: false),
                                width: 588)
        #expect(compact.height < ordinary.height,
                Comment(rawValue: "the compact well (\(compact.height) pt) should render visibly shorter than "
                        + "the same subject's own 4-line collapsed well (\(ordinary.height) pt)"))
        // One row's own floor — the overflow chip's `TouchTarget.minimum`
        // square plus the compact row's own tight padding
        // (`SubjectWell.compactCollapsedRow`'s own `.padding(.vertical, 2)`)
        // — comfortably clears one line of text but stays well short of a
        // second full collapsed line.
        #expect(compact.height < 60,
                Comment(rawValue: "the compact well measured \(compact.height) pt — expected a single row, "
                        + "not a multi-line collapse"))
    }

    /// **The header carries BOTH the folded-controls menu and the
    /// yielded-actions chip together — RETOLD: the geometry that
    /// reaches each fold changed completely, but the claim worth proving
    /// did not.** previously, "controls folded, actions NOT folded"
    /// was reachable — the legacy `bandActionsColumn`'s own three-argument
    /// overload gated FIRST on `bandControlsShown`, so "actions folded,
    /// Controls NOT folded" was the one combination that same overload
    /// made UNREACHABLE by construction, and this test's own comparison
    /// geometry had to be built around that asymmetry. The mandatory-column
    /// redesign inverts which combination is awkward to reach: Controls
    /// can now fold WITHOUT the actions column ever losing capacity (a
    /// band wide enough for both, merely short on height), and the actions
    /// column can now fall short of `capacity` WITHOUT Controls folding at
    /// all (a generous width, a squeezed row budget) — both are ordinary,
    /// independently reachable facts now, not one asymmetric survivor of a
    /// stricter rule.
    ///
    /// **Three geometries, not two — neither folded, actions-only, and
    /// both together — each a real `bandZonePlan` outcome, asserted as
    /// this test's own premise before anything is rendered.** Ten offered
    /// actions throughout, so the SAME action count crosses every shape:
    /// the strip's own full band width at a generous height (`capacity`
    /// 10, `controlsShown` true — neither fold); the SAME wide band at a
    /// shorter height (`capacity` 6, short by 4, `controlsShown` still
    /// true — the row budget alone cost the column four slots, Controls
    /// untouched); the min window's own band width at a genuinely squeezed
    /// height (`capacity` 2, short by 8, `controlsShown` false — the
    /// squeezed step folds Controls AND still cannot hold every action).
    ///
    /// **Presence, not merely height.** The height assertion below holds the header's
    /// own fixed row to its named constant; it says nothing about whether
    /// the menu and the chip this test is NAMED for actually drew
    /// anything, since a folded-away control and a rendered-but-invisible
    /// one report the identical height. `.accessibilityLabel` has no
    /// supported read-back path in this headless harness
    /// (`CardColorPickerTests`'s own doc comment states the same
    /// limitation) — so presence is proven by GEOMETRY:
    /// `measuredWidth(_:height:)`'s own NATURAL, unconstrained reading,
    /// pairwise across the three geometries, isolating each fold's own
    /// contribution rather than a single combined delta that either
    /// control alone could satisfy (previously: the chip measures ≈90+ pt on its own, well past a
    /// single `TouchTarget.minimum` (44) threshold, so a combined check
    /// could not tell "both drew" from "only the bigger one did").
    @Test("the header carries the controls menu and the actions overflow chip together when both the actions column's own capacity and Controls fold at once")
    func headerCarriesBothFoldsTogether() {
        let runtime = Self.liveNeedsYouBandShapeRuntime(quickActions: Self.manyActions(10))
        guard runtime.frame.decisions.first != nil else {
            Issue.record("the live-shape fixture produced no decision, so nothing below is measured")
            return
        }
        #expect(runtime.frame.actions.count == 10, "the fixture's own premise: ten offered actions")

        // Neither fold: the strip's own full band width, generous height.
        let neitherWidth = 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let neitherHeight = 419.0
        let neitherPlan = OverviewLayout.bandZonePlan(bandWidth: neitherWidth, actionCount: 10,
                                                       usableHeight: neitherHeight)
        #expect(neitherPlan.actions?.capacity == 10 && neitherPlan.controlsShown,
                Comment(rawValue: "the neither-folded fixture's own premise — capacity "
                        + "\(String(describing: neitherPlan.actions?.capacity)), controlsShown "
                        + "\(neitherPlan.controlsShown)"))

        // Actions folded ALONE: the SAME wide band, a shorter usable
        // height — Controls still clears its own (lower) floor, but the
        // row budget leaves the actions column only 3 rows (capacity 6),
        // short of what ten actions need.
        let actionsOnlyHeight = 300.0
        let actionsOnlyPlan = OverviewLayout.bandZonePlan(bandWidth: neitherWidth, actionCount: 10,
                                                          usableHeight: actionsOnlyHeight)
        #expect((actionsOnlyPlan.actions?.capacity ?? 10) < 10 && actionsOnlyPlan.controlsShown,
                Comment(rawValue: "the actions-fold-only fixture's own premise — capacity "
                        + "\(String(describing: actionsOnlyPlan.actions?.capacity)), controlsShown "
                        + "\(actionsOnlyPlan.controlsShown)"))

        // BOTH folded: the min window's own band width, squeezed height —
        // Controls folds (freeing its own share) AND the surviving
        // squeezed column still falls short of ten.
        let bothWidth = 960.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth
        let bothHeight = 249.0
        let bothPlan = OverviewLayout.bandZonePlan(bandWidth: bothWidth, actionCount: 10, usableHeight: bothHeight)
        #expect((bothPlan.actions?.capacity ?? 10) < 10 && !bothPlan.controlsShown,
                Comment(rawValue: "the both-folded fixture's own premise — capacity "
                        + "\(String(describing: bothPlan.actions?.capacity)), controlsShown \(bothPlan.controlsShown)"))

        let neitherBand = DetailBand(runtime: runtime, width: neitherWidth, usableHeight: neitherHeight,
                                     dismissedStage: nil)
        let actionsOnlyBand = DetailBand(runtime: runtime, width: neitherWidth, usableHeight: actionsOnlyHeight,
                                         dismissedStage: nil)
        let bothBand = DetailBand(runtime: runtime, width: bothWidth, usableHeight: bothHeight, dismissedStage: nil)

        let bothHeaderSize = measured(bothBand.header, width: bothWidth)
        #expect(bothHeaderSize.height > 0, "the header rendered as nothing")
        // The header's own natural height should still match its named
        // constant — carrying the menu and the chip must not grow the
        // fixed 48 pt row (`bandHeaderHeight`'s own doc comment states
        // the arithmetic this leans on: the collapse button's own touch
        // floor, not either leading control, is what sets it).
        #expect(abs(Double(bothHeaderSize.height) - OverviewLayout.bandHeaderHeight) < 1,
                Comment(rawValue: "the header measured \(bothHeaderSize.height) pt with both folds engaged — "
                        + "expected \(OverviewLayout.bandHeaderHeight) pt, unchanged"))

        let neitherHeaderWidth = measuredWidth(neitherBand.header, height: OverviewLayout.bandHeaderHeight).width
        let actionsOnlyHeaderWidth = measuredWidth(actionsOnlyBand.header,
                                                   height: OverviewLayout.bandHeaderHeight).width
        let bothHeaderWidth = measuredWidth(bothBand.header, height: OverviewLayout.bandHeaderHeight).width

        // The chip's own share: actions folded alone vs neither folded.
        #expect(Double(actionsOnlyHeaderWidth) - Double(neitherHeaderWidth) > 0,
                Comment(rawValue: "the actions-fold-only header (\(actionsOnlyHeaderWidth) pt) should "
                        + "measurably exceed the unfolded header (\(neitherHeaderWidth) pt) — the "
                        + "yielded-actions chip should have drawn on its own, with the controls menu still "
                        + "absent"))

        // The menu's own share: both folded vs actions-fold-only —
        // isolating exactly what Controls' own fold adds on top of an
        // already-present chip.
        #expect(Double(bothHeaderWidth) - Double(actionsOnlyHeaderWidth) >= TouchTarget.minimum,
                Comment(rawValue: "the fully-folded header (\(bothHeaderWidth) pt) should measurably exceed "
                        + "the actions-fold-only header (\(actionsOnlyHeaderWidth) pt) by at least the menu's "
                        + "own \(TouchTarget.minimum) pt touch floor — this is what a single combined delta "
                        + "against the fully-unfolded header could not distinguish from the chip's own share"))
    }

    /// **The Group→VStack fix (5h) — live-proven at tall budgets on real
    /// glass; NOT independently reproduced by this headless harness, and
    /// stated honestly rather than claimed otherwise.** `actZone(for:)`'s
    /// own interior used to be a `Group`, which is layout-transparent: a
    /// modifier chained onto a `Group` is documented SwiftUI behaviour to
    /// distribute to EACH child independently, so `.frame(maxHeight:)
    /// .clipped()` applied to `ActionBlockNotice` and `DecisionBar`
    /// together really applied to each of them SEPARATELY — live-observed
    /// (the requirement, a 900 pt window) as the two spreading
    /// apart: the notice pinned top, the decision floating mid-column
    /// rather than sitting directly underneath. A real `VStack(alignment:
    /// .leading, spacing: 6)` applies the cap ONCE, to the stack as a
    /// whole, which is the architecturally correct fix regardless of
    /// whether any given measurement technique can show the difference.
    ///
    /// **Investigated directly: this file's own `measured(_:width:)` /
    /// `NSHostingView.layoutSubtreeIfNeeded()` single-pass technique
    /// measures the SAME buttons position under the OLD `Group` and the
    /// NEW `VStack`** — tried by hand, reverting to `Group` locally and
    /// re-running this exact test, both before writing this comment.
    /// Neither `.frame(maxHeight:)` alone inflates a non-expanding view's
    /// reported size below its own cap, in either arrangement, so a
    /// single AppKit layout pass never exercises whatever multi-pass,
    /// live-display-cycle interaction actually produced the spreading
    /// seen live. This test is therefore NOT this fix's own live arbiter
    /// — there is no headless one, the same honest gap `bandFitsTheStripWorstCaseDecision`'s
    /// own doc comment already admits for a different combination (the
    /// narrower desktop window's own tightest budget). What it DOES hold,
    /// genuinely: the composed act-zone content's own reported position
    /// stacks by natural size and stays BUDGET-INVARIANT — a real,
    /// independently worthwhile regression guard (a future change that
    /// reintroduced budget-dependent stretching anywhere in this stack
    /// would fail it), just not proof of THIS specific historical bug's
    /// absence.
    ///
    /// The comparison: the decision buttons' own `maxY` at two genuinely
    /// different, both-generous budgets, measured within ONE test so the
    /// comparison is direct rather than reconstructed across two
    /// independent runs — for the one shape (`ActionBlockNotice` beside
    /// `DecisionBar`) this file's own `worstCaseDecisionRuntime()` never
    /// exercises (`ActionBlock` and an open decision coexist only when a
    /// lane is simultaneously unroutable — `host: nil`, no `.located`
    /// event — AND has a real, `held`-bearing hold open, which is exactly
    /// what this fixture builds).
    @Test("the notice and the decision bar stack directly, both top-anchored, unmoved by extra budget above them")
    func actionBlockNoticeAndDecisionBarStackDirectlyAtATallBudget() {
        let suggestionsJSON = JSONValue.parse(
            #"[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"git push *"}],"behavior":"allow","destination":"localSettings"}]"#)
        let session = SessionID("unroutable-with-a-hold")
        let events: [DeckEvent] = [
            .hook(HookEvent(id: EventID("s1"), at: at(0), kind: .sessionStart,
                            session: session, cwd: Redacted("/w/alpha"),
                            tool: nil, toolUseID: nil, held: .absent)),
            .hook(HookEvent(id: EventID("q1"), at: at(10), kind: .preToolUse,
                            session: session, cwd: Redacted("/w/alpha"),
                            tool: "Bash", toolUseID: "t1", held: .value(120_000),
                            subject: Subject(tool: "Bash", detail: Redacted("git push origin main"), field: "command"),
                            permissionSuggestions: suggestionsJSON)),
            .sessionSelected(session, at: at(20)),
        ]
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        runtime.replaceStateForTesting(Reducer.run(events))
        #expect(runtime.frame.actionBlock == .unroutable,
                Comment(rawValue: "the fixture's own premise: an unrouted lane — got "
                        + "\(String(describing: runtime.frame.actionBlock))"))
        #expect(runtime.frame.decisions.first?.hold.session == session,
                "the fixture's own premise: a real, open decision on the same lane")

        let bandWidth = 1920.0 - OverviewLayout.bandFleetWidth - OverviewLayout.bandSeamWidth

        var frameAt800: CGRect?
        var bandAt800 = DetailBand(runtime: runtime, width: bandWidth, usableHeight: 800, dismissedStage: nil)
        bandAt800.onDecisionButtonsFrameMeasured = { frameAt800 = $0 }
        _ = measured(bandAt800, width: bandWidth)

        var frameAt1200: CGRect?
        var bandAt1200 = DetailBand(runtime: runtime, width: bandWidth, usableHeight: 1200, dismissedStage: nil)
        bandAt1200.onDecisionButtonsFrameMeasured = { frameAt1200 = $0 }
        _ = measured(bandAt1200, width: bandWidth)

        guard let frameAt800, let frameAt1200 else {
            Issue.record("the decision buttons' own geometry probe never fired at one or both budgets")
            return
        }
        #expect(abs(Double(frameAt800.maxY) - Double(frameAt1200.maxY)) < 1,
                Comment(rawValue: "the buttons row's own bottom edge measured \(frameAt800.maxY) pt at an 800 "
                        + "pt budget and \(frameAt1200.maxY) pt at a 1200 pt one — a taller budget moved the "
                        + "content, which means the notice and the decision bar are still spreading apart to "
                        + "fill available room rather than stacking directly by their own natural size"))
        // And, sanity: neither reading sits anywhere near either budget's
        // own ceiling — both are governed by natural content size, the
        // property the equality above is actually proving the mechanism
        // FOR.
        #expect(Double(frameAt800.maxY) < 300,
                Comment(rawValue: "the buttons row's own bottom edge (\(frameAt800.maxY) pt) is implausibly "
                        + "far down for two short pieces of content stacked directly"))
    }

}
