import SwiftUI
#if os(macOS)
import AppKit
typealias KemoPlatformImage = NSImage
#else
typealias KemoPlatformImage = UIImage
#endif

/// The light and material are artwork, not a runtime approximation of the toy.
/// The writing rig moves a separate hand/pencil over a stationary notebook.
struct ArtworkCompanion: View {
    let theme: BotTheme
    var performance = "idle"
    var thinking = false
    var speaking = false
    var listening = false
    var reducedMotion = false
    var active = true
    var attention = false
    var audioLevel: Float = 0
    var bpm = 100.0
    var replay = 0
    var framesPerSecond = 60.0
    @State private var started = Date()
    @State private var elapsed = 0.0
    private var choreography: ArtworkPerformance? {
        ArtworkPerformance(rawValue: speaking ? "speaking" : thinking ? "thinking" : listening ? "listening" : performance)
    }
    static let previewIDs = Set(ArtworkPerformance.allCases.map(\.rawValue))
    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            TimelineView(.animation(minimumInterval: 1 / max(1, framesPerSecond), paused: !active || reducedMotion)) { tick in
                let time = reducedMotion ? 0 : (previewTime ?? (elapsed + (active ? tick.date.timeIntervalSince(started) : 0)))
                Group {
                    if let choreography {
                        ArtworkScene(theme: theme, performance: choreography, side: side, time: time, bpm: bpm,
                                     audioLevel: Double(audioLevel), reducedMotion: reducedMotion)
                            .scaleEffect(attention && !reducedMotion && choreography.rig == .companion ? 1.015 : 1)
                            .animation(.easeOut(duration: 0.18), value: attention)
                    } else {
                        Text("Animation unavailable").font(KemoType.font(.caption)).foregroundStyle(.secondary)
                    }
                }.frame(width: geometry.size.width, height: geometry.size.height)
            }
        }.onChange(of: active) { _, newValue in
            if newValue { started = Date() } else { elapsed += Date().timeIntervalSince(started) }
        }.onChange(of: replay) { elapsed = 0; started = Date() }
            .onChange(of: performance) { elapsed = 0; started = Date() }
            .onChange(of: choreography?.rawValue) { elapsed = 0; started = Date() }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(CompanionIdentity.name + ", " + (speaking ? "speaking" : thinking ? "thinking" : listening ? "listening" : performance))
    }
    private var previewTime: Double? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing"),
           let arg = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--preview-time=") }) {
            return Double(arg.dropFirst("--preview-time=".count))
        }
        #endif
        return nil
    }
}

/// One moment of a performance: the ground shadow and the performance's rig.
/// Separate from the clock so tests and previews can render any exact time.
struct ArtworkScene: View {
    let theme: BotTheme
    let performance: ArtworkPerformance
    let side: CGFloat
    let time: Double
    var bpm = 100.0
    var audioLevel = 0.0
    var reducedMotion = false
    var body: some View {
        ZStack {
            Ellipse().fill(.black.opacity(0.18)).frame(width: side * 0.47, height: side * 0.055)
                .blur(radius: side * 0.024).offset(y: side * 0.414)
            switch performance.rig {
            case .musicDesk:
                MusicDeskArtwork(theme: theme, side: side, time: time, bpm: bpm, performance: performance, reducedMotion: reducedMotion)
            case .notebook:
                WritingArtwork(theme: theme, side: side, time: time, reducedMotion: reducedMotion, performance: performance)
            case .book:
                ReadingArtwork(theme: theme, side: side, time: time, performance: performance, reducedMotion: reducedMotion)
            case .computer:
                DesktopArtwork(theme: theme, side: side, time: reducedMotion ? 0 : time, performance: performance, reducedMotion: reducedMotion)
            case .companion:
                PuppetArtwork(theme: theme, side: side, time: reducedMotion ? 0 : time,
                              pose: performance.pose(at: time, bpm: bpm, level: audioLevel, reducedMotion: reducedMotion),
                              performance: performance)
            }
        }.frame(width: side, height: side)
    }
}

@MainActor enum ArtworkAssets {
    private static var images: [String: KemoPlatformImage] = [:]
    static func image(_ name: String) -> KemoPlatformImage? {
        if let image = images[name] { return image }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png", subdirectory: "Character/Artwork"),
              let image = KemoPlatformImage(contentsOfFile: url.path) else { return nil }
        images[name] = image; return image
    }
}

/// Kemo's loading indicator: an animated thinking orb (Libraries.dev, vendored in
/// ios/Vendor/ThinkingOrbs) in the current tint, never a spinning wheel. The state
/// says what's happening: listening while the microphone takes your voice,
/// connecting while waiting on another device or a permission, and thinking,
/// composing, searching, or solving for the task at hand. It holds still for Reduce Motion.
struct KemoOrb: View {
    var size: CGFloat = 20
    /// A second color blended with the tint, such as the character's body color.
    var secondary: Color? = nil
    var state: OrbState = .breathing
    var body: some View {
        // The orb draws light strokes on transparency; its alpha masks a fill in the theme's colors.
        Rectangle().fill(.tint)
            .overlay { if let secondary { LinearGradient(colors: [secondary.opacity(0.75), .clear], startPoint: .bottomTrailing, endPoint: .topLeading) } }
            .mask { ThinkingOrb(state: state, size: size <= 32 ? .px20 : .px64, theme: .dark, displaySize: size) }
            .frame(width: size, height: size)
            .accessibilityElement().accessibilityLabel(state.label.replacingOccurrences(of: "…", with: ""))
    }
    /// The orb for a request, matching what Kemo acts out.
    static func state(for request: String) -> OrbState {
        switch TaskActivity.performance(for: request) {
        case .writing, .emailDraft: .composing
        case .reading, .research: .searching
        case .coding, .calculating: .solving
        case .filing, .calendarPlanning, .focus: .weaving
        default: .breathing
        }
    }
}
