#if os(macOS)
import AppKit
import Carbon.HIToolbox
import SwiftUI
import TsukumoCore
import TsukumoUI
import TsukumoVoice

// Talking to a bot in the dock (design/UI-GUIDE.md#the-side-dock): click a character to talk, and it listens
// until you stop talking; or hold it and let go to send. A double-click opens its chat. What you said goes
// to that bot's chat as your message, and its reply is spoken in its voice while it streams in. ⌃⌥D does the
// same for the bot in front (the open chat's, or the one you last talked to), from any app.

/// What a press on a character means. Pure, so tap, hold, double-click, and drag are unit tested.
public struct DockTalkGesture: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        /// Start listening (as hold to talk until the press ends).
        case startListening
        /// The press was a hold: send what was said.
        case send
        /// The press was a tap: keep listening until the owner stops talking.
        case keepListening
        /// A second click right after the first: drop the turn and open the chat.
        case openChat
        /// A drag started: drop the turn (it reorders instead).
        case cancel
        case none
    }
    struct Press: Equatable, Sendable {
        var bot: UUID
        var start: Date
        /// This press started the turn (otherwise one was already listening for this bot).
        var started: Bool
        var moved = false
    }
    var press: Press?
    /// When the last quick click on a bot ended, for a double-click.
    var lastClick: (bot: UUID, at: Date)?
    public static func == (a: Self, b: Self) -> Bool { a.press == b.press && a.lastClick?.bot == b.lastClick?.bot && a.lastClick?.at == b.lastClick?.at }

    public var holdThreshold: TimeInterval = VoiceGestures.holdThreshold
    public var doubleClick: TimeInterval = 0.4
    public init(doubleClick: TimeInterval = NSEvent.doubleClickInterval) { self.doubleClick = min(0.6, max(0.2, doubleClick)) }

    public var isPressing: Bool { press != nil }

    /// The pointer went down on `bot`. `listening` is whether a turn is already live for it.
    public mutating func began(_ bot: UUID, listening: Bool, now: Date) -> Action {
        guard press == nil else { return .none }
        press = Press(bot: bot, start: now, started: !listening)
        return listening ? .none : .startListening
    }
    /// The pointer moved far enough to be a drag.
    public mutating func moved() -> Action {
        guard var current = press, !current.moved else { return .none }
        current.moved = true
        press = current
        lastClick = nil
        return current.started ? .cancel : .none
    }
    /// The pointer came up.
    public mutating func ended(now: Date) -> Action {
        guard let current = press else { return .none }
        press = nil
        if current.moved { return .none }
        if current.started {
            if now.timeIntervalSince(current.start) >= holdThreshold { lastClick = nil; return .send }
            lastClick = (current.bot, now)
            return .keepListening
        }
        // A press on a bot already listening: right after a click it's a double-click; otherwise it sends.
        if let lastClick, lastClick.bot == current.bot, current.start.timeIntervalSince(lastClick.at) <= doubleClick {
            self.lastClick = nil
            return .openChat
        }
        lastClick = nil
        return .send
    }
}

public extension BotDock {
    /// The bot in front: the open chat's, or the one last talked to, or KemoSabe.
    var frontmostBot: UUID {
        if case .bot(let id)? = surface, bot(id) != nil { return id }
        if let last = store.state.lastTalkedTo, bot(last) != nil { return last }
        return BotSpec.kemoSabeID
    }
    /// The turn of listening for `id`, while it's live.
    func listener(for id: UUID) -> VoiceListener? {
        guard let listener = voice?.listener, listener.botID == id, listener.phase.isLive else { return nil }
        return listener
    }
    /// The turn listening now, or the last one for a moment (its bubble says what happened).
    var voiceBubble: VoiceListener? {
        if let listener = voice?.listener, listener.botID != nil { return listener }
        if let last = voice?.lastListener, last.botID != nil, last.phase != .cancelled { return last }
        return nil
    }

    /// Starts listening for a bot: what's said goes to its chat as the owner's message, and the reply is
    /// spoken. A reply being spoken stops first.
    @discardableResult
    func talk(to id: UUID, hold: Bool) -> VoiceListener? {
        guard let voice, bot(id) != nil, let session = session(id) else { return nil }
        store.setLastTalkedTo(id)
        dismissCallout()
        return voice.listen(to: id, hold: hold, names: bots.map(\.name)) { [weak session] text in
            Task { await session?.say(text, to: id) }
        }
    }
    /// Carries out what a press on a character meant.
    func perform(_ action: DockTalkGesture.Action, on id: UUID) {
        switch action {
        case .startListening:
            if voice == nil { toggle(.bot(id)) } else { talk(to: id, hold: true) }
        case .send: listener(for: id)?.stop()
        case .keepListening: listener(for: id)?.setHold(false)
        case .openChat:
            listener(for: id)?.cancel()
            open(.bot(id))
        case .cancel: listener(for: id)?.cancel()
        case .none: break
        }
    }
}

