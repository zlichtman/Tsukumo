#if os(macOS)
import AppKit
import SwiftUI
import TsukumoCore
import TsukumoUI

// The side dock's shelf and its characters (ported from `AgentsDockStrip`, `DockCharacterTile`,
// `DockShelf`, `DockGlass`, and `DockMenu` in the old Mac app's dock). A Dock on its
// side: Liquid Glass, the Dock's proportions, magnification, names on hover, a separator before + and
// Together, and a sliver at the edge while it's tucked away.

public extension EnvironmentValues {
    /// Offscreen renders can't draw live Liquid Glass: snapshots and tests draw a stand-in instead.
    @Entry var dockGlassFallback = false
}

/// The Dock's material: Liquid Glass on macOS 26, a material before it (and in offscreen renders).
public struct DockGlass<S: Shape>: View {
    let shape: S
    var tint: Color?
    @Environment(\.dockGlassFallback) private var fallback
    public init(shape: S, tint: Color? = nil) { self.shape = shape; self.tint = tint }
    public var body: some View {
        if fallback {
            shape.fill(.regularMaterial)
                .overlay(shape.fill((tint ?? .clear).opacity(0.12)))
                .overlay(shape.stroke(.white.opacity(0.4), lineWidth: 1))
                .overlay(shape.stroke(Color.black.opacity(0.1), lineWidth: 0.5))
        } else if #available(macOS 26, *) {
            Color.clear.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)) } ?? .regular, in: shape)
        } else {
            shape.fill(.regularMaterial).overlay(shape.stroke(.white.opacity(0.25), lineWidth: 0.75))
        }
    }
}

/// The shelf in its style: Liquid Glass, glass tinted with the accent, a solid color, or nothing (Minimal).
struct DockShelf<S: InsettableShape>: View {
    let style: DockStyle
    let shape: S
    var accent: Color
    var body: some View {
        switch style {
        case .glass: DockGlass(shape: shape)
        case .tinted:
            DockGlass(shape: shape, tint: accent)
                .overlay(shape.strokeBorder(accent.opacity(0.35), lineWidth: 0.75))
        case .solid:
            shape.fill(Color(nsColor: .windowBackgroundColor)).overlay(shape.strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
        case .minimal: Color.clear
        }
    }
}

/// One character on the shelf, acting out its state, with its badges.
struct DockTile: View {
    let bot: BotSpec
    let state: ClayState
    var size: CGFloat
    /// The clock, for live moments (a hop, the celebration, looking at the pointer).
    var time: Double
    /// Seconds since the state began.
    var local: Double
    var level: DockAnimationLevel
    var reduceMotion: Bool
    /// False holds still (tucked away or out of sight).
    var active: Bool
    var gaze: CGPoint?
    var selected = false
    var engineMark: DockEngineMark = .ring
    var hovered = false
    var pressed = false
    var ringIndicator = false
    var accent: Color
    var reaction: (kind: DockReaction, tick: Int)?
    var cue: DockWorkCue?
    @Environment(\.engineInfo) private var engineInfo
    /// Offscreen renders (snapshots) can't draw a layer's pictures: every tile is drawn as a pose there.
    @Environment(\.dockGlassFallback) private var offscreen

