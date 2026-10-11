import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoEngines
import TsukumoVoice

@main
struct TsukumoApp: App {
    @State private var model: AppModel

    init() {
        let launch = Launch()
        let folder = launch.uiTesting
            ? FileManager.default.temporaryDirectory.appendingPathComponent("TsukumoUITest-\(UUID().uuidString)", isDirectory: true)
            : AppModel.defaultFolder
        // UI tests keep their API keys apart from the owner's.
        let keys = KeychainAPIKeys(service: launch.uiTesting ? "com.zlichtman.tsukumo.api-keys.ui-testing" : "com.zlichtman.tsukumo.api-keys")
        // System One's hosted models' keys: this iPhone's Keychain only, apart from the API keys.
        let systemOneKeys = KeychainAPIKeys(service: launch.uiTesting ? "com.zlichtman.tsukumo.system-one-keys.ui-testing" : "com.zlichtman.tsukumo.system-one-keys")
        _model = State(initialValue: AppModel(folder: folder, keys: keys, systemOneKeys: systemOneKeys, launch: launch))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                // The first run, until it's done; then the chat is the whole app.
                if model.needsOnboarding {
                    OnboardingFlow(host: model)
                        .transition(.opacity)
                } else {
                    RootView()
                }
            }
            .environment(model)
            .environment(\.engineInfo, model.engineInfo)
            .environment(\.voice, model.voice)
            .preferredColorScheme(model.launch.appearance == "dark" ? .dark : model.launch.appearance == "light" ? .light : nil)
        }
    }
}

/// Two places, in a small Liquid Glass tab bar (design/UI-GUIDE.md, The app): Chat, and You (your picture and name,
/// then every setting). Your chats come up from the composer as a bottom sheet, so everything is in thumb reach.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme
    /// Settings, from your picture at the top right.
    @State private var settings = false
    @State private var conversations = false
    @State private var demo = false
    @State private var settingsPath: [SettingsDestination] = []
    @State private var played = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ChatScreen(session: model.session) {
            EmptyView()
        } trailing: {
            // Your picture opens Settings: the one way in, at the top right.
            Button { settings = true } label: {
                ProfilePicture(photo: model.profilePhoto, name: model.accounts.account?.name ?? "", size: 38)
                    .overlay(Circle().stroke(TsukumoTheme(scheme).hairline))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("openSettings")
            .task { model.loadProfilePhoto() }
        }
        .environment(\.composerActions, composerActions)
        .tint(TsukumoTheme(scheme).accent)
        .fullScreenCover(isPresented: $demo) { DemoScreen() }
        .sheet(isPresented: $settings) {
            SettingsScreen(path: $settingsPath, close: { settings = false }) { settings = false }
                .tsukumoSheet()
        }
        .sheet(isPresented: $conversations) {
            ConversationsSheet { conversations = false }
                .presentationDetents([.medium, .large])
                .tsukumoSheet()
        }
        .onAppear {
            switch model.launch.open {
            case "settings": settings = true
            case "activity": settingsPath = [.activity]; settings = true
            case "connections": settingsPath = [.connections]; settings = true
            case "models": settingsPath = [.models]; settings = true
            case "drawer": conversations = true
            default: break
            }
            if model.launch.demo == .play || model.launch.demo == .consent, !played {
                played = true
                Task { await DemoFixture.play(model.session, pace: model.launch.pace) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back in the app: catch up with the owner's other devices; what's in Notification Center is old news.
            if phase == .active {
                model.sync.syncSoon(after: 0); model.voice?.resumeBetterModels()
                model.notifications.clearDelivered()
                Task { await model.notifications.refresh() }
            }
            // Leaving the app stops listening and speaking, and lets a bot that's still working finish (its reply
            // comes as a notification).
            if phase == .background {
                model.voice?.listener?.cancel(); model.voice?.stopSpeaking()
                let model = model
                model.notifications.keepFinishing { model.session.isBusy }
            }
        }
        // The first message you send is when a reply might come while you're away: iOS asks then, once.
        .onChange(of: model.session.isBusy) { _, busy in if busy { model.notifications.askOnce() } }
        // A tapped notification opens its chat.
        .onChange(of: model.notifications.requestedThread) { _, id in
            guard let id else { return }
            model.notifications.requestedThread = nil
            if let thread = model.threads.first(where: { $0.id == id }) { model.open(thread) }
            conversations = false; demo = false; settings = false
        }
        .task { await model.accounts.checkAppleCredential() }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") { model.problem = nil }
        } message: { Text(model.problem ?? "") }
    }

    /// What the composer can do: your chats, a new chat, and a bot's model, power, and speed.
    private var composerActions: ComposerActions {
        let model = model
        return ComposerActions(showConversations: { conversations = true },
                               newChat: { model.newThread() },
                               engines: { model.engineChoices },
                               save: { model.save(bot: $0)?.message },
                               showDemo: { demo = true })
    }
}

/// "See how KemoSabe works": the website demo, played in its own chat on sample chats (Claude asks KemoSabe when
/// Sarah is free, and you allow it), with nothing of yours read and nothing saved. Close goes back to your chat.
struct DemoScreen: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var session = DemoFixture.session(asksFirst: true)
    @State private var played = false

    var body: some View {
        let theme = TsukumoTheme(scheme)
        ChatScreen(session: session) {
            EmptyView()
        } trailing: {
            HStack(spacing: 8) {
                Text("Demo · sample chats").font(.caption.weight(.semibold)).foregroundStyle(theme.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6).background(theme.fill, in: Capsule())
                ControlCircle("Close the demo", systemImage: "xmark") { dismiss() }
                    .accessibilityIdentifier("closeDemo")
            }
        }
        // Nothing to say out loud in the demo: no microphone.
        .environment(\.voice, nil)
        .task {
            guard !played else { return }
            played = true
            await DemoFixture.play(session)
        }
    }
}
