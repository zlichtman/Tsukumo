import XCTest

/// Agents on your Mac on the iPhone (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone, UI guide):
/// Settings → Models → LLM's section before pairing, a typed code, and a scanned pairing link asking
/// before it pairs. No Mac is on the test's network, so pairing ends by saying so.
final class MacRelayUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// Kept in the test result, and written to `RELAY_SCREENSHOTS` when the run sets it.
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["RELAY_SCREENSHOTS"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor func testPairingPageTakesATypedCodeAndSaysWhenNoMacIsFound() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture", "-app.appearance.mode", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10))
        app.buttons["settingsGear"].tap()
        // Settings → Models opens on the LLM tab; Agents on your Mac is a row there, with its own page.
        let row = app.buttons["openModel"]
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        for _ in 0..<8 where !(row.exists && row.isHittable) { app.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        let agents = app.buttons["openMacAgents"]
        for _ in 0..<6 where !(agents.exists && agents.isHittable) { app.swipeUp() }
        XCTAssertTrue(agents.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["macAgentsStatus"].exists || agents.label.contains("Not paired"))
        agents.tap()
        let field = app.textFields["relayCodeField"], pair = app.buttons["relayPair"]
        for _ in 0..<10 where !(field.exists && field.isHittable) { app.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["AGENTS ON YOUR MAC"].exists || app.staticTexts["Agents on your Mac"].exists, "The section's header")
        XCTAssertFalse(pair.isEnabled, "Nothing to pair with yet")
        capture(app, "relay-iphone-unpaired")
        field.tap(); field.typeText("abcd-efgh")
        XCTAssertFalse(pair.isEnabled, "Not a whole code")
        field.typeText("-jkmn-pqrs-tvwx-yz01-2345")
        XCTAssertTrue(pair.isEnabled)
        pair.tap()
        let problem = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "No Mac showing a code")).firstMatch
        XCTAssertTrue(problem.waitForExistence(timeout: 20), "Says no Mac is on this Wi‑Fi instead of waiting forever")
        capture(app, "relay-iphone-no-mac")
    }

    @MainActor func testAScannedLinkAsksBeforeItPairs() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture", "-app.appearance.mode", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10))
        let code = "ABCDEFGHJKMNPQRSTVWXYZ012345"
        app.open(URL(string: "kemosabe://pair-mac?mac=\(UUID().uuidString)&name=Test%20Mac&code=\(code)")!)
        let alert = app.alerts["Use your agents through “Test Mac”?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        XCTAssertTrue(alert.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Only pair your own Mac")).firstMatch.exists)
        capture(app, "relay-iphone-link")
        alert.buttons["Cancel"].tap()
        XCTAssertFalse(alert.waitForExistence(timeout: 2))
    }
}
