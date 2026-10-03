import CloudKit
import XCTest
@testable import KemoSabe

/// A cloud database in memory that behaves like CloudKit's private database where it matters:
/// saves are conditional on the version they started from, changes come in order since a token,
/// and the account, quota, zone, and token can all fail.
actor FakeCloudDatabase: CloudDatabase {
    private(set) var user = "icloud-user-a"
    var status: CloudAccountStatus = .available
    private(set) var zones: [String: [String: CloudRecord]] = [:]
    private var log: [(zone: String, name: String)] = []
    private var failSave: CloudFailure?, failChanges: CloudFailure?
    var maxBatch = Int.max, pageSize = Int.max
    private(set) var saveRequests = 0
    func signIn(_ user: String) { self.user = user }
    func setStatus(_ status: CloudAccountStatus) { self.status = status }
    func failNextSave(_ failure: CloudFailure) { failSave = failure }
    func failNextChanges(_ failure: CloudFailure) { failChanges = failure }
    func limit(batch: Int = .max, page: Int = .max) { maxBatch = batch; pageSize = page }
    func deleteZone(_ zone: String) { zones[zone] = nil; log.removeAll { $0.zone == zone } }
    func record(_ name: String, in zone: String) -> CloudRecord? { zones[zone]?[name] }
    /// Another device (with its own tag) changes a record on the server.
    func serverEdit(_ record: CloudRecord, in zone: String) {
        var saved = record; saved.tag = Data(UUID().uuidString.utf8)
        zones[zone, default: [:]][record.name] = saved; log.append((zone, record.name))
    }

    func accountStatus() async throws -> CloudAccountStatus { status }
    func userRecordName() async throws -> String { user }
    func ensureZone(_ zone: String) async throws { if zones[zone] == nil { zones[zone] = [:] } }
    func subscribe(zone: String) async throws {}
    func save(_ records: [CloudRecord], zone: String) async throws -> [String: CloudSaveResult] {
        if let failure = failSave { failSave = nil; throw failure }
        guard zones[zone] != nil else { throw CloudFailure.zoneNotFound }
        if records.count > maxBatch { throw CloudFailure.tooLarge }
        saveRequests += 1
        var results: [String: CloudSaveResult] = [:]
        for record in records {
            if let current = zones[zone]?[record.name], current.tag != record.tag {
                results[record.name] = .conflict(server: current); continue
            }
            var saved = record; saved.tag = Data(UUID().uuidString.utf8)
            zones[zone]?[record.name] = saved; log.append((zone, record.name))
            results[record.name] = .saved(saved)
        }
        return results
    }
    func changes(zone: String, since token: Data?) async throws -> CloudChanges {
        if let failure = failChanges { failChanges = nil; throw failure }
        guard let records = zones[zone] else { throw CloudFailure.zoneNotFound }
        let start = token.flatMap { Int(String(decoding: $0, as: UTF8.self)) } ?? 0
        guard start <= log.count else { throw CloudFailure.tokenExpired }
        let end = pageSize >= log.count ? log.count : min(log.count, start + pageSize)
        var names: [String] = []
        for entry in log[start..<end] where entry.zone == zone { names.removeAll { $0 == entry.name }; names.append(entry.name) }
        return CloudChanges(records: names.compactMap { records[$0] }, deleted: [], token: Data(String(end).utf8), moreComing: end < log.count)
    }
}

