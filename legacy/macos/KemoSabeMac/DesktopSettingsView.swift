import AuthenticationServices
import SwiftUI
import UniformTypeIdentifiers

struct DesktopSettingsView: View {
    @Environment(DesktopNavigation.self) private var desktop
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    @Environment(OnboardingFlow.self) private var onboarding
    var changed: () -> Void
    @State private var developer = DeveloperMode.shared
    @State private var versionNote: String?
    @State private var updater = AppUpdater.shared
    @State private var account = AccountStore.shared
    @State private var session = AppleAccountSession.shared
    @State private var accountSync = AccountSyncService.shared
    @State private var confirmingSignOut = false
    @State private var accountName = ""
    @State private var accountHandle = ""
    @State private var choosingPhoto = false
    @State private var photoProblem: String?
    @State private var git = GitIdentity()
    var body: some View {
        @Bindable var desktop = desktop
        HStack(spacing: 0) {
            if desktop.showSidebar { sidebar }
            VStack(alignment: .leading, spacing: 0) {
                if !desktop.showSidebar { TitlebarControls().fixedSize().padding(.leading, 10) }
                Text(currentPage).font(preferences.font(20)).fontWeight(.medium).frame(maxWidth: 760, alignment: .leading).padding(.horizontal, 28).padding(.top, desktop.showSidebar ? 44 : 14).padding(.bottom, 12).frame(maxWidth: .infinity)
                Group {
                    switch currentPage {
                    case "Account": accountPage
                    case "Notifications": MacNotificationsPage()
                    case "Usage": usage
                    case "Git": gitPage
                    case "Appearance": SettingsContent { InterfaceAppearanceSection(changed: changed) }
                    case "Companion": DesktopCompanionSettings(changed: changed)
                    case "Animations": if developer.enabled { AnimationGallery() } else { general }
                    case "Shortcuts": ShortcutsSettingsPage()
                    case "Tools": tools
                    case "Archived chats": SettingsContent { ConversationArchiveList() }
                    case "Editors": CodingAgentsSettings()
                    case "Agents": CodingAgentsPage()
                    case "Terminal": TerminalSettingsPage()
                    case "Personalization": PersonalRoutineSettings().formStyle(.grouped).scrollContentBackground(.hidden).environment(\.openConnections) { desktop.settingsPage = "Connections" }
                    case "Models":
                        ModelConnectionsView(tab: modelsTab, openPersonalization: { desktop.settingsPage = "Personalization" })
                            .id(modelsTab)
                    case "Connections": DesktopConnectionsView()
                    case "Privacy": privacy
                    default: if let note = SettingsCatalog.page(currentPage)?.planned { planned(note) } else { general }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // The sidebar runs up under the transparent titlebar, as in the main window and Codex.
        .ignoresSafeArea(.container, edges: .top)
        .font(preferences.font()).controlSize(.regular).buttonStyle(DesktopButtonStyle()).toggleStyle(.switch).accessibilityIdentifier("desktopSettings")
    }
    /// The same sidebar as the main window: controls beside the traffic lights, then the pages.
    private var sidebar: some View {
        @Bindable var desktop = desktop
        return VStack(alignment: .leading, spacing: 10) {
            TitlebarControls()
            Button { desktop.settingsPage = nil; desktop.settingsSearch = "" } label: {
                // A full row, like the pages below, so the highlight covers the label.
                HStack(spacing: 9) { Image(systemName: "arrow.left").frame(width: 16); Text("Back to app"); Spacer(minLength: 0) }
                    .font(preferences.font(13)).padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(DesktopRowButtonStyle()).accessibilityIdentifier("backToApp")
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.secondary)
                TextField("Search", text: $desktop.settingsSearch).textFieldStyle(.plain).font(preferences.font(13)).accessibilityIdentifier("settingsSearch")
            }.padding(.horizontal, 11).padding(.vertical, 8).background(Color.primary.opacity(0.06), in: Capsule())
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // The same groups and pages as iPhone, from the shared catalog.
                    ForEach(SettingsCatalog.groups(for: .mac, search: desktop.settingsSearch), id: \.name) { group in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(SettingsCatalog.title(group.name)).font(preferences.font(13)).foregroundStyle(.secondary).padding(.horizontal, 8).padding(.vertical, 5)
                            ForEach(group.pages) { page in
                                Button { desktop.settingsPage = page.id } label: {
                                    HStack(spacing: 9) { Image(systemName: page.symbol).frame(width: 16); Text(page.title).lineLimit(1); Spacer(minLength: 0) }
                                        .font(preferences.font(13)).padding(.horizontal, 8).padding(.vertical, 7).contentShape(Rectangle())
                                }.buttonStyle(DesktopRowButtonStyle(selected: currentPage == page.id)).accessibilityIdentifier("settings-" + page.id)
                            }
                        }
                    }
                }
            }.scrollIndicators(.hidden)
        }.padding(.horizontal, 10).padding(.bottom, 12).frame(width: 248)
            .background(SidebarSurface(tint: preferences.palette(scheme).sidebar, translucent: preferences.translucentSidebar))
            .overlay(alignment: .trailing) { Divider() }
    }
    /// The page to show. Pages that became a tab or a section (Voice, System One, Profile,
    /// Coding runtimes…) open the page that holds them, so older links and commands still work.
    private var currentPage: String {
        let page = desktop.settingsPage ?? "General"
        if page == "About" { return "General" }
        return SettingsCatalog.moved[page]?.page ?? page
    }
    private var modelsTab: ModelsTab { SettingsCatalog.moved[desktop.settingsPage ?? ""]?.tab ?? .llm }
    /// A page that isn't built yet says what it will do, so nothing is silently missing.
    private func planned(_ note: String) -> some View {
        SettingsContent {
            SettingsCard(title: "Complete later") {
                SettingsRow(title: "Not available yet", detail: note) { Text("Planned").foregroundStyle(.secondary) }
            }
        }
    }
    /// A square-cropped JPEG no larger than `maxSide` on each side.
    static func jpeg(_ image: NSImage, maxSide: CGFloat) -> Data? {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        let side = min(cg.width, cg.height)
        guard let square = cg.cropping(to: CGRect(x: (cg.width - side) / 2, y: (cg.height - side) / 2, width: side, height: side)) else { return nil }
        let target = Int(min(maxSide, CGFloat(side)))
        guard let context = CGContext(data: nil, width: target, height: target, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(square, in: CGRect(x: 0, y: 0, width: target, height: target))
        guard let scaled = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: scaled).representation(using: .jpeg, properties: [.compressionFactor: 0.85])
    }
    /// Read from the bundle so local, CI and future builds show their real number.
    static var versionLabel: String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }
    private var tools: some View {
        SettingsContent {
            SettingsCard(title: "Tool servers") {
                SettingsRow(title: "MCP servers", detail: "Connect tools that agents can use, each with its own permissions. In development: nothing is connected or given access yet.") { Text("Coming").foregroundStyle(.secondary) }
                Divider()
                SettingsRow(title: "Agents", detail: "Bring your own coding agent (any Agent Client Protocol agent), each a separate recipient with its own grants.") { Button("Agents…") { desktop.settingsPage = "Agents" } }
            }
            SettingsCard(title: "Available now") {
                SettingsRow(title: "Apple apps", detail: "Calendar, Reminders, and Contacts.") { Button("Connections…") { desktop.settingsPage = "Connections" } }
                Divider()
                SettingsRow(title: "Shortcuts", detail: "Run shortcuts you allow by name.") { Button("Shortcuts…") { desktop.settingsPage = "Shortcuts" } }
                Divider()
                SettingsRow(title: "Model endpoints", detail: "Compatible APIs and local servers.") { Button("Models…") { desktop.settingsPage = "Models" } }
                Divider()
                SettingsRow(title: "Editors", detail: "Open a project in the app you choose.") { Button("Editors…") { desktop.settingsPage = "Editors" } }
            }
        }
    }
    private var accountPage: some View {
        SettingsContent {
            // Your account: the same name and photo on every device.
            SettingsCard(title: "Account") {
                HStack(spacing: 14) {
                    AccountPhoto(size: 54)
                    VStack(alignment: .leading, spacing: 6) {
                        Button("Choose photo…") { choosingPhoto = true }.accessibilityIdentifier("chooseAccountPhoto")
                        if account.account.photoFile != nil { Button("Remove photo") { try? account.setPhoto(nil) } }
                        if let photoProblem { Text(photoProblem).font(.caption).foregroundStyle(.orange) }
                    }
                    Spacer()
                }.padding(.vertical, 12)
                Divider()
                SettingsRow(title: "Name") {
                    // The Mac's own name is only a suggestion: it's never saved to your account unless you type it.
                    TextField("Your name", text: $accountName, prompt: Text(account.displayName.isEmpty ? "Your name" : account.displayName))
                        .textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit { account.update { $0.name = accountName } }.accessibilityIdentifier("accountName")
                }
                Divider()
                SettingsRow(title: "Username") {
                    TextField("username", text: $accountHandle).textFieldStyle(.roundedBorder).frame(width: 200)
                        .onSubmit { account.update { $0.handle = accountHandle }; accountHandle = account.account.handle }
                }
            }
            .onAppear { accountName = account.account.name; accountHandle = account.account.handle }
            // A name or username that arrives from another device shows here at once, unless you've
            // started changing that field, so leaving the page never writes an older one back over it.
            .onChange(of: account.account.name) { old, new in if accountName == old { accountName = new } }
            .onChange(of: account.account.handle) { old, new in if accountHandle == old { accountHandle = new } }
            .onDisappear {
                guard accountName != account.account.name || accountHandle != account.account.handle else { return }
                account.update { $0.name = accountName; $0.handle = accountHandle }
            }
            .fileImporter(isPresented: $choosingPhoto, allowedContentTypes: [.image]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    guard let image = NSImage(contentsOf: url), let data = Self.jpeg(image, maxSide: 512) else { throw CocoaError(.fileReadCorruptFile) }
                    try account.setPhoto(data); photoProblem = nil
                } catch { photoProblem = "That image couldn't be used. Try a JPEG or PNG." }
            }
            if let note = session.lastSwitchNote {
                SettingsCard(title: "") {
                    SettingsRow(title: "Account changed", detail: note) { Button("OK") { session.dismissLastSwitch() } }
                }
            }
            // Sign in with Apple links this Mac and your iPhone to one account and one profile.
            SettingsCard(title: "Sign in") {
                SettingsRow(title: "Apple Account", detail: session.status == .local ? "One account for your iPhone, Mac, and Watch." : nil) {
                    if !AppleAccountSession.availableInBuild {
                        Text("Complete later").foregroundStyle(.secondary)
                    } else if session.status == .local || session.status == .needsConfirmation {
                        SignInWithAppleButton(.signIn, onRequest: session.prepare, onCompletion: { session.handle($0, account: account) })
                            .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                            .frame(width: 200, height: 32).accessibilityIdentifier("signInWithApple")
                    } else if session.status == .finishingSignIn || session.status == .finishingSignOut {
                        // Signing in or out finishes at once; this shows only when it couldn't (nothing changed then).
                        HStack {
                            Button("Try again") { session.retrySwitch() }.accessibilityIdentifier("retryAccountSwitch")
                            Button("Restart \(KemoSabeMacApp.appName)") { Self.relaunch() }.accessibilityIdentifier("restartForAccount")
                        }
                    } else {
                        Text(session.statusTitle).foregroundStyle(.secondary).accessibilityIdentifier("appleAccountStatus")
                    }
                }
                if let email = account.account.email {
                    Divider()
                    SettingsRow(title: "Email") { Text(email).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                if let notice = session.notice {
                    Divider()
                    SettingsRow(title: "Note", detail: notice) { EmptyView() }
                }
                if session.status == .linked || session.status == .finishingSignIn || session.status == .needsConfirmation {
                    Divider()
                    SettingsRow(title: session.status == .finishingSignIn ? "Cancel sign-in" : "Sign out") {
                        Button(session.status == .finishingSignIn ? "Cancel" : "Sign out…") {
                            if session.status == .finishingSignIn { session.signOut() } else { confirmingSignOut = true }
                        }.accessibilityIdentifier("appleSignOut")
                    }
                }
            }
            .onAppear { session.refresh() }
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut) {
                Button("Sign out", role: .destructive) { session.signOut() }
            } message: { Text("Nothing is deleted. It comes back when you sign in again.") }
            if accountSync.canSync {
                // One switch and its status (the owner, September 25, 2026: "this is overcomplicated").
                SettingsCard(title: "Sync") {
                    SettingsRow(title: accountSync.title, detail: accountSync.hasProblem || accountSync.usesRelay ? (accountSync.statusDetail ?? accountSync.statusTitle) : accountSync.statusTitle) {
                        HStack(spacing: 10) {
                            if accountSync.phase == .syncing { KemoOrb(size: 14, state: .connecting) }
                            Toggle("iCloud Sync", isOn: Binding(get: { accountSync.enabled }, set: { accountSync.enabled = $0 }))
                                .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("syncEnabled")
                        }
                    }
                    if accountSync.phase == .mismatch {
                        Divider()
                        SettingsRow(title: "Use this iCloud account") {
                            Button("Use this account") { Task { await accountSync.useThisICloudAccount() } }.accessibilityIdentifier("syncRebind")
                        }
                    }
                }
            }
        }
    }
    /// The fallback when a sign-in or sign-out couldn't finish while Tsukumo ran: quit and reopen,
    /// and the launch finishes it (see AccountSwitch).
    static func relaunch() {
        let script = "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "tsukumo-account", Bundle.main.bundlePath]
        do { try process.run(); NSApp.terminate(nil) } catch { AppleAccountSession.shared.notice = "Tsukumo couldn't restart itself. Quit and reopen it to finish." }
    }
    private var usage: some View {
        let rows = UsageSummary.rows(archives: store.state.conversationArchives ?? [], current: store.conversationMessages, currentModel: store.modelLabel)
        return SettingsContent {
            SettingsCard(title: "Messages on this Mac") {
                if rows.isEmpty {
                    SettingsRow(title: "No chats yet") { EmptyView() }
                }
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    SettingsRow(title: row.model, detail: "\(row.chats) \(row.chats == 1 ? "chat" : "chats") · \(row.replies) \(row.replies == 1 ? "reply" : "replies")") {
                        Text("\(row.sent) sent").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            SettingsCard(title: "Billing") {
                SettingsRow(title: "Your models bill you", detail: "Apple's on-device model is free. Connected models are billed by their providers under your own keys; Tsukumo charges nothing.") { EmptyView() }
                Divider()
                SettingsRow(title: "Tokens and cost", detail: "Per-model token counts and spend from each provider's usage reports. Complete later.") { Text("Planned").foregroundStyle(.secondary) }
            }
        }
    }
    private var gitPage: some View {
        SettingsContent {
            SettingsCard(title: "Identity") {
                SettingsRow(title: "Author name", detail: "Commits from Tsukumo's terminals and agents use your Git settings.") { Text(git.name ?? "Not set").foregroundStyle(.secondary) }
                Divider()
                SettingsRow(title: "Author email") { Text(git.email ?? "Not set").foregroundStyle(.secondary) }
                Divider()
                SettingsRow(title: "Git") { Text(git.version ?? "Not installed").foregroundStyle(.secondary) }
            }
            SettingsCard(title: "Agents") {
                SettingsRow(title: "Branch prefix", detail: "The prefix for branches agents create, and whether they may commit or push. Complete later.") { Text("Planned").foregroundStyle(.secondary) }
            }
            Text("Change your name and email with git config in the terminal; Tsukumo reads them here.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.task { git = await GitIdentity.load() }
    }
    private var general: some View {
        @Bindable var preferences = preferences
        @Bindable var desktop = desktop
        return SettingsContent {
            SettingsCard(title: KemoSabeMacApp.appName) {
                SettingsRow(title: "Version", detail: versionNote ?? updateNote) {
                    HStack(spacing: 12) {
                        // Seven taps unlock developer settings, the same on iPhone.
                        Text(Self.versionLabel).foregroundStyle(.secondary).contentShape(Rectangle())
                            .onTapGesture { versionNote = developer.tapVersion() }.accessibilityIdentifier("versionNumber")
                        updateButton
                    }
                }
            }
            // For testing: onboarding again from the welcome. Developer settings only.
            if developer.enabled {
                DeveloperSection {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Onboarding")
                            Text("Runs the welcome, sign-in, companion, and Tsukumo setup again. Nothing is deleted.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Show again") { desktop.settingsPage = nil; onboarding.restart() }.accessibilityIdentifier("replayOnboarding")
                    }
                }
            }
            SettingsCard(title: "Workspace") {
                SettingsRow(title: "Show menu bar icon") { Toggle("Show menu bar icon", isOn: $preferences.showMenuBar).labelsHidden().toggleStyle(.switch).onChange(of: preferences.showMenuBar) { changed() } }
                Divider()
                SettingsRow(title: "Show navigation sidebar") { Toggle("Show navigation sidebar", isOn: $desktop.showSidebar).labelsHidden().toggleStyle(.switch) }
                Divider()
                SettingsRow(title: "Close or minimize", detail: "Keep \(CompanionIdentity.name) nearby as a movable desktop companion.") { Button("Customize…") { desktop.settingsPage = "Companion" } }
            }
            SettingsCard(title: "Models and context") {
                SettingsRow(title: "Current model", detail: store.modelLabel) { Button("Manage…") { desktop.settingsPage = "Models" } }
                Divider()
                SettingsRow(title: "Saved memories", detail: "Review, edit, or forget what KemoSabe remembers.") { Button("Open…") { desktop.settingsPage = "Personalization" } }
                Divider()
                SettingsRow(title: "Privacy and permissions") { Button("Review…") { desktop.settingsPage = "Privacy" } }
            }
        }
    }
    /// Check for Updates, and then the same steps as the sidebar card, so updating works from here too.
    @ViewBuilder private var updateButton: some View {
        switch updater.phase {
        case .available:
            Button(updater.updateTitle) { updater.update(desktop: desktop) }.accessibilityIdentifier("checkForUpdates")
        case .upgrading: Button("Show Terminal") { updater.showTerminal(desktop) }.accessibilityIdentifier("checkForUpdates")
        case .restarting: Button("Reopening…") {}.disabled(true)
        default:
            Button("Check for Updates") { Task { await updater.check() } }
                .disabled(updater.phase == .checking).accessibilityIdentifier("checkForUpdates")
        }
    }
    private var updateNote: String? {
        switch updater.phase {
        case .checking: "Checking for updates…"
        case .upToDate: "Tsukumo is up to date."
        case .available(let release):
            (updater.installedByHomebrew
                ? "Build \(release.build) is available. Update with Homebrew runs brew in a Tsukumo terminal tab."
                : "Build \(release.build) is available. This copy didn't come from Homebrew, so Download opens the disk image.")
                + (release.notes.map { " " + $0 } ?? "")
        case .upgrading(let release): "Homebrew is installing build \(release.build). Tsukumo reopens when it's done."
        case .restarting: "Reopening Tsukumo…"
        case .failed(let message): message
        case .idle: nil
        }
    }
    private var privacy: some View {
        SettingsContent {
            SettingsCard(title: "Private context") {
                SettingsRow(title: "Saved memories", detail: "Available only to the Apple local model.") { Button("Review…") { desktop.settingsPage = "Personalization" } }
                Divider()
                SettingsRow(title: "API conversations", detail: "Each model connection has separate conversation history.") { Button("Connections…") { desktop.settingsPage = "Models" } }
                Divider()
                SettingsRow(title: "Project files", detail: "Opening a folder does not give a model access to it.") { Text("Read-only").foregroundStyle(.secondary) }
            }
            SettingsCard(title: "Actions") {
                SettingsRow(title: "Calendar and Reminders", detail: "Changes need an exact review or a standing grant for a selected KemoSabe-managed destination.") { Button("Review…") { desktop.settingsPage = nil; desktop.page = "Day" } }
                Divider()
                SettingsRow(title: "Connected apps", detail: "Review native access on this Mac.") { Button("Manage…") { desktop.settingsPage = "Connections" } }
            }
            Text("Private question-and-answer exchange with coding agents is still in development. No coding agent can currently query your saved memories.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}

/// Companion → Voice on the Mac, in the iPhone's order: <companion>'s voice (the one voice choice, and
/// pace), Listening, Conversation, and Voice models (always the best this Mac can run). A sheet from
/// the Companion page, since the Mac's settings pages aren't in a navigation stack.
struct MacVoiceSettings: View {
    /// The sheet's size; pictures of the whole page pass nil.
    var size: CGSize? = CGSize(width: 600, height: 720)
    @Environment(\.dismiss) private var dismiss
    @State private var readAloud = MacReadAloud.shared
    var body: some View {
        NavigationStack {
            Form {
                CompanionVoiceSection().modelsRow()
                Section("Listening") {
                    LabeledContent("Microphone") { Text("Beside your message").foregroundStyle(.secondary) }
                    LabeledContent("Microphone access") {
                        Button("Open System Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") { NSWorkspace.shared.open(url) }
                        }.accessibilityIdentifier("microphoneSystemSettings")
                    }
                }.modelsRow()
                Section("Conversation") {
                    Toggle(isOn: Binding(get: { readAloud.enabled }, set: { readAloud.setEnabled($0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Read \(CompanionIdentity.name)'s replies aloud")
                            Text("Hover over a reply and click the speaker to hear just that one.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("macReadAloud")
                }.modelsRow()
                VoiceModelsSection().modelsRow()
                OpenAIVoiceSection().modelsRow()
            }
            .modelsForm()
            .navigationTitle("Voice")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("closeVoiceSettings") } }
        }
        .frame(width: size?.width, height: size?.height)
    }
}
