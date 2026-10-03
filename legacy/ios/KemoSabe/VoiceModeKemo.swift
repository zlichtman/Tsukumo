import SwiftUI

// In-app voice mode (the owner's request, September 25, 2026): while you talk with Kemo, Kemo acts
// out the conversation from the approved character (`PuppetArtwork`). It squashes and stretches
// gently with your voice, its eyes follow your words into the message box, its mouth moves with
// the synthesizer's words while it speaks, and it settles back when the conversation goes quiet.
// Reduce Motion keeps it still. There are no rings, no orb under it, and no bar at the bottom of
// the chat, and your words still fill the message box.
//
// One clear signal per state (the owner's report on build 51, September 25, 2026): voice mode
// never draws a second Kemo over the conversation. When the big Kemo is on the chat, that same
// Kemo plays voice mode in place; when it's hidden, Kemo appears in a band at the top of the chat
// that pushes the conversation down. `ChatSignals` decides what each state shows.

/// What the chat shows for each state, so every state has exactly one signal and nothing is drawn
/// over the conversation:
/// - at rest, the big Kemo (when it's shown) and then the heading, with no orb;
/// - thinking, only the transcript's row (an orb and "Thinking…" or the task's label);
/// - listening, only the composer ("Listening…" and the microphone's small orb);
/// - voice mode, one Kemo: the big Kemo in place, or a band that pushes the chat down.
/// The corner Kemo shows the name; its status line appears only on another tab while Kemo works
/// on a reply, where nothing else says so, and never says Listening.
struct ChatSignals: Equatable {
    enum Stage: Equatable {
        /// No Kemo on the chat itself (the corner still shows it).
        case none
        /// The big Kemo acting out the current performance or task.
        case performance
        /// Kemo playing voice mode: in the big Kemo's place, or in the band when that's hidden.
        case voice
    }
    let stage: Stage
    /// Voice mode with the big Kemo hidden: Kemo takes a band at the top of the chat, pushing it down.
    let voiceBand: Bool
    /// The corner's status line under the name.
    let headerStatus: Bool
    /// The composer says "Listening…" and the microphone shows its listening orb.
    let composerListening: Bool

    /// - Parameters:
    ///   - onChat: the Chat tab is showing, with no sheet over it.
    ///   - bigKemo: the person has the big Kemo shown on the chat.
    ///   - voiceMode: a spoken exchange is under way (`VoiceModePresence`).
    ///   - listening: the microphone is taking your voice.
    ///   - working: Kemo is working on a reply.
    init(onChat: Bool, bigKemo: Bool, voiceMode: Bool, listening: Bool, working: Bool) {
        let voice = onChat && voiceMode
        stage = voice ? .voice : onChat && bigKemo ? .performance : .none
        voiceBand = voice && !bigKemo
        // On Chat the transcript's row says Kemo is thinking and the composer says it's listening.
        headerStatus = working && !onChat
        composerListening = listening
    }
}

/// What voice mode reads from the voice session (or, in UI tests, a simulation).
struct VoiceModeInput: Equatable {
    var phase: VoicePhase = .off
    /// The microphone level, 0–1.
    var level: Double = 0
    /// Your words so far, while you speak.
    var heard = ""
    /// Changes at every word the synthesizer reaches.
    var wordMarker = -1

    @MainActor init(_ voice: VoiceController) {
        phase = voice.phase
        level = Double(voice.audioLevel)
        heard = voice.captionRole == "You" ? voice.caption : ""
        wordMarker = voice.spokenRange?.location ?? -1
    }
    init(phase: VoicePhase = .off, level: Double = 0, heard: String = "", wordMarker: Int = -1) {
        self.phase = phase; self.level = level; self.heard = heard; self.wordMarker = wordMarker
    }
}

/// When voice mode shows: from the moment you talk (your voice, or new words while listening),
/// through Kemo's thinking and reply, then for a moment after the last sound or word, so it
/// settles back once the conversation goes quiet. Only a spoken turn starts it: turning the
/// microphone on, a typed message, or the spoken answer to a typed command never does.
struct VoiceModePresence: Equatable {
    static let linger: TimeInterval = 3
    /// A level this loud counts as talking.
    static let speechLevel = 0.15
    private(set) var lastActivity: Date?
    private var lastHeard = ""

    mutating func observe(_ input: VoiceModeInput, at now: Date) {
        // Turning the microphone off (or losing it, which typing also does) ends the exchange at once.
        if input.phase == .off || input.phase == .unavailable { lastActivity = nil }
        let newWords = input.heard != lastHeard && !input.heard.isEmpty
        lastHeard = input.heard
        switch input.phase {
        case .listening:
            if input.level >= Self.speechLevel || newWords { lastActivity = now }
        case .thinking, .speaking:
            // Kemo answering what you said keeps it up; answering something typed doesn't start it.
            if lastActivity != nil { lastActivity = now }
        case .off, .starting, .unavailable: break
        }
    }
    func isVisible(_ phase: VoicePhase, at now: Date) -> Bool {
        guard let lastActivity else { return false }
        switch phase {
        case .thinking, .speaking: return true
        // The recognizer restarting between turns (`.starting`) doesn't end the exchange.
        case .listening, .starting: return now.timeIntervalSince(lastActivity) < Self.linger
        case .off, .unavailable: return false
        }
    }
    /// When voice mode settles if nothing else happens.
    var settlesAt: Date? { lastActivity?.addingTimeInterval(Self.linger) }
}

