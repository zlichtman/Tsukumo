import AuthenticationServices
import SwiftUI

struct VoiceCompanionView: View {
    var covered = false
    var performance = "idle"
    var replay = 0
    var openSettings: () -> Void
    @Environment(AppStore.self) private var store
    @Environment(VoiceController.self) private var voice
    @Environment(\.accessibilityReduceMotion) private var reducedMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PageBackground()
                VStack(spacing: 0) {
                    HStack {
                        BrandWordmark()
                        Spacer()
                        Button {
                            if voice.phase == .unavailable || store.state.voiceEnabled != true {
                                Task { await voice.requestPermissions(store: store) }
                            } else {
                                store.state.voiceEnabled = false; store.save(); voice.deactivate()
                            }
                        } label: {
                            Group {
                                if voice.permissionsBusy || voice.phase == .starting {
                                    KemoOrb(size: 30, secondary: store.state.theme.accentColor, state: .listening).tint(store.state.theme.bodyColor)
                                } else {
                                    Image(systemName: microphoneIcon).font(.system(size: 19, weight: .medium))
                                }
                            }
                            .foregroundStyle(store.state.theme.bodyColor.opacity(0.85))
                            .frame(width: 46, height: 46)
                            .background(.white.opacity(0.045), in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.07)))
                        }.buttonStyle(.plain).disabled(voice.permissionsBusy)
                            .accessibilityLabel(microphoneLabel)
                            .accessibilityValue(microphoneValue)
                            .accessibilityIdentifier("microphoneToggle")
                        Button(action: openSettings) {
                            Image(systemName: "gearshape").font(.system(size: 19, weight: .medium))
                                .foregroundStyle(store.state.theme.bodyColor.opacity(0.85))
                                .frame(width: 46, height: 46)
                                .background(.white.opacity(0.045), in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.07)))
                        }.buttonStyle(.plain).accessibilityLabel("Settings").accessibilityIdentifier("settingsGear")
                    }.padding(.horizontal, 26).padding(.top, 12)
                    Spacer(minLength: 12)
                    ArtworkCompanion(theme: store.state.theme, performance: performance, thinking: performance == "idle" && voice.phase == .thinking, speaking: performance == "idle" && voice.phase == .speaking, listening: performance == "idle" && voice.phase == .listening, reducedMotion: reducedMotion, active: visible && !covered && scenePhase == .active, attention: voice.attention, audioLevel: voice.audioLevel, replay: replay)
                        .frame(height: min(geometry.size.width * 1.05, geometry.size.height * 0.63))
                        .accessibilityLabel("KemoSabe, \(performance == "idle" ? voice.phase.rawValue : performance)")
                        .accessibilityIdentifier("homeCompanion")
                    Spacer(minLength: 12)
                    VStack(spacing: 12) {
                        HStack(spacing: 8) {
                            Circle().fill(voice.phase == .listening ? Color.green.opacity(0.8) : store.state.theme.bodyColor.opacity(0.5)).frame(width: 6, height: 6)
                            Text(voice.status).font(KemoType.font(.callout)).foregroundStyle(store.state.theme.bodyColor).multilineTextAlignment(.center)
                        }.padding(.horizontal, 18).padding(.vertical, 12)
                            .background(.white.opacity(0.035), in: Capsule())
                            .accessibilityIdentifier("voiceStatus")
                        if voice.phase == .listening {
                            HStack(spacing: 4) {
                                ForEach(0..<9) { i in Capsule().fill(store.state.theme.bodyColor.opacity(0.7)).frame(width: 3, height: 4 + CGFloat(voice.audioLevel) * CGFloat(24 - abs(i-4)*4)) }
                            }.frame(height: 28).animation(reducedMotion ? nil : .easeOut(duration: 0.12), value: voice.audioLevel).accessibilityLabel("Microphone input level")
                        }
                        if (voice.phase == .listening || store.state.captionsEnabled != false) && !voice.caption.isEmpty {
                            VStack(spacing: 6) {
                                Text(voice.captionRole).font(KemoType.font(.caption2, weight: .semibold)).foregroundStyle(.white.opacity(0.4))
                                Text(captionText).font(KemoType.font(.callout)).multilineTextAlignment(.center).lineLimit(5).accessibilityIdentifier("voiceCaption")
                            }
                        }
                        if voice.phase == .speaking && voice.canInterrupt {
                            Text("Say “KemoSabe” to interrupt").font(KemoType.font(.caption2)).foregroundStyle(.white.opacity(0.4))
                        }
                    }.padding(.horizontal, 30).padding(.bottom, 36)
                }.frame(maxWidth: 650).frame(maxWidth: .infinity)
            }
        }.onAppear { visible = true }.onDisappear { visible = false }
    }
    private var microphoneIcon: String {
        if voice.phase == .unavailable { return "arrow.clockwise" }
        return store.state.voiceEnabled == true ? "mic.fill" : "mic.slash"
    }
    private var microphoneLabel: String {
        if voice.phase == .unavailable { return "Retry microphone" }
        return store.state.voiceEnabled == true ? "Turn microphone off" : "Turn microphone on"
    }
    private var microphoneValue: String {
        if voice.permissionsBusy { return "Requesting permission" }
        if voice.phase == .starting { return "Starting" }
        if voice.phase == .unavailable { return "Unavailable" }
        return store.state.voiceEnabled == true ? "On" : "Off"
    }
    private var captionText: AttributedString {
        let text = NSMutableAttributedString(string: voice.caption, attributes: [.foregroundColor: UIColor.white.withAlphaComponent(0.72)])
        if let range = voice.spokenRange, range.location != NSNotFound, NSMaxRange(range) <= text.length {
            text.addAttribute(.foregroundColor, value: UIColor(store.state.theme.bodyColor), range: range)
        }
        return AttributedString(text)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.mobilePalette) private var palette
    @State private var search = ""
    @State private var account = AccountStore.shared
    @State private var session = AppleAccountSession.shared
    @State private var profiles = ProfileStore.shared
    @State private var showingAccount = false
    var body: some View {
        NavigationStack {
            // The same groups and pages as the Mac, from the shared catalog.
            List {
                // Your account first, as a card with your picture, like the Apple Account row in iOS Settings.
                if search.isEmpty, let page = SettingsCatalog.page("Account") {
                    Section { NavigationLink { destination(page) } label: { accountCard }.accessibilityIdentifier(Self.identifier(page)) }
                }
                ForEach(SettingsCatalog.groups(for: .iPhone, search: search), id: \.name) { group in
                    let pages = group.pages.filter { !search.isEmpty || $0.id != "Account" }
                    if !pages.isEmpty {
                        Section(SettingsCatalog.title(group.name)) {
                            ForEach(pages) { page in entry(page) }
                        }
                    }
                }
            }.scrollContentBackground(.hidden).background(palette.background)
                .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search settings")
                .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(role: .close) { dismiss() }.accessibilityIdentifier("closeSettings") } }
                .navigationDestination(isPresented: $showingAccount) { AccountSettingsPage() }
        }
        // After signing in or out, the app is rebuilt on the new account; come back to Account.
        .onAppear {
            if navigation.reopenAccountPage { navigation.reopenAccountPage = false; showingAccount = true }
        }
    }
    private var accountCard: some View {
        HStack(spacing: 14) {
            Group {
                if let image = profiles.tabAvatar(side: 120) { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
            }.frame(width: 56, height: 56).clipShape(Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(account.displayName.isEmpty ? "Your account" : account.displayName).font(KemoType.font(.title3, weight: .semibold)).foregroundStyle(.primary)
                Text(session.status == .local ? "One account for iPhone, Mac, and Watch" : "Apple Account · " + session.statusTitle)
                    .font(KemoType.font(.footnote)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 0)
            Text(AccountPlan.current).font(KemoType.font(.caption, weight: .semibold)).padding(.horizontal, 8).padding(.vertical, 3)
                .background(palette.accent.opacity(0.18), in: Capsule()).foregroundStyle(palette.accent)
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
    /// Pages that live in the app's panels open there; the rest push onto Settings.
    @ViewBuilder private func entry(_ page: SettingsPage) -> some View {
        switch page.id {
        case "Models": Button { navigation.open(.model) } label: { row(page.title, icon: page.symbol, disclosure: true) }.accessibilityIdentifier("openModel")
        case "Connections": Button { navigation.open(.connections) } label: { row(page.title, icon: page.symbol, disclosure: true) }.accessibilityIdentifier("openConnections")
        case "Nearby": Button { navigation.open(.nearby) } label: { row(page.title, icon: page.symbol, disclosure: true) }.accessibilityIdentifier("openNearby")
        default: NavigationLink { destination(page) } label: { row(page.title, icon: page.symbol) }.accessibilityIdentifier(Self.identifier(page))
        }
    }
    @ViewBuilder private func destination(_ page: SettingsPage) -> some View {
        switch page.id {
        case "Appearance": AppAppearancePage()
        case "Companion": CharacterAppearancePage()
        case "Personalization": PersonalRoutineSettings().environment(\.openConnections) { navigation.open(.connections) }
        case "Privacy": MobilePrivacyPage()
        case "Account": AccountSettingsPage()
        case "Usage": UsageSettingsPage()
        case "Notifications": NotificationSettingsPage()
        case "Shortcuts": ShortcutsPage()
        case "General": GeneralPage()
        default: if let note = page.planned { PlannedSettingsPage(title: page.title, note: note) } else { GeneralPage() }
        }
    }
    /// Identifiers kept from earlier builds so UI tests and automation still find each row.
    static func identifier(_ page: SettingsPage) -> String {
        ["Appearance": "openAppearance", "Companion": "openCharacter", "Privacy": "storageAndAI",
         "Shortcuts": "openShortcuts"][page.id] ?? "open" + page.id.replacingOccurrences(of: " ", with: "")
    }
    private func row(_ title: String, icon: String, disclosure: Bool = false) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).frame(width: 22).foregroundStyle(.secondary)
            Text(title).foregroundStyle(.primary)
            if disclosure { Spacer(); Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary) }
        }.padding(.vertical, 3)
    }
}

