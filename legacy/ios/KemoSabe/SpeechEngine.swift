import Foundation
import AVFoundation

/// The boundary every reply voice sits behind, on iPhone and Mac: Apple's on-device voices (the
/// fallback), Kokoro-82M (an on-device download), the person's own voice (an on-device clone made
/// only from a live recording with spoken consent), and OpenAI's voices (an opt-in that names
/// api.openai.com). Apple Watch keeps speaking with the Apple voices
/// it runs itself; none of these engines run on the watch.
@MainActor protocol SpeechEngine: AnyObject {
    var kind: SpeechEngineKind { get }
    /// Where the text goes to be spoken, or nil when it never leaves this device.
    var destination: String? { get }
    /// Ready to speak now: installed, supported on this hardware, and (for OpenAI) connected.
    var isAvailable: Bool { get }
    var voices: [SpeechVoiceOption] { get }
    /// Speaks `text` into audio without playing it. The caller plays it.
    func synthesize(_ text: String, voice: String?) async throws -> SpeechAudio
}

enum SpeechEngineKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case apple, openAI, kokoro, ownVoice
    var id: String { rawValue }
    var title: String {
        switch self {
        case .apple: "Apple voice"
        case .openAI: "OpenAI voice"
        case .kokoro: "Kokoro"
        case .ownVoice: "Your voice (cloned)"
        }
    }
    /// Where text goes to be spoken; nil for engines that run on this device.
    var destination: String? { self == .openAI ? CloudVoice.host : nil }
}

struct SpeechVoiceOption: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let detail: String
}

enum SpeechEngineError: Error, Equatable, LocalizedError {
    case notInstalled, unsupportedHardware, notEnrolled, emptyText, inBackground, synthesisFailed(String)
    var errorDescription: String? {
        switch self {
        case .notInstalled: "The voice model isn't downloaded."
        case .unsupportedHardware: "This voice needs Apple silicon with Metal; it can't run in the Simulator."
        case .notEnrolled: "Record your voice first."
        case .emptyText: "Nothing to say."
        case .inBackground: "On-device voices speak only while the app is open."
        case .synthesisFailed(let reason): "The voice couldn't speak: \(reason)"
        }
    }
}

/// Audio an engine made: mono float samples, or an encoded file.
struct SpeechAudio: Sendable {
    enum Payload: Sendable { case pcm([Float], sampleRate: Int), encoded(Data) }
    let payload: Payload

