import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Models, simplified (the owner, September 30, 2026): three tabs from one catalog on both devices, the
/// default model, Training's statuses, the sync of what the owner expects to be the same on iPhone
/// and Mac, and the relay fallback's hub and log (in memory; `MacRelaySyncTests` runs it over TLS).
@MainActor final class ModelsPageTests: XCTestCase {
    private var root = FileManager.default.temporaryDirectory
    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ModelsPageTests-" + UUID().uuidString, isDirectory: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: One catalog, three tabs (rules 9 and 10)

    func testModelsHasLLMSystemOneAndTrainingOnBothDevicesAndVoiceIsOnCompanion() {
        XCTAssertEqual(ModelsTab.allCases.map(\.rawValue), ["LLM", "System One", "Training"])
        for device in [SettingsPage.Device.iPhone, .mac] {
            let pages = SettingsCatalog.groups(for: device).flatMap(\.pages).map(\.id)
            XCTAssertTrue(pages.contains("Models") && pages.contains("Companion"), "\(device)")
            XCTAssertFalse(pages.contains("Voice"), "Voice isn't a page or a tab")
            for word in ["Training", "your voice", "Laya", "ollama"] {
                XCTAssertTrue(SettingsCatalog.groups(for: device, search: word).flatMap(\.pages).contains { $0.id == "Models" }, word)
            }
            for word in ["speaking pace", "microphone", "read aloud", "OpenAI"] {
                XCTAssertTrue(SettingsCatalog.groups(for: device, search: word).flatMap(\.pages).contains { $0.id == "Companion" }, word)
            }
        }
        // The same groups, names, and order on both devices, for the pages both show.
        let iPhone = SettingsCatalog.groups(for: .iPhone).map { ($0.name, $0.pages.filter { $0.devices.contains(.mac) }.map(\.id)) }
        let mac = SettingsCatalog.groups(for: .mac).map { ($0.name, $0.pages.filter { $0.devices.contains(.iPhone) }.map(\.id)) }
        XCTAssertEqual(iPhone.map(\.0).filter { name in mac.contains { $0.0 == name } }, mac.map(\.0).filter { name in iPhone.contains { $0.0 == name } })
        for (name, pages) in iPhone { if let other = mac.first(where: { $0.0 == name }) { XCTAssertEqual(pages, other.1, name) } }
        // Older links still land.
        XCTAssertEqual(SettingsCatalog.moved["Voice"]?.page, "Companion")
        XCTAssertEqual(SettingsCatalog.moved["Train Laya"]?.tab, .training)
        XCTAssertEqual(SettingsCatalog.moved["Your voice"]?.tab, .training)
        XCTAssertEqual(SettingsCatalog.moved["System One"]?.tab, .systemOne)
        XCTAssertEqual(SettingsCatalog.moved[SettingsCatalog.macAgents.iPhone]?.tab, .llm)
    }

    // MARK: Training

