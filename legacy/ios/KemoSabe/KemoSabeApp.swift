import CloudKit
import SwiftUI

@main struct KemoSabeApp: App {
    @UIApplicationDelegateAdaptor(KemoAppDelegate.self) private var appDelegate
    init() {
        BundledFonts.register(); KemoType.configureNavigation(); RoutineBackground.register()
        var repository = LocalRepository.standard
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // --system-one-fixture: System One in its own folder and Keychain service, before its settings load.
            SystemOneFixture.install()
            // Every UI test starts with the default name; --first-run shows the naming sheet.
            for key in [CompanionIdentity.key, CompanionIdentity.namedKey, CompanionIdentity.personalityKey, CompanionCharacters.key, CompanionIntro.stepKey, AccountStore.key, "kemo.account.companionUpdated"] {
                AccountDirectory.accountSettings.removeObject(forKey: key)
            }
            // --onboarding runs as a clean install, in a new install's look (the KemoSabe theme, dark), and
            // so does the agent request demo (--agent-request-fixture), recorded in the default look.
            if ProcessInfo.processInfo.arguments.contains("--onboarding") || ProcessInfo.processInfo.arguments.contains("--agent-request-fixture") {
                for key in ["app.appearance.mode", "app.appearance.light", "app.appearance.dark", "app.appearance.custom"] { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--planner-fixture") || ProcessInfo.processInfo.arguments.contains("--isolated-fixture") {
            repository = .init(url: FileManager.default.temporaryDirectory.appendingPathComponent("PlannerUITests").appendingPathComponent(UUID().uuidString).appendingPathComponent("state.json"))
        }
        #endif
        let fixture = repository.owner == nil ? repository : nil
        let runtime = MobileAccountRuntime(repository: { fixture ?? .standard })
        _runtime = State(initialValue: runtime)
        #if DEBUG
        // A keyless Claude connection, so UI tests can see the chat's effort slider; nothing is sent.
        if fixture != nil, ProcessInfo.processInfo.arguments.contains("--model-effort-fixture") { runtime.store.installEffortFixture() }
        #endif
        WatchBridge.shared.start(store: runtime.store)
        VoiceAnywhere.shared.use(runtime.store)
        let voice = VoiceController(), navigation = AppNavigation()
        _voice = State(initialValue: voice); _navigation = State(initialValue: navigation)
        // First launch only: welcome, one account, the companion's intro, and optional permissions.
        // An install with data from before onboarding existed is marked finished and never sees it.
        let onboarding = OnboardingFlow(steps: PhoneOnboardingStep.all)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            // UI tests skip onboarding with their usual fixtures; --onboarding runs it as a clean install.
            if ProcessInfo.processInfo.arguments.contains("--onboarding") {
                AccountDirectory.accountSettings.removeObject(forKey: Onboarding.completedKey)
                onboarding.restart()
            } else { onboarding.skip() }
        } else if let evidence = runtime.store.onboardingEvidence() { onboarding.decide(evidence) }
        #else
        if let evidence = runtime.store.onboardingEvidence() { onboarding.decide(evidence) }
        #endif
        _onboarding = State(initialValue: onboarding)
        // Signing in or out finishes here and now: the old account's stores stop and close, and
        // everything reopens on the new account (see LiveAccountSwitch).
        LiveAccountSwitch.hooks = .init(quiesce: { voice.deactivate(); InAppNoticeCenter.shared.clear(); runtime.close() },
                                        reopen: { runtime.reopen(); SpeechVoices.shared.reload(); navigation.reopenAccountPage = navigation.panel == .settings })
    }
    @State private var runtime: MobileAccountRuntime
    @State private var voice: VoiceController
    @State private var navigation: AppNavigation
    @State private var connectors = ConnectorStore()
    @State private var onboarding: OnboardingFlow
    var body: some Scene {
        WindowGroup {
            #if DEBUG
            if MotionAuditView.requested { MotionAuditView() } else {
                AccountScopedRoot(runtime: runtime).environment(voice).environment(navigation).environment(connectors).environment(onboarding).modifier(MobileAppStyle())
            }
            #else
            AccountScopedRoot(runtime: runtime).environment(voice).environment(navigation).environment(connectors).environment(onboarding).modifier(MobileAppStyle())
            #endif
        }
    }
}

