//
//  SettingsView.swift · DeckApp
//
//  A macOS settings window: a tab per subject, a `Form` (`.formStyle(.grouped)`)
//  inside each, help text in the section footer where the platform puts it.
//  `Form` supplies the label column, row heights, grouping and footer
//  treatment, so none of that is hand-padded here.
//
//  Every DISCRETE control (toggle, stepper, picker, Remove, drag reorder) is
//  modeless and instant-apply: one gesture, one write
//  (`var p = prefs; ...; runtime.setPrefs(p)`).
//
//  TEXT IS DIFFERENT. A half-typed title is not a preference, and writing
//  "Continu" on the way to "Continue" would cost a reducer apply, a
//  `UserDefaults` write and a frame reprojection per keystroke.
//  `QuickActionDetailEditor` holds a draft (seeded from the model) for the
//  selected button's three text fields (message, label, folder pattern) and
//  commits it via `runtime.setPrefs` on `.onSubmit`, on focus loss
//  (`@FocusState`), when the window goes inactive (`\.controlActiveState`),
//  and when the selection moves to a different button. Escape reverts the
//  touched field (`.onExitCommand`). There is no Save button.
//
//  TOUCH TARGETS. The deck is sized for a finger (44 pt, 64 pt for a
//  decision); this window is a pointer surface with the platform's own
//  controls, and inflating a `Form` to 44-pt rows would look foreign. The one
//  exception is the remove control: 15 pt is too small even for a mouse and it
//  destroys work, so its hit area is enlarged (the glyph is not).
//

import SwiftUI
import DeckCore
import DeckAdapters

struct DeckSettingsView: View {

