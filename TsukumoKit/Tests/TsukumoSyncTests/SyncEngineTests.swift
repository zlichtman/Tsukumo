import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
@testable import TsukumoSync

/// Sync against an in-memory cloud database (porting `CloudSyncTests`): what leaves, conflicts,
/// account changes, lost zones, and that nothing Device only or Secret (or a key) is ever saved.
struct SyncEngineTests {
    let zone = "personal-test"
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    func engine(_ database: InMemoryCloudDatabase, device: String = "iPhone", user: String? = nil) -> SyncEngine {
        SyncEngine(database: database, zone: zone, device: device, boundUser: user)
    }
    func note(_ id: String, _ level: PrivacyLevel, kind: ItemKind = .note, modified: Date? = nil, text: String = "x") -> SyncItem {
        SyncItem(id: id, type: .artifact, label: TypeLabel(kind: kind, level: level), modified: modified ?? now, payload: Data(text.utf8))
    }

    @Test func botsThreadsAndOpenToSensitiveItemsSync() async throws {
        let database = InMemoryCloudDatabase(), sync = engine(database)
        let bot = BotSpec(name: "Pip", engine: .appleOnDevice, look: BotLook(shape: .mochi, palette: "matcha", eyes: .ovals))
        #expect(await sync.stage(try .bot(bot, modified: now)))
        let thread = ChatThread(botIDs: [bot.id])
        #expect(await sync.stage(try .thread(thread, level: .sensitive, modified: now)))
        #expect(await sync.stage(note("a", .open)))
        let report = try await sync.sync()
        #expect(Set(report.pushed) == ["bot:\(bot.id.uuidString)", "thread:\(thread.id.uuidString)", "a"])
        #expect(await sync.pending.isEmpty)
        #expect(await sync.iCloudUser == "_test-user")
    }

    @Test func deviceOnlySecretAndPersonalSourcesNeverLeave() async throws {
        let database = InMemoryCloudDatabase(), sync = engine(database)
        #expect(!(await sync.stage(note("local", .deviceOnly, text: "door code 4417"))))
        #expect(!(await sync.stage(note("secret", .secret, text: "diary"))))
        #expect(!(await sync.stage(note("answer", .personal, kind: .personalAnswer, text: "After 7 tonight"))))
        #expect(!(await sync.stage(note("messages", .personal, kind: .textMessage, text: "Sarah: free after 7"))))
        #expect(!(await sync.stage(note("key", .open, kind: .credential, text: "sk-test"))))
        _ = try await sync.sync()
        let saved = await database.savedNames
        #expect(saved.isEmpty)
        let payloads = await database.savedPayloads.map { String(decoding: $0, as: UTF8.self) }.joined()
        #expect(!payloads.contains("4417") && !payloads.contains("After 7"))
    }

    @Test func artifactsSyncAtTheirEffectiveLevel() async throws {
        let store = try ArtifactStore()
        let source = try await store.put(ArtifactDraft(kind: .note, level: .deviceOnly, owner: .owner, summaryLine: "Door code", content: "4417"))
        let derived = try await store.put(ArtifactDraft(kind: .note, level: .open, owner: .owner, summaryLine: "Arrival plan", content: "Use the side door"),
                                          derivedFrom: [source])
        let open = try await store.put(ArtifactDraft(kind: .note, level: .open, owner: .owner, summaryLine: "Roadmap", content: "Ship it"))
        let database = InMemoryCloudDatabase(), sync = engine(database)
        #expect(!(await sync.stage(try await .artifact(derived, from: store))), "Derived from Device only: stays")
        #expect(await sync.stage(try await .artifact(open, from: store)))
        let report = try await sync.sync()
        #expect(report.pushed == ["artifact:\(open.id)"])
    }

