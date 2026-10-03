import SwiftUI

/// iPhone's companion lives inside the app. iOS does not permit a general
/// draggable overlay over other apps; that interaction belongs to the Mac shell.
struct AssistantShell: View {
    @Environment(AppStore.self) private var store
    @Environment(VoiceController.self) private var voice
    @Environment(AppNavigation.self) private var navigation
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.mobilePalette) private var palette
    @Environment(OnboardingFlow.self) private var onboarding
    @State private var tab = "Chat"
    @State private var draft = ""
    @State private var attachmentRequest = 0
    @State private var images: [ChatImage] = []
    /// The person keeps the big Kemo on the chat (the corner Kemo hides it or brings it back).
    @State private var expanded = true
    /// Where Kemo is: up on the stage while the chat has room, otherwise in the latest reply's avatar (`ChatStage`).
    @State private var stageShown = true
    @State private var stageMetrics = ChatStage.Metrics()
    /// A performance just asked for (or the corner tapped) plays on the stage until the person scrolls or sends.
    @State private var stagePinned = false
    /// The person scrolled the conversation by hand and isn't back at its latest message (`ChatStage`).
    @State private var browsing = false
    @State private var pageHeight: CGFloat = 0
    @Namespace private var kemoSpace
    @State private var showingConversations = false
    /// A saved conversation the draft seems to belong with, and ones the person waved off.
    @State private var suggestion: ConversationArchive?
    @State private var dismissedSuggestions: Set<UUID> = []
    /// Kept across continuing another conversation, which otherwise clears the draft.
    @State private var carriedDraft: String?
    /// The draft is voice's live transcript, not typing.
    @State private var voiceDraft = false
    /// Voice mode while you talk with Kemo (`VoiceModeKemo`), played by the Kemo on the chat.
    @State private var voiceMode = VoiceModeState()
    @State private var anywhere = VoiceAnywhere.shared
    #if DEBUG
    @State private var simulation = VoiceModeSimulation.shared
    #endif
    @AppStorage("kemo.navigation.showNames") private var showNames = false
    @State private var profiles = ProfileStore.shared
    @AppStorage(CompanionIdentity.key, store: AccountDirectory.accountSettings) private var companionName = CompanionIdentity.defaultName
    @AppStorage(CompanionIntro.stepKey, store: AccountDirectory.accountSettings) private var introStep = ""
    var performance: String
    var send: (String) -> Void
    var newConversation: () -> Void
    var cancelResponse: () -> Void
    var body: some View {
        withVoiceMode(VStack(spacing: 0) {
            header
            TabView(selection: $tab) {
                // Home and Library on the left, Chat in the middle, Day beside your profile picture.
                Tab(value: "Home") {
                    HomeExploreView(prepare: { prompt in tab = "Chat"; draft = prompt },
                                    resume: { archive in store.resumeArchivedConversation(archive.id); tab = "Chat" },
                                    openDay: { tab = "Day" }, openProfile: { tab = "Profile" })
                } label: { tabLabel("Home", symbol: "house") }
                Tab(value: "Library") { WorkspaceView(embedded: true) } label: { tabLabel("Library", symbol: "books.vertical") }
                Tab(value: "Chat") { chatPage.background(palette.background) } label: { tabLabel("Chat", symbol: "bubble.left.and.bubble.right") }
                Tab(value: "Day") { RoutineView(embedded: true) } label: { tabLabel("Day", symbol: "calendar") }
                Tab(value: "Profile") { ProfilePage() } label: { profileTabLabel }
            }.tint(palette.accent).tabBarMinimizeBehavior(.never).animation(nil, value: showNames)
        }
        .background(palette.background.ignoresSafeArea()))
        .sheet(isPresented: $showingConversations) { conversationDrawer }
        .onChange(of: store.conversationRevision) { draft = carriedDraft ?? ""; carriedDraft = nil; images = []; suggestion = nil }
        .task(id: draft) {
            // Pause while typing; suggestions are computed on the device and never move anything.
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            let saved = (store.state.conversationArchives ?? []).filter { store.canResume($0) && !dismissedSuggestions.contains($0.id) }
            let found = ConversationSuggestions.suggestion(for: draft, current: store.conversationMessages, saved: saved)
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { suggestion = found }
        }
        // What you say appears in the message box as you speak; it clears once Kemo takes it.
        .onChange(of: voice.caption) {
            guard voice.captionRole == "You", !voice.caption.isEmpty, draft.isEmpty || voiceDraft else { return }
            draft = voice.caption; voiceDraft = true
        }
        .onChange(of: store.isThinking) { if store.isThinking, voiceDraft { draft = ""; voiceDraft = false } }
        .onChange(of: navigation.performanceRevision) { tab = "Chat"; expanded = true; stagePinned = true; showingConversations = false; updateStage() }
        .onChange(of: voiceMode.visible) { updateStage() }
        .onChange(of: store.conversationRevision) { stagePinned = false; updateStage() }
        .onChange(of: store.conversationMessages.isEmpty) { updateStage() }
        // A notification tap names the tab to show (its conversation, or Day).
        .onChange(of: navigation.requestedTab, initial: true) {
            guard let requested = navigation.requestedTab else { return }
            tab = requested; showingConversations = false; navigation.requestedTab = nil
        }
        .onChange(of: tab) {
            if tab != "Chat" { navigation.voiceBlocks.insert("libraryTab"); showingConversations = false }
            else { navigation.voiceBlocks.remove("libraryTab") }
        }
        .onChange(of: showingConversations) {
            // Browsing conversations pauses voice like any other non-chat surface.
            if showingConversations { navigation.voiceBlocks.insert("conversationSidebar") }
            else { navigation.voiceBlocks.remove("conversationSidebar") }
        }
        .onChange(of: store.state.theme.id) { AccountStore.shared.companionChanged() }
        // In-app notices never show for what's on screen, and wear Kemo's palette.
        .onChange(of: visibleScreen, initial: true) { InAppNoticeCenter.shared.screen = visibleScreen }
        .onChange(of: store.state.theme, initial: true) { InAppNoticeCenter.shared.companion = store.state.theme }
        .onChange(of: onboarding.current) { startOnboardingIntro() }
        .onChange(of: introStep) {
            // The intro finished: after a moment to read its last line, onboarding moves on to permissions.
            guard introStep.isEmpty, onboarding.phoneStep == .companion else { return }
            Task {
                try? await Task.sleep(for: .seconds(1.4))
                if onboarding.phoneStep == .companion, CompanionIntro.step == nil { onboarding.advance() }
            }
        }
        // Onboarding lands in Chat.
        .onChange(of: onboarding.finishedRevision) { tab = "Chat" }
        .onAppear {
            AccountStore.shared.currentPaletteID = { [store] in store.state.theme.id }
            AccountStore.shared.applyPalette = { [store] id in
                guard let theme = (BotTheme.presets + (store.state.customThemes ?? [])).first(where: { $0.id == id }) else { return }
                store.state.theme = theme; store.save()
            }
            AccountStore.shared.sync()
            profiles.record()
            // Sign in with Apple is checked each launch; a revoked sign-in signs this iPhone out.
            if AppleAccountSession.availableInBuild { Task { await AppleAccountSession.shared.verify() } }
            if anywhere.takeInAppRequest() { openVoice() }
            // The companion starts the first chat by asking for its name. On a new install, onboarding
            // hands off to it after the welcome and sign-in (`startOnboardingIntro`).
            if !onboarding.active && CompanionIdentity.needsNaming && Self.asksForName && CompanionIntro.step == nil { tab = "Chat"; store.beginCompanionIntro() }
            startOnboardingIntro()
            #if DEBUG
            // Screenshots: launch with --tab=Home (or another tab name).
            if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--tab=") }) { tab = String(argument.dropFirst(6)) }
            // UI tests and screenshots: --sample-conversation=<n> opens with n exchanges already in the chat.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), store.conversationMessages.isEmpty,
               let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--sample-conversation=") }),
               let count = Int(argument.dropFirst("--sample-conversation=".count)), count > 0 {
                for index in 1...count {
                    store.appendVisibleMessage(role: "You", text: "Sample question \(index): what should I focus on next?")
                    store.appendVisibleMessage(role: "KemoSabe", text: "Sample answer \(index). Start with the smallest step you can finish today, then build on it.")
                }
            }
            // The hand-off demo (`--agent-handoff-fixture`): the task types in and plays with a fake Claude.
            if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ChatHandoffFixture.requested, !ChatHandoffFixture.started {
                ChatHandoffFixture.started = true
                tab = "Chat"
                ChatHandoffFixture.seed(store)
                ChatHandoffFixture.type(into: { draft = $0 }) { ChatHandoffFixture.play(store: store) }
            }
            #endif
        }
    }
    /// Onboarding's companion step is the intro chat itself: it starts here, in Chat. A companion
    /// already named (an account signed in during onboarding that has one) goes straight on.
    private func startOnboardingIntro() {
        guard onboarding.phoneStep == .companion else { return }
        tab = "Chat"
        guard CompanionIntro.step == nil else { return }
        if CompanionIdentity.needsNaming { store.beginCompanionIntro() } else { onboarding.advance() }
    }
    /// Voice mode follows the voice session; the Kemo on the chat plays it and nothing floats over
    /// the conversation. Talk to Kemo and the Live Activity open the chat.
    private func withVoiceMode(_ content: some View) -> some View {
        let layered = content
            .background { VoiceModeFeeder(state: voiceMode, simulated: simulatedInput) }
            // Talk to Kemo asked for the app (it was open, or a permission or unlock was needed).
            .onChange(of: anywhere.inAppRequests) { if anywhere.takeInAppRequest() { openVoice() } }
            // Tapping Kemo's Live Activity opens the conversation.
            .onOpenURL { url in
                guard url.scheme == "kemosabe", url.host() == "chat" || url.host() == "talk" else { return }
                tab = "Chat"; navigation.home(); showingConversations = false
                if url.host() == "talk" { openVoice() }
            }
        #if DEBUG
        // The simulated words fill the message box like real dictation, and clear once Kemo takes them.
        return layered
            .onAppear { simulation?.start() }
            .onChange(of: simulation?.input.heard) {
                guard let heard = simulation?.input.heard, !heard.isEmpty else { return }
                draft = heard; voiceDraft = true
            }
            .onChange(of: simulation?.input.phase) {
                guard simulation?.input.phase == .thinking, voiceDraft else { return }
                // As in a spoken turn, the words go to Kemo; with a reply fixture they're really sent.
                let heard = draft; draft = ""; voiceDraft = false
                if UITestReplyFixture.fromLaunchArguments != nil { send(heard) }
            }
        #else
        return layered
        #endif
    }
    /// Projects and chats come up as a drawer from the composer's conversations button.
    private var conversationDrawer: some View {
        ConversationSidebar(close: { showingConversations = false }, resumed: { showingConversations = false }, deleteCurrent: {
            cancelResponse(); store.deleteCurrentConversation(); draft = ""; images = []
        }, newConversation: { project in
            newConversation()
            if let project { store.moveCurrentConversation(to: project) }
        })
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(palette.background)
    }
    private var chatPage: some View {
        VStack(spacing: 0) {
                // One Kemo on the chat, above the conversation and never over it: the big Kemo acting
                // out the task, or playing voice mode in the same place (or in a band that pushes the
                // chat down while the big Kemo is hidden).
                // While the chat has room, the big Kemo is up here acting out what it's doing; when the
                // conversation fills the view, it shrinks into the latest reply's avatar (`ChatStage`).
                switch signals.stage {
                case .performance:
                    ArtworkCompanion(theme: store.state.theme, performance: stagePerformance,
                        reducedMotion: reduceMotion, active: scenePhase == .active && navigation.panel == nil,
                        replay: navigation.performanceRevision)
                        .frame(height: stageHeight)
                        .accessibilityIdentifier("homeCompanion")
                        .accessibilityLabel(CompanionIdentity.name + ", " + stagePerformance)
                        // The stage's Kemo moves to and from the home avatar as one character.
                        .modifier(StageKemo(namespace: reduceMotion ? nil : kemoSpace))
                case .voice:
                    VoiceModeKemo(theme: store.state.theme, state: voiceMode)
                        .allowsHitTesting(false)
                        .frame(height: signals.voiceBand ? VoiceModeKemo.bandHeight : stageHeight)
                        .transition(signals.voiceBand && !reduceMotion ? .scale(scale: 0.6, anchor: .top).combined(with: .opacity) : .opacity)
                case .none:
                    EmptyView()
                }
                // Room under the header when no Kemo is there.
                ChatTranscript { draft = $0; submit() }.safeAreaPadding(.top, signals.stage == .none ? 16 : 0)
                    .environment(\.chatStage, ChatStageContext(namespace: kemoSpace, kemoInAvatar: signals.stage == .none || signals.voiceBand,
                        anchorsTop: ChatStage.anchorsTop(stageMetrics, stageHeight: stageHeight, shown: stageShown && expanded, browsing: browsing),
                        reduceMotion: reduceMotion, report: { updateStage($0) }, scrolled: {
                            browsing = true
                            guard stagePinned else { return }
                            stagePinned = false; updateStage()
                        }))
                VStack(spacing: 8) {
                    // Voice fills the message box itself; only a problem gets a line above it.
                    if voice.phase == .unavailable {
                        Text(voice.status).font(KemoType.font(.caption2)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("voiceStatus")
                    }
                    if store.modelRoute == .api, let profile = store.activeAPIProfile {
                        Text("Messages sent to " + (profile.endpoint.host ?? "your model")).font(KemoType.font(.caption2)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if store.modelRoute == .onDevice, store.appleModel == .privateCloud {
                        Text(PrivateCloudText.destination).font(KemoType.font(.caption2)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("composerDestination")
                    }
                    if let step = CompanionIntro.Step(rawValue: introStep) {
                        IntroChoices(choices: CompanionIntro.choices(for: step), accent: palette.accent) { store.answerCompanionIntro($0) }
                    }
                    if let suggestion, !store.isThinking {
                        ConversationSuggestion(title: suggestion.title, accent: palette.accent) {
                            carriedDraft = draft
                            store.resumeArchivedConversation(suggestion.id)
                            if store.storageError != nil { carriedDraft = nil }
                        } dismiss: {
                            dismissedSuggestions.insert(suggestion.id); self.suggestion = nil
                        }
                    }
                    ChatComposerPanel(text: $draft, images: $images, surface: palette.surface, accent: palette.accent, listening: signals.composerListening, attachmentRequest: attachmentRequest,
                        microphoneOn: microphoneOn, microphoneBusy: voice.permissionsBusy,
                        microphoneUnavailable: voice.phase == .unavailable,
                        send: submit, cancel: cancelResponse, attach: { attachmentRequest += 1 },
                        newConversation: newConversation,
                        openConversations: { showingConversations = true },
                        toggleMicrophone: toggleMicrophone, focusChanged: { editing in
                            if editing { navigation.voiceBlocks.insert("chatEditor") }
                            else { navigation.voiceBlocks.remove("chatEditor") }
                        })
                }.padding(.horizontal, Self.composerInset).padding(.bottom, 10)
        }
        // Voice mode comes and goes with a spring; with Reduce Motion it fades.
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.78), value: signals.stage)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { pageHeight = $0 }
    }
    /// The stage's height: about a quarter of the screen.
    private var stageHeight: CGFloat { bigKemoHeight(pageHeight) }
    /// What the stage acts out: a greeting to open a new chat, then idle, or the task under way.
    private var stagePerformance: String {
        ChatStage.performance(live: livePerformance, conversationEmpty: store.conversationMessages.isEmpty)
    }
    /// Kemo hops between the stage and the latest reply's avatar as the room comes and goes.
    private func updateStage(_ metrics: ChatStage.Metrics? = nil) {
        // The first measurement places Kemo without a hop (a long conversation opens with Kemo in its avatar).
        let measured = stageMetrics.viewportHeight > 0
        if let metrics { stageMetrics = metrics; if ChatStage.atBottom(metrics) { browsing = false } }
        let next = ChatStage.stageShown(stageMetrics, stageHeight: stageHeight, shown: stageShown && expanded,
                                        allowed: expanded, voiceMode: voiceMode.visible, pinned: stagePinned,
                                        empty: store.conversationMessages.isEmpty, browsing: browsing)
        guard next != stageShown else { return }
        if !measured { stageShown = next; return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.74)) { stageShown = next }
    }
    /// The big Kemo is on the chat now.
    private var bigKemoOnChat: Bool { expanded && stageShown }
    /// About a quarter of the screen: smaller on an SE, larger on a Pro Max, and smaller again at
    /// the accessibility text sizes so the heading and the conversation keep their room.
    private func bigKemoHeight(_ container: CGFloat) -> CGFloat {
        dynamicTypeSize.isAccessibilitySize ? min(220, max(140, container * 0.2)) : min(300, max(190, container * 0.27))
    }
    /// What each state shows, once (`ChatSignals`).
    private var signals: ChatSignals {
        ChatSignals(onChat: tab == "Chat" && navigation.panel == nil, bigKemo: bigKemoOnChat, voiceMode: voiceMode.visible,
                    listening: voicePhase == .listening, working: store.isThinking)
    }
    /// The voice session's phase, or the UI tests' simulated one.
    private var voicePhase: VoicePhase { simulatedInput?.phase ?? voice.phase }
    private var microphoneOn: Bool { simulatedInput.map { $0.phase != .off } ?? (store.state.voiceEnabled == true) }
    /// What Kemo acts out: the current request's activity while it works, otherwise
    /// the last performance asked for.
    private var livePerformance: String {
        TaskActivity.live(performance, store: store)
    }
    /// Your profile picture, like Instagram; the person symbol until you choose a photo.
    private var profileTabLabel: some View {
        Label {
            Text(showNames ? "Profile" : "")
        } icon: {
            if let avatar = profiles.tabAvatar() { Image(uiImage: avatar) } else { Image(systemName: "person.crop.circle") }
        }.accessibilityLabel("Profile").accessibilityIdentifier("tab-Profile")
    }
    private func tabLabel(_ name: String, symbol: String) -> some View {
        Label(showNames ? name : "", systemImage: symbol).accessibilityLabel(name).accessibilityIdentifier("tab-" + name)
    }
    /// The first conversation, where the companion asks its name; UI tests opt in with --first-run.
    private static var asksForName: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return !arguments.contains("--ui-testing") || arguments.contains("--first-run")
    }
    /// Matches the floating tab bar's side inset so the composer and tab bar share edges.
    static let composerInset: CGFloat = 20
    private var header: some View {
        HStack(spacing: 8) {
            Button {
                // Hides the big Kemo, or brings it up to the stage (where it stays until you scroll).
                let show = !(bigKemoOnChat && tab == "Chat")
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.18)) { expanded = show; stagePinned = show; tab = "Chat" }
                updateStage()
            } label: {
                // The corner shows who and what state; the live performance plays only on the main screen.
                ArtworkCompanion(theme: store.state.theme, performance: "idle", reducedMotion: true, active: false)
                    .frame(width: 48, height: 48).scaleEffect(1.18)
                    .background(.white.opacity(0.06), in: Circle()).clipShape(Circle())
            }.buttonStyle(.plain).accessibilityLabel(bigKemoOnChat ? "Minimize companion" : "Expand companion")
                .accessibilityIdentifier(bigKemoOnChat ? "compactCompanion" : "homeCompanion")
            VStack(alignment: .leading, spacing: 2) {
                if companionName == CompanionIdentity.defaultName {
                    BrandWordmark().scaleEffect(0.76, anchor: .leading).frame(width: 124, height: 18, alignment: .leading)
                } else {
                    // A chosen name replaces the wordmark; the artwork itself is never retyped.
                    Text(companionName).font(.system(size: 19, weight: .heavy, design: .rounded)).lineLimit(1)
                        .foregroundStyle(store.state.theme.bodyColor).accessibilityIdentifier("headerName")
                }
                if let state = headerState {
                    HStack(spacing: 5) {
                        KemoOrb(size: 12, secondary: store.state.theme.bodyColor, state: KemoOrb.state(for: lastRequest)).tint(palette.accent)
                        Text(state).font(KemoType.font(.caption)).foregroundStyle(.secondary).lineLimit(1)
                    }.transition(.opacity).accessibilityElement(children: .combine).accessibilityIdentifier("headerState")
                }
            }.animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: headerState)
            Spacer(minLength: 4)
            // Settings matches Kemo's circle on the other side; your photo lives on the Profile tab.
            Button { navigation.open(.settings) } label: {
                Image(systemName: "gearshape").font(.system(size: 19, weight: .medium))
                    .frame(width: 48, height: 48)
                    .background(.white.opacity(0.06), in: Circle())
            }
                .buttonStyle(.plain).accessibilityLabel("Settings").accessibilityIdentifier("settingsGear")
        }.padding(.leading, 18).padding(.trailing, 18).padding(.vertical, 8).foregroundStyle(palette.foreground)
            .overlay(alignment: .bottom) { Divider().opacity(0.5) }
    }
    /// What's on screen now, for in-app notices (`VisibleScreen`).
    private var visibleScreen: VisibleScreen {
        let mac = NotificationRoutes.shared.macNotice
        return VisibleScreen(tab: tab, conversation: store.state.openConversations?[store.currentConversationSlot]?.id,
                             covered: navigation.panel != nil || showingConversations || mac != nil, macTask: mac?.task,
                             blocked: onboarding.coversPhone || AppleAccountSession.shared.needsSignIn)
    }
    private var lastRequest: String { store.conversationMessages.last { $0.role == "You" }?.text ?? "" }
    /// The UI tests' simulated conversation, in place of the voice session.
    private var simulatedInput: VoiceModeInput? {
        #if DEBUG
        return simulation?.input
        #else
        return nil
        #endif
    }
    /// Opens the chat with the microphone on, asking for permission first if it's needed.
    private func openVoice() {
        tab = "Chat"; navigation.home(); showingConversations = false
        if store.state.voiceEnabled != true || voice.phase == .unavailable {
            Task { await voice.requestPermissions(store: store) }
        }
    }
    /// What Kemo is working on, under its name in the corner: only on another tab, where nothing
    /// else says so. On Chat the transcript's row and the composer do, and it never says Listening.
    private var headerState: String? {
        signals.headerStatus ? TaskActivity.label(for: lastRequest) : nil
    }
    private func submit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !images.isEmpty {
            voice.deactivate()
            let attached = store.takeComposerAttachments()
            if store.sendImages(text, images: images, attachments: attached) { draft = ""; images = [] } else { store.composerAttachments = attached }
            return
        }
        guard !text.isEmpty, !store.isThinking else { return }
        // Intro answers are read on the device, so they work before a model is ready.
        if CompanionIntro.step != nil { draft = ""; send(text); return }
        guard text.count <= 2000 else { store.error = "Keep this message under 2,000 characters."; return }
        // A chat with an agent runs on your paired Mac: when it can't be reached, say so and keep the message.
        if store.state.chatAgent != nil, ChatAgentRouting.kemoMessage(text) == nil {
            #if DEBUG
            let demo = ChatHandoffFixture.requested
            #else
            let demo = false
            #endif
            if !demo, !MacRelayPhone.shared.isConnected { store.error = MacRelayPhone.shared.unreachable(store); return }
            stagePinned = false
            draft = ""; send(text); return
        }
        guard VoiceCommand.parse(text) != nil || store.canChat else { store.error = store.availability; return }
        // Sending ends a pinned performance; a command that asks for one pins it again.
        stagePinned = false
        draft = ""; send(text)
    }
    private func toggleMicrophone() {
        if voice.phase == .unavailable || store.state.voiceEnabled != true {
            Task { await voice.requestPermissions(store: store) }
        } else { store.state.voiceEnabled = false; store.save(); voice.deactivate() }
    }
}

/// Answers for the first conversation's current question, one tap each.
private struct IntroChoices: View {
    let choices: [String]
    let accent: Color
    let choose: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(choices, id: \.self) { choice in
                    Button(choice) { choose(choice) }
                        .font(KemoType.font(.footnote, weight: .medium))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(accent.opacity(0.14), in: Capsule())
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("introChoice-" + choice)
                }
            }
        }.scrollClipDisabled().transition(.opacity)
    }
}

/// “Continue in …”: one tap moves the draft into the saved conversation it seems
/// to belong with. Nothing is sent until the person sends it there.
private struct ConversationSuggestion: View {
    let title: String
    let accent: Color
    let accept: () -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 8) {
            Button(action: accept) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.uturn.forward").foregroundStyle(accent)
                    Text("Continue in “\(title)”").lineLimit(1)
                }.font(KemoType.font(.footnote, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityIdentifier("conversationSuggestion")
                .accessibilityHint("Continues that earlier conversation with your message")
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).frame(width: 28, height: 28) }
                .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Keep it here").accessibilityIdentifier("dismissConversationSuggestion")
        }
        .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
        .background(Color.primary.opacity(0.06), in: Capsule())
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
