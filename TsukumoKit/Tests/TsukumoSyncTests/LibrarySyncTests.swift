import Foundation
import Testing
import TsukumoCore
import TsukumoPolicy
@testable import TsukumoSync

/// Conversations, bots, and the default model between a Mac and an iPhone, through one in-memory iCloud
/// database: a chat made on either appears on the other, edits merge, deletes propagate, and keys,
/// KemoSabe's answers, and Device only chats never leave.
@MainActor struct LibrarySyncTests {
    /// One device: its library, and the real sync controller over the shared database.
    @MainActor final class Device {
        var library: SyncLibrary
        var controller: LibrarySyncController!
        init(_ name: String, database: InMemoryCloudDatabase, library: SyncLibrary = SyncLibrary(bots: [.kemoSabe()])) {
            self.library = library
            controller = LibrarySyncController(database: database, signedIn: true, ledgerURL: nil, devicePrefix: name,
                                               read: { [unowned self] in self.library }, apply: { [unowned self] in self.library = $0 })
        }
        func sync() async { await controller.syncNow() }
    }

    let start = Date(timeIntervalSince1970: 1_900_000_000)

    func message(_ text: String, _ author: Author = .owner, at offset: Double) -> Message {
        Message(date: start.addingTimeInterval(offset), author: author, parts: [.text(text)], tags: author == .owner ? [BotSpec.kemoSabeID] : [])
    }
    func thread(_ title: String, _ messages: [Message]) -> ChatThread {
        ChatThread(title: title, botIDs: [BotSpec.kemoSabeID], messages: messages)
    }
    /// Everything that reached iCloud, as text: each record's envelope and the payload inside it.
    func payloads(_ database: InMemoryCloudDatabase) async -> String {
        struct Envelope: Decodable { let payload: Data }
        return await database.savedPayloads.map { data in
            let inner = (try? JSONDecoder().decode(Envelope.self, from: data)).map { String(decoding: $0.payload, as: UTF8.self) } ?? ""
            return String(decoding: data, as: UTF8.self) + "\n" + inner
        }.joined(separator: "\n")
    }

    @Test func aChatMadeOnEitherDeviceAppearsOnTheOther() async throws {
        let cloud = InMemoryCloudDatabase()
        let mac = Device("Mac", database: cloud), phone = Device("iPhone", database: cloud)
        let fromMac = thread("Weekend plans", [message("What should I do this weekend?", at: 0)])
        mac.library.threads.append(fromMac)
        await mac.sync()
        await phone.sync()
        #expect(phone.library.threads.map(\.id) == [fromMac.id])
        #expect(phone.library.threads.first?.messages.first?.text == "What should I do this weekend?")

        let fromPhone = thread("Groceries", [message("Remind me to buy oat milk", at: 10)])
        phone.library.threads.append(fromPhone)
        await phone.sync()
        await mac.sync()
        #expect(Set(mac.library.threads.map(\.id)) == [fromMac.id, fromPhone.id])
        #expect(mac.controller.state.isOn && phone.controller.state.isOn)
        #expect(mac.controller.state.title == "Syncing with iCloud")
    }

    @Test func editsOnBothDevicesMerge() async throws {
        let cloud = InMemoryCloudDatabase()
        let mac = Device("Mac", database: cloud), phone = Device("iPhone", database: cloud)
        let shared = thread("Trip", [message("Plan a trip", at: 0)])
        mac.library.threads = [shared]
        await mac.sync()
        await phone.sync()

        // Both add to the same chat before either syncs again.
        mac.library.threads[0].messages.append(message("Somewhere warm", at: 20))
        phone.library.threads[0].messages.append(message("Under 500 dollars", at: 30))
        await mac.sync()
        await phone.sync()
        await mac.sync()
        await phone.sync()
        let expected = ["Plan a trip", "Somewhere warm", "Under 500 dollars"]
        #expect(mac.library.threads[0].messages.map(\.text) == expected)
        #expect(phone.library.threads[0].messages.map(\.text) == expected)

        // And it settles: another round sends nothing more.
        let before = await cloud.savedNames.count
        await mac.sync()
        await phone.sync()
        #expect(await cloud.savedNames.count == before)
    }