/// Everything on the iPhone bound to the open account: the app's store and its routines. When a
/// sign-in or sign-out finishes while the app runs, the old ones are closed and new ones opened
/// on the account now current (the shared stores reopen in `LiveAccountSwitch`).
@MainActor @Observable final class MobileAccountRuntime {
    private(set) var store: AppStore
    private(set) var routines: RoutineStore
    /// Changes with every reopen, so the UI below is rebuilt and every `@State` and `@AppStorage`
    /// in it reads the account now open.
    private(set) var scope: String
    @ObservationIgnored private let repository: () -> LocalRepository
    @ObservationIgnored private var reopened = 0
    init(repository: @escaping () -> LocalRepository) {
        self.repository = repository
        let store = AppStore(repository: repository(), provider: Self.provider)
        self.store = store
        routines = RoutineStore(ledger: store.proposalLedger)
        scope = AccountDirectory.current().id
        NotificationRoutes.shared.use(store)
        AccountSyncService.shared.attach(store: store, extra: [ProfileSyncAdapter(profiles: ProfileStore.shared), ProfileImageSyncAdapter.forSharedProfile(), DocsSyncAdapter.forSharedStore()])
        // Your profile's shares, and profiles shared with you (design/ACCOUNTS-AND-PROFILES.md).
        _ = ProfileSharingStore.shared; _ = SharedProfilesStore.shared
    }
    /// Apple's on-device model; UI tests can answer with `--reply-fixture` instead.
    private static var provider: any AssistantProvider {
        #if DEBUG
        if let fixture = UITestReplyFixture.fromLaunchArguments { return fixture }
        #endif
        return OnDeviceAssistant()
    }
    /// Stops the reply and background work and writes what's pending, while the old account is open.
    func close() { store.closeForAccountSwitch(); DocsStore.shared.close(); ProfileSharingStore.shared.close() }
    func reopen() {
        ProfileStore.reopen()
        ProfileSharingStore.reopen()
        SharedProfilesStore.reopen()
        DocsStore.reopen()
        let store = AppStore(repository: repository(), provider: Self.provider)
        self.store = store
        routines = RoutineStore(ledger: store.proposalLedger)
        WatchBridge.shared.use(store)
        VoiceAnywhere.shared.use(store)
        NotificationRoutes.shared.use(store)
        AccountSyncService.shared.attach(store: store, extra: [ProfileSyncAdapter(profiles: ProfileStore.shared), ProfileImageSyncAdapter.forSharedProfile(), DocsSyncAdapter.forSharedStore()])
        reopened += 1
        scope = AccountDirectory.current().id + "#\(reopened)"
    }
}

/// The app's UI for the open account, rebuilt (`.id`) whenever the account changes.
struct AccountScopedRoot: View {
    let runtime: MobileAccountRuntime
    var body: some View {
        RootView().environment(runtime.store).environment(runtime.routines).id(runtime.scope)
    }
}

