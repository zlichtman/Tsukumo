import AppIntents
import SwiftUI
import UIKit

// Kemo's Live Activity views: the Lock Screen and the Dynamic Island pieces. The widget extension
// draws them; the app compiles them too so its render tests can check every state
// (`VoiceActivityRenderTests`). Kemo is drawn from the approved frames in the companion's palette.

struct KemoVoiceLockScreen: View {
    let attributes: KemoVoiceAttributes
    let state: KemoVoiceAttributes.ContentState
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            KemoVoiceFigure(attributes: attributes, state: state, side: 48)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(attributes.name).font(.headline).lineLimit(1)
                    Spacer(minLength: 4)
                    if state.isLive { KemoVoiceStopButton(tint: KemoVoiceFrames.color(attributes.themeAccent)) }
                }
                KemoVoiceTurnText(state: state, foreground: KemoVoiceFrames.color(attributes.foreground), lines: 4)
            }
        }
        .foregroundStyle(KemoVoiceFrames.color(attributes.foreground))
        .padding(14)
    }
}

/// Kemo, and under it the listening or thinking orb. No rings.
struct KemoVoiceFigure: View {
    let attributes: KemoVoiceAttributes
    let state: KemoVoiceAttributes.ContentState
    let side: CGFloat
    var body: some View {
        VStack(spacing: 0) {
            KemoVoiceFrame(attributes: attributes, state: state, mini: false)
                .frame(width: side, height: side)
            Group {
                if state.phase == .listening || state.phase == .thinking {
                    KemoVoiceOrb(state: state, size: 12, color: KemoVoiceFrames.color(attributes.accent))
                } else {
                    Color.clear
                }
            }.frame(width: 12, height: 12).offset(y: -3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(attributes.name + ", " + state.phase.spoken)
    }
}

/// The approved frame for the state, in the companion's palette, with a gentle squash and stretch
/// from the microphone level.
struct KemoVoiceFrame: View {
    let attributes: KemoVoiceAttributes
    let state: KemoVoiceAttributes.ContentState
    let mini: Bool
    var body: some View {
        Image(uiImage: KemoVoiceFrames.image(state.frame + (mini ? "-mini" : ""), attributes: attributes))
            .resizable()
            .scaledToFit()
            .scaleEffect(x: 1 - state.stretch * 0.25, y: 1 + state.stretch, anchor: .bottom)
            .animation(.easeOut(duration: 0.3), value: state.level)
            .contentTransition(.opacity)
            .accessibilityHidden(true)
    }
}

struct KemoVoiceTurnText: View {
    let state: KemoVoiceAttributes.ContentState
    let foreground: Color
    let lines: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let heard = state.heard {
                Text(heard).font(.caption).foregroundStyle(foreground.opacity(0.62)).lineLimit(1)
            }
            Text(state.line)
                .font(state.phase == .speaking || state.phase == .answered ? .callout : .subheadline.weight(.medium))
                .foregroundStyle(state.phase == .failed ? foreground.opacity(0.8) : foreground)
                .lineLimit(lines)
                .contentTransition(.opacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct KemoVoiceTrailingSign: View {
    let state: KemoVoiceAttributes.ContentState
    let tint: Color
    var body: some View {
        Group {
            switch state.phase {
            case .listening, .thinking:
                KemoVoiceOrb(state: state, size: 18, color: tint)
            case .speaking:
                Image(systemName: "waveform", variableValue: state.mouthOpen ? 1 : 0.4).foregroundStyle(tint)
            case .answered:
                Image(systemName: "text.bubble.fill").foregroundStyle(tint)
            case .failed:
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityLabel(state.phase.spoken)
    }
}

/// Kemo's thinking orb in the theme's color (as `KemoOrb` draws it), frozen at the update's tick:
/// a Live Activity can't animate on its own, so the orb moves a step with each update.
struct KemoVoiceOrb: View {
    let state: KemoVoiceAttributes.ContentState
    let size: CGFloat
    let color: Color
    var body: some View {
        Rectangle().fill(color)
            .mask {
                ThinkingOrb(state: state.phase == .listening ? .listening : .breathing, size: .px20, theme: .dark, displaySize: size)
                    .orbFrozenTime(Double(state.tick) * 0.37)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct KemoVoiceStopButton: View {
    let tint: Color
    var body: some View {
        Button(intent: StopTalkingToKemoIntent()) {
            Image(systemName: "stop.fill").font(.system(size: 13, weight: .bold))
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.22), in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Stop")
    }
}

extension VoiceAnywherePhase {
    var spoken: String {
        switch self {
        case .listening: "listening"
        case .thinking: "thinking"
        case .speaking: "speaking"
        case .answered: "answered"
        case .failed: "couldn't finish"
        }
    }
}

/// The approved frames, recolored to the companion's palette with the watch's formula (`KemoTint`,
/// which matches the iPhone's shader). The approved palette is drawn as is.
enum KemoVoiceFrames {
    nonisolated(unsafe) private static var cache: [String: UIImage] = [:]
    /// Where the frames are: the widget extension's asset catalog.
    nonisolated(unsafe) static var bundle = Bundle.main
    static func image(_ name: String, attributes: KemoVoiceAttributes) -> UIImage {
        let key = name + attributes.body + attributes.accent + (attributes.tinted ? "t" : "")
        if let image = cache[key] { return image }
        guard let base = UIImage(named: name, in: bundle, with: nil) else { return UIImage() }
        var result = base
        if attributes.tinted, let cgImage = base.cgImage,
           let body = KemoTint.RGB(hex: attributes.body), let accent = KemoTint.RGB(hex: attributes.accent),
           let recolored = KemoTint.recolored(cgImage, body: body, accent: accent) {
            result = UIImage(cgImage: recolored, scale: base.scale, orientation: .up)
        }
        cache[key] = result
        return result
    }
    /// "211B2C" or "#211B2C"; clear when malformed.
    static func color(_ hex: String) -> Color {
        guard let rgb = KemoTint.RGB(hex: hex) else { return .clear }
        return Color(.sRGB, red: Double(rgb.r), green: Double(rgb.g), blue: Double(rgb.b))
    }
}