    /// The remove control, built in one place so a test can measure the one that
    /// ships (a lookalike built in the test would keep passing with the floor
    /// stripped). The glyph stays its natural size; the HIT AREA grows.
    static func removeControl(_ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "minus.circle") }
            .buttonStyle(.borderless)
            .touchTarget()
    }

    let runtime: DeckRuntime

    @State private var confirmingDisconnect = false

    private var prefs: DeckPrefs { runtime.prefs }

    var body: some View {
        TabView(selection: Binding(
            get: { prefs.lastPane ?? "Actions" },
            set: { pane in
                var p = prefs
                p.lastPane = pane
                runtime.setPrefs(p)
            })) {
            connectionPane
                .tabItem { Label("Connection", systemImage: "cable.connector") }
                .tag("Connection")
            actionsPane
                .tabItem { Label("Actions", systemImage: "bolt") }
                .tag("Actions")
            sessionsPane
                .tabItem { Label("Sessions", systemImage: "rectangle.3.group") }
                .tag("Sessions")
            windowPane
                .tabItem { Label("Window", systemImage: "macwindow") }
                .tag("Window")
        }
        .frame(minWidth: 480, minHeight: 280)
    }

    // ---------------------------------------------------------- connection

    /// The durable half of setup.
    ///
    /// The connect card in the empty state is where somebody arrives; this is
    /// where they come back — to see which port the hooks point at, to repair
    /// drift after a port change, and to disconnect. One control does the
    /// first two, because the reconciliation converges from any state.
    private var connectionPane: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Label(runtime.connection.title, systemImage: runtime.connection.needsAttention
                          ? "exclamationmark.triangle.fill" : "checkmark.circle")
                        .foregroundStyle(runtime.connection.needsAttention
                                         ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                }
                LabeledContent("Listening on") {
                    Text(runtime.status.message).font(.callout.monospaced())
                }
                Text(runtime.connection.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // Shown only for a genuine mismatch between the installed hold timeout and
                // the running policy, never for "nothing is installed" (the status line says
                // that). Same repair as the empty-state card. The `needsAttention` gate
                // stays in the parent; the row itself is `HoldTimeoutDriftNotice` so a render
                // test can drive it with a plain value.
                if !runtime.connection.needsAttention {
                    HoldTimeoutDriftNotice(drift: runtime.connectionDrift) {
                        Task { await runtime.connect(addStatusline: false) }
                    }
                }
            }

            Section {
                HoldBudgetPicker(budget: prefs.holdBudget) { budget in
                    var p = prefs
                    p.holdBudget = budget
                    runtime.setPrefs(p)
                }
            } footer: {
                Text("Longer holds keep Allow and Deny on the deck longer. Until answered has "
                     + "no deck-side timer; if the deck ever freezes mid-hold, held tool calls "
                     + "wait with it — a 24-hour engine fallback is the only net.\n\n"
                     + "This deck's own countdown picks up the new number immediately, for any "
                     + "hold opened from now on. The installed hooks' own cutoff — curl's "
                     + "--max-time, the engine's per-command timeout — keeps the numbers Connect "
                     + "last wrote until you press Connect or Repair again, so lengthening the "
                     + "budget without repairing leaves calls answered after the old, shorter "
                     + "cutoff already closed the connection. The drift notice above is the tell.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Same idiom as the permission hold's row, with its own preference and
            // floor. Shortening is safe because `PostToolUse` is registered: a released
            // question learns it was answered elsewhere.
            Section {
                QuestionHoldBudgetPicker(budget: prefs.questionHoldBudget) { budget in
                    var p = prefs
                    p.questionHoldBudget = budget
                    runtime.setPrefs(p)
                }
            } footer: {
                Text("How long a question waits for an answer on the deck before the call falls "
                     + "through to its own terminal. Short by default — a released question keeps "
                     + "rendering on the strip, marked live in the terminal, and answers itself the "
                     + "instant the terminal reports what was chosen. Until answered restores the "
                     + "old behavior: a question holds exactly as long as a permission does.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                // Present whatever the state, because it is also the repair:
                // a stale port, a duplicate hook and a hook somebody wrote by
                // hand are all fixed by the same press.
                Button("Connect or Repair") {
                    Task { await runtime.connect(addStatusline: false) }
                }
                .disabled(!runtime.connection.isConnectable)
                .touchTarget(minWidth: 160)

                Button("Disconnect…", role: .destructive) { confirmingDisconnect = true }
                    .touchTarget(minWidth: 160)

                Toggle("Open Open Agent Deck at login",
                       isOn: Binding(get: { LoginItem.isEnabled }, set: { LoginItem.set($0) }))
                    .touchTarget()
            } footer: {
                Text("Disconnecting removes exactly what the deck added and restores your "
                     + "statusline. Sessions waiting on the deck are handed back to their own "
                     + "terminals first, so none of them is left waiting for a reply.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Disconnect Claude Code from this deck?",
                            isPresented: $confirmingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { Task { await runtime.disconnect() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The deck stops seeing your sessions. Nothing else about them changes, and "
                 + "you can connect again at any time.")
        }
    }

    // ------------------------------------------------------------- actions

    /// The list row's selection: a `QuickAction.ID`, never the deck's
    /// `SessionID` selection (`runtime.frame.selection`). Two unrelated facts
    /// that share the word "selection": which BUTTON this pane edits vs which
    /// SESSION the deck's window has picked.
    @State private var selectedActionID: QuickAction.ID?

    /// **Which row `addAction()` most recently created, so its Message field
    /// gets focus once and only once.** An ID rather than a `Bool`, so
    /// re-selecting that row later does not steal focus again.
    /// `QuickActionDetailEditor` clears it when it consumes the request
    /// (`onConsumeFocusRequest`).
    @State private var pendingFocusMessageID: QuickAction.ID?

    /// **The selected button's draft, owned HERE, not by the editor's `@State`.**
    /// ⌘D and "−" must read what is currently TYPED, not just what is stored, and
    /// they are methods of this view with no reach into a child's private state.
    /// An `@Observable` this view owns is a synchronously readable seam with no
    /// flush token or deferred runloop hop. See `liveAction(for:stored:)`.
    @State private var draft = QuickActionDraft()

    /// **`\.undoManager`: SwiftUI's environment key, populated from the hosting
    /// window.** Used by `removeSelected` to make delete undoable. `nil` outside
    /// such a window (a headless render test), in which case delete simply cannot
    /// be undone.
    @Environment(\.undoManager) private var undoManager

    private var selectedAction: QuickAction? {
        guard let selectedActionID else { return nil }
        return prefs.quickActions.first { $0.id == selectedActionID }
    }

    /// **The selected row as it would read if its live draft committed RIGHT NOW,
    /// never `stored` alone.** ⌘D is a `.keyboardShortcut` so it fires while a
    /// text field holds focus; reading `stored` would drop uncommitted typing.
    ///
    /// `draft.actionID == id` guards a measured transient: when the selection
    /// moves, one body pass can show the NEW row's identity beside the OLD row's
    /// text:
    ///
    ///     a|AlphaX      the edit, on the row it belongs to
    ///     c|AlphaX      <- ONE PASS showing the NEW row's identity
    ///                      alongside the OLD row's text
    ///     c|Charlie     corrected
    ///
    /// `actionID` is `private(set)` and moves only inside `reseed`, in the same
    /// mutation as the text, so during that pass it still names the OLD row and
    /// this answers `stored`. The old row's text can never become committable
    /// onto the new row. The in-flight edit is not lost; it commits to the row it
    /// was typed on. Keep `actionID` and the text assigned in one mutation.
    private func liveAction(for id: QuickAction.ID, stored: QuickAction) -> QuickAction {
        guard draft.actionID == id else { return stored }
        return QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: draft.title,
                                                      draftMessage: draft.message, draftPattern: draft.pattern)
            ?? stored
    }

    /// The directory `QuickActionDetailEditor.prefilledPattern(forDirectory:)`
    /// derives the pattern pre-fill from, resolved here from the deck's selection
    /// (`runtime.frame.selection`) so the editor takes a plain value and a render
    /// test needs no live `DeckRuntime`.
    ///
    /// `nil` for no selection and for a lane with no directory yet: a fact this
    /// pane cannot resolve reads as absent, never guessed (as in
    /// `QuickAction.shows(in:)`).
    /// guessed at.
    private var selectedSessionDirectory: String? {
        guard let session = runtime.frame.selection,
              let lane = runtime.frame.lanes.first(where: { $0.session == session })
        else { return nil }
        return lane.directory?.value
    }

    /// **`List`, not a `Form` section.** `.onMove(perform:)` on a `ForEach` inside
    /// a grouped `Form` never fires on macOS; the identical drag against a `List`
    /// reorders. (Measured.)
    ///
    /// **Master–detail, not one editor per row.** The pane renders ONE set of
    /// fields for whichever row `selectedActionID` names, so the draft lives on
    /// this view and `QuickActionDetailEditor` is a single instance whose
    /// `action:` is recomputed from `selectedAction` each render.
    private var actionsPane: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 0) {
                masterList
                    .frame(minWidth: 200, idealWidth: 220, maxWidth: 260)
                Divider()
                detail
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(minHeight: 320)

            footer
        }
        .padding(12)
        // 720, not the 480 of the other panes: this pane needs a list column AND a
        // detail form. Set on this pane's content, not the shared `TabView`, because
        // macOS resizes a settings window per tab.
        .frame(minWidth: 720)
        // ⌘D duplicates the selected button (make one general button, then one
        // variant per folder). No visible control, like Finder's ⌘D: the `Button`
        // only owns a `.keyboardShortcut`. A key equivalent fires whatever text
        // field holds focus; a raw `.onKeyPress` would not, since every editor field
        // claims "d" first.
        .background(
            Button("Duplicate Selected Button", action: duplicateSelected)
                .keyboardShortcut("d", modifiers: .command)
                .disabled(selectedActionID == nil)
                .opacity(0)
                .accessibilityHidden(true)
                .frame(width: 0, height: 0)
        )
        .onAppear {
            if selectedActionID == nil { selectedActionID = prefs.quickActions.first?.id }
        }
        // **Wholesale replace.** Reset to Defaults or any caller replacing
        // `prefs.quickActions` can leave `selectedActionID` naming a missing id,
        // stranding the detail pane on "no button selected". This is the general
        // reconciliation; `removeSelected` picks the deleted row's neighbour itself.
        .onChange(of: prefs.quickActions.map(\.id)) { _, ids in
            if let selectedActionID, !ids.contains(selectedActionID) {
                self.selectedActionID = ids.first
            }
        }
        // **Commit the OLD selection's live draft, then reseed for the NEW one.**
        // `selectedAction` changes when `selectedActionID` moves to a different row
        // (the only case that commits), when Reset to Defaults replaces the stored
        // row under the same id, or when this pane's own commit reflects back
        // through `runtime.setPrefs`. The last two only reseed, discarding (Reset)
        // or matching (reflection) the draft.
        .onChange(of: selectedAction) { (oldValue: QuickAction?, newValue: QuickAction?) in
            if let oldValue, oldValue.id != newValue?.id,
               let pending = QuickActionDetailEditor.pendingCommit(for: oldValue, draftTitle: draft.title,
                                                                    draftMessage: draft.message,
                                                                    draftPattern: draft.pattern) {
                commit(pending)
            }
            draft.reseed(from: newValue)
        }
    }

    /// Find the row by id, splice the updated value in at its index, write
    /// through. Shared by `detail`'s `onCommit` and the reseed handler.
    private func commit(_ updated: QuickAction) {
        var p = prefs
        if let i = p.quickActions.firstIndex(where: { $0.id == updated.id }) {
            p.quickActions[i] = updated
            runtime.setPrefs(p)
        }
    }

    /// The list column: the rows, the `.onMove` drag handle, and the `+`/`−` pair
    /// beneath (the Login Items idiom).
    private var masterList: some View {
        VStack(spacing: 0) {
            Text("Buttons")
                .font(.headline)
                .padding(.horizontal, 8)
                .padding(.top, 4)
            List(selection: $selectedActionID) {
                ForEach(prefs.quickActions) { action in
                    actionRow(action).tag(action.id)
                }
                // Order is load-bearing: the band's `QuickActionsColumn` fills its 2×5
                // grid column-major in this order (see
                // `QuickActionsColumn.columnMajorSplit(_:)`). Past `QuickAction.maxOffered`
                // (10) offered to a session, `QuickAction.offerable(_:in:)` stops including
                // the row for that session, so dragging a button earlier makes it show sooner
                // everywhere it already could.
                .onMove { indices, newOffset in
                    var p = prefs
                    p.quickActions = QuickAction.moved(p.quickActions, fromOffsets: indices,
                                                       toOffset: newOffset)
                    runtime.setPrefs(p)
                }
            }
            .listStyle(.inset)

            Divider()
            HStack(spacing: 2) {
                Button(action: addAction) { Image(systemName: "plus") }
                    .buttonStyle(.borderless)
                    .frame(width: 22, height: 20)
                    .accessibilityLabel("Add Button")
                // The one exception to this window's "no 44pt controls" rule, built in
                // the same place as every other use so `removeControlIsHittable`
                // (`TouchTargetTests`) measures the control that ships. Undo makes a
                // mis-click recoverable, but recoverable is not free, so the enlarged hit
                // area stays.
                DeckSettingsView.removeControl(removeSelected)
                    .disabled(selectedActionID == nil)
                    .accessibilityLabel("Remove Selected Button")
                Spacer(minLength: 0)
            }
            .padding(4)
        }
    }

    /// One row of the list. A scope badge for a `.folders` action (so a glance
    /// shows which buttons are conditional), nothing for `.everywhere`, and the
    /// red tint for `.escape` (`action.rail == .alarm`).
    private func actionRow(_ action: QuickAction) -> some View {
        HStack(spacing: 6) {
            Text(action.displayTitle)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if case .folders = action.scope {
                Image(systemName: "folder")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Limited to matching folders")
            }
        }
        .foregroundStyle(action.rail == .alarm ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
        .accessibilityLabel(action.displayTitle + (action.rail == .alarm ? ", interrupt" : ""))
    }

    /// The detail column. Nothing selected reads as nothing to edit, not as an
    /// error: `selectedAction` turns a stale id into `nil`, and this copes with an
    /// empty list or a deselected pane.
    @ViewBuilder
    private var detail: some View {
        if let selectedAction {
            QuickActionDetailEditor(
                action: selectedAction,
                index: prefs.quickActions.firstIndex(where: { $0.id == selectedAction.id }) ?? 0,
                allActions: prefs.quickActions,
                lanes: runtime.frame.lanes,
                selectedDirectory: selectedSessionDirectory,
                draft: draft,
                focusMessageOnAppear: pendingFocusMessageID == selectedAction.id,
                onConsumeFocusRequest: { pendingFocusMessageID = nil },
                onCommit: commit)
        } else {
            VStack {
                Spacer(minLength: 0)
                Text("No button selected")
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Past ten offered TO A GIVEN SESSION the Quick Actions column shows nothing
            // for the rest, so the cap, not a fold, is what to say here.
            Text("Buttons the deck offers when you select a session. They send exactly what you type. A message beginning with “/” is a command — the deck can send it but can never confirm it arrived, because Claude Code reports no submission for one. Drag a button to reorder it — the first buttons fill the Quick Actions column first. Scope a button to “Folders matching” to offer it only on sessions working in a matching directory. The deck offers up to ten finished buttons per session; the rest stay saved here and never show there.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if prefs.quickActions != QuickAction.shipped {
                Button("Reset to Defaults") {
                    var p = prefs
                    p.quickActions = QuickAction.shipped
                    runtime.setPrefs(p)
                }
            }
        }
    }

    private func addAction() {
        var p = prefs
        // `title: nil`: a new button's title is derived from its message. It
        // renders rejected ("a button needs a message to send") until a message
        // is typed, which shows its own reason in `QuickActionDetailEditor`.
        // `QuickAction.user` de-duplicates the id against the live set.
        let new = QuickAction.user(title: nil, message: "", among: p.quickActions)
        p.quickActions.append(new)
        runtime.setPrefs(p)
        // Arrives selected, with the Message field about to take focus (the one
        // field a brand-new button cannot do without).
        selectedActionID = new.id
        pendingFocusMessageID = new.id
    }

    /// **Selects the deleted row's NEIGHBOUR before removing it.**
    /// `selectionAfterRemoving(_:from:)` must be asked against the array as it
    /// stood BEFORE removal, the only place the adjacency still exists.
    private func removeSelected() {
        guard let id = selectedActionID,
              let index = prefs.quickActions.firstIndex(where: { $0.id == id })
        else { return }
        var p = prefs
        // **`liveAction`, not `p.quickActions[index]` alone.** The row may have
        // an in-progress edit in `draft` (a click on "−" right after typing never
        // loses focus first); capturing only the STORED value would let undo
        // resurrect the row without that edit.
        let removed = liveAction(for: id, stored: p.quickActions[index])
        let next = DeckSettingsView.selectionAfterRemoving(id, from: p.quickActions)
        p.quickActions.remove(at: index)
        runtime.setPrefs(p)
        selectedActionID = next

        // **Undo, not a confirmation dialog.** The recursive undo/redo
        // registration lives in `registerRemovalUndo`/`registerRemovalRedo`,
        // `self`-free because `self` is a `View` value recreated every render;
        // `runtime`, which outlives a render, is threaded through explicitly.
        if let undoManager {
            DeckSettingsView.registerRemovalUndo(of: removed, at: index, manager: undoManager, runtime: runtime)
        }
    }

    private func duplicateSelected() {
        guard let id = selectedActionID,
              let action = prefs.quickActions.first(where: { $0.id == id })
        else { return }
        // **`liveAction`, not `action` alone.** ⌘D fires while a text field holds
        // focus, so building the duplicate from the stale stored row would drop
        // the very edit that made this button worth copying.
        let source = liveAction(for: id, stored: action)
        var p = prefs
        let copy = DeckSettingsView.duplicated(source, among: p.quickActions)
        p.quickActions.append(copy)
        runtime.setPrefs(p)
        selectedActionID = copy.id
    }

    // ---------------------------------------------------- list-level rules
    //
    // Pure and `static` so a headless test can call what each decides.

    /// **A sensible NEIGHBOUR, not merely "not nil."** Deleting a middle row
    /// selects whatever now occupies its old position, deleting the last row
    /// selects the new last, and deleting the only row selects nil: clamp the old
    /// index into the array with that row already gone. `id` is looked up in
    /// `actions` as it stood BEFORE removal.
    static func selectionAfterRemoving(_ id: QuickAction.ID, from actions: [QuickAction]) -> QuickAction.ID? {
        guard let index = actions.firstIndex(where: { $0.id == id }) else { return nil }
        var remaining = actions
        remaining.remove(at: index)
        guard !remaining.isEmpty else { return nil }
        return remaining[min(index, remaining.count - 1)].id
    }

    /// **Undo's restoration: insert back at the ORIGINAL index, clamped.**
    /// Appending would put a row deleted from the middle at the end. The index
    /// was captured at delete time and the array may have grown or shrunk since,
    /// so it is clamped rather than trusted (a bare `insert(at:)` could trap).
    ///
    /// **Gives the restored row a FRESH id when the original has since been
    /// claimed.** Delete "continue", type a new button whose message derives the
    /// same slug (`QuickAction.user` de-dups only against the live set), press
    /// ⌘Z: two rows would share an id, and every id-keyed lookup in this pane
    /// would hit whichever is first until `dedupedByID` drops one at next launch.
    /// Undo resurrects the ROW, under a new id if it has to; the caller is handed
    /// the id that landed so a later redo removes the right row.
    static func restored(_ action: QuickAction, at index: Int,
                         into actions: [QuickAction]) -> (actions: [QuickAction], restoredID: QuickAction.ID) {
        let restoredAction: QuickAction
        if actions.contains(where: { $0.id == action.id }) {
            let idSource = QuickAction.user(title: action.title, message: action.payload ?? action.displayTitle,
                                            among: actions)
            restoredAction = QuickAction(id: idSource.id, title: action.title, kind: action.kind,
                                         scope: action.scope)
        } else {
            restoredAction = action
        }
        var result = actions
        result.insert(restoredAction, at: min(max(index, 0), result.count))
        return (result, restoredAction.id)
    }

    /// **Undo and redo are the SAME primitive, alternating direction.**
    /// `UndoManager` has no separate "register a redo"; a redo is an undo
    /// registered from INSIDE another undo's handler. Without that
    /// re-registration ⌘Z works once and ⇧⌘Z does nothing.
    ///
    /// **`self`-free by necessity.** `DeckSettingsView` is a value type SwiftUI
    /// recreates every render, so a closure that may run minutes later cannot
    /// close over `self`. Both directions take `runtime` explicitly and recurse
    /// through each other.
    static func registerRemovalUndo(of removed: QuickAction, at index: Int,
                                    manager: UndoManager, runtime: DeckRuntime) {
        manager.registerUndo(withTarget: runtime) { target in
            var p = target.prefs
            let (updatedActions, restoredID) = DeckSettingsView.restored(removed, at: index, into: p.quickActions)
            p.quickActions = updatedActions
            target.setPrefs(p)
            DeckSettingsView.registerRemovalRedo(of: removed, at: index, restoredID: restoredID,
                                                 manager: manager, runtime: target)
        }
        manager.setActionName("Delete “\(removed.displayTitle)”")
    }

    /// The other half of the pair above: re-deletes the row `restoredID` actually
    /// landed under (`restored(_:at:into:)` may have renamed it), then registers
    /// another undo so a further ⌘Z after ⇧⌘Z keeps working. Each step only
    /// reverses the step before it.
    private static func registerRemovalRedo(of removed: QuickAction, at index: Int, restoredID: QuickAction.ID,
                                             manager: UndoManager, runtime: DeckRuntime) {
        manager.registerUndo(withTarget: runtime) { target in
            var p = target.prefs
            p.quickActions.removeAll { $0.id == restoredID }
            target.setPrefs(p)
            DeckSettingsView.registerRemovalUndo(of: removed, at: index, manager: manager, runtime: target)
        }
        manager.setActionName("Delete “\(removed.displayTitle)”")
    }

    /// **A fresh id from `QuickAction.user`'s de-duplication; every OTHER field
    /// carried from the ORIGINAL.** `user(title:message:among:)` is the only
    /// exposed id-generation logic (the slug rule and `-2`, `-3` collision loop
    /// are private to `DeckCore`; this file keeps no second copy), but it builds
    /// only a `.prompt` action with `scope: .everywhere`. A duplicate is a copy,
    /// so `user` is asked ONLY for the id and the duplicate is built from
    /// `action`'s own `title`, `kind` and `scope`. `messageForID` falls back to
    /// `displayTitle` for a kind with no payload (`.escape`) so the slug has
    /// something to derive from.
    static func duplicated(_ action: QuickAction, among others: [QuickAction]) -> QuickAction {
        let messageForID = action.payload ?? action.displayTitle
        let idSource = QuickAction.user(title: action.title, message: messageForID, among: others)
        return QuickAction(id: idSource.id, title: action.title, kind: action.kind, scope: action.scope)
    }

    // ------------------------------------------------------------ sessions

    /// The hidden-sessions sentence, as a pure function of what is observable,
    /// so it is checked without rendering.
    static func hiddenSentence(onDeck count: Int, stored: Int = 2) -> String {
        switch count {
        // Pluralised on what is STORED, since nothing is on the deck to count.
        case 0: return stored == 1
            ? "The hidden session is not running right now."
            : "The hidden sessions are not running right now."
        case 1: return "1 session is hidden from the deck."
        default: return "\(count) sessions are hidden from the deck."
        }
    }

    /// **Auto-continue: a standing default, and a one-time bulk act.**
    ///
    /// Two controls, deliberately separate: the toggle is a default for panes the
    /// deck has NOT seen yet; the button acts on the sessions in front of you
    /// right now. Collapsing them would give either a default that silently
    /// rewrites sessions set by hand, or a bulk action that keeps re-applying
    /// itself.
    ///
    /// **Wording matters.** The feature is usage-limit only:
    /// `DeckState.shouldArmAutoContinue` requires `bindingUsageWindow`, which
    /// requires `usedPercentage >= 100`. The footer says so in the terms a
    /// person meets it in (hit a limit, come back, the work has moved). Casing
    /// follows the HIG: sentence case for the checkbox, title case for push
    /// buttons.
    ///
    /// **`coverage` is read ONCE**, so a disabled button and the sentence under
    /// it cannot answer from two different reads of a fleet that changes while
    /// Settings is open.
    private var autoContinueSection: some View {
        let coverage = runtime.autoContinueCoverage
        return Section {
            Toggle("Continue new sessions automatically", isOn: Binding(
                get: { prefs.autoContinueByDefault },
                set: { runtime.setAutoContinueByDefault($0) }))

            // Offered only when there is something to act on. **Gated on
            // `hasAnythingToShow`, not `total > 0`:** `total` counts sessions the
            // deck could continue, which is 0 exactly when Turn Off matters most
            // (Continue dragged past the ten-action cap leaves armed entries that
            // resurrect when it comes back).
            if coverage.hasAnythingToShow {
                HStack {
                    Button("Turn On for All Sessions") {
                        runtime.setAutoContinueForAllSessions(true)
                    }
                    // Enabled while anything is left to arm OR any refusal to clear; gating
                    // on arming alone made refusal-clearing unreachable on a fully armed
                    // fleet.
                    .disabled((coverage.total == 0 || coverage.armed == coverage.total)
                              && coverage.refusals == 0)
                    // Enabled on `armedAnywhere`: there can be nothing continuable and
                    // still something armed to clear.
                    Button("Turn Off for All Sessions") {
                        runtime.setAutoContinueForAllSessions(false)
                    }
                    .disabled(coverage.armedAnywhere == 0)
                }
            }
        } header: {
            Text("Auto-Continue")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("When your usage limit interrupts a session, the deck sends "
                     + "\u{201C}Continue\u{201D} as soon as the limit resets.")
                Text(Self.coverageSentence(coverage))
                // A session not yet placed WILL arm its pane once it is, so the pane
                // count above would otherwise be incomplete.
                if coverage.heldOffers > 0 {
                    Text(Self.heldOfferSentence(coverage.heldOffers))
                }
                // Not guessable from the labels, and getting it wrong is a surprise.
                Text("Turning the setting on does not change sessions already on the deck.")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What is waiting on a pane the deck has not worked out yet. Separate from
    /// the coverage count: these are sessions, not panes.
    static func heldOfferSentence(_ count: Int) -> String {
        count == 1
            ? "1 session is still being placed and will continue automatically once it is."
            : "\(count) sessions are still being placed and will continue automatically once they are."
    }

    /// The coverage sentence, as a pure function of the counts (`static` so it is
    /// checked without rendering).
    ///
    /// Pluralised on the TOTAL, the noun the verb agrees with, and spelled "All"
    /// rather than "3 of 3" at the top end.
    ///
    /// **Reads `heldOffers` so it never says "none" above a line saying "one".**
    static func coverageSentence(_ coverage: DeckRuntime.AutoContinueCoverage) -> String {
        // Nothing the deck can continue at all: said plainly rather than "0 of
        // 0", with the reason, since the state is reachable by dragging Continue
        // out of the offered actions.
        //
        // **"Will continue automatically" is an absolute and may only be said
        // when nothing ELSE is going to.** Both an offer still being placed and a
        // pane armed in the preferences whose session is not currently
        // continuable (a quiet tab, or Continue dragged past the ten-action cap)
        // must be consulted; the latter really will continue the next session
        // started in it. Where something else will, the sentence narrows to what
        // it can vouch for: nothing on the deck is ARMED, or nothing is OFFERED
        // Continue. Pluralise on the noun each sentence uses, not on `total`.
        let somethingElseWill = coverage.prefArmed > 0 || coverage.heldOffers > 0
        guard coverage.total > 0 else {
            if coverage.prefArmed > 0 {
                return "No session on the deck is offered Continue right now."
            }
            return coverage.heldOffers > 0
                ? "No session on the deck is armed to continue automatically."
                : "No sessions on the deck will continue automatically."
        }
        let noun = coverage.total == 1 ? "session" : "sessions"
        let verb = coverage.total == 1 ? "is" : "are"
        if coverage.armed == 0 {
            return somethingElseWill
                ? "No \(noun) on the deck \(verb) armed to continue automatically."
                : "No \(noun) on the deck will continue automatically."
        }
        if coverage.armed == coverage.total {
            return coverage.total == 1
                ? "The one session on the deck will continue automatically."
                : "All \(coverage.total) \(noun) on the deck will continue automatically."
        }
        return "\(coverage.armed) of \(coverage.total) \(noun) on the deck will continue automatically."
    }

    private var sessionsPane: some View {
        Form {
            Section {
                Stepper(value: Binding(
                    get: { prefs.promptHistory },
                    set: { n in
                        var p = prefs
                        p.promptHistory = min(max(n, 1), 8)
                        runtime.setPrefs(p)
                    }), in: 1...8) {
                    LabeledContent("Recent prompts shown", value: "\(prefs.promptHistory)")
                }
            } footer: {
                Text("How many of the selected session's latest prompts the deck lists.")
            }

            autoContinueSection

            if !prefs.hidden.isEmpty {
                Section {
                    Button("Show All Hidden Sessions") { runtime.unhideAll() }
                } footer: {
                    // **Counts hidden LANES on the deck, not entries in the preference.**
                    // `prefs.hidden` holds SURFACES, and a surface has two spellings
                    // (`Reducer.followSurfaceRename`), so one pane can legitimately appear
                    // twice; and a pane stays hidden while nothing runs in it, so the set is
                    // normally larger than the fleet. The button clears the whole preference,
                    // which is why the section is gated on the PREFERENCE being non-empty while
                    // the sentence reports what is observable (never "0 sessions are hidden"
                    // above a button with something to do).
                    Text(Self.hiddenSentence(onDeck: runtime.frame.hidden.count, stored: prefs.hidden.count))
                }
            }
        }
        .formStyle(.grouped)
    }

    // -------------------------------------------------------------- window

    private var windowPane: some View {
        Form {
            Section {
                LabeledContent("Width") {
                    TextField("Width", value: Binding(
                        get: { prefs.windowSize?.width ?? DeckPrefs.defaultWindow.width },
                        set: { width in
                            var p = prefs
                            let height = p.windowSize?.height ?? DeckPrefs.defaultWindow.height
                            p.windowSize = Canvas(width: width, height: height)
                            runtime.setPrefs(p)
                        }), format: .number)
                        // **`.labelsHidden()`**: a `TextField` in a `LabeledContent` value slot
                        // renders its OWN title as a second label. This field stays in the value
                        // column on purpose: a window dimension is a value read at a glance, and
                        // trailing-aligned is the Mac convention for one (text somebody AUTHORS
                        // belongs stacked; see `StackedField`).
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Default window width in points")
                }
                LabeledContent("Height") {
                    TextField("Height", value: Binding(
                        get: { prefs.windowSize?.height ?? DeckPrefs.defaultWindow.height },
                        set: { height in
                            var p = prefs
                            let width = p.windowSize?.width ?? DeckPrefs.defaultWindow.width
                            p.windowSize = Canvas(width: width, height: height)
                            runtime.setPrefs(p)
                        }), format: .number)
                        // Same treatment as Width above, for the same reason.
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                        .accessibilityLabel("Default window height in points")
                }
            } header: {
                Text("Default Size")
            } footer: {
                Text("Used when macOS has no remembered position — a fresh machine, or a display it has not opened on before. Otherwise the deck reopens at the size and place you left it. There is no minimum of the deck's own: the layout adapts to whatever size you drag it to.")
            }

            Section {
                Button("Use Current Size") {
                    guard let current = runtime.currentWindowSize() else { return }
                    var p = prefs
                    p.windowSize = current
                    runtime.setPrefs(p)
                }
                .disabled(!runtime.hasDeckWindow)

                Button("Apply Now") {
                    runtime.applyWindowSize(prefs.windowSize ?? DeckPrefs.defaultWindow)
                }
                .disabled(!runtime.hasDeckWindow)

                Button("Reset to Default") {
                    var p = prefs
                    // nil, not a number: "never chose" follows the product
                    // default wherever it goes next.
                    p.windowSize = nil
                    runtime.setPrefs(p)
                }
                .disabled(prefs.windowSize == nil)
            }
        }
        .formStyle(.grouped)
    }
}

// ----------------------------------------------------------- action editing

/// **The selected button's draft, as a synchronously readable object.**
/// `@Observable`, owned by `DeckSettingsView` and handed to the editor by
/// reference, because `duplicateSelected`/`removeSelected` must read what is
/// CURRENTLY TYPED (⌘D fires while a text field holds focus) and a `View`'s
/// private `@State` has no seam a sibling method can reach. No flush token or
/// deferred runloop hop: a write to `draft.title` from the editor's
/// `TextField` binding is visible to `liveAction(for:stored:)` immediately.
///
/// **`@MainActor`**: this is a view's editing state, and `reseed(from:)` reads
/// rules that are main-actor isolated by living on a `View`. Without it the
/// `QuickActionDetailEditor` statics are called from a nonisolated context
/// and Swift 6 warns. Every reader and writer is already on the main actor.
@MainActor
@Observable
final class QuickActionDraft {
    /// Which row this draft's other three fields belong to. Read only by
    /// `DeckSettingsView.liveAction(for:stored:)` as a guard; it should never
    /// disagree with `selectedActionID` in practice.
    private(set) var actionID: QuickAction.ID?
    var title = ""
    var message = ""
    var pattern = ""

    init() {}

    /// A draft already seeded from `action`, the shape test fixtures and the
    /// `.onChange(of: selectedAction)` handler reach for.
    convenience init(action: QuickAction) {
        self.init()
        reseed(from: action)
    }

    /// Reseeds every field from a freshly selected (or changed) stored action,
    /// using the same title / payload / stored-pattern resolution the editor's
    /// statics state (`resolvedTitle(for:)`, `storedPattern(for:)`). `nil` clears
    /// every field ("nothing is selected").
    func reseed(from action: QuickAction?) {
        guard let action else {
            actionID = nil; title = ""; message = ""; pattern = ""
            return
        }
        actionID = action.id
        title = QuickActionDetailEditor.resolvedTitle(for: action)
        message = action.payload ?? ""
        pattern = QuickActionDetailEditor.storedPattern(for: action)
    }
}

/// **A text input somebody AUTHORS: label above, bordered field full width
/// beneath it, never in a `Form` row's value column.**
///
/// Grouped `Form` puts a row's value on the trailing edge, right for a number
/// somebody reads at a glance and wrong for text somebody types: the caret
/// sits against the right margin, far from its label. Measured: nothing
/// overrides the value column's trailing placement (not
/// `.multilineTextAlignment(.leading)`, not `.frame(maxWidth: .infinity,
/// alignment: .leading)`, not `.labelsHidden()`); only leaving it, as this
/// stacked shape does, works.
///
/// `.labelsHidden()` also prevents a `TextField` that carries its own title
/// from drawing it as a SECOND label in the value slot; the title stays an
/// accessibility name, and anything a sighted reader needs is the `prompt:`.
private struct StackedField<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .foregroundStyle(.secondary)
            field
                // The border says "editable"; the borderless value treatment reads as a
                // rendered fact.
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// **The selected quick action's editor: ONE instance for the whole pane, not
/// one per row.** Master–detail renders one row's fields at a time, for
/// whichever id `selectedActionID` names, so the draft/commit machinery lives
/// behind a single instance whose `action:` is recomputed from the selection
/// every render. The incoming value's IDENTITY, not only its content, can
/// change under a live draft.
///
/// **Draft commit.** Three text drafts (label, message, pattern) live in
/// `QuickActionDraft` and commit together via `onCommit` (wired to
/// `runtime.setPrefs` by `DeckSettingsView.commit`) on `.onSubmit`, on any
/// field's `@FocusState` going false, or on the window going inactive
/// (`\.controlActiveState`). `.onExitCommand` reverts the field Escape was
/// pressed in to the model's value instead of committing.
///
/// **`@FocusState` does not reliably go false when the window merely
/// RESIGNS KEY** (measured with synthetic clicks), which is the ordinary way
/// someone finishes with this pane, so an edit finished by clicking away was
/// lost. `\.controlActiveState` going `.inactive` covers resign-key and
/// close alike; `NSWindow.willCloseNotification` fires for every window in
/// the process and was rejected.
///
/// **Selection changing is a fourth commit trigger**, handled by
/// `DeckSettingsView`'s `.onChange(of: selectedAction)`, which commits the
/// OLD selection's pending edit before reseeding `draft` for the new one (see
/// `actionsPane`).
struct QuickActionDetailEditor: View {
    let action: QuickAction
    /// This row's position in `allActions`, looked up by the caller. Used only
    /// for the rejection preview's "an earlier button already says that" check
    /// (`QuickAction.rejection(at:among:)`); the commit path keys on `action.id`.
    let index: Int
    /// The full stored set, for the rejection preview's duplicate-title check.
    /// This row substitutes its live `candidate` in at `index`.
    let allActions: [QuickAction]
    /// Every open session's lane, read only for `matchSummary`'s live count. A
    /// plain `[LaneView]` rather than a `DeckRuntime` so a render test can drive it.
    let lanes: [LaneView]
    /// The deck's current session's directory, for the pattern field's one-time
    /// pre-fill, resolved by `DeckSettingsView.selectedSessionDirectory` so this
    /// type stays free of `Frame`/`SessionID`.
    let selectedDirectory: String?
    /// Owned by `DeckSettingsView` (see `QuickActionDraft`). `@Bindable` so
    /// fields bind straight to `$draft.title` etc.
    @Bindable var draft: QuickActionDraft
    /// True for exactly one transition: the render right after
    /// `DeckSettingsView.addAction()` created this row. Consumed immediately
    /// (`onConsumeFocusRequest`) so re-selecting the row never steals focus.
    let focusMessageOnAppear: Bool
    let onConsumeFocusRequest: () -> Void
    let onCommit: (QuickAction) -> Void

    @FocusState private var titleFocused: Bool
    @FocusState private var messageFocused: Bool
    @FocusState private var patternFocused: Bool

    /// The window-level commit boundary: `.inactive` is SwiftUI's report that this
    /// window stopped being active (resign-key and close alike). Read as an
    /// environment value so there is no window to filter on and no second
    /// mechanism to keep correct.
    @Environment(\.controlActiveState) private var controlActiveState

    /// True while `action.scope` is `.folders`, read from the STORED value, never
    /// a draft flag. The scope Picker is instant-apply, so `action.scope` already
    /// reflects its latest choice; only the text fields have a draft/model gap.
    private var isFolder: Bool {
        if case .folders = action.scope { return true }
        return false
    }

    /// `action.scope`'s pattern, or `""` for `.everywhere`; the seed for
    /// `QuickActionDraft.reseed(from:)`. One resolution, so call sites cannot
    /// drift.
    static func storedPattern(for action: QuickAction) -> String {
        if case .folders(let pattern) = action.scope { return pattern }
        return ""
    }

    // ---------------------------------------------------------- the preview

    /// The action this row would save RIGHT NOW, every draft included, never the
    /// stored `action` alone. Read by the preview pill and by `rejection` (the
    /// warning updates as you type). `scope` substitutes the LIVE `draft.pattern`
    /// when `isFolder`, since the committed pattern can be a keystroke behind the
    /// field. Title goes through `committedTitle(for:draftTitle:)`, not an
    /// unconditional `QuickAction.commitTitle`: an untouched, non-canonical stored
    /// title must not preview canonicalised while the real button renders the raw
    /// stored one.
    private var candidate: QuickAction {
        let kind: QuickAction.Kind
        switch action.kind {
        case .prompt: kind = .prompt(draft.message)
        case .escape: kind = .escape
        case .dialogKey(let key): kind = .dialogKey(key)
        }
        let scope: QuickAction.Scope = isFolder ? .folders(draft.pattern) : action.scope
        return QuickAction(id: action.id, title: Self.committedTitle(for: action, draftTitle: draft.title),
                           kind: kind, scope: scope)
    }

    /// The duplicate-title / empty-field / empty-pattern warning, evaluated
    /// against the DRAFT (`candidate` substituted into `allActions` at this row's
    /// position), so it flags before the keystroke reaches `runtime.setPrefs`.
    private var rejection: String? {
        var set = allActions
        if set.indices.contains(index) { set[index] = candidate } else { set.append(candidate) }
        return candidate.rejection(at: index, among: set)
    }

    // ------------------------------------------------------------- the rules

    /// Resolves to the EXPLICIT title, empty string when `nil`, never the derived
    /// `displayTitle`. Every "does the draft disagree with the model" comparison
    /// goes through this so an untouched DERIVED row reads as untouched.
    static func resolvedTitle(for action: QuickAction) -> String {
        action.title ?? ""
    }

    /// Bounds TYPING: a paste past `editorTitleCap` clamps as it lands. Refuses
    /// to touch a value the MODEL handed the field: otherwise Escape on a row
    /// whose stored title is over the cap would revert through this clamp,
    /// diverge from the model, and the next commit would truncate a title nobody
    /// edited. `escapeIsInertOnAnOverCapStoredTitle` (`SettingsActionsTests`)
    /// covers it.
    static func clampedInput(_ newValue: String, storedTitle: String) -> String {
        guard newValue != storedTitle else { return newValue }
        return String(newValue.prefix(QuickAction.editorTitleCap))
    }

    /// **The ONE place a draft title becomes the value a commit stores.** The
    /// title is canonicalised only when the draft differs from
    /// `resolvedTitle(for:)`. Canonicalising unconditionally would silently
    /// rewrite a non-canonical stored title (padded, over `editorTitleCap`,
    /// legacy or hand-edited) when only the message was edited. Shared by
    /// `pendingCommit`, `scopeCommit` and `candidate` so the rule cannot drift.
    static func committedTitle(for action: QuickAction, draftTitle: String) -> String? {
        guard draftTitle != Self.resolvedTitle(for: action) else { return action.title }
        let committed = QuickAction.commitTitle(draftTitle)
        return committed.isEmpty ? nil : committed
    }

    /// **The three drafts (title, message, pattern), in ONE write.** Hazards
    /// closed:
    ///
    ///   - **raw, not canonical, is what "touched" means for the title**:
    ///     `draftTitle != resolvedTitle(for: action)`, never `commitTitle
    ///     (draftTitle) != action.title`, via `committedTitle(for:draftTitle:)`;
    ///   - **`.escape` tests `action.kind`, not `action.payload`**: an escape row
    ///     seeds `draft.message` from `action.payload ?? ""`, so comparing against
    ///     the payload reads as changed for every untouched escape row and would
    ///     rewrite an interrupt button into an empty prompt at any boundary that
    ///     fires for EVERY row (`\.controlActiveState` does);
    ///   - **a cleared title commits `nil`, never `""`**: the two are different
    ///     representations and `displayTitle` has no emptiness check to derive
    ///     around a stray `Optional("")`.
    ///
    /// **`patternChanged` reads `action.scope`'s CASE as ground truth** rather
    /// than a draft flag: the scope Picker is instant-apply, so only the pattern
    /// TEXT needs a buffered draft. When `action.scope` is `.everywhere`,
    /// `draftPattern` is not consulted, so **`scope` cannot be perturbed by an
    /// unrelated title or message edit**, carrying the field forward as other
    /// reconstruction sites do (`QuickAction.migrated`).
    /// already had to learn to.
    static func pendingCommit(for action: QuickAction, draftTitle: String, draftMessage: String,
                              draftPattern: String) -> QuickAction? {
        let titleTouched = draftTitle != Self.resolvedTitle(for: action)
        var messageChanged = false
        if case .prompt(let stored) = action.kind, draftMessage != stored { messageChanged = true }
        var patternChanged = false
        var newScope = action.scope
        if case .folders(let stored) = action.scope, draftPattern != stored {
            patternChanged = true
            newScope = .folders(draftPattern)
        }
        guard titleTouched || messageChanged || patternChanged else { return nil }
        let newTitle = Self.committedTitle(for: action, draftTitle: draftTitle)
        guard newTitle != action.title || messageChanged || patternChanged else { return nil }
        return QuickAction(id: action.id, title: newTitle,
                           kind: messageChanged ? .prompt(draftMessage) : action.kind,
                           scope: newScope)
    }

    /// **The scope Picker's write: a SEPARATE path from `pendingCommit`, because
    /// it fires on SELECTION, not on a focus/window boundary, and must never
    /// read a stale `action.title`/`.kind` while a text edit is in flight.**
    /// Flipping "Every session"/"Folders matching" does not take focus from the
    /// field being typed in, so building the result from `action`'s stored fields
    /// alone would let `onCommit`'s reseed put the STALE stored value back over a
    /// half-typed title. Building from the same drafts every other boundary reads
    /// avoids that race. Routes through `committedTitle(for:draftTitle:)`, the
    /// same gate `pendingCommit` uses.
    static func scopeCommit(for action: QuickAction, draftTitle: String, draftMessage: String,
                            isFolder: Bool, pattern: String) -> QuickAction {
        let newTitle = Self.committedTitle(for: action, draftTitle: draftTitle)
        var newKind = action.kind
        if case .prompt(let stored) = action.kind, draftMessage != stored { newKind = .prompt(draftMessage) }
        let newScope: QuickAction.Scope = isFolder ? .folders(pattern) : .everywhere
        return QuickAction(id: action.id, title: newTitle, kind: newKind, scope: newScope)
    }

    /// **`*/<last path component>*`: nobody should have to author a glob from
    /// scratch.** For example `*/zephyr*`: a leading `*` for whatever sits above
    /// the project folder, the folder's name literal, a trailing `*`. Derived
    /// from the directory the deck's selection sits in, so switching to "Folders
    /// matching" starts from a pattern that already matches the session being
    /// viewed.
    ///
    /// A trailing slash is stripped first, so `/Users/h/work/zephyr/` derives the
    /// same `*/zephyr*` (splitting alone would read an empty final component).
    /// `nil` and a directory that is nothing but slashes return the empty string:
    /// `*/*` would mean "every directory", which should be typed on purpose.
    static func prefilledPattern(forDirectory directory: String?) -> String {
        guard let directory else { return "" }
        let trimmed = directory.hasSuffix("/") ? String(directory.dropLast()) : directory
        guard let last = trimmed.split(separator: "/").last, !last.isEmpty else { return "" }
        return "*/\(last)*"
    }

    /// **The scope Picker's pre-fill DECISION, pulled out of `commitScope` so a
    /// test can call it.** Switching "Folders matching" off and back on within
    /// one editing session must PRESERVE a pattern already typed: a non-empty
    /// `draftPattern` wins, and `prefilledPattern` is asked only when there is
    /// nothing to preserve. (The preservation itself follows from
    /// `QuickActionDraft.pattern` being storage separate from the radio choice.)
    ///
    /// **Trimmed-empty, not merely `.isEmpty`.** A whitespace-only draft is not
    /// something to preserve (`Glob.matches` treats it as matching nothing
    /// meaningful), and `.isEmpty` would leave the field looking blank without
    /// deriving a suggestion. `DeckCore`'s `String.trimmed` is `internal`, so
    /// this spells out `.trimmingCharacters(in:)`.
    static func patternOnSwitchingToFolders(draftPattern: String, directory: String?) -> String {
        draftPattern.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.prefilledPattern(forDirectory: directory) : draftPattern
    }

    /// **N of M, as a pure static function so the pane's highest-value control
    /// is provable without a live runtime.** `Glob.matches` documents why a bare
    /// word with no `*` matches nothing a realistic `cwd` would hand it; this
    /// count catches that silent trap. A lane with no `directory` never matches
    /// (fail-closed, as in `QuickAction.shows(in:)`).
    static func matchSummary(forPattern pattern: String, among lanes: [LaneView]) -> (matches: Int, total: Int) {
        let matches = lanes.filter { lane in
            guard let directory = lane.directory?.value else { return false }
            return Glob.matches(pattern: pattern, path: directory)
        }.count
        return (matches, lanes.count)
    }

    // ------------------------------------------------------------- wiring

    /// The WIRING. It deliberately does NOT normalise `draftTitle`
    /// unconditionally: that would rewrite an untouched draft into canonical
    /// form, make it differ from `resolvedTitle(for: action)`, and manufacture
    /// a phantom edit at the next deactivation. Both branches route the model's
    /// title through `resolvedTitle(for:)` rather than reading `.title` raw.
    private func commitPending() {
        if let updated = Self.pendingCommit(for: action, draftTitle: draft.title, draftMessage: draft.message,
                                            draftPattern: draft.pattern) {
            // Show the typist what was stored, clamp included: empty when the commit
            // derived, never the derived text itself.
            draft.title = Self.resolvedTitle(for: updated)
            draft.pattern = Self.storedPattern(for: updated)
            onCommit(updated)
        } else if draft.title != Self.resolvedTitle(for: action) {
            // Touched, but it canonicalises to what is already stored: no write, and
            // the field stops showing stray whitespace.
            draft.title = Self.resolvedTitle(for: action)
        }
    }

    /// The scope Picker's `set`. Pre-fills the pattern from the deck's selection
    /// ONLY when `draft.pattern` is still (trimmed) empty, so a pattern typed
    /// earlier in this editing session is preserved. `draft.pattern` is separate
    /// from the radio choice and never reset by it, so preservation holds by
    /// construction.
    private func commitScope(isFolder: Bool) {
        let pattern: String
        if isFolder {
            pattern = Self.patternOnSwitchingToFolders(draftPattern: draft.pattern, directory: selectedDirectory)
            draft.pattern = pattern
        } else {
            pattern = draft.pattern
        }
        onCommit(Self.scopeCommit(for: action, draftTitle: draft.title, draftMessage: draft.message,
                                  isFolder: isFolder, pattern: pattern))
    }

    var body: some View {
        Form {
            Section {
                switch action.kind {
                case .escape:
                    LabeledContent("Message") {
                        Text("Interrupts the session").foregroundStyle(.secondary)
                    }
                // Unreachable in practice: `dialogAnswers` never joins
                // `prefs.quickActions`. Present so a new `Kind` case is a compile error
                // here rather than a silent gap.
                case .dialogKey:
                    LabeledContent("Message") {
                        Text("Answers a terminal dialog").foregroundStyle(.secondary)
                    }
                case .prompt:
                    // **Message BEFORE Label, and multi-line.** The message is what the
                    // button DOES; the label is a display detail that defaults to it.
                    // `axis: .vertical` means Return inserts a newline rather than
                    // submitting, so this field commits only on focus loss and the window
                    // boundary.
                    StackedField("Message") {
                        TextField("Message", text: $draft.message,
                                  prompt: Text("Message to send"), axis: .vertical)
                            .lineLimit(3...8)
                            .focused($messageFocused)
                            .onSubmit { commitPending() }
                            .onChange(of: messageFocused) { _, focused in if !focused { commitPending() } }
                            .onExitCommand { draft.message = action.payload ?? "" }
                    }
                }

                StackedField("Label") {
                    // `prompt:` shows the DERIVED label (`action.displayTitle`) whenever the
                    // field is empty, so an empty field visibly means "same as the message".
                    TextField("Label", text: $draft.title, prompt: Text(action.displayTitle))
                        // **Content-proportional width hazard.** Without a cap, an `NSTextField`
                        // hosted in SwiftUI reports an IDEAL width proportional to its string
                        // value, so a 64-character stored title (hand-edited / older-writer
                        // data, see `PrefsTests.storedRowsPastTheCapSurviveDecode`) made the
                        // whole `Form` 24pt taller than a 2-character one.
                        // `.frame(maxWidth: .infinity)` was measured not to fix it.
                        // `editorRowHeightIsUnaffectedByTitleLength` (`RenderSweepTests`) is the
                        // arbiter.
                        .frame(maxWidth: 300)
                        .focused($titleFocused)
                        .onChange(of: draft.title) { _, newValue in
                            let clamped = Self.clampedInput(newValue, storedTitle: Self.resolvedTitle(for: action))
                            if clamped != newValue { draft.title = clamped }
                        }
                        .onSubmit { commitPending() }
                        .onChange(of: titleFocused) { _, focused in if !focused { commitPending() } }
                        .onExitCommand { draft.title = Self.resolvedTitle(for: action) }
                }

                // **The native macOS idiom for a small exclusive choice in a form.**
                // Instant-apply (see `isFolder`): `commitScope(isFolder:)` writes through
                // `onCommit` the moment the radio changes.
                Picker("Shows on", selection: Binding(
                    get: { isFolder },
                    set: { commitScope(isFolder: $0) })) {
                    Text("Every session").tag(false)
                    Text("Folders matching").tag(true)
                }
                .pickerStyle(.radioGroup)

                // **Stacked like the other authored fields, not under an empty
                // `LabeledContent` label**, which produced a trailing-aligned caret and a
                // centred placeholder. A glob is authored, so it gets the authoring
                // treatment. Labelled "Pattern", not "Folders matching", because the radio
                // above already says that.
                StackedField("Pattern") {
                    VStack(alignment: .leading, spacing: 4) {
                        // **Always present, `.disabled` rather than hidden when "Every session"
                        // is selected**, so switching back does not make it appear from nowhere.
                        TextField("Folder pattern", text: $draft.pattern,
                                  prompt: Text(verbatim: "*/zephyr*"))
                            .disabled(!isFolder)
                            .accessibilityLabel("Folder pattern")
                            .focused($patternFocused)
                            .onSubmit { commitPending() }
                            .onChange(of: patternFocused) { _, focused in if !focused { commitPending() } }
                            .onExitCommand { draft.pattern = Self.storedPattern(for: action) }
                        if isFolder {
                            // **A live "N of M"**, read off `draft.pattern` so it updates on every
                            // keystroke before any commit boundary. Shown only for `.folders`: a
                            // count is meaningless when the rule is not in force.
                            let summary = Self.matchSummary(forPattern: draft.pattern, among: lanes)
                            Text("matches \(summary.matches) of \(summary.total) open session"
                                 + (summary.total == 1 ? "" : "s"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section {
                // **The truncation preview uses the REAL control.**
                // `QuickActionBar.control` is the one place the bar's button is built, so
                // this is what the bar will show, truncation and all. Non-interactive
                // (`disabled`, `allowsHitTesting(false)`, `accessibilityHidden`): the
                // fields above already speak for it.
                QuickActionBar.control(candidate.displayTitle, alarming: action.rail == .alarm,
                                       measuredWidth: ActionPillMeasurer.width(for: candidate.displayTitle)) {}
                    .disabled(true)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)

                if let rejection {
                    // Named, not hidden; the action stays out of the deck until fixed, so a
                    // half-finished button can never be pressed.
                    Label("\(rejection) — this button is not shown yet",
                          systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        // **`.onAppear` AND `.onChange(of: focusMessageOnAppear)` together.**
        // This editor is a single persistent instance across selection changes (no
        // `.id()`), so `.onAppear` fires once for the pane's lifetime. Every later
        // `addAction()` changes `focusMessageOnAppear` on an instance that never
        // re-appears, which only `.onChange` observes.
        .onAppear {
            if focusMessageOnAppear {
                messageFocused = true
                onConsumeFocusRequest()
            }
        }
        .onChange(of: focusMessageOnAppear) { _, shouldFocus in
            if shouldFocus {
                messageFocused = true
                onConsumeFocusRequest()
            }
        }
        // No `.onChange(of: action)` here: committing the OLD selection's draft
        // and reseeding for the new one happens in `DeckSettingsView.actionsPane`
        // (the draft lives on that view).
        //
        // The window stopped being the active one (a click back to the deck, a
        // switch to another app, or this window closing). All three are a person
        // finishing with this pane, and none moves `@FocusState` (measured).
        .onChange(of: controlActiveState) { _, state in
            if state == .inactive { commitPending() }
        }
    }
}

// -------------------------------------------------------------- hold budget

/// The connection pane's drift row, alone: an installed hold timeout that does
/// not match the configured budget, with the same repair the empty-state card
/// offers. `drift` mirrors `SettingsMerge.timeoutDrift`'s return shape; `nil`,
/// or a drift whose `installed` is `nil`, renders nothing.
///
/// Extracted so a render test can drive "drift present" and "absent" with a
/// plain value (`DeckRuntime.connectionDrift` comes only from a real config
/// read and has no test setter).
struct HoldTimeoutDriftNotice: View {
    let drift: (installed: Int?, expected: Int)?
    let onRepair: () -> Void

    var body: some View {
        if let drift, drift.installed != nil {
            HStack {
                Label("The installed hold timeout doesn't match this setting",
                      systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Spacer(minLength: 8)
                Button("Repair", action: onRepair)
                    .font(.caption)
            }
        }
    }
}

/// The hold-budget picker, alone: takes the current value and a change
/// handler rather than a `DeckRuntime`, so it is render-testable.
///
/// **The off-preset row.** A `Picker` whose `selection` matches none of its
/// tags renders with nothing chosen, so a hand-edited prefs file carrying,
/// say, `.seconds(45)` would leave the control showing no selection while a
/// non-default budget is in force. One extra row for the current value,
/// appearing only when it is not a shipped preset, fixes that.
struct HoldBudgetPicker: View {
    let budget: HoldBudget
    let onChange: (HoldBudget) -> Void

    private static let presets: [HoldBudget] = [.seconds(120), .seconds(300), .seconds(600), .untilAnswered]

    var body: some View {
        Picker("Hold budget", selection: Binding(get: { budget }, set: { onChange($0) })) {
            Text("2 minutes").tag(HoldBudget.seconds(120))
            Text("5 minutes").tag(HoldBudget.seconds(300))
            Text("10 minutes").tag(HoldBudget.seconds(600))
            Text("Until answered").tag(HoldBudget.untilAnswered)
            if !Self.presets.contains(budget) {
                Text(Self.offPresetLabel(budget)).tag(budget)
            }
        }
    }

    /// "Current: 45 seconds", in whole seconds. Only the shipped presets earn a
    /// rounder label; an off-preset value came from somewhere this picker did not
    /// offer, so the plain number is the honest label. `.untilAnswered` is always
    /// a preset; its case keeps the switch exhaustive as `HoldBudget` grows.
    static func offPresetLabel(_ budget: HoldBudget) -> String {
        switch budget {
        case .seconds(let n): return "Current: \(n) second\(n == 1 ? "" : "s")"
        case .untilAnswered:  return "Current: until answered"
        }
    }
}

/// **`HoldBudgetPicker`'s idiom, not `HoldBudgetPicker` itself.** A
/// question's budget is its own preference, with its own floor
/// (`HoldBudget.questionFloorSeconds`, 3s, against the permission budget's
/// 10s) and default (`HoldBudget.questionStandard`, 8s), which
/// `HoldBudgetPicker`'s hardcoded 2/5/10-minute presets do not cover. It
/// shares the structure (a `Picker` of tagged presets plus the off-preset
/// rescue row), not the type.
struct QuestionHoldBudgetPicker: View {
    let budget: HoldBudget
    let onChange: (HoldBudget) -> Void

    private static let presets: [HoldBudget] = [.seconds(5), .seconds(8), .seconds(15),
                                                 .seconds(30), .untilAnswered]

    var body: some View {
        Picker("Question hold budget", selection: Binding(get: { budget }, set: { onChange($0) })) {
            Text("5 seconds").tag(HoldBudget.seconds(5))
            Text("8 seconds (default)").tag(HoldBudget.seconds(8))
            Text("15 seconds").tag(HoldBudget.seconds(15))
            Text("30 seconds").tag(HoldBudget.seconds(30))
            Text("Until answered").tag(HoldBudget.untilAnswered)
            if !Self.presets.contains(budget) {
                Text(Self.offPresetLabel(budget)).tag(budget)
            }
        }
    }

    /// "Current: 12 seconds", same wording as `HoldBudgetPicker.offPresetLabel`.
    /// An off-preset value is most likely a hand-edited prefs file clamped to the
    /// 3s floor rather than to a shipped preset.
    static func offPresetLabel(_ budget: HoldBudget) -> String {
        switch budget {
        case .seconds(let n): return "Current: \(n) second\(n == 1 ? "" : "s")"
        case .untilAnswered:  return "Current: until answered"
        }
    }
}
