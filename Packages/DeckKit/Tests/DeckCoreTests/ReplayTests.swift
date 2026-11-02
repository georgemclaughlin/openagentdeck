//
//  ReplayTests.swift · Tests/DeckCoreTests
//
//  Cases P1.7–P1.17. The recorded hook stream driven through the reducer at
//  virtual time, asserting on the frame sequence — L2 as 04-TEST-LEVELS defines
//  it, and the level that carries most of this product's behaviour.
//

import Testing
import DeckCore

struct ReplayTests {

    // MARK: reducer

    /// The wire gives no ordering guarantee (SG5), so the
    /// reducer must not depend on one. Fixed permutations rather than a random
    /// shuffle: a test whose input changes per run cannot be re-run against a
    /// failure.
    @Test("a permuted event stream yields the identical final state")
    func permutationInvariant() {
        let events = Corpus.hookEvents()
        #expect(events.count == 153)
        let straight = Reducer.run(events)

        for permutation in [Array(events.reversed()),
                            Array(events.dropFirst(37)) + Array(events.prefix(37)),
                            events.enumerated().sorted { ($0.offset % 7, $0.offset) < ($1.offset % 7, $1.offset) }.map(\.element)] {
            #expect(Reducer.run(permutation) == straight)
        }
    }

    /// **The permutation invariant, across the hook/fleet boundary.**
    /// `permutationInvariant` above pins order-independence within one wire
    /// feed (153 recorded hooks); `isWire` promises the same thing between
    /// feeds — `.hook` and `.fleet` are both wire events (SG5 gives no
    /// ordering guarantee for either) — and this is the small constructed
    /// case that pins the promise there instead of assuming it.
    ///
    /// **The genuinely divergent pair:** a Notification `permission_prompt`
    /// (raises a HOLDLESS needs-you lane — this hook kind opens no hold) and
    /// an idle fleet poll (the row now qualified to correct that residue).
    /// Under the rule this reducer change replaced — a needs-you lane fully
    /// immune to every poll, hold open or not — this pair diverged:
    /// `[permission_prompt, fleet]` left the lane at `.needsYou` forever
    /// (the poll could never touch it), while `[fleet, permission_prompt]`
    /// let the fleet row plant `.idle` BEFORE the notification arrived, and
    /// the notification then lost arbitration to that already-later
    /// timestamp — two orderings of the same two events, two different
    /// answers.
    ///
    /// **Regression breadth:** the triple adds a Notification `idle_prompt`
    /// (the engine's own, independent way of saying the same turn ended).
    /// Under the current rule, every ordering of all three converges, because
    /// the idle_prompt's own timestamp is the latest and its transition is
    /// unconditional, so it always wins arbitration last, however the pair
    /// lands in between.
    ///
    /// **Scope — what this does NOT cover.** A hold-OPENING
    /// `permissionRequest` interleaved with polls is genuinely
    /// order-dependent: whether a poll may move the lane depends on whether
    /// the hold it is racing happens to exist yet at the moment the poll is
    /// applied, and that is a real, unclosed gap — not one this case
    /// silently claims to close. Nor does it touch `.decision` or
    /// `.holdExpired`: those are not wire events, and `isWire`'s own
    /// doctrine — "order IS the history" — exempts them from this promise
    /// entirely.
    @Test("a Notification permission_prompt, an idle fleet poll, and a Notification idle_prompt converge under every ordering")
    func fleetAndHookPermutationsConverge() {
        let session = SessionID("converge")
        func notify(_ ms: Int64, _ type: String) -> DeckEvent {
            .hook(HookEvent(id: EventID("notif-\(type)"), at: Instant(sinceStart: Millis(ms)),
                            kind: .notification, session: session, cwd: nil, tool: nil,
                            toolUseID: nil, held: .absent, notificationType: type))
        }
        let permissionPrompt = notify(100, "permission_prompt")
        let idleFleetPoll = DeckEvent.fleet(
            [FleetRow(session: session, name: "converge", kind: "interactive",
                      state: .absent, status: .value("idle"))],
            at: Instant(sinceStart: Millis(200)), id: EventID("fleet-idle"))
        let idlePrompt = notify(300, "idle_prompt")

        let orderings: [[DeckEvent]] = [
            [permissionPrompt, idleFleetPoll, idlePrompt],
            [permissionPrompt, idlePrompt, idleFleetPoll],
            [idleFleetPoll, permissionPrompt, idlePrompt],
            [idleFleetPoll, idlePrompt, permissionPrompt],
            [idlePrompt, permissionPrompt, idleFleetPoll],
            [idlePrompt, idleFleetPoll, permissionPrompt],
        ]
        let results = orderings.map { Reducer.run($0) }
        #expect(results.allSatisfy { $0 == results[0] },
                "the same three events converged to different states depending on arrival order")
        #expect(results[0].lanes[session]?.state == .idle,
                "the converged state was not the one every ordering should reach")

        // The genuinely divergent pair: permission_prompt and idle fleet poll.
        // Under the old rule, these two orderings diverged; under the current rule,
        // both orderings converge to the same final lane state.
        let pairOrderings: [[DeckEvent]] = [
            [permissionPrompt, idleFleetPoll],
            [idleFleetPoll, permissionPrompt],
        ]
        let pairResults = pairOrderings.map { Reducer.run($0) }
        #expect(pairResults.allSatisfy { $0 == pairResults[0] },
                "the permission_prompt and idle fleet poll converged to different states depending on arrival order")
        #expect(pairResults[0].lanes[session]?.state == .idle,
                "the pair did not converge to the idle state")
    }

    /// 'S other half. Idempotent per event id.
    @Test("delivering every event twice changes nothing")
    func idempotent() {
        let events = Corpus.hookEvents()
        let once = Reducer.run(events)
        let twice = Reducer.run(events + events)
        let interleaved = Reducer.run(events.flatMap { [$0, $0] })
        #expect(twice == once)
        #expect(interleaved == once)
    }

    /// At the reducer. An unrecognised kind holds prior state.
    @Test("an unrecognised hook holds the lane's prior state")
    func unrecognisedHoldsPriorState() {
        let session = SessionID("s1")
        // `notificationType` defaults to nil rather than a real value: an
        // absent one holds prior state exactly as `.unrecognised` does (see
        // `notificationTypeGatesLaneState`), so this helper is handed
        // `permission_prompt` explicitly to reach needs-you at all — the
        // fixture the REST of this case needs, not the case in its own right.
        func hook(_ kind: HookKind, _ ms: Int64, held: Fed<Int> = .absent,
                  notificationType: String? = nil) -> DeckEvent {
            .hook(HookEvent(id: EventID("\(kind)-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                            kind: kind, session: session, cwd: nil, tool: nil,
                            toolUseID: nil, held: held, notificationType: notificationType))
        }
        let before = Reducer.run([hook(.sessionStart, 0),
                                  hook(.notification, 10, notificationType: "permission_prompt")])
        #expect(before.lanes[session]?.state == .needsYou)

        let after = Reducer.run([hook(.sessionStart, 0),
                                 hook(.notification, 10, notificationType: "permission_prompt"),
                                 hook(.unrecognised("PreCompact"), 20),
                                 hook(.unrecognised("SomethingNewIn2027"), 30)])
        #expect(after.lanes[session]?.state == .needsYou)
        // Provenance is held too: nothing about the displayed state came from
        // the unrecognised event, so nothing should claim it did.
        #expect(after.lanes[session]?.stateSource == before.lanes[session]?.stateSource)
    }

    /// **The change.** `notification_type` decides a `Notification`'s lane,
    /// not the hook kind — only `idle_prompt` and `permission_prompt` move
    /// anything, and an unrecognised type, or none at all, holds the prior
    /// state exactly as an `.unrecognised` HOOK KIND does above. Before this,
    /// `idle_prompt` — "Claude finished, waiting for the next prompt" — read
    /// as needs-you on every ordinary turn end, because nothing decoded the
    /// field that says otherwise.
    @Test("a notification's type decides the lane, and an unknown one holds prior state")
    func notificationTypeGatesLaneState() {
        let session = SessionID("s1")
        func start(_ ms: Int64) -> DeckEvent {
            .hook(HookEvent(id: EventID("start-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                            kind: .sessionStart, session: session, cwd: nil, tool: nil,
                            toolUseID: nil, held: .absent))
        }
        func notify(_ ms: Int64, notificationType: String?) -> DeckEvent {
            .hook(HookEvent(id: EventID("notif-\(ms)"), at: Instant(sinceStart: Millis(ms)),
                            kind: .notification, session: session, cwd: nil, tool: nil,
                            toolUseID: nil, held: .absent, notificationType: notificationType))
        }

        // idle_prompt: the wire's own definition of idle.
        let idled = Reducer.run([start(0), notify(10, notificationType: "idle_prompt")])
        #expect(idled.lanes[session]?.state == .idle)

        // permission_prompt: the one value that really means needs-you.
        let asked = Reducer.run([start(0), notify(10, notificationType: "permission_prompt")])
        #expect(asked.lanes[session]?.state == .needsYou)

        // An unrecognised type holds prior state — the same doctrine an
        // unrecognised HOOK KIND gets, one field down. Started from `working`
        // rather than `idle` so a bug that silently mapped it to `.idle`
        // (the OLD default for "not needs-you") could not hide behind a
        // state the lane was already in.
        let workingFirst: [DeckEvent] = [start(0),
            .hook(HookEvent(id: EventID("prompt"), at: Instant(sinceStart: Millis(5)),
                            kind: .userPromptSubmit, session: session, cwd: nil,
                            tool: nil, toolUseID: nil, held: .absent))]
        let base = Reducer.run(workingFirst)
        #expect(base.lanes[session]?.state == .working, "the fixture never reached working")

        let unknown = Reducer.run(workingFirst + [notify(10, notificationType: "auth_success")])
        #expect(unknown.lanes[session]?.state == .working,
                "an unrecognised notification_type moved the lane")
        #expect(unknown.lanes[session]?.stateSource == base.lanes[session]?.stateSource,
                "an unrecognised notification_type claimed provenance it does not have")

        // And absence — the value never arriving at all — holds it too.
        let absent = Reducer.run(workingFirst + [notify(10, notificationType: nil)])
        #expect(absent.lanes[session]?.state == .working,
                "a notification with no type moved the lane")
        #expect(absent.lanes[session]?.stateSource == base.lanes[session]?.stateSource,
                "a typeless notification claimed provenance it does not have")
    }

    // MARK: frames

    /// No lane exists that the corpus does not name.
    @Test("every lane in every frame traces to a session the corpus records")
    func noLaneWithoutRecord() {
        let recorded = Corpus.recordedSessions()
        let (state, frames) = Replay.run(Corpus.hookEvents())
        #expect(!recorded.isEmpty)

        for lane in state.lanes.keys {
            #expect(recorded.contains(lane), "lane \(lane) is in no recorded payload")
        }
        for frame in frames {
            for lane in frame.lanes {
                #expect(recorded.contains(lane.session), "frame lane \(lane.session) was invented")
            }
        }
    }

    /// Session-start order, never reordered by state.
    @Test("lane order is session-start order and never changes between frames")
    func laneOrderIsSessionStartOrder() {
        let (_, frames) = Replay.run(Corpus.hookEvents())
        #expect(frames.count > 1)

        // A lane may appear, but the lanes already present keep their relative
        // order in every subsequent frame. That is the falsifier verbatim: "two
        // consecutive frames with a reordering not preceded by a pin action".
        for (previous, next) in zip(frames, frames.dropFirst()) {
            let before = previous.lanes.map(\.session)
            let after = next.lanes.map(\.session)
            let survivors = after.filter(before.contains)
            #expect(survivors == before.filter(after.contains),
                    "lanes reordered between frames")
        }

        // And the order is by first-seen time, not by state or activity.
        let (state, _) = Replay.run(Corpus.hookEvents())
        let firstSeen = state.order.compactMap { state.lanes[$0]?.firstSeenAt }
        #expect(firstSeen == firstSeen.sorted())
    }

    // MARK: manual order (prefs.cardOrder)
    //
    // `Projection.manualOrder`'s own doc comment states the three-rule
    // merge; these pin it through the full projection, the same way
    // `laneOrderIsSessionStartOrder` just above pins session-start order
    // itself. Small, hand-built states rather than the corpus — the corpus
    // carries no `cardOrder` prefs to key against, and these cases need
    // precise control over which surface hosts which session and when.

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// A `SessionStart` carrying a host — enough to give the lane a SURFACE
    /// for `cardOrder` to key on. Mirrors `HostIdentityTests.hostedStart`.
    private func hostedStart(_ session: String, surface: String, ms: Int64) -> DeckEvent {
        .hook(HookEvent(id: EventID("start-\(session)-\(ms)"), at: at(ms), kind: .sessionStart,
                        session: SessionID(session), cwd: nil, tool: nil, toolUseID: nil,
                        held: .absent, host: HostAddress(workspace: "WS", surface: surface)))
    }

    /// A `SessionStart` with no host at all — a lane `cardOrder` has no
    /// surface to key on, the same shape `HostIdentityTests.bareStart` uses.
    private func bareStart(_ session: String, ms: Int64) -> DeckEvent {
        .hook(HookEvent(id: EventID("bare-\(session)-\(ms)"), at: at(ms), kind: .sessionStart,
                        session: SessionID(session), cwd: nil, tool: nil, toolUseID: nil, held: .absent))
    }

    @Test("prefs cardOrder sorts stored surfaces first, in stored order")
    func manualOrderSortsStoredSurfacesFirst() {
        var state = DeckState()
        Reducer.reduce(&state, hostedStart("a", surface: "surf-A", ms: 10))
        Reducer.reduce(&state, hostedStart("b", surface: "surf-B", ms: 20))
        Reducer.reduce(&state, hostedStart("c", surface: "surf-C", ms: 30))
        // Session-start order today would be a, b, c — cardOrder reverses it.
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(cardOrder: ["surf-C", "surf-A", "surf-B"]), at: at(40)))

        let frame = Projection.frame(from: state, at: at(50))
        #expect(frame.lanes.map(\.session.raw) == ["c", "a", "b"])
    }

    /// **"Reordering works only the first time, after that I can't reorder
    /// anymore" — the whole bug, end to end.**
    ///
    /// The host names one pane two ways and `LaneRecord.host` is re-fed by
    /// every payload, so which name a lane holds is only ever "whoever spoke
    /// last": `DeckRuntime.locate` resolves a pid through `cmux tree` and
    /// stores a SHORT REF (`surface:13`), while the lane's own hooks report
    /// the UUID pair cmux exports as `CMUX_SURFACE_ID`. The router already
    /// pays for this (`HostSession.identifies(_:)` exists because comparing
    /// the two with `==` matched nothing, ever); ordering was still
    /// comparing them with `==`, through `manualOrder`'s `rank` lookup.
    ///
    /// So the user arranged a fleet stored in short refs, and the first hook
    /// each lane sent re-spelled it out of `rank` and dropped it to the
    /// untouched tail — the arrangement coming apart one card at a time,
    /// and a re-drag only writing another spelling that would flip in turn.
    /// The live prefs on the machine this was diagnosed from carried the
    /// fingerprint exactly: thirteen `cardOrder` entries, six UUIDs and
    /// seven short refs.
    @Test("a lane the host RE-SPELLS keeps the place the user dragged it to — the order follows the pane, not the host's current word for it")
    func manualOrderFollowsASurfaceRename() {
        var state = DeckState()
        Reducer.reduce(&state, hostedStart("a", surface: "surface:12", ms: 10))
        Reducer.reduce(&state, hostedStart("b", surface: "surface:37", ms: 20))
        Reducer.reduce(&state, hostedStart("c", surface: "surface:13", ms: 30))
        // The user drags c to the front and the drop writes the order.
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(cardOrder: ["surface:13", "surface:12", "surface:37"]), at: at(40)))
        #expect(Projection.frame(from: state, at: at(45)).lanes.map(\.session.raw) == ["c", "a", "b"])

        // c's next hook reports the same pane the way its own environment
        // spells it — the UUID, not the short ref the inventory answered in.
        let asTheHookSpellsIt = "7BB88BAA-6151-4BED-950D-81A33DFA27C6"
        Reducer.reduce(&state, hostedStart("c", surface: asTheHookSpellsIt, ms: 50))

        #expect(state.lanes[SessionID("c")]?.host?.value.surface == asTheHookSpellsIt,
                "the hook did not re-feed the host at all — this test is no longer about anything")
        #expect(state.prefs.cardOrder == [asTheHookSpellsIt, "surface:12", "surface:37"],
                "the stored order still names the pane by a spelling its host has abandoned")
        #expect(Projection.frame(from: state, at: at(60)).lanes.map(\.session.raw) == ["c", "a", "b"],
                "the card the user dragged to the front fell back to session-start order on a re-spelling")
    }

    @Test("a re-spelling onto a name the order already carries keeps one entry, at the renamed card's own place")
    func manualOrderRenameOntoAnExistingNameDeduplicates() {
        var state = DeckState()
        Reducer.reduce(&state, hostedStart("a", surface: "surface:12", ms: 10))
        Reducer.reduce(&state, hostedStart("b", surface: "surface:37", ms: 20))
        // "surface:37" already sits later in the stored order; renaming a's
        // pane onto it must not leave the list naming one surface twice —
        // the invariant `DeckPrefs.decode`'s own entry-wise dedupe keeps.
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(cardOrder: ["surface:12", "surface:37"]), at: at(30)))
        Reducer.reduce(&state, hostedStart("a", surface: "surface:37", ms: 40))

        #expect(state.prefs.cardOrder == ["surface:37"])
    }

    @Test("re-spelling one of two sessions sharing a pane strands neither — both names rank adjacently")
    func manualOrderRenameKeepsASharedSurfaceReachable() {
        var state = DeckState()
        // Two sessions in ONE pane — `manualOrder`'s own rule 1 case.
        Reducer.reduce(&state, hostedStart("old", surface: "surface:12", ms: 10))
        Reducer.reduce(&state, hostedStart("new", surface: "surface:12", ms: 20))
        Reducer.reduce(&state, hostedStart("other", surface: "surface:37", ms: 30))
        Reducer.reduce(&state, .prefsChanged(
            DeckPrefs(cardOrder: ["surface:12", "surface:37"]), at: at(40)))

        // Only ONE of the two re-spells; the other still answers to the ref.
        Reducer.reduce(&state, hostedStart("new", surface: "UUID-FOR-PANE-12", ms: 50))

        #expect(state.prefs.cardOrder == ["UUID-FOR-PANE-12", "surface:12", "surface:37"],
                "the shared pane lost one of its two names")
        // Both pane-12 sessions still lead, and "other" still trails.
        #expect(Projection.frame(from: state, at: at(60)).lanes.map(\.session.raw)
                == ["new", "old", "other"])
    }

    @Test("a lane whose surface never changes leaves the stored order untouched")
    func manualOrderRenameIsANoOpWithoutARename() {
        var state = DeckState()
        Reducer.reduce(&state, hostedStart("a", surface: "surface:12", ms: 10))
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(cardOrder: ["surface:12"]), at: at(20)))
        Reducer.reduce(&state, hostedStart("a", surface: "surface:12", ms: 30))
        // And a lane the order does not name at all is not added by one.
        Reducer.reduce(&state, hostedStart("b", surface: "surface:99", ms: 40))
        Reducer.reduce(&state, hostedStart("b", surface: "surface:100", ms: 50))

        #expect(state.prefs.cardOrder == ["surface:12"])
    }

    @Test("a lane with no host, or a surface cardOrder does not name, appends after every stored lane, in session-start order")
    func manualOrderAppendsUnknownAndHostlessLanesAfterStoredOnes() {
        var state = DeckState()
        Reducer.reduce(&state, hostedStart("known", surface: "surf-known", ms: 10))
        Reducer.reduce(&state, bareStart("noHost", ms: 20))
        Reducer.reduce(&state, hostedStart("unknownSurface", surface: "surf-unlisted", ms: 30))
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(cardOrder: ["surf-known"]), at: at(40)))

        let frame = Projection.frame(from: state, at: at(50))
        // "known" is the only stored surface, so it leads; "noHost" and
        // "unknownSurface" tie for last and keep their session-start
        // relative order (noHost started at 20, before unknownSurface at 30).
        #expect(frame.lanes.map(\.session.raw) == ["known", "noHost", "unknownSurface"])
    }

    @Test("two sessions sharing one stored surface tie on it and keep their session-start relative order")
    func manualOrderTiesOnASharedSurfaceKeepSessionStartOrder() {
        var state = DeckState()
        // Both sessions host on the SAME surface — a relaunch mid-frame, or
        // `/exit` and a fresh session in the same tab before the old one's
        // lane has retired.
        Reducer.reduce(&state, hostedStart("first", surface: "surf-shared", ms: 10))
        Reducer.reduce(&state, hostedStart("second", surface: "surf-shared", ms: 20))
        Reducer.reduce(&state, hostedStart("other", surface: "surf-other", ms: 30))
        Reducer.reduce(&state, .prefsChanged(DeckPrefs(cardOrder: ["surf-other", "surf-shared"]), at: at(40)))

        let frame = Projection.frame(from: state, at: at(50))
        // "surf-other" ranks first; the two "surf-shared" sessions tie for
        // second and keep session-start order (first, then second).
        #expect(frame.lanes.map(\.session.raw) == ["other", "first", "second"])
    }

    /// The no-prefs path is byte-for-byte the old behavior — an empty
    /// `cardOrder` must never so much as touch the order a fresh install
    /// already produced.
    @Test("an empty cardOrder reproduces today's session-start order exactly")
    func manualOrderWithEmptyCardOrderIsByteForByteTheOldOrder() {
        let (state, _) = Replay.run(Corpus.hookEvents())
        let withoutPrefs = Projection.frame(from: state, at: at(9_999_999))

        var withEmptyCardOrder = state
        Reducer.reduce(&withEmptyCardOrder, .prefsChanged(DeckPrefs(cardOrder: []), at: at(9_999_998)))
        let withPrefs = Projection.frame(from: withEmptyCardOrder, at: at(9_999_999))

        #expect(withPrefs.lanes.map(\.session) == withoutPrefs.lanes.map(\.session))
    }

    /// The merge happens BEFORE the visible/hidden split (`Frame.init`'s own
    /// one-pass partition) — hidden lanes still take part in it, and each
    /// side of the partition keeps its own relative order afterward.
    @Test("the manual order applies before the hidden/visible split — hidden lanes still merge, relative order preserved on both sides")
    func manualOrderAppliesBeforeTheHiddenSplit() {
        var state = DeckState()
        Reducer.reduce(&state, hostedStart("a", surface: "surf-A", ms: 10))
        Reducer.reduce(&state, hostedStart("b", surface: "surf-B", ms: 20))
        Reducer.reduce(&state, hostedStart("c", surface: "surf-C", ms: 30))
        Reducer.reduce(&state, hostedStart("d", surface: "surf-D", ms: 40))
        var prefs = DeckPrefs(cardOrder: ["surf-D", "surf-B", "surf-C", "surf-A"])
        prefs.hidden = ["surf-B", "surf-D"]
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(50)))

        let frame = Projection.frame(from: state, at: at(60))
        // Manual order first: d, b, c, a. Partitioned by hidden (b, d
        // hidden) without disturbing relative order on either side.
        #expect(frame.visibleLanes.map(\.session.raw) == ["c", "a"])
        #expect(frame.hidden.map(\.session.raw) == ["d", "b"])
    }

    /// Conservation: the mast counts every waiter.
    @Test("the mast counter equals the number of needs-you lanes, in every frame")
    func mastEqualsNeedsYouCount() {
        let (_, frames) = Replay.run(Corpus.hookEvents())
        var sawAWaiter = false
        for frame in frames {
            let waiting = frame.lanes.filter { $0.state == .needsYou }.count
            #expect(frame.mastNeedsYou == waiting)
            if waiting > 0 { sawAWaiter = true }
        }
        // A conservation law checked only over frames with nothing to conserve
        // is the `all([])` defect wearing a different hat.
        #expect(sawAWaiter, "no frame in the replay had a waiting lane — the test proved nothing")
    }

    /// At most one takeover expanded.
    @Test("at most one lane is expanded in any frame")
    func atMostOneExpanded() {
        let (_, frames) = Replay.run(Corpus.hookEvents())
        for frame in frames { #expect(frame.expandedCount <= 1) }
        #expect(frames.contains { $0.expandedCount == 1 },
                "no frame ever expanded a lane — the bound was never approached")
    }

    /// Every rendered value names an event that was received.
    @Test("every frame value cites a source event that exists in the log")
    func everyValueHasProvenance() {
        let events = Corpus.hookEvents()
        var received = Set<EventID>()
        for case .hook(let h) in events { received.insert(h.id) }

        let (_, frames) = Replay.run(events)
        for frame in frames {
            #expect(frame.unprovenancedFields.isEmpty,
                    "value with no provenance: \(frame.unprovenancedFields)")
            for lane in frame.lanes {
                for (field, source) in lane.sources {
                    #expect(received.contains(source),
                            "\(lane.session).\(field) cites \(source), which was never received")
                }
            }
        }
    }

    /// An absent feed is an empty slot, never `0%`.
    @Test("a session with no statusline renders an empty context slot")
    func missingStatuslineRendersEmpty() {
        let hooks = Corpus.hookEvents()
        let (_, hookOnlyFrames) = Replay.run(hooks)
        for lane in hookOnlyFrames.last!.lanes {
            #expect(lane.contextPercent == nil, "\(lane.session) showed a percentage nobody sent")
        }

        // And a feed that arrived with `used_percentage: null` says NOTHING —
        // the empty-slot rule's second clause is narrowed. The corpus
        // proves the shape occurs (12 of its 54 lines carry it, opening every
        // session), and under the old letter each of those lines wiped the
        // gauge. A null neither fabricates a number nor erases one: the
        // last-known value stays, its provenance stays, and its staleness
        // clock keeps running from the event that actually supplied it.
        let feed = Corpus.statusline.compactMap { StatuslineIngest.payload(from: $0) }
        let nulls = feed.filter { $0.contextPercent == .unset }
        #expect(!nulls.isEmpty)
        guard let valued = feed.first(where: { $0.contextPercent.isPresent }) else {
            Issue.record("the feed carries no value at all — the test proves nothing"); return
        }
        let cleared = StatuslinePayload(session: valued.session, contextPercent: .unset,
                                        costUSD: valued.costUSD, model: valued.model,
                                        version: valued.version)
        let hook = hooks.first!
        let atValue = Instant(sinceStart: Millis(1_000_000))
        let atNull = Instant(sinceStart: Millis(1_000_001))

        let shown = Replay.run([hook, .statusline(valued, at: atValue, id: EventID("sl-1"))]).state
        #expect(shown.lanes[valued.session]?.contextPercent.value != nil,
                "a fed value did not render — the keeping assertion below would be vacuous")

        let kept = Replay.run([hook,
                               .statusline(valued, at: atValue, id: EventID("sl-1")),
                               .statusline(cleared, at: atNull, id: EventID("sl-2"))]).state
        #expect(kept.lanes[valued.session]?.contextPercent == valued.contextPercent)
        #expect(kept.lanes[valued.session]?.contextSource == EventID("sl-1"))
        // The clock did NOT restart at the null: staleness measures from the
        // value's own event, or a chatty-but-null feed would keep a dead
        // reading looking fresh forever.
        #expect(kept.lanes[valued.session]?.contextDecidedAt == atValue)
    }

    /// One frame per event, and the last frame reflects every event.
    @Test("the replay is deterministic and complete")
    func replayIsDeterministic() {
        let events = Corpus.hookEvents()
        let first = Replay.run(events)
        let second = Replay.run(events)

        #expect(first.frames == second.frames)
        #expect(first.state == second.state)
        #expect(first.frames.count == events.count)
        #expect(first.frames.last?.lanes.count == first.state.lanes.count)
        #expect(first.frames.first?.lanes.count == 1)
    }

    /// The corpus's own dimensions, anchored.
    @Test("the replay produces one lane per recorded session")
    func laneCountMatchesCorpus() {
        let (state, _) = Replay.run(Corpus.hookEvents())
        // 30, not 31: five recorded rows carry no `session_id` at all — the
        // `unknown` events whose payload is `{raw: …}` — and the
        // no-synthesised-lane rule forbids inventing a lane for them. The
        // plan's first draft said 31 because it counted the null as a
        // session; the test found it.
        #expect(state.lanes.count == 30)
        #expect(state.order.count == 30)
        #expect(Set(state.order).count == 30)
    }
}
