import Network
import XCTest
@testable import KemoSabeMac

/// Sync through the paired iPhone, end to end on this Mac (design/ACCOUNTS-AND-PROFILES.md#what-syncs):
/// the Mac's `KemoSabeRelay` over TLS with pre-shared keys on localhost, the phone's `MacRelayClient`
/// with its `RelaySyncHub`, and a Mac `SyncEngine` whose transport is `RelaySyncTransport`. The phone's
/// "iCloud" is an in-memory transport shared with a second device. Nothing is advertised on the network.
@MainActor final class MacRelaySyncTests: XCTestCase {
    private var folders: [URL] = []
    private var relay: KemoSabeRelay!
    private let phone = UUID()

    override func setUp() async throws {
        let defaults = UserDefaults(suiteName: "kemo-relay-sync-tests-" + UUID().uuidString)!
        relay = KemoSabeRelay(defaults: defaults, folder: temporaryFolder(), handoff: KemoSabeHandoff())
        relay.advertise = false
        relay.nameOverride = "Test Mac"
    }
    override func tearDown() async throws {
        relay.setEnabled(false)
        relay = nil
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }

    private struct Device {
        let store: AppStore
        let engine: SyncEngine
        let service: AccountSyncService
    }
    private func device(_ name: String, transport: SyncTransport) throws -> Device {
        let folder = temporaryFolder()
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        let engine = SyncEngine(transport: transport, device: name, url: folder.appendingPathComponent("Sync/records.json"))
        let records = AccountRecords(engine: engine)
        let service = AccountSyncService(records: { records }, defaults: UserDefaults(suiteName: "relay-sync-" + UUID().uuidString)!, available: true)
        service.attach([AppStoreSyncAdapter(store: store)], startSync: false)
        return Device(store: store, engine: engine, service: service)
    }

    func testTheMacSyncsThroughItsPairedIPhoneOverTheRelay() async throws {
        let cloud = MemorySyncTransport()
        let iPhone = try device("phone", transport: cloud), iPad = try device("ipad", transport: cloud)
        let mac = try device("mac", transport: RelaySyncTransport { [relay] in relay?.core.syncLink() ?? .failure(.unavailable(MacRelaySync.notPaired)) })

        // Before pairing, and paired but not connected: the Mac waits, it doesn't fail.
        await mac.service.syncNow()
        XCTAssertEqual(mac.service.phase, .waiting(MacRelaySync.notPaired))
        let key = try await pairedPhone()
        await mac.service.syncNow()
        XCTAssertEqual(mac.service.phase, .waiting(MacRelaySync.waiting))

        // The iPhone connects as a hub: it carries the account's records.
        let hub = RelaySyncHub(engine: { iPhone.engine }, logURL: { [unowned self] in self.temporaryFolder().appendingPathComponent("log.json") },
                               reconcile: { try iPhone.service.reconcileNow() }, changed: {})
        iPhone.store.saveMemory(MemoryNote(text: "Prefers window seats"))
        iPad.store.saveMemory(MemoryNote(text: "Allergic to peanuts"))
        await sync(iPad, iPhone)
        let client = try await connect(key: key, hub: hub)
        XCTAssertTrue(relay.core.hasSyncHub)
        XCTAssertEqual(client.welcome?.version, 3)

        await sync(mac)
        XCTAssertEqual(Set(mac.store.state.memories.map(\.text)), ["Prefers window seats", "Allergic to peanuts"], "Everything the account has")
        mac.store.saveMemory(MemoryNote(text: "Takes the 8:10 train"))
        await sync(mac)
        XCTAssertTrue(iPhone.store.state.memories.contains { $0.text == "Takes the 8:10 train" }, "The iPhone takes the Mac's change in")
        await sync(iPhone, iPad)
        XCTAssertTrue(iPad.store.state.memories.contains { $0.text == "Takes the 8:10 train" }, "…and passes it on through iCloud")

        // The same conflict rule: the newer edit wins, whichever side made it.
        let note = try XCTUnwrap(iPad.store.state.memories.first { $0.text == "Prefers window seats" })
        var edited = note; edited.text = "Prefers aisle seats"
        iPad.store.saveMemory(edited)
        await sync(iPad, iPhone, mac)
        XCTAssertTrue(mac.store.state.memories.contains { $0.text == "Prefers aisle seats" })
        XCTAssertFalse(mac.store.state.memories.contains { $0.text == "Prefers window seats" })
        XCTAssertEqual(mac.engine.state.outbox.count, 0)

        // The phone goes away: the Mac waits again, with its change kept for next time.
        client.close()
        try await waitUntil { !self.relay.core.hasSyncHub }
        mac.store.saveMemory(MemoryNote(text: "Kept until the iPhone is back"))
        await mac.service.syncNow()
        if case .waiting = mac.service.phase {} else { XCTFail("\(mac.service.phase)") }
        XCTAssertFalse(mac.engine.state.outbox.isEmpty, "Nothing is lost while the iPhone is away")
    }

    func testAPhoneThatDoesntSyncWithICloudIsNotAHub() async throws {
        let key = try await pairedPhone()
        let hub = RelaySyncHub(engine: { nil }, logURL: { nil }, reconcile: {}, changed: {})
        _ = try await connect(key: key, hub: hub)
        XCTAssertFalse(relay.core.hasSyncHub)
        guard case .failure(.unavailable(let message)) = relay.core.syncLink() else { return XCTFail("No hub") }
        XCTAssertEqual(message, MacRelaySync.noHub)
    }

    // MARK: Helpers

    private func sync(_ devices: Device...) async {
        for device in devices {
            await device.service.syncNow()
            XCTAssertEqual(device.service.phase, .idle, "\(device.engine.device): \(device.service.phase)")
        }
    }
    private func transport() -> MacRelayDirectTransport {
        MacRelayDirectTransport { [relay] in relay?.port.flatMap { NWEndpoint.Port(rawValue: $0) }.map { .hostPort(host: "127.0.0.1", port: $0) } }
    }
    private func pairedPhone() async throws -> Data {
        relay.setEnabled(true)
        let offer = try XCTUnwrap(relay.offer)
        try await waitUntil { self.relay.port != nil }
        let channel = try await transport().open(mac: nil, identity: MacRelay.pairingIdentity, key: MacRelay.Keys.pairing(code: offer.code)).get()
        let paired = try await MacRelayPairing.pair(over: channel, phone: phone, name: "Test iPhone", code: offer.code).get()
        try await waitUntil { self.relay.port != nil && !self.relay.phones.isEmpty }
        return paired.key
    }
    private func connect(key: Data, hub: RelaySyncHub) async throws -> MacRelayClient {
        let channel = try await transport().open(mac: relay.mac, identity: MacRelay.identity(phone: phone), key: key).get()
        let client = MacRelayClient(phone: phone, key: key, name: "Test iPhone")
        client.syncHub = hub
        client.start(channel)
        try await waitUntil { client.isConnected }
        return client
    }
    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MacRelaySyncTests-" + UUID().uuidString, isDirectory: true)
        folders.append(folder)
        return folder
    }
    private func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < end else { return XCTFail("Timed out") }
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