/// Keeps `VoiceModePresence` current and settles Kemo on time.
@MainActor @Observable final class VoiceModeState {
    private(set) var visible = false
    private(set) var input = VoiceModeInput()
    @ObservationIgnored private var presence = VoiceModePresence()
    @ObservationIgnored private var settle: Task<Void, Never>?

    func update(_ input: VoiceModeInput, now: Date = Date()) {
        self.input = input
        presence.observe(input, at: now)
        refresh(now: now)
    }
    private func refresh(now: Date) {
        let next = presence.isVisible(input.phase, at: now)
        if next != visible { visible = next }
        settle?.cancel(); settle = nil
        guard visible, input.phase == .listening || input.phase == .starting, let at = presence.settlesAt else { return }
        settle = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.05, at.timeIntervalSinceNow + 0.05)))
            guard let self, !Task.isCancelled else { return }
            self.refresh(now: Date())
        }
    }
}

/// Kemo's pose in voice mode, from the approved performances plus the voice.
enum VoiceModePose {
    static func performance(for phase: VoicePhase) -> ArtworkPerformance {
        switch phase {
        case .speaking: .speaking
        case .thinking: .thinking
        default: .listening
        }
    }
    /// - Parameters:
    ///   - sinceWord: seconds since the synthesizer's last word, or nil with no word callbacks.
    static func pose(phase: VoicePhase, time: Double, level: Double, heard: String,
                     sinceWord: Double?, reducedMotion: Bool) -> ArtworkPerformance.Pose {
        let performance = performance(for: phase)
        guard !reducedMotion else { return Pose() }
        let level = min(1, max(0, level))
        var pose = performance.pose(at: time, level: level)
        switch phase {
        case .listening, .starting:
            // Gentle squash and stretch: taller with your voice, a little squat between words.
            pose.stretch = min(0.05, max(-0.02, 0.008 + (level - 0.2) * 0.07))
            pose.y = -level * 0.012
            pose.gaze = gaze(following: heard)
        case .speaking:
            if let sinceWord {
                // Opens on each word and closes after it.
                let open = exp(-max(0, sinceWord) * 7)
                pose.mouth = 0.12 + 0.78 * open
                pose.stretch += open * 0.01
            }
        default: break
        }
        return pose
    }
    /// Kemo looks down at the message box and along your words as they arrive.
    static func gaze(following heard: String) -> CGPoint {
        guard !heard.isEmpty else { return CGPoint(x: 0, y: 0.004) }
        let progress = min(1, Double(heard.count) / 60)
        return CGPoint(x: -0.008 + 0.016 * progress, y: 0.012)
    }
    typealias Pose = ArtworkPerformance.Pose
}

/// Feeds the voice session (or the UI tests' simulation) into `VoiceModeState`. It's its own tiny
/// view so the microphone level, which changes many times a second, redraws only this and Kemo.
struct VoiceModeFeeder: View {
    @Environment(VoiceController.self) private var voice
    let state: VoiceModeState
    var simulated: VoiceModeInput?
    var body: some View {
        let input = simulated ?? VoiceModeInput(voice)
        Color.clear.frame(width: 0, height: 0)
            .onChange(of: input, initial: true) { state.update(input) }
            .accessibilityHidden(true)
    }
}

/// Kemo in voice mode, drawn like the big Kemo (`ArtworkScene`'s ground shadow and puppet) so it
/// can take the big Kemo's place without a jump, or sit in the band at the top of the chat. No orb
/// under it: the composer shows listening and the transcript's row shows thinking.
struct VoiceModeKemo: View {
    /// The band's height when the big Kemo is hidden.
    static let bandHeight: CGFloat = 108
    let theme: BotTheme
    let state: VoiceModeState
    private var input: VoiceModeInput { state.input }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var started = Date()
    @State private var wordAt: Date?

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            artwork(side: side)
                // Kemo stays inside its square whatever the pose, so in the band it never covers the
                // conversation. Each paw is a whole artwork plate that turns about the shoulder, and a
                // turned plate's box (thinking raises and turns the right paw) reaches a quarter of
                // the square past it: clipped here, and Kemo's frame is the square itself.
                .frame(width: side, height: side)
                .clipShape(Rectangle())
                .contentShape(Rectangle())
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(CompanionIdentity.name + ", " + phaseWord)
                .accessibilityValue("Level \(Int((input.level * 100).rounded())) percent")
                .accessibilityIdentifier("voiceModeKemo")
                .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onChange(of: input.wordMarker) { if input.wordMarker >= 0 { wordAt = Date() } }
        .onChange(of: input.phase) { if input.phase != .speaking { wordAt = nil } }
    }
    private func artwork(side: CGFloat) -> some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { tick in
            let time = reduceMotion ? 0 : tick.date.timeIntervalSince(started)
            ZStack {
                Ellipse().fill(.black.opacity(0.18)).frame(width: side * 0.47, height: side * 0.055)
                    .blur(radius: side * 0.024).offset(y: side * 0.414)
                PuppetArtwork(theme: theme, side: side, time: time,
                              pose: VoiceModePose.pose(phase: input.phase, time: time, level: input.level, heard: input.heard,
                                                       sinceWord: wordAt.map { tick.date.timeIntervalSince($0) }, reducedMotion: reduceMotion),
                              performance: VoiceModePose.performance(for: input.phase))
            }.frame(width: side, height: side)
        }
    }
    private var phaseWord: String {
        switch input.phase {
        case .speaking: "Speaking"
        case .thinking: "Thinking"
        default: "Listening"
        }
    }
}

