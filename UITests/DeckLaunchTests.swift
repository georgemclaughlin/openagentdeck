//
//  DeckLaunchTests.swift · OpenAgentDeckUITests
//
//  The layer the package cannot reach. Every rule about what the deck DRAWS is
//  asserted headlessly in `DeckUITests` against an `ImageRenderer`, which is
//  faster and more precise than driving a window — so nothing here re-tests a
//  pixel. What is left is the part that only exists once macOS has launched a
//  signed bundle: that there IS a window, that it carries the deck's identity,
//  and that AppKit's own chrome behaves.
//
//  XCTest rather than Swift Testing: UI automation has no Swift Testing
//  equivalent, and `XCUIApplication` is an XCTest type.
//

import XCTest

nonisolated final class DeckLaunchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Launches a deck on a port of its own.
    ///
    /// A bare `XCUIApplication()` would come up on the DEFAULT port. If a
    /// deck is already running there, the second instance surrenders to the
    /// first and exits almost immediately, and `xcodebuild` reports "the
    /// test runner hung before establishing connection" for what is really
    /// a port collision in the app.
    @MainActor
    private func launchIsolatedDeck() throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OAD_HOOK_PORT"] = String(try FreePort.next())
        // A launch smoke test must not depend on how many Claude sessions
        // are running; see `DeckRuntime.fleetDiscoverySuppressed`.
        app.launchEnvironment["OAD_NO_FLEET_DISCOVERY"] = "1"
        app.launch()
        return app
    }

    /// The bundle launches and puts a window on screen.
    ///
    /// This is the smoke test for the app bundle. `swift build` produces a
    /// bare Mach-O, which the window server treats as a background process;
    /// only a real bundle gets the standing of an application. If the app
    /// target's wiring regresses, this is what says so.
    @MainActor
    func testDeckLaunchesWithAWindow() throws {
        let app = try launchIsolatedDeck()

        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 15),
                      "the app never reached the foreground")

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 10),
                      "the deck launched without putting a window on screen")
    }

    /// One deck, one window, one identity.
    ///
    /// `DeckScene` uses `Window` rather than `WindowGroup` precisely so the
    /// frame identity is stable across close-and-reopen. A regression to
    /// `WindowGroup` would still launch and still draw; the identifier and the
    /// single-window count are what distinguish them from outside.
    ///
    /// Matched on IDENTIFIER, not title. `DeckScene` declares
    /// `Window("Open Agent Deck", id: "deck")`, but macOS composes the
    /// window's accessibility title from the title AND the navigation
    /// subtitle (e.g. `"Open Agent Deck – 10 sessions"`), which varies with
    /// the session count. The `id:` is the stable fact.
    @MainActor
    func testTheDeckHasExactlyOneTitledWindow() throws {
        let app = try launchIsolatedDeck()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        XCTAssertEqual(app.windows.count, 1,
                       "the deck opened more than one window")
        XCTAssertTrue(app.windows["deck"].exists,
                      "the deck's window does not carry DeckScene's own 'deck' identity")
    }

    /// Settings is a first-class scene, reachable the way macOS says it is.
    ///
    /// The pane is modeless and instant-apply and owns no state of its own, so
    /// there is nothing to assert about its contents that the package does not
    /// already assert. That it OPENS on the standard key is a fact about the
    /// app's scene graph, and only a launched app has one.
    ///
    /// Matched on SwiftUI's own settings-window identifier, not the title
    /// "Settings". A SwiftUI `Settings` scene on macOS titles its window
    /// after the SELECTED TAB (here "Actions"), so a title match breaks on
    /// any tab rename. `com_apple_SwiftUI_Settings_window` is the
    /// identifier SwiftUI assigns the scene itself.
    @MainActor
    func testSettingsOpensOnCommandComma() throws {
        let app = try launchIsolatedDeck()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 10))

        app.typeKey(",", modifierFlags: .command)

        let settings = app.windows["com_apple_SwiftUI_Settings_window"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5),
                      "Command-comma did not open the settings scene")
    }
}
