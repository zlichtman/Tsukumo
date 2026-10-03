import SwiftUI

/// Kemo on the watch, drawn from frames pre-rendered from the approved
/// character (watchOS has no Metal or SwiftUI shaders) in the iPhone's character
/// palette. Motion pauses when the wrist is down and holds still for Reduce Motion.
///
/// At rest, Kemo shows how it feels as a pet (`KemoVitals.Mood`) with the same frames:
/// happy Kemo squints with pleasure, hungry Kemo puts a paw to its mouth now and then, lonely
/// Kemo looks around and waves for you, and sleeping Kemo keeps its eyes shut and breathes slowly.
struct KemoFigure: View {
    enum Mood { case idle, greeting, listening, thinking, speaking }
    var mood: Mood
    var pet: KemoVitals.Mood = .content
    var palette: WatchLink.Palette?
    /// The companion's name for VoiceOver: KemoSabe, or the name the person chose.
    var name = "KemoSabe"
    @Environment(\.isLuminanceReduced) private var dimmed
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // Frames change at 6 fps; thinking and sleeping also breathe, which needs a smooth rate.
        TimelineView(.animation(minimumInterval: breathes ? 1.0 / 30 : 1.0 / 6, paused: dimmed || reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            KemoFrames.image(frame(at: time), palette: palette)
                .resizable()
                .scaledToFit()
                .scaleEffect(scale(at: time))
        }
        .accessibilityElement()
        .accessibilityLabel(name)
        .accessibilityValue(description)
        .accessibilityIdentifier("watchKemo")
    }
    private var breathes: Bool { mood == .thinking || (mood == .idle && pet == .sleepy) }
    private func scale(at time: TimeInterval) -> CGFloat {
        guard !(dimmed || reduceMotion) else { return 1 }
        if mood == .thinking { return 1 + 0.035 * sin(time * 5) }
        // Slow sleeping breaths, about one every five seconds.
        if mood == .idle, pet == .sleepy { return 1 + 0.02 * sin(time * 1.25) }
        return 1
    }
    private func frame(at time: TimeInterval) -> String {
        let still = dimmed || reduceMotion
        switch mood {
        case .greeting: return "kemo-greeting"
        case .listening: return "kemo-listening"
        case .thinking: return "kemo-thinking"
        case .speaking: return still || Int(time * 6) % 2 == 0 ? "kemo-speaking-open" : "kemo-speaking-closed"
        case .idle: return idleFrame(at: time, still: still)
        }
    }
    private func idleFrame(at time: TimeInterval, still: Bool) -> String {
        switch pet {
        case .sleepy: return "kemo-blink"
        case .content: return !still && time.truncatingRemainder(dividingBy: 4.2) < 0.17 ? "kemo-blink" : "kemo-idle"
        case .happy:
            // A contented squint every few seconds.
            guard !still else { return "kemo-idle" }
            let t = time.truncatingRemainder(dividingBy: 5)
            return t < 0.8 ? "kemo-blink" : "kemo-idle"
        case .hungry:
            // Puts a paw to its mouth now and then, asking to be fed.
            guard !still else { return "kemo-thinking" }
            let t = time.truncatingRemainder(dividingBy: 4)
            if t < 0.17 { return "kemo-blink" }
            return (2..<3.2).contains(t) ? "kemo-thinking" : "kemo-idle"
        case .lonely:
            // Looks around for you, and waves now and then.
            guard !still else { return "kemo-listening" }
            let t = time.truncatingRemainder(dividingBy: 7)
            if t < 1.1 { return "kemo-greeting" }
            return (4..<4.17).contains(t) ? "kemo-blink" : "kemo-listening"
        }
    }
    private var description: String {
        switch mood {
        case .idle: pet == .content ? "Ready" : pet.word
        case .greeting: "Waving"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .speaking: "Speaking"
        }
    }
}