struct RootView: View {
    @Environment(AppStore.self) private var store
    @Environment(VoiceController.self) private var voice
    @Environment(\.scenePhase) private var scenePhase
    @Environment(AppNavigation.self) private var navigation
    @Environment(ConnectorStore.self) private var connectors
    @Environment(RoutineStore.self) private var routines
    @Environment(OnboardingFlow.self) private var onboarding
    @Environment(\.mobilePalette) private var palette
    @State private var commandTask: Task<Void, Never>?
    /// Set when a private command itself moves to the on-device model, so the route-change
    /// handler doesn't cancel the command that was just started.
    @State private var routeSwitchedForCommand = false
    var body: some View {
        @Bindable var store = store
        @Bindable var navigation = navigation
        AssistantShell(performance: previewPerformance, send: submitText, newConversation: newConversation, cancelResponse: cancelResponse)
        // Claude through your paired Mac, in the chat's model menu (MacRelayPhone).
        .environment(\.chatAgents, chatAgents)
        // A scanned pairing link from the Mac asks before it pairs.
        .modifier(MacRelayInviteAlert())
        // Another agent's request for one piece of context: a card over whatever is on screen.
        .agentRequestSheet(store: store, colors: .init(background: palette.background, surface: palette.surface,
                                                       foreground: palette.foreground, accent: palette.accent))
        // Only the onboarding pages answer VoiceOver while they cover the app.
        .accessibilityHidden(onboarding.coversPhone)
        .sheet(item: $navigation.panel, onDismiss: { navigation.detail = nil; navigation.showingThemes = false }) { panel in
            PanelHost(panel: panel).sheet(item: $navigation.detail) { PanelHost(panel: $0) }
        }
        // A notification tap opens its conversation, Day, or "Approve it on your Mac".
        .modifier(NotificationRouting())
        // A profile someone shared with you opens as soon as its invitation is accepted.
        .modifier(SharedProfileArrival())
        // In-app notices, in their own window over the app and its sheets.
        .background(InAppNoticeWindowInstaller().frame(width: 0, height: 0).accessibilityHidden(true))
        .tint(palette.accent)
        // First launch: the onboarding pages cover the app, except while the companion's intro runs in Chat.
        .overlay {
            if onboarding.coversPhone { PhoneOnboardingView().transition(.opacity) }
            // No account on this iPhone (just signed out, say): sign in before anything else.
            else if AppleAccountSession.shared.needsSignIn { SignInGateView().transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.25), value: onboarding.coversPhone)
        .onChange(of: onboarding.coversPhone, initial: true) {
            // Voice waits while onboarding covers the app.
            if onboarding.coversPhone { navigation.voiceBlocks.insert("onboarding") } else { navigation.voiceBlocks.remove("onboarding") }
        }
        .onChange(of: onboarding.finishedRevision) { WatchBridge.shared.publishStatus() }
        .onAppear {
            voice.onCommand = handle; WatchBridge.shared.onCommand = handle; updateVoice()
            // Pairing is in Models → LLM → Agents on your Mac.
            MacRelayPhone.shared.openSettings = { navigation.home(); navigation.open(.model) }
            MacRelayPhone.shared.setActive(scenePhase != .background, store: store)
        }
        .onChange(of: navigation.voiceBlocks) { updateVoice() }
        .onChange(of: connectors.authorizing) { updateVoice() }
        .onChange(of: routines.busy) { updateVoice() }
        .onChange(of: voice.permissionsBusy) { updateVoice() }
        .onChange(of: voice.activationRevision) { updateVoice() }
        // A Talk to Kemo turn from the Action button or a Control holds the audio session until it ends.
        .onChange(of: VoiceAnywhere.shared.running, initial: true) {
            if VoiceAnywhere.shared.running { navigation.voiceBlocks.insert("voiceAnywhere") }
            else { navigation.voiceBlocks.remove("voiceAnywhere") }
        }
        .task {
            AccountSyncService.shared.setActive(scenePhase == .active)
            try? await store.proposalLedger.recover(now: Date())
            await routines.refresh()
            // UI automation never activates the host microphone. Release builds have no bypass.
            #if DEBUG
            InAppNoticeProbe.start(store: store)
            if ProcessInfo.processInfo.arguments.contains("--demo-voice-activity") { Task { await VoiceAnywhere.shared.demoActivity() } }
            if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                // The agent request demo: a conversation with Sarah and Muse's request for one thing in it.
                AgentRequestFixture.install(in: store)
                // A saved chat about dinner with Sarah, memories at every level, and a connection, for "Share context with…".
                ContextPacketFixture.install(in: store)
                // Nearby mid-exchange, for screenshots (`NearbyKemosFixture`).
                if NearbyKemosFixture.requested {
                    NearbyKemosFixture.prepare()
                    navigation.open(.nearby)
                    return
                }
                if ProcessInfo.processInfo.arguments.contains("--planner-fixture") {
                    await seedPlannerReviewFixture()
                    navigation.open(.workspace)
                    return
                }
                // Stands in for Apple's sheet so a UI test can watch a sign-in finish in place.
                if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--apple-sign-in=") }),
                   AppleAccountSession.shared.active.kind == .local {
                    var name = PersonNameComponents(); name.givenName = "Test"; name.familyName = "Person"
                    try? AppleAccountSession.shared.completeSignIn(userIdentifier: String(argument.dropFirst("--apple-sign-in=".count)),
                                                                  fullName: name, email: "test@privaterelay.appleid.com", account: AccountStore.shared)
                    navigation.open(.settings); navigation.reopenAccountPage = true
                    return
                }
                if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--voice-command=") }),
                   let command = VoiceCommand.parse(String(argument.dropFirst("--voice-command=".count))) { handle(command) }
                return
            }
            #endif
            // New users opt in through the microphone button. Existing enabled
            // sessions still resume through the same foreground lifecycle gate.
            updateVoice()
        }
        .onChange(of: store.state.voiceEnabled) { updateVoice() }
        .onChange(of: store.isThinking) { if !store.isThinking { navigation.voiceBlocks.remove("typedResponse") } }
        .onChange(of: store.modelLabel) { WatchBridge.shared.publishStatus() }
        .onChange(of: store.canChat) { WatchBridge.shared.publishStatus() }
        .onChange(of: watchLook) { WatchBridge.shared.publishStatus() }
        .onChange(of: store.state.selectedAPIProfile) { commandTask?.cancel(); connectors.cancel(); voice.deactivate(); updateVoice() }
        .onChange(of: store.modelRoute) {
            // A private command already cancelled older work when it switched; keep the command itself.
            if routeSwitchedForCommand { routeSwitchedForCommand = false; updateVoice(); return }
            // No old audio/job callbacks survive a privacy boundary change.
            commandTask?.cancel(); connectors.cancel(); voice.deactivate(); updateVoice()
        }
        .onChange(of: store.connectionProposal) {
            guard let connector = store.connectionProposal else { return }
            store.connectionProposal = nil
            connectors.selected = connector; navigation.open(.connections)
            // Opening setup is not permission, OAuth, a read, or an action.
        }
        .onChange(of: scenePhase) {
            // A launch in the background while locked couldn't read the store; decide once it can.
            if scenePhase == .active, !onboarding.decided, let evidence = store.onboardingEvidence() { onboarding.decide(evidence) }
            store.refreshAvailability(); connectors.refresh(); WatchBridge.shared.publishStatus()
            AccountSyncService.shared.setActive(scenePhase == .active)
            MacRelayPhone.shared.setActive(scenePhase != .background, store: store)
            if scenePhase == .active {
                // Your shares catch up with your profile, and profiles shared with you with theirs.
                Task { await ProfileSharingStore.shared.publish(); await SharedProfilesStore.shared.refresh() }
                // Better voice models the owner agreed to download finish in the background, on Wi-Fi.
                SpeechVoices.shared.resumeBetterModels()
            }
            if scenePhase == .background {
                commandTask?.cancel(); connectors.cancel()
                #if DEBUG
                if !ProcessInfo.processInfo.arguments.contains("--ui-testing") { Task { await routines.checkpoint() } }
                #else
                Task { await routines.checkpoint() }
                #endif
            }
            updateVoice()
        }
        .alert("Local storage needs attention", isPresented: Binding(get: { store.storageError != nil }, set: { _ in })) {
            Button(store.failedToLoad ? "Retry loading" : "Retry saving") { store.retrySave() }
        } message: { Text(store.storageError ?? "") }
    }
    /// The paired Mac's agents. UI tests and demos see them only once a Mac is paired, so their menus stay as recorded.
    private var chatAgents: [ChatAgentOption] {
        let relay = MacRelayPhone.shared
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"), relay.mac == nil || ChatHandoffFixture.requested { return [] }
        #endif
        return relay.options
    }
    /// What Apple Watch mirrors besides the model: Kemo's palette, the dark app theme, and the reading voice.
    private var watchLook: [String] {
        let theme = store.state.theme, dark = MobileAppearance.shared.colors(.dark)
        return [theme.id, theme.name, theme.body, theme.accent, theme.background, dark.background, dark.foreground, dark.accent,
                store.state.speechVoiceID ?? "", String(store.state.speechRate ?? 0)]
    }
    private func updateVoice() {
        if navigation.voiceBlocks.isEmpty && connectors.authorizing == nil && !routines.busy && !voice.permissionsBusy && scenePhase == .active { voice.activate(store: store) }
        else { voice.deactivate() }
    }
    private func newConversation() {
        voice.deactivate(); commandTask?.cancel(); store.newConversation()
        navigation.voiceBlocks.remove("typedResponse"); updateVoice()
    }
    private func cancelResponse() {
        if store.handoffWorking != nil { MacRelayPhone.shared.stop(store: store); return }
        voice.deactivate(); commandTask?.cancel(); store.cancel()
        navigation.voiceBlocks.remove("typedResponse"); updateVoice()
    }
    private func submitText(_ text: String) {
        if store.answerCompanionIntro(text) { return }
        // A chat with an agent: your message goes to it on your paired Mac, and "@KemoSabe …" to KemoSabe here.
        if store.state.chatAgent != nil {
            if let kemo = ChatAgentRouting.kemoMessage(text) { store.send(kemo, attachments: store.takeComposerAttachments()); return }
            if let working = store.handoffWorking { store.error = "\(working) is still answering. Stop it, or wait."; return }
            MacRelayPhone.shared.send(text, store: store); return
        }
        if let command = VoiceCommand.parse(text) {
            usePrivateRoute(for: command)
            store.appendVisibleMessage(role: "You", text: text); handle(command)
        } else {
            navigation.voiceBlocks.insert("typedResponse"); updateVoice()
            store.send(text, attachments: store.takeComposerAttachments(), completion: { _ in
                navigation.voiceBlocks.remove("typedResponse"); updateVoice()
            })
        }
    }
    private func respond(_ text: String) {
        store.appendVisibleMessage(role: "KemoSabe", text: text)
        voice.respond(text)
    }
    /// Private commands run on the on-device model. Switching cancels older work now, before the
    /// command starts, instead of in the route-change handler, which would cancel the command too.
    private func usePrivateRoute(for command: VoiceCommand) {
        guard command.requiresPrivateContext, store.modelRoute != .onDevice else { return }
        commandTask?.cancel(); connectors.cancel()
        routeSwitchedForCommand = true
        store.selectModel(.onDevice)
        if store.modelRoute != .onDevice { routeSwitchedForCommand = false }
    }
    private func handle(_ command: VoiceCommand) {
        usePrivateRoute(for: command)
        if let reply = VoiceSettingsAction.apply(command, to: &store.state) {
            store.save()
            if case .theme = command { navigation.showingThemes = false }
            respond(store.storageError == nil ? reply : "That setting couldn’t be saved. Check storage in Settings.")
            return
        }
        switch command {
        case .perform(let performance):
            navigation.perform(performance)
            respond(performance == .idle ? "Stopped." : "Here goes.")
        case .open(.animations) where !DeveloperMode.shared.enabled:
            respond("The animation gallery is a developer view. Tap the version in Settings, General, seven times to turn it on.")
        case .open(let panel):
            if panel == .connections { connectors.selected = nil }
            navigation.open(panel)
            respond(panel == .connections ? "Connections. Say connect my calendar, or choose an app." : "\(panel.rawValue.capitalized).")
        case .back:
            if (navigation.detail ?? navigation.panel) == .connections, connectors.selected != nil { connectors.selected = nil }
            else { navigation.back() }
            respond("Back.")
        case .home: navigation.home(); respond("I’m here.")
        case .runShortcut(let name): respond(ShortcutsIntegration.shared.run(name))
        case .help: navigation.open(.voice); respond("Try dance, wave, show your writing animation, connect my calendar, or speak slower.")
        case .pause:
            commandTask?.cancel(); connectors.cancel(); store.state.voiceEnabled = false; store.save(); voice.deactivate()
        case .cancel: commandTask?.cancel(); connectors.cancel(); store.cancel(); store.cancelStandup(); connectors.selected = nil; respond("Cancelled. Any drafts already prepared remain for review.")
        case .connect(let id): beginConnection(id)
        case .connectSelected:
            guard navigation.panel == .connections || navigation.detail == .connections, let id = connectors.selected else { navigation.open(.connections); respond("Which connection? Say connect my calendar, reminders, or contacts."); return }
            beginConnection(id)
        case .disconnect(let id): respond(connectors.disconnect(id, store: store))
        case .agenda: readConnection(.calendar)
        case .reminders: readConnection(.reminders)
        case .contact(let name): readConnection(.contacts, query: name)
        case .goodnight:
            commandTask?.cancel()
            commandTask = Task {
                await routines.goodnight(); guard !Task.isCancelled else { return }; updateVoice()
                respond(routines.error ?? (routines.state.context?.learning == false ? "Goodnight." : "Goodnight. I’ve noted when you went to bed."))
            }
        case .morning:
            commandTask?.cancel()
            commandTask = Task {
                await routines.morning()
                guard !Task.isCancelled else { return }; updateVoice()
                if let error = routines.error { respond(error); return }
                if store.canChat { voice.ask("Help me plan my morning. Use what you know about me and ask the most useful next question; do not assume how I slept.") }
                else { respond("Good morning. Apple Intelligence isn’t available yet, but your wake-up time is noted.") }
            }
        default: break
        }
    }
    private func beginConnection(_ id: ConnectorID) {
        navigation.open(.connections); connectors.selected = id
        commandTask?.cancel()
        commandTask = Task {
            let reply = await connectors.connect(id, store: store)
            guard !Task.isCancelled else { return }
            updateVoice(); respond(reply)
        }
    }
    private func readConnection(_ id: ConnectorID, query: String? = nil) {
        commandTask?.cancel()
        commandTask = Task {
            let reply = await connectors.read(id, query: query, store: store)
            guard !Task.isCancelled else { return }
            if !connectors.status(id, state: store.state).usable { navigation.open(.connections) }
            respond(reply)
        }
    }
    private var previewPerformance: String {
        #if DEBUG
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-performance=") }) {
            let id = String(argument.dropFirst("--preview-performance=".count))
            if ArtworkPerformance(rawValue: id) != nil { return id }
        }
        if ProcessInfo.processInfo.arguments.contains("--preview-writing") { return "writing" }
        #endif
        return navigation.performance.rawValue
    }
    #if DEBUG
    /// UI-test fixture only. Does not invoke a model, permissions, or external tools.
    private func seedPlannerReviewFixture() async {
        let note = MemoryNote(text: "Team updates start with the result, then blockers.", scope: "Company")
        store.saveMemory(note)
        let request = PlanningRequest(message: "Draft my update and remember that I prefer short paragraphs.", history: [], memories: [note], standupFormat: store.state.standupFormat)
        let plan = CompanionPlan(answer: "", actions: [
            .init(kind: .remember, title: "Writing preference", content: "I prefer short paragraphs."),
            .init(kind: .draft, title: "Team update draft", content: "Result: [add today's result].\nBlockers: [confirm any blockers].")
        ])
        do {
            let proposals = try PlanValidator.proposals(plan, request: request, model: "UI test fixture", currentNotes: store.state.memories, now: Date())
            try await store.proposalLedger.enqueuePlan(proposals)
            store.proposalRevision += 1
            await routines.refresh()
        } catch { store.error = "Review fixture couldn't be prepared." }
    }
    #endif
}

