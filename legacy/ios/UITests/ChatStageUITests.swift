import XCTest

/// Kemo in a chat (the owner's request, September 27, 2026): like a profile picture beside each
/// reply, and, while the chat has room, the big Kemo up on the stage acting out what it's doing.
/// `--sample-conversation=<n>` opens the chat with n exchanges already in it.
final class ChatStageUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private static let orbLabels = ["Working", "Searching", "Solving", "Listening", "Connecting", "Weaving", "Composing", "Thinking", "Shaping"]
    private func orbs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", Self.orbLabels))
    }
    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture"] + extra
        app.launch()
        XCTAssertTrue(app.textFields["chatInput"].waitForExistence(timeout: 8))
        return app
    }
    private func stage(_ app: XCUIApplication) -> XCUIElement { app.otherElements["homeCompanion"] }
    private func avatar(_ app: XCUIApplication) -> XCUIElement { app.descendants(matching: .any)["kemoAvatar"].firstMatch }
    private func gone(_ element: XCUIElement, timeout: TimeInterval = 5) {
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)], timeout: timeout)
    }

    @MainActor func testANewChatStartsWithTheBigKemo() {
        let app = launch()
        XCTAssertTrue(stage(app).waitForExistence(timeout: 5), "A new chat starts with Kemo on the stage")
        XCTAssertTrue(stage(app).label.hasPrefix("KemoSabe, greeting"), stage(app).label)
        let heading = app.staticTexts["What’s on your mind?"]
        XCTAssertTrue(heading.exists)
        XCTAssertGreaterThanOrEqual(heading.frame.minY, stage(app).frame.maxY, "The stage never covers the conversation")
        XCTAssertFalse(avatar(app).exists, "Kemo is on the stage, not in an avatar")
        XCTAssertEqual(app.buttons["compactCompanion"].label, "Minimize companion")
        capture("chat-stage-new", app)
    }

    @MainActor func testAShortConversationKeepsTheStage() {
        let app = launch(["--reply-fixture=0.5"])
        let input = app.textFields["chatInput"]
        input.tap(); input.typeText("Hello"); app.buttons["sendMessage"].tap()
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "KemoSabe: ")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 10))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        XCTAssertTrue(stage(app).exists, "Room for the stage: Kemo stays up")
        XCTAssertGreaterThanOrEqual(reply.frame.minY, stage(app).frame.maxY - 2, "The reply is under the stage")
        capture("chat-stage-short", app)
    }

    @MainActor func testALongChatPutsKemoInTheAvatarAndTheTopBringsItBack() {
        let app = launch(["--sample-conversation=10"])
        // The conversation fills the view: the stage is gone and Kemo is the latest reply's avatar.
        XCTAssertTrue(avatar(app).waitForExistence(timeout: 5), "Kemo is in the latest reply's avatar")
        XCTAssertFalse(stage(app).exists, "No stage while the conversation fills the view")
        XCTAssertTrue(app.buttons["homeCompanion"].exists, "The corner can bring Kemo back up")
        let composer = app.textFields["chatInput"]
        XCTAssertLessThan(avatar(app).frame.maxY, composer.frame.minY, "The avatar is beside the latest reply, above the composer")
        capture("chat-stage-long", app)

        // Scrolled to the top, the stage area is free: Kemo hops back up.
        let transcript = app.scrollViews["chatTranscript"]
        for _ in 0..<8 where !stage(app).exists { transcript.swipeDown(velocity: .fast) }
        XCTAssertTrue(stage(app).waitForExistence(timeout: 5), "Scrolling to the top brings the stage back")
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        capture("chat-stage-long-top", app)
        let first = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "You: Sample question 1:")).firstMatch
        XCTAssertTrue(first.exists)
        XCTAssertGreaterThanOrEqual(first.frame.minY, stage(app).frame.maxY - 2, "The stage pushes the conversation down, never covering it")
        XCTAssertFalse(avatar(app).exists, "Only one Kemo: the avatar is still again")

        // Back down to the latest message, Kemo returns to the avatar.
        for _ in 0..<8 where stage(app).exists { transcript.swipeUp(velocity: .fast) }
        gone(stage(app))
        // At the latest message, Kemo is its avatar again.
        let latest = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "KemoSabe: Sample answer 10.")).firstMatch
        for _ in 0..<6 where !(latest.exists && latest.isHittable) { transcript.swipeUp(velocity: .fast) }
        XCTAssertTrue(avatar(app).waitForExistence(timeout: 5))
        XCTAssertEqual(avatar(app).frame.midY, latest.frame.minY + 14, accuracy: 24, "Kemo is the latest reply's avatar")
        XCTAssertFalse(stage(app).exists)
    }

    @MainActor func testThinkingIsTheAvatarWithItsOrb() {
        let app = launch(["--sample-conversation=10", "--reply-fixture=20"])
        let input = app.textFields["chatInput"]
        input.tap(); input.typeText("Plan my week"); app.buttons["sendMessage"].tap()
        let row = app.descendants(matching: .any)["streamingReply"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        // One signal: the thinking row's avatar and its small orb, nothing else.
        XCTAssertEqual(orbs(app).count, 1, "Only the avatar's orb")
        let orb = orbs(app).firstMatch, kemo = avatar(app)
        XCTAssertTrue(kemo.exists, "Kemo is the thinking row's avatar")
        XCTAssertTrue(row.frame.contains(CGPoint(x: kemo.frame.midX, y: kemo.frame.midY)), "The avatar is in the thinking row")
        XCTAssertLessThan(abs(orb.frame.midX - kemo.frame.maxX), kemo.frame.width, "The orb sits on the avatar")
        XCTAssertFalse(stage(app).exists, "The conversation fills the view, so no stage")
        XCTAssertFalse(app.descendants(matching: .any)["headerState"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["voiceModeKemo"].exists)
        capture("chat-stage-thinking", app)
    }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        // For review: TEST_RUNNER_CHAT_STAGE_SHOTS=<folder> also writes each screenshot there.
        if let folder = ProcessInfo.processInfo.environment["CHAT_STAGE_SHOTS"], !folder.isEmpty {
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
