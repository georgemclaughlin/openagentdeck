//
//  SettingsActionsTests.swift · Tests/DeckAppTests
//
//  Q3's own plumbing, driven through the same seam `PrefsPersistenceTests`
//  already uses: `DeckRuntime.setPrefs`, and `PrefsStore.load` to read back
//  the throwaway suite's actual bytes (`markStartedForTesting()` points
//  `prefsDefaults` at one — that file's own comment states it, and this one
//  leans on the identical fact rather than restating it).
//
//  Most RULES are pure and tested core-side: the reorder arithmetic
//  (`QuickAction.moved`) and the title commit's trim-and-clamp
//  (`QuickAction.commitTitle`), both in `QuickActionTests` (`DeckCoreTests`).
//  **Everything here that is a RULE rather than WIRING lives
//  DeckApp-side instead**, on the two types that own it:
//
//    - `QuickActionDetailEditor` (`SettingsView.swift`) — the selected
//      button's own draft/commit machinery: `resolvedTitle(for:)`,
//      `clampedInput(_:storedTitle:)`, `committedTitle(for:draftTitle:)`,
//      `pendingCommit(for:draftTitle:draftMessage:draftPattern:)`,
//      `scopeCommit(for:draftTitle:draftMessage:isFolder:pattern:)`,
//      `prefilledPattern(forDirectory:)`,
//      `patternOnSwitchingToFolders(draftPattern:directory:)` and
//      `matchSummary(forPattern:among:)`. None of it can live in `DeckCore`
//      — it reasons about an EDITOR's draft state, which core has no notion
//      of — and none of it can be exercised through the boundaries that call
//      it, since `@FocusState`, `\.controlActiveState` and a live `List`
//      selection are SwiftUI's to deliver and none of the three can be
//      driven headlessly. So every one of them is `static` and tested
//      directly, in the sections that carry their names.
//    - `DeckSettingsView` itself — the LIST-level rules `addAction`/
//      `removeSelected`/`duplicateSelected` decide by calling:
//      `selectionAfterRemoving(_:from:)`, `restored(_:at:into:)`,
//      `duplicated(_:among:)`, and the recursive undo/redo pair
//      `registerRemovalUndo(of:at:manager:runtime:)`/
//      `registerRemovalRedo(...)`.
//
//  The rest of this file is still WIRING: what `DeckSettingsView`'s own
//  closures — `masterList`'s `.onMove`, `detail`'s `onCommit`,
//  `removeSelected`'s body — do around those rules. Those closures are
//  literals inside a `View`'s body/methods with no seam of their own to call
//  directly, so this file replicates their exact shape rather than reaching
//  into them, and drives it through the REAL `setPrefs` → reducer →
//  equality-guarded save → disk path, the same way a live drag, a live
//  commit or a live delete would. A bug in the WIRING — reading the wrong
//  array, keying a lookup on the wrong field, forgetting the write — would
//  pass every rule-side test and fail only here.
//
//  **Undo/redo ARE driven end to end here, through a REAL `UndoManager` —
//  an earlier draft of this comment claimed there was "no seam to construct
//  one headlessly," and that claim was wrong.**
//  `UndoManager` is a plain Foundation object: it needs no window and no
//  SwiftUI environment, only `import Foundation`. `registerRemovalUndo(of:
//  at:manager:runtime:)` takes the manager and the runtime as EXPLICIT
//  parameters for exactly this reason — `DeckSettingsView` never reaches
//  into `\.undoManager` itself except at the one call site
//  (`removeSelected`) that has an environment to read; the function it calls
//  is free of that dependency and this file drives it directly, the same
//  "replicate the caller's own shape" idiom every other wiring test here
//  already uses. Finding this gap the first time would very likely have
//  caught the redo hazard (finding 3, below) on its own.
//

import Testing
import Foundation
import DeckCore
import DeckAdapters
@testable import DeckApp

@MainActor
struct SettingsActionsTests {

    /// `markStartedForTesting()` itself points `prefsDefaults` at a fresh
    /// throwaway `UserDefaults` suite — `PrefsPersistenceTests`'s own
    /// `spyDefaults()` doc comment states the ordering this depends on: call
    /// it before touching `prefsDefaults`, never after.
    private func freshRuntime() -> DeckRuntime {
        let runtime = DeckRuntime()
        runtime.markStartedForTesting()
        return runtime
    }

    private func actions(_ ids: String...) -> [QuickAction] {
        ids.map { QuickAction(id: $0, title: $0, kind: .prompt($0)) }
    }

    /// A minimal, obviously-synthetic `LaneView` — only `directory` varies
    /// across the fixtures below, which is the only field `matchSummary`
    /// and the pattern pre-fill ever read.
    private func lane(_ id: String, directory: String?) -> LaneView {
        LaneView(session: SessionID(id), state: .idle, isExpanded: false,
                 contextPercent: nil, sources: [:],
                 directory: Redacted(optional: directory))
    }

    // -------------------------------------------------------------- reorder

