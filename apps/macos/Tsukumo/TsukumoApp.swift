import AppKit
import Observation
import SwiftUI
import TsukumoCore
import TsukumoContext
import TsukumoEngines
import TsukumoGate
import TsukumoPolicy
import TsukumoSync
import TsukumoUI
import TsukumoDock

// Tsukumo for Mac: your bots' side dock (TsukumoKit's TsukumoDock), from the menu bar. Opening it shows
// the side dock, always; the first run (TsukumoUI's `OnboardingFlow`, the same as the iPhone's) comes
// first, in its own window. Settings is a window of its own (⌘,). `--demo` plays the website demo on the
// dock and saves nothing; `--ui-testing` starts from a fresh temporary folder with its own Keychain items,
// a stand-in for Sign in with Apple, and a stand-in login item, so nothing of the owner's is touched.

@main
struct TsukumoApp: App {
    @NSApplicationDelegateAdaptor(TsukumoDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarMenu(app: delegate)
        } label: {
            Image("MenuBarMark")
        }
    }
}

/// The menu bar item's menu: short and plain.
struct MenuBarMenu: View {
    let app: TsukumoDelegate
    var body: some View {
        Button(app.controller?.isHidden == false && (app.accounts.onboarded || app.isDemo) ? "Hide Dock" : "Show Dock") { app.toggleDock() }
        Button("Open Together") { app.open(.together) }
        Button("Add a Bot…") { app.open(.edit(nil)) }
        Divider()
        Button("Settings…") { app.showSettings() }.keyboardShortcut(",")
        Divider()
        Button("Quit Tsukumo") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}

@MainActor @Observable final class TsukumoDelegate: NSObject, NSApplicationDelegate, OnboardingHost {
    private(set) var dock: BotDock?
    private(set) var controller: BotDockController?
    let isDemo = CommandLine.arguments.contains("--demo")
    /// `--ui-testing`: a fresh temporary folder, its own Keychain items, and stand-ins for Sign in with
    /// Apple and the login item.
    let isTesting = CommandLine.arguments.contains("--ui-testing")
    @ObservationIgnored let storage: Storage
    let accounts: AccountStore
    @ObservationIgnored let keys: KeychainAPIKeys
    private(set) var connections: [ConnectionRecord]
    private(set) var sources: [PersonalSourceKind: PersonalSourceSetting]
    private(set) var sync: LibrarySyncController?
    let launchAtLogin: LaunchAtLogin
    /// Why the move from the preview's folder didn't finish (shown in Settings, General).
    private(set) var migrationProblem: String?
    @ObservationIgnored private(set) var onboardingWindow: NSWindow?
    @ObservationIgnored private(set) var settings: SettingsWindow?