struct PageBackground: View {
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        palette.background.ignoresSafeArea()
    }
}

struct Eyebrow: View {
    let text: String
    var body: some View { Text(text).font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary) }
}


struct MotionLibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var selected = "writing"
    @State private var category = "All"
    @State private var search = ""
    @State private var searchPresented = false
    @State private var playing = true
    @State private var bpm = 100.0
    @State private var replay = 0
    @State private var visible = false
    private var entries: [Performance] { Performance.suite.filter { (category == "All" || $0.group == category) && (search.isEmpty || ($0.name + $0.description).localizedCaseInsensitiveContains(search)) } }
    private var current: Performance? { Performance.all.first { $0.id == selected } }
    var body: some View {
        NavigationStack {
            ZStack {
                PageBackground()
                GeometryReader { geometry in
                VStack(spacing: 8) {
                    Group {
                            ArtworkCompanion(theme: store.state.theme, performance: selected, thinking: selected == "thinking", speaking: selected == "speaking", listening: selected == "listening", reducedMotion: reduceMotion, active: playing && visible && scenePhase == .active, bpm: bpm, replay: replay)
                    }
                        .frame(height: min(240, max(80, geometry.size.height * 0.38))).clipShape(RoundedRectangle(cornerRadius: 28)).padding(.horizontal, 20)
                    HStack {
                        VStack(alignment: .leading, spacing: 4) { Text(current?.name ?? "Animation unavailable").font(KemoType.font(.headline)); Text(current?.group ?? "").font(KemoType.font(.caption)).foregroundStyle(.secondary) }
                        Spacer()
                        Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") { playing.toggle() }.labelStyle(.iconOnly).frame(width: 44, height: 44).accessibilityIdentifier("motionPause")
                        Button("Replay", systemImage: "arrow.counterclockwise") { replay += 1; playing = true }.labelStyle(.iconOnly).frame(width: 44, height: 44)
                    }.padding(.horizontal, 24)
                    if ArtworkPerformance(rawValue: selected)?.prop == .headphones {
                        HStack { Text("\(Int(bpm)) BPM").monospacedDigit(); Slider(value: $bpm, in: 60...180, step: 1).accessibilityLabel("Demo tempo") }.font(KemoType.font(.caption)).padding(.horizontal, 24)
                        Text("Demo beat clock · no music service connected").font(KemoType.font(.caption2)).foregroundStyle(.secondary)
                    }
                    Picker("Category", selection: $category) { ForEach(["All", "Conversation", "Work", "Life"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu).accessibilityIdentifier("motionCategory")
                    List {
                        Section {
                            ForEach(entries) { item in
                                Button { selected = item.id; replay += 1; searchPresented = false } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: selected == item.id ? "waveform.circle.fill" : "play.circle").font(KemoType.font(.title2)).foregroundStyle(store.state.theme.bodyColor)
                                        VStack(alignment: .leading, spacing: 4) { Text(item.name).foregroundStyle(.primary); Text(item.group).font(KemoType.font(.caption)).foregroundStyle(.secondary) }
                                        Spacer()
                                        if selected == item.id { Image(systemName: "checkmark").foregroundStyle(store.state.theme.bodyColor) }
                                    }.padding(.vertical, 5)
                                }.accessibilityIdentifier("animation-" + item.id).listRowBackground(Color.white.opacity(0.035))
                            }
                        } header: { Text(entries.count == 1 ? "1 animation" : "\(entries.count) animations") }
                    }.scrollContentBackground(.hidden).listStyle(.insetGrouped)
                }
                }
            }.navigationTitle("Motion studio").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
                .searchable(text: $search, isPresented: $searchPresented, prompt: "Find an animation")
                .onAppear { visible = true }.onDisappear { visible = false }
        }
    }
}