    var duration: TimeInterval {
        if case .pcm(let samples, let rate) = payload, rate > 0 { return Double(samples.count) / Double(rate) }
        return 0
    }
    /// Something `AVAudioPlayer` can play: the encoded file, or 16-bit PCM WAV.
    func playableData() -> Data {
        switch payload {
        case .encoded(let data): return data
        case .pcm(let samples, let rate): return Self.wav(samples, sampleRate: rate)
        }
    }
    static func wav(_ samples: [Float], sampleRate: Int) -> Data {
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

// MARK: - Which engine speaks and listens

/// Which voice the companion sounds like: one of Kokoro's voices, or the person's own. The one voice
/// choice there is, on the Companion page; saved with the account's settings, so it syncs to the
/// person's other devices (`AccountSettingsAdapter`). Which model speaks it is never a choice
/// (`VoiceAuto`).
enum VoicePersona: Equatable, Sendable {
    case kokoro(String), own
    static let key = "kemo.voice.persona"
    /// The keys it replaced: the chosen engine and Kokoro voice (both before September 30, 2026).
    static let legacyEngineKey = "kemo.voice.replyEngine", legacyKokoroKey = "kemo.voice.kokoroVoice"
    var stored: String {
        switch self {
        case .own: "own"
        case .kokoro(let id): KokoroVoices.normalized(id)
        }
    }
    init(stored: String?) { self = stored == "own" ? .own : .kokoro(KokoroVoices.normalized(stored)) }
    /// The Kokoro voice to speak with: the chosen one, or the default while the person's own voice
    /// can't speak here.
    var kokoroVoice: String {
        if case .kokoro(let id) = self { return KokoroVoices.normalized(id) }
        return KokoroVoices.defaultID
    }
    static func stored(in defaults: UserDefaults) -> VoicePersona {
        if let saved = defaults.string(forKey: key) { return VoicePersona(stored: saved) }
        // Someone who chose their own voice before keeps it; everyone else keeps their Kokoro voice.
        if defaults.string(forKey: legacyEngineKey) == "ownVoice" { return .own }
        return .kokoro(KokoroVoices.normalized(defaults.string(forKey: legacyKokoroKey)))
    }
    /// "Heart", "Your voice (cloned)", or "Apple" where neither can run.
    func title(neuralSupported: Bool) -> String {
        guard neuralSupported else { return "Apple" }
        switch self {
        case .own: return SpeechEngineKind.ownVoice.title
        case .kokoro(let id): return KokoroVoices.voice(id).name
        }
    }
    static var current: VoicePersona {
        get { stored(in: AccountDirectory.accountSettings) }
        set { AccountDirectory.accountSettings.set(newValue.stored, forKey: key) }
    }
}

/// The voice models this device uses: always the best it can run, never a choice (the owner,
/// September 30, 2026: "no one wants a worse model"). Listening: Whisper on this device once it's
/// downloaded and the device can run it, otherwise Apple's recognizer. Speaking: the person's own
/// voice when that's the voice they chose and it's ready, otherwise Kokoro once it's downloaded and the
/// device can run it, otherwise Apple's best installed voice. The one exception is the OpenAI opt-in
/// (`CloudVoice`): while it's on and connected, it replaces only the part the person turned on.
enum VoiceAuto {
    /// What this device has and can run.
    struct Device: Equatable, Sendable {
        /// A Metal GPU that MLX can use (not the Simulator).
        var neuralSupported: Bool
        /// iPhone: the app is in front, so the GPU is available. Always true on Mac.
        var canRunNow = true
        var whisperInstalled: Bool
        var kokoroInstalled: Bool
        /// The Your voice model is downloaded and the person's voice is made.
        var ownVoiceReady: Bool
    }
    enum Listening: Equatable, Sendable { case whisper, apple, openAI(CloudVoice.Transcriber) }
    /// `openAI` is the OpenAI transcriber opted into and connected (`CloudVoice.activeTranscriber`).
    static func listening(_ device: Device, openAI: CloudVoice.Transcriber? = nil) -> Listening {
        if let openAI { return .openAI(openAI) }
        return device.neuralSupported && device.whisperInstalled ? .whisper : .apple
    }
    /// `openAIVoice` is the OpenAI voice opted into and connected (`CloudVoice.activeVoice`).
    static func speaking(_ device: Device, persona: VoicePersona, openAIVoice: String? = nil) -> SpeechRouting.Route {
        if let openAIVoice { return .openAI(voice: openAIVoice) }
        guard device.neuralSupported, device.canRunNow else { return .apple }
        if persona == .own, device.ownVoiceReady { return .ownVoice }
        if device.kokoroInstalled { return .kokoro(voice: persona.kokoroVoice) }
        return .apple
    }
    /// The better models this device could run and doesn't have yet, largest first. Empty where MLX
    /// can't run, since Apple's models are already the best there.
    static func missing(_ device: Device) -> [VoiceModelPack] {
        guard device.neuralSupported else { return [] }
        return [device.whisperInstalled ? nil : VoiceModelPack.whisper, device.kokoroInstalled ? nil : VoiceModelPack.kokoro].compactMap { $0 }
    }
    /// "Whisper · on this device", for the page.
    static func listeningTitle(_ listening: Listening) -> String {
        switch listening {
        case .whisper: "Whisper · on this device"
        case .apple: "Apple · on this device"
        case .openAI(let model): model.menuTitle
        }
    }
    static func speakingTitle(_ route: SpeechRouting.Route, appleVoice: String?) -> String {
        switch route {
        case .ownVoice: SpeechEngineKind.ownVoice.title + " · on this device"
        case .kokoro(let voice): "Kokoro · " + KokoroVoices.voice(voice).name
        case .openAI(let voice): "OpenAI · \(voice.capitalized) · \(CloudVoice.host)"
        case .apple: "Apple · " + (appleVoice ?? "on this device")
        }
    }
}

/// The engine speaking a reply now. Anything not ready falls back to the Apple voice on this device.
enum SpeechRouting {
    enum Route: Equatable, Sendable {
        case apple, openAI(voice: String), kokoro(voice: String), ownVoice
        var kind: SpeechEngineKind {
            switch self {
            case .apple: .apple
            case .openAI: .openAI
            case .kokoro: .kokoro
            case .ownVoice: .ownVoice
            }
        }
    }
}

/// Splits a reply into sentences for engines that speak best a sentence at a time, so the first
/// sentence plays while the next is made. Long sentences are cut at a comma or space.
enum SpeechChunks {
    static func sentences(_ text: String, maxCharacters: Int = 300) -> [String] {
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
}

// MARK: - Apple and OpenAI behind the boundary

/// Apple's on-device voices. Live replies on iPhone still go straight to `AVSpeechSynthesizer`
/// so captions can follow each spoken word; this renders the same utterance into samples.
@MainActor final class AppleSpeechEngine: SpeechEngine {
    let kind = SpeechEngineKind.apple
    let destination: String? = nil
    var isAvailable: Bool { true }
    var rate: Double?
    private let synthesizer = AVSpeechSynthesizer()
    init(rate: Double? = nil) { self.rate = rate }
    var voices: [SpeechVoiceOption] {
        VoiceCatalog.available.map { .init(id: $0.identifier, name: $0.name, detail: $0.language + " · " + VoiceCatalog.quality($0)) }
    }
    func synthesize(_ text: String, voice: String?) async throws -> SpeechAudio {
        let prepared = SpeechText.prepared(text)
        guard !prepared.isEmpty else { throw SpeechEngineError.emptyText }
        let utterance = VoiceCatalog.utterance(for: prepared, voiceID: voice, rate: rate)
        let collector = BufferCollector()
        return try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    guard let result = collector.finish() else { continuation.resume(throwing: SpeechEngineError.synthesisFailed("no audio")); return }
                    continuation.resume(returning: result)
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
            return samples.isEmpty ? nil : SpeechAudio(payload: .pcm(samples, sampleRate: rate))
        }
    }
}

/// OpenAI's reply voices, through the person's OpenAI connection. Used only after the
/// opt-in that names api.openai.com (Companion → Voice).
@MainActor final class OpenAISpeechEngine: SpeechEngine {
    let kind = SpeechEngineKind.openAI
    var destination: String? { CloudVoice.host }
    private let key: String?
    init(key: String?) { self.key = key }
    var isAvailable: Bool { key?.isEmpty == false }
    var voices: [SpeechVoiceOption] { CloudVoice.voices.map { .init(id: $0, name: $0.capitalized, detail: "OpenAI · " + CloudVoice.speechModel) } }
    func synthesize(_ text: String, voice: String?) async throws -> SpeechAudio {
        guard let key, !key.isEmpty else { throw SpeechEngineError.notInstalled }
        let prepared = SpeechText.prepared(text)
        guard !prepared.isEmpty else { throw SpeechEngineError.emptyText }
        let chosen = voice.flatMap { CloudVoice.voices.contains($0) ? $0 : nil } ?? CloudVoice.voices[0]
        return SpeechAudio(payload: .encoded(try await OpenAIAudio(key: key).speech(prepared, voice: chosen)))
    }
}
