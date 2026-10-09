import SwiftUI
import TsukumoCore
import TsukumoVoice

// Voice in the chat and the bot editors, the same on iPhone and Mac: the composer's microphone, the
// listening meter, and a bot's voice (TsukumoVoice's `VoiceHub` does the listening and speaking).

public extension EnvironmentValues {
    /// The app's voice. Nil (tests, the demo, previews) shows no microphone.
    @Entry var voice: VoiceHub? = nil
}

/// A bot's voice: the nine voices, each with a sample to play (▶︎), and a check on the one it uses.
public struct VoicePicker: View {
    @Binding var bot: BotSpec
    var compact = false
    @Environment(\.voice) private var voice
    @Environment(\.colorScheme) private var scheme

    public init(bot: Binding<BotSpec>, compact: Bool = false) { _bot = bot; self.compact = compact }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        let current = KokoroVoices.voice(for: bot)
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            ForEach(KokoroVoices.all) { option in
                HStack(spacing: 10) {
                    Button {
                        bot.voice = option.id
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: option == current ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(option == current ? theme.accent : theme.secondary)
                            Text(option.name).fontWeight(option == current ? .semibold : .regular)
                            Text(option.detail).foregroundStyle(theme.secondary)
                            Spacer(minLength: 4)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option.name + ", " + option.detail)
                    .accessibilityAddTraits(option == current ? [.isButton, .isSelected] : .isButton)
                    .accessibilityIdentifier("voice-" + option.name)
                    if let voice {
                        let playing = voice.previewing == option.id
                        Button { voice.preview(option, for: bot) } label: {
                            Image(systemName: playing ? "stop.fill" : "play.fill").font(.system(size: compact ? 10 : 12, weight: .semibold))
                                .frame(width: compact ? 22 : 28, height: compact ? 22 : 28)
                                .background(theme.fill, in: Circle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(playing ? "Stop" : "Play \(option.name)")
                        .accessibilityIdentifier("previewVoice-" + option.name)
                    }
                }
                .padding(.vertical, compact ? 2 : 3)
            }
        }
        .font(compact ? .system(size: 12.5) : .body)
    }

    /// The line under the picker: which model speaks it here.
    public static func footer(voice: VoiceHub?, device: String) -> String {
        guard let voice else { return "Your bot speaks in this voice when it answers something you said." }
        if voice.device.neuralSupported, voice.kokoro.isInstalled { return "Spoken by Kokoro, on this \(device)." }
        return voice.device.neuralSupported
            ? "Until the better voice models are on this \(device) (Settings, Models, Voice), Apple’s closest voice speaks."
            : "Apple’s closest voice speaks on this \(device)."
    }
}

/// A small level meter: five bars that follow your voice.
public struct VoiceMeter: View {
    let level: Double
    var color: Color
    var height: CGFloat
    public init(level: Double, color: Color, height: CGFloat = 16) { self.level = level; self.color = color; self.height = height }
    public var body: some View {
        HStack(alignment: .center, spacing: max(1.5, height * 0.12)) {
            ForEach(0..<5, id: \.self) { index in
                let shape = [0.5, 0.8, 1.0, 0.8, 0.5][index]
                Capsule().fill(color)
                    .frame(width: max(2, height * 0.16), height: max(height * 0.2, height * CGFloat(min(1, 0.18 + level * shape))))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.1), value: level)
        .accessibilityHidden(true)
    }
}

/// What the composer shows while it listens: the meter and your words as they come, with stop and cancel.
public struct ListeningStrip: View {
    let listener: VoiceListener
    var compact = false
    @Environment(\.colorScheme) private var scheme
    public init(listener: VoiceListener, compact: Bool = false) { self.listener = listener; self.compact = compact }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(spacing: compact ? 8 : 10) {
            VoiceMeter(level: listener.level, color: theme.accent, height: compact ? 14 : 18)
            Text(Self.words(listener))
                .font(compact ? .system(size: 13) : .body)
                .foregroundStyle(listener.partial.isEmpty ? theme.secondary : theme.ink)
                .lineLimit(compact ? 2 : 3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("listeningWords")
            Button { listener.cancel() } label: {
                Image(systemName: "xmark").font(.system(size: compact ? 11 : 13, weight: .semibold))
                    .frame(width: compact ? 24 : 32, height: compact ? 24 : 32)
                    .background(theme.fill, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
            .accessibilityIdentifier("cancelListening")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Listening")
    }

    /// "Listening…", your words so far, or "Writing it down…" while Whisper reads it.
    public static func words(_ listener: VoiceListener) -> String {
        switch listener.phase {
        case .starting: "Starting the microphone…"
        case .listening: listener.partial.isEmpty ? "Listening…" : listener.partial
        case .transcribing: listener.partial.isEmpty ? "Writing it down…" : listener.partial
        case .sent(let text): text
        case .failed(let message): message
        case .cancelled: ""
        }
    }
}

/// The composer's microphone: tap to talk (it stops when you do), tap again to send now; hold to talk and
/// let go to send. While it listens it's the accent with a stop square.
public struct ComposerMicButton: View {
    let session: ChatSession
    let voice: VoiceHub
    var size: CGFloat = 38
    public init(session: ChatSession, voice: VoiceHub, size: CGFloat = 38) { self.session = session; self.voice = voice; self.size = size }
    @State private var pressStart: Date?
    @State private var startedHere = false
    @Environment(\.colorScheme) private var scheme

    private var mine: VoiceListener? {
        guard let listener = voice.listener, listener.botID == nil, listener.phase.isLive else { return nil }
        return listener
    }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        let on = mine != nil
        Image(systemName: on ? "stop.fill" : "mic.fill")
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(on ? theme.onAccent : theme.ink)
            .frame(width: size, height: size)
            .background(on ? theme.accent : theme.fill, in: Circle())
            .overlay(Circle().stroke(on ? .clear : theme.hairline))
            .contentShape(Circle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { _ in
                guard pressStart == nil else { return }
                pressStart = Date()
                if let mine { mine.stop(); startedHere = false } else { start(); startedHere = true }
            }.onEnded { _ in
                defer { pressStart = nil }
                guard startedHere, let start = pressStart, let listener = mine else { return }
                // Held: let go to send. Tapped: it listens until you stop talking.
                if Date().timeIntervalSince(start) >= VoiceGestures.holdThreshold { listener.stop() } else { listener.setHold(false) }
            })
            .accessibilityLabel(on ? "Stop and send" : "Talk")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { if let mine { mine.stop() } else { start() } }
            .accessibilityIdentifier("composerMic")
    }

    private func start() {
        voice.listen(to: nil, hold: true, names: session.bots.map(\.name)) { text in
            Task { await session.say(text) }
        }
    }
}

/// The shared timing for tap and hold.
public enum VoiceGestures {
    /// A press held this long is hold to talk (letting go sends); shorter is a tap (it listens until you stop
    /// talking). The old dock's hold was 0.35 seconds.
    public static let holdThreshold: TimeInterval = 0.35
}
