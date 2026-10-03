import Foundation
import AVFoundation

/// OpenAI for voice, an opt-in under Companion → Voice (the owner, September 30, 2026): off by default,
/// and never a model menu. Each part is its own switch: speaking replies in an OpenAI voice, and
/// transcribing what you say with an OpenAI model. Turning either on first confirms, naming
/// api.openai.com and what goes there, and uses the key of the OpenAI connection in Models → LLM.
/// While one is on (and that connection's key is on this device) it replaces only that part of the
/// automatic on-device choice (`VoiceAuto`); everything else stays automatic.
enum CloudVoice {
    /// OpenAI's transcription models. The saved value shares the key the old Transcription menu used,
    /// so anyone who chose one keeps it; the old on-device values read as off.
    enum Transcriber: String, CaseIterable, Identifiable, Sendable {
        case gpt4oTranscribe = "gpt-4o-transcribe", gpt4oMiniTranscribe = "gpt-4o-mini-transcribe", whisper = "whisper-1"
        var id: String { rawValue }
        var title: String {
            switch self {
            case .gpt4oTranscribe: "GPT-4o Transcribe"
            case .gpt4oMiniTranscribe: "GPT-4o mini Transcribe"
            case .whisper: "Whisper (OpenAI)"
            }
        }
        /// Names where the audio goes.
        var menuTitle: String { "\(title) · \(CloudVoice.host)" }
    }
    /// OpenAI's reply voices, spoken by its text-to-speech model.
    static let voices = ["coral", "nova", "sage", "shimmer", "alloy", "ash", "ballad", "echo", "fable", "onyx", "verse"]
    static let speechModel = "gpt-4o-mini-tts"
    static let host = "api.openai.com"

    static let transcriberKey = "kemo.voice.transcriber", speakingKey = "kemo.voice.openAISpeaking"
    static let voiceKey = "kemo.voice.openAIVoice", legacyEngineKey = "kemo.voice.replyEngine"
    private static var settings: UserDefaults { AccountDirectory.accountSettings }

    /// The OpenAI transcriber opted into, or nil for the automatic on-device choice.
    static func transcriber(in defaults: UserDefaults) -> Transcriber? { defaults.string(forKey: transcriberKey).flatMap(Transcriber.init(rawValue:)) }
    static var transcriber: Transcriber? {
        get { transcriber(in: settings) }
        set { if let newValue { settings.set(newValue.rawValue, forKey: transcriberKey) } else { settings.removeObject(forKey: transcriberKey) } }
    }
    /// Speaking replies in an OpenAI voice is on. Before it was a switch, it was the chosen engine
    /// ("openAI"), or an OpenAI voice saved before engines existed; both keep it on.
    static func speaking(in defaults: UserDefaults) -> Bool {
        if let saved = defaults.object(forKey: speakingKey) as? Bool { return saved }
        if let engine = defaults.string(forKey: legacyEngineKey) { return engine == "openAI" }
        return defaults.string(forKey: voiceKey).map(voices.contains) == true
    }
    static var speaking: Bool {
        get { speaking(in: settings) }
        set { settings.set(newValue, forKey: speakingKey) }
    }
    /// The OpenAI voice to speak with (coral until one is picked).
    static var replyVoice: String {
        get { settings.string(forKey: voiceKey).flatMap { voices.contains($0) ? $0 : nil } ?? voices[0] }
        set { settings.set(voices.contains(newValue) ? newValue : voices[0], forKey: voiceKey) }
    }
    /// The OpenAI connection whose Keychain key these use.
    @MainActor static func connection(in store: AppStore) -> APIModelProfile? {
        (store.state.apiProfiles ?? []).first { $0.wire == .openAICompatible && $0.endpoint.host == host }
    }
    @MainActor static func key(in store: AppStore) -> String? {
        connection(in: store).flatMap { try? KeychainAPIKeys().read($0.id) }
    }
    /// What's in use now: the opted-in part, only while the OpenAI connection's key is on this device.
    @MainActor static func activeTranscriber(in store: AppStore?) -> Transcriber? {
        guard let transcriber, let store, key(in: store) != nil else { return nil }
        return transcriber
    }
    @MainActor static func activeVoice(in store: AppStore?) -> String? {
        guard speaking, let store, key(in: store) != nil else { return nil }
        return replyVoice
    }
}

/// OpenAI's audio endpoints: transcription and speech.
struct OpenAIAudio {
    let key: String
    var session: URLSession = .shared
    enum Failure: Error { case rejected, unreachable }

    /// Sends one recorded utterance or clip and returns its text.
    func transcribe(_ audio: Data, fileName: String, model: CloudVoice.Transcriber) async throws -> String {
        guard !audio.isEmpty, audio.count <= 24_000_000 else { throw Failure.rejected }
        let boundary = "kemo-" + UUID().uuidString
        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", model.rawValue)
        field("response_format", "json")
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\nContent-Type: application/octet-stream\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://\(CloudVoice.host)/v1/audio/transcriptions")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        struct Reply: Decodable { let text: String }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let reply = try? JSONDecoder().decode(Reply.self, from: data) else { throw Failure.rejected }
        return reply.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Speaks text in an OpenAI voice and returns AAC audio to play.
    func speech(_ text: String, voice: String) async throws -> Data {
        struct Body: Encodable { let model: String; let voice: String; let input: String; let response_format = "aac"
            let instructions = "Speak warmly and naturally, like a friendly companion." }
        var request = URLRequest(url: URL(string: "https://\(CloudVoice.host)/v1/audio/speech")!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(model: CloudVoice.speechModel, voice: voice, input: String(text.prefix(4000))))
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { throw Failure.rejected }
        return data
    }
}

extension UtteranceRecorder {
    /// The utterance as a WAV file's bytes, then cleared (for OpenAI transcription).
    func take() -> Data? {
        let taken = takeBuffers()
        guard let format = taken.first?.format else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("utterance-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
            for buffer in taken { try file.write(from: buffer) }
        } catch { return nil }
        return try? Data(contentsOf: url)
    }
}
