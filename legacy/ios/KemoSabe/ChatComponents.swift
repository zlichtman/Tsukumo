import SwiftUI

private struct ChatAccentOverrideKey: EnvironmentKey { static let defaultValue: Color? = nil }
extension EnvironmentValues {
    var chatAccentOverride: Color? {
        get { self[ChatAccentOverrideKey.self] }
        set { self[ChatAccentOverrideKey.self] = newValue }
    }
}

struct ChatTranscript: View {
    @AppStorage(CompanionIdentity.key, store: AccountDirectory.accountSettings) private var companionName = CompanionIdentity.defaultName
    #if os(macOS)
    @Environment(DesktopPreferences.self) private var desktopPreferences
    private var contentFont: Font { desktopPreferences.font(content: true) }
    #else
    private var contentFont: Font { KemoType.font(.body) }
    #endif
    @Environment(AppStore.self) private var store
    @Environment(\.chatAccentOverride) private var accentOverride
    private var accent: Color { accentOverride ?? store.state.theme.bodyColor }
    var suggestion: (String) -> Void
    @State private var atBottom = true
    @State private var visibleMessages = Set<UUID>()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.chatStage) private var stage
    /// Agents this device can chat with: a new chat offers "Chat with Claude", "Chat with Codex".
    @Environment(\.chatAgents) private var agents
    /// The latest reply, whose avatar is where Kemo is while the stage is hidden (the thinking row is, while Kemo works).
    private var homeReply: UUID? {
        store.isThinking || store.localLookup != nil ? nil
            : store.conversationMessages.last { $0.role != "You" && ($0.handoff == nil || [.question, .answer].contains($0.handoff?.part)) }?.id
    }
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 26) {
                    if store.conversationMessages.isEmpty, let kemo = stage.emptyKemo {
                        // On Mac a new chat looks like a new Tsukumo task: Kemo in the greeting, in the same place.
                        NewChatLayout(title: "What’s on your mind?", subtitle: "Make room for your day.", subtitleFont: contentFont,
                                      topInset: stage.emptyTopInset) { kemo } suggestions: {
                            suggestionButton("Plan my day", icon: "sun.max", message: "Help me plan my day. Ask what you need to know first.")
                            suggestionButton("Think something through", icon: "sparkle", message: "Help me think through a decision. Start with one useful question.")
                            suggestionButton("Show me your animation", icon: "figure.dance", message: "Do your animation")
                            // The first two agents ready now; the model chip lists them all.
                            ForEach(Array(agents.filter { $0.available && $0.signIn == nil && store.state.chatAgent != $0.id }.prefix(2))) { agent in
                                agentSuggestion(agent)
                            }
                        }
                    } else if store.conversationMessages.isEmpty {
                        // On Mac the greeting shares one center line with the big Kemo and the composer.
                        VStack(alignment: Self.emptyAlignment, spacing: 12) {
                            Text("What’s on your mind?").font(KemoType.font(.largeTitle, weight: .semibold))
                            Text("Make room for your day.").font(contentFont).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 10) {
                                suggestionButton("Plan my day", icon: "sun.max", message: "Help me plan my day. Ask what you need to know first.")
                                suggestionButton("Think something through", icon: "sparkle", message: "Help me think through a decision. Start with one useful question.")
                                suggestionButton("Show me your animation", icon: "figure.dance", message: "Do your animation")
                            }.padding(.top, 18)
                        }.multilineTextAlignment(Self.emptyAlignment == .center ? .center : .leading)
                            .padding(.top, 38).padding(.bottom, 20).frame(maxWidth: .infinity, alignment: Self.emptyAlignment == .center ? .center : .leading)
                    }
                    ForEach(store.conversationMessages) { message in
                        ChatMessageRow(message: message, home: message.id == homeReply).id(message.id)
                            .onScrollVisibilityChange(threshold: 0.3) { visible in
                                if visible { visibleMessages.insert(message.id) } else { visibleMessages.remove(message.id) }
                            }
                    }
                    if store.isThinking {
                        // The thinking row is Kemo's avatar with its small orb: the one signal while it works.
                        let request = store.conversationMessages.last { $0.role == "You" }?.text ?? ""
                        HStack(alignment: .top, spacing: ChatMessageRow.avatarGap) {
                            KemoAvatarSlot(theme: store.state.theme, home: true, orb: KemoOrb.state(for: request), accent: accent, size: ChatMessageRow.avatarSize)
                            VStack(alignment: .leading, spacing: 4) {
                                ChatMessageRow.nameLabel(companionName)
                                if store.streamingReply.isEmpty {
                                    Text(TaskActivity.label(for: request)).font(contentFont).foregroundStyle(.secondary)
                                } else { Text(store.streamingReply).font(contentFont).textSelection(.enabled).lineSpacing(4) }
                            }
                        }.accessibilityElement(children: .contain).accessibilityIdentifier("streamingReply")
                    } else if let agent = store.handoffWorking, store.localLookup == nil, store.agentQuestions.consent?.inChat != true {
                        // The agent working on your message, its reply streaming in. While Kemo reads for
                        // it (or asks you first), Kemo's card is what's live instead.
                        HStack(alignment: .top, spacing: ChatMessageRow.avatarGap) {
                            HandoffAgentAvatar(agent: agent, size: ChatMessageRow.avatarSize)
                            VStack(alignment: .leading, spacing: 4) {
                                ChatMessageRow.nameLabel(agent)
                                if store.handoffStreaming.isEmpty { Text("Working…").font(contentFont).foregroundStyle(.secondary) }
                                else { Text(store.handoffStreaming).font(contentFont).textSelection(.enabled).lineSpacing(4) }
                            }
                        }.accessibilityElement(children: .combine).accessibilityIdentifier("handoffWorking")
                    }
                    if let notice = store.notice {
                        Label(notice, systemImage: "info.circle").font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("modelNotice")
                    }
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.circle").font(KemoType.font(.callout)).foregroundStyle(.orange)
                    }
                    if let pending = store.pendingConnectorGrant { ConnectorGrantPrompt(pending: pending, accent: accent) }
                    Color.clear.frame(height: 1).id("chatBottom")
                        .onAppear { atBottom = true }.onDisappear { atBottom = false }
                }.padding(.horizontal, 24).padding(.bottom, 20).frame(maxWidth: 780).frame(maxWidth: .infinity)
            }.overlay(alignment: .leading) {
                if store.conversationMessages.count > 3 {
                    GeometryReader { geometry in
                        let count = store.conversationMessages.count
                        let gap = min(7.0, max(1.0, (geometry.size.height - 30) / Double(count) - 3))
                        VStack(spacing: 0) {
                            ForEach(Array(store.conversationMessages.enumerated()), id: \.element.id) { index, message in
                                Button {
                                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.18)) { proxy.scrollTo(message.id, anchor: .center) }
                                } label: {
                                    RoundedRectangle(cornerRadius: 1).fill(accent.opacity(visibleMessages.contains(message.id) ? 0.85 : 0.22))
                                        .frame(width: message.role == "You" ? 9 : 6, height: 3)
                                        .frame(width: 16, height: 3 + gap).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityLabel("Jump to message \(index + 1), \(message.role)")
                                    .help("Message \(index + 1) of \(count)")
                            }
                        }.frame(maxHeight: .infinity).padding(.leading, 3)
                    }.frame(width: 22).accessibilityElement(children: .contain).accessibilityLabel("Conversation position")
                }
            }.accessibilityIdentifier("chatTranscript")
                // The stage above the conversation comes and goes by its geometry (`ChatStage`).
                .onScrollGeometryChange(for: ChatStage.Metrics.self) { geometry in
                    ChatStage.Metrics(contentHeight: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                      viewportHeight: geometry.containerSize.height,
                                      distanceFromTop: geometry.contentOffset.y + geometry.contentInsets.top)
                } action: { _, metrics in stage.report?(metrics) }
                .onScrollPhaseChange { _, phase in if phase == .interacting { stage.scrolled?() } }
                // A conversation opens at its latest message; a new chat at its greeting.
                .defaultScrollAnchor(store.conversationMessages.isEmpty ? .top : .bottom, for: .initialOffset)
                .defaultScrollAnchor(stage.anchorsTop ? .top : .bottom, for: .sizeChanges)
                .onChange(of: store.conversationMessages.count) { proxy.scrollTo("chatBottom", anchor: .bottom) }
                .onChange(of: store.streamingReply) { if atBottom { proxy.scrollTo("chatBottom", anchor: .bottom) } }
                .onChange(of: store.localLookup) { proxy.scrollTo("chatBottom", anchor: .bottom) }
                .onChange(of: store.handoffWorking) { proxy.scrollTo("chatBottom", anchor: .bottom) }
                .onChange(of: store.handoffStreaming) { if atBottom { proxy.scrollTo("chatBottom", anchor: .bottom) } }
                .onChange(of: store.modelLabel) { proxy.scrollTo("chatBottom", anchor: .bottom) }
        }
    }
    #if os(macOS)
    private static let emptyAlignment: HorizontalAlignment = .center
    #else
    private static let emptyAlignment: HorizontalAlignment = .leading
    #endif
    /// "Chat with Claude": starts a chat with the agent (you, the agent, and Kemo).
    private func agentSuggestion(_ agent: ChatAgentOption) -> some View {
        Button { store.selectChatAgent(agent.id) } label: {
            HStack(spacing: 12) {
                ChatAgentLogo(logo: agent.logo, title: agent.title, size: 18).frame(width: 22)
                Text("Chat with " + agent.title).font(KemoType.font(.callout)); Spacer(); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06)))
        }.buttonStyle(.plain).frame(maxWidth: 380).accessibilityIdentifier("chatWith-" + agent.id)
    }
    private func suggestionButton(_ title: String, icon: String, message: String) -> some View {
        Button { suggestion(message) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(accent).frame(width: 22)
                Text(title).font(KemoType.font(.callout)); Spacer(); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06)))
        }.buttonStyle(.plain).frame(maxWidth: 380)
    }
}

