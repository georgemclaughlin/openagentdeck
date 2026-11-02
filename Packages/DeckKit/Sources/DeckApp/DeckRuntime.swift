//
//  DeckRuntime.swift · DeckApp
//
//  Wiring, and nothing else. This is the only place concrete adapters are
//  constructed, and the only place a hook's HTTP response is
//  made to wait on a human.
//
//  Architecture §5: `DeckCore` is a single serialized inbox. Every external
//  input — an HTTP request, a poll result, a button — becomes an event on one
//  actor, and the reducer stays synchronous and total. That is what makes
//  "a hook is answered exactly once" a property of a list rather than a race.
//

import AppKit
import Foundation
import Observation
import DeckCore
import DeckPorts
import DeckAdapters

@MainActor
@Observable
public final class DeckRuntime {

    public private(set) var frame: Frame = Projection.frame(from: DeckState(), at: .start)
    public private(set) var port: UInt16 = DeckRuntime.defaultPort
    /// Whether the deck is actually listening — rendered permanently along the
    /// window's bottom edge, because an always-on device that has stopped
    /// receiving looks exactly like one with nothing to report.
    public private(set) var status: HookServerStatus = .notStarted

    /// **Whether Claude Code can reach this deck**, which is a different
    /// question from whether the socket is bound; answered by combining the two.
    /// Computed from the settings file every time rather than remembered: a
    /// stored "installed" flag goes stale the moment someone edits
    /// `settings.json` by hand, and a Connected badge over an unreachable deck
    /// is a lie.
    public private(set) var connection: Connection = .notConnected

    /// The last thing read at the settings path, so the empty state can offer
    /// to connect without re-reading a file on every render.
    private var readout: ConfigReadout = .absent
    private var installedPort: Int?
    /// Unsigned loopback `/hook` entries in the file, counted at the same
    /// read. What `Connection.unlisted` renders: the difference between
    /// "adopt this one" and "the hook is gone".
    private var candidatesSeen = 0
    /// A write to the settings file is in flight.
    ///
    /// Three surfaces can start one (the empty-state card, the banner's sheet,
    /// the Settings pane) and `connect` awaits a read before it awaits a write.
    /// Two presses that both read before either writes would apply the same
    /// diff twice: two writes, and the second backup would hold the first
    /// write's output. Same shape as `draining`'s guard.
    private var writingConfig = false

    /// Monotonic, so two writes in one fleet-poll window cannot collide. A
    /// poll counter does not move between two presses a second apart, which
    /// put the backup and the temp file at the same path.
    private var configWrites: Int64 = 0

    /// Has any hook ever arrived this run? The difference between "connected
    /// and quiet" and "connected and nothing is actually reaching us".
    private var heardAHook = false

    private var windowObservers: [NSObjectProtocol] = []
    private var fitting = false

    /// Reads whether the system currently asks for reduced motion.
    /// `internal var` like `host` below: app-target tests substitute a scripted
    /// closure so they can flip the flag without touching System Settings.
    internal var readsReduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The last value `readsReduceMotion()` returned, threaded into every
    /// `refresh()` so `Frame.reduceMotion` carries the current setting.
    /// Set only by `refreshAccessibility()`.
    private var systemReduceMotion: Bool = false

    /// Sets `systemReduceMotion` from `readsReduceMotion()` and republishes.
    /// The one method both production and tests call. Called once at launch
    /// (`loadPrefs()`) and again whenever the system notifies that the setting
    /// changed.
    internal func refreshAccessibility() {
        systemReduceMotion = readsReduceMotion()
        refresh()
    }

    /// Load prefs, read the accessibility flags, start watching the themes
    /// folder. Called once from `start()`.
    ///
    /// `internal` rather than `private` as a test seam: `start()` binds a real
    /// `HookServer` and polls real adapters, so it cannot run headless, and this
    /// is the narrowest piece a test can call directly
    /// (`PrefsPersistenceTests.launchWritesNothingWhenPrefsAlreadyExist`,
    /// `ReduceMotionWireTests.loadPrefsPerformsTheLaunchRead`). The window-fit
    /// observer registration and the deferred `fitWindow()` run too, harmlessly:
    /// `deckWindow()` finds nothing in a headless test and no-ops.
    internal func loadPrefs() {
        // A window moved to a screen too small for it may have its title bar off
        // the edge, which the deck cannot see for itself. This nudges it back
        // on-screen and never shrinks it (see `fitted`). Watched rather than
        // checked once: displays get plugged in, and a window restored from one
        // screen opens on another.
        for name in Self.fitTriggers {
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main) { [weak self] _ in
                    // **Never inside the notification.** See `fitWindow`.
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated { self?.fitWindow() }
                    }
                })
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.fitWindow() } }

        // First reading, synchronous, so `state.prefs` below and
        // `frame.reduceMotion` are both current before this method returns.
        refreshAccessibility()
        // Register on `NSWorkspace.shared.notificationCenter`, NOT
        // `NotificationCenter.default`: `accessibilityDisplayOptionsDidChangeNotification`
        // posts on the workspace's own center. Registering on the default center
        // compiles, runs, and never fires.
        windowObservers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.refreshAccessibility() }
                }
            })

        // Set the tracker to what was just READ, before `apply` runs the event
        // through the reducer. Otherwise `apply`'s persistence check sees the loaded
        // `state.prefs` differ from `lastPersistedPrefs`'s init default (`.firstRun`)
        // on every launch that ever saved anything, and writes the bytes just read
        // straight back to disk.
        let loaded = PrefsStore.load(from: prefsDefaults)
        lastPersistedPrefs = loaded
        _ = apply(.prefsChanged(loaded, at: now()))
    }


    /// Seat a reduced state directly, for tests that need a deck in a shape
    /// no single event produces. Nothing in `DeckApp` calls it; the reducer is
    /// the only way state moves in production.
    internal func replaceStateForTesting(_ replacement: DeckState) {
        state = replacement
        refresh()
    }

