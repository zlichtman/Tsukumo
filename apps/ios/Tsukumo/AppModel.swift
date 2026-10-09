import Foundation
import Observation
import TsukumoCore
import TsukumoPolicy
import TsukumoContext
import TsukumoGate
import TsukumoSystemOne
import TsukumoEngines
import TsukumoSync
import TsukumoVoice
import TsukumoMLXVoice
import TsukumoLaya
import TsukumoUI
import UIKit

/// Everything the app keeps, and the TsukumoKit modules it runs on:
///
/// - The bots (KemoSabe and the owner's bots, made here or on their Mac; on this iPhone, those that run here: Apple
///   on-device, or an API model with a key), chats, Activity, API connections, and KemoSabe's source settings: JSON
///   files in Application Support on this iPhone, one per kind, written atomically. API keys: the Keychain, this
///   device only.
/// - TsukumoContext's `ArtifactStore` (SQLite, same folder): KemoSabe's answers and what bots may read.
/// - TsukumoGate's `Gate`: KemoSabe, with its grants and journal saved beside the rest.
/// - TsukumoEngines: Apple on-device for KemoSabe and on-device bots, `APIEngine` for API bots.
/// - TsukumoSystemOne: `route` for untagged messages and `selectContext` for each turn, through TsukumoUI's
///   `SystemOneCenter`: Laya on this iPhone once downloaded, then the hosted models the owner turned on,
///   and when all abstain the bot last spoken to answers.
/// - TsukumoUI's `AccountStore`: the owner's account (Sign in with Apple; the Apple user ID in the
///   Keychain) and whether the first run is done.
/// - TsukumoSync's `LibrarySyncController`: bots, chats, the default model, and connections without
///   keys, in step with the owner's Mac through their private iCloud, only in a build made with the
///   iCloud capability (`CloudCapability`) and only while signed in.
///
/// UI tests and the demo use a fresh temporary folder.
@MainActor @Observable final class AppModel {
    /// KemoSabe and the owner's bots (saved as `bots.json`), including those that run only on their Mac (kept, so sync
    /// never takes them off it).
    private(set) var saved: [BotSpec] = [.kemoSabe()]
    /// KemoSabe, then the owner's bots that run on this iPhone: Apple on-device, or an API model with a key here.
    var bots: [BotSpec] { BotLineup.bots(kemoSabe: saved[0], saved: saved).filter { $0.isKemoSabe || runsHere($0) } }
    /// Whether a bot runs on this iPhone.
    func runsHere(_ bot: BotSpec) -> Bool {
        switch bot.engine {
        case .appleOnDevice: true
        case .api(let profile): launch.demo != nil || keyed.contains(profile)
        default: false
        }
    }
    /// Which services are connected on this iPhone (its API keys; coding agents and the gateway are a Mac's).
    var services: ServiceConnections {
        let usable = connections.filter { launch.demo != nil || keyed.contains($0.id) }
        return ServiceConnections(claudeAPI: usable.first { $0.provider == .anthropic }?.id, openAIAPI: usable.first { $0.provider == .openAI }?.id,
                                  isMac: false)
    }
    /// The connections with a key in this iPhone's Keychain (read when connections change, not on every look).
    private(set) var keyed: Set<UUID> = []
    private func refreshKeyed() { keyed = Set(connections.filter { hasKey($0.id) }.map(\.id)) }
    /// What 2.05's lineup retired on the owner's Mac, kept for good so sync maps old IDs onto what they became.
    private(set) var aliases = LineupAliases()
    private(set) var threads: [ChatThread] = []
    private(set) var activity: [ActivityItem] = []
    private(set) var connections: [ConnectionRecord] = []
    /// What KemoSabe may read (`sources.json`, this iPhone only), and the Gate's sources made from it.
    let sources: SourceLibrary
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
    /// Listening and speaking (not in the demo): the composer's microphone, holding a bot's chip, and replies
    /// spoken in each bot's voice.
    @ObservationIgnored let voice: VoiceHub?
    /// System One (not in the demo): Laya on this iPhone, then the hosted models turned on, for untagged
    /// messages and each turn's context.
    @ObservationIgnored let systemOne: SystemOneCenter?
    @ObservationIgnored private var store: ArtifactStore!
    /// The owner's account and the first run.
    let accounts: AccountStore
    /// Sync with the owner's other devices (its status is Settings, Account's line).
    private(set) var sync: LibrarySyncController!

