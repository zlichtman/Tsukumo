import XCTest

/// The agent request demo (design/CONTEXT-HARNESS.md#agent-requests): `--agent-request-fixture`
/// seeds a conversation with Sarah and shows Muse's request for the restaurant picked for Friday, in
/// the default KemoSabe theme, dark. Share shows what went; Decline shows that nothing did.
final class AgentRequestUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "--agent-request-fixture", "-app.appearance.mode", "Dark"]
        app.launch()
        return app
    }
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// Kept in the test result, and written to `AGENT_REQUEST_SCREENSHOTS` when the run sets it.
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["AGENT_REQUEST_SCREENSHOTS"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor func testShareSendsTheSliceAndSaysSo() {
        let app = launch()
        let card = element(app, "agentRequestCard")
        XCTAssertTrue(card.waitForExistence(timeout: 15), "Muse's request appears")
        let summary = element(app, "agentRequestSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.contains("Muse wants to access your conversation with Sarah"), summary.label)
        let share = app.buttons["agentRequestShare"]
        XCTAssertTrue(share.waitForExistence(timeout: 20), "Kemo read it on this device")
        XCTAssertTrue(element(app, "agentRequestAnswer").label.contains("Osteria Lucia"))
        XCTAssertTrue(element(app, "agentRequestWithheld").label.contains("The rest of your conversation with Sarah stays on your iPhone."))
        capture(app, "agent-request-card")
        share.tap()
        XCTAssertTrue(element(app, "agentRequestShared").waitForExistence(timeout: 5), "The confirmation shows what went")
        capture(app, "agent-request-shared")
        app.buttons["agentRequestDone"].tap()
        XCTAssertFalse(card.waitForExistence(timeout: 2))
    }

    @MainActor func testDeclineSharesNothing() {
        let app = launch()
        XCTAssertTrue(element(app, "agentRequestCard").waitForExistence(timeout: 15))
        let decline = app.buttons["agentRequestDecline"]
        XCTAssertTrue(app.buttons["agentRequestShare"].waitForExistence(timeout: 20))
        decline.tap()
        XCTAssertTrue(element(app, "agentRequestDeclined").waitForExistence(timeout: 5))
        capture(app, "agent-request-declined")
    }

    @MainActor func testEditTrimsWhatIsShared() {
        let app = launch()
        XCTAssertTrue(app.buttons["agentRequestShare"].waitForExistence(timeout: 20))
        app.buttons["agentRequestEdit"].tap()
        let excerpt = element(app, "agentRequestExcerptField")
        XCTAssertTrue(excerpt.waitForExistence(timeout: 5))
        // Trim the excerpt away: only the answer goes.
        excerpt.coordinate(withNormalizedOffset: CGVector(dx: 0.98, dy: 0.9)).tap()
        excerpt.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 160))
        capture(app, "agent-request-editing")
        app.buttons["agentRequestShare"].tap()
        XCTAssertTrue(element(app, "agentRequestShared").waitForExistence(timeout: 5))
    }
}
