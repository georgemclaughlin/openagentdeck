//
//  HostIdentityTests.swift · Tests/DeckCoreTests
//
//  The session tells the deck where it lives, and the deck
//  carries it like any other fed value.
//
//  The first case here is a repair. The deck's installed hook command was
//  `curl -s -X POST http://…/hook` — no `--data-binary @-` — so it posted an
//  EMPTY BODY and every session installed through the deck's own installer was
//  invisible to it. It survived because no scenario ever called
//  `SettingsMerge.install`: every live capture wrote its own hook script, so
//  the evidence pipeline exercised everything except the path a real user
//  takes. That is the gap this file closes first.
//

import Testing
@testable import DeckCore

struct HostIdentityTests {

    private func at(_ ms: Int64) -> Instant { Instant(sinceStart: Millis(ms)) }

    /// A `SessionStart` carrying a host directly — the simplest event that
    /// creates a lane and resolves its address in the same reduce.
    /// `cwd` defaults to nil so every EXISTING call site (host/address
    /// tests that have nothing to do with colour) keeps reading exactly as
    /// it did; the card-colour section below is what actually supplies one,
    /// since colour assignment fires off the DIRECTORY now, not the host.
    private func hostedStart(_ session: String, surface: String, ms: Int64 = 10,
                             cwd: String? = nil) -> HookEvent {
        HookEvent(id: EventID("start-\(session)-\(ms)"), at: at(ms), kind: .sessionStart,
                 session: SessionID(session), cwd: cwd.map(Redacted.init), tool: nil, toolUseID: nil,
                 held: .absent, host: HostAddress(workspace: "WS", surface: surface))
    }

    /// A `SessionStart` with no host at all — a lane the deck can watch but
    /// has no surface to key `HostAddress` on. `cwd` defaults to nil for the
    /// same reason `hostedStart`'s does.
    private func bareStart(_ session: String, ms: Int64 = 10, cwd: String? = nil) -> HookEvent {
        HookEvent(id: EventID("bare-\(session)-\(ms)"), at: at(ms), kind: .sessionStart,
                 session: SessionID(session), cwd: cwd.map(Redacted.init), tool: nil, toolUseID: nil,
                 held: .absent)
    }

    /// The installed command actually carries the payload.
    @Test("the installed hook command posts the payload it was given")
    func hookCommandCarriesThePayload() {
        let diff = SettingsMerge.install(into: .object([:]), port: 8765)
        let text = "\(diff)"

        // `--data-binary @-` is what makes curl read stdin. Without it the
        // deck receives `{}`, finds no session_id, and drops the event.
        #expect(text.contains("--data-binary @-"),
                "the installed hook does not post its stdin — every session would be invisible")
        #expect(text.contains("127.0.0.1:8765/hook"))

