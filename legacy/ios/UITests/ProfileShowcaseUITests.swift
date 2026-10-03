import XCTest

/// A filled-in profile (`--profile-sample`, a sample music library with `--sample-music`), block by
/// block, in dark and light, while editing, and at the largest text size. Screenshots are attached
/// as `profile-*` for design/profile-redesign.
final class ProfileShowcaseUITests: XCTestCase {
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "--profile-sample", "--sample-music"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["tab-Profile"].waitForExistence(timeout: 20))
        app.buttons["tab-Profile"].tap()
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor func testFilledProfileBlocksMusicAndLinkedIn() {
        let app = launch()
        XCTAssertTrue(app.staticTexts["Avery Chen"].exists)
        XCTAssertTrue(app.buttons["profilePinned"].exists, "The pinned post leads Photos")
        XCTAssertTrue(app.buttons["profileAllPosts"].exists)
        shot("profile-01-top", app)

        // Real stats from the (sample) library, only after Connect.
        let connect = reveal(app.buttons["profileConnectAppleMusic"], in: app)
        connect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileMusicTopArtist"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Frank Ocean")).firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["profileMusicGenre"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["profileMusicTotals"].exists)
        shot("profile-02-music", app)

        // Work reads like LinkedIn: a promotion grouped under one company, with durations.
        reveal(app.descendants(matching: .any)["profileWorkAbout"], in: app)
        app.swipeUp(velocity: .slow); sleep(1)
        XCTAssertTrue(app.staticTexts["Northwind Labs"].exists, "Two roles at Northwind Labs group under it")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Present ·")).firstMatch.exists, "Dates carry a duration")
        shot("profile-03-work", app)
        XCTAssertTrue(reveal(app.descendants(matching: .any)["profileCertification"].firstMatch, in: app).exists)
        shot("profile-04-work-more", app)
        app.swipeUp(); sleep(1); shot("profile-05-writing-personal", app)
        app.swipeUp(); sleep(1); shot("profile-06-links-kemo", app)

        // All posts: grouped by day.
        toTop(app)
        app.buttons["profileAllPosts"].tap()
        XCTAssertTrue(app.staticTexts["profileDay"].firstMatch.waitForExistence(timeout: 5))
        shot("profile-07-all-posts", app)
        app.navigationBars.buttons.element(boundBy: 0).tap()

        // Editing in place: fields, accent, and a bar on every block.
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))
        app.buttons["profileEdit"].tap()
        XCTAssertTrue(app.textFields["profileName"].waitForExistence(timeout: 5))
        shot("profile-08-edit-header", app)
        reveal(app.buttons["profileBlockStyle-music"], in: app).tap()
        app.buttons["Top songs"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileMusicSong"].firstMatch.waitForExistence(timeout: 5))
        shot("profile-09-edit-blocks", app)
        app.swipeUp(); sleep(1); shot("profile-10-edit-work", app)
        toTop(app)
        app.buttons["profileDone"].tap()
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))

        // Light mode.
        app.buttons["settingsGear"].tap(); app.buttons["openAppearance"].tap()
        app.segmentedControls["appColorMode"].buttons["Light"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["closeSettings"].tap()
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))
        sleep(1); shot("profile-11-light-top", app)
        reveal(app.descendants(matching: .any)["profileMusicSong"].firstMatch, in: app)
        sleep(1); shot("profile-12-light-music", app)
        app.swipeUp(); sleep(1); shot("profile-13-light-work", app)
    }

    /// The largest accessibility text size: everything still fits and wraps.
    @MainActor func testFilledProfileAtTheLargestTextSize() {
        let app = launch(["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.staticTexts["Avery Chen"].exists)
        shot("profile-ax-01-top", app)
        reveal(app.buttons["profileConnectAppleMusic"], in: app).tap()
        XCTAssertTrue(app.descendants(matching: .any)["profileMusicTopArtist"].waitForExistence(timeout: 8))
        shot("profile-ax-02-music", app)
        reveal(app.descendants(matching: .any)["profileBlock-work"], in: app)
        app.swipeUp(); sleep(1); shot("profile-ax-03-work", app)
        toTop(app)
        app.buttons["profileEdit"].tap()
        XCTAssertTrue(app.textFields["profileName"].waitForExistence(timeout: 5))
        reveal(app.buttons["profileBlockHide-photos"], in: app)
        shot("profile-ax-04-edit", app)
    }

    private func shot(_ name: String, _ app: XCUIApplication) {
        let a = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    @MainActor private func toTop(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        for _ in 0..<14 { app.swipeDown(velocity: .fast) }
    }
    @MainActor @discardableResult private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        _ = element.waitForExistence(timeout: 2)
        // On screen means its top is in the middle band of the window (clear of the header and tab bar).
        func onScreen() -> Bool {
            guard element.exists else { return false }
            let window = app.windows.firstMatch.frame, top = element.frame.minY
            return top > window.height * 0.15 && top < window.height * 0.7
        }
        for _ in 0..<24 where !(onScreen() || element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.exists, "\(element) never appeared")
        return element
    }
}