    private func example(_ kind: DecisionKind, right: Bool = true) -> SystemOneExample {
        SystemOneExample(at: Date(), kind: kind, questionID: "q", options: ["a", "b"], laya: [0.6, 0.4], shown: 0, correct: right ? 0 : 1)
    }
    func testTrainingSaysWhereEachModelStands() {
        var state = SystemOnePersonalState()
        XCTAssertEqual(TrainingCatalog.laya(counts: [:], state: state), .notStarted)
        XCTAssertEqual(TrainingCatalog.laya(counts: [.candidateFit: 12, .routineIntent: 3], state: state), .collecting(12, of: 30))
        XCTAssertEqual(TrainingStatus.collecting(12, of: 30).title, "Collecting 12 of 30")
        XCTAssertEqual(TrainingCatalog.laya(counts: [.candidateFit: 30], state: state), .ready)
        XCTAssertEqual(TrainingCatalog.laya(counts: [.interruptionTiming: 40], state: state), .notStarted, "A decision nothing asks yet doesn't count")
        // Trained, but the layer didn't beat Laya: needs more, until new marks make it ready again.
        let examples = (0..<30).map { _ in example(.candidateFit) }
        state = PersonalTraining.trainAll(examples)
        XCTAssertNotNil(state.report(.candidateFit))
        if state.activeKinds.isEmpty {
            XCTAssertEqual(TrainingCatalog.laya(counts: [.candidateFit: 30], state: state), .needsMore)
            XCTAssertEqual(TrainingCatalog.laya(counts: [.candidateFit: 34], state: state), .ready)
        } else {
            XCTAssertEqual(TrainingCatalog.laya(counts: [.candidateFit: 30], state: state), .trained)
        }
        XCTAssertEqual(TrainingStatus.needsMore.title, "Needs more examples")
        XCTAssertEqual(TrainingStatus.trained.title, "Trained")
        XCTAssertEqual(TrainingCatalog.voice(enrolled: false), .notStarted)
        XCTAssertEqual(TrainingCatalog.voice(enrolled: true), .trained)
        XCTAssertEqual(TrainingCatalog.dayPlans(learning: true, examples: 0), .notStarted)
        XCTAssertEqual(TrainingCatalog.dayPlans(learning: true, examples: 7).title, "Collecting 7")
        XCTAssertEqual(TrainingCatalog.dayPlans(learning: false, examples: 7), .off)
    }

    // MARK: The default model

