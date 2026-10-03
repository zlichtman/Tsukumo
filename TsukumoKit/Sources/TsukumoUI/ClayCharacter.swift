import SwiftUI
import TsukumoCore

// A bot's clay character, drawn exactly as the Mac dock draws it (ported from `DockCritterArt.swift` and
// `DockCharacters.swift` in the old Mac app's dock, with `BotLook` in place of `DockLook`): a big round head on
// a small body with stubby arms and feet, every part shaded the same way (a key light from the top left,
// a soft rim light, ambient occlusion where parts meet, a specular dab, a gentle ground shadow), glossy
// eyes with catchlights, cheek blush, a topper for its silhouette, and a prop for its job. One Canvas,
// so it stays crisp from 18 to 160 pt. KemoSabe keeps its own companion artwork (`KemoSabeFigure`).

/// What a character is acting out.
public enum ClayState: String, CaseIterable, Sendable {
    /// Breathing, blinking, now and then looking around.
    case idle
    /// Typing on a tiny keyboard.
    case working
    /// A turn started, no words yet: dots orbit over its head.
    case thinking
    /// Words streaming in: its mouth moves.
    case talking
    /// It spoke up on its own: a hop, a wave, a small speech bubble.
    case chirping
    /// Waiting on the owner: a raised hand and a gentle bounce.
    case needsYou
    /// Just finished: a little celebration.
    case done
    /// Tucked away: eyes closed, Zzz.
    case sleeping
}

/// One moment of a character, in fractions of its size (and radians).
public struct ClayPose: Equatable, Sendable {
    public var lift: Double = 0
    /// Positive is wider and shorter.
    public var squash: Double = 0
    public var tilt: Double = 0
    /// Where the pupils point, each -1…1.
    public var gaze: CGPoint = .zero
    /// 0 open, 1 shut.
    public var blink: Double = 0
    /// 0 a closed smile, 1 wide open.
    public var mouth: Double = 0
    /// Arms: 0 down, about 2.6 straight up.
    public var leftArm: Double = 0.25
    public var rightArm: Double = 0.25
    public var keyboard = false
    public var keyPress = 0
    public var dots = 0
    public var dotsAngle: Double = 0
    public var zzz: Double = 0
    public var happy = false
    public var sleepy = false
    public var confetti: Double = 0
    public var bubble: Double = 0
    public var wide: Double = 0
    public init() {}
}

public enum ClayMotion {
    /// The moment a still pose represents: settled, with the state's gesture showing.
    public static let stillMoment = 1.4

    /// The pose for `state` at `time` (seconds on the clock) and `local` (seconds since the state began).
    /// Still (Reduce Motion) always returns the same pose for a state.
    public static func pose(_ state: ClayState, time: Double, local: Double = stillMoment, still: Bool, seed: Double = 0) -> ClayPose {
        let t = still ? 0 : time + seed * 3.7
        let l = still ? stillMoment : local
        var pose = ClayPose()
        if !still {
            pose.squash = 0.02 * sin(t * 1.9)
            let blinkPhase = t.truncatingRemainder(dividingBy: 3.9 + seed)
            pose.blink = blinkPhase < 0.3 ? sin(blinkPhase / 0.3 * .pi) : 0
        }
        switch state {
        case .idle:
            if !still {
                let cycle = (t * 0.23).truncatingRemainder(dividingBy: 2)
                if cycle > 1.55 { pose.gaze = CGPoint(x: sin(t * 2.2) * 0.9, y: -0.2) }
                pose.tilt = 0.03 * sin(t * 0.8)
            }
        case .working:
            pose.keyboard = true
            pose.gaze = CGPoint(x: 0, y: 0.7)
            let tap = still ? 0 : Int(t * 9)
            pose.keyPress = tap % 4
            pose.leftArm = 0.9 + (tap % 2 == 0 ? 0.18 : 0)
            pose.rightArm = 0.9 + (tap % 2 == 1 ? 0.18 : 0)
            pose.lift = still ? 0 : 0.008 * abs(sin(t * 9))
        case .thinking:
            pose.dots = 3
            pose.dotsAngle = still ? 0.6 : t * 2.4
            pose.gaze = CGPoint(x: still ? 0.35 : 0.5 * sin(t * 0.9), y: -0.8)
            pose.rightArm = 1.35
            pose.tilt = still ? 0.06 : 0.06 * sin(t * 0.7)
        case .talking:
            pose.mouth = still ? 0.55 : 0.25 + 0.75 * abs(sin(t * 11)) * abs(sin(t * 3.1))
            pose.lift = still ? 0 : 0.012 * abs(sin(t * 5.5))
            pose.leftArm = still ? 0.6 : 0.45 + 0.3 * sin(t * 3)
        case .chirping:
            let hop = l < 0.5 ? sin(l / 0.5 * .pi) : 0
            pose.lift = still ? 0 : 0.16 * hop
            pose.squash = still ? 0 : (l < 0.08 ? 0.1 : l > 0.45 && l < 0.6 ? 0.08 : 0)
            pose.rightArm = 2.3 + (still ? 0 : 0.35 * sin(l * 14))
            pose.mouth = 0.6
            pose.bubble = still ? 1 : min(1, max(0, (l - 0.15) / 0.25))
            pose.wide = 0.2
        case .needsYou:
            pose.rightArm = 2.6
            pose.lift = still ? 0 : 0.035 * abs(sin(t * 3.2))
            pose.gaze = CGPoint(x: 0, y: -0.15)
            pose.wide = 0.25
            pose.mouth = 0.3
        case .done:
            let burst = min(1, l / 1.2)
            pose.happy = true
            pose.confetti = still ? 0 : (l < 1.4 ? burst : 0)
            if !still && l < 1 {
                pose.lift = 0.12 * max(0, sin(l / 0.5 * .pi))
                pose.leftArm = 2.4; pose.rightArm = 2.4
            } else { pose.leftArm = 0.4; pose.rightArm = 0.4 }
        case .sleeping:
            pose.sleepy = true
            pose.blink = 1
            pose.zzz = still ? 0.5 : (t * 0.45).truncatingRemainder(dividingBy: 1)
            pose.squash = still ? 0.04 : 0.04 + 0.035 * sin(t * 1.1)
            pose.tilt = 0.08
            pose.leftArm = 0.15; pose.rightArm = 0.15
        }
        return pose
    }
}

