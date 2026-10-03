import XCTest

/// Context packets (design/CONTEXT-HARNESS.md#context-packets): `--context-packet-fixture` seeds a saved
/// chat about dinner with Sarah, memories at each level, Sarah in People, and a Claude API connection.
/// "Share context with…" shows what goes and what stays for each reader; Continue opens the new chat
/// with the context card, which can be taken out. Nothing is sent to a model here.
final class ContextPacketUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// Kept in the test result, and written to `CONTEXT_PACKET_SCREENSHOTS` when the run sets it.
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["CONTEXT_PACKET_SCREENSHOTS"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor func testSendingAChatsContextToAnotherChat() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "--context-packet-fixture", "-app.appearance.mode", "Dark"]
        app.launch()
        let input = app.textFields["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertFalse(element(app, "contextPacketCard").exists, "A new chat has no context card")

        // From the saved chat's menu in the drawer.
        app.buttons["openConversations"].tap()
        let saved = app.buttons.matching(identifier: "savedConversation").firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        saved.press(forDuration: 1.0)
        let share = app.buttons["Share context with…"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        share.tap()

        // The card, for the chat's own model first: on this iPhone everything used in chat may go.
        XCTAssertTrue(element(app, "contextPacketReview").waitForExistence(timeout: 5))
        let summary = element(app, "contextPacketSummary")
        XCTAssertTrue(summary.label.contains("Bring context from your chat “Help me plan dinner with Sarah on Friday.” to Apple on-device"), summary.label)
        XCTAssertTrue(element(app, "contextPacketShared").exists)
        XCTAssertFalse(element(app, "contextPacketConsent").exists, "Nothing needs an OK on this device")
        capture(app, "context-packet-on-device")

        // Another company's model: Sensitive items wait for the owner's OK; Device only stays.
        let claude = element(app, "contextPacketTo-Claude API")
        XCTAssertTrue(claude.waitForExistence(timeout: 3))
        claude.tap()
        XCTAssertTrue(summary.label.contains("to Claude API, in a new chat"), summary.label)
        let consent = element(app, "contextPacketConsent")
        XCTAssertTrue(consent.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Sensitive. It goes to Claude API only if you include it."].exists)
        let withheld = element(app, "contextPacketWithheld")
        withheld.swipeUp(velocity: .slow)
        XCTAssertTrue(app.staticTexts["Device only. It stays on this iPhone."].waitForExistence(timeout: 3))
        capture(app, "context-packet-claude-api")

        // Include one Sensitive item, then continue.
        let include = app.buttons.matching(identifier: "contextPacketInclude").firstMatch
        include.tap()
        capture(app, "context-packet-included")
        app.buttons["contextPacketContinue"].tap()

        // The new chat starts with the context card, and the chat is with Claude API.
        let card = element(app, "contextPacketCard")
        XCTAssertTrue(card.waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "contextPacketReview").exists)
        XCTAssertTrue(element(app, "contextPacketCardTitle").label.hasPrefix("Context from your chat “Help me plan dinner"))
        XCTAssertTrue(app.buttons["chooseModel"].label.contains("Claude API"), app.buttons["chooseModel"].label)
        capture(app, "context-packet-chat-card")
        app.buttons["contextPacketCardExpand"].tap()
        XCTAssertTrue(app.staticTexts["Sarah is vegetarian and loves Italian food."].waitForExistence(timeout: 3), "Open, it lists what goes")
        capture(app, "context-packet-chat-card-open")

        // Taken out, nothing more from it goes.
        app.buttons["contextPacketCardRemove"].tap()
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: card)
        wait(for: [gone], timeout: 5)
    }
}
