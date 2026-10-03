import SwiftUI
import TsukumoCore

// Who's talking: KemoSabe as its companion artwork (the cloud from the website demo), every other bot
// as its clay character with a small mark for what runs it, as in the Mac dock.

/// How the app names an engine and which mark it wears. The app knows its API connections (a bot only
/// holds the connection's ID), so it provides this through the environment.
public struct EngineInfo: Hashable, Sendable {
    public enum Mark: String, Hashable, Sendable { case claude, openAI, apple, generic, mac }
    /// "Claude", "Apple on-device", "My server"
    public var title: String
    /// "Anthropic API", "On this iPhone", "Runs on your Mac"
    public var detail: String
    public var mark: Mark
    public init(title: String, detail: String = "", mark: Mark) { self.title = title; self.detail = detail; self.mark = mark }

    /// What TsukumoUI says about an engine when the app hasn't said more.
    public static func standard(_ engine: EngineID) -> EngineInfo {
        switch engine {
        case .appleOnDevice: EngineInfo(title: "Apple on-device", detail: "On this device", mark: .apple)
        case .api: EngineInfo(title: "API model", detail: "A connected model", mark: .generic)
        case .codingAgent(let id):
            switch id {
            case "claude-code": EngineInfo(title: "Claude Code", detail: "Runs on your Mac", mark: .claude)
            case "codex": EngineInfo(title: "Codex", detail: "Runs on your Mac", mark: .openAI)
            case "muse": EngineInfo(title: "Muse Code", detail: "Runs on your Mac", mark: .mac)
            case "cursor-agent": EngineInfo(title: "Cursor Agent", detail: "Runs on your Mac", mark: .mac)
            default: EngineInfo(title: id, detail: "Runs on your Mac", mark: .mac)
            }
        case .acp(let id): EngineInfo(title: id, detail: "Runs on your Mac", mark: .mac)
        case .mlx(let model): EngineInfo(title: model, detail: "On this device", mark: .generic)
        case .unknown: EngineInfo(title: "Unknown", detail: "Made by a newer Tsukumo", mark: .generic)
        }
    }
}

private struct EngineDirectoryKey: EnvironmentKey {
    static let defaultValue: @Sendable (EngineID) -> EngineInfo = { EngineInfo.standard($0) }
}
public extension EnvironmentValues {
    /// Names and marks for engines (the app maps its API connections here).
    var engineInfo: @Sendable (EngineID) -> EngineInfo {
        get { self[EngineDirectoryKey.self] }
        set { self[EngineDirectoryKey.self] = newValue }
    }
}

/// An engine's mark: Claude's spark, OpenAI's blossom, Apple Intelligence, or a plain glyph.
public struct EngineMarkView: View {
    public let mark: EngineInfo.Mark
    public var size: CGFloat
    @Environment(\.colorScheme) private var scheme
    public init(_ mark: EngineInfo.Mark, size: CGFloat = 16) { self.mark = mark; self.size = size }
    public var body: some View {
        Group {
            switch mark {
            case .claude: TsukumoArt.image(.claude).resizable().interpolation(.high).scaledToFit()
            case .openAI:
                TsukumoArt.image(.openAI).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                    .foregroundStyle(TsukumoTheme(scheme).ink)
            case .apple: Image(systemName: "apple.intelligence").resizable().scaledToFit().foregroundStyle(TsukumoTheme(scheme).accent)
            case .mac: Image(systemName: "laptopcomputer").resizable().scaledToFit().foregroundStyle(TsukumoTheme(scheme).secondary)
            case .generic: Image(systemName: "cloud").resizable().scaledToFit().foregroundStyle(TsukumoTheme(scheme).secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// KemoSabe's companion artwork: resting, or at its computer while it reads this device.
public struct KemoSabeFigure: View {
    public var searching: Bool
    public var shadow: Bool
    public init(searching: Bool = false, shadow: Bool = true) { self.searching = searching; self.shadow = shadow }
    public var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if shadow {
                    Ellipse().fill(.black.opacity(0.18)).frame(width: side * 0.47, height: side * 0.055)
                        .blur(radius: side * 0.024).offset(y: side * 0.414)
                }
                TsukumoArt.image(searching ? .kemoSabeSearching : .kemoSabe).resizable().interpolation(.high).scaledToFit()
                    .frame(width: side, height: side)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .accessibilityElement()
        .accessibilityLabel(searching ? "KemoSabe, looking on this device" : "KemoSabe")
    }
}

/// A bot's picture in the chat: KemoSabe's artwork in a soft circle (with a lock ring when it answers
/// for another bot), or a bot's clay character with its engine's mark in the corner.
public struct BotAvatar: View {
    public let bot: BotSpec
    public var size: CGFloat
    /// KemoSabe answering for another bot, on this device: a coral ring and a lock.
    public var locked: Bool
    public var state: ClayState
    public var showsEngine: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.engineInfo) private var engineInfo

    public init(bot: BotSpec, size: CGFloat = 28, locked: Bool = false, state: ClayState = .idle, showsEngine: Bool = true) {
        self.bot = bot; self.size = size; self.locked = locked; self.state = state; self.showsEngine = showsEngine
    }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        Group {
            if bot.isKemoSabe {
                let tint = bot.kemoSabeColor
                ZStack {
                    Circle().fill(bot.kemoSabeTint == nil ? theme.ink.opacity(0.06) : tint.opacity(0.16))
                    TsukumoArt.image(.kemoSabe).resizable().interpolation(.high).scaledToFit()
                        .frame(width: size * 1.2, height: size * 1.2)
                }
                .frame(width: size, height: size)
                .clipShape(Circle())
                .padding(locked ? 2 : 0)
                .overlay { if locked { Circle().stroke(tint, lineWidth: 1.5) } }
                .overlay(alignment: .bottomTrailing) {
                    if locked {
                        Image(systemName: "lock.fill").font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(.white)
                            .frame(width: size * 0.46, height: size * 0.46).background(tint, in: Circle())
                            .offset(x: 3, y: 3)
                    }
                }
            } else {
                ClayCharacter(look: bot.look, state: state, animated: state != .idle, shadow: false)
                    .frame(width: size * 1.12, height: size * 1.12)
                    .frame(width: size, height: size)
                    .overlay(alignment: .bottomTrailing) {
                        if showsEngine {
                            EngineMarkView(engineInfo(bot.engine).mark, size: size * 0.34)
                                .padding(size * 0.06)
                                .background(theme.background, in: Circle())
                                .offset(x: size * 0.12, y: size * 0.08)
                        }
                    }
            }
        }
        .accessibilityHidden(true)
    }
}
