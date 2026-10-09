import SwiftUI
import TsukumoCore

// KemoSabe's two looks, the owner's pick (`BotLook.figure`, synced with its palette): its cloud (`CompanionArt`), the
// standard look, and the two-tone figure (October 7, 2026): a rounded face split down the middle, a dark half and a
// light half (blue and white in its Classic palette), simple eyes and a smile across both halves, a small body, and a
// waving hand, lit softly like clay. The figure is drawn here in code (one Canvas, crisp at any size), in every state
// the cloud has: idle, thinking, answering, needs you, listening, and sleeping. A companion palette recolors either
// look (for the figure, its accent the dark half, its body the light one).

/// What a bot's tile acts out (the dock and the chat's avatars).
public enum BotState: String, CaseIterable, Sendable {
    /// At rest.
    case idle
    /// A coding agent at work.
    case working
    /// A turn started, no words yet.
    case thinking
    /// Words streaming in, or its reply read aloud.
    case talking
    /// It spoke up on its own.
    case chirping
    /// Waiting on the owner.
    case needsYou
    /// Just finished.
    case done
    /// Tucked away, or at night.
    case sleeping

    /// The word for a tile's accessibility value and the bubble's header.
    public var label: String {
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

/// What KemoSabe acts out: the states the cloud had, each with its own pose.
public enum KemoSabeMood: String, CaseIterable, Sendable {
    /// Resting, waving now and then.
    case idle
    /// Reading on this device for someone (the cloud at its computer).
    case thinking
    /// Its words coming in, or read aloud.
    case answering
    /// A question or a caller waits on the owner's OK.
    case needsYou
    /// The owner is talking to it.
    case listening
    /// Tucked away, or at night.
    case sleeping

    /// KemoSabe's mood for a tile's state (listening wins).
    public init(_ state: BotState, listening: Bool = false) {
        if listening { self = .listening; return }
        switch state {
        case .idle, .done, .chirping: self = .idle
        case .working, .thinking: self = .thinking
        case .talking: self = .answering
        case .needsYou: self = .needsYou
        case .sleeping: self = .sleeping
        }
    }

    /// For VoiceOver.
    var words: String {
        switch self {
        case .idle: ""
        case .thinking: "looking on this device"
        case .answering: "answering"
        case .needsYou: "needs you"
        case .listening: "listening"
        case .sleeping: "asleep"
        }
    }
}

// MARK: The figure

/// KemoSabe in a look (its owner's, from `init(bot:)`), palette, and mood. `animated` plays the
/// mood's motion on a 30 fps clock (never under Reduce Motion); otherwise it's one still pose.
public struct KemoSabeFigure: View {
    public var mood: KemoSabeMood
    public var shadow: Bool
    public var palette: BotPalette
    public var animated: Bool
    public var look: KemoSabeLook
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(palette: BotPalette = BotPalette.named(KemoSabeLook.standard.defaultPalette), mood: KemoSabeMood = .idle, animated: Bool = false,
                shadow: Bool = true, look: KemoSabeLook = .standard) {
        self.palette = palette; self.mood = mood; self.animated = animated; self.shadow = shadow; self.look = look
    }
    /// KemoSabe as `bot` has it (its companion palette).
    public init(bot: BotSpec, mood: KemoSabeMood = .idle, animated: Bool = false, shadow: Bool = true) {
        self.init(palette: bot.kemoSabePalette, mood: mood, animated: animated, shadow: shadow, look: bot.kemoSabeLook)
    }
    /// Resting, or reading on this device (`searching`).
    public init(bot: BotSpec, searching: Bool, shadow: Bool = true) {
        self.init(bot: bot, mood: searching ? .thinking : .idle, shadow: shadow)
    }

    public var body: some View {
        Group {
            switch look {
            case .finder:
                if animated && !reduceMotion {
                    TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                        TwoToneKemoSabe(palette: palette, mood: mood, time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600),
                                        still: false, shadow: shadow)
                    }
                } else {
                    TwoToneKemoSabe(palette: palette, mood: mood, time: 0, still: true, shadow: shadow)
                }
            case .cloud:
                CloudKemoSabe(palette: palette, searching: mood == .thinking, shadow: shadow)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(mood.words.isEmpty ? "KemoSabe" : "KemoSabe, " + mood.words)
    }
}

/// KemoSabe's face alone, filling a circle's worth of space (avatars, chips, small tiles).
public struct KemoSabeFace: View {
    public var palette: BotPalette
    public var look: KemoSabeLook
    public init(palette: BotPalette, look: KemoSabeLook = .standard) { self.palette = palette; self.look = look }
    public var body: some View {
        switch look {
        case .finder:
            Canvas { context, size in
                let side = min(size.width, size.height)
                TwoTonePainter(palette: palette, pose: TwoTonePose(.idle, time: 0, still: true), side: side, shadow: false, faceOnly: true)
                    .paint(&context, origin: CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2))
            }
            .accessibilityHidden(true)
        case .cloud:
            CompanionArt.image(palette: palette, small: true).resizable().interpolation(.high).scaledToFit()
                .scaleEffect(1.2)
                .accessibilityHidden(true)
        }
    }
}

/// The cloud KemoSabe had before (the switch's other side): resting, or at its computer while it reads.
struct CloudKemoSabe: View {
    let palette: BotPalette
    let searching: Bool
    let shadow: Bool
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if shadow {
                    Ellipse().fill(.black.opacity(0.18)).frame(width: side * 0.47, height: side * 0.055)
                        .blur(radius: side * 0.024).offset(y: side * 0.414)
                }
                CompanionArt.image(searching: searching, palette: palette, small: side <= 110).resizable().interpolation(.high).scaledToFit()
                    .frame(width: side, height: side)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// The two-tone KemoSabe at one moment.
struct TwoToneKemoSabe: View {
    let palette: BotPalette
    let mood: KemoSabeMood
    let time: Double
    let still: Bool
    let shadow: Bool
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            TwoTonePainter(palette: palette, pose: TwoTonePose(mood, time: time, still: still), side: side, shadow: shadow)
                .paint(&context, origin: CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2))
        }
    }
}

