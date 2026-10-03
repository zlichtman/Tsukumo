import XCTest

final class KemoSabeUITests: XCTestCase {
    @MainActor func testBuild29NavigationComposerAndThemeGallery() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["attachImages"].waitForExistence(timeout: 8))
        // Since docs (September 26) the + also attaches docs and journal entries; its image choices
        // wait for a model that takes images.
        app.buttons["attachImages"].tap()
        XCTAssertTrue(app.buttons["attachDoc"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["attachLibrary"].isEnabled, "Apple's local model is text-only; image choices are disabled, not a prompt")
        app.buttons["attachDoc"].tap(); app.buttons["Cancel"].tap()
        XCTAssertFalse(app.staticTexts["Add an image"].exists)
        XCTAssertTrue(app.buttons["chooseModel"].exists); XCTAssertTrue(app.buttons["newConversation"].exists)
        XCTAssertTrue(app.buttons["openConversations"].exists)
        capture("b32-grouped-composer")
        app.buttons["tab-Library"].tap()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.segmentedControls["librarySections"].buttons["History"].exists)
        capture("b29-library")
        app.buttons["addMemory"].tap()
        XCTAssertTrue(app.textViews["memoryText"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["tab-Profile"].tap()
        // Since build 36 the name is edited from Edit profile, not inline.
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))
        capture("b29-profile")
        app.buttons["profilePeople"].tap()
        XCTAssertTrue(app.textFields["peopleSearch"].waitForExistence(timeout: 5))
        capture("b29-friends")
        app.swipeDown(); app.swipeDown()
        app.terminate(); app.launch()
        app.buttons["settingsGear"].tap(); app.buttons["openAppearance"].tap()
        app.segmentedControls["appColorMode"].buttons["Dark"].tap()
        XCTAssertFalse(app.buttons["appLightTheme"].exists)
        app.buttons["appDarkTheme"].tap()
        // Themes are alphabetical, so Slate is further down the grid.
        let slate = reveal(app.buttons["mobileTheme-Slate"], in: app)
        capture("b29-themes")
        slate.tap()
        XCTAssertTrue(app.segmentedControls["appColorMode"].waitForExistence(timeout: 5))
        app.segmentedControls["appColorMode"].buttons["Light"].tap()
        XCTAssertFalse(app.buttons["appDarkTheme"].exists)
        XCTAssertTrue(app.buttons["appLightTheme"].exists)
    }

    @MainActor func testOrganizedSettingsIndependentAppearanceAndLibrary() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch(); XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 8))
        app.buttons["settingsGear"].tap()
        XCTAssertTrue(app.buttons["openCharacter"].waitForExistence(timeout: 5))
        reveal(app.buttons["openModel"], in: app)
        XCTAssertEqual(app.buttons.matching(identifier: "openModel").count, 1, "Voice is on Companion, not its own row")
        capture("b28-settings")
        app.swipeDown(); app.swipeDown()
        app.buttons["openCharacter"].tap()
        let palette = reveal(app.buttons["openThemeDrawer"], in: app)
        XCTAssertTrue(palette.waitForExistence(timeout: 5)); let original = palette.value as? String
        XCTAssertFalse(app.buttons["openModel"].exists)
        capture("b28-character")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["openAppearance"].tap()
        XCTAssertTrue(app.segmentedControls["appColorMode"].waitForExistence(timeout: 5))
        app.segmentedControls["appColorMode"].buttons["Light"].tap()
        XCTAssertTrue(app.buttons["appLightTheme"].exists)
        capture("b28-app-appearance-light")
        app.segmentedControls["appColorMode"].buttons["Dark"].tap()
        capture("b28-app-appearance-dark")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["openCharacter"].tap()
        XCTAssertEqual(reveal(app.buttons["openThemeDrawer"], in: app).value as? String, original)
        app.navigationBars.buttons.element(boundBy: 0).tap(); app.buttons["closeSettings"].tap()
        app.buttons["tab-Library"].tap()
        XCTAssertTrue(app.textFields["librarySearch"].waitForExistence(timeout: 5))
        app.buttons["addMemory"].tap()
        let input = app.textViews["memoryText"]; XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.tap(); input.typeText("I prefer morning walks")
        app.buttons["saveMemory"].tap()
        XCTAssertTrue(app.staticTexts["I prefer morning walks"].waitForExistence(timeout: 5))
        capture("b28-library")
        let search = app.textFields["librarySearch"]; search.tap(); search.typeText("unmatched")
        XCTAssertTrue(app.staticTexts["No matching memories"].waitForExistence(timeout: 5))
        app.buttons["Clear search"].tap(); search.typeText("\n")
        app.buttons["tab-Profile"].tap(); app.buttons["profilePeople"].tap()
        XCTAssertTrue(app.textFields["peopleSearch"].waitForExistence(timeout: 5))
        capture("b28-people-search")
    }

    @MainActor func testTypedQuestionReceivesModelReply() throws {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch()
        let input = app.textFields["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        let replies = app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "KemoSabe: "))
        let before = replies.count
        let question = "Suggest a name for a houseplant."
        input.tap(); input.typeText(question); app.buttons["sendMessage"].tap()
        let asked = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "You: " + question)).firstMatch
        guard asked.waitForExistence(timeout: 5) else { throw XCTSkip("Apple's on-device model is unavailable on this device.") }
        // Typing turns voice off; that gate must not cancel the reply it just started.
        let answered = expectation(for: NSPredicate(format: "count > %d", before), evaluatedWith: replies)
        wait(for: [answered], timeout: 90)
        capture("b31-typed-reply")
    }
    @MainActor func testConversationSidebarKeepsAndDeletesConversations() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch()
        let input = app.textFields["chatInput"]; XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["newConversation"].isEnabled)
        input.tap(); input.typeText("Do your animation"); app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["newConversation"].isEnabled)
        app.buttons["newConversation"].tap()
        XCTAssertTrue(app.staticTexts["What’s on your mind?"].waitForExistence(timeout: 5))
        app.buttons["openConversations"].tap()
        let saved = app.buttons.matching(identifier: "savedConversation").firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5))
        capture("b32-conversation-sidebar")
        saved.swipeLeft(); app.buttons["Delete"].tap()
        app.buttons["Delete conversation"].tap()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 5))
        app.buttons["closeConversations"].tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
    }
    @MainActor func testComposerOpensConversationsAndContinuesASavedOne() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch()
        let input = app.textFields["chatInput"]; XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap(); input.typeText("Do your animation"); app.buttons["sendMessage"].tap()
        app.buttons["newConversation"].tap()
        XCTAssertTrue(app.staticTexts["What’s on your mind?"].waitForExistence(timeout: 5))
        // Conversations open from the composer, between the model and new-conversation buttons.
        let open = app.buttons["openConversations"], model = app.buttons["chooseModel"], new = app.buttons["newConversation"]
        XCTAssertTrue(open.frame.minX > model.frame.maxX && open.frame.maxX < new.frame.minX)
        open.tap()
        let saved = app.buttons.matching(identifier: "savedConversation").firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 5)); saved.tap()
        let resume = app.buttons["continueConversation"]; XCTAssertTrue(resume.waitForExistence(timeout: 5))
        capture("b35-continue-conversation")
        resume.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Do your animation"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["What’s on your mind?"].exists)
        capture("b35-composer")
        // Projects: make one from the drawer and move the saved chat into it.
        open.tap()
        let newProject = app.buttons["newProject"]; XCTAssertTrue(newProject.waitForExistence(timeout: 5))
        newProject.tap()
        let projectName = app.alerts.textFields.firstMatch; XCTAssertTrue(projectName.waitForExistence(timeout: 3))
        projectName.typeText("Tahoe trip"); app.alerts.buttons["Create"].firstMatch.tap()
        let project = app.buttons["project-Tahoe trip"]; XCTAssertTrue(project.waitForExistence(timeout: 3))
        capture("b40-chats-drawer")
        app.buttons["currentConversation"].press(forDuration: 1.0)
        app.buttons["Move to project"].tap(); app.buttons["Tahoe trip"].tap()
        project.tap()
        XCTAssertTrue(app.buttons["currentConversation"].waitForExistence(timeout: 3), "The current chat is filed in the project")
        capture("b40-project")
        app.buttons["closeConversations"].firstMatch.tap()
        XCTAssertTrue(input.waitForExistence(timeout: 5))
    }
    /// The profile as blocks (design/PROFILE-REDESIGN.md): followers, following, and Kemo over blocks
    /// you arrange. Edit profile turns the page into its editable layout in place: header fields,
    /// links, a bar per block to restyle, move, and hide it, and hidden blocks keep their contents.
    @MainActor func testProfileBlocksStatsAndEditing() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch(); XCTAssertTrue(app.buttons["tab-Profile"].waitForExistence(timeout: 8))
        app.buttons["tab-Profile"].tap()
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profilePeople"].exists, "People stays one tap away")
        XCTAssertFalse(app.buttons["profileFeaturedSlot-0"].exists, "No featured slots")
        XCTAssertFalse(app.buttons["profileSection-posts"].exists, "Blocks, not tabs")
        XCTAssertTrue(app.descendants(matching: .any)["profilePostsEmpty"].exists, "Empty posts show a quiet grid")
        XCTAssertTrue(app.descendants(matching: .any)["profileBlock-photos"].exists)
        // No followers or following: "Shared with" counts the people who accepted, and opens Sharing.
        XCTAssertFalse(app.buttons["profileFollowers"].exists)
        XCTAssertTrue(app.buttons["profileSharedWith"].label.contains("0"))
        app.buttons["profileSharedWith"].tap()
        XCTAssertTrue(app.buttons["sharingClose"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "once accounts")).firstMatch.exists)
        app.buttons["sharingClose"].tap()
        XCTAssertTrue(app.buttons["profileKemo"].waitForExistence(timeout: 5))
        app.buttons["profileKemo"].tap()
        XCTAssertTrue(app.staticTexts["kemoCardName"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["kemoCardNoWatch"].exists || app.descendants(matching: .any)["kemoCardLevel"].exists)
        capture("b54-kemo-card")
        app.buttons["profileSheetClose"].tap()

        // Editing happens on the page: the header becomes fields, and there's no Edit profile sheet.
        app.buttons["profileEdit"].tap()
        let name = app.textFields["profileName"]; XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profileDone"].exists)
        XCTAssertFalse(app.navigationBars["Edit profile"].exists)
        XCTAssertTrue(app.buttons["profileAccent-Ocean"].exists)
        name.tap(); name.typeText("Kemo Tester")
        app.textFields["profileHandleField"].tap(); app.textFields["profileHandleField"].typeText("Kemo.Tester")
        app.textFields["profileHeadlineField"].tap(); app.textFields["profileHeadlineField"].typeText("iOS engineer")
        app.buttons["profileAccent-Ocean"].tap()
        capture("b54-profile-editing")
        let instagram = reveal(app.textFields["profileLinkField-instagram"], in: app)
        instagram.tap(); instagram.typeText("kemotester")
        toTop(app)
        app.buttons["profileDone"].tap()
        XCTAssertTrue(app.staticTexts["Kemo Tester"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["@kemo.tester"].exists)
        XCTAssertTrue(app.staticTexts["iOS engineer"].exists)
        capture("b54-profile")
        XCTAssertTrue(reveal(app.links["profileLink-instagram"], in: app).exists)

        // Work, empty: its title and buttons.
        toTop(app)
        reveal(app.buttons["profileAddWork"], in: app).tap()
        let title = app.textFields["workTitle"]; XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("iOS Engineer")
        app.textFields["workCompany"].tap(); app.textFields["workCompany"].typeText("Northwind Labs")
        app.buttons["workSave"].tap()
        XCTAssertTrue(app.buttons["profileWorkEntry"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Northwind Labs"].exists)

        let blog = reveal(app.textFields["profileBlogAddress"], in: app)
        blog.tap(); blog.typeText("example.com")
        XCTAssertTrue(app.staticTexts["profileBlogDisclosure"].waitForExistence(timeout: 5), "The feed fetch names what it contacts")
        XCTAssertTrue(app.staticTexts["Reads example.com"].exists)

        // Music picks stay possible by hand.
        toTop(app)
        reveal(app.buttons["profileAddSong"], in: app).tap()
        app.buttons["Song on repeat"].tap()
        let song = app.textFields["songTitle"]; XCTAssertTrue(song.waitForExistence(timeout: 5))
        song.tap(); song.typeText("Kemo Theme"); app.textFields["songArtist"].tap(); app.textFields["songArtist"].typeText("KemoSabe")
        app.buttons["songAdd"].tap()
        XCTAssertTrue(app.staticTexts["Kemo Theme"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["profileConnectAppleMusic"].exists)
        XCTAssertFalse(app.buttons["profileConnectSpotify"].isEnabled, "Spotify is Complete later")

        // Hiding a block takes it off the page and keeps what's in it; editing shows it dimmed.
        toTop(app)
        app.buttons["profileEdit"].tap()
        reveal(app.buttons["profileBlockHide-work"], in: app).tap()
        toTop(app)
        app.buttons["profileDone"].tap()
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["profileBlock-work"].exists)
        XCTAssertFalse(app.buttons["profileWorkEntry"].exists)
        app.buttons["profileEdit"].tap()
        reveal(app.buttons["profileBlockHide-work"], in: app).tap()
        // Move Work above Music, and show Photos as a feed.
        app.buttons["profileBlockMenu-work"].tap()
        app.buttons["Move up"].tap()
        toTop(app)
        reveal(app.buttons["profileBlockStyle-photos"], in: app).tap()
        app.buttons["Feed"].tap()
        XCTAssertEqual(app.buttons["profileBlockStyle-photos"].value as? String, "Feed")
        toTop(app)
        app.buttons["profileDone"].tap()
        let work = reveal(app.descendants(matching: .any)["profileBlock-work"], in: app)
        let music = app.descendants(matching: .any)["profileBlock-music"]
        XCTAssertTrue(app.buttons["profileWorkEntry"].exists, "A hidden block keeps its entries")
        XCTAssertLessThan(work.frame.minY, music.frame.minY, "Work moved above Music")
    }
    /// The owner's "Fix profile": an empty profile is labels, content, and buttons only (a quiet
    /// grid for posts, no how-to paragraphs, no "once accounts arrive" notes), and Add offers the
    /// system camera and the photo library (the film camera and its filters were removed).
    @MainActor func testCleanProfileAndCamera() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch(); XCTAssertTrue(app.buttons["tab-Profile"].waitForExistence(timeout: 20))
        app.buttons["tab-Profile"].tap()
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["profilePostsEmpty"].exists)
        let removed = ["Share your first photo or video", "Old photos land on the day", "Instagram posts can come in", "once accounts arrive",
                       "Your profile is on this iPhone", "as on LinkedIn. Import", "opens its public page", "Add your blog or its RSS",
                       "Things you're into", "A few facts you choose", "Connecting a music service", "contacts your blog only"]
        func assertNoFiller(_ where_: String) {
            for text in removed {
                XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", text)).firstMatch.exists, "\(where_) still says “\(text)”")
            }
        }
        assertNoFiller("Posts")
        capture("b52-profile-empty")
        // Each empty block keeps its title and buttons, down the one page.
        let expected: [(String, XCUIElement)] = [
            ("music", app.buttons["profileConnectAppleMusic"]), ("work", app.buttons["profileImportLinkedIn"]),
            ("work", app.buttons["profileAddWork"]), ("writing", app.textFields["profileBlogAddress"]),
            ("personal", app.buttons["profileAddInterest"]), ("links", app.buttons["profileAddHandles"]),
        ]
        for (block, element) in expected {
            XCTAssertTrue(reveal(element, in: app).exists, "The empty \(block) block has its buttons")
            assertNoFiller(block)
        }
        capture("b54-profile-empty-blocks")
        toTop(app)

        // Add offers the camera and the library.
        app.buttons["profileAddMedia"].tap()
        let camera = app.buttons["Camera"]; XCTAssertTrue(camera.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Photo Library"].exists)
        XCTAssertTrue(app.buttons["Import from LinkedIn"].exists && app.buttons["Import from Instagram"].exists, "Add holds the one Import")
        capture("b52-profile-add")
        camera.tap()
        // The system camera (or, with no camera, a sheet that says so). Either way it closes back.
        // The system camera draws its own controls, which the test can't query by name, so its close
        // button (✕, bottom left) is tapped by position.
        let unavailable = app.staticTexts["cameraUnavailable"]
        sleep(3)
        XCTAssertFalse(app.buttons["filmShutter"].exists, "The film camera and its looks are gone")
        XCTAssertFalse(app.buttons["profileEdit"].isHittable, "The camera covers the profile")
        capture("b57-camera")
        if unavailable.exists { app.buttons["cameraClose"].tap() }
        else { app.coordinate(withNormalizedOffset: CGVector(dx: 0.145, dy: 0.933)).tap() }
        XCTAssertTrue(app.buttons["profileEdit"].waitForExistence(timeout: 5))
    }
    @MainActor func testLightModeCharacterEdges() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch(); XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 8))
        app.buttons["settingsGear"].tap(); app.buttons["openAppearance"].tap()
        XCTAssertTrue(app.segmentedControls["appColorMode"].waitForExistence(timeout: 5))
        app.segmentedControls["appColorMode"].buttons["Light"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        app.buttons["closeSettings"].tap()
        XCTAssertTrue(app.textFields["chatInput"].waitForExistence(timeout: 5))
        capture("b32-light-header")
        // A new chat starts with the big Kemo on the stage; the corner brings it up otherwise.
        if app.buttons["homeCompanion"].exists { app.buttons["homeCompanion"].tap() }
        XCTAssertTrue(app.otherElements["homeCompanion"].waitForExistence(timeout: 5))
        capture("b32-light-expanded")
    }
    @MainActor func testChatComposerTabsAndModelSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch()
        let input = app.textFields["chatInput"]
        XCTAssertTrue(input.waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["tab-Chat"].waitForExistence(timeout: 5))
        // Home, Library, Chat in the middle, Day, then your profile picture.
        let order = ["tab-Home", "tab-Library", "tab-Chat", "tab-Day", "tab-Profile"].map { app.buttons[$0].frame.midX }
        XCTAssertEqual(order, order.sorted(), "Tabs are out of order")
        XCTAssertEqual(app.buttons["microphoneToggle"].value as? String, "Off")
        capture("b27-iphone-chat")
        input.tap(); input.typeText("Do your animation")
        app.buttons["sendMessage"].tap()
        XCTAssertEqual(app.otherElements["homeCompanion"].label, "KemoSabe, dance")
        capture("b27-iphone-animation-chat")
        app.buttons["tab-Day"].tap()
        XCTAssertTrue(app.staticTexts["Nothing needs your attention"].waitForExistence(timeout: 5))
        app.buttons["tab-Library"].tap()
        XCTAssertTrue(app.buttons["addMemory"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Memory connections"].exists)
        capture("b27-iphone-library")
        app.buttons["addMemory"].tap()
        XCTAssertTrue(app.textViews["memoryText"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["tab-Home"].tap()
        XCTAssertTrue(app.buttons["idea-arrow.triangle.branch"].waitForExistence(timeout: 5))
        capture("b39-iphone-home")
        app.buttons["idea-arrow.triangle.branch"].tap()
        XCTAssertEqual(input.value as? String, "Help me think through a decision. Ask one useful question at a time.")
        app.buttons["tab-Chat"].tap()
        app.buttons["chooseModel"].tap()
        // The model chip's picker opens on its model list, or on the effort page when the model takes one.
        if app.buttons["effortModel"].waitForExistence(timeout: 2) { app.buttons["effortModel"].tap() }
        XCTAssertTrue(app.buttons["addModelConnection"].waitForExistence(timeout: 5))
        capture("b27-iphone-models")
        app.buttons["addModelConnection"].tap()
        // Claude is first: paste a key, then choose from its models. Nothing is contacted until asked.
        XCTAssertTrue(app.secureTextFields["providerKey"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["loadModels"].exists)
        XCTAssertFalse(app.textFields["providerEndpoint"].exists, "Presets don't ask for an endpoint")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        capture("b27-iphone-add-model")
    }

    @MainActor func testDeleteConversationAndSharedAnimationGallery() {
        let app = XCUIApplication(); app.launchArguments = ["--developer", "--ui-testing", "--isolated-fixture"]
        app.launch()
        let input = app.textFields["chatInput"]; XCTAssertTrue(input.waitForExistence(timeout: 8))
        input.tap(); input.typeText("Do your animation"); app.buttons["sendMessage"].tap()
        app.buttons["openConversations"].tap()
        let current = app.buttons["currentConversation"]; XCTAssertTrue(current.waitForExistence(timeout: 5))
        current.swipeLeft(); app.buttons["Delete"].tap()
        app.buttons["Delete conversation"].tap()
        XCTAssertTrue(app.staticTexts["No conversations yet"].waitForExistence(timeout: 5))
        app.buttons["closeConversations"].tap()
        XCTAssertTrue(app.staticTexts["What’s on your mind?"].waitForExistence(timeout: 5))
        openAnimationGallery(app)
        XCTAssertTrue(app.buttons["motionPause"].waitForExistence(timeout: 5))
        capture("b27-current-animation-gallery")
        XCTAssertFalse(app.buttons["Muse previews · 64"].exists, "Muse clips were removed on September 24")
    }
    @MainActor func testPeopleManualProfileAndNativeNavigation() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch(); XCTAssertTrue(app.buttons["tab-Profile"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.tabBars.count, 1)
        app.buttons["tab-Profile"].tap(); app.buttons["profilePeople"].tap(); app.buttons["addPerson"].tap(); app.collectionViews.buttons["Add person"].tap()
        let value = app.textFields["Value"].firstMatch; XCTAssertTrue(value.waitForExistence(timeout: 5))
        value.tap(); value.typeText("Gallery Test Person"); app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons.containing(.staticText, identifier: "Gallery Test Person").firstMatch.waitForExistence(timeout: 5))
        app.buttons.containing(.staticText, identifier: "Gallery Test Person").firstMatch.tap()
        XCTAssertTrue(app.buttons["Profile options"].waitForExistence(timeout: 5))
        capture("b27-people-profile")
        app.buttons["Add context or source"].tap()
        XCTAssertTrue(app.textFields["Value"].firstMatch.waitForExistence(timeout: 5))
        app.textFields["Value"].firstMatch.tap(); app.textFields["Value"].firstMatch.typeText("Met at a design meetup")
        app.buttons["Save"].tap()
        XCTAssertTrue(app.staticTexts["Met at a design meetup"].waitForExistence(timeout: 5))
        app.buttons["Profile options"].tap(); app.buttons["Delete profile"].tap(); app.buttons["Delete profile"].tap()
        XCTAssertTrue(app.buttons["addPerson"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Gallery Test Person"].exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }

    @MainActor func testSpokenAnimationCommandPlaysOnHomeWithoutModel() {
        let app = XCUIApplication()
        for (request, performance) in [("Kemosabe can you please do your animation", "dance"), ("Show me your writing animation", "writing")] {
            app.launchArguments = ["--ui-testing", "--isolated-fixture", "--voice-command=" + request]
            app.launch()
            let companion = app.otherElements["homeCompanion"]
            XCTAssertTrue(companion.waitForExistence(timeout: 8))
            XCTAssertEqual(companion.label, "KemoSabe, " + performance)
            // The reply is in the conversation; voice no longer has a caption bar above the composer.
            XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Here goes.")).firstMatch.waitForExistence(timeout: 5))
            XCTAssertEqual(app.buttons["microphoneToggle"].value as? String, "Off")
            capture("b23-voice-" + performance)
            app.terminate()
        }
    }
    @MainActor func testRoutinePermissionsStartWithoutDestinationsOrGrants() {
        let app = XCUIApplication()
        // Routine permissions live in Settings → Personalization.
        app.launchArguments = ["--ui-testing", "--isolated-fixture"]
        app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 8)); app.buttons["settingsGear"].tap()
        reveal(app.buttons["openPersonalization"], in: app).tap()
        XCTAssertTrue(app.navigationBars["Personalization"].waitForExistence(timeout: 5))
        // No destination yet, so no automatic changes: Connect goes to Connections.
        XCTAssertFalse(app.switches["automaticChanges-calendar"].exists)
        XCTAssertFalse(app.switches["automaticChanges-reminders"].exists)
        XCTAssertTrue(app.buttons["connectCalendar"].exists || app.buttons["calendarDestination"].exists)
        capture("b23-private-routine-permissions")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
    @MainActor func testVoiceQualitySetupDoesNotRequestMicrophoneOrDownloadAutomatically() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["settingsGear"].tap()
        openVoicePage(app)
        XCTAssertTrue(app.buttons["play-voice-apple-best"].waitForExistence(timeout: 5))
        reveal(app.sliders["speechRate"], in: app)
        capture("b20-voice-quality")
        reveal(app.descendants(matching: .any)["voiceListeningModel"].firstMatch, in: app)
        XCTAssertFalse(app.otherElements["recognitionDownloadProgress"].exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        capture("b20-recognition-setup")
        // No preview, download, or microphone tap: this is presentation-only.
    }
    /// Companion → Voice: one voice choice (which voice it sounds like), one microphone switch, the
    /// voice models chosen for the device with nothing to pick, and the long notes and licenses on
    /// About voices. Playing a voice uses the UI-testing stub, so nothing is heard.
    @MainActor func testVoicePageHasOneChoiceAndAboutVoices() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        app.buttons["settingsGear"].tap()
        openVoicePage(app)
        // The Simulator has no GPU for MLX: Apple's best voice speaks, and it's the one row.
        let best = app.buttons["voice-apple-best"]
        XCTAssertTrue(best.waitForExistence(timeout: 5))
        XCTAssertTrue(best.isSelected, "Apple's best available voice speaks here")
        for old in ["replyVoice", "kokoroVoice", "speechVoicePicker", "transcriptionModel", "kokoro-download", "whisper-download", "moreAppleVoices", "setUpOwnVoice"] {
            XCTAssertFalse(app.buttons[old].exists, "\(old) was a model choice or a second picker")
        }
        capture("voice-chooser")
        let play = app.buttons["play-voice-apple-best"]
        play.tap()
        XCTAssertTrue(expectValue(play, "Playing"))
        play.tap()
        XCTAssertTrue(expectValue(play, "Playing", matches: false))
        if app.buttons["betterAppleVoices"].exists {
            reveal(app.buttons["betterAppleVoices"], in: app).tap()
            XCTAssertTrue(app.staticTexts["betterAppleVoicesPath"].waitForExistence(timeout: 3) || app.otherElements["betterAppleVoicesPath"].exists)
            app.buttons["closeBetterAppleVoices"].tap()
        }
        // One microphone, in Listening.
        reveal(app.switches["enableVoice"], in: app)
        XCTAssertEqual(app.switches.matching(identifier: "enableVoice").count, 1)
        reveal(app.switches["voiceInterruptions"], in: app)
        XCTAssertTrue(app.staticTexts["Say “KemoSabe” or “hold on”"].exists || (app.switches["voiceInterruptions"].label.contains("hold on")))
        // The models: always the best this device runs, nothing to choose, nothing to download here.
        reveal(app.descendants(matching: .any)["voiceListeningModel"].firstMatch, in: app)
        XCTAssertTrue(app.staticTexts["Apple · on this device"].exists || app.descendants(matching: .any)["voiceListeningModel"].firstMatch.label.contains("Apple · on this device"))
        XCTAssertFalse(app.buttons["downloadBetterVoiceModels"].exists, "Nothing better runs in the Simulator")
        // OpenAI is an opt-in below: off, and it needs an OpenAI connection first.
        for id in ["openAIVoicesOptIn", "openAITranscription"] {
            let toggle = reveal(app.switches[id], in: app)
            XCTAssertEqual(toggle.value as? String, "0", "\(id) is off by default")
            XCTAssertFalse(toggle.isEnabled, "\(id) needs an OpenAI connection")
        }
        XCTAssertTrue(app.staticTexts["openAINeedsConnection"].exists)
        capture("voice-openai-optin")
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'huggingface'")).firstMatch.exists)
        let about = reveal(app.buttons["openAboutVoices"], in: app)
        capture("voice-models")
        about.tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'huggingface.co'")).firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'no voice model to choose'")).firstMatch.exists)
        capture("voice-about")
        reveal(app.staticTexts["aboutListening"], in: app)
        XCTAssertTrue(app.staticTexts["aboutListening"].label.contains("Listens while the app is open"))
        reveal(app.staticTexts["mlx-audio-swift"], in: app)
        XCTAssertTrue(app.staticTexts["Whisper large-v3-turbo"].exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
    @MainActor private func expectValue(_ element: XCUIElement, _ value: String, matches: Bool = true) -> Bool {
        let done = XCTNSPredicateExpectation(predicate: NSPredicate(format: matches ? "value == %@" : "NOT (value == %@)", value), object: element)
        return XCTWaiter().wait(for: [done], timeout: 3) == .completed
    }
    @MainActor func testModelAndNearbyDrawersDoNotActivateServices() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--voice-command=Open model"]
        app.launch()
        XCTAssertTrue(app.buttons["model-onDevice"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["addModelConnection"].exists)
        XCTAssertTrue(app.staticTexts["Apple on-device"].exists)
        // Apple's Private Cloud sits beside on-device: chosen only after its one destination line, and
        // without the lock. Where the system doesn't offer it, the row is disabled with the reason.
        let cloud = app.buttons["model-privateCloud"]
        XCTAssertTrue(cloud.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Apple Private Cloud"].exists)
        if cloud.isEnabled {
            XCTAssertTrue(app.staticTexts["privacyLock"].exists)
            cloud.tap()
            let confirm = app.buttons["confirmPrivateCloud"].firstMatch
            XCTAssertTrue(confirm.waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["Runs on Apple’s Private Cloud Compute."].exists)
            capture("pcc-confirm")
            confirm.tap()
            XCTAssertTrue(app.staticTexts["privateCloudDestination"].waitForExistence(timeout: 5))
            XCTAssertFalse(app.staticTexts["privacyLock"].exists, "No lock while Private Cloud is in use")
            capture("pcc-chosen")
            app.buttons["model-onDevice"].tap()
            XCTAssertTrue(app.staticTexts["privacyLock"].waitForExistence(timeout: 5))
        } else {
            XCTAssertFalse(app.staticTexts["privateCloudDestination"].exists)
        }
        capture("b19-model-options")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--voice-command=Find nearby kemos"]
        app.launch()
        // Nearby is one switch, off until you turn it on; the limits are visible before anything starts.
        let open = app.switches["startNearbyKemos"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        XCTAssertEqual(open.value as? String, "0")
        XCTAssertTrue(app.textFields["nearbyInterests"].exists)
        capture("b19-nearby-off")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        // Deliberately do not tap discovery: this test never broadcasts.
    }
    @MainActor func testMicrophoneFailureOffersRetryWithoutRecording() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--voice-startup-failure"]
        app.launch()
        let retry = app.buttons["microphoneToggle"]
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        // Only a problem gets a line above the composer; retrying clears it without listening.
        let problem = app.staticTexts["voiceStatus"]
        XCTAssertTrue(problem.waitForExistence(timeout: 5))
        retry.tap()
        XCTAssertTrue(problem.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Listening…"].exists)
        app.buttons["settingsGear"].tap()
        XCTAssertFalse(app.otherElements["drawerVoiceBar"].exists)
        XCTAssertFalse(app.switches["enableVoice"].exists)
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
    }
    @MainActor func testEntireMotionLibraryAudit() {
        let app = XCUIApplication()
        for time in ["1.2","4.6","8.8"] {
            app.launchArguments = ["--ui-testing","--motion-audit","--preview-time="+time]
            app.launch(); XCTAssertTrue(app.staticTexts["auditReady"].waitForExistence(timeout:10))
            for page in 0..<8 {
                capture("b15-audit-\(page)-\(time)")
                app.buttons["auditNext"].tap()
            }
            app.terminate()
        }
    }
    @MainActor func testMusicAndPencilV5Frames() {
        let app = XCUIApplication()
        for (id,time) in [("dj","1"),("dj","2"),("piano","1"),("piano","2"),("dance","1"),("writing","1"),("writing","3.7"),("writing","6")] {
            app.launchArguments = ["--ui-testing","--preview-performance="+id,"--preview-time="+time,"--voice-command=Switch to the apricot theme"]
            app.launch(); XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout:5))
            capture("b14-"+id+"-"+time); app.terminate()
        }
    }
    @MainActor func testLapWritingV6Frames() {
        let app = XCUIApplication()
        for (theme,time) in [("apricot","0.8"),("apricot","4.0"),("apricot","6.9"),("sky","6.9")] {
            app.launchArguments = ["--ui-testing","--preview-performance=writing","--preview-time="+time,
                                   "--voice-command=Switch to the "+theme+" theme"]
            app.launch()
            XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout:5))
            XCTAssertFalse(app.staticTexts["I couldn’t find one matching palette. Choose one in Appearance."].exists)
            capture("v6-lap-writing-"+theme+"-"+time)
            app.terminate()
        }
    }
    @MainActor func testExpandedPropScenes() {
        let app = XCUIApplication()
        let frames = [("coding","3.2"),("debugging","4"),("debugging","8"),("testing","6"),("code-review","5"),("deploying","9"),("email-draft","3"),("calendar-planning","5"),("filing","4"),("searching-files","4"),("tea-break","1"),("sipping","4"),("countdown","5"),("headphone-listen","3"),("conducting","1"),("drumming","1"),("breathing","3"),("stretching","3"),("recipe","3"),("reading","4"),("page-turn","2"),("bookmarking","3"),("sources","5"),("comparing","5"),("reviewing","4")]
        for (id,time) in frames {
            app.launchArguments = ["--ui-testing", "--preview-performance="+id, "--preview-time="+time, "--voice-command=Switch to the apricot theme"]
            app.launch(); XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout:5))
            capture("b13-scene-"+id+"-"+time); app.terminate()
        }
    }
    @MainActor func testPropThemePreviews() {
        let app = XCUIApplication()
        for theme in ["sky","moss","ink","paper"] {
            for id in ["coding","dance","sipping"] {
                app.launchArguments = ["--ui-testing", "--preview-performance="+id, "--preview-time=3", "--voice-command=Switch to the "+theme+" theme"]
                app.launch(); XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout:5))
                capture("b13-prop-"+theme+"-"+id); app.terminate()
            }
        }
    }
    @MainActor func testDistinctThemeCharacterPreviews() {
        let app = XCUIApplication()
        for theme in ["matcha", "pistachio", "moss", "ember", "lagoon", "mulberry", "ink", "paper"] {
            for performance in ["idle", "reading"] {
                app.launchArguments = ["--ui-testing", "--preview-performance=" + performance, "--preview-time=0", "--voice-command=Switch to the " + theme + " theme"]
                app.launch()
                XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 5))
                capture("b13-" + theme + "-" + performance)
                app.terminate()
            }
        }
    }
    @MainActor func testPlannerReviewAndMemoryApproval() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--planner-fixture"]
        app.launch()
        // Prepared proposals are listed under Library → Drafts.
        let drafts = app.segmentedControls.buttons["Drafts"].firstMatch
        XCTAssertTrue(drafts.waitForExistence(timeout: 8)); drafts.tap()
        let save = app.buttons["Save memory"].firstMatch
        for _ in 0..<4 where !save.isHittable { app.swipeUp() }
        XCTAssertTrue(save.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Saved to memory"].exists)
        capture("b12-planner-review")
        save.tap()
        XCTAssertTrue(app.staticTexts["Saved to memory"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.firstMatch.exists)
        capture("b12-memory-approved")
        let reviewed = app.buttons["Mark reviewed"].firstMatch
        for _ in 0..<4 where !reviewed.isHittable { app.swipeUp() }
        XCTAssertTrue(reviewed.waitForExistence(timeout: 3)); reviewed.tap()
        XCTAssertTrue(app.staticTexts["Reviewed · not sent"].firstMatch.waitForExistence(timeout: 3))
    }
    @MainActor func testRoutineReviewDoesNotScheduleWithoutApproval() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--voice-command=Open routine"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Your day"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Review alarm"].exists)
        XCTAssertFalse(app.switches["Prepare my morning"].exists)
        XCTAssertFalse(app.staticTexts["Scheduled with Apple AlarmKit"].exists)
        capture("b13-continuity")
        XCTAssertFalse(XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["Allow “KemoSabe” to schedule alarms and timers?"].exists)
        app.terminate()
        app.launchArguments = ["--ui-testing", "--voice-command=Open voice settings"]
        app.launch()
        reveal(app.sliders["speechRate"], in: app)
        XCTAssertFalse(app.buttons["Local & subscription voices"].exists)
        capture("b11-voice-options")
    }
    @MainActor func testBookAndWritingThemeRegression() {
        let app = XCUIApplication()
        for theme in ["sky", "apricot", "matcha"] {
            for (id,time) in [("reading","0"),("reading","6.6"),("writing","1.4"),("writing","5.2"),("writing","7.8")] {
                app.launchArguments = ["--ui-testing", "--preview-performance="+id, "--preview-time="+time,
                                       "--voice-command=Switch to the "+theme+" theme"]
                app.launch()
                XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 5))
                capture("b11-"+theme+"-"+id+"-"+time)
                app.terminate()
            }
        }
    }
    @MainActor func testApprovedCharacterReviewFrames() {
        let app = XCUIApplication()
        for (id, time) in [("idle", "0"), ("reading", "0"), ("reading", "6.6"), ("thinking", "3"), ("dance", "0.17"), ("coding", "3.2"), ("sketching", "7.8")] {
            app.launchArguments = ["--ui-testing", "--preview-performance="+id, "--preview-time="+time,
                                   "--voice-command=Switch to the apricot theme"]
            app.launch()
            XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 5))
            capture("v3-"+id+"-"+time)
            app.terminate()
        }
    }
    @MainActor func testNativeReadingAndWriting() {
        let app = XCUIApplication(); app.launchArguments = ["--developer", "--ui-testing"]; app.launch()
        openAnimationGallery(app)
        XCTAssertFalse(app.buttons["Earlier 3D studies"].exists)
        XCTAssertTrue(app.buttons["motionPause"].waitForExistence(timeout: 5))
        capture("native-writing")
        reveal(app.buttons["animation-reading"], in: app).tap()
        capture("native-reading")
    }
    /// Replaces the pre-tab-bar core journey: a palette choice and a custom palette survive a relaunch.
    @MainActor func testCustomPaletteAndThemePersistAcrossLaunch() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 8))
        app.buttons["settingsGear"].tap(); app.buttons["openCharacter"].tap()
        XCTAssertTrue(app.buttons["openThemeDrawer"].waitForExistence(timeout: 5))
        app.buttons["openThemeDrawer"].tap(); app.buttons["theme-lavender"].tap()
        XCTAssertTrue(app.buttons["closeThemeDrawer"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["openThemeDrawer"].value as? String, "Lavender")
        reveal(app.buttons["customColors"], in: app).tap()
        XCTAssertTrue(app.textFields["paletteName"].waitForExistence(timeout: 3))
        capture("b44-custom-palette")
        app.buttons["savePalette"].tap()
        XCTAssertTrue(app.buttons["customColors"].waitForExistence(timeout: 3))
        // Saving a palette selects it; choose Lavender again so the relaunch checks a stock choice.
        app.buttons["openThemeDrawer"].tap(); reveal(app.buttons["theme-lavender"], in: app).tap()
        XCTAssertTrue(app.buttons["closeThemeDrawer"].waitForNonExistence(timeout: 3))
        app.terminate(); app.launch()
        app.buttons["settingsGear"].tap(); app.buttons["openCharacter"].tap()
        XCTAssertTrue(app.buttons["openThemeDrawer"].waitForExistence(timeout: 5))
        app.buttons["openThemeDrawer"].tap()
        XCTAssertEqual(app.buttons["theme-lavender"].value as? String, "Selected")
        app.buttons["theme-apricot"].tap()
        XCTAssertTrue(app.buttons["closeThemeDrawer"].waitForNonExistence(timeout: 3))
    }
    @MainActor func testThemesUseOneContinuousGrid() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        app.buttons["settingsGear"].tap(); app.buttons["openCharacter"].tap()
        app.buttons["openThemeDrawer"].tap()
        XCTAssertFalse(app.buttons["moreThemeShades"].exists)
        XCTAssertFalse(app.staticTexts["Your palettes"].exists)
        XCTAssertFalse(app.staticTexts["Current palette"].exists)
        XCTAssertFalse(app.buttons["theme-blueberry"].exists)
        let peach = app.buttons["theme-peach"]
        if !peach.isHittable { app.swipeUp() }
        XCTAssertFalse(app.buttons["theme-blueberry"].exists)
        XCTAssertTrue(peach.waitForExistence(timeout: 3)); peach.tap()
        XCTAssertTrue(app.buttons["closeThemeDrawer"].waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.buttons["openThemeDrawer"].value as? String, "Peach")
        app.buttons["openThemeDrawer"].tap()
        if !app.buttons["theme-peach"].isHittable { app.swipeUp() }
        XCTAssertEqual(app.buttons.matching(identifier: "theme-peach").count, 1)
        XCTAssertEqual(app.buttons["theme-peach"].value as? String, "Selected")
        capture("09-continuous-theme-drawer")
        let apricot = app.buttons["theme-apricot"]
        for _ in 0..<5 where !(apricot.exists && apricot.isHittable) { app.scrollViews.firstMatch.swipeDown() }
        apricot.tap()
        XCTAssertTrue(app.buttons["closeThemeDrawer"].waitForNonExistence(timeout: 3))
    }
    /// The Character page's preview pages like the watch's face-style editor (September 25):
    /// swipe between Color and Tone, step through options, and Kemo previews the choice live.
    @MainActor func testCharacterCardPagesColorAndToneLikeTheWatch() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 8))
        app.buttons["settingsGear"].tap(); app.buttons["openCharacter"].tap()
        let color = app.staticTexts["characterFaceOption-Color"]
        XCTAssertTrue(color.waitForExistence(timeout: 5))
        let before = color.label
        app.buttons["characterFace-Color-next"].tap()
        XCTAssertNotEqual(color.label, before, "The next palette applies right away")
        let chosen = String(color.label.dropFirst("Color: ".count))
        XCTAssertEqual(app.buttons["openThemeDrawer"].value as? String, chosen, "The palette row below agrees")
        capture("character-card-color")
        app.buttons["characterFace-Color-previous"].tap()
        XCTAssertEqual(color.label, before)
        // Swipe across the card, from right of the name to well left of it.
        let start = color.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).withOffset(CGVector(dx: 120, dy: -120))
        start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: -260, dy: 0)))
        let tone = app.staticTexts["characterFaceOption-Tone"]
        XCTAssertTrue(tone.waitForExistence(timeout: 3))
        XCTAssertEqual(tone.label, "Tone: Default")
        app.buttons["characterFace-Tone-next"].tap()
        XCTAssertEqual(tone.label, "Tone: Warm")
        capture("character-card-tone")
        app.buttons["characterFace-Tone-previous"].tap()
        XCTAssertEqual(tone.label, "Tone: Default")
    }
    @MainActor func testConnectionsHaveHonestAvailabilityAndNativePermissionEntry() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing"]; app.launch()
        // Connections sits below the fold now that Personal has more pages.
        app.buttons["settingsGear"].tap(); reveal(app.buttons["openConnections"], in: app).tap()
        XCTAssertTrue(app.buttons["connector-calendar"].waitForExistence(timeout: 4))
        XCTAssertTrue(app.buttons["connector-reminders"].exists)
        XCTAssertTrue(app.buttons["connector-contacts"].exists)
        XCTAssertFalse(app.otherElements["drawerVoiceBar"].exists)
        capture("10-connections")
        app.buttons["connector-calendar"].tap()
        XCTAssertTrue(app.buttons["connectConnector"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["connectionStatus"].label, "Not connected")
        capture("11-calendar-permission-entry")
        app.buttons["allConnectors"].tap()
        let gmail = app.buttons["connector-gmail"]
        if !gmail.isHittable { app.swipeUp() }
        gmail.tap()
        XCTAssertTrue(app.staticTexts["Not available"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["connectConnector"].exists)
        capture("12-unconfigured-account")
    }
    @MainActor func testSpokenNavigationUsesTheSameDrawerWithoutAnAIModel() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--voice-command=Kemo, open connections"]; app.launch()
        XCTAssertTrue(app.buttons["connector-calendar"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["drawerVoiceBar"].exists)
        app.buttons["closeConnections"].tap()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.tabBars.count, 1, "Closing the drawer returns to the tabbed shell")
    }
    @MainActor func testSpokenThemeAppliesAndPersists() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--voice-command=Kemo switch to the matcha theme"]; app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 4))
        app.buttons["settingsGear"].tap(); app.buttons["openCharacter"].tap()
        XCTAssertEqual(app.buttons["openThemeDrawer"].value as? String, "Matcha")
        app.buttons["openThemeDrawer"].tap(); app.buttons["theme-apricot"].tap()
        XCTAssertTrue(app.buttons["closeThemeDrawer"].waitForNonExistence(timeout: 3))
    }
    @MainActor func testArtworkAndVoiceControls() {
        let app = XCUIApplication(); app.launchArguments = ["--developer", "--ui-testing"]; app.launch()
        app.buttons["settingsGear"].tap(); openVoicePage(app)
        reveal(app.sliders["speechRate"], in: app)
        reveal(app.switches["patientListening"], in: app)
        reveal(app.switches["voiceInterruptions"], in: app)
        capture("07-voice-conversation")
        // Models is a sheet over Settings; start fresh for the gallery.
        app.terminate(); app.launch()
        openAnimationGallery(app)
        reveal(app.buttons["animation-writing"], in: app).tap()
        capture("08-reference-writing")
    }
    private func capture(_ name: String) {
        let screenshot = XCUIScreen.main.screenshot()
        let a = XCTAttachment(screenshot: screenshot); a.name = name; a.lifetime = .keepAlways; add(a)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".png")
        try? screenshot.pngRepresentation.write(to: url)
        print("PREVIEW_PATH: \(url.path)")
    }
    @MainActor func testFirstRunNamesTheCompanionEverywhere() {
        // Like Muse: the companion opens the first chat by asking its name, then its look and tone.
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture", "--first-run"]; app.launch()
        XCTAssertTrue(app.staticTexts[CompanionIntroCopy.opening].waitForExistence(timeout: 8))
        capture("b40-intro-name")
        let input = app.textFields["chatInput"]
        input.tap(); input.typeText("call you mochi!"); app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.staticTexts[CompanionIntroCopy.look("Mochi")].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["introChoice-Lavender"].exists)
        capture("b40-intro-look")
        app.buttons["introChoice-Lavender"].tap()
        XCTAssertTrue(app.buttons["introChoice-Playful"].waitForExistence(timeout: 5))
        app.buttons["introChoice-Playful"].tap()
        XCTAssertTrue(app.staticTexts[CompanionIntroCopy.finished("Mochi")].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["introChoice-Playful"].exists)
        capture("b40-intro-done")
        input.tap(); input.typeText("Do your animation")
        app.buttons["sendMessage"].tap()
        XCTAssertEqual(app.otherElements["homeCompanion"].label, "Mochi, dance")
        app.buttons["settingsGear"].tap(); app.buttons["openCharacter"].tap()
        XCTAssertEqual(app.textFields["companionName"].value as? String, "Mochi")
        XCTAssertTrue(app.buttons["character-Mochi"].exists)
    }
    /// A clean install (September 25): welcome, one account for iPhone, Mac, and Watch, the
    /// companion's own intro chat, optional permissions (nothing asked until tapped), then Chat.
    @MainActor func testOnboardingOnACleanInstall() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture", "--onboarding", "--developer"]; app.launch()
        XCTAssertTrue(app.images["onboardingLogo"].waitForExistence(timeout: 8), "The official logo on the welcome")
        XCTAssertTrue(app.buttons["onboardingContinue"].exists)
        capture("onboarding-1-welcome")
        app.buttons["onboardingContinue"].tap()

        XCTAssertTrue(app.staticTexts["onboardingAccountTitle"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["onboardingAccountTitle"].label, "One account for iPhone, Mac, and Watch")
        for words in ["Create", "new account", "Sign up"] {
            XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] %@", words)).firstMatch.exists, words)
        }
        capture("onboarding-2-account")
        app.buttons["onboardingLocal"].tap()

        // The companion's intro runs in Chat itself: the same Muse-like conversation as before.
        XCTAssertTrue(app.staticTexts[CompanionIntroCopy.opening].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["onboardingContinue"].exists, "The pages step aside for the intro")
        capture("onboarding-3-intro")
        let input = app.textFields["chatInput"]
        input.tap(); input.typeText("Mochi"); app.buttons["sendMessage"].tap()
        XCTAssertTrue(app.buttons["introChoice-Lavender"].waitForExistence(timeout: 5))
        app.buttons["introChoice-Lavender"].tap()
        XCTAssertTrue(app.buttons["introChoice-Playful"].waitForExistence(timeout: 5))
        app.buttons["introChoice-Playful"].tap()
        XCTAssertTrue(app.staticTexts[CompanionIntroCopy.finished("Mochi")].waitForExistence(timeout: 5))

        // Then permissions, each only when tapped, each with Not now.
        XCTAssertTrue(app.staticTexts["onboardingPermissionsTitle"].waitForExistence(timeout: 6))
        for permission in ["microphone", "notifications", "calendar", "contacts"] {
            // Notification permission can't be reset between UI tests, and the notification tests
            // grant it on the same simulator; a permission that's already allowed shows "On".
            let row = app.descendants(matching: .any)["onboardingPermission-" + permission]
            if permission == "notifications", row.staticTexts["On"].exists { continue }
            XCTAssertTrue(app.buttons["onboardingAllow-" + permission].exists, permission)
            XCTAssertTrue(app.buttons["onboardingNotNow-" + permission].exists, permission)
        }
        capture("onboarding-4-permissions")
        app.buttons["onboardingNotNow-microphone"].tap()
        XCTAssertFalse(app.buttons["onboardingAllow-microphone"].exists)
        app.buttons["onboardingAllow-calendar"].tap()
        XCTAssertTrue(app.staticTexts["On"].waitForExistence(timeout: 3))
        app.buttons["onboardingDone"].tap()

        // Done: Chat, with the companion named.
        XCTAssertTrue(app.staticTexts["headerName"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["headerName"].label, "Mochi")
        XCTAssertTrue(input.isHittable)
        XCTAssertFalse(app.buttons["onboardingDone"].exists)
        capture("onboarding-5-chat")

        // Developer settings can show it again, from General.
        app.buttons["settingsGear"].tap()
        reveal(app.buttons["openGeneral"], in: app).tap()
        let replay = reveal(app.buttons["replayOnboarding"], in: app)
        replay.tap()
        XCTAssertTrue(app.images["onboardingLogo"].waitForExistence(timeout: 5))
        app.terminate()

        // UI tests with their usual fixtures never see it.
        app.launchArguments = ["--ui-testing", "--isolated-fixture"]; app.launch()
        XCTAssertTrue(app.buttons["settingsGear"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.images["onboardingLogo"].exists)
    }
    @MainActor func testVersionEasterEggRevealsDeveloperSettings() {
        let app = XCUIApplication(); app.launchArguments = ["--ui-testing", "--isolated-fixture"]; app.launch()
        app.buttons["settingsGear"].tap()
        XCTAssertFalse(app.buttons["openAnimations"].exists, "Animations are a developer view, not a Settings row")
        app.buttons["openCharacter"].tap()
        XCTAssertTrue(app.buttons["openThemeDrawer"].waitForExistence(timeout: 3))
        app.swipeUp(); app.swipeUp()
        if app.buttons["turnOffDeveloper"].exists { app.buttons["turnOffDeveloper"].tap() }
        XCTAssertFalse(app.buttons["openAnimations"].exists)
        app.navigationBars.buttons.element(boundBy: 0).tap()
        reveal(app.buttons["openGeneral"], in: app).tap()
        let version = app.buttons["versionNumber"]
        XCTAssertTrue(version.waitForExistence(timeout: 3))
        for _ in 0..<7 { version.tap() }
        XCTAssertTrue(app.staticTexts["Developer settings unlocked. Find them at the bottom of Companion."].waitForExistence(timeout: 3))
        capture("b39-developer-unlocked")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        // Settings is still scrolled down to About, with Companion under the search bar; search for it.
        let search = app.searchFields.firstMatch
        search.tap(); search.typeText("Companion")
        app.buttons["openCharacter"].tap()
        let link = reveal(app.buttons["openAnimations"], in: app)
        capture("b39-developer-section")
        app.buttons["turnOffDeveloper"].tap()
        XCTAssertTrue(link.waitForNonExistence(timeout: 3))
    }
    /// The animation gallery is a developer view at the bottom of Companion.
    @MainActor private func openAnimationGallery(_ app: XCUIApplication) {
        if !app.buttons["openCharacter"].exists { app.buttons["settingsGear"].tap() }
        app.buttons["openCharacter"].tap()
        reveal(app.buttons["openAnimations"], in: app).tap()
    }
    /// Voice is a tab of the Models page.
    /// Your voice set-up with the stand-in microphone (a synthetic hum, never a person) and a
    /// checker that hears the line on screen: the room check, takes with the live meter, a redo,
    /// the consent line, Hear it, Record more, and Start over. Save stays off: there's no voice
    /// model in the Simulator, so nothing is ever saved from the stand-in.
    @MainActor func testYourVoiceTrainingFlow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--stub-own-voice", "--stub-noisy-room"]
        app.launch()
        app.buttons["settingsGear"].tap()
        openTrainingTab(app)
        reveal(app.buttons["setUpOwnVoice"], in: app).tap()
        let checkRoom = app.buttons["ownVoiceCheckRoom"]
        XCTAssertTrue(checkRoom.waitForExistence(timeout: 5))
        capture("own-voice-start")
        checkRoom.tap()
        XCTAssertTrue(app.descendants(matching: .any)["ownVoiceNoisy"].waitForExistence(timeout: 8))
        capture("own-voice-noisy-room")
        app.buttons["ownVoiceContinueAnyway"].tap()

        func recordTake(_ id: Int, screenshot: String? = nil) {
            let record = reveal(app.buttons["ownVoiceRecordTake"], in: app)
            record.tap()
            let stop = app.buttons["ownVoiceStopTake"]
            XCTAssertTrue(stop.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1.5)
            if let screenshot {
                XCTAssertTrue(app.descendants(matching: .any)["ownVoiceMeter"].exists)
                capture(screenshot)
            }
            stop.tap()
            XCTAssertTrue(app.buttons["ownVoiceRedo-\(id)"].waitForExistence(timeout: 8), "take \(id) accepted")
        }
        recordTake(0, screenshot: "own-voice-recording")
        recordTake(1)
        capture("own-voice-takes")
        // Redo a take: it goes back to be read again.
        reveal(app.buttons["ownVoiceRedo-1"], in: app).tap()
        recordTake(1)
        recordTake(2)
        recordTake(3)

        let consent = reveal(app.buttons["ownVoiceRecordConsent"], in: app)
        consent.tap()
        let stop = app.buttons["ownVoiceStopTake"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        stop.tap()

        let hear = app.buttons["ownVoiceHearIt"]
        XCTAssertTrue(hear.waitForExistence(timeout: 15))
        reveal(hear, in: app)
        capture("own-voice-ready")
        hear.tap()
        XCTAssertTrue(expectValue(hear, "Playing"))
        let save = reveal(app.buttons["saveOwnVoice"], in: app)
        XCTAssertFalse(save.isEnabled, "no voice model in the Simulator, so nothing is saved")

        // Record more adds a fifth passage and rebuilds; five is the most.
        reveal(app.buttons["ownVoiceRecordMore"], in: app).tap()
        recordTake(4)
        XCTAssertTrue(reveal(app.buttons["ownVoiceHearIt"], in: app).waitForExistence(timeout: 15))
        XCTAssertFalse(reveal(app.buttons["ownVoiceRecordMore"], in: app).isEnabled)

        reveal(app.buttons["ownVoiceStartOver"], in: app).tap()
        XCTAssertTrue(app.buttons["ownVoiceCheckRoom"].waitForExistence(timeout: 5))
        app.buttons["closeOwnVoice"].tap()
        XCTAssertTrue(app.buttons["setUpOwnVoice"].waitForExistence(timeout: 5), "still not set up")
    }

    /// Settings → Companion → Voice.
    @MainActor private func openVoicePage(_ app: XCUIApplication) {
        let companion = app.buttons["openCharacter"]
        XCTAssertTrue(companion.waitForExistence(timeout: 5)); companion.tap()
        reveal(app.buttons["openVoiceSettings"], in: app).tap()
        XCTAssertTrue(app.navigationBars["Voice"].waitForExistence(timeout: 5))
    }
    /// Settings → Models → Training.
    @MainActor private func openTrainingTab(_ app: XCUIApplication) {
        reveal(app.buttons["openModel"], in: app).tap()
        let tab = app.segmentedControls["modelsTabs"].buttons["Training"]
        XCTAssertTrue(tab.waitForExistence(timeout: 5)); tab.tap()
    }
    /// Scrolls back to the top of the page.
    @MainActor private func toTop(_ app: XCUIApplication) {
        if app.keyboards.firstMatch.exists { app.swipeDown() }
        for _ in 0..<6 { app.swipeDown(velocity: .fast) }
    }
    /// Lists load rows lazily, so scroll until the element is on screen.
    @MainActor @discardableResult private func reveal(_ element: XCUIElement, in app: XCUIApplication) -> XCUIElement {
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<8 where !(element.exists && element.isHittable) { app.swipeUp() }
        XCTAssertTrue(element.exists, "\(element) never appeared")
        return element
    }
}

/// The intro's lines, kept in step with CompanionIntro (the UI test target doesn't link the app).
private enum CompanionIntroCopy {
    static let opening = "Hi, I'm your new companion! What would you like to call me? KemoSabe is fine too."
    static func look(_ name: String) -> String { "\(name) it is! Want to change how I look? Say a color like lavender or blue, pick one below, or keep this look." }
    static func finished(_ name: String) -> String { "All set. I'm \(name). You can change any of this in Settings → Companion. What's on your mind?" }
}
