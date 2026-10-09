import SwiftUI
import TsukumoCore
import TsukumoVoice

/// The composer: the message, the bots it goes to (chips you tap, or "@name" in the text), and send.
/// With nobody tagged, the placeholder names who gets it ("Message Claude…").
public struct ChatComposer: View {
    @Bindable var session: ChatSession
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.voice) private var voice
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
                if let listening, listening.phase.isLive {
                    ListeningStrip(listener: listening)
                        .padding(.horizontal, 16).padding(.top, 14)
                } else {
                    TextField(session.placeholder, text: $session.draft, axis: .vertical)
                        .lineLimit(1...6)
                        .tsukumoFont(.body)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .submitLabel(.send)
                        .onSubmit(send)
                        .padding(.horizontal, 16).padding(.top, 16)
                        .accessibilityIdentifier("chatInput")
                }
                HStack(spacing: 8) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.threadBots) { bot in chip(bot, theme: theme) }
                        }
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
