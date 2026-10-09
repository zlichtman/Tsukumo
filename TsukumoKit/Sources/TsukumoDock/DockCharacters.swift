#if os(macOS)
import Foundation
import SwiftUI
import TsukumoCore
import TsukumoUI

// What each tile acts out (design/UI-GUIDE.md, the side dock), and the dock's small performances. KemoSabe is
// drawn by TsukumoUI's `KemoSabeFigure` in its owner's look (its cloud, or the two-tone figure) and mood; every other tile is its
// service's mark (`ServiceMarkView`), with the state shown around it.

/// What a bot's tile acts out, from what the bot is doing.
public enum DockCharacterState {
    /// One state, most urgent first: needing the owner, a chirp's hop, a reply read aloud, a running turn
    /// (a coding agent at work types; otherwise thinking until words come, then talking), the done
    /// celebration, then asleep (tucked away or at night) or idle.
    public static func resolve(needsYou: Bool, running: Bool, hasWords: Bool, coding: Bool, voicing: Bool,
                               sinceChirp: TimeInterval?, done: Bool, tucked: Bool, night: Bool) -> BotState {
        if needsYou { return .needsYou }
        if let sinceChirp, sinceChirp >= 0, sinceChirp < 2.5 { return .chirping }
        if voicing { return .talking }
        if running { return coding ? .working : hasWords ? .talking : .thinking }
        if done { return .done }
        if tucked || night { return .sleeping }
        return .idle
    }
    /// Night for a sleepy character: 11 pm to 7 am.
    public static func isNight(_ date: Date, calendar: Calendar = .current) -> Bool {
        let hour = calendar.component(.hour, from: date)
        return hour >= 23 || hour < 7
    }
}

/// A poke on a tile: click-and-hold wiggles, a double click giggles.
public enum DockReaction: String, Equatable, Sendable { case poke, giggle }

/// Which panel is open beside the dock.
public enum DockSurface: Hashable, Sendable {
    /// A bot's chat.
    case bot(UUID)
    /// Every bot in one thread.
    case together
    /// A bot's panel: KemoSabe's palette and voice, or one of the owner's bots (who it is, what it runs on, what it
    /// asked, what was shared, what it sent, its grants and Revoke, and for a bot that chats, its settings).
    case panel(UUID)
    /// Adding a bot: bringing in one the owner has elsewhere, or making one.
    case addBot
}

/// A speech bubble next to a tile for a few seconds.
public struct DockCallout: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public let bot: UUID
    public let text: String
    public init(bot: UUID, text: String) { self.bot = bot; self.text = text }
}

// MARK: Motion

/// The tiles' little performances. Every one is still under Reduce Motion (a fade stands in).
public enum DockMotion: String, CaseIterable, Equatable, Sendable {
    case none
    /// A bot starts talking: a soft bob.
    case bob
    /// A bot chirps in: a little hop.
    case hop
    /// Needs the owner: a wiggle.
    case wiggle

    public struct Spec: Equatable, Sendable {
        public var lift: CGFloat = 0
        public var angle: Double = 0
        public var scale: CGFloat = 1
        public var duration: Double = 0
        public var isStill: Bool { lift == 0 && angle == 0 && scale == 1 }
    }
    public func spec(reduceMotion: Bool) -> Spec {
        if reduceMotion { return Spec(duration: self == .none ? 0 : 0.2) }
        switch self {
        case .none: return Spec()
        case .bob: return Spec(lift: 4, scale: 1.04, duration: 0.7)
        case .hop: return Spec(lift: 12, scale: 1.08, duration: 0.55)
        case .wiggle: return Spec(angle: 9, duration: 0.6)
        }
    }
}
#endif