/// Your account: Sign in with Apple links your iPhone and Mac to one account and one profile.
private struct AccountSettingsPage: View {
    @Environment(\.mobilePalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @State private var account = AccountStore.shared
    @State private var session = AppleAccountSession.shared
    @State private var accountSync = AccountSyncService.shared
    @State private var profiles = ProfileStore.shared
    @State private var confirmingSignOut = false
    private var signedIn: Bool { [.linked, .needsConfirmation, .finishingSignIn].contains(session.status) }
    /// Kept short on purpose (the owner, September 25, 2026: "this is overcomplicated"): who you
    /// are, one sync switch with its status, and sign out. Details show only when something needs you.
    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Group {
                        if let image = profiles.tabAvatar(side: 120) { Image(uiImage: image).resizable().scaledToFill() }
                        else { Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary) }
                    }.frame(width: 56, height: 56).clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(account.displayName.isEmpty ? "Your account" : account.displayName).font(KemoType.font(.title3, weight: .semibold))
                        if let email = account.account.email { Text(email).font(KemoType.font(.footnote)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                    }
                }.padding(.vertical, 4).accessibilityElement(children: .combine)
                if let note = session.lastSwitchNote {
                    Text(note).font(.footnote).foregroundStyle(.secondary)
                        .onTapGesture { session.dismissLastSwitch() }.accessibilityIdentifier("dismissAccountSwitch")
                }
                if AppleAccountSession.availableInBuild, session.status == .local || session.status == .needsConfirmation {
                    SignInWithAppleButton(.signIn, onRequest: session.prepare, onCompletion: { session.handle($0, account: account) })
                        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                        .frame(height: 44).accessibilityIdentifier("signInWithApple")
                }
                if session.status == .finishingSignIn || session.status == .finishingSignOut {
                    Button("Try again") { session.retrySwitch() }.accessibilityIdentifier("retryAccountSwitch")
                }
                if let notice = session.notice { Text(notice).font(.footnote).foregroundStyle(.orange) }
            }
            if accountSync.canSync {
                Section {
                    Toggle(isOn: Binding(get: { accountSync.enabled }, set: { accountSync.enabled = $0 })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("iCloud Sync")
                            HStack(spacing: 6) {
                                if accountSync.phase == .syncing { KemoOrb(size: 12, state: .connecting) }
                                Text(accountSync.statusTitle).accessibilityIdentifier("syncStatus")
                            }.font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                        }
                    }.accessibilityIdentifier("syncEnabled")
                    if accountSync.phase == .mismatch {
                        Button("Use this iCloud account") { Task { await accountSync.useThisICloudAccount() } }.accessibilityIdentifier("syncRebind")
                    }
                } footer: {
                    if accountSync.phase == .mismatch || accountSync.hasProblem, let detail = accountSync.statusDetail { Text(detail) }
                    else { Text("Private to your iCloud. Your chats, memories, People, and profile on every device.") }
                }
            }
            if signedIn {
                Section {
                    Button(session.status == .finishingSignIn ? "Cancel sign-in" : "Sign out", role: .destructive) {
                        if session.status == .finishingSignIn { session.signOut() } else { confirmingSignOut = true }
                    }.accessibilityIdentifier("appleSignOut")
                }
            }
        }.scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("Account").navigationBarTitleDisplayMode(.inline)
            .refreshable { if accountSync.canSync, accountSync.enabled { await accountSync.syncNow() } }
            .onAppear { session.refresh() }
            .confirmationDialog("Sign out?", isPresented: $confirmingSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { session.signOut() }
            } message: { Text("Nothing is deleted. It comes back when you sign in again.") }
    }
}

