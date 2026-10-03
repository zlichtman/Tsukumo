import Foundation
import Testing
import TsukumoCore
import TsukumoEngines
import TsukumoSync
import TsukumoUI
@testable import Tsukumo

/// The first run, the account, KemoSabe staying standard, starters on iPhone engines, and sync's view
/// of the app (what goes out, and what coming in does to the chat).
@MainActor struct AccountAndSyncTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("TsukumoTests-\(UUID().uuidString)", isDirectory: true)
    }
    private let keys = MemoryAPIKeys()

    @Test func theFirstRunShowsOnceAndTheAccountIsKept() throws {
        let place = folder(), appleID = MemoryAppleIDStore()
        let model = AppModel(folder: place, keys: keys, launch: Launch(arguments: []), appleID: appleID)
        #expect(model.needsOnboarding)
        #expect(model.sync.state == .noAccount)
        try model.accounts.signIn(userID: "001234.abcd", name: "Sam Rivera")
        #expect(appleID.read() == "001234.abcd", "the Apple user ID is in the Keychain")
        #expect(model.sync.state == .waitingForCapability, "this build has no iCloud capability")
        model.accounts.finishOnboarding()
        model.finishOnboarding()
        #expect(!model.needsOnboarding)
        let saved = try String(contentsOf: place.appendingPathComponent("account.json"), encoding: .utf8)
        #expect(saved.contains("Sam Rivera") && !saved.contains("001234"), "the file has the name, never the Apple user ID")

        let again = AppModel(folder: place, keys: keys, launch: Launch(arguments: []), appleID: appleID)
        #expect(!again.needsOnboarding)
        #expect(again.accounts.account?.name == "Sam Rivera")
        again.accounts.signOut()
        #expect(appleID.read() == nil && again.sync.state == .noAccount)
        // The demo and --skip-onboarding never show it.
        #expect(!AppModel(folder: folder(), keys: keys, launch: Launch(arguments: ["--demo-final"]), appleID: MemoryAppleIDStore()).needsOnboarding)
        #expect(!AppModel(folder: folder(), keys: keys, launch: Launch(arguments: ["--skip-onboarding"]), appleID: MemoryAppleIDStore()).needsOnboarding)
    }

    @Test func kemoSabeSavesOnlyItsColor() {
        let model = AppModel(folder: folder(), keys: keys, launch: Launch(arguments: []), appleID: MemoryAppleIDStore())
        var edited = model.bots[0]
        edited.look = BotLook(shape: .block, palette: "lagoon", eyes: .visor, prop: .hardHat, accentColor: "6F63C9")
        edited.engine = .api(profile: UUID())
        edited.name = "KemoSabe"
        model.save(bot: edited)
        #expect(model.bots[0].look == .kemoSabe(tint: "6F63C9"))
        #expect(model.bots[0].engine == .appleOnDevice)
        #expect(model.bots.count == 1)
    }

    @Test func startersRunOnWhatThisIPhoneHas() throws {
        let model = AppModel(folder: folder(), keys: keys, launch: Launch(arguments: []), appleID: MemoryAppleIDStore())
        // Nothing connected: Apple on-device.
        let first = try #require(model.add(starter: StarterBot.all[0]))
        #expect(first.engine == .appleOnDevice)
        // A Claude connection becomes the default, and starters use it.
        let claude = try APIConnection.validated(name: "Claude", endpoint: APIConnection.anthropicEndpoint, model: "claude-opus-5-5", wire: .anthropic)
        try model.save(connection: ConnectionRecord(connection: claude, provider: .anthropic, models: ["claude-opus-5-5"]), key: nil)
        #expect(model.defaultModel == DefaultModel(engine: .api(profile: claude.id), model: "claude-opus-5-5"))
        let research = try #require(model.add(starter: StarterBot.all[2]))
        #expect(research.engine == .api(profile: claude.id))
        #expect(!research.engine.runsOnlyOnMac, "never a coding agent on iPhone")
    }

    @Test func syncReadsTheAppAndWhatArrivesReachesTheChat() throws {
        let model = AppModel(folder: folder(), keys: keys, launch: Launch(arguments: ["--skip-onboarding"]), appleID: MemoryAppleIDStore())
        let claude = try APIConnection.validated(name: "Claude", endpoint: APIConnection.anthropicEndpoint, model: "claude-opus-5-5", wire: .anthropic)
        try model.save(connection: ConnectionRecord(connection: claude, provider: .anthropic, models: []), key: "sk-ant-secret")
        let library = model.library
        #expect(library.connections.map(\.id) == [claude.id])
        #expect(!String(describing: library).contains("sk-ant-secret"), "keys aren't in what syncs")

        // A chat from the Mac, and a new bot, arrive.
        var rng = SeededGenerator(seed: 9)
        let pip = BotSpec.new(engine: .appleOnDevice, existing: model.bots, using: &rng)
        let fromMac = ChatThread(title: "From the Mac", botIDs: [BotSpec.kemoSabeID], messages: [Message.owner("hello from the Mac", tags: [BotSpec.kemoSabeID])])
        var next = library
        next.bots.append(pip)
        next.threads.append(fromMac)
        model.apply(library: next)
        #expect(model.bots.map(\.id).contains(pip.id))
        #expect(model.savedThreads.map(\.id) == [fromMac.id])
        #expect(model.session.threadBots.contains { $0.id == pip.id })

        // The open chat follows an edit from the Mac.
        model.open(fromMac)
        var edited = fromMac
        edited.messages.append(Message.owner("and more", tags: [BotSpec.kemoSabeID]))
        next.threads = [edited]
        model.apply(library: next)
        #expect(model.session.thread.messages.map(\.text) == ["hello from the Mac", "and more"])

        // Keeping it on this iPhone takes it out of what syncs.
        model.setKeepsOnDevice(fromMac.id, true)
        #expect(model.threads.first?.privacy == .deviceOnly)
        var ledger = SyncLedger(device: "test")
        let outbound = LibraryMapping.outbound(model.library, ledger: &ledger, now: Date())
        #expect(!outbound.contains { $0.id == "thread:" + fromMac.id.uuidString })
    }

    @Test func launchArgumentsForTheFirstRunAndPictures() {
        let launch = Launch(arguments: ["--ui-testing", "--onboarding", "--appearance=dark"])
        #expect(launch.onboarding && !launch.skipOnboarding && launch.appearance == "dark")
        #expect(Launch(arguments: ["--skip-onboarding"]).skipOnboarding)
    }
}