// MARK: The listening bubble

/// Beside a character while it listens: its face, your words as they come (or "Listening…"), the meter,
/// send now, and cancel. Then for a moment what happened ("Sent", or "Didn’t catch that").
struct DockListeningBubble: View {
    let bot: BotSpec
    let listener: VoiceListener
    var tailOnLeft = false
    var openChat: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TsukumoTheme(scheme)
        HStack(alignment: .center, spacing: 9) {
            BotAvatar(bot: bot, size: 24, showsEngine: false)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    if listener.phase == .listening { VoiceMeter(level: listener.level, color: theme.accent, height: 11) }
                }
                Text(ListeningStrip.words(listener)).font(.system(size: 12.5)).lineLimit(3)
                    .foregroundStyle(listener.partial.isEmpty && listener.phase.isLive ? .secondary : .primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("dockListeningWords")
            }
            Spacer(minLength: 2)
            if listener.phase.isLive {
                Button { listener.stop() } label: {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(theme.onAccent)
                        .frame(width: 22, height: 22).background(theme.accent, in: Circle())
                }
                .buttonStyle(.plain).help("Send now").accessibilityLabel("Send now").accessibilityIdentifier("dockListeningSend")
                .disabled(listener.phase == .transcribing)
                Button { listener.cancel() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                        .frame(width: 22, height: 22).background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain).help("Cancel").accessibilityLabel("Cancel").accessibilityIdentifier("dockListeningCancel")
            } else if case .sent = listener.phase {
                Button("Open chat", action: openChat).buttonStyle(.link).font(.system(size: 11))
            }
        }
        .padding(.leading, tailOnLeft ? 18 : 11).padding(.trailing, tailOnLeft ? 11 : 18).padding(.vertical, 9)
        .frame(width: 250, alignment: .leading)
        .background { DockGlass(shape: DockSpeechShape()).scaleEffect(x: tailOnLeft ? -1 : 1) }
        .padding(tailOnLeft ? .leading : .trailing, 2)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(bot.name), \(title)")
        .accessibilityIdentifier("dockListening")
    }

    private var title: String {
        switch listener.phase {
        case .starting, .listening: listener.hold ? "Listening · let go to send" : "Listening"
        case .transcribing: "Writing it down"
        case .sent: "Sent to \(bot.name)"
        case .failed: "Didn’t send"
        case .cancelled: "Cancelled"
        }
    }
}

// MARK: Push to talk from anywhere

/// ⌃⌥D, from any app: press and hold to talk to the bot in front and let go to send, or press once to
/// talk until you stop (press again to send now). A Carbon hot key, so it needs no Accessibility access.
@MainActor public final class DockPushToTalk {
    public static let shortcut = "⌃⌥D"
    private let dock: BotDock
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressedAt: Date?
    private var startedHere = false
    private static weak var current: DockPushToTalk?

    public init(dock: BotDock) { self.dock = dock }

    /// Registers the key. Returns false if another app has it.
    @discardableResult public func register() -> Bool {
        guard hotKey == nil else { return true }
        Self.current = self
        var spec = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                    EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            let kind = GetEventKind(event)
            MainActor.assumeIsolated {
                if kind == UInt32(kEventHotKeyPressed) { DockPushToTalk.current?.pressed() } else { DockPushToTalk.current?.released() }
            }
            return noErr
        }, 2, &spec, nil, &handler)
        let id = EventHotKeyID(signature: OSType(0x5453_4B4D), id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_D), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr
    }
    public func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil
    }

    func pressed() {
        guard pressedAt == nil else { return }
        pressedAt = Date()
        let id = dock.frontmostBot
        if let listener = dock.listener(for: id) { listener.stop(); startedHere = false; return }
        startedHere = dock.talk(to: id, hold: true) != nil
    }
    func released() {
        defer { pressedAt = nil; startedHere = false }
        guard startedHere, let start = pressedAt, let listener = dock.listener(for: dock.frontmostBot) else { return }
        if Date().timeIntervalSince(start) >= VoiceGestures.holdThreshold { listener.stop() } else { listener.setHold(false) }
    }
}
#endif
