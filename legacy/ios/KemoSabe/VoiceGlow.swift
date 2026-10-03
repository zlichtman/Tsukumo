import SwiftUI

/// A glow that rises from the bottom edge of the composer with your voice, and a
/// beam that travels along it while Kemo works. A native take on Libraries.dev's
/// voice-glow (MIT, React), redrawn in SwiftUI in the theme's colors.
struct VoiceGlow: View {
    enum Phase: Equatable { case idle, listening, processing }
    var phase: Phase
    /// Microphone level, 0–1, while listening.
    var level: CGFloat
    var colors: [Color]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: phase == .idle || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            GeometryReader { proxy in
                let width = proxy.size.width
                let rise = phase == .listening ? 0.35 + level * 0.65 : phase == .processing ? 0.45 : 0
                ZStack(alignment: .bottom) {
                    // Soft lobes of color that bloom upward with the voice.
                    ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { index, color in
                        let drift = reduceMotion ? 0 : sin(t * (0.7 + Double(index) * 0.23) + Double(index) * 1.7) * 0.08
                        let x = phase == .processing ? beamX(t) : (0.2 + 0.2 * CGFloat(index) + drift)
                        Ellipse()
                            .fill(RadialGradient(colors: [color.opacity(0.9), color.opacity(0)], center: .center, startRadius: 0, endRadius: width * 0.28))
                            .frame(width: width * (phase == .processing ? 0.35 : 0.6), height: 70 * rise + 8)
                            .position(x: width * x, y: proxy.size.height)
                            .blur(radius: 18)
                    }
                    // A bright line along the edge.
                    Capsule()
                        .fill(LinearGradient(colors: colors.map { $0.opacity(0.9) }, startPoint: .leading, endPoint: .trailing))
                        .frame(height: 2)
                        .opacity(rise > 0 ? 0.55 + rise * 0.45 : 0)
                        .blur(radius: 0.6)
                }
            }
        }
        .allowsHitTesting(false)
        .opacity(phase == .idle ? 0 : 1)
        .animation(.easeOut(duration: 0.4), value: phase)
        .accessibilityHidden(true)
    }

    /// Where the processing beam is, easing into each turn.
    private func beamX(_ t: TimeInterval) -> CGFloat {
        let phase = (sin(t * 1.4) + 1) / 2
        return 0.15 + 0.7 * CGFloat(phase)
    }
}
