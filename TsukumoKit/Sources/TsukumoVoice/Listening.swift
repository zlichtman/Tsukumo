@preconcurrency import AVFoundation
import Foundation
@preconcurrency import Speech

// Speech in: the microphone and Apple's on-device recognizer, which gives the live words while you talk.
// Ported from the old Mac app's dictation (`legacy/macos/KemoSabeMac/MacVoiceInput.swift`) and the old app's
// `UtteranceRecorder`; new is `EndOfSpeech`, which ends a tap-to-talk turn when you stop talking.

/// What the microphone reports while it listens.
public enum CaptureEvent: Equatable, Sendable {
    /// The loudest recent sound, in dBFS (about -160 to 0).
    case level(Float)
    /// Apple's recognizer's words so far.
    case partial(String)
    /// Apple's recognizer decided the utterance is over (or stopped).
    case ended
}

public enum CaptureError: Error, Equatable, LocalizedError {
    case microphoneDenied, speechDenied, unavailable, microphoneFailed
    public var errorDescription: String? {
        switch self {
        case .microphoneDenied: "Allow the microphone for Tsukumo in Settings, Privacy & Security."
        case .speechDenied: "Allow speech recognition for Tsukumo in Settings, Privacy & Security."
        case .unavailable: "On-device speech recognition isn’t available here."
        case .microphoneFailed: "The microphone couldn’t start. Check it and try again."
        }
    }
}

/// The microphone and the live recognizer. The real one is `AppleSpeechCapture`; tests use a fake that
/// plays recorded levels and words, so no test touches the microphone.
@MainActor public protocol SpeechCapturing: AnyObject {
    /// Asks for the microphone (and speech recognition) the first time, then starts listening. `hints` are
    /// names the recognizer should expect; `keepAudio` keeps the utterance in memory for Whisper.
    func start(hints: [String], keepAudio: Bool, onEvent: @escaping @MainActor (CaptureEvent) -> Void) async throws
    /// Stops listening; the utterance as 16 kHz mono samples (empty unless `keepAudio`). Nothing is written
    /// to disk.
    func finish() async -> [Float]
    /// Stops listening and drops the audio.
    func cancel()
}

/// When a tap-to-talk turn is over: after you've said something and then gone quiet for a moment (longer
/// after "and" or "so", shorter after a full stop), or when nothing was heard at all. Hold to talk ends only
/// when you let go. Either way a turn stops at 55 seconds. Pure, so it's unit tested with recorded levels.
public struct EndOfSpeech: Sendable {
    public enum Decision: Equatable, Sendable { case keepListening, finish, nothingHeard }
    public let hold: Bool
    public let startedAt: TimeInterval
    public static let maximum: TimeInterval = 55
    public static let nothingHeardAfter: TimeInterval = 8

    private var floor: Float = -60
    private var speechSeconds: Double = 0
    private var lastFrame: TimeInterval?
    private var lastActivity: TimeInterval
    private var words = ""
    public private(set) var heardSpeech = false

    public init(hold: Bool, startedAt: TimeInterval) {
        self.hold = hold; self.startedAt = startedAt; self.lastActivity = startedAt
    }

    /// Whether a level counts as someone talking: well above the room's quiet, and not whisper-quiet.
    public func isSpeech(_ level: Float) -> Bool { level > max(floor + 12, -52) }

    public mutating func level(_ db: Float, at time: TimeInterval) -> Decision {
        let step = lastFrame.map { max(0, min(0.2, time - $0)) } ?? 0
        // The room's quiet starts at the first sound heard (never louder than -35 dBFS, in case the owner
        // is already talking), then follows quieter sounds at once and louder ones slowly, so a steady fan
        // stops counting as talking.
        if lastFrame == nil { floor = min(db, -35) }
        lastFrame = time
        if isSpeech(db) {
            speechSeconds += step
            lastActivity = time
            if speechSeconds >= 0.3 { heardSpeech = true }
        }
        floor = db < floor ? db : floor + Float(step) * 3
        return decide(at: time)
    }

    public mutating func words(_ text: String, at time: TimeInterval) -> Decision {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != words {
            words = trimmed
            if !trimmed.isEmpty { heardSpeech = true; lastActivity = time }
        }
        return decide(at: time)
    }

    public func decide(at time: TimeInterval) -> Decision {
        if time - startedAt >= Self.maximum { return heardSpeech ? .finish : .nothingHeard }
        guard !hold else { return .keepListening }
        if !heardSpeech { return time - startedAt >= Self.nothingHeardAfter ? .nothingHeard : .keepListening }
        return time - lastActivity >= Self.pause(after: words) ? .finish : .keepListening
    }

