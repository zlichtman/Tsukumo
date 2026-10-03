import AVFoundation

enum VoiceCaptureMode: String { case voiceProcessing, standard }
enum VoiceCaptureStage: String, CaseIterable {
    case sessionCategory, sessionActivation, voiceProcessing, inputFormat, tapInstallation, engineStart, unknown
}

/// Deliberately excludes NSError.userInfo, device details and captured audio.
struct VoiceCaptureBackendError: Error {
    let stage: VoiceCaptureStage
    let domain: String
    let code: Int

    init(stage: VoiceCaptureStage, error: Error) {
        let underlying = error as NSError
        self.stage = stage; domain = underlying.domain; code = underlying.code
    }

    init(stage: VoiceCaptureStage, code: Int) {
        self.stage = stage; domain = "KemoSabe.VoiceCapture"; self.code = code
    }
}

struct VoiceCaptureDiagnostic: Equatable, CustomStringConvertible {
    let mode: VoiceCaptureMode
    let stage: VoiceCaptureStage
    let domain: String
    let code: Int
    var description: String { "\(mode.rawValue)/\(stage.rawValue): \(domain) (\(code))" }
}

struct VoiceCaptureError: Error, LocalizedError, CustomStringConvertible {
    let diagnostics: [VoiceCaptureDiagnostic]
    var description: String {
        diagnostics.map(\.description).joined(separator: "; ")
    }
    var errorDescription: String? { description }
}

@MainActor protocol VoiceCaptureBackend: AnyObject {
    var isRunning: Bool { get }
    var engineObject: AnyObject? { get }
    func start(mode: VoiceCaptureMode, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws
    /// Stops microphone I/O immediately, without waiting for session deactivation.
    func stopAudio()
    func deactivate() async
}

/// A bounded, foreground-only capture startup. No audio is stored here.
@MainActor final class VoiceCapture {
    private let makeBackend: () -> any VoiceCaptureBackend
    private var backend: (any VoiceCaptureBackend)?
    private var echoCancellationReady = false
    private var generation: UInt64 = 0
    private var startup: Task<Bool, Error>?
    private var transition: Task<Void, Never>?
    private(set) var lastDiagnostics: [VoiceCaptureDiagnostic] = []
    var isRunning: Bool { backend?.isRunning == true }

    convenience init() { self.init(makeBackend: { NativeVoiceCaptureBackend() }) }
    init(makeBackend: @escaping () -> any VoiceCaptureBackend) { self.makeBackend = makeBackend }

    /// Returns false on successful standard capture: callers must use half-duplex recognition.
    @discardableResult func start(onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws -> Bool {
        try Task.checkCancellation()
        if isRunning { return echoCancellationReady }
        stop()
        let run = generation, previous = transition
        let work = Task { @MainActor [self] in
            // Old activation and deactivation must finish before a new session starts.
            // Otherwise a delayed Off completion could deactivate the new microphone.
            await previous?.value
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            lastDiagnostics = []
            for mode in [VoiceCaptureMode.voiceProcessing, .standard] {
                let candidate = makeBackend()
                do {
                    try await candidate.start(mode: mode, onBuffer: onBuffer)
                    try Task.checkCancellation()
                    guard generation == run else { throw CancellationError() }
                    guard candidate.isRunning else { throw VoiceCaptureBackendError(stage: .engineStart, code: 3) }
                    backend = candidate
                    echoCancellationReady = mode == .voiceProcessing
                    return echoCancellationReady
                } catch {
                    candidate.stopAudio()
                    await candidate.deactivate()
                    // Cancellation is not a hardware failure and must never trigger fallback.
                    guard !(error is CancellationError), !Task.isCancelled, generation == run else {
                        throw CancellationError()
                    }
                    let failure = (error as? VoiceCaptureBackendError) ?? .init(stage: .unknown, error: error)
                    lastDiagnostics.append(.init(mode: mode, stage: failure.stage, domain: failure.domain, code: failure.code))
                }
            }
            throw VoiceCaptureError(diagnostics: lastDiagnostics)
        }
        startup = work
        transition = Task { _ = try? await work.value }
        defer { if generation == run { startup = nil } }
        do {
            let result = try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { work.cancel() }
            try Task.checkCancellation()
            guard generation == run else { throw CancellationError() }
            return result
        } catch {
            if error is CancellationError, generation == run { stop() }
            throw error
        }
    }

    func stop() {
        generation &+= 1
        startup?.cancel(); startup = nil
        let retired = backend, previous = transition
        backend = nil; echoCancellationReady = false
        retired?.stopAudio()
        transition = Task {
            await previous?.value
            await retired?.deactivate()
        }
    }

    /// Waits only for already-scheduled cleanup; useful for orderly shutdown and tests.
    func waitUntilSettled() async {
        await transition?.value
    }

    /// Call from the controller's actor hop, not inside AVAudioEngine's notification callback.
    func handlesConfigurationChange(_ object: AnyObject?) -> Bool {
        guard let object, let owned = backend?.engineObject else { return false }
        return object === owned
    }
}

enum VoiceCaptureFormat {
    /// The iOS 27 tap API supports 100–400 ms; a fixed 2048-frame tap is too short at 48 kHz.
    static func tapFrames(sampleRate: Double, channels: AVAudioChannelCount) throws -> AVAudioFrameCount {
        let frames = (sampleRate * 0.1).rounded(.up)
        guard sampleRate.isFinite, sampleRate > 0, channels > 0,
              frames >= 1, frames <= Double(UInt32.max) else {
            throw VoiceCaptureBackendError(stage: .inputFormat, code: 1)
        }
        return AVAudioFrameCount(frames)
    }
}

/// AVAudioEngine invokes this only while its tap is installed, on its audio callback queue.
private final class VoiceCaptureBufferDelivery: @unchecked Sendable {
    let callback: (AVAudioPCMBuffer) -> Void
    init(_ callback: @escaping (AVAudioPCMBuffer) -> Void) { self.callback = callback }
}

@MainActor private final class NativeVoiceCaptureBackend: VoiceCaptureBackend {
    private var engine: AVAudioEngine?
    private var tapInstalled = false
    private var activatedSession = false
    var isRunning: Bool { engine?.isRunning == true }
    var engineObject: AnyObject? { engine }

