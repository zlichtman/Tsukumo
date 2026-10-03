import XCTest
@testable import KemoSabe

final class KemoSabeTests: XCTestCase {
    @MainActor func testNameAndStandupCommandsHaveBoundaries() {
        XCTAssertTrue(VoiceController.containsName("Hey Kemo Sabe!"))
        XCTAssertFalse(VoiceController.containsName("kemosabers"))
        XCTAssertTrue(VoiceController.isNameOnly("Hey Kemosabe!"))
        XCTAssertFalse(VoiceController.isNameOnly("Kemosabe write a paper"))
        XCTAssertTrue(VoiceController.isStandupCommand("KemoSabe, prepare my standup."))
        XCTAssertFalse(VoiceController.isStandupCommand("Don't prepare my standup"))
    }
    func testEveryCatalogAnimationHasNativeChoreography() {
        XCTAssertEqual(Set(Performance.all.map(\.id)), Set(ArtworkPerformance.allCases.map(\.rawValue)))
        for item in ArtworkPerformance.allCases {
            for t in stride(from: 0.0, to: 12.0, by: 0.05) {
                let p = item.pose(at: t)
                XCTAssertTrue([p.x,p.y,p.tilt,p.stretch,p.left.x,p.right.y].allSatisfy(\.isFinite))
                XCTAssertLessThan(abs(p.tilt), 0.2)
                let still = item.pose(at: t, reducedMotion: true)
                XCTAssertEqual(still.x, 0); XCTAssertEqual(still.left, .zero)
            }
        }
    }
    @MainActor func testStandupProvenanceAndReview() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: DelayedProvider())
        let kept = MemoryNote(text: "Shipped the settings cleanup", scope: "Company")
        store.saveMemory(kept); store.saveMemory(.init(text: "Excluded", useInChat: false))
        store.draftStandup()
        try await Task.sleep(for: .milliseconds(150))
        let item = try XCTUnwrap(store.state.workItems?.first)
        XCTAssertEqual(item.sourceIDs, [kept.id]); XCTAssertEqual(item.status, "Needs review")
        store.markReviewed(item.id); XCTAssertEqual(store.state.workItems?.first?.status, "Reviewed · not sent")
        store.draftStandup(); store.cancelStandup()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(store.state.workItems?.last?.status, "Interrupted")
        XCTAssertEqual(store.state.workItems?.last?.draft, "")
    }
    func testAtmosphereRemainsLegible() {
        XCTAssertEqual(CustomPaletteEditor.darkAtmosphere("FFFFFF"), "585858")
        XCTAssertEqual(CustomPaletteEditor.darkAtmosphere("211B2C"), "211B2C")
        XCTAssertEqual(CustomPaletteEditor.darkAtmosphere("000000"), "000000")
    }
    func testCustomThemesAndPermissionStatePersist() throws {
        var state = SavedState()
        state.customThemes = [BotTheme(id: "custom-test", name: "My palette", body: "FFFFFF", accent: "FF5500", background: "211B2C")]
        state.permissionSetupAttempted = true
        let saved = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(saved.customThemes?.first?.id, "custom-test")
        XCTAssertEqual(saved.permissionSetupAttempted, true)
    }
    @MainActor func testVoicePauseCommandsAreExplicit() {
        XCTAssertTrue(VoiceController.isPauseCommand("Stop listening!"))
        XCTAssertTrue(VoiceController.isPauseCommand("Kemosabe, stop listening."))
        XCTAssertFalse(VoiceController.isPauseCommand("Don’t stop listening yet."))
        XCTAssertFalse(VoiceController.isPauseCommand("Help me write about listening."))
    }
    func testExistingStateMigratesWithVoiceOff() throws {
        let original = SavedState()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SavedState.self, from: data)
        XCTAssertNil(decoded.voiceEnabled)
        XCTAssertNil(decoded.captionsEnabled)
    }
    @MainActor func testVoiceStaysOffUntilOptIn() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: DelayedProvider())
        let voice = VoiceController()
        voice.activate(store: store)
        XCTAssertEqual(voice.phase, .off)
        XCTAssertEqual(voice.status, "Tap the microphone to start")
        voice.deactivate()
        XCTAssertEqual(voice.phase, .off)
    }
    @MainActor func testVoiceGateDoesNotCancelTypedReply() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: DelayedProvider())
        let voice = VoiceController()
        voice.activate(store: store)
        let replied = expectation(description: "typed reply finishes")
        store.send("Hello", completion: { answer in
            XCTAssertEqual(answer, "Late response"); replied.fulfill()
        })
        // RootView turns voice off while a typed reply runs; that must not cancel the reply.
        voice.deactivate()
        await fulfillment(of: [replied], timeout: 3)
        XCTAssertEqual(store.state.messages.last?.text, "Late response")
    }
    func testBookPageRemainsAttachedToGutter() {
        for turn in stride(from: 0.0, through: 1.0, by: 0.01) {
            XCTAssertEqual(ReadingMotion.pagePoint(u: 0, v: 0, turn: turn), CGPoint(x: 0.5, y: 0.706))
            let tip = ReadingMotion.pagePoint(u: 1, v: 0, turn: turn)
            XCTAssertTrue((0.32...0.68).contains(tip.x)); XCTAssertTrue((0.50...0.71).contains(tip.y))
        }
    }
    func testCatalogIsComplete() {
        XCTAssertEqual(Performance.all.count, 64)
        XCTAssertEqual(Set(Performance.all.map(\.id)).count, 64)
        XCTAssertTrue(Performance.all.contains { $0.id == "proofreading" })
    }
    func testThemePresetsAreValidAndUnique() {
        XCTAssertEqual(Set(BotTheme.presets.map(\.id)).count, 21)
        XCTAssertEqual(Array(BotTheme.presets.prefix(6).map(\.id)), ["apricot", "matcha", "lavender", "rose", "sky", "cocoa"])
        for theme in BotTheme.presets {
            for hex in [theme.body, theme.accent, theme.background] { XCTAssertEqual(hex.count, 6); XCTAssertNotNil(UInt32(hex, radix: 16)) }
            XCTAssertNotEqual(theme.body, theme.accent)
        }
    }
    func testThemeShelfIsCuratedWithoutLosingExistingPalettes() {
        XCTAssertEqual(ThemeShelf.featured.count, 8)
        XCTAssertEqual(Set(ThemeShelf.featured.map(\.id)).count, 8)
        XCTAssertTrue(Set(ThemeShelf.featured.map(\.id)).isDisjoint(with: ThemeShelf.more.map(\.id)))
        XCTAssertEqual(Set((ThemeShelf.featured + ThemeShelf.more).map(\.id)), Set(BotTheme.presets.map(\.id)))
        XCTAssertEqual(ThemeShelf.visible.count, 20)
        XCTAssertEqual(Set(ThemeShelf.visible.map(\.id)), Set(BotTheme.presets.map(\.id)).subtracting(["blueberry"]))
        XCTAssertNil(ThemeShelf.extraCurrent(BotTheme.presets[0]))
        let peach = BotTheme.presets.first { $0.id == "peach" }!
        XCTAssertEqual(ThemeShelf.extraCurrent(peach), peach)
    }
    func testRepeatedCustomPalettesShowOnceWithoutLosingSelectedIdentity() {
        var first = BotTheme.presets[0]; first.id = "custom-first"; first.name = "My palette"
        var second = first; second.id = "custom-second"
        let result = ThemeShelf.uniqueCustom([first, second], currentID: second.id)
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result.first?.id, second.id)
        second.name = "A different name"
        XCTAssertEqual(ThemeShelf.uniqueCustom([first, second], currentID: second.id).count, 2)
    }
    func testPersistenceRoundTrip() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = LocalRepository(url: folder.appendingPathComponent("state.json"))
        var state = SavedState(); state.theme = BotTheme.presets[2]; state.memories = [.init(text: "Short standups")]
        try repo.save(state)
        let restored = try repo.read()
        XCTAssertEqual(restored.theme, state.theme); XCTAssertEqual(restored.memories, state.memories)
        XCTAssertEqual(try folder.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
    }
    func testContextExcludesDisabledNotesAndBoundsHistory() {
        let context = OnDeviceAssistant.context(history: (0..<30).map { .init(role: "You", text: "message-\($0)") }, memories: [.init(text: "included"), .init(text: "secret-excluded", useInChat: false)], standupFormat: "Wins / Next")
        XCTAssertTrue(context.contains("included")); XCTAssertFalse(context.contains("secret-excluded")); XCTAssertFalse(context.contains("message-0\n")); XCTAssertTrue(context.contains("message-29")); XCTAssertTrue(context.contains("Wins / Next"))
    }
    @MainActor func testMemoryUpdateDeleteAndBlankProtection() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")))
        store.saveMemory(.init(text: "   ")); XCTAssertTrue(store.state.memories.isEmpty)
        var note = MemoryNote(text: "First"); store.saveMemory(note); note.text = "Changed"; store.saveMemory(note)
        XCTAssertEqual(store.state.memories.count, 1); XCTAssertEqual(store.state.memories[0].text, "Changed")
        store.deleteMemory(note.id); XCTAssertTrue(store.state.memories.isEmpty)
    }
    @MainActor func testCancelledReplyCannotRepopulateClearedChat() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: DelayedProvider())
        store.send("Hello"); XCTAssertTrue(store.isThinking); store.clearConversation()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(store.isThinking); XCTAssertTrue(store.state.messages.isEmpty)
    }
    func testStreamingSpeechWaitsForSentenceBoundary() {
        XCTAssertEqual(VoiceTurnPolicy.stablePrefix("We can start with", final: false), "")
        XCTAssertEqual(VoiceTurnPolicy.stablePrefix("Start here. Then we", final: false), "Start here.")
        XCTAssertEqual(VoiceTurnPolicy.stablePrefix("Ask Dr. Smith", final: false), "")
        XCTAssertEqual(VoiceTurnPolicy.stablePrefix("The last thought", final: true), "The last thought")
    }
    func testVoiceEndpointerAllowsUnfinishedThoughts() {
        XCTAssertEqual(VoiceTurnPolicy.endDelay(for: "And then because", patient: false), 1.5)
        XCTAssertEqual(VoiceTurnPolicy.endDelay(for: "That is all.", patient: false), 0.75)
        XCTAssertEqual(VoiceTurnPolicy.endDelay(for: "That is all.", patient: true), 1.7)
        XCTAssertEqual(VoiceTurnPolicy.endDelay(for: "Let me think", patient: false), 1.05)
    }
    func testInterruptionsIgnoreEchoAndRequireExplicitCue() {
        XCTAssertFalse(VoiceTurnPolicy.interruption("I can help", spoken: "I can help you draft that."))
        XCTAssertFalse(VoiceTurnPolicy.interruption("KemoSabe", spoken: "KemoSabe is the app name."))
        XCTAssertTrue(VoiceTurnPolicy.interruption("KemoSabe, actually use yesterday", spoken: "Here's a draft."))
        XCTAssertTrue(VoiceTurnPolicy.interruption("Hold on", spoken: "Here's a draft."))
        XCTAssertTrue(VoiceTurnPolicy.interruption("Stop listening", spoken: "Here's a draft."))
        XCTAssertFalse(VoiceTurnPolicy.interruption("Don't stop", spoken: "Here's a draft."))
    }
    func testVoicePreferencesMigrateAndPersist() throws {
        var state = SavedState()
        XCTAssertNil(state.speechVoiceID); XCTAssertNil(state.patientListening)
        state.speechVoiceID = "test-voice"; state.speechRate = 0.46
        state.patientListening = true; state.voiceInterruptions = false
        let decoded = try JSONDecoder().decode(SavedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded.speechVoiceID, "test-voice"); XCTAssertEqual(decoded.speechRate, 0.46)
        XCTAssertEqual(decoded.patientListening, true); XCTAssertEqual(decoded.voiceInterruptions, false)
        XCTAssertEqual(VoiceCatalog.rate(9), 0.56, accuracy: 0.001)
        XCTAssertEqual(VoiceCatalog.rate(-9), 0.40, accuracy: 0.001)
    }
    @MainActor func testArtworkSourcePlatesAreBundled() {
        XCTAssertNil(ArtworkAssets.image("idle-v1")); XCTAssertNil(ArtworkAssets.image("writing-v1"))
        XCTAssertNotNil(ArtworkAssets.image("writing-lap-v6"))
        XCTAssertNil(ArtworkAssets.image("writing-clean-v2"))
        for name in ["body-clean-v3", "reading-v3", "paws-v3", "computer-v4", "headphones-v5", "dj-v5", "piano-v5", "pencil-paw-v5", "files-v4", "mug-v4", "timer-v4"] { XCTAssertNotNil(ArtworkAssets.image(name), name) }
        XCTAssertEqual(ArtworkCompanion.previewIDs.count, 64)
        XCTAssertNil(Bundle.main.url(forResource: "player", withExtension: "html", subdirectory: "Character"))
        XCTAssertNil(Bundle.main.url(forResource: "rig", withExtension: "js", subdirectory: "Character"))
    }
    func testWritingGraphiteEndsAtPencilContact() throws {
        for time in stride(from: 0.0, to: WritingMotion.duration, by: 1.0 / 60) {
            let pose = WritingMotion.pose(at: time)
            guard pose.penDown else { continue }
            let lastPoint = try XCTUnwrap(pose.ink.last(where: { !$0.isEmpty })?.last)
            XCTAssertEqual(lastPoint.x, pose.tip.x, accuracy: 0.000001)
            XCTAssertEqual(lastPoint.y, pose.tip.y, accuracy: 0.000001)
        }
    }
    func testWritingLiftsWithoutDrawingBetweenLines() {
        let before = WritingMotion.pose(at: 4.0)
        let after = WritingMotion.pose(at: 4.2)
        XCTAssertFalse(before.penDown); XCTAssertFalse(after.penDown)
        XCTAssertEqual(before.ink, after.ink)
        XCTAssertGreaterThan(after.tip.x, before.tip.x)
        XCTAssertNotEqual(before.tip.y, after.tip.y)
    }
    func testWritingLoopIsContinuousAndStaysOnThePage() {
        let first = WritingMotion.pose(at: 0)
        let last = WritingMotion.pose(at: WritingMotion.duration - 0.0001)
        XCTAssertEqual(first.tip.x, last.tip.x, accuracy: 0.00001)
        XCTAssertEqual(first.tip.y, last.tip.y, accuracy: 0.00001)
        XCTAssertEqual(last.inkOpacity, 0)
        for stroke in WritingMotion.strokes {
            for point in stroke.points(through: 1) {
                XCTAssertTrue((0.425...0.625).contains(point.x))
                XCTAssertTrue((0.740...0.789).contains(point.y))
            }
        }
    }
    func testReducedMotionKeepsWritingStillWithFinishedMarks() {
        let first = WritingMotion.pose(at: 0, reducedMotion: true)
        let later = WritingMotion.pose(at: 4, reducedMotion: true)
        XCTAssertEqual(first.tip, later.tip); XCTAssertEqual(first.ink, later.ink)
        XCTAssertTrue(first.ink.allSatisfy { !$0.isEmpty })
    }
    @MainActor func testStreamingSnapshotsArriveBeforeCompletionAndCancellationDropsLateText() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: StreamingTestProvider())
        var snapshots: [String] = [], completed = false
        store.send("Hello", onPartial: { snapshots.append($0) }, completion: { _ in completed = true })
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(snapshots, ["First sentence. "]); XCTAssertFalse(completed)
        store.clearConversation()
        try await Task.sleep(for: .milliseconds(180))
        XCTAssertEqual(snapshots.count, 1); XCTAssertFalse(completed); XCTAssertTrue(store.state.messages.isEmpty)
    }
}

struct StreamingTestProvider: AssistantProvider {
    var runsLocally = true
    var isAvailable = true
    var availabilityDescription = "Test stream"
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { "First sentence. Second sentence." }
    func streamReply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String, onSnapshot: @escaping @MainActor (String) -> Void) async throws -> String {
        await onSnapshot("First sentence. ")
        try? await Task.sleep(for: .milliseconds(130))
        await onSnapshot("First sentence. Second sentence.")
        return "First sentence. Second sentence."
    }
}

struct DelayedProvider: AssistantProvider {
    var runsLocally = true
    var isAvailable = true
    var availabilityDescription = "Test provider"
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { try? await Task.sleep(for: .milliseconds(80)); return "Late response" }
}
