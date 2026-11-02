//
//  SessionOverview.swift · DeckApp
//
//  Every session at once. Not an empty state: the deck.
//
//  A fleet monitor answers "which of these needs me", a question about the
//  SET, so every member is on the glass at once carrying its own live state.
//
//  The card is the whole information budget for one session. Its fields are
//  chosen by what changes (context gauge, permission badge, last prompt)
//  rather than what does not (directory, branch).
//
//  STATE IS ITSELF THE SIGNAL, carried by wash, chip and tick, not by height.
//  Cards are always bounded and uniform, so the bottom line stays clean (see
//  `Ticks`, `DeckWindow.swift`).
//

import SwiftUI
import DeckCore

struct SessionOverview: View {
    let runtime: DeckRuntime
    let layout: OverviewLayout
    /// The size `DeckWindow` measures the fleet region at — the same read
    /// `layout` is decided from, handed down rather than measured a second
    /// time here. Only used to notice when it CHANGES; see the scroll-to-
    /// selection wiring in `body` for why.
    var fleetSize: CGSize = .zero
    /// Whether `DeckWindow` is composing the detail band (its own `banded` flag,
    /// threaded through). While true, `lanes` filters to the SELECTED lane alone
    /// (`Self.lanes(from:banded:selection:)`; see `OverviewLayout.bandFleetWidth`).
    /// Defaults `false`: the full fleet, unfiltered.
    var banded: Bool = false

    /// Whether the fleet is in edit mode (`DeckWindow.editingLayout`, threaded
    /// through). Defaults `false`: no wiggle, no drag. The flag lives in
    /// `DeckWindow`; see its doc comment for why.
    var editing: Bool = false

    /// Whether the hidden lanes are on the glass right now. View state and not
    /// the reducer's: hiding is a preference that outlives a launch, and
    /// *looking* at what you hid is a glance that should not.
    @State private var revealingHidden = false

    /// Which card the keyboard is on. A grid of buttons gives only Tab, so
    /// arrow-key traversal is written here (`move(_:)`).
    @FocusState private var focused: SessionID?

    // ------------------------------------------------------- edit mode

    /// The card currently under a finger, or nil. View-local, never in `DeckCore`
    /// (see `CardDrag`, `FleetEditMode.swift`).
    @State private var drag: CardDrag?
    /// **The in-flight reorder, over VALUE snapshots, never the projection
    /// itself.** `nil` between drags, when `displayedLanes` reads straight through
    /// to `lanes`. Seeded at grab, mutated locally by `ReorderMath.retargetIndex`/
    /// `Array.moveElement`, and cleared once a drop's `DeckRuntime.reorder(_:)`
    /// makes the projection agree. See `dragGesture(for:)`.
    @State private var draftOrder: [SessionID]?
    /// Every card's last-reported frame in the `"fleet"` coordinate space. It
    /// ACCUMULATES: `.onGeometryChange` is edge-triggered and fills an entry only
    /// when that card's geometry changes, so the map must never be cleared or
    /// pruned (nothing would refill it; see the notes in `chrome` and on
    /// `ReorderMath.dragRenderOffset`). Stale entries are harmless. The hidden
    /// shelf never contributes an entry.
    @State private var slots: [SessionID: CGRect] = [:]

    /// **Pure projection: narrows `base` to the selected lane while banded.**
    /// Static so it is testable without a view. `base` is what `lanes` already
    /// decided to draw, so this only narrows; a hidden, unrevealed selection stays
    /// absent (see `scrollToSelection`).
    static func lanes(from base: [LaneView], banded: Bool, selection: SessionID?) -> [LaneView] {
        guard banded, let selection else { return base }
        return base.filter { $0.session == selection }
    }

    /// What is actually drawn: the fleet, plus the hidden ones when asked
    /// for, narrowed to the selection alone while the band is showing.
    private var lanes: [LaneView] {
        let base = revealingHidden ? runtime.frame.visibleLanes + runtime.frame.hidden
                                    : runtime.frame.visibleLanes
        return Self.lanes(from: base, banded: banded, selection: runtime.frame.selection)
    }

    /// **`OverviewLayout.fleetRows(usableHeight:banded:)`, hoisted once** so
    /// `body`'s `LazyHGrid`, `cards`' per-card prompt cap and `move(_:)`'s
    /// traversal stride all agree.
    ///
    /// **Gated on `layout == .row` here, not by each reader.** `fleetRows` knows
    /// nothing about `layout`, so an ungated read would give `.grid`/`.column` a
    /// `rows` of 2 whenever their region is tall, and `move(_:)` would apply a
    /// column-major stride to a single-column or adaptive grid and misroute arrow
    /// keys.
    private var rows: Int {
        layout == .row ? OverviewLayout.fleetRows(usableHeight: fleetSize.height, banded: banded) : 1
    }

    /// **Whether the connection-setup empty state belongs on screen.** Static so
    /// it is testable without a view (like `DeckWindow.bandShown`). Reads the
    /// UNFILTERED `frame.lanes`, never `lanes` above: `ConnectCard` claims
    /// "nothing has ever spoken to me", and hiding the one visible lane (or a
    /// selection that just got hidden) can make the narrowed set read empty while
    /// the deck is still connected. `body`'s `.overlay` reads this directly.
    static func showsConnectCard(for frame: Frame) -> Bool {
        frame.lanes.isEmpty
    }