struct MemoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var editing: MemoryNote?
    @State private var deleting: MemoryNote?
    var body: some View {
        @Bindable var store = store
        NavigationStack {
            ZStack {
                PageBackground()
                List {
                    Section {
                        Label("Kept on this device", systemImage: "lock.shield").foregroundStyle(store.state.theme.bodyColor)
                        Text("Review what KemoSabe remembers. Tap a note to edit it or change its privacy, or swipe to forget it.").font(KemoType.font(.callout)).foregroundStyle(.secondary)
                    }.listRowBackground(Color.white.opacity(0.04))
                    Section("Saved memories · \(store.state.memories.count)") {
                        if store.state.memories.isEmpty { Text("No saved notes yet. Tap + to add one.").foregroundStyle(.secondary) }
                        ForEach(store.state.memories) { note in
                            Button { editing = note } label: {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(note.scope + " · " + store.memoryLevel(note).title).font(KemoType.font(.caption2, weight: .semibold)).foregroundStyle(store.state.theme.bodyColor)
                                    Text(note.text).foregroundStyle(.primary).lineLimit(4)
                                }.padding(.vertical, 6)
                            }.swipeActions { Button("Delete", role: .destructive) { deleting = note } }
                        }
                    }.listRowBackground(Color.white.opacity(0.04))
                    Section { Text("No cloud sync, analytics, or work-account connection. Voice capture pauses here; no audio recordings are saved. Notes and recent conversation are stored with iOS file protection and excluded from device backups. Delete sensitive company notes before changing roles. Removing a note does not remove earlier replies that referenced it.").font(KemoType.font(.caption)).foregroundStyle(.secondary) }.listRowBackground(Color.clear)
                }.scrollContentBackground(.hidden)
            }.navigationTitle("Memory")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
                .toolbar { Button("Add memory", systemImage: "plus") { editing = MemoryNote(text: "") }.accessibilityIdentifier("addMemory") }
                .sheet(item: $editing) { note in MemoryEditor(note: note) }
                .confirmationDialog("Delete this memory?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) { Button("Delete memory", role: .destructive) { if let note = deleting { store.deleteMemory(note.id) }; deleting = nil } }
        }
    }
}

