@preconcurrency import AVFoundation
import Foundation
import TsukumoCore

// Speech out, ported from the old KemoSabe app (`legacy/ios/KemoSabe/SpeechEngine.swift`,
// `NeuralSpeechEngines.swift`, `VoicePolicy.swift`'s `VoiceCatalog`, and `CompanionPolicy.swift`'s
// `SpeechText`): every reply voice sits behind `SpeechEngine`, Kokoro on the device once it's downloaded,
// and Apple's best installed voice as the fallback for everything. New: each bot has its own voice.

/// Text made ready to speak: links, Markdown, and line breaks become what a voice should say.
public enum SpeechText {
    public static func prepared(_ text: String) -> String {
        var value = text.replacingOccurrences(of: #"!\[([^\]]*)\]\(https?://[^)]+\)"#, with: "$1", options: .regularExpression)
        value = value.replacingOccurrences(of: #"\[([^\]]+)\]\(https?://[^)]+\)"#, with: "$1", options: .regularExpression)
        // Sentence punctuation stays outside a bare URL so the voice still pauses.
        value = value.replacingOccurrences(of: #"https?://[^\s<]*[^\s<.,!?;:)]"#, with: "the link", options: .regularExpression)
        value = value.replacingOccurrences(of: #"(?m)^[ \t]{0,3}(?:#{1,6}[ \t]+|>[ \t]?|[-+*•][ \t]+)"#, with: "", options: .regularExpression)
        value = value.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "__", with: "")
            .replacingOccurrences(of: "~~", with: "").replacingOccurrences(of: "`", with: "")
        value = value.replacingOccurrences(of: #"[ \t]*\n+[ \t]*"#, with: " ", options: .regularExpression)
        value = value.replacingOccurrences(of: #"[ \t]{2,}"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Splits a reply into sentences, so the first plays while the next is made. Long sentences are cut at a
/// comma or space.
public enum SpeechChunks {
    public static func sentences(_ text: String, maxCharacters: Int = 300) -> [String] {
        let prepared = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prepared.isEmpty else { return [] }
        var pieces: [String] = []
        prepared.enumerateSubstrings(in: prepared.startIndex..., options: [.bySentences, .localized]) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty { pieces.append(sentence) }
        }
        if pieces.isEmpty { pieces = [prepared] }
        return pieces.flatMap { split($0, max: maxCharacters) }
    }
    private static func split(_ sentence: String, max: Int) -> [String] {
        var rest = Substring(sentence), out: [String] = []
        while rest.count > max {
            let window = rest.prefix(max)
            let cut = window.lastIndex(of: ",").map { rest.index(after: $0) } ?? window.lastIndex(of: " ") ?? window.endIndex
            out.append(String(rest[..<cut]).trimmingCharacters(in: .whitespaces))
            rest = rest[cut...].drop { $0 == " " }
        }
        if !rest.isEmpty { out.append(String(rest)) }
        return out.filter { !$0.isEmpty }
    }

    /// The part of a reply still streaming in that is safe to speak now: complete sentences only, never an
    /// abbreviation's period. (The old app's `VoiceTurnPolicy.stablePrefix`.)
    public static func stablePrefix(_ text: String, final: Bool) -> String {
        if final { return text }
        var boundary = text.startIndex
        var cursor = text.startIndex
        while cursor < text.endIndex {
            let next = text.index(after: cursor)
            if ".!?\n".contains(text[cursor]), next < text.endIndex, text[next].isWhitespace {
                let prefix = String(text[..<next])
                let word = prefix.split(whereSeparator: \.isWhitespace).last?.lowercased() ?? ""
                if !["dr.", "mr.", "mrs.", "ms.", "e.g.", "i.e.", "vs.", "st."].contains(word) { boundary = next }
            }
            cursor = next
        }
        return String(text[..<boundary])
    }
}

/// Audio an engine made: mono float samples.
public struct SpeechAudio: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int
    public init(samples: [Float], sampleRate: Int) { self.samples = samples; self.sampleRate = sampleRate }
    public var duration: TimeInterval { sampleRate > 0 ? Double(samples.count) / Double(sampleRate) : 0 }
    /// 16-bit PCM WAV, which `AVAudioPlayer` plays.
    public var wav: Data {
        var data = Data(capacity: 44 + samples.count * 2)
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(UInt32(36) + bytes)
        data.append(contentsOf: Array("WAVE".utf8)); data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16)); append(UInt16(1)); append(UInt16(1)); append(UInt32(sampleRate))
        append(UInt32(sampleRate * 2)); append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(Int16(max(-1, min(1, sample.isFinite ? sample : 0)) * Float(Int16.max))) }
        return data
    }
}

public enum SpeechEngineError: Error, Equatable, LocalizedError {
    case notInstalled, unsupportedHardware, emptyText, inBackground, synthesisFailed(String)
    public var errorDescription: String? {
        switch self {
        case .notInstalled: "The voice model isn’t downloaded."
        case .unsupportedHardware: "This voice needs Apple silicon with Metal; it can’t run in the Simulator."
        case .emptyText: "Nothing to say."
        case .inBackground: "On-device voices speak only while the app is open."
        case .synthesisFailed(let reason): "The voice couldn’t speak: \(reason)"
        }
    }
}

/// Every reply voice, on iPhone and Mac.
@MainActor public protocol SpeechEngine: AnyObject {
    /// Speaks `text` into audio without playing it.
    func synthesize(_ text: String) async throws -> SpeechAudio
}

// MARK: The voices

/// The Kokoro voices in the download (American English, which the bundled G2P covers). Each bot speaks
/// with one of them; where Kokoro can't run, Apple's closest voice stands in (`AppleVoices.closest`).
public enum KokoroVoices {
    public struct Voice: Identifiable, Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        public let detail: String
        /// Kokoro's voice IDs start "af_" (a woman's voice) or "am_" (a man's).
        public var isMasculine: Bool { id.hasPrefix("am_") }
    }
    public static let all: [Voice] = [
        .init(id: "af_heart", name: "Heart", detail: "Warm"),
        .init(id: "af_bella", name: "Bella", detail: "Bright"),
        .init(id: "af_nicole", name: "Nicole", detail: "Soft, close"),
        .init(id: "af_aoede", name: "Aoede", detail: "Calm"),
        .init(id: "af_kore", name: "Kore", detail: "Clear"),
        .init(id: "af_sarah", name: "Sarah", detail: "Even"),
        .init(id: "am_fenrir", name: "Fenrir", detail: "Deep"),
        .init(id: "am_michael", name: "Michael", detail: "Friendly"),
        .init(id: "am_puck", name: "Puck", detail: "Playful"),
    ]
    public static let defaultID = "af_heart"
    public static func normalized(_ id: String?) -> String {
        guard let id, all.contains(where: { $0.id == id }) else { return defaultID }
        return id
    }
    public static func voice(_ id: String?) -> Voice {
        let wanted = normalized(id)
        return all.first { $0.id == wanted } ?? all[0]
    }

    /// The voice a bot speaks with: the one the owner picked, or one chosen for it from its ID, so bots
    /// sound different from each other without anyone choosing. KemoSabe is Heart until the owner picks.
    public static func voice(for bot: BotSpec) -> Voice {
        if let chosen = bot.voice, all.contains(where: { $0.id == chosen }) { return voice(chosen) }
        if bot.isKemoSabe { return voice(defaultID) }
        // A stable pick from the ID's bytes (never Heart, which is KemoSabe's).
        let bytes = withUnsafeBytes(of: bot.id.uuid) { Array($0) }
        let others = all.dropFirst()
        let index = bytes.reduce(0) { ($0 &* 31 &+ Int($1)) % 9973 } % others.count
        return others[others.startIndex + index]
    }
}

/// Apple's installed voices, best first (ported from the old app's `VoiceCatalog`): English, never novelty
/// or Personal Voice, Premium before Enhanced before Standard, the owner's region first.
public enum AppleVoices {
    public struct Option: Equatable, Sendable {
        public enum Quality: Int, Comparable, Sendable {
            case standard, enhanced, premium
            public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
            public var title: String { self == .premium ? "Premium" : self == .enhanced ? "Enhanced" : "Standard" }
        }
        public enum Gender: Sendable { case feminine, masculine, unknown }
        public let identifier: String
        public let name: String
        public let language: String
        public let quality: Quality
        public let gender: Gender
        public let isNovelty: Bool
        public let isPersonal: Bool
        public init(identifier: String, name: String, language: String, quality: Quality, gender: Gender = .unknown,
                    isNovelty: Bool = false, isPersonal: Bool = false) {
            self.identifier = identifier; self.name = name; self.language = language; self.quality = quality
            self.gender = gender; self.isNovelty = isNovelty; self.isPersonal = isPersonal
        }
    }

