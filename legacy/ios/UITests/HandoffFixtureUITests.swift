import XCTest

/// The chat-with-Claude demo on iPhone (design/CONTEXT-HARNESS.md#chatting-with-an-agent):
/// `--agent-handoff-fixture` types "find a date spot for Sarah and I tonight" to a fake Claude, which
/// asks KemoSabe when Sarah's free; KemoSabe's card answers on this iPhone ("After 7 tonight", with what
/// stayed and what was shared), and Claude replies with a date spot. The four beats appear in order.
final class HandoffFixtureUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// Kept in the test result, and written to `HANDOFF_SCREENSHOTS` when the run sets it.
    @MainActor private func capture(_ app: XCUIApplication, _ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot); attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
        if let folder = ProcessInfo.processInfo.environment["HANDOFF_SCREENSHOTS"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }

    @MainActor func testTheFourBeatsAppearInOrder() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "--agent-handoff-fixture", "-app.appearance.mode", "Dark"]
        app.launch()

        let task = element(app, "handoff-task"), question = element(app, "handoff-question")
        let answer = element(app, "handoff-answer"), result = element(app, "handoff-result")

        XCTAssertTrue(task.waitForExistence(timeout: 20), "1. Your message goes to Claude")
        XCTAssertTrue(task.label.contains("find a date spot for Sarah and I tonight"), task.label)
        XCTAssertFalse(question.exists)
        XCTAssertTrue(element(app, "handoffWorking").waitForExistence(timeout: 5), "Claude works")
        capture(app, "handoff-1-task")

        XCTAssertTrue(question.waitForExistence(timeout: 15), "2. Claude asks KemoSabe, on KemoSabe's card")
        XCTAssertTrue(question.label.contains("What time is Sarah free tonight?"), question.label)
        XCTAssertFalse(answer.exists)
        XCTAssertTrue(element(app, "handoffLooking").waitForExistence(timeout: 5), "KemoSabe looks on this iPhone")
        capture(app, "handoff-2-looking")

        XCTAssertTrue(answer.waitForExistence(timeout: 15), "3. KemoSabe answers on this iPhone")
        XCTAssertTrue(answer.label.contains("After 7 tonight"), answer.label)
        XCTAssertTrue(answer.label.contains("On this iPhone · Apple on-device"), answer.label)
        XCTAssertTrue(answer.label.contains("Stayed on this iPhone: 4 messages, 2 chats"), answer.label)
        XCTAssertTrue(answer.label.contains("Not read: 1 Device only chat"), answer.label)
        XCTAssertTrue(answer.label.contains("Shared: After 7 tonight"), answer.label)
        XCTAssertFalse(answer.label.contains("4411"), "What was left out is never shown")
        XCTAssertFalse(result.exists)
        capture(app, "handoff-3-answer")

        XCTAssertTrue(result.waitForExistence(timeout: 15), "4. Claude's result")
        XCTAssertTrue(result.label.contains("Osteria Lucia"), result.label)
        capture(app, "handoff-4-result")

        // You're messaging Claude: the chip is Claude's (no lock), the box says so, and KemoSabe's
        // part is the line under it, with the lock.
        let chip = app.buttons["chooseModel"]
        XCTAssertTrue(chip.label.hasPrefix("Chatting with Claude"), chip.label)
        XCTAssertFalse(chip.label.contains("On-device") || chip.label.contains("private on this device"), chip.label)
        XCTAssertEqual(app.textFields["chatInput"].placeholderValue, "Message Claude…")
        let assist = element(app, "chatAgentAssist")
        XCTAssertTrue(assist.exists)
        XCTAssertTrue(assist.label.contains("KemoSabe assists on this iPhone"), assist.label)

        // The stage never covers a message: once the conversation outgrows the room, the big
        // KemoSabe moves into the avatar, and every beat is on screen together.
        sleep(2)
        let stage = app.otherElements["homeCompanion"]
        for beat in [task, answer, result] {
            if stage.exists { XCTAssertFalse(beat.frame.intersects(stage.frame), "\(beat.identifier) is under the stage") }
            XCTAssertTrue(app.frame.contains(beat.frame), "\(beat.identifier) is on screen")
        }
        XCTAssertGreaterThanOrEqual(task.frame.minY, element(app, "chatTranscript").frame.minY - 1, "Your message isn't scrolled away")
    }
}