@MainActor final class CloudSyncTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory
    private let accountID = "apple-0123456789abcdef0123456789abcdef"
    private var zone: String { "personal-" + accountID }
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("CloudSyncTests-" + UUID().uuidString, isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    /// One device: its own store, synced copy, transport (with its own view of the server), and sync service.
    struct Device {
        let store: AppStore
        let engine: SyncEngine
        let transport: CloudKitSyncTransport
        let service: AccountSyncService
    }
    private func device(_ name: String, database: FakeCloudDatabase, extra: [SyncAdapter] = []) throws -> Device {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let transport = CloudKitSyncTransport(database: database, accountID: accountID, bindingURL: folder.appendingPathComponent("Sync/icloud.json"), subscribes: false)
        let engine = SyncEngine(transport: transport, device: name, url: folder.appendingPathComponent("Sync/records.json"))
        let records = AccountRecords(engine: engine)
        let service = AccountSyncService(records: { records }, defaults: try suite("cloud-sync-tests-"), available: true)
        service.attach([AppStoreSyncAdapter(store: store)] + extra, startSync: false)
        return Device(store: store, engine: engine, transport: transport, service: service)
    }
    private func sync(_ devices: Device...) async {
        for device in devices {
            await device.service.syncNow()
            XCTAssertEqual(device.service.phase, .idle, "\(device.engine.device): \(device.service.phase)")
        }
    }
    private func suite(_ prefix: String) throws -> UserDefaults { try XCTUnwrap(UserDefaults(suiteName: prefix + UUID().uuidString)) }
    private func message(_ text: String, role: String = "You") -> ChatMessage { ChatMessage(role: role, text: text) }

    // MARK: Two devices

    func testTwoDevicesConvergeOnConversationsMemoriesDraftsProjectsAndPeople() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud), mac = try device("mac", database: cloud)
        let project = try XCTUnwrap(phone.store.createProject("Trip"))
        phone.store.appendVisibleMessage(role: "You", text: "Plan my trip to Lisbon")
        phone.store.newConversation(in: project.id)
        phone.store.appendVisibleMessage(role: "You", text: "What should I pack?")
        phone.store.saveMemory(MemoryNote(text: "Prefers window seats"))
        phone.store.state.workItems = [WorkItem(title: "Standup", status: "Needs review", draft: "Yesterday: sync")]
        phone.store.save()
        try phone.store.updatePeople { try $0.add(PeopleSource(kind: .note, label: "Met at WWDC", fields: [.init(kind: .name, value: "Maya")]), to: nil) }

        await sync(phone, mac)

        XCTAssertEqual(mac.store.state.memories.map(\.text), ["Prefers window seats"])
        XCTAssertEqual(mac.store.state.workItems?.map(\.draft), ["Yesterday: sync"])
        XCTAssertEqual(mac.store.state.conversationProjects?.map(\.name), ["Trip"])
        XCTAssertEqual(mac.store.state.people?.profiles.map(\.name), ["Maya"])
        let archives = mac.store.state.conversationArchives ?? []
        XCTAssertEqual(Set(archives.map { $0.messages.first?.text ?? "" }), ["Plan my trip to Lisbon", "What should I pack?"],
                       "The saved conversation and the one open on the iPhone both show on the Mac")
        let open = try XCTUnwrap(phone.store.state.openConversations?["onDevice"]?.id)
        XCTAssertTrue(archives.contains { $0.id == open }, "An open conversation keeps one ID everywhere")
        XCTAssertTrue(archives.flatMap(\.messages).allSatisfy { $0.contextRevision == nil }, "Context revisions stay on each device")

        // Continuing the iPhone's conversation on the Mac keeps it one conversation.
        mac.store.resumeArchivedConversation(open)
        mac.store.appendVisibleMessage(role: "Kemo", text: "A light jacket.")
        await sync(mac, phone)
        XCTAssertEqual(phone.store.state.messages.map(\.text), ["What should I pack?", "A light jacket."])
        let arrived = try XCTUnwrap(phone.store.state.messages.last)
        XCTAssertEqual(arrived.contextRevision, phone.store.state.contextRevision ?? 0,
                       "A message that arrives in an open conversation joins this device's current context")
        await sync(phone, mac)
        XCTAssertEqual(mac.engine.state.outbox.count, 0)
        XCTAssertEqual(phone.engine.state.outbox.count, 0, "Converged: nothing bounces back and forth")
    }

    func testDeletesPropagateBothWays() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud), mac = try device("mac", database: cloud)
        let note = MemoryNote(text: "Allergic to peanuts")
        phone.store.saveMemory(note)
        phone.store.appendVisibleMessage(role: "You", text: "Old chat")
        phone.store.newConversation()
        let chat = try XCTUnwrap(phone.store.state.conversationArchives?.first?.id)
        await sync(phone, mac)
        XCTAssertEqual(mac.store.state.memories.count, 1)

        phone.store.deleteMemory(note.id)
        mac.store.deleteArchivedConversation(chat)
        await sync(phone, mac, phone)
        XCTAssertTrue(mac.store.state.memories.isEmpty, "A memory deleted on the iPhone is deleted on the Mac")
        XCTAssertTrue(phone.store.state.conversationArchives?.isEmpty ?? true, "A chat deleted on the Mac is deleted on the iPhone")
        let tombstone = await cloud.record("memory-" + note.id.uuidString, in: zone)
        XCTAssertEqual(tombstone?.deleted, true, "Deletions are tombstones, so a device that was offline can't bring it back")
    }

    func testConflictsResolveAndConverge() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud), mac = try device("mac", database: cloud)
        var note = MemoryNote(text: "Coffee: oat latte")
        phone.store.saveMemory(note)
        await sync(phone, mac)

        // Both edit before either syncs: the later sync's edit wins, and both end up with it.
        note.text = "Coffee: flat white"; phone.store.saveMemory(note)
        var macNote = note; macNote.text = "Coffee: cortado"; mac.store.saveMemory(macNote)
        await sync(phone, mac, phone)
        XCTAssertEqual(phone.store.state.memories.map(\.text), ["Coffee: cortado"])
        XCTAssertEqual(mac.store.state.memories.map(\.text), ["Coffee: cortado"])

        // An edit beats a deletion made at the same time.
        phone.store.deleteMemory(note.id)
        macNote.text = "Coffee: espresso"; mac.store.saveMemory(macNote)
        await sync(phone, mac, phone)
        XCTAssertEqual(phone.store.state.memories.map(\.text), ["Coffee: espresso"])
        XCTAssertEqual(mac.store.state.memories.map(\.text), ["Coffee: espresso"])
    }

    func testTheServerKeepsTheNewerEditWhenDevicesRace() async throws {
        let cloud = FakeCloudDatabase()
        let transport = CloudKitSyncTransport(database: cloud, accountID: accountID, bindingURL: nil, subscribes: false)
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        func record(_ text: String, at date: Date, device: String) -> SyncRecord {
            SyncRecord(id: "memory-x", type: SyncType.memory, zone: .personal, modified: date, device: device, payload: Data(text.utf8))
        }
        try await transport.push([record("first", at: t0, device: "phone")])
        await cloud.serverEdit(CloudRecord(name: "memory-x", type: SyncType.memory, modified: t0 + 20, device: "mac", deleted: false, payload: Data("newer".utf8)), in: zone)
        // An older edit arriving late never replaces the newer one on the server...
        try await transport.push([record("older", at: t0 + 10, device: "phone")])
        var stored = await cloud.record("memory-x", in: zone)
        XCTAssertEqual(stored?.payload, Data("newer".utf8))
        // ...and a newer one replaces it after a conflict, without a pull in between.
        try await transport.push([record("newest", at: t0 + 30, device: "phone")])
        stored = await cloud.record("memory-x", in: zone)
        XCTAssertEqual(stored?.payload, Data("newest".utf8))
    }

    // MARK: Joining and migration

    func testExistingLocalDataGoesIntoTheFirstSync() async throws {
        let cloud = FakeCloudDatabase()
        // Data saved before sync existed: no conversation IDs, an open chat, saved chats, and memories.
        let folder = root.appendingPathComponent("phone", isDirectory: true)
        var saved = SavedState()
        saved.memories = [MemoryNote(text: "Lives in Brooklyn"), MemoryNote(text: "Runs on Sundays")]
        saved.messages = [message("Hi"), message("Hello!", role: "Kemo")]
        saved.conversationArchives = [ConversationArchive(model: "Apple on-device", recipient: nil, messages: [message("An older chat")])]
        try LocalRepository(url: folder.appendingPathComponent("state.json")).save(saved)

        let phone = try device("phone", database: cloud)
        XCTAssertNil(phone.store.state.openConversations)
        await sync(phone)
        let names = Set(await cloud.zones[zone]?.keys.map { $0 } ?? [])
        XCTAssertEqual(names.filter { $0.hasPrefix("memory-") }.count, 2)
        XCTAssertEqual(names.filter { $0.hasPrefix("conversation-") }.count, 2, "The open chat and the saved one")

        let mac = try device("mac", database: cloud)
        await sync(mac)
        XCTAssertEqual(Set(mac.store.state.memories.map(\.text)), ["Lives in Brooklyn", "Runs on Sundays"])
        XCTAssertEqual(mac.store.state.conversationArchives?.count, 2)
    }

    func testAJoiningDeviceTakesTheAccountsValuesInsteadOfOverwritingThem() async throws {
        let cloud = FakeCloudDatabase()
        let phoneSettings = try suite("cloud-sync-phone-")
        let macSettings = try suite("cloud-sync-mac-")
        let characters = try JSONEncoder().encode([CompanionCharacter(id: UUID(), name: "Mochi", theme: BotTheme.presets[1])])
        phoneSettings.set(true, forKey: CompanionIdentity.namedKey)
        phoneSettings.set(characters, forKey: CompanionCharacters.key)
        macSettings.set(false, forKey: CompanionIdentity.namedKey)   // a fresh Mac that hasn't been set up
        let phone = try device("phone", database: cloud, extra: [AccountSettingsAdapter(defaults: { phoneSettings }, accountID: nil)])
        await sync(phone)
        let mac = try device("mac", database: cloud, extra: [AccountSettingsAdapter(defaults: { macSettings }, accountID: nil)])
        await sync(mac, phone)
        XCTAssertTrue(macSettings.bool(forKey: CompanionIdentity.namedKey), "The Mac takes the account's value when it first joins")
        XCTAssertEqual(macSettings.data(forKey: CompanionCharacters.key), characters)
        XCTAssertTrue(phoneSettings.bool(forKey: CompanionIdentity.namedKey), "and never overwrites the account's with its defaults")
    }

    // MARK: Safety

    func testPrivateTypesNeverEnterASharedZone() async throws {
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "mac")
        for type in [SyncType.draft, SyncType.chatProject, SyncType.setting, SyncType.conversation, SyncType.memory, SyncType.peopleNote, SyncType.companion, SyncType.account] {
            XCTAssertThrowsError(try engine.putPayload(Data(), id: "x", type: type, zone: .shared(project: "p"))) {
                XCTAssertEqual($0 as? SyncError, .privateInSharedZone(type))
            }
        }
        // The CloudKit transport carries only the personal zone; anything shared stays queued for a
        // transport that handles shares, and never lands in the personal database.
        let cloud = FakeCloudDatabase()
        let transport = CloudKitSyncTransport(database: cloud, accountID: accountID, bindingURL: nil, subscribes: false)
        let mixed = SyncEngine(transport: transport, device: "mac")
        try mixed.put("task", id: "t", type: SyncType.collabTask, zone: .shared(project: "p"))
        try mixed.put("note", id: "m", type: SyncType.memory, zone: .personal)
        try await mixed.sync()
        let names = Set(await cloud.zones[zone]?.keys.map { $0 } ?? [])
        XCTAssertEqual(names, ["m"])
        XCTAssertNotNil(mixed.state.outbox["project-p/t"], "The shared record waits for a shared transport")
    }

    func testADifferentICloudAccountIsRefusedUntilThePersonChooses() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud)
        phone.store.saveMemory(MemoryNote(text: "Zach's memory"))
        await sync(phone)
        let binding = try await phone.transport.binding()
        XCTAssertEqual(binding?.userRecordName, "icloud-user-a")

        // Someone else signs in to iCloud on this iPhone.
        await cloud.signIn("icloud-user-b")
        await phone.transport.accountChanged()
        phone.store.saveMemory(MemoryNote(text: "Written after the change"))
        await phone.service.syncNow()
        XCTAssertEqual(phone.service.phase, .mismatch)
        let sent = await cloud.zones[zone]?.count
        XCTAssertEqual(sent, 2, "Nothing more was sent to the other person's iCloud (the memory and the preferences record)")
        XCTAssertFalse(phone.service.statusDetail?.isEmpty ?? true)
        await phone.service.syncNow()
        XCTAssertEqual(phone.service.phase, .mismatch, "It stays paused on its own")

        // The person chooses to use this iCloud account: everything goes there, nothing is deleted.
        await phone.service.useThisICloudAccount()
        XCTAssertEqual(phone.service.phase, .idle)
        let rebound = try await phone.transport.binding()
        XCTAssertEqual(rebound?.userRecordName, "icloud-user-b")
        XCTAssertEqual(phone.store.state.memories.count, 2)
    }

    func testICloudProblemsAreReportedAndNothingIsLost() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud)
        await cloud.setStatus(.noAccount)
        phone.store.saveMemory(MemoryNote(text: "Kept"))
        await phone.service.syncNow()
        XCTAssertEqual(phone.service.phase, .failed("Sign in to iCloud in Settings to sync."))

        await cloud.setStatus(.available)
        await phone.transport.accountChanged()
        await cloud.failNextSave(.quotaExceeded)
        await phone.service.syncNow()
        XCTAssertEqual(phone.service.phase, .failed(AccountSyncService.message(.quotaExceeded)))
        XCTAssertFalse(phone.engine.state.outbox.isEmpty, "Unsent changes stay queued")

        await cloud.failNextSave(.network(retryAfter: 5))
        await phone.service.syncNow()
        if case .failed = phone.service.phase {} else { XCTFail("A network error is reported") }

        await sync(phone)
        XCTAssertTrue(phone.engine.state.outbox.isEmpty)
        let count = await cloud.zones[zone]?.count
        XCTAssertEqual(count, 2, "The memory and the preferences record")
    }

    func testALostZoneIsSentAgainAndOldTokensStartOver() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud), mac = try device("mac", database: cloud)
        for text in ["one", "two", "three"] { phone.store.saveMemory(MemoryNote(text: text)) }
        await sync(phone)
        // The person deleted the app's iCloud data in Settings.
        await cloud.deleteZone(zone)
        await phone.service.syncNow()
        XCTAssertEqual(phone.service.phase, .failed(AccountSyncService.message(.resetRequired)))
        // Requests iCloud finds too large are split; changes arrive a page at a time.
        await cloud.limit(batch: 2, page: 1)
        await sync(phone)
        let count = await cloud.zones[zone]?.count
        XCTAssertEqual(count, 4, "Everything on the iPhone was sent again (three memories and the preferences record)")

        await cloud.failNextChanges(.tokenExpired)
        await sync(mac)
        XCTAssertEqual(Set(mac.store.state.memories.map(\.text)), ["one", "two", "three"], "Paged changes and large batches still arrive")
    }

    func testAStoreThatIsntOpenNeverLooksDeleted() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud)
        phone.store.saveMemory(MemoryNote(text: "Precious"))
        await sync(phone)
        // The same account's data can't be read (a locked iPhone, a damaged file).
        let folder = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("state.json"))
        let locked = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertTrue(locked.failedToLoad)
        XCTAssertNil(AppStoreSyncAdapter(store: locked).snapshot())
        let result = try phone.engine.reconcile(AppStoreSyncAdapter(store: locked))
        XCTAssertEqual(result, ReconcileResult())
        XCTAssertTrue(phone.engine.state.outbox.isEmpty, "No tombstones")

        // Unreadable synced state is never replaced by an empty copy.
        let records = root.appendingPathComponent("unreadable/records.json")
        try FileManager.default.createDirectory(at: records.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("garbage".utf8).write(to: records)
        let engine = SyncEngine(transport: MemorySyncTransport(), device: "x", url: records)
        XCTAssertTrue(engine.unreadable)
        XCTAssertThrowsError(try engine.put("x", id: "m", type: SyncType.memory, zone: .personal)) { XCTAssertEqual($0 as? SyncError, .stateUnreadable) }
        XCTAssertEqual(try Data(contentsOf: records), Data("garbage".utf8))
    }

    func testAccountNameAndHandleSync() async throws {
        let cloud = FakeCloudDatabase()
        let phoneAccount = AccountStore(defaults: try suite("cloud-sync-account-"), cloud: nil)
        let macAccount = AccountStore(defaults: try suite("cloud-sync-account-"), cloud: nil)
        phoneAccount.update { $0.name = "Zach"; $0.handle = "zach"; $0.email = "hidden@privaterelay.appleid.com" }
        let phone = try device("phone", database: cloud, extra: [AccountSyncAdapter(account: phoneAccount)])
        await sync(phone)
        let mac = try device("mac", database: cloud, extra: [AccountSyncAdapter(account: macAccount)])
        await sync(mac)
        XCTAssertEqual(macAccount.account.name, "Zach")
        XCTAssertEqual(macAccount.account.handle, "zach")
        XCTAssertNil(macAccount.account.email, "The email never syncs")
        let payloads = await cloud.zones[zone]?.values.map { String(decoding: $0.payload, as: UTF8.self) } ?? []
        XCTAssertFalse(payloads.contains { $0.contains("privaterelay") })
    }

    // MARK: CloudKit records

    func testCloudKitRecordsKeepEveryFieldEncryptedAndLargePayloadsAsAssets() throws {
        let zoneID = CKCloudDatabase.zoneID(zone)
        let small = CloudRecord(name: "memory-1", type: SyncType.memory, modified: Date(timeIntervalSince1970: 1_790_000_000), device: "phone",
                                deleted: false, payload: Data(#"{"text":"hi"}"#.utf8), tag: nil)
        var files: [URL] = []
        let record = try CKCloudDatabase.makeRecord(small, zone: zoneID, files: &files)
        XCTAssertEqual(record.recordType, CKCloudDatabase.recordType)
        XCTAssertEqual(record.recordID.zoneID.zoneName, zone)
        XCTAssertEqual(record.encryptedValues["type"] as? String, SyncType.memory)
        XCTAssertEqual(record.encryptedValues["payload"] as? Data, small.payload)
        XCTAssertEqual(record.encryptedValues["device"] as? String, "phone")
        XCTAssertEqual(record.encryptedValues["modified"] as? Date, small.modified)
        var back = try CKCloudDatabase.cloudRecord(record)
        back.tag = nil
        XCTAssertEqual(back, small)

        let large = CloudRecord(name: "conversation-1", type: SyncType.conversation, modified: small.modified, device: "mac", deleted: false,
                                payload: Data(repeating: 7, count: CKCloudDatabase.inlineLimit + 1), tag: nil)
        let assetRecord = try CKCloudDatabase.makeRecord(large, zone: zoneID, files: &files)
        XCTAssertNil(assetRecord.encryptedValues["payload"] as? Data)
        XCTAssertNotNil(assetRecord["payloadAsset"] as? CKAsset)
        XCTAssertEqual(try CKCloudDatabase.cloudRecord(assetRecord).payload, large.payload)
        for file in files { try? FileManager.default.removeItem(at: file) }

        // A saved record's version comes back as its system fields, and restores the same record.
        let tag = CKCloudDatabase.systemFields(record)
        let restored = try CKCloudDatabase.makeRecord(CloudRecord(name: "memory-1", type: SyncType.memory, modified: small.modified, device: "phone",
                                                                  deleted: true, payload: Data(), tag: tag), zone: zoneID, files: &files)
        XCTAssertEqual(restored.recordID, record.recordID)
        XCTAssertEqual(restored.encryptedValues["deleted"] as? Int64, 1)
    }

    func testCloudKitErrorsMapToWhatThePersonSees() {
        XCTAssertEqual(CKCloudDatabase.failure(CKError(.quotaExceeded)), .quotaExceeded)
        XCTAssertEqual(CKCloudDatabase.failure(CKError(.zoneNotFound)), .zoneNotFound)
        XCTAssertEqual(CKCloudDatabase.failure(CKError(.userDeletedZone)), .zoneNotFound)
        XCTAssertEqual(CKCloudDatabase.failure(CKError(.changeTokenExpired)), .tokenExpired)
        XCTAssertEqual(CKCloudDatabase.failure(CKError(.notAuthenticated)), .notAuthenticated)
        XCTAssertEqual(CKCloudDatabase.failure(CKError(.limitExceeded)), .tooLarge)
        XCTAssertEqual(CKCloudDatabase.failure(CKError(.networkUnavailable)), .network(retryAfter: nil))
        XCTAssertEqual(CloudKitSyncTransport.error(.quotaExceeded), .quotaExceeded)
    }

    func testSyncIsOffInBuildsWithoutICloudAndForLocalAccounts() throws {
        let noBuild = AccountSyncService(records: { AccountRecords(engine: SyncEngine(transport: MemorySyncTransport(), device: "x")) },
                                         defaults: try suite("cloud-sync-off-"), available: false)
        XCTAssertFalse(noBuild.canSync)
        if case .unavailable = noBuild.phase {} else { XCTFail("A build without the entitlement says it doesn't sync") }
        let local = AccountSyncService(records: { AccountRecords(engine: nil) }, defaults: try suite("cloud-sync-off-"), available: true)
        XCTAssertFalse(local.canSync)
        // The container exists (September 25, 2026), so this build carries the iCloud switch.
        XCTAssertTrue(AccountSyncService.availableInBuild, "The iCloud switch is on now that the container exists")
        XCTAssertTrue(AccountSyncService.transport(for: .newLocal(), folder: root) is UnavailableSyncTransport)
    }

    func testTokensAtOrPastTheEndOfTheLog() async throws {
        let cloud = FakeCloudDatabase()
        let transport = CloudKitSyncTransport(database: cloud, accountID: accountID, bindingURL: nil, subscribes: false)
        let record = SyncRecord(id: "memory-1", type: SyncType.memory, zone: .personal, modified: Date(), device: "phone", payload: Data("x".utf8))
        try await transport.push([record])
        let first = try await transport.pull(since: nil)
        XCTAssertEqual(first.records.map(\.id), ["memory-1"])
        // A token at the end brings nothing new.
        let atEnd = try await transport.pull(since: first.token)
        XCTAssertTrue(atEnd.records.isEmpty)
        XCTAssertEqual(atEnd.token, first.token)
        // A token past the end (as after the zone was reset) is expired: everything comes again.
        let past = try await transport.pull(since: Data("999".utf8))
        XCTAssertEqual(past.records.map(\.id), ["memory-1"])
    }

    func testTurningSyncOffStopsIt() async throws {
        let cloud = FakeCloudDatabase()
        let phone = try device("phone", database: cloud)
        phone.service.enabled = false
        phone.store.saveMemory(MemoryNote(text: "Stays here"))
        await phone.service.syncNow()
        XCTAssertEqual(phone.service.phase, .off)
        let count = await cloud.zones[zone]?.count ?? 0
        XCTAssertEqual(count, 0)
        phone.service.enabled = true
        await sync(phone)
        let after = await cloud.zones[zone]?.count ?? 0
        XCTAssertEqual(after, 2, "Changes made while it was off go once it's on again (with the preferences record)")
    }
}