    public static func ranked(_ options: [Option], preferredLanguage: String) -> [Option] {
        options.filter { languageCode($0.language) == "en" && !$0.isNovelty && !$0.isPersonal }.sorted { lhs, rhs in
            if lhs.quality != rhs.quality { return lhs.quality > rhs.quality }
            let left = localeScore(lhs.language, preferred: preferredLanguage), right = localeScore(rhs.language, preferred: preferredLanguage)
            if left != right { return left > right }
            let order = lhs.name.localizedCaseInsensitiveCompare(rhs.name)
            if order != .orderedSame { return order == .orderedAscending }
            return lhs.identifier < rhs.identifier
        }
    }
    /// Apple's best voice that sounds most like a Kokoro voice: the best quality first, then one of the same
    /// kind (a man's or a woman's voice), so bots still sound different when Kokoro isn't here.
    public static func closest(to voice: KokoroVoices.Voice, in ranked: [Option]) -> Option? {
        guard let best = ranked.first else { return nil }
        let wanted: Option.Gender = voice.isMasculine ? .masculine : .feminine
        let sameQuality = ranked.filter { $0.quality == best.quality }
        let matches = sameQuality.filter { $0.gender == wanted }
        let pool = matches.isEmpty ? sameQuality : matches
        // Spread the voices of one kind across what's installed.
        let kind = KokoroVoices.all.filter { $0.isMasculine == voice.isMasculine }
        let index = (kind.firstIndex(of: voice) ?? 0) % max(1, pool.count)
        return pool[index]
    }

