//
//  DeckScene.swift · DeckApp
//
//  The deck's scenes, as a `Scene` rather than an `App`. The `@main` entry
//  point belongs to the application target — it is the one thing that cannot
//  live in a library — and everything it needs to build lives here, so the
//  app target stays a shim over a tested module.
//

import SwiftUI
import DeckCore
import DeckAdapters

public struct DeckScene: Scene {
    @State private var runtime = DeckRuntime()

    /// Read once, at scene construction — `defaultSize` is consulted before
    /// any runtime task runs, so the preference has to be read synchronously
    /// here. It is the same adapter read the runtime makes a moment later.
    private let defaultWindow = PrefsStore.load(from: PrefsStore.standard).windowSize
        ?? DeckPrefs.defaultWindow

    /// The port the hook server binds.
    ///
    /// A deck owns its port — a second launch finds the first and surrenders —
    /// which makes the default a machine-wide singleton and a UI test that
    /// posts to it a test of whichever deck answered. `OAD_HOOK_PORT` lets a
    /// launched instance be addressed on a port of the caller's choosing, so
    /// an automated run talks to the app it started and to nothing else.
    private var hookPort: UInt16 {
        ProcessInfo.processInfo.environment["OAD_HOOK_PORT"]
            .flatMap(UInt16.init) ?? DeckRuntime.defaultPort
    }

    /// A launch-time window size, for automated runs that need the same
    /// picture every time. `WIDTHxHEIGHT`, e.g. `1100x620`.
    private var launchWindowSize: DeckCore.Canvas? {
        guard let raw = ProcessInfo.processInfo.environment["OAD_WINDOW_SIZE"] else { return nil }
        let parts = raw.lowercased().split(separator: "x").compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0, parts[1] > 0 else { return nil }
        return DeckCore.Canvas(width: parts[0], height: parts[1])
    }

    /// Arms the crash-recovery watchdog once per launch; see `CrashRecovery`.
    public init() { CrashRecovery.arm() }

    public var body: some Scene {
        // `Window`, not `WindowGroup`: one deck, one window, one identity.
        // A WindowGroup window reopened after ⌘W gets a fresh frame identity
        // and loses its saved frame (documented widely); a single Window
        // scene with a stable id is the configuration whose automatic frame
        // persistence has no known failure mode — the size and position you
        // leave it at is the one it relaunches with. Closing it quits, which
        // is honest for a deck: glass that is not on screen is not
        // supervising anyone.
        Window("Open Agent Deck", id: "deck") {
            DeckWindow(runtime: runtime)
                .task { await runtime.start(port: hookPort) }
                // The window's resize floor comes from `DeckWindow.body`'s outermost
                // `.frame(minWidth:minHeight:)` (`DeckPrefs.minWindow`, 960x270), the single
                // explicit floor. Without it, any uncompressible interior (e.g. `DetailBand`'s
                // fixed rows) folds into the minimum that `.windowResizability(.contentSize)`
                // enforces, and the window refuses to shrink below the size it had when a band
                // opened.
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        // The default for a launch with NO remembered frame; otherwise macOS restores the
        // previous one, so a window remembered tall from a big monitor can land with its
        // title bar off the 480 pt strip. The launch-time fit in `DeckRuntime.start`
        // repositions a restored frame back into reach but never resizes it
        // (`DeckRuntime.fitted`): the window's size is the user's.
        .defaultSize(width: CGFloat((launchWindowSize ?? defaultWindow).width),
                     height: CGFloat((launchWindowSize ?? defaultWindow).height))
        .windowResizability(.contentSize)
        // The strip is 480 pt tall and the titlebar is not the deck's to spend; the
        // standard style reserves ~52 pt. `.unifiedCompact` measures exactly 40 pt
        // (Accessibility API, live), and `QuestionOptionsBand.usableStripHeight` (419)
        // and `RenderSweepTests.stageViewportHeight` (440) derive from that figure.
        // Compact, not hidden: the title/subtitle and usage readout stay in the toolbar.
        // Only the deck's `Window` gets it, never `Settings`.
        .windowToolbarStyle(.unifiedCompact)

        // The settings surface: modeless, instant-apply, Command-comma for free. The pane
        // owns no state; every control writes through the reducer.
        Settings {
            DeckSettingsView(runtime: runtime)
        }
    }
}
