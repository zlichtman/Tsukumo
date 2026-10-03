import AVFoundation
import Observation

/// Reads replies aloud in the iPhone's voice and pace when this watch has that
/// voice, otherwise in a voice for the same language. The next request stops it.
@MainActor @Observable final class WatchSpeaker: NSObject, AVSpeechSynthesizerDelegate {
    @ObservationIgnored private let synthesizer = AVSpeechSynthesizer()
    private(set) var speaking = false

    override init() {
        super.init()
        synthesizer.delegate = self
    }
    func speak(_ text: String, voice: WatchLink.Voice?) {
        stop()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .voicePrompt)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        if let voice {
            utterance.voice = Self.voice(for: voice)
            utterance.rate = voice.rate
        }
        synthesizer.speak(utterance)
        speaking = true
    }
    /// The iPhone's voice if it is on this watch, otherwise one in the same language.
    nonisolated static func voice(for voice: WatchLink.Voice) -> AVSpeechSynthesisVoice? {
        AVSpeechSynthesisVoice(identifier: voice.identifier) ?? AVSpeechSynthesisVoice(language: voice.language)
    }
    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        speaking = false
    }
    private func finished() {
        guard !synthesizer.isSpeaking else { return }
        speaking = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in self.finished() }
    }
}