/// Messages per model, counted from the conversations on this device.
private struct UsageSettingsPage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        let rows = UsageSummary.rows(archives: store.state.conversationArchives ?? [], current: store.conversationMessages, currentModel: store.modelLabel)
        Form {
            Section("Messages on this iPhone") {
                if rows.isEmpty { Text("No chats yet").foregroundStyle(.secondary) }
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(row.model).font(.body.weight(.semibold)); Spacer(); Text("\(row.sent) sent").foregroundStyle(.secondary).monospacedDigit() }
                        Text("\(row.chats) \(row.chats == 1 ? "chat" : "chats") · \(row.replies) \(row.replies == 1 ? "reply" : "replies")").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Tokens and cost", value: "Complete later")
            } header: { Text("Billing") } footer: {
                Text("Apple's on-device model is free. Connected models are billed by their providers under your own keys; KemoSabe charges nothing.")
            }
        }.scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle("Usage").navigationBarTitleDisplayMode(.inline)
    }
}

/// A page that isn't built yet says what it will do instead of being left out.
private struct PlannedSettingsPage: View {
    let title: String
    let note: String
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        Form {
            Section { LabeledContent("Status", value: "Complete later") } footer: { Text(note) }
        }.scrollContentBackground(.hidden).background(palette.background)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
    }
}

