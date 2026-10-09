#if os(macOS)
import AppKit
import SwiftUI
import TsukumoCore
import TsukumoUI

// The side dock's shelf and its tiles (ported from `AgentsDockStrip`, `DockCharacterTile`, `DockShelf`,
// `DockGlass`, and `DockMenu` in the old Mac app's dock). A Dock on its side: Liquid Glass, the Dock's
// proportions, magnification, names on hover, a separator before Together and Settings (always last), and a sliver at the edge while it's
// tucked away. Its tiles are KemoSabe, then the owner's bots, each as its character (a Codex pet) or its service's mark.

public extension EnvironmentValues {
    /// Offscreen renders can't draw live Liquid Glass: snapshots and tests draw a stand-in instead.
    @Entry var dockGlassFallback = false
}

/// The Dock's material: Liquid Glass on macOS 26, a material before it (and in offscreen renders).
public struct DockGlass<S: Shape>: View {
    let shape: S
    var tint: Color?
    /// How strongly the tint shows (Tinted glass is stronger than a tinted Glass).
    var strength: Double = 0.25
    @Environment(\.dockGlassFallback) private var fallback
    public init(shape: S, tint: Color? = nil, strength: Double = 0.25) { self.shape = shape; self.tint = tint; self.strength = strength }
    public var body: some View {
        if fallback {
            shape.fill(.regularMaterial)
                .overlay(shape.fill((tint ?? .clear).opacity(strength * 0.6)))
                .overlay(shape.stroke(.white.opacity(0.4), lineWidth: 1))
                .overlay(shape.stroke(Color.black.opacity(0.1), lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(tint.map { Glass.regular.tint($0.opacity(strength)) } ?? .regular, in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.fill((tint ?? .clear).opacity(strength * 0.6)))
                .overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.75))
        }
    }
}

/// The shelf in its style: Liquid Glass, glass tinted with the accent, a solid color, or nothing (Minimal).
/// The owner's dock color (`DockSettings.tint`) tints the glass lightly, Tinted glass more, and fills Solid.
struct DockShelf<S: InsettableShape>: View {
    let style: DockStyle
    let shape: S
    var accent: Color
    /// The owner's color, or nil for Automatic.
    var tint: Color? = nil
    var body: some View {
        switch style {
        case .glass: DockGlass(shape: shape, tint: tint, strength: 0.2)
        case .tinted:
            // Liquid Glass washes a light tint out over a bright or a dark wallpaper, so the color is also laid
            // beneath the glass: the shelf reads as that color (coral on Automatic) and still refracts, unlike Solid.
            let color = tint ?? accent
            ZStack {
                shape.fill(color.opacity(0.55))
                DockGlass(shape: shape, tint: color, strength: 0.6)
            }
            .overlay(shape.strokeBorder(color.opacity(0.7), lineWidth: 1))
        case .solid:
            shape.fill(tint ?? Color(nsColor: .windowBackgroundColor))
                .overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        case .minimal: Color.clear
        }
    }
}

/// One bot on the shelf: KemoSabe acting out its mood, a pet acting out its state, or a service's mark with its state
/// around it.
struct DockTile: View {
    let bot: BotSpec
    let state: BotState
    var size: CGFloat
    var level: DockAnimationLevel
    var reduceMotion: Bool
    /// False holds still (tucked away or out of sight).
    var active: Bool
    var selected = false
    var hovered = false
    var pressed = false
    var ringIndicator = false
    var accent: Color
    var reaction: (kind: DockReaction, tick: Int)?
    @Environment(\.codexPets) private var pets
    var cue: DockWorkCue?
    /// Listening to the owner: the voice's level (0 to 1), drawn as a ring that follows it.
    var listening: Double?
    /// Clicking talks to it (the app has a voice and the bot chats).
    var talks = false
    /// Background work the owner hasn't seen yet (a plugged-in panel's task that finished or didn't), until they open it.
    var unread: ServiceBotTileStatus?

    private struct Poke { var angle: Double = 0; var squash: Double = 0 }
    private var still: Bool { reduceMotion || level == .still }