// MARK: Poses

/// One moment of the two-tone KemoSabe, in fractions of its size (and radians).
public struct TwoTonePose: Equatable, Sendable {
    public enum Mouth: Equatable, Sendable { case smile, open(Double), round, flat, small }
    /// Lift off the ground.
    public var bob: Double = 0
    public var tilt: Double = 0
    /// The waving arm: 0 hangs down, about 2.4 is up beside its face.
    public var arm: Double = 0.4
    /// 0 open, 1 shut.
    public var blink: Double = 0
    /// Taller eyes when it's alert.
    public var eyes: Double = 1
    /// Where the eyes look, each -1…1.
    public var gaze: CGPoint = .zero
    public var mouth: Mouth = .smile
    /// The thinking dots' phase, the z's drift, and the listening arcs' phase, when they show.
    public var dots: Double?
    public var zzz: Double?
    public var waves: Double?

    public init() {}

    /// The pose for `mood` at `time` seconds; `still` (Reduce Motion, a still picture) is always the same pose.
    public init(_ mood: KemoSabeMood, time: Double, still: Bool) {
        let t = still ? 0 : time
        if !still {
            bob = 0.006 * sin(t * 1.8)
            let blinkPhase = t.truncatingRemainder(dividingBy: 4.3)
            blink = blinkPhase < 0.26 ? sin(blinkPhase / 0.26 * .pi) : 0
        }
        switch mood {
        case .idle:
            // A friendly wave: up beside its face, rocking.
            arm = 2.15 + (still ? 0 : 0.22 * sin(t * 5.2))
        case .thinking:
            arm = 0.9
            gaze = CGPoint(x: 0.6, y: -0.8)
            mouth = .flat
            dots = still ? 0.35 : (t * 1.6).truncatingRemainder(dividingBy: 1)
            tilt = still ? 0.04 : 0.04 * sin(t * 0.8)
        case .answering:
            mouth = .open(still ? 0.6 : 0.25 + 0.75 * abs(sin(t * 10)) * abs(sin(t * 3.3)))
            arm = 1.5 + (still ? 0 : 0.35 * sin(t * 3))
            bob += still ? 0 : 0.01 * abs(sin(t * 5))
        case .needsYou:
            arm = 2.35
            eyes = 1.22
            mouth = .round
            bob = still ? 0 : 0.03 * abs(sin(t * 3.2))
        case .listening:
            arm = 1.95
            eyes = 1.12
            gaze = CGPoint(x: -0.2, y: 0)
            mouth = .small
            waves = still ? 0.5 : (t * 1.4).truncatingRemainder(dividingBy: 1)
        case .sleeping:
            blink = 1
            arm = 0.2
            mouth = .small
            tilt = 0.07
            bob = 0
            zzz = still ? 0.5 : (t * 0.45).truncatingRemainder(dividingBy: 1)
        }
    }
}