    var body: some View {
        // The selected card can end up off-screen when the scroll position never
        // follows it. Live paths:
        //   (a) The toolbar's "Session Details" button (`DeckWindow.detailToggle`)
        //       jumps selection to the first needs-you lane across ALL lanes, not
        //       only the ones drawn here.
        //   (b) A decision's arrival auto-opens `frame.decisions.first`'s session
        //       (`DeckWindow.autoOpen`) wherever its card sits.
        // While banded, `lanes` holds only the selected card, so no second card can
        // fall out of view (see `scrollToSelection`).
        ScrollViewReader { proxy in
            ScrollView(layout.scrollAxis) {
                // One container for the whole fleet, so the system computes the glass once
                // for the group instead of every card sampling its own backdrop (see
                // `DecisionBar`).
                GlassEffectContainer(spacing: 12) {
                    Group {
                        switch layout {
                        case .grid:
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: OverviewLayout.cardMinimumWidth),
                                                        spacing: 12)],
                                      spacing: 12) {
                                cards
                                shelf
                            }
                        case .row:
                            // The strip's shape. Cards enumerate along the ABUNDANT axis (a 1920 x 480
                            // deck has width, not height), so each keeps as much height as a row can
                            // give it.
                            //
                            // **One `LazyHGrid`, at 1 row or 2, rather than a lazy stack beside a
                            // separate grid.** `banded` flips `rows` to 1 in the same render pass the
                            // selection lands; swapping containers would break view identity and tear
                            // down the rows, their focus and the scroll position (see
                            // `DeckWindow.body`). A single-row `LazyHGrid` lays out exactly like a
                            // `LazyHStack`, so one container can be both shapes. If a glide is ever
                            // wanted, use a matchedGeometryEffect hero OUTSIDE this lazy container; never
                            // re-animate its children.
                            //
                            // **Bounded cards always.** Every card fills its row's height uniformly
                            // (`cards`' frame modifiers), top-aligned, with `Spacer(minLength: 0)`
                            // absorbing the gap above the pinned footer. Height comes from the CONTAINER,
                            // not a sibling comparison: in a lazy stack a shared-tallest height only
                            // covers what has materialised, so scrolling a taller card in would resize
                            // the visible ones.
                            LazyHGrid(rows: Array(repeating: GridItem(.flexible(),
                                                                      spacing: OverviewLayout.fleetRowSpacing),
                                                  count: rows),
                                      spacing: OverviewLayout.fleetRowSpacing) {
                                cards
                                shelf
                            }
                        case .column:
                            LazyVStack(spacing: 8) { cards; shelf }
                        }
                    }
                    .padding(12)
                    // The slot map lives on the padded grid content, INSIDE the scroll and
                    // INSIDE `GlassEffectContainer`. Every card's `.onGeometryChange`
                    // (`card(for:)`) reads its frame in `.named("fleet")`: one shared origin for
                    // `slots`, whichever grid case is laid out.
                    .coordinateSpace(.named("fleet"))
                }
                // **The fleet's content is transaction-proof: no ambient animation reaches
                // a card.** The only ambient transaction here is the band-open spring
                // (`DeckWindow`'s `.animation(_:value: banded)`), and letting it in caused
                // four measured artifacts:
                //
                //   1. Siblings removed from `lanes` rode the spring as full-opacity ghosts
                //      for its ~0.68s settle (a lazy container never interpolates its
                //      default `.opacity` removal), drawn on top of the selected card, then
                //      popped out ~150ms after it settled.
                //   2. `.transition(.identity)` corrupted the grid across the next mass
                //      insertion: the restored fleet came back scrambled and never
                //      self-healed. Never attach an `AnyTransition` to a child of these
                //      containers.
                //   3. A per-card `.transaction` guard cannot fix 1: removal scheduling
                //      belongs to the CONTAINER's diff.
                //   4. The animated card drew its selection stroke at the destination frame
                //      from the first flight frame, while the glass morph showed a
                //      resampled ghost of its content.
                //
                // **Placement is load-bearing: on `GlassEffectContainer` itself, OUTSIDE it,
                // never on the inner `Group`.** The container coordinates its members' glass
                // shapes and must be denied the animation too; with the override on the
                // `Group` the glass coordinator kept the spring while its member set changed
                // instantly, and the close came back scrambled. The selected card therefore
                // CUTS to the band-header pose. `DeckWindow`'s spring still eases the fleet's
                // width and the band's slide-in, and `CardWash`'s own
                // `.animation(_:value: style)` re-arms below this override.
                //
                // **The kill is CONDITIONAL on `!editing`.** An unconditional kill cancels
                // the `withAnimation(EditTune.slide)` that `dragGesture(for:)` makes on a
                // retarget (measured: the reorder snapped to its final position within 40ms
                // of a 0.35s spring). The four artifacts are all browse-time mass-insertion
                // effects and the displayed order never changes outside edit mode, so while
                // editing the reorder springs (`EditTune.slide`/`.settle`) win.
                .transaction { transaction in
                    if !editing { transaction.animation = nil }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            // **V1 limitation (`docs/UX_DESIGN.md`): a fleet overflowing the strip's
            // width cannot reorder past the fold.** The slot map and
            // `ReorderMath.retargetIndex` read screen-space coordinates, and a live
            // scroll offset under an in-flight drag would be a second source of truth,
            // so scrolling is disabled while editing.
            .scrollDisabled(editing)
            // Arrow-key traversal; see `move(_:)`.
            .onMoveCommand { move($0) }
            .overlay {
                // Nothing on the glass is five different states, not one, and "never
                // connected" must not read like the others. `Self.showsConnectCard(for:)`
                // explains why this reads `frame.lanes` rather than `lanes`.
                if Self.showsConnectCard(for: runtime.frame) { ConnectCard(runtime: runtime) }
            }
            // Paths (a) and (b) above both funnel through `frame.selection` changing
            // (both are `runtime.select(_:)`).
            //
            // While banded, `lanes` is the selected card alone, so `scrollToSelection` is
            // a no-op for selection changes that stay banded. On collapse (`old` a real
            // session, `new` nil) the same render pass flips `banded` to false, so `lanes`
            // is the full fleet again and scrolling to the just-collapsed id brings it
            // back into view.
            .onChange(of: runtime.frame.selection) { old, new in
                if new == nil, let old {
                    proxy.scrollTo(old)
                } else {
                    scrollToSelection(with: proxy)
                }
            }
            // React to the raw size rather than `layout` (`OverviewLayout.forSize` only
            // recomputes at row/grid/column thresholds). Needed while a decision is
            // STAGED: `banded` reads `false` (`DeckWindow.bandShown`'s guard) even though
            // `frame.selection` is set, so `lanes` is the full fleet and a window resize
            // can scroll the selected card out of view.
            .onChange(of: fleetSize) { _, _ in
                scrollToSelection(with: proxy)
            }
            // Reveal-after-select: a toolbar jump or autoOpen selects a HIDDEN needs-you
            // lane and `scrollTo` no-ops on the unrendered card; when the user then opens
            // the shelf the card materializes at the far end with nothing scrolling to it.
            .onChange(of: revealingHidden) { _, _ in
                scrollToSelection(with: proxy)
            }
            // A retired lane is dropped live and shifts every later card 312pt
            // left, which can slide a leading-edge selected card out of view
            // with neither existing trigger firing.
            .onChange(of: lanes.map(\.session)) { _, current in
                scrollToSelection(with: proxy)
                // **The dragged lane retiring mid-gesture.** Its card leaves the tree with
                // the gesture attached and `onEnded` may never fire, so the stale `drag` is
                // cleared once the fleet stops naming it. The draft is kept: `draftApplied`
                // skips a retired id, and the rest of the arrangement should survive one
                // neighbor's exit.
                if let drag, !current.contains(drag.session) {
                    self.drag = nil
                }
            }
            // **Exit hygiene: every flip of `editing` starts edit-mode view state
            // clean.** Exiting matters: `DeckWindow`'s band-open rule can end edit mode
            // mid-drag, and a stale `drag`/`draftOrder` would draw a lifted card with
            // nothing to drop into.
            //
            // **Never clear `slots` here.** `.onGeometryChange` is EDGE-triggered: it
            // fires when its computed value changes, not once per layout pass. Emptying
            // the dictionary changes no card's geometry, so nothing re-reports and the
            // map stays empty. With no slots `ReorderMath.nearestID` has no candidate,
            // `retargetIndex` answers nil every frame, and the dragged card follows the
            // finger while no neighbour makes room (reordering worked exactly once).
            // Stale entries are harmless: they are overwritten when the card moves, and
            // `nearestID` only walks the CURRENT draft order (see the note in `chrome`
            // on why there is no `.onDisappear` pruning either).
            .onChange(of: editing) { _, _ in
                drag = nil
                draftOrder = nil
            }
        }
    }

    /// Bring the selected card back onto the glass, minimally.
    ///
    /// No `anchor:`: `scrollTo`'s default makes the smallest scroll that reveals
    /// the target instead of recentring it.
    ///
    /// Guarded on a selection existing.
    ///
    /// Neither debounced nor wrapped in `withAnimation`: `onChange` fires once per
    /// settled value and `onGeometryChange` only for a real size change, and a
    /// jump-cut scroll is the honest one.
    ///
    /// **The zero-`withAnimation` rule has exactly TWO exceptions, and this is
    /// neither.**
    /// 1. `DeckWindow`'s band composition animates the fleet's width and the
    ///    band's in/out: GEOMETRY, never a state truth. Only while OPENING with
    ///    `frame.reduceMotion == false`; closing is always a hard cut
    ///    (`DeckWindow.bandTransitionAnimation`).
    /// 2. `CardWash`'s intensity transitions (`SessionCard.washTransitionAnimation`,
    ///    scoped to `CardWash`'s two `Rectangle`s). This eases how loud the
    ///    ambient wash reads, never what a state says: chip, pill, glyph and ticks
    ///    all cut instantly.
    ///
    /// Scrolling, ticks, chips and the `QuestionStage` overlay stay instant; an
    /// interrupt is not a browse.
    ///
    /// A selection that is hidden and not revealed is not in `lanes`, so
    /// `scrollTo` finds no `.id` and does nothing. That is a real no-op: forcing
    /// `revealingHidden = true` would reveal cards nobody asked to see.
    ///
    /// **While banded this is a moot no-op, by construction.** `lanes` holds only
    /// the selected lane, which is already on the glass. Clicking the 3rd or 4th
    /// card once never scrolled it into view because the band covers the rest of
    /// the strip and a fixed-width viewport cannot scroll to a card behind
    /// covering content; the fix is that `lanes` no longer enumerates unreachable
    /// cards while banded.
    private func scrollToSelection(with proxy: ScrollViewProxy) {
        guard let selection = runtime.frame.selection else { return }
        proxy.scrollTo(selection)
    }

    // ------------------------------------------------------- edit mode

    /// What is actually drawn: draft order applied on top of `lanes`. The
    /// `ForEach` iterates this RESULT, a self-contained VALUE, never an index into
    /// live `@Observable` state (see `QuickActionsColumn`, `DecisionBar.swift`): a
    /// `ForEach` child closure can re-run independently of `body`, so closures
    /// read only their captured `lane`.
    private var displayedLanes: [LaneView] { Self.draftApplied(lanes, draft: draftOrder) }

    /// **Draft-first order: the draft's ids in draft order, then every lane the
    /// draft does not name, in `lanes` order.** A `nil` draft is the identity. A
    /// draft id absent from `lanes` contributes nothing; a duplicate id applies
    /// once, at its first occurrence (malformed input, as in `DeckPrefs.decode`'s
    /// `cardOrder`).
    static func draftApplied(_ lanes: [LaneView], draft: [SessionID]?) -> [LaneView] {
        guard let draft else { return lanes }
        var bySession: [SessionID: LaneView] = [:]
        for lane in lanes { bySession[lane.session] = lane }
        var seen = Set<SessionID>()
        var result: [LaneView] = []
        result.reserveCapacity(lanes.count)
        for id in draft where !seen.contains(id) {
            guard let lane = bySession[id] else { continue }
            seen.insert(id)
            result.append(lane)
        }
        for lane in lanes where !seen.contains(lane.session) {
            result.append(lane)
        }
        return result
    }

    /// **The drop's commit order: the SURFACES of the draft's HOSTED lanes, in
    /// draft order.** A hostless lane's order cannot persist (`DeckPrefs.cardOrder`
    /// keys on the surface), so it contributes nothing and rides the fallback tail
    /// of `Projection.manualOrder` rule 2. Feeds `DeckRuntime.reorder(_:)`.
    static func commitOrder(_ draft: [SessionID], lanes: [LaneView]) -> [String] {
        var bySession: [SessionID: LaneView] = [:]
        for lane in lanes { bySession[lane.session] = lane }
        return draft.compactMap { bySession[$0]?.host?.surface }
    }

    @ViewBuilder
    private var cards: some View {
        ForEach(displayedLanes, id: \.session) { lane in
            card(for: lane)
                // Explicit `.id`: `scrollTo` matches on a view's `.id` and SwiftUI does not
                // promise that `ForEach` row identity is the same lookup. Both use the same
                // `SessionID`, so they cannot disagree.
                .id(lane.session)
                // No transition and no per-card transaction override, on purpose: both
                // fail (see the `GlassEffectContainer` comment in `body`). The one exception
                // to the container-scope kill is `editing` (`EditTune.slide`/`.settle`).
        }
    }

    /// One card, browse or editing.
    ///
    /// **Participation rule: a card wiggles and drags only when
    /// `editing && lane.host != nil && !lane.isHidden`.** A HOSTLESS lane's order
    /// cannot persist (`DeckPrefs.cardOrder` keys on the surface), so it rides the
    /// fallback tail of `Projection.manualOrder`. A HIDDEN, revealed lane renders
    /// in this same `ForEach` with the same slot recording (`chrome(...)`) but
    /// gets no gesture and no wiggle: the shelf stays a read-only door onto the
    /// fleet, never a second reorderable surface.
    ///
    /// **The three-way branch below is per-card structural identity churn, a
    /// deliberate trade.** `@ViewBuilder` diffs `if/else` positionally, so every
    /// hosted card rebuilds its wrapper node when Edit Layout toggles. This is the
    /// same mechanism as the `.row` container-swap problem (see `body`), but it
    /// only flips leaf wrappers at a user-initiated mode boundary. Scroll position
    /// survives (the `ScrollView` sits above `cards`) and so does focus
    /// (`.focused($focused, equals:)` is in every branch); only an in-flight press
    /// on the card `Button` resets, which `.disabled(editing)` ended anyway. The
    /// single-identity alternative (gesture always attached with a `GestureMask`,
    /// `.contextMenu` permanently mounted) was rejected because a mounted menu
    /// beside a live drag risks a mid-drag menu race; revisit it if the churn
    /// ever bites.
    @ViewBuilder
    private func card(for lane: LaneView) -> some View {
        let participates = editing && lane.host != nil && !lane.isHidden
        let isDragged = drag?.session == lane.session
        let composed = chrome(cardButton(for: lane), lane: lane,
                              participates: participates, isDragged: isDragged)

        if participates {
            composed.highPriorityGesture(dragGesture(for: lane))
        } else if editing {
            // Editing, but this lane cannot participate (hostless or a revealed hidden
            // card): no gesture and no `.contextMenu` either, so no single card behaves
            // differently from its neighbors in edit mode.
            composed
        } else {
            // Not editing: the ordinary browse fleet. `.contextMenu` attaches ONLY
            // here, never alongside a drag gesture, so a menu can never pop mid-drag by
            // construction.
            composed.contextMenu { SessionMenu(lane: lane, runtime: runtime) }
        }
    }

    /// The card's own `Button`. `.disabled(editing)`: a card that is a live drag
    /// handle stops being a tap target.
    private func cardButton(for lane: LaneView) -> some View {
        Button {
            switch Self.cardTap(layout: layout, selection: runtime.frame.selection,
                                tapped: lane.session) {
            case .select(let session): runtime.select(session)
            case .collapse: runtime.dismiss()
            }
        } label: {
            SessionCard(lane: lane,
                        name: runtime.frame.displayName(for: lane),
                        disambiguator: runtime.frame.disambiguator(for: lane),
                        isSelected: runtime.frame.selection == lane.session,
                        promptLineLimit: layout == .row
                            ? OverviewLayout.promptLineLimit(usableHeight: fleetSize.height, rows: rows,
                                                              banded: banded) : 3,
                        reduceMotion: runtime.frame.reduceMotion,
                        banded: banded)
                // **`.equatable()` wraps `SessionCard` itself, HERE, before the `.frame(...)`
                // modifiers.** It compares the view it is directly attached to using that
                // view's `==` (see `SessionCard.==`); attached after the frame modifiers it
                // would compare the modified-content wrapper, which is not `Equatable`, and
                // would not skip `SessionCard.body`.
                .equatable()
                .frame(width: layout == .row ? OverviewLayout.cardIdealWidth : nil)
                // **Bounded cards always.** `.grid` and `.row` fill whatever height the
                // container gives them, top-aligned, with `SessionCard`'s
                // `Spacer(minLength: 0)` absorbing the rest. Only `.column` stays natural: one
                // card per row, where a stretched height would be blank space.
                .frame(maxWidth: layout == .row ? nil : .infinity,
                       maxHeight: layout != .column ? .infinity : nil,
                       alignment: .top)
        }
        .buttonStyle(.plain)
        .disabled(editing)
        .focused($focused, equals: lane.session)
    }

    /// The wiggle, the lift chrome (scale/shadow, or the Reduce Motion border),
    /// the drag offset, the z-index and the slot recording. Every card gets the
    /// SLOT RECORDING regardless of participation, since the retarget math needs
    /// every visible card's frame; the rest only affects the dragged card or a
    /// wiggling neighbor.
    @ViewBuilder
    private func chrome(_ button: some View, lane: LaneView, participates: Bool, isDragged: Bool) -> some View {
        let reduceMotion = runtime.frame.reduceMotion
        wiggled(button, lane: lane, participates: participates, isDragged: isDragged)
            .scaleEffect(isDragged && !reduceMotion ? EditTune.liftScale : 1)
            .shadow(color: .black.opacity(isDragged && !reduceMotion ? EditTune.liftShadowOpacity : 0),
                    radius: isDragged && !reduceMotion ? EditTune.liftShadowRadius : 0)
            .overlay {
                // Reduce Motion swaps the scale+shadow lift (both read as zero) for a
                // static border, so a dragged card still shows it is lifted.
                if isDragged && reduceMotion {
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(.white.opacity(0.7), lineWidth: EditTune.reducedMotionBorderWidth)
                }
            }
            .offset(dragOffset(for: lane, isDragged: isDragged))
            .zIndex(isDragged ? EditTune.liftZIndex : 0)
            .onGeometryChange(for: CGRect.self) { proxy in
                proxy.frame(in: .named("fleet"))
            } action: { newFrame in
                slots[lane.session] = newFrame
            }
            // **No `.onDisappear` eviction of `slots`: it made the fleet unreorderable.**
            // Pruning on unmount races edit-mode entry: `card(for:)`'s branch changes
            // structural identity when `editing` flips, and SwiftUI mounts the
            // replacement (which reports its geometry) BEFORE tearing down the original,
            // whose `.onDisappear` then deletes the entry just written. The map was empty
            // when edit mode began, so no drag could retarget.
            //
            // Staleness is left alone: a stale frame is overwritten when its card moves,
            // `nearestID` only walks the CURRENT draft order, and an OLD entry still
            // points at a real grid slot. A bounded inaccuracy beats an empty map.
    }

    /// **Wiggle seed identity: the PANE (`lane.host?.surface`), not the
    /// session.** The order persists by surface (`DeckPrefs.cardOrder`), so the
    /// per-card wiggle personality (`ReorderMath.wiggleSeed(for:)`) matches that
    /// scope: a `/exit` and a fresh session in the same tab keep the same rhythm.
    /// Requires `participates`, `!reduceMotion` (`runtime.frame.reduceMotion`),
    /// and not being the dragged card (a lifted card stops wiggling).
    @ViewBuilder
    private func wiggled(_ button: some View, lane: LaneView, participates: Bool, isDragged: Bool) -> some View {
        if participates, !runtime.frame.reduceMotion, !isDragged, let surface = lane.host?.surface {
            button.modifier(WiggleDriver(seed: ReorderMath.wiggleSeed(for: surface)))
        } else {
            button
        }
    }

    /// The dragged card's render offset, recomputed fresh from the LIVE slot map
    /// on every call, which keeps the card glued under the finger through a
    /// retarget (see `ReorderMath.dragRenderOffset`).
    private func dragOffset(for lane: LaneView, isDragged: Bool) -> CGSize {
        guard isDragged, let drag, let slot = slots[lane.session] else { return .zero }
        return ReorderMath.dragRenderOffset(finger: drag.finger, liveSlotFrame: slot,
                                            grabOffsetInCard: drag.grabOffsetInCard)
    }

    /// The reorder gesture, attached only to a PARTICIPATING card
    /// (`card(for:)`'s gate). `draftOrder` holds the in-flight order because the
    /// fleet's real order lives in the projection, not in view state.
    private func dragGesture(for lane: LaneView) -> some Gesture {
        DragGesture(minimumDistance: EditTune.dragMinimumDistance, coordinateSpace: .named("fleet"))
            .onChanged { value in
                if drag?.session != lane.session {
                    // First frame of a NEW drag: fix the grab offset against the card's CURRENT
                    // slot frame and seed `draftOrder` from what is on screen right now.
                    //
                    // **Keyed on the SESSION, not on `drag == nil`.** This gesture belongs to
                    // ONE card, so a mismatched `drag.session` can only be a stale drag: the
                    // previously-dragged lane retired mid-gesture and its `onEnded` never cleared
                    // `drag`. Keying on nil would wedge every future drag into the finger-update
                    // branch below. A fresh gesture on any card reseeds instead, so the wedge
                    // self-heals.
                    let originFrame = slots[lane.session] ?? CGRect(origin: value.startLocation, size: .zero)
                    let grab = ReorderMath.grabOffset(startLocation: value.startLocation, cardFrame: originFrame)
                    drag = CardDrag(session: lane.session, grabOffsetInCard: grab, finger: value.location)
                    draftOrder = displayedLanes.map(\.session)
                } else {
                    drag?.finger = value.location
                }
                guard let order = draftOrder,
                      let currentIndex = order.firstIndex(of: lane.session) else { return }
                let target = ReorderMath.retargetIndex(currentIndex: currentIndex, order: order,
                                                        slots: slots, finger: value.location)
                if let target, target != currentIndex {
                    withAnimation(EditTune.slide) {
                        draftOrder?.moveElement(from: currentIndex, to: target)
                    }
                }
            }
            .onEnded { _ in
                // The commit: hosted lanes only, draft order (`Self.commitOrder`), ONE
                // `DeckRuntime.reorder(_:)` call per drop, never per retarget.
                if let order = draftOrder {
                    runtime.reorder(Self.commitOrder(order, lanes: lanes))
                }
                // Both are cleared INSIDE the settle spring, the draft especially. For
                // HOSTED lanes the projection already agrees with the draft (`reorder(_:)`
                // lands synchronously through `setPrefs` -> `refresh()`). A HOSTLESS lane's
                // draft position was never committed (it rides `Projection.manualOrder`'s
                // fallback tail), so a hosted card dragged PAST one can disagree with the
                // projection; that residue must SETTLE on this spring, not teleport.
                withAnimation(EditTune.settle) {
                    drag = nil
                    draftOrder = nil
                }
            }
    }

    /// Where the keyboard focus goes next.
    ///
    /// Static and pure so a test can drive it without a rendered view.
    ///
    /// **`rows == 1` is the flat traversal:** clamped, not wrapped; right/down and
    /// left/up each step by one.
    ///
    /// **`rows > 1` is column-major**, matching how the `.row` fleet's
    /// `LazyHGrid` fills (down the first column, then the second). With `i` the
    /// current index, `r` = `rows`, `n` = `ids.count`: DOWN steps to `i + 1` only
    /// while `i % r` is not already the bottom track and a next card exists,
    /// otherwise focus holds. UP mirrors it. RIGHT strides a whole column
    /// (`i + r`); when a later column exists but `i + r` overruns a partial last
    /// column, RIGHT lands on the last card. LEFT strides back a column, holding
    /// at the first.
    static func nextFocus(from current: SessionID?, in ids: [SessionID],
                          _ direction: MoveCommandDirection, rows: Int = 1) -> SessionID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let i = ids.firstIndex(of: current) else { return ids.first }
        guard rows > 1 else {
            switch direction {
            // Clamped rather than wrapped. A fleet is a list of real things in
            // a fixed order, and focus jumping from the last back to the first
            // reads as focus getting lost.
            case .right, .down: return ids[min(i + 1, ids.count - 1)]
            case .left, .up: return ids[max(i - 1, 0)]
            @unknown default: return current
            }
        }
        let n = ids.count
        switch direction {
        case .down:
            return (i % rows) + 1 < rows && i + 1 < n ? ids[i + 1] : ids[i]
        case .up:
            return i % rows > 0 ? ids[i - 1] : ids[i]
        case .right:
            if i + rows < n { return ids[i + rows] }
            return (n - 1) / rows > i / rows ? ids[n - 1] : ids[i]
        case .left:
            return i - rows >= 0 ? ids[i - rows] : ids[i]
        @unknown default: return current
        }
    }

    private func move(_ direction: MoveCommandDirection) {
        focused = Self.nextFocus(from: focused, in: lanes.map(\.session), direction, rows: rows)
    }

    /// **What a card tap does, as a value: one of the band's three doors back to
    /// the fleet.** "Collapse = deselect" (see `DeckWindow`'s composition
    /// comment): the band's close button and the toolbar's Session Details toggle
    /// both clear the selection, and a tap on the card already serving as the
    /// band's header does the same instead of re-selecting itself.
    ///
    /// Scoped to `.row` on purpose. `.grid`/`.column` also route to the band
    /// (`OverviewLayout.presentation(...)`) but have no collapse-by-reselecting
    /// affordance; this is `.row`'s door, where the header card reads naturally
    /// as "close what I'm looking at".
    enum CardTap: Equatable {
        case select(SessionID)
        case collapse
    }

    static func cardTap(layout: OverviewLayout, selection: SessionID?,
                        tapped: SessionID) -> CardTap {
        layout == .row && selection == tapped ? .collapse : .select(tapped)
    }

    // ------------------------------------------------------------- the shelf

    /// What is hidden, said out loud even while it is not drawn.
    ///
    /// "The strip declines to draw it; the rail says it is there; nothing pretends
    /// it is gone" (`LaneView.isHidden`). `Frame.hiddenNeedsYou` exists so a
    /// concealed request for a human cannot go unannounced.
    ///
    /// **`!banded`.** The door leads INTO the scrolling fleet, but while banded
    /// `Self.lanes(from:banded:selection:)` filters `base` to the selected lane
    /// regardless of `revealingHidden`, so toggling the shelf reveals nothing.
    /// Composing it anyway costs ~150 pt of width beside the one card
    /// (`OverviewLayout.cardIdealWidth / 2`, see `HiddenShelf`), pushing content
    /// past `bandFleetWidth` and reopening the "content wider than the fixed
    /// viewport" problem (see `bandFleetWidth`). `Ticks` and
    /// `Frame.mastNeedsYou`/`.hiddenNeedsYou` carry the awareness half while
    /// banded.
    @ViewBuilder
    private var shelf: some View {
        if !banded, !runtime.frame.hidden.isEmpty {
            HiddenShelf(count: runtime.frame.hidden.count,
                        needsYou: runtime.frame.hiddenNeedsYou,
                        revealed: $revealingHidden,
                        layout: layout)
                // Nothing attached here, deliberately: the shelf leaves on the same
                // instant-cut terms as every card (see the `.transaction` override on
                // `body`'s `GlassEffectContainer`, which also forbids a `.transition` or
                // per-child transaction here).
        }
    }
}