/// General, as on Mac: the version (seven quick taps turn on developer settings) and updates,
/// which reach iPhone through TestFlight.
private struct GeneralPage: View {
    @Environment(\.mobilePalette) private var palette
    @Environment(\.openURL) private var openURL
    @State private var developer = DeveloperMode.shared
    @State private var note: String?
    @Environment(OnboardingFlow.self) private var onboarding
    @Environment(AppNavigation.self) private var navigation
    var body: some View {
        Form {
            Section {
                Button {
                    note = developer.tapVersion()
                    if developer.enabled { UIImpactFeedbackGenerator(style: .rigid).impactOccurred() }
                } label: {
                    LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""))")
                        .foregroundStyle(.primary)
                }.accessibilityIdentifier("versionNumber")
                Button("Check for Updates") { openURL(URL(string: "itms-beta://")!) }.accessibilityIdentifier("checkForUpdates")
            } header: { Text("KemoSabe") } footer: {
                Text(note ?? "New builds arrive through TestFlight.").accessibilityIdentifier("versionNote")
            }
            // For testing: onboarding again from the welcome, on this account. Developer settings only.
            if developer.enabled {
                Section {
                    Button("Show onboarding again") { navigation.home(); onboarding.restart() }
                        .accessibilityIdentifier("replayOnboarding")
                } header: { DeveloperHeader() } footer: {
                    Text("Runs the welcome, sign-in, and permissions again from the start; the companion's intro runs only while it has no name. Nothing is deleted.")
                }
            }
        }.navigationTitle("General").navigationBarTitleDisplayMode(.inline).scrollContentBackground(.hidden).background(palette.background)
    }
}

private struct MobilePrivacyPage: View {
    @Environment(AppStore.self) private var store
    @Environment(\.mobilePalette) private var palette
    @State private var clearHistory = false
    var body: some View {
        Form {
            Section("Private context") {
                Label("Saved on this device", systemImage: "lock.shield")
                Text("Enabled memories are available to the Apple local model. API connections have separate histories. People profiles are excluded from model context.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Conversations") {
                Button("Clear all conversation history", role: .destructive) { clearHistory = true }
                Text("Delete individual conversations in Chat or Library. Saved memories remain separately editable in Library.").font(.footnote).foregroundStyle(.secondary)
            }
            Section("On-device AI") {
                Text(store.availability).font(.footnote).foregroundStyle(.secondary)
                Button("Check availability") { store.refreshAvailability() }
            }
        }.scrollContentBackground(.hidden).background(palette.background).navigationTitle("Privacy").navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Clear all conversation history?", isPresented: $clearHistory, titleVisibility: .visible) {
                Button("Clear history", role: .destructive) { store.clearConversation() }
            } message: { Text("Saved memories, People profiles, and recent context are separate. Provider-retained copies are not removed.") }
    }
}

struct VoiceHistoryView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppStore.self) private var store
    @State private var memory: MemoryNote?
    var body: some View {
        NavigationStack {
            List {
                Text(store.modelLabel).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                if store.conversationMessages.isEmpty { Text("No conversations yet.").foregroundStyle(.secondary) }
                ForEach(store.conversationMessages) { message in
                    VStack(alignment: .leading, spacing: 8) {
                        Eyebrow(text: message.role)
                        Text(message.text).textSelection(.enabled)
                        Button("Keep in memory") { memory = MemoryNote(text: message.text) }.font(KemoType.font(.caption))
                    }.padding(.vertical, 8)
                }
                ConversationArchiveList()
            }.navigationTitle("Conversation history").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(role: .close) { dismiss() } } }
                .sheet(item: $memory) { MemoryEditor(note: $0) }
        }
    }
}
