import XCTest

/// The owner's September 26, 2026 requests on iPhone: flipping through days in Day, Personalization
/// with only controls, and the chat model chip's power-up picker. With `KEMO_SHOT_DIR` set (pass
/// `TEST_RUNNER_KEMO_SHOT_DIR`), screenshots are saved there, named with `KEMO_SHOT_MODE`.
final class DayAndSettingsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }
    /// The app's own appearance (it starts dark), set for the screenshot mode.
    private var appearance: [String] {
        ["-app.appearance.mode", ProcessInfo.processInfo.environment["KEMO_SHOT_MODE"] == "light" ? "Light" : "Dark"]
    }

    /// Swipe to tomorrow and back; from another day, Today returns.
    @MainActor func testSwipeThroughDaysAndTodayReturns() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"] + appearance
        app.launch()
        XCTAssertTrue(app.buttons["tab-Day"].waitForExistence(timeout: 8)); app.buttons["tab-Day"].tap()
        let title = app.staticTexts["dayTitle"], today = app.buttons["dayTodayChip"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Your day")
        XCTAssertFalse(today.exists, "No Today chip on today")
        XCTAssertTrue(app.staticTexts["Nothing needs your attention"].exists)
        shot("day-today")
        let page = app.scrollViews["dayPage"].firstMatch
        page.swipeLeft()
        XCTAssertTrue(waitFor(title, label: "Tomorrow"), "Swiping left shows tomorrow")
        XCTAssertTrue(today.waitForExistence(timeout: 3), "Away from today, the Today chip appears")
        shot("day-tomorrow")
        page.swipeRight()
        XCTAssertTrue(waitFor(title, label: "Your day"), "Swiping right comes back")
        XCTAssertTrue(waitForGone(today))
        page.swipeRight()
        XCTAssertTrue(waitFor(title, label: "Yesterday"))
        shot("day-yesterday")
        today.tap()
        XCTAssertTrue(waitFor(title, label: "Your day"), "Today returns")
        XCTAssertTrue(waitForGone(today))
        // The date opens a compact calendar to jump.
        app.buttons["dayDateButton"].tap()
        XCTAssertTrue(app.datePickers["dayCalendarPicker"].waitForExistence(timeout: 5))
        shot("day-calendar")
    }

    @MainActor func testPersonalizationIsControlsWithFactsOnAbout() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"] + appearance
        app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 8)); app.buttons["settingsGear"].tap()
        reveal(app.buttons["openPersonalization"], in: app).tap()
        XCTAssertTrue(app.navigationBars["Personalization"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["connectCalendar"].exists || app.buttons["calendarDestination"].exists)
        XCTAssertTrue(app.datePickers["planningStart"].exists)
        XCTAssertTrue(app.datePickers["planningEnd"].exists)
        XCTAssertFalse(app.steppers.firstMatch.exists, "No steppers for hours")
        // The old walls of text moved to About personalization.
        for moved in ["Recent context is separate from saved memories and retained for up to 30 days.",
                      "Changing these fields does not expand an existing permission. Stop it and enable a new one to change its limits."] {
            XCTAssertFalse(app.staticTexts[moved].exists, moved)
        }
        shot("personalization-top")
        reveal(app.switches["learnFromChoices"], in: app)
        XCTAssertTrue(app.switches["carryRecentContext"].exists)
        XCTAssertTrue(app.buttons["forgetLearning"].exists)
        shot("personalization-bottom")
        reveal(app.buttons["openAboutPersonalization"], in: app).tap()
        XCTAssertTrue(app.staticTexts["Recent context is separate from saved memories and retained for up to 30 days."].waitForExistence(timeout: 5))
        shot("personalization-about")
    }

    @MainActor func testModelChipOpensThePowerUpPicker() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture", "--model-effort-fixture"] + appearance
        app.launch()
        let chip = app.buttons["chooseModel"]
        XCTAssertTrue(chip.waitForExistence(timeout: 8))
        chip.tap()
        // A keyless Claude connection (claude-opus-5) set to High: the effort page with its slider.
        let title = app.staticTexts["effortTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "High")
        XCTAssertTrue(app.otherElements["effortSlider"].exists || app.descendants(matching: .any)["effortSlider"].exists)
        shot("model-effort")
        app.buttons["resetEffort"].tap()
        XCTAssertTrue(waitFor(title, label: "Model's default"))
        app.buttons["effortModel"].tap()
        XCTAssertTrue(app.buttons["model-onDevice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["model-privateCloud"].exists)
        XCTAssertTrue(app.buttons["addModelConnection"].exists)
        shot("model-list")
        // Choosing on-device: no efforts unless the system's model can reason, so the list stays.
        app.buttons["model-onDevice"].tap()
        XCTAssertTrue(app.buttons["model-onDevice"].isSelected || app.staticTexts["effortTitle"].waitForExistence(timeout: 3))
    }

    // MARK: Helpers

    private func waitFor(_ element: XCUIElement, label: String) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)], timeout: 5) == .completed
    }
    private func waitForGone(_ element: XCUIElement) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 5) == .completed
    }
    @MainActor @discardableResult private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<6 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists, "\(element) never appeared")
        return element
    }
    private func shot(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let environment = ProcessInfo.processInfo.environment
        guard let folder = environment["KEMO_SHOT_DIR"], !folder.isEmpty else { return }
        let mode = environment["KEMO_SHOT_MODE"] ?? "light"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent("iphone-\(name)-\(mode).png"))
    }
}