    @Test func deletesPropagateButKemoSabeStays() async throws {
        let cloud = InMemoryCloudDatabase()
        var rng = SeededGenerator(seed: 4)
        let pip = BotSpec.new(engine: .appleOnDevice, existing: [.kemoSabe()], using: &rng)
        let mac = Device("Mac", database: cloud, library: SyncLibrary(bots: [.kemoSabe(), pip]))
        let phone = Device("iPhone", database: cloud)
        let chat = thread("Old chat", [message("hello", at: 0)])
        mac.library.threads = [chat]
        await mac.sync()
        await phone.sync()
        #expect(phone.library.bots.map(\.id) == [BotSpec.kemoSabeID, pip.id])
        #expect(phone.library.threads.map(\.id) == [chat.id])

        phone.library.threads.removeAll()
        phone.library.bots.removeAll { $0.id == pip.id }
        // Even a device that drops KemoSabe from its list never deletes it anywhere.
        phone.library.bots.removeAll { $0.isKemoSabe }
        await phone.sync()
        await mac.sync()
        #expect(mac.library.threads.isEmpty)
        #expect(mac.library.bots.map(\.id) == [BotSpec.kemoSabeID])
    }

    @Test func keysAnswersAndDeviceOnlyChatsNeverLeave() async throws {
        let cloud = InMemoryCloudDatabase()
        let connection = APIConnectionRecord(id: UUID(), name: "Claude", endpoint: URL(string: "https://api.anthropic.com/v1/messages")!,
                                             model: "claude-opus-5-5", wire: "anthropic")
        let mac = Device("Mac", database: cloud, library: SyncLibrary(bots: [.kemoSabe()], connections: [connection]))
        // A chat with KemoSabe's answer card: who asked and the outcome sync; what it shared doesn't.
        var card = GateAnswerCard(exchange: GateExchangeID(), askerName: "Claude", question: "What time is Sarah free tonight?",
                                  outcome: .answered, shared: "After 7 tonight", stayed: "7 messages", device: "Mac",
                                  answer: ArtifactRef(id: ArtifactID(), revision: 1, sha256: "abc"))
        card.notRead = "1 Device only chat"
        let answered = ChatThread(title: "Date night", botIDs: [BotSpec.kemoSabeID],
                                  messages: [message("find a date spot", at: 0), Message(date: start.addingTimeInterval(5), author: .bot(BotSpec.kemoSabeID), parts: [.gateAnswer(card)])])
        let kept = ChatThread(title: "Door code", botIDs: [BotSpec.kemoSabeID], messages: [message("The side door code is 4417", at: 1)], privacy: .deviceOnly)
        mac.library.threads = [answered, kept]
        await mac.sync()

        let sent = await payloads(cloud)
        #expect(sent.contains("What time is Sarah free tonight?"))
        #expect(!sent.contains("After 7 tonight"), "KemoSabe's answers never sync")
        #expect(!sent.contains("4417") && !sent.contains("Door code"), "a Device only chat never leaves")
        #expect(!sent.contains("sk-"), "no key is in the library at all")
        #expect(await cloud.savedNames.contains("connection:" + connection.id.uuidString), "the connection syncs without its key")

        let phone = Device("iPhone", database: cloud)
        await phone.sync()
        #expect(phone.library.threads.map(\.id) == [answered.id])
        #expect(phone.library.connections == [connection])
        guard case .gateAnswer(let arrived)? = phone.library.threads.first?.messages.last?.parts.first else {
            Issue.record("the card should arrive"); return
        }
        #expect(arrived.shared == nil && arrived.answer == nil && arrived.outcome == .answered && arrived.notRead == "1 Device only chat")
        // The Mac keeps its own full card.
        guard case .gateAnswer(let own)? = mac.library.threads[0].messages.last?.parts.first else { Issue.record("kept"); return }
        #expect(own.shared == "After 7 tonight")
    }

    @Test func aChatMovedToDeviceOnlyLeavesTheOtherDevices() async throws {
        let cloud = InMemoryCloudDatabase()
        let mac = Device("Mac", database: cloud), phone = Device("iPhone", database: cloud)
        let chat = thread("Health notes", [message("my appointment is at 3", at: 0)])
        phone.library.threads = [chat]
        await phone.sync()
        await mac.sync()
        #expect(mac.library.threads.count == 1)
        phone.library.threads[0].privacy = .deviceOnly
        await phone.sync()
        await mac.sync()
        #expect(mac.library.threads.isEmpty, "gone from the Mac")
        #expect(phone.library.threads.count == 1, "kept on the iPhone")
    }

