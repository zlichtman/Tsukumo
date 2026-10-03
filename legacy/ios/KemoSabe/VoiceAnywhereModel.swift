import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

// "Talk to Kemo" from anywhere: the Action button, a Control, or Siri (the owner's request,
// September 25, 2026). This file is the part the app and the widget extension share: what a
// Live Activity shows, how a turn moves from listening to the reply, and when a turn listens
// in the background or hands over to the app. It has no app dependencies, so the widget
// extension compiles it as is. See design/KEMO-VOICE-ANYWHERE.md.

/// Where a turn is.
enum VoiceAnywherePhase: String, Codable, Hashable, Sendable {
    case listening, thinking, speaking, answered, failed
}

#if canImport(ActivityKit)
/// Kemo's Live Activity: the Lock Screen, and the Dynamic Island (compact, minimal, expanded).
/// Static data is the companion's look; the content state is one turn. Both stay far under
/// ActivityKit's 4 KB limit (`VoiceAnywhereMachine.maxLine`, `maxHeard`).
struct KemoVoiceAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        var phase: VoiceAnywherePhase
        /// A status ("Listening", "Thinking…") or, once answered, the reply.
        var line: String
        /// What Kemo heard, once it has the words.
        var heard: String?
        /// The microphone level while listening, in four steps (0–3), for a gentle squash and stretch.
        var level: Int = 0
        /// Alternates on the synthesizer's word callbacks while speaking (the approved open and closed mouth frames).
        var mouthOpen = false
        /// Advances with each update, so the orb under Kemo moves between updates (a Live Activity can't run a clock).
        var tick = 0
    }
    /// The companion's name.
    var name: String
    /// The companion's palette (hex), so the approved frames are recolored like the watch's.
    var body: String
    var accent: String
    /// False for the approved palette, which is drawn untinted.
    var tinted: Bool
    /// The dark app theme (hex): background, text, and accent.
    var background: String
    var foreground: String
    var themeAccent: String
}

extension KemoVoiceAttributes.ContentState {
    /// The approved frame for this state (rendered from the character; see WatchArtworkRenderTests).
    var frame: String {
        switch phase {
        case .listening: "kemo-listening"
        case .thinking: "kemo-thinking"
        case .speaking: mouthOpen ? "kemo-speaking-open" : "kemo-speaking-closed"
        case .answered: "kemo-greeting"
        case .failed: "kemo-idle"
        }
    }
    /// A gentle squash and stretch from the microphone level; nothing in other phases.
    var stretch: Double { phase == .listening ? Double(level) * 0.018 : 0 }
    /// Whether the turn is still going (a Stop button is offered).
    var isLive: Bool { phase == .listening || phase == .thinking || phase == .speaking }
}
#endif

/// One turn, from listening to the reply. Pure, so its rules are tested
/// (`VoiceAnywhereTests`). Terminal states ignore everything after them.
struct VoiceAnywhereMachine: Equatable, Sendable {
    enum Event: Equatable, Sendable {
        /// The microphone level, 0–1, while listening.
        case level(Double)
        /// Listening ended without speech.
        case heardNothing
        /// The clip is done; the words go to the harness.
        case transcribing
        /// The harness answered.
        case answered(reply: String, heard: String?)
        /// The synthesizer reached another word.
        case word
        case finishedSpeaking
        case failed(String)
        /// The person tapped Stop.
        case stop
    }
    private(set) var phase: VoiceAnywherePhase = .listening
    private(set) var line = VoiceAnywhereText.listening
    private(set) var heard: String?
    private(set) var level = 0
    private(set) var mouthOpen = false
    private(set) var tick = 0

    var isFinished: Bool { phase == .answered || phase == .failed }

    /// Applies an event; returns whether anything changed.
    @discardableResult mutating func handle(_ event: Event) -> Bool {
        let before = self
        switch (phase, event) {
        case (.listening, .level(let value)):
            let step = Self.step(value)
            if step != level { level = step; tick += 1 }
        case (.listening, .heardNothing):
            fail(VoiceAnywhereText.heardNothing)
        case (.listening, .transcribing):
            phase = .thinking; line = VoiceAnywhereText.thinking; level = 0; tick += 1
        case (.thinking, .answered(let reply, let words)):
            let reply = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { fail(VoiceAnywhereText.lost); break }
            phase = .speaking; line = Self.trimmed(reply, to: Self.maxLine)
            heard = words.map { Self.trimmed($0, to: Self.maxHeard) }.flatMap { $0.isEmpty ? nil : $0 }
            tick += 1
        case (.speaking, .word):
            mouthOpen.toggle(); tick += 1
        case (.speaking, .finishedSpeaking), (.speaking, .stop), (.speaking, .failed):
            // The reply stays on screen; only the voice stopped.
            phase = .answered; mouthOpen = false; tick += 1
        case (.listening, .failed(let message)), (.thinking, .failed(let message)):
            fail(message)
        case (.listening, .stop), (.thinking, .stop):
            fail(VoiceAnywhereText.stopped)
        default:
            break
        }
        return self != before
    }
    private mutating func fail(_ message: String) {
        phase = .failed; line = Self.trimmed(message, to: Self.maxLine); level = 0; mouthOpen = false; tick += 1
    }