/// "Let <model> read your <connection>? Results are sent to <host>." Shown in the chat the first time a
/// connected model's request needs a connection it hasn't been allowed; nothing was read or sent yet.
struct ConnectorGrantPrompt: View {
    @Environment(AppStore.self) private var store
    let pending: AppStore.PendingConnectorGrant
    let accent: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(pending.required.question, systemImage: "lock.open").font(KemoType.font(.callout, weight: .semibold))
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { buttons }
                VStack(alignment: .leading, spacing: 8) { buttons }
            }
        }.padding(16).frame(maxWidth: 520, alignment: .leading)
            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(accent.opacity(0.18)))
            .accessibilityElement(children: .contain).accessibilityIdentifier("connectorGrantPrompt")
    }
    @ViewBuilder private var buttons: some View {
        Button("Allow once") { store.resolveConnectorGrant(.once) }.buttonStyle(.borderedProminent).tint(accent)
            .accessibilityIdentifier("grantOnce")
        Button("Always for this model") { store.resolveConnectorGrant(.always) }.buttonStyle(.bordered)
            .accessibilityIdentifier("grantAlways")
        Button("Don’t allow") { store.resolveConnectorGrant(.deny) }.buttonStyle(.bordered)
            .accessibilityIdentifier("grantDeny")
    }
}

