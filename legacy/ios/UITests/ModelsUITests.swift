import XCTest

/// Settings → Models on iPhone (the owner, September 30, 2026): three tabs, LLM, System One, and
/// Training, each on the theme; the LLM list with the default at the top; and voice on the Companion
/// page with no model choice. Light and dark pictures of each tab go to `KEMO_SNAPSHOT_DIR` when it's set
/// (pass `TEST_RUNNER_KEMO_SNAPSHOT_DIR`; `design/models/` for the owner). Nothing is downloaded or sent.
final class ModelsUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor func testModelsHasThreeTabsAndVoiceIsOnCompanion() {
        for mode in ["Light", "Dark"] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--isolated-fixture", "--system-one-fixture", "-app.appearance.mode", mode]
            app.launch()
            XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10))
            app.buttons["settingsGear"].tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            let models = app.buttons["openModel"]
            for _ in 0..<8 where !(models.exists && models.isHittable) { app.swipeUp() }
            models.tap()
            XCTAssertTrue(app.navigationBars["Models"].waitForExistence(timeout: 5))
            let tabs = app.segmentedControls["modelsTabs"]
            XCTAssertEqual(tabs.buttons.allElementsBoundByIndex.map(\.label), ["LLM", "System One", "Training"])

            // LLM: the default on top, then one list of models, Agents on your Mac, and Add a connection.
            XCTAssertTrue(app.staticTexts["defaultModel"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.staticTexts["defaultModel"].label, "Apple on-device")
            XCTAssertTrue(app.buttons["model-onDevice"].isSelected, "The default carries its badge")
            XCTAssertTrue(app.buttons["model-privateCloud"].exists)
            XCTAssertTrue(app.buttons["openMacAgents"].exists)
            XCTAssertTrue(app.buttons["addModelConnection"].exists)
            XCTAssertFalse(app.switches.matching(NSPredicate(format: "identifier BEGINSWITH 'grant-'")).firstMatch.exists,
                           "What a connection may read is on its own page")
            snapshot(app, "iphone-llm-" + mode.lowercased())

            // System One: one status card with its action, compact rows, and Details closed.
            tabs.buttons["System One"].tap()
            let summary = app.descendants(matching: .any).matching(identifier: "systemOneSummary").firstMatch
            XCTAssertTrue(summary.waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["systemOneAction"].exists)
            XCTAssertTrue(app.buttons["showJevKey"].exists)
            XCTAssertFalse(app.buttons["trainLaya"].exists, "Training has its own tab")
            snapshot(app, "iphone-system-one-" + mode.lowercased())
            let details = app.buttons["systemOneDetails"]
            for _ in 0..<4 where !(details.exists && details.isHittable) { app.swipeUp() }
            XCTAssertTrue(details.exists, "Details, closed")
            XCTAssertFalse(app.buttons["systemOneWrong"].exists, "Marks are behind Details")
            for _ in 0..<4 { app.swipeDown() }

            // Training: Laya, your voice, and day plans, each with a status and one action.
            tabs.buttons["Training"].tap()
            let laya = app.descendants(matching: .any).matching(identifier: "training-laya").firstMatch
            XCTAssertTrue(laya.waitForExistence(timeout: 5))
            XCTAssertEqual(laya.label, "Not started", "Nothing marked yet")
            XCTAssertTrue(app.buttons["trainLaya"].exists)
            XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "training-voice").firstMatch.label, "Not started")
            XCTAssertTrue(app.buttons["setUpOwnVoice"].exists)
            snapshot(app, "iphone-training-" + mode.lowercased())
            let dayPlans = app.descendants(matching: .any).matching(identifier: "training-dayPlans").firstMatch
            for _ in 0..<4 where !dayPlans.exists { app.swipeUp() }
            XCTAssertTrue(dayPlans.exists, "Day plans, with Manage")

            // Voice is on Companion: which voice it sounds like, with no model to choose.
            app.terminate(); app.launch()
            XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10))
            app.buttons["settingsGear"].tap()
            let companion = app.buttons["openCharacter"]
            XCTAssertTrue(companion.waitForExistence(timeout: 5))
            companion.tap()
            let voice = app.buttons["openVoiceSettings"]
            for _ in 0..<6 where !(voice.exists && voice.isHittable) { app.swipeUp() }
            voice.tap()
            XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.buttons["transcriptionModel"].exists)
            snapshot(app, "iphone-companion-voice-" + mode.lowercased())
            app.terminate()
        }
    }

    @MainActor private func snapshot(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["KEMO_SNAPSHOT_DIR"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
