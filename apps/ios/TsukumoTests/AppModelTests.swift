import Foundation
import Testing
import TsukumoCore
import TsukumoEngines
import TsukumoGate
import TsukumoPolicy
import TsukumoUI
@testable import Tsukumo

/// The app's own parts: saving, KemoSabe's grants, keys, connections, and launch arguments.
@MainActor struct AppModelTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TsukumoTests-\(UUID().uuidString)", isDirectory: true)
    }
    private let keys = MemoryAPIKeys()
    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<1000 { if condition() { return true }; try? await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }
    private func claudeConnection() throws -> APIConnection {
        try APIConnection.validated(name: "Claude", endpoint: APIConnection.anthropicEndpoint, model: "claude-opus-5-5", wire: .anthropic)
    }

    @Test func botsChatsAndActivitySurviveARelaunch() async throws {
        let place = folder()
        let model = AppModel(folder: place, keys: keys, launch: Launch(arguments: []))
        #expect(model.bots.map(\.id) == [BotSpec.kemoSabeID])
        var rng = SeededGenerator(seed: 3)
        let pip = BotSpec.new(engine: .appleOnDevice, existing: model.bots, using: &rng)
        model.save(bot: pip)
        #expect(model.session.thread.botIDs.contains(pip.id))

        // A bot that can't run here answers with a status line, and the chat is saved.
        var mac = BotSpec.new(engine: .codingAgent("codex"), existing: model.bots, using: &rng)
        mac.name = "Mac Bot"
        model.save(bot: mac)
        model.session.chips = [mac.id]
        model.session.draft = "hello"
        model.session.send()
        #expect(await eventually { !model.session.isBusy && model.session.thread.messages.count == 2 })

        let again = AppModel(folder: place, keys: keys, launch: Launch(arguments: []))
        #expect(again.bots.map(\.id) == [BotSpec.kemoSabeID, pip.id, mac.id])
        #expect(again.threads.count == 1)
        #expect(again.threads.first?.title == "hello")
        #expect(again.threads.first?.messages.last?.parts == [.status("Mac Bot runs on a Mac. Coding agents aren’t on iPhone yet.")])
        #expect(again.session.thread.id == again.threads.first?.id)
    }

    @Test func kemoSabeCannotBeRemoved() {
        let model = AppModel(folder: folder(), keys: keys, launch: Launch(arguments: []))
        model.remove(bot: BotSpec.kemoSabeID)
        #expect(model.bots.first?.isKemoSabe == true)
    }

    @Test func anUnreadableFileIsKeptNotOverwritten() throws {
        let place = folder()
        try FileManager.default.createDirectory(at: place, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: place.appendingPathComponent("threads.json"))
        let model = AppModel(folder: place, keys: keys, launch: Launch(arguments: []))
        #expect(model.problem != nil)
        let kept = try FileManager.default.contentsOfDirectory(atPath: place.path).filter { $0.hasPrefix("threads-unreadable") }
        #expect(kept.count == 1)
    }

    @Test func keysStayInTheKeychainNotInFiles() throws {
        let place = folder()
        let keychain = KeychainAPIKeys(service: "com.zlichtman.tsukumo.api-keys.unit-tests")
        let model = AppModel(folder: place, keys: keychain, launch: Launch(arguments: []))
        let connection = try claudeConnection()
        try model.save(connection: ConnectionRecord(connection: connection, provider: .anthropic, models: []), key: "sk-ant-test-123")
        defer { model.remove(connection: connection.id) }
        #expect(try keychain.read(connection.id) == "sk-ant-test-123")
        #expect(model.hasKey(connection.id))
        let saved = try String(contentsOf: place.appendingPathComponent("connections.json"), encoding: .utf8)
        #expect(!saved.contains("sk-ant"))
        model.remove(connection: connection.id)
        #expect(try keychain.read(connection.id) == nil)
    }

    @Test func anAPIBotRunsOnItsConnection() async throws {
        let model = AppModel(folder: folder(), keys: keys, launch: Launch(arguments: []))
        let connection = try claudeConnection()
        try model.save(connection: ConnectionRecord(connection: connection, provider: .anthropic, models: ["claude-opus-5-5"]), key: nil)
        var rng = SeededGenerator(seed: 5)
        let bot = BotSpec.new(engine: .api(profile: connection.id), existing: model.bots, using: &rng)
        model.save(bot: bot)
        #expect(model.engineInfo(bot.engine).title == "Claude")
        #expect(model.engineChoices.contains { $0.engine == bot.engine && $0.unavailable == nil })
        // No key yet: TsukumoEngines says so instead of calling the API.
        model.session.chips = [bot.id]
        model.session.draft = "hi"
        model.session.send()
        #expect(await eventually { !model.session.isBusy })
        #expect(model.session.thread.messages.last?.parts == [.status("\(bot.name) stopped. Add this connection's API key in Settings.")])
    }

    @Test func consentIsTheGatesAndSurvivesARelaunch() async throws {
        let place = folder()
        let model = AppModel(folder: place, keys: keys, launch: Launch(arguments: []))
        let connection = try claudeConnection()
        try model.save(connection: ConnectionRecord(connection: connection, provider: .anthropic, models: []), key: nil)
        var rng = SeededGenerator(seed: 8)
        let bot = BotSpec.new(engine: .api(profile: connection.id), existing: model.bots, using: &rng)
        model.save(bot: bot)
        #expect(model.allowedBots.isEmpty)

        // The first question asks; Allow always is kept by the Gate and saved.
        let answerer = GateAnswerer(gate: model.gate) { _ in "api.anthropic.com" }
        _ = await answerer.ask(KemoSabeQuestion(asker: bot, question: "When am I free tonight?", purpose: "plans"),
                               consent: { .always }, share: { _ in false })
        #expect(model.allowedBots.map(\.id) == [bot.id])
        let again = AppModel(folder: place, keys: keys, launch: Launch(arguments: []))
        #expect(again.allowedBots.map(\.id) == [bot.id])
        await again.refreshJournal()
        #expect(again.journal.count == 1)
        #expect(again.journal.first?.shared == nil)

        // "Ask again" removes it.
        again.revokeConsent(bot)
        #expect(again.allowedBots.isEmpty)
    }

    @Test func engineChoicesPutWhatRunsHereFirst() {
        let model = AppModel(folder: folder(), keys: keys, launch: Launch(arguments: []))
        let choices = model.engineChoices
        #expect(choices.first?.engine == .appleOnDevice)
        #expect(choices.filter { $0.engine.runsOnlyOnMac }.allSatisfy { $0.unavailable == "Coding agents run on a Mac." })
        #expect(choices.contains { $0.unavailable == "Connect one in Settings, Models." })
    }

    @Test func theDemoUsesTheRealGateWithoutSavingAnything() async {
        let place = folder()
        let model = AppModel(folder: place, keys: keys, launch: Launch(arguments: ["--demo-fixture", "--demo-pace=0.001"]))
        #expect(model.bots.map(\.name) == ["KemoSabe", "Claude"])
        await DemoFixture.play(model.session, pace: 0.001)
        #expect(await eventually { model.session.events.contains(.replied(DemoFixture.claudeID)) })
        #expect(model.session.thread.messages.count == 3)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? []
        #expect(files.filter { $0.hasSuffix(".json") }.isEmpty)
    }

    @Test func launchArgumentsAreRead() {
        let launch = Launch(arguments: ["--ui-testing", "--demo-fixture", "--demo-pace=0.25", "--open=activity", "--create-bot"])
        #expect(launch.uiTesting && launch.demo == .play && launch.pace == 0.25 && launch.open == "activity" && launch.createBot)
        #expect(Launch(arguments: ["--consent-fixture"]).demo == .consent)
    }

    @Test func modelListsKeepChatModelsOnly() throws {
        let data = Data(#"{"data":[{"id":"gpt-5.2","created":3},{"id":"text-embedding-3","created":2},{"id":"gpt-5.1","created":1}]}"#.utf8)
        #expect(try ModelCatalog.chatModels(in: data, provider: .openAI) == ["gpt-5.2", "gpt-5.1"])
        #expect(ConnectionRecord.Provider.detect(key: "sk-ant-abc") == .anthropic)
        #expect(ConnectionRecord.Provider.detect(key: "sk-proj-abc") == .openAI)
    }
}