    var body: some View {
        ZStack {
            if selected {
                Ellipse().fill(RadialGradient(colors: [accent.opacity(0.45), .clear], center: .center, startRadius: 0, endRadius: size * 0.4))
                    .frame(width: size * 0.9, height: size * 0.26)
                    .offset(y: size * 0.4)
            }
            if let cue, cue.running, let progress = cue.progress {
                Circle().stroke(Color.primary.opacity(0.1), lineWidth: 2.5).frame(width: size * 1.02, height: size * 1.02)
                Circle().trim(from: 0, to: max(0.04, progress)).stroke(accent, style: .init(lineWidth: 2.5, lineCap: .round))
                    .rotationEffect(.degrees(-90)).frame(width: size * 1.02, height: size * 1.02)
            }
            if ringIndicator {
                Circle().strokeBorder(accent.opacity(0.8), lineWidth: max(1.5, size * 0.04)).frame(width: size * 1.06, height: size * 1.06)
                    .accessibilityHidden(true)
            }
            if let listening {
                // Listening: a soft accent glow and a ring that grows with the owner's voice.
                Circle().fill(RadialGradient(colors: [accent.opacity(0.28), .clear], center: .center, startRadius: size * 0.2, endRadius: size * 0.62))
                    .frame(width: size * 1.2, height: size * 1.2)
                    .accessibilityHidden(true)
                Circle().strokeBorder(accent.opacity(0.9), lineWidth: max(1.5, size * 0.045))
                    .frame(width: size * 1.04, height: size * 1.04)
                    .scaleEffect(reduceMotion ? 1 : 1 + 0.14 * listening)
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: listening)
                    .accessibilityHidden(true)
            }
            face
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed ? 0.93 : hovered ? 1.05 : 1, anchor: .bottom)
        .offset(y: state == .chirping && !still ? -size * 0.08 : 0)
        .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.3), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
        .animation(reduceMotion ? nil : .spring(duration: 0.35, bounce: 0.5), value: state)
        .keyframeAnimator(initialValue: Poke(), trigger: still ? 0 : (reaction?.tick ?? 0)) { content, poke in
            content.rotationEffect(.radians(poke.angle), anchor: .bottom).scaleEffect(x: 1 + poke.squash, y: 1 - poke.squash, anchor: .bottom)
        } keyframes: { _ in
            let giggle = reaction?.kind == .giggle
            KeyframeTrack(\.angle) {
                if giggle { LinearKeyframe(0, duration: 0.6) } else {
                    LinearKeyframe(0.2, duration: 0.07); LinearKeyframe(-0.2, duration: 0.1); LinearKeyframe(0.12, duration: 0.1)
                    LinearKeyframe(-0.06, duration: 0.1); LinearKeyframe(0, duration: 0.1)
                }
            }
            KeyframeTrack(\.squash) {
                if giggle {
                    SpringKeyframe(0.14, duration: 0.1); SpringKeyframe(-0.08, duration: 0.12); SpringKeyframe(0.1, duration: 0.1)
                    SpringKeyframe(-0.05, duration: 0.12); SpringKeyframe(0, duration: 0.2)
                } else { LinearKeyframe(0, duration: 0.45) }
            }
        }
        .overlay(alignment: .topLeading) {
            if listening != nil {
                Image(systemName: "mic.fill").font(.system(size: max(8, size * 0.17), weight: .bold)).foregroundStyle(.white)
                    .frame(width: max(14, size * 0.3), height: max(14, size * 0.3)).background(Circle().fill(accent))
                    .offset(x: -2, y: -2).accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topTrailing) {
            if state == .needsYou {
                Text("!").font(.system(size: max(9, size * 0.2), weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .frame(width: max(14, size * 0.3), height: max(14, size * 0.3)).background(Circle().fill(.orange)).offset(x: 2, y: -2)
            } else if !bot.isKemoSabe, !BotCharacterView.actsOut(bot, pets: pets), [.thinking, .working, .talking].contains(state) {
                // A mark can't act it out: a small bubble says it's at work.
                Image(systemName: state == .talking ? "waveform" : "ellipsis")
                    .font(.system(size: max(7, size * 0.15), weight: .bold)).foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: active && !still)
                    .frame(width: max(16, size * 0.36), height: max(12, size * 0.26))
                    .background(Capsule().fill(accent))
                    .offset(x: 3, y: -3)
                    .accessibilityHidden(true)
            }
        }
        .overlay(alignment: .topLeading) {
            if let tests = cue?.tests, cue?.running == true || cue?.ready == true {
                Image(systemName: "flask.fill").font(.system(size: max(8, size * 0.17), weight: .semibold)).foregroundStyle(.white)
                    .frame(width: max(13, size * 0.28), height: max(13, size * 0.28))
                    .background(Circle().fill(tests == .passed ? Color.green : tests == .failed ? Color.red : Color.orange.opacity(0.85)))
                    .offset(x: -2, y: -2).accessibilityLabel("Tests " + tests.rawValue)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if cue?.ready == true, state != .needsYou {
                Image(systemName: "text.magnifyingglass").font(.system(size: max(8, size * 0.17), weight: .bold)).foregroundStyle(.white)
                    .frame(width: max(14, size * 0.3), height: max(14, size * 0.3)).background(Circle().fill(Color.blue))
                    .offset(x: 2, y: 1).accessibilityLabel("Ready for review")
            } else if state == .done || (unread == .done && state != .needsYou) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: max(11, size * 0.26), weight: .semibold)).foregroundStyle(.white, .green)
                    .background(Circle().fill(.background).padding(1)).offset(x: 2, y: 1).transition(.opacity)
            } else if unread == .failed, state != .needsYou {
                Image(systemName: "xmark.circle.fill").font(.system(size: max(11, size * 0.26), weight: .semibold)).foregroundStyle(.white, .red)
                    .background(Circle().fill(.background).padding(1)).offset(x: 2, y: 1).transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .help(bot.name + (bot.role.isEmpty ? "" : ": " + bot.role) + (talks ? "\nClick to talk, or hold and let go to send. Double-click for the chat." : "\nClick for what it asked KemoSabe and what it may do."))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bot.name)
        .accessibilityValue(listening != nil ? "Listening" : unread == .done ? "Finished, not opened yet" : unread == .failed ? "Didn’t finish, not opened yet" : state.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("dockTile-" + (bot.isKemoSabe ? "kemosabe" : bot.name))
    }

    @ViewBuilder private var face: some View {
        if bot.isKemoSabe {
            // KemoSabe in its look and palette, acting out its mood (moving only while something is happening).
            let mood = KemoSabeMood(state, listening: listening != nil)
            KemoSabeFigure(bot: bot, mood: mood, animated: active && !still && mood != .idle && mood != .sleeping, shadow: true)
                .scaleEffect(1.08, anchor: .bottom)
        } else {
            BotCharacterView(bot: bot, state: state, size: size * 0.8, animated: active && !still)
                .shadow(color: .black.opacity(0.22), radius: size * 0.05, y: size * 0.03)
                .saturation(state == .sleeping ? 0.4 : 1)
                .opacity(state == .sleeping ? 0.7 : 1)
        }
    }
}

