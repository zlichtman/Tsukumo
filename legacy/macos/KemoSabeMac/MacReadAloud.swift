import AppKit
import AVFoundation
import Observation

/// Reads Kemo's replies aloud on this Mac, in the reply voice chosen in Models → Voice (the same
/// `SpeechEngine` routing as the iPhone): the Apple voice by default and as the fallback, Kokoro
/// or your own voice on this Mac once downloaded, or an OpenAI voice only after its opt-in naming
/// api.openai.com. Replies are read automatically when "Read Kemo's replies aloud" is on, and any
/// reply can be read from its context menu. Dictation and sending a message stop it.
@MainActor @Observable final class MacReadAloud: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = MacReadAloud()
    static let enabledKey = "kemo.voice.macReadAloud"

    /// Read each new reply aloud. Off by default; saved with the account's settings.
    private(set) var enabled: Bool
    /// The message being read, for its Stop item.
    private(set) var speaking: UUID?
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    @ObservationIgnored private let player = SpeechPlayer()
    @ObservationIgnored private var appleUtterance: AVSpeechUtterance?

    override init() {
        enabled = AccountDirectory.accountSettings.bool(forKey: Self.enabledKey)
        super.init()
        synthesizer.delegate = self
    }

    func setEnabled(_ on: Bool) {
        AccountDirectory.accountSettings.set(on, forKey: Self.enabledKey)
        enabled = on
        if !on { stop() }
    }
    /// Re-reads the saved choice after an account switch.
    func reload() { stop(); enabled = AccountDirectory.accountSettings.bool(forKey: Self.enabledKey); SpeechVoices.shared.reload() }

    /// Reads `text` in the chosen voice. Anything that can't speak falls back to the Apple voice.
    func speak(_ text: String, id: UUID?, store: AppStore) {
        stop()
        guard !SpeechText.prepared(text).isEmpty else { return }
        speaking = id
        let voices = SpeechVoices.shared
        let key = CloudVoice.key(in: store)
        let route = voices.route(openAIVoice: CloudVoice.activeVoice(in: store))
        switch route {
        case .apple:
            speakApple(text, store: store)
        case .openAI(let voice):
            play(text, engine: OpenAISpeechEngine(key: key), voice: voice, store: store)
        case .kokoro, .ownVoice:
            play(text, engine: voices.engine(for: route, appleRate: store.state.speechRate), voice: voices.persona.kokoroVoice, store: store)
        }
    }
    func stop() {
        player.stop()
        appleUtterance = nil
        synthesizer.stopSpeaking(at: .immediate)
        speaking = nil
    }

    private func play(_ text: String, engine: any SpeechEngine, voice: String?, store: AppStore) {
        let id = speaking
        player.play(text, engine: engine, voice: voice) { [weak self] error, unspoken in
            guard let self, self.speaking == id else { return }
            if error != nil, !unspoken.isEmpty { self.speakApple(unspoken.joined(separator: " "), store: store); return }
            self.speaking = nil
        }
    }
    private func speakApple(_ text: String, store: AppStore) {
        let utterance = VoiceCatalog.utterance(for: text, voiceID: nil, rate: store.state.speechRate)
        appleUtterance = utterance
        synthesizer.speak(utterance)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in if utterance === self.appleUtterance { self.appleUtterance = nil; self.speaking = nil } }
    }
}
