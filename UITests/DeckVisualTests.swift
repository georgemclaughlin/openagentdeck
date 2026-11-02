//
//  DeckVisualTests.swift · OpenAgentDeckUITests
//
//  Photographs of the real window, driven by fixture payloads.
//
//  A headless `ImageRenderer` cannot draw this UI: `NavigationSplitView` needs
//  a window, and Liquid Glass needs a compositor — rendered off-screen the
//  first comes out as SwiftUI's unsupported placeholder and the second as
//  nothing at all. So the pictures come from the running app, which is also
//  the only way to judge the thing being judged. Spacing, control weight and
//  whether it reads as a Mac app are properties of what the window server
//  draws, not of what a renderer approximates.
//
//  The deck is filled by POSTing recorded shapes at its own hook port, so the
//  states are reproducible and no Claude Code session is required.
//
//  Every shot is attached to the test result, and also written to
//  `DECK_SNAPSHOT_DIR` when that is set, so a person can flip through them.
//

import XCTest

nonisolated final class DeckVisualTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// The window at the sizes a user can drag it to. Nothing may vanish
    /// between them — that is the requirement these pictures exist to check.
    @MainActor
    func testTheWindowAtEverySize() async throws {
        for (name, size) in [("default", "1100x620"),
                             ("narrow", "620x520"),
                             ("short", "1000x360"),
                             ("wide", "1600x760")] {
            let port = try freePort()
            let app = launch(port: port, windowSize: size)
            try await fill(port: port)

            // Let the frame settle before photographing it.
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
            capture(app, named: "window-\(name)")
            app.terminate()
        }
    }

    /// The empty deck, which is what a first launch actually looks like and
    /// the state most often left undesigned.
    @MainActor
    func testTheEmptyDeck() throws {
        let app = launch(port: try freePort(), windowSize: "1100x620")
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
        capture(app, named: "window-empty")
        app.terminate()
    }

    /// The settings window, which is a different surface with different rules
    /// — a `Form`, and the platform's own row and label treatment.
    @MainActor
    func testSettings() throws {
        let app = launch(port: try freePort(), windowSize: "1100x620")
        _ = app.windows.firstMatch.waitForExistence(timeout: 10)
        app.typeKey(",", modifierFlags: .command)
        _ = app.windows["Settings"].waitForExistence(timeout: 5)
        capture(app, named: "settings")
        app.terminate()
    }

    // ------------------------------------------------------------- fixtures

    /// Three sessions, one of them holding a decision — the state the product
    /// exists for, and the one the pictures most need to show.
    private func fill(port: UInt16) async throws {
        try await post(sessionStart("alpha", cwd: "/Users/you/work/open-agent-deck"), to: port)
        try await post(sessionStart("beta", cwd: "/Users/you/work/parser"), to: port)
        try await post(sessionStart("gamma", cwd: "/Users/you/work/notes"), to: port)
        try await post(prompt("alpha", "Rewrite the layout so it adapts to the window"), to: port)
        try await post(prompt("gamma", "Summarise yesterday's notes"), to: port)
        // The hold. Posted last so the deck is already populated behind it.
        try await post(preToolUse("alpha", command: "git push --force origin main"), to: port)
        try? await Task.sleep(for: .seconds(1))
    }

    private func sessionStart(_ session: String, cwd: String) -> [String: Any] {
        ["session_id": session, "hook_event_name": "SessionStart", "cwd": cwd]
    }

    private func prompt(_ session: String, _ text: String) -> [String: Any] {
        ["session_id": session, "hook_event_name": "UserPromptSubmit",
         "cwd": "/Users/you/work", "prompt": text]
    }

    private func preToolUse(_ session: String, command: String) -> [String: Any] {
        ["session_id": session, "hook_event_name": "PreToolUse",
         "cwd": "/Users/you/work", "tool_name": "Bash",
         "tool_use_id": "t-\(UUID().uuidString.prefix(6))",
         "tool_input": ["command": command]]
    }

    // -------------------------------------------------------------- harness

    @MainActor
    private func launch(port: UInt16, windowSize: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OAD_HOOK_PORT"] = String(port)
        app.launchEnvironment["OAD_WINDOW_SIZE"] = windowSize
        // Keep the developer's live fleet out of the snapshots; see
        // `DeckRuntime.fleetDiscoverySuppressed`.
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

    private func post(_ body: [String: Any], to port: UInt16) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // A held hook does not answer until it is decided, so a decision-
        // opening post must not be waited on.
        request.timeoutInterval = 3
        _ = try? await URLSession.shared.data(for: request)
    }

    /// See `FreePort` for why this cannot use `bind()`.
    private func freePort() throws -> UInt16 { try FreePort.next() }
}
