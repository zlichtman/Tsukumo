import XCTest

/// Models → System One on iPhone (design/UI-GUIDE.md, "System One"), with `--system-one-fixture`:
/// its own folder and Keychain service (".uitests"), no saved key, and one Plan fit decision Laya
/// was unsure of. The status card says what to do, Add key opens the field and the confirmation,
/// Details holds the decision to mark Wrong, and Training counts the mark. Nothing is sent anywhere:
/// no chat runs, so no decision reaches Jev.
final class SystemOneUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    @MainActor private func reveal(_ target: XCUIElement, in app: XCUIApplication, up: Bool = true) -> XCUIElement {
        for _ in 0..<12 where !(target.exists && target.isHittable) { up ? app.swipeUp() : app.swipeDown() }
        return target
    }
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor func testAddAJevKeyAndMarkADecisionWrong() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "--system-one-fixture", "-app.appearance.mode", "Dark"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10))
        app.buttons["settingsGear"].tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        let models = reveal(app.buttons["openModel"], in: app)
        XCTAssertTrue(models.waitForExistence(timeout: 5))
        models.tap()
        XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
        let tab = app.segmentedControls["modelsTabs"].buttons["System One"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5))
        tab.tap()

        // Off, and the one thing to do.
        let summary = element(app, "systemOneSummary")
        XCTAssertTrue(summary.waitForExistence(timeout: 5))
        XCTAssertTrue(summary.label.hasPrefix("Off"), summary.label)
        XCTAssertTrue(summary.label.contains("Download Laya to decide on this device."), summary.label)
        XCTAssertTrue(app.buttons["systemOneAction"].exists, "Download, on the card")
        XCTAssertFalse(app.buttons["layaDownload"].exists, "One Download, not two")
        let openAI = reveal(element(app, "systemOneStatus-OpenAI Decisions"), in: app)
        XCTAssertTrue(openAI.waitForExistence(timeout: 5))
        XCTAssertEqual(openAI.label, "In preview")

        // Add the key: the link to TypeSafe is there, Add waits for a whole key, then confirms where decisions go.
        XCTAssertFalse(app.secureTextFields["jevKey"].exists, "The key field waits for Add key")
        reveal(app.buttons["showJevKey"], in: app).tap()
        let field = reveal(app.secureTextFields["jevKey"], in: app, up: false)
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "getJevKey").exists, "Get a Jev key")
        let add = app.buttons["addJevKey"]
        XCTAssertFalse(add.isEnabled)
        field.tap(); field.typeText("tsk-uitest-key-0123456789")
        XCTAssertTrue(add.isEnabled)
        capture(app, "system-one-key")
        add.tap()
        let confirm = app.buttons["Send decisions to api.typesafe.ai"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        let jevStatus = element(app, "systemOneStatus-Jev")
        XCTAssertTrue(jevStatus.waitForExistence(timeout: 5))
        XCTAssertTrue(waitForLabel(jevStatus, "Active"))
        XCTAssertTrue(app.switches["jevEnabled"].exists, "Use Jev")
        XCTAssertFalse(app.secureTextFields["jevKey"].exists, "The key isn't shown again")
        XCTAssertTrue(waitForLabel(reveal(element(app, "systemOneSummary"), in: app, up: false), "On · Jev decides with your key, Until Laya is on this device.")
                      || element(app, "systemOneSummary").label.hasPrefix("On · Jev decides with your key"))
        capture(app, "system-one-jev-active")

        // Details hold the decisions: mark the Plan fit one Wrong, 2:00 PM was right, not 9:00 AM.
        XCTAssertFalse(element(app, "systemOneWrong").exists, "Behind Details")
        reveal(app.buttons["systemOneDetails"], in: app).tap()
        let wrong = reveal(element(app, "systemOneWrong"), in: app)
        XCTAssertTrue(wrong.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Laya leaned: 9:00 AM"].exists)
        wrong.tap()
        let choice = app.buttons["2:00 PM"].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["9:00 AM"].exists, "Only the other choices")
        choice.tap()
        let marked = element(app, "systemOneMarked")
        XCTAssertTrue(marked.waitForExistence(timeout: 5))
        XCTAssertEqual(marked.label, "Marked wrong · 2:00 PM was right")
        capture(app, "system-one-marked")
        // Training counts it.
        for _ in 0..<8 { app.swipeDown() }
        app.segmentedControls["modelsTabs"].buttons["Training"].tap()
        let planFit = element(app, "personalStatus-candidateFit")
        XCTAssertTrue(planFit.waitForExistence(timeout: 5))
        XCTAssertEqual(planFit.label, "1 of 30 marked")
        XCTAssertEqual(element(app, "training-laya").label, "Collecting 1 of 30")
        XCTAssertFalse(app.buttons["trainLaya"].isEnabled, "Not enough marks yet")
        capture(app, "training-marked")
    }

    private func waitForLabel(_ element: XCUIElement, _ label: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        return XCTWaiter.wait(for: [expectation], timeout: 5) == .completed
    }
}