struct MemoryEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State var note: MemoryNote
    var body: some View {
        NavigationStack {
            Form {
                Section("Note") { TextEditor(text: $note.text).frame(minHeight: 150).accessibilityIdentifier("memoryText"); Text("\(note.text.count)/1,000 characters").font(KemoType.font(.caption)).foregroundStyle(.secondary) }
                Picker("Label", selection: $note.scope) { Text("Personal").tag("Personal"); Text("Company").tag("Company"); Text("Industry").tag("Industry") }
                // Secret is "Not used in chat"; the other levels say which models may read it.
                PrivacyLevelPicker(level: $note.privacyLevel)
            }.navigationTitle("Memory").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { store.saveMemory(note); dismiss() }.disabled(note.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || note.text.count > 1000).accessibilityIdentifier("saveMemory") }
                }
        }
    }
}

/// Registers for CloudKit's silent pushes, so another device's change syncs here soon after it's
/// made. Only a build that syncs (`AccountSyncService.availableInBuild`) registers.
final class KemoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        if AccountSyncService.availableInBuild, !AccountDirectory.isTestHost { application.registerForRemoteNotifications() }
        // Before launch finishes, so a tap that launched the app is handled.
        PhoneNotificationDelegate.shared.install()
        return true
    }
    /// The app's window scenes use `KemoSceneDelegate`, so an invitation to someone's profile opens here.
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: session.role)
        if session.role == .windowApplication { configuration.delegateClass = KemoSceneDelegate.self }
        return configuration
    }
    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard AccountSyncService.availableInBuild, let notification = CKNotification(fromRemoteNotificationDictionary: userInfo) else { return .noData }
        // Something shared with you changed: only that is fetched.
        if notification.subscriptionID == CKShareDatabase.sharedSubscription {
            await SharedProfilesStore.shared.refresh()
            return .newData
        }
        await AccountSyncService.shared.remoteChanged()
        // A coding agent on your Mac may need you (`CrossDeviceNotices`); posted before the push's time runs out.
        CrossDeviceNotices.shared.deliver()
        return .newData
    }
}

/// Accepts invitations to someone's profile: a tap on the link opens KemoSabe (the Info.plist key
/// `CKSharingSupported`), and iOS hands the invitation here, at launch or while running.
final class KemoSceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options: UIScene.ConnectionOptions) {
        guard let metadata = options.cloudKitShareMetadata else { return }
        Task { @MainActor in await SharedProfilesStore.shared.accept(metadata) }
    }
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { @MainActor in await SharedProfilesStore.shared.accept(metadata) }
    }
}
