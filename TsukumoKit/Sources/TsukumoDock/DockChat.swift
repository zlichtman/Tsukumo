#if os(macOS)
import SwiftUI
import TsukumoCore
import TsukumoGateway
import TsukumoUI
import TsukumoVoice

// A bot's chat on the Mac: TsukumoUI's chat (the same transcript, KemoSabe card, consent and share cards
// as the iPhone app and the website demo) at Mac sizes (`ChatDensity.compact`), with a composer that fits
// the bubble beside the dock. Ported in place of the old dock's `DockThread` and
// `DockComposer`, which had their own message types.

/// One conversation: the transcript and the composer.
public struct DockChatPane: View {
    @Bindable var session: ChatSession
    let dock: BotDock
    /// The conversation: a bot, or `BotDock.togetherID`.
    let conversation: UUID
    @Environment(\.colorScheme) private var scheme

    public init(session: ChatSession, dock: BotDock, conversation: UUID) {
        self.session = session; self.dock = dock; self.conversation = conversation
    }

    public var body: some View {
        VStack(spacing: 8) {
            if session.thread.messages.isEmpty && session.working.isEmpty {
                DockChatEmpty(dock: dock, conversation: conversation)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        ChatTranscriptContent(session: session, showsStage: false)
                            .padding(.top, -6)
                        Color.clear.frame(height: 1).id("dockChatBottom")
                    }
                    .defaultScrollAnchor(.bottom)
                    .onChange(of: session.thread.messages.count) { scrollDown(proxy) }
                    .onChange(of: session.working.count) { scrollDown(proxy) }
                    .onChange(of: session.liveExchanges) { scrollDown(proxy) }
                    .onChange(of: session.thread.messages.last) { scrollDown(proxy) }
                    .onChange(of: session.sharePrompts.count) { scrollDown(proxy) }
                    .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.05), .init(color: .black, location: 1)],
                                         startPoint: .top, endPoint: .bottom))
                }
            }
            if let banner = session.banner {
                Label(banner, systemImage: "checkmark.seal").font(.system(size: 11, weight: .medium)).lineLimit(1)
                    .foregroundStyle(TsukumoTheme(scheme).secondary)
                    .transition(.opacity)
            }
            DockComposer(session: session, dock: dock, conversation: conversation)
        }
        .environment(\.chatDensity, .compact)
        .environment(\.engineInfo, dock.engineInfo)
        .environment(\.codexPets, dock.pets)
        .foregroundStyle(TsukumoTheme(scheme).ink)
        .tint(TsukumoTheme(scheme).accent)
    }
    private func scrollDown(_ proxy: ScrollViewProxy) {
        withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo("dockChatBottom", anchor: .bottom) }
    }
}

/// An empty conversation: who's here and what they're for.
struct DockChatEmpty: View {
    let dock: BotDock
    let conversation: UUID
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(spacing: 8) {
            if conversation == BotDock.togetherID {
                HStack(spacing: -6) {
                    ForEach(dock.bots.prefix(5)) { bot in BotAvatar(bot: bot, size: 30, showsEngine: false) }
                }
                Text("Together").font(.system(size: 14, weight: .semibold))
                Text("Tag bots below, or type @name. Each answers in its own words.")
            } else if let bot = dock.bot(conversation) {
                if bot.isKemoSabe { KemoSabeFigure(bot: bot).frame(width: 84, height: 84) }
                else { BotCharacterView(bot: bot, state: .idle, size: 60, animated: false).padding(.bottom, 4) }
                Text(bot.isKemoSabe ? "Ask \(bot.name) anything" : "Message \(bot.name)").font(.system(size: 14, weight: .semibold))
                Text(bot.isKemoSabe ? "It answers on this Mac. Nothing leaves it."
                     : "Runs on \(dock.engineInfo(bot.engine).title). It asks KemoSabe for anything personal, and only gets the answer.")
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(theme.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 24)
    }
}

/// The message box at Mac sizes: the message, the bots it goes to (chips, or "@name"), and send or stop.
struct DockComposer: View {
    @Bindable var session: ChatSession
    let dock: BotDock
    let conversation: UUID
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    /// This chat's microphone, while it listens.
    private var listening: VoiceListener? {
        guard let listener = dock.voice?.listener, listener.botID == nil, listener.phase.isLive else { return nil }
        return listener
    }

    var body: some View {
        content(TsukumoTheme(scheme))
    }

