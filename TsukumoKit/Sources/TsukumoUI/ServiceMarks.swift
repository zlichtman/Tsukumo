import SwiftUI
import TsukumoCore
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// Each service's bot is shown with that service's own mark, the plain way an app says what it works with: the
// mark on a rounded tile, never redrawn into a character. Claude's spark and OpenAI's blossom ship (Resources,
// ART-NOTICE.txt). For a service whose official mark isn't bundled yet, the tile shows its name's initials in
// the service's color, until the owner adds the mark as `ServiceMark-<id>.png` (192 px, from the company's own
// press kit) to TsukumoUI's Resources: a bundled file is used as soon as it's there.

public extension ServiceID {
    /// The tile's color behind a mark or initials.
    var tileHex: String {
        switch self {
        case .claude: "F4F1EA"
        case .openAI: "FFFFFF"
        case .codex: "111111"
        case .grok: "0B0B0B"
        case .muse: "0866FF"
        case .openClaw: "D9434A"
        case .cursor: "26262B"
        case .gemini: "3F6FE8"
        }
    }
    /// The initials a tile shows until the service's own mark is bundled.
    var initials: String {
        switch self {
        case .claude: "C"
        case .openAI: "AI"
        case .codex: "Cx"
        case .grok: "Gk"
        case .muse: "M"
        case .openClaw: "OC"
        case .cursor: "Cu"
        case .gemini: "Gm"
        }
    }
    /// The bundled mark that names this service, if one ships.
    var bundledMark: TsukumoArt.Name? {
        switch self {
        case .claude: .claude
        case .openAI, .codex: .openAI
        default: nil
        }
    }
}

/// A service's mark on its tile: its own mark when it's bundled, its initials until then.
public struct ServiceMarkView: View {
    public let service: ServiceID
    public var size: CGFloat
    public init(_ service: ServiceID, size: CGFloat = 28) { self.service = service; self.size = size }

    public var body: some View {
        let tile = RGB(hex: service.tileHex)
        let onTile: Color = tile.luminance > 0.5 ? .black : .white
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(LinearGradient(colors: [tile.mix(.white, 0.08).color, tile.mix(.black, 0.06).color], startPoint: .top, endPoint: .bottom))
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .strokeBorder(Color.black.opacity(tile.luminance > 0.5 ? 0.1 : 0.25), lineWidth: max(0.5, size * 0.012))
            if let image = Self.dropIn(service) {
                image.resizable().interpolation(.high).scaledToFit().padding(size * 0.16)
            } else if let mark = service.bundledMark {
                if mark == .openAI {
                    TsukumoArt.image(mark).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                        .foregroundStyle(onTile).padding(size * 0.14)
                } else {
                    TsukumoArt.image(mark).resizable().interpolation(.high).scaledToFit().padding(size * 0.17)
                }
            } else {
                Text(service.initials)
                    .font(.system(size: size * (service.initials.count > 1 ? 0.36 : 0.46), weight: .bold, design: .rounded))
                    .foregroundStyle(onTile)
                    .minimumScaleFactor(0.5)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(service.title)
    }

    /// The service's own mark, once the owner bundles it (`ServiceMark-<id>.png`).
    static func dropIn(_ service: ServiceID) -> Image? {
        guard let url = Bundle.module.url(forResource: "ServiceMark-" + service.rawValue, withExtension: "png") else { return nil }
        #if canImport(UIKit)
        return UIImage(contentsOfFile: url.path).map { Image(uiImage: $0) }
        #elseif canImport(AppKit)
        return NSImage(contentsOf: url).map { Image(nsImage: $0) }
        #else
        return nil
        #endif
    }
}

// MARK: A service bot's own panel

/// What a plugged-in panel gets when its tile opens.
@MainActor public struct ServiceBotPanelContext {
    /// The service bot as the lineup has it now (its engine, model, project, and access).
    public let bot: BotSpec
    /// Its chat, when it has one: the standard chat the panel replaces, for history or a fallback.
    public let session: ChatSession?
    /// "Mac" or "iPhone".
    public let deviceName: String
    /// Puts the panel away.
    public let close: () -> Void
    public init(bot: BotSpec, session: ChatSession?, deviceName: String, close: @escaping () -> Void) {
        self.bot = bot; self.session = session; self.deviceName = deviceName; self.close = close
    }
}

/// A service's own panel in place of the standard chat on its tile. Tsukumo's Claude bot plugs in here: until a
/// provider is registered for a service (the dock's `panelProviders`), its tile opens the standard chat on
/// whatever runs it (for Claude, the API key or Claude Code), exactly as before.
@MainActor public protocol ServiceBotPanelProvider: AnyObject {
    /// The service whose tile it takes.
    var service: ServiceID { get }
    /// The panel to show for `context.bot`, or nil to keep the standard chat (it isn't ready, say).
    func panel(_ context: ServiceBotPanelContext) -> AnyView?
    /// What its tile shows besides the chat's own state (observable on the provider): its work runs in the
    /// background, so a task waiting on the owner or running shows on the tile like a chat's.
    var tileStatus: ServiceBotTileStatus { get }
    /// One short line for the tile's subtitle ("Needs you: Tidy my notes"), or nil.
    var tileLine: String? { get }
    /// Work that finished (`.done`) or didn't (`.failed`) and the owner hasn't opened yet, whatever else is running:
    /// the tile marks it until the panel opens.
    var tileUnread: ServiceBotTileStatus? { get }
}

public extension ServiceBotPanelProvider {
    var tileStatus: ServiceBotTileStatus { .idle }
    var tileLine: String? { nil }
    var tileUnread: ServiceBotTileStatus? { nil }
}

/// What a plugged-in service's tile shows besides its chat.
public enum ServiceBotTileStatus: String, Hashable, Sendable {
    /// Nothing to see.
    case idle
    /// A task is running.
    case working
    /// A task waits on the owner (an approval, or KemoSabe's card).
    case needsYou
    /// A task finished and the owner hasn't looked yet.
    case done
    /// A task failed and the owner hasn't looked yet.
    case failed
}