    func start(mode: VoiceCaptureMode, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        let session = AVAudioSession.sharedInstance()
        try at(.sessionCategory) {
            try session.setCategory(.playAndRecord, mode: mode == .voiceProcessing ? .voiceChat : .default,
                                    options: [.defaultToSpeaker, .allowBluetoothHFP])
        }
        do {
            if #available(iOS 27.0, *) {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    session.activate(options: []) { activated, error in
                        if let error { continuation.resume(throwing: error) }
                        else if activated { continuation.resume() }
                        else { continuation.resume(throwing: VoiceCaptureBackendError(stage: .sessionActivation, code: 4)) }
                    }
                }
            } else {
                try session.setActive(true)
            }
        } catch { throw VoiceCaptureBackendError(stage: .sessionActivation, error: error) }
        activatedSession = true
        // Off/background may have arrived while Apple was activating the session.
        try Task.checkCancellation()

        let candidate = AVAudioEngine()
        engine = candidate
        let input = candidate.inputNode
        if mode == .voiceProcessing {
            try at(.voiceProcessing) { try input.setVoiceProcessingEnabled(true) }
            guard input.isVoiceProcessingEnabled else { throw VoiceCaptureBackendError(stage: .voiceProcessing, code: 2) }
        }
        let hardwareFormat = input.inputFormat(forBus: 0)
        _ = try VoiceCaptureFormat.tapFrames(sampleRate: hardwareFormat.sampleRate, channels: hardwareFormat.channelCount)
        let format = input.outputFormat(forBus: 0)
        let frames = try VoiceCaptureFormat.tapFrames(sampleRate: format.sampleRate, channels: format.channelCount)
        let delivery = VoiceCaptureBufferDelivery(onBuffer)
        if #available(iOS 27.0, *) {
            try at(.tapInstallation) {
                try input.installAudioTap(onBus: 0, bufferSize: frames, format: format) { buffer, _ in
                    delivery.callback(AVAudioPCMBuffer(copying: buffer))
                }
            }
        } else {
            // iOS 26's nonthrowing API requires a fresh engine and a validated native format.
            input.installTap(onBus: 0, bufferSize: frames, format: format) { buffer, _ in
                delivery.callback(buffer)
            }
        }
        tapInstalled = true
        // A microphone-only tap does not need an input-to-output connection; start prepares it.
        try at(.engineStart) { try candidate.start() }
    }

    func stopAudio() {
        if let engine {
            engine.stop()
            if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
            engine.reset()
        }
        tapInstalled = false; engine = nil
    }

    func deactivate() async {
        guard activatedSession else { return }
        activatedSession = false
        let session = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.deactivate(options: .notifyOthersOnDeactivation) { _, _ in continuation.resume() }
            }
        } else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    private func at(_ stage: VoiceCaptureStage, _ operation: () throws -> Void) throws {
        do { try operation() } catch { throw VoiceCaptureBackendError(stage: stage, error: error) }
    }
}