// MARK: Painting

/// Paints the two-tone KemoSabe into a Canvas, in a unit square scaled to `side`.
public struct TwoTonePainter {
    let palette: BotPalette
    let pose: TwoTonePose
    let side: CGFloat
    var shadow = true
    /// Only its face, filling the square (avatars).
    var faceOnly = false

    /// The dark half and the light half.
    var dark: RGB { RGB(hex: palette.accent) }
    var light: RGB { RGB(hex: palette.body) }
    /// The ink its eyes and smile are drawn in on a half: dark on a light half, light on a dark one.
    static let ink = RGB(hex: "18233A")
    static func features(on half: RGB) -> RGB { half.luminance < 0.16 ? RGB(hex: "F6F8FB") : ink }

    // The head's box, in the unit square: round, a little wider than tall, like a vinyl toy's.
    static let head = CGRect(x: 0.15, y: 0.07, width: 0.66, height: 0.58)
    /// Where the halves meet below the face: the chin's end of the line down it, straight down the body.
    static var split: CGFloat { head.minX + head.width * 0.555 }

    private func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * side, y: y * side) }
    private func rect(_ r: CGRect) -> CGRect { CGRect(x: r.minX * side, y: r.minY * side, width: r.width * side, height: r.height * side) }
    /// A point in the head's own unit box.
    private func h(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
        let box = Self.head
        return pt(box.minX + box.width * x, box.minY + box.height * y)
    }

    public func paint(_ context: inout GraphicsContext, origin: CGPoint) {
        context.translateBy(x: origin.x, y: origin.y)
        if faceOnly {
            // Fit the head to the square.
            let box = Self.head
            let scale = 0.96 / max(box.width, box.height)
            context.translateBy(x: side * 0.5, y: side * 0.5)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -side * box.midX, y: -side * box.midY)
            drawHead(&context)
            return
        }
        if shadow {
            context.fill(Path(ellipseIn: rect(CGRect(x: 0.27, y: 0.895, width: 0.44, height: 0.045))),
                         with: .color(.black.opacity(0.16 * (1 - pose.bob * 6))))
        }
        context.translateBy(x: 0, y: -CGFloat(pose.bob) * side)
        // Lean a little around its feet.
        context.translateBy(x: side * 0.48, y: side * 0.9)
        context.rotate(by: .radians(pose.tilt))
        context.translateBy(x: -side * 0.48, y: -side * 0.9)

        drawBody(&context)
        drawLeftArm(&context)
        // The head's soft shadow on the body.
        context.fill(Path(ellipseIn: rect(CGRect(x: 0.33, y: 0.59, width: 0.31, height: 0.06))), with: .color(.black.opacity(0.13)))
        drawHead(&context)
        drawRightArm(&context)
        drawExtras(&context)
    }

    // MARK: Parts

    private var headPath: Path { Path(ellipseIn: rect(Self.head)) }
    /// Everything left of the line down its face: a profile's gentle nose, as the two halves meet.
    private var leftOfSplit: Path {
        var path = Path()
        path.move(to: h(-0.1, -0.1))
        path.addLine(to: h(0.53, -0.1))
        path.addLine(to: h(0.53, 0))
        path.addCurve(to: h(0.475, 0.4), control1: h(0.52, 0.16), control2: h(0.485, 0.3))
        path.addCurve(to: h(0.43, 0.5), control1: h(0.465, 0.45), control2: h(0.425, 0.47))
        path.addCurve(to: h(0.505, 0.58), control1: h(0.44, 0.54), control2: h(0.485, 0.55))
        path.addCurve(to: h(0.555, 1.0), control1: h(0.54, 0.68), control2: h(0.555, 0.86))
        path.addLine(to: h(0.555, 1.1))
        path.addLine(to: h(-0.1, 1.1))
        path.closeSubpath()
        return path
    }

    /// A clay fill: lighter toward the light at the top left, a little darker at the bottom right.
    private func clay(_ context: inout GraphicsContext, _ path: Path, color: RGB, in box: CGRect) {
        let r = rect(box)
        context.fill(path, with: .linearGradient(Gradient(colors: [color.mix(.white, 0.2).color, color.color, color.mix(.black, 0.16).color]),
                                                 startPoint: CGPoint(x: r.minX, y: r.minY), endPoint: CGPoint(x: r.maxX, y: r.maxY)))
    }
    /// Soft light on a rounded part: a glow toward the top left and shade toward the bottom, with no edges.
    private func shade(_ context: inout GraphicsContext, _ path: Path, in box: CGRect) {
        let r = rect(box)
        context.drawLayer { layer in
            layer.clip(to: path)
            layer.fill(path, with: .radialGradient(Gradient(colors: [.white.opacity(0.32), .white.opacity(0.06), .clear]),
                                                   center: CGPoint(x: r.minX + r.width * 0.3, y: r.minY + r.height * 0.22),
                                                   startRadius: 0, endRadius: max(r.width, r.height) * 0.55))
            layer.fill(path, with: .linearGradient(Gradient(colors: [.clear, .black.opacity(0.14)]),
                                                   startPoint: CGPoint(x: r.midX, y: r.minY + r.height * 0.55), endPoint: CGPoint(x: r.midX, y: r.maxY)))
        }
    }
    private var outline: Color { dark.mix(.black, 0.4).color.opacity(0.22) }

    private func drawHead(_ context: inout GraphicsContext) {
        let head = headPath
        let box = Self.head
        // The light half, then the dark half over it.
        clay(&context, head, color: light, in: box)
        context.drawLayer { layer in
            layer.clip(to: head)
            layer.clip(to: leftOfSplit)
            clay(&layer, head, color: dark, in: box)
        }
        shade(&context, head, in: box)
        context.stroke(head, with: .color(outline), lineWidth: max(0.6, 0.006 * side))
        drawFeatures(&context)
    }

    /// Its eyes and mouth, in each half's own ink.
    private func drawFeatures(_ context: inout GraphicsContext) {
        let head = headPath
        for left in [true, false] {
            let ink = Self.features(on: left ? dark : light).color
            context.drawLayer { layer in
                layer.clip(to: head)
                if left { layer.clip(to: leftOfSplit) } else { layer.clip(to: leftOfSplit, options: .inverse) }
                for x in [0.33, 0.69] as [CGFloat] { eye(&layer, at: h(x + CGFloat(pose.gaze.x) * 0.03, 0.43 + CGFloat(pose.gaze.y) * 0.04), ink: ink) }
                mouth(&layer, ink: ink)
            }
        }
    }

    private func eye(_ context: inout GraphicsContext, at center: CGPoint, ink: Color) {
        let width = 0.046 * side, full = 0.082 * side * CGFloat(pose.eyes)
        if pose.blink >= 0.95 {
            // Closed: a little downward curve.
            var path = Path()
            path.move(to: CGPoint(x: center.x - width * 0.9, y: center.y))
            path.addQuadCurve(to: CGPoint(x: center.x + width * 0.9, y: center.y), control: CGPoint(x: center.x, y: center.y + width * 0.9))
            context.stroke(path, with: .color(ink), style: StrokeStyle(lineWidth: 0.02 * side, lineCap: .round))
            return
        }
        let height = max(width * 0.35, full * CGFloat(1 - 0.88 * pose.blink))
        context.fill(Path(ellipseIn: CGRect(x: center.x - width / 2, y: center.y - height / 2, width: width, height: height)), with: .color(ink))
        // A catchlight.
        if pose.blink < 0.5 {
            context.fill(Path(ellipseIn: CGRect(x: center.x - width * 0.18, y: center.y - height * 0.36, width: width * 0.3, height: width * 0.3)),
                         with: .color(.white.opacity(0.75)))
        }
    }

    private func mouth(_ context: inout GraphicsContext, ink: Color) {
        let line = StrokeStyle(lineWidth: 0.022 * side, lineCap: .round)
        switch pose.mouth {
        case .smile:
            var path = Path()
            path.move(to: h(0.42, 0.66))
            path.addQuadCurve(to: h(0.62, 0.66), control: h(0.52, 0.75))
            context.stroke(path, with: .color(ink), style: line)
        case .open(let amount):
            var path = Path()
            path.move(to: h(0.43, 0.65))
            path.addQuadCurve(to: h(0.61, 0.65), control: h(0.52, 0.68))
            path.addQuadCurve(to: h(0.43, 0.65), control: h(0.52, 0.68 + 0.17 * CGFloat(amount)))
            path.closeSubpath()
            context.fill(path, with: .color(ink))
        case .round:
            context.fill(Path(ellipseIn: CGRect(origin: h(0.49, 0.65), size: CGSize(width: 0.045 * side, height: 0.055 * side))), with: .color(ink))
        case .flat:
            var path = Path()
            path.move(to: h(0.45, 0.69))
            path.addQuadCurve(to: h(0.6, 0.68), control: h(0.52, 0.7))
            context.stroke(path, with: .color(ink), style: line)
        case .small:
            var path = Path()
            path.move(to: h(0.46, 0.68))
            path.addQuadCurve(to: h(0.58, 0.68), control: h(0.52, 0.73))
            context.stroke(path, with: .color(ink), style: line)
        }
    }

    private func drawBody(_ context: inout GraphicsContext) {
        // Short legs and rounded feet, each in its half's color.
        for (x, color) in [(0.425 as CGFloat, dark), (0.585 as CGFloat, light)] {
            let leg = CGRect(x: x - 0.04, y: 0.76, width: 0.08, height: 0.12)
            let legPath = Path(roundedRect: rect(leg), cornerRadius: 0.04 * side, style: .continuous)
            clay(&context, legPath, color: color, in: leg)
            shade(&context, legPath, in: leg)
            let foot = CGRect(x: x - 0.055 + (x < Self.split ? -0.012 : 0.012), y: 0.845, width: 0.11, height: 0.055)
            let footPath = Path(ellipseIn: rect(foot))
            clay(&context, footPath, color: color, in: foot)
            shade(&context, footPath, in: foot)
            context.stroke(footPath, with: .color(outline), lineWidth: max(0.5, 0.005 * side))
        }
        // A plump body, wider at the bottom, split in line with the chin.
        let box = CGRect(x: 0.32, y: 0.54, width: 0.34, height: 0.29)
        let r = rect(box)
        var body = Path()
        body.move(to: CGPoint(x: r.midX, y: r.minY))
        body.addCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * 0.62), control1: CGPoint(x: r.maxX - r.width * 0.12, y: r.minY),
                      control2: CGPoint(x: r.maxX, y: r.minY + r.height * 0.3))
        body.addCurve(to: CGPoint(x: r.midX, y: r.maxY), control1: CGPoint(x: r.maxX, y: r.maxY - r.height * 0.06), control2: CGPoint(x: r.maxX - r.width * 0.2, y: r.maxY))
        body.addCurve(to: CGPoint(x: r.minX, y: r.minY + r.height * 0.62), control1: CGPoint(x: r.minX + r.width * 0.2, y: r.maxY),
                      control2: CGPoint(x: r.minX, y: r.maxY - r.height * 0.06))
        body.addCurve(to: CGPoint(x: r.midX, y: r.minY), control1: CGPoint(x: r.minX, y: r.minY + r.height * 0.3), control2: CGPoint(x: r.minX + r.width * 0.12, y: r.minY))
        body.closeSubpath()
        clay(&context, body, color: light, in: box)
        context.drawLayer { layer in
            layer.clip(to: body)
            layer.clip(to: Path(rect(CGRect(x: 0, y: 0, width: Self.split, height: 1))))
            clay(&layer, body, color: dark, in: box)
        }
        shade(&context, body, in: box)
        context.stroke(body, with: .color(outline), lineWidth: max(0.5, 0.006 * side))
    }

    /// A stubby arm, round at both ends, and a mitten hand.
    private func arm(_ context: inout GraphicsContext, shoulder: CGPoint, angle: Double, length: CGFloat, color: RGB, hand: RGB) {
        let tip = CGPoint(x: shoulder.x + length * CGFloat(sin(angle)), y: shoulder.y + length * CGFloat(cos(angle)))
        var path = Path()
        path.move(to: pt(shoulder.x, shoulder.y))
        path.addLine(to: pt(tip.x, tip.y))
        context.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: 0.094 * side, lineCap: .round))
        context.stroke(path, with: .color(color.color), style: StrokeStyle(lineWidth: 0.084 * side, lineCap: .round))
        context.stroke(path, with: .color(.white.opacity(0.16)), style: StrokeStyle(lineWidth: 0.03 * side, lineCap: .round))
        let r: CGFloat = 0.056
        let mitten = CGRect(x: tip.x - r, y: tip.y - r, width: r * 2, height: r * 2)
        let mittenPath = Path(ellipseIn: rect(mitten))
        clay(&context, mittenPath, color: hand, in: mitten)
        shade(&context, mittenPath, in: mitten)
        context.stroke(mittenPath, with: .color(outline), lineWidth: max(0.5, 0.006 * side))
    }

    private func drawLeftArm(_ context: inout GraphicsContext) {
        // At its side.
        arm(&context, shoulder: CGPoint(x: 0.35, y: 0.64), angle: -0.5, length: 0.1, color: dark, hand: dark)
    }
    private func drawRightArm(_ context: inout GraphicsContext) {
        // The arm that waves, with a hand in the dark half's color.
        let length: CGFloat = 0.15
        arm(&context, shoulder: CGPoint(x: 0.63, y: 0.64), angle: pose.arm, length: length, color: light, hand: dark)
        // Wave lines beside the hand while it waves.
        if pose.arm > 2, pose.mouth == .smile {
            let tip = CGPoint(x: 0.63 + length * CGFloat(sin(pose.arm)), y: 0.64 + length * CGFloat(cos(pose.arm)))
            for (index, offset) in [0.0, 0.035].enumerated() {
                var path = Path()
                let base = CGPoint(x: tip.x + 0.075 + offset, y: tip.y - 0.035 - offset * 0.4)
                path.move(to: pt(base.x, base.y))
                path.addQuadCurve(to: pt(base.x + 0.02, base.y + 0.07), control: pt(base.x + 0.035, base.y + 0.03))
                context.stroke(path, with: .color(dark.color.opacity(index == 0 ? 0.5 : 0.3)), style: StrokeStyle(lineWidth: 0.012 * side, lineCap: .round))
            }
        }
    }

    private func drawExtras(_ context: inout GraphicsContext) {
        let accent = dark.color
        if let phase = pose.dots {
            // Thinking: three dots rising beside its head, one lit at a time.
            for index in 0..<3 {
                let lit = Int(phase * 3) % 3 == index
                let x = 0.8 + CGFloat(index) * 0.055, y = 0.17 - CGFloat(index) * 0.045
                let r = 0.022 + CGFloat(index) * 0.006
                context.fill(Path(ellipseIn: rect(CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))), with: .color(accent.opacity(lit ? 0.95 : 0.4)))
            }
        }
        if let phase = pose.zzz {
            for index in 0..<2 {
                let drift = (phase + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                let size = (0.07 + 0.03 * CGFloat(index)) * side
                let text = Text("z").font(.system(size: size, weight: .heavy, design: .rounded)).foregroundStyle(accent.opacity(0.85 * (1 - drift * 0.6)))
                context.draw(text, at: pt(0.8 + CGFloat(index) * 0.07 + CGFloat(drift) * 0.03, 0.2 - CGFloat(index) * 0.08 - CGFloat(drift) * 0.06))
            }
        }
        if let phase = pose.waves {
            // Listening: sound arcs coming in toward its face.
            for index in 0..<3 {
                let radius = (0.06 + 0.045 * CGFloat(index)) * side
                var path = Path()
                path.addArc(center: pt(0.8, 0.36), radius: radius, startAngle: .degrees(-40), endAngle: .degrees(40), clockwise: false)
                let alpha = 0.25 + 0.6 * (1 - abs(Double(index) / 2 - phase))
                context.stroke(path, with: .color(accent.opacity(min(1, max(0.15, alpha)))), style: StrokeStyle(lineWidth: 0.016 * side, lineCap: .round))
            }
        }
    }
}
