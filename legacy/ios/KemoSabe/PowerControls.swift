import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The power-up controls shared by Tsukumo's coding composer and KemoSabe's chat model chip on Mac
// and iPhone: the heat-tinted effort colors, the sparkles, and the thick snapping slider.

// MARK: Effort weights and names

/// How hard an effort asks a model to think, 0…1, and the name a person reads. The provider's own
/// name is always what's sent; these are only for the slider's heat and the popover's title.
enum EffortWeight {
    static func heat(_ effort: String) -> Double {
        switch effort.lowercased() {
        case "none": 0.05
        case "minimal": 0.12
        case "low", "light": 0.25
        case "medium", "moderate": 0.45
        case "high": 0.65
        case "deep", "xhigh": 0.8
        case "max": 0.92
        case "ultra": 1
        default: 0.5
        }
    }
    static func title(_ effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return "Model's default" }
        switch effort.lowercased() {
        case "xhigh": return "Extra high"
        default: return effort.prefix(1).uppercased() + effort.dropFirst()
        }
    }
}

// MARK: Heat colors

/// The slider's fill: the theme's accent, warmer and hotter as effort rises. The hue leans toward
/// magenta-red (at most a small turn, so every theme keeps its own color) and saturation and
/// brightness climb with the heat.
enum EffortHeat {
    #if os(macOS)
    private typealias PlatformColor = NSColor
    #else
    private typealias PlatformColor = UIColor
    #endif
    private static func components(_ color: Color) -> (CGFloat, CGFloat, CGFloat) {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        #if os(macOS)
        let base = NSColor(color).usingColorSpace(.deviceRGB) ?? .systemPurple
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        #else
        if !UIColor(color).getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha) {
            UIColor.systemPurple.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        }
        #endif
        return (hue, saturation, brightness)
    }
    private static func make(_ hue: CGFloat, _ saturation: CGFloat, _ brightness: CGFloat) -> Color {
        #if os(macOS)
        Color(nsColor: NSColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
        #else
        Color(uiColor: UIColor(hue: hue, saturation: saturation, brightness: brightness, alpha: 1))
        #endif
    }
    static func ramp(accent: Color, heat: Double, dark: Bool) -> [Color] {
        let (hue, saturation, brightness) = components(accent)
        var delta = 0.95 - hue
        if delta > 0.5 { delta -= 1 } else if delta < -0.5 { delta += 1 }
        delta = min(max(delta, -0.12), 0.12)
        let h = max(0, min(1, heat))
        func shifted(_ amount: Double) -> CGFloat {
            var value = hue + delta * CGFloat(amount)
            if value < 0 { value += 1 } else if value > 1 { value -= 1 }
            return value
        }
        let soft = make(shifted(-0.25), saturation * (dark ? 0.5 : 0.45), min(1, brightness * 1.08 + (dark ? 0.12 : 0.18)))
        let middle = make(shifted(0.35 * h), min(1, saturation * (0.8 + 0.2 * h)), min(1, brightness * (0.98 + 0.08 * h)))
        let hot = make(shifted(0.4 + 0.6 * h), min(1, saturation * (0.85 + 0.35 * h) + 0.05 * h), min(1, brightness * (0.96 + 0.16 * h) + (dark ? 0.04 : 0)))
        return [soft, middle, hot]
    }
    /// The effort name's color: the hot end, readable on the popover in either mode.
    static func title(accent: Color, heat: Double, dark: Bool) -> Color {
        ramp(accent: accent, heat: 0.15 + 0.85 * heat, dark: dark)[2]
    }
}

// MARK: Sparkles