    private func store(_ name: String, keys: MemoryAPIKeys = MemoryAPIKeys()) -> AppStore {
        AppStore(repository: .init(url: root.appendingPathComponent(name).appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: keys)
    }
    private func claude() throws -> APIModelProfile {
        try APIModelProfile.validated(name: "Claude", endpoint: "https://api.anthropic.com/v1/messages", model: "claude-opus-5-5", format: .anthropic)
    }

    func testChoosingAModelMakesItTheDefaultAndAConnectionWithoutAKeyWaits() throws {
        let store = store("default")
        let profile = try claude()
        try store.addAPIProfile(profile, key: "sk-ant-test-key")
        try store.selectAPIProfile(profile)
        XCTAssertEqual(store.state.defaultModel, .init(route: .api, profile: profile.id))
        store.selectAppleModel(.onDevice)
        XCTAssertEqual(store.state.defaultModel, .init(route: .onDevice))
        XCTAssertEqual(store.modelRoute, .onDevice)

        // Another device's default names a connection whose key isn't here: this device keeps its model.
        let keys = MemoryAPIKeys()
        let other = self.store("other", keys: keys)
        other.state.apiProfiles = [profile]
        other.state.defaultModel = .init(route: .api, profile: profile.id)
        other.applyDefaultModel()
        XCTAssertEqual(other.modelRoute, .onDevice, "No key here yet")
        XCTAssertFalse(other.hasAPIKey(profile))
        try other.setAPIKey("sk-ant-other-key", for: profile)
        XCTAssertTrue(other.hasAPIKey(profile))
        XCTAssertEqual(other.modelRoute, .api, "Once its key is added, the account's default is used here too")
        XCTAssertEqual(other.activeAPIProfile?.id, profile.id)
        // Removing the connection puts the default back on Apple's model.
        try other.removeAPIProfile(profile)
        XCTAssertEqual(other.state.defaultModel, .init(route: .onDevice))
    }

    func testAConnectionsSwitchesCanChangeButNotItsAddress() throws {
        let store = store("update")
        let profile = try claude()
        try store.addAPIProfile(profile, key: "sk-ant-test-key")
        var changed = profile; changed.streaming = false; changed.supportsImages = true
        store.updateAPIProfile(changed)
        XCTAssertEqual(store.state.apiProfiles?.first?.streaming, false)
        XCTAssertEqual(store.state.apiProfiles?.first?.supportsImages, true)
        XCTAssertEqual(store.state.apiProfiles?.first?.endpoint, profile.endpoint)
    }

    // MARK: What now syncs, through the engine with an in-memory transport

    private struct Device {
        let store: AppStore
        let keys: MemoryAPIKeys
        let defaults: UserDefaults
        let engine: SyncEngine
        let service: AccountSyncService
    }
    private func device(_ name: String, transport: SyncTransport) throws -> Device {
        let keys = MemoryAPIKeys()
        let store = store(name, keys: keys)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "models-sync-" + name + "-" + UUID().uuidString))
        let engine = SyncEngine(transport: transport, device: name, url: root.appendingPathComponent(name).appendingPathComponent("Sync/records.json"))
        let records = AccountRecords(engine: engine)
        let service = AccountSyncService(records: { records }, defaults: defaults, available: true)
        service.attach([AppStoreSyncAdapter(store: store), AccountSettingsAdapter(defaults: { defaults }, accountID: nil)], startSync: false)
        return Device(store: store, keys: keys, defaults: defaults, engine: engine, service: service)
    }
    private func sync(_ devices: Device...) async {
        for device in devices {
            await device.service.syncNow()
            XCTAssertEqual(device.service.phase, .idle, "\(device.engine.device): \(device.service.phase)")
        }
    }

    func testModelConnectionsSyncWithoutTheirKeysAndLocalhostStaysHere() async throws {
        let cloud = MemorySyncTransport()
        let phone = try device("phone", transport: cloud), mac = try device("mac", transport: cloud)
        let profile = try claude()
        try phone.store.addAPIProfile(profile, key: "sk-ant-phone-only")
        let ollama = try APIModelProfile.validated(name: "Ollama", endpoint: "http://localhost:11434/v1/chat/completions", model: "llama3")
        try phone.store.addAPIProfile(ollama, key: "")
        try phone.store.selectAPIProfile(profile)

        await sync(phone, mac)
        XCTAssertEqual(mac.store.state.apiProfiles?.map(\.name), ["Claude"], "Localhost means something else on each device")
        XCTAssertEqual(mac.store.state.apiProfiles?.first?.model, "claude-opus-5-5")
        XCTAssertFalse(mac.store.hasAPIKey(profile), "Keys never sync")
        XCTAssertTrue(mac.engine.state.records.values.allSatisfy { !String(decoding: $0.payload, as: UTF8.self).contains("sk-ant") }, "No key in any record")
        XCTAssertEqual(mac.store.state.defaultModel, .init(route: .api, profile: profile.id), "The default arrives")
        XCTAssertEqual(mac.store.modelRoute, .onDevice, "…and waits for this Mac's key")
        try mac.store.setAPIKey("sk-ant-mac-key", for: profile)
        XCTAssertEqual(mac.store.activeAPIProfile?.id, profile.id)

        // Streaming changed on the Mac reaches the iPhone; removing it on the iPhone removes it on the Mac.
        var changed = profile; changed.streaming = false
        mac.store.updateAPIProfile(changed)
        await sync(mac, phone)
        XCTAssertEqual(phone.store.state.apiProfiles?.first { $0.id == profile.id }?.streaming, false)
        try phone.store.removeAPIProfile(profile)
        await sync(phone, mac)
        XCTAssertNil(mac.store.state.apiProfiles?.first { $0.id == profile.id }, "Removed on every device")
        XCTAssertFalse(mac.store.hasAPIKey(profile), "Its key goes with it")
        XCTAssertEqual(mac.store.modelRoute, .onDevice)
        await sync(mac, phone)
        XCTAssertEqual(phone.engine.state.outbox.count, 0); XCTAssertEqual(mac.engine.state.outbox.count, 0)
    }

    func testPreferencesAndPalettesSync() async throws {
        let cloud = MemorySyncTransport()
        let phone = try device("phone", transport: cloud), mac = try device("mac", transport: cloud)
        phone.store.state.speechRate = 0.52
        phone.store.state.patientListening = true
        phone.store.state.captionsEnabled = false
        phone.store.state.modelEfforts = ["apple.onDevice": "high"]
        var palette = BotTheme.presets[0]; palette.id = "custom-" + UUID().uuidString; palette.name = "Dusk"
        phone.store.state.customThemes = [palette]
        phone.store.selectAppleModel(.onDevice)
        phone.store.save()
        await sync(phone, mac)
        XCTAssertEqual(mac.store.state.speechRate, 0.52)
        XCTAssertEqual(mac.store.state.patientListening, true)
        XCTAssertEqual(mac.store.state.captionsEnabled, false)
        XCTAssertEqual(mac.store.state.modelEfforts, ["apple.onDevice": "high"])
        XCTAssertEqual(mac.store.state.customThemes?.map(\.name), ["Dusk"])
        // A palette made on the Mac joins the iPhone's; one removed there goes here too.
        var other = BotTheme.presets[0]; other.id = "custom-" + UUID().uuidString; other.name = "Moss"
        mac.store.state.customThemes = (mac.store.state.customThemes ?? []) + [other]; mac.store.save()
        await sync(mac, phone)
        XCTAssertEqual(Set(phone.store.state.customThemes?.map(\.name) ?? []), ["Dusk", "Moss"])
        phone.store.state.customThemes?.removeAll { $0.name == "Dusk" }; phone.store.save()
        await sync(phone, mac)
        XCTAssertEqual(mac.store.state.customThemes?.map(\.name), ["Moss"])
        // Never synced: what each connection may read, and the Apple connections disconnected here.
        XCTAssertFalse(SyncType.personalOnly.isDisjoint(with: [SyncType.modelConnection, SyncType.palette, SyncType.preferences]))
        XCTAssertTrue([SyncType.modelConnection, SyncType.palette, SyncType.preferences].allSatisfy(SyncType.personalOnly.contains),
                      "Never in a shared project or profile share")
    }

    func testTheCompanionsVoiceAndUseLayaSync() async throws {
        let cloud = MemorySyncTransport()
        let phone = try device("phone", transport: cloud), mac = try device("mac", transport: cloud)
        phone.defaults.set(VoicePersona.kokoro("am_puck").stored, forKey: VoicePersona.key)
        let settings = SystemOneSettings(keys: NoJevKey(), defaults: phone.defaults)
        settings.layaEnabled = false
        phone.store.save()
        await sync(phone, mac)
        XCTAssertEqual(VoicePersona.stored(in: mac.defaults), .kokoro("am_puck"))
        XCTAssertFalse(SystemOneSettings(keys: NoJevKey(), defaults: mac.defaults).layaEnabled, "Use Laya follows the account")
        XCTAssertNil(mac.defaults.object(forKey: SystemOneSettings.jevKey), "Jev's switch stays with its key on each device")
    }

    // MARK: Sync through the paired iPhone (the relay fallback), in memory

    /// The Mac's side of the relay, handing each request straight to the phone's hub.
    private final class DirectLink: RelaySyncLink {
        let hub: RelaySyncHub
        let pageBytes: Int
        var pulls = 0
        init(hub: RelaySyncHub, pageBytes: Int) { self.hub = hub; self.pageBytes = pageBytes }
        func pull(token: String?) async throws -> (records: [SyncRecord], token: String?, more: Bool) {
            pulls += 1
            let page = try hub.pull(token: token, pageBytes: pageBytes)
            return (page.records, page.token, page.more)
        }
        func push(_ records: [SyncRecord]) async throws { try hub.push(records) }
    }

    func testAMacWithoutICloudSyncsTheSameRecordsThroughItsIPhone() async throws {
        let cloud = MemorySyncTransport()
        let phone = try device("phone", transport: cloud), laptop = try device("laptop", transport: cloud)
        let hub = RelaySyncHub(engine: { phone.engine }, logURL: { self.root.appendingPathComponent("phone/Sync/relay-log.json") },
                               reconcile: { try phone.service.reconcileNow() }, changed: {})
        let link = DirectLink(hub: hub, pageBytes: 200)
        let mac = try device("mac", transport: RelaySyncTransport { .success(link) })

        // What the account already has reaches the Mac through the iPhone, a small page at a time.
        phone.store.saveMemory(MemoryNote(text: "Prefers window seats"))
        laptop.store.saveMemory(MemoryNote(text: "Allergic to peanuts"))
        await sync(laptop, phone)
        await sync(mac)
        XCTAssertEqual(Set(mac.store.state.memories.map(\.text)), ["Prefers window seats", "Allergic to peanuts"])
        XCTAssertGreaterThan(link.pulls, 1, "Paged")

        // The Mac's own change goes to the iPhone, on to iCloud, and to the account's other devices.
        mac.store.saveMemory(MemoryNote(text: "Takes the 8:10 train"))
        await sync(mac)
        XCTAssertTrue(phone.store.state.memories.contains { $0.text == "Takes the 8:10 train" }, "The iPhone takes it in at once")
        await sync(phone, laptop)
        XCTAssertTrue(laptop.store.state.memories.contains { $0.text == "Takes the 8:10 train" }, "…and passes it on")

        // A deletion and a newer edit travel the same way; nothing bounces back and forth.
        let note = try XCTUnwrap(laptop.store.state.memories.first { $0.text == "Allergic to peanuts" })
        laptop.store.deleteMemory(note.id)
        await sync(laptop, phone, mac)
        XCTAssertFalse(mac.store.state.memories.contains { $0.text == "Allergic to peanuts" })
        let pulls = link.pulls
        await sync(mac)
        XCTAssertEqual(link.pulls - pulls, 1, "Only what changed since the last pull")
        XCTAssertEqual(mac.engine.state.outbox.count, 0)
    }

    func testTheHubsLogHandsOutEachVersionOnceAndStartsOverForAnotherLog() throws {
        let log = RelaySyncLog(url: root.appendingPathComponent("log.json"))
        var state = SyncState()
        let record = SyncRecord(id: "memory-1", type: SyncType.memory, zone: .personal, modified: Date(), device: "phone", payload: Data("a".utf8))
        let shared = SyncRecord(id: "task-1", type: SyncType.collabTask, zone: .shared(project: "p"), modified: Date(), device: "phone", payload: Data("b".utf8))
        state.records[record.key] = record; state.records[shared.key] = shared
        let first = try log.page(of: state, after: nil, pageBytes: 1000)
        XCTAssertEqual(first.records.map(\.id), ["memory-1"], "Only the personal zone")
        XCTAssertTrue(try log.page(of: state, after: first.token, pageBytes: 1000).records.isEmpty)
        var edited = record; edited.modified = Date().addingTimeInterval(5); edited.payload = Data("aa".utf8)
        state.records[edited.key] = edited
        XCTAssertEqual(try log.page(of: state, after: first.token, pageBytes: 1000).records.first?.payload, Data("aa".utf8))
        XCTAssertEqual(RelaySyncLog.position("\(UUID().uuidString):9", epoch: log.document.epoch), 0, "Another log's token starts over")
        XCTAssertEqual(RelaySyncLog(url: root.appendingPathComponent("log.json")).document.epoch, log.document.epoch, "Kept across launches")
        XCTAssertEqual(MacRelaySync.chunks([record, edited], limit: 1).count, 2, "Pushes split by size")
    }

    func testAMacWithoutAnIPhoneWaitsRatherThanFails() async throws {
        let mac = try device("mac", transport: RelaySyncTransport { .failure(.unavailable(MacRelaySync.waiting)) })
        mac.store.saveMemory(MemoryNote(text: "Kept until the iPhone is here"))
        await mac.service.syncNow()
        XCTAssertEqual(mac.service.phase, .waiting(MacRelaySync.waiting))
        XCTAssertFalse(mac.service.hasProblem)
        XCTAssertEqual(mac.service.statusTitle, "Waiting for your iPhone")
        XCTAssertEqual(mac.service.title, "Sync with your iPhone")
    }
}

private struct NoJevKey: JevKeyStoring {
    func read() -> String? { nil }
    func save(_ key: String) throws {}
    func remove() throws {}
}