/// One session, as a card.
///
/// Presentational and runtime-free on purpose: it is measured for real in
/// `TouchTargetTests` and `SessionCardTests` through `NSHostingView`, and a
/// view that needed a runtime to lay out could only be checked by running one.
///
/// **`Equatable`, paired with `SessionOverview.cards`' `.equatable()` call, to
/// stop per-card fan-out.** Without it SwiftUI cannot prove one card's VALUE
/// is unchanged, so one lane's context percent moving would repaint the whole
/// fleet. `==` (below the stored properties) is hand-written: the synthesized
/// conformance would include EVERY stored property, and
/// `onStateChipWidthMeasured` is a closure, never `Equatable`, so it would not
/// compile.
struct SessionCard: View, Equatable {
    let lane: LaneView
    let name: String
    /// The short id that tells two same-named lanes apart, or nil when the
    /// name already stands alone. It does not add a field here — the id is on
    /// every card regardless — it decides how LEGIBLY that id is drawn.
    var disambiguator: String? = nil
    let isSelected: Bool
    /// How many lines the prompt block may show:
    /// `OverviewLayout.promptLineLimit(usableHeight:rows:)`'s answer, threaded
    /// through by `cards` because this view is presentational and runtime-free.
    /// Defaults to 3, the cap `.grid`/`.column` use.
    var promptLineLimit: Int = 3
    /// Whether the system asks for reduced motion (`Frame.reduceMotion`),
    /// threaded through by `cards` like `promptLineLimit`. Defaults to `false`.
    var reduceMotion: Bool = false
    /// **Whether `SessionOverview` is composing the detail band**
    /// (`SessionOverview.banded`), threaded through by `cards`. Combines with
    /// `isSelected` (`hidesContext`, below) to decide whether THIS card's ctx
    /// reading is redundant with the band's big-number readout
    /// (`DetailBand.header`). It never decides WHICH card is selected; that stays
    /// `isSelected`. Defaults to `false` (the ctx reading shows).
    var banded: Bool = false
    /// Test seam only (`RenderSweepTests.theStateChipNeverTruncatesInTheFooter`).
    /// `onGeometryChange`, not a `PreferenceKey`, because a `PreferenceKey` value
    /// never arrives in the headless harness (`measured(_:width:)`; same finding
    /// as `DetailBand.onControlsColumnWidthMeasured`). The closure is the test's,
    /// called with whatever width SwiftUI laid the state chip out at.
    var onStateChipWidthMeasured: ((Double) -> Void)?