/// Small four-point stars drifting through the slider's fill: a few slow, faint ones at low
/// effort and more, brighter, quicker ones as it rises. One Canvas, a fixed seed per star, and a
/// 30 fps timeline that pauses under Reduce Motion (the stars then stand still).
struct SparkleField: View {
    var heat: Double
    var animate: Bool
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animate)) { context in
            Canvas(rendersAsynchronously: false) { canvas, size in
                Self.draw(in: &canvas, size: size, heat: heat, time: animate ? context.date.timeIntervalSinceReferenceDate : 0, moving: animate)
            }
        }
        .allowsHitTesting(false).accessibilityHidden(true)
    }
    /// A repeatable number in 0..<1 for a star and a property.
    static func noise(_ star: Int, _ property: Int) -> Double {
        let value = sin(Double(star) * 12.9898 + Double(property) * 78.233) * 43758.5453
        return value - value.rounded(.down)
    }
    static func starCount(_ heat: Double) -> Int { 5 + Int((max(0, min(1, heat)) * 21).rounded()) }
    static func draw(in canvas: inout GraphicsContext, size: CGSize, heat: Double, time: TimeInterval, moving: Bool) {
        let span = size.width + 12
        for star in 0..<starCount(heat) {
            let speed = (5 + 34 * heat) * (0.55 + noise(star, 3))
            let x = (noise(star, 1) * span + time * speed).truncatingRemainder(dividingBy: span) - 6
            let y = (0.18 + 0.64 * noise(star, 2)) * size.height
            let twinkle = moving ? 0.5 + 0.5 * sin(time * (1.4 + 3.2 * heat) * (0.6 + noise(star, 4)) + noise(star, 5) * 6.283) : 0.45 + 0.55 * noise(star, 4)
            let opacity = (0.22 + 0.62 * heat) * twinkle
            let radius = (1.1 + 2.3 * noise(star, 6)) * (0.75 + 0.5 * heat)
            if radius > 2.2 {
                canvas.fill(Path(ellipseIn: CGRect(x: x - radius * 1.6, y: y - radius * 1.6, width: radius * 3.2, height: radius * 3.2)), with: .color(.white.opacity(opacity * 0.18)))
            }
            canvas.fill(sparkle(at: CGPoint(x: x, y: y), radius: radius), with: .color(.white.opacity(opacity)))
        }
    }
    /// A four-point star with concave sides.
    static func sparkle(at center: CGPoint, radius: Double) -> Path {
        var path = Path()
        let waist = radius * 0.28
        path.move(to: CGPoint(x: center.x, y: center.y - radius))
        path.addQuadCurve(to: CGPoint(x: center.x + radius, y: center.y), control: CGPoint(x: center.x + waist, y: center.y - waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y + radius), control: CGPoint(x: center.x + waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x - radius, y: center.y), control: CGPoint(x: center.x - waist, y: center.y + waist))
        path.addQuadCurve(to: CGPoint(x: center.x, y: center.y - radius), control: CGPoint(x: center.x - waist, y: center.y - waist))
        path.closeSubpath()
        return path
    }
}

// MARK: The power slider

/// A thick rounded track whose fill runs to a big round thumb. It snaps to `count` stops as you drag
/// or click, with a tick on each; the fill carries the heat ramp and the sparkles. `height` grows
/// for touch on iPhone.
struct PowerSlider: View {
    let count: Int
    @Binding var step: Int
    /// The heat at the current stop.
    let heat: Double
    let accent: Color
    /// What VoiceOver reads for the current stop.
    var valueTitle: String
    var height: CGFloat = 30
    var animate = true
    var onStep: (Int) -> Void = { _ in }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    private var thumb: CGFloat { height - 6 }
    private let inset: CGFloat = 3
    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let fill = center(step, width) + thumb / 2 + inset
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.1 : 0.07))
                    .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                ForEach(0..<max(count, 1), id: \.self) { index in
                    Circle().fill(Color.primary.opacity(index <= step ? 0 : 0.2)).frame(width: 4, height: 4)
                        .position(x: center(index, width), y: height / 2)
                }
                ZStack(alignment: .leading) {
                    LinearGradient(colors: EffortHeat.ramp(accent: accent, heat: heat, dark: scheme == .dark), startPoint: .leading, endPoint: .trailing)
                        .frame(width: fill)
                    SparkleField(heat: heat, animate: animate && !reduceMotion).frame(width: width)
                }
                .frame(width: width, height: height, alignment: .leading)
                .mask(alignment: .leading) { Capsule().frame(width: fill) }
                Circle().fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
                    .shadow(color: .black.opacity(scheme == .dark ? 0.45 : 0.22), radius: 3, y: 1.5)
                    .frame(width: thumb, height: thumb)
                    .position(x: center(step, width), y: height / 2)
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                let next = nearest(value.location.x, width)
                if next != step { step = next; onStep(next) }
            })
            .animation(reduceMotion ? nil : .spring(response: 0.26, dampingFraction: 0.78), value: step)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Reasoning effort")
        .accessibilityValue(valueTitle)
        .accessibilityAdjustableAction { direction in
            let next = min(max(step + (direction == .increment ? 1 : -1), 0), count - 1)
            if next != step { step = next; onStep(next) }
        }
    }
    private func center(_ index: Int, _ width: CGFloat) -> CGFloat {
        let usable = max(0, width - thumb - inset * 2)
        let fraction = count > 1 ? CGFloat(index) / CGFloat(count - 1) : 0
        return inset + thumb / 2 + usable * fraction
    }
    private func nearest(_ x: CGFloat, _ width: CGFloat) -> Int {
        guard count > 1 else { return 0 }
        let usable = max(1, width - thumb - inset * 2)
        let fraction = min(max((x - inset - thumb / 2) / usable, 0), 1)
        return Int((fraction * CGFloat(count - 1)).rounded())
    }
}
