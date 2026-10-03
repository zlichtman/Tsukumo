import XCTest

final class KemoSabeWatchUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testHomeTalkAndSettings() {
        let app = XCUIApplication()
        // --ui-testing skips the first-run screen, as on a watch that has seen it.
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.buttons["watchTalk"].waitForExistence(timeout: 15))
        // Kemo is the talk button itself.
        XCTAssertEqual(app.buttons["watchTalk"].label, "Talk to KemoSabe")
        capture(app, "watch-home")
        // Tap to talk only (September 25): no Type, quick-note, or speaker buttons; volume is on the side.
        XCTAssertFalse(app.descendants(matching: .any)["watchType"].exists)
        XCTAssertFalse(app.buttons["watchCapture"].exists)
        XCTAssertFalse(app.buttons["watchReadAloud"].exists)
        // Clean and minimal (September 25): no model names or notes about where messages go.
        for words in ["on-device", "answers", "sent to", "Apple"] {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", words)).firstMatch.exists, words)
        }
        XCTAssertFalse(app.descendants(matching: .any)["watchSource"].exists)
        let settings = app.buttons.matching(identifier: "watchSettings").firstMatch
        XCTAssertTrue(settings.exists)
        settings.tap()
        XCTAssertTrue(app.switches["watchSettingsReadAloud"].waitForExistence(timeout: 5))
        // Kemo's nudges are off until turned on here; turning them on asks for notification permission.
        XCTAssertTrue(app.switches["watchSettingsNudges"].waitForExistence(timeout: 5))
        capture(app, "watch-settings-nudges")
        // Colors and tone are customized like a watch face, from Settings or a long press on Kemo.
        let customize = app.descendants(matching: .any)["watchSettingsCustomize"]
        XCTAssertTrue(customize.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", "on your iPhone")).firstMatch.exists)
        capture(app, "watch-settings")
        customize.tap()
        let editor = app.descendants(matching: .any)["watchEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.label, "Color")
        editor.tap()
        XCTAssertTrue(customize.waitForExistence(timeout: 5), "Tap to finish returns to Settings")
    }

    /// Long-press Kemo: Kemo shrinks, pages are titled at the top, the crown cycles options with a
    /// live preview, swipe changes page, and a tap finishes and applies the choices.
    func testCustomizeKemoLikeAWatchFace() {
        let app = XCUIApplication()
        // Sample palettes and local settings stand in for the iPhone.
        app.launchArguments = ["--ui-testing", "--watch-palettes", "--local-settings"]
        app.launch()
        let kemo = app.buttons["watchTalk"]
        XCTAssertTrue(kemo.waitForExistence(timeout: 15))
        kemo.press(forDuration: 1.2)
        let editor = app.descendants(matching: .any)["watchEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["watchSettings"].exists, "Only Kemo while editing")
        XCTAssertEqual(editor.label, "Color")
        XCTAssertEqual(editor.value as? String, "Apricot")
        capture(app, "watch-editor-color")
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
        let color = editor.value as? String
        XCTAssertNotEqual(color, "Apricot", "The crown cycles colors")
        capture(app, "watch-editor-color-turned")
        editor.swipeLeft()
        XCTAssertEqual(editor.label, "Tone")
        XCTAssertEqual(editor.value as? String, "Default")
        XCUIDevice.shared.rotateDigitalCrown(delta: 0.5)
        let tone = editor.value as? String
        XCTAssertNotEqual(tone, "Default", "The crown cycles tones")
        capture(app, "watch-editor-tone")
        editor.tap()
        XCTAssertTrue(kemo.waitForExistence(timeout: 5), "Tap to finish")
        // The choices stuck: editing again starts from them.
        kemo.press(forDuration: 1.2)
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, color)
        editor.swipeLeft()
        XCTAssertEqual(editor.value as? String, tone)
    }

    /// Kemo is a pet on the wrist: two tiny meters under it and a face that shows its mood.
    func testPetMoodShowsUnderKemo() {
        let app = XCUIApplication()
        // As it would be at 14:00, so the check doesn't depend on the time of day.
        app.launchArguments = ["--ui-testing", "--pet=hungry", "--pet-hour=14"]
        app.launch()
        let vitals = app.descendants(matching: .any)["watchVitals"]
        XCTAssertTrue(vitals.waitForExistence(timeout: 15))
        XCTAssertEqual(vitals.label, "Hungry")
        XCTAssertTrue((vitals.value as? String)?.hasPrefix("Fed 10 percent") == true, String(describing: vitals.value))
        capture(app, "watch-pet-hungry")
        app.terminate()
        // Kemo sleeps from 22:00 to 8:00, hungry or not.
        app.launchArguments = ["--ui-testing", "--pet=lonely", "--pet-hour=23"]
        app.launch()
        XCTAssertTrue(vitals.waitForExistence(timeout: 15))
        XCTAssertEqual(vitals.label, "Asleep")
        capture(app, "watch-pet-asleep")
        app.terminate()
        app.launchArguments = ["--ui-testing", "--pet=lonely", "--pet-hour=14"]
        app.launch()
        XCTAssertTrue(vitals.waitForExistence(timeout: 15))
        XCTAssertEqual(vitals.label, "Lonely")
        capture(app, "watch-pet-lonely")
    }

    /// The first run (September 25): no sign-in and no long text. Until the iPhone is set up, Kemo
    /// and "Finish setup on your iPhone"; then "Tap Kemo to talk", and the first tap goes home.
    func testFirstRunWaitsForTheIPhoneThenTapToTalk() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--first-run", "--phone-setup=no"]
        app.launch()
        let line = app.staticTexts["watchFirstRunLine"]
        XCTAssertTrue(line.waitForExistence(timeout: 15))
        XCTAssertEqual(line.label, "Finish setup on your iPhone")
        XCTAssertTrue(app.descendants(matching: .any)["watchKemo"].exists, "Kemo shows while waiting")
        XCTAssertFalse(app.buttons["watchFirstRunTalk"].exists, "Nothing to tap until the iPhone is set up")
        XCTAssertFalse(app.buttons["watchTalk"].exists)
        XCTAssertFalse(app.buttons["watchSettings"].exists, "One screen, no other controls")
        capture(app, "watch-first-run-phone")
        app.terminate()

        // The iPhone finished onboarding: one screen, then done.
        app.launchArguments = ["--ui-testing", "--first-run", "--phone-setup=yes"]
        app.launch()
        let talk = app.buttons["watchFirstRunTalk"]
        XCTAssertTrue(talk.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["watchFirstRunLine"].label, "Tap KemoSabe to talk")
        capture(app, "watch-first-run-tap")
        talk.tap()
        XCTAssertTrue(app.buttons["watchTalk"].waitForExistence(timeout: 5), "The first tap finishes the first run")
        XCTAssertTrue(app.buttons["watchSettings"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["watchFirstRunLine"].exists)
        app.terminate()

        // It doesn't come back on the next launch.
        app.launchArguments = ["--phone-setup=no"]
        app.launch()
        XCTAssertTrue(app.buttons["watchTalk"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["watchFirstRunLine"].exists)
    }

    private func capture(_ app: XCUIApplication, _ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