    /// What this device has installed.
    public static var installed: [Option] {
        ranked(AVSpeechSynthesisVoice.speechVoices().map(option), preferredLanguage: preferredEnglishLanguage)
    }
    public static func option(_ voice: AVSpeechSynthesisVoice) -> Option {
        let quality: Option.Quality = voice.quality == .premium ? .premium : voice.quality == .enhanced ? .enhanced : .standard
        let gender: Option.Gender = voice.gender == .male ? .masculine : voice.gender == .female ? .feminine : .unknown
        return Option(identifier: voice.identifier, name: voice.name, language: voice.language, quality: quality, gender: gender,
                      isNovelty: voice.voiceTraits.contains(.isNoveltyVoice), isPersonal: voice.voiceTraits.contains(.isPersonalVoice))
    }
    /// The speaking pace (0.40 to 0.56; natural is 0.48) as Apple's rate.
    public static func rate(_ pace: Double) -> Float { Float(min(0.56, max(0.40, pace))) }
    /// The pace as Kokoro's speed (0.7 to 1.4).
    public static func kokoroSpeed(_ pace: Double) -> Float { Float(min(1.4, max(0.7, 1 + (pace - 0.48) * 3))) }

    static var preferredEnglishLanguage: String { Locale.preferredLanguages.first { languageCode($0) == "en" } ?? "en-US" }
    static func languageCode(_ identifier: String) -> String {
        if let code = Locale.Language(identifier: identifier).languageCode?.identifier { return code.lowercased() }
        return identifier.replacingOccurrences(of: "_", with: "-").split(separator: "-").first.map { String($0).lowercased() } ?? ""
    }
    private static func localeScore(_ language: String, preferred: String) -> Int {
        guard languageCode(language) == languageCode(preferred) else { return 0 }
        let region = Locale.Language(identifier: language).region?.identifier.lowercased()
        let wanted = Locale.Language(identifier: preferred).region?.identifier.lowercased()
        return region != nil && region == wanted ? 2 : 1
    }
}

// MARK: Engines

/// Apple's on-device voices, rendered into samples so every voice plays (and stops) the same way.
@MainActor public final class AppleSpeechEngine: SpeechEngine {
    public let voiceID: String?
    public let pace: Double
    private let synthesizer = AVSpeechSynthesizer()
    public init(voiceID: String?, pace: Double) { self.voiceID = voiceID; self.pace = pace }