    /// Test seam only, and deliberately NOT a stored closure like
    /// `onStateChipWidthMeasured`.
    ///
    /// A stored closure is part of this view's VALUE, which is why `==` below
    /// excludes it. Counting body evaluations needs a seam that is NOT part of any
    /// card's value, so it can watch every evaluation without causing more of
    /// them. A `static var` is process state, invisible to `Equatable` and
    /// `EquatableView`'s comparison.
    ///
    /// `InvalidationTests.oneChangedLaneRepaintsOnlyItsOwnCard` is the one setter
    /// and resets it to nil when done: this is shared mutable state across the
    /// test process.
    @MainActor static var bodyEvalCounter: (() -> Void)?

    /// **The VALUE inputs only.** `onStateChipWidthMeasured` is excluded
    /// (closures are never `Equatable`, and comparing presence would make
    /// identical cards unequal whenever a test attached a probe, defeating the
    /// fan-out fix) and `bodyEvalCounter` is `static`, not part of any instance.
    ///
    /// **Depends on `LaneView.==` excluding `sources`** (`Frame.swift`).
    /// `lhs.lane == rhs.lane` is only true across an update where nothing this
    /// card DRAWS changed, because `LaneView` equality treats "confirmed again by
    /// a different event, same displayed facts" as equal; `sources` re-stamps on
    /// every confirming touch, so comparing it would make this `==` false nearly
    /// every frame.
    ///
    /// **Measured: this conformance did not move the number.** `ForEach`'s own
    /// row reuse, keyed off `LaneView: Equatable` (`SessionOverview.cards`),
    /// already isolated the fan-out (see
    /// `InvalidationTests.oneChangedLaneRepaintsOnlyItsOwnCard`: `[1, 1, 1, 1, 1,
    /// 1]` body evaluations). This `==` makes that invariant explicit and local
    /// instead of resting on undocumented `ForEach` behaviour.
    ///
    /// `nonisolated`: `Equatable`'s requirement is not actor-isolated (SwiftUI's
    /// diffing may call it from anywhere), while `SessionCard` is inferred
    /// `@MainActor` from `View`. Every compared field is a plain `Sendable`
    /// value, so opting this member out is sound.
    nonisolated static func == (lhs: SessionCard, rhs: SessionCard) -> Bool {
        lhs.lane == rhs.lane
            && lhs.name == rhs.name
            && lhs.disambiguator == rhs.disambiguator
            && lhs.isSelected == rhs.isSelected
            && lhs.promptLineLimit == rhs.promptLineLimit
            && lhs.reduceMotion == rhs.reduceMotion
            && lhs.banded == rhs.banded
    }