    override init() {
        let arguments = CommandLine.arguments
        let testing = arguments.contains("--ui-testing")
        let folder = testing
            ? FileManager.default.temporaryDirectory.appendingPathComponent("Tsukumo-\(UUID().uuidString)", isDirectory: true)
            : Storage.standard
        storage = Storage(folder: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let service = testing ? "com.zlichtman.tsukumo.mac.ui-testing" : "com.zlichtman.tsukumo.mac"
        keys = KeychainAPIKeys(service: service + ".api-keys")
        let appleID = KeychainAppleIDStore(service: service + ".account")

        // The preview's files and Keychain items, once (with `--ui-testing`, only from a folder the
        // DEBUG argument `--preview-folder` names, and never from the owner's Keychain).
        var previewFolder: URL? = testing ? nil : Storage.preview
        #if DEBUG
        if testing, let index = arguments.firstIndex(of: "--preview-folder"), index + 1 < arguments.count {
            previewFolder = URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        #endif
        var problem: String?
        if let previewFolder, !arguments.contains("--demo") {
            switch PreviewMigration.run(from: previewFolder, to: folder) {
            case .moved:
                if !testing {
                    PreviewMigration.moveKeys(connections: Storage(folder: folder).connections(),
                                              from: KeychainAPIKeys(service: "com.zlichtman.tsukumo.preview.api-keys"), to: keys,
                                              appleID: KeychainAppleIDStore(service: "com.zlichtman.tsukumo.preview.account"), to: appleID)
                }
            case .nothingToDo: break
            case .failed(let why): problem = "Your bots from before couldn’t be moved yet (\(why)). They’re still in “Tsukumo Preview”; Tsukumo tries again next time it opens."
            }
        }
        migrationProblem = problem
        if arguments.contains("--onboarding") { try? FileManager.default.removeItem(at: storage.account) }
        accounts = AccountStore(file: storage.account, appleID: appleID)
        connections = storage.connections()
        sources = storage.read([PersonalSourceKind: PersonalSourceSetting].self, "sources.json") ?? [:]
        launchAtLogin = LaunchAtLogin(item: testing ? StandInLoginItem() : SystemLoginItem(), defaults: testing ? nil : .standard)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let dock: BotDock
        if isDemo {
            dock = BotDock.demo()
        } else {
            let store = BotDockStore(file: storage.dock)
            let grants = storage.read([RecipientGrant].self, "grants.json") ?? []
            let artifacts = try? ArtifactStore(url: storage.artifacts)
            let resolve = engineResolver()
            dock = BotDock.standard(store: store, sources: PersonalSourceKind.sources(sources), grants: grants,
                                    journal: GateJournal(url: storage.journal), artifacts: artifacts, resolve: resolve)
            dock.gate?.onGrantsChanged = { [weak self] grants in self?.storage.write(grants, "grants.json") }
            dock.upcoming = EventKitDockSource()
            dock.allowedSources = { Set(DockChirpSource.allCases.filter(EventKitDockSource.permitted)) }
            dock.onChirp = { [weak dock] in if dock?.settings.chirpSounds == true { NSSound(named: "Pop")?.play() } }
            dock.startChirps()
        }
        dock.openSettings = { [weak self] in self?.showSettings() }
        self.dock = dock
        refreshEngines()
        startSync(dock)
        let controller = BotDockController(dock: dock)
        self.controller = controller
        if !isDemo && !accounts.onboarded {
            showOnboarding()
        } else {
            controller.apply()
            if !isDemo { launchAtLogin.turnOnByDefault(appPath: Bundle.main.bundlePath) }
        }
        if isDemo {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                controller.open(.bot(DemoFixture.claudeID))
                await dock.playDemo()
            }
        }
        #if DEBUG
        startCapture()
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        dock?.shutDown()
        controller?.close()
    }

    // MARK: The menu

    func toggleDock() {
        guard accounts.onboarded || isDemo else { showOnboarding(); return }
        guard let controller else { return }
        controller.setHidden(!controller.isHidden)
    }
    func open(_ surface: DockSurface) {
        guard accounts.onboarded || isDemo else { showOnboarding(); return }
        controller?.open(surface)
    }
    func showSettings(_ section: SettingsSection? = nil) {
        if settings == nil { settings = SettingsWindow(app: self) }
        settings?.show(section)
    }

    // MARK: The first run

    func showOnboarding() {
        if let onboardingWindow { NSApp.activate(); onboardingWindow.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 720), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Welcome to Tsukumo"
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.contentView = onboardingView(start: .welcome)
        window.center()
        onboardingWindow = window
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func onboardingView(start: OnboardingFlow<TsukumoDelegate>.Step) -> NSView {
        var names: @Sendable (EngineID) -> EngineInfo = { EngineInfo.standard($0) }
        if let dock { names = dock.engineInfo }
        return NSHostingView(rootView: OnboardingFlow(host: self, start: start).environment(\.engineInfo, names))
    }

    var deviceName: String { "Mac" }
    /// The stand-in for Sign in with Apple while testing; DEBUG `--real-sign-in` shows Apple's own button.
    var fixtureSignIn: Bool { isTesting && !CommandLine.arguments.contains("--real-sign-in") }
    var appleIntelligence: (ready: Bool, text: String) {
        AppleOnDeviceModel().isAvailable ? (true, "Ready on this Mac") : (false, AppleOnDeviceModel.unavailableReason ?? "Apple Intelligence isn’t available right now.")
    }
    private func provider(_ provider: OnboardingProvider) -> ConnectionRecord.Provider { provider == .claude ? .anthropic : .openAI }
    func isConnected(_ provider: OnboardingProvider) -> Bool {
        connections.contains { $0.provider == self.provider(provider) && hasKey($0.id) }
    }
    /// Checks the key against the provider's model list, then saves the connection (the key into this
    /// Mac's Keychain only).
    func connect(_ provider: OnboardingProvider, key: String) async throws {
        let kind = self.provider(provider)
        if let detected = ConnectionRecord.Provider.detect(key: key), detected != kind { throw ModelCatalog.Failure.key }
        guard let endpoint = URL(string: kind.endpoint) else { throw ModelCatalog.Failure.unreachable }
        let models = try await ModelCatalog.models(provider: kind, endpoint: endpoint, key: key)
        let model = models.contains(kind.defaultModel) ? kind.defaultModel : models.first ?? kind.defaultModel
        let connection = try APIConnection.validated(id: connections.first { $0.provider == kind }?.id ?? UUID(), name: kind.title,
                                                     endpoint: kind.endpoint, model: model, wire: kind.wire)
        try save(connection: ConnectionRecord(connection: connection, provider: kind, models: models), key: key)
    }
    var onboardingSources: [OnboardingSource] {
        PersonalSourceKind.allCases.map { OnboardingSource(id: $0.rawValue, title: $0.title, symbol: $0.symbol, on: setting($0).on, level: setting($0).level) }
    }
    func setSource(_ id: String, on: Bool) async {
        guard let kind = PersonalSourceKind(rawValue: id) else { return }
        await set(kind, on: on)
    }
    func setSource(_ id: String, level: PrivacyLevel) async {
        guard let kind = PersonalSourceKind(rawValue: id) else { return }
        await set(kind, level: level)
    }
    var bots: [BotSpec] { dock?.bots ?? [.kemoSabe()] }
    var engineChoices: [EngineChoice] { dock?.engineChoices ?? BotDock.macEngines }
    func add(starter: StarterBot) -> BotSpec? {
        guard let dock else { return nil }
        var bot = starter.bot(existing: dock.bots)
        bot.model = dock.engineChoices.first { $0.engine == bot.engine }?.models.first
        return try? dock.add(bot).get()
    }
    func save(bot: BotSpec) {
        guard let dock else { return }
        if dock.bot(bot.id) == nil { dock.add(bot) } else { dock.update(bot) }
    }
    func remove(bot id: UUID) { dock?.remove(id) }
    func finishOnboarding() {
        onboardingWindow?.close()
        onboardingWindow = nil
        controller?.apply()
        launchAtLogin.turnOnByDefault(appPath: Bundle.main.bundlePath)
    }

    // MARK: Connections and KemoSabe's sources

    func hasKey(_ id: UUID) -> Bool { ((try? keys.read(id)) ?? nil).map { !$0.isEmpty } ?? false }

    /// Saves a connection (and its key, into this Mac's Keychain). The first one becomes the default.
    func save(connection record: ConnectionRecord, key: String?) throws {
        if let key { try keys.save(key, for: record.id) }
        if let index = connections.firstIndex(where: { $0.id == record.id }) { connections[index] = record } else { connections.append(record) }
        storage.save(connections: connections)
        if dock?.store.defaultModel == nil { dock?.store.setDefaultModel(DefaultModel(engine: record.engine, model: record.connection.model)) }
        refreshEngines()
        sync?.localChanged()
    }
    func remove(connection id: UUID) {
        try? keys.remove(id)
        connections.removeAll { $0.id == id }
        storage.save(connections: connections)
        if case .api(let profile)? = dock?.store.defaultModel?.engine, profile == id { dock?.store.setDefaultModel(nil) }
        refreshEngines()
        sync?.localChanged()
    }

    func setting(_ source: PersonalSourceKind) -> PersonalSourceSetting { sources[source] ?? PersonalSourceSetting(level: source.defaultLevel) }
    /// Turns a source on (asking macOS for access first) or off, or changes its level.
    func set(_ source: PersonalSourceKind, on: Bool? = nil, level: PrivacyLevel? = nil) async {
        var value = setting(source)
        if let on { value.on = on ? await source.requestAccess() : false }
        if let level { value.level = level }
        sources[source] = value
        storage.write(sources, "sources.json")
        dock?.gate?.sources = PersonalSourceKind.sources(sources)
    }

    // MARK: Engines and sync

    private func info(_ record: ConnectionRecord) -> EngineInfo {
        EngineInfo(title: record.name, detail: record.provider == .compatible ? record.host : record.provider.detail, mark: record.provider.mark)
    }

    /// Runs a bot on its API connection (the key from this Mac's Keychain); other engines aren't
    /// connected on this Mac yet.
    private func engineResolver() -> @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineRunner.EngineUnavailable> {
        let lookup = ConnectionLookup(), keys = self.keys
        connectionLookup = lookup
        lookup.set(connections.map(\.connection))
        return { bot in
            guard case .api(let profile) = bot.engine, let connection = lookup.connection(profile) else { return await BotDock.notConnected(bot) }
            return .success(ResolvedEngine(engine: APIEngine(connection: connection, keys: keys),
                                           recipient: .apiModel(profile: profile, host: connection.endpoint.host() ?? "")))
        }
    }
    @ObservationIgnored private var connectionLookup: ConnectionLookup?

    /// The coding agents, and each API connection.
    private func refreshEngines() {
        connectionLookup?.set(connections.map(\.connection))
        guard let dock, !isDemo else { return }
        let api = connections.map { record in
            EngineChoice(engine: record.engine, info: info(record), models: record.models.isEmpty ? [record.connection.model] : record.models,
                         wire: record.connection.effortWire)
        }
        dock.engineChoices = BotDock.macEngines + api
        let known = Dictionary(uniqueKeysWithValues: api.map { ($0.engine, $0.info) })
        dock.engineInfo = { engine in known[engine] ?? EngineInfo.standard(engine) }
    }

    private func startSync(_ dock: BotDock) {
        guard !isDemo else { return }
        let cloud: (any CloudDatabase)? = CloudCapability.isEnabled() && !isTesting ? CKCloudDatabase(containerID: CloudCapability.containerID) : nil
        let sync = LibrarySyncController(database: cloud, signedIn: accounts.isSignedIn, ledgerURL: storage.syncLedger,
                                         devicePrefix: "Mac", read: { [unowned self] in self.library },
                                         apply: { [unowned self] in self.apply(library: $0) })
        self.sync = sync
        accounts.onChange = { [weak sync] account in sync?.setSignedIn(account != nil) }
        dock.store.onChange = { [weak sync] in sync?.localChanged() }
        if accounts.isSignedIn { sync.syncSoon(after: 0) }
    }

    private var library: SyncLibrary {
        let mine: (bots: [BotSpec], threads: [ChatThread]) = dock?.store.library ?? ([], [])
        return SyncLibrary(bots: mine.bots, threads: mine.threads, defaultModel: dock?.store.defaultModel, connections: connections.map {
            APIConnectionRecord(id: $0.id, name: $0.name, endpoint: $0.connection.endpoint, model: $0.connection.model, wire: $0.provider.rawValue)
        })
    }
    private func apply(library: SyncLibrary) {
        dock?.applySynced(bots: library.bots, threads: library.threads)
        if library.defaultModel != dock?.store.defaultModel { dock?.store.setDefaultModel(library.defaultModel) }
        let next = library.connections.compactMap { record -> ConnectionRecord? in
            let provider = ConnectionRecord.Provider(rawValue: record.wire) ?? (record.wire == "anthropic" ? .anthropic : .compatible)
            guard let connection = try? APIConnection.validated(id: record.id, name: record.name, endpoint: record.endpoint.absoluteString,
                                                                 model: record.model, wire: provider.wire) else { return nil }
            return ConnectionRecord(connection: connection, provider: provider, models: connections.first { $0.id == record.id }?.models ?? [])
        }
        if next != connections {
            connections = next
            storage.save(connections: next)
            refreshEngines()
        }
    }
}

/// The API connections as engines read them, from any thread.
final class ConnectionLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [APIConnection] = []
    func set(_ connections: [APIConnection]) { lock.withLock { list = connections } }
    func connection(_ id: UUID) -> APIConnection? { lock.withLock { list.first { $0.id == id } } }
}