/// A bot's character. Animated states run on a timeline unless Reduce Motion is on; `.idle` without
/// `animated` is one still picture (what lists and avatars use, so a long list costs nothing).
public struct ClayCharacter: View {
    public let look: BotLook
    public var state: ClayState
    public var animated: Bool
    public var shadow: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(look: BotLook, state: ClayState = .idle, animated: Bool = false, shadow: Bool = true) {
        self.look = look; self.state = state; self.animated = animated; self.shadow = shadow
    }

    public var body: some View {
        if animated && !reduceMotion {
            // A periodic schedule, not `.animation`: macOS stops a display-linked schedule in a panel it
            // reports as hidden, such as a menu-bar panel.
            TimelineView(.periodic(from: .now, by: 1.0 / 30)) { context in
                canvas(ClayMotion.pose(state, time: context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 3600),
                                       local: ClayMotion.stillMoment, still: false))
            }
        } else {
            canvas(ClayMotion.pose(state, time: 0, still: true))
        }
    }

    private func canvas(_ pose: ClayPose) -> some View {
        let look = self.look, shadow = self.shadow
        return Canvas { context, size in
            let side = min(size.width, size.height)
            ClayPainter(look: look, pose: pose, side: side, shadow: shadow)
                .paint(&context, origin: CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2))
        }
        .accessibilityHidden(true)
    }
}

/// Paints a character into a Canvas, in a unit square scaled to `side`.
public struct ClayPainter {
    public let look: BotLook
    public let pose: ClayPose
    public let side: CGFloat
    public var shadow = true

    public init(look: BotLook, pose: ClayPose, side: CGFloat, shadow: Bool = true) {
        self.look = look; self.pose = pose; self.side = side; self.shadow = shadow
    }