    @Test func apiConnectionsSyncWithoutTheirKeys() async throws {
        let database = InMemoryCloudDatabase(), sync = engine(database)
        let record = APIConnectionRecord(id: UUID(), name: "Claude", endpoint: URL(string: "https://api.anthropic.com/v1/messages")!, model: "claude-opus-4-5", wire: "anthropic")
        #expect(await sync.stage(try .connection(record, modified: now)))
        _ = try await sync.sync()
        let saved = try #require(await database.record("connection:\(record.id.uuidString)", zone: zone))
        let item = try #require(SyncEngine.item(saved))
        let payload = String(decoding: item.payload, as: UTF8.self)
        #expect(payload.contains("claude-opus-4-5") && !payload.lowercased().contains("key"))
        #expect(try TsukumoJSON.decoder.decode(APIConnectionRecord.self, from: item.payload) == record)
    }

    @Test func anotherDevicesChangesArrive() async throws {
        let database = InMemoryCloudDatabase()
        let phone = engine(database, device: "iPhone"), mac = engine(database, device: "Mac")
        await mac.stage(note("plan", .personal, text: "from the Mac"))
        _ = try await mac.sync()
        let report = try await phone.sync()
        #expect(report.received.map(\.id) == ["plan"])
        #expect(String(decoding: report.received[0].payload, as: UTF8.self) == "from the Mac")
        // Its own writes don't come back as news.
        await phone.stage(note("mine", .open))
        let again = try await phone.sync()
        #expect(again.received.isEmpty)
    }

    @Test func conflictsGoToTheNewerEdit() async throws {
        let database = InMemoryCloudDatabase()
        let phone = engine(database, device: "iPhone")
        await phone.stage(note("doc", .open, modified: now, text: "v1"))
        _ = try await phone.sync()
        // The Mac edits it later; the phone's next edit is older.
        let server = await database.record("doc", zone: zone)!
        var newer = server
        newer.device = "Mac"; newer.modified = now.addingTimeInterval(60)
        newer.payload = try TsukumoJSON.encoder.encode(["kind": "note", "level": "open", "payload": Data("from Mac".utf8).base64EncodedString()])
        await database.write(asAnotherDevice: newer, zone: zone)
        await phone.stage(note("doc", .open, modified: now.addingTimeInterval(30), text: "older edit"))
        let report = try await phone.sync()
        #expect(report.keptServer == 1 && report.keptLocal == 0)
        #expect(report.received.contains { $0.id == "doc" })
        // A newer local edit goes on top of the server's.
        await phone.stage(note("doc", .open, modified: now.addingTimeInterval(120), text: "newest"))
        let later = try await phone.sync()
        #expect(later.pushed == ["doc"])
        #expect(await database.record("doc", zone: zone)?.modified == now.addingTimeInterval(120))
    }

    @Test func aDifferentICloudUserStopsSync() async throws {
        let database = InMemoryCloudDatabase()
        let sync = engine(database, user: "_someone-else")
        await #expect(throws: SyncError.iCloudAccountMismatch) { try await sync.sync() }
        await database.setStatus(.noAccount)
        await #expect(throws: SyncError.self) { try await engine(database).sync() }
    }

    @Test func aLostZoneStartsOverAndBigBatchesSplit() async throws {
        let database = InMemoryCloudDatabase(), sync = engine(database)
        await sync.stage(note("a", .open))
        _ = try await sync.sync()
        await database.dropZone(zone)
        await sync.stage(note("b", .open))
        await #expect(throws: SyncError.resetRequired) { try await sync.sync() }
        await sync.stage(note("b", .open))
        _ = try await sync.sync()
        #expect(await database.record("b", zone: zone) != nil)

        await database.setMaxBatch(2)
        for index in 0..<5 { await sync.stage(note("n\(index)", .open)) }
        let report = try await sync.sync()
        #expect(report.pushed.count == 5)
    }

    @Test func failuresReadPlainly() async throws {
        let database = InMemoryCloudDatabase(), sync = engine(database)
        _ = try await sync.sync()
        await database.failNext(.quotaExceeded)
        await sync.stage(note("a", .open))
        await #expect(throws: SyncError.quotaExceeded) { try await sync.sync() }
        #expect(SyncStatus.failed(.quotaExceeded).text == "Your iCloud storage is full, so sync has paused.")
        #expect(!SyncStatus.failed(.iCloudAccountMismatch).text.contains("Kemo "))
    }
}