/// The side dock: a Liquid Glass shelf like the Dock's, on the screen's side, with the characters on it.
public struct DockShelfView: View {
    let dock: BotDock
    let layout: DockLayout
    var revealed: Bool
    var reduceMotion: Bool
    var active = true
    /// Snapshots: a fixed moment instead of the clock, and where the pointer is.
    var fixedTime: Double?
    var pointer: CGPoint?
    @State private var hover: CGPoint?
    @State private var pressed: UUID?
    /// What a press on a character means: talk (tap or hold), or the chat (double-click).
    @State private var talk = DockTalkGesture()
    @Environment(\.colorScheme) private var scheme

    public init(dock: BotDock, layout: DockLayout, revealed: Bool, reduceMotion: Bool, active: Bool = true, fixedTime: Double? = nil, pointer: CGPoint? = nil) {
        self.dock = dock; self.layout = layout; self.revealed = revealed; self.reduceMotion = reduceMotion; self.active = active
        self.fixedTime = fixedTime; self.pointer = pointer
    }

    private var settings: DockSettings { layout.settings }
    private var still: Bool { reduceMotion || settings.animation == .still }
    private var right: Bool { settings.edge == .right }
    private var accent: Color { TsukumoTheme(scheme).accent }
    /// The owner's dock color, if they picked one.
    private var tint: Color? { settings.tint.map { RGB(hex: $0).color } }
    /// The sliver, the working ring, and the selected glow: the dock color, or Tsukumo's coral.
    private var mark: Color { tint ?? accent }

