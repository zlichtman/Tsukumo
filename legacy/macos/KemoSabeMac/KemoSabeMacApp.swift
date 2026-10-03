import AppKit
import SwiftUI
import Observation

@MainActor @Observable final class DesktopNavigation {
    private let defaults: UserDefaults
    var page: String {
        didSet {
            defaults.set(page, forKey: "desktop.lastPage")
            if !travelling, oldValue != page { history.append(oldValue); future = [] }
        }
    }
    /// Which Tsukumo surface is open: a project, or coordination between agents.
    var tsukumoSurface = "Project"
    /// Back and forward through pages, like Codex's arrows beside the traffic lights.
    private(set) var history: [String] = []
    private(set) var future: [String] = []
    private var travelling = false
    func goBack() {
        guard let previous = history.popLast() else { return }
        travelling = true; future.append(page); page = previous; travelling = false
    }
    func goForward() {
        guard let next = future.popLast() else { return }
        travelling = true; history.append(page); page = next; travelling = false
    }
    var settingsPage: String? { didSet { defaults.set(settingsPage, forKey: "desktop.lastSettingsPage") } }
    var settingsSearch = ""
    var search = ""
    var showSidebar: Bool { didSet { defaults.set(showSidebar, forKey: "desktop.showSidebar") } }
    var windowVisible = true
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.string(forKey: "desktop.lastPage") ?? "Chat"
        page = ["Chat", "People", "Day", "Library", "Tsukumo"].contains(saved) ? saved : "Chat"
        settingsPage = defaults.string(forKey: "desktop.lastSettingsPage")
        showSidebar = defaults.object(forKey: "desktop.showSidebar") == nil || defaults.bool(forKey: "desktop.showSidebar")
    }
}

/// Whether a restored main-window frame can be used as is; otherwise the window opens at
/// `defaultContentSize`, centered.
enum MainWindowFrame {
    static let defaultContentSize = NSSize(width: 1120, height: 760)
    /// Usable when it is at least the window's minimum size and overlaps a screen's visible area.
    static func isUsable(_ frame: NSRect, minSize: NSSize, visibleFrames: [NSRect]) -> Bool {
        guard frame.width.isFinite, frame.height.isFinite,
              frame.width >= minSize.width, frame.height >= minSize.height else { return false }
        return visibleFrames.contains { !$0.intersection(frame).isEmpty }
    }
}

