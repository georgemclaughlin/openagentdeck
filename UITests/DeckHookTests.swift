//
//  DeckHookTests.swift · OpenAgentDeckUITests
//
//  End to end, in the only sense the word earns here: a recorded hook payload
//  goes over a real socket to the running application, through the real
//  server, the real reducer and the real renderer, and a lane has to appear on
//  the glass carrying the accessibility label a screen reader would announce.
//
//  Every one of those stages is already tested in isolation. What no package
//  test can show is that they are CONNECTED — that the server the app starts
//  is listening on the port the app was told to bind, and that an event
//  arriving on it reaches the window.
//
//  Each test launches its deck on a port of its own. A deck owns its port and
//  a second launch surrenders to the first, so a test posting to the default
//  would be testing whichever deck happened to answer, including one the
//  developer left running.
//

import XCTest

nonisolated final class DeckHookTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// A session the deck has never heard of arrives, and becomes a lane.
    ///
    /// The session id is unique per run, so the assertion cannot pass on a
    /// lane left over from anything else.
    @MainActor
    func testAPostedSessionBecomesALaneOnTheDeck() async throws {
        let port = try freePort()
        let app = try launchDeck(onPort: port)

        let session = "uitest-\(UUID().uuidString.prefix(8))"
        try await post(sessionStart(session), to: port)

        // The lane's own label, as `DeckView` builds it for assistive
        // traversal: matching on it means the row a screen reader would read
        // is the row that arrived.
        let lane = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", session))
            .firstMatch

        XCTAssertTrue(lane.waitForExistence(timeout: 15),
                      "the posted session never became a lane on the deck")
    }

    /// The deck refuses what it cannot understand, and stays up.
    ///
    /// The unknown-is-not-error rule is asserted over the reducer in the
    /// package; this is the same rule at the socket, where a malformed body is
    /// the difference between a deck that ignores a bad frame and one that
    /// dies holding somebody's permission prompt.
    @MainActor
    func testAMalformedPayloadDoesNotTakeTheDeckDown() async throws {
        let port = try freePort()
        let app = try launchDeck(onPort: port)

        try? await post(Data("{ this is not json".utf8), to: port)

        XCTAssertEqual(app.state, .runningForeground,
                       "a malformed hook payload took the deck down")
        XCTAssertTrue(app.windows.firstMatch.exists,
                      "the deck lost its window to a malformed payload")
    }

    // ----------------------------------------------------------- the harness

    @MainActor
    private func launchDeck(onPort port: UInt16) throws -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["OAD_HOOK_PORT"] = String(port)
        // Only the sessions this test posts; see
        // `DeckRuntime.fleetDiscoverySuppressed`.
        app.launchEnvironment["OAD_NO_FLEET_DISCOVERY"] = "1"
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15),
                      "no window to receive the event")
        return app
    }

    private func post(_ body: Data, to port: UInt16) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/hook")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10
        _ = try await URLSession.shared.data(for: request)
    }

    /// A port nothing is listening on. Racy in principle, but a hard-coded
    /// port would collide with other tests. See `FreePort` for why this
    /// cannot use `bind()`.
    private func freePort() throws -> UInt16 { try FreePort.next() }

    /// The shape Claude Code posts when a session begins, reduced to the keys
    /// the deck reads.
    private func sessionStart(_ session: String) -> Data {
        let payload: [String: Any] = [
            "session_id": session,
            "hook_event_name": "SessionStart",
            "cwd": "/tmp/\(session)",
        ]
        return try! JSONSerialization.data(withJSONObject: payload)
    }
}