    /// How long a pause ends the turn (the old app's `VoiceTurnPolicy.endDelay`).
    public static func pause(after text: String) -> TimeInterval {
        let words = text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        if let last = words.last, ["and", "but", "because", "so", "to", "the", "a", "an", "or", "with", "if", "your", "my",
                                   "do", "can", "could", "you", "um", "uh"].contains(last) { return 1.6 }
        return text.last.map { ".?!".contains($0) } == true ? 0.8 : 1.2
    }

    /// A level for the meter, 0 to 1.
    public static func meter(_ db: Float) -> Double { Double(min(1, max(0, (db + 55) / 45))) }
}

/// Keeps one utterance's audio in memory for Whisper, at most 60 seconds. Nothing is written to disk.
final class UtteranceRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var buffers: [AVAudioPCMBuffer] = []
    private var frames: AVAudioFrameCount = 0
    private var enabled = false
    func reset(enabled: Bool) { lock.lock(); buffers = []; frames = 0; self.enabled = enabled; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard enabled, frames < AVAudioFrameCount(buffer.format.sampleRate * 60), let copy = Self.copy(buffer) else { return }
        buffers.append(copy); frames += buffer.frameLength
    }
    static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { return nil }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for index in 0..<min(source.count, target.count) {
            guard let from = source[index].mData, let to = target[index].mData else { return nil }
            let bytes = min(source[index].mDataByteSize, target[index].mDataByteSize)
            memcpy(to, from, Int(bytes)); target[index].mDataByteSize = bytes
        }
        return copy
    }
    func take() -> [AVAudioPCMBuffer] {
        lock.lock(); defer { lock.unlock() }
        let taken = buffers; buffers = []; frames = 0
        return taken
    }
}

/// Hands microphone buffers to the recognizer from the audio thread.
private final class RequestSink: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    func set(_ value: SFSpeechAudioBufferRecognitionRequest?) { lock.lock(); request = value; lock.unlock() }
    func append(_ buffer: AVAudioPCMBuffer) { lock.lock(); request?.append(buffer); lock.unlock() }
    func end() { lock.lock(); request?.endAudio(); request = nil; lock.unlock() }
}

/// Carries main-actor work out of callbacks that run elsewhere (the audio thread, the recognizer's queue).
private final class EventRelay: @unchecked Sendable {
    let send: @MainActor (CaptureEvent) -> Void
    init(_ send: @escaping @MainActor (CaptureEvent) -> Void) { self.send = send }
    func post(_ event: CaptureEvent) { Task { @MainActor in self.send(event) } }
}

/// The microphone (AVAudioEngine) and Apple's on-device recognizer (`SFSpeechRecognizer`, on-device only:
/// nothing goes to Apple's servers). On iPhone it sets the audio session for talking and listening.
@MainActor public final class AppleSpeechCapture: SpeechCapturing {
    private let engine = AVAudioEngine()
    private let sink = RequestSink()
    private let recorder = UtteranceRecorder()
    private var task: SFSpeechRecognitionTask?
    private var tapInstalled = false
    public init() {}