    private struct Poke { var angle: Double = 0; var squash: Double = 0 }
    /// A looping state, not looking anywhere in particular: drawn once and played by Core Animation.
    var resting: Bool { ClaySprites.looping.contains(state) && gaze == nil }
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
            if !bot.isKemoSabe, bot.look.ring == .custom || (engineMark == .ring && bot.look.ring == .engine),
               let ring = DockEngineColor.ring(for: bot) {
                // Which engine runs it (when the dock shows engines as rings), or the owner's own ring color.
                Ellipse().strokeBorder(ring.opacity(0.85), lineWidth: max(1.2, size * 0.035))
                    .frame(width: size * 0.62, height: size * 0.17).offset(y: size * 0.4)
                    .accessibilityHidden(true)
            }
            if ringIndicator {
                Circle().strokeBorder(accent.opacity(0.8), lineWidth: max(1.5, size * 0.04)).frame(width: size * 1.06, height: size * 1.06)
                    .accessibilityHidden(true)
            }
            face
        }
        .frame(width: size, height: size)
        .scaleEffect(pressed ? 0.93 : hovered ? 1.05 : 1, anchor: .bottom)
        .animation(reduceMotion ? nil : .spring(duration: 0.18, bounce: 0.3), value: hovered)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: pressed)
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
        .overlay(alignment: .bottomLeading) {
            if engineMark == .logo, !bot.isKemoSabe {
                EngineMarkView(engineInfo(bot.engine).mark, size: max(9, size * 0.17))
                    .padding(2).background(Circle().fill(.background).shadow(color: .black.opacity(0.18), radius: 1, y: 0.5))
                    .offset(x: -1, y: 1)
            }
        }
        .overlay(alignment: .topTrailing) {
            if state == .needsYou {
                Text("!").font(.system(size: max(9, size * 0.2), weight: .heavy, design: .rounded)).foregroundStyle(.white)
                    .frame(width: max(14, size * 0.3), height: max(14, size * 0.3)).background(Circle().fill(.orange)).offset(x: 2, y: -2)
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
            } else if state == .done {
                Image(systemName: "checkmark.circle.fill").font(.system(size: max(11, size * 0.26), weight: .semibold)).foregroundStyle(.white, .green)
                    .background(Circle().fill(.background).padding(1)).offset(x: 2, y: 1).transition(.opacity)
            }
        }
        .contentShape(Rectangle())
        .help(bot.name + (bot.role.isEmpty ? "" : ": " + bot.role))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(bot.name)
        .accessibilityValue(state.label)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityIdentifier("dockTile-" + (bot.isKemoSabe ? "kemosabe" : bot.name))
    }

    @ViewBuilder private var face: some View {
        if bot.isKemoSabe {
            // KemoSabe keeps its companion artwork: at its computer while it reads this Mac.
            KemoSabeFigure(searching: state == .working || state == .thinking, shadow: true)
                .scaleEffect(1.08, anchor: .bottom)
        } else if resting && active && !offscreen {
            // A loop the window server plays: no redraws while it rests, types, thinks, or talks.
            ClaySprite(look: bot.look, state: state, side: size, animate: active && !still, level: level,
                       phase: Double(abs(bot.id.hashValue % 97)) / 97)
                .scaleEffect(1.12 * bot.look.scale, anchor: .bottom)
        } else {
            // Its own size in the dock (`BotLook.scale`), standing on the same spot.
            ClayPoseView(look: bot.look, pose: livePose)
                .scaleEffect(1.12 * bot.look.scale, anchor: .bottom)
        }
    }
    /// This moment of a one-off state, looking at the pointer when there's one.
    private var livePose: ClayPose {
        var pose = ClayMotion.pose(state, time: time, local: local, still: still || !active, seed: Double(abs(bot.id.hashValue % 97)) / 97)
        if let gaze { pose.gaze = CGPoint(x: gaze.x * 0.9, y: gaze.y * 0.7) }
        return pose
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
    @State private var drag: (id: UUID, offset: CGFloat)?
    @State private var pressed: UUID?
    @Environment(\.colorScheme) private var scheme

    public init(dock: BotDock, layout: DockLayout, revealed: Bool, reduceMotion: Bool, active: Bool = true, fixedTime: Double? = nil, pointer: CGPoint? = nil) {
        self.dock = dock; self.layout = layout; self.revealed = revealed; self.reduceMotion = reduceMotion; self.active = active
        self.fixedTime = fixedTime; self.pointer = pointer
    }

    private var settings: DockSettings { layout.settings }
    private var still: Bool { reduceMotion || settings.animation == .still }
    private var right: Bool { settings.edge == .right }
    private var accent: Color { TsukumoTheme(scheme).accent }

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
                Capsule().fill(accent.opacity(dock.waitingBot != nil ? 0.9 : 0.45))
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
    }

    private var pointerNow: CGPoint? { pointer ?? hover }
    /// Something only a running clock can show: a chirp's hop, the done celebration, or a bot looking at
    /// the pointer.
    private var lively: Bool {
        _ = dock.settleTick
        return dock.bots.contains { dock.finishedAt[$0.id] != nil }
            || dock.lastChirp.map { dock.now().timeIntervalSince($0.at) < 3 } == true
    }

    /// The shelf's glass (`glass: true`, drawn when the layout or pointer changes) or its tiles (on the clock).
    private func shelf(time: Double, glass: Bool) -> some View {
        let box = layout.shelfInPanel
        let count = dock.bots.count + 2
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
                DockShelf(style: settings.style, shape: shape, accent: accent)
                    .frame(width: box.width, height: box.height + total)
                    .position(x: box.midX, y: box.midY)
                if settings.separators, settings.style != .minimal {
                    Rectangle().fill(Color.primary.opacity(0.22)).frame(width: box.width - layout.padding * 3, height: 1)
                        .position(x: box.midX, y: separatorY)
                }
            } else {
                ForEach(Array(dock.bots.enumerated()), id: \.element.id) { index, bot in
                    let point = center(index)
                    let tile = layout.size * scales[index]
                    characterTile(bot, index: index, size: tile, time: time, center: point)
                        .position(x: point.x, y: point.y + (drag?.id == bot.id ? drag!.offset : 0))
                        .zIndex(drag?.id == bot.id ? 2 : 1)
                    if settings.indicator == .dot, dock.running(bot.id) || dock.needsYou(bot.id) {
                        Circle().fill(Color.primary.opacity(0.75)).frame(width: 4, height: 4)
                            .position(x: right ? box.maxX - layout.padding / 2 : box.minX + layout.padding / 2, y: point.y)
                            .accessibilityHidden(true)
                    }
                }
                plusTile(size: layout.size * scales[count - 2]).position(center(count - 2))
                togetherTile(size: layout.size * scales[count - 1]).position(center(count - 1))
                if dock.bots.count == 1, settings.labels != .off, dock.surface == nil {
                    // A first dock: KemoSabe, and an invitation to add a bot.
                    let index = count - 2
                    nameLabel(index: index, title: "Add a bot").position(labelPosition(center(index), tile: layout.size))
                } else if settings.labels != .off, let index = hoveredIndex(box: box), index < count {
                    nameLabel(index: index).position(labelPosition(center(index), tile: layout.size * scales[index]))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
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
        let count = dock.bots.count + 2
        return (0..<count).min { abs(box.minY + layout.tileOffset($0) - point.y) < abs(box.minY + layout.tileOffset($1) - point.y) }
            .flatMap { abs(box.minY + layout.tileOffset($0) - point.y) < layout.size * 0.7 ? $0 : nil }
    }

    private func characterTile(_ bot: BotSpec, index: Int, size: CGFloat, time: Double, center: CGPoint) -> some View {
        let state = dock.characterState(bot.id, tucked: !revealed)
        let local: Double = {
            switch state {
            case .chirping: return dock.lastChirp.map { dock.now().timeIntervalSince($0.at) } ?? 0
            case .done: return dock.finishedAt[bot.id].map { dock.now().timeIntervalSince($0) } ?? 0
            default: return time
            }
        }()
        // It looks at the pointer; when a neighbor chirps, it glances that way.
        var gaze: CGPoint?
        if settings.animation == .lively, let point = pointerNow, hoveredIndex(box: layout.shelfInPanel) != nil {
            let dx = point.x - center.x, dy = point.y - center.y, length = max(1, hypot(dx, dy))
            gaze = CGPoint(x: dx / length, y: dy / length)
        }
        if let chirp = dock.lastChirp, chirp.bot != bot.id, dock.now().timeIntervalSince(chirp.at) < 1.6,
           let other = dock.bots.firstIndex(where: { $0.id == chirp.bot }) {
            gaze = CGPoint(x: right ? -0.3 : 0.3, y: other < index ? -1 : 1)
        }
        return DockTile(bot: bot, state: state, size: size, time: time, local: local, level: settings.animation, reduceMotion: reduceMotion,
                        active: active && fixedTime == nil && revealed, gaze: gaze,
                        selected: dock.surface == .bot(bot.id), engineMark: settings.engineMark,
                        hovered: hoveredBot == bot.id, pressed: pressed == bot.id,
                        ringIndicator: settings.indicator == .ring && (dock.running(bot.id) || dock.needsYou(bot.id)), accent: accent,
                        reaction: dock.reaction[bot.id], cue: dock.cues[bot.id])
            .onTapGesture(count: 2) { dock.react(.giggle, on: bot.id) }
            .onTapGesture { dock.toggle(.bot(bot.id)) }
            .onLongPressGesture(minimumDuration: 0.35, perform: {}, onPressingChanged: { pressing in
                pressed = pressing ? bot.id : nil
                if pressing { dock.react(.poke, on: bot.id) }
            })
            .simultaneousGesture(DragGesture(minimumDistance: 6).onChanged { value in
                guard !bot.isKemoSabe else { return }
                drag = (bot.id, value.translation.height)
            }.onEnded { value in
                guard !bot.isKemoSabe else { return }
                let steps = Int((value.translation.height / (layout.size + layout.spacing)).rounded())
                withAnimation(reduceMotion ? nil : .spring(duration: 0.3)) {
                    drag = nil
                    if steps != 0 { dock.move(bot.id, to: index + steps) }
                }
            })
            .accessibilityAction { dock.toggle(.bot(bot.id)) }
    }

    private func plusTile(size: CGFloat) -> some View {
        Button { dock.toggle(.edit(nil)) } label: {
            Image(systemName: "plus").font(.system(size: size * 0.34, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: size * 0.82, height: size * 0.82)
                .background(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.25), style: .init(lineWidth: 1, dash: [4, 3])))
                .frame(width: size, height: size).contentShape(Rectangle())
        }
        .buttonStyle(.plain).help("Add a bot").accessibilityLabel("Add a bot").accessibilityIdentifier("dockAddBot")
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
        let title = title ?? (index < dock.bots.count ? dock.bots[index].name : index == dock.bots.count ? "Add a bot" : "Together")
        return Text(title).font(.system(size: 13, weight: .medium)).lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background { if settings.labels == .glass { DockGlass(shape: Capsule()) } }
            .shadow(color: settings.labels == .plain ? .black.opacity(0.35) : .clear, radius: 2, y: 1)
            .frame(width: DockLayout.labelSpace - 16, alignment: right ? .trailing : .leading)
            .allowsHitTesting(false)
    }
}

/// The dock's right-click menu, like the Dock's own: where it sits, hiding, magnification, then Add a Bot
/// and Settings (the rest of the dock's look is in Settings, Dock).
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
        Button("Add a Bot…") { dock.toggle(.edit(nil)) }
        if let openSettings = dock.openSettings {
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