        // And it reports the host, from the environment its parent gave it.
        #expect(text.contains("surface=${CMUX_SURFACE_ID:-}"),
                "the installed hook does not report its surface")
        #expect(text.contains("workspace=${CMUX_WORKSPACE_ID:-}"))

        // **And the variables can actually expand.** The two assertions above were
        // both true while the URL was wrapped in SINGLE quotes, which suppress
        // `${...}` — so the deck received the literal text `$CMUX_SURFACE_ID:-` as
        // the surface, every session was unroutable, and the panel reported "the
        // deck has no route to this session" for a reason that was its own doing.
        // A substring check on a shell command is not a check on what the shell
        // does with it. H17.9 in the app target runs the thing.
        #expect(!text.contains("'http://"),
                "the URL is single-quoted, so ${CMUX_SURFACE_ID} can never expand")
        #expect(text.contains("\"http://"),
                "the URL is not double-quoted — the & would reach the shell unprotected")
    }

    /// An address needs both halves. Half an address addresses no one,
    /// and a lane claiming reachability it does not have is worse than a lane
    /// admitting it.
    @Test("an address exists only when both halves arrived")
    func bothHalvesOrNothing() {
        // Through `String?`, deliberately: a bare literal is non-optional and
        // resolves to the memberwise init, so testing with literals would test
        // the wrong overload — which is exactly what the first version of this
        // case did. The wire path only ever has optionals (`stringValue`), so
        // this is also the shape that actually occurs.
        func address(_ workspace: String?, _ surface: String?) -> HostAddress? {
            HostAddress(workspace: workspace, surface: surface)
        }
        #expect(address("w", "s") != nil)
        #expect(address("w", nil) == nil)
        #expect(address(nil, "s") == nil)
        #expect(address("", "s") == nil, "an empty half is not an address")
        #expect(address("w", "") == nil)
    }

    /// The identity survives the whole path: wire row → ingest → lane
    /// → frame, with provenance, and absent stays absent.
    @Test("the host address travels from the wire to the frame, with provenance")
    func identityReachesTheFrame() {
        func row(_ session: String, surface: String?, workspace: String?) -> JSONValue {
            var fields: [String: JSONValue] = [
                "ts": .string("2026-07-29T10:00:00.000Z"),
                "payload": .object([
                    "session_id": .string(session),
                    "hook_event_name": .string("UserPromptSubmit"),
                    "cwd": .string("/w"),
                ]),
            ]
            if let surface { fields["surface"] = .string(surface) }
            if let workspace { fields["workspace"] = .string(workspace) }
            return .object(fields)
        }

        // A cmux-hosted session: the UUIDs the hook actually reported in
        // fixtures/live/LV30-multitab.
        let hosted = HookIngest.event(
            from: row("s1", surface: "D8538236-0000-0000-0000-000000000001",
                      workspace: "BFC288A8-0000-0000-0000-000000000002"),
            epochBase: 0)
        #expect(hosted?.host?.surface == "D8538236-0000-0000-0000-000000000001")
        #expect(hosted?.host?.workspace == "BFC288A8-0000-0000-0000-000000000002")

        // A session somewhere with no such notion: absent, not empty.
        let bare = HookIngest.event(from: row("s2", surface: nil, workspace: nil), epochBase: 0)
        #expect(bare?.host == nil)

        var state = DeckState()
        Reducer.reduce(&state, .hook(hosted!))
        Reducer.reduce(&state, .hook(bare!))
        let frame = Projection.frame(from: state, at: at(1_000))

        let hostedLane = frame.lanes.first { $0.session == SessionID("s1") }
        let bareLane = frame.lanes.first { $0.session == SessionID("s2") }
        #expect(hostedLane?.host?.surface == "D8538236-0000-0000-0000-000000000001")
        #expect(bareLane?.host == nil, "a lane invented an address nobody sent")

        // A value on screen names the event that supplied it.
        #expect(hostedLane?.sources["host"] != nil)
        #expect(bareLane?.sources["host"] == nil)
        #expect(frame.unprovenancedFields.isEmpty)
    }

    /// Two tabs of one workspace stay two lanes with two addresses.
    /// The shape that broke every earlier design: cmux's own `CMUX_TAB_ID`
    /// equals `CMUX_WORKSPACE_ID` in a two-tab workspace, so only the surface
    /// separates them.
    @Test("two sessions sharing a workspace keep distinct addresses")
    func twoTabsOneWorkspace() {
        let workspace = "BFC288A8-SHARED"
        func event(_ session: String, _ surface: String) -> HookEvent {
            HookIngest.event(from: .object([
                "ts": .string("2026-07-29T10:00:0\(session.suffix(1)).000Z"),
                "surface": .string(surface),
                "workspace": .string(workspace),
                "payload": .object([
                    "session_id": .string(session),
                    "hook_event_name": .string("SessionStart"),
                ]),
            ]), epochBase: 0)!
        }

        var state = DeckState()
        Reducer.reduce(&state, .hook(event("tab1", "SURFACE-ONE")))
        Reducer.reduce(&state, .hook(event("tab2", "SURFACE-TWO")))
        let lanes = Projection.frame(from: state, at: at(5_000)).lanes

        #expect(lanes.count == 2)
        let addresses = lanes.compactMap(\.host)
        #expect(Set(addresses).count == 2, "two tabs collapsed into one address")
        #expect(Set(addresses.map(\.workspace)).count == 1, "two tabs of one workspace should share it")
        #expect(Set(addresses.map(\.surface)).count == 2,
                "the surface is the only per-tab identity there is")
    }

    // -------------------------------------------------------------- card colour
    //
    // `CardColorTests` covers the type's own arithmetic in isolation; these
    // drive it through the actual path a live session takes — a hook or
    // fleet event, the reducer's assignment site (`recordCardColorIfNeeded`),
    // and the frame it projects. Colour is keyed on the DIRECTORY (`cwd`)
    // now, not the host surface — the user's own mental model is "same
    // project, same colour", and the directory is the fact that actually
    // names a project.

    /// A lane with no directory at all still gets a colour, derived from
    /// its own session id rather than a directory it does not have — the
    /// same hole `Frame.hidable`'s own doc names for Hide. Nothing is
    /// recorded for it: there is no directory to key a `directoryColors`
    /// entry on.
    @Test("a directory-less lane shows its stable fallback colour, and records nothing")
    func directorylessLaneShowsFallbackColor() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-bare", surface: "SURF-BARE")))

        let lane = Projection.frame(from: state, at: at(100)).lanes.first { $0.session == SessionID("s-bare") }
        let expected = CardColor.slot(CardColor.fallbackSlot(for: "s-bare"))
        #expect(lane?.color == expected)
        #expect(state.prefs.directoryColors.isEmpty,
                "a directory-less lane recorded a colour with no directory to key it on")
    }

    /// Before the directory resolves there is nothing to record; the instant
    /// it does, the reducer writes the assignment down
    /// (`recordCardColorIfNeeded`) and the very next projection reads it
    /// back rather than recomputing the fallback.
    @Test("a lane earns a recorded assignment the moment its directory resolves")
    func hostedLaneEarnsAnAssignmentAtFirstSight() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-earns", surface: "SURF-EARNS", ms: 10)))
        #expect(state.prefs.directoryColors.isEmpty, "an assignment was recorded before any directory existed")

        Reducer.reduce(&state, .hook(hostedStart("s-earns", surface: "SURF-EARNS", ms: 20, cwd: "/w/earns")))
        let expected = CardColor.slot(CardColor.fallbackSlot(for: "/w/earns"))
        #expect(state.prefs.directoryColors["/w/earns"] == expected,
                "no assignment was recorded the instant the directory resolved")

        let lane = Projection.frame(from: state, at: at(30)).lanes.first { $0.session == SessionID("s-earns") }
        #expect(lane?.color == expected)
    }

    /// A stored choice — whatever it is, deliberately NOT the fallback the
    /// reducer would have picked on its own — wins over the fallback at
    /// projection. Proves the frame reads `prefs.directoryColors` rather
    /// than recomputing a colour from the directory every time.
    @Test("a lane with a stored colour choice shows the choice, not the fallback")
    func hostedLaneShowsItsStoredChoice() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-chosen", surface: "SURF-CHOSEN", cwd: "/w/chosen")))

        let fallback = CardColor.fallbackSlot(for: "/w/chosen")
        let chosen = CardColor.slot((fallback + 1) % CardColor.paletteCount)
        var prefs = state.prefs
        prefs.directoryColors["/w/chosen"] = chosen
        Reducer.reduce(&state, .prefsChanged(prefs, at: at(50)))

        let lane = Projection.frame(from: state, at: at(100)).lanes.first { $0.session == SessionID("s-chosen") }
        #expect(lane?.color == chosen)
    }

    /// The whole point of recording at first sight rather than computing
    /// fresh every time: a second projection, with nothing having changed,
    /// reads back the identical colour rather than re-deriving one.
    @Test("an assignment sticks across a second projection — no churn")
    func assignmentSticksAcrossASecondProjection() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-sticky", surface: "SURF-STICKY", cwd: "/w/sticky")))

        let first = Projection.frame(from: state, at: at(100))
            .lanes.first { $0.session == SessionID("s-sticky") }?.color
        let second = Projection.frame(from: state, at: at(200))
            .lanes.first { $0.session == SessionID("s-sticky") }?.color
        #expect(first == second)
    }

    /// Two sessions in DIFFERENT directories, arriving with free slots
    /// available, land on different colours — `CardColor.assign`'s "lowest
    /// free slot" rule exercised through the reducer rather than called
    /// directly.
    @Test("two sessions in different directories arriving together get distinct colours")
    func twoSessionsArrivingGetDistinctColors() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-first", surface: "SURF-FIRST", ms: 10, cwd: "/w/first")))
        Reducer.reduce(&state, .hook(hostedStart("s-second", surface: "SURF-SECOND", ms: 20, cwd: "/w/second")))

        let first = state.prefs.directoryColors["/w/first"]
        let second = state.prefs.directoryColors["/w/second"]
        #expect(first != nil && second != nil)
        #expect(first != second, "two live directories landed on the same colour while free slots existed")
    }

    // -------------------------------------------------- same-directory sharing
    //
    // The feature's headline promise, driven end to end: two sessions open
    // on the SAME working directory read as one project and share one
    // colour, and the recording site is order-agnostic about which reducer
    // funnel first learns the directory — a hook event or a fleet row.

    /// Two sessions, same `cwd`, arriving as separate hook events: exactly
    /// ONE `directoryColors` entry gets written (the second session's
    /// arrival finds the directory already coloured and the guard declines
    /// to touch it again), and both lanes project the identical colour.
    @Test("two sessions sharing a directory earn exactly one directoryColors entry")
    func twoSessionsSameDirectoryShareOneEntry() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-a", surface: "SURF-A", ms: 10, cwd: "/w/shared")))
        Reducer.reduce(&state, .hook(hostedStart("s-b", surface: "SURF-B", ms: 20, cwd: "/w/shared")))

        #expect(state.prefs.directoryColors.count == 1,
                "two sessions in one directory recorded \(state.prefs.directoryColors.count) entries, not one")

        let frame = Projection.frame(from: state, at: at(30))
        let colorA = frame.lanes.first { $0.session == SessionID("s-a") }?.color
        let colorB = frame.lanes.first { $0.session == SessionID("s-b") }?.color
        #expect(colorA != nil && colorA == colorB, "two lanes in one directory projected different colours")
    }

    /// Three sessions across TWO directories: exactly two entries, and the
    /// two directories land on distinct slots.
    @Test("three sessions across two directories earn exactly two entries with distinct slots")
    func threeSessionsTwoDirectoriesEarnTwoEntries() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-a", surface: "SURF-A", ms: 10, cwd: "/w/proj1")))
        Reducer.reduce(&state, .hook(hostedStart("s-b", surface: "SURF-B", ms: 20, cwd: "/w/proj1")))
        Reducer.reduce(&state, .hook(hostedStart("s-c", surface: "SURF-C", ms: 30, cwd: "/w/proj2")))

        #expect(state.prefs.directoryColors.count == 2, Comment(rawValue:
                "three sessions across two directories recorded " +
                "\(state.prefs.directoryColors.count) entries, not two"))
        let proj1 = state.prefs.directoryColors["/w/proj1"]
        let proj2 = state.prefs.directoryColors["/w/proj2"]
        #expect(proj1 != nil && proj2 != nil)
        #expect(proj1 != proj2, "two distinct directories landed on the same slot")
    }

    /// The fleet row funnel can be the FIRST to learn a lane's directory —
    /// a session the poll discovers before any hook of its own ever fires
    /// (`apply(_:[FleetRow])`'s own `discovered` branch). Recording must
    /// fire from THAT funnel too, not only the hook one.
    @Test("a directory that first resolves through a fleet row still earns a recorded colour")
    func fleetRowFirstDiscoveryRecordsAColor() {
        let row = FleetRow(session: SessionID("s-fleet"), name: nil, kind: "background",
                           state: .value("working"), status: .absent, cwd: "/w/fleet-first")
        var state = DeckState()
        Reducer.reduce(&state, .fleet([row], at: at(10), id: EventID("f1")))

        let expected = CardColor.slot(CardColor.fallbackSlot(for: "/w/fleet-first"))
        #expect(state.prefs.directoryColors["/w/fleet-first"] == expected, Comment(rawValue:
                "a directory discovered through a fleet row alone did not earn a recorded colour"))

        let lane = Projection.frame(from: state, at: at(20)).lanes.first { $0.session == SessionID("s-fleet") }
        #expect(lane?.color == expected)
    }

    /// A fleet row whose `cwd` is an empty (or all-whitespace) string must
    /// yield NO directory at all — `Redacted(optional:)`'s posture, the
    /// same one the hook path takes. The trap this pins: a non-nil-but-
    /// EMPTY directory passes the Card Color row's `lane.directory != nil`
    /// gate while failing every `!dir.isEmpty` write guard behind it — a
    /// control that renders but cannot act.
    @Test("an empty fleet-row cwd yields no directory, no colour record, and no picker gate")
    func emptyFleetRowCwdYieldsNoDirectory() {
        let row = FleetRow(session: SessionID("s-blank"), name: nil, kind: "background",
                           state: .value("working"), status: .absent, cwd: "   ")
        var state = DeckState()
        Reducer.reduce(&state, .fleet([row], at: at(10), id: EventID("f1")))

        #expect(state.lanes[SessionID("s-blank")]?.cwd == nil, Comment(rawValue:
                "a whitespace-only fleet cwd was ingested as a directory"))
        let noRecord = state.prefs.directoryColors.isEmpty
        #expect(noRecord, "an empty cwd earned a directoryColors entry")

        let lane = Projection.frame(from: state, at: at(20)).lanes.first { $0.session == SessionID("s-blank") }
        let gateClosed = lane?.directory == nil
        #expect(gateClosed, Comment(rawValue:
                "the projection surfaced a directory for a lane with none — " +
                "the picker gate would open onto a control that cannot write"))
    }

    // ------------------------------------------------------------- migration
    //
    // `legacyCardColors` carries the OLD surface-keyed entries forward;
    // `recordCardColorIfNeeded` is where each one gets a chance to adopt
    // onto the lane's real directory, or is discarded if the slot it named
    // is already spoken for.

    /// The simple case: one legacy entry, one lane whose surface matches
    /// it. The directory adopts the legacy slot outright, and the legacy
    /// entry is drained.
    @Test("a lane resolving its directory adopts a matching legacy surface entry")
    func adoptsALegacyEntryOnFirstResolution() {
        var state = DeckState()
        state.prefs.legacyCardColors["SURF-LEGACY"] = .slot(5)

        Reducer.reduce(&state, .hook(hostedStart("s-legacy", surface: "SURF-LEGACY", cwd: "/w/legacy")))

        #expect(state.prefs.directoryColors["/w/legacy"] == .slot(5),
                "the legacy surface entry was not adopted onto the resolved directory")
        #expect(state.prefs.legacyCardColors["SURF-LEGACY"] == nil,
                "the legacy entry survived its own adoption")
    }

    /// Two legacy entries both parked on slot 5, under different surfaces —
    /// the exact shape a pre-migration disk file can hold (two old tabs
    /// that both happened to earn the same slot at different times, since
    /// the old rule only ever narrowed to the LIVE fleet). The first lane
    /// resolved adopts 5; the second lane's own legacy entry cannot — slot
    /// 5 is now RECORDED against the first directory — so it falls through
    /// to the ordinary `assign` path and lands on a DIFFERENT slot. Both
    /// legacy entries are drained either way: adoption and discard both
    /// consume the map entry, only the outcome differs.
    @Test("a legacy slot collision adopts once, then falls through to a different slot")
    func legacySlotCollisionAdoptsOnceThenFallsThrough() {
        var state = DeckState()
        state.prefs.legacyCardColors["SURF-ONE"] = .slot(5)
        state.prefs.legacyCardColors["SURF-TWO"] = .slot(5)

        Reducer.reduce(&state, .hook(hostedStart("s-one", surface: "SURF-ONE", ms: 10, cwd: "/w/one")))
        #expect(state.prefs.directoryColors["/w/one"] == .slot(5))

        Reducer.reduce(&state, .hook(hostedStart("s-two", surface: "SURF-TWO", ms: 20, cwd: "/w/two")))
        #expect(state.prefs.directoryColors["/w/two"] != .slot(5), Comment(rawValue:
                "the second legacy entry adopted a slot already recorded against another directory"))
        #expect(state.prefs.directoryColors["/w/two"] != nil, "the second directory earned no colour at all")

        #expect(state.prefs.legacyCardColors.isEmpty, "both legacy entries should have drained by now")
    }

    /// The second-session drain: a directory is ALREADY coloured (the first
    /// session recorded it already), and a second lane for the SAME
    /// directory arrives carrying its own legacy surface entry. The
    /// directory's colour must not change — the `directoryColors[dir] ==
    /// nil` guard sees it is already set — but the second lane's legacy
    /// entry must still be consumed, or it would sit in `legacyCardColors`
    /// forever with no lane left that could ever drain it (this exact
    /// surface's session already resolved once).
    @Test("a second session of an already-adopted directory still drains its own legacy entry")
    func secondSessionDrainsItsLegacyEntryWithoutChangingTheColor() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-first", surface: "SURF-FIRST", ms: 10, cwd: "/w/already")))
        let recorded = state.prefs.directoryColors["/w/already"]
        #expect(recorded != nil, "the fixture's own premise: the first session recorded a colour")

        // A second lane, same directory, carrying a legacy entry under its
        // OWN surface — seeded directly on prefs rather than by an earlier
        // hook, since this surface never actually earned one live; the
        // point under test is only that the drain runs regardless.
        state.prefs.legacyCardColors["SURF-SECOND"] = .slot((CardColor.fallbackSlot(for: "/w/already") + 1)
                                                             % CardColor.paletteCount)
        Reducer.reduce(&state, .hook(hostedStart("s-second", surface: "SURF-SECOND", ms: 20, cwd: "/w/already")))

        #expect(state.prefs.directoryColors["/w/already"] == recorded,
                "the already-recorded directory's colour changed on a second session's arrival")
        #expect(state.prefs.legacyCardColors["SURF-SECOND"] == nil,
                "the second session's own legacy entry was left stranded, undrained")
    }

    /// `.custom` adopts unconditionally — it holds no NAMED slot at either
    /// of `CardColor.assign`'s first two tiers (tier 3, `generate`, has
    /// nothing to do with migration adoption), so there is no collision for
    /// it to lose to, even when its "nearest" slot (there isn't one; the
    /// point is that the question does not even apply) is otherwise taken.
    @Test("a custom legacy entry adopts even when every palette slot is already recorded")
    func customLegacyEntryAdoptsRegardlessOfSlotPressure() {
        var state = DeckState()
        for i in 0..<CardColor.paletteCount {
            state.prefs.directoryColors["/w/filled-\(i)"] = .slot(i)
        }
        let custom = CardColor.custom(red: 0.2, green: 0.5, blue: 0.8)
        state.prefs.legacyCardColors["SURF-CUSTOM"] = custom

        Reducer.reduce(&state, .hook(hostedStart("s-custom", surface: "SURF-CUSTOM", cwd: "/w/custom-adopter")))

        #expect(state.prefs.directoryColors["/w/custom-adopter"] == custom,
                "a custom legacy entry failed to adopt despite holding no slot to collide over")
        #expect(state.prefs.legacyCardColors["SURF-CUSTOM"] == nil)
    }

    // ------------------------------------------------- migration: the floor

    /// A past defect, reproduced through the migration path rather than
    /// `assign` directly: openagentdeck's directory is already recorded on
    /// teal (slot 4), and alpha's SURFACE carries a legacy entry parked
    /// on mint (slot 3) — 0.0279 from teal, under
    /// `CardColor.minimumAssignedHueSeparation` (0.05), the exact distance
    /// that let this feature ship with a live collision. The old adoption
    /// guard asked only "is slot 3 exactly the slot teal holds?" — no — and
    /// waved mint through. The current guard asks the honest question and
    /// refuses it.
    ///
    /// Refusal does not strand the legacy entry — it is drained either way
    /// (`recordCardColorIfNeeded`'s own doc comment: adoption and discard
    /// both consume the map entry) — and the directory still gets a
    /// colour, just through the ordinary `assign` path rather than the
    /// migration shortcut: the farthest free named slot from worn teal,
    /// which lands on pink (slot 9, score 0.4579), comfortably clear of the
    /// floor.
    @Test("a legacy slot within the separation floor of an already-worn hue is refused, not adopted")
    func legacySlotWithinTheSeparationFloorIsRefused() {
        var state = DeckState()
        state.prefs.directoryColors["/w/teal-project"] = .slot(4)
        state.prefs.legacyCardColors["SURF-MINT"] = .slot(3)

        Reducer.reduce(&state, .hook(hostedStart("s-mint", surface: "SURF-MINT", cwd: "/w/mint-project")))

        #expect(state.prefs.directoryColors["/w/mint-project"] != .slot(3), Comment(rawValue:
                "mint adopted 0.0279 from a worn teal — the exact defect this floor exists to close"))
        #expect(state.prefs.legacyCardColors["SURF-MINT"] == nil,
                "the refused legacy entry was left stranded, undrained")

        guard let assigned = state.prefs.directoryColors["/w/mint-project"] else {
            Issue.record("the fixture's own premise: a colour was assigned after adoption was refused")
            return
        }
        let assignedHue: Double
        switch assigned {
        case .slot(let s): assignedHue = CardColor.paletteHue(s)
        case .custom(let r, let g, let b): assignedHue = CardColor.rgbToHSB(red: r, green: g, blue: b).hue
        }
        let distanceFromTeal = CardColor.hueDistance(assignedHue, CardColor.paletteHue(4))
        #expect(distanceFromTeal >= CardColor.minimumAssignedHueSeparation, Comment(rawValue:
                "the fallback colour landed \(distanceFromTeal) from worn teal — under the very floor " +
                "adoption was just refused for"))
        #expect(assigned == .slot(9), "expected pink (slot 9), the farthest free slot from worn teal")
    }

    /// Sovereignty, not spread: a `.custom` legacy entry parked a mere 0.02
    /// from an already-worn hue still adopts outright. The floor governs
    /// which NAMED slot the deck hands out on its own initiative; it has
    /// no say over a colour a person already chose, migration-carried or
    /// not — the same exemption `CardColor.assign`'s own doc comment gives
    /// a hand-picked `.custom` colour at every one of its tiers.
    @Test("a legacy custom entry adopts even 0.02 from an already-worn hue — sovereignty, not spread")
    func legacyCustomEntryAdoptsDespiteSittingWithinTheFloor() {
        var state = DeckState()
        state.prefs.directoryColors["/w/teal-project"] = .slot(4)
        let nearTeal = CardColor.custom(hue: CardColor.paletteHue(4) - 0.02, saturation: 0.8, brightness: 0.9)
        state.prefs.legacyCardColors["SURF-NEAR-TEAL"] = nearTeal

        Reducer.reduce(&state, .hook(hostedStart("s-near-teal", surface: "SURF-NEAR-TEAL",
                                                  cwd: "/w/near-teal-project")))

        #expect(state.prefs.directoryColors["/w/near-teal-project"] == nearTeal, Comment(rawValue:
                "a custom legacy entry failed to adopt despite sovereignty over its own near-duplicate pick"))
        #expect(state.prefs.legacyCardColors["SURF-NEAR-TEAL"] == nil,
                "the adopted legacy entry survived its own adoption")
    }

    // ------------------------------------------------------- projection fallback

    /// Two RECORDLESS lanes sharing a `cwd` already read as the same colour
    /// before either one earns a recorded assignment — the fallback hashes
    /// the DIRECTORY, not the session id, so this holds from the very first
    /// projection rather than only after the reducer catches up.
    ///
    /// Built by hand-assembling `DeckState` rather than through `Reducer
    /// .reduce` — a real hook or fleet event would immediately trigger
    /// `recordCardColorIfNeeded` and turn this into a RECORDED-colour test,
    /// which `twoSessionsSameDirectoryShareOneEntry` already covers. This
    /// test's own point is narrower: the FALLBACK alone, with nothing
    /// recorded at all, already agrees for two lanes on one directory.
    @Test("two recordless lanes sharing a directory already fall back to the same colour")
    func recordlessLanesShareTheDirectoryFallback() {
        func lane(_ session: String) -> LaneRecord {
            var l = LaneRecord(session: SessionID(session), firstSeenAt: at(0), lastEventAt: at(0),
                               state: .idle, stateSource: EventID("f1"), stateDecidedAt: nil,
                               fleetState: .absent, waitingFor: .absent, isBackground: true,
                               contextPercent: .absent, contextSource: nil, contextDecidedAt: nil)
            l.cwd = Sourced(value: Redacted("/w/shared-fallback"), source: EventID("f1"), decidedAt: at(0))
            return l
        }
        var state = DeckState()
        state.lanes[SessionID("s-x")] = lane("s-x")
        state.lanes[SessionID("s-y")] = lane("s-y")

        let projected = Projection.frame(from: state, at: at(10))
        let colorX = projected.lanes.first { $0.session == SessionID("s-x") }?.color
        let colorY = projected.lanes.first { $0.session == SessionID("s-y") }?.color
        #expect(colorX != nil && colorX == colorY,
                "two recordless lanes on one directory fell back to different colours")
        #expect(state.prefs.directoryColors.isEmpty, "the fixture's own premise: nothing was recorded")
    }

    /// A lane with NO directory at all still falls back to the session-id
    /// hash — the existing, pre-feature behaviour, preserved for the one
    /// case a directory can never cover.
    @Test("a lane with no directory at all falls back to the session-id hash")
    func directorylessLaneFallsBackToSessionIDHash() {
        var state = DeckState()
        Reducer.reduce(&state, .hook(hostedStart("s-no-dir", surface: "SURF-NO-DIR")))

        let lane = Projection.frame(from: state, at: at(10)).lanes.first { $0.session == SessionID("s-no-dir") }
        #expect(lane?.color == .slot(CardColor.fallbackSlot(for: "s-no-dir")))
    }

    // --------------------------------------------------- exhaustion generates
    //
    // `CardColorTests.exhaustionGeneratesRatherThanRepeats` pins `assign`'s
    // tier 3 in isolation; this drives the identical promise through the
    // real reducer funnel — the seam an actual fleet of a dozen projects
    // would exercise, not a hand-built `existing` map.

    /// Twelve directories, one hook event apiece, in order. An earlier
    /// version of this test expected the first eleven to fill every named
    /// slot before the twelfth ever generated — true under the OLD "lowest
    /// free slot" tier 2, false under the spread rule. Run for real
    /// here (not hand-simulated): only EIGHT of the eleven named slots
    /// actually get claimed before generation starts. The other three —
    /// orange, teal, cyan — go DORMANT partway through, each one stranded
    /// by a close neighbour that claimed a slot earlier in the run (brown,
    /// mint, and mint again respectively — mint sits 0.0279 from teal AND
    /// 0.0462 from cyan, so its round-one claim strands BOTH of its
    /// neighbours at once, all within `minimumAssignedHueSeparation`
    /// of the dormant one) and never recovers: once a neighbour that close
    /// is worn, nothing can make the dormant slot spread far enough from
    /// EVERY worn hue to clear the floor again, so it stays dormant for
    /// every directory after it, not just the one that stranded it. Four
    /// directories generate as a result, not one.
    ///
    /// What the earlier test still proves, unchanged: zero duplicates
    /// among all twelve — the product rule this whole feature exists to
    /// guarantee, spread rule or not — and a relaunch (a fresh `DeckState`
    /// seeded with nothing but the SAME recorded `directoryColors`, then
    /// fed the identical directories again) reads back the exact same
    /// twelve colours, because `recordCardColorIfNeeded`'s own guard
    /// declines to touch an entry that already exists rather than
    /// re-deriving one.
    @Test("twelve directories earn twelve distinct colours, four generated once the spread rule strands three named slots, stable across relaunch")
    func twelveDirectoriesEarnTwelveDistinctColorsFourGenerated() {
        var state = DeckState()
        for i in 0..<12 {
            Reducer.reduce(&state, .hook(hostedStart("s-\(i)", surface: "SURF-\(i)", ms: Int64(10 * i),
                                                      cwd: "/w/project-\(i)")))
        }

        #expect(state.prefs.directoryColors.count == 12, Comment(rawValue:
                "twelve hosted directories recorded \(state.prefs.directoryColors.count) entries, not twelve"))

        let colors = (0..<12).map { state.prefs.directoryColors["/w/project-\($0)"] }
        #expect(colors.allSatisfy { $0 != nil }, "some directory earned no recorded colour at all")

        for i in 0..<colors.count {
            for j in (i + 1)..<colors.count {
                #expect(colors[i] != colors[j], Comment(rawValue:
                        "directories \(i) and \(j) recorded the identical colour " +
                        "\(String(describing: colors[i])) — the never-duplicate rule broke"))
            }
        }

        let generatedCount = colors.compactMap { $0 }.filter {
            if case .custom = $0 { return true } else { return false }
        }.count
        #expect(generatedCount == 4, Comment(rawValue:
                "expected exactly four GENERATED colours among twelve — orange, teal, and cyan " +
                "stranded dormant by close neighbours claimed earlier in the run — found \(generatedCount)"))

        // Relaunch: a fresh state carrying only the recorded map, fed the
        // same twelve directories again. Nothing here should re-derive —
        // the guard alone is what makes the colours stick.
        var relaunched = DeckState()
        relaunched.prefs.directoryColors = state.prefs.directoryColors
        for i in 0..<12 {
            Reducer.reduce(&relaunched, .hook(hostedStart("s-\(i)-again", surface: "SURF-\(i)-AGAIN",
                                                           ms: Int64(10 * i), cwd: "/w/project-\(i)")))
        }
        for i in 0..<12 {
            #expect(relaunched.prefs.directoryColors["/w/project-\(i)"] == colors[i],
                    "directory \(i)'s colour changed across a relaunch")
        }
    }
}