@main @MainActor final class KemoSabeMacApp: NSObject, NSApplicationDelegate, NSWindowDelegate {
    /// The Mac app is Tsukumo; KemoSabe, the personal agent, lives inside it.
    static let appName = "Tsukumo"
    /// The open account's store; replaced when a sign-in or sign-out finishes while Tsukumo runs.
    private var store: AppStore
    private let coding: CodingWorkspaceStore
    /// True when this process only hosts the Mac tests.
    static let isTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    /// Settings storage: the real app's, or a throwaway suite for tests so they never change
    /// the installed app's window, navigation, preferences, or saved projects.
    private static let hostDefaults: UserDefaults = {
        guard isTestHost else { return .standard }
        let suite = "com.zlichtman.kemosabe.mac.tests"
        UserDefaults().removePersistentDomain(forName: suite)
        return UserDefaults(suiteName: suite) ?? .standard
    }()
    private let navigation = AppNavigation()
    private let desktop = DesktopNavigation(defaults: KemoSabeMacApp.hostDefaults)
    private let preferences = DesktopPreferences(defaults: KemoSabeMacApp.hostDefaults)
    private let voice = MacVoiceInput()
    private let codingApplications = CodingApplicationRegistry(defaults: KemoSabeMacApp.hostDefaults)
    private let projects = DesktopProjects(defaults: KemoSabeMacApp.hostDefaults)
    private let connectors = ConnectorStore()
    /// First launch only: welcome, one account, the companion, and Tsukumo's setup, in the main
    /// window. Owned here so it carries on across the account switch in the sign-in step.
    private let onboarding = OnboardingFlow(steps: MacOnboardingStep.all)
    private var routines: RoutineStore
    /// The store's repository for each account opened (a throwaway one for fixtures and tests).
    private let repository: () -> LocalRepository
    private var window: NSWindow!
    private var companion: CompanionPanel!
    private var statusItem: NSStatusItem?
    private var screenObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private var macSpacesBridge: MacSpacesBridgeServer?
    private var isQuitting = false
    /// Where agents' `ask_kemosabe` calls arrive from the KemoSabe MCP helper.
    private var bridge: KemoSabeBridgeServer?
    /// The sandbox copy's outcome, decided in `main()` before this object (and every stored
    /// property above, some of which read settings) is created.
    private static var startupMigration: SandboxMigration.Outcome = .alreadyDone
    override init() {
        let migration = Self.startupMigration
        // `LocalRepository.standard` opens the account folder, which moves pre-account items into
        // it; with the sandbox copy incomplete, that move waits, and AppStore holds saving from
        // its first line (before it could write a fresh state over data still on its way).
        if migration == .failed { AccountDirectory.holdLegacyMigration = true }
        #if DEBUG
        let fixture: LocalRepository? = ProcessInfo.processInfo.arguments.contains("--isolated-fixture") || ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            ? .init(url: FileManager.default.temporaryDirectory.appendingPathComponent("KemoMacUITests/" + UUID().uuidString + "/state.json")) : nil
        #else
        let fixture: LocalRepository? = nil
        #endif
        repository = { fixture ?? .standard }
        let store = AppStore(repository: repository())
        // Earlier data that couldn't be brought over yet keeps saving off, so nothing new replaces it.
        if migration == .failed {
            store.holdStorage("Your data from the earlier Tsukumo couldn't be moved yet. Nothing has been changed. Retry to try again.") {
                // First the sandbox copy, then the move into the account that waited for it.
                SandboxMigration.run() != .failed && AccountDirectory.releaseLegacyHold()
            }
        }
        self.store = store; coding = CodingWorkspaceStore(); routines = RoutineStore(ledger: store.proposalLedger)
        super.init()
    }
    static func main() {
        // Before anything reads settings or opens account storage.
        startupMigration = isTestHost ? .alreadyDone : SandboxMigration.run()
        let app = NSApplication.shared
        let delegate = KemoSabeMacApp(); app.delegate = delegate
        DesktopIconArtwork.apply()
        app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        BundledFonts.register()
        // A test host opens no window, companion, menu bar item, or account sync.
        guard !Self.isTestHost else { return }
        // Move to Applications comes first when Tsukumo runs from a disk image, Downloads, or a translocated
        // copy (MoveToApplications.swift); after "Not now" the launch carries on from the top, once.
        if MoveToApplications.offer(theme: store.state.theme, preferences: preferences, then: { [weak self] in self?.applicationDidFinishLaunching(notification) }) { return }
        // AppKit's manual main entry point does not reliably initialize the Dock
        // image from Launch Services during development launches. Set the same
        // approved bundled icon explicitly for every launch path.
        DesktopIconArtwork.apply()
        startMacSpacesBridge()
        installMenu()
        // The quick terminal's global shortcut, and the terminal's keyboard settings.
        QuickTerminal.shared.install(preferences: preferences)
        // Look for a newer published build once the window has settled; the sidebar shows it.
        // Tests never reach the network for it.
        if !Self.isTestHost { Task { try? await Task.sleep(for: .seconds(8)); await AppUpdater.shared.check() } }
        connectAccount()
        // Signing in or out finishes here and now, without restarting: the open account's replies,
        // voice, and coding agents stop and write what's pending, and after the switch every store,
        // the window, and the companion reopen on the account now current (see LiveAccountSwitch).
        LiveAccountSwitch.hooks = .init(quiesce: { [weak self] in self?.closeAccount() }, reopen: { [weak self] in self?.reopenAccount() })
        // Sign in with Apple is checked each launch; a revoked sign-in signs this Mac out.
        if AppleAccountSession.availableInBuild { Task { await AppleAccountSession.shared.verify() } }
        // Before the window exists, so a window frame saved by an earlier launch still tells an
        // existing install from a new one.
        decideOnboarding()
        window = NSWindow(contentRect: .init(x: 0, y: 0, width: 1120, height: 760),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = Self.appName; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(calibratedWhite: 0.09, alpha: 1)
        window.minSize = .init(width: 760, height: 540); window.isReleasedWhenClosed = false; window.delegate = self
        installRoot()
        window.setContentSize(MainWindowFrame.defaultContentSize)
        // A saved frame that is too small or off every screen (one app replacing another while it
        // ran once saved a frame of almost no size) opens at the default size, centered.
        let restored = window.setFrameUsingName("KemoSabe.MainWindow")
        if !restored || !MainWindowFrame.isUsable(window.frame, minSize: window.minSize, visibleFrames: NSScreen.screens.map(\.visibleFrame)) {
            window.setContentSize(MainWindowFrame.defaultContentSize)
            window.center()
        }
        window.setFrameAutosaveName("KemoSabe.MainWindow")
        createCompanion()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Tsukumo's mark as a template image, so the menu bar tints it for light and dark.
        let mark = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "bubble.left.and.bubble.right", accessibilityDescription: nil)
        mark?.isTemplate = true; mark?.size = NSSize(width: 18, height: 18); mark?.accessibilityDescription = Self.appName
        statusItem?.button?.image = mark
        statusItem?.button?.target = self; statusItem?.button?.action = #selector(openChat)
        statusItem?.button?.toolTip = "Open " + Self.appName
        statusItem?.isVisible = preferences.showMenuBar
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.clampCompanion() }
        }
        // Coding follows the signed-in account: a sign-out or a different account stops its agent
        // processes and swaps in that account's tasks and drafts. Anything that saves the current
        // account record (`AccountDirectory.currentKey`) is followed here, without polling.
        accountObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor in self?.coding.follow(AccountDirectory.saved()) }
        }
        openChat()
        startBridge()
        startRelay()
        #if DEBUG
        // The agent request demo (--isolated-fixture --agent-request-fixture): Muse's request as a card.
        AgentRequestFixture.install(in: store)
        // The chat-with-Claude demo (--isolated-fixture --agent-handoff-fixture), with a fake Claude.
        if ChatHandoffFixture.requested { desktop.page = "Chat" }
        #endif
        Task { try? await store.proposalLedger.recover(now: Date()); await routines.refresh() }
    }
    /// Whether this Mac shows onboarding: only a new install does. One with a saved window, projects,
    /// coding tasks, or account data from before onboarding existed is marked finished and skips it.
    private func decideOnboarding() {
        #if DEBUG
        // Screenshots and manual checks: --onboarding runs it as on a new install.
        if ProcessInfo.processInfo.arguments.contains("--onboarding") {
            AccountDirectory.accountSettings.removeObject(forKey: Onboarding.completedKey)
            onboarding.restart(); return
        }
        #endif
        let earlier = MacOnboardingEvidence.earlierUse(device: Self.hostDefaults, projects: projects.projects.count, tasks: coding.tasks.count)
        if let evidence = store.onboardingEvidence(other: earlier) { onboarding.decide(evidence) }
    }
    /// Hooks the account's shared store up to this app's theme, and brings in other devices' edits.
    private func connectAccount() {
        AccountStore.shared.currentPaletteID = { [store] in store.state.theme.id }
        AccountStore.shared.applyPalette = { [store] id in
            guard let theme = (BotTheme.presets + (store.state.customThemes ?? [])).first(where: { $0.id == id }) else { return }
            store.state.theme = theme; store.save()
        }
        AccountStore.shared.sync()
        // Account sync (iCloud) keeps this account's chats, memories, drafts, People, and companion
        // in step with the person's other devices; it does nothing for a local account or a build
        // without the iCloud entitlement.
        AccountSyncService.shared.attach(store: store, extra: [ProfileImageSyncAdapter.forSharedAccountPhoto(), DocsSyncAdapter.forSharedStore()])
        AccountSyncService.shared.setActive(NSApp.isActive)
    }
    /// The main window's content, built on the open account's stores. Rebuilt whole when the
    /// account changes, so every view's state and `@AppStorage` reads the new account.
    private func installRoot() {
        let root = DesktopRootView(minimize: { [weak self] in self?.minimizeToCompanion() }, toggleCompanion: { [weak self] in self?.toggleCompanion() }, preferencesChanged: { [weak self] in self?.updateCompanion(); self?.statusItem?.isVisible = self?.preferences.showMenuBar ?? true })
            .environment(store).environment(navigation).environment(desktop).environment(preferences)
            .environment(voice).environment(connectors).environment(routines).environment(codingApplications).environment(projects).environment(coding)
            .environment(onboarding)
            .font(KemoType.font(.body))
        let hosting = NSHostingView(rootView: root); hosting.sizingOptions = []
        let size = window.contentView?.frame.size
        window.contentView = hosting
        if let size, size.width > 0 { window.setContentSize(size) }
    }
    /// Before an account switch: stops replies, voice, and coding agents and writes what's
    /// pending, while the account being left is still the open one.
    /// Agents ask KemoSabe through the helper (design/CONTEXT-HARNESS.md#agents-asking-kemosabe); each
    /// question goes to the account open at that moment, and nothing is answered while the Mac is locked.
    private func startBridge() {
        #if DEBUG
        // A fixture run answers only on a folder its test names, never on the installed app's socket.
        if ProcessInfo.processInfo.arguments.contains("--isolated-fixture"),
           ProcessInfo.processInfo.environment[KemoSabeBridgeWire.folderEnvironment] == nil { return }
        #endif
        let bridge = KemoSabeBridgeServer { [weak self] request in
            await self?.answerBridge(request) ?? .init(status: "unavailable", text: "Tsukumo is closing. Ask again once it’s open.")
        }
        do { try bridge.start(); self.bridge = bridge } catch { NSLog("KemoSabe bridge didn't start: \(error)") }
    }
    private func answerBridge(_ request: KemoSabeBridgeWire.Request) async -> KemoSabeBridgeWire.Response {
        // Claude in a chat on the owner's iPhone asks the iPhone's KemoSabe, not this Mac's.
        if !isQuitting, let relayed = await KemoSabeRelay.shared.answer(request) { return relayed }
        store.agentQuestions.isLocked = KemoSabeBridgeServer.screenLocked
        return await KemoSabeBridgeAnswers.respond(request, store: isQuitting ? nil : store)
    }
    /// Agents on your Mac (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone): starts at launch when it was
    /// left on, never in a fixture or UI-test run (those must not answer the owner's iPhone).
    private func startRelay() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--isolated-fixture") || arguments.contains("--ui-testing") { return }
        #endif
        KemoSabeRelay.shared.startIfEnabled()
    }
    private func closeAccount() {
        voice.stop(); MacReadAloud.shared.stop(); store.cancelStandup(); store.closeForAccountSwitch(); DocsStore.shared.close()
        coding.switchAccount(to: nil)
    }
    /// After an account switch (or a failed one): every store reopens on the account now open,
    /// and the window and companion are rebuilt on them. Settings stay on the Account page.
    private func reopenAccount() {
        let store = AppStore(repository: repository())
        self.store = store
        routines = RoutineStore(ledger: store.proposalLedger)
        DocsStore.reopen()
        MacReadAloud.shared.reload()
        coding.follow(AccountDirectory.saved())
        connectAccount()
        guard window != nil else { return }
        installRoot()
        if let wrapper = companion?.contentView {
            wrapper.subviews.forEach { $0.removeFromSuperview() }
            let view = NSHostingView(rootView: FloatingCompanionView().environment(store).environment(preferences).environment(navigation))
            view.frame = wrapper.bounds; view.autoresizingMask = [.width, .height]; wrapper.addSubview(view)
        }
        Task { try? await store.proposalLedger.recover(now: Date()); await routines.refresh() }
    }
    /// The MacSpaces quick-task receiver starts only here, with the app, and never in a test host or
    /// an isolated fixture run (those must not answer the person's MacSpaces). A failure leaves it
    /// off and is shown in Settings → Agents, where Try again calls this again.
    func startMacSpacesBridge() {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--isolated-fixture") || arguments.contains("--ui-testing") {
            MacSpacesBridgeStatus.shared.set(.off("Off in fixture and UI-test runs.")); return
        }
        #endif
        if macSpacesBridge == nil {
            let routes = MacSpacesBridgeRoutes(
                chat: { [weak self] in self?.store },
                projects: { [weak self] in self?.projects.projects ?? [] },
                resolve: { [weak self] id in guard let self else { throw CocoaError(.fileNoSuchFile) }; return try self.projects.resolve(id) },
                openChat: { [weak self] in guard let self else { return }; self.openChat(); self.desktop.page = "Chat" })
            macSpacesBridge = MacSpacesBridgeServer(coding: coding, routes: routes) { [weak self] id in
                guard let self, let task = self.coding.task(id) else { return }
                self.openChat(); self.desktop.page = "Tsukumo"; self.desktop.tsukumoSurface = "Project"
                self.projects.selected = task.projectID; self.coding.select(id)
            }
        }
        MacSpacesBridgeStatus.shared.retry = { [weak self] in self?.startMacSpacesBridge() }
        do { try macSpacesBridge?.start() } catch { NSLog("MacSpaces bridge unavailable: %@", error.localizedDescription) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { openChat(); return true }
    func applicationWillResignActive(_ notification: Notification) { voice.stop(); AccountSyncService.shared.setActive(false) }
    func applicationDidBecomeActive(_ notification: Notification) {
        guard !Self.isTestHost else { return }
        AccountSyncService.shared.setActive(true)
    }
    func applicationWillTerminate(_ notification: Notification) {
        macSpacesBridge?.stop()
        bridge?.stop()
        KemoSabeRelay.shared.shutDown()
        coding.stopAll()
        isQuitting = true; voice.stop(); store.cancel(); store.cancelStandup()
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if isQuitting { return true }; minimizeToCompanion(); return false
    }
    func windowDidMiniaturize(_ notification: Notification) { voice.stop(); desktop.windowVisible = false; showCompanion() }
    func windowDidDeminiaturize(_ notification: Notification) { preferences.isVisible = false; desktop.windowVisible = true; companion.orderOut(nil) }
    func windowDidChangeOcclusionState(_ notification: Notification) { desktop.windowVisible = window.occlusionState.contains(.visible) }
    @objc func openChat() {
        // A reopen can arrive before the window exists (a test host, or early in launch).
        guard let window else { return }
        preferences.isVisible = false; desktop.windowVisible = true; companion?.orderOut(nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        store.refreshAvailability()
    }
    @objc func minimizeToCompanion() { voice.stop(); desktop.windowVisible = false; window?.orderOut(nil); showCompanion() }
    @objc private func customize() { desktop.settingsPage = "Companion"; openChat() }
    @objc private func settings() { desktop.settingsPage = "General"; openChat() }
    @objc private func hideCompanion() { preferences.isVisible = false; companion.orderOut(nil) }
    /// Kemo's picture in the sidebar shows or hides the floating companion; the window stays put.
    @objc func toggleCompanion() { preferences.isVisible ? hideCompanion() : showCompanion() }
    @objc private func quit() { isQuitting = true; NSApp.terminate(nil) }
    @objc private func newChat() {
        // ⌘N in Tsukumo starts a new coding task.
        if codingMenu?.newTaskIfCoding() == true { return }
        voice.stop(); store.newConversation(); desktop.page = "Chat"; openChat()
    }
    /// Tsukumo's Task menu (CodingChatCommands.swift).
    private var codingMenu: CodingChatMenu?
    private func showCompanion() { preferences.isVisible = true; updateCompanion(); companion.orderFrontRegardless() }
    private func createCompanion() {
        companion = CompanionPanel(contentRect: NSRect(origin: .zero, size: preferences.panelSize),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        companion.title = "KemoSabe companion"; companion.isOpaque = false; companion.backgroundColor = .clear
        companion.level = .floating; companion.hasShadow = true; companion.hidesOnDeactivate = false
        companion.isReleasedWhenClosed = false
        let wrapper = CompanionDragView(frame: NSRect(origin: .zero, size: preferences.panelSize))
        let view = NSHostingView(rootView: FloatingCompanionView().environment(store).environment(preferences).environment(navigation))
        view.frame = wrapper.bounds; view.autoresizingMask = [.width, .height]; wrapper.addSubview(view)
        wrapper.clicked = { [weak self] in self?.openChat() }
        wrapper.moved = { [weak self] in self?.clampCompanion(); self?.saveCompanionOrigin() }
        wrapper.menuBuilder = { [weak self] in self?.companionMenu() ?? NSMenu() }
        wrapper.setAccessibilityElement(true); wrapper.setAccessibilityRole(.button)
        wrapper.setAccessibilityLabel("KemoSabe companion. Drag to move, click to open.")
        wrapper.setAccessibilityIdentifier("desktopCompanion")
        companion.contentView = wrapper
        if UserDefaults.standard.object(forKey: "companion.x") != nil {
            companion.setFrameOrigin(.init(x: UserDefaults.standard.double(forKey: "companion.x"), y: UserDefaults.standard.double(forKey: "companion.y")))
        } else if let screen = NSScreen.main?.visibleFrame {
            companion.setFrameOrigin(.init(x: screen.minX + 34, y: screen.minY + 28))
        }
        updateCompanion()
    }
    private func updateCompanion() {
        guard companion != nil else { return }
        companion.hasShadow = !preferences.characterOnly
        companion.setContentSize(preferences.panelSize)
        companion.collectionBehavior = preferences.showOnAllSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        clampCompanion()
    }
    private func clampCompanion() {
        guard companion != nil else { return }
        companion.setFrame(CompanionPlacement.clamped(companion.frame, screens: NSScreen.screens.map(\.visibleFrame)), display: true)
    }
    private func saveCompanionOrigin() {
        UserDefaults.standard.set(companion.frame.minX, forKey: "companion.x")
        UserDefaults.standard.set(companion.frame.minY, forKey: "companion.y")
    }
    private func companionMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, action) in [("Open " + Self.appName, #selector(openChat)), ("Customize companion…", #selector(customize)), ("Hide companion", #selector(hideCompanion)), ("Quit " + Self.appName, #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self; menu.addItem(item)
        }
        return menu
    }
    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(); let appMenu = NSMenu(title: Self.appName)
        appMenu.addItem(withTitle: "About " + Self.appName, action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        let settings = appMenu.addItem(withTitle: "Settings…", action: #selector(settings), keyEquivalent: ","); settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide " + Self.appName, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let quit = appMenu.addItem(withTitle: "Quit " + Self.appName, action: #selector(quit), keyEquivalent: "q"); quit.target = self
        appItem.submenu = appMenu; main.addItem(appItem)
        let editItem = NSMenuItem(); let edit = NSMenu(title: "Edit")
        for (name, selector, key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {
            edit.addItem(withTitle: name, action: NSSelectorFromString(selector), keyEquivalent: key)
        }
        editItem.submenu = edit; main.addItem(editItem)
        let windowItem = NSMenuItem(); let menu = NSMenu(title: "Window")
        for (title, action, key) in [("Open " + Self.appName,#selector(openChat),"0"),("New conversation",#selector(newChat),"n"),("Show or hide desktop companion",#selector(toggleCompanion),"m")] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
        windowItem.submenu = menu; main.addItem(windowItem)
        let taskMenu = CodingChatMenu(coding: coding, desktop: desktop, projects: projects) { [weak self] in self?.openChat() }
        codingMenu = taskMenu; main.insertItem(taskMenu.item(), at: 2)
        CodingTaskNotifications.shared.install(coding: self.coding) { [weak self] id in
            guard let self, let task = self.coding.task(id) else { return }
            self.openChat(); self.desktop.page = "Tsukumo"; self.desktop.tsukumoSurface = "Project"; self.projects.selected = task.projectID; self.coding.select(id)
        }
        NSApp.mainMenu = main
    }
}
