import SwiftUI
import TsukumoCore
import TsukumoVoice

/// The composer (design/UI-GUIDE.md, The composer): the chat's bots as chips you tap to tag (or "@name" in the text)
/// and hold to talk to, the message, and one row in thumb reach: the model chip (the bot it goes to, its model and
/// power; it opens the model sheet), your chats, a new chat, the microphone, and send. With nobody tagged, the
/// placeholder names who gets it ("Message Claude…").
public struct ChatComposer: View {
    @Bindable var session: ChatSession
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.voice) private var voice
    @Environment(\.composerActions) private var actions
    @Environment(\.engineInfo) private var engineInfo
    /// The bot the model sheet is open for.
    @State private var tuning: BotSpec?
    /// The bot being held to talk (press and hold its chip); its tap then doesn't tag it.
    @State private var holding: UUID?

    /// A turn of listening for this chat (its microphone, or a chip held), while it's live.
    private var listening: VoiceListener? {
        guard let listener = voice?.listener, listener.phase.isLive else { return nil }
        return listener.botID == nil || session.bot(listener.botID) != nil ? listener : nil
    }

    public init(session: ChatSession) {
        self.session = session
    }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 8) {
            if !session.mentionSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(session.mentionSuggestions) { bot in
                            Button { session.complete(mention: bot) } label: {
                                HStack(spacing: 6) {
                                    BotAvatar(bot: bot, size: 18, showsEngine: false)
                                    Text("@" + bot.name.replacingOccurrences(of: " ", with: "")).tsukumoFont(.subheadline, weight: .medium)
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(theme.fill, in: Capsule())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("mention-" + bot.name)
                        }
                    }
                    .padding(.horizontal, 4)
                }
            }
            if let last = voice?.lastListener, case .failed(let message) = last.phase, last.botID == nil || session.bot(last.botID) != nil {
                Label(message, systemImage: "mic.slash").tsukumoFont(.caption).foregroundStyle(theme.secondary)
                    .padding(.horizontal, 8)
                    .accessibilityIdentifier("voiceProblem")
            }
            VStack(alignment: .leading, spacing: 10) {
                if session.threadBots.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.threadBots) { bot in chip(bot, theme: theme) }
                        }
                        .padding(.horizontal, 10)
                    }
                    .padding(.top, 10)
                }
                if let listening, listening.phase.isLive {
                    ListeningStrip(listener: listening)
                        .padding(.horizontal, 16).padding(.top, session.threadBots.count > 1 ? 0 : 14)
                } else {
                    TextField(session.placeholder, text: $session.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .tsukumoFont(.body)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 16).padding(.top, session.threadBots.count > 1 ? 2 : 16)
                        .accessibilityIdentifier("chatInput")
                }
                HStack(spacing: 8) {
                    if let actions, let bot = session.recipients.first ?? session.threadBots.first {
                        modelChip(bot, actions: actions, theme: theme)
                    } else if session.threadBots.count <= 1 {
                        ForEach(session.threadBots) { bot in chip(bot, theme: theme) }
                    }
                    Spacer(minLength: 0)
                    if let actions {
                        ControlCircle("Your chats", systemImage: "bubble.left.and.bubble.right") { focused = false; actions.showConversations() }
                            .accessibilityIdentifier("openConversations")
                        ControlCircle("New chat", systemImage: "square.and.pencil") { focused = false; actions.newChat() }
                            .accessibilityIdentifier("newChat")
                    }
                    if let voice { ComposerMicButton(session: session, voice: voice) }
                    sendButton(theme)
                }
                .padding(.horizontal, 10)
                Label("KemoSabe assists on this \(session.device)", systemImage: "lock.fill")
                    .tsukumoFont(.caption2).foregroundStyle(theme.secondary)
                    .padding(.horizontal, 16).padding(.bottom, 12)
                    .accessibilityIdentifier("composerFooter")
            }
            .background(theme.fill, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(theme.ink.opacity(focused ? 0.16 : 0.08)))
        }
    }

    /// The bot the message goes to, its model, and its power ("Opus 5.5 · High"); it opens the model sheet.
    private func modelChip(_ bot: BotSpec, actions: ComposerActions, theme: TsukumoTheme) -> some View {
        let choice = actions.engines().first { $0.engine == bot.engine }
        let title: String = bot.isKemoSabe ? "On-device" : choice?.shortName(bot.model) ?? engineInfo(bot.engine).title
        let power = bot.effort.map { EffortWeight.title($0.rawValue) }
        return Button { focused = false; tuning = bot } label: {
            HStack(spacing: 6) {
                if bot.isKemoSabe { Image(systemName: "lock.fill").font(.system(size: 11, weight: .semibold)) }
                else { EngineMarkView(engineInfo(bot.engine).mark, size: 16) }
                Text(power.map { title + " · " + $0 } ?? title).tsukumoFont(.subheadline, weight: .medium).lineLimit(1)
                if bot.fast { Image(systemName: "hare.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.accent) }
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.secondary)
            }
            .padding(.horizontal, 12).frame(height: TsukumoMetrics.control)
            .background(theme.ink.opacity(scheme == .dark ? 0.08 : 0.06), in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Model for \(bot.name), \(title)" + (power.map { ", power " + $0 } ?? ""))
        .accessibilityIdentifier("modelChip")
        .sheet(item: $tuning) { bot in
            ModelSheet(bot: bot, bots: session.threadBots.filter { !$0.isBroughtIn }, actions: actions).fittedSheet()
        }
    }

    private func chip(_ bot: BotSpec, theme: TsukumoTheme) -> some View {
        let on = session.chips.contains(bot.id)
        return Button {
            if holding == bot.id { holding = nil; return }
            session.toggleChip(bot.id)
        } label: {
            HStack(spacing: 6) {
                BotAvatar(bot: bot, size: 20, showsEngine: false)
                Text(bot.name).tsukumoFont(.subheadline, weight: .medium).lineLimit(1)
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 7)
            .background(on ? theme.accent.opacity(0.22) : theme.fill, in: Capsule())
            .overlay(Capsule().stroke(on ? theme.accent.opacity(0.55) : theme.hairline))
        }
        .buttonStyle(.plain)
        .onLongPressGesture(minimumDuration: VoiceGestures.holdThreshold, perform: { hold(bot) }, onPressingChanged: { pressing in
            // Letting go of a held chip sends what was said.
            guard !pressing, holding == bot.id, let listener = voice?.listener, listener.botID == bot.id else { return }
            listener.stop()
            Task { try? await Task.sleep(for: .milliseconds(400)); if holding == bot.id { holding = nil } }
        })
        .accessibilityLabel(bot.name)
        .accessibilityValue(on ? "Tagged" : "Not tagged")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityHint(voice == nil ? "" : "Touch and hold to talk to \(bot.name).")
        .accessibilityAction(named: "Talk to \(bot.name)") { hold(bot); voice?.listener?.setHold(false) }
        .accessibilityIdentifier("chip-" + bot.name)
    }

    /// Press and hold a bot's chip to talk to it: it listens while you hold and sends when you let go (or,
    /// if you let go at once, when you stop talking).
    private func hold(_ bot: BotSpec) {
        guard let voice else { return }
        focused = false
        holding = bot.id
        voice.listen(to: bot.id, hold: true, names: session.bots.map(\.name)) { text in
            Task { await session.say(text, to: bot.id) }
        }
    }

    private func sendButton(_ theme: TsukumoTheme) -> some View {
        let busy = session.isBusy
        return Button { if busy { session.stopAll() } else { send() } } label: {
            Image(systemName: busy ? "stop.fill" : "arrow.up").font(.system(size: 16, weight: .semibold))
                .foregroundStyle(theme.onAccent)
                .frame(width: 38, height: 38)
                .background(theme.accent.opacity(busy || session.canSend ? 1 : 0.45), in: Circle())
        }
        .buttonStyle(.plain)
        .disabled(!busy && !session.canSend)
        .accessibilityLabel(busy ? "Stop" : "Send")
        .accessibilityIdentifier("sendMessage")
    }

    private func send() {
        guard session.canSend else { return }
        focused = false
        session.send()
    }
}
