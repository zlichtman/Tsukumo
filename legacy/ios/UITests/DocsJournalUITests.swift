import XCTest

/// Docs and Journal in Library (design/DOCS-AND-JOURNAL.md): a page written with `/` and Markdown
/// shortcuts, a sub-page, a journal entry with a mood and a photo, flipping days, and a doc
/// attached in chat. `--docs-sample` fills Docs and Journal for the screenshots.
final class DocsJournalUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    @MainActor private func launch(_ extra: [String] = [], appearance: String = "Dark") -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture", "-app.appearance.mode", appearance] + extra
        app.launch()
        XCTAssertTrue(app.buttons["tab-Library"].waitForExistence(timeout: 10))
        return app
    }
    @MainActor private func openLibrary(_ app: XCUIApplication, _ section: String) {
        app.buttons["tab-Library"].tap()
        let picker = app.segmentedControls["librarySections"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        picker.buttons[section].tap()
    }
    private func element(_ app: XCUIApplication, _ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    /// Lets a new block's field take the keyboard before typing more.
    private func settle() { usleep(600_000) }
    @MainActor private func editingField(_ app: XCUIApplication) -> XCUIElement {
        let field = element(app, "docBlockEditing")
        XCTAssertTrue(field.waitForExistence(timeout: 5), "A block is being edited")
        return field
    }

    @MainActor func testWritePageWithSlashMenuShortcutsAndSubPage() {
        let app = launch()
        openLibrary(app, "Docs")
        app.buttons["newDocPage"].tap()
        let title = element(app, "docTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Groceries")
        // Return in the title goes to the first block.
        app.typeText("\n"); settle()
        _ = editingField(app)

        // "/" opens the block menu; picking To-do turns the block into one.
        app.typeText("/tod")
        let todo = app.buttons["slashItem-todo"]
        XCTAssertTrue(todo.waitForExistence(timeout: 12), "The block menu filters as you type")
        todo.tap(); settle()
        app.typeText("Oat milk"); app.typeText("\n"); settle()
        app.typeText("Bread"); app.typeText("\n"); settle()
        // Return on an empty to-do ends the list.
        app.typeText("\n"); settle()
        // Markdown shortcuts.
        app.typeText("## "); settle()
        app.typeText("Notes"); app.typeText("\n"); settle()
        app.typeText("- "); settle()
        app.typeText("From the **market**"); app.typeText("\n"); settle()
        app.typeText("\n"); settle()
        app.typeText("> "); settle()
        app.typeText("Buy what's in season")
        settle()

        // Leave the text and check what was made.
        app.swipeDown()
        settle()
        XCTAssertTrue(element(app, "docTodo-0").waitForExistence(timeout: 5), "First to-do")
        XCTAssertTrue(element(app, "docTodo-1").exists, "Return continued the list")
        // Return on the empty to-do made text, which "## " made a heading; Return twice left the bullets.
        XCTAssertEqual(element(app, "docBlock-2").value as? String, "heading2")
        XCTAssertEqual(element(app, "docBlock-3").value as? String, "bulleted")
        XCTAssertEqual(element(app, "docBlock-4").value as? String, "quote")
        element(app, "docTodo-0").tap()
        XCTAssertEqual(element(app, "docTodo-0").label, "Done")

        // A sub-page from the block menu opens right away.
        let end = element(app, "docEditorEnd")
        if end.exists { end.tap() } else { element(app, "docBlock-4").tap() }
        settle()
        app.typeText("/sub")
        let sub = app.buttons["slashItem-subPage"]
        XCTAssertTrue(sub.waitForExistence(timeout: 5))
        sub.tap()
        let childTitle = element(app, "docTitle")
        XCTAssertTrue(childTitle.waitForExistence(timeout: 5))
        settle()
        childTitle.tap(); childTitle.typeText("Aisles")
        app.swipeDown()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "docPageLink-Aisles").waitForExistence(timeout: 5), "The parent links its new sub-page")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "docRow-Groceries").waitForExistence(timeout: 5))

        // Search finds text inside pages.
        let search = app.textFields["librarySearch"]
        search.tap(); search.typeText("milk")
        XCTAssertTrue(element(app, "docResult-Groceries").waitForExistence(timeout: 5))
    }

    @MainActor func testJournalEntryWithMoodPhotoTagAndFlippingDays() {
        let app = launch()
        openLibrary(app, "Journal")
        app.buttons["journalToday"].tap()
        let write = app.buttons["journalWrite"]
        XCTAssertTrue(write.waitForExistence(timeout: 5))
        XCTAssertTrue(element(app, "journalDayTitle").label == "Today")
        write.tap(); settle()
        _ = editingField(app)
        app.typeText("Walked to the harbor before work.")
        app.swipeDown(); settle()
        app.buttons["mood-good"].tap()
        XCTAssertTrue(app.buttons["mood-good"].isSelected)
        app.buttons["journalAddPhoto"].tap()
        let sample = app.buttons["Sample photo"].firstMatch
        XCTAssertTrue(sample.waitForExistence(timeout: 5))
        sample.tap()
        XCTAssertTrue(element(app, "journalPhoto").waitForExistence(timeout: 5), "The photo is on the entry")
        let tag = app.textFields["journalTagField"]
        tag.tap(); tag.typeText("harbor\n")
        XCTAssertTrue(element(app, "journalTag-harbor").waitForExistence(timeout: 5))
        capture("docs-journal-entry")

        // Flip to yesterday and back.
        app.swipeDown()
        app.buttons["journalPrevDay"].tap()
        XCTAssertEqual(element(app, "journalDayTitle").label, "Yesterday")
        XCTAssertTrue(app.buttons["journalWrite"].waitForExistence(timeout: 5), "Yesterday has no entry yet")
        app.buttons["journalNextDay"].tap()
        XCTAssertEqual(element(app, "journalDayTitle").label, "Today")
        XCTAssertTrue(app.buttons["mood-good"].isSelected)

        // The timeline shows the entry.
        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(element(app, "journalTodayRow").waitForExistence(timeout: 5))
    }

    @MainActor func testAttachADocInChat() {
        let app = launch(["--reply-fixture=0.3"])
        openLibrary(app, "Docs")
        app.buttons["newDocPage"].tap()
        let title = element(app, "docTitle")
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Groceries")
        app.typeText("\n"); settle()
        app.typeText("Oat milk and bread")
        app.swipeDown()
        app.navigationBars.buttons.element(boundBy: 0).tap()

        app.buttons["tab-Chat"].tap()
        // The + attaches docs and journal entries with any of Apple's models; images need a model that takes them.
        app.buttons["attachImages"].tap()
        XCTAssertTrue(app.buttons["attachDoc"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["attachDoc"].isEnabled)
        XCTAssertFalse(app.buttons["attachLibrary"].isEnabled)
        app.buttons["attachDoc"].tap()
        XCTAssertTrue(app.buttons["attachPick-Groceries"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()

        // "@" offers docs to attach.
        let input = app.textFields["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("@Gro")
        let mention = app.buttons["mentionDoc-Groceries"]
        XCTAssertTrue(mention.waitForExistence(timeout: 5))
        mention.tap()
        XCTAssertTrue(element(app, "attachedDoc-Groceries").waitForExistence(timeout: 5), "The doc is a chip on the message")
        input.typeText("What should I buy?")
        capture("docs-chat-attached")
        app.buttons["sendMessage"].tap()
        let sent = app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "attached Groceries")).firstMatch
        XCTAssertTrue(sent.waitForExistence(timeout: 8), "The sent message shows what was attached")
        XCTAssertFalse(element(app, "attachedDoc-Groceries").exists, "Only that message takes it")
    }

    /// Screenshots for design/docs-journal (light and dark).
    @MainActor func testScreenshotsLightAndDark() {
        for appearance in ["Light", "Dark"] {
            let app = launch(["--docs-sample"], appearance: appearance)
            openLibrary(app, "Docs")
            XCTAssertTrue(element(app, "docRow-Weekend plans").waitForExistence(timeout: 5))
            capture("iphone-docs-\(appearance.lowercased())")
            element(app, "docRow-Weekend plans").tap()
            XCTAssertTrue(element(app, "docTitle").waitForExistence(timeout: 5))
            settle()
            capture("iphone-page-\(appearance.lowercased())")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            app.segmentedControls["librarySections"].buttons["Journal"].tap()
            XCTAssertTrue(element(app, "journalTodayRow").waitForExistence(timeout: 5))
            capture("iphone-journal-\(appearance.lowercased())")
            app.buttons["journalToday"].tap()
            XCTAssertTrue(element(app, "journalDayTitle").waitForExistence(timeout: 5))
            settle()
            capture("iphone-journal-day-\(appearance.lowercased())")
            app.terminate()
        }
    }

    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        // DOCS_SNAPSHOT_DIR (TEST_RUNNER_DOCS_SNAPSHOT_DIR for xcodebuild) also saves them as files.
        if let folder = ProcessInfo.processInfo.environment["DOCS_SNAPSHOT_DIR"], !folder.isEmpty {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            try? screenshot.pngRepresentation.write(to: URL(fileURLWithPath: folder).appendingPathComponent(name + ".png"))
        }
    }
}
