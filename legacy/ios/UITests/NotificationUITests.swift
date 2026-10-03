import XCTest

/// Settings → Notifications and where a notification tap goes (the owner's request, September 25,
/// 2026), plus a real local notification delivered on the simulator.
final class NotificationUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func openNotifications(_ arguments: [String]) -> XCUIApplication {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10))
        app.buttons["settingsGear"].tap()
        let row = app.buttons["openNotifications"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<5 where !row.isHittable { app.swipeUp() }
        row.tap()
        XCTAssertTrue(app.navigationBars["Notifications"].waitForExistence(timeout: 5))
        return app
    }
    @MainActor private func element(_ id: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any)[id].firstMatch
    }

    @MainActor func testNotificationsPageShowsEachPermissionState() {
        // Not asked yet: one button asks.
        var app = openNotifications(["--notification-permission=notDetermined"])
        XCTAssertTrue(app.buttons["allowNotifications"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["openNotificationSettings"].exists)
        // One switch per kind, and the watch's nudges.
        for id in ["notify-replies", "notify-day", "notify-coding"] { XCTAssertTrue(app.switches[id].waitForExistence(timeout: 5), id) }
        XCTAssertTrue(element("watchNudgesState", in: app).waitForExistence(timeout: 5))
        let replies = app.switches["notify-replies"]
        XCTAssertEqual(replies.value as? String, "1")
        replies.switches.firstMatch.tap()
        XCTAssertEqual(replies.value as? String, "0")
        replies.switches.firstMatch.tap()
        XCTAssertEqual(replies.value as? String, "1")
        capture("notifications-not-determined", app)
        app.terminate()
        // Turned off in iOS Settings: a short line and Open Settings.
        app = openNotifications(["--notification-permission=denied"])
        XCTAssertTrue(app.buttons["openNotificationSettings"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Notifications are off for KemoSabe."].exists)
        XCTAssertFalse(app.buttons["allowNotifications"].exists)
        capture("notifications-denied", app)
        app.terminate()
        // Allowed.
        app = openNotifications(["--notification-permission=allowed"])
        XCTAssertTrue(element("notificationPermission", in: app).waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["allowNotifications"].exists); XCTAssertFalse(app.buttons["openNotificationSettings"].exists)
        capture("notifications-allowed", app)
    }

    @MainActor func testARealLocalNotificationAppears() {
        let app = openNotifications(["--notification-probe"])
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        if app.buttons["allowNotifications"].waitForExistence(timeout: 3) {
            app.buttons["allowNotifications"].tap()
            let allow = springboard.alerts.buttons["Allow"]
            XCTAssertTrue(allow.waitForExistence(timeout: 10), "iOS asks only when the button is tapped")
            allow.tap()
        }
        XCTAssertTrue(element("notificationPermission", in: app).waitForExistence(timeout: 10), "Notifications are on")
        let send = app.buttons["sendTestNotification"]
        for _ in 0..<5 where !send.isHittable { app.swipeUp() }
        send.tap()
        XCTAssertTrue(element("testNotificationNote", in: app).waitForExistence(timeout: 5))
        // Leave the app; the system shows the banner five seconds after it was sent.
        XCUIDevice.shared.press(.home)
        let banner = springboard.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Notifications work.")).firstMatch
        XCTAssertTrue(banner.waitForExistence(timeout: 20), "The local notification was delivered and shown")
        capture("notification-banner", springboard)
    }

    @MainActor func testTappingANotificationOpensDayOrTheMacNotice() {
        var app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture", "--notification-link=day"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your day"].waitForExistence(timeout: 10), "A Day notification opens Day")
        app.terminate()
        app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture", "--notification-link=mac-approval"]
        app.launch()
        let title = app.staticTexts["macNoticeTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertEqual(title.label, "Approve it on your Mac")
        XCTAssertTrue(app.staticTexts["Claude Code"].exists); XCTAssertTrue(app.staticTexts["Run a command"].exists)
        XCTAssertFalse(app.buttons["Approve"].exists, "Approving happens on the Mac")
        capture("mac-notice", app)
        app.buttons["closeMacNotice"].tap()
        XCTAssertFalse(title.waitForExistence(timeout: 2))
    }

    // MARK: In-app notices (Dynamic Island–style, September 25, 2026)

    @MainActor private func launchNotice(_ kind: String, tab: String = "Home", hold: Int = 30) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "--tab=\(tab)", "--in-app-notice=\(kind)", "--in-app-notice-hold=\(hold)"]
        app.launch()
        return app
    }
    /// With an island the card's top sits in the island's place; without one it drops below the status bar.
    @MainActor private func islandSuffix(_ notice: XCUIElement) -> String { notice.frame.minY < 30 ? "island" : "no-island" }

    @MainActor func testInAppReplyNoticeExpandsAndOpensItsConversation() {
        let app = launchNotice("reply")
        let notice = element("inAppNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10), "A reply on another tab shows in the app")
        XCTAssertTrue(notice.label.contains("Saturday is set"))
        Thread.sleep(forTimeInterval: 1)
        let suffix = islandSuffix(notice)
        XCTAssertGreaterThan(notice.frame.width, 300, "Out of the island into a card")
        capture("in-app-notice-compact-" + suffix, app)
        // A long press shows more, with Open and Dismiss.
        notice.press(forDuration: 0.8)
        let open = app.buttons["inAppNoticeOpen"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["inAppNoticeDismiss"].exists)
        Thread.sleep(forTimeInterval: 0.8)
        capture("in-app-notice-expanded-" + suffix, app)
        open.tap()
        XCTAssertTrue(app.buttons["tab-Chat"].waitForExistence(timeout: 5))
        let chat = NSPredicate(format: "isSelected == true")
        expectation(for: chat, evaluatedWith: app.buttons["tab-Chat"])
        waitForExpectations(timeout: 5)
        XCTAssertFalse(notice.waitForExistence(timeout: 2) && notice.isHittable, "It went back into the island")
    }

    @MainActor func testTappingAMacNoticeOpensApproveItOnYourMac() {
        let app = launchNotice("mac")
        let notice = element("inAppNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("Claude Code needs you"))
        Thread.sleep(forTimeInterval: 1)
        capture("in-app-notice-mac-" + islandSuffix(notice), app)
        notice.tap()
        let title = app.staticTexts["macNoticeTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertEqual(title.label, "Approve it on your Mac")
    }

    @MainActor func testNoticesQueueAndSwipeUpDismisses() {
        let app = launchNotice("queue")
        let notice = element("inAppNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("Saturday is set"), "The reply first")
        Thread.sleep(forTimeInterval: 1)
        notice.swipeUp()
        // The Mac notice follows once the reply has gone back into the island.
        let next = NSPredicate(format: "label CONTAINS %@", "Claude Code needs you")
        expectation(for: next, evaluatedWith: element("inAppNotice", in: app))
        waitForExpectations(timeout: 6)
    }

    @MainActor func testADayNoticeOpensDay() {
        let app = launchNotice("day")
        let notice = element("inAppNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        XCTAssertTrue(notice.label.contains("Your day"))
        notice.tap()
        expectation(for: NSPredicate(format: "isSelected == true"), evaluatedWith: app.buttons["tab-Day"])
        waitForExpectations(timeout: 5)
    }

    @MainActor func testNoNoticeForTheChatYoureLookingAt() {
        let app = launchNotice("reply", tab: "Chat")
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 10))
        XCTAssertFalse(element("inAppNotice", in: app).waitForExistence(timeout: 5))
    }

    @MainActor func testTheNoticeCollapsesOnItsOwn() {
        let app = launchNotice("reply", hold: 2)
        let notice = element("inAppNotice", in: app)
        XCTAssertTrue(notice.waitForExistence(timeout: 10))
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: notice)
        waitForExpectations(timeout: 8)
    }

    @MainActor private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