struct ChatMessageRow: View {
    @AppStorage(CompanionIdentity.key, store: AccountDirectory.accountSettings) private var companionName = CompanionIdentity.defaultName
    #if os(macOS)
    @Environment(DesktopPreferences.self) private var desktopPreferences
    private var contentFont: Font { desktopPreferences.font(content: true) }
    #else
    private var contentFont: Font { KemoType.font(.body) }
    #endif
    let message: ChatMessage
    /// The latest reply: Kemo is in this avatar while the stage above the conversation is hidden.
    var home = false
    @Environment(AppStore.self) private var store
    @Environment(\.chatAccentOverride) private var accentOverride
    private var accent: Color { accentOverride ?? store.state.theme.bodyColor }
    private var isUser: Bool { message.role == "You" }
    static let avatarSize: CGFloat = 28
    static let avatarGap: CGFloat = 10
    /// The companion's name beside its avatar, small and quiet.
    static func nameLabel(_ name: String) -> some View {
        Text(name).font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            .frame(minHeight: avatarSize * 0.62, alignment: .center)
    }
    /// What VoiceOver reads: who speaks, the text, a hand-off's quiet line, and any attachments.
    private var spokenLabel: String {
        let speaker: String = isUser ? "You" : (message.handoff?.agent ?? "KemoSabe")
        let detail: String = message.handoff?.detail.map { ". " + $0 } ?? ""
        let attached: String = (message.attachments ?? []).map { ", attached " + $0.title }.joined()
        return speaker + ": " + message.text + detail + attached
    }
    #if os(macOS)
    @State private var readAloud = MacReadAloud.shared
    @State private var hovering = false
    private var isReading: Bool { readAloud.speaking == message.id }
    private func toggleReading() {
        if isReading { readAloud.stop() } else { readAloud.speak(message.text, id: message.id, store: store) }
    }
    #endif
    var body: some View {
        // An agent's question to Kemo, and Kemo's answer: Kemo's card.
        if let handoff = message.handoff, handoff.part == .question || handoff.part == .answer {
            KemoAskCard(message: message, handoff: handoff, home: home, accent: accent, contentFont: contentFont)
        } else { row }
    }
    private var row: some View {
        HStack(alignment: .top, spacing: isUser ? 8 : Self.avatarGap) {
            if isUser { Spacer(minLength: 30) }
            // A reply carries Kemo's avatar, like a profile picture in a chat; your messages keep their bubble.
            // An agent's reply carries its own mark and name.
            else if let handoff = message.handoff { HandoffAgentAvatar(agent: handoff.agent, size: Self.avatarSize) }
            else { KemoAvatarSlot(theme: store.state.theme, home: home, accent: accent, size: Self.avatarSize) }
            VStack(alignment: .leading, spacing: isUser ? 9 : 4) {
                if !isUser { Self.nameLabel(message.handoff?.agent ?? companionName) }
                if let images = message.images, !images.isEmpty { ScrollView(.horizontal) { HStack { ForEach(images) { ChatImageThumbnail(image: $0) } } } }
                if let attachments = message.attachments, !attachments.isEmpty { ChatAttachmentLabels(attachments: attachments) }
                Text(message.text).font(contentFont).textSelection(.enabled).lineSpacing(4)
                if let detail = message.handoff?.detail, !detail.isEmpty {
                    Text(detail).font(KemoType.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                #if os(macOS)
                if !isUser {
                    Button(action: toggleReading) {
                        Image(systemName: isReading ? "stop.fill" : "speaker.wave.2").font(.system(size: 11, weight: .medium))
                            .frame(width: 22, height: 18).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(.secondary)
                        .help(isReading ? "Stop reading" : "Read aloud").accessibilityIdentifier("readAloud")
                        .opacity(hovering || isReading ? 1 : 0)
                }
                #endif
            }.padding(isUser ? 15 : 0)
                .background(isUser ? Color.primary.opacity(0.065) : .clear, in: RoundedRectangle(cornerRadius: 20))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenLabel)
            #if os(macOS)
                // Any reply can be read aloud in the voice chosen in Models → Voice.
                .accessibilityActions {
                    if !isUser { Button(isReading ? "Stop reading" : "Read aloud") { toggleReading() } }
                }
            #endif
            if !isUser { Spacer(minLength: 16) }
        }
        .modifier(HandoffRowIdentity(part: message.handoff?.part))
        #if os(macOS)
            .onHover { hovering = $0 }
        #endif
    }
}

/// Kemo stepping into a chat with an agent: Kemo's avatar with a lock ring, and a card, "Claude asked
/// Kemo", with the question, then Kemo reading this device (or, the first time, asking you), then
/// Kemo's answer with what stayed on this device and exactly what was shared.
struct KemoAskCard: View {
    @AppStorage(CompanionIdentity.key, store: AccountDirectory.accountSettings) private var companionName = CompanionIdentity.defaultName
    @Environment(AppStore.self) private var store
    let message: ChatMessage
    let handoff: ChatHandoff
    var home = false
    let accent: Color
    let contentFont: Font
    private var question: String { handoff.part == .answer ? handoff.question ?? "" : message.text }
    private var looking: Bool { handoff.part == .question && store.localLookup == message.text }
    private var asking: Bool {
        handoff.part == .question && store.agentQuestions.consent.map { $0.inChat && $0.question == message.text } == true
    }
    var body: some View {
        HStack(alignment: .top, spacing: ChatMessageRow.avatarGap) {
            KemoLockedAvatar(theme: store.state.theme, accent: accent, home: home || looking, orb: looking ? .searching : nil, size: ChatMessageRow.avatarSize)
            VStack(alignment: .leading, spacing: 6) {
                ChatMessageRow.nameLabel(companionName)
                VStack(alignment: .leading, spacing: 8) {
                    Label("\(handoff.agent) asked \(companionName)", systemImage: "lock.shield").font(KemoType.font(.caption, weight: .semibold)).foregroundStyle(accent)
                    Text("“" + question + "”").font(contentFont).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    if let detail = handoff.part == .question ? handoff.detail : nil {
                        Text(detail).font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                    if handoff.part == .question {
                        if asking { consent }
                        else if looking {
                            HStack(spacing: 8) {
                                KemoOrb(size: 18, secondary: accent, state: .searching).tint(accent)
                                Text("Looking on this \(AgentDevice.name)…").font(contentFont).foregroundStyle(.secondary)
                            }.accessibilityElement(children: .combine).accessibilityIdentifier("handoffLooking")
                        }
                    } else {
                        Text(message.text).font(contentFont.weight(.semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let stayed = handoff.stayedLine {
                            Label(stayed, systemImage: "lock").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                        }
                        if let detail = handoff.detail, !detail.isEmpty {
                            Text(detail).font(KemoType.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        if let shared = handoff.shared {
                            Text("Shared: “\(shared)”").font(KemoType.font(.caption2)).foregroundStyle(.secondary)
                        }
                    }
                    Label(handoff.localCaption, systemImage: "apple.intelligence").font(KemoType.font(.caption2, weight: .medium)).foregroundStyle(.secondary)
                }
                .padding(12).frame(maxWidth: 460, alignment: .leading)
                .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent.opacity(0.2)))
            }
            Spacer(minLength: 16)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("handoff-" + handoff.part.rawValue)
        .accessibilityLabel(spoken)
    }
    private var spoken: String {
        var parts = ["\(handoff.agent) asked \(companionName): " + question]
        if handoff.part == .answer {
            parts.append(companionName + " answered: " + message.text)
            if let stayed = handoff.stayedLine { parts.append(stayed) }
            if let detail = handoff.detail { parts.append(detail) }
            if let shared = handoff.shared { parts.append("Shared: " + shared) }
        } else if looking { parts.append("Looking on this \(AgentDevice.name)") }
        parts.append(handoff.localCaption)
        return parts.joined(separator: ". ")
    }
    /// The first time: "Let Claude ask Kemo about your chats?"
    private var consent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Let \(handoff.agent) ask \(companionName) about your chats?").font(KemoType.font(.callout, weight: .semibold))
            Text("\(companionName) reads them on this \(AgentDevice.name) and sends back only the answer. Sensitive items still ask you; Device only and Secret never leave.")
                .font(KemoType.font(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { consentButtons }
                VStack(alignment: .leading, spacing: 8) { consentButtons }
            }
        }.accessibilityElement(children: .contain).accessibilityIdentifier("agentConsentCard")
    }
    @ViewBuilder private var consentButtons: some View {
        Button("Allow always") { store.agentQuestions.decide(.always) }.buttonStyle(.borderedProminent).tint(accent).accessibilityIdentifier("agentConsentAlways")
        Button("Allow once") { store.agentQuestions.decide(.once) }.buttonStyle(.bordered).accessibilityIdentifier("agentConsentOnce")
        Button("Don’t allow") { store.agentQuestions.decide(.deny) }.buttonStyle(.bordered).accessibilityIdentifier("agentConsentDeny")
    }
}

/// A chat with an agent: its rows are findable by part ("handoff-result"); other rows are left as they were.
private struct HandoffRowIdentity: ViewModifier {
    let part: ChatHandoff.Part?
    @ViewBuilder func body(content: Content) -> some View {
        if let part { content.accessibilityElement(children: .combine).accessibilityIdentifier("handoff-" + part.rawValue) } else { content }
    }
}

struct ChatComposer: View {
    #if os(macOS)
    @Environment(DesktopPreferences.self) private var desktopPreferences
    private var contentFont: Font { desktopPreferences.font(content: true) }
    #else
    private var contentFont: Font { KemoType.font(.body) }
    #endif
    @Environment(\.colorScheme) private var colorScheme
    @Binding var text: String
    var busy: Bool
    var microphoneOn: Bool
    var hasAttachments = false
    var microphoneBusy = false
    var microphoneUnavailable = false
    var send: () -> Void
    var cancel: () -> Void
    var attach: (() -> Void)? = nil
    var toggleMicrophone: () -> Void
    var focusChanged: (Bool) -> Void = { _ in }
    @FocusState private var focused: Bool
    @Environment(AppStore.self) private var store
    @Environment(\.chatAccentOverride) private var accentOverride
    private var accent: Color { accentOverride ?? store.state.theme.bodyColor }
    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            HStack(alignment: .bottom, spacing: 4) {
            if let attach {
                Button(action: attach) { Image(systemName: "plus").font(.system(size: 19, weight: .medium)).frame(width: 38, height: 44) }
                    .buttonStyle(.plain).padding(.leading, 4).disabled(busy)
                    .accessibilityLabel("Add attachment").accessibilityIdentifier("attachImages")
            }
            TextField("Message \(CompanionIdentity.name)…", text: $text, axis: .vertical)
                .lineLimit(1...6).font(contentFont).textFieldStyle(.plain)
                .padding(.vertical, 12).padding(.leading, attach == nil ? 16 : 0)
                .focused($focused).submitLabel(.send).onSubmit { submit() }
                .accessibilityIdentifier("chatInput")
            Button { if busy { cancel() } else { submit() } } label: {
                Image(systemName: busy ? "stop.fill" : "arrow.up").font(.system(size: 16, weight: .semibold))
                    .frame(width: 36, height: 36).foregroundStyle(accentOverride == nil || colorScheme == .dark ? Color.black.opacity(0.85) : Color.white)
                    .background(accent, in: Circle())
            }.buttonStyle(.plain).padding(5)
                .disabled(!busy && !hasAttachments && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityLabel(busy ? "Stop response" : "Send message").accessibilityIdentifier("sendMessage")
        }.background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 25))
            .overlay(RoundedRectangle(cornerRadius: 25).stroke(Color.primary.opacity(focused ? 0.16 : 0.08)))
                        Button {
                focused = false; toggleMicrophone()
            } label: {
                Group {
                    if microphoneBusy { KemoOrb(size: 18, state: .listening) }
                    else { Image(systemName: microphoneOn ? "mic.fill" : "mic").font(.system(size: 18)) }
                }.frame(width: 42, height: 44)
                    .foregroundStyle(microphoneOn ? store.state.theme.accentColor : .secondary)
            }.buttonStyle(.plain).disabled(microphoneBusy)
                .accessibilityLabel(microphoneUnavailable ? "Retry microphone" : microphoneOn ? "Turn microphone off" : "Turn microphone on")
                .accessibilityValue(microphoneBusy ? "Starting" : microphoneOn ? "On" : "Off").accessibilityIdentifier("microphoneToggle")
                .background(Color.primary.opacity(0.065), in: Circle())
                .overlay(Circle().stroke(Color.primary.opacity(0.09), lineWidth: 0.5))
        }
            .onChange(of: focused) { focusChanged(focused) }
            .onDisappear { focusChanged(false) }
    }
    private func submit() {
        guard !busy, hasAttachments || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        focused = false; send()
    }
}