    #if canImport(ActivityKit)
    var content: KemoVoiceAttributes.ContentState {
        .init(phase: phase, line: line, heard: heard, level: level, mouthOpen: mouthOpen, tick: tick)
    }
    #endif

    static let maxLine = 700
    static let maxHeard = 200
    /// Four steps are enough for the squash and stretch and keep updates rare.
    static func step(_ level: Double) -> Int {
        switch level {
        case ..<0.08: 0
        case ..<0.3: 1
        case ..<0.6: 2
        default: 3
        }
    }
    static func trimmed(_ text: String, to limit: Int) -> String {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count > limit ? String(text.prefix(limit - 1)) + "…" : text
    }
}

/// Decides when a spoken turn is over from the microphone level alone (the clip is
/// transcribed after it ends, on the device). Times are seconds since listening began.
struct VoiceEndpointer: Sendable {
    enum Decision: Equatable, Sendable { case keepListening, finished, heardNothing }
    var speechThreshold = 0.12
    /// Quiet after speech that ends the turn.
    var silence: TimeInterval = 1.3
    /// No speech at all by then ends the turn with nothing heard.
    var noSpeechTimeout: TimeInterval = 7
    var maxDuration: TimeInterval = 30
    private(set) var heardSpeech = false
    private var lastSpeech: TimeInterval = 0

    mutating func feed(level: Double, at time: TimeInterval) -> Decision {
        if level >= speechThreshold { heardSpeech = true; lastSpeech = time }
        if time >= maxDuration { return heardSpeech ? .finished : .heardNothing }
        if heardSpeech { return time - lastSpeech >= silence ? .finished : .keepListening }
        return time >= noSpeechTimeout ? .heardNothing : .keepListening
    }
}

/// Where a Talk to Kemo request goes. Nothing listens without the microphone and speech
/// permissions the person already gave in the app; a locked iPhone follows `LockedWatchMode`.
enum VoiceAnywhereRoute: Equatable, Sendable {
    /// KemoSabe is open: its own voice mode takes the request.
    case inApp
    /// Listen here, with Kemo in a Live Activity, without opening the app.
    case background
    /// Microphone or speech recognition isn't allowed yet: the app opens and asks.
    case openToAllow
    /// Locked, with no locked working set: the person unlocks and the app opens listening.
    case unlockFirst

    static func decide(appActive: Bool, microphoneAllowed: Bool, speechAllowed: Bool,
                       liveActivitiesAllowed: Bool, locked: Bool, lockedAnswerReady: Bool) -> Self {
        if appActive { return .inApp }
        if !microphoneAllowed || !speechAllowed { return .openToAllow }
        if locked && !lockedAnswerReady { return .unlockFirst }
        // A background recording must show a Live Activity the whole time (AudioRecordingIntent).
        if !liveActivitiesAllowed { return .inApp }
        return .background
    }
}

/// Keeps Live Activity updates rare: a new phase or line goes out at once; level and mouth
/// changes at most every `interval` seconds, with the latest one sent when the gap closes.
struct LiveActivityThrottle: Sendable {
    var interval: TimeInterval = 0.35
    private var lastSent: TimeInterval = -.infinity
    private var lastKey: String?

    /// Whether an update with this phase and line may go out at `time`.
    mutating func allows(phase: VoiceAnywherePhase, line: String, at time: TimeInterval) -> Bool {
        let key = phase.rawValue + "|" + line
        if key != lastKey || time - lastSent >= interval {
            lastKey = key; lastSent = time
            return true
        }
        return false
    }
    /// Seconds until a held-back update may go out.
    func wait(at time: TimeInterval) -> TimeInterval { max(0, interval - (time - lastSent)) }
}

/// The lines a turn shows. Watch-facing failures ("Open KemoSabe on iPhone.") read
/// differently on the iPhone itself.
enum VoiceAnywhereText {
    static let listening = "Listening"
    static let thinking = "Thinking…"
    static let heardNothing = "Didn't catch that. Try again."
    static let lost = "Couldn't finish that. Try again."
    static let stopped = "Stopped."
    static let unlock = "Unlock your iPhone to talk to KemoSabe."

    static func phoneLine(_ watchLine: String) -> String {
        switch watchLine {
        case "Open KemoSabe on iPhone.", "Not ready. Open KemoSabe on iPhone.": "Open KemoSabe to finish setting up."
        case "Allow speech in KemoSabe on iPhone.": "Allow speech recognition in KemoSabe."
        case "Speech isn't ready on iPhone.": "Speech recognition isn't ready yet."
        case "Update KemoSabe on your iPhone and watch, then try again.": lost
        default: watchLine
        }
    }
}