/// The stored prefs, read-only. The settings window renders these and
/// writes only through `setPrefs`.
    public var prefs: DeckPrefs { state.prefs }


    /// Turn auto-continue on or off for the SELECTED session's surface.
    ///
    /// Goes through `setPrefs` like every other preference: the reducer, then
    /// disk. Keyed on the surface rather than the session because a session id
    /// lasts one invocation (see `DeckPrefs.autoContinue`).
    public func setAutoContinue(_ on: Bool) {
        guard let selected = state.selected,
              let surface = state.lanes[selected]?.host?.value.surface else { return }
        var next = state.prefs
        if on { next.autoContinue.insert(surface) } else { next.autoContinue.remove(surface) }
        // A hand answer is recorded in the direction it was given. Turning OFF
        // records the refusal, which stops `DeckState.seedAutoContinue` re-arming
        // the session on its next host report. Turning ON clears the refusal.
        if on {
            next.autoContinueRefused.remove(surface)
        } else {
            next.autoContinueRefused.insert(surface)
        }
        guard next != state.prefs else { return }
        setPrefs(next)
    }

    /// **The same preference, written for a NAMED surface rather than for
    /// whatever is selected.**
    ///
    /// `setAutoContinue(_:)` reads `state.selected`, which is wrong for any
    /// surface that addresses a lane directly (`SessionActionsPanel`). Same
    /// write, same decision-recording, one explicit key.
    public func setAutoContinue(_ on: Bool, forSurface surface: String) {
        guard !surface.isEmpty else { return }
        var next = state.prefs
        if on {
            next.autoContinue.insert(surface)
            next.autoContinueRefused.remove(surface)
        } else {
            next.autoContinue.remove(surface)
            next.autoContinueRefused.insert(surface)
        }
        guard next != state.prefs else { return }
        setPrefs(next)
    }

    /// Whether the deck could actually send Continue to THIS lane: the
    /// per-lane form of `continuableSurfaces`, and the gate a lane-keyed switch
    /// needs so it is not offered where `Reducer.arm` would decline.
    public func offersContinue(to lane: LaneView) -> Bool {
        guard lane.host != nil else { return false }
        return QuickAction.offerable(state.prefs.quickActions, in: lane.directory?.value)
            .contains { $0.id == QuickAction.continueID }
    }

    /// **Every session the deck can currently address, armed or disarmed in
    /// one act (the bulk half of the feature).**
    ///
    /// Acts on SURFACES the deck knows right now, not "all sessions ever": a
    /// pane the deck has never located has no key to write. Hidden lanes ARE
    /// included: hiding takes a session off the strip, not out of the fleet
    /// (`DeckPrefs.hidden`), and a hidden session stalled at the usage limit is
    /// exactly the one nobody is watching.
    ///
    /// Returns the number of surfaces whose ARMING changed. That is not the
    /// same as "was anything written": the OFF direction also cancels held
    /// offers, so a call that changes no arming can still do work and return
    /// zero. It is a count for a sentence, not a control-flow signal.
    ///
    /// **Records no refusal.** A sweep of the fleet is not a standing
    /// instruction about tabs, so Turn Off adds no refusal and removes none
    /// (adding would void the per-session toggle for those tabs; removing would
    /// let Turn Off arm a tab the user had refused). Turn On clears every
    /// refusal, because that IS asking for what was refused. See
    /// `DeckEvent.autoContinueSetForAll`; the per-session switch remains the
    /// control for "never this tab".
    @discardableResult
    public func setAutoContinueForAllSessions(_ on: Bool) -> Int {
        // The two directions are deliberately not symmetric.
        //
        // ON is narrow: only surfaces the deck could actually continue, because
        // writing a preference it cannot honour would put a promise in the file
        // that `Reducer.arm` will skip.
        //
        // OFF is total, wider than "every addressable surface". A pane armed by the
        // standing default keeps its entry after its session ends (surface keys
        // outlive sessions), so a sweep over the live fleet could never reach it;
        // the footer would then read "No sessions ... will continue" while the next
        // session started in that tab was continued anyway. Disarming must reach
        // anything arming could reach; the reducer clears the whole set.
        //
        // Routed through an EVENT, not a `setPrefs` write, because disarming also
        // cancels offers held in `awaitingAutoContinue`, which is reducer state;
        // inferring that from the resulting preferences misfired (see
        // `DeckEvent.autoContinueSetForAll`).
        let surfaces = on ? Array(continuableSurfaces) : []
        let changed = on
            ? surfaces.filter { !state.prefs.autoContinue.contains($0) }.count
            : state.prefs.autoContinue.count
        // OFF also cancels held offers, so "is there anything to do" is wider than
        // "is anything armed". Refusals belong to the ON side only; testing them
        // for OFF made every Turn Off dispatch a no-op event.
        let hasWork = on
            ? (!surfaces.isEmpty || !state.prefs.autoContinueRefused.isEmpty)
            // Read the one fact needed directly: `autoContinueCoverage` rebuilds
            // `continuableSurfaces`, which this gate does not need.
            : (changed > 0 || state.awaitingAutoContinue.values.contains {
                now().sinceStart.raw - $0.sinceStart.raw <= Reducer.autoContinueOfferBudget.raw
            })
        guard hasWork else { return 0 }
        _ = apply(.autoContinueSetForAll(on: on, surfaces: surfaces, at: now(),
                                         id: EventID("auto-continue-all|\(on)|\(now().sinceStart.raw)")))
        return changed
    }

    /// The standing default for panes the deck has not seen before.
    ///
    /// Turning it ON arms NOTHING that already exists (see
    /// `DeckPrefs.autoContinueByDefault`); `setAutoContinueForAllSessions(_:)`
    /// is the explicit retroactive control.
    public func setAutoContinueByDefault(_ on: Bool) {
        var next = state.prefs
        next.autoContinueByDefault = on
        guard next != state.prefs else { return }
        setPrefs(next)
    }

    /// **The surfaces this feature can actually act on: BOTH halves of what
    /// arming requires, not just the preference.**
    ///
    /// `Frame` treats auto-continue as two facts (`autoContinueOn` is the
    /// preference, `autoContinuable` is whether the deck could honour it), and
    /// `Reducer.arm` enforces the second: it skips any session whose
    /// `QuickAction.offerable(_:in:)` set has no Continue (dragged past the
    /// ten-action cap, or scoped to folders the session's `cwd` does not match).
    /// Counting the preference alone made the Settings footer overstate.
    ///
    /// One derivation, two readers: the bulk act writes exactly the set the
    /// footer counts.
    ///
    /// A pane shared by two sessions is ONE surface, continuable if EITHER of
    /// its sessions is: the preference is keyed on the pane, so one live route
    /// suffices.
    private var continuableSurfaces: Set<String> {
        var surfaces: Set<String> = []
        for lane in state.lanes.values {
            guard let surface = lane.host?.value.surface, !surface.isEmpty else { continue }
            let offered = QuickAction.offerable(state.prefs.quickActions,
                                                in: lane.cwd?.value.value)
            guard offered.contains(where: { $0.id == QuickAction.continueID }) else { continue }
            surfaces.insert(surface)
        }
        return surfaces
    }

    /// How many sessions the deck can continue are armed, and how many there
    /// are: the numbers the Settings footer reports. Computed here so the view
    /// states a measured fact rather than recounting the fleet.
    public var autoContinueCoverage: AutoContinueCoverage {
        let continuable = continuableSurfaces
        // Offers past their deadline will not arm anything, so they are neither
        // counted nor announced; otherwise the footer would claim forever that
        // sessions were "still being placed". Asked against the clock at READ time,
        // which changes no stored state and so cannot disagree with the reducer.
        let live = state.awaitingAutoContinue.values.count {
            now().sinceStart.raw - $0.sinceStart.raw <= Reducer.autoContinueOfferBudget.raw
        }
        return AutoContinueCoverage(
            armed: continuable.filter(state.prefs.autoContinue.contains).count,
            total: continuable.count,
            // Every armed pane, PLUS any offer held for a session the deck cannot
            // address yet. Both will auto-continue, so both must keep "Turn Off for All
            // Sessions" reachable.
            // Every held offer counts, including one whose session has ended, because
            // the reducer redeems every held offer (see
            // `Reducer.redeemAwaitedAutoContinue`). Hiding ended ones would make an
            // offer invisible to the UI while still live in the reducer, so a later
            // fleet poll could arm a pane with no on-screen control to stop it. What
            // will arm must be something the user can see and cancel.
            armedAnywhere: state.prefs.autoContinue.count + live,
            heldOffers: live,
            refusals: state.prefs.autoContinueRefused.count)
    }

    /// **What Settings needs to draw the auto-continue controls: a named value
    /// rather than a tuple, because the facts answer different questions.**
    ///
    /// `armed`/`total` are about sessions the deck could ACTUALLY continue and
    /// feed the footer sentence; promising a continuation `Reducer.arm` will
    /// skip would be a lie.
    ///
    /// `armedAnywhere` counts EVERY armed pane, addressable or not. The two come
    /// apart when Continue is dragged past the ten-action cap (`total` is 0) or
    /// when a tab the standing default armed goes quiet. Armed entries still
    /// sit in the preferences waiting to continue the next session, so "Turn
    /// Off for All Sessions" must stay reachable.
    public struct AutoContinueCoverage: Equatable, Sendable {
        public let armed: Int
        public let total: Int
        public let armedAnywhere: Int
        /// Offers held for sessions the deck has not placed yet. They WILL arm
        /// their pane once it resolves, so the footer names them.
        public let heldOffers: Int
        /// Whether there is anything for either button to do; the gate the
        /// Settings section reads, rather than `total > 0`. Refusals count: "Turn On
        /// for All Sessions" clears them, and a refusal on an unaddressable pane is
        /// otherwise unclearable.
        public var hasAnythingToShow: Bool { total > 0 || armedAnywhere > 0 || refusals > 0 }
        /// Panes the user has explicitly refused. Keeps the ON button reachable
        /// while there is a refusal to clear, even on a fully armed fleet.
        public let refusals: Int
        /// Panes armed in the PREFERENCES, ignoring whether the deck can currently
        /// continue them: `armedAnywhere` minus the pending offers.
        public var prefArmed: Int { armedAnywhere - heldOffers }
    }

    /// Take a session off the strip. Keyed on its SURFACE, so it stays hidden
    /// through the `/exit` that gives the session a new id.
    ///
    /// A lane with no address cannot be hidden (nothing to key the preference
    /// on) and the panel offers no control for one.
    ///
    /// **Hiding the selected session also deselects it.** Tapping "Hide from the
    /// Deck" in the band means "done with this one on my glass", so the band
    /// collapses and the fleet returns, rather than leaving a `.row` selection
    /// pointed at a lane `visibleLanes` no longer carries
    /// (`ShellTests.hidingTheSelectedLaneDeselectsAndCollapsesTheBand`). The rule
    /// lives here, not in view state, because `hide` is the one place every
    /// caller routes through. Hiding a lane that is NOT the selection leaves the
    /// selection and any open band untouched.
    public func hide(_ session: SessionID) {
        guard let surface = state.lanes[session]?.host?.value.surface else { return }
        var next = state.prefs
        next.hidden.insert(surface)
        guard next != state.prefs else { return }
        // The panel is about the lane that just left the strip, so it goes too.
        if state.selected == session { _ = apply(.sessionSelected(nil, at: now())) }
        setPrefs(next)
    }

    /// Bring one lane back, from the shelf that named it. Without this, the
    /// only reversal would be `unhideAll`, which punishes looking at the shelf.
    public func unhide(_ session: SessionID) {
        guard let surface = state.lanes[session]?.host?.value.surface else { return }
        var next = state.prefs
        next.hidden.remove(surface)
        guard next != state.prefs else { return }
        setPrefs(next)
    }

    /// Bring every hidden lane back. One control rather than a list: the strip
    /// is where sessions live and this is the door back to it.
    public func unhideAll() {
        var next = state.prefs
        guard !next.hidden.isEmpty else { return }
        next.hidden.removeAll()
        setPrefs(next)
    }

    /// Choose, or clear, a session's card colour. The picker's one write path.
    ///
    /// **Keyed on the DIRECTORY, not the surface.** A colour is a fact about the
    /// project: the choice paints every session open on that directory, so two
    /// sessions sharing a working directory read as one project. A lane with no
    /// resolved directory is declined silently (as in `hide`), a backstop beside
    /// the control's own `lane.directory != nil` gate in `SessionControls`.
    ///
    /// A non-nil `choice` pins that colour outright, including a knowingly
    /// duplicate one; it never goes through `assign` (see `CardColor.assign` on
    /// why a deliberate duplicate belongs to the person). `nil` ("Automatic")
    /// REMOVES the recorded entry and immediately re-records what a fresh
    /// arrival would get now: the same `CardColor.fallbackSlot` / `.assign` pair
    /// the reducer's `recordCardColorIfNeeded` runs, computed against
    /// `next.directoryColors` with THIS directory's entry already gone (so
    /// `assign` cannot see its own old slot as held). The colour lands in the
    /// same gesture, not on the next poll.
    ///
    /// Routed through `setPrefs`, so it is exactly one `PrefsStore.save` per call.
    public func setCardColor(_ choice: CardColor?, for session: SessionID) {
        guard let dir = state.lanes[session]?.cwd?.value.value, !dir.isEmpty else { return }
        var next = state.prefs
        if let choice {
            next.directoryColors[dir] = choice
        } else {
            next.directoryColors[dir] = nil
            let preferred = CardColor.fallbackSlot(for: dir)
            next.directoryColors[dir] = CardColor.assign(existing: next.directoryColors,
                                                         preferred: preferred)
        }
        guard next != state.prefs else { return }
        setPrefs(next)
    }

    /// Persist the fleet's manual order after a drop (edit mode's write path):
    /// copy `state.prefs`, mutate the one field, guard on a real change,
    /// `setPrefs` once.
    ///
    /// **Surfaces are deduped, preserving first occurrence**, mirroring the
    /// decode clamp in `DeckPrefs.decode`: a duplicate is malformed input, not a
    /// legitimate state for a merge that reads position as rank.
    ///
    /// **One prefs write per drop.** The caller (`SessionOverview`'s drag
    /// handler, `onEnded`) derives the full visible hosted order once and calls
    /// this once per drop, never per retarget.
    ///
    /// **A merge, not a wholesale replace: surfaces the caller could not see
    /// keep their entries.** The commit names only the lanes that were on screen
    /// for the drag (a collapsed shelf's hidden lanes are not among them), and
    /// `hide()`/`unhide()` never touch `cardOrder`, so hiding a card does not
    /// forget where it goes. Replacing wholesale would drop every unnamed surface
    /// into `Projection.manualOrder`'s unordered tail. So the write is: the
    /// caller's surfaces first, then every other surface the stored order
    /// already named, in prior relative order.
    public func reorder(_ surfaces: [String]) {
        var next = state.prefs
        var seen = Set<String>()
        var order: [String] = []
        for surface in surfaces + state.prefs.cardOrder {
            guard !seen.contains(surface) else { continue }
            seen.insert(surface)
            order.append(surface)
        }
        next.cardOrder = order
        guard next != state.prefs else { return }
        setPrefs(next)
    }

    /// Remove a session from the deck entirely. The Claude Code process is not
    /// touched: it keeps running and keeps asking for permission in its own
    /// terminal, where the user now has to answer.
    ///
    /// Any call the deck is currently holding for it is RELEASED first (not
    /// denied). That ordering is the safety argument: a deleted session with a
    /// waiting continuation and no lane to resolve it would hang until the
    /// budget ran out.
    ///
    /// `requestDelete` asks: the panel then shows what the delete will and will
    /// not do, and nothing is removed until it is confirmed.
    public func requestDelete(_ session: SessionID) {
        _ = apply(.deleteRequested(session, at: now()))
        refresh()
    }

    public func cancelDelete() {
        _ = apply(.deleteAbandoned(at: now()))
        refresh()
    }

    public func confirmDelete(_ session: SessionID) {
        _ = apply(.deleteConfirmed(session, at: now()))
        delete(session)
    }

    public func delete(_ session: SessionID) {
        for (hold, continuation) in waiting where hold.session == session {
            continuation.resume(returning: HookResponse.decision(
                .release, reason: "removed from the deck",
                event: kindOf[hold] ?? .preToolUse))
            waiting[hold] = nil
            kindOf[hold] = nil
        }
        // The per-session side tables go with the lane. `resolvedCwd` is a "has
        // been answered" memory; a session that comes BACK (the fleet keeps listing
        // it, because delete does not touch the process) would otherwise find its
        // directory already marked resolved and never render a branch again.
        resolvedCwd[session] = nil
        unplaceable[session] = nil
        // `seededTranscriptSessions` goes with the lane for the same reason. The
        // id cannot walk back in right away: `prefs.deleted` makes the reducer
        // refuse every hook for it until the tombstone is pruned (missing from the
        // fleet for `Self.tombstoneMisses` consecutive polls, i.e. the process is
        // truly gone). After that, a fresh hook opens a NEW `LaneRecord` with
        // `transcriptSeeded` false, and that lane must not find its history
        // withheld by a stale entry that outlived the delete.
        seededTranscriptSessions.remove(session)
        // Cleared for symmetry: a deleted session's completed task handle (and the
        // path its closure captured) should not outlive the delete either.
        pendingTranscriptSeedTask.removeValue(forKey: session)
        var next = state.prefs
        next.deleted.insert(session.raw)
        guard next != state.prefs else { return }
        setPrefs(next)
        note("deleted session from the deck")
    }

    public func setPrefs(_ prefs: DeckPrefs) {
        // `apply`'s own equality-guarded save is the write; this function does not
        // perform a second one. Pre-setting the tracker to the ARGUMENT and then
        // saving the argument would overwrite any value the reducer refined
        // (`recordCardColorIfNeeded` refines prefs on this same funnel), and leave
        // the tracker equal to the refined value so the self-healing compare never
        // fired again. In-memory tests passed (`state.prefs` was right); only a
        // relaunch showed it, e.g. the standing default arming every pane at its
        // first hook because `autoContinueRefused` never reached disk. Letting
        // `apply` own the write means whatever the reducer settles on is what
        // reaches disk, still exactly one save per change.
        _ = apply(.prefsChanged(prefs, at: now()))
        refresh()
    }

    /// What `PrefsStore` was last asked to write, compared against `state.prefs`
    /// after every event so reducer-side refinements
    /// (`Reducer.recordCardColorIfNeeded`) reach disk without a save call inside
    /// the reducer, which has no storage handle (`DeckCore` stays storage-free).
    /// See `apply(_:)` for the read side and `setPrefs` for the other writer.
    private var lastPersistedPrefs = DeckPrefs.firstRun
    private var state = DeckState()
    private var server: HookServer?
    /// `internal var` like `host` below: app-target tests substitute scripted
    /// ones.
    internal var fleet: FleetPort = FleetCLI()
    internal var worktree: WorktreePort = GitWorktree()
    /// `internal var` like `worktree` above: tests substitute a seam-mocked one
    /// so core tests never touch the real filesystem.
    internal var transcriptFile: TranscriptFilePort = TranscriptFile()
    /// **The api-error peek's own port: a SEPARATE property from
    /// `transcriptFile`, even though both read the same real file in
    /// production.** `TranscriptFile` is a stateless actor (each call opens,
    /// reads and closes its own `FileHandle`), so a second instance behaves
    /// identically to sharing one. Sharing would cost a test seam:
    /// `transcriptFile` is a scripted double that records or gates every call
    /// without knowing which feature is asking, and the transcript seed fires on
    /// the same hook kinds (`.sessionStart` above all) as this peek. A shared
    /// property made existing `TranscriptBackfillTests` fixtures see a second,
    /// uninvited call (`triggersExactlyOnce` broke, and a `GatedTranscriptFile`
    /// leaked an unresumed continuation). A dedicated property costs nothing in
    /// production; the api-error suite wires this one explicitly.
    internal var apiErrorTranscriptFile: TranscriptFilePort = TranscriptFile()
    /// ~256 KB: the floor rung of the transcript backfill's size ladder,
    /// restated from `TranscriptTail.backfillFloorBytes` (which lives in
    /// `DeckCore`, see its doc) so there is one literal. See
    /// `seedTranscript(for:path:)` for why a tail read and how the ladder
    /// escalates. `internal` so a test asserts the same number production reads
    /// with.
    internal static let transcriptTailFloorBytes = TranscriptTail.backfillFloorBytes
    internal var config: ConfigPort = ConfigFile()
    /// The recurring fleet poll. A one-shot discovery at launch would freeze
    /// every discovered lane's status at whatever was true when the deck
    /// started; the fleet is the only feed a hook-less session has.
    private var fleetHeartbeat: Task<Void, Never>?
    /// Five seconds: `claude agents --json` is a ~100-300 ms local process, so
    /// this keeps a lane's idle/busy honest within a glance's tolerance while
    /// the deck stays a rounding error in Activity Monitor.
    internal static let fleetCadenceSeconds: Double = 5
    /// The terminal application hosting the sessions. `var` rather than `let`
    /// because app-target tests substitute a recording one, which is the reason
    /// the port exists.
    internal var host: SessionHostPort = CmuxHost()
    private var waiting: [HoldID: CheckedContinuation<String, Never>] = [:]
    private var started: Date?
    /// The directory each session was last resolved for. `cwd` is on nearly
    /// every payload and changes almost never, so re-walking the filesystem per
    /// hook would be wasted work (the idle-CPU rule).
    private var resolvedCwd: [SessionID: String] = [:]
    /// Sessions the transcript-well backfill has already tried to seed this
    /// launch. Not the authority: the reducer's `.transcriptSeeded` case
    /// (gated on `lane.transcriptSeeded`) is, and makes a duplicate event a
    /// no-op. This set only stops the ADAPTER from reading the file a second
    /// time for a session it already read. In memory only: a relaunch starts
    /// empty, which is correct ("once per session per LAUNCH", see
    /// `seedTranscript(for:path:)`). `delete(_:)` also clears it, so a
    /// deleted-then-recreated lane is re-seedable.
    private var seededTranscriptSessions: Set<SessionID> = []
    /// Test seam only: the seed's own in-flight `Task`, keyed by session, so a
    /// test can `await` completion deterministically rather than sleeping.
    /// `seedTranscript(for:path:)` runs fire-and-forget from `handle(_:)` on
    /// purpose (never blocking the hook response), so otherwise nothing about
    /// WHEN it finishes is observable. This only adds a handle a test may hold;
    /// production never reads it.
    internal var pendingTranscriptSeedTask: [SessionID: Task<Void, Never>] = [:]
    /// The api-error peek's in-flight guard: ONE per session, and unlike
    /// `pendingTranscriptSeedTask` it is cleared the instant its `Task`
    /// completes. The seed is once-per-launch (`seededTranscriptSessions` is
    /// the permanent gate), but a peek is not: the session's last word can change
    /// on every trigger hook (a retry, another error, an ordinary `Stop`). This
    /// keeps two peeks from running CONCURRENTLY for one session while letting a
    /// later hook schedule its own. Also a test seam; production never reads it.
    internal var pendingApiErrorPeekTask: [SessionID: Task<Void, Never>] = [:]
    /// `runForwardPlan`'s handle, `pendingTranscriptSeedTask`'s twin: a test
    /// `await`s this rather than sleeping against
    /// `forwardStepPacingNanoseconds`. Awaiting still costs the real pacing delay
    /// between steps (this is not a fake clock); it only removes guessing how
    /// long is enough. Production never reads it.
    internal var pendingForwardTask: [HoldID: Task<Void, Never>] = [:]
    /// Test seams for the three scheduled watchers, same doctrine as
    /// `pendingForwardTask`: a test `await`s these against a SHORTENED
    /// `HoldPolicy` allowance. Production never reads them.
    /// `pendingReadinessTask` backs `scheduleReadinessWatch()`,
    /// `pendingScreenObservationTask` backs `attemptScreenObservation`, and
    /// `pendingForwardLandingTask` backs `scheduleForwardLandingWatch`.
    internal var pendingReadinessTask: [HoldID: Task<Void, Never>] = [:]
    internal var pendingScreenObservationTask: [HoldID: Task<Void, Never>] = [:]
    internal var pendingForwardLandingTask: [HoldID: Task<Void, Never>] = [:]
    /// Dedup for the two bounded readiness timers above, same shape as
    /// `scheduleUsageReset`'s `scheduledReset`, keyed per hold: re-deriving an
    /// UNCHANGED deadline schedules nothing new, so a chatty session cannot
    /// stack sleepers for the same mirror.
    private var readinessDeadline: [HoldID: Instant] = [:]
    /// One-shot dedup for the screen observation: fires at most once per
    /// mirror's lifetime (a `HoldID` is never reused), unlike the timer above,
    /// which re-arms on every changed deadline. A second dispatch of the same
    /// read buys nothing; `attemptScreenObservation`'s single retry is the one
    /// second chance.
    private var screenObservationAttempted: Set<HoldID> = []
    /// Sessions whose pid the host could not place, and the pid it could not
    /// place. The negative half of `locate`'s memory: without it a failure is
    /// retried on every beat forever, because failure leaves no address behind
    /// to notice. Cleared when the pid changes (a new process is a new
    /// question) and when the session goes.
    private var unplaceable: [SessionID: Int] = [:]
    /// Consecutive polls in which a tombstoned id did not appear in the fleet
    /// (see `collectTombstones`). In memory only: a tombstone that survives a
    /// relaunch simply starts counting again, which errs toward keeping it.
    private var tombstoneMisses_: [String: Int] = [:]

    /// Whether `note(_:)` also writes to stderr. Read ONCE at construction
    /// rather than per line, since the environment does not change under a
    /// running process and a syscall per diagnostic line is a per-event cost.
    ///
    /// Launched from Xcode, or from a terminal with `OPENAGENTDECK_STDERR` set
    /// to anything, the deck narrates every line it logs. Launched the ordinary
    /// way (Finder, login) nobody is reading stderr; the log file on disk is the
    /// record, and the write to it (in `note`) stays unconditional.
    internal let stderrEnabled: Bool

    /// The flag's derivation, pulled out so a test can ask it of an arbitrary
    /// dictionary: `setenv` would leak process-wide state across tests.
    /// Presence-only: the VALUE never matters, so `OPENAGENTDECK_STDERR=` (empty)
    /// counts as set, like `OPENAGENTDECK_STDERR=1`.
    internal static func stderrEnabled(in environment: [String: String]) -> Bool {
        environment["OPENAGENTDECK_STDERR"] != nil
    }

    public init() {
        stderrEnabled = DeckRuntime.stderrEnabled(in: ProcessInfo.processInfo.environment)
    }

    /// The test seam for the flag above. Production has one caller
    /// (`DeckScene`) and it always wants the real environment.
    internal init(environment: [String: String]) {
        stderrEnabled = DeckRuntime.stderrEnabled(in: environment)
    }

    /// Test seam: motion seeding is gated on the deck having started, and
    /// spinning the real HTTP server just to unlock a zoom animation would test
    /// the wrong thing.
    internal func markStartedForTesting() {
        started = Date()
        // A test that exercises setPrefs must not write the developer's real
        // preferences.
        prefsDefaults = PrefsStore.throwaway()
        // Nor the developer's real LOG: a live deck would open on a file full of
        // lines about test sessions that never existed.
        logPath = NSTemporaryDirectory() + "/openagentdeck-test-\(UUID().uuidString).log"
        // And not the developer's own display: the type scale is derived from the
        // surface's density, so an unpinned measurement makes every layout
        // assertion depend on which monitor the suite runs on.
        measuresDensity = false
    }

    /// Where prefs persist. The adapter's suite in production; the test seam
    /// swaps in a throwaway so no test touches a real machine's settings.
    /// The type is inferred on purpose: naming `UserDefaults` here would put
    /// preference storage outside the prefs adapter.
    internal var prefsDefaults = PrefsStore.standard

    /// Whether this runtime asks the display how large a point is. Always,
    /// except under test (see `measureDensity`).
    internal var measuresDensity = true

    /// Test seam: deck time, supplied rather than read.
    ///
    /// The idle gate compares two event stamps, so a test needs two events in
    /// DIFFERENT milliseconds, and against a real clock that is a race.
    internal var testClockMS: Int64?

    /// **The wall-clock millisecond `Instant.start` stands for: the one seam
    /// that converts an outside timestamp onto this runtime's timeline.** Used
    /// by `handleStatusline` (a `resets_at` epoch off the wire) and
    /// `peekTranscript` (a recap row's ISO timestamp off the disk), which must
    /// agree on this arithmetic.
    ///
    /// `nil` when the runtime is not started: with no origin there is nothing to
    /// measure an outside moment against, and both callers refuse to guess.
    ///
    /// **Deliberately NOT routed through `testClockMS`, unlike `now()`.** That
    /// override pins the DECK's clock; this is the epoch origin an outside
    /// timestamp is rebased against. A test that pins deck time still wants a
    /// real base here.
    private var epochBaseMillis: Int64? {
        guard let started else { return nil }
        return Int64(started.timeIntervalSince1970 * 1000)
    }

    /// Deck time, from the one clock this program is allowed to read.
    private func now() -> Instant {
        if let testClockMS { return Instant(sinceStart: Millis(testClockMS)) }
        guard let started else { return .start }
        return Instant(sinceStart: Millis(Int64(Date().timeIntervalSince(started) * 1000)))
    }

    /// The port a deck binds unless told otherwise.
    public static let defaultPort: UInt16 = 8765

    public func start(port: UInt16 = DeckRuntime.defaultPort) async {
        guard server == nil else { return }
        self.port = port
        started = Date()
        loadPrefs()
        let server = HookServer(decide: { [weak self] event in
            guard let self else { return HookResponse.none }
            return await self.handle(event)
        }, statusline: { [weak self] json in
            guard let self else { return "" }
            return await self.handleStatusline(json)
        })
        do {
            try await server.start(port: port)
            self.server = server
            status = .listening(port: port)
        } catch {
            // Loopback or nothing: a listener that could not bind loopback is not
            // retried on another address.
            status = .failed(reason: "127.0.0.1:\(port) — \(error)")
        }
        // The init-time fit ran before any window existed and no-oped; this one
        // runs with glass on screen. It heals the strip's own version of the trap:
        // macOS restores the frame a bigger monitor remembered, and on a 480 pt
        // display its title bar can land off-glass. Nothing else fires
        // (`fitTriggers` watches screen CHANGES, and a window that opens wrong has
        // not changed screens). It is repositioned, never resized.
        DispatchQueue.main.async { MainActor.assumeIsolated { self.fitWindow() } }
        await pollFleet()
        // And keep polling. The launch poll covers "the deck started last"; the
        // heartbeat covers state changes, later sessions, and agents ending.
        fleetHeartbeat?.cancel()
        fleetHeartbeat = Task { [weak self] in
            while !Task.isCancelled {
                // A cancelled sleeper must RETURN (see `scheduleReadinessWatch`). This is
                // the one sleep production genuinely cancels (`fleetHeartbeat?.cancel()`
                // above, on every re-arm); a swallowed cancellation would buy one stray
                // `pollFleet()` before the `while` condition ended the loop.
                guard (try? await Task.sleep(for: .seconds(Self.fleetCadenceSeconds))) != nil else { break }
                // `guard let`, not `self?.`: a runtime that has gone leaves no work, and the
                // optional-chained form kept the loop waking every five seconds for nothing.
                guard let self else { break }
                await self.pollFleet()
            }
        }
        // Ask the host once at launch. Waiting for the first selection meant a
        // refusal was discovered from a panel that looked broken rather than from a
        // deck that already knew.
        await probeHost()
        await refreshConnection()
    }

    // ------------------------------------------------------------- connecting

    /// Re-read the settings file and recompute whether Claude Code can reach
    /// this deck.
    ///
    /// Called at launch and whenever the window becomes key. The deck runs for
    /// days; a config edited by hand or rewritten by another tool would
    /// otherwise leave a stale Connected badge.
    public func refreshConnection() async {
        let document = await config.read()
        switch document {
        case .absent:
            readout = .absent; installedPort = nil; candidatesSeen = 0; connectionDrift = nil
        case .unreadable(let why):
            readout = .unreadable(why); installedPort = nil; candidatesSeen = 0
            connectionDrift = nil
        case .present(let value):
            readout = .present
            installedPort = SettingsMerge.installedPort(value, policy: state.policy)
            candidatesSeen = SettingsMerge.candidates(in: value, policy: state.policy).count
            hasNoStatusline = value["statusLine"] == nil
            // Same read as `installedPort` and `candidatesSeen`, so the pane's repair
            // notice and the connection state beside it cannot disagree.
            connectionDrift = SettingsMerge.timeoutDrift(value, policy: state.policy)
        }
        if case .absent = document { hasNoStatusline = true }
        recomputeConnection()
        // The first place this function has BOTH facts an auto-heal needs: the
        // document just read, and `status` (set before `refreshConnection` is
        // called). See `autoHealSettingsIfNeeded`.
        if case .present(let value) = document {
            await autoHealSettingsIfNeeded(document: value)
        }
    }

    /// **Auto-heal.** `SettingsMerge.reconcile` gained a managed event
    /// (`PostToolUse`), but connecting is consent-gated and nobody re-runs it
    /// unprompted, so an install that predates the event never receives it and
    /// a held call gets no retirement event.
    ///
    /// **The consent boundary is preserved by construction:**
    /// - `adopting: []` never adopts an unsigned candidate hook; only an entry
    ///   THIS deck signed is touched.
    /// - `addStatusline: false` never creates a statusline the person did not
    ///   ask for.
    /// - `SettingsMerge.installedPort(document) == Int(port)`: the function is a
    ///   no-op unless the person has ALREADY consented to THIS deck on THIS
    ///   port. A machine never connected, or connected to a different deck or
    ///   port, is left to the person's own connect tap.
    ///
    /// **Once per launch.** `refreshConnection()` runs repeatedly (launch, every
    /// window-key), and a repair that already ran has nothing left to do.
    ///
    /// **Races a user-driven connect safely.** `connect(_:)` refuses while
    /// `writingConfig` is true and this calls the same function, so one write
    /// proceeds and the other is refused.
    private var autoHealAttempted = false
    private func autoHealSettingsIfNeeded(document: JSONValue) async {
        guard !autoHealAttempted else { return }
        guard case .listening(let port) = status else { return }
        autoHealAttempted = true
        guard SettingsMerge.installedPort(document, policy: state.policy) == Int(port) else { return }
        let plan = SettingsMerge.reconcile(document, port: Int(port), policy: state.policy,
                                           addStatusline: false, adopting: [])
        guard !plan.isNoOp else { return }
        // Privacy: `plan.steps` is deck-authored plain-English prose about WHICH
        // managed event changed (`reconcile`'s `addedSentences`), never file
        // content, a command, or a path, so it is safe for `note()`.
        note("settings healed: \(plan.steps.count) managed event(s) — the deck learned a hook it did not have before")
        for step in plan.steps { note("settings healed: \(step)") }
        _ = await connect(addStatusline: false)
    }

    /// What `SettingsMerge.timeoutDrift` finds at the same read as
    /// `installedPort` and `candidatesSeen`: `nil` when the installed held
    /// timeout agrees with the current policy, or nothing is installed. The
    /// Settings pane's connection status line reads it.
    public private(set) var connectionDrift: (installed: Int?, expected: Int)?

    private func recomputeConnection() {
        connection = Connection.decide(
            document: readout,
            listeningOn: {
                if case .listening(let port) = status { return Int(port) }
                return nil
            }(),
            bindFailed: {
                if case .failed = status { return true }
                return false
            }(),
            installedPort: installedPort,
            attemptedPort: Int(port),
            lanesSeen: state.lanes.count,
            hooksHeard: heardAHook,
            candidatesSeen: candidatesSeen)
    }

    /// What connecting would change, without changing it. The empty state
    /// renders these sentences beside the button and the diff behind them.
    public func connectionPreview(addStatusline: Bool,
                                  adopting: Set<String> = []) async -> Reconciliation? {
        guard case .listening(let port) = status,
              let document = await config.read().document else { return nil }
        return SettingsMerge.reconcile(document, port: Int(port), policy: state.policy,
                                       addStatusline: addStatusline, adopting: adopting)
    }

    /// Connect, or repair. One control, because the reconciliation converges
    /// from any starting state, so this also fixes a stale port, a duplicate
    /// hook and a hand-written hook.
    @discardableResult
    public func connect(addStatusline: Bool,
                        adopting: Set<String> = []) async -> Result<Reconciliation, PortFailure> {
        guard case .listening(let port) = status else {
            return .failure(.unavailable("the deck is not listening, so there is no port to point at"))
        }
        guard !writingConfig else {
            return .failure(.refused("a settings write is already in progress"))
        }
        writingConfig = true
        defer { writingConfig = false }

        let read = await config.read()
        guard let document = read.document else {
            // Refused rather than merged into nothing (see `ConfigDocument`).
            if case .unreadable(let why) = read { return .failure(.malformed(why)) }
            return .failure(.malformed("the settings file could not be read"))
        }
        // Parses, but is not a shape the deck can edit. Refused like an unparseable
        // file: merging into an unknown shape means replacing it.
        if let why = SettingsMerge.misshapen(document) {
            return .failure(.malformed("the settings file parses, but \(why) — the deck will "
                                       + "not rewrite a shape it does not recognise"))
        }
        let plan = SettingsMerge.reconcile(document, port: Int(port), policy: state.policy,
                                           addStatusline: addStatusline, adopting: adopting)
        guard !plan.isNoOp else { await refreshConnection(); return .success(plan) }
        // Did the ROUTE move, or was this a write about something else?
        let routeMoved = SettingsMerge.installedPort(document, policy: state.policy) != Int(port)

        _ = apply(.configRequested(.settingsWindow, plan.diff))
        do {
            configWrites += 1
            try await config.apply(WritePlan.plan(plan.diff, target: configPath,
                                                  stamp: configWrites))
        } catch {
            note("connect failed: \(error)")
            return .failure(.refused("could not write the settings file: \(error)"))
        }
        _ = apply(.configConfirmed(plan.diff))
        // A new ROUTE (and only a new route) invalidates the proof that a hook
        // arrived. Keeping `heardAHook` sticky made repairing a drifted port go
        // straight back to Connected on the strength of a hook from the old port;
        // clearing it on every write dropped a proven connection to "waiting" when
        // only a statusline was added on the same port.
        if routeMoved { heardAHook = false }
        note("connected on 127.0.0.1:\(port)")
        await refreshConnection()
        return .success(plan)
    }

    /// Undo exactly what connecting added, and nothing else.
    ///
    /// **Holds go first.** A session held by a deck that has just removed its
    /// own hooks would wait out its whole budget for a reply that is no longer
    /// coming (the same ordering argument as `delete`).
    @discardableResult
    public func disconnect() async -> Result<ConfigDiff, PortFailure> {
        guard !writingConfig else {
            return .failure(.refused("a settings write is already in progress"))
        }
        writingConfig = true
        defer { writingConfig = false }

        for (hold, continuation) in waiting {
            continuation.resume(returning: HookResponse.decision(
                .release, reason: "the deck was disconnected",
                event: kindOf.removeValue(forKey: hold) ?? .preToolUse))
            waiting[hold] = nil
        }
        guard let document = await config.read().document else {
            return .failure(.malformed("the settings file could not be read"))
        }
        let diff = SettingsMerge.uninstall(from: document, policy: state.policy)
        guard !diff.isNoOp else { await refreshConnection(); return .success(diff) }
        do {
            configWrites += 1
            try await config.apply(WritePlan.plan(diff, target: configPath,
                                                  stamp: configWrites))
        } catch {
            return .failure(.refused("could not write the settings file: \(error)"))
        }
        heardAHook = false
        await refreshConnection()
        return .success(diff)
    }

    /// Whether the user has no statusline of their own.
    ///
    /// The deck WRAPS an existing statusline and only OFFERS to create one:
    /// writing a key the person never had is a consent decision, hence a
    /// checkbox rather than a default. This decides whether the checkbox is
    /// shown at all.
    public private(set) var hasNoStatusline = false

    /// Where the settings live. `internal` so a test can point it somewhere
    /// disposable rather than at the machine's real configuration.
    internal var configPath = NSHomeDirectory() + "/.claude/settings.json"

    /// Test seam: the banner and the card branch on the connection, and a test
    /// must not need a settings file (or a real socket) to reach every branch.
    internal func setConnectionForTesting(_ next: Connection) { connection = next }

    internal func setStatusForTesting(_ next: HookServerStatus) {
        status = next
        recomputeConnection()
    }

    public func stop() async {
        fleetHeartbeat?.cancel()
        fleetHeartbeat = nil
        await server?.stop()
        server = nil
        closeLog()
        status = .stopped
    }

    // ------------------------------------------------------------------ hooks
    /// `internal` rather than private so app-target tests drive the REAL seam.
    /// This method re-stamps the arrived event field by field, and a field it
    /// omits is dropped silently: no test of the reducer or ingest can see it,
    /// because both are correct. `host` and `permissionSuggestions` were each
    /// lost exactly here (see `PermissionWireTests`). The same trap applies to
    /// `rawQuestions` and `questionsUnreadable`, and to the second re-stamping
    /// constructor in `openHold`. When adding a `HookEvent` field, thread it
    /// through both.
    internal func handle(_ event: HookEvent) async -> String {
        let arrived = HookEvent(id: event.id, at: now(), kind: event.kind, session: event.session,
                                cwd: event.cwd, transcriptPath: event.transcriptPath,
                                tool: event.tool, toolUseID: event.toolUseID,
                                held: event.held,
                                subject: event.subject, questions: event.questions,
                                questionsUnreadable: event.questionsUnreadable,
                                rawQuestions: event.rawQuestions,
                                // Thread `answers` through for the same reason as `host` below: a field on
                                // `HookEvent` but not here is invisible to every live hook arrival.
                                answers: event.answers,
                                permissionSuggestions: event.permissionSuggestions,
                                prompt: event.prompt, title: event.title,
                                permissionMode: event.permissionMode,
                                // The host address (workspace, surface). Omitting it left every live lane
                                // with no route, so every action went dark for a reason that was not true.
                                host: event.host)
        // The first hook is proof the connection works. Writing the file only
        // proves the file was written (Claude Code may need a restart to read it),
        // so setup is not "done" until something arrives.
        if !heardAHook { heardAHook = true; recomputeConnection() }
        // Captured, not discarded: `PostToolUse`'s retirement path can produce
        // `.resolveHold(id, .answeredElsewhere)` for a hold that is STILL OPEN
        // (LV38: a human answers in the terminal before the deck's budget
        // elapses). Nothing else would resume that `waiting[id]` continuation, so
        // the terminal's `curl` would stay blocked until the budget timer fired
        // `expire`. Routed here the same way `decide`/`submit`/`expire` route
        // theirs, the connection closes as soon as `PostToolUse` lands.
        let effects = apply(.hook(arrived))
        for effect in effects {
            guard case .resolveHold(let id, let outcome) = effect,
                  let continuation = waiting.removeValue(forKey: id) else { continue }
            note("PostToolUse retired \(id) as \(outcome.logWord) — closing its held connection")
            continuation.resume(returning: HookResponse.decision(
                outcome, reason: "answered elsewhere",
                event: kindOf.removeValue(forKey: id) ?? .preToolUse))
        }
        // A turn that ended is when a queued prompt becomes sendable (LV21: text
        // sent mid-turn is deferred until Stop). Only the kinds that move the idle
        // pair trigger a drain attempt.
        switch arrived.kind {
        case .stop, .sessionStart:
            Task { [weak self] in await self?.drain() }
        default: break
        }
        // The branch is derived, so somebody has to look. Fired for every event
        // carrying a directory, not once per session: `cwd` can change mid-session,
        // and a branch pinned to the first one would be a stale fact.
        if let cwd = arrived.cwd, resolvedCwd[arrived.session] != cwd.value {
            resolvedCwd[arrived.session] = cwd.value
            // Not awaited: the branch is a display fact and the hook response is a
            // person waiting. It arrives as an event whenever it arrives.
            Task { [weak self] in await self?.resolveBranch(for: arrived.session, cwd: cwd.value) }
        }

        // Transcript-well backfill trigger: once per session per launch, on the
        // FIRST hook carrying a `transcriptPath`. Unlike `cwd`, the path is not
        // expected to change mid-session. Reads the event's own copy rather than
        // `state.lanes[...]?.transcriptPath`, since a lane can exist for a while
        // before any hook carries the field, and the read should start as early as
        // possible.
        //
        // The deleted-session rule is checked explicitly here, NOT inherited from
        // `resolveBranch`: a git branch is a filesystem fact, but a transcript is
        // the person's actual conversation (the privacy absolute). Checked against
        // `state.prefs.deleted` AFTER `apply(.hook(arrived))` so it sees whatever
        // this event just changed.
        //
        // Dispatching on the first path-bearing hook only SHRINKS a known race
        // (a live hook in flight may carry a prompt the file's tail also carries);
        // `seedTranscript(for:path:)` documents it in full.
        if let transcriptPath = arrived.transcriptPath,
           !seededTranscriptSessions.contains(arrived.session),
           !state.prefs.deleted.contains(arrived.session.raw) {
            // Marked BEFORE the `Task` starts: set the guard synchronously, race only
            // the read (as with `resolvedCwd` above). See `seededTranscriptSessions`.
            seededTranscriptSessions.insert(arrived.session)
            // Captured into `pendingTranscriptSeedTask` (a test seam; production reads
            // nothing back from it).
            let session = arrived.session
            let path = transcriptPath.value
            pendingTranscriptSeedTask[session] = Task { [weak self] in
                await self?.seedTranscript(for: session, path: path)
            }
        }

        // API-error peek trigger: rides hook arrivals the deck already receives; no
        // file watcher, timer, or poll. A live probe (fake API endpoint forced to
        // fail) found NO hook fires when a turn dies on an API error:
        // `UserPromptSubmit` at T, the synthetic error row on disk at T+0.4s, then
        // silence until a `Notification` with `notification_type: "idle_prompt"` at
        // T+60s, and no `Stop` (in `-p` mode the process just exits, `SessionEnd`
        // without `Stop`). So the deck looks on whichever of these five hook kinds
        // arrives next.
        //
        // `.preToolUse`/`.postToolUse`/`.permissionRequest` are EXCLUDED: they
        // fire mid-turn, where an API error cannot yet be the last word, and they
        // are the most frequent hooks, so peeking on each would add idle file I/O.
        //
        // Known gap: a `Notification` whose type the transition table does not
        // recognise writes no state, so its peek stands on plain dominance and could
        // in principle beat a fresher anchor in the sub-second window before a
        // retry's user row reaches disk. Unreachable with the two types Claude Code
        // sends today, self-healing on the next hook, and a type filter would also
        // filter future error-bearing kinds.
        //
        // One in flight per session (`pendingApiErrorPeekTask`), not once per
        // launch: the session's last word can change between trigger hooks.
        if [.sessionStart, .userPromptSubmit, .notification, .stop, .sessionEnd].contains(arrived.kind),
           let transcriptPath = arrived.transcriptPath,
           !state.prefs.deleted.contains(arrived.session.raw),
           pendingApiErrorPeekTask[arrived.session] == nil {
            let session = arrived.session
            let path = transcriptPath.value
            let triggerAt = arrived.at
            let triggerID = arrived.id
            pendingApiErrorPeekTask[session] = Task { [weak self] in
                await self?.peekTranscript(session: session, path: path, triggerAt: triggerAt, triggerID: triggerID)
                self?.pendingApiErrorPeekTask[session] = nil
            }
        }

        // A deleted session is answered, never held. `HookResponse.none` is "{}"
        // (no opinion), so the call falls through to Claude Code's own permission
        // prompt in its terminal. Going silent instead would leave the session
        // hanging until the hold budget expired, making it worse off for the deck
        // existing. Release is not deny: collapsing them "silently converts I did
        // not answer into I said no".
        //
        // Before the takeover check, so a deleted session cannot open a hold, and
        // before any lane work, so nothing about it is learned.
        if state.prefs.deleted.contains(arrived.session.raw) { return HookResponse.none }

        // A call the ENGINE wants a human for becomes a takeover. Everything else is
        // observed and waved through: the deck is an instrument, not a toll booth
        // (measured live: 94% of human-blocking time was `pwd`, `ls` and `find`,
        // which Claude Code auto-approves anyway).
        //
        // `questionsUnreadable` rides this call: an `AskUserQuestion` the ingest
        // layer could not decode would otherwise pass on its tool name alone and
        // open a hold the deck could only show broken, blocking the terminal for the
        // full budget. `needsAHuman` refuses it here, so the response is `{}` before
        // `openHold` is reached and the terminal sees the question with zero
        // deck-added delay.
        guard let use = arrived.toolUseID,
              HoldPolicy.spec.needsAHuman(kind: arrived.kind, tool: arrived.tool,
                                          permissionMode: arrived.permissionMode,
                                          questionsUnreadable: arrived.questionsUnreadable) else {
            return HookResponse.none
        }
        let hold = HoldID(session: arrived.session, toolUseID: use)
        kindOf[hold] = arrived.kind
        openHold(hold, from: arrived, at: arrived.at)

        // Block the HTTP response until a human decides or the budget runs out.
        // The wait lives in the adapter layer, never in the reducer.
        return await withCheckedContinuation { continuation in
            // Release the one already there, never overwrite it. A hook retried by its
            // transport, or a `PermissionRequest` and `PreToolUse` sharing one
            // toolUseID, arrives twice for one hold. A dropped `CheckedContinuation` is
            // never resumed: that HTTP request would stay open forever. Releasing hands
            // the decision back to the engine's own policy.
            if let orphan = waiting.removeValue(forKey: hold) {
                note("second arrival for \(hold) — releasing the first")
                orphan.resume(returning: HookResponse.decision(
                    .release, reason: "superseded by a second arrival",
                    event: kindOf[hold] ?? .preToolUse))
            }
            waiting[hold] = continuation
            // The hold's OWN budget, frozen on it at `openHold`, not a fresh read of
            // the policy: this timer then answers to the same number as the countdown
            // and the fall-through filter.
            //
            // `nil` is `.untilAnswered`: no timer, and the hold waits as long as the
            // engine's own terminal dialog would.
            if let budgetMs = state.holds[hold]?.budget {
                Task { [weak self] in
                    let budget = UInt64(budgetMs.raw) * 1_000_000
                    // A swallowed `nil` from `Task.sleep` IS cancellation (it throws only on
                    // cancellation), and a cancelled sleeper must RETURN rather than act as if
                    // its deadline elapsed. Never cancelled today; applied uniformly anyway.
                    guard (try? await Task.sleep(nanoseconds: budget)) != nil else { return }
                    self?.expire(hold)
                }
            }
        }
    }

    /// Turn an arrived call into an open hold.
    ///
    /// The synthetic event carries `held: .value(1)` because live the deck is
    /// the thing doing the holding (in replay `held_ms` records the spike's
    /// relay). It also carries the **subject, questions, and permission
    /// suggestions**: a hold opened without them is an armed ALLOW over a blank
    /// well, or a third-option button the frame can never render.
    ///
    /// This is the second of two constructors that re-stamp a `HookEvent` field
    /// by field (`handle` is the first; see its doc for the trap).
    /// `questionsUnreadable` and `rawQuestions` are named for that reason: a hold
    /// without `questionsUnreadable` renders Allow/Deny on a question the deck
    /// could not read; without `rawQuestions`, an answered call re-derives its
    /// `updatedInput` from the deck's lossy model instead of echoing the tool's
    /// own input (see `QuestionCall.rawQuestions`).
    private func openHold(_ hold: HoldID, from event: HookEvent, at: Instant) {
        var seeded = state
        Reducer.reduce(&seeded, .hook(HookEvent(id: EventID("open-\(hold)"), at: at,
                                                kind: .preToolUse, session: hold.session,
                                                cwd: nil, tool: event.tool,
                                                toolUseID: hold.toolUseID,
                                                held: .value(1),
                                                subject: event.subject,
                                                questions: event.questions,
                                                questionsUnreadable: event.questionsUnreadable,
                                                rawQuestions: event.rawQuestions,
                                                permissionSuggestions: event.permissionSuggestions)))
        state = seeded
        refresh()
    }

    /// Ask the worktree port what branch this directory is on, and tell the
    /// reducer the answer, including "none", which is an answer.
    private func resolveBranch(for session: SessionID, cwd: String) async {
        let answer = await worktree.branch(at: cwd)
        apply(.worktree(session, branch: answer, at: now(),
                        id: EventID("branch|\(session.raw)|\(cwd)|\(answer ?? "-")")))
    }

    /// **The transcript-well backfill read: fire-and-forget, off the path
    /// anything waits on, for the same reason as `resolveBranch`.** The hook
    /// response in `handle(_:)` is a person's terminal waiting; blocking it on a
    /// filesystem read would spend the latency budget on history nobody asked to
    /// wait for. The well upgrades from empty to populated whenever this `Task`
    /// finishes, never gating selection or the render already done.
    ///
    /// **Why a ladder.** A 44.2MB transcript from a busy session with subagents
    /// had its nearest genuine human prompt 950KB from EOF. A single fixed 256KB
    /// tail read 51 rows (8 user-role, one `isMeta`, the rest `tool_result`) and
    /// silently seeded ZERO prompts. The filter was right; the READ never reached
    /// them. `LaneRecord.historyCap` is a COUNT (8 prompts), so a fixed byte
    /// count was always a guess. `TranscriptTail.backfillWindows(fileSize:)`
    /// carries the ladder; this function walks it.
    ///
    /// **The walk.** `size(of:)` is asked once, before the first
    /// `tail(of:maxBytes:)`, to build the clamped plan (or the raw ladder if the
    /// size is unknown). Each rung re-reads and re-parses what shallower rungs
    /// covered, deliberately: a superset re-parse is obviously correct
    /// (`humanPrompts(fromJSONL:)` is pure), the walk is off the hot path, and
    /// the worst case (~82MB cumulative, see `TranscriptTail.backfillLadder`) is
    /// a one-off per session per launch. Stitching tails would add permanent
    /// complexity for a saving that matters once.
    ///
    /// `texts` is reassigned whole at every rung, never merged: a wider tail's
    /// parse already contains what a narrower one found. The loop stops when
    /// `texts.count` reaches `LaneRecord.historyCap`, when the rung covered the
    /// WHOLE file (`maxBytes >= fileSize`, if known), or when the ladder runs out
    /// (a giant file whose last 8 prompts sit past the 64MB ceiling seeds fewer
    /// than 8, honestly).
    ///
    /// **Missing or unreadable: seed nothing, and log no path or content.**
    /// `TranscriptFilePort.tail(of:maxBytes:)` collapses every failure (missing,
    /// permission denied, invalid UTF-8) to one `nil`; the well's empty state
    /// already says the honest thing. The one logged line carries the session id
    /// only, never the path (redacted like `cwd`) or any byte of the file. A
    /// failure MID-ladder discards earlier rungs' findings too: the file is in
    /// trouble now, and returning a shallow rung's few prompts would downgrade
    /// "the file broke" into "the file only ever had this many".
    ///
    /// An empty parse (a real file with zero surviving human prompts, e.g. a
    /// session that only ran tool calls) is not a failure and is not noted.
    ///
    /// **Accepted race: the same utterance can land twice.**
    /// `DeckEvent.transcriptSeeded` dedups against what `lane.transcript`
    /// already holds, which covers a live hook arriving first but NOT the
    /// reverse: if this read wins and a `UserPromptSubmit` already in flight for
    /// the same prompt arrives after, the live append has a genuinely different
    /// `at`, so `rememberTranscript`'s dedup key treats it as a new row. The
    /// trigger dispatches on the first path-bearing hook to keep the window
    /// small, but a file read has unbounded latency, and the ladder widens the
    /// window (more time for a live hook to land first). Left declared: the
    /// cost is one duplicate line, while content-based dedup would reopen the
    /// retyped-prompt case already accepted in `DeckState.apply(_:HookEvent)`.
    ///
    /// **Accepted divergence: the seed can show FEWER lines than the live
    /// well.** A live retry fires two `UserPromptSubmit` hooks and the live path
    /// keeps both (a hook carries no `parentUuid`). The file knows they were
    /// siblings, and dead-branch pruning (`TranscriptTail.liveBranches(of:)`)
    /// keeps only the branch the conversation continued from. Only a dead branch
    /// is ever removed.
    private func seedTranscript(for session: SessionID, path: String) async {
        let fileSize = await transcriptFile.size(of: path)
        var texts: [Redacted] = []
        for maxBytes in TranscriptTail.backfillWindows(fileSize: fileSize) {
            guard let raw = await transcriptFile.tail(of: path, maxBytes: maxBytes) else {
                note("transcript backfill: file unreadable for \(session.raw)")
                return
            }
            texts = TranscriptTail.humanPrompts(fromJSONL: raw)
            if texts.count >= LaneRecord.historyCap { break }
            if let fileSize, maxBytes >= fileSize { break }
        }
        guard !texts.isEmpty else { return }
        apply(.transcriptSeeded(session, texts: texts, at: now()))
    }

    /// **The api-error peek: ONE tail read of `TranscriptTail.backfillFloorBytes`,
    /// never the seed's escalating ladder.** An API-error row is the transcript's
    /// newest content (appended the instant the turn dies), so it lives at EOF.
    /// Known gap: a transcript whose trailing window holds no qualifying message
    /// row (e.g. an enormous run of tool output after the error) reads as `nil`
    /// (see `TranscriptTail.apiErrorLastWord(fromJSONL:)`). No escalation: this
    /// trigger fires far more often than the once-per-launch seed, and deeper
    /// reads on ordinary hooks would be exactly the idle I/O to avoid.
    ///
    /// `triggerAt`/`triggerID` are the ARRIVED hook's, never this function's own
    /// moment (see `DeckEvent.apiError`): a found error establishes "as of the
    /// trigger hook, the last word was an API error". Stamped that way, the
    /// reducer's gate (`dominates`, plus the `.idle`-only exception in
    /// `DeckState`'s `.apiError` handler) resolves every race, including the tie
    /// against the trigger's own synchronous write.
    ///
    /// **Two products off ONE read.** The recap
    /// (`TranscriptTail.latestRecap(fromJSONL:)`) lives in the same window and is
    /// wanted on the same five trigger kinds, so a second read would double the
    /// file I/O.
    ///
    /// The recap has the same gap: no `away_summary` row in the window reads as
    /// "no recap", not "look deeper". A recap ages out as the conversation
    /// continues; the ledger keeps the row already recorded
    /// (`rememberTranscript` never un-writes), and the next recap lands inside
    /// the window again.
    ///
    /// **Neither product blocks the other.** No API error is the ORDINARY case,
    /// and an early `return` would make the recap unreachable in healthy sessions.
    private func peekTranscript(session: SessionID, path: String, triggerAt: Instant, triggerID: EventID) async {
        guard let raw = await apiErrorTranscriptFile.tail(of: path, maxBytes: TranscriptTail.backfillFloorBytes) else { return }

        if let found = TranscriptTail.apiErrorLastWord(fromJSONL: raw) {
            apply(.apiError(session, text: found, at: triggerAt, id: triggerID))
        }

        // The recap is placed at its OWN moment, not the trigger's (the opposite of
        // the error above; see `DeckEvent.recap`). `Timestamp.epochMillis(iso:)` is
        // pure integer arithmetic (the core refuses Foundation's date parsers, see
        // `Timestamp.swift`); `epochBaseMillis` rebases it onto this timeline, as
        // `handleStatusline` does for `resets_at`.
        //
        // A recap the deck cannot PLACE is dropped, not guessed at. Both `nil` paths
        // (runtime not started, or unparseable timestamp) mean the deck cannot
        // honestly date the row, and inventing `now()` would date a possibly
        // hours-old summary as current.
        if let recap = TranscriptTail.latestRecap(fromJSONL: raw),
           let base = epochBaseMillis,
           let epoch = Timestamp.epochMillis(iso: recap.iso) {
            apply(.recap(session, text: recap.text,
                         at: Instant(sinceStart: Millis(epoch - base)),
                         id: EventID("recap:\(session.raw)@\(recap.iso)")))
        }
    }

    // -------------------------------------------------------------- statusline
    /// How many statusline readings have arrived this run: what distinguishes
    /// one reading from the next.
    private var statuslineReadings = 0

    /// A statusline render arrived. The payload's `resets_at` epochs become
    /// Instants against THIS runtime's origin (the same seam `HookIngest` owns
    /// for `ts`). The returned text is the terminal's rendered line: composed
    /// from Diagnostic-grade facts only, never payload bytes, and short because
    /// it shares a row with the prompt.
    ///
    /// `internal` rather than `private` like `handle(_:)`: the HTTP server binds
    /// this closure at `start()` and cannot run headless, so this is the
    /// narrowest seam a test can call (`InvalidationTests` pins whether a no-op
    /// reading repaints the fleet).
    internal func handleStatusline(_ json: JSONValue) async -> String {
        guard let epochBase = epochBaseMillis else { return "" }
        guard let payload = StatuslineIngest.payload(from: json, epochBase: epochBase)
        else { return "" }
        let at = now()
        // Sequenced like the fleet poll. A hook event's id can be derived from the
        // ROW (same row, same id, which is the wire's idempotence), but a statusline
        // id built from the runtime's clock made two different readings in one
        // millisecond collapse into one event. Contemporary readings are not
        // duplicates.
        statuslineReadings += 1
        apply(.statusline(payload, at: at,
                          id: EventID(String(format: "statusline|%@|%09d",
                                             payload.session.raw, statuslineReadings))))
        scheduleUsageReset()
        if let usage = frame.usage { return usage.limited ? "◆ deck · \(usage.label)" : "◆ deck" }
        return "◆ deck"
    }

    /// The one timer the idle-CPU rule sanctions for the dot (`usage-reset` in
    /// `scheduledWork`): the feed goes quiet at the limit, so nothing else will
    /// flip it green when the deadline passes. Deduplicated per deadline so
    /// re-renders while limited cannot stack sleepers.
    private var scheduledReset: Instant?
    private func scheduleUsageReset() {
        guard let resetsAt = frame.usage?.resetsAt, scheduledReset != resetsAt else { return }
        scheduledReset = resetsAt
        let waitMs = max(resetsAt.sinceStart.raw - now().sinceStart.raw, 0) + 100
        Task { [weak self] in
            // See THE LAW in `scheduleReadinessWatch`. Never re-armed against a shorter
            // deadline, so no known live cancellation path; applied anyway.
            guard (try? await Task.sleep(for: .milliseconds(waitMs))) != nil else { return }
            guard let self else { return }
            self.scheduledReset = nil
            self.refresh()
            // The window has opened, so whatever was held for it may go now. Without
            // this a queued Continue would sit until the next hook arrived, which at a
            // usage limit is exactly when nothing is arriving.
            await self.drain()
        }
    }

    /// The second timer the idle-CPU rule sanctions. The stall notice is derived
    /// from the clock, and a WEDGED session emits no further hooks, so without
    /// one wake the case the notice exists for would never draw it. Scheduled
    /// only while `scheduledWork` says a queue is waiting on a busy session, and
    /// deduplicated so a busy session's hooks cannot stack sleepers.
    private var stallWatchScheduled = false
    private func scheduleStallWatch() {
        guard state.scheduledWork.contains(TimerID("stall-watch")),
              !stallWatchScheduled else { return }
        stallWatchScheduled = true
        Task { [weak self] in
            // See THE LAW in `scheduleReadinessWatch`. Not re-armed against a shorter
            // deadline, so no known live cancellation path; applied anyway.
            guard (try? await Task.sleep(for: .milliseconds(DeckState.stallGrace.raw + 100))) != nil
            else { return }
            guard let self else { return }
            self.stallWatchScheduled = false
            self.refresh()
            self.scheduleStallWatch()
        }
    }

    // --------------------------------------------------------- readiness gate

    /// **The two bounded timers that promote a `.released` mirror to
    /// `.terminalLive` without waiting on the ceremony pair.**
    /// `HoldPolicy.permissionRequestAllowance`/`.noSignalAllowance` carry the
    /// derivation, the fixture evidence for each number, and why the two combine
    /// as a MINIMUM.
    ///
    /// **THE LAW for every `Task.sleep` in this file:** `Task.sleep` throws ONLY
    /// on cancellation, so a swallowed `try?` returning `nil` IS cancellation. A
    /// cancelled sleeper must RETURN rather than fall through and act as if its
    /// deadline had elapsed (see the 78ms promotion described below). Every
    /// sleep site uses `guard (try? await Task.sleep(...)) != nil else { return }`.
    ///
    /// Called from `apply(_:)`'s choke point and re-derived from CURRENT state
    /// after every event (like `scheduleStallWatch`), not fired from one event:
    /// a mirror can become `.released` through three reducer cases
    /// (`releaseMirrorIfAny`, `DeckState.swift`), and a scheduler keyed to one
    /// would miss the others. Deduplicated per hold against `readinessDeadline`,
    /// the same dedup-by-deadline shape as `scheduleUsageReset`.
    private func scheduleReadinessWatch() {
        // Bounded memory: an id that left `.released` by ANY door (the ceremony
        // pair, a resolution, or one of these two signals winning) drops its
        // tracked deadline on the next run.
        for id in readinessDeadline.keys where !isReleased(id) {
            readinessDeadline[id] = nil
        }
        for (id, mirror) in state.mirrors {
            guard case .released(let releasedAt) = mirror.stage else { continue }
            let noSignalDeadline = releasedAt.advanced(by: state.policy.noSignalAllowance)
            let deadline: Instant
            if let seenAt = mirror.permissionRequestSeenAt {
                // The shorter allowance is a BONUS for early proof, never a second wait
                // stacked on the first (see `HoldPolicy.permissionRequestAllowance`).
                deadline = min(noSignalDeadline,
                               seenAt.advanced(by: state.policy.permissionRequestAllowance))
            } else {
                deadline = noSignalDeadline
            }
            if readinessDeadline[id] != deadline {
                readinessDeadline[id] = deadline
                let waitMs = max(deadline.sinceStart.raw - now().sinceStart.raw, 0)
                // Cancel the superseded sleeper. The `.released` check below cannot tell
                // "my deadline elapsed" from "I was cancelled and `try?` swallowed it":
                // both reach the same guard, which the mirror still passes. A
                // `PermissionRequest` ~70ms after release shortens this deadline and
                // cancels the old 20s sleeper; before THE LAW the swallowed cancellation
                // fired `.mirrorReadinessElapsed` at once (promotion 78ms after release,
                // 15+ seconds early). `.cancel()` is necessary but not sufficient; THE LAW
                // inside the closure is what stops the fall-through.
                pendingReadinessTask[id]?.cancel()
                pendingReadinessTask[id] = Task { [weak self] in
                    // THE LAW: `nil` here IS cancellation, never a signal to proceed.
                    guard (try? await Task.sleep(for: .milliseconds(waitMs))) != nil else { return }
                    guard let self else { return }
                    self.pendingReadinessTask[id] = nil
                    guard case .released? = self.state.mirrors[id]?.stage else { return }
                    self.apply(.mirrorReadinessElapsed(id, at: self.now()))
                }
            }
            // One attempt, ever, per mirror; the timer above is the fallback this can
            // only beat, never replace.
            if screenObservationAttempted.insert(id).inserted,
               let questionText = mirror.call.questions.first?.text.value {
                pendingScreenObservationTask[id] = Task { [weak self] in
                    await self?.attemptScreenObservation(for: id, question: questionText)
                    self?.pendingScreenObservationTask[id] = nil
                }
            }
        }
    }

    private func isReleased(_ id: HoldID) -> Bool {
        if case .released? = state.mirrors[id]?.stage { return true }
        return false
    }

    /// **The readiness gate's strongest signal.** Bounded reads of the
    /// terminal's screen (`SessionHostPort.read`, the same call
    /// `runForwardPlan` and `drain()` use) looking for the question's text. A
    /// FIXED number of reads, not a polling loop; then it gives up and leaves the
    /// timers in `scheduleReadinessWatch` to decide.
    ///
    /// **Four attempts, not two.** Two (0s, 3s) gave up before the picker's
    /// measured render lag (~7s; `HoldPolicy.permissionRequestAllowance` cites
    /// `LV38-question-mirror-latency-control`'s 6.021s `PermissionRequest` ->
    /// `Notification` gap), so it could never catch the common case. Four reads
    /// at `screenObservationRetryDelay` (3s) apart (0s, 3s, 6s, 9s) straddle
    /// that figure at a still-bounded cost.
    ///
    /// Every failure is silent by design (no route, no matching session, a
    /// failed read, text not there yet): this is a bonus proof the timers will
    /// supply anyway, so nothing here darkens a control.
    ///
    /// One false positive: the question's text in scrollback (an assistant
    /// preamble quoting it) before the picker renders promotes the mirror early.
    /// The backstop is the awaiting-confirmation state
    /// (`MirrorView.awaitingConfirmation`): a tap forwarded at a picker that is
    /// not there yet produces no `PostToolUse`, the mirror reads "Answer sent,
    /// waiting for the terminal", and cannot be tapped again until confirmation
    /// arrives or the person asks to send again.
    private static let screenObservationAttempts = 4
    private func attemptScreenObservation(for id: HoldID, question: String) async {
        for attempt in 0..<Self.screenObservationAttempts {
            if attempt > 0 {
                // See THE LAW in `scheduleReadinessWatch`. Never explicitly cancelled today
                // (the outer task is dispatched once per mirror); applied anyway.
                guard (try? await Task.sleep(for: .milliseconds(state.policy.screenObservationRetryDelay.raw))) != nil
                else { return }
            }
            guard case .released? = state.mirrors[id]?.stage else { return }
            guard let reported = state.lanes[id.session]?.host?.value else { continue }
            guard case .success(let sessions) = await host.inventory(),
                  let match = sessions.first(where: { $0.identifies(reported) }) else { continue }
            guard case .success(let screen) = await host.read(match.address, lines: 60) else { continue }
            if screen.contains(question) {
                guard case .released? = state.mirrors[id]?.stage else { return }
                apply(.mirrorObservedLive(id, at: now()))
                return
            }
        }
    }

    /// **Trigger for forward recovery.** Called from `runForwardPlan` when its
    /// plan disappears from `state.forwarding`, which happens when
    /// `forwardStepSent` marks the LAST step sent (`ForwardPlan.isComplete`).
    /// `HoldPolicy.forwardLandingAllowance` explains why cmux's `.sent` is not
    /// the proof this waits for. This is what makes the two bounded promotions
    /// above safe to be aggressive about: a tap that landed on a picker not yet
    /// ready is recoverable rather than silent.
    ///
    /// **Cancel before replacing.** A plain dictionary write does not stop a
    /// `Task` already in flight; it only stops anything finding it again. A
    /// second tap while the first watch was counting down left both running, and
    /// each completing plan armed its own 5s watch (two `forwardDidNotLand`
    /// lines 1.2s apart).
    private func scheduleForwardLandingWatch(_ hold: HoldID) {
        let waitMs = state.policy.forwardLandingAllowance.raw
        pendingForwardLandingTask[hold]?.cancel()
        pendingForwardLandingTask[hold] = Task { [weak self] in
            // See THE LAW in `scheduleReadinessWatch`.
            guard (try? await Task.sleep(for: .milliseconds(waitMs))) != nil else { return }
            guard let self else { return }
            self.pendingForwardLandingTask[hold] = nil
            guard case .terminalLive? = self.state.mirrors[hold]?.stage else { return }
            self.apply(.forwardUnconfirmed(hold, at: self.now()))
        }
    }

    // ------------------------------------------------- resolved-mirror linger

    /// **Wakes the UI when a resolved mirror's linger elapses.**
    /// `Projection.frame`'s `projectsMirror` is a PURE function of `at`, so a
    /// quiet session (no hooks once the answer lands) emits no event when
    /// `HoldPolicy.resolvedMirrorLinger` elapses. Without a timer the card is
    /// aged out by the predicate but never re-RENDERED, and sits stale on the
    /// glass, hiding the transcript well that already carries the answer. Same
    /// idle-CPU-sanctioned shape as `scheduleUsageReset`: dedup per deadline
    /// (ONE sleeper, not one per mirror), `refresh()` on wake, and re-derived
    /// from CURRENT state on every `apply(_:)` (alongside
    /// `scheduleReadinessWatch`) so a second mirror resolving before the first
    /// elapses does not orphan the first's wake.
    ///
    /// **`internal` so a test can pin the deadline field.** A CPU-spin defect
    /// here (a past deadline endlessly rediscovering itself) is a sequence of
    /// correctly-behaved short sleeps, not a swallowed cancellation, and is
    /// invisible to any test that only observes the FRAME. Exposing the field
    /// lets a test assert "an aged-out mirror never re-arms the sleeper".
    /// Production never reads it for a decision; only
    /// `scheduleMirrorLingerSweep` (also `internal`, so a test can call it twice
    /// without another `apply(_:)`) writes and compares it.
    internal var scheduledMirrorLingerDeadline: Instant?
    internal func scheduleMirrorLingerSweep() {
        // The EARLIEST deadline among mirrors still projecting as `.resolved`.
        // Once it elapses and `refresh()` re-renders, mirrors that aged out simply
        // stop projecting (`projectsMirror`'s `<=` check) and the recursive call
        // re-derives the next deadline, if any.
        //
        // PAST deadlines are excluded: `state.mirrors` keeps a resolved mirror until
        // the 20-minute hold sweep (`HoldPolicy.resolvedMirrorLinger`), so without
        // the exclusion the same past deadline is rediscovered on every recursive
        // re-derive, clamps to the `+ 50` floor, and re-arms every 50ms (a 20Hz CPU
        // spin for up to 20 minutes per resolved mirror). A past deadline needs no
        // wake: every `refresh()` renders with the CURRENT `at`, so the mirror is
        // already read as aged out. The wake exists to GUARANTEE a next frame for a
        // QUIET session, not to re-confirm a fact already true.
        let currentNow = now()
        let deadline = state.mirrors.values.compactMap { mirror -> Instant? in
            guard case .resolved(_, _, let resolvedAt) = mirror.stage else { return nil }
            let candidate = resolvedAt.advanced(by: state.policy.resolvedMirrorLinger)
            return candidate > currentNow ? candidate : nil
        }.min()
        guard let deadline else {
            scheduledMirrorLingerDeadline = nil
            return
        }
        guard scheduledMirrorLingerDeadline != deadline else { return }
        scheduledMirrorLingerDeadline = deadline
        let waitMs = max(deadline.sinceStart.raw - now().sinceStart.raw, 0) + 50
        Task { [weak self] in
            // See THE LAW in `scheduleReadinessWatch`.
            guard (try? await Task.sleep(for: .milliseconds(waitMs))) != nil else { return }
            guard let self else { return }
            self.scheduledMirrorLingerDeadline = nil
            self.refresh()
            self.scheduleMirrorLingerSweep()
        }
    }

    // ------------------------------------------------------------ navigation
    /// Back from a question step. A gesture handed to the reducer, which owns
    /// every refusal (step 0, a closed hold, a re-arm window). The runtime adds
    /// nothing but the clock.
    public func stepBack(_ hold: HoldID) { apply(.questionSteppedBack(hold, at: now())) }

    // -------------------------------------------------------- quick actions
    /// A lane was tapped with nothing waiting on it. Display only (the reducer
    /// emits nothing), but it is also when the deck finds out whether it can
    /// speak to that session, so the panel opens saying the truth.
    public func select(_ session: SessionID) {
        apply(.sessionSelected(session, at: now()))
        Task { [weak self] in await self?.probeHost() }
    }


    /// Esc, Cmd-[, or the panel's back control. **One event**; the reducer owns
    /// the precedence (a question stepper first, then the selection). A view
    /// cannot know which is open, and duplicating that predicate outside the
    /// reducer lets places disagree about the front.
    public func dismiss() { apply(.dismissRequested(at: now())) }

    /// A person tapped an action. It joins the selected session's queue and the
    /// runtime tries to drain, which may find the session mid-turn and leave it
    /// queued, visibly.
    public func queue(_ action: QuickAction) {
        guard let session = state.selected else { return }
        apply(.actionQueued(session, action, at: now()))
        Task { [weak self] in await self?.drain() }
    }

    /// A pending action tapped again: take it back. The deck's only undo short
    /// of sending an interrupt.
    public func cancel(_ action: QuickAction) {
        guard let session = state.selected else { return }
        apply(.actionCancelled(session, actionID: action.id, at: now()))
    }

    /// Discard everything not yet on the wire. What was sent stays: it cannot be
    /// recalled and the deck still needs its receipt.
    public func clearQueue() {
        guard let session = state.selected else { return }
        apply(.queueCleared(session, at: now()))
    }

    /// Can the host be reached at all? The darkened-control rule: the deck says
    /// why a control is dark, and this finds out before anybody taps one. One
    /// local call on a user gesture, not a poll (the idle-CPU rule counts timers).
    private func probeHost() async {
        switch await host.inventory() {
        case .success(let sessions):
            hostSessions = sessions
            apply(.actionBlocked(nil, nil, at: now()))
        case .failure(let failure):
            hostSessions = []
            apply(.actionBlocked(nil, Self.block(for: failure), at: now()))
            // Log the ADAPTER's sentence, not the enum's name. `ActionBlock` is narrowed
            // to keep a path out of the FRAME; the log is the other audience (someone
            // debugging a dark control) and gets the whole thing.
            note("host unavailable: \(Self.reason(failure))")
        }
    }

    /// The adapter's own words, for the log only.
    private static func reason(_ failure: PortFailure) -> String {
        switch failure {
        case .unavailable(let why), .refused(let why), .malformed(let why): return why
        }
    }

    /// The adapter's failure, narrowed to what the core may hold. The adapter's
    /// sentence (which names the app and the setting to change) goes to the log;
    /// `ActionBlock` is a closed enum so a path in a host's stderr cannot ride
    /// into a frame.
    private static func block(for failure: PortFailure) -> ActionBlock {
        switch failure {
        case .unavailable: return .hostUnavailable
        case .refused:     return .unroutable
        case .malformed:   return .hostError
        }
    }

    /// Put the next queued action on the wire, if the core says there is one.
    ///
    /// **The reducer never emits a send**: a send effect produced by a wire event
    /// would make the reducer's output depend on arrival order, and
    /// `ReplayTests` compares whole states across every permutation. The core
    /// answers "what next", the runtime acts, and the runtime reports back.
    ///
    /// One at a time, and re-entered after each send rather than looped: every
    /// send changes what the core would answer next, and a loop reading a
    /// snapshot would send into a state that no longer exists.
    ///
    /// **Every branch that darkens a control also NOTES why**, in the adapter's
    /// or reducer's own words and never the screen text (the privacy absolute),
    /// so the log explains a dark control beyond the closed `ActionBlock` enum
    /// on the frame (see `Diagnostics.swift`).
    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }

        guard let next = state.nextSend(at: now()) else { return }
        guard let reported = state.lanes[next.session]?.host?.value else {
            note("action blocked: unroutable (lane has no host address) session=\(next.session.raw)")
            apply(.actionBlocked(next.session, .unroutable, at: now()))
            return
        }

        // The target must still be in the host's inventory. Asked fresh rather than
        // trusted from the last probe: a surface the person closed thirty seconds
        // ago is exactly what a cached inventory would send to.
        //
        // The host decides whether these are the same session, and the address it
        // reports is the one used from here down. `reported` came from the hook
        // (the session's environment); the inventory came from the host's listing.
        // On cmux those are two names for one surface (LV32), so a plain `==`
        // refused every send as unroutable. Canonicalising also means one naming
        // system reaches the wire.
        let address: SessionAddress
        switch await host.inventory() {
        case .failure(let failure):
            let block = Self.block(for: failure)
            note("action blocked: \(block.rawValue) (inventory failed: \(Self.reason(failure)))")
            apply(.actionBlocked(nil, block, at: now()))
            return
        case .success(let sessions):
            hostSessions = sessions
            guard let match = sessions.first(where: { $0.identifies(reported) }) else {
                note("action blocked: unroutable (address not in host inventory) session=\(next.session.raw)")
                apply(.actionBlocked(next.session, .unroutable, at: now()))
                return
            }
            address = match.address
        }

        let outcome: SendOutcome
        switch next.action.kind {
        case .escape:
            // An interrupt does not type, so it does not read first: its purpose is to
            // stop what is happening, and a composer check would refuse it in exactly
            // the state it is wanted (measured on a background surface, LV30).
            outcome = await host.sendKey("escape", to: address)
        case .dialogKey(let key):
            // A dialog key does not type either: the screen IS the dialog this key
            // answers, and reading it first would refuse the send for showing what it
            // is supposed to. `Composer.read` treats ANY line beginning with the
            // composer's `❯` glyph as a draft, and Claude Code's numbered dialog renders
            // its selected option behind that same cursor ("❯ 1. Yes"), so a composer
            // gate would read `.holdingText` over a dialog. This path skips the gate
            // entirely, with no `host.read`, like `.escape`.
            // Digits go through `send`, not `send-key`: tapping "2. Yes, and don't ask
            // again" failed with `send-key failed: ... Unknown key` because cmux
            // `send-key` rejects digit keys. `send` writes the digit as pty bytes, which
            // the dialog receives identically (`send-key` is for keys with no byte form,
            // like arrows).
            outcome = await host.send(key, to: address)
        case .prompt:
            // Read BEFORE writing. LV23: a draft in the composer splices onto the
            // deck's text and arrives as one prompt. LV30: a surface that is not a
            // session at all would run the deck's prompt as a shell command.
            switch await host.read(address, lines: 40) {
            case .failure(let failure):
                let block = Self.block(for: failure)
                note("action blocked: \(block.rawValue) (read-screen failed: \(Self.reason(failure))) session=\(next.session.raw)")
                apply(.actionBlocked(next.session, block, at: now()))
                return
            case .success(let screen):
                // The screen is judged and dropped in one expression. It is the densest
                // payload in this system and nothing keeps a reference to it (redaction by
                // construction). `reading` is a `Composer.Reading` CASE, never the screen
                // text, so the note below can say why the deck refused without ever holding
                // the screen.
                let reading = Composer.read(screen)
                if let blocked = Composer.block(for: reading) {
                    note("action blocked: \(blocked.rawValue) (composer read \(reading.rawValue)) session=\(next.session.raw)")
                    apply(.actionBlocked(next.session, blocked, at: now()))
                    return
                }
            }
            guard let text = next.action.payload else { return }
            switch await host.send(text, to: address) {
            case .sent:
                // Text and submit stay two decisions, so the newline is its own call. A
                // send whose Enter failed leaves a composer holding the deck's own text:
                // reported, not retried, because a retry would type it twice.
                outcome = await host.sendKey("enter", to: address)
            case let other: outcome = other
            }
        }

        switch outcome {
        case .sent:
            apply(.actionSent(next.session, actionID: next.action.id, at: now()))
            // Sending changes what the core would send next (a stacked
            // Compact-then-Continue is two passes, and the second waits for the first
            // to be witnessed).
            draining = false
            await drain()
        case .unavailable(let why):
            note("send unavailable: \(why)")
            apply(.actionBlocked(nil, .hostUnavailable, at: now()))
        case .failed(let why):
            note("send failed: \(why)")
            apply(.actionBlocked(next.session, .hostError, at: now()))
        }
    }

    private var draining = false
    /// The host's inventory as of the last ask. Display and routing only; never
    /// a substitute for asking before a send.
    public private(set) var hostSessions: [HostSession] = []


    /// The title bar's height, approximated: the tolerance below which the
    /// window's top edge (`maxY`, where the title bar sits; AppKit's y-axis runs
    /// bottom-up) counts as sunk out of reach at the bottom. Not measured, same
    /// status as `QuestionOptionsBand.usableStripHeight`: `.unifiedCompact`
    /// reserves roughly this much (`DeckScene`), and "roughly" is enough for a
    /// tolerance that only decides WHETHER to nudge.
    static let grabHeight: CGFloat = 38

    /// The traffic-light cluster's width, approximated the same way: the
    /// tolerance below which the window's left edge (`origin.x`) counts as slid
    /// out of reach on the right.
    static let grabWidth: CGFloat = 80

    /// The frame a window should take: position nudged into `visible`,
    /// **size never touched.**
    ///
    /// Product law: the deck never changes its own window SIZE on its own, not
    /// on a screen change, not to "fit", with no hard caps. Only a user action
    /// (dragging an edge, Settings -> "Apply Now") resizes. A window bigger than
    /// its screen stays bigger.
    ///
    /// What can be fixed is the ORIGIN: a window restored at 1995 x 575 from a
    /// built-in display and moved to a 1920 x 480 panel can sit with its title
    /// bar off the glass, and AppKit hands the deck a frame, not a verdict on
    /// whether it is reachable. Sliding it back is safe in a way shrinking never
    /// is.
    ///
    /// **Nudge on UNREACHABILITY, not on any deviation from a corner.** Clamping
    /// unconditionally whenever the frame did not fit `visible` exactly would
    /// yank an overtall window whose title bar is already on-glass, or an
    /// overwide one ten points in from the left, and since `fitTriggers`
    /// includes `didChangeScreenParametersNotification` (dock toggle, resolution
    /// change) the deck would re-fight the user on every one. So each axis asks
    /// whether the part of the title bar the user grabs is still on the visible
    /// screen, and nudges only when it is not, exactly as far as makes it so:
    ///   - **x** (traffic lights, left): unreachable if `origin.x < visible.minX`
    ///     (no tolerance for the corner itself) or `origin.x > visible.maxX -
    ///     grabWidth` (not even a `grabWidth` sliver remains).
    ///   - **y** (title bar, top; `maxY` since AppKit's y-axis runs bottom-up):
    ///     unreachable if `maxY > visible.maxY` or `maxY < visible.minY +
    ///     grabHeight`.
    ///
    /// **Pure, so it can be tested.** A frame failing neither condition comes
    /// back identical, and the function is idempotent: nudging lands exactly on
    /// the tolerance boundary, on the reachable side, so a second pass finds
    /// nothing to do.
    static func fitted(_ frame: CGRect, in visible: CGRect) -> CGRect {
        // A visible frame too small for either tolerance would make an axis's two
        // conditions overlap and the nudge alternate between them, breaking
        // idempotence. No real `NSScreen.visibleFrame` is sub-80x38; this guards the
        // promise, not a screen that exists.
        guard visible.width >= grabWidth, visible.height >= grabHeight else { return frame }
        var out = frame
        if out.origin.x < visible.minX {
            out.origin.x = visible.minX
        } else if out.origin.x > visible.maxX - grabWidth {
            out.origin.x = visible.maxX - grabWidth
        }
        if out.maxY > visible.maxY {
            out.origin.y = visible.maxY - out.height
        } else if out.maxY < visible.minY + grabHeight {
            out.origin.y = visible.minY + grabHeight - out.height
        }
        return out
    }

    /// **When the deck checks that it still fits.**
    ///
    /// Do NOT watch `didMoveNotification` or `didResizeNotification`: doing so
    /// crashed the app minutes into a first run on the strip panel:
    ///
    ///     -[NSWindow(NSDisplayCycle) _postWindowNeedsUpdateConstraints]
    ///     ... NSHostingView.updateConstraints
    ///     EXC_BREAKPOINT  +[NSApplication _crashOnException:]
    ///
    /// `setFrame` posts `didResize`, so calling it from inside that notification
    /// re-enters AppKit's layout while SwiftUI's hosting view is mid-
    /// `updateConstraints`; AppKit throws and macOS 26 crashes on an exception
    /// raised inside the display cycle. A `target != window.frame` guard stops an
    /// infinite loop but not the re-entrancy.
    ///
    /// Two rules, both needed:
    ///   - a resize or drag is the USER's business, so only watch the two
    ///     moments a window can land somewhere it does not fit: another screen,
    ///     or the displays themselves changing;
    ///   - push the work to the next run-loop turn, so it never executes inside
    ///     a constraint pass, whoever posted the notification.
    static let fitTriggers: [Notification.Name] = [
        NSWindow.didChangeScreenNotification,
        NSApplication.didChangeScreenParametersNotification,
    ]

    /// What a fit should do. **Pure, so the guard against the crash can be
    /// tested**: `fitWindow` itself needs a window, a hosting view and a display
    /// cycle.
    ///
    /// `.reposition`, not `.resize`: `fitted` never changes a window's size, so
    /// the returned frame differs from the input by origin alone.
    enum Fit: Equatable {
        case leaveAlone
        case reposition(CGRect)
    }

    static func fitDecision(frame: CGRect, visible: CGRect, isFitting: Bool) -> Fit {
        // A second fit begun inside the first is the shape of the crash: `setFrame`
        // posts notifications, and acting on one while still inside the call that
        // caused it re-enters AppKit's layout.
        guard !isFitting else { return .leaveAlone }
        let target = fitted(frame, in: visible)
        // A window that already fits is never touched; a fitter that always moved
        // something would fight the user every time they positioned it.
        return target == frame ? .leaveAlone : .reposition(target)
    }

    /// **The deck's own window, by identity.** Not "the first visible window
    /// with a content view": `NSApplication.windows` has no documented order and
    /// the Settings window satisfies that too (minimise the deck, open Settings,
    /// tap Apply Now, and Settings would be resized and its size stored as the
    /// deck's default). The scene declares `id: "deck"`, which SwiftUI hands to
    /// the window as its identifier; the title is the fallback.
    internal static let windowID = "deck"
    internal static let windowTitle = "Open Agent Deck"

    /// What a window looks like to the chooser below: the three facts the
    /// decision turns on (an `NSWindow` cannot be built in a test).
    struct WindowFacts: Equatable {
        let identifier: String?
        let title: String
        let hasContent: Bool
        init(identifier: String? = nil, title: String = "", hasContent: Bool = true) {
            self.identifier = identifier; self.title = title; self.hasContent = hasContent
        }
    }

    /// **Which of these is the deck's window.** Pure, so the rule can be tested
    /// without AppKit.
    ///
    /// By identity first (SwiftUI derives the identifier from the scene's `id`,
    /// suffixing it, e.g. `deck-AppWindow-1`), then by title for a window the
    /// identifier does not reach.
    static func chooseWindow(among windows: [WindowFacts]) -> Int? {
        let usable = windows.enumerated().filter { $0.element.hasContent }
        return usable.first { $0.element.identifier?.hasPrefix(windowID) == true }?.offset
            ?? usable.first { $0.element.title == windowTitle }?.offset
    }

    internal func deckWindow() -> NSWindow? {
        let windows = NSApplication.shared.windows
        let facts = windows.map {
            WindowFacts(identifier: $0.identifier?.rawValue, title: $0.title,
                        hasContent: $0.contentView != nil)
        }
        return Self.chooseWindow(among: facts).map { windows[$0] }
    }

    /// Keep the deck's title bar reachable on the screen it is on, never its
    /// size (see `fitted`). Always called asynchronously (see `fitTriggers`).
    internal func fitWindow() {
        guard let window = deckWindow(), window.isVisible,
              let screen = window.screen else { return }
        guard case .reposition(let target) = Self.fitDecision(
            frame: window.frame, visible: screen.visibleFrame, isFitting: fitting)
        else { return }
        fitting = true
        defer { fitting = false }
        // `setFrame` sets origin and size, but `target`'s size is always
        // `window.frame`'s own, so this is a move, not a resize.
        window.setFrame(target, display: true)
    }

    /// The deck's window content region as a canvas, read by the settings pane's
    /// "Use Current Size". nil headless or with the deck minimised; nil disables
    /// the control rather than inventing a number.
    public func currentWindowSize() -> Canvas? {
        guard let window = deckWindow(), window.isVisible,
              let content = window.contentView else { return nil }
        return Canvas(width: Int(content.frame.width), height: Int(content.frame.height))
    }

    /// Whether there is a deck window to resize: what "Apply Now" needs, and
    /// what disables it when there is not.
    public var hasDeckWindow: Bool { deckWindow()?.isVisible == true }

    /// Resize the live window (the settings pane's "Apply Now").
    ///
    /// `defaultSize` is consulted only on a launch with no remembered frame;
    /// macOS restores the rest, so without this a size preference would read as
    /// stored-but-ignored. This call IS the user resizing, so the fit afterwards
    /// only repositions: asked for 800 tall on the 480 strip, the answer is 800
    /// tall, and if the title bar lands off the strip the fit nudges the window
    /// back into reach without touching the size.
    public func applyWindowSize(_ size: Canvas) {
        guard let window = deckWindow(), window.isVisible else { return }
        window.setContentSize(NSSize(width: size.width, height: size.height))
        DispatchQueue.main.async { MainActor.assumeIsolated { self.fitWindow() } }
    }

    public func decide(_ hold: HoldID, _ resolution: Resolution) {
        // Read the hold's raw suggestions BEFORE `apply` resolves it: a resolved
        // hold becomes eligible for `sweepHolds`'s amortised reclaim, so a later
        // read could find nothing (same "read before the state that clears it
        // moves on" ordering as `submit`). nil for every resolution but
        // `allowAndRemember`, where the encoder needs it to pick the tapped element.
        let suggestions = state.holds[hold]?.suggestions
        note("tap \(resolution.logWord) on \(hold) waiting=\(waiting.count) open=\(state.holds.values.filter(\.isOpen).count)")
        let effects = apply(.decision(hold, resolution, at: now()))
        note("tap produced \(effects.count) effect(s)")
        for effect in effects {
            guard case .resolveHold(let id, let outcome) = effect,
                  let continuation = waiting.removeValue(forKey: id) else { continue }
            // A stale index (the suggestions changed shape between the frame that drew
            // the button and the tap, or the hold had none) is not allowed to fail
            // silently. `HookResponse.decision` degrades `allowAndRemember` to a plain
            // allow when the index does not resolve; this is the loud half of that
            // degrade, so anybody can learn it happened.
            if case .allowAndRemember(let index) = outcome {
                let count = suggestions?.arrayValue?.count ?? 0
                if !(suggestions?.arrayValue?.indices.contains(index) ?? false) {
                    note("allowAndRemember index \(index) out of range (\(count) suggestions) "
                        + "— degrading to allow")
                }
            }
            // The kind goes with the continuation. Dropping it only in `delete` (the
            // rarest resolution path) leaked one permanent entry per answered
            // permission.
            continuation.resume(returning: HookResponse.decision(
                outcome, reason: "deck", event: kindOf.removeValue(forKey: id) ?? .preToolUse,
                suggestions: suggestions))
        }
    }

    /// Which event opened each hold. `PermissionRequest` and `PreToolUse` take
    /// **different response shapes** (`decision.behavior` against
    /// `permissionDecision`), and answering one in the other's form is rejected
    /// silently, which would look exactly like the deck being ignored.
    private var kindOf: [HoldID: HookKind] = [:]

    /// The user answered a question call.
    ///
    /// The all-or-nothing rule lives in the reducer, not here: a partial
    /// submission produces no effects, so this loop finds nothing to resume and
    /// the hold stays open. A view cannot talk the wire into accepting
    /// something the rule refuses.
    public func pick(_ hold: HoldID, _ label: Redacted) {
        submit(.questionPicked(hold, label: label, at: now()), for: hold)
    }

    public func commit(_ hold: HoldID) {
        submit(.questionCommitted(hold, at: now()), for: hold)
    }

    /// The user typed an answer instead of tapping an offered option (the
    /// terminal's own "Other..." escape).
    ///
    /// `step` is a PARAMETER, not read off live state. Reading
    /// `state.answering[hold]?.step` here would make the reducer's
    /// `progress.step == step` guard unfalsifiable (both sides read the same
    /// fresh state), so a racing step change could never be caught.
    /// `OtherAnswerField` captures its step at render time (the same value its
    /// `.id()` keys on); threading that through lets the reducer refuse a stale
    /// submit.
    ///
    /// `text` becomes `Redacted` here: `Redacted(optional:)` fails to construct
    /// for blank or whitespace-only text, so a blank field never reaches
    /// `submit` and the reducer needs no second guard.
    public func answerFreely(_ hold: HoldID, _ text: String, step: Int) {
        guard let typed = Redacted(optional: text) else { return }
        submit(.questionAnsweredFreely(hold, step: step, text: typed, at: now()), for: hold)
    }

    private func submit(_ event: DeckEvent, for hold: HoldID) {
        // Read the call BEFORE reducing: a submission clears it, and the wire form
        // needs the questions echoed back beside the answers.
        let call = state.questions[hold]
        let effects = apply(event)
        for effect in effects {
            guard case .updatedInput(let id, let answers) = effect,
                  let call, let continuation = waiting.removeValue(forKey: id) else { continue }
            note("answered \(id) with \(answers.count) of \(call.questionCount)")
            continuation.resume(returning: HookResponse.answered(call, answers))
        }
    }

    private func expire(_ hold: HoldID) {
        let effects = apply(.holdExpired(hold, at: now()))
        for effect in effects {
            guard case .resolveHold(let id, let outcome) = effect,
                  let continuation = waiting.removeValue(forKey: id) else { continue }
            continuation.resume(returning: HookResponse.decision(
                outcome, reason: "deck timeout",
                event: kindOf.removeValue(forKey: id) ?? .preToolUse))
        }
    }

    // --------------------------------------------------------- V2 forwarding

    /// The pause between two steps of a forward plan.
    ///
    /// **Not fixture-measured.** The LV38 corpus recorded the wire bytes a
    /// keystroke sequence produced, not timestamped keystrokes, so there is no
    /// per-step interval to read (see `ForwardPlanBuilder.build` for the same
    /// caveat on the down-arrow count). 180ms is a plain interactive default:
    /// slow enough for the terminal's UI to process one keystroke before the
    /// next (LV38's composer-leak race, `race/payloads.ndjson`, measured two
    /// keystrokes ~400ms apart including process-spawn overhead; a scripted plan
    /// has no spawn overhead to hide behind), fast enough that a five-step
    /// multi-select finishes in under a second.
    private static let forwardStepPacingNanoseconds: UInt64 = 180_000_000

    /// Build and start a plan for the given mirror. A silent no-op when the
    /// mirror is not `.terminalLive`, a plan is already running for it, or
    /// `ForwardPlanBuilder` refuses the request (`labels`/`otherText` do not
    /// describe an answerable shape). A plan the builder cannot build with
    /// confidence must not run.
    public func forward(_ mirror: MirrorView, picking labels: [Redacted] = [],
                        otherText: Redacted? = nil) {
        guard let question = mirror.question,
              let steps = ForwardPlanBuilder.build(for: question, picking: labels, otherText: otherText)
        else { return }
        apply(.forwardPlanStarted(ForwardPlan(hold: mirror.hold, steps: steps), at: now()))
        // Refused by the reducer itself (not `.terminalLive`, or a plan already
        // running): `state.forwarding[mirror.hold]` stays nil, nothing to step.
        guard state.forwarding[mirror.hold] != nil else { return }
        let hold = mirror.hold
        pendingForwardTask[hold] = Task { [weak self] in
            await self?.runForwardPlan(hold)
            self?.pendingForwardTask.removeValue(forKey: hold)
        }
    }

    /// Explicit cancellation. The visible half is `actionBlock`/host-gone, which
    /// aborts loudly; `PostToolUse` mid-plan (`DeckState`'s `.postToolUse`
    /// handling) aborts silently and instantly (the `cullStaleDialogKeys`
    /// class). Harmless against a plan that already finished or never ran.
    public func cancelForwarding(_ hold: HoldID) {
        apply(.forwardPlanCancelled(hold, at: now()))
    }

    /// **Explicit re-arm: "Send again", never a replay.** See `MirrorSendAgainRow`
    /// (`QuestionMirrorCard.swift`). This clears `forwardSentAt` and
    /// `forwardUnconfirmedAt` (`DeckState`'s `.forwardRearmed`) so
    /// `.forwardPlanStarted`'s reducer guard admits the NEXT plan the person's
    /// next tap builds. It never re-sends steps a completed plan already sent.
    public func rearmForward(_ mirror: MirrorView) {
        apply(.forwardRearmed(mirror.hold, at: now()))
    }

    /// Steps a plan to completion, one send per loop, re-reading
    /// `state.forwarding[hold]` fresh on every pass, for the same reason `drain()`
    /// re-enters after each send: a step can complete the plan, or a
    /// `PostToolUse` between two steps can cancel it, and the next action must
    /// answer to the state as it stands.
    private func runForwardPlan(_ hold: HoldID) async {
        while let plan = state.forwarding[hold], let step = plan.currentStep {
            guard let reported = state.lanes[hold.session]?.host?.value else {
                note("action blocked: unroutable (lane has no host address) session=\(hold.session.raw)")
                apply(.forwardPlanCancelled(hold, at: now()))
                apply(.actionBlocked(hold.session, .unroutable, at: now()))
                return
            }
            let address: SessionAddress
            switch await host.inventory() {
            case .failure(let failure):
                let block = Self.block(for: failure)
                note("action blocked: \(block.rawValue) (inventory failed: \(Self.reason(failure)))")
                apply(.forwardPlanCancelled(hold, at: now()))
                apply(.actionBlocked(nil, block, at: now()))
                return
            case .success(let sessions):
                hostSessions = sessions
                guard let match = sessions.first(where: { $0.identifies(reported) }) else {
                    note("action blocked: unroutable (address not in host inventory) session=\(hold.session.raw)")
                    apply(.forwardPlanCancelled(hold, at: now()))
                    apply(.actionBlocked(hold.session, .unroutable, at: now()))
                    return
                }
                address = match.address
            }

            // Re-checked AFTER the (possibly slow) inventory round-trip, immediately
            // before sending: `PostToolUse` may have cancelled this plan meanwhile.
            guard state.forwarding[hold]?.cursor == plan.cursor else { return }

            let outcome: SendOutcome
            switch step {
            // Digits and typed text go through `CmuxHost.send`, never `sendKey` (see
            // `ForwardStep.bytes` for the measured failure).
            case .bytes(let text): outcome = await host.send(text, to: address)
            // Named keys with no byte form (`down`, `enter`), the same call `.escape`
            // and `.prompt`'s trailing Enter use.
            case .key(let key):    outcome = await host.sendKey(key, to: address)
            }

            switch outcome {
            case .sent:
                apply(.forwardStepSent(hold, at: now()))
            case .unavailable(let why):
                note("forward step unavailable: \(why)")
                apply(.forwardPlanCancelled(hold, at: now()))
                apply(.actionBlocked(nil, .hostUnavailable, at: now()))
                return
            case .failed(let why):
                note("forward step failed: \(why)")
                apply(.forwardPlanCancelled(hold, at: now()))
                apply(.actionBlocked(hold.session, .hostError, at: now()))
                return
            }

            // Cancellation is checked again before pacing: no reason to sleep for a
            // plan `PostToolUse` already retired. Reaching here with
            // `state.forwarding[hold] == nil` means completion (`forwardStepSent` marked
            // the LAST step sent, `ForwardPlan.isComplete`) OR a cancellation during the
            // send await. The landing watch arms either way, safely: for an already-
            // resolved mirror both the watchdog's `terminalLive` guard and the reducer
            // no-op it. See `scheduleForwardLandingWatch` for why cmux's `.sent` alone
            // does not end the story.
            guard state.forwarding[hold] != nil else {
                scheduleForwardLandingWatch(hold)
                return
            }
            // See THE LAW in `scheduleReadinessWatch`. This `Task` is never explicitly
            // cancelled (cancelling a plan is state-based: `.forwardPlanCancelled`
            // clears `state.forwarding`, read at the top of the next iteration), but the
            // idiom is applied uniformly.
            guard (try? await Task.sleep(nanoseconds: Self.forwardStepPacingNanoseconds)) != nil else { return }
        }
    }

    // ------------------------------------------------------------------ fleet
    /// How many times the fleet has been polled this run: the identity of a
    /// poll, and the only thing guaranteed to differ from the last.
    private var fleetPolls = 0

    /// Whether the pid-less-feed warning below has already fired this run. Noted
    /// ONCE: at a five-second heartbeat it would otherwise repeat hundreds of
    /// times an hour and bury the one fact worth knowing.
    private var notedPidlessFleet = false

    /// **`OAD_NO_FLEET_DISCOVERY`: makes a UI test's fleet contain only what the
    /// test put there.**
    ///
    /// The deck discovers live Claude Code sessions on the machine, which is its
    /// point and exactly wrong under test: a UI test posting four sessions and
    /// asserting four cards is really asserting `4 + <sessions the developer has
    /// open>` cards fit the window (the `DeckBandCycleTests` UI test, in `UITests/`, failed with "gamma's
    /// card never came back" for lack of room, nondeterministically).
    ///
    /// Gated HERE rather than at the call sites (`start()`'s launch poll and
    /// heartbeat, plus the manual refresh), since a switch that must be
    /// remembered at every call site is one call site from being wrong.
    ///
    /// Hook-delivered sessions are unaffected: they arrive through `handle(_:)`.
    private static let fleetDiscoverySuppressed =
        ProcessInfo.processInfo.environment["OAD_NO_FLEET_DISCOVERY"] == "1"

    public func pollFleet() async {
        guard !Self.fleetDiscoverySuppressed else { return }
        let rows = await fleet.poll()
        guard !rows.isEmpty else { return }
        // Claude Code 2.1.231 dropped `pid` from `claude agents --json`, so every
        // row of a non-empty poll can carry no pid, which silently starves
        // `locate(_:)` of the one field it routes a fleet-discovered session by.
        // Hook-delivered addresses are UNAFFECTED; only a session that never fires a
        // hook stays watch-only.
        if !notedPidlessFleet, rows.allSatisfy({ $0.pid == nil }) {
            notedPidlessFleet = true
            // "known to omit", not "dropped": the predicate is true whenever every row
            // lacks an integer pid, which this line cannot attribute to the upstream
            // removal for certain.
            note("fleet feed carries no pid on any row; pid discovery routing unavailable (claude agents --json 2.1.231 is known to omit the field)")
        }
        collectTombstones(against: rows)
        // ONE clock read for one event: `now()` twice could stamp an id with a
        // millisecond its own `at` does not carry.
        let at = now()
        // The id counts POLLS, not rows and milliseconds. A `fleet-<rowCount>-<ms>`
        // id let two polls in the same millisecond with the same row count collide,
        // and the reducer (idempotent per session and event id) discarded the second
        // as a duplicate. ZERO-PADDED because the tie-break compares id strings and
        // "fleet-10" sorts before "fleet-9"; an unpadded counter would pass every
        // small test and fail in the field at the tenth poll.
        fleetPolls += 1
        apply(.fleet(rows, at: at, id: EventID(String(format: "fleet-%09d", fleetPolls))))
        await locate(rows)
        // A discovered lane's branch. The hook path resolves for every payload with
        // a directory; a hook-less session's only directory is the fleet row's.
        // Same dedupe map and arbiter (`Derived.branch`) as the hook path, and
        // awaited rather than spawned: a poll has no human waiting on its latency,
        // and a test can observe the result deterministically.
        for row in rows {
            guard let session = row.session, let cwd = row.cwd,
                  !state.prefs.deleted.contains(session.raw),
                  resolvedCwd[session] != cwd else { continue }
            resolvedCwd[session] = cwd
            await resolveBranch(for: session, cwd: cwd)
        }
    }

    /// Give every discovered lane a route.
    ///
    /// A fleet row opens a lane but cannot address it (`agents --json` knows the
    /// process, not the terminal). The host resolves a pid to the surface it runs
    /// in, and only then can the deck do more than watch.
    ///
    /// Asked once per session: a lane that already has an address has one from
    /// its own hook, the more direct source. This is a process spawn per
    /// unresolved session, so it is bounded by "sessions the deck has never
    /// placed" rather than run on every poll.
    ///
    /// **And asked once per FAILURE.** A pid that cannot be placed (no cmux, or
    /// cmux refusing the socket to a deck it did not spawn) never sets `host`, so
    /// the "already placed" guard never fires and the ask would repeat forever:
    /// at a five-second heartbeat with six sessions, some eighty doomed process
    /// launches a minute. A pid is re-asked only when it CHANGES.
    private func locate(_ rows: [FleetRow]) async {
        for row in rows {
            guard let session = row.session, let pid = row.pid else { continue }
            guard state.lanes[session]?.host == nil else { continue }
            guard !state.prefs.deleted.contains(session.raw) else { continue }
            guard unplaceable[session] != pid else { continue }
            guard let address = await host.address(ofPID: pid) else {
                unplaceable[session] = pid
                continue
            }
            unplaceable[session] = nil
            apply(.located(session, host: address, at: now(),
                           id: EventID("located|\(session.raw)|\(address.surface)")))
        }
    }

    /// Drop tombstones for sessions that have gone.
    ///
    /// A deleted id is remembered so the session cannot walk back in through the
    /// next hook, and ACROSS RELAUNCHES or delete would evaporate on restart.
    /// But a session id is a UUID: once it stops appearing in the fleet it can
    /// never recur, so its tombstone is dead weight.
    ///
    /// Only run against a NON-EMPTY roster. An empty answer means the CLI failed
    /// or found nothing, and treating it as "every session is gone" would forget
    /// every deletion on the first poll hiccup.
    ///
    /// **And only after the id has been missing for several consecutive polls**
    /// (`tombstoneMisses`). The empty-roster guard does not defend a PARTIAL
    /// failure (a roster omitting one session), which would collect that
    /// session's tombstone and let the next poll re-admit it as a new discovery:
    /// the deck silently supervising a session the user removed. Collection is
    /// not urgent, so it can afford to be sure.
    static let tombstoneMisses = 3
    private func collectTombstones(against rows: [FleetRow]) {
        let alive = Set(rows.compactMap { $0.session?.raw })
        guard !alive.isEmpty else { return }
        var misses = tombstoneMisses_
        for id in state.prefs.deleted {
            misses[id] = alive.contains(id) ? 0 : (misses[id] ?? 0) + 1
        }
        // Only ids still under a tombstone are tracked; the rest is stale.
        tombstoneMisses_ = misses.filter { state.prefs.deleted.contains($0.key) }
        let kept = state.prefs.deleted.filter { (tombstoneMisses_[$0] ?? 0) < Self.tombstoneMisses }
        guard kept != state.prefs.deleted else { return }
        var next = state.prefs
        next.deleted = kept
        setPrefs(next)
    }







    /// `internal`, not `private`, like `handle(_:)`: app-target tests drive the
    /// REAL seam. Driving a mirror to `.terminalLive` through the public surface
    /// means waiting out a real question-budget timer (`openHold`'s
    /// `Task.sleep`, decoupled from `testClockMS`); feeding DeckEvents directly is
    /// the deterministic alternative.
    @discardableResult
    internal func apply(_ event: DeckEvent) -> [Effect] {
        let effects = Reducer.reduce(&state, event)
        // What the deck writes about itself is built from `Diagnostic`, which has no
        // field a command, a path or a prompt could travel in. This log is what live
        // scenarios read as evidence, so redaction matters here first.
        if let entry = DiagnosticExport.record(event, effects: effects) {
            log.append(entry)
            // Trimmed in BATCHES: `removeFirst(k)` moves every remaining element, so
            // trimming by one per event past the cap would be an O(n) memmove per event.
            // Running to a high-water mark and cutting back in one go is amortised O(1)
            // for the same retained ceiling.
            if log.count >= Self.logHighWater {
                log.removeFirst(log.count - Self.logCap)
            }
            note(entry.line)
        }
        // Persistence half of card-colour auto-assignment. The reducer
        // (`Reducer.recordCardColorIfNeeded`) mutates `state.prefs` besides
        // `setPrefs`, and `DeckCore` may not touch storage, so the write happens
        // here, at the choke point every event flows through, guarded by equality
        // against `lastPersistedPrefs` so ordinary hook events never touch disk.
        //
        // This is the ONLY save, for explicit preference changes too: `setPrefs`
        // hands the value to the reducer and this compare persists whatever came
        // out. Don't pre-set the tracker and save the argument instead: that lost
        // every reducer-side refinement of prefs, in ways only a relaunch exposed.
        //
        // The compare is cheap by inspection (not measured): every `DeckPrefs`
        // field is a scalar, a small enum, or a collection bounded by the fleet's
        // size, and synthesized `Equatable` short-circuits at the first differing
        // field, so the common no-change case is a few small comparisons.
        if state.prefs != lastPersistedPrefs {
            PrefsStore.save(state.prefs, to: prefsDefaults)
            lastPersistedPrefs = state.prefs
        }
        refresh()
        scheduleStallWatch()
        scheduleReadinessWatch()
        scheduleMirrorLingerSweep()
        return effects
    }

    public private(set) var log: [Diagnostic] = []

    /// A log on disk, because an app launched by Finder has no terminal to write
    /// to. Redacted like everything else: it prints `Diagnostic.line`, which has
    /// no field a payload can travel in.
    static let defaultLogPath = NSHomeDirectory() + "/Library/Logs/OpenAgentDeck.log"

    /// Where this runtime writes. **A property, not a constant**, like
    /// `prefsDefaults`: app-target tests construct real runtimes, and a
    /// `static let` made every test run append to the developer's own log, so a
    /// live deck opened on lines about sessions that never existed.
    internal var logPath = DeckRuntime.defaultLogPath

    /// What the in-memory log keeps, and when it cuts back.
    private static let logCap = 500
    private static let logHighWater = 600

    /// **The on-disk cap, past which the file rotates.** ~5 MB: a `note` line is
    /// about 40-80 bytes (a millisecond stamp and a `Diagnostic.line`, never a
    /// payload), so that is tens of thousands of lines, weeks of diagnostics,
    /// and two generations (this file plus the one `.old`) are negligible on disk.
    ///
    /// `internal var` like `logPath`: a rotation test needs a cap it can cross
    /// in a handful of writes.
    internal var logCapBytes: Int64 = DeckRuntime.defaultLogCapBytes
    internal static let defaultLogCapBytes: Int64 = 5 * 1_024 * 1_024

    /// The open log file, held rather than reopened. Open/seek/write/close per
    /// line cost four syscalls per event on the main actor: measured 22.1 us per
    /// line against 1.16 us for a held handle, more than the whole frame
    /// projection beside it.
    private var logHandle: FileHandle?

    /// Bytes written to `logHandle` since it was opened: mirrors the file offset
    /// without a `stat` per line, incremented by what `note` wrote and compared
    /// against `logCapBytes` before the NEXT write. Seeded from the file's actual
    /// size when the handle opens (see `openLog`), so an already-large file is
    /// rotated on this run's first line.
    private var logBytesWritten: Int64 = 0

    /// `.old` sits beside the live file; never a second generation. Rotating
    /// while an `.old` exists REPLACES it (see `rotateLog`), which bounds total
    /// retained log data at 2x `logCapBytes` by construction.
    private var logOldPath: String { logPath + ".old" }

    /// Open the live file (creating it on a cold start) and seek to its end.
    /// Separate so `rotateLog` can reopen after moving the file.
    private func openLog() {
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil)
        }
        let handle = FileHandle(forWritingAtPath: logPath)
        handle?.seekToEndOfFile()
        logHandle = handle
        logBytesWritten = Int64(handle?.offsetInFile ?? 0)
    }

    /// Close, rename the full file to `.old` (replacing any previous `.old`), and
    /// open a fresh one. The write that TRIGGERED this runs after it returns (see
    /// `note`), into the new file, so no line is lost or split across the
    /// boundary.
    private func rotateLog() {
        closeLog()
        try? FileManager.default.removeItem(atPath: logOldPath)
        try? FileManager.default.moveItem(atPath: logPath, toPath: logOldPath)
        openLog()
    }

    private func note(_ line: String) {
        // The log FILE's write below stays unconditional; this gates only the
        // second copy, to a stream that is read only when somebody asked for it.
        if stderrEnabled { FileHandle.standardError.write(Data((line + "\n").utf8)) }
        let stamped = "\(now().sinceStart.raw)ms \(line)\n"
        let bytes = Data(stamped.utf8)

        if logHandle == nil { openLog() }
        // Checked BEFORE writing, cheaply (one integer compare, no `stat`), and
        // rotated inline when the line about to be written would cross the cap, so
        // the triggering line lands whole in the fresh file.
        if logBytesWritten + Int64(bytes.count) > logCapBytes { rotateLog() }
        guard let logHandle else { return }
        // `write` on a closed or unwritable handle raises rather than throws, and a
        // log is never worth taking the deck down for.
        try? logHandle.write(contentsOf: bytes)
        logBytesWritten += Int64(bytes.count)
    }

    /// Where this deck is writing, for a test that needs to read it back.
    internal var logPathForTesting: String { logPath }

    private func closeLog() {
        try? logHandle?.close()
        logHandle = nil
    }

    /// **Equality-guarded.** `@Observable` fires a view's `body` on SET, not on
    /// CHANGE (whether this Swift also short-circuits an equal-valued set is
    /// unconfirmed, so this does not rely on it), and `refresh()` runs after
    /// EVERY event, most of which change nothing on screen (a fleet poll
    /// reporting the same idle roster, a repeated statusline percentage).
    /// Assigning `frame` unconditionally would repaint every card for them.
    ///
    /// The cost is one `Frame` equality compare. `Frame`'s hand-written `==` (see
    /// `Frame.swift`) makes it worthwhile: it excludes `at`, which would differ
    /// on every call
    /// (`PerformanceTests.frameEqualityIgnoresTheProjectionInstant`), and
    /// short-circuits on `lanes` first, the field most likely to differ.
    /// `PerformanceTests.measureFramePublishGuard` prints the compare's cost.
    ///
    /// The seed publish still lands: `frame` starts as
    /// `Projection.frame(from: DeckState(), at: .start)`, which no real
    /// projection equals, so the first real event always publishes.
    private func refresh() {
        let next = Projection.frame(from: state, at: now(), reduceMotion: systemReduceMotion)
        if next != frame { frame = next }
    }

}