#if DEBUG
/// UI tests can't use the host microphone. `--simulate-voice-mode` (with `--voice-level=0.7`, and
/// `--voice-quiet=<seconds>` for how long the microphone listens before any words) plays one
/// scripted conversation through voice mode: the microphone listening quietly, then listening with a
/// simulated level while words fill the message box, thinking, speaking word by word, then quiet until
/// Kemo settles back. With `--reply-fixture`, the words are sent when it starts thinking.
@MainActor @Observable final class VoiceModeSimulation {
    private(set) var input = VoiceModeInput()
    @ObservationIgnored private var task: Task<Void, Never>?
    /// An ordinary question, not a spoken command, so a reply fixture answers it in the chat.
    static let sentence = "What should I cook tonight"

    /// One simulation per launch.
    static let shared: VoiceModeSimulation? = fromLaunchArguments()
    private static func fromLaunchArguments() -> VoiceModeSimulation? {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"), arguments.contains("--simulate-voice-mode") else { return nil }
        let level = arguments.first { $0.hasPrefix("--voice-level=") }.flatMap { Double($0.dropFirst("--voice-level=".count)) } ?? 0.6
        let simulation = VoiceModeSimulation()
        simulation.level = level
        simulation.quiet = arguments.first { $0.hasPrefix("--voice-quiet=") }.flatMap { Double($0.dropFirst("--voice-quiet=".count)) } ?? 4
        return simulation
    }
    @ObservationIgnored private var level = 0.6
    @ObservationIgnored private var quiet = 4.0
    /// Starts once the chat is on screen: off for a moment, then the conversation.
    func start() {
        guard task == nil else { return }
        let level = level, quiet = quiet
        task = Task { [weak self] in
            func pause(_ seconds: Double) async { try? await Task.sleep(for: .seconds(seconds)) }
            await pause(2.5)
            // The microphone is on and nothing has been said yet.
            self?.input = VoiceModeInput(phase: .listening)
            await pause(quiet)
            let words = Self.sentence.split(separator: " ").map(String.init)
            for step in 0..<45 {
                guard let self, !Task.isCancelled else { return }
                let shown = words.prefix(min(words.count, step / 4 + 1)).joined(separator: " ")
                self.input = VoiceModeInput(phase: .listening, level: level * (0.7 + 0.3 * sin(Double(step))), heard: shown)
                await pause(0.12)
            }
            self?.input = VoiceModeInput(phase: .thinking)
            // Long enough for a UI test to find Kemo thinking and measure it; its polling can miss a shorter phase.
            await pause(3)
            for word in 0..<14 {
                guard let self, !Task.isCancelled else { return }
                self.input = VoiceModeInput(phase: .speaking, wordMarker: word * 6)
                await pause(0.22)
            }
            // Quiet again: Kemo settles back after `VoiceModePresence.linger`.
            self?.input = VoiceModeInput(phase: .listening)
        }
    }
}
#endif

#if DEBUG
/// UI tests can't count on a language model. `--reply-fixture=<seconds>` (with `--ui-testing`) answers
/// every message after that long with a fixed line, so a reply's thinking state can be checked.
struct UITestReplyFixture: AssistantProvider {
    static let text = "Here's a test reply."
    let delay: Double
    var runsLocally: Bool { true }
    var availabilityDescription: String { "UI test replies" }
    var isAvailable: Bool { true }
    func reply(to message: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String {
        try await Task.sleep(for: .seconds(delay))
        return Self.text
    }
    static let fromLaunchArguments: UITestReplyFixture? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--ui-testing"),
              let delay = arguments.first(where: { $0.hasPrefix("--reply-fixture=") }).flatMap({ Double($0.dropFirst("--reply-fixture=".count)) })
        else { return nil }
        return UITestReplyFixture(delay: delay)
    }()
}
#endif
