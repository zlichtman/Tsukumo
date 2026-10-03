import XCTest
@testable import KemoSabe

/// Watch requests while the iPhone is locked (the owner's instruction, September 25, 2026).
/// "Locked" is simulated with `LockedWatchMode.protectedDataAvailable`.
@MainActor final class WatchLockedModeTests: XCTestCase {
    private var root: URL!
    private var locked = false
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchLockedModeTests-" + UUID().uuidString)
        locked = false
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    private func mode(keys: any APIKeyStoring = MemoryAPIKeys()) -> LockedWatchMode {
        let folder = root.appendingPathComponent("watch-locked")
        return LockedWatchMode(folder: { folder }, keys: keys, protectedDataAvailable: { [unowned self] in !self.locked })
    }
    private func profile(_ name: String) throws -> APIModelProfile {
        try APIModelProfile.validated(name: name, endpoint: "https://\(name.lowercased()).example/v1/chat/completions", model: name)
    }

    func testProtectionClasses() throws {
        // Only the tiny working set is readable after first unlock; the inbox can be written
        // while locked but read only after unlock; everything else stays complete.
        XCTAssertEqual(LockedWatchMode.workingSetProtection, .completeFileProtectionUntilFirstUserAuthentication)
        XCTAssertEqual(LockedWatchMode.inboxProtection, .completeFileProtectionUnlessOpen)
        let watch = mode()
        watch.refresh(route: .onDevice, profile: nil, allProfiles: [])
        let workingSet = root.appendingPathComponent("watch-locked/working-set.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: workingSet.path))
        let state = root.appendingPathComponent("state.json")
        try LocalRepository(url: state).save(SavedState())
        // The simulator records protection classes when it reports them at all; a device always does.
        if let recorded = try FileManager.default.attributesOfItem(atPath: workingSet.path)[.protectionKey] as? FileProtectionType {
            XCTAssertEqual(recorded, .completeUntilFirstUserAuthentication)
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: state.path)[.protectionKey] as? FileProtectionType, .complete,
                           "Chats and memories keep complete protection")
        }
        // The working set names the model, never a key, a chat, or a memory.
        let text = String(decoding: try Data(contentsOf: workingSet), as: UTF8.self)
        XCTAssertEqual(text, #"{"route":"onDevice"}"#)
    }

    func testWorkingSetFollowsTheSelectedModel() throws {
        let watch = mode()
        let connected = try profile("Claude")
        watch.refresh(route: .api, profile: connected, allProfiles: [connected])
        XCTAssertEqual(watch.workingSet, .init(route: .api, profile: connected))
        watch.refresh(route: .onDevice, profile: nil, allProfiles: [connected])
        XCTAssertEqual(watch.workingSet, .init(route: .onDevice))
        watch.refresh(route: .onDevice, profile: nil, allProfiles: [])
        watch.clear(allProfiles: [])
        XCTAssertNil(watch.workingSet)
    }

    func testLockedAnswerUsesOnlyTheSelectedConnectionWithoutHistory() async throws {
        let keys = MemoryAPIKeys()
        let connected = try profile("Claude")
        keys.keys[connected.id] = "sk-test"
        let watch = mode(keys: keys)
        watch.refresh(route: .api, profile: connected, allProfiles: [connected])
        locked = true
        XCTAssertTrue(watch.isLocked)
        var sent: [(APIModelProfile, String, String)] = []
        watch.apiReply = { profile, key, message in sent.append((profile, key, message)); return " Four. " }
        watch.onDeviceReply = { _ in XCTFail("The on-device model isn't the selected one"); return "" }
        let outcome = await watch.answer("What's two plus two?", capture: false)
        XCTAssertEqual(outcome, .answered("Four."))
        XCTAssertEqual(sent.map(\.0), [connected]); XCTAssertEqual(sent.map(\.1), ["sk-test"]); XCTAssertEqual(sent.map(\.2), ["What's two plus two?"])
        locked = false
        XCTAssertEqual(watch.inbox.map(\.reply), ["Four."])
        XCTAssertEqual(watch.inbox.first?.route, .api)
        XCTAssertEqual(watch.inbox.first?.profileID, connected.id)
        // A connection that fails says so in one line.
        locked = true
        watch.apiReply = { _, _, _ in throw APIModelError.configuration }
        let failure = await watch.answer("Hello", capture: false)
        XCTAssertEqual(failure, .failed("Claude didn't answer. Try again."))
        // A key that isn't readable while locked asks to unlock rather than failing silently.
        keys.keys = [:]
        let noKey = await watch.answer("Hello", capture: false)
        XCTAssertEqual(noKey, .failed(LockedWatchMode.unlockToAnswer))
    }