    public func synthesize(_ text: String) async throws -> SpeechAudio {
        let prepared = SpeechText.prepared(text)
        guard !prepared.isEmpty else { throw SpeechEngineError.emptyText }
        let utterance = AVSpeechUtterance(string: prepared)
        utterance.voice = voiceID.flatMap(AVSpeechSynthesisVoice.init(identifier:)) ?? AVSpeechSynthesisVoice(language: AppleVoices.preferredEnglishLanguage)
        utterance.rate = AppleVoices.rate(pace)
        utterance.preUtteranceDelay = 0; utterance.postUtteranceDelay = 0
        let collector = BufferCollector()
        return try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    guard let result = collector.finish() else { return }
                    if result.samples.isEmpty { continuation.resume(throwing: SpeechEngineError.synthesisFailed("no audio")) }
                    else { continuation.resume(returning: result) }
                } else { collector.append(pcm) }
            }
        }
    }
    /// Gathers the synthesizer's buffers as mono floats. The final, empty buffer ends it once.
    private final class BufferCollector: @unchecked Sendable {
        private var samples: [Float] = []
        private var rate = 0
        private var done = false
        func append(_ buffer: AVAudioPCMBuffer) {
            rate = Int(buffer.format.sampleRate)
            let count = Int(buffer.frameLength)
            if let floats = buffer.floatChannelData { samples.append(contentsOf: UnsafeBufferPointer(start: floats[0], count: count)) }
            else if let ints = buffer.int16ChannelData {
                samples.append(contentsOf: UnsafeBufferPointer(start: ints[0], count: count).map { Float($0) / Float(Int16.max) })
            }
        }
        func finish() -> SpeechAudio? {
            guard !done else { return nil }
            done = true
            return SpeechAudio(samples: samples, sampleRate: rate)
        }
    }
}

/// Kokoro-82M on this device, through the app's MLX runtime, after the one download consent.
@MainActor public final class KokoroSpeechEngine: SpeechEngine {
    let runtime: any NeuralVoiceRuntime
    let folder: URL
    let voice: String
    let speed: Float
    public init(runtime: any NeuralVoiceRuntime, folder: URL, voice: String, pace: Double) {
        self.runtime = runtime; self.folder = folder; self.voice = KokoroVoices.normalized(voice); self.speed = AppleVoices.kokoroSpeed(pace)
    }
    public func synthesize(_ text: String) async throws -> SpeechAudio {
        let prepared = SpeechText.prepared(text)
        guard !prepared.isEmpty else { throw SpeechEngineError.emptyText }
        return try await runtime.speak(prepared, voice: voice, speed: speed, kokoroFolder: folder)
    }
}

/// The models that need MLX on the GPU (Whisper and Kokoro), supplied by the app (`TsukumoMLXVoice`), so
/// TsukumoKit keeps no package dependencies and its tests never load a model. Nothing here touches the
/// network: the models come only from `VoiceModelStore`, verified against their pins.
public protocol NeuralVoiceRuntime: Sendable {
    /// A Metal GPU that MLX can use (not the Simulator).
    var isSupported: Bool { get }
    /// Whisper's reading of 16 kHz mono samples.
    func transcribe(_ samples: [Float], whisperFolder: URL) async throws -> String
    /// Loads Whisper ahead of the first utterance, so the first answer isn't a cold start.
    func prepareWhisper(folder: URL) async
    /// Kokoro speaking `text` in `voice`.
    func speak(_ text: String, voice: String, speed: Float, kokoroFolder: URL) async throws -> SpeechAudio
    /// Frees the loaded models (memory pressure, removing them).
    func unload() async
}
