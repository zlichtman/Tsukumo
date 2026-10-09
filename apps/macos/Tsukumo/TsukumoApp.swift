import AppKit
import Observation
import SwiftUI
import TsukumoCore
import TsukumoContext
import TsukumoEngines
import TsukumoGate
import TsukumoGateway
import TsukumoPolicy
import TsukumoSync
import TsukumoSystemOne
import TsukumoUI
import TsukumoDock
import TsukumoMuse
import TsukumoUpdate
import TsukumoVoice
import TsukumoClaude
import TsukumoMLXVoice
import TsukumoLaya

// Tsukumo for Mac: your bots' side dock (TsukumoKit's TsukumoDock), from the menu bar: KemoSabe, then one bot
// for each service connected here (its API key, its agent on this Mac, a gateway caller that signed in, or a
// paired Muse). Nothing makes bots. Opening it shows the side dock, always; the first run (TsukumoUI's
// `OnboardingFlow`, the same as the iPhone's) comes first, in its own window. Settings is a window of its own (⌘,). `--demo` plays the website demo on the
// dock and saves nothing; `--ui-testing` starts from a fresh temporary folder with its own Keychain items,
// a stand-in for Sign in with Apple, and a stand-in login item, so nothing of the owner's is touched.
// Software Update (TsukumoUpdate) checks tsukumo.json on zlichtman.com; Debug builds and those runs never
// check or install.

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
        Divider()
        Button("Settings…") { app.showSettings() }.keyboardShortcut(",")
        Button("Check for Updates") { app.checkForUpdates() }
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
    /// What KemoSabe may read (`sources.json`, this Mac only), and the Gate's sources made from it.
    let sources: SourceLibrary
    private(set) var sync: LibrarySyncController?
    /// Listening and speaking: click a bot to talk to it (not in the demo).
    private(set) var voice: VoiceHub?
    /// System One: who answers an untagged message, and each turn's context (not in the demo).
    private(set) var systemOne: SystemOneCenter?
    /// The KemoSabe gateway: agents elsewhere ask KemoSabe over MCP on 127.0.0.1 (off until the owner turns it on;
    /// not in the demo).
    private(set) var gateway: KemoSabeGateway?
    @ObservationIgnored private var signIn: GatewaySignInWindow?
    /// Tsukumo's Dock as a Muse gadget (not in the demo): off until the owner saves an SDK token and pairs.
    private(set) var muse: MuseGadget?
    @ObservationIgnored private var musePrompt: MusePairingPrompt?
    /// The Claude bot (not in the demo): tasks on the owner's own Claude, and its panel for the dock's Claude tile.
    private(set) var claudeBot: ClaudeBot?
    /// The artifact store every chat and the Claude bot share (nil in the demo).
    @ObservationIgnored private var artifacts: ArtifactStore?
    @ObservationIgnored private var memoryPressure: DispatchSourceMemoryPressure?
    @ObservationIgnored private var pushToTalk: DockPushToTalk?
    let launchAtLogin: LaunchAtLogin
    /// The coding agents on this Mac (Claude Code, Codex, Cursor Agent, Gemini CLI), each on the owner's own
    /// sign-in. Under `--ui-testing` none is looked for, so no test runs the owner's agents.
    @ObservationIgnored let coding: CodingAgentCatalog
    /// Why the move from the preview's folder didn't finish (shown in Settings, General).
    private(set) var migrationProblem: String?
    /// Why the custom bots couldn't be moved into the lineup yet (shown in Settings, Bots).
    private(set) var lineupProblem: String?
    #if DEBUG
    /// `--capture`: the services shown in the pictures, in place of what's really connected.
    var capturedServices: ServiceConnections? { didSet { refreshServices() } }
    #endif
    @ObservationIgnored private(set) var onboardingWindow: NSWindow?
    @ObservationIgnored private(set) var settings: SettingsWindow?
    /// Software Update: checks tsukumo.json on zlichtman.com, and installs only when the owner clicks Install and Relaunch.
    /// Debug builds and `--ui-testing`, `--demo`, and `--capture` runs never check or install.
    let updates: UpdateService
    @ObservationIgnored private var updateNotices: UpdateNotices?

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
        // Under `--ui-testing` nothing of the owner's is read: permissions are stand-ins that never ask the system,
        // sources read nothing, a connector "connects" without the network, and tokens go to the test's own
        // Keychain items.
        sources = testing
            ? SourceLibrary(file: folder.appendingPathComponent("sources.json"), authorizer: StandInSourceAuthorizer(), factory: .empty,
                            tokens: KeychainConnectorTokens(service: service + ".connectors"),
                            discover: { _, _ in [MCPTool(name: "search", argument: "query")] })
            : SourceLibrary(file: folder.appendingPathComponent("sources.json"), authorizer: SystemSourceAuthorizer(messages: .system),
                            factory: .system(messages: .system, sharedMessages: nil),
                            tokens: KeychainConnectorTokens(service: service + ".connectors"))
        launchAtLogin = LaunchAtLogin(item: testing ? StandInLoginItem() : SystemLoginItem(), defaults: testing ? nil : .standard)
        coding = testing || arguments.contains("--demo") ? CodingAgentCatalog(path: []) : CodingAgentCatalog()
        #if DEBUG
        updates = UpdateService(environment: .main(isDebugBuild: true))
        #else
        updates = UpdateService(environment: .main(isDebugBuild: false))
        #endif
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppAppearance.current.apply()
        let dock: BotDock
        if isDemo {
            dock = BotDock.demo()
        } else {
            let store = BotDockStore(file: storage.dock)
            // 2.05's lineup (one bot per service) becomes the owner's own bots, once: each service bot they used stays,
            // on what its connection gives it (a coding agent counts as there; its tile says so if it isn't). The
            // Claude bot stays if it has tasks or a chat.
            let keyed = connections.filter { hasKey($0.id) }
            let services = ServiceConnections(claudeAPI: keyed.first { $0.provider == .anthropic }?.id, openAIAPI: keyed.first { $0.provider == .openAI }?.id,
                                              installedAgents: Set(ServiceID.allCases.compactMap(\.codingAgent)))
            let claude = ClaudeBotFile(url: storage.url("claude-bot.json")).load().state
            let used: Set<ServiceID> = !claude.tasks.isEmpty || claude.chat?.messages.isEmpty == false ? [.claude] : []
            if case .failure(let problem) = store.adoptBots(used: used, engine: services.engine(for:)) { lineupProblem = problem.message }
            let grants = storage.read([RecipientGrant].self, "grants.json") ?? []
            let artifacts = try? ArtifactStore(url: storage.artifacts)
            self.artifacts = artifacts
            let resolve = engineResolver()
            let center = startSystemOne()
            dock = BotDock.standard(store: store, sources: sources.sources(), grants: grants,
                                    journal: GateJournal(url: storage.journal), artifacts: artifacts, router: center.router(), resolve: resolve)
            dock.gate?.onGrantsChanged = { [weak self] grants in self?.storage.write(grants, "grants.json") }
            sources.onChange = { [weak self, weak dock] in if let self { dock?.gate?.sources = self.sources.sources() } }
            dock.upcoming = EventKitDockSource()
            // Chirps come only from sources KemoSabe may read: on in Settings, KemoSabe, and allowed by macOS.
            let sourceLibrary = self.sources
            dock.allowedSources = {
                MainActor.assumeIsolated {
                    Set(DockChirpSource.allCases.filter { source in
                        EventKitDockSource.permitted(source) && SourceKind(rawValue: source.rawValue).map(sourceLibrary.isReadable) == true
                    })
                }
            }
            dock.onChirp = { [weak dock] in if dock?.settings.chirpSounds == true { NSSound(named: "Pop")?.play() } }
            dock.startChirps()
            let folders = codingFolders
            dock.codingFolder = { bot in bot.contextScope.project ?? folders.appendingPathComponent(bot.id.uuidString).path }
            // The login shell's PATH, each agent's version, then its models (no prompt is sent), off the main thread.
            if !isTesting {
                Task { [weak self] in
                    await self?.coding.refresh()
                    self?.refreshEngines()
                }
                dock.refreshCharacters = { [weak self] in self?.refreshCharacters() }
                refreshCharacters()
            }
        }
        dock.openSettings = { [weak self] in self?.showSettings() }
        if !isDemo { startVoice(dock); startGateway(dock) }
        if let notice = dock.store.state.lineupNotice, !isDemo {
            // Said once beside the dock; Settings, Bots keeps it until the owner clears it.
            Task { @MainActor [weak dock] in
                try? await Task.sleep(for: .seconds(2))
                dock?.show(DockCallout(bot: BotSpec.kemoSabeID, text: notice), for: 20)
            }
        }
        self.dock = dock
        if !isDemo { startMuse(dock); startClaudeBot(dock) }
        refreshEngines()
        startSync(dock)
        let controller = BotDockController(dock: dock)
        self.controller = controller
        #if DEBUG
        // `--dock-style <glass|tinted|solid|minimal>` (with `--ui-testing`): straight to the dock, shown, in that style,
        // with a stand-in lineup, to look at the live Liquid Glass (offscreen pictures can't draw it).
        if isTesting, let at = CommandLine.arguments.firstIndex(of: "--dock-style"), at + 1 < CommandLine.arguments.count,
           let style = DockStyle(rawValue: CommandLine.arguments[at + 1]) {
            accounts.finishOnboarding()
            dock.store.update { $0.style = style; $0.autohide = false }
            capturedServices = ServiceConnections(installedAgents: ["codex"], callers: [.claude, .grok, .muse])
        }
        #endif
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
        startUpdates()
        #if DEBUG
        startCapture()
        startVoiceCheck()
        #endif
    }

    /// Opening Tsukumo again while it runs (its icon in Finder, Launchpad, or Spotlight) shows
    /// Settings, like MacSpaces; before the first run is finished it shows the first run.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if accounts.onboarded || isDemo { showSettings() } else { showOnboarding() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates.stop()
        pushToTalk?.unregister()
        gateway?.relay?.stop()
        gateway?.server.stop()
        gateway?.ledger.flush()
        muse?.stop()
        claudeBot?.shutDown()
        voice?.stopSpeaking()
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
    /// The menu's Check for Updates: Settings, General, where the answer shows, and a check.
    func checkForUpdates() {
        showSettings(.general)
        updates.checkNow()
    }

    // MARK: Software Update

    /// A notification when an update is ready (only if notifications are allowed; Tsukumo asks only when the
    /// owner turns on Download updates automatically), opening the downloaded DMG when Tsukumo can't replace
    /// itself, and quitting so the helper reopens the new copy. Off in Debug, test, demo, and capture runs.
    private func startUpdates() {
        let notices = UpdateNotices { [weak self] in self?.showSettings(.general) }
        updateNotices = notices
        updates.onReady = { feed in notices.ready(feed) }
        updates.openFile = { NSWorkspace.shared.open($0) }
        updates.quit = { NSApp.terminate(nil) }
        updates.start()
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
        [SourceKind.calendar, .reminders, .contacts].compactMap { sources.entry($0.rawValue) }.map {
            OnboardingSource(id: $0.id, title: $0.title, symbol: $0.symbol, on: $0.isOn, level: $0.level)
        }
    }
    func setSource(_ id: String, on: Bool) async { await sources.set(id, on: on) }
    func setSource(_ id: String, level: PrivacyLevel) async { sources.set(id, level: level) }
    var kemoSabe: BotSpec { dock?.bot(BotSpec.kemoSabeID) ?? .kemoSabe() }
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


    // MARK: System One

    /// Laya lives beside the voice models (device data, excluded from backup, never synced) and is loaded
    /// at launch once it's ready; a compiled copy the old KemoSabe app left is used after the same pinned
    /// checks, never changed. Hosted models' keys are in this Mac's Keychain only.
    private func startSystemOne() -> SystemOneCenter {
        let service = isTesting ? "com.zlichtman.tsukumo.mac.ui-testing" : "com.zlichtman.tsukumo.mac"
        let models = storage.url("VoiceModels")
        let provider = CoreMLLayaProvider(directory: models.appendingPathComponent(VoiceModelPack.laya.id).appendingPathComponent("model"),
                                          tokenizer: LayaBundleTokenizer.make)
        let laya = LayaModel(root: models, provider: provider, seeds: isTesting ? [] : [Storage.oldVoiceModels])
        let center = SystemOneCenter(folder: storage.folder, keys: KeychainAPIKeys(service: service + ".system-one-keys"), deviceName: "Mac",
                                     laya: laya, local: provider)
        laya.start()
        // Under memory pressure Laya is let go; the next decision loads it again.
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { Task { await provider.unload() } }
        source.resume()
        memoryPressure = source
        systemOne = center
        return center
    }

    // MARK: The KemoSabe gateway

    /// The gateway reads only what KemoSabe may read (its catalog), and answers on 127.0.0.1 only once the owner
    /// turns it on. Under `--ui-testing` it reads made-up data from the test's own folder, never the owner's.
    private func startGateway(_ dock: BotDock) {
        let sources: GatewaySources
        let content: any GatewayContent
        if isTesting {
            sources = GatewaySources(calendarLevel: { .personal }, contactsLevel: { .personal }, busy: FixtureBusyTimes.sample(),
                                     contacts: FixtureContacts.sample)
            content = FixtureContent.sample(folder: storage.url("Gateway fixture"))
        } else {
            sources = GatewaySources.library(self.sources)
            content = LibraryContent(library: self.sources, messages: .system)
        }
        let gateway = KemoSabeGateway(folder: storage.folder, sources: sources, content: content)
        // The public address (the Tsukumo relay): this Mac's key in its Keychain (Secure Enclave when it has one),
        // or in memory under --ui-testing. Off until the owner turns it on.
        gateway.attachRelay(keys: isTesting ? MemoryRelayKeyStore() : KeychainRelayKeyStore(service: "com.zlichtman.tsukumo.mac.relay"),
                            secureEnclave: !isTesting)
        if let gate = dock.gate { gateway.tools.attach(gate: gate) }
        dock.attach(gateway: gateway.desk, inbox: gateway.inbox)
        dock.gatewayHub = gateway
        // A caller signing in (or being revoked) changes what can be brought in.
        let changed = gateway.store.onChange
        gateway.store.onChange = { [weak self] in changed?(); self?.refreshServices() }
        let shown = gateway.desk.onRequest
        gateway.desk.onRequest = { [weak self] request in
            shown?(request)
            if case .newClient = request.kind { self?.showSignIn(request) }
        }
        self.gateway = gateway
        #if DEBUG
        if isTesting, let index = CommandLine.arguments.firstIndex(of: "--gateway-smoke"), index + 1 < CommandLine.arguments.count {
            let folder = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
            gateway.store.update { $0.contentTools = true; $0.inbox = true; $0.port = 0 }
            let made = gateway.store.addTokenCaller(name: "Smoke test")
            // With `--relay-smoke <relay>` (a relay on this computer, `wrangler dev`), the public address turns on too,
            // and its public MCP address joins the report once the relay is ready.
            var relayURL: String?
            if let at = CommandLine.arguments.firstIndex(of: "--relay-smoke"), at + 1 < CommandLine.arguments.count { relayURL = CommandLine.arguments[at + 1] }
            Task { @MainActor in
                await gateway.setEnabled(true)
                var report: [String: String] = ["url": "http://127.0.0.1:\(gateway.server.port)/mcp", "token": made.token, "caller": made.caller.id]
                if let relayURL, let relay = gateway.relay {
                    gateway.setRelayURL(relayURL)
                    gateway.setRelayEnabled(true)
                    var waited = 0
                    while waited < 100, relay.publicMCPURL == nil || relay.connectedBase == nil {
                        try? await Task.sleep(for: .milliseconds(100))
                        waited += 1
                    }
                    report["public_url"] = relay.publicMCPURL ?? ""
                    report["relay_status"] = "\(relay.status)"
                }
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? JSONEncoder().encode(report).write(to: folder.appendingPathComponent("gateway-smoke.json"))
            }
            return
        }
        #endif
        Task { await gateway.apply() }
    }

    /// The native window for a client signing in with OAuth: the owner allows or refuses it here, never in a browser.
    func showSignIn(_ request: GatewayApprovalRequest) {
        guard let gateway else { return }
        if signIn == nil {
            signIn = GatewaySignInWindow(desk: gateway.desk) { [weak self] caller, service, transport in
                // A caller confirmed as a service comes in as a bot of the owner's.
                self?.dock?.bind(caller: caller, to: service, transport: transport)
                self?.refreshServices()
            }
        }
        signIn?.show(request)
    }

    // MARK: Muse

    /// Muse calls Tsukumo as a caller that must ask KemoSabe (TsukumoMuse's commands through the dock). The
    /// identity is a file in the app's folder; the SDK token and the device tokens are in this Mac's Keychain.
    /// Under `--ui-testing` its secrets are in memory and Bluetooth is never used.
    private func startMuse(_ dock: BotDock) {
        let secrets: any MuseSecrets = isTesting ? MemoryMuseSecrets() : KeychainMuseSecrets(service: "com.zlichtman.tsukumo.mac.muse")
        let name: String = Host.current().localizedName ?? "this Mac"
        var radio: (@MainActor (String) -> any MusePairingRadio)?
        if !isTesting { radio = { @MainActor name in MusePeripheral(name: name) } }
        let muse = MuseGadget(folder: storage.folder, secrets: secrets, displayName: "Tsukumo on " + name, makeRadio: radio)
        // Saving the token opens pairing at once: the step people missed was clicking Pair.
        muse.autoPairAfterToken = !isTesting
        // Muse is a caller of the KemoSabe gateway (Settings, Gateway lists it, with Revoke): pairing adds it, any end
        // of the pairing revokes it there, and Revoke unpairs it (`DockMuseGateway`).
        muse.handler = TsukumoMuseCommands(tsukumo: DockMuseBridge(dock: dock, tools: gateway?.tools))
        if let gateway { DockMuseGateway.connect(muse, to: gateway) }
        // A phone that finished the handshake waits for the owner here before anything secret is sent.
        let prompt = MusePairingPrompt(muse: muse)
        muse.onConfirmationNeeded = { prompt.show() }
        musePrompt = prompt
        muse.start()
        self.muse = muse
    }

    // MARK: The Claude bot

    /// The Claude bot (TsukumoClaude) runs on the owner's own Claude Code, else their Claude API key, works in
    /// `Claude/` in the app's folder, asks KemoSabe through the gateway as its own caller ("Claude" in Settings,
    /// Gateway), and keeps its tasks in `claude-bot.json` on this Mac. Its panel is what the dock's Claude tile
    /// opens. Under `--ui-testing` no Claude Code is looked for and no key exists.
    private func startClaudeBot(_ dock: BotDock) {
        // Read on the main actor only: the Claude bot asks for what's available from its own main-actor work.
        let host = ClaudeEngineHost.mac(catalog: coding, connections: { [weak self] in MainActor.assumeIsolated { self?.connections ?? [] } }, keys: keys)
        let bot = ClaudeBot(file: ClaudeBotFile(url: storage.url("claude-bot.json")), folder: storage.url("Claude"), host: host,
                            kemoSabe: gateway.map { ClaudeKemoSabe(gateway: $0) }, inbox: gateway?.inbox, artifacts: artifacts)
        bot.onActivity = { [weak dock] item in dock?.note(item) }
        if let router = systemOne?.router() { bot.useSystemOne(router) }
        // Revoke in Settings, Gateway stops Claude asking KemoSabe until the owner turns it back on in its panel.
        let revoked = gateway?.onRevoke
        gateway?.onRevoke = { [weak bot] caller in
            revoked?(caller)
            if caller.id == GatewayCaller.claudeBotID { bot?.kemoSabeRevoked() }
        }
        bot.start()
        dock.panelProviders[BotSpec.claudeBotID] = bot
        claudeBot = bot
    }

    // MARK: Voice

    /// The voice models live in the app's folder (device data, excluded from backup, never synced). A copy
    /// the old KemoSabe app already downloaded and checked is reused after the same checks, never changed.
    private func startVoice(_ dock: BotDock) {
        let models = storage.url("VoiceModels")
        var capture: @MainActor () -> any SpeechCapturing = { AppleSpeechCapture() }
        #if DEBUG
        // Pictures of the listening state never ask for the microphone.
        if CommandLine.arguments.contains("--capture") { capture = { ScriptedSpeechCapture.sample() } }
        #endif
        let hub = VoiceHub(folder: models, settingsURL: storage.url("voice.json"), deviceName: "Mac",
                           runtime: MLXVoiceRuntime(cacheFolder: models), seeds: isTesting ? [] : [Storage.oldVoiceModels],
                           makeCapture: capture)
        hub.resumeBetterModels()
        dock.voice = hub
        voice = hub
        if !isTesting {
            let keys = DockPushToTalk(dock: dock)
            keys.register()
            pushToTalk = keys
        }
    }

    // MARK: Engines and sync

    private func info(_ record: ConnectionRecord) -> EngineInfo {
        EngineInfo(title: record.name, detail: record.provider == .compatible ? record.host : record.provider.detail, mark: record.provider.mark)
    }

    /// Where a coding bot without a project works: a folder of its own in the app's store.
    private var codingFolders: URL { storage.url("Coding") }

    /// Runs a bot on its API connection (the key from this Mac's Keychain), or a coding bot on its agent
    /// (the owner's own CLI and sign-in, in its project or its own folder).
    private func engineResolver() -> @Sendable (BotSpec) async -> Result<ResolvedEngine, EngineRunner.EngineUnavailable> {
        let lookup = ConnectionLookup(), keys = self.keys, coding = self.coding, folders = codingFolders
        connectionLookup = lookup
        lookup.set(connections.map(\.connection))
        let muse: @Sendable @MainActor (String, String) async throws -> MuseChatResult = { [weak self] text, session in
            guard let gadget = self?.muse else { throw MuseChatFailure() }
            do { return try await gadget.chat(text, session: session) } catch let failure as MuseChatFailure { throw failure } catch { throw MuseChatFailure() }
        }
        return { bot in
            if bot.engine == .muse { return .success(ResolvedEngine(engine: MuseChatEngine(send: muse), recipient: .externalAgent("service:muse"))) }
            if let resolved = BotDock.codingAgent(bot, catalog: coding, folder: { folders.appendingPathComponent($0.id.uuidString) }) { return resolved }
            guard case .api(let profile) = bot.engine, let connection = lookup.connection(profile) else { return await BotDock.notConnected(bot) }
            return .success(ResolvedEngine(engine: APIEngine(connection: connection, keys: keys),
                                           recipient: .apiModel(profile: profile, host: connection.endpoint.host() ?? "")))
        }
    }
    @ObservationIgnored private var connectionLookup: ConnectionLookup?

    /// Which service an API connection is (Claude or OpenAI), for a bot's mark, from a snapshot of `records`.
    static func apiService(_ records: [ConnectionRecord]) -> (UUID) -> ServiceID? {
        { id in
            switch records.first(where: { $0.id == id })?.provider {
            case .anthropic?: .claude
            case .openAI?: .openAI
            default: nil
            }
        }
    }

    /// The owner's Codex pets and ChatGPT dot, read from Codex on this Mac off the main thread (only the dot's name,
    /// pet, and IDs are read from Codex's state file), and their recent Codex and Claude Code conversations.
    private func refreshCharacters() {
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { (CodexPets.installed(), CodexPets.primaryDot(), CodingSessions.recent()) }.value
            guard let dock = self?.dock else { return }
            if dock.pets != found.0 { dock.pets = found.0 }
            if dock.codingSessions != found.2 { dock.codingSessions = found.2 }
            let dot = found.1.flatMap { $0.available ? BotDock.DotOffer($0) : nil }
            if dock.dot != dot { dock.dot = dot }
        }
    }

    /// The coding agents, and each API connection.
    private func refreshEngines() {
        connectionLookup?.set(connections.map(\.connection))
        dock?.apiService = Self.apiService(connections)
        guard let dock, !isDemo else { return }
        let api = connections.map { record in
            EngineChoice(engine: record.engine, info: info(record), models: record.models.isEmpty ? [record.connection.model] : record.models,
                         wire: record.connection.effortWire)
        }
        // Under `--ui-testing` the agents aren't looked for; the list shows them as they're known to be.
        dock.engineChoices = (isTesting ? BotDock.macEngines : BotDock.macEngines(coding: coding.installed)) + api
        let known = Dictionary(uniqueKeysWithValues: api.map { ($0.engine, $0.info) })
        dock.engineInfo = { engine in known[engine] ?? EngineInfo.standard(engine) }
        refreshServices()
    }

    /// Which services are connected here, for what bots can run on and be brought in: the first Claude and OpenAI
    /// connection with a key, the coding agents installed on this Mac, and the gateway's callers (a paired Muse is one).
    func refreshServices() {
        guard let dock, !isDemo else { return }
        #if DEBUG
        if let capturedServices { dock.connections = capturedServices; return }
        #endif
        let keyed = connections.filter { hasKey($0.id) }
        // A paired Muse is Muse (the owner paired it here, under Muse's own caller ID); every other caller counts for a
        // service only once the owner confirmed which one it is, by its authenticated ID. Tsukumo's Claude bot is a
        // device caller too, but it's Tsukumo's own: never bound to a service.
        if let muse = gateway?.store.caller(MuseCaller.muse.id), muse.kind == .device, dock.store.binding(forCaller: muse.id) == nil {
            dock.bind(caller: muse.id, to: .muse, transport: "paired with this Mac")
        }
        // The callers the owner confirmed in 2.05 come in as bots, once.
        dock.bringInConfirmedCallers()
        // A binding an earlier build saved for it is dropped.
        if dock.store.binding(forCaller: GatewayCaller.claudeBotID) != nil { dock.store.forgetBinding(caller: GatewayCaller.claudeBotID) }
        let callers = Set((gateway?.store.callers ?? []).filter { !$0.isTsukumosClaudeBot }.compactMap { dock.store.binding(forCaller: $0.id)?.service })
        dock.connections = ServiceConnections(claudeAPI: keyed.first { $0.provider == .anthropic }?.id,
                                              openAIAPI: keyed.first { $0.provider == .openAI }?.id,
                                              installedAgents: Set(coding.installed.map(\.kind.id)), callers: callers)
    }

    /// The owner read the lineup notice.
    func dismissLineupNotice() { dock?.store.dismissLineupNotice() }

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
        }, aliases: dock?.store.aliases ?? LineupAliases())
    }
    private func apply(library: SyncLibrary) {
        // The connections first, so a custom bot that arrives with its connection is classified by it.
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
        dock?.apiService = Self.apiService(connections)
        dock?.store.addAliases(library.aliases)
        dock?.applySynced(bots: library.bots, threads: library.threads)
        if library.defaultModel != dock?.store.defaultModel { dock?.store.setDefaultModel(library.defaultModel) }
    }
}

/// The API connections as engines read them, from any thread.
final class ConnectionLookup: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [APIConnection] = []
    func set(_ connections: [APIConnection]) { lock.withLock { list = connections } }
    func connection(_ id: UUID) -> APIConnection? { lock.withLock { list.first { $0.id == id } } }
}
