import AVFoundation
import Speech
import Observation

enum VoicePhase: String { case off, starting, listening, thinking, speaking, unavailable }

private final class VoiceNotificationBag {
    var tokens: [NSObjectProtocol] = []
    deinit { for token in tokens { NotificationCenter.default.removeObserver(token) } }
}

/// The audio callback owns no UI state; request swaps are atomic with append().
private final class SpeechInputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func replace(_ value: SFSpeechAudioBufferRecognitionRequest?) {
        lock.lock(); request = value; lock.unlock()
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); request?.append(buffer); lock.unlock()
    }
}

/// Foreground conversation with local ASR, sentence-streamed speech and explicit
/// wake-name interruption. Drawers remain voice-controlled; capture stops for
/// text editors, system authorization and whenever the app leaves foreground.
@MainActor @Observable final class VoiceController: NSObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    private(set) var phase: VoicePhase = .off
    private(set) var status = "Tap the microphone to start"
    private(set) var caption = ""
    private(set) var captionRole = "You"
    private(set) var spokenRange: NSRange?
    private(set) var permissionsBusy = false
    private(set) var activationRevision = 0
    private(set) var startupDiagnostic: String?
    private(set) var audioLevel: Float = 0
    private(set) var attention = false
    private(set) var echoCancellationReady = false
    let recognitionAssets = RecognitionModelAssets()
    private(set) var recognitionDescription = "Apple on-device speech"
    private let capture = VoiceCapture()
    private let sink = SpeechInputSink()
    private let utterance = UtteranceRecorder()
    /// Plays a reply in an OpenAI voice when that's chosen; the Apple voice otherwise.
    private var cloudPlayer: AVAudioPlayer?
    /// Plays a reply in Kokoro or the person's own voice, a sentence at a time, on this device.
    private let neuralPlayer = SpeechPlayer()
    private let modernRecognition = ModernSpeechRecognition()
    private var recognitionStartTask: Task<Void, Never>?
    private var recognitionWatchdog: Task<Void, Never>?
    private var modernFailedThisActivation = false
    private var usesSpeechDetector = false
    private let synthesizer = AVSpeechSynthesizer()
    private var playbackStarting = false
    private var playbackToken: VoiceGenerationToken?
    private var playbackReceiver: VoiceEngineReceiver?
    private var runtimeStop: Task<Void, Never>?
    @ObservationIgnored private lazy var audioRuntime = VoiceRuntimeCoordinator(local: ClosureVoiceEngine(kind: .local,
        startCapture: { [weak self] _, _ in
            guard let self else { throw CancellationError() }
            try await self.startNativeCapture()
        }, stopCapture: { [weak self] in self?.stopNativeCapture() },
        play: { [weak self] request, token, receive in
            guard let self, self.active else { throw CancellationError() }
            self.playbackToken = token; self.playbackReceiver = receive
            let utterance = VoiceCatalog.utterance(for: request.text, voiceID: nil, rate: self.store?.state.speechRate)
            self.currentSpeech = utterance
            // The best voice this device can run now (`VoiceAuto`), or the OpenAI voice when it's opted
            // into; Apple's best voice otherwise.
            let key = self.store.flatMap { CloudVoice.key(in: $0) }
            switch SpeechVoices.shared.route(openAIVoice: CloudVoice.activeVoice(in: self.store)) {
            case .openAI(let voice): self.speakInCloudVoice(request.text, voice: voice, key: key ?? "", marker: utterance)
            case .kokoro, .ownVoice: self.speakOnDeviceNeural(request.text, marker: utterance)
            case .apple: self.synthesizer.speak(utterance)
            }
        }, stopPlayback: { [weak self] in self?.stopNativePlayback() },
        cancelJobs: { [weak self] in self?.cancelOwnedReasoning() }
    ), onEvent: { [weak self] event in
        guard let self else { return }
        if case .playbackFinished = event { self.playNext() }
    })
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var recognition: SFSpeechRecognitionTask?
    private var silenceTask: Task<Void, Never>?
    private var rotationTask: Task<Void, Never>?
    private var attentionTask: Task<Void, Never>?
    private var recoveryTask: Task<Void, Never>?
    private var startupTask: Task<Void, Never>?
    private var active = false
    private var audioInterrupted = false
    private var epoch = UUID()
    private var recognitionID = UUID()
    private var replyID = UUID()
    private var transcript = ""
    private var noticedName = false
    private var lastSpeechAt = Date.distantPast
    private var retryCount = 0
    private var currentSpeech: AVSpeechUtterance?
    private var queuedSpeech: [String] = []
    private var generatedText = ""
    private var releasedPrefix = ""
    private var generationFinished = true
    /// The AppStore request started by ask(); voice never cancels a typed request.
    private var ownedRequestID: UUID?
    private weak var store: AppStore?
    private let notifications = VoiceNotificationBag()
    var onCommand: ((VoiceCommand) -> Void)?

    var permissionSummary: String {
        let mic = AVAudioApplication.shared.recordPermission == .granted ? "Allowed" : "Not allowed"
        let speech = SFSpeechRecognizer.authorizationStatus() == .authorized ? "Allowed" : "Not allowed"
        return "Microphone: \(mic) · Speech recognition: \(speech)"
    }
    var canInterrupt: Bool { echoCancellationReady && store?.state.voiceInterruptions != false }
    override init() {
        super.init(); synthesizer.delegate = self
        notifications.tokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let options = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            Task { @MainActor [weak self] in
                guard let self, self.active else { return }
                if type == AVAudioSession.InterruptionType.began.rawValue {
                    self.audioInterrupted = true; self.epoch = UUID()
                    self.startupTask?.cancel(); self.recoveryTask?.cancel()
                    self.stopReply(); self.stopCapture(); self.phase = .off; self.status = "Audio paused"
                } else {
                    self.audioInterrupted = false
                    if AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) { self.recoverAudio() }
                    else { self.fail("Audio paused. Tap the microphone to reconnect.") }
                }
            }
        })
        notifications.tokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue || reason == AVAudioSession.RouteChangeReason.newDeviceAvailable.rawValue {
                Task { @MainActor [weak self] in self?.recoverAudio() }
            }
        })
        notifications.tokens.append(NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let object = note.object as AnyObject?
            Task { @MainActor [weak self] in
                guard let self, self.active, self.phase != .starting,
                      self.capture.handlesConfigurationChange(object), !self.capture.isRunning else { return }
                self.recoverAudio()
            }
        })
        notifications.tokens.append(NotificationCenter.default.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.recoverAudio() }
        })
    }

    func requestPermissions(store: AppStore) async {
        guard !permissionsBusy else { return }
        permissionsBusy = true; defer { permissionsBusy = false }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            store.state.voiceEnabled = true; activationRevision += 1; return
        }
        #endif
        let microphoneGranted: Bool
        if AVAudioApplication.shared.recordPermission == .granted { microphoneGranted = true }
        else { microphoneGranted = await AVAudioApplication.requestRecordPermission() }
        guard microphoneGranted else { fail("Allow the microphone in iOS Settings."); return }
        let permission: SFSpeechRecognizerAuthorizationStatus
        if SFSpeechRecognizer.authorizationStatus() == .authorized { permission = .authorized }
        else {
            permission = await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        guard permission == .authorized else { fail("Allow speech recognition in iOS Settings."); return }
        store.state.voiceEnabled = true; store.save()
        // Retry must not depend on a false -> true toggle. After a transient
        // failure, the saved preference may already be true.
        activationRevision += 1
        status = "Voice is ready"
    }
    func activate(store: AppStore) {
        self.store = store
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if ProcessInfo.processInfo.arguments.contains("--voice-startup-failure"), activationRevision == 0 {
                phase = .unavailable; status = "The microphone couldn’t start. Retry in Settings."
            } else { phase = .off; status = activationRevision > 0 ? "Microphone retry requested" : "Voice off during UI testing" }
            return
        }
        #endif
        guard !permissionsBusy else { return }
        guard !audioInterrupted else { return }
        guard !active else {
            if phase != .starting && !capture.isRunning { recoverAudio() }
            return
        }
        guard store.state.voiceEnabled == true else {
            // Keep a denial visible when the permission dialog closes. An
            // explicit Off action calls deactivate() and clears this state.
            if phase != .unavailable { phase = .off; status = "Tap the microphone to start" }
            return
        }
        guard AVAudioApplication.shared.recordPermission == .granted, SFSpeechRecognizer.authorizationStatus() == .authorized else { fail("Allow voice access in Settings."); return }
        active = true; epoch = UUID(); retryCount = 0; modernFailedThisActivation = false
        store.prepareVoice()
        OnDeviceWhisper.prewarm()
        phase = .starting; status = "Starting microphone…"; startupDiagnostic = nil
        let run = epoch
        startupTask = Task { @MainActor [weak self] in
            guard let self, self.active, self.epoch == run else { return }
            do {
                try await self.startCapture()
                guard self.active, self.epoch == run, !Task.isCancelled else { return }
                if self.queuedSpeech.isEmpty { self.listen(restartRecognition: false) }
                else { self.playNext() }
            } catch {
                guard !(error is CancellationError), self.active, self.epoch == run, !Task.isCancelled else { return }
                self.failCapture(error)
            }
        }
    }
    func deactivate() {
        active = false; audioInterrupted = false; epoch = UUID(); recoveryTask?.cancel(); startupTask?.cancel(); startupTask = nil
        stopReply(); stopCapture(); attentionTask?.cancel()
        phase = .off; status = "Microphone off"; caption = ""; spokenRange = nil; attention = false
    }
    private func startCapture() async throws {
        await runtimeStop?.value
        guard active, !Task.isCancelled else { throw CancellationError() }
        _ = try await audioRuntime.activateLocalCapture()
    }
    private func startNativeCapture() async throws {
        guard !capture.isRunning else { return }
        let run = epoch, sink = sink, modernInput = modernRecognition.input
        await recognitionAssets.refresh()
        guard active, epoch == run, !Task.isCancelled else { throw CancellationError() }
        // Warm/attach the recognizer before opening the hardware tap so the
        // first words do not fall into a model-preparation gap.
        let prepared = startRecognition()
        await prepared?.value
        guard active, epoch == run, !Task.isCancelled else { throw CancellationError() }
        let recorder = utterance
        let ready = try await capture.start { [weak self] buffer in
            sink.append(buffer)
            recorder.append(buffer)
            modernInput.append(buffer)
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for i in 0..<Int(buffer.frameLength) { sum += samples[i] * samples[i] }
            let rms = sqrt(sum / Float(buffer.frameLength))
            Task { @MainActor [weak self] in
                guard let self, self.active, self.epoch == run else { return }
                self.audioLevel = self.audioLevel * 0.45 + min(1, rms * 12) * 0.55
                if !self.usesSpeechDetector, rms > 0.012 { self.lastSpeechAt = Date() }
            }
        }
        guard active, epoch == run, !Task.isCancelled else { throw CancellationError() }
        echoCancellationReady = ready
        startupDiagnostic = capture.lastDiagnostics.isEmpty ? nil : capture.lastDiagnostics.map(\.description).joined(separator: " · ")
    }
    private func listen(keepingCaption: Bool = true, restartRecognition: Bool = true) {
        guard active else { return }
        phase = .listening; status = "Listening"; transcript = ""; noticedName = false; spokenRange = nil
        if !keepingCaption { caption = "" }
        if restartRecognition { startRecognition() }
    }
    @discardableResult private func startRecognition() -> Task<Void, Never>? {
        stopRecognition()
        utterance.reset(enabled: CloudVoice.activeTranscriber(in: store) != nil || OnDeviceWhisper.keepsUtteranceAudio)
        guard active else { return nil }
        let cycle = recognitionID, run = epoch
        if recognitionAssets.ready, let locale = recognitionAssets.locale, !modernFailedThisActivation {
            usesSpeechDetector = true
            recognitionDescription = "Apple SpeechTranscriber · on device"
            if phase == .listening { phase = .starting; status = "Preparing speech…" }
            recognitionWatchdog = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(8)) } catch { return }
                guard let self, self.active, self.epoch == run, self.recognitionID == cycle else { return }
                self.fail("Speech couldn’t get ready. Tap the mic to retry.")
            }
            recognitionStartTask = Task { [weak self] in
                guard let self else { return }
                do {
                    try await self.modernRecognition.start(locale: locale, context: self.recognitionHints,
                        onText: { [weak self] text in
                            // A final SpeechTranscriber segment is not a finished
                            // human turn. The speech-aware endpointer decides.
                            self?.recognized(text, final: false, failed: false, cycle: cycle, run: run)
                        }, onActivity: { [weak self] speaking in
                            guard let self, self.active, self.epoch == run, self.recognitionID == cycle else { return }
                            if speaking { self.lastSpeechAt = Date() }
                        }, onFailure: { [weak self] in
                            guard let self, self.active, self.epoch == run, self.recognitionID == cycle else { return }
                            // A runtime gap must not turn the remaining words
                            // into a fresh command. Startup-only failures may
                            // fall back; lost live audio requires a fresh opt-in.
                            self.transcript = ""
                            self.fail("Speech was interrupted. Tap the mic and say that again.")
                        })
                    guard self.active, self.epoch == run, self.recognitionID == cycle, !Task.isCancelled else { return }
                    self.recognitionWatchdog?.cancel(); self.recognitionWatchdog = nil
                    if self.phase == .starting && self.capture.isRunning { self.phase = .listening; self.status = "Listening" }
                    self.armRecognitionRotation(cycle: cycle, run: run)
                } catch {
                    guard !(error is CancellationError), self.active, self.epoch == run,
                          self.recognitionID == cycle, !Task.isCancelled else { return }
                    self.modernFailedThisActivation = true; self.startRecognition()
                }
            }
        } else {
            recognitionDescription = "Apple dictation · on device"
            startLegacyRecognition(cycle: cycle, run: run)
        }
        return recognitionStartTask
    }
    private var recognitionHints: [String] {
        [CompanionIdentity.name, "KemoSabe", "Kemo Sabe", "Kemo", "standup", "hold on", "connections", "calendar", "reminders", "contacts", "dance", "wave", "writing animation", "motion studio"] + BotTheme.presets.map(\.name)
    }
    private func startLegacyRecognition(cycle: UUID, run: UUID) {
        guard active, let recognizer, recognizer.isAvailable, recognizer.supportsOnDeviceRecognition else { fail("English speech recognition isn’t ready on this device."); return }
        if phase == .starting && capture.isRunning { phase = .listening; status = "Listening" }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true; request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = true
        request.contextualStrings = recognitionHints
        self.request = request; sink.replace(request)
        recognition = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString
            let final = result?.isFinal == true, failed = error != nil
            Task { @MainActor [weak self] in
                self?.recognized(text, final: final, failed: failed, cycle: cycle, run: run)
            }
        }
        armRecognitionRotation(cycle: cycle, run: run)
    }
    private func recognized(_ text: String?, final: Bool, failed: Bool, cycle: UUID, run: UUID) {
        guard active, epoch == run, recognitionID == cycle else { return }
        if failed {
            // Error callbacks may include a plausible but incomplete transcript.
            // Never promote it to a tool command at the silence timeout.
            if !transcript.isEmpty || !(text ?? "").isEmpty {
                transcript = ""; fail("Speech was interrupted. Tap the mic and say that again.")
            } else { retryRecognition(run: run) }
            return
        }
        if let text, !text.isEmpty {
            retryCount = 0
            if phase == .speaking || phase == .thinking {
                guard canInterrupt, VoiceTurnPolicy.interruption(text, spoken: generatedText) else {
                    if final || failed { startRecognition() }; return
                }
                stopReply(); phase = .listening; status = "Listening"; transcript = ""; perkUp()
            }
            guard phase == .listening else { return }
            if text != transcript {
                transcript = text; caption = text; captionRole = "You"; spokenRange = nil
                lastSpeechAt = Date()
                if Self.containsName(text), !noticedName { noticedName = true; perkUp() }
                scheduleEndpoint(cycle: cycle)
            }
            if final { finishUtterance() }
        } else if failed || final { retryRecognition(run: run) }
    }
    private func armRecognitionRotation(cycle: UUID, run: UUID) {
        rotationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(45)) } catch { return }
            guard let self, self.active, self.epoch == run, self.recognitionID == cycle else { return }
            if self.phase == .listening && !self.transcript.isEmpty { self.finishUtterance() }
            else { self.startRecognition() }
        }
    }
    private func perkUp() {
        attention = true; attentionTask?.cancel()
        let run = epoch
        attentionTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(1.3)) } catch { return }
            guard let self, self.epoch == run else { return }; self.attention = false
        }
    }
    private func scheduleEndpoint(cycle: UUID) {
        silenceTask?.cancel()
        let delay = VoiceTurnPolicy.endDelay(for: transcript, patient: store?.state.patientListening == true)
        silenceTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.active, self.phase == .listening, self.recognitionID == cycle else { return }
            // A recognizer can pause its partial text while the person is still
            // speaking. Don't submit just because that text hasn't changed.
            if Date().timeIntervalSince(self.lastSpeechAt) < 0.45 { self.scheduleEndpoint(cycle: cycle) }
            else { self.finishUtterance() }
        }
    }
    private func retryRecognition(run: UUID) {
        stopRecognition(); retryCount += 1
        guard retryCount <= 3 else { fail("Speech recognition stopped. Tap the mic to retry."); return }
        rotationTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            guard let self, self.active, self.epoch == run else { return }; self.startRecognition()
        }
    }
    private func finishUtterance() {
        guard active, phase == .listening else { return }
        let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { listen(); return }
        stopRecognition()
        if Self.isNameOnly(text) || ["stop", "wait", "hold on", "stop talking"].contains(VoiceTurnPolicy.normalized(text)) {
            listen(keepingCaption: false); status = "Yes?"; perkUp(); return
        }
        // With cloud transcription on, the recognizer found the end of the sentence; the chosen
        // model reads the words. Falls back to the on-device words if it can't.
        let cloud = CloudVoice.activeTranscriber(in: store)
        // Otherwise, once Whisper is on this iPhone (`VoiceAuto`), it reads the same audio again; Apple's
        // words stay if it can't run now (background, locked), fails, or runs past its timeout.
        if cloud == nil, OnDeviceWhisper.shouldRun(.voiceMode) {
            let buffers = utterance.takeBuffers()
            phase = .thinking; status = "Transcribing"
            let run = epoch
            Task { [weak self] in
                let final = await OnDeviceWhisper.finalText(apple: text, buffers: buffers, surface: .voiceMode)
                guard let self, self.active, self.epoch == run else { return }
                if final.source == .whisper { self.caption = final.text; self.captionRole = "You" }
                self.handleUtterance(final.text.isEmpty ? text : final.text)
            }
            return
        }
        if let model = cloud, let store, let key = CloudVoice.key(in: store), let audio = utterance.take() {
            phase = .thinking; status = "Transcribing"
            let run = epoch
            Task { [weak self] in
                let heard = (try? await OpenAIAudio(key: key).transcribe(audio, fileName: "utterance.wav", model: model)) ?? ""
                guard let self, self.active, self.epoch == run else { return }
                if !heard.isEmpty { self.caption = heard; self.captionRole = "You" }
                self.handleUtterance(heard.isEmpty ? text : heard)
            }
            return
        }
        handleUtterance(text)
    }
    private func handleUtterance(_ text: String) {
        // The first conversation (naming, look, personality) is answered on the device.
        if CompanionIntro.step != nil, let store, store.answerCompanionIntro(text) {
            speak(store.conversationMessages.last { $0.role == "KemoSabe" }?.text ?? ""); return
        }
        if let command = VoiceCommand.parse(text), let onCommand {
            phase = .thinking; status = "Working"; onCommand(command); return
        }
        ask(text)
    }
    /// Shared conversational planner path, including explicit routine entry points.
    func ask(_ text: String) {
        guard active else { return }
        guard text.count <= 2000 else { listen(); status = "Try a shorter thought"; return }
        guard let store, store.canChat else { fail(store?.availability ?? "Apple Intelligence isn’t ready."); return }
        guard !store.working else { speak("A draft is still running. Finish or cancel it before starting another request."); return }
        stopReply()
        phase = .thinking; status = "Thinking"; generationFinished = false
        let token = UUID(); replyID = token; let run = epoch
        if canInterrupt { startRecognition() }
        let previousRequest = store.requestID
        store.send(text, mode: .spokenConversation, onPartial: { [weak self] snapshot in
            guard let self, self.active, self.epoch == run, self.replyID == token else { return }
            self.receive(snapshot, final: false)
        }, completion: { [weak self] answer in
            guard let self, self.active, self.epoch == run, self.replyID == token else { return }
            guard let answer else {
                self.stopReply(); self.listen(); self.status = store.error ?? "I lost that thought. Try again."; return
            }
            self.generationFinished = true; self.receive(answer, final: true)
            self.playNext()
        })
        // send() assigns a new request ID only when it actually starts work.
        if store.requestID != previousRequest { ownedRequestID = store.requestID }
    }
    private func receive(_ text: String, final: Bool) {
        generatedText = text
        let ready = VoiceTurnPolicy.stablePrefix(text, final: final)
        // Never replay already spoken words if an upstream snapshot is revised.
        guard ready.hasPrefix(releasedPrefix) else { return }
        let delta = String(ready.dropFirst(releasedPrefix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        releasedPrefix = ready
        if !delta.isEmpty { queuedSpeech.append(delta) }
        playNext()
    }
    private func speak(_ text: String) {
        stopReply(); generatedText = text; generationFinished = true; queuedSpeech = [text]
        if canInterrupt { startRecognition() }
        playNext()
    }
    /// Deterministic settings/connector feedback; no language model required.
    func respond(_ text: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { caption = text; captionRole = CompanionIdentity.name; return }
        #endif
        guard active else { return }
        speak(text)
    }
    func previewVoice() { respond("What are we working on? Tell me where you left off.") }
    private func playNext() {
        guard active, currentSpeech == nil, !playbackStarting else { return }
        guard !queuedSpeech.isEmpty else {
            if generationFinished && phase != .listening { listen() }
            else if !generationFinished { phase = .thinking; status = "Thinking" }
            return
        }
        // Activation owns the audio-session transition. Keep the text queued
        // until the local engine is ready instead of dropping it on noActiveEngine.
        guard Self.localPlaybackReady(in: audioRuntime.mode) else { return }
        phase = .speaking; status = CompanionIdentity.name
        // Half-duplex fallback must not transcribe speaker playback, including
        // a voice preview started while listening.
        if !canInterrupt { stopRecognition() }
        // Coalesce ready sentences into one utterance to preserve their prosody.
        let text = queuedSpeech.joined(separator: " ")
        queuedSpeech.removeAll(keepingCapacity: true)
        caption = SpeechText.prepared(text); captionRole = CompanionIdentity.name; spokenRange = nil
        playbackStarting = true
        let run = epoch, reply = replyID
        Task { @MainActor [weak self] in
            guard let self, self.active, self.epoch == run, self.replyID == reply else { return }
            do {
                _ = try await self.audioRuntime.play(.init(text, privacy: .privateLocal))
                self.playbackStarting = false
            } catch {
                self.playbackStarting = false
                guard self.active, self.epoch == run, self.replyID == reply else { return }
                let preservedCaption = Self.replyCaption(
                    generatedText: self.generatedText,
                    attemptedText: text
                )
                self.stopReply(); self.listen(); self.status = "Speech stopped. Your reply is still available in captions."
                if !preservedCaption.isEmpty {
                    self.caption = preservedCaption; self.captionRole = CompanionIdentity.name; self.spokenRange = nil
                }
            }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.active, self.currentSpeech === utterance else { return }; self.spokenRange = characterRange
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.active, self.currentSpeech === utterance else { return }
            self.currentSpeech = nil; self.spokenRange = nil
            if let token = self.playbackToken { self.playbackReceiver?(token, .playbackFinished) }
            else { self.playNext() }
        }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor [weak self] in
            guard let self, self.active, self.currentSpeech === utterance else { return }
            self.stopReply(); self.listen()
        }
    }
    private func stopReply() {
        // Stopping output and canceling reasoning are distinct explicit actions.
        audioRuntime.stopPlayback(); audioRuntime.cancelJob()
        replyID = UUID(); cancelOwnedReasoning(); currentSpeech = nil; queuedSpeech = []
        generatedText = ""; releasedPrefix = ""; generationFinished = true; spokenRange = nil
        stopNativePlayback()
    }
    /// Cancels the model request only while it is still the one ask() started.
    /// Gating voice off for a typed reply must leave that reply running.
    private func cancelOwnedReasoning() {
        if let owned = ownedRequestID, let store, store.requestID == owned { store.cancel() }
        ownedRequestID = nil
    }
    private func stopNativePlayback() {
        currentSpeech = nil; playbackStarting = false; playbackToken = nil; playbackReceiver = nil
        synthesizer.stopSpeaking(at: .immediate)
        cloudPlayer?.stop(); cloudPlayer = nil
        neuralPlayer.stop()
    }
    /// Speaks the reply with Kokoro or the person's own voice on this device. If the model fails,
    /// the Apple voice says whatever wasn't spoken yet.
    private func speakOnDeviceNeural(_ text: String, marker: AVSpeechUtterance) {
        let voices = SpeechVoices.shared
        let route = voices.route()
        let engine = voices.engine(for: route, appleRate: store?.state.speechRate)
        neuralPlayer.play(text, engine: engine, voice: voices.persona.kokoroVoice) { [weak self] error, unspoken in
            guard let self, self.active, self.currentSpeech === marker else { return }
            if error != nil, !unspoken.isEmpty {
                let rest = VoiceCatalog.utterance(for: unspoken.joined(separator: " "), voiceID: nil, rate: self.store?.state.speechRate)
                self.currentSpeech = rest; self.synthesizer.speak(rest); return
            }
            self.currentSpeech = nil; self.spokenRange = nil
            if let token = self.playbackToken { self.playbackReceiver?(token, .playbackFinished) }
            else { self.playNext() }
        }
    }
    /// Fetches the reply in an OpenAI voice and plays it; the Apple voice speaks if that fails.
    private func speakInCloudVoice(_ text: String, voice: String, key: String, marker: AVSpeechUtterance) {
        Task { [weak self] in
            let audio = try? await OpenAIAudio(key: key).speech(SpeechText.prepared(text), voice: voice)
            guard let self, self.active, self.currentSpeech === marker else { return }
            if let audio, let player = try? AVAudioPlayer(data: audio) {
                player.delegate = self; self.cloudPlayer = player; player.play()
            } else { self.synthesizer.speak(marker) }
        }
    }
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor [weak self] in
            guard let self, self.active, self.cloudPlayer === player else { return }
            self.cloudPlayer = nil; self.currentSpeech = nil; self.spokenRange = nil
            if let token = self.playbackToken { self.playbackReceiver?(token, .playbackFinished) }
            else { self.playNext() }
        }
    }
    private func stopRecognition() {
        recognitionID = UUID(); silenceTask?.cancel(); rotationTask?.cancel()
        recognitionStartTask?.cancel(); recognitionStartTask = nil
        recognitionWatchdog?.cancel(); recognitionWatchdog = nil
        modernRecognition.stop(); usesSpeechDetector = false
        silenceTask = nil; rotationTask = nil; sink.replace(nil)
        request?.endAudio(); recognition?.cancel(); recognition = nil; request = nil
    }
    private func stopCapture() {
        // Stop synchronously for permission/editor/foreground gates; the runtime
        // then drains any pending transition before another capture can start.
        stopNativeCapture()
        let previous = runtimeStop
        runtimeStop = Task { @MainActor [audioRuntime] in
            await previous?.value
            await audioRuntime.stopAll()
        }
    }
    private func stopNativeCapture() {
        stopRecognition()
        capture.stop(); audioLevel = 0; echoCancellationReady = false
    }
    private func recoverAudio() {
        guard active, !audioInterrupted else { return }
        startupTask?.cancel(); startupTask = nil
        stopReply(); stopCapture(); recoveryTask?.cancel()
        epoch = UUID(); phase = .starting; status = "Reconnecting microphone…"
        let run = epoch
        recoveryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
            guard let self, self.active, self.epoch == run else { return }
            do {
                try await self.startCapture()
                guard self.active, self.epoch == run, !Task.isCancelled else { return }
                if self.queuedSpeech.isEmpty { self.listen(restartRecognition: false) }
                else { self.playNext() }
            } catch {
                guard !(error is CancellationError), self.active, self.epoch == run, !Task.isCancelled else { return }
                self.failCapture(error)
            }
        }
    }
    private func failCapture(_ error: Error) {
        // Diagnostics never contain audio, transcripts or the route/device name.
        if let failure = error as? VoiceCaptureError { startupDiagnostic = failure.description }
        else { let failure = error as NSError; startupDiagnostic = "Audio startup: \(failure.domain) (\(failure.code))" }
        fail("The microphone couldn’t start. Tap the mic to retry, or check your audio connection.")
    }
    private func fail(_ message: String) { deactivate(); phase = .unavailable; status = message }

    nonisolated static func containsName(_ text: String) -> Bool {
        VoiceTurnPolicy.containsName(text)
    }
    nonisolated static func isNameOnly(_ text: String) -> Bool {
        let custom = CompanionIdentity.spokenName.map { [$0, "hey " + $0] } ?? []
        return (["kemosabe", "kemo sabe", "hey kemosabe", "hey kemo sabe", "kemo", "hey kemo"] + custom).contains(VoiceTurnPolicy.normalized(text))
    }
    nonisolated static func isPauseCommand(_ text: String) -> Bool {
        VoiceTurnPolicy.isPauseCommand(text)
    }
    nonisolated static func isStandupCommand(_ text: String) -> Bool {
        var words = VoiceTurnPolicy.normalized(text)
        for prefix in ["hey kemo sabe ", "hey kemosabe ", "kemo sabe ", "kemosabe "] where words.hasPrefix(prefix) { words.removeFirst(prefix.count); break }
        return ["prepare my standup", "draft my standup", "prepare my stand up", "draft my stand up"].contains(words)
    }

    static func localPlaybackReady(in mode: VoiceRuntimeMode) -> Bool {
        switch mode {
        case .active(.local), .safeMode: return true
        default: return false
        }
    }

    static func replyCaption(generatedText: String, attemptedText: String) -> String {
        let fullestAvailable = generatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        return SpeechText.prepared(fullestAvailable.isEmpty ? attemptedText : fullestAvailable)
    }
}