    init(folder: URL, keys: any APIKeyStore = KeychainAPIKeys(), systemOneKeys: (any APIKeyStore)? = nil, launch: Launch = Launch(), appleID: (any AppleIDStore)? = nil) {
        self.folder = folder; self.keys = keys; self.launch = launch
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let models = folder.appendingPathComponent("VoiceModels", isDirectory: true)
        systemOne = launch.demo == nil ? Self.makeSystemOne(folder: folder, models: models, keys: systemOneKeys ?? MemoryAPIKeys()) : nil
        voice = launch.demo == nil
            ? VoiceHub(folder: models, settingsURL: folder.appendingPathComponent("voice.json"), deviceName: "iPhone",
                       runtime: MLXVoiceRuntime(cacheFolder: models))
            : nil
        if launch.onboarding { try? FileManager.default.removeItem(at: folder.appendingPathComponent("account.json")) }
        accounts = AccountStore(file: launch.demo == nil ? folder.appendingPathComponent("account.json") : nil,
                                appleID: appleID ?? KeychainAppleIDStore(service: launch.uiTesting ? "com.zlichtman.tsukumo.account.ui-testing" : "com.zlichtman.tsukumo.account"))
        // UI tests and the demo read nothing of the owner's: stand-in permissions that never ask iOS, sources
        // that read nothing, and a connector that "connects" without the network.
        sources = launch.uiTesting || launch.demo != nil
            ? SourceLibrary(file: launch.demo == nil ? folder.appendingPathComponent("sources.json") : nil, authorizer: StandInSourceAuthorizer(),
                            factory: .empty, tokens: KeychainConnectorTokens(service: "com.zlichtman.tsukumo.connectors.ui-testing"),
                            discover: { _, _ in [MCPTool(name: "search", argument: "query")] })
            : SourceLibrary(file: folder.appendingPathComponent("sources.json"), authorizer: SystemSourceAuthorizer(messages: nil),
                            factory: .system(messages: nil, sharedMessages: SharedMessagesStore(folder: folder.appendingPathComponent("shared-messages"))),
                            tokens: KeychainConnectorTokens(service: "com.zlichtman.tsukumo.connectors"))
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
        sources.onChange = { [weak self] in
            guard let self, self.launch.demo == nil else { return }
            self.gate.sources = self.sources.sources()
        }
        let current = launch.demo != nil ? (launch.demo == .final ? DemoFixture.finalThread : DemoFixture.emptyThread)
            : (threads.last ?? ChatThread(botIDs: bots.filter(\.engine.chats).map(\.id)))
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

    /// Laya beside the voice models (device data, excluded from backup, never synced), loaded at launch once
    /// it's ready and let go when the app goes to the background or memory runs low; hosted models' keys in
    /// this iPhone's Keychain only.
    private static func makeSystemOne(folder: URL, models: URL, keys: any APIKeyStore) -> SystemOneCenter {
        let provider = CoreMLLayaProvider(directory: models.appendingPathComponent(VoiceModelPack.laya.id).appendingPathComponent("model"),
                                          tokenizer: LayaBundleTokenizer.make)
        let laya = LayaModel(root: models, provider: provider)
        laya.start()
        for name in [UIApplication.didReceiveMemoryWarningNotification, UIApplication.didEnterBackgroundNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in Task { await provider.unload() } }
        }
        return SystemOneCenter(folder: folder, keys: keys, deviceName: "iPhone", laya: laya, local: provider)
    }

