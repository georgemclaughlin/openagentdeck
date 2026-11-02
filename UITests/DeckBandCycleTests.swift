//
//  DeckBandCycleTests.swift · OpenAgentDeckUITests
//
//  The band's full round trip — open on a tap, close on the collapse
//  button — photographed and asserted against the real window server.
//
//  Guards a regression no package test can see: with
//  `.transition(.identity)` on every fleet card (so band-open removes its
//  siblings the same frame the selection lands), the CLOSE direction came
//  back with restored cards missing content and stale glass shapes. The
//  package suite has no compositor and runs no animation transaction, so
//  only the running app can pin "every card comes back".
//

import XCTest

nonisolated final class DeckBandCycleTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// Open the band on one card, close it, and every card the open
    /// displaced must be back on the glass — present, hittable, and at a
    /// sane frame — not a ghost the lazy grid declined to rebuild.
    @MainActor
    func testEveryCardComesBackWhenTheBandCloses() async throws {
        let sessions = ["alpha", "beta", "gamma", "delta"]
        let port = try freePort()
        let app = launch(port: port, windowSize: "1100x620")
        defer { app.terminate() }

        for session in sessions {
            try await post(sessionStart(session, cwd: "/Users/you/work/\(session)"), to: port)
        }
        for session in sessions {
            try await post(prompt(session, "Keep \(session) busy with something readable"), to: port)
        }

        for session in sessions {
            XCTAssertTrue(card(session, in: app).waitForExistence(timeout: 10),
                          "\(session)'s card never arrived on the glass")
        }
        capture(app, named: "band-cycle-1-before")

        // Open: a real click runs the real animated open transaction.
        card("alpha", in: app).click()
        let collapse = app.buttons["Collapse, back to the fleet"]
        XCTAssertTrue(collapse.waitForExistence(timeout: 5),
                      "the band never opened on alpha's card")
        // Let the open transaction settle first: the regression was removal
        // bookkeeping outliving the spring.
        try? await Task.sleep(for: .seconds(1))
        capture(app, named: "band-cycle-2-open")

        collapse.click()

        // 10s, matching the arrival wait. A card coming back needs a spring
        // close, a grid rebuild and a compositor pass, which is more than
        // one lazy-grid insert, and a shorter budget made this flaky.
        // `waitForExistence` returns as soon as the element appears, so the
        // longer ceiling costs nothing on the passing path.
        for session in sessions {
            XCTAssertTrue(card(session, in: app).waitForExistence(timeout: 10),
                          "\(session)'s card never came back after the band closed")
        }
        // The restored fleet must also be LAID OUT as a fleet: every card at
        // a positive-area frame inside the window, no zero-sized or
        // off-glass ghosts.
        try? await Task.sleep(for: .seconds(1))
        capture(app, named: "band-cycle-3-after")
        let windowFrame = app.windows.firstMatch.frame
        for session in sessions {
            let restored = card(session, in: app)
            let frame = restored.frame
            XCTAssertGreaterThan(frame.width, 100, "\(session)'s restored card has no width")
            XCTAssertGreaterThan(frame.height, 80, "\(session)'s restored card has no height")
            XCTAssertTrue(windowFrame.intersects(frame),
                          "\(session)'s restored card sits off the glass at \(frame)")
            XCTAssertTrue(restored.isHittable,
                          "\(session)'s restored card exists but cannot be hit — a ghost, not a card")
        }
    }

    // -------------------------------------------------------------- harness

    /// The card for a session, matched the way `DeckHookTests` matches a
    /// lane: by the accessibility label a screen reader would announce.
    @MainActor
    private func card(_ session: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", session)).firstMatch
    }

    @MainActor
    private func launch(port: UInt16, windowSize: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OAD_HOOK_PORT"] = String(port)
        app.launchEnvironment["OAD_WINDOW_SIZE"] = windowSize
        // Only the sessions this test posts; see
        // `DeckRuntime.fleetDiscoverySuppressed` for why.
        app.launchEnvironment["OAD_NO_FLEET_DISCOVERY"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "the deck never put a window on screen")
        return app
    }

    @MainActor
    private func capture(_ app: XCUIApplication, named name: String) {
        let shot = app.windows.firstMatch.exists
            ? app.windows.firstMatch.screenshot()
            : XCUIScreen.main.screenshot()

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let dir = ProcessInfo.processInfo.environment["DECK_SNAPSHOT_DIR"] else { return }
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
    }

    private func sessionStart(_ session: String, cwd: String) -> [String: Any] {
        ["session_id": session, "hook_event_name": "SessionStart", "cwd": cwd]
    }

    private func prompt(_ session: String, _ text: String) -> [String: Any] {
        ["session_id": session, "hook_event_name": "UserPromptSubmit",
         "cwd": "/Users/you/work", "prompt": text]
    }

    private func post(_ body: [String: Any], to port: UInt16) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: request)
    }

    /// See `FreePort` for why this cannot use `bind()`.
    private func freePort() throws -> UInt16 { try FreePort.next() }
}
