import Foundation
import Observation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
import TsukumoGate
import TsukumoSystemOne
import TsukumoEngines
import TsukumoSync
import TsukumoUI

/// Everything the app keeps, and the TsukumoKit modules it runs on:
///
/// - Bots, chats, Activity, API connections, and KemoSabe's source settings: JSON files in Application
///   Support on this iPhone, one per kind, written atomically. API keys: the Keychain, this device only.
/// - TsukumoContext's `ArtifactStore` (SQLite, same folder): KemoSabe's answers and what bots may read.
/// - TsukumoGate's `Gate`: KemoSabe, with its grants and journal saved beside the rest.
/// - TsukumoEngines: Apple on-device for KemoSabe and on-device bots, `APIEngine` for API bots.
/// - TsukumoSystemOne: `route` for untagged messages (no provider on iPhone yet, so it abstains and
///   the bot last spoken to answers).
/// - TsukumoUI's `AccountStore`: the owner's account (Sign in with Apple; the Apple user ID in the
///   Keychain) and whether the first run is done.
/// - TsukumoSync's `LibrarySyncController`: bots, chats, the default model, and connections without
///   keys, in step with the owner's Mac through their private iCloud, only in a build made with the
///   iCloud capability (`CloudCapability`) and only while signed in.
///
/// UI tests and the demo use a fresh temporary folder.
@MainActor @Observable final class AppModel {
    private(set) var bots: [BotSpec] = [.kemoSabe()]
    private(set) var threads: [ChatThread] = []
    private(set) var activity: [ActivityItem] = []
    private(set) var connections: [ConnectionRecord] = []
    private(set) var sources: [SourceKind: SourceSetting] = [:]
    /// What new bots start on (it syncs).
    private(set) var defaultModel: DefaultModel?
    /// The first run shows until it's done (never in the demo or with `--skip-onboarding`).
    private(set) var needsOnboarding = false
    /// KemoSabe's journal, newest last (read from the Gate when Settings opens it).
    private(set) var journal: [GateJournalEntry] = []
    /// The chat on screen.
    private(set) var session: ChatSession!
    private(set) var gate: Gate!
    /// A save that failed, in words.
    var problem: String?

    @ObservationIgnored let folder: URL
    @ObservationIgnored let keys: any APIKeyStore
    @ObservationIgnored let launch: Launch
    @ObservationIgnored private var store: ArtifactStore!
    /// The owner's account and the first run.
    let accounts: AccountStore
    /// Sync with the owner's other devices (its status is Settings, Account's line).
    private(set) var sync: LibrarySyncController!

    init(folder: URL, keys: any APIKeyStore = KeychainAPIKeys(), launch: Launch = Launch(), appleID: (any AppleIDStore)? = nil) {
        self.folder = folder; self.keys = keys; self.launch = launch
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if launch.onboarding { try? FileManager.default.removeItem(at: folder.appendingPathComponent("account.json")) }
        accounts = AccountStore(file: launch.demo == nil ? folder.appendingPathComponent("account.json") : nil,
                                appleID: appleID ?? KeychainAppleIDStore(service: launch.uiTesting ? "com.zlichtman.tsukumo.account.ui-testing" : "com.zlichtman.tsukumo.account"))
        load()
        if launch.demo != nil { seedDemo() }
        if launch.demoActivity { seedDemoActivity() }
        do {
            store = launch.demo != nil ? try ArtifactStore() : try ArtifactStore(url: folder.appendingPathComponent("artifacts.sqlite"))
        } catch {
            problem = "Tsukumo couldn’t open its saved context. It’s kept for recovery, and this session starts fresh."
            store = try? ArtifactStore()
        }
        gate = makeGate()
        let current = launch.demo != nil ? (launch.demo == .final ? DemoFixture.finalThread : DemoFixture.emptyThread)
            : (threads.last ?? ChatThread(botIDs: bots.map(\.id)))
        session = makeSession(current)
        needsOnboarding = launch.demo == nil && !launch.skipOnboarding && !accounts.onboarded
        // iCloud only in a build that carries the capability, and never in UI tests or the demo.
        let cloud: (any CloudDatabase)? = CloudCapability.isEnabled() && !launch.uiTesting && launch.demo == nil
            ? CKCloudDatabase(containerID: CloudCapability.containerID) : nil
        sync = LibrarySyncController(database: cloud, signedIn: accounts.isSignedIn, ledgerURL: launch.demo == nil ? folder.appendingPathComponent("sync-ledger.json") : nil,
                                     devicePrefix: "iPhone", read: { [unowned self] in self.library }, apply: { [unowned self] in self.apply(library: $0) })
        accounts.onChange = { [weak self] account in self?.sync.setSignedIn(account != nil) }
        if accounts.isSignedIn { sync.syncSoon(after: 0) }
    }

