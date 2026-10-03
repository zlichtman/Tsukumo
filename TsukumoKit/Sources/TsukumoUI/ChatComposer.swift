import SwiftUI
import TsukumoCore

/// The composer: the message, the bots it goes to (chips you tap, or "@name" in the text), and send.
/// With nobody tagged, the placeholder names who gets it ("Message Claude…").
public struct ChatComposer: View {
    @Bindable var session: ChatSession
    var onCreateBot: () -> Void
    @FocusState private var focused: Bool
    @Environment(\.colorScheme) private var scheme

    public init(session: ChatSession, onCreateBot: @escaping () -> Void = {}) {
        self.session = session; self.onCreateBot = onCreateBot
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
            VStack(alignment: .leading, spacing: 10) {
                TextField(session.placeholder, text: $session.draft, axis: .vertical)
                    .lineLimit(1...6)
                    .tsukumoFont(.body)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .submitLabel(.send)
                    .onSubmit(send)
                    .padding(.horizontal, 16).padding(.top, 16)
                    .accessibilityIdentifier("chatInput")
                HStack(spacing: 8) {
                    Button(action: onCreateBot) {
                        Image(systemName: "plus").font(.system(size: 17, weight: .medium))
                            .frame(width: 38, height: 38)
                            .background(theme.fill, in: Circle())
                            .overlay(Circle().stroke(theme.hairline))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Make a bot")
                    .accessibilityIdentifier("composerAddBot")
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.threadBots) { bot in chip(bot, theme: theme) }
                        }
                    }
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
        return Button { session.toggleChip(bot.id) } label: {
            HStack(spacing: 6) {
                BotAvatar(bot: bot, size: 20, showsEngine: false)
                Text(bot.name).tsukumoFont(.subheadline, weight: .medium).lineLimit(1)
            }
            .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 7)
            .background(on ? theme.accent.opacity(0.22) : theme.fill, in: Capsule())
            .overlay(Capsule().stroke(on ? theme.accent.opacity(0.55) : theme.hairline))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(bot.name)
        .accessibilityValue(on ? "Tagged" : "Not tagged")
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier("chip-" + bot.name)
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
