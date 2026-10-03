import AVFoundation

/// Records one short clip for the iPhone to transcribe. Nothing stays on the
/// watch: the file is read once and deleted. It sends by itself once you have
/// spoken and then paused, or at the time limit.
@MainActor final class WatchRecorder: NSObject, AVAudioRecorderDelegate {
    private var recorder: AVAudioRecorder?
    private var monitor: Task<Void, Never>?
    /// Called when you pause after speaking, or the clip reaches the time limit.
    var finishedSpeaking: (() -> Void)?
    /// How loud the microphone is, from 0 to 1, for the listening animation.
    private(set) var level: Double = 0
    /// Seconds of quiet after speech that end a clip.
    static let pause: TimeInterval = 1.2
    var isRecording: Bool { recorder != nil }

    static func permission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: true
        case .denied: false
        default: await AVAudioApplication.requestRecordPermission()
        }
    }
    func start() throws {
        cancel()
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .default)
        try session.setActive(true)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".m4a")
        // Speech-quality AAC keeps a full clip small enough for one message.
        let recorder = try AVAudioRecorder(url: url, settings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 12_000,
        ])
        recorder.delegate = self
        recorder.isMeteringEnabled = true
        guard recorder.record(forDuration: WatchLink.maxRecordingSeconds) else {
            recorder.deleteRecording(); deactivate()
            throw WatchRecorderError.couldNotStart
        }
        self.recorder = recorder
        watchForPause()
    }
    /// Learns the room's noise in the first moments, then ends the clip once
    /// speech clearly above it has stopped for `pause` seconds.
    private func watchForPause() {
        monitor?.cancel()
        monitor = Task { [weak self] in
            var floor: Float = 0, samples = 0, heardSpeech = false
            var quietSince: Date?
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, let recorder = self.recorder, recorder.isRecording else { return }
                recorder.updateMeters()
                let power = recorder.averagePower(forChannel: 0)
                self.level = Double(max(0, min(1, (power + 50) / 40)))
                samples += 1
                if samples <= 3 { floor = samples == 1 ? power : min(floor, power); continue }
                let speaking = power > max(floor + 12, -42)
                if speaking { heardSpeech = true; quietSince = nil; continue }
                guard heardSpeech else { continue }
                if quietSince == nil { quietSince = Date() }
                if let quietSince, Date().timeIntervalSince(quietSince) >= Self.pause { self.finishedSpeaking?(); return }
            }
        }
    }
    /// Stops and returns the clip, or nil when it was too short to hold a request.
    func finish() -> Data? {
        guard let recorder else { return nil }
        self.recorder = nil; monitor?.cancel(); level = 0
        let long = recorder.currentTime >= 0.5 || !recorder.isRecording
        recorder.stop(); deactivate()
        defer { recorder.deleteRecording() }
        return long ? try? Data(contentsOf: recorder.url) : nil
    }
    func cancel() {
        guard let recorder else { return }
        self.recorder = nil; monitor?.cancel(); level = 0
        recorder.stop(); recorder.deleteRecording(); deactivate()
    }
    private func deactivate() { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let finished = ObjectIdentifier(recorder)
        Task { @MainActor in
            // A clip stopped by finish() or cancel() is no longer current.
            if let current = self.recorder, ObjectIdentifier(current) == finished { self.finishedSpeaking?() }
        }
    }
}

enum WatchRecorderError: LocalizedError {
    case couldNotStart
    var errorDescription: String? { "The microphone didn't start. Try again." }
}