    // The palette's colors, with the owner's own body and accent in their place when set.
    private var baseRGB: RGB { RGB(hex: look.bodyHex) }
    private var accentRGB: RGB { RGB(hex: look.accentHex) }
    private var inkRGB: RGB { RGB(hex: look.inkHex) }
    private var base: Color { baseRGB.color }
    private var accent: Color { accentRGB.color }
    private var ink: Color { inkRGB.color }
    private var s: CGFloat { side }
    private func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    private func r(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: x * s, y: y * s, width: w * s, height: h * s) }
    private static func hex(_ value: String) -> Color { RGB(hex: value).color }

    /// The head, by shape (in the unit square).
    var head: CGRect {
        switch look.shape {
        case .bean: r(0.2, 0.08, 0.6, 0.62)
        case .gumdrop: r(0.14, 0.12, 0.72, 0.58)
        case .block: r(0.16, 0.14, 0.68, 0.56)
        case .mochi: r(0.1, 0.22, 0.8, 0.48)
        case .sprout: r(0.17, 0.1, 0.66, 0.6)
        case .pebble: r(0.13, 0.13, 0.74, 0.58)
        }
    }
    private var bodyRect: CGRect { r(0.32, 0.6, 0.36, 0.28) }
    private var hatted: Bool { look.prop == .hardHat }
    private var topper: BotLook.Topper {
        if hatted { return .none }
        if look.prop == .antenna { return .antenna }
        if look.prop == .headset, look.topper == .ears || look.topper == .roundEars { return .none }
        return look.topper
    }

    public func paint(_ context: inout GraphicsContext, origin: CGPoint) {
        context.translateBy(x: origin.x, y: origin.y)
        if shadow {
            let width = (0.52 - pose.lift * 0.6) * s
            context.fill(Ellipse().path(in: CGRect(x: 0.5 * s - width / 2, y: 0.87 * s, width: width, height: 0.07 * s)),
                         with: .radialGradient(Gradient(colors: [.black.opacity(0.26 - pose.lift * 0.5), .black.opacity(0)]),
                                               center: p(0.5, 0.905), startRadius: 0, endRadius: width / 2))
        }
        var body = context
        // Drawn a little smaller than the square, so hops, toppers, and hats stay inside it.
        body.translateBy(x: 0.5 * s, y: 0.9 * s); body.scaleBy(x: 0.84, y: 0.84); body.translateBy(x: -0.5 * s, y: -0.9 * s)
        body.translateBy(x: 0.5 * s, y: 0.9 * s - pose.lift * s)
        body.rotate(by: .radians(pose.tilt))
        body.scaleBy(x: 1 + pose.squash, y: 1 - pose.squash)
        body.translateBy(x: -0.5 * s, y: -0.9 * s)

        backTopper(&body)
        arm(&body, left: true, angle: pose.leftArm)
        arm(&body, left: false, angle: pose.rightArm)
        feet(&body)
        clay(&body, Path(roundedRect: bodyRect, cornerRadius: bodyRect.width * 0.44, style: .continuous), rect: bodyRect, color: baseRGB.mix(accentRGB, 0.08))
        body.fill(Ellipse().path(in: r(0.3, 0.6, 0.4, 0.09)),
                  with: .radialGradient(Gradient(colors: [ink.opacity(0.34), ink.opacity(0)]), center: p(0.5, 0.645), startRadius: 0, endRadius: 0.2 * s))
        clay(&body, headPath, rect: head, color: baseRGB)
        accessory(&body)
        frontTopper(&body)
        face(&body)
        prop(&body)
        if pose.keyboard { keyboard(&body) }
        overlays(&body)
    }

    // MARK: Clay

    private func clay(_ context: inout GraphicsContext, _ path: Path, rect: CGRect, color: RGB, specular: Bool = true) {
        let reach = max(rect.width, rect.height)
        context.fill(path, with: .radialGradient(Gradient(stops: [
            .init(color: color.mix(.white, 0.5).color, location: 0),
            .init(color: color.color, location: 0.42),
            .init(color: color.mix(inkRGB, 0.32).color, location: 1)
        ]), center: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.minY + rect.height * 0.26), startRadius: 0, endRadius: reach * 0.95))
        var rim = context
        rim.clip(to: path)
        rim.stroke(path, with: .linearGradient(Gradient(colors: [.white.opacity(0), .white.opacity(0), .white.opacity(0.5)]),
                                                startPoint: CGPoint(x: rect.minX, y: rect.minY), endPoint: CGPoint(x: rect.maxX, y: rect.maxY)),
                   lineWidth: max(1, s * 0.045))
        context.stroke(path, with: .color(color.mix(inkRGB, 0.6).color.opacity(0.38)), lineWidth: max(0.6, s * 0.011))
        if specular {
            var dab = context
            let spot = CGRect(x: rect.minX + rect.width * 0.18, y: rect.minY + rect.height * 0.1, width: rect.width * 0.26, height: rect.height * 0.14)
            dab.translateBy(x: spot.midX, y: spot.midY); dab.rotate(by: .degrees(-24)); dab.translateBy(x: -spot.midX, y: -spot.midY)
            dab.fill(Ellipse().path(in: spot), with: .radialGradient(Gradient(colors: [.white.opacity(0.85), .white.opacity(0)]),
                                                                       center: CGPoint(x: spot.midX, y: spot.midY), startRadius: 0, endRadius: spot.width / 2))
        }
    }
    private func clay(_ context: inout GraphicsContext, _ path: Path, rect: CGRect, hex: String, specular: Bool = true) {
        clay(&context, path, rect: rect, color: RGB(hex: hex), specular: specular)
    }

    private var headPath: Path {
        let h = head
        func q(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: h.minX + h.width * x, y: h.minY + h.height * y) }
        var path = Path()
        switch look.shape {
        case .bean: path.addRoundedRect(in: h, cornerSize: CGSize(width: h.width * 0.48, height: h.width * 0.48), style: .continuous)
        case .block: path.addRoundedRect(in: h, cornerSize: CGSize(width: h.width * 0.3, height: h.width * 0.3), style: .continuous)
        case .sprout: path.addEllipse(in: h)
        case .gumdrop:
            path.move(to: q(0.02, 0.86))
            path.addCurve(to: q(0.5, 0), control1: q(-0.02, 0.38), control2: q(0.18, 0))
            path.addCurve(to: q(0.98, 0.86), control1: q(0.82, 0), control2: q(1.02, 0.38))
            path.addCurve(to: q(0.02, 0.86), control1: q(0.9, 1.04), control2: q(0.1, 1.04))
        case .mochi:
            path.move(to: q(0, 0.7))
            path.addCurve(to: q(0.5, 0), control1: q(-0.01, 0.2), control2: q(0.22, 0))
            path.addCurve(to: q(1, 0.7), control1: q(0.78, 0), control2: q(1.01, 0.2))
            path.addCurve(to: q(0, 0.7), control1: q(0.98, 1.06), control2: q(0.02, 1.06))
        case .pebble:
            path.move(to: q(0.03, 0.58))
            path.addCurve(to: q(0.44, 0.01), control1: q(-0.02, 0.24), control2: q(0.18, 0.0))
            path.addCurve(to: q(0.99, 0.46), control1: q(0.72, 0.02), control2: q(1.02, 0.14))
            path.addCurve(to: q(0.52, 0.99), control1: q(0.97, 0.84), control2: q(0.8, 1.0))
            path.addCurve(to: q(0.03, 0.58), control1: q(0.2, 0.98), control2: q(0.06, 0.86))
        }
        return path
    }

    // MARK: Limbs

    private func arm(_ context: inout GraphicsContext, left: Bool, angle: Double) {
        let b = bodyRect
        var limb = context
        limb.translateBy(x: left ? b.minX - 0.005 * s : b.maxX + 0.005 * s, y: b.minY + 0.1 * s)
        limb.rotate(by: .radians(left ? angle : -angle))
        let rect = CGRect(x: -0.05 * s, y: -0.02 * s, width: 0.1 * s, height: 0.15 * s)
        clay(&limb, Path(roundedRect: rect, cornerRadius: 0.05 * s, style: .continuous), rect: rect, color: baseRGB.mix(accentRGB, 0.12), specular: false)
        if look.prop == .wrench, !left { wrench(&limb) }
        if look.prop == .paintbrush, !left { brush(&limb) }
    }
    private func feet(_ context: inout GraphicsContext) {
        for x in [0.36, 0.52] as [CGFloat] {
            let rect = r(x, 0.84, 0.12, 0.065)
            clay(&context, Ellipse().path(in: rect), rect: rect, color: baseRGB.mix(inkRGB, 0.12), specular: false)
        }
    }

    // MARK: Toppers

    private func backTopper(_ context: inout GraphicsContext) {
        let h = head
        switch topper {
        case .ears:
            for left in [true, false] {
                var ear = Path()
                let x0 = left ? h.minX + h.width * 0.12 : h.maxX - h.width * 0.12
                let tip = CGPoint(x: left ? h.minX - h.width * 0.02 : h.maxX + h.width * 0.02, y: h.minY - h.height * 0.16)
                ear.move(to: CGPoint(x: x0 - h.width * 0.12, y: h.minY + h.height * 0.22))
                ear.addQuadCurve(to: tip, control: CGPoint(x: (x0 + tip.x) / 2 - h.width * 0.08, y: h.minY))
                ear.addQuadCurve(to: CGPoint(x: x0 + h.width * 0.16, y: h.minY + h.height * 0.12), control: CGPoint(x: (x0 + tip.x) / 2 + h.width * 0.12, y: h.minY - h.height * 0.04))
                ear.closeSubpath()
                clay(&context, ear, rect: ear.boundingRect, color: baseRGB, specular: false)
                let inner = ear.boundingRect.insetBy(dx: ear.boundingRect.width * 0.32, dy: ear.boundingRect.height * 0.3)
                context.fill(Ellipse().path(in: inner), with: .color(accent.opacity(0.45)))
            }
        case .roundEars:
            for left in [true, false] {
                let rect = CGRect(x: (left ? h.minX + h.width * 0.02 : h.maxX - h.width * 0.3), y: h.minY - h.height * 0.08, width: h.width * 0.28, height: h.width * 0.28)
                clay(&context, Ellipse().path(in: rect), rect: rect, color: baseRGB, specular: false)
                context.fill(Ellipse().path(in: rect.insetBy(dx: rect.width * 0.26, dy: rect.height * 0.26)), with: .color(accent.opacity(0.4)))
            }
        default: break
        }
    }
    private func frontTopper(_ context: inout GraphicsContext) {
        let h = head, top = topY
        switch topper {
        case .antenna:
            var stem = Path(); stem.move(to: CGPoint(x: h.midX, y: top + 0.01 * s)); stem.addQuadCurve(to: CGPoint(x: h.midX + 0.02 * s, y: top - 0.1 * s), control: CGPoint(x: h.midX - 0.03 * s, y: top - 0.05 * s))
            context.stroke(stem, with: .color(inkRGB.mix(.white, 0.3).color), style: .init(lineWidth: max(1, s * 0.018), lineCap: .round))
            let ball = CGRect(x: h.midX - 0.03 * s, y: top - 0.15 * s, width: 0.1 * s, height: 0.1 * s)
            context.fill(Ellipse().path(in: ball.insetBy(dx: -0.03 * s, dy: -0.03 * s)), with: .radialGradient(Gradient(colors: [accent.opacity(0.35), accent.opacity(0)]), center: CGPoint(x: ball.midX, y: ball.midY), startRadius: 0, endRadius: 0.08 * s))
            clay(&context, Ellipse().path(in: ball), rect: ball, color: accentRGB)
        case .tuft:
            var curl = Path()
            let x = h.midX + 0.02 * s
            curl.move(to: CGPoint(x: x - 0.06 * s, y: top + 0.03 * s))
            curl.addCurve(to: CGPoint(x: x + 0.02 * s, y: top - 0.11 * s), control1: CGPoint(x: x - 0.07 * s, y: top - 0.06 * s), control2: CGPoint(x: x - 0.04 * s, y: top - 0.11 * s))
            curl.addCurve(to: CGPoint(x: x + 0.05 * s, y: top - 0.03 * s), control1: CGPoint(x: x + 0.08 * s, y: top - 0.11 * s), control2: CGPoint(x: x + 0.08 * s, y: top - 0.05 * s))
            curl.addCurve(to: CGPoint(x: x + 0.05 * s, y: top + 0.03 * s), control1: CGPoint(x: x + 0.01 * s, y: top - 0.02 * s), control2: CGPoint(x: x + 0.02 * s, y: top + 0.02 * s))
            curl.closeSubpath()
            clay(&context, curl, rect: curl.boundingRect, color: baseRGB.mix(accentRGB, 0.25), specular: false)
        case .leaf:
            var stem = Path(); stem.move(to: CGPoint(x: h.midX, y: top + 0.01 * s)); stem.addLine(to: CGPoint(x: h.midX + 0.01 * s, y: top - 0.06 * s))
            context.stroke(stem, with: .color(Self.hex("5F8F4E")), style: .init(lineWidth: max(1, s * 0.022), lineCap: .round))
            var leaf = Path()
            let a = CGPoint(x: h.midX + 0.01 * s, y: top - 0.05 * s), b = CGPoint(x: h.midX + 0.15 * s, y: top - 0.11 * s)
            leaf.move(to: a); leaf.addQuadCurve(to: b, control: CGPoint(x: h.midX + 0.05 * s, y: top - 0.16 * s))
            leaf.addQuadCurve(to: a, control: CGPoint(x: h.midX + 0.11 * s, y: top - 0.02 * s)); leaf.closeSubpath()
            clay(&context, leaf, rect: leaf.boundingRect, hex: "7DB36A", specular: false)
        default: break
        }
    }
    /// The top of the head, where toppers and hats sit.
    private var topY: CGFloat { head.minY + (look.shape == .block ? 0 : head.height * 0.01) }

    // MARK: Face

    private var eyeY: CGFloat { head.minY + head.height * (look.shape == .mochi ? 0.5 : 0.56) }
    private var eyeSpread: CGFloat { head.width * 0.19 }
    private var eyeSize: CGFloat { 0.115 * s * (1 + pose.wide * 0.5) * (look.eyes == .sparkle ? 1.12 : 1) }
    private var gazeOffset: CGPoint { CGPoint(x: pose.gaze.x * 0.02 * s, y: pose.gaze.y * 0.015 * s) }

    private func face(_ context: inout GraphicsContext) {
        let h = head
        if look.blush {
            for side in [-1.0, 1.0] as [CGFloat] {
                let center = CGPoint(x: h.midX + side * (eyeSpread + 0.075 * s), y: eyeY + 0.07 * s)
                context.fill(Ellipse().path(in: CGRect(x: center.x - 0.07 * s, y: center.y - 0.04 * s, width: 0.14 * s, height: 0.08 * s)),
                             with: .radialGradient(Gradient(colors: [accent.opacity(0.5), accent.opacity(0)]), center: center, startRadius: 0, endRadius: 0.07 * s))
            }
        }
        if look.eyes == .visor && !pose.happy && !pose.sleepy { visor(&context) }
        else { for side in [-1.0, 1.0] as [CGFloat] { eye(&context, at: CGPoint(x: h.midX + side * eyeSpread + gazeOffset.x, y: eyeY + gazeOffset.y)) } }
        if look.expression == .focused && look.eyes != .visor && !pose.sleepy { brows(&context) }
        mouth(&context, at: CGPoint(x: h.midX + gazeOffset.x * 0.4, y: eyeY + 0.095 * s))
    }

    /// Two short, slanted brows for a focused face.
    private func brows(_ context: inout GraphicsContext) {
        let h = head
        for side in [-1.0, 1.0] as [CGFloat] {
            let center = CGPoint(x: h.midX + side * eyeSpread + gazeOffset.x, y: eyeY - eyeSize * 0.95)
            var brow = Path()
            brow.move(to: CGPoint(x: center.x - side * eyeSize * 0.55, y: center.y - eyeSize * 0.12))
            brow.addLine(to: CGPoint(x: center.x + side * eyeSize * 0.45, y: center.y + eyeSize * 0.14))
            context.stroke(brow, with: .color(ink.opacity(0.85)), style: .init(lineWidth: max(1, s * 0.016), lineCap: .round))
        }
    }

    private func eye(_ context: inout GraphicsContext, at center: CGPoint) {
        let w = eyeSize
        if pose.happy || pose.sleepy || pose.blink > 0.95 {
            var arc = Path()
            if pose.happy {
                arc.move(to: CGPoint(x: center.x - w * 0.5, y: center.y + w * 0.15))
                arc.addQuadCurve(to: CGPoint(x: center.x + w * 0.5, y: center.y + w * 0.15), control: CGPoint(x: center.x, y: center.y - w * 0.55))
            } else {
                arc.move(to: CGPoint(x: center.x - w * 0.5, y: center.y))
                arc.addQuadCurve(to: CGPoint(x: center.x + w * 0.5, y: center.y), control: CGPoint(x: center.x, y: center.y + w * 0.4))
            }
            context.stroke(arc, with: .color(ink), style: .init(lineWidth: max(1, w * 0.22), lineCap: .round))
            return
        }
        let height = w * (look.eyes == .ovals ? 1.3 : 1.08) * (1 - pose.blink)
        let rect = CGRect(x: center.x - w / 2, y: center.y - height / 2, width: w, height: max(1, height))
        context.fill(Ellipse().path(in: rect), with: .linearGradient(Gradient(colors: [ink, inkRGB.mix(accentRGB, 0.35).color]),
                                                                      startPoint: CGPoint(x: rect.midX, y: rect.minY), endPoint: CGPoint(x: rect.midX, y: rect.maxY)))
        guard pose.blink < 0.6 else { return }
        let big = w * (look.eyes == .sparkle ? 0.46 : 0.38)
        context.fill(Ellipse().path(in: CGRect(x: rect.minX + w * 0.14, y: rect.minY + height * 0.12, width: big, height: big)), with: .color(.white))
        let small = w * 0.17
        context.fill(Ellipse().path(in: CGRect(x: rect.maxX - w * 0.36, y: rect.maxY - height * 0.36, width: small, height: small)), with: .color(.white.opacity(0.75)))
        if look.eyes == .sparkle {
            context.fill(Ellipse().path(in: CGRect(x: rect.midX - w * 0.04, y: rect.minY + height * 0.58, width: w * 0.1, height: w * 0.1)), with: .color(.white.opacity(0.6)))
        }
    }

    private func visor(_ context: inout GraphicsContext) {
        let h = head
        let band = CGRect(x: h.midX - h.width * 0.34, y: eyeY - 0.065 * s * (1 - pose.blink * 0.8), width: h.width * 0.68, height: max(1, 0.13 * s * (1 - pose.blink * 0.8)))
        let path = Path(roundedRect: band, cornerRadius: band.height / 2, style: .continuous)
        context.fill(path, with: .linearGradient(Gradient(colors: [inkRGB.mix(.white, 0.12).color, ink, inkRGB.mix(accentRGB, 0.35).color]),
                                                 startPoint: CGPoint(x: band.midX, y: band.minY), endPoint: CGPoint(x: band.midX, y: band.maxY)))
        context.fill(Path(roundedRect: CGRect(x: band.minX + band.width * 0.1, y: band.minY + band.height * 0.12, width: band.width * 0.55, height: band.height * 0.18), cornerRadius: band.height * 0.09),
                     with: .color(.white.opacity(0.28)))
        for side in [-1.0, 1.0] as [CGFloat] {
            let center = CGPoint(x: h.midX + side * eyeSpread + gazeOffset.x * 1.4, y: band.midY + gazeOffset.y * 0.5)
            context.fill(Ellipse().path(in: CGRect(x: center.x - 0.06 * s, y: center.y - 0.04 * s, width: 0.12 * s, height: 0.08 * s)),
                         with: .radialGradient(Gradient(colors: [accentRGB.mix(.white, 0.6).color.opacity(0.7), accent.opacity(0)]), center: center, startRadius: 0, endRadius: 0.06 * s))
            context.fill(Path(roundedRect: CGRect(x: center.x - 0.03 * s, y: center.y - 0.014 * s, width: 0.06 * s, height: max(1, 0.028 * s * (1 - pose.blink))), cornerRadius: 0.014 * s),
                         with: .color(accentRGB.mix(.white, 0.65).color))
        }
    }

    private func mouth(_ context: inout GraphicsContext, at center: CGPoint) {
        if pose.mouth > 0.08 {
            let rect = CGRect(x: center.x - (0.03 + pose.mouth * 0.015) * s, y: center.y - 0.012 * s, width: (0.06 + pose.mouth * 0.03) * s, height: (0.025 + 0.05 * pose.mouth) * s)
            context.fill(Path(roundedRect: rect, cornerRadius: rect.width * 0.45), with: .color(inkRGB.mix(accentRGB, 0.2).color))
            context.fill(Ellipse().path(in: CGRect(x: rect.midX - rect.width * 0.28, y: rect.maxY - rect.height * 0.42, width: rect.width * 0.56, height: rect.height * 0.36)), with: .color(accentRGB.mix(.white, 0.25).color))
        } else if pose.sleepy {
            context.stroke(Ellipse().path(in: CGRect(x: center.x - 0.016 * s, y: center.y - 0.01 * s, width: 0.032 * s, height: 0.026 * s)), with: .color(ink), lineWidth: max(0.8, s * 0.011))
        } else {
            restingMouth(&context, at: center)
        }
    }

    /// The mouth its expression gives it at rest.
    private func restingMouth(_ context: inout GraphicsContext, at center: CGPoint) {
        let line = StrokeStyle(lineWidth: max(1, s * 0.016), lineCap: .round)
        switch pose.happy ? .smile : look.expression {
        case .smile:
            var smile = Path()
            smile.move(to: CGPoint(x: center.x - 0.035 * s, y: center.y - 0.006 * s))
            smile.addQuadCurve(to: CGPoint(x: center.x + 0.035 * s, y: center.y - 0.006 * s), control: CGPoint(x: center.x, y: center.y + 0.03 * s))
            context.stroke(smile, with: .color(ink), style: line)
        case .grin:
            var grin = Path()
            grin.move(to: CGPoint(x: center.x - 0.045 * s, y: center.y - 0.012 * s))
            grin.addQuadCurve(to: CGPoint(x: center.x + 0.045 * s, y: center.y - 0.012 * s), control: CGPoint(x: center.x, y: center.y + 0.06 * s))
            grin.closeSubpath()
            context.fill(grin, with: .color(inkRGB.mix(accentRGB, 0.2).color))
            context.fill(Ellipse().path(in: CGRect(x: center.x - 0.018 * s, y: center.y + 0.006 * s, width: 0.036 * s, height: 0.014 * s)),
                         with: .color(accentRGB.mix(.white, 0.25).color))
        case .calm:
            var calm = Path()
            calm.move(to: CGPoint(x: center.x - 0.026 * s, y: center.y))
            calm.addQuadCurve(to: CGPoint(x: center.x + 0.026 * s, y: center.y), control: CGPoint(x: center.x, y: center.y + 0.01 * s))
            context.stroke(calm, with: .color(ink), style: line)
        case .smirk:
            var smirk = Path()
            smirk.move(to: CGPoint(x: center.x - 0.03 * s, y: center.y + 0.004 * s))
            smirk.addQuadCurve(to: CGPoint(x: center.x + 0.038 * s, y: center.y - 0.016 * s), control: CGPoint(x: center.x + 0.012 * s, y: center.y + 0.02 * s))
            context.stroke(smirk, with: .color(ink), style: line)
        case .wow:
            let rect = CGRect(x: center.x - 0.018 * s, y: center.y - 0.014 * s, width: 0.036 * s, height: 0.042 * s)
            context.fill(Ellipse().path(in: rect), with: .color(inkRGB.mix(accentRGB, 0.2).color))
        case .focused:
            var flat = Path()
            flat.move(to: CGPoint(x: center.x - 0.024 * s, y: center.y + 0.002 * s))
            flat.addLine(to: CGPoint(x: center.x + 0.024 * s, y: center.y + 0.002 * s))
            context.stroke(flat, with: .color(ink), style: line)
        }
    }

    // MARK: Accessories

    /// Where the head meets the body: a bow tie, a scarf, or a necklace sits here.
    private var neckY: CGFloat { min(head.maxY - 0.015 * s, bodyRect.minY + 0.1 * s) }

    private func accessory(_ context: inout GraphicsContext) {
        let h = head
        switch look.accessory {
        case .none: break
        case .bowTie:
            let center = CGPoint(x: 0.5 * s, y: neckY + 0.025 * s)
            for side in [-1.0, 1.0] as [CGFloat] {
                var wing = Path()
                wing.move(to: center)
                wing.addLine(to: CGPoint(x: center.x + side * 0.085 * s, y: center.y - 0.045 * s))
                wing.addQuadCurve(to: CGPoint(x: center.x + side * 0.085 * s, y: center.y + 0.045 * s), control: CGPoint(x: center.x + side * 0.105 * s, y: center.y))
                wing.closeSubpath()
                clay(&context, wing, rect: wing.boundingRect, color: accentRGB, specular: false)
            }
            let knot = CGRect(x: center.x - 0.024 * s, y: center.y - 0.024 * s, width: 0.048 * s, height: 0.048 * s)
            clay(&context, Path(roundedRect: knot, cornerRadius: 0.014 * s), rect: knot, color: accentRGB.mix(inkRGB, 0.15), specular: false)
        case .scarf:
            let band = CGRect(x: 0.27 * s, y: neckY - 0.012 * s, width: 0.46 * s, height: 0.07 * s)
            clay(&context, Path(roundedRect: band, cornerRadius: band.height / 2, style: .continuous), rect: band, color: accentRGB)
            let tail = CGRect(x: 0.56 * s, y: band.midY, width: 0.075 * s, height: 0.14 * s)
            var hanging = context
            hanging.translateBy(x: tail.midX, y: tail.minY); hanging.rotate(by: .degrees(-10)); hanging.translateBy(x: -tail.midX, y: -tail.minY)
            clay(&hanging, Path(roundedRect: tail, cornerRadius: 0.02 * s, style: .continuous), rect: tail, color: accentRGB.mix(inkRGB, 0.12), specular: false)
            for index in 0..<3 {
                let stripe = CGRect(x: band.minX + band.width * (0.2 + CGFloat(index) * 0.25), y: band.minY + 0.012 * s, width: 0.012 * s, height: band.height - 0.024 * s)
                context.fill(Path(roundedRect: stripe, cornerRadius: 0.006 * s), with: .color(.white.opacity(0.35)))
            }
        case .necklace:
            var string = Path()
            string.move(to: CGPoint(x: 0.36 * s, y: neckY))
            string.addQuadCurve(to: CGPoint(x: 0.64 * s, y: neckY), control: CGPoint(x: 0.5 * s, y: neckY + 0.11 * s))
            context.stroke(string, with: .color(inkRGB.mix(.white, 0.35).color.opacity(0.8)), lineWidth: max(0.8, s * 0.01))
            for index in 0..<5 {
                let t = CGFloat(index) / 4
                let x = 0.38 * s + t * 0.24 * s
                let y = neckY + 0.055 * s * (1 - pow(2 * t - 1, 2))
                let bead = CGRect(x: x - 0.016 * s, y: y - 0.016 * s, width: 0.032 * s, height: 0.032 * s)
                clay(&context, Ellipse().path(in: bead), rect: bead, color: index == 2 ? accentRGB : RGB(hex: "F4F1EA"), specular: false)
            }
        case .flower:
            let center = CGPoint(x: h.maxX - h.width * 0.16, y: h.minY + h.height * 0.16)
            for index in 0..<5 {
                let angle = Double(index) / 5 * 2 * .pi
                let petal = CGRect(x: center.x + cos(angle) * 0.038 * s - 0.03 * s, y: center.y + sin(angle) * 0.038 * s - 0.03 * s, width: 0.06 * s, height: 0.06 * s)
                clay(&context, Ellipse().path(in: petal), rect: petal, color: accentRGB.mix(.white, 0.35), specular: false)
            }
            let middle = CGRect(x: center.x - 0.024 * s, y: center.y - 0.024 * s, width: 0.048 * s, height: 0.048 * s)
            clay(&context, Ellipse().path(in: middle), rect: middle, hex: "F5C84C", specular: false)
        case .badge:
            let rect = CGRect(x: 0.53 * s, y: neckY + 0.035 * s, width: 0.085 * s, height: 0.085 * s)
            clay(&context, Ellipse().path(in: rect), rect: rect, color: accentRGB)
            var star = Path()
            for index in 0..<10 {
                let angle = Double(index) / 10 * 2 * .pi - .pi / 2
                let radius = (index % 2 == 0 ? 0.028 : 0.012) * s
                let point = CGPoint(x: rect.midX + cos(angle) * radius, y: rect.midY + sin(angle) * radius)
                if index == 0 { star.move(to: point) } else { star.addLine(to: point) }
            }
            star.closeSubpath()
            context.fill(star, with: .color(.white.opacity(0.9)))
        }
    }

    // MARK: Props

    private func prop(_ context: inout GraphicsContext) {
        let h = head
        switch look.prop {
        case .hardHat:
            let dome = CGRect(x: h.minX + h.width * 0.06, y: topY - 0.05 * s, width: h.width * 0.88, height: h.height * 0.48)
            var shell = Path()
            shell.move(to: CGPoint(x: dome.minX, y: dome.midY + 0.01 * s))
            shell.addCurve(to: CGPoint(x: dome.maxX, y: dome.midY + 0.01 * s), control1: CGPoint(x: dome.minX, y: dome.minY - dome.height * 0.15), control2: CGPoint(x: dome.maxX, y: dome.minY - dome.height * 0.15))
            shell.closeSubpath()
            clay(&context, shell, rect: shell.boundingRect, hex: "F7C843")
            context.fill(Path(roundedRect: CGRect(x: dome.midX - 0.025 * s, y: dome.minY + 0.005 * s, width: 0.05 * s, height: dome.height * 0.5), cornerRadius: 0.02 * s), with: .color(Self.hex("FFE48A").opacity(0.9)))
            let brim = CGRect(x: h.minX - h.width * 0.02, y: dome.midY - 0.005 * s, width: h.width * 1.04, height: 0.055 * s)
            clay(&context, Path(roundedRect: brim, cornerRadius: brim.height / 2, style: .continuous), rect: brim, hex: "E9A52A", specular: false)
        case .headset:
            var band = Path()
            band.move(to: CGPoint(x: h.minX + h.width * 0.04, y: eyeY - 0.02 * s))
            band.addCurve(to: CGPoint(x: h.maxX - h.width * 0.04, y: eyeY - 0.02 * s), control1: CGPoint(x: h.minX, y: topY - 0.12 * s), control2: CGPoint(x: h.maxX, y: topY - 0.12 * s))
            context.stroke(band, with: .linearGradient(Gradient(colors: [Self.hex("5A5F6B"), Self.hex("2E323A")]), startPoint: CGPoint(x: h.midX, y: topY - 0.1 * s), endPoint: CGPoint(x: h.midX, y: eyeY)),
                           style: .init(lineWidth: max(1.5, s * 0.03), lineCap: .round))
            for left in [true, false] {
                let cup = CGRect(x: left ? h.minX - 0.035 * s : h.maxX - 0.055 * s, y: eyeY - 0.06 * s, width: 0.09 * s, height: 0.13 * s)
                clay(&context, Path(roundedRect: cup, cornerRadius: 0.035 * s, style: .continuous), rect: cup, color: accentRGB)
            }
            var boom = Path()
            boom.move(to: CGPoint(x: h.minX, y: eyeY + 0.05 * s))
            boom.addQuadCurve(to: CGPoint(x: h.midX - 0.08 * s, y: eyeY + 0.12 * s), control: CGPoint(x: h.minX + 0.02 * s, y: eyeY + 0.13 * s))
            context.stroke(boom, with: .color(Self.hex("3A3F48")), style: .init(lineWidth: max(1, s * 0.016), lineCap: .round))
            context.fill(Ellipse().path(in: CGRect(x: h.midX - 0.1 * s, y: eyeY + 0.1 * s, width: 0.04 * s, height: 0.04 * s)), with: .color(Self.hex("3A3F48")))
        case .glasses:
            let radius = eyeSize * 0.92
            for side in [-1.0, 1.0] as [CGFloat] {
                let center = CGPoint(x: h.midX + side * eyeSpread, y: eyeY)
                let ring = Ellipse().path(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
                context.fill(ring, with: .color(.white.opacity(0.12)))
                context.stroke(ring, with: .linearGradient(Gradient(colors: [inkRGB.mix(.white, 0.25).color, ink]), startPoint: CGPoint(x: center.x, y: center.y - radius), endPoint: CGPoint(x: center.x, y: center.y + radius)),
                               lineWidth: max(1, s * 0.022))
                var glint = Path(); glint.move(to: CGPoint(x: center.x + radius * 0.2, y: center.y - radius * 0.62)); glint.addLine(to: CGPoint(x: center.x + radius * 0.6, y: center.y - radius * 0.2))
                context.stroke(glint, with: .color(.white.opacity(0.7)), style: .init(lineWidth: max(0.8, s * 0.012), lineCap: .round))
            }
            var bridge = Path(); bridge.move(to: CGPoint(x: h.midX - eyeSpread + radius, y: eyeY - radius * 0.2)); bridge.addQuadCurve(to: CGPoint(x: h.midX + eyeSpread - radius, y: eyeY - radius * 0.2), control: CGPoint(x: h.midX, y: eyeY - radius * 0.6))
            context.stroke(bridge, with: .color(ink), lineWidth: max(1, s * 0.018))
        case .pencil:
            var pencil = context
            pencil.translateBy(x: h.maxX - h.width * 0.08, y: topY + h.height * 0.16)
            pencil.rotate(by: .degrees(-38))
            let barrel = CGRect(x: -0.1 * s, y: -0.022 * s, width: 0.17 * s, height: 0.044 * s)
            clay(&pencil, Path(roundedRect: barrel, cornerRadius: 0.006 * s), rect: barrel, hex: "F5C84C", specular: false)
            let eraser = CGRect(x: -0.135 * s, y: -0.022 * s, width: 0.04 * s, height: 0.044 * s)
            clay(&pencil, Path(roundedRect: eraser, cornerRadius: 0.012 * s), rect: eraser, hex: "F2A7B5", specular: false)
            pencil.fill(Path(CGRect(x: -0.1 * s, y: -0.022 * s, width: 0.016 * s, height: 0.044 * s)), with: .color(Self.hex("C9CED6")))
            var tip = Path(); tip.move(to: CGPoint(x: 0.07 * s, y: -0.022 * s)); tip.addLine(to: CGPoint(x: 0.12 * s, y: 0)); tip.addLine(to: CGPoint(x: 0.07 * s, y: 0.022 * s)); tip.closeSubpath()
            pencil.fill(tip, with: .color(Self.hex("E9D2A8")))
            pencil.fill(Ellipse().path(in: CGRect(x: 0.104 * s, y: -0.008 * s, width: 0.018 * s, height: 0.016 * s)), with: .color(Self.hex("3A3A3A")))
        case .book:
            var book = context
            book.translateBy(x: 0.5 * s, y: 0.76 * s); book.rotate(by: .degrees(-6))
            let cover = CGRect(x: -0.12 * s, y: -0.08 * s, width: 0.24 * s, height: 0.16 * s)
            clay(&book, Path(roundedRect: cover, cornerRadius: 0.015 * s), rect: cover, color: accentRGB)
            book.fill(Path(roundedRect: CGRect(x: -0.105 * s, y: 0.05 * s, width: 0.21 * s, height: 0.022 * s), cornerRadius: 0.005 * s), with: .color(.white.opacity(0.9)))
            book.fill(Path(CGRect(x: -0.004 * s, y: -0.08 * s, width: 0.008 * s, height: 0.15 * s)), with: .color(accentRGB.mix(inkRGB, 0.3).color))
        default: break
        }
    }
    private func wrench(_ context: inout GraphicsContext) {
        let metal = Gradient(colors: [Self.hex("E3E7EC"), Self.hex("9AA3AE"), Self.hex("6C7480")])
        let handle = CGRect(x: -0.018 * s, y: 0.1 * s, width: 0.036 * s, height: 0.13 * s)
        context.fill(Path(roundedRect: handle, cornerRadius: 0.018 * s), with: .linearGradient(metal, startPoint: CGPoint(x: handle.minX, y: 0), endPoint: CGPoint(x: handle.maxX, y: 0)))
        let head = CGRect(x: -0.045 * s, y: 0.2 * s, width: 0.09 * s, height: 0.07 * s)
        context.fill(Path(roundedRect: head, cornerRadius: 0.025 * s), with: .linearGradient(metal, startPoint: CGPoint(x: head.minX, y: head.minY), endPoint: CGPoint(x: head.maxX, y: head.maxY)))
        context.fill(Path(roundedRect: CGRect(x: -0.014 * s, y: 0.245 * s, width: 0.028 * s, height: 0.03 * s), cornerRadius: 0.006 * s), with: .color(baseRGB.mix(inkRGB, 0.2).color))
    }
    private func brush(_ context: inout GraphicsContext) {
        let handle = CGRect(x: -0.014 * s, y: 0.1 * s, width: 0.028 * s, height: 0.14 * s)
        context.fill(Path(roundedRect: handle, cornerRadius: 0.014 * s), with: .linearGradient(Gradient(colors: [Self.hex("D39B66"), Self.hex("9A6438")]), startPoint: CGPoint(x: handle.minX, y: 0), endPoint: CGPoint(x: handle.maxX, y: 0)))
        context.fill(Path(CGRect(x: -0.018 * s, y: 0.225 * s, width: 0.036 * s, height: 0.025 * s)), with: .color(Self.hex("C9CED6")))
        var tip = Path(); tip.move(to: CGPoint(x: -0.02 * s, y: 0.25 * s)); tip.addQuadCurve(to: CGPoint(x: 0.02 * s, y: 0.25 * s), control: CGPoint(x: 0, y: 0.32 * s)); tip.closeSubpath()
        context.fill(tip, with: .color(accent))
    }

    private func keyboard(_ context: inout GraphicsContext) {
        let deck = r(0.25, 0.79, 0.5, 0.1)
        clay(&context, Path(roundedRect: deck, cornerRadius: 0.025 * s, style: .continuous), rect: deck, color: inkRGB.mix(.white, 0.22), specular: false)
        for index in 0..<4 {
            let key = CGRect(x: deck.minX + 0.035 * s + CGFloat(index) * 0.11 * s, y: deck.minY + 0.025 * s + (index == pose.keyPress ? 0.006 * s : 0), width: 0.08 * s, height: 0.042 * s)
            context.fill(Path(roundedRect: key, cornerRadius: 0.01 * s), with: .color(index == pose.keyPress ? accent : .white.opacity(0.82)))
        }
    }

    // MARK: Overlays

    private func overlays(_ context: inout GraphicsContext) {
        let h = head
        if pose.dots > 0 {
            for index in 0..<pose.dots {
                let angle = pose.dotsAngle + Double(index) * 2.1
                let center = CGPoint(x: h.midX + 0.2 * s * cos(angle), y: topY - 0.11 * s + 0.035 * s * sin(angle))
                let dot = CGRect(x: center.x - 0.032 * s, y: center.y - 0.032 * s, width: 0.064 * s, height: 0.064 * s)
                clay(&context, Ellipse().path(in: dot), rect: dot, color: accentRGB, specular: false)
            }
        }
        if pose.zzz > 0 {
            for index in 0..<2 {
                let phase = (pose.zzz + Double(index) * 0.5).truncatingRemainder(dividingBy: 1)
                context.draw(Text("z").font(.system(size: s * (0.12 + 0.06 * phase), weight: .heavy, design: .rounded)).foregroundColor(accent.opacity(1 - phase * 0.7)),
                             at: CGPoint(x: h.maxX - 0.02 * s + 0.1 * s * phase, y: topY + 0.02 * s - 0.18 * s * phase))
            }
        }
        if pose.bubble > 0 {
            let rect = CGRect(x: h.minX - 0.12 * s, y: topY - 0.16 * s, width: 0.3 * s * pose.bubble, height: 0.2 * s * pose.bubble)
            var bubble = Path(roundedRect: rect, cornerRadius: rect.height * 0.45, style: .continuous)
            bubble.move(to: CGPoint(x: rect.maxX - rect.width * 0.3, y: rect.maxY - 1)); bubble.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY + 0.05 * s * pose.bubble)); bubble.addLine(to: CGPoint(x: rect.maxX - rect.width * 0.12, y: rect.maxY - 1))
            context.fill(bubble, with: .color(.white.opacity(pose.bubble)))
            context.stroke(bubble, with: .color(ink.opacity(0.2 * pose.bubble)), lineWidth: 0.6)
            context.draw(Text("!").font(.system(size: s * 0.13 * pose.bubble, weight: .black, design: .rounded)).foregroundColor(accent), at: CGPoint(x: rect.midX, y: rect.midY))
        }
        if pose.confetti > 0 {
            for index in 0..<8 {
                let angle = Double(index) / 8 * 2 * .pi - .pi / 2
                let distance = (0.22 + 0.24 * pose.confetti) * s
                let center = CGPoint(x: 0.5 * s + distance * cos(angle), y: 0.45 * s + distance * sin(angle) * 0.9)
                var bit = context
                bit.translateBy(x: center.x, y: center.y); bit.rotate(by: .radians(angle + pose.confetti * 6))
                bit.fill(Path(roundedRect: CGRect(x: -0.018 * s, y: -0.025 * s, width: 0.036 * s, height: 0.05 * s), cornerRadius: 0.006 * s),
                         with: .color((index % 2 == 0 ? accent : Self.hex("F5C84C")).opacity(1 - pose.confetti * 0.8)))
            }
        }
    }
}
