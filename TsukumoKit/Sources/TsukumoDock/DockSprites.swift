#if os(macOS)
import AppKit
import QuartzCore
import SwiftUI
import TsukumoCore
import TsukumoUI

// Characters animated by Core Animation (design/UI-GUIDE.md#the-side-dock), ported from the old Mac
// app's dock. Most of a character's life is a loop: breathing and blinking
// at rest, typing, the thinking dots, talking, a raised hand, dozing. Each loop is drawn once into a few
// pictures with TsukumoUI's `ClayPainter`, and the window server plays them as layer animations: no
// SwiftUI redraws, so a dock full of characters costs close to nothing at rest. Only one-off moments
// (a chirp's hop, the done celebration) and looking at the pointer are drawn live.

/// A state's loop: its pictures and how long one pass takes.
public struct ClayLoop {
    public var frames: [CGImage]
    public var duration: Double
}

/// One pose of a character, drawn by `ClayPainter`.
struct ClayPoseView: View {
    let look: BotLook
    let pose: ClayPose
    var shadow = true
    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            ClayPainter(look: look, pose: pose, side: side, shadow: shadow)
                .paint(&context, origin: CGPoint(x: (size.width - side) / 2, y: (size.height - side) / 2))
        }
    }
}

@MainActor public enum ClaySprites {
    private static var cache: [String: CGImage] = [:]
    /// Which states loop in Core Animation (the rest are drawn live while they last).
    public static let looping: Set<ClayState> = [.idle, .sleeping, .working, .thinking, .talking, .needsYou]

    /// One picture of a character: a moment of a state's motion, or its still pose (eyes shut for a blink).
    public static func image(_ look: BotLook, state: ClayState, time: Double? = nil, eyesShut: Bool = false, side: CGFloat, scale: CGFloat) -> CGImage? {
        let key = "\(look.drawingKey)|\(state.rawValue)|\(time.map { String(format: "%.3f", $0) } ?? "still")|\(eyesShut)|\(Int(side))|\(scale)"
        if let image = cache[key] { return image }
        var pose = time.map { ClayMotion.pose(state, time: $0, local: $0, still: false) } ?? ClayMotion.pose(state, time: 0, still: true)
        if eyesShut { pose.blink = 1 }
        let renderer = ImageRenderer(content: ClayPoseView(look: look, pose: pose).frame(width: side, height: side))
        renderer.scale = scale
        guard let image = renderer.cgImage else { return nil }
        if cache.count > 600 { cache.removeAll() }
        cache[key] = image
        return image
    }

    /// The pictures of a state's loop, at evenly spaced moments of `ClayMotion`.
    public static func loop(_ look: BotLook, state: ClayState, level: DockAnimationLevel, side: CGFloat, scale: CGFloat) -> ClayLoop? {
        let (count, duration): (Int, Double) = switch state {
        case .working: (4, 4.0 / 9)            // one key press each
        case .thinking: (12, 2 * .pi / 2.4)     // one orbit of the dots
        case .talking: (8, 0.9)
        case .needsYou: (8, .pi / 3.2)          // one bounce
        case .sleeping: (10, 1 / 0.45)          // one drift of the z's
        default: (0, 0)
        }
        guard count > 0 else { return nil }
        // Calm plays the same loop slower.
        let pace = level == .calm ? 1 / 0.7 : 1
        let frames = (0..<count).compactMap { index in
            image(look, state: state, time: 1000 + Double(index) * duration / Double(count), side: side, scale: scale)
        }
        return frames.count == count ? ClayLoop(frames: frames, duration: duration * pace) : nil
    }
}

/// A character as a layer: a resting picture that breathes and blinks, or a state's loop.
struct ClaySprite: NSViewRepresentable {
    let look: BotLook
    var state: ClayState = .idle
    let side: CGFloat
    /// Plays; false holds one still picture (Reduce Motion, Still, out of sight).
    var animate: Bool
    var level: DockAnimationLevel = .lively
    /// Spreads the characters' breaths and blinks apart.
    var phase: Double = 0

    func makeNSView(context: Context) -> ClayLayerView { ClayLayerView() }
    func updateNSView(_ view: ClayLayerView, context: Context) {
        view.configure(look: look, state: state, side: side, animate: animate, level: level, phase: phase)
    }
}

/// The layer-backed view behind `ClaySprite`.
public final class ClayLayerView: NSView {
    public let sprite = CALayer()
    private var configured: String?
    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(sprite)
        sprite.anchorPoint = CGPoint(x: 0.5, y: 0)
        sprite.contentsGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    public override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sprite.bounds = bounds
        sprite.position = CGPoint(x: bounds.midX, y: 0)
        CATransaction.commit()
    }
    /// The animations it's playing, for tests.
    public var playing: [String] { sprite.animationKeys() ?? [] }

    public func configure(look: BotLook, state: ClayState, side: CGFloat, animate: Bool, level: DockAnimationLevel, phase: Double) {
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let key = "\(look)|\(state)|\(side)|\(animate)|\(level)|\(scale)"
        guard key != configured else { return }
        configured = key
        let still = ClaySprites.image(look, state: state, side: side, scale: scale)
        CATransaction.begin(); CATransaction.setDisableActions(true)
        sprite.contents = still
        sprite.contentsScale = scale
        sprite.removeAllAnimations()
        CATransaction.commit()
        guard animate, level != .still, let still else { return }
        let now = CACurrentMediaTime()
        // Everyone breathes.
        let breathe = CABasicAnimation(keyPath: "transform.scale.y")
        breathe.fromValue = 1; breathe.toValue = level == .calm ? 1.012 : 1.024
        breathe.duration = state == .sleeping ? 2.6 : 1.8
        breathe.autoreverses = true; breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        breathe.beginTime = now - phase * 3
        sprite.add(breathe, forKey: "breathe")
        if state == .idle {
            guard let shut = ClaySprites.image(look, state: state, eyesShut: true, side: side, scale: scale) else { return }
            let blink = CAKeyframeAnimation(keyPath: "contents")
            blink.values = [still, shut, still]
            blink.keyTimes = [0, 0.95, 0.975, 1]
            blink.calculationMode = .discrete
            blink.duration = 4 + phase
            blink.repeatCount = .infinity
            blink.beginTime = now - phase * 2
            sprite.add(blink, forKey: "blink")
        } else if let loop = ClaySprites.loop(look, state: state, level: level, side: side, scale: scale) {
            let frames = CAKeyframeAnimation(keyPath: "contents")
            frames.values = loop.frames
            frames.keyTimes = (0...loop.frames.count).map { NSNumber(value: Double($0) / Double(loop.frames.count)) }
            frames.calculationMode = .discrete
            frames.duration = loop.duration
            frames.repeatCount = .infinity
            frames.beginTime = now - phase
            sprite.add(frames, forKey: "loop")
        }
    }
}
#endif