    /// The app's own folder in Application Support.
    static var defaultFolder: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Tsukumo", isDirectory: true)
    }

    // MARK: The modules

    private func makeGate() -> Gate {
        if launch.demo != nil { return DemoFixture.gate(pace: launch.pace, asksFirst: launch.demo == .consent) }
        let grants: [RecipientGrant] = read([RecipientGrant].self, "grants") ?? []
        let gate = Gate(model: AppleExtractionModel(), sources: personalSources(), grants: grants,
                        journal: GateJournal(url: folder.appendingPathComponent("journal.json")), answers: store, deviceName: "iPhone")
        gate.apply(bots: bots)
        gate.onGrantsChanged = { [weak self] grants in self?.save(grants, "grants") }
        return gate
    }

    private func personalSources() -> [any PersonalSource] {
        var list: [any PersonalSource] = []
        if setting(.calendar).on { list.append(CalendarSource(level: setting(.calendar).level)) }
        if setting(.reminders).on { list.append(RemindersSource(level: setting(.reminders).level)) }
        return list
    }

    private func makeSession(_ thread: ChatThread) -> ChatSession {
        var thread = thread
        let ids = bots.map(\.id)
        thread.botIDs = thread.botIDs.filter(ids.contains) + ids.filter { !thread.botIDs.contains($0) }
        let hosts = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0.host) })
        let answerer = GateAnswerer(gate: gate) { bot in if case .api(let profile) = bot.engine { hosts[profile] } else { nil } }
        let runner: any BotTurnRunning = launch.demo != nil ? DemoFixture.runner(pace: launch.pace) : makeRunner()
        let session = ChatSession(thread: thread, bots: bots, runner: runner, gate: answerer,
                                  router: launch.demo != nil ? nil : SystemOneRouter(providers: .none))
        session.onThreadChange = { [weak self] thread in self?.keep(thread) }
        session.onActivity = { [weak self] item in self?.record(item) }
        return session
    }

    /// Each bot on its engine: Apple on-device, or its API connection.
    private func makeRunner() -> EngineRunner {
        let keys = self.keys
        let records = connections
        return EngineRunner(store: store) { bot in
            switch bot.engine {
            case .appleOnDevice:
                let model = AppleOnDeviceModel()
                guard model.isAvailable else { return .failure(.init("\(bot.name) can’t answer here. \(AppleOnDeviceModel.unavailableReason ?? "")")) }
                return .success(ResolvedEngine(engine: OnDeviceEngine(model: model), recipient: .appleOnDevice))
            case .api(let profile):
                guard let record = records.first(where: { $0.id == profile }) else {
                    return .failure(.init("\(bot.name)’s connection is gone. Pick another in its settings."))
                }
                return .success(ResolvedEngine(engine: APIEngine(connection: record.connection, keys: keys),
                                               recipient: .apiModel(profile: profile, host: record.host)))
            case .codingAgent, .acp:
                return .failure(.init("\(bot.name) runs on a Mac. Coding agents aren’t on iPhone yet."))
            case .mlx, .unknown:
                return .failure(.init("\(bot.name) can’t run on this iPhone."))
            }
        }
    }

    /// After bots or connections change: the Gate's limits and the chat's engines follow.
    private func rewire() {
        gate.apply(bots: bots)
        let thread = session.thread
        session.stopAll()
        session = makeSession(thread)
    }

    // MARK: Chats

    func newThread() {
        session.open(ChatThread(botIDs: bots.map(\.id)))
    }
    func open(_ thread: ChatThread) {
        session.open(thread)
        session.update(bots: bots)
    }
    func deleteThread(_ id: UUID) {
        threads.removeAll { $0.id == id }
        save(threads, "threads")
        if session.thread.id == id { newThread() }
        sync?.localChanged()
    }
    /// Keeps a chat on this iPhone (Device only: it leaves iCloud and the owner's other devices), or
    /// lets it sync again (Personal).
    func setKeepsOnDevice(_ id: UUID, _ keep: Bool) {
        guard let index = threads.firstIndex(where: { $0.id == id }) else { return }
        threads[index].privacy = keep ? .deviceOnly : .personal
        save(threads, "threads")
        if session.thread.id == id { session.open(threads[index]) }
        sync?.localChanged()
    }
    /// Saved chats, newest first, with something in them.
    var savedThreads: [ChatThread] {
        threads.filter { !$0.messages.isEmpty }.sorted { ($0.messages.last?.date ?? .distantPast) > ($1.messages.last?.date ?? .distantPast) }
    }

    private func keep(_ thread: ChatThread) {
        guard launch.demo == nil, !thread.messages.isEmpty else { return }
        var thread = thread
        if thread.title.isEmpty, let first = thread.messages.first(where: { $0.author == .owner }) {
            thread.title = String(first.text.prefix(60))
        }
        if let index = threads.firstIndex(where: { $0.id == thread.id }) {
            thread.privacy = threads[index].privacy
            threads[index] = thread
        } else { threads.append(thread) }
        save(threads, "threads")
        sync?.localChanged()
    }

    // MARK: Bots

    func save(bot: BotSpec) {
        // KemoSabe stays standard whatever the sheet sent; only its color changes.
        let bot = bot.normalized()
        if let index = bots.firstIndex(where: { $0.id == bot.id }) { bots[index] = bot } else { bots.append(bot) }
        save(bots, "bots")
        gate.apply(bots: bots)
        session.update(bots: bots)
        sync?.localChanged()
    }
    func remove(bot id: UUID) {
        guard id != BotSpec.kemoSabeID, let bot = bots.first(where: { $0.id == id }) else { return }
        bots.removeAll { $0.id == id }
        save(bots, "bots")
        // Its consent goes with it, unless another bot shares its connection.
        if !bots.contains(where: { $0.engine == bot.engine }) { gate.revokeConsent(recipient(bot)) }
        gate.apply(bots: bots)
        session.update(bots: bots)
        sync?.localChanged()
    }

    func recipient(_ bot: BotSpec) -> RecipientID {
        if case .api(let profile) = bot.engine { return .bot(bot, host: connections.first { $0.id == profile }?.host) }
        return .bot(bot)
    }

    /// What a new bot can run on: Apple on-device, each API connection, and (not here) coding agents.
    var engineChoices: [EngineChoice] {
        let apple = AppleOnDevice.status
        var choices = [EngineChoice(engine: .appleOnDevice, info: EngineInfo(title: "Apple on-device", detail: "On this iPhone. Nothing leaves it.", mark: .apple),
                                    wire: .apple, unavailable: apple.ready ? nil : apple.text)]
        for record in connections {
            choices.append(EngineChoice(engine: record.engine, info: info(record), models: record.models.isEmpty ? [record.connection.model] : record.models,
                                        wire: record.connection.effortWire))
        }
        if connections.isEmpty {
            choices.append(EngineChoice(engine: .unknown("api"), info: EngineInfo(title: "An API model", detail: "", mark: .generic),
                                        unavailable: "Connect one in Settings, Models."))
        }
        choices.append(EngineChoice(engine: .codingAgent("claude-code"), info: EngineInfo.standard(.codingAgent("claude-code")), unavailable: "Coding agents run on a Mac."))
        choices.append(EngineChoice(engine: .codingAgent("codex"), info: EngineInfo.standard(.codingAgent("codex")), unavailable: "Coding agents run on a Mac."))
        return choices
    }

    func info(_ record: ConnectionRecord) -> EngineInfo {
        EngineInfo(title: record.name, detail: record.provider == .compatible ? record.host : record.provider.detail, mark: record.provider.mark)
    }

    /// Names and marks for the chat (a bot only holds its connection's ID).
    var engineInfo: @Sendable (EngineID) -> EngineInfo {
        let known = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, info($0)) })
        return { engine in
            if case .api(let profile) = engine, let info = known[profile] { return info }
            return DemoFixture.engineInfo(engine)
        }
    }

    // MARK: Connections

    func save(connection record: ConnectionRecord, key: String?) throws {
        if let key { try keys.save(key, for: record.id) }
        if let index = connections.firstIndex(where: { $0.id == record.id }) { connections[index] = record } else { connections.append(record) }
        save(connections, "connections")
        if defaultModel == nil { setDefault(DefaultModel(engine: record.engine, model: record.connection.model)) }
        rewire()
        sync?.localChanged()
    }
    func remove(connection id: UUID) {
        try? keys.remove(id)
        connections.removeAll { $0.id == id }
        save(connections, "connections")
        gate.revokeConsent(.apiModel(profile: id, host: ""))
        if case .api(let profile)? = defaultModel?.engine, profile == id { setDefault(nil) }
        rewire()
        sync?.localChanged()
    }

    // MARK: The default model

    /// What new bots start on: Apple on-device or a connection, and its model. It syncs.
    func setDefault(_ model: DefaultModel?) {
        defaultModel = model
        saveDefault()
        sync?.localChanged()
    }
    private func saveDefault() {
        if let defaultModel { save(defaultModel, "defaultModel") } else if launch.demo == nil { try? FileManager.default.removeItem(at: url("defaultModel")) }
    }
    /// The engine a starter runs on here: the default model, else the connection that suits it (Claude
    /// for the homework and research starters, OpenAI for the coder), else any, else Apple on-device.
    func engine(for starter: StarterBot) -> (EngineID, String?) {
        func usable(_ engine: EngineID) -> Bool { engineChoices.contains { $0.engine == engine && $0.unavailable == nil } }
        if let model = defaultModel, usable(model.engine) { return (model.engine, model.model) }
        let preferred: ConnectionRecord.Provider = starter.engine == .codingAgent("codex") ? .openAI : .anthropic
        if let record = connections.first(where: { $0.provider == preferred }) ?? connections.first {
            return (record.engine, record.connection.model)
        }
        return (.appleOnDevice, nil)
    }
    func hasKey(_ id: UUID) -> Bool { ((try? keys.read(id)) ?? nil).map { !$0.isEmpty } ?? false }

    // MARK: KemoSabe

    func setting(_ source: SourceKind) -> SourceSetting { sources[source] ?? SourceSetting(level: source.defaultLevel) }

    /// Turns a source on (asking iOS for access first) or off, or changes its level.
    func set(_ source: SourceKind, on: Bool? = nil, level: PrivacyLevel? = nil) async {
        var value = setting(source)
        if let on {
            value.on = on ? await source.requestAccess() : false
            if on && !value.on { problem = "Tsukumo can’t read \(source.title). Allow it in Settings, Privacy & Security." }
        }
        if let level { value.level = level }
        sources[source] = value
        save(sources, "sources")
        gate.sources = personalSources()
    }

    /// The bots KemoSabe answers without asking, from the Gate's consent grants.
    var allowedBots: [BotSpec] {
        bots.filter { !$0.isKemoSabe && !gate.consentGrants(for: recipient($0)).isEmpty }
    }
    func revokeConsent(_ bot: BotSpec) { gate.revokeConsent(recipient(bot)) }

    func refreshJournal() async { journal = await gate.journal.all() }

    // MARK: Activity

    private func record(_ item: ActivityItem) {
        activity.append(item)
        activity = Array(activity.suffix(1000))
        if launch.demo == nil { save(activity, "activity") }
    }
    func clearActivity() {
        activity = []
        save(activity, "activity")
    }

    // MARK: Files

    private func url(_ name: String) -> URL { folder.appendingPathComponent(name + ".json") }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        do { return try TsukumoJSON.decoder.decode(type, from: data) } catch {
            // Keep the unreadable file for recovery rather than overwrite it.
            try? FileManager.default.moveItem(at: url(name), to: url(name + "-unreadable-\(Int(Date().timeIntervalSince1970))"))
            problem = "Some saved \(name) couldn’t be read. A copy was kept."
            return nil
        }
    }

    private func load() {
        var loaded = read([BotSpec].self, "bots") ?? []
        // KemoSabe is always there, first, and standard (decoding normalizes it).
        let kemo = (loaded.first { $0.isKemoSabe } ?? .kemoSabe()).normalized()
        loaded.removeAll { $0.isKemoSabe }
        bots = [kemo] + loaded
        threads = read([ChatThread].self, "threads") ?? []
        activity = read([ActivityItem].self, "activity") ?? []
        connections = read([ConnectionRecord].self, "connections") ?? []
        sources = read([SourceKind: SourceSetting].self, "sources") ?? [:]
        defaultModel = read(DefaultModel.self, "defaultModel")
    }

    // MARK: Sync

    /// What syncs: bots, chats, the default model, and connections (never their keys).
    var library: SyncLibrary {
        SyncLibrary(bots: bots, threads: threads, defaultModel: defaultModel, connections: connections.map {
            APIConnectionRecord(id: $0.id, name: $0.name, endpoint: $0.connection.endpoint, model: $0.connection.model, wire: $0.provider.rawValue)
        })
    }

    /// Takes what the owner's other devices changed.
    func apply(library: SyncLibrary) {
        let kemo = (library.bots.first { $0.isKemoSabe } ?? bots[0]).normalized()
        bots = [kemo] + library.bots.filter { !$0.isKemoSabe }.map { $0.normalized() }
        save(bots, "bots")
        threads = library.threads
        save(threads, "threads")
        if library.defaultModel != defaultModel { defaultModel = library.defaultModel; saveDefault() }
        var records: [ConnectionRecord] = []
        for synced in library.connections {
            if let kept = connections.first(where: { $0.id == synced.id }), kept.connection.endpoint == synced.endpoint,
               kept.connection.model == synced.model, kept.name == synced.name {
                records.append(kept)
                continue
            }
            let provider = ConnectionRecord.Provider(rawValue: synced.wire) ?? .compatible
            if let connection = try? APIConnection.validated(id: synced.id, name: synced.name, endpoint: synced.endpoint.absoluteString,
                                                             model: synced.model, wire: provider.wire) {
                records.append(ConnectionRecord(connection: connection, provider: provider,
                                                models: connections.first { $0.id == synced.id }?.models ?? []))
            }
        }
        let connectionsChanged = records != connections
        connections = records
        save(connections, "connections")
        if connectionsChanged { rewire() }
        gate.apply(bots: bots)
        // The chat on screen follows unless it's mid-turn (its next save merges again).
        if !session.isBusy {
            if let current = threads.first(where: { $0.id == session.thread.id }) {
                if current != session.thread { session.open(current) }
            } else if !session.thread.messages.isEmpty {
                session.open(ChatThread(botIDs: bots.map(\.id)))
            }
        }
        session.update(bots: bots)
    }

    // MARK: The first run

    func finishOnboarding() {
        needsOnboarding = false
        newThread()
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard launch.demo == nil else { return }
        do {
            let data = try TsukumoJSON.encoder.encode(value)
            try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            problem = "Couldn’t save \(name): \(error.localizedDescription)"
        }
    }

    // MARK: The demo

    private func seedDemo() {
        if let claude = try? APIConnection.validated(id: DemoFixture.claudeProfile, name: "Claude", endpoint: APIConnection.anthropicEndpoint,
                                                     model: "claude-opus-5-5", wire: .anthropic) {
            connections = [ConnectionRecord(connection: claude, provider: .anthropic, models: ["claude-opus-5-5"])]
        }
        bots = [.kemoSabe(), DemoFixture.claude]
        threads = []
    }

    private func seedDemoActivity() {
        let now = Date()
        let card = DemoFixture.answerCard(exchange: GateExchangeID())
        activity = [
            ActivityItem(date: now.addingTimeInterval(-3 * 3600), kind: .systemOne, title: "Sent to Claude",
                         detail: "No bot was tagged, so it went to the bot you last talked to.", botID: DemoFixture.claudeID),
            ActivityItem(date: now.addingTimeInterval(-26 * 3600), kind: .kemoSabeRefusal, title: "Didn’t answer Claude",
                         detail: "“Where is Sarah right now?” You said Don’t allow.", botID: DemoFixture.claudeID),
            ActivityItem.gate(card, botID: DemoFixture.claudeID, threadID: nil, date: now.addingTimeInterval(-120)),
            ActivityItem(date: now.addingTimeInterval(-60), kind: .botWork, title: "Claude replied",
                         detail: DemoFixture.result, botID: DemoFixture.claudeID)
        ]
        if !bots.contains(where: { $0.id == DemoFixture.claudeID }) { bots.append(DemoFixture.claude) }
    }
}

