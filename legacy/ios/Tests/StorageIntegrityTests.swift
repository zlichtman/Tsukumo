import XCTest
@testable import KemoSabe

/// Saved data is versioned, a newer format is never overwritten, and deleting a chat also
/// forgets the continuity notes taken from it, even across an interrupted deletion.
@MainActor final class StorageIntegrityTests: XCTestCase {
    private var root: URL!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: root) }
    private var repository: LocalRepository { .init(url: root.appendingPathComponent("state.json")) }

    func testSavesRecordTheFormatAndKeepTheOlderFileOnce() throws {
        // A file from before versioning (no schemaVersion).
        let legacy = Data(#"{"theme":{"id":"cream","name":"Cream","body":"FFF6E8","accent":"F28C6B","background":"FFFFFF"},"memories":[],"messages":[],"standupFormat":"x","onboarded":true}"#.utf8)
        try legacy.write(to: repository.url)
        var state = (try? repository.read()) ?? SavedState()
        state.onboarded = true
        try repository.save(state)
        XCTAssertEqual(try repository.read().schemaVersion, LocalRepository.schemaVersion)
        XCTAssertEqual(try Data(contentsOf: repository.backupURL), legacy, "The pre-upgrade file is kept")
        try repository.save(state)
        XCTAssertEqual(try Data(contentsOf: repository.backupURL), legacy, "…and only the first time")
    }
    func testStateFromTheRemovedCloudDemoLoadsOnDeviceAndKeepsEverything() throws {
        // A file saved with the cloud demo chosen, its own open conversation, and its brief.
        var old = SavedState()
        old.messages = [.init(role: "You", text: "On-device chat")]
        old.memories = [.init(text: "Likes hiking")]
        old.conversationArchives = [.init(model: "Apple on-device", recipient: nil, messages: [.init(role: "You", text: "Saved chat")])]
        let onDevice = UUID(), cloud = UUID()
        old.openConversations = ["onDevice": .init(id: onDevice), "managed": .init(id: cloud, date: Date(timeIntervalSince1970: 1_790_000_000), privacy: .open)]
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        object["modelRoute"] = "managed"
        object["managedMessages"] = [["id": UUID().uuidString, "role": "You", "text": "Cloud question", "date": 0, "contextRevision": 3],
                                     ["id": UUID().uuidString, "role": "KemoSabe", "text": "Cloud answer", "date": 1]]
        object["managedSharedBrief"] = "brief"
        object["managedRecipientID"] = "abc"
        try JSONSerialization.data(withJSONObject: object).write(to: repository.url)

        let store = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertNil(store.storageError)
        XCTAssertEqual(store.state.modelRoute, .onDevice, "The removed route reads as on-device")
        XCTAssertEqual(store.modelRoute, .onDevice)
        XCTAssertEqual(store.conversationMessages.map(\.text), ["On-device chat"])
        XCTAssertEqual(store.state.memories.map(\.text), ["Likes hiking"])
        XCTAssertEqual(store.state.openConversations?["onDevice"]?.id, onDevice)
        XCTAssertNil(store.state.openConversations?["managed"])
        // The cloud demo's conversation is in the list, under the ID it had, read-only.
        let archives = try XCTUnwrap(store.state.conversationArchives)
        XCTAssertEqual(archives.map(\.messages.first?.text), ["Saved chat", "Cloud question"])
        let kept = try XCTUnwrap(archives.last)
        XCTAssertEqual(kept.id, cloud); XCTAssertEqual(kept.model, "KemoSabe cloud"); XCTAssertEqual(kept.privacy, .open)
        XCTAssertEqual(kept.date, Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(kept.messages.map(\.text), ["Cloud question", "Cloud answer"])
        XCTAssertNil(kept.messages.first?.contextRevision)
        XCTAssertFalse(store.canResume(kept))
        XCTAssertTrue(store.canResume(archives[0]))

        // Saved once, the old fields are gone, and reading again doesn't add it twice.
        store.save()
        let saved = String(decoding: try Data(contentsOf: repository.url), as: UTF8.self)
        XCTAssertFalse(saved.contains("managed"), saved)
        XCTAssertEqual(try repository.read().conversationArchives?.count, 2)
        XCTAssertEqual(try repository.read().conversationArchives?.last?.id, cloud)
    }

    func testAnUnknownModelRouteReadsAsOnDevice() throws {
        let data = Data(#"{"theme":{"id":"cream","name":"Cream","body":"FFF6E8","accent":"F28C6B","background":"FFFFFF"},"memories":[],"messages":[],"standupFormat":"x","onboarded":true,"modelRoute":"somethingNew"}"#.utf8)
        try data.write(to: repository.url)
        let state = try repository.read()
        XCTAssertEqual(state.modelRoute, .onDevice)
        XCTAssertTrue(state.onboarded)
    }

    func testANewerFormatIsRefusedAndNeverOverwritten() throws {
        var newer = SavedState(); newer.schemaVersion = LocalRepository.schemaVersion + 1
        let data = try JSONEncoder().encode(newer)
        try data.write(to: repository.url)
        XCTAssertThrowsError(try repository.read()) { XCTAssertEqual($0 as? LocalRepositoryError, .newerSchema(LocalRepository.schemaVersion + 1)) }
        let store = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertEqual(store.storageError, AppStore.newerSchemaMessage)
        store.createProject("Should not save")
        store.save()
        XCTAssertEqual(try Data(contentsOf: repository.url), data)
    }
    func testDeletingAChatForgetsItsContinuityNotes() async throws {
        let store = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let ledger = store.proposalLedger
        let now = Date()
        try await ledger.observeConversation(id: UUID(), text: "My sister Maya visits on Friday", now: now)
        try await ledger.observeConversation(id: UUID(), text: "I'm training for a half marathon", now: now)
        store.state.conversationArchives = [ConversationArchive(model: "Apple on-device", recipient: nil,
            messages: [ChatMessage(role: "You", text: "My sister Maya visits on Friday"), ChatMessage(role: "KemoSabe", text: "Noted.")])]
        store.save()
        store.deleteArchivedConversation(store.state.conversationArchives![0].id)
        await store.finishForgetting()
        let notes = try await ledger.snapshot().context?.observations.map(\.text) ?? []
        XCTAssertEqual(notes, ["I'm training for a half marathon"])
        XCTAssertNil(store.state.pendingContextForgets)
        XCTAssertFalse(String(decoding: try Data(contentsOf: repository.url), as: UTF8.self).contains("Maya"), "Nothing pending keeps the deleted words")
    }
    func testAnInterruptedDeletionFinishesOnTheNextLaunch() async throws {
        let first = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        try await first.proposalLedger.observeConversation(id: UUID(), text: "Remember the gate code", now: Date())
        // The app stopped after the chat was deleted but before its notes were forgotten.
        first.state.pendingContextForgets = [ContextForgetting.digest("Remember the gate code")]
        first.save()
        let relaunched = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        await relaunched.finishForgetting()
        let notes = try await relaunched.proposalLedger.snapshot().context?.observations ?? []
        XCTAssertTrue(notes.isEmpty)
        XCTAssertNil(relaunched.state.pendingContextForgets)
    }
    func testDeletingEverythingForgetsEveryConversationNote() async throws {
        let store = AppStore(repository: repository, provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        try await store.proposalLedger.observeConversation(id: UUID(), text: "One", now: Date())
        try await store.proposalLedger.recordBedtime(Date())
        store.clearConversation()
        await store.finishForgetting()
        let notes = try await store.proposalLedger.snapshot().context?.observations ?? []
        XCTAssertEqual(notes.map(\.kind), [.reportedBedtime], "Only conversation notes go; explicit routine reports have their own control")
    }
}
