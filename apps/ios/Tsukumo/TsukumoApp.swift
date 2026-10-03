import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoEngines

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
        _model = State(initialValue: AppModel(folder: folder, keys: keys, launch: launch))
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
            .preferredColorScheme(model.launch.appearance == "dark" ? .dark : model.launch.appearance == "light" ? .light : nil)
        }
    }
}

/// The chat is the whole app. The conversations drawer slides in from the left (its button, or a
/// swipe from the left edge) with New chat, your chats, and Activity; Settings is the button at the
/// top right.
struct RootView: View {
    enum Sheet: String, Identifiable {
        case settings, activity, createBot
        var id: String { rawValue }
    }
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drawerOpen = false
    @State private var sheet: Sheet?
    @State private var played = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                ChatScreen(session: model.session, onCreateBot: { sheet = .createBot }) {
                    HeaderButton("Your chats", systemImage: "sidebar.leading") { setDrawer(true) }
                        .accessibilityIdentifier("openDrawer")
                } trailing: {
                    HeaderButton("Settings", systemImage: "gearshape") { sheet = .settings }
                        .accessibilityIdentifier("openSettings")
                }
                .accessibilityHidden(drawerOpen)

                // A swipe from the left edge opens the drawer.
                Color.clear
                    .frame(width: 16)
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                        if drag.translation.width > 50 { setDrawer(true) }
                    })
                    .accessibilityHidden(true)

                if drawerOpen {
                    Color.black.opacity(0.4).ignoresSafeArea()
                        .onTapGesture { setDrawer(false) }
                        .accessibilityLabel("Close your chats")
                        .accessibilityAddTraits(.isButton)
                        .transition(.opacity)
                    ConversationsDrawer(close: { setDrawer(false) }, showActivity: {
                        setDrawer(false)
                        sheet = .activity
                    })
                    .frame(width: min(330, geometry.size.width * 0.86))
                    .gesture(DragGesture(minimumDistance: 12).onEnded { drag in
                        if drag.translation.width < -50 { setDrawer(false) }
                    })
                    .transition(.move(edge: .leading))
                    .zIndex(1)
                }
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .settings: SettingsScreen()
            case .activity: ActivityScreen()
            case .createBot:
                BotEditor(existing: model.bots, engines: model.engineChoices, seed: model.launch.uiTesting ? 7 : nil) { bot in
                    model.save(bot: bot)
                    self.sheet = nil
                } onCancel: { self.sheet = nil }
            }
        }
        .onAppear {
            switch model.launch.open {
            case "settings": sheet = .settings
            case "activity": sheet = .activity
            case "drawer": drawerOpen = true
            default: break
            }
            if model.launch.createBot { sheet = .createBot }
            if model.launch.demo == .play || model.launch.demo == .consent, !played {
                played = true
                Task { await DemoFixture.play(model.session, pace: model.launch.pace) }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Back in the app: catch up with the owner's other devices.
            if phase == .active { model.sync.syncSoon(after: 0) }
        }
        .task { await model.accounts.checkAppleCredential() }
        .alert("Something went wrong", isPresented: Binding(get: { model.problem != nil }, set: { if !$0 { model.problem = nil } })) {
            Button("OK") { model.problem = nil }
        } message: { Text(model.problem ?? "") }
    }

    private func setDrawer(_ open: Bool) {
        withAnimation(reduceMotion ? nil : .spring(duration: 0.32, bounce: 0.12)) { drawerOpen = open }
    }
}
