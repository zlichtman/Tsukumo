#if os(macOS)
import Foundation
import SwiftUI
import TsukumoCore
import TsukumoUI

// The dock's characters (design/UI-GUIDE.md#the-side-dock), ported from the old Mac app's dock.
// The drawing is TsukumoUI's `ClayPainter` (one source of truth for the clay family, on iPhone and Mac);
// this file decides what a character acts out, suggests a character for a new bot, and keeps the dock's
// small performances. KemoSabe keeps its own companion artwork.

/// What a bot's character acts out, from what the bot is doing.
public enum DockCharacterState {
    /// One state, most urgent first: needing the owner, a chirp's hop, a reply read aloud, a running turn
    /// (a coding agent at work types; otherwise thinking until words come, then talking), the done
    /// celebration, then asleep (tucked away or at night) or idle.
    public static func resolve(needsYou: Bool, running: Bool, hasWords: Bool, coding: Bool, voicing: Bool,
                               sinceChirp: TimeInterval?, done: Bool, tucked: Bool, night: Bool) -> ClayState {
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

public extension ClayState {
    /// The word for a tile's accessibility value and the bubble's header.
    var label: String {
        switch self {
        case .idle: ""
        case .working: "Working"
        case .thinking: "Thinking"
        case .talking: "Talking"
        case .chirping: "Chirping in"
        case .needsYou: "Needs you"
        case .done: "Done"
        case .sleeping: "Asleep"
        }
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
    /// A bot's settings: one to edit, or nil for a new one.
    case edit(UUID?)
}

/// A speech bubble next to a tile for a few seconds.
public struct DockCallout: Equatable, Identifiable, Sendable {
    public var id = UUID()
    public let bot: UUID
    public let text: String
    public init(bot: UUID, text: String) { self.bot = bot; self.text = text }
}

// MARK: Starting a bot

/// The three bots a new dock offers to start from (TsukumoCore's `StarterBot`, shared with the iPhone's
/// first run). `BotLook.suggested` lives beside it in TsukumoCore.
public typealias DockStarter = StarterBot

// MARK: Engines on the dock

/// Each engine's color, for the thin ring at a bot's feet (TsukumoUI's `EngineColor`, so the editors'
/// previews match the dock).
public enum DockEngineColor {
    public static func hex(_ engine: EngineID) -> String { EngineColor.hex(engine) }
    public static func color(_ engine: EngineID) -> Color { RGB(hex: hex(engine)).color }
    /// The ring a bot wears: its engine's color, its own, or none.
    public static func ring(for bot: BotSpec) -> Color? { bot.look.ringColor(engineHex: hex(bot.engine)) }
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