    private func makeGate() -> Gate {
        if launch.demo != nil { return DemoFixture.gate(pace: launch.pace, asksFirst: launch.demo == .consent) }
        let grants: [RecipientGrant] = read([RecipientGrant].self, "grants") ?? []
        let gate = Gate(model: AppleExtractionModel(), sources: personalSources(), grants: grants,
                        journal: GateJournal(url: folder.appendingPathComponent("journal.json")), answers: store, deviceName: "iPhone")
        gate.apply(bots: bots)
        gate.onGrantsChanged = { [weak self] grants in self?.save(grants, "grants") }
        return gate
    }

    private func personalSources() -> [any PersonalSource] { sources.sources() }

    private func makeSession(_ thread: ChatThread) -> ChatSession {
        var thread = thread
        let ids = bots.filter(\.engine.chats).map(\.id)
        thread.botIDs = thread.botIDs.filter(ids.contains) + ids.filter { !thread.botIDs.contains($0) }
        let hosts = Dictionary(uniqueKeysWithValues: connections.map { ($0.id, $0.host) })
        let answerer = GateAnswerer(gate: gate) { bot in if case .api(let profile) = bot.engine { hosts[profile] } else { nil } }
        let runner: any BotTurnRunning = launch.demo != nil ? DemoFixture.runner(pace: launch.pace) : makeRunner()
        let session = ChatSession(thread: thread, bots: bots, runner: runner, gate: answerer, router: systemOne?.router())
        session.onThreadChange = { [weak self] thread in self?.keep(thread) }
        session.onActivity = { [weak self] item in self?.record(item) }
        session.voice = voice
        return session
    }

