import XCTest

/// Sharing your profile (design/ACCOUNTS-AND-PROFILES.md, "Sharing your profile"): audiences in
/// Edit profile, people from (sample) contacts, who sees what confirmed once, an invitation, and
/// "Shared with" in the header; then a profile shared with you in People. iCloud is a stub that
/// accepts every invitation (`--sharing-stub`); nothing leaves the simulator. Screenshots are
/// attached as `sharing-*` for design/profile-sharing.
final class ProfileSharingUITests: XCTestCase {
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "--profile-sample"] + extra
        app.launch()
        XCTAssertTrue(app.buttons["tab-Profile"].waitForExistence(timeout: 20))
        app.buttons["tab-Profile"].tap()
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 8))
        return app
    }

    @MainActor func testChoosePeopleAudiencesAndInvite() {
        let app = launch(["--sharing-stub", "--sample-contacts"])
        // No followers: the people who accepted, and a Sharing button.
        XCTAssertFalse(app.buttons["profileFollowers"].exists)
        XCTAssertFalse(app.buttons["profileFollowing"].exists)
        let sharedWith = app.buttons["profileSharedWith"]
        XCTAssertTrue(sharedWith.label.contains("0"))
        XCTAssertTrue(app.buttons["profileSharing"].exists)
        shot("sharing-01-header", app)

        // Edit profile: every block's bar has "Who can see this", Only you to start.
        app.buttons["profileEdit"].tap()
        let workAudience = reveal(app.buttons["profileBlockAudience-work"], in: app)
        XCTAssertEqual(workAudience.value as? String, "Only you")
        workAudience.tap()
        XCTAssertTrue(app.buttons["Your people"].waitForExistence(timeout: 5))
        shot("sharing-02-audience-menu", app)
        app.buttons["Your people"].tap()
        XCTAssertEqual(app.buttons["profileBlockAudience-work"].value as? String, "Your people")
        shot("sharing-03-edit-audience", app)
        toTop(app)
        app.buttons["profileDone"].tap()

        // Sharing: groups, then your people from contacts.
        app.buttons["profileSharing"].tap()
        XCTAssertTrue(app.buttons["sharingClose"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["sharingGroup-people"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["sharingGroup-close"].exists)
        shot("sharing-04-empty", app)
        app.buttons["sharingAddContacts"].tap()
        XCTAssertTrue(app.buttons["sampleContact-Alex Rivera"].waitForExistence(timeout: 5))
        app.buttons["sampleContact-Alex Rivera"].tap()
        app.buttons["sampleContact-Jordan Diaz"].tap()
        app.buttons["sampleContactsDone"].tap()

        // Who sees what, confirmed once, with suggestions.
        XCTAssertTrue(app.buttons["sharingUseDefaults"].waitForExistence(timeout: 5))
        shot("sharing-05-who-sees-what", app)
        app.buttons["sharingUseDefaults"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["sharingMember"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "sharingMember").count, 2)
        shot("sharing-06-people", app)

        // One person: Close friend, a per-block override, and the invitation.
        app.staticTexts["Alex Rivera"].tap()
        let close = app.switches["sharingClose-toggle"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertEqual(close.value as? String, "1")
        XCTAssertEqual(app.buttons["sharingBlock-photos"].value as? String, "Visible", "Close friends see photos")
        app.buttons["sharingBlock-photos"].tap()
        app.buttons["Never show"].tap()
        XCTAssertEqual(app.buttons["sharingBlock-photos"].value as? String, "Hidden")
        shot("sharing-07-member", app)
        app.buttons["sharingInvite"].tap()
        // The share sheet with the link: sent by you, through Messages or Mail.
        let sheet = app.otherElements["ActivityListView"]
        let shown = NSPredicate { _, _ in sheet.exists || app.buttons["Close"].exists || app.buttons["Copy"].exists }
        wait(for: [XCTNSPredicateExpectation(predicate: shown, object: nil)], timeout: 15)
        sleep(1); shot("sharing-08-invite", app)
        // The share sheet's own close (Sharing's close button is also named Close, underneath it).
        let shareClose = sheet.buttons["Close"]
        if shareClose.exists { shareClose.tap() } else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9))) }
        // If Sharing closed with it, open it again at the person.
        if app.buttons["profileSharing"].waitForExistence(timeout: 2), !app.buttons["sharingClose"].exists, !app.switches["sharingClose-toggle"].exists {
            app.buttons["profileSharing"].tap(); app.staticTexts["Alex Rivera"].tap()
        }
        XCTAssertTrue(app.staticTexts["Accepted"].waitForExistence(timeout: 10), "The stub accepts at once")
        // Back to Sharing (the share sheet's dismissal can leave the first tap to settle it).
        for _ in 0..<3 where !app.buttons["sharingClose"].waitForExistence(timeout: 2) {
            let back = app.navigationBars["Alex Rivera"].buttons.firstMatch
            if back.exists && back.isHittable { back.tap() }
            else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5)).press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5))) }
        }
        XCTAssertTrue(app.buttons["sharingClose"].waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(app.staticTexts["Accepted"].waitForExistence(timeout: 5))
        shot("sharing-09-accepted", app)
        app.buttons["sharingClose"].tap()

        // The header counts the one person who accepted.
        XCTAssertTrue(app.buttons["profileSharedWith"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profileSharedWith"].label.contains("1"))
        shot("sharing-10-shared-with-one", app)

        // Removing someone.
        app.buttons["profileSharing"].tap()
        XCTAssertTrue(app.staticTexts["Alex Rivera"].waitForExistence(timeout: 5))
        app.staticTexts["Alex Rivera"].tap()
        reveal(app.buttons["sharingRemove"], in: app).tap()
        app.buttons["sharingRemoveConfirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["sharingClose"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Alex Rivera"].exists)
        app.buttons["sharingClose"].tap()
        XCTAssertTrue(app.buttons["profileSharedWith"].label.contains("0"))
    }

    @MainActor func testAProfileSharedWithYouInPeople() {
        let app = launch(["--shared-profile-sample"])
        app.buttons["profilePeople"].tap()
        let row = app.buttons["sharedProfileRow"]
        XCTAssertTrue(row.waitForExistence(timeout: 8))
        shot("sharing-11-people-shared-with-you", app)
        row.tap()
        XCTAssertTrue(app.staticTexts["sharedProfileName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["sharedBlock-work"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["sharedBlock-personal"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["sharedBlock-photos"].exists, "Only what they shared")
        shot("sharing-12-shared-card", app)
        app.buttons["sharedProfileOptions"].tap()
        app.buttons["Remove profile"].firstMatch.tap()
        app.buttons["sharedProfileRemoveConfirm"].firstMatch.tap()
        XCTAssertTrue(app.buttons["closePeople"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sharedProfileRow"].exists)
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
        for _ in 0..<16 where !(element.exists && element.isHittable) { app.swipeUp(velocity: .slow) }
        XCTAssertTrue(element.exists, "\(element) never appeared")
        return element
    }
}
