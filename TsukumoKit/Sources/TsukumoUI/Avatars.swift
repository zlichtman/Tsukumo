import SwiftUI
import TsukumoCore

// Who's talking: KemoSabe as its own face (`KemoSabeFace`, in its look and palette), and every other bot as its
// character (`BotCharacterView`: its Codex pet, or its service's mark), as in the Mac dock.

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
        case .acp(let id): EngineInfo(title: id == "gemini" ? "Gemini CLI" : id, detail: "Runs on your Mac", mark: .mac)
        case .mlx(let model): EngineInfo(title: model, detail: "On this device", mark: .generic)
        case .service(let id): EngineInfo(title: ServiceID(rawValue: id)?.title ?? id, detail: "Asks KemoSabe through the gateway", mark: .generic)
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

/// A bot's picture in the chat: KemoSabe's face in a soft circle (with a lock ring when it answers for another
/// bot), or the bot's character.
public struct BotAvatar: View {
    public let bot: BotSpec
    public var size: CGFloat
    /// KemoSabe answering for another bot, on this device: a ring and a lock in its color.
    public var locked: Bool
    public var state: BotState
    public var showsEngine: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.engineInfo) private var engineInfo

    public init(bot: BotSpec, size: CGFloat = 28, locked: Bool = false, state: BotState = .idle, showsEngine: Bool = true) {
        self.bot = bot; self.size = size; self.locked = locked; self.state = state; self.showsEngine = showsEngine
    }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        Group {
            if bot.isKemoSabe {
                let tint = bot.kemoSabeColor
                let palette = bot.kemoSabePalette
                ZStack {
                    Circle().fill(palette.id == "apricot" || palette.id == "classic" ? theme.ink.opacity(0.06) : tint.opacity(0.16))
                    KemoSabeFace(palette: palette, look: bot.kemoSabeLook).frame(width: size, height: size)
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
                BotCharacterView(bot: bot, state: state, size: size, animated: false)
            }
        }
        .accessibilityHidden(true)
    }
}
