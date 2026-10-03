import XCTest

/// In-app voice mode and the chat's signals. UI tests never use the host microphone, so
/// `--simulate-voice-mode` plays one scripted conversation with a simulated voice level
/// (`VoiceModeSimulation`), and `--reply-fixture=<seconds>` answers messages after that long
/// (`UITestReplyFixture`) so a reply's thinking state can be checked without a model.
///
/// One clear signal per state (the owner's report on build 51, September 25, 2026): at rest, the
/// big Kemo and then the heading, with no orb; thinking, only the transcript's row; listening, only
/// the composer; voice mode, one Kemo that never covers the conversation.
final class VoiceModeUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    /// Every thinking orb drawn on its own (`KemoOrb` labels, without the ellipsis). Orbs inside a
    /// button, such as the microphone's, belong to the button and aren't counted.
    private static let orbLabels = ["Working", "Searching", "Solving", "Listening", "Connecting", "Weaving", "Composing", "Thinking", "Shaping"]
    private func orbs(_ app: XCUIApplication) -> XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "label IN %@", Self.orbLabels))
    }
    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture"] + extra
        app.launch()
        XCTAssertTrue(app.textFields["chatInput"].waitForExistence(timeout: 8))
        return app
    }
    /// The big Kemo on the chat: a new chat starts with it on the stage; otherwise the corner Kemo brings it up.
    private func expandKemo(_ app: XCUIApplication) -> XCUIElement {
        let big = app.otherElements["homeCompanion"]
        if big.waitForExistence(timeout: 3) { settle(); return big }
        let corner = app.buttons["homeCompanion"]
        XCTAssertTrue(corner.waitForExistence(timeout: 5))
        corner.tap()
        XCTAssertTrue(big.waitForExistence(timeout: 5))
        settle()
        return big
    }

    // MARK: Rest

    @MainActor func testRestShowsKemoThenTheHeadingWithNoOrb() {
        for size in ["", "UICTContentSizeCategoryAccessibilityXL"] {
            let app = launch(size.isEmpty ? [] : ["-UIPreferredContentSizeCategoryName", size])
            let kemo = expandKemo(app)
            let heading = app.staticTexts["What’s on your mind?"], subtitle = app.staticTexts["Make room for your day."]
            XCTAssertTrue(heading.waitForExistence(timeout: 5))
            XCTAssertGreaterThanOrEqual(heading.frame.minY, kemo.frame.maxY, "The heading sits under Kemo, not over it (\(size))")
            if subtitle.exists { XCTAssertGreaterThan(subtitle.frame.minY, heading.frame.minY) }
            XCTAssertEqual(orbs(app).count, 0, "No orb under Kemo at rest")
            XCTAssertFalse(app.descendants(matching: .any)["voiceModeKemo"].exists)
            XCTAssertFalse(app.descendants(matching: .any)["headerState"].exists, "The corner shows the name only")
            XCTAssertEqual(app.buttons["microphoneToggle"].value as? String, "Off", "The microphone is a still icon")
            capture("indicators-rest" + (size.isEmpty ? "" : "-xl"), app)
            app.terminate()
        }
    }

    // MARK: Typed thinking

    @MainActor func testTypedThinkingShowsOnlyTheTranscriptRow() {
        let app = launch(["--reply-fixture=20"])
        let kemo = expandKemo(app)
        let input = app.textFields["chatInput"]
        input.tap(); input.typeText("Plan my week"); app.buttons["sendMessage"].tap()
        let row = app.descendants(matching: .any)["streamingReply"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5), "The transcript's thinking row")
        // Exactly one indicator: the row's orb. None under Kemo, none in the corner, no floating Kemo.
        XCTAssertEqual(orbs(app).count, 1)
        let orb = orbs(app).firstMatch
        XCTAssertGreaterThanOrEqual(orb.frame.minY, kemo.frame.maxY, "The orb is in the transcript, not under Kemo")
        XCTAssertFalse(app.descendants(matching: .any)["headerState"].exists, "No status line in the corner on Chat")
        XCTAssertFalse(app.descendants(matching: .any)["voiceModeKemo"].exists, "A typed message never starts voice mode")
        XCTAssertNotEqual(app.buttons["microphoneToggle"].value as? String, "Listening", "The microphone isn't a second indicator")
        XCTAssertEqual(app.buttons["sendMessage"].label, "Stop response")
        capture("indicators-typed-thinking", app)
        // Away from Chat, the corner's status line is the one place that says Kemo is working.
        app.buttons["tab-Day"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["headerState"].firstMatch.waitForExistence(timeout: 3))
        capture("indicators-thinking-other-tab", app)
        app.buttons["tab-Chat"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["headerState"].exists)
        // The reply arrives and every indicator goes.
        let reply = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "KemoSabe: ")).firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 30))
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: row)], timeout: 5)
        XCTAssertEqual(orbs(app).count, 0)
    }

    // MARK: Listening

    @MainActor func testListeningShowsOnlyInTheComposer() {
        let app = launch(["--simulate-voice-mode", "--voice-level=0.8"])
        let microphone = app.buttons["microphoneToggle"]
        // The simulation listens quietly for a moment before any words: the mic is on, nothing is said yet.
        wait(for: [expectation(for: NSPredicate(format: "value == %@", "Listening"), evaluatedWith: microphone)], timeout: 8)
        XCTAssertFalse(app.descendants(matching: .any)["voiceModeKemo"].exists, "Turning the microphone on isn't talking")
        capture("indicators-listening", app)
        XCTAssertEqual(app.textFields["chatInput"].placeholderValue, "Listening…")
        XCTAssertFalse(app.descendants(matching: .any)["headerState"].exists, "No Listening in the header while the composer says it")
        XCTAssertEqual(orbs(app).count, 0, "No orb under Kemo or in the header")
    }

    // MARK: Voice mode

    /// With the big Kemo hidden, voice mode shows Kemo in a band that pushes the chat down; it never
    /// covers a message.
    @MainActor func testVoiceModeRisesWithTheVoiceAndSettlesBack() {
        let app = launch(["--simulate-voice-mode", "--voice-level=0.8", "--reply-fixture=1.2"])
        let input = app.textFields["chatInput"]
        let kemo = app.descendants(matching: .any)["voiceModeKemo"]
        // A new chat starts with the big Kemo on the stage; the corner Kemo hides it.
        let corner = app.buttons["compactCompanion"]
        if corner.waitForExistence(timeout: 3) { corner.tap() }
        XCTAssertTrue(app.buttons["homeCompanion"].waitForExistence(timeout: 3), "The big Kemo is hidden")

        // Entering: Kemo appears listening, at the top of the chat, moving with the voice level.
        XCTAssertTrue(kemo.waitForExistence(timeout: 15), "Voice mode appears while you talk")
        // Your words still fill the message box.
        wait(for: [expectation(for: NSPredicate(format: "value CONTAINS %@", "cook"), evaluatedWith: input)], timeout: 8)
        capture("voice-mode-listening", app)
        XCTAssertTrue(kemo.label.contains("Listening"), kemo.label)
        XCTAssertLessThan(kemo.frame.midY, app.frame.height * 0.35, "Kemo is at the top of the chat")
        XCTAssertLessThan(kemo.frame.maxY, input.frame.minY, "It never covers the message box")
        // Kemo's frame is its drawn artwork, which moves with the voice; the transcript's frame is the layout.
        let header = app.buttons["settingsGear"].frame.maxY, transcript = app.scrollViews["chatTranscript"]
        XCTAssertGreaterThanOrEqual(transcript.frame.minY - header, 100, "A band above the conversation pushes it down")
        XCTAssertGreaterThan(kemo.frame.midY, header, "Kemo sits under the header, not over it")
        XCTAssertLessThan(kemo.frame.midY, transcript.frame.minY, "Kemo sits in the band, above the conversation")
        assertInBand(kemo, under: header, above: transcript)
        XCTAssertFalse(app.otherElements["homeCompanion"].exists, "One Kemo on the chat")
        let level = NSPredicate(format: "value MATCHES %@", "Level ([3-9][0-9]|100) percent")
        wait(for: [expectation(for: level, evaluatedWith: kemo)], timeout: 5)
        let heading = app.staticTexts["What’s on your mind?"]
        if heading.exists { XCTAssertGreaterThanOrEqual(heading.frame.minY, kemo.frame.maxY, "The band pushes the chat down") }
        XCTAssertEqual(orbs(app).count, 0, "No orb under Kemo; the composer shows listening")
        XCTAssertFalse(app.descendants(matching: .any)["headerState"].exists)

        // Thinking: the message is sent, and Kemo stays clear of it. The transcript's row is the one indicator.
        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "Thinking"), evaluatedWith: kemo)], timeout: 8)
        let bubble = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "You: ")).firstMatch
        XCTAssertTrue(bubble.waitForExistence(timeout: 3))
        assertClear(kemo, of: bubble, below: transcript)
        assertInBand(kemo, under: header, above: transcript)
        XCTAssertLessThanOrEqual(orbs(app).count, 1, "At most the transcript's thinking row")
        XCTAssertFalse(app.descendants(matching: .any)["headerState"].exists)
        capture("voice-mode-thinking", app)

        wait(for: [expectation(for: NSPredicate(format: "label CONTAINS %@", "Speaking"), evaluatedWith: kemo)], timeout: 8)
        assertClear(kemo, of: bubble, below: transcript)
        assertInBand(kemo, under: header, above: transcript)
        XCTAssertEqual(orbs(app).count, 0)
        capture("voice-mode-speaking", app)

        // Leaving: quiet again, Kemo settles back and the chat is as it was, with no bar under it.
        wait(for: [expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: kemo)], timeout: 12)
        XCTAssertTrue(input.exists)
        XCTAssertTrue(bubble.exists)
    }

    /// With the big Kemo on screen, voice mode animates that same Kemo in place: no second one.
    @MainActor func testVoiceModeAnimatesTheBigKemoInPlace() {
        // A longer quiet start leaves time to expand Kemo and measure it at rest.
        let app = launch(["--simulate-voice-mode", "--voice-level=0.8", "--voice-quiet=10"])
        let big = expandKemo(app)
        let resting = big.frame, transcript = app.scrollViews["chatTranscript"], restingTop = transcript.frame.minY
        let kemo = app.descendants(matching: .any)["voiceModeKemo"]
        XCTAssertTrue(kemo.waitForExistence(timeout: 25)); settle()
        XCTAssertFalse(app.otherElements["homeCompanion"].exists, "The big Kemo plays voice mode itself")
        // The same slot: the conversation doesn't move, and Kemo (its drawn frame moves with the voice) stays in place.
        XCTAssertEqual(transcript.frame.minY, restingTop, accuracy: 1, "Nothing is pushed or covered")
        XCTAssertEqual(kemo.frame.midY, resting.midY, accuracy: 16, "Same place as the big Kemo")
        XCTAssertEqual(kemo.frame.height, resting.height, accuracy: 0.15 * resting.height, "Same size as the big Kemo")
        XCTAssertLessThanOrEqual(kemo.frame.maxY, restingTop + 8, "It stays above the conversation (its soft ground shadow may reach the edge)")
        XCTAssertEqual(orbs(app).count, 0)
        capture("voice-mode-big-kemo", app)
        // Settles back into the ordinary big Kemo.
        XCTAssertTrue(app.otherElements["homeCompanion"].waitForExistence(timeout: 30))
    }

    /// Kemo's frame is its drawn artwork (transparent edges included, moving with the voice), so it
    /// may touch the band's edge by a point or two; the message must sit in the transcript, below Kemo.
    private func assertClear(_ kemo: XCUIElement, of message: XCUIElement, below transcript: XCUIElement,
                             file: StaticString = #filePath, line: UInt = #line) {
        let overlap = kemo.frame.intersection(message.frame)
        XCTAssertTrue(overlap.isNull || overlap.height <= 3, "Voice mode never covers the first message (\(kemo.frame) vs \(message.frame))", file: file, line: line)
        XCTAssertLessThan(kemo.frame.midY, transcript.frame.minY, file: file, line: line)
        XCTAssertGreaterThan(message.frame.midY, transcript.frame.minY, "The message is in the transcript under the band", file: file, line: line)
    }

    /// The band's height (`VoiceModeKemo.bandHeight`).
    private static let bandHeight: CGFloat = 108
    /// In the band, Kemo's frame is its square and never more, whatever the pose: a turned paw's
    /// artwork plate is clipped to it, so Kemo stays between the header and the conversation.
    private func assertInBand(_ kemo: XCUIElement, under header: CGFloat, above transcript: XCUIElement,
                              file: StaticString = #filePath, line: UInt = #line) {
        let frame = kemo.frame
        XCTAssertLessThanOrEqual(frame.height, Self.bandHeight + 1, "Kemo fits the band (\(frame))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.width, Self.bandHeight + 1, "Kemo is its square (\(frame))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(frame.minY, header, "Kemo stays under the header (\(frame))", file: file, line: line)
        XCTAssertLessThanOrEqual(frame.maxY, transcript.frame.minY + 1, "Kemo stays above the conversation (\(frame) vs \(transcript.frame))", file: file, line: line)
    }

    /// Lets a spring or ease finish before frames are compared.
    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.8)) }

    private func capture(_ name: String, _ app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
}
