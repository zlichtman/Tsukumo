import AppKit
import AVFoundation
import Speech
import Observation

private final class MacSpeechSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = value; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
}

/// Deliberate local dictation. The full utterance goes into the visible composer
/// for review; only Send submits it to the selected model.
@MainActor @Observable final class MacVoiceInput {
    private(set) var listening = false
    private(set) var authorizing = false
    private(set) var status = ""
    private let engine = AVAudioEngine()
    private let sink = MacSpeechSink()
    private var task: SFSpeechRecognitionTask?
    private var generation = UUID()
    private var tapInstalled = false
    private var timeout: Task<Void, Never>?
    private(set) var transcribing = false
    private let recorder = UtteranceRecorder()
    /// The OpenAI key for OpenAI transcription, when the person turned it on in Companion → Voice.
    private var cloudKey: String?
    /// The OpenAI transcriber opted into in Companion → Voice, for this dictation.
    private var cloudModel: CloudVoice.Transcriber?
    /// On-device Whisper is on this Mac (`VoiceAuto`): the dictation's audio is
    /// kept in memory so Whisper can read it again when it ends.
    private var whisperRecording = false
    /// Apple's latest words for this dictation, kept if Whisper can't finish.
    private var appleText = ""
    var onText: ((String) -> Void)?
    /// Returns the OpenAI connection's key; set by the window, which owns the app state.
    var cloudKeyProvider: (@MainActor () -> String?)?
    func toggle() {
        if listening, cloudKey != nil { finishCloud(); return }
        if listening, whisperRecording { finishWhisper(); return }
        if listening || authorizing || transcribing { stop(); return }
        authorizing = true; let run = UUID(); generation = run
        cloudModel = CloudVoice.transcriber
        cloudKey = cloudModel != nil ? cloudKeyProvider?() : nil
        whisperRecording = cloudKey == nil && OnDeviceWhisper.shouldRun(.dictation)
        appleText = ""
        if whisperRecording { OnDeviceWhisper.prewarm() }
        Task {
            let microphone = await AVCaptureDevice.requestAccess(for: .audio)
            guard generation == run else { return }
            guard microphone else { authorizing = false; status = "Allow microphone access in System Settings to dictate."; return }
            if cloudKey != nil { startCloud(run); return }
            let speech = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
            guard generation == run, NSApp.isActive else { stop(); return }
            authorizing = false
            guard speech == .authorized, let recognizer = SFSpeechRecognizer(locale: .init(identifier: "en-US")),
                  recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else {
                status = "On-device English dictation is unavailable. You can still type."; return
            }
            do {
                let request = SFSpeechAudioBufferRecognitionRequest()
                request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
                sink.set(request)
                recorder.reset(enabled: whisperRecording)
                let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
                guard format.sampleRate > 0, format.channelCount > 0 else { throw APIModelError.unavailable }
                input.installTap(onBus: 0, bufferSize: 1024, format: format) { [sink, recorder] buffer, _ in sink.append(buffer); recorder.append(buffer) }
                tapInstalled = true; engine.prepare(); try engine.start(); listening = true
                // The composer shows listening ("Listening…" and the microphone's orb); no second line.
                status = ""
                task = recognizer.recognitionTask(with: request) { [weak self] result, error in
                    let text = result?.bestTranscription.formattedString; let final = result?.isFinal == true; let failed = error != nil
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        if let text, !text.isEmpty { self.appleText = text; self.onText?(text) }
                        if final || failed {
                            if self.whisperRecording { self.finishWhisper(); return }
                            self.stop(); self.status = failed ? "Dictation stopped. Review the text before sending." : "Review your message, then send."
                        }
                    }
                }
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(55)) } catch { return }
                    guard let self, self.generation == run else { return }
                    if self.whisperRecording { self.finishWhisper(); return }
                    self.stop(); self.status = "Review your message, then send."
                }
            } catch { stop(); status = "The microphone couldn’t start. Check its connection and try again." }
        }
    }
    /// The dictation ended (the mic was tapped, or Apple's recognizer finished): Whisper reads
    /// the audio again on this Mac and its text replaces Apple's in the message box. Apple's
    /// text stays if Whisper fails or runs past its timeout. The audio never leaves this Mac.
    private func finishWhisper() {
        let buffers = recorder.takeBuffers(), apple = appleText
        stopCapture()
        recorder.reset(enabled: false); whisperRecording = false
        let run = UUID(); generation = run
        guard !buffers.isEmpty else { status = apple.isEmpty ? "" : "Review your message, then send."; return }
        transcribing = true
        Task {
            let final = await OnDeviceWhisper.finalText(apple: apple, buffers: buffers, surface: .dictation)
            guard generation == run else { return }
            transcribing = false
            if !final.text.isEmpty { onText?(final.text) }
            status = final.text.isEmpty ? "" : "Review your message, then send."
        }
    }
    /// Records the utterance for the OpenAI transcriber (opted into in Companion → Voice); the
    /// audio is sent to api.openai.com only when the person finishes.
    private func startCloud(_ run: UUID) {
        guard NSApp.isActive else { stop(); return }
        authorizing = false
        do {
            recorder.reset(enabled: true)
            let input = engine.inputNode; let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw APIModelError.unavailable }
            input.installTap(onBus: 0, bufferSize: 1024, format: format) { [recorder] buffer, _ in recorder.append(buffer) }
            tapInstalled = true; engine.prepare(); try engine.start(); listening = true
            status = "Recording for \(cloudModel?.title ?? "OpenAI") · tap mic to finish"
            timeout = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(55)) } catch { return }
                guard let self, self.generation == run else { return }; self.finishCloud()
            }
        } catch { stop(); status = "The microphone couldn’t start. Check its connection and try again." }
    }
    private func finishCloud() {
        let key = cloudKey
        stopCapture()
        guard let key, let model = cloudModel, let audio = recorder.take() else { status = "Nothing was recorded. Try again."; return }
        let run = UUID(); generation = run; transcribing = true
        status = "Transcribing with \(model.title)…"
        Task {
            let text = try? await OpenAIAudio(key: key).transcribe(audio, fileName: "dictation.wav", model: model)
            guard generation == run else { return }
            transcribing = false
            if let text, !text.isEmpty { onText?(text); status = "Review your message, then send." }
            else { status = "\(model.title) couldn’t transcribe that. Try again, or type." }
        }
    }
    private func stopCapture() {
        timeout?.cancel(); timeout = nil; sink.set(nil)
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        task?.cancel(); task = nil; listening = false; authorizing = false
    }
    func stop() {
        generation = UUID(); recorder.reset(enabled: false); cloudKey = nil; whisperRecording = false; transcribing = false; timeout?.cancel(); timeout = nil; sink.set(nil)
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
        task?.cancel(); task = nil; listening = false; authorizing = false
        status = ""
    }
}