    /// What a wash LOOKS like, independent of drawing it: none, a fixed level, or
    /// a level that moves between two bounds on a period. `CardWash` is the only
    /// thing that turns one into pixels; this type exists so a test can pin the
    /// RULE without hosting a view. `internal` rather than `private`, like
    /// `contextTint`, so tests can read it.
    enum WashStyle: Equatable {
        case none
        case steady(opacity: Double)
        case pulsing(low: Double, high: Double, period: Double)

        /// The level the wash sits at when nothing is mid-pulse: `.none`'s zero, a
        /// `.steady` wash's only level, or a `.pulsing` wash's OFF floor. `CardWash`
        /// paints this as the always-present base layer; a pulse's excursion above it
        /// is a second, additive layer (see `CardWash` for why summing, not
        /// swapping).
        var baseOpacity: Double {
            switch self {
            case .none: 0
            case .steady(let opacity): opacity
            case .pulsing(let low, _, _): low
            }
        }
    }

    /// A working card's steady level and, BY CONSTRUCTION, a pulsing needs-you
    /// card's quietest instant (`washStyle`'s pulse `low`): needs-you only ever
    /// ADDS urgency on top of what a working card shows.
    static let workingWashOpacity: Double = 0.14
    /// The loudest a wash ever gets — a needs-you card at the crest of its
    /// pulse, or its Reduce-Motion static level.
    static let needsYouWashPeak: Double = 0.30
    /// An errored card's wash opacity. An errored card must not change how loud
    /// it reads.
    static let erroredWashOpacity: Double = 0.22
    /// `docs/UX_DESIGN.md`'s own needs-you pulse figure: one full cycle is
    /// a 0.6 s swell up and a 0.6 s settle back, `easeInOut` each leg.
    static let washPulsePeriod: Double = 1.2

    /// The pure rule: state (and whether motion is reduced) alone decide a
    /// wash's shape.
    ///
    /// **The pulse's midpoint is the errored opacity, by construction:**
    /// `(workingWashOpacity + needsYouWashPeak) / 2 == erroredWashOpacity`. The
    /// signal's SHAPE (steady versus pulsing) tells working and needs-you apart
    /// without changing the strip's average loudness.
    ///
    /// Under Reduce Motion the pulse collapses to a static two-step: working holds
    /// the low step, needs-you is PINNED at the high one, so 0.30 outranking 0.14
    /// stands in for the excursion a still frame cannot show.
    ///
    /// Every pulsing card shares this one `washPulsePeriod`, so two needs-you
    /// cards pulse IN UNISON, deliberately (they read as one urgency; the mast
    /// counter carries the count). If desync is ever wanted, the period could vary
    /// +/-5% by `CardColor.fallbackSlot`'s hash; not built.
    static func washStyle(state: LaneState, reduceMotion: Bool) -> WashStyle {
        switch state {
        case .idle, .ended: .none
        case .working: .steady(opacity: workingWashOpacity)
        case .needsYou:
            reduceMotion
                ? .steady(opacity: needsYouWashPeak)
                : .pulsing(low: workingWashOpacity, high: needsYouWashPeak, period: washPulsePeriod)
        case .errored: .steady(opacity: erroredWashOpacity)
        }
    }

    /// How a CHANGE in wash style is allowed to look; not the pulse itself, which
    /// is `CardWash`'s own ambient animation.
    ///
    /// 0.5 s: longer than the band's 0.3 s `.snappy`
    /// (`DeckWindow.bandTransitionAnimation`) because this eases an AMBIENCE, not
    /// a mechanism, and shorter than a pulse's two 0.6 s legs so a transition is
    /// never mistaken for a stray beat. `nil` under Reduce Motion (hard cut),
    /// safe because reduced motion has no pulse layer to snap out from under.
    static func washTransitionAnimation(reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : .easeInOut(duration: 0.5)
    }

    /// The colour a wash paints in; whether and how loud is `washStyle`'s job
    /// alone.
    ///
    /// `.errored` stays plain `.red`: DANGER OUTRANKS IDENTITY. `CardColor` places
    /// no restriction on a `.custom` pick (it reserves `red` out of the named
    /// palette for this reason), so a near-red custom colour must not let the
    /// errored reading fade into "just what it looks like".
    ///
    /// Every other state reads the lane's identity colour (see
    /// `PresentationTests.identityAndMeaningAreSeparateChannels`).
    ///
    /// **Non-optional, deliberately.** Idle and ended cards carry their identity
    /// colour too, at `WashStyle.none`'s zero opacity, so a none-to-steady
    /// transition eases OPACITY alone, and needsYou-to-errored crossfades identity
    /// into red in one eased transaction instead of two properties that could
    /// disagree on timing.
    var washColor: Color { lane.state == .errored ? .red : lane.color.tint }
    private var badge: PermissionBadge? { PermissionBadge.forMode(lane.permissionMode) }
    private var shortID: String { String(lane.session.raw.prefix(8)) }
    /// The deck can watch this session but not speak to it.
    private var isUnroutable: Bool { lane.host == nil }

    /// The identity bar's width: thick enough to read as the card's spine at
    /// arm's length, thin enough to sit inside the 12pt inner padding (`body`'s
    /// `.padding(12)`).
    ///
    /// An OVERLAY, not a layout member: it costs no height or width, which keeps
    /// every card-height arbiter (`RenderSweepTests.aFullCardFitsTheTwoRowBudget`'s
    /// exact-equality pins, among others) green by construction.
    static let identityBarWidth: Double = 5

