import XCTest

/// The iPhone app end to end: the first run, the demo, sending a message, making and customizing a bot,
/// KemoSabe's settings, the consent card, Activity. Every launch uses `--ui-testing` (fresh, temporary
/// storage, its own Keychain services, and a stand-in for Sign in with Apple); all but the first-run
/// tests also pass `--skip-onboarding`.
@MainActor final class TsukumoUITests: XCTestCase {
    override func setUp() async throws { continueAfterFailure = false }

    private func launch(_ arguments: [String], onboarding: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (onboarding ? [] : ["--skip-onboarding"]) + arguments
        app.launch()
        return app
    }
    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// The website demo, beat for beat: typed, sent to Claude, Claude works, asks KemoSabe, KemoSabe
    /// reads and answers, Claude replies.
    func testDemoFixturePlaysBeatForBeat() {
        let app = launch(["--demo-fixture"])
        XCTAssertTrue(element(app, "ownerMessage").waitForExistence(timeout: 20), "beat 1: the message is sent")
        XCTAssertTrue(element(app, "ownerMessage").label.contains("find a date spot for Sarah and I tonight"))
        XCTAssertTrue(element(app, "kemoSabeQuestion").waitForExistence(timeout: 10), "beat 3: Claude asks KemoSabe")
        XCTAssertTrue(element(app, "kemoSabeAnswer").waitForExistence(timeout: 10), "beat 4: KemoSabe answers")
        XCTAssertTrue(app.staticTexts["After 7 tonight"].exists)
        XCTAssertTrue(app.staticTexts["Not read: 1 Device only chat."].exists)
        let reply = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Osteria Lucia")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10), "beat 5: Claude replies")
        attach(app, "Demo final frame")

        // What happened shows in Activity, at the bottom of the conversations drawer.
        element(app, "openDrawer").tap()
        XCTAssertTrue(element(app, "drawerActivity").waitForExistence(timeout: 5))
        element(app, "drawerActivity").tap()
        XCTAssertTrue(element(app, "activity-kemoSabeAnswer").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "activity-botWork").exists)
    }

    /// The chat is the whole app: no tab bar; the conversations drawer (its button or a swipe from the
    /// left edge) has New chat, your chats, and Activity; Settings is the top right button.
    func testConversationsDrawer() {
        let app = launch([])
        let input = element(app, "chatInput")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        XCTAssertEqual(app.tabBars.count, 0, "no tab bar")
        input.tap()
        input.typeText("remember the drawer")
        element(app, "sendMessage").tap()
        XCTAssertTrue(element(app, "ownerMessage").waitForExistence(timeout: 5))

        // A swipe from the left edge opens the drawer, with this chat in it.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.01, dy: 0.5))
        edge.press(forDuration: 0.05, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.7, dy: 0.5)))
        XCTAssertTrue(element(app, "drawer").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "drawerNewChat").exists)
        XCTAssertTrue(element(app, "drawerActivity").exists)
        XCTAssertTrue(element(app, "drawerChat").waitForExistence(timeout: 5))
        attach(app, "Conversations drawer")

        // New chat closes the drawer on an empty chat.
        element(app, "drawerNewChat").tap()
        XCTAssertTrue(app.staticTexts["What’s on your mind?"].waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "ownerMessage").exists)

        // The button opens it too; picking the chat closes it and shows that chat.
        element(app, "openDrawer").tap()
        XCTAssertTrue(element(app, "drawerChat").waitForExistence(timeout: 5))
        element(app, "drawerChat").tap()
        XCTAssertTrue(element(app, "ownerMessage").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "drawer").exists)

        // Settings is the top right button.
        element(app, "openSettings").tap()
        XCTAssertTrue(element(app, "bot-KemoSabe").waitForExistence(timeout: 5))
        element(app, "closeSettings").tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
    }

    func testSendingAMessageGetsAnAnswer() {
        let app = launch([])
        let input = element(app, "chatInput")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        input.tap()
        input.typeText("hello")
        element(app, "sendMessage").tap()
        XCTAssertTrue(element(app, "ownerMessage").waitForExistence(timeout: 5))
        // KemoSabe answers on Apple's on-device model, or says why it can't on this simulator.
        let answered = NSPredicate { _, _ in self.element(app, "botReply").exists || self.element(app, "botStatus").exists }
        expectation(for: answered, evaluatedWith: nil)
        waitForExpectations(timeout: 60)
        attach(app, "kemosabe-answer")
        // A reason is written for people: never the framework's own error, never lowercased names.
        let status = element(app, "botStatus")
        if status.exists {
            let text = status.label
            XCTAssertFalse(text.contains("FoundationModels") || text.contains("error -"), text)
            XCTAssertFalse(text.contains("apple intelligence") || text.contains("iphone"), text)
        }
    }

    func testMakingABot() {
        let app = launch(["--demo-final"])
        element(app, "composerAddBot").tap()
        let claude = element(app, "engine-Claude")
        XCTAssertTrue(claude.waitForExistence(timeout: 5), "the engine comes first")
        XCTAssertFalse(element(app, "engine-Claude Code").isEnabled, "coding agents run on a Mac")
        claude.tap()

        let name = element(app, "botName")
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let first = name.value as? String ?? ""
        XCTAssertFalse(first.isEmpty, "a fun name is filled in")
        element(app, "rerollName").tap()
        XCTAssertNotEqual(name.value as? String, first, "the dice give a new name")
        element(app, "rerollCharacter").tap()
        // The drawers start closed: Look, Personality, Brain, Context, Permissions, Dock.
        for drawer in ["drawerLook", "drawerPersonality", "drawerBrain", "drawerContext", "drawerPermissions", "drawerDock"] {
            XCTAssertTrue(element(app, drawer).exists, drawer)
        }
        XCTAssertFalse(app.staticTexts["Most private it may get"].exists)
        attach(app, "Make a bot")
        let chosen = name.value as? String ?? ""
        element(app, "saveBot").tap()
        XCTAssertTrue(element(app, "chip-" + chosen).waitForExistence(timeout: 5), "the new bot joins the composer's chips")
    }

    func testFirstQuestionShowsTheConsentCard() {
        let app = launch(["--consent-fixture", "--demo-pace=0.25"])
        let always = element(app, "consentAlways")
        XCTAssertTrue(always.waitForExistence(timeout: 20), "the first time, KemoSabe asks on its card")
        XCTAssertTrue(element(app, "consentOnce").exists)
        XCTAssertTrue(element(app, "consentDeny").exists)
        attach(app, "Consent card")
        always.tap()
        XCTAssertTrue(element(app, "kemoSabeAnswer").waitForExistence(timeout: 10))
    }

    func testActivityShowsWhatHappened() {
        let app = launch(["--demo-activity", "--open=activity"])
        XCTAssertTrue(element(app, "activity-kemoSabeAnswer").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "activity-kemoSabeRefusal").exists)
        XCTAssertTrue(element(app, "activity-systemOne").exists)
        XCTAssertTrue(element(app, "activity-botWork").exists)
        attach(app, "Activity")
        app.segmentedControls.buttons["System One"].tap()
        XCTAssertTrue(element(app, "activity-systemOne").waitForExistence(timeout: 3))
        XCTAssertFalse(element(app, "activity-kemoSabeAnswer").exists)
    }

    func testSettingsHasBotsModelsAndKemoSabe() {
        let app = launch(["--demo-final", "--open=settings"])
        XCTAssertTrue(element(app, "bot-KemoSabe").waitForExistence(timeout: 10))
        XCTAssertTrue(element(app, "bot-Claude").exists)
        attach(app, "Settings")
        element(app, "settingsModels").tap()
        XCTAssertTrue(element(app, "appleOnDeviceStatus").waitForExistence(timeout: 5))
        app.navigationBars.buttons.element(boundBy: 0).tap()
        element(app, "settingsKemoSabe").tap()
        XCTAssertTrue(app.staticTexts["Personal sources"].waitForExistence(timeout: 5))
    }

    // MARK: The first run

    /// Walks the first run: welcome, sign in (the stand-in), skip connecting, pick starters, and land in
    /// the chat. Each step can wait `pause` seconds (the tour).
    private func walkOnboarding(_ app: XCUIApplication, pause: (Double) -> Void = { _ in }) {
        XCTAssertTrue(element(app, "onboardingWelcome").waitForExistence(timeout: 10), "the first run starts with the welcome")
        pause(2)
        element(app, "onboardingStart").tap()
        XCTAssertTrue(element(app, "onboardingSignIn").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "continueWithoutAccount").exists, "an account is optional")
        pause(1.5)
        element(app, "signInWithApple").tap()
        XCTAssertTrue(element(app, "onboardingConnect").waitForExistence(timeout: 5), "signing in moves on")
        XCTAssertTrue(element(app, "onboardingAppleIntelligence").exists)
        XCTAssertTrue(element(app, "connectKey-claude").exists)
        XCTAssertTrue(element(app, "onboardingSource-calendar").exists)
        pause(2)
        element(app, "connectSkip").tap()
        XCTAssertTrue(element(app, "onboardingBots").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "onboardingKemoSabe").exists, "KemoSabe is always included")
        pause(1)
        element(app, "starter-Homework helper").tap()
        pause(0.8)
        element(app, "starter-Research reader").tap()
        pause(1.5)
        element(app, "onboardingFinish").tap()
    }

    func testOnboardingEndToEnd() {
        let app = launch([], onboarding: true)
        walkOnboarding(app)
        // The chat, with the starters as chips beside KemoSabe.
        XCTAssertTrue(element(app, "chatInput").waitForExistence(timeout: 10), "lands in the chat")
        XCTAssertTrue(element(app, "chip-Homework").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "chip-Research").exists)
        attach(app, "After the first run")

        // Settings, Account: the account, sync waiting on the capability, and Sign Out.
        element(app, "openSettings").tap()
        element(app, "settingsAccount").tap()
        XCTAssertTrue(element(app, "accountName").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "accountName").label, "Test Owner")
        XCTAssertEqual(element(app, "syncStatus").label, "Waiting for iCloud to be turned on for Tsukumo")
        element(app, "signOut").tap()
        XCTAssertTrue(element(app, "signInWithApple").waitForExistence(timeout: 5), "signed out, it offers Sign in with Apple again")
        XCTAssertEqual(element(app, "syncStatus").label, "Off: no account")
        // That the first run shows once across launches is `AccountAndSyncTests` (each --ui-testing launch
        // starts from a fresh folder).
    }

    func testContinuingWithoutAnAccountKeepsSyncOff() {
        let app = launch([], onboarding: true)
        XCTAssertTrue(element(app, "onboardingStart").waitForExistence(timeout: 10))
        element(app, "onboardingStart").tap()
        element(app, "continueWithoutAccount").tap()
        element(app, "connectSkip").tap()
        element(app, "onboardingFinish").tap()
        XCTAssertTrue(element(app, "chatInput").waitForExistence(timeout: 10))
        element(app, "openSettings").tap()
        element(app, "settingsAccount").tap()
        XCTAssertTrue(element(app, "syncStatus").waitForExistence(timeout: 5))
        XCTAssertEqual(element(app, "syncStatus").label, "Off: no account")
    }

    // MARK: Bots

    /// KemoSabe's settings are its color and nothing else: no dice, no name, no character, no engine.
    func testKemoSabeSettingsShowOnlyItsColor() {
        let app = launch(["--open=settings"])
        XCTAssertTrue(element(app, "bot-KemoSabe").waitForExistence(timeout: 10))
        element(app, "bot-KemoSabe").tap()
        XCTAssertTrue(element(app, "kemoSabeEditor").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "kemoSabePreview").exists, "its cloud")
        for absent in ["rerollCharacter", "rerollName", "botName", "drawerLook", "drawerBrain", "drawerPermissions", "botEngine", "lookPreview"] {
            XCTAssertFalse(element(app, absent).exists, "\(absent) isn't offered for KemoSabe")
        }
        XCTAssertTrue(element(app, "kemoSabeColor-coral").exists)
        element(app, "kemoSabeColor-iris").tap()
        XCTAssertTrue(element(app, "kemoSabeColor-iris").isSelected)
        attach(app, "KemoSabe settings")
        element(app, "saveBot").tap()
        // Reopened, the color stuck.
        XCTAssertTrue(element(app, "bot-KemoSabe").waitForExistence(timeout: 5))
        element(app, "bot-KemoSabe").tap()
        XCTAssertTrue(element(app, "kemoSabeColor-iris").waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "kemoSabeColor-iris").isSelected)
    }

    /// A bot's look changes live on its character as it's edited, and stays.
    func testCustomizingABotsLook() {
        let app = launch(["--demo-final", "--open=settings"])
        XCTAssertTrue(element(app, "bot-Claude").waitForExistence(timeout: 10))
        element(app, "bot-Claude").tap()
        let preview = element(app, "lookPreview")
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let before = preview.value as? String ?? ""
        element(app, "drawerLook").tap()
        let bowTie = element(app, "accessory-bowTie")
        XCTAssertTrue(bowTie.waitForExistence(timeout: 5))
        bowTie.tap()
        element(app, "expression-grin").tap()
        // Back up to the preview at the top of the sheet.
        for _ in 0..<4 where !preview.exists { app.swipeDown() }
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        let after = preview.value as? String ?? ""
        XCTAssertNotEqual(before, after)
        XCTAssertTrue(after.contains("Bow tie") && after.contains("Big grin"), after)
        attach(app, "Customized bot")
        element(app, "saveBot").tap()
        XCTAssertTrue(element(app, "bot-Claude").waitForExistence(timeout: 5))
        element(app, "bot-Claude").tap()
        XCTAssertTrue(element(app, "lookPreview").waitForExistence(timeout: 5))
        XCTAssertTrue((element(app, "lookPreview").value as? String ?? "").contains("Bow tie"), "the look was saved")
    }

    // MARK: Pictures

    /// Light and dark pictures of the first run, KemoSabe's settings, and a customized bot, into
    /// `TEST_RUNNER_TSUKUMO_SCREENSHOT_DIR` (design/onboarding and design/bot-customization are made from it).
    func testScreenshots() throws {
        guard let folder = ProcessInfo.processInfo.environment["TSUKUMO_SCREENSHOT_DIR"].flatMap({ $0.isEmpty ? nil : $0 }) else {
            throw XCTSkip("Set TEST_RUNNER_TSUKUMO_SCREENSHOT_DIR to save the pictures.")
        }
        let out = URL(fileURLWithPath: folder, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func shot(_ app: XCUIApplication, _ name: String) throws {
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            try app.screenshot().pngRepresentation.write(to: out.appendingPathComponent(name + ".png"))
        }
        for appearance in ["light", "dark"] {
            let app = launch(["--appearance=" + appearance], onboarding: true)
            XCTAssertTrue(element(app, "onboardingWelcome").waitForExistence(timeout: 10))
            try shot(app, "iphone-1-welcome-" + appearance)
            element(app, "onboardingStart").tap()
            XCTAssertTrue(element(app, "onboardingSignIn").waitForExistence(timeout: 5))
            try shot(app, "iphone-2-sign-in-" + appearance)
            element(app, "signInWithApple").tap()
            XCTAssertTrue(element(app, "onboardingConnect").waitForExistence(timeout: 5))
            try shot(app, "iphone-3-connect-" + appearance)
            element(app, "connectSkip").tap()
            XCTAssertTrue(element(app, "onboardingBots").waitForExistence(timeout: 5))
            element(app, "starter-Homework helper").tap()
            try shot(app, "iphone-4-bots-" + appearance)
            element(app, "onboardingFinish").tap()
            XCTAssertTrue(element(app, "chatInput").waitForExistence(timeout: 10))
            try shot(app, "iphone-5-chat-" + appearance)

            element(app, "openSettings").tap()
            element(app, "settingsAccount").tap()
            XCTAssertTrue(element(app, "accountName").waitForExistence(timeout: 5))
            try shot(app, "iphone-account-" + appearance)
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(element(app, "bot-KemoSabe").waitForExistence(timeout: 5))
            element(app, "bot-KemoSabe").tap()
            XCTAssertTrue(element(app, "kemoSabeColor-iris").waitForExistence(timeout: 5))
            element(app, "kemoSabeColor-iris").tap()
            try shot(app, "iphone-kemosabe-settings-" + appearance)
            element(app, "saveBot").tap()

            XCTAssertTrue(element(app, "bot-Homework").waitForExistence(timeout: 5))
            element(app, "bot-Homework").tap()
            XCTAssertTrue(element(app, "drawerLook").waitForExistence(timeout: 5))
            element(app, "drawerLook").tap()
            element(app, "accessory-scarf").tap()
            element(app, "expression-grin").tap()
            element(app, "accentColor-iris").tap()
            try shot(app, "iphone-bot-editor-look-" + appearance)
            app.swipeUp()
            app.swipeUp()
            try shot(app, "iphone-bot-editor-look-2-" + appearance)
            // Back to the top: the customized character, live.
            for _ in 0..<6 where !element(app, "lookPreview").isHittable { app.swipeDown() }
            try shot(app, "iphone-bot-editor-preview-" + appearance)
            app.terminate()
        }
    }

    /// A paced walk through the app for a screen recording, on the real on-device model: the first run,
    /// then the chat. Runs only with TEST_RUNNER_TSUKUMO_TOUR=1, so the suite stays quick.
    func testTour() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TSUKUMO_TOUR"] != nil, "Set TEST_RUNNER_TSUKUMO_TOUR=1 to record the tour.")
        let app = launch([], onboarding: true)
        let pause = { (seconds: Double) in RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
        walkOnboarding(app, pause: pause)
        let input = element(app, "chatInput")
        XCTAssertTrue(input.waitForExistence(timeout: 10))
        pause(1.5)
        input.tap()
        input.typeText("What should I do this weekend?")
        pause(0.6)
        element(app, "sendMessage").tap()
        XCTAssertTrue(element(app, "botReply").waitForExistence(timeout: 60))
        pause(3)
        input.tap()
        input.typeText("Something outside, and cheap")
        element(app, "sendMessage").tap()
        let replies = app.descendants(matching: .any).matching(identifier: "botReply")
        expectation(for: NSPredicate(format: "count >= 2"), evaluatedWith: replies)
        waitForExpectations(timeout: 60)
        pause(3.5)

        element(app, "openDrawer").tap()
        XCTAssertTrue(element(app, "drawer").waitForExistence(timeout: 5))
        pause(2)
        element(app, "drawerNewChat").tap()
        pause(1.5)

        element(app, "composerAddBot").tap()
        let engine = element(app, "engine-Apple on-device")
        XCTAssertTrue(engine.waitForExistence(timeout: 5))
        pause(1.2)
        engine.tap()
        XCTAssertTrue(element(app, "botName").waitForExistence(timeout: 5))
        pause(1.2)
        element(app, "rerollCharacter").tap()
        pause(1)
        element(app, "rerollCharacter").tap()
        pause(1.5)
        element(app, "saveBot").tap()
        pause(2)

        element(app, "openSettings").tap()
        XCTAssertTrue(element(app, "bot-KemoSabe").waitForExistence(timeout: 5))
        pause(2.5)
        element(app, "bot-KemoSabe").tap()
        XCTAssertTrue(element(app, "kemoSabeColor-iris").waitForExistence(timeout: 5))
        pause(1.2)
        element(app, "kemoSabeColor-iris").tap()
        pause(1.5)
        element(app, "saveBot").tap()
        pause(1)
        element(app, "closeSettings").tap()
        pause(1)
    }
}