/// Whether this iPhone can run Apple's on-device model, in words for Settings.
enum AppleOnDevice {
    static var status: (ready: Bool, text: String) {
        AppleOnDeviceModel().isAvailable ? (true, "Ready on this iPhone") : (false, AppleOnDeviceModel.unavailableReason ?? "Apple Intelligence isn’t available right now.")
    }
}

/// How the app was launched (UI tests and the demo pass arguments).
struct Launch: Sendable {
    enum Demo: String, Sendable { case play, final, consent }
    /// Fresh, temporary storage.
    var uiTesting = false
    /// Plays the website demo (`--demo-fixture`), shows its final frame (`--demo-final`), or plays it
    /// with the first-time consent card (`--consent-fixture`).
    var demo: Demo?
    /// Scales the demo's pauses (`--demo-pace=0.2`).
    var pace = 1.0
    /// Fills Activity with a few examples (`--demo-activity`).
    var demoActivity = false
    /// What to open on launch (`--open=drawer`, `--open=activity`, `--open=settings`).
    var open: String?
    /// Opens the add-bot sheet (`--create-bot`).
    var createBot = false
    /// Starts the first run over (`--onboarding`), or skips it (`--skip-onboarding`, what most UI tests use).
    var onboarding = false
    var skipOnboarding = false
    /// Light or dark whatever the system says (`--appearance=dark`), for screenshots.
    var appearance: String?

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        uiTesting = arguments.contains("--ui-testing")
        if arguments.contains("--demo-fixture") { demo = .play }
        if arguments.contains("--demo-final") { demo = .final }
        if arguments.contains("--consent-fixture") { demo = .consent }
        demoActivity = arguments.contains("--demo-activity")
        createBot = arguments.contains("--create-bot")
        onboarding = arguments.contains("--onboarding")
        skipOnboarding = arguments.contains("--skip-onboarding")
        for argument in arguments {
            if argument.hasPrefix("--demo-pace="), let value = Double(argument.dropFirst("--demo-pace=".count)) { pace = value }
            if argument.hasPrefix("--open=") { open = String(argument.dropFirst("--open=".count)) }
            if argument.hasPrefix("--appearance=") { appearance = String(argument.dropFirst("--appearance=".count)) }
        }
    }
}