    public var body: some View {
        ZStack(alignment: .topLeading) {
            if revealed {
                // The glass sits outside the clock: Liquid Glass is costly to redraw.
                ZStack(alignment: .topLeading) {
                    shelf(time: 0, glass: true)
                    // A live clock only while something one-off is happening; resting characters animate in
                    // Core Animation. The clock is periodic, not `.animation`: a display-linked schedule
                    // stops in panels macOS reports as hidden (found in a menu-bar panel).
                    if !active || still || !lively || fixedTime != nil {
                        shelf(time: fixedTime ?? dock.now().timeIntervalSinceReferenceDate, glass: false)
                    } else {
                        TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                            shelf(time: context.date.timeIntervalSinceReferenceDate, glass: false)
                        }
                    }
                }
                .transition(reduceMotion ? .opacity : .move(edge: right ? .trailing : .leading).combined(with: .opacity))
            } else {
                Capsule().fill(mark.opacity(dock.waitingBot != nil ? 0.9 : 0.45))
                    .frame(width: DockLayout.sliver, height: min(120, layout.length * 0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: right ? .trailing : .leading)
                    .padding(right ? .trailing : .leading, 1)
                    .accessibilityLabel("Bot dock")
                    .accessibilityHint("Point here to show your bots.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase { case .active(let point): hover = point; case .ended: hover = nil }
        }
        .contextMenu { DockMenu(dock: dock) }
        .environment(\.engineInfo, dock.engineInfo)
        .environment(\.codexPets, dock.pets)
    }

    private var pointerNow: CGPoint? { pointer ?? hover }
    /// Something only a running clock can show: a chirp, the done celebration, or listening.
    private var lively: Bool {
        _ = dock.settleTick
        return dock.bots.contains { dock.finishedAt[$0.id] != nil }
            || dock.lastChirp.map { dock.now().timeIntervalSince($0.at) < 3 } == true
            || dock.voice?.listener != nil
    }

    /// The shelf's glass (`glass: true`, drawn when the layout or pointer changes) or its tiles (on the clock).
    private func shelf(time: Double, glass: Bool) -> some View {
        let box = layout.shelfInPanel
        let bots = dock.bots
        let count = bots.count + Self.extraTiles
        let scales = (0..<count).map { scale($0, box: box) }
        let extras = scales.map { (CGFloat($0) - 1) * layout.size }
        let total = extras.reduce(0, +)
        func center(_ index: Int) -> CGPoint {
            let before = extras.prefix(index).reduce(0, +)
            let y = box.minY + layout.tileOffset(index) + before + extras[index] / 2 - total / 2
            let tile = layout.size * scales[index]
            let x = right ? box.maxX - layout.padding - tile / 2 : box.minX + layout.padding + tile / 2
            return CGPoint(x: x, y: y)
        }
        let shape = RoundedRectangle(cornerRadius: layout.cornerRadius, style: .continuous)
        let separatorY = center(count - 2).y - layout.size * scales[count - 2] / 2 - (DockLayout.separatorGap + layout.spacing) / 2
        return ZStack(alignment: .topLeading) {
            if glass {
                DockShelf(style: settings.style, shape: shape, accent: accent, tint: tint)
                    .frame(width: box.width, height: box.height + total)
                    .position(x: box.midX, y: box.midY)
                if settings.separators, settings.style != .minimal {
                    Rectangle().fill(Color.primary.opacity(0.22)).frame(width: box.width - layout.padding * 3, height: 1)
                        .position(x: box.midX, y: separatorY)
                }
            } else {
                ForEach(Array(bots.enumerated()), id: \.element.id) { index, bot in
                    let point = center(index)
                    let tile = layout.size * scales[index]
                    characterTile(bot, index: index, size: tile, time: time, center: point)
                        .position(x: point.x, y: point.y)
                    if settings.indicator == .dot, dock.running(bot.id) || dock.needsYou(bot.id) {
                        Circle().fill(tint ?? Color.primary.opacity(0.75)).frame(width: 4, height: 4)
                            .position(x: right ? box.maxX - layout.padding / 2 : box.minX + layout.padding / 2, y: point.y)
                            .accessibilityHidden(true)
                    }
                }
                // Add a Bot right under the bots, then Together, then Settings, always the last tile.
                addTile(size: layout.size * scales[count - 3]).position(center(count - 3))
                togetherTile(size: layout.size * scales[count - 2]).position(center(count - 2))
                settingsTile(size: layout.size * scales[count - 1]).position(center(count - 1))
                if settings.labels != .off, let index = hoveredIndex(box: box), index < count {
                    nameLabel(index: index).position(labelPosition(center(index), tile: layout.size * scales[index]))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    /// The order of the shelf's tiles: the bots, Add a Bot, then Together, then Settings, always last.
    public enum Tile: Equatable, Sendable { case bot(UUID), add, together, settings }
    /// The tiles after the bots.
    public static let extraTiles = 3
    public static func tiles(_ bots: [BotSpec]) -> [Tile] { bots.map { .bot($0.id) } + [.add, .together, .settings] }
    /// The name a tile shows on hover.
    public static func tileTitle(_ index: Int, bots: [BotSpec]) -> String {
        guard index >= 0, index < bots.count + extraTiles else { return "" }
        switch tiles(bots)[index] {
        case .bot: return bots[index].name
        case .add: return "Add a Bot"
        case .together: return "Together"
        case .settings: return "Settings"
        }
    }
    private func labelPosition(_ center: CGPoint, tile: CGFloat) -> CGPoint {
        let offset = tile / 2 + 8 + (DockLayout.labelSpace - 16) / 2
        return CGPoint(x: right ? center.x - offset : center.x + offset, y: center.y)
    }

    private var hoveredBot: UUID? {
        hoveredIndex(box: layout.shelfInPanel).flatMap { $0 < dock.bots.count ? dock.bots[$0].id : nil }
    }
    private func scale(_ index: Int, box: CGRect) -> Double {
        guard settings.magnification, !reduceMotion, let point = pointerNow,
              point.x >= box.minX - layout.reach - 4, point.x <= box.maxX + 4 else { return 1 }
        let center = box.minY + layout.tileOffset(index)
        return Double(DockLayout.magnification(distance: abs(point.y - center), size: layout.size, magnified: CGFloat(settings.magnifiedSize)))
    }
    private func hoveredIndex(box: CGRect) -> Int? {
        guard let point = pointerNow, point.x >= box.minX - layout.reach - 4, point.x <= box.maxX + 4 else { return nil }
        let count = dock.bots.count + Self.extraTiles
        return (0..<count).min { abs(box.minY + layout.tileOffset($0) - point.y) < abs(box.minY + layout.tileOffset($1) - point.y) }
            .flatMap { abs(box.minY + layout.tileOffset($0) - point.y) < layout.size * 0.7 ? $0 : nil }
    }

    private func characterTile(_ bot: BotSpec, index: Int, size: CGFloat, time: Double, center: CGPoint) -> some View {
        let state = dock.characterState(bot.id, tucked: !revealed)
        let listener = dock.listener(for: bot.id)
        let talks = dock.voice != nil && bot.engine.chats
        return DockTile(bot: bot, state: state, size: size, level: settings.animation, reduceMotion: reduceMotion,
                        active: active && fixedTime == nil && revealed,
                        selected: dock.surface == .bot(bot.id) || dock.surface == .panel(bot.id),
                        hovered: hoveredBot == bot.id, pressed: pressed == bot.id,
                        ringIndicator: settings.indicator == .ring && (dock.running(bot.id) || dock.needsYou(bot.id)), accent: mark,
                        reaction: dock.reaction[bot.id], cue: dock.cue(for: bot.id), listening: listener.map(\.level), talks: talks,
                        unread: dock.unread(bot.id))
            // One gesture for a press: down starts listening (hold to talk), a quick click keeps listening until the
            // owner stops talking, and a second click right after opens the chat. A service that doesn't chat opens
            // its panel instead.
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global).onChanged { _ in
                guard !talk.isPressing else { return }
                pressed = bot.id
                guard talks else { _ = talk.began(bot.id, listening: false, now: dock.now()); return }
                dock.perform(talk.began(bot.id, listening: dock.listener(for: bot.id) != nil, now: dock.now()), on: bot.id)
            }.onEnded { _ in
                pressed = nil
                let action = talk.ended(now: dock.now())
                if !bot.engine.chats { dock.toggle(.panel(bot.id)) }
                // Without a voice (the demo), a click opens the chat as before.
                else if dock.voice == nil { dock.toggle(.bot(bot.id)) } else { dock.perform(action, on: bot.id) }
            })
            .contextMenu {
                if talks {
                    Button(dock.listener(for: bot.id) == nil ? "Talk to \(bot.name)" : "Send Now") {
                        if let live = dock.listener(for: bot.id) { live.stop() } else { dock.talk(to: bot.id, hold: false) }
                    }
                }
                if bot.engine.chats { Button("Open Chat") { dock.open(.bot(bot.id)) } }
                Button(DockPanelWords.menuTitle(bot)) { dock.open(.panel(bot.id)) }
                if !bot.isKemoSabe {
                    let place = dock.bots.firstIndex { $0.id == bot.id } ?? 0
                    if place > 1 { Button("Move Up") { dock.move(bot.id, to: place - 1) } }
                    if place < dock.bots.count - 1 { Button("Move Down") { dock.move(bot.id, to: place + 1) } }
                    Button("Remove from Dock") { dock.remove(bot.id) }
                }
                Divider()
                DockMenu(dock: dock)
            }
            .accessibilityAction {
                if !bot.engine.chats { dock.toggle(.panel(bot.id)) }
                else if dock.voice == nil { dock.toggle(.bot(bot.id)) }
                else if let live = dock.listener(for: bot.id) { live.stop() } else { dock.talk(to: bot.id, hold: false) }
            }
            .accessibilityAction(named: "Open Chat") { if bot.engine.chats { dock.open(.bot(bot.id)) } }
            .accessibilityAction(named: DockPanelWords.menuTitle(bot)) { dock.open(.panel(bot.id)) }
            .accessibilityHint(talks ? "Talks to \(bot.name). Double-click opens the chat." : "")
    }

    /// Add a Bot: bring in a bot the owner has elsewhere, or make one.
    private func addTile(size: CGFloat) -> some View {
        let on = dock.surface == .addBot
        return Button { dock.toggle(.addBot) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(on ? accent.opacity(0.25) : Color.primary.opacity(0.07))
                    .frame(width: size * 0.84, height: size * 0.84)
                Image(systemName: "plus").font(.system(size: size * 0.36, weight: .semibold)).foregroundStyle(on ? accent : .secondary)
            }
            .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Add a bot")
        .accessibilityLabel("Add a Bot").accessibilityIdentifier("dockAddBot")
    }
    /// Settings, the same window as the menu bar's Settings… and ⌘,.
    private func settingsTile(size: CGFloat) -> some View {
        Button { dock.dismissCallout(); dock.openSettings?() } label: {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(Color.primary.opacity(0.07))
                    .frame(width: size * 0.84, height: size * 0.84)
                Image(systemName: "gearshape.fill").font(.system(size: size * 0.36)).foregroundStyle(.secondary)
            }
            .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Settings")
        .accessibilityLabel("Settings").accessibilityHint("Opens Tsukumo’s Settings.").accessibilityIdentifier("dockSettings")
    }
    private func togetherTile(size: CGFloat) -> some View {
        let on = dock.surface == .together
        return Button { dock.toggle(.together) } label: {
            ZStack {
                RoundedRectangle(cornerRadius: size * 0.24, style: .continuous).fill(on ? accent.opacity(0.25) : Color.primary.opacity(0.07))
                    .frame(width: size * 0.84, height: size * 0.84)
                Image(systemName: "bubble.left.and.bubble.right.fill").font(.system(size: size * 0.34)).foregroundStyle(on ? accent : .secondary)
            }
            .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Together: every bot in one thread")
        .accessibilityLabel("Together").accessibilityIdentifier("dockTogether")
    }
    private func nameLabel(index: Int, title: String? = nil) -> some View {
        let title = title ?? Self.tileTitle(index, bots: dock.bots)
        // Under a bot's name, what a click does: talk (and twice, its chat), or its page for a bot that doesn't chat.
        let bot = index < dock.bots.count ? dock.bots[index] : nil
        let hint: String? = bot.map { bot in
            guard bot.engine.chats else { return "Click: its page" }
            return dock.voice == nil ? "Click: chat" : "Click: talk · 2×: chat"
        }
        return VStack(alignment: right ? .trailing : .leading, spacing: 1) {
            Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            if let hint { Text(hint).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1) }
        }
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background { if settings.labels == .glass { DockGlass(shape: RoundedRectangle(cornerRadius: 12, style: .continuous)) } }
            .shadow(color: settings.labels == .plain ? .black.opacity(0.35) : .clear, radius: 2, y: 1)
            .frame(width: DockLayout.labelSpace - 16, alignment: right ? .trailing : .leading)
            .allowsHitTesting(false)
    }
}

/// The dock's right-click menu, like the Dock's own: where it sits, hiding, magnification, then Settings (the
/// rest of the dock's look is in Settings, Dock).
struct DockMenu: View {
    let dock: BotDock
    var body: some View {
        let settings = dock.settings
        let store = dock.store
        Menu("Position on Screen") {
            ForEach(DockSettings.Edge.allCases) { edge in
                Toggle(edge.title, isOn: Binding(get: { settings.edge == edge }, set: { _ in store.update { $0.edge = edge } }))
            }
            Divider()
            ForEach(DockSettings.Position.allCases) { position in
                Toggle(position.title, isOn: Binding(get: { settings.position == position }, set: { _ in store.update { $0.position = position } }))
            }
        }
        Toggle("Automatically Hide", isOn: Binding(get: { settings.autohide }, set: { value in store.update { $0.autohide = value } }))
        Toggle("Magnification", isOn: Binding(get: { settings.magnification }, set: { value in store.update { $0.magnification = value } }))
        Divider()
        Button("Add a Bot…") { dock.open(.addBot) }
        if let openSettings = dock.openSettings {
            Divider()
            Button("Settings…") { openSettings() }
        }
    }
}

// MARK: The callout

/// A speech bubble from a tile: a bot chirping in, or finishing while the owner wasn't looking.
struct DockCalloutBubble: View {
    let bot: BotSpec
    let text: String
    /// The dock is on the left edge: the tail points left.
    var tailOnLeft = false
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            BotAvatar(bot: bot, size: 22, showsEngine: false)
            VStack(alignment: .leading, spacing: 2) {
                Text(bot.name).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true).lineLimit(3)
            }
        }
        .padding(.leading, tailOnLeft ? 18 : 11).padding(.trailing, tailOnLeft ? 11 : 18).padding(.vertical, 9)
        .frame(width: 250, alignment: .leading)
        .background { DockGlass(shape: DockSpeechShape()).scaleEffect(x: tailOnLeft ? -1 : 1) }
        .padding(tailOnLeft ? .leading : .trailing, 2)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("dockCallout")
    }
}

/// A rounded bubble with a small tail on its right edge, pointing at the tile.
struct DockSpeechShape: Shape {
    func path(in rect: CGRect) -> Path {
        let body = CGRect(x: rect.minX, y: rect.minY, width: rect.width - 7, height: rect.height)
        var path = Path(roundedRect: body, cornerRadius: 14, style: .continuous)
        let y = min(rect.midY, rect.minY + 22)
        path.move(to: CGPoint(x: body.maxX - 1, y: y - 6))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: y), control: CGPoint(x: body.maxX + 3, y: y - 1))
        path.addQuadCurve(to: CGPoint(x: body.maxX - 1, y: y + 6), control: CGPoint(x: body.maxX + 3, y: y + 1))
        path.closeSubpath()
        return path
    }
}
#endif