    /// Each bot on its engine: Apple on-device, or its API connection.
    private func makeRunner() -> EngineRunner {
        let keys = self.keys
        let records = connections
        var selectContext: (@Sendable (BotTurn) async -> any ReferenceChooser)?
        if let router = systemOne?.router() { selectContext = { turn in await router.chooser(for: turn) } }
        return EngineRunner(store: store, selectContext: selectContext) { bot in
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
            case .service:
                return .failure(.init("\(bot.name) doesn’t chat in Tsukumo. It asks KemoSabe through your Mac’s gateway."))
            case .mlx, .unknown:
                return .failure(.init("\(bot.name) can’t run on this iPhone."))
            }
        }
    }

    /// After bots or connections change: the Gate's limits and the chat's engines follow.
    private func rewire() {
        refreshKeyed()
        gate.apply(bots: bots)
        let thread = session.thread
        session.stopAll()
        session = makeSession(thread)
    }

    // MARK: Chats

    func newThread() {
        session.open(ChatThread(botIDs: bots.filter(\.engine.chats).map(\.id)))
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
            // The session only holds the bots that chat on this iPhone. A member it can't run here (the Mac's coding
            // agents, a service not connected on this iPhone) stays in the chat, in its place, so sync never takes it
            // off the owner's other devices.
            let here = Set(bots.filter(\.engine.chats).map(\.id))
            let shown = thread.botIDs
            thread.botIDs = threads[index].botIDs.filter { !here.contains($0) || shown.contains($0) } + shown.filter { !threads[index].botIDs.contains($0) }
            threads[index] = thread
        } else { threads.append(thread) }
        save(threads, "threads")
        sync?.localChanged()
    }

    // MARK: Bots

    /// Saves what the owner set on KemoSabe (its palette and voice) or one of their bots. KemoSabe stays standard
    /// whatever the sheet sent; another bot's name is its own, and where it's from never changes.
    @discardableResult func save(bot: BotSpec) -> BotProblem? {
        guard let index = saved.firstIndex(where: { $0.id == bot.id }) else { return BotProblem("That bot isn’t here any more.") }
        var next = bot
        if !bot.isKemoSabe {
            next.origin = saved[index].origin
            if case .made = next.origin, next.engine != saved[index].engine { next.service = service(of: next.engine) }
            switch next.validated(existing: saved) {
            case .failure(let problem): return problem
            case .success(let clean): next = clean
            }
            if next.engine != saved[index].engine { next.model = nil; next.effort = nil }
        }
        var bots = saved
        bots[index] = next.normalized()
        return commit(bots)
    }
    /// Adds a bot the owner made here, at the end.
    @discardableResult func add(bot: BotSpec) -> Result<BotSpec, BotProblem> {
        guard !bot.isKemoSabe, !saved.contains(where: { $0.id == bot.id }) else { return .failure(BotProblem("That bot is already here.")) }
        guard saved.count - 1 < BotLineup.maxBots else { return .failure(BotProblem("You have \(BotLineup.maxBots) bots besides KemoSabe. Remove one to add another.")) }
        var bot = bot
        bot.origin = .made
        bot.service = service(of: bot.engine)
        switch bot.validated(existing: saved) {
        case .failure(let problem): return .failure(problem)
        case .success(let clean):
            if let problem = commit(saved + [clean]) { return .failure(problem) }
            return .success(clean)
        }
    }
    /// Removes one of the owner's bots, everywhere (sync takes it off their other devices too). Its chats stay.
    /// A removed bot's turn stops at once.
    @discardableResult func remove(bot id: UUID) -> BotProblem? {
        guard id != BotSpec.kemoSabeID, saved.contains(where: { $0.id == id }) else { return nil }
        return commit(saved.filter { $0.id != id })
    }
    /// Writes the bots and takes them, or leaves everything as it was and says why. The chat follows (a bot that left
    /// stops), and sync hears of it.
    private func commit(_ next: [BotSpec]) -> BotProblem? {
        if launch.demo == nil {
            do { try write(next, "bots") } catch {
                return BotProblem("Tsukumo couldn’t save your bots (\(error.localizedDescription)), so that change wasn’t made.")
            }
        }
        saved = next
        gate.apply(bots: bots)
        session.update(bots: bots)
        sync?.localChanged()
        return nil
    }

    /// Which service an API connection is (Claude or OpenAI), from a snapshot of `records`.
    static func apiService(_ records: [ConnectionRecord]) -> (UUID) -> ServiceID? {
        { id in
            switch records.first(where: { $0.id == id })?.provider {
            case .anthropic?: .claude
            case .openAI?: .openAI
            default: nil
            }
        }
    }
    /// The service an engine is, for a bot's mark.
    func service(of engine: EngineID) -> ServiceID? { ServiceID.of(engine, apiService: Self.apiService(connections)) }

    func recipient(_ bot: BotSpec) -> RecipientID {
        if case .api(let profile) = bot.engine { return .bot(bot, host: connections.first { $0.id == profile }?.host) }
        return .bot(bot)
    }

    /// The models each connection offers, for a service bot's model and effort.
    /// What a bot made here can run on: Apple on-device, then each API connection (one without a key here, greyed).
    var engineChoices: [EngineChoice] {
        [EngineChoice(engine: .appleOnDevice, info: EngineInfo(title: "Apple on-device", detail: "On this iPhone. Nothing leaves it.", mark: .apple))]
            + connections.map { record in
                EngineChoice(engine: record.engine, info: info(record), models: record.models.isEmpty ? [record.connection.model] : record.models,
                             wire: record.connection.effortWire, unavailable: launch.demo != nil || keyed.contains(record.id) ? nil : "Add its key in Models.")
            }
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
    func hasKey(_ id: UUID) -> Bool { ((try? keys.read(id)) ?? nil).map { !$0.isEmpty } ?? false }

    // MARK: KemoSabe

    /// Messages the owner's Shortcuts automation gave KemoSabe, on this iPhone.
    var sharedMessages: SharedMessagesStore { SharedMessagesStore(folder: folder.appendingPathComponent("shared-messages")) }

    /// The bots KemoSabe answers without asking, from the Gate's consent grants.
    var allowedBots: [BotSpec] {
        bots.filter { !$0.isKemoSabe && !gate.consentGrants(for: recipient($0)).isEmpty }
    }
    func revokeConsent(_ bot: BotSpec) { gate.revokeConsent(recipient(bot)) }

    func refreshJournal() async { journal = gate.journal.all() }

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
        saved = [kemo] + loaded
        threads = read([ChatThread].self, "threads") ?? []
        activity = read([ActivityItem].self, "activity") ?? []
        connections = read([ConnectionRecord].self, "connections") ?? []
        refreshKeyed()
        defaultModel = read(DefaultModel.self, "defaultModel")
        aliases = read(LineupRecord.self, "lineup")?.aliases ?? LineupAliases()
    }

    // MARK: Sync

    /// What syncs: KemoSabe and the owner's bots, chats, the default model, and connections (never their keys).
    var library: SyncLibrary {
        SyncLibrary(bots: saved, threads: threads, defaultModel: defaultModel, connections: connections.map {
            APIConnectionRecord(id: $0.id, name: $0.name, endpoint: $0.connection.endpoint, model: $0.connection.model, wire: $0.provider.rawValue)
        }, aliases: aliases)
    }

    /// Takes what the owner's other devices changed.
    func apply(library: SyncLibrary) {
        // The connections first, so a bot that arrives with its connection runs here.
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
        // Another device's aliases (they only grow), then chats already mapped through them (`LibraryMapping`); a bot
        // 2.05's lineup retired is an alias, never brought back.
        if library.aliases != aliases {
            aliases.add(library.aliases)
            save(LineupRecord(version: 1, aliases: aliases), "lineup")
        }
        let kemo = (library.bots.first { $0.isKemoSabe } ?? saved[0]).normalized()
        saved = [kemo] + BotLineup.oneEach(library.bots.filter { !$0.isKemoSabe && !aliases.retires(bot: $0.id) }.map { $0.normalized() })
        threads = library.threads
        save(threads, "threads")
        save(saved, "bots")
        if library.defaultModel != defaultModel { defaultModel = library.defaultModel; saveDefault() }
        if connectionsChanged { rewire() }
        gate.apply(bots: bots)
        // The chat on screen follows unless it's mid-turn (its next save merges again).
        if !session.isBusy {
            if let current = threads.first(where: { $0.id == session.thread.id }) {
                if current != session.thread { session.open(current) }
            } else if !session.thread.messages.isEmpty {
                session.open(ChatThread(botIDs: bots.filter(\.engine.chats).map(\.id)))
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
        do { try write(value, name) } catch {
            problem = "Couldn’t save \(name): \(error.localizedDescription)"
        }
    }
    /// Writes one file atomically, or throws.
    private func write<T: Encodable>(_ value: T, _ name: String) throws {
        let data = try TsukumoJSON.encoder.encode(value)
        try data.write(to: url(name), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: The demo

    private func seedDemo() {
        if let claude = try? APIConnection.validated(id: DemoFixture.claudeProfile, name: "Claude", endpoint: APIConnection.anthropicEndpoint,
                                                     model: "claude-opus-5-5", wire: .anthropic) {
            connections = [ConnectionRecord(connection: claude, provider: .anthropic, models: ["claude-opus-5-5"])]
        }
        saved = [.kemoSabe(), DemoFixture.claude]
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
        if !saved.contains(where: { $0.id == DemoFixture.claudeID }) { saved.append(DemoFixture.claude) }
    }
}

/// What `lineup.json` keeps: what 2.05's lineup retired on the owner's other devices (from sync), for good.
struct LineupRecord: Codable {
    var version: Int
    /// The retired bots and merged chats.
    var aliases: LineupAliases?
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
        onboarding = arguments.contains("--onboarding")
        skipOnboarding = arguments.contains("--skip-onboarding")
        for argument in arguments {
            if argument.hasPrefix("--demo-pace="), let value = Double(argument.dropFirst("--demo-pace=".count)) { pace = value }
            if argument.hasPrefix("--open=") { open = String(argument.dropFirst("--open=".count)) }
            if argument.hasPrefix("--appearance=") { appearance = String(argument.dropFirst("--appearance=".count)) }
        }
    }
}