    private func content(_ theme: TsukumoTheme) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.mentionSuggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(session.mentionSuggestions) { bot in
                        Button { session.complete(mention: bot) } label: {
                            HStack(spacing: 4) {
                                BotAvatar(bot: bot, size: 14, showsEngine: false)
                                Text("@" + bot.name.replacingOccurrences(of: " ", with: "")).font(.system(size: 11, weight: .medium))
                            }
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(theme.fill, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if session.threadBots.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) { ForEach(session.threadBots) { chip($0, theme: theme) } }
                }
            }
            if let last = dock.voice?.lastListener, last.botID == nil, case .failed(let message) = last.phase {
                Label(message, systemImage: "mic.slash").font(.system(size: 11)).foregroundStyle(theme.secondary)
            }
            HStack(spacing: 8) {
                if let listening {
                    ListeningStrip(listener: listening, compact: true)
                } else {
                    TextField(session.placeholder, text: $session.draft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit(send)
                        .accessibilityIdentifier("dockChatInput")
                }
                if let voice = dock.voice { ComposerMicButton(session: session, voice: voice, size: 24) }
                sendButton(theme)
            }
            .padding(.leading, 12).padding(.trailing, 5).padding(.vertical, 5)
            .frame(minHeight: 34)
            .background(theme.fill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.ink.opacity(focused ? 0.16 : 0.07)))
        }
    }

    private func chip(_ bot: BotSpec, theme: TsukumoTheme) -> some View {
        let on = session.chips.contains(bot.id)
        return Button { session.toggleChip(bot.id) } label: {
            HStack(spacing: 4) {
                BotAvatar(bot: bot, size: 15, showsEngine: false)
                Text(bot.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
            }
            .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 3)
            .background(on ? theme.accent.opacity(0.22) : theme.fill, in: Capsule())
            .overlay(Capsule().stroke(on ? theme.accent.opacity(0.55) : theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.name)
        .accessibilityValue(on ? "Tagged" : "Not tagged")
        .accessibilityIdentifier("dockChip-" + bot.name)
    }

    private func sendButton(_ theme: TsukumoTheme) -> some View {
        let busy = session.isBusy
        return Button { if busy { session.stopAll() } else { send() } } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up").font(.system(size: 12, weight: .bold))
                .foregroundStyle(theme.onAccent)
                .frame(width: 24, height: 24)
                .background(theme.accent.opacity(busy || session.canSend ? 1 : 0.4), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!busy && !session.canSend)
        .help(busy ? "Stop" : "Send")
        .accessibilityLabel(busy ? "Stop" : "Send")
        .accessibilityIdentifier("dockSend")
    }

    private func send() {
        guard session.canSend else { return }
        session.send()
        dock.store.setLastTalkedTo(conversation == BotDock.togetherID ? nil : conversation)
    }
}

// MARK: The bubble beside the side dock

/// The panel beside the dock: a bot's chat (or the panel plugged in for it), Together, or a bot's panel.
public struct DockBubble: View {
    let dock: BotDock
    @Environment(\.colorScheme) private var scheme

    public init(dock: BotDock) { self.dock = dock }

    public var body: some View {
        let size = DockMetrics.size(for: dock.surface)
        Group {
            switch dock.surface {
            case .bot(let id)?:
                if let bot = dock.bot(id), let session = dock.session(id) {
                    if let plugged = plugged(bot, session: session) { pluggedIn(bot: bot, panel: plugged) } else { chat(bot: bot, session: session) }
                } else { Color.clear }
            case .together?:
                if let session = dock.session(BotDock.togetherID) { together(session) } else { Color.clear }
            case .panel(let id)?:
                if let bot = dock.bot(id) { DockBotPanel(dock: dock, bot: bot) { dock.open(nil) } } else { Color.clear }
            case .addBot?:
                DockAddBot(dock: dock) { added in dock.open(added.map { .panel($0.id) }) }
            case nil:
                Color.clear
            }
        }
        .id(dock.surface)
        .frame(width: size.width, height: size.height)
        .background { DockGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .environment(\.engineInfo, dock.engineInfo)
        .environment(\.codexPets, dock.pets)
        .environment(\.voice, dock.voice)
    }

    /// The panel plugged in for this bot's tile, if any (Tsukumo's Claude bot).
    private func plugged(_ bot: BotSpec, session: ChatSession) -> AnyView? {
        guard let provider = dock.panelProviders[bot.id] else { return nil }
        return provider.panel(ServiceBotPanelContext(bot: bot, session: session, deviceName: "Mac") { dock.open(nil) })
    }
    private func pluggedIn(bot: BotSpec, panel: AnyView) -> some View {
        VStack(spacing: 0) {
            header(title: bot.name, subtitle: dock.subtitle(bot.id)) {
                Button { dock.open(.panel(bot.id)) } label: { Image(systemName: "info.circle") }
                    .buttonStyle(DockIconButtonStyle()).help(DockPanelWords.menuTitle(bot)).accessibilityLabel(DockPanelWords.menuTitle(bot))
            } leading: {
                BotAvatar(bot: bot, size: 30, state: dock.characterState(bot.id))
            }
            Divider().opacity(0.5)
            panel
        }
    }

    private func chat(bot: BotSpec, session: ChatSession) -> some View {
        VStack(spacing: 0) {
            header(title: bot.name, subtitle: dock.subtitle(bot.id)) {
                // Its settings, one click away (and its page has Chat, back here).
                Button { dock.open(.panel(bot.id)) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(DockIconButtonStyle()).help(DockPanelWords.menuTitle(bot)).accessibilityLabel(DockPanelWords.menuTitle(bot))
                    .accessibilityIdentifier("dockChatSettings")
                Menu {
                    Button("Clear conversation") { dock.clear(bot.id) }.disabled(session.isBusy)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.button).buttonStyle(DockIconButtonStyle()).menuIndicator(.hidden).fixedSize().accessibilityLabel("More")
            } leading: {
                BotAvatar(bot: bot, size: 30, state: dock.characterState(bot.id))
            }
            Divider().opacity(0.5)
            if let cue = dock.cue(for: bot.id) { DockWorkCard(cue: cue).padding(.horizontal, 12).padding(.top, 10) }
            if bot.isKemoSabe, let gateway = dock.gateway {
                GatewayRequestList(desk: gateway, identity: { dock.identityLine(for: $0) }).padding(.horizontal, 12).padding(.top, 10)
            }
            DockChatPane(session: session, dock: dock, conversation: bot.id).padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
        }
    }

    private func together(_ session: ChatSession) -> some View {
        VStack(spacing: 0) {
            header(title: "Together", subtitle: "Every bot in one thread") { EmptyView() } leading: {
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: 14)).foregroundStyle(TsukumoTheme(scheme).accent)
                    .frame(width: 30, height: 30).background(Circle().fill(TsukumoTheme(scheme).accent.opacity(0.14)))
            }
            Divider().opacity(0.5)
            DockChatPane(session: session, dock: dock, conversation: BotDock.togetherID).padding(.horizontal, 12).padding(.bottom, 12).padding(.top, 4)
        }
    }

    private func header<Trailing: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        header(title: title, subtitle: subtitle, trailing: trailing) { EmptyView() }
    }
    private func header<Trailing: View, Leading: View>(title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing,
                                                         @ViewBuilder leading: () -> Leading) -> some View {
        HStack(spacing: 10) {
            leading()
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            trailing()
            Button { dock.open(nil) } label: { Image(systemName: "xmark") }
                .buttonStyle(DockIconButtonStyle()).accessibilityLabel("Close").keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}

/// A quiet icon button.
struct DockIconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            .frame(width: 24, height: 24)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.primary.opacity(configuration.isPressed ? 0.11 : 0)))
            .contentShape(Rectangle())
    }
}

/// What a coding bot's work is doing, at a glance.
struct DockWorkCard: View {
    let cue: DockWorkCue
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let accent = TsukumoTheme(scheme).accent
        HStack(spacing: 10) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.12), lineWidth: 3)
                Circle().trim(from: 0, to: cue.ready || cue.status == .done ? 1 : max(0.05, cue.progress ?? 0.05))
                    .stroke(cue.ready ? Color.blue : accent, style: .init(lineWidth: 3, lineCap: .round)).rotationEffect(.degrees(-90))
                if let step = cue.step, let steps = cue.steps, !cue.ready {
                    Text("\(step)/\(steps)").font(.system(size: 7.5, weight: .bold, design: .rounded)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(cue.headline).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                HStack(spacing: 6) {
                    if let file = cue.fileLabel { Text(file).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1) }
                    if let tests = cue.tests {
                        Label("Tests " + tests.rawValue, systemImage: "flask.fill").font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(tests == .passed ? Color.green : tests == .failed ? .red : .orange)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(cue.approval != nil ? Color.orange.opacity(0.5) : Color.primary.opacity(0.08), lineWidth: 0.75))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dockWorkCard")
    }
}
#endif