    /// **`masterList`'s own `.onMove` closure, replicated and driven end to
    /// end.** Not just `QuickAction.moved`'s own pure arithmetic
    /// (`QuickActionTests`), but the whole path a drag actually takes: the
    /// reducer, the equality-guarded save, and disk — read back through
    /// `PrefsStore.load`, the same throwaway-suite bytes any other consumer
    /// would see. The closure BODY is unchanged from the `Form`-hosted
    /// version this phase replaced — the fix was swapping the CONTAINER
    /// (`List`, not `Form`; `DeckSettingsView.masterList`'s own doc comment
    /// states why), never this arithmetic.
    @Test("a reorder persists the new order through setPrefs, to disk")
    func reorderPersistsThroughSetPrefs() {
        let runtime = freshRuntime()
        var prefs = runtime.prefs
        prefs.quickActions = actions("a", "b", "c", "d")
        runtime.setPrefs(prefs)

        // The exact shape `masterList`'s `.onMove` closure runs: whole-value
        // read, `QuickAction.moved`, whole-value write.
        var p = runtime.prefs
        p.quickActions = QuickAction.moved(p.quickActions, fromOffsets: [0], toOffset: 3)
        runtime.setPrefs(p)

        #expect(runtime.prefs.quickActions.map(\.id) == ["b", "c", "a", "d"],
                "the reordered array did not reach runtime.prefs")
        let onDisk = PrefsStore.load(from: runtime.prefsDefaults)
        #expect(onDisk.quickActions.map(\.id) == ["b", "c", "a", "d"],
                "the reordered array round-tripped through the runtime but not through disk")
    }

    // --------------------------------------------------------------- remove

    /// **`removeSelected`'s own shape — index-based, not `removeAll`, and
    /// the neighbour is computed BEFORE the row is gone.** The earlier remove
    /// closure keyed on id alone (`removeAll { $0.id == id }`); the current
    /// `removeSelected` additionally has a SELECTION to move and an undo
    /// entry to register, so it looks the row up by id, captures its index,
    /// asks `selectionAfterRemoving` against the array as it still stands,
    /// and only then removes — the exact order `DeckSettingsView
    /// .selectionAfterRemoving`'s own doc comment states matters.
    @Test("remove takes out the selected row and selects its neighbour")
    func removeTakesTheSelectedRowAndItsNeighbour() {
        let runtime = freshRuntime()
        var prefs = runtime.prefs
        prefs.quickActions = actions("zeta-fixture", "yankee-fixture", "xray-fixture")
        runtime.setPrefs(prefs)

        let selectedID = "yankee-fixture"
        var p = runtime.prefs
        let index = p.quickActions.firstIndex(where: { $0.id == selectedID })!
        let next = DeckSettingsView.selectionAfterRemoving(selectedID, from: p.quickActions)
        p.quickActions.remove(at: index)
        runtime.setPrefs(p)

        #expect(runtime.prefs.quickActions.map(\.id) == ["zeta-fixture", "xray-fixture"],
                "the removal did not reach runtime.prefs")
        #expect(next == "xray-fixture",
                "deleting the MIDDLE row should select its neighbour, not merely something")
        let onDisk = PrefsStore.load(from: runtime.prefsDefaults)
        #expect(onDisk.quickActions.map(\.id) == ["zeta-fixture", "xray-fixture"],
                "the removal round-tripped through the runtime but not through disk")
    }

    // --------------------------------------------------------------- commit

    /// **`detail`'s own `onCommit` closure, applied at whatever index the
    /// row actually holds now.** Built the way `DeckSettingsView.detail`
    /// builds it: find the row by id, splice the updated value in at ITS
    /// index — not an index captured earlier, which a reorder or an earlier
    /// removal may have since moved. Unchanged since Q3: master–detail
    /// replaced WHO calls this closure (one shared editor instead of one per
    /// row) but not the closure's own shape.
    @Test("commit updates the row with the matching id, not a captured index")
    func commitUpdatesTheRightRowByID() {
        let runtime = freshRuntime()
        var prefs = runtime.prefs
        prefs.quickActions = actions("a", "b", "c")
        runtime.setPrefs(prefs)

        let updated = QuickAction(id: "b", title: "Renamed B", kind: .prompt("go"))
        // `detail`'s own `onCommit` closure, verbatim.
        var p = runtime.prefs
        if let i = p.quickActions.firstIndex(where: { $0.id == updated.id }) {
            p.quickActions[i] = updated
            runtime.setPrefs(p)
        }

        #expect(runtime.prefs.quickActions.map(\.displayTitle) == ["a", "Renamed B", "c"],
                "the commit landed on the wrong row, or not at all")
    }

    /// **The race `onCommit`'s own `if let` guards against.** A row commits
    /// on focus loss, which is asynchronous with respect to any OTHER
    /// control on the pane — if this row's own action was removed in the
    /// meantime (Remove tapped, then the field's blur lands a moment later),
    /// the id is simply not found any more and the commit is silently
    /// dropped: never re-inserted at the end, never written over a
    /// different row that happens to occupy the old index.
    @Test("a commit for a row that no longer exists is silently dropped, not misapplied")
    func commitForARemovedRowIsDropped() {
        let runtime = freshRuntime()
        var prefs = runtime.prefs
        prefs.quickActions = actions("a", "b", "c")
        runtime.setPrefs(prefs)

        let staleCommit = QuickAction(id: "ghost", title: "Too Late", kind: .prompt("go"))
        var p = runtime.prefs
        if let i = p.quickActions.firstIndex(where: { $0.id == staleCommit.id }) {
            p.quickActions[i] = staleCommit
            runtime.setPrefs(p)
        }

        #expect(runtime.prefs.quickActions.map(\.id) == ["a", "b", "c"],
                "a commit for a row with no matching id changed the stored set anyway")
    }

    // ------------------------------------------------- the commit decision
    //
    // `QuickActionDetailEditor.pendingCommit(for:draftTitle:draftMessage:
    // draftPattern:)` is the pure rule behind every FOCUS/window commit
    // boundary the editor has. The boundaries are SwiftUI's to deliver and
    // cannot be driven headlessly; what this rule decides, once delivered,
    // is entirely testable — and it is where the hazards live.

    @Test("nothing dirty commits nothing")
    func pendingCommitIsNilWhenBothDraftsMatch() {
        let stored = QuickAction(id: "a", title: "Continue", kind: .prompt("Continue"))
        #expect(QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "Continue",
                                                       draftMessage: "Continue", draftPattern: "") == nil)
    }

    @Test("a dirty title alone commits the title and leaves the message alone")
    func pendingCommitCarriesTheTitle() {
        let stored = QuickAction(id: "a", title: "Continue", kind: .prompt("Continue"))
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "Keep going",
                                                             draftMessage: "Continue", draftPattern: "")
        #expect(updated?.title == "Keep going")
        #expect(updated?.payload == "Continue", "the message changed when only the title was edited")
    }

    @Test("a dirty message alone commits the message and leaves the title alone")
    func pendingCommitCarriesTheMessage() {
        let stored = QuickAction(id: "a", title: "Continue", kind: .prompt("Continue"))
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "Continue",
                                                             draftMessage: "Carry on", draftPattern: "")
        #expect(updated?.title == "Continue")
        #expect(updated?.payload == "Carry on")
    }

    /// **The hazard the window boundary made reachable, Q3.** Every FOCUS
    /// boundary alone can only ever have ONE draft dirty — you cannot type
    /// into the message field without the title field having lost focus
    /// first. A window going inactive fires with BOTH drafts possibly dirty,
    /// so a naive pair of independent commit functions would have written
    /// one draft back over the other. One write, built from every draft at
    /// once, cannot express that.
    @Test("every dirty draft commits together, none overwriting another")
    func pendingCommitCarriesEveryDraftAtOnce() {
        let stored = QuickAction(id: "a", title: "Continue", kind: .prompt("Continue"))
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "Status",
                                                             draftMessage: "/status", draftPattern: "")
        #expect(updated?.title == "Status", "the title was lost when the message committed with it")
        #expect(updated?.payload == "/status", "the message was lost when the title committed with it")
    }

    /// **The hazard a boundary that fires for EVERY row created.** The
    /// message field only ever existed on `.prompt` rows, so a naive
    /// `draftMessage != action.payload` test is safe only by construction on
    /// a `.prompt`-only boundary. It is not safe on a boundary every row
    /// receives: an escape row seeds its message draft from `action.payload
    /// ?? ""` — nil — so that comparison is true for every escape button
    /// that never had a message at all, and the interrupt would have been
    /// silently rewritten into a prompt sending the empty string. The rule
    /// tests `action.kind` instead.
    @Test("an escape row is never rewritten into a prompt by the window boundary")
    func pendingCommitNeverConvertsAnEscapeRow() {
        let escape = QuickAction(id: "escape", title: "Escape Key", kind: .escape)
        #expect(QuickActionDetailEditor.pendingCommit(for: escape, draftTitle: "Escape Key",
                                                       draftMessage: "", draftPattern: "") == nil,
                "an untouched escape row committed anyway")

        let renamed = QuickActionDetailEditor.pendingCommit(for: escape, draftTitle: "Interrupt",
                                                             draftMessage: "", draftPattern: "")
        #expect(renamed?.title == "Interrupt")
        #expect(renamed?.kind == .escape, "renaming an escape row turned it into a prompt")
        #expect(renamed?.payload == nil)
    }

    /// The clamp-and-trim rule (`QuickAction.commitTitle`) applies at this
    /// boundary too, not only at the field's own live input clamp — a title
    /// that arrives here with trailing whitespace commits trimmed, and one
    /// past `editorTitleCap` commits clamped.
    @Test("the committed title goes through commitTitle, not the raw draft")
    func pendingCommitClampsAndTrims() {
        let stored = QuickAction(id: "a", title: "Go", kind: .prompt("go"))
        let padded = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "  Continue  ",
                                                            draftMessage: "go", draftPattern: "")
        #expect(padded?.title == "Continue")

        let long = String(repeating: "x", count: QuickAction.editorTitleCap + 20)
        let clamped = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: long,
                                                             draftMessage: "go", draftPattern: "")
        #expect(clamped?.title?.count == QuickAction.editorTitleCap)
    }

    /// A draft that differs from the stored title ONLY by whitespace commits
    /// nothing: `commitTitle` trims it back to what is already stored, so the
    /// rule sees no change. Without this, every window deactivation would
    /// write identical bytes through the reducer and to disk.
    @Test("a whitespace-only difference is not a change")
    func pendingCommitIgnoresAWhitespaceOnlyEdit() {
        let stored = QuickAction(id: "a", title: "Continue", kind: .prompt("Continue"))
        #expect(QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "Continue   ",
                                                       draftMessage: "Continue", draftPattern: "") == nil)
    }

    /// **A NON-CANONICAL STORED TITLE, UNTOUCHED, MUST NOT COMMIT — the silent
    /// write the window boundary made reachable, and the one
    /// caught as Q3.** `QuickAction.decode` takes a stored title verbatim: it
    /// guards only that the key is a string, never trimming and never
    /// clamping. So `" Continue "`, or a title longer than `editorTitleCap`
    /// stored before that cap existed, is a real row a real prefs file can
    /// hold. An untouched draft is seeded byte-identically from that stored
    /// value; had the rule asked "is the stored title canonical" instead of
    /// "does the draft differ from what was seeded," every such row would
    /// commit the instant the window lost key, with nobody having typed
    /// anything.
    @Test("a non-canonical stored title nobody touched is not an edit",
          arguments: [" Continue ", "Continue\t"])
    func pendingCommitDoesNotRewriteAnUntouchedNonCanonicalTitle(_ storedTitle: String) {
        let stored = QuickAction(id: "a", title: storedTitle, kind: .prompt("Continue"))
        #expect(QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: storedTitle,
                                                       draftMessage: "Continue", draftPattern: "") == nil,
                "an untouched row committed because its STORED title was not canonical")
    }

    /// The same, for a stored title past `editorTitleCap` — the clamp arm of
    /// the identical hazard. Untouched, it must not be truncated behind the
    /// user's back; touched, it clamps normally (the second half).
    @Test("an over-long stored title is left alone until somebody edits it")
    func pendingCommitDoesNotClampAnUntouchedOverlongTitle() {
        let long = String(repeating: "x", count: QuickAction.editorTitleCap + 20)
        let stored = QuickAction(id: "a", title: long, kind: .prompt("go"))
        #expect(QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: long,
                                                       draftMessage: "go", draftPattern: "") == nil,
                "an untouched over-long stored title was silently truncated")

        let edited = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: long + "EDIT",
                                                            draftMessage: "go", draftPattern: "")
        #expect(edited?.title?.count == QuickAction.editorTitleCap,
                "once actually edited, the clamp must still apply")
    }

    /// **A past defect.** An earlier `pendingCommit`
    /// computed the committed title UNCONDITIONALLY — `commitTitle
    /// (draftTitle)` — gating only whether the OVERALL commit fires, never
    /// whether the TITLE half of it should canonicalise. A row whose stored
    /// title is non-canonical (padded, exactly the class
    /// `pendingCommitDoesNotRewriteAnUntouchedNonCanonicalTitle` above
    /// already pins for an OTHERWISE-untouched row), left untouched, while
    /// the user edits ONLY the message: this fixture is the case that first
    /// test's own sibling functions missed, because they all pass a
    /// MATCHING `draftMessage`, so the buggy code path never got far enough
    /// to canonicalise anything. Here the message is genuinely dirty, so the
    /// commit proceeds — and the returned title must still be BYTE-IDENTICAL
    /// to the non-canonical stored one, not silently trimmed as a side
    /// effect of a completely unrelated field being edited.
    @Test("a dirty message alone does not canonicalise an untouched non-canonical title")
    func pendingCommitDoesNotCanonicalizeATitleWhenOnlyTheMessageIsDirty() {
        let stored = QuickAction(id: "a", title: " Continue ", kind: .prompt("go"))
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: " Continue ",
                                                             draftMessage: "carry on", draftPattern: "")
        #expect(updated?.title == " Continue ",
                "an untouched non-canonical title was silently trimmed because a DIFFERENT field was dirty")
    }

    /// The same hazard, the CLAMP arm rather than the trim arm — an
    /// over-cap stored title, untouched, with only the message dirty.
    @Test("a dirty message alone does not clamp an untouched over-cap title")
    func pendingCommitDoesNotClampATitleWhenOnlyTheMessageIsDirty() {
        let long = String(repeating: "x", count: QuickAction.editorTitleCap + 20)
        let stored = QuickAction(id: "a", title: long, kind: .prompt("go"))
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: long,
                                                             draftMessage: "carry on", draftPattern: "")
        #expect(updated?.title == long,
                "an untouched over-cap title was silently clamped because a DIFFERENT field was dirty")
    }

    // -------------------------------------------------------- committedTitle
    //
    // `committedTitle(for:draftTitle:)` — the ONE place a draft title
    // becomes the value a commit stores, extracted so `pendingCommit` and
    // `scopeCommit` cannot re-diverge on it the way that
    // defect happened. Tested directly, not only through the two callers.

    @Test("committedTitle preserves an untouched title verbatim, canonical or not")
    func committedTitlePreservesAnUntouchedTitleVerbatim() {
        let stored = QuickAction(id: "a", title: " Continue ", kind: .prompt("go"))
        #expect(QuickActionDetailEditor.committedTitle(for: stored, draftTitle: " Continue ") == " Continue ")
    }

    @Test("committedTitle trims and clamps a genuinely touched title")
    func committedTitleClampsATouchedTitle() {
        let stored = QuickAction(id: "a", title: "Go", kind: .prompt("go"))
        #expect(QuickActionDetailEditor.committedTitle(for: stored, draftTitle: "  Zulu Fixture  ") == "Zulu Fixture")

        let long = String(repeating: "x", count: QuickAction.editorTitleCap + 10)
        #expect(QuickActionDetailEditor.committedTitle(for: stored, draftTitle: long)?.count
                == QuickAction.editorTitleCap)
    }

    @Test("committedTitle maps a cleared touched title to nil, never an explicit empty string")
    func committedTitleMapsAClearedTouchedTitleToNil() {
        let stored = QuickAction(id: "a", title: "Zulu Fixture", kind: .prompt("go"))
        #expect(QuickActionDetailEditor.committedTitle(for: stored, draftTitle: "   ") == nil)
    }

    // ------------------------------------------------------- scope
    //
    // `pendingCommit`'s own THIRD draft. `action.scope`'s own CASE is ground
    // truth (the Picker is instant-apply — `QuickActionDetailEditor.isFolder`'s
    // own doc comment states why); only the PATTERN TEXT is buffered here,
    // the identical reason title and message are.

    /// An untouched pattern — `draftPattern` still equal to whatever
    /// `.folders` already stores — commits nothing, the identical "raw
    /// comparison, not canonicalised" posture the title half already takes.
    @Test("an untouched folder pattern commits nothing")
    func pendingCommitIgnoresAnUntouchedPattern() {
        let stored = QuickAction(id: "a", title: "Status Check", kind: .prompt("/status"),
                                 scope: .folders("*/basecamp-fixture*"))
        #expect(QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "Status Check",
                                                       draftMessage: "/status",
                                                       draftPattern: "*/basecamp-fixture*") == nil)
    }

    /// Editing the pattern ALONE commits a new `.folders` scope, title and
    /// message carried through untouched — the pattern-only twin of
    /// `pendingCommitCarriesTheTitle`/`pendingCommitCarriesTheMessage`.
    @Test("a dirty pattern alone commits the new scope and leaves title and message alone")
    func pendingCommitCarriesThePatternAlone() {
        let stored = QuickAction(id: "a", title: "Status Check", kind: .prompt("/status"),
                                 scope: .folders("*/basecamp-fixture*"))
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "Status Check",
                                                             draftMessage: "/status",
                                                             draftPattern: "*/summit-fixture*")
        #expect(updated?.scope == .folders("*/summit-fixture*"))
        #expect(updated?.title == "Status Check")
        #expect(updated?.payload == "/status")
    }

    /// **Scope survives a title/message-only commit, every combination of
    /// `Scope` and `Kind` this arc's own review has asked for.** The three
    /// separate reconstruction sites this arc found dropping `scope` earlier
    /// (`ActionRowEditor.candidate`/`.pendingCommit`, Q3; `QuickAction
    /// .migrated`) were all found by exactly this shape of question — build
    /// a row that carries a NON-default field, run it through a commit that
    /// has no business touching that field, and check it survived. Only
    /// `.prompt` rows have a message to edit, so `.escape`/`.dialogKey`
    /// fixtures edit the title instead — either way, `scope` must come back
    /// unchanged and `kind` must come back unchanged too.
    private nonisolated static let scopeKindFixtures: [(label: String, scope: QuickAction.Scope, kind: QuickAction.Kind)] = [
        ("everywhere + prompt", .everywhere, .prompt("water the greenhouse fixture")),
        ("folders + prompt", .folders("*/greenhouse-fixture*"), .prompt("water the greenhouse fixture")),
        ("everywhere + escape", .everywhere, .escape),
        ("folders + escape", .folders("*/greenhouse-fixture*"), .escape),
        ("everywhere + dialogKey", .everywhere, .dialogKey("1")),
        ("folders + dialogKey", .folders("*/greenhouse-fixture*"), .dialogKey("1")),
    ]

    /// **All THREE drafts dirty at once — only pairs were tested before
    /// this (title+message, `pendingCommitCarriesEveryDraftAtOnce`; the
    /// message alone; the pattern alone).** The window-inactive boundary
    /// can fire with title, message AND pattern all mid-edit simultaneously
    /// (nothing stops a person from typing into all three fields across
    /// several window activations before ever losing focus to a boundary
    /// that commits), and the three-guard structure in `pendingCommit`
    /// makes no special case for "how many" are dirty — this pins that the
    /// general case actually behaves like the sum of the pairs, not like
    /// something novel two-at-a-time testing could not have caught.
    @Test("title, message and pattern all dirty at once commit together, none dropped")
    func pendingCommitCarriesAllThreeDraftsAtOnce() {
        let stored = QuickAction(id: "a", title: "Old Title", kind: .prompt("old message"),
                                 scope: .folders("*/old-fixture*"))
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "New Title",
                                                             draftMessage: "new message",
                                                             draftPattern: "*/new-fixture*")
        #expect(updated?.title == "New Title", "the title was lost when three drafts committed together")
        #expect(updated?.payload == "new message", "the message was lost when three drafts committed together")
        #expect(updated?.scope == .folders("*/new-fixture*"),
                "the pattern was lost when three drafts committed together")
    }

    @Test("scope and kind both survive a title-only commit", arguments: scopeKindFixtures)
    func pendingCommitPreservesScopeAndKind(_ fixture: (label: String, scope: QuickAction.Scope, kind: QuickAction.Kind)) {
        let stored = QuickAction(id: "fixture", title: "Original Title", kind: fixture.kind, scope: fixture.scope)
        let pattern: String = { if case .folders(let p) = fixture.scope { return p }; return "" }()
        let updated = QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: "New Title",
                                                             draftMessage: "water the greenhouse fixture",
                                                             draftPattern: pattern)
        #expect(updated?.title == "New Title", Comment(rawValue: "\(fixture.label): the title itself did not commit"))
        #expect(updated?.scope == fixture.scope,
                Comment(rawValue: "\(fixture.label): scope was dropped or altered by an unrelated title commit"))
        #expect(updated?.kind == fixture.kind,
                Comment(rawValue: "\(fixture.label): kind was altered by an unrelated title commit"))
    }

    // ---------------------------------------------------- the scope Picker
    //
    // `scopeCommit(for:draftTitle:draftMessage:isFolder:pattern:)` is the
    // INSTANT-APPLY write the radio group makes — a separate path from
    // `pendingCommit` because it fires on SELECTION, not a focus/window
    // boundary (`QuickActionDetailEditor.isFolder`'s own doc comment states
    // why scope itself is never a buffered draft).

    @Test("switching to Folders matching carries the current title and message forward")
    func scopeCommitCarriesCurrentDrafts() {
        let stored = QuickAction(id: "a", title: "Original", kind: .prompt("original message"))
        let updated = QuickActionDetailEditor.scopeCommit(for: stored, draftTitle: "Original",
                                                           draftMessage: "original message",
                                                           isFolder: true, pattern: "*/delta-fixture*")
        #expect(updated.scope == .folders("*/delta-fixture*"))
        #expect(updated.title == "Original")
        #expect(updated.payload == "original message")
    }

    @Test("switching back to Every session drops the pattern but keeps everything else")
    func scopeCommitClearsScopeOnEverywhere() {
        let stored = QuickAction(id: "a", title: "Original", kind: .prompt("original message"),
                                 scope: .folders("*/delta-fixture*"))
        let updated = QuickActionDetailEditor.scopeCommit(for: stored, draftTitle: "Original",
                                                           draftMessage: "original message",
                                                           isFolder: false, pattern: "*/delta-fixture*")
        #expect(updated.scope == .everywhere)
        #expect(updated.title == "Original")
    }

    /// **Kind survives a scope-only write, across all three kinds** — the
    /// `scopeCommit` twin of `pendingCommitPreservesScopeAndKind` above.
    @Test("kind survives a scope-only commit", arguments: [
        QuickAction.Kind.prompt("carry the crate fixture"), .escape, .dialogKey("2"),
    ])
    func scopeCommitPreservesKind(_ kind: QuickAction.Kind) {
        let stored = QuickAction(id: "a", title: "Fixture Title", kind: kind)
        let updated = QuickActionDetailEditor.scopeCommit(for: stored, draftTitle: "Fixture Title",
                                                           draftMessage: stored.payload ?? "",
                                                           isFolder: true, pattern: "*/crate-fixture*")
        #expect(updated.kind == kind)
    }

    /// **The hazard found while designing this function, not by a later
    /// review — restated here because it is exactly this arc's own
    /// class of bug.** The Picker's write is INSTANT, independent of the
    /// title/message drafts' own commit boundary; a first draft of
    /// `commitScope` built its write from `action`'s own STORED title,
    /// which is correct only if nothing else was mid-edit. Flipping the
    /// radio does not take focus away from a field the user is actively
    /// typing into, so a half-typed title must be carried into the SAME
    /// write the scope change makes, not silently overwritten a moment
    /// later when the resulting model change reseeds the draft back to the
    /// stale stored value.
    @Test("switching scope mid-edit carries the in-progress title, not the stale stored one")
    func scopeCommitCarriesAnInProgressTitleEdit() {
        let stored = QuickAction(id: "a", title: "Old Title", kind: .prompt("old message"))
        // The user is mid-typing a new title when they click the radio —
        // `draftTitle` is already "New Title" but nothing has committed it.
        let updated = QuickActionDetailEditor.scopeCommit(for: stored, draftTitle: "New Title",
                                                           draftMessage: "old message",
                                                           isFolder: true, pattern: "*/echo-fixture*")
        #expect(updated.title == "New Title",
                "the scope click silently discarded an in-progress title edit")
        #expect(updated.scope == .folders("*/echo-fixture*"))
    }

    /// The MESSAGE half of the identical hazard — only the title-in-flight
    /// case was pinned before this (`scopeCommitCarriesAnInProgressTitleEdit`).
    /// `scopeCommit` tests `action.kind`, not a raw equality with a stored
    /// payload that does not exist for `.escape`, so this specifically needs
    /// a `.prompt` fixture to have a message worth losing.
    @Test("switching scope mid-edit carries the in-progress message, not the stale stored one")
    func scopeCommitCarriesAnInProgressMessageEdit() {
        let stored = QuickAction(id: "a", title: "Fixture Title", kind: .prompt("old message"))
        let updated = QuickActionDetailEditor.scopeCommit(for: stored, draftTitle: "Fixture Title",
                                                           draftMessage: "new in-progress message",
                                                           isFolder: true, pattern: "*/golf-fixture*")
        #expect(updated.payload == "new in-progress message",
                "the scope click silently discarded an in-progress message edit")
        #expect(updated.scope == .folders("*/golf-fixture*"))
    }

    /// **An untouched non-canonical title must not be canonicalised as a
    /// side effect of an unrelated scope click** — `scopeCommit`'s own twin
    /// of `pendingCommitDoesNotRewriteAnUntouchedNonCanonicalTitle`. Clicking
    /// a radio button is not "editing the title," and the title comparison
    /// here is the same RAW one `pendingCommit` uses for the identical
    /// reason.
    @Test("an untouched non-canonical title is not canonicalised by a scope-only commit")
    func scopeCommitDoesNotCanonicalizeAnUntouchedTitle() {
        let stored = QuickAction(id: "a", title: " Continue ", kind: .prompt("go"))
        let updated = QuickActionDetailEditor.scopeCommit(for: stored, draftTitle: " Continue ",
                                                           draftMessage: "go",
                                                           isFolder: true, pattern: "*/foxtrot-fixture*")
        #expect(updated.title == " Continue ",
                "an untouched title was canonicalised merely because the scope radio was clicked")
    }

    // ------------------------------------------------------ the pattern pre-fill
    //
    // `prefilledPattern(forDirectory:)` — `*/<last path component>*`, the
    // the documented worked-example shape, derived from whichever directory the
    // deck's own selection sits in so nobody has to author a glob by hand.

    @Test("no directory pre-fills nothing")
    func prefilledPatternIsEmptyWithNoDirectory() {
        #expect(QuickActionDetailEditor.prefilledPattern(forDirectory: nil) == "")
    }

    @Test("an ordinary directory pre-fills */<last component>*")
    func prefilledPatternDerivesFromTheLastComponent() {
        #expect(QuickActionDetailEditor.prefilledPattern(forDirectory: "/Users/fixture/code/zephyr-harbor")
                == "*/zephyr-harbor*")
    }

    @Test("a trailing slash derives the same pattern as no trailing slash")
    func prefilledPatternHandlesATrailingSlash() {
        #expect(QuickActionDetailEditor.prefilledPattern(forDirectory: "/Users/fixture/code/zephyr-harbor/")
                == "*/zephyr-harbor*")
    }

    @Test("the bare root has no component to name a project with, and pre-fills nothing")
    func prefilledPatternIsEmptyForTheRoot() {
        #expect(QuickActionDetailEditor.prefilledPattern(forDirectory: "/") == "",
                "a bare root pre-filling */*  would silently mean \"every directory\"")
    }

    // ---------------------------------------------- preserve, don't lose
    //
    // The requirement: switching "Folders matching" off and back
    // on within the SAME editing session must not lose a pattern already
    // typed. `patternOnSwitchingToFolders` is the pure decision behind the
    // Picker's `set` — PRESERVE, chosen over discard-and-rederive, and
    // pinned here.

    @Test("a pattern already typed survives switching away and back, unrelated to the directory")
    func patternOnSwitchingToFoldersPreservesATypedPattern() {
        let preserved = QuickActionDetailEditor.patternOnSwitchingToFolders(
            draftPattern: "*/golf-fixture*", directory: "/Users/fixture/code/hotel-fixture")
        #expect(preserved == "*/golf-fixture*",
                "a pattern the user already typed was re-derived from the directory instead of kept")
    }

    @Test("an empty draft falls back to the directory pre-fill")
    func patternOnSwitchingToFoldersFallsBackToThePrefill() {
        let derived = QuickActionDetailEditor.patternOnSwitchingToFolders(
            draftPattern: "", directory: "/Users/fixture/code/india-fixture")
        #expect(derived == "*/india-fixture*")
    }

    // ------------------------------------------------------- the match count
    //
    // `matchSummary(forPattern:among:)` — the pane's single highest-value
    // control, extracted so the "N of M" claim is provable without a live
    // `DeckRuntime`/`Frame` behind it. Fixtures below are entirely
    // synthetic session ids and paths.

    @Test("the match count is N of M, counting only lanes with a matching directory")
    func matchSummaryCountsMatchingLanes() {
        let lanes = [
            lane("fixture-1", directory: "/Users/fixture/code/juliet-fixture"),
            lane("fixture-2", directory: "/Users/fixture/code/mike-fixture"),
            lane("fixture-3", directory: "/Users/fixture/code/kilo-fixture"),
            lane("fixture-4", directory: nil),
        ]
        let summary = QuickActionDetailEditor.matchSummary(forPattern: "*/juliet-fixture*", among: lanes)
        #expect(summary.matches == 1, "only the one lane whose directory actually names juliet-fixture should count")
        #expect(summary.total == 4, "the total must count every open lane, matching or not")
    }

    /// **A trailing `*` matches any SUFFIX too, not only the bare literal —
    /// worth pinning on its own, since it is the one property of `Glob
    /// .matches` easiest to misjudge when reading a match COUNT rather than
    /// a single yes/no.** `*/juliet-fixture*` is "contains the literal
    /// `juliet-fixture` anywhere," by `Glob`'s own doc comment — so a lane
    /// whose directory merely EXTENDS the name (`juliet-fixture-annex`)
    /// counts too, exactly as it would if a person read the pattern by eye
    /// and asked "does this directory mention juliet-fixture."
    @Test("a trailing wildcard also counts a directory that only extends the pattern's own literal")
    func matchSummaryCountsASuffixExtensionToo() {
        let lanes = [
            lane("fixture-1", directory: "/Users/fixture/code/juliet-fixture"),
            lane("fixture-2", directory: "/Users/fixture/code/juliet-fixture-annex"),
        ]
        let summary = QuickActionDetailEditor.matchSummary(forPattern: "*/juliet-fixture*", among: lanes)
        #expect(summary.matches == 2,
                "a trailing * should match a directory that merely extends the literal, not only the exact name")
    }

    @Test("a lane with no directory never matches, fail-closed")
    func matchSummaryNeverMatchesADirectorylessLane() {
        let lanes = [lane("fixture-1", directory: nil)]
        let summary = QuickActionDetailEditor.matchSummary(forPattern: "*", among: lanes)
        #expect(summary.matches == 0, "a directoryless lane matched even a bare wildcard")
        #expect(summary.total == 1)
    }

    @Test("a pattern matching none reports zero of M, not an error")
    func matchSummaryReportsZeroForANonMatchingPattern() {
        let lanes = [
            lane("fixture-1", directory: "/Users/fixture/code/lima-fixture"),
            lane("fixture-2", directory: "/Users/fixture/code/mike-fixture"),
        ]
        let summary = QuickActionDetailEditor.matchSummary(forPattern: "*/nowhere-fixture*", among: lanes)
        #expect(summary.matches == 0)
        #expect(summary.total == 2)
    }

    // ------------------------------------------------------------ reset re-seed

    /// **Reset to Defaults must not be undone by a later deactivation.**
    /// `DeckSettingsView.footer`'s Reset button replaces the whole array; the
    /// editor's own `.onChange(of: action)` re-seeds every draft (title,
    /// message and pattern) from the new stored value when the id stays the
    /// same (Reset never changes ids). This pins the state that re-seed
    /// leaves behind: drafts equal to the shipped row, so the window
    /// boundary firing afterwards finds nothing pending and cannot
    /// resurrect the edit that was just reset away.
    @Test("after a reset re-seeds the drafts, the window boundary has nothing to commit")
    func pendingCommitFindsNothingAfterAReseed() {
        let shipped = QuickAction.shipped.first { $0.id == "compact" }!
        // Exactly what `.onChange(of: action)` assigns.
        #expect(QuickActionDetailEditor.pendingCommit(
            for: shipped,
            draftTitle: QuickActionDetailEditor.resolvedTitle(for: shipped),
            draftMessage: shipped.payload ?? "",
            draftPattern: QuickActionDetailEditor.storedPattern(for: shipped)) == nil)
    }

    // ------------------------------------------------ derived titles

    @Test("resolvedTitle resolves to the explicit title, or empty string when derived — never the derived text")
    func resolvedTitleIsExplicitOrEmpty() {
        let explicit = QuickAction(id: "a", title: "My Label", kind: .prompt("do a thing"))
        #expect(QuickActionDetailEditor.resolvedTitle(for: explicit) == "My Label")

        let derived = QuickAction(id: "b", title: nil, kind: .prompt("do a thing"))
        #expect(QuickActionDetailEditor.resolvedTitle(for: derived) == "",
                Comment(rawValue: "a derived row's resolvedTitle must be empty, not the text displayTitle would "
                        + "derive — that text is the field's PLACEHOLDER, not its value"))
    }

    @Test("an untouched derived row's draft — the empty string — commits nothing")
    func pendingCommitFindsNothingForAnUntouchedDerivedRow() {
        let derived = QuickAction(id: "b", title: nil, kind: .prompt("Ship it"))
        #expect(QuickActionDetailEditor.pendingCommit(for: derived, draftTitle: "", draftMessage: "Ship it",
                                                       draftPattern: "") == nil,
                "an untouched derived row must not read as touched merely because its draft resolves to empty")
    }

    @Test("typing the derived text by hand is a real edit, not a no-op")
    func pendingCommitTreatsATypedDerivedTitleAsTouched() {
        let derived = QuickAction(id: "b", title: nil, kind: .prompt("Ship it"))
        let updated = QuickActionDetailEditor.pendingCommit(for: derived, draftTitle: "Ship it",
                                                             draftMessage: "Ship it", draftPattern: "")
        #expect(updated?.title == "Ship it",
                Comment(rawValue: "typing the placeholder's own text by hand should store it explicitly, not be "
                        + "swallowed as untouched"))
    }

    @Test("clearing a title field back to blank commits nil, not an explicit empty string")
    func pendingCommitMapsABlankDraftTitleToNil() {
        let explicit = QuickAction(id: "a", title: "My Label", kind: .prompt("Ship it"))
        let cleared = QuickActionDetailEditor.pendingCommit(for: explicit, draftTitle: "   ",
                                                             draftMessage: "Ship it", draftPattern: "")
        #expect(cleared?.title == nil,
                Comment(rawValue: "a cleared (whitespace-only) title draft must commit as derived (nil), not as "
                        + "an explicit empty string"))
    }

    // ------------------------------------------------------- the live clamp, and Escape

    @Test("typing past the cap is clamped")
    func clampedInputBoundsTyping() {
        let long = String(repeating: "x", count: QuickAction.editorTitleCap + 40)
        #expect(QuickActionDetailEditor.clampedInput(long, storedTitle: "Continue").count
                == QuickAction.editorTitleCap)
    }

    @Test("a draft that is exactly the stored title is left alone, cap or no cap")
    func clampedInputNeverEditsTheStoredValue() {
        let overCap = String(repeating: "x", count: QuickAction.editorTitleCap + 20)
        #expect(QuickActionDetailEditor.clampedInput(overCap, storedTitle: overCap) == overCap,
                "the clamp cut down a value the model itself supplied")
        #expect(QuickActionDetailEditor.clampedInput("Continue", storedTitle: "Continue") == "Continue")
    }

    /// **The whole Escape path, composed — the sequence, not just its parts.**
    /// `.onExitCommand` assigns `QuickActionDetailEditor.resolvedTitle(for:
    /// action)` into the draft; the live clamp runs on that assignment; then
    /// a commit boundary evaluates. Chaining the two pure rules in that
    /// order is what proves the gesture is inert.
    @Test("Escape on a row with an over-cap stored title reverts and commits nothing")
    func escapeIsInertOnAnOverCapStoredTitle() {
        let overCap = String(repeating: "x", count: QuickAction.editorTitleCap + 20)
        let stored = QuickAction(id: "a", title: overCap, kind: .prompt("go"))

        let whileTyping = QuickActionDetailEditor.clampedInput(overCap + "EDIT", storedTitle: overCap)
        #expect(whileTyping.count == QuickAction.editorTitleCap)

        let storedTitle = QuickActionDetailEditor.resolvedTitle(for: stored)
        let reverted = QuickActionDetailEditor.clampedInput(storedTitle, storedTitle: storedTitle)
        #expect(reverted == overCap, "the revert was clamped and no longer matches the model")

        #expect(QuickActionDetailEditor.pendingCommit(for: stored, draftTitle: reverted,
                                                       draftMessage: "go", draftPattern: "") == nil,
                "Escape left a pending commit that would truncate the stored title")
    }

    // ----------------------------------------------------- selection after delete
    //
    // `DeckSettingsView.selectionAfterRemoving(_:from:)` — a sensible
    // NEIGHBOUR, not merely "not nil": a middle delete selects what was
    // next, the last delete selects the new last, the only row selects nil.

    @Test("deleting a middle row selects its neighbour, not the first row")
    func selectionAfterRemovingAMiddleRowSelectsTheNeighbour() {
        let set = actions("november-fixture", "oscar-fixture", "papa-fixture")
        #expect(DeckSettingsView.selectionAfterRemoving("oscar-fixture", from: set) == "papa-fixture")
    }

    @Test("deleting the last row selects the new last")
    func selectionAfterRemovingTheLastRowSelectsTheNewLast() {
        let set = actions("quebec-fixture", "romeo-fixture", "sierra-fixture")
        #expect(DeckSettingsView.selectionAfterRemoving("sierra-fixture", from: set) == "romeo-fixture")
    }

    @Test("deleting the only row selects nil")
    func selectionAfterRemovingTheOnlyRowSelectsNil() {
        let set = actions("tango-fixture")
        #expect(DeckSettingsView.selectionAfterRemoving("tango-fixture", from: set) == nil)
    }

    @Test("deleting the first row selects the neighbour that took its place")
    func selectionAfterRemovingTheFirstRowSelectsTheNewFirst() {
        let set = actions("uniform-fixture", "victor-fixture", "whiskey-fixture")
        #expect(DeckSettingsView.selectionAfterRemoving("uniform-fixture", from: set) == "victor-fixture")
    }

    // -------------------------------------------------------------------- undo
    //
    // `DeckSettingsView.restored(_:at:into:)` — the pure half of undo's own
    // registration. Returns `(actions:restoredID:)` now, not `[QuickAction]`
    // alone: the restored row can land under a
    // FRESH id when its original has since been claimed, so the caller (and
    // this file's own redo tests, below) need to know which id actually
    // landed, not assume it is always `action.id`.

    @Test("undo restores a deleted action at its ORIGINAL index, not at the end")
    func restoredReinsertsAtTheOriginalIndex() {
        let deleted = QuickAction(id: "xray-two-fixture", title: "xray-two-fixture", kind: .prompt("go"))
        let remaining = actions("yankee-two-fixture", "zulu-two-fixture")
        let result = DeckSettingsView.restored(deleted, at: 1, into: remaining)
        #expect(result.actions.map(\.id) == ["yankee-two-fixture", "xray-two-fixture", "zulu-two-fixture"],
                "undo appended at the end instead of restoring the row's own position")
        #expect(result.restoredID == "xray-two-fixture")
    }

    @Test("restoring at index 0 puts the row back first")
    func restoredReinsertsAtTheFront() {
        let deleted = QuickAction(id: "alpha-two-fixture", title: "alpha-two-fixture", kind: .prompt("go"))
        let remaining = actions("bravo-two-fixture", "charlie-two-fixture")
        let result = DeckSettingsView.restored(deleted, at: 0, into: remaining)
        #expect(result.actions.map(\.id) == ["alpha-two-fixture", "bravo-two-fixture", "charlie-two-fixture"])
    }

    /// **Clamped, not trusted — time passes between a delete and a ⌘Z.** The
    /// array can have shrunk again by the time undo actually fires (another
    /// delete in between); a stale index past the current bounds must
    /// degrade to "restored at the end" rather than trap.
    @Test("an index past the current bounds clamps instead of trapping")
    func restoredClampsAnOutOfBoundsIndex() {
        let deleted = QuickAction(id: "delta-two-fixture", title: "delta-two-fixture", kind: .prompt("go"))
        let remaining = actions("echo-two-fixture")
        let result = DeckSettingsView.restored(deleted, at: 99, into: remaining)
        #expect(result.actions.map(\.id) == ["echo-two-fixture", "delta-two-fixture"])
    }

    @Test("restoring into an empty array is safe")
    func restoredIntoAnEmptyArray() {
        let deleted = QuickAction(id: "foxtrot-two-fixture", title: "foxtrot-two-fixture", kind: .prompt("go"))
        let result = DeckSettingsView.restored(deleted, at: 0, into: [])
        #expect(result.actions.map(\.id) == ["foxtrot-two-fixture"])
        #expect(result.restoredID == "foxtrot-two-fixture")
    }

    /// **Undo must not reintroduce a
    /// duplicate id.** Delete "golf-two-fixture", then something ELSE
    /// legitimately claims that same id (`QuickAction.user` only de-dups
    /// against the LIVE set, which no longer holds it) — undo must not
    /// hand back a second row sharing it. `QuickAction.dedupedByID`'s own
    /// doc comment calls a shared id "reachable only by hand-editing the
    /// file"; this is the ordinary-UI-use counter-example.
    @Test("restoring a row whose id was claimed in the meantime gets a fresh one")
    func restoredGivesAFreshIdWhenTheOriginalWasClaimed() {
        let deleted = QuickAction(id: "golf-two-fixture", title: nil, kind: .prompt("Golf Fixture"))
        // The vacated id was re-claimed by an unrelated new row before ⌘Z.
        let claimant = QuickAction(id: "golf-two-fixture", title: nil, kind: .prompt("Golf Fixture, decoy"))
        let result = DeckSettingsView.restored(deleted, at: 0, into: [claimant])
        let ids = result.actions.map(\.id)
        #expect(Set(ids).count == ids.count, "two rows now share an id")
        #expect(result.restoredID != "golf-two-fixture",
                "the restored row kept the id something else already holds")
        #expect(result.actions.contains(where: { $0.payload == "Golf Fixture" }),
                "the restored row's own content did not survive the id change")
    }

    /// **A fresh id when claimed, the SAME id when not — the restoration is
    /// otherwise unchanged.** Pins the common case is not disturbed by the
    /// de-duplication branch existing at all.
    @Test("restoring a row whose id is still free keeps its original id")
    func restoredKeepsTheOriginalIdWhenItIsStillFree() {
        let deleted = QuickAction(id: "hotel-two-fixture", title: nil, kind: .prompt("Hotel Fixture"))
        let result = DeckSettingsView.restored(deleted, at: 0, into: [])
        #expect(result.restoredID == "hotel-two-fixture")
    }

    // ------------------------------------------------------------ undo + redo
    //
    // **A REAL `UndoManager` — not a claim that one cannot be constructed
    // headlessly.** `UndoManager` is a plain Foundation object; it needs no
    // window and no SwiftUI environment. These replicate `removeSelected`'s
    // own shape (capture the removed row, mutate, register) exactly the way
    // this file already replicates `.onMove`/`onCommit`, then drive the
    // SAME manager's `.undo()`/`.redo()` directly.

    @Test("undo restores the row, and redo removes it again, through a real UndoManager")
    func undoAndRedoRoundTripThroughARealUndoManager() {
        let runtime = freshRuntime()
        var prefs = runtime.prefs
        prefs.quickActions = actions("india-two-fixture", "juliet-two-fixture", "kilo-two-fixture")
        runtime.setPrefs(prefs)

        let manager = UndoManager()
        var p = runtime.prefs
        let index = 1
        let removed = p.quickActions[index]
        p.quickActions.remove(at: index)
        runtime.setPrefs(p)
        DeckSettingsView.registerRemovalUndo(of: removed, at: index, manager: manager, runtime: runtime)

        #expect(runtime.prefs.quickActions.map(\.id) == ["india-two-fixture", "kilo-two-fixture"])

        manager.undo()
        #expect(runtime.prefs.quickActions.map(\.id) == ["india-two-fixture", "juliet-two-fixture", "kilo-two-fixture"],
                "undo did not restore the row at its original index")

        #expect(manager.canRedo, "no redo was registered — ⇧⌘Z would do nothing")
        manager.redo()
        #expect(runtime.prefs.quickActions.map(\.id) == ["india-two-fixture", "kilo-two-fixture"],
                "redo did not remove the row again")

        // A SECOND undo, after the redo — proves the chain re-registers
        // itself rather than working exactly once.
        manager.undo()
        #expect(runtime.prefs.quickActions.map(\.id) == ["india-two-fixture", "juliet-two-fixture", "kilo-two-fixture"],
                "a second undo after a redo did not restore the row — the chain broke after one cycle")
    }

    /// **The exact scenario: delete "continue", add a
    /// button whose slug also resolves to "continue," then ⌘Z.**
    /// `QuickAction.user` only de-dups against the LIVE set, so once
    /// "continue" is deleted a brand new button legitimately claims it —
    /// undo must not then hand back a second "continue."
    @Test("undo after the vacated id was claimed by a new button never collides")
    func undoNeverReintroducesAClaimedID() {
        let runtime = freshRuntime()
        var prefs = runtime.prefs
        prefs.quickActions = [QuickAction(id: "continue", title: nil, kind: .prompt("Continue"))]
        runtime.setPrefs(prefs)

        let manager = UndoManager()
        var p = runtime.prefs
        let removed = p.quickActions[0]
        p.quickActions.remove(at: 0)
        runtime.setPrefs(p)
        DeckSettingsView.registerRemovalUndo(of: removed, at: 0, manager: manager, runtime: runtime)

        let claimant = QuickAction.user(title: nil, message: "Continue", among: runtime.prefs.quickActions)
        #expect(claimant.id == "continue", "the fixture's own premise: the new button claims the vacated id")
        var p2 = runtime.prefs
        p2.quickActions.append(claimant)
        runtime.setPrefs(p2)

        manager.undo()

        let ids = runtime.prefs.quickActions.map(\.id)
        #expect(Set(ids).count == ids.count, "undo reintroduced a duplicate id")
        #expect(ids.count == 2, "the restored row went missing entirely instead of landing under a fresh id")
    }

    // --------------------------------------------------------------- duplicate
    //
    // `DeckSettingsView.duplicated(_:among:)` — a fresh, de-duplicated id
    // from `QuickAction.user`'s own logic, every OTHER field carried from
    // the ORIGINAL rather than from whatever `user` would have defaulted.

    @Test("duplicate produces a distinct id and preserves message, label and folder scope")
    func duplicatedPreservesEveryFieldForAScopedRow() {
        let original = QuickAction(id: "golf-two-fixture", title: "Golf Fixture", kind: .prompt("run the golf check"),
                                   scope: .folders("*/golf-course-fixture*"))
        let copy = DeckSettingsView.duplicated(original, among: [original])
        #expect(copy.id != original.id, "the duplicate shares an id with the original")
        #expect(copy.title == "Golf Fixture")
        #expect(copy.payload == "run the golf check")
        #expect(copy.scope == .folders("*/golf-course-fixture*"),
                "scope was dropped by the duplicate — the exact reconstruction hazard this arc keeps finding")
    }

    @Test("duplicate preserves .everywhere scope and a non-prompt kind")
    func duplicatedPreservesEverywhereScopeAndEscapeKind() {
        let original = QuickAction(id: "hotel-two-fixture", title: "Hotel Fixture", kind: .escape)
        let copy = DeckSettingsView.duplicated(original, among: [original])
        #expect(copy.id != original.id)
        #expect(copy.title == "Hotel Fixture")
        #expect(copy.kind == .escape)
        #expect(copy.scope == .everywhere)
    }

    @Test("duplicate de-duplicates its id against the live set, not just the original")
    func duplicatedAvoidsCollidingWithAnyExistingRow() {
        let original = QuickAction(id: "india-two-fixture", title: "India Fixture", kind: .prompt("scout ahead"))
        let others = [original, QuickAction(id: "india-two-fixture-2", title: "Decoy", kind: .prompt("decoy"))]
        let copy = DeckSettingsView.duplicated(original, among: others)
        #expect(!others.map(\.id).contains(copy.id), "the duplicate's id collided with an existing row")
    }

    /// **`duplicateSelected`'s own wiring, replicated — the third of this
    /// file's three "reads the live draft" wiring tests, matching
    /// `removeSelected`'s and `onCommit`'s own.** ⌘D is a `.keyboardShortcut`
    /// specifically so it fires while a text field still holds focus
    /// (`actionsPane`'s own doc comment on why), so the shape under test is
    /// `liveAction(for:stored:)` folded into `duplicated(_:among:)` — the
    /// EXACT sequence `duplicateSelected` runs — not `duplicated` called on
    /// the stale stored row alone.
    @Test("duplicate is built from the live draft, not the stale stored row")
    func duplicateSelectedIsBuiltFromTheLiveDraft() {
        let runtime = freshRuntime()
        var prefs = runtime.prefs
        prefs.quickActions = actions("yankee-three-fixture")
        runtime.setPrefs(prefs)

        let stored = runtime.prefs.quickActions[0]
        let liveMessage = "carry the yankee crate, live edit"
        // `liveAction(for:stored:)`'s own shape: fold whatever the draft
        // holds into the stored row via `pendingCommit` before duplicating.
        let live = QuickActionDetailEditor.pendingCommit(
            for: stored, draftTitle: QuickActionDetailEditor.resolvedTitle(for: stored),
            draftMessage: liveMessage, draftPattern: "") ?? stored
        let copy = DeckSettingsView.duplicated(live, among: runtime.prefs.quickActions)

        #expect(copy.payload == liveMessage,
                "the duplicate was built from the stale stored message, not the live in-progress edit")
        #expect(copy.id != stored.id)
    }

    // ------------------------------------------------------------- the cap
    //
    // **`maxOffered`'s own predicate stays removed — the editor
    // adds a DIFFERENT live number (`matchSummary`'s own "N of M"), not the
    // "how many of your ten offered slots are used" count an earlier draft
    // of this file's own comment predicted.** `actionsPane`'s Add Button
    // used to disable at `QuickAction.offerable(prefs.quickActions).count
    // >= QuickAction.maxOffered` — a single true/false fact about the
    // STORED set, correct only because every row that offered anywhere used
    // to offer everywhere. `QuickAction.Scope` broke that premise, and
    // nothing here brings a per-session "N of 10 offered" readout
    // back — `matchSummary`, above, answers a related but DIFFERENT
    // question ("how many open sessions would this ONE folder rule match"),
    // not "is this session's own panel full." Add Button stays enabled
    // unconditionally, and there is still no
    // predicate here to drive end to end.
}