    public func start(hints: [String], keepAudio: Bool, onEvent: @escaping @MainActor (CaptureEvent) -> Void) async throws {
        guard await Self.microphoneAllowed() else { throw CaptureError.microphoneDenied }
        let speechAllowed = await Self.speechAllowed()
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        let recognizes = speechAllowed && recognizer?.isAvailable == true && recognizer?.supportsOnDeviceRecognition == true
        // Without Apple's recognizer, only Whisper can read the audio.
        guard recognizes || keepAudio else { throw speechAllowed ? CaptureError.unavailable : CaptureError.speechDenied }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try? session.setActive(true, options: [])
        #endif
        let relay = EventRelay(onEvent)
        recorder.reset(enabled: keepAudio)
        if recognizes, let recognizer {
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = true
            request.addsPunctuation = true
            request.contextualStrings = hints
            sink.set(request)
            task = recognizer.recognitionTask(with: request, resultHandler: Self.resultHandler(relay))
        }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { cancel(); throw CaptureError.microphoneFailed }
        input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(sink: sink, recorder: recorder, relay: relay))
        tapInstalled = true
        engine.prepare()
        do { try engine.start() } catch { cancel(); throw CaptureError.microphoneFailed }
    }

    public func finish() async -> [Float] {
        stopEngine()
        sink.end()
        task?.finish(); task = nil
        let buffers = recorder.take()
        recorder.reset(enabled: false)
        guard !buffers.isEmpty else { return [] }
        let pending = Buffers(buffers)
        return await Task.detached(priority: .userInitiated) { (try? WhisperAudioInput.monoSamples(from: pending.buffers)) ?? [] }.value
    }

    public func cancel() {
        stopEngine()
        sink.set(nil)
        task?.cancel(); task = nil
        recorder.reset(enabled: false)
    }

    private func stopEngine() {
        if engine.isRunning { engine.stop() }
        if tapInstalled { engine.inputNode.removeTap(onBus: 0); tapInstalled = false }
    }

    // The tap and the recognizer's callback run off the main actor, so they're made outside it.
    private nonisolated static func tap(sink: RequestSink, recorder: UtteranceRecorder, relay: EventRelay) -> AVAudioNodeTapBlock {
        { buffer, _ in
            sink.append(buffer)
            recorder.append(buffer)
            relay.post(.level(level(buffer)))
        }
    }
    private nonisolated static func resultHandler(_ relay: EventRelay) -> @Sendable (SFSpeechRecognitionResult?, Error?) -> Void {
        { result, error in
            if let text = result?.bestTranscription.formattedString, !text.isEmpty { relay.post(.partial(text)) }
            if result?.isFinal == true || error != nil { relay.post(.ended) }
        }
    }
    /// The buffer's peak, in dBFS.
    nonisolated static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return -160 }
        var peak: Float = 0
        for index in 0..<Int(buffer.frameLength) { peak = max(peak, abs(channel[index])) }
        return peak > 0 ? 20 * log10(peak) : -160
    }

    /// Asks for the microphone the first time.
    public static func microphoneAllowed() async -> Bool {
        #if os(iOS)
        await AVAudioApplication.requestRecordPermission()
        #else
        await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
    /// Asks for on-device speech recognition the first time.
    public static func speechAllowed() async -> Bool {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: return true
        case .denied, .restricted: return false
        default:
            return await withCheckedContinuation { continuation in
                SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
            }
        }
    }
}

private struct Buffers: @unchecked Sendable {
    let buffers: [AVAudioPCMBuffer]
    init(_ buffers: [AVAudioPCMBuffer]) { self.buffers = buffers }
}

/// A stand-in microphone that plays recorded events: levels and words at set times, then the utterance's
/// samples. For tests and the Mac app's DEBUG `--capture` (so pictures of the listening state never ask
/// for the microphone). It never touches audio hardware.
@MainActor public final class ScriptedSpeechCapture: SpeechCapturing {
    public struct Step: Sendable {
        public let after: TimeInterval
        public let event: CaptureEvent
        public init(after: TimeInterval, _ event: CaptureEvent) { self.after = after; self.event = event }
    }
    public let steps: [Step]
    public let samples: [Float]
    public var failure: CaptureError?
    public private(set) var started = false
    public private(set) var finished = false
    public private(set) var cancelled = false
    public private(set) var hints: [String] = []
    public private(set) var keptAudio = false
    private var player: Task<Void, Never>?

    public init(steps: [Step], samples: [Float] = [], failure: CaptureError? = nil) {
        self.steps = steps; self.samples = samples; self.failure = failure
    }
    /// Someone asking what's on tomorrow, for pictures.
    public static func sample() -> ScriptedSpeechCapture {
        var steps: [Step] = []
        var time = 0.0
        for (index, words) in ["What’s", "What’s on my", "What’s on my calendar", "What’s on my calendar tomorrow"].enumerated() {
            for _ in 0..<6 { time += 0.05; steps.append(Step(after: time, .level(-18 - Float(index % 2) * 6))) }
            steps.append(Step(after: time, .partial(words)))
        }
        // Then it keeps listening (the speaker is still talking), so the picture holds.
        for _ in 0..<400 { time += 0.05; steps.append(Step(after: time, .level(-20 - Float(Int(time * 10) % 3) * 4))) }
        return ScriptedSpeechCapture(steps: steps)
    }

    public func start(hints: [String], keepAudio: Bool, onEvent: @escaping @MainActor (CaptureEvent) -> Void) async throws {
        if let failure { throw failure }
        self.hints = hints; keptAudio = keepAudio; started = true
        let steps = self.steps
        player = Task { @MainActor in
            var elapsed = 0.0
            for step in steps {
                let wait = step.after - elapsed
                if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
                elapsed = step.after
                guard !Task.isCancelled else { return }
                onEvent(step.event)
            }
        }
    }
    public func finish() async -> [Float] { player?.cancel(); finished = true; return keptAudio ? samples : [] }
    public func cancel() { player?.cancel(); cancelled = true }
}