    func testOnDeviceModelThatWontRunWhileLockedAsksToUnlock() async {
        let watch = mode()
        watch.refresh(route: .onDevice, profile: nil, allProfiles: [])
        locked = true
        watch.apiReply = { _, _, _ in XCTFail("Never falls back to another destination"); return "" }
        watch.onDeviceAvailable = { false }
        let unavailable = await watch.answer("Hi Kemo", capture: false)
        XCTAssertEqual(unavailable, .failed(LockedWatchMode.unlockToAnswer))
        watch.onDeviceAvailable = { true }
        watch.onDeviceReply = { _ in throw CancellationError() }
        let refused = await watch.answer("Hi Kemo", capture: false)
        XCTAssertEqual(refused, .failed(LockedWatchMode.unlockToAnswer))
        watch.onDeviceReply = { _ in "Hi! What's up?" }
        let answered = await watch.answer("Hi Kemo", capture: false)
        XCTAssertEqual(answered, .answered("Hi! What's up?"))
        locked = false
        XCTAssertEqual(watch.inbox.count, 1, "Only the answered exchange is kept")
    }

    func testWithoutAWorkingSetAsksToUnlock() async {
        let watch = mode()
        locked = true
        let outcome = await watch.answer("Hi", capture: false)
        XCTAssertEqual(outcome, .failed(LockedWatchMode.unlockToAnswer))
    }

    func testRemindersNotesAndCapturesWaitForUnlock() async {
        let watch = mode()
        watch.refresh(route: .onDevice, profile: nil, allProfiles: [])
        locked = true
        watch.onDeviceAvailable = { true }
        watch.onDeviceReply = { _ in XCTFail("No model claims a reminder it can't set"); return "" }
        let reminder = await watch.answer("Remind me to call Mom at 5", capture: false)
        XCTAssertEqual(reminder, .answered(LockedWatchMode.waitsForUnlock))
        let capture = await watch.answer("Buy oat milk tomorrow", capture: true)
        XCTAssertEqual(capture, .answered(LockedWatchMode.waitsForUnlock))
        locked = false
        XCTAssertEqual(watch.inbox.map(\.request), ["Remind me to call Mom at 5", "Add this as a reminder: Buy oat milk tomorrow"])
        XCTAssertTrue(watch.inbox.allSatisfy { $0.reply == nil && $0.route == nil })
    }

    func testAfterUnlockExchangesJoinTheAnsweringModelsConversationOnly() async throws {
        let store = AppStore(repository: .init(url: root.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let first = try profile("First"), second = try profile("Second")
        try store.addAPIProfile(first, key: "k1"); try store.addAPIProfile(second, key: "k2")
        store.state.messages = [.init(role: "You", text: "Earlier local chat")]
        let keys = MemoryAPIKeys(); keys.keys[first.id] = "k1"
        let watch = mode(keys: keys)
        watch.apiReply = { _, _, _ in "From First" }
        watch.onDeviceAvailable = { true }
        watch.onDeviceReply = { _ in "From on-device" }
        watch.refresh(route: .api, profile: first, allProfiles: [first, second])
        locked = true
        _ = await watch.answer("Question for First", capture: false)
        _ = await watch.answer("Remember that I like tea", capture: false)
        locked = false
        watch.refresh(route: .onDevice, profile: nil, allProfiles: [first, second])
        locked = true
        _ = await watch.answer("Question on device", capture: false)
        // Nothing moves while still locked.
        XCTAssertEqual(watch.importAnswered(into: store), [])
        locked = false
        let waiting = watch.importAnswered(into: store)
        XCTAssertEqual(waiting.map(\.request), ["Remember that I like tea"], "Requests that waited run through the full harness")
        XCTAssertEqual(store.state.apiConversations?[first.id.uuidString]?.map(\.text), ["Question for First", "From First"])
        XCTAssertEqual(store.state.apiConversations?[second.id.uuidString] ?? [], [], "Never another model's conversation")
        XCTAssertEqual(store.state.messages.map(\.text), ["Earlier local chat", "Question on device", "From on-device"])
        XCTAssertEqual(watch.inbox.count, 1, "Imported exchanges are deleted; the waiting one stays until it runs")
        // Saved: a reopened store has the exchanges.
        let reopened = AppStore(repository: .init(url: root.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertEqual(reopened.state.messages.last?.text, "From on-device")
        watch.remove(waiting[0])
        XCTAssertTrue(watch.inbox.isEmpty)
    }

    func testOnlyTheSelectedKeyIsReadableAfterFirstUnlock() throws {
        let keychain = KeychainAPIKeys()
        let selected = UUID(), other = UUID()
        do { try keychain.save("sk-selected", for: selected); try keychain.save("sk-other", for: other) }
        catch { throw XCTSkip("The Keychain isn't available to this test host.") }
        defer { try? keychain.remove(selected); try? keychain.remove(other) }
        let afterFirstUnlock = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        let whenUnlocked = kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String
        XCTAssertEqual(keychain.accessibility(selected), whenUnlocked, "Keys start readable only while unlocked")
        keychain.allowLockedUse(of: selected, among: [selected, other])
        XCTAssertEqual(keychain.accessibility(selected), afterFirstUnlock)
        XCTAssertEqual(keychain.accessibility(other), whenUnlocked)
        XCTAssertEqual(try keychain.read(selected), "sk-selected")
        // Switching away (or unpairing the watch) returns every key to unlocked-only.
        keychain.allowLockedUse(of: nil, among: [selected, other])
        XCTAssertEqual(keychain.accessibility(selected), whenUnlocked)
        XCTAssertEqual(keychain.accessibility(other), whenUnlocked)
    }
}