    var body: some View {
        // `let _ =`, not a bare statement: `body` is a `@ViewBuilder`, which runs
        // every bare expression statement through `buildExpression` looking for a
        // `View`; a `Void` call has no such overload. A `let` declaration passes
        // through untouched.
        let _ = Self.bodyEvalCounter?()
        VStack(alignment: .leading, spacing: 0) {
            // Full-bleed, against the card's top edge: a gauge read at a glance has to
            // be findable without aiming. The bar reads `ContextLoad` unconditionally,
            // like the footer's number (see `ContextBar`).
            ContextBar(meter: contextMeter)

            VStack(alignment: .leading, spacing: 10) {
                heading
                if badge != nil || lane.branch?.value.isEmpty == false { tags }
                // The 0 tier is the promptless two-row card
                // (`OverviewLayout.promptLineLimit`): a fleet packed that tight drops the
                // block rather than draw zero lines.
                if let prompt = lane.prompt?.value, !prompt.isEmpty, promptLineLimit > 0 { promptBlock(prompt) }
                Spacer(minLength: 0)
                footer
            }
            .padding(12)
        }
        // The identity bar: the card's spine in the lane's colour, drawn in EVERY
        // state, selected or not. Identity is neither selection nor state: this
        // overlay reads only `lane.color` (`selectionIsItsOwnChannel` in
        // `SessionCardTests`).
        //
        // Attached to the outer VStack BEFORE `.clipShape` so the same clip rounds
        // the bar's left corners with the card's.
        //
        // Decoration, never the sole carrier of a fact: with Differentiate Without
        // Color the name, id and chips remain the textual identity channel.
        .overlay(alignment: .leading) {
            Rectangle().fill(lane.color.tint).frame(width: Self.identityBarWidth)
        }
        .clipShape(.rect(cornerRadius: 12))
        // A working, waiting or errored card is washed as well as chipped and
        // glyphed. Decisions live in the band, which only opens for a selection, so
        // the fleet must say WHERE a request is when nothing is selected, and how
        // ACTIVE a lane is, before anyone reads a chip.
        //
        // The wash is a plain fill OVER untinted glass, never a tint on the glass.
        // Materials take their inactive appearance when the window resigns key, and
        // the deck's user is by definition in another window, so tinted glass would
        // wash out to gray exactly when the wash matters.
        //
        // The hue is the lane's IDENTITY colour (see `washColor`, including the
        // `.errored` exception), not a fixed orange, so "which one needs me" reads
        // from across the room. The MEANING channel (loud chip, glyph, the ticks'
        // orange in `DeckWindow.swift`) is unchanged, so a reader who cannot tell
        // hues apart loses nothing.
        //
        // `CardWash` owns INTENSITY (steady, pulsing, or the change between); this
        // call site only supplies WHAT to paint (`washColor`) and WHICH shape
        // (`washStyle`).
        .background {
            CardWash(color: washColor,
                     style: Self.washStyle(state: lane.state, reduceMotion: reduceMotion),
                     transition: Self.washTransitionAnimation(reduceMotion: reduceMotion))
        }
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
        // Selection is an OUTLINE, not a fill: a fill paints over the state glyph
        // and chip (a needs-you badge rendered white), the less important signal
        // destroying the more important one. An outline is its own channel.
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        }
        .contentShape(.rect(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(spokenDescription)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // ------------------------------------------------------------- heading

    private var heading: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: lane.state.symbolName)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(lane.state.tint)
                .font(.title3)
                .accessibilityHidden(true)
            Text(name)
                .font(.headline)
                .lineLimit(1)
                // Tail, not middle. The end of a path is what identifies it.
                .truncationMode(.tail)
            // "The deck can watch this session but not speak to it" (`LaneView.host`)
            // must be visible while scanning, not only after selecting the lane.
            if let routeMarkSymbol {
                Image(systemName: routeMarkSymbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .help("The deck can watch this session but not send to it")
            }
            // Revealed from the shelf, so it sits beside non-hidden cards. Marked, or it
            // would be indistinguishable from the fleet.
            if lane.isHidden {
                Image(systemName: "eye.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                    .help("Hidden from the deck")
            }
            Spacer(minLength: 0)
        }
    }

    // ---------------------------------------------------------------- tags

    /// Branch and permission mode. The badge takes layout priority and the
    /// branch gives way: a truncated branch is an inconvenience, and a
    /// truncated "Bypassing permissions" is the deck failing at its job.
    private var tags: some View {
        HStack(spacing: 8) {
            if let branch = lane.branch?.value, !branch.isEmpty {
                Text(branch)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if let badge {
                Chip(ChipSpec.permission(badge))
                    .layoutPriority(1)
            }
            Spacer(minLength: 0)
        }
    }

    // -------------------------------------------------------------- prompt

    /// What this session was last asked to do: the single field that answers
    /// "what is it doing".
    private func promptBlock(_ prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("LAST USER PROMPT")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.6)
            Text(prompt)
                .font(.callout)
                .lineLimit(promptLineLimit)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // -------------------------------------------------------------- footer

    /// Four facts on one line.
    ///
    /// **The three facts that decide whether somebody walks over never give way:
    /// `.layoutPriority(1)`, the same idiom as the permission badge in `tags`.**
    /// SwiftUI's fair-share allocation proposes each unprioritized child
    /// `remaining / unallocated-children` while the `Spacer(minLength: 4)` still
    /// counts in that divisor, so a chip with real slack in the row can be offered
    /// less than it needs (measured: the "Working" chip wants 75 pt and was offered
    /// 71 pt, truncating to "Worki..."). The tool name gives way first (it has its
    /// own `lineLimit(1)`), so priority goes on the state chip, the context
    /// reading and the short id. `RenderSweepTests.theStateChipNeverTruncatesInTheFooter`
    /// is the arbiter.
    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Chip(ChipSpec.state(lane.state))
                .layoutPriority(1)
                .onGeometryChange(for: Double.self) { $0.size.width } action: { width in
                    onStateChipWidthMeasured?(width)
                }
            if let tool = lane.lastTool {
                Text(tool)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            // **`!hidesContext`:** the band's big-number readout already shows this
            // fact for the selected session (`DetailBand.header`), so the selected card
            // must not repeat it. Every other card keeps its reading (see `hidesContext`).
            if let reading = visibleContextReading, !hidesContext {
                Text(reading)
                    .font(.caption.monospaced())
                    .foregroundStyle(contextTint)
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            // Always, not only on a name collision — the id is the identity of
            // record, the one thing that survives a `--resume`. What the
            // collision changes is how loudly it is drawn: when it is the only
            // thing telling two cards apart it stops being a footnote.
            Text(shortID)
                .font(idFont)
                .foregroundStyle(disambiguator == nil ? AnyShapeStyle(.tertiary)
                                                      : AnyShapeStyle(.secondary))
                .layoutPriority(1)
        }
    }

    /// **What the footer SAYS about context**: the statusline's number, in the
    /// statusline's idiom, in every state.
    ///
    /// One reading, not two. Swapping in the meter's label on alarm quoted what
    /// was LEFT beside a number quoting what was used (`ctx:91%` became `9%
    /// left`); the deck must not reinterpret a relayed number. `Meter.used`
    /// carries exactly what Claude Code reported, and the alarm changes the ink,
    /// not the arithmetic.
    var visibleContextReading: String? { contextMeter?.reading }

    /// **Whether THIS card's footer reading is redundant with the band's
    /// big-number readout for the same session: true only for the selected card
    /// while banded.** `isSelected` alone is wrong: a card can be selected while
    /// nothing bands (a `QuestionStage`/`QuestionMirrorStage` overlay owns the
    /// hold, and the band is not composed while staged; see
    /// `DeckWindow.bandShown`). The ctx number then appears nowhere else, so
    /// hiding it would be a silent loss. `banded` alone is wrong the other way:
    /// while banded `SessionOverview.lanes` already narrows to the selected lane,
    /// so every card rendered is the selected one today, but stating
    /// `isSelected && banded` keeps that a description of the current narrowing
    /// rather than a hidden assumption.
    var hidesContext: Bool { isSelected && banded }

    /// **One meter, read by everything that draws the gauge.**
    ///
    /// The bar, the footer's words and the footer's ink all need the same
    /// severity, and deriving it three times is three places that can come to
    /// disagree — which is the defect that produced a red bar beside
    /// `ctx:91%` in the first place.
    ///
    /// Not private: it is the exact value `ContextBar` fills from, so a test
    /// asserting which way the bar runs has to read this rather than a string
    /// that merely tracks it.
    var contextMeter: Meter? {
        lane.contextPercent.map(Meter.context(usedPercent:))
    }

    /// **The footer's number, ALWAYS in its load colour, never grey.** A grey
    /// number beside `ContextBar`'s fill and the `.working` chip (both
    /// accent-coloured) told a different, coarser story, so one rule,
    /// `ContextLoad` (`Frame.swift`), is read here, at `ContextBar`'s fill and at
    /// `DetailBand.header`'s readout: the same three-state colouring everywhere
    /// ctx paints, regardless of staleness.
    ///
    /// The card carries NO age signal for ctx, deliberately: a 30 s max age
    /// against a feed that only renders during active turns greyed most cards most
    /// of the time, and age has no business dimming a fact that does not decay
    /// (see `ContextBar`). `LaneView.contextStale` survives only for the meters
    /// alarm gate (`Frame.swift`).
    var contextTint: Color {
        ContextLoad(percent: lane.contextPercent ?? 0).tint
    }

    /// The font the session id is drawn in — larger and heavier when a name
    /// collision makes it the only thing telling two cards apart.
    ///
    /// A property rather than an expression inline in `footer` so a test can
    /// assert the escalation happens. Measuring the card cannot see it: the
    /// footer's height is set by the state chip either way, so a height
    /// assertion passes identically whether or not the escalation exists.
    var idFont: Font {
        disambiguator == nil ? .caption2.monospaced()
                             : .caption.monospaced().weight(.semibold)
    }

    /// The glyph marking a lane the deck cannot send to, or nil. Same reason
    /// as `idFont`: the mark rides inside a baseline-aligned row and adds no
    /// height, so what a test can check is that the card decided to draw it.
    var routeMarkSymbol: String? {
        isUnroutable ? "antenna.radiowaves.left.and.right.slash" : nil
    }

    // ------------------------------------------------------- what it says

    /// Exposed for tests: everything on the card, in one sentence, in the
    /// order somebody triaging would want it. Colour is the one field that
    /// breaks "triage order" on purpose and sits last: an identity trim,
    /// not a triage-critical fact — it says WHICH card this is, never WHAT
    /// IT NEEDS, so it goes after everything that does.
    var spokenDescription: String {
        var parts = [name, lane.state.spokenName]
        if lane.isHidden { parts.append("hidden from the deck") }
        if let badge { parts.append(badge.spokenDescription) }
        if isUnroutable { parts.append("no route — the deck can watch this session but not send to it") }
        if let branch = lane.branch?.value, !branch.isEmpty { parts.append("branch \(branch)") }
        if let used = lane.contextPercent { parts.append("context \(used)% used") }
        if let tool = lane.lastTool { parts.append("last tool \(tool)") }
        if let prompt = lane.prompt?.value, !prompt.isEmpty { parts.append("last prompt, \(prompt)") }
        parts.append("session \(shortID)")
        parts.append("color \(lane.color.spokenName)")
        return parts.joined(separator: ", ")
    }
}

/// The wash layer: state intensity only, in the card's `.background` slot.
///
/// **Why `.animation(_:value:)` lives HERE and not on `SessionCard`'s modifier
/// chain.** Its scope is exactly the two `Rectangle`s in the `ZStack` below;
/// on the card's chain it would ease every other animatable attribute on a
/// state flip too, catching the chip, pills and glyph mid-tween when they are
/// supposed to cut. A headless test checking only final values cannot see that
/// mistake.
///
/// **Why a `phaseAnimator` over `[0, 1]`, not `repeatForever` or
/// `TimelineView`.** `repeatForever(autoreverses:)` is an ADDITIVE implicit
/// animation that outlives its transaction, so a pulsing card leaving
/// `.needsYou` mid-cycle fights its own removal (frozen or ghost pulses).
/// `TimelineView(.animation)` re-evaluates the body every frame: real CPU on
/// every pulsing card, forever. `phaseAnimator`'s CONTINUOUS overload (the
/// `[Double]` form) cycles abstract phase values while Core Animation
/// interpolates, and the content closure re-runs once per phase (per 0.6 s
/// leg), not per frame. A one-shot `keyframeAnimator` plays once, but the
/// pulse must last as long as the state.
///
/// **Idle CPU stays idle.** The animator node exists ONLY inside
/// `if case .pulsing` below, so an idle, working, errored or ended fleet runs
/// ZERO animation clocks, matching `DeckState.scheduledWork`'s accounting
/// (`DeckState.swift`). The phases array is never mutated mid-flight (SwiftUI
/// does not document that case); a style change removes and reinserts the
/// node.
///
/// **The layering law: sum, never multiply, and only one animation touches the
/// base.** The pulse layer's opacity is `(high - low) * phase`, the EXCURSION
/// alone, so removing it only subtracts the excursion. The base owns
/// `style.baseOpacity`, and the ONE `.animation(transition, value: style)`
/// below is the only thing that moves it. none->steady tweens the base
/// 0->0.14; working->needsYou leaves the base at 0.14 (working's steady level
/// equals the pulse's low; see `SessionCard.washStyle`) while the pulse layer
/// blooms in on top; pulsing->resolved removes the pulse node under
/// `.transition(.opacity)` while `transition` eases the base, so the envelope
/// shrinks smoothly.
///
/// **Window occlusion.** `phaseAnimator` is not documented to suspend or
/// resync while its window is off-screen; worst case a resumed pulse holds
/// some value in `[low, high]`, never louder than a legitimate peak, and the
/// chip and glyph still carry the state. Worth a live look; no speculative
/// code.
private struct CardWash: View {
    let color: Color                        // `SessionCard.washColor`
    let style: SessionCard.WashStyle        // `SessionCard.washStyle(state:reduceMotion:)`
    let transition: Animation?              // `SessionCard.washTransitionAnimation(reduceMotion:)`

    var body: some View {
        ZStack {
            // Base: the state truth's steady level. Structurally ALWAYS present
            // (opacity 0 for `.none`), so every boundary is an opacity tween on an
            // EXISTING layer, never a layer appearing or disappearing.
            Rectangle().fill(color).opacity(style.baseOpacity)

            // Pulse: ONLY the excursion above the low, additive on the base (see the
            // layering law above).
            if case .pulsing(let low, let high, let period) = style {
                Rectangle().fill(color)
                    .phaseAnimator([0.0, 1.0]) { fill, phase in
                        fill.opacity((high - low) * phase)
                    } animation: { _ in .easeInOut(duration: period / 2) }
                    .transition(.opacity)
            }
        }
        // The ONE transition driver for this layer — scoped HERE, never on
        // the card's own chain (see this type's own doc comment above).
        .animation(transition, value: style)
        .clipShape(.rect(cornerRadius: 12))
    }
}

// ------------------------------------------------------------- the shelf

/// The hidden lanes, counted and reachable.
///
/// The count is stated whether or not anything is wrong with it, because a
/// control that appears only when there is bad news is a control nobody has
/// learned the position of. What changes with the news is the volume: a hidden
/// session asking for a human gets a loud chip, since concealing exactly that
/// is the one thing this deck exists not to do.
struct HiddenShelf: View {
    let count: Int
    let needsYou: Int
    @Binding var revealed: Bool
    let layout: OverviewLayout

    var body: some View {
        Button { revealed.toggle() } label: {
            content
                .padding(12)
                // Half a card in the row, full width everywhere else. Narrower
                // than a card on purpose: it is a door, not a session, and
                // sizing it like one would put a thing you cannot act on in the
                // middle of a fleet of things you can.
                .frame(maxWidth: layout == .row ? nil : .infinity, alignment: .leading)
                .frame(width: layout == .row ? OverviewLayout.cardIdealWidth / 2 : nil,
                       alignment: .leading)
                .glassEffect(.regular, in: .rect(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .touchTarget()
        .accessibilityLabel(spokenDescription)
        .accessibilityAddTraits(.isButton)
        .help(revealed ? "Hide them again" : "Show the hidden sessions")
    }

    @ViewBuilder
    private var content: some View {
        // The strip stacks it and everything else lays it out along the row,
        // for the same reason the fleet does: spend whichever axis is spare.
        if layout == .row {
            VStack(alignment: .leading, spacing: 8) { pieces }
        } else {
            HStack(spacing: 10) { pieces }
        }
    }

    @ViewBuilder
    private var pieces: some View {
        Label("\(count) hidden", systemImage: revealed ? "eye" : "eye.slash")
            .font(.callout.weight(.medium))
            .lineLimit(1)
        if needsYou > 0 {
            Chip(symbol: LaneState.needsYou.symbolName,
                 title: "\(needsYou) needs you",
                 tint: LaneState.needsYou.tint, isLoud: true)
        }
        Spacer(minLength: 0)
        Image(systemName: revealed ? "chevron.up" : "chevron.down")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Exposed for tests: a concealed request for a human has to be announced,
    /// and the announcement is the whole point of this control.
    var spokenDescription: String {
        let base = "\(count) hidden \(count == 1 ? "session" : "sessions")"
        let news = needsYou > 0 ? ", \(needsYou) of them waiting for you" : ""
        return base + news + (revealed ? ". Showing." : ". Hidden.")
    }
}

// -------------------------------------------------------------- the ticks

/// What the band narrowed the fleet to ONE CARD hides, stated at the seam
/// rather than left silent.
///
/// While banded, `SessionOverview.lanes(from:banded:selection:)` filters the
/// fleet to the SELECTED lane alone (see `OverviewLayout.bandFleetWidth`), so
/// this seam is the ONLY place on the glass saying anything about the lanes
/// the band hides: one mark per needs-you lane, nothing for a calm fleet.
/// Every non-selected card is off-viewport BY CONSTRUCTION (filtered out of
/// `lanes`, not scrolled past), so no scroll tracking is needed;
/// `offViewportNeedsYou` is the whole rule.
///
/// Visual-only: thin wash-coloured marks, not buttons, so no `contextMenu`,
/// no `Button`, nothing to route a tap into.
///
/// **Marks beyond the glass clip.** `body` is a plain `VStack` of exact-size
/// capsules with no cap of its own; a busy enough fleet (13+ off-viewport
/// needs-you lanes, banner up) would report that stack's height as ITS minimum
/// and drag the window floor up, the same failure `DetailBand.body`'s
/// containment closes for the band beside it. `DeckWindow.body` caps it with
/// `.frame(minHeight: 0, maxHeight: .infinity, alignment: .center).clipped()`
/// on the `Ticks` child (see its comment for the arithmetic). So this view is
/// an indicator, not a ledger: past the seam's height the excess marks are
/// silently trimmed. A "+N" fold is possible follow-on work.
struct Ticks: View {
    /// The full lane set — hidden included. `Frame.mastNeedsYou`'s own
    /// conservation rule is the reason: a concealed request for a human is
    /// exactly what this deck exists not to lose track of, on or off the
    /// shelf.
    let lanes: [LaneView]
    let selection: SessionID?

    /// Pure projection, so the seam's own honesty — every needs-you lane
    /// off the narrowed viewport, none dropped — is testable without a
    /// view. The selected lane is excluded on purpose: it is the one card
    /// still on the glass, and a tick for it would be marking something
    /// that is not actually off-screen.
    static func offViewportNeedsYou(lanes: [LaneView], selection: SessionID?) -> [LaneView] {
        lanes.filter { $0.state == .needsYou && $0.session != selection }
    }

    private var marks: [LaneView] { Self.offViewportNeedsYou(lanes: lanes, selection: selection) }

    var body: some View {
        VStack(spacing: 3) {
            ForEach(marks, id: \.session) { _ in
                Capsule()
                    .fill(LaneState.needsYou.tint.opacity(0.85))
                    .frame(width: 4, height: 12)
            }
        }
        // `OverviewLayout.bandSeamWidth`, not a private copy: it lives in `DeckCore`
        // because `DeckWindow.bandWidth` and `OverviewLayout.bandZones(for:)`'s pure
        // tests need production's EXACT subtraction, and `DeckCoreTests` cannot import
        // `DeckApp`. It is a real `HStack` sibling, not an overlay, so it costs this
        // many points of the content region.
        .frame(width: OverviewLayout.bandSeamWidth)
        .accessibilityElement(children: .ignore)
        .accessibilityHidden(marks.isEmpty)
        .accessibilityLabel(spokenDescription)
    }

    /// Exposed for tests, the same reason `HiddenShelf.spokenDescription` is:
    /// a concealed request for a human has to be announced, not merely drawn.
    var spokenDescription: String {
        "\(marks.count) session\(marks.count == 1 ? "" : "s") need\(marks.count == 1 ? "s" : "") you, off screen"
    }
}

// ------------------------------------------------------------- the gauge

/// The context gauge, drawn along the card's top edge.
///
/// **Used, and only used.** The bar fills as the window is consumed, the
/// direction the number arrives in. `Meter.context` supplies the used
/// percentage, unaltered.
///
/// **Coloured by `ContextLoad`, unconditionally: never grey, and never a
/// second ladder from the footer's number.** The bar once dimmed to
/// `.tertiary` whenever `LaneView.contextStale` was true, which at a 30 s max
/// age (`MaxAges.contextPercent`) against a feed that only renders during
/// active turns is most cards most of the time. Even when fresh it filled from
/// `Meter.severity` (`.tint`/red at the 90% alarm line), a coarser ladder than
/// the footer's `ContextLoad` ramp (blue/orange/red at 50/75): a 63% card drew
/// a BLUE bar under an ORANGE number.
///
/// **Why grey was never right.** A context percentage does not decay with
/// time: an idle session's context is exactly what it was, and the last
/// statusline reading stays TRUE until the next turn moves it. Age-dimming
/// answers "can I still trust this number", and for ctx the answer is always
/// yes. The usage gauge does not dim either (`UsageIndicator`).
/// `LaneView.contextStale` survives only for ALARMS: a red raised on an old
/// reading is one the deck cannot vouch for.
///
/// **The red boundary is 75, with orange from 50.** `Meter.severity`/`.label`
/// are unchanged and still govern the labelled-red rule's cross-lane
/// falsifier (`Frame.unlabelledAlarms`), a different question (does an alarm
/// carry a cause) answered in the frame, not the pixel.
///
/// An unfed gauge draws its track and nothing else. Never `0%`: a reading
/// nobody supplied and a session that has used none of its window must not
/// look alike.
struct ContextBar: View {
    /// Given rather than derived. The card computes one meter and hands it to
    /// the bar and the footer's own words, because two derivations of one
    /// meter are two things that can disagree.
    let meter: Meter?

    static let height: Double = 4

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.quaternary)
                if let meter {
                    Rectangle()
                        .fill(Self.fill(for: meter))
                        .frame(width: geo.size.width * Double(meter.used) / 100)
                }
            }
        }
        .frame(height: Self.height)
        // The footer states the same reading in words and in a number. A bar
        // repeated into VoiceOver is one more thing to sit through on the way
        // to the sentence that actually says it.
        .accessibilityHidden(true)
    }

    /// **The rule `body` paints with, kept as its own directly-testable
    /// function.** `contextTint` (`SessionCard`) is held to the identical formula,
    /// and `staleReadingsAreUnmarkedByAge`'s bar twin (`SessionCardTests`) calls
    /// this directly rather than rendering pixels to prove the bar never greys.
    static func fill(for meter: Meter) -> Color {
        ContextLoad(percent: meter.used).tint
    }
}

// -------------------------------------------------------------- the chip

/// A fact, as a filled capsule.
///
/// Filled because it has to survive being glanced at from a metre away, which
/// is how a deck is read. A word in a colour is a word you have to look at; a
/// chip is a shape you can see. Used for the lane state and for the permission
/// badge — the two facts that decide whether somebody walks over.
struct Chip: View {
    let symbol: String
    let title: String
    /// The colour this chip is ABOUT.
    let tint: Color
    /// Whether it fills with that colour or merely tints its glyph.
    let isLoud: Bool

    init(symbol: String, title: String, tint: Color, isLoud: Bool) {
        self.symbol = symbol; self.title = title; self.tint = tint; self.isLoud = isLoud
    }

    init(_ spec: ChipSpec) {
        self.init(symbol: spec.symbol, title: spec.title, tint: spec.tint, isLoud: spec.isLoud)
    }

    /// **White text on a system colour does not clear WCAG AA.**
    ///
    /// Measured, not assumed: white on systemOrange is 2.20:1 and on
    /// systemRed 3.55:1, against 4.5:1 for text at this size — and those are
    /// the fills for `needsYou` and `errored`, the two states a fleet monitor
    /// exists to make unmissable. They were the least legible text on the
    /// card. Darkening the fill by a third takes them to 4.91:1 and 7.25:1
    /// while keeping the hue that carries the meaning.
    static let loudDarkening: Double = 0.35

    var body: some View {
        HStack(spacing: 4) {
            // The quiet chip's glyph keeps the raw tint, and for `working`
            // that is `.accentColor` — which the user chooses, and which they
            // may well choose badly against a `.quaternary` fill. That is
            // survivable here and only here: the word sits beside the glyph in
            // `.secondary`, which holds its contrast by construction, so a
            // washed-out glyph loses decoration rather than information. The
            // loud states never take this path.
            Image(systemName: symbol)
                .foregroundStyle(isLoud ? AnyShapeStyle(.white) : AnyShapeStyle(tint))
            Text(title)
                .foregroundStyle(isLoud ? AnyShapeStyle(.white) : AnyShapeStyle(.secondary))
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .truncationMode(.tail)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(isLoud ? AnyShapeStyle(tint.mix(with: .black, by: Self.loudDarkening))
                           : AnyShapeStyle(.quaternary),
                    in: .capsule)
    }
}

/// What a chip SAYS, as data rather than as a view.
///
/// A view held in an array and re-rendered by index is correct only for as
/// long as the array's shape is invariant — add a third chip, or order them by
/// severity, and positional identity starts morphing one chip into another.
/// Nothing here does that today; this exists so that nothing here can.
struct ChipSpec: Identifiable, Equatable {
    let id: String
    let symbol: String
    let title: String
    let tint: Color
    let isLoud: Bool

    /// `id` names the ROLE rather than the reading, so a chip whose title
    /// changes stays the same chip and animates instead of being replaced.
    init(id: String, symbol: String, title: String, tint: Color, isLoud: Bool) {
        self.id = id; self.symbol = symbol; self.title = title
        self.tint = tint; self.isLoud = isLoud
    }

    static func state(_ state: LaneState) -> ChipSpec {
        ChipSpec(id: "state", symbol: state.symbolName, title: state.spokenName,
                 tint: state.tint, isLoud: state == .needsYou || state == .errored)
    }

    static func permission(_ badge: PermissionBadge) -> ChipSpec {
        ChipSpec(id: "permission", symbol: badge.symbolName, title: badge.label,
                 tint: badge.severity.tint, isLoud: badge.severity != .normal)
    }
}

// ------------------------------------------------------ layout, in SwiftUI

extension OverviewLayout {
    /// Which way the fleet scrolls. The mapping is here rather than in
    /// `DeckCore` because `Axis` is SwiftUI's; the *decision* — that a row
    /// enumerates sideways and everything else downward — is the core's, and
    /// this only spells it in the framework's vocabulary.
    var scrollAxis: Axis.Set {
        switch self {
        case .row: .horizontal
        case .grid, .column: .vertical
        }
    }
}

// ----------------------------------------------------- the badge's glyph

extension PermissionBadge {
    /// A glyph as well as a colour. This is the field on the deck where
    /// colour-only encoding costs the most: a colour-blind user reading a
    /// bypassing session as an ordinary one is the exact failure the badge
    /// exists to prevent.
    var symbolName: String {
        switch severity {
        case .alarm: "exclamationmark.shield.fill"
        case .caution: "shield.lefthalf.filled"
        case .normal: "shield"
        }
    }
}

// -------------------------------------------------- identity, in pixels

extension CardColor {
    /// The pixels for a slot's name: the ONE place a palette name becomes a
    /// Color. DeckApp paints what DeckCore names (see `Signal.swift`,
    /// `CardColor.swift`).
    ///
    /// **In palette order, and MUST stay congruent with
    /// `CardColor.paletteNames`**: same length, position and word (index 4 is
    /// "teal" there and `.teal` here).
    /// `CardIdentityAppearanceTests.identityAndMeaningAreSeparateChannels`
    /// (`PresentationTests.swift`) and `SessionCardTests.theIdentityBarIsAlwaysOn`
    /// pin this array against a literal table, so a palette that grows in one
    /// file and not the other fails a test.
    private static let paletteTints: [Color] = [
        .orange, .yellow, .green, .mint, .teal,
        .cyan, .blue, .indigo, .purple, .pink, .brown,
    ]

    var tint: Color {
        switch self {
        case .slot(let index):
            // Folded exactly the way `spokenName` folds `index` — modulo,
            // positive first, since Swift's `%` keeps the sign of its left
            // operand — so a name and its pixels can never disagree about
            // which palette entry a wild stored index lands on.
            let count = Self.paletteCount
            let clamped = ((index % count) + count) % count
            return Self.paletteTints[clamped]
        case .custom(let red, let green, let blue):
            // A user-chosen CONSTANT, not a system colour: the person
            // picked these exact pixels, and honouring that choice means
            // drawing exactly them, unadapted to anybody's appearance.
            // System-adaptive shading is the PALETTE's own job, above — a
            // custom pick answers to nobody's screen but the one it was
            // made for.
            return Color(.sRGB, red: red, green: green, blue: blue, opacity: 1)
        }
    }
}