    @Test func aSyncedKemoSabeArrivesStandard() async throws {
        let cloud = InMemoryCloudDatabase()
        // Another device (or an older build) wrote KemoSabe with a clay look, a cloud model, and wide scope.
        var odd = BotSpec.kemoSabe(tint: "3F86C6")
        odd.look = BotLook(shape: .block, palette: "lagoon", eyes: .visor, prop: .hardHat, accentColor: "3F86C6")
        odd.engine = .api(profile: UUID())
        odd.contextScope = ContextScope(ceiling: .open, mayAskKemoSabe: true)
        odd.personality = BotPersonality(tone: .playful, instructions: "be someone else")
        let raw = try TsukumoJSON.encoder.encode(odd)
        #expect(String(decoding: raw, as: UTF8.self).contains("hardHat"), "what was written carries the other look")
        let item = SyncItem(id: "bot:" + BotSpec.kemoSabeID.uuidString, type: .bot, label: TypeLabel(kind: "bot", level: .open),
                            modified: start, payload: raw)
        let other = SyncEngine(database: cloud, zone: LibrarySyncController.zone, device: "Elsewhere")
        await other.stage(item)
        _ = try await other.sync()

        let phone = Device("iPhone", database: cloud)
        await phone.sync()
        let kemoSabe = try #require(phone.library.bots.first { $0.isKemoSabe })
        #expect(kemoSabe.look == .kemoSabe(tint: "3F86C6"), "only its color came across")
        #expect(kemoSabe.engine == .appleOnDevice)
        #expect(kemoSabe.contextScope == ContextScope(ceiling: .deviceOnly, mayAskKemoSabe: false))
        #expect(kemoSabe.personality == BotPersonality())
    }

    @Test func theDefaultModelFollows() async throws {
        let cloud = InMemoryCloudDatabase()
        let profile = UUID()
        let mac = Device("Mac", database: cloud, library: SyncLibrary(bots: [.kemoSabe()], defaultModel: DefaultModel(engine: .api(profile: profile), model: "claude-opus-5-5")))
        let phone = Device("iPhone", database: cloud)
        await mac.sync()
        await phone.sync()
        #expect(phone.library.defaultModel == DefaultModel(engine: .api(profile: profile), model: "claude-opus-5-5"))
    }

    @Test func statusLines() async throws {
        let noAccount = LibrarySyncController(database: InMemoryCloudDatabase(), signedIn: false, ledgerURL: nil, devicePrefix: "iPhone",
                                              read: { SyncLibrary() }, apply: { _ in })
        #expect(noAccount.state == .noAccount && noAccount.state.title == "Off: no account")
        await noAccount.syncNow()
        #expect(noAccount.state == .noAccount, "nothing syncs without an account")

        let noCapability = LibrarySyncController(database: nil, signedIn: true, ledgerURL: nil, devicePrefix: "iPhone",
                                                 read: { SyncLibrary() }, apply: { _ in })
        #expect(noCapability.state.title == "Waiting for iCloud to be turned on for Tsukumo")

        let cloud = InMemoryCloudDatabase()
        await cloud.setStatus(.noAccount)
        let signedOut = LibrarySyncController(database: cloud, signedIn: true, ledgerURL: nil, devicePrefix: "iPhone",
                                              read: { SyncLibrary() }, apply: { _ in })
        await signedOut.syncNow()
        #expect(signedOut.state == .iCloudSignedOut)

        #expect(!CloudCapability.isEnabled(), "the test host carries no iCloud capability")
    }

    @Test func theLedgerSurvivesARelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent("sync-ledger.json")
        let cloud = InMemoryCloudDatabase()
        let chat = thread("A", [message("one", at: 0)])
        var library = SyncLibrary(bots: [.kemoSabe()], threads: [chat])
        let first = LibrarySyncController(database: cloud, signedIn: true, ledgerURL: url, devicePrefix: "Mac", read: { library }, apply: { library = $0 })
        await first.syncNow()
        let sent = await cloud.savedNames.count
        // After a relaunch nothing has changed, so nothing is sent again.
        let second = LibrarySyncController(database: cloud, signedIn: true, ledgerURL: url, devicePrefix: "Mac", read: { library }, apply: { library = $0 })
        await second.syncNow()
        #expect(await cloud.savedNames.count == sent)
        // A chat deleted while the app was closed is deleted everywhere.
        library.threads = []
        let third = LibrarySyncController(database: cloud, signedIn: true, ledgerURL: url, devicePrefix: "Mac", read: { library }, apply: { library = $0 })
        await third.syncNow()
        #expect(await cloud.record("thread:" + chat.id.uuidString, zone: LibrarySyncController.zone)?.deleted == true)
    }
}
