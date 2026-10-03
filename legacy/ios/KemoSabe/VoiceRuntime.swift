import Foundation

enum VoiceEngineKind: String, Equatable {
    case local
    case cloud
}

enum VoiceRuntimeMode: Equatable {
    case off
    case transitioning(to: VoiceEngineKind)
    case active(VoiceEngineKind)
    /// Local playback is allowed, but no capture engine is open.
    case safeMode
}

enum VoiceOperation: Equatable {
    case capture
    case playback
    case job
}

struct VoiceGenerationToken: Equatable {
    let operation: VoiceOperation
    fileprivate let value: UUID

    fileprivate init(operation: VoiceOperation) {
        self.operation = operation
        value = UUID()
    }
}

enum VoiceEngineFailure: Equatable {
    case captureUnavailable
    case playbackUnavailable
    case connectionLost
    case cancelled
}

enum VoiceRuntimeEvent: Equatable {
    case transcript(String, final: Bool)
    case playbackFinished
    case jobText(String, final: Bool)
    case failure(VoiceOperation, VoiceEngineFailure)

    fileprivate var operation: VoiceOperation {
        switch self {
        case .transcript: return .capture
        case .playbackFinished: return .playback
        case .jobText: return .job
        case let .failure(operation, _): return operation
        }
    }
}

enum VoicePlaybackPrivacy: Equatable {
    case conversation
    /// Must never be submitted to a cloud voice engine.
    case privateLocal
}

struct VoicePlaybackRequest: Equatable {
    let text: String
    let privacy: VoicePlaybackPrivacy

    init(_ text: String, privacy: VoicePlaybackPrivacy = .conversation) {
        self.text = text
        self.privacy = privacy
    }
}

typealias VoiceEngineReceiver = @MainActor @Sendable (VoiceGenerationToken, VoiceRuntimeEvent) -> Void

/// Engine adapters own implementation details (Apple speech, a local model, or
/// a managed cloud session). The coordinator is the only component that may
/// move capture/playback ownership between adapters.
@MainActor protocol VoiceEngine: AnyObject {
    var kind: VoiceEngineKind { get }
    func startCapture(token: VoiceGenerationToken, receive: @escaping VoiceEngineReceiver) async throws
    /// Must also interrupt an in-flight startCapture(), return promptly, and
    /// not return while captured audio can still leave this engine.
    func stopCapture() async
    /// Schedules playback and returns; completion arrives through `receive`.
    func play(_ request: VoicePlaybackRequest, token: VoiceGenerationToken,
              receive: @escaping VoiceEngineReceiver) async throws
    /// Stops audible output only. It must not cancel an upstream reasoning job.
    func stopPlayback()
    /// Cancels provider/generation work only. It must not implicitly stop audio.
    func cancelJobs()
}

/// A small adapter for incrementally wrapping the existing VoiceController
/// lifecycle without creating a second audio-session owner.
@MainActor final class ClosureVoiceEngine: VoiceEngine {
    typealias StartCapture = @MainActor (VoiceGenerationToken, @escaping VoiceEngineReceiver) async throws -> Void
    typealias StopCapture = @MainActor () async -> Void
    typealias Play = @MainActor (VoicePlaybackRequest, VoiceGenerationToken, @escaping VoiceEngineReceiver) async throws -> Void
    typealias Stop = @MainActor () -> Void

    let kind: VoiceEngineKind
    private let startCaptureBody: StartCapture
    private let stopCaptureBody: StopCapture
    private let playBody: Play
    private let stopPlaybackBody: Stop
    private let cancelJobsBody: Stop

    init(kind: VoiceEngineKind, startCapture: @escaping StartCapture, stopCapture: @escaping StopCapture,
         play: @escaping Play, stopPlayback: @escaping Stop, cancelJobs: @escaping Stop) {
        self.kind = kind
        startCaptureBody = startCapture
        stopCaptureBody = stopCapture
        playBody = play
        stopPlaybackBody = stopPlayback
        cancelJobsBody = cancelJobs
    }

    func startCapture(token: VoiceGenerationToken, receive: @escaping VoiceEngineReceiver) async throws {
        try await startCaptureBody(token, receive)
    }
    func stopCapture() async { await stopCaptureBody() }
    func play(_ request: VoicePlaybackRequest, token: VoiceGenerationToken,
              receive: @escaping VoiceEngineReceiver) async throws {
        try await playBody(request, token, receive)
    }
    func stopPlayback() { stopPlaybackBody() }
    func cancelJobs() { cancelJobsBody() }
}

/// Keeps the cloud path structurally present but permanently unable to acquire
/// capture until a real, separately validated implementation is supplied.
@MainActor final class DisabledCloudVoiceEngine: VoiceEngine {
    let kind: VoiceEngineKind = .cloud
    func startCapture(token: VoiceGenerationToken, receive: @escaping VoiceEngineReceiver) async throws {
        throw VoiceRuntimeError.cloudAudioNotAllowed
    }
    func stopCapture() async {}
    func play(_ request: VoicePlaybackRequest, token: VoiceGenerationToken,
              receive: @escaping VoiceEngineReceiver) async throws {
        throw VoiceRuntimeError.cloudAudioNotAllowed
    }
    func stopPlayback() {}
    func cancelJobs() {}
}

struct VoiceCloudFeatureGate: Equatable {
    let isEnabled: Bool
    let validationSucceeded: Bool

    init(isEnabled: Bool = false, validationSucceeded: Bool = false) {
        self.isEnabled = isEnabled
        self.validationSucceeded = validationSucceeded
    }

    var allowsUse: Bool { isEnabled && validationSucceeded }
}

struct VoiceCloudAccess: Equatable {
    let featureGate: VoiceCloudFeatureGate
    let audioConsent: Bool

    init(featureGate: VoiceCloudFeatureGate = .init(), audioConsent: Bool = false) {
        self.featureGate = featureGate
        self.audioConsent = audioConsent
    }

    var allowsCloudAudio: Bool { featureGate.allowsUse && audioConsent }
}

enum VoiceRuntimeError: Error, Equatable {
    case cloudAudioNotAllowed
    case privateSpeechRequiresSafeMode
    case invalidEngineConfiguration
    case noActiveEngine
}

/// Serializes engine transitions while keeping capture, playback and job
/// generations independent. No transcript or audio is retained here.
@MainActor final class VoiceRuntimeCoordinator {
    private let local: any VoiceEngine
    private let cloud: any VoiceEngine
    private let onEvent: @MainActor (VoiceRuntimeEvent) -> Void
    private var transitionTail: Task<Void, Never>?
    private var transitionIntent = UUID()
    private var generations: [VoiceOperation: VoiceGenerationToken] = [:]
    private var owner: (any VoiceEngine)?
    private var startingEngine: (any VoiceEngine)?

    private(set) var mode: VoiceRuntimeMode = .off
    private(set) var cloudAccess: VoiceCloudAccess

    init(
        local: any VoiceEngine,
        cloud: any VoiceEngine,
        cloudAccess: VoiceCloudAccess = .init(),
        onEvent: @escaping @MainActor (VoiceRuntimeEvent) -> Void
    ) {
        self.local = local
        self.cloud = cloud
        self.cloudAccess = cloudAccess
        self.onEvent = onEvent
    }

    convenience init(
        local: any VoiceEngine,
        onEvent: @escaping @MainActor (VoiceRuntimeEvent) -> Void
    ) {
        self.init(local: local, cloud: DisabledCloudVoiceEngine(), onEvent: onEvent)
    }

    func updateCloudAccess(_ access: VoiceCloudAccess) async {
        cloudAccess = access
        let cloudIsStartingOrActive = owner?.kind == .cloud || startingEngine?.kind == .cloud ||
            mode == .transitioning(to: .cloud) || mode == .active(.cloud)
        if cloudIsStartingOrActive, !access.allowsCloudAudio {
            await stopAll()
        }
    }

    @discardableResult func activateLocalCapture() async throws -> VoiceGenerationToken {
        let intent = nextIntent()
        invalidateAll()
        mode = .transitioning(to: .local)
        return try await enqueue { [self] in try await activate(local, intent: intent) }
    }

    @discardableResult func activateCloudCapture() async throws -> VoiceGenerationToken {
        guard cloudAccess.allowsCloudAudio else { throw VoiceRuntimeError.cloudAudioNotAllowed }
        let intent = nextIntent()
        invalidateAll()
        mode = .transitioning(to: .cloud)
        return try await enqueue { [self] in
            try requireCurrent(intent)
            guard cloudAccess.allowsCloudAudio else { throw VoiceRuntimeError.cloudAudioNotAllowed }
            return try await activate(cloud, intent: intent)
        }
    }

    /// Safe Mode never silently falls back from cloud failure. It is an explicit
    /// transition that closes the current capture before private local speech.
    @discardableResult func enterSafeMode(speaking text: String) async throws -> VoiceGenerationToken {
        let intent = nextIntent()
        invalidateAll()
        mode = .transitioning(to: .local)
        return try await enqueue { [self] in
            try requireCurrent(intent)
            try validateConfiguration()
            await closeOwner()
            try requireCurrent(intent)
            owner = local
            mode = .safeMode
            let token = replaceToken(for: .playback)
            try await local.play(.init(text, privacy: .privateLocal), token: token, receive: receiver)
            guard isCurrent(intent), accepts(token) else { local.stopPlayback(); throw CancellationError() }
            return token
        }
    }

    @discardableResult func play(_ request: VoicePlaybackRequest) async throws -> VoiceGenerationToken {
        guard let owner else { throw VoiceRuntimeError.noActiveEngine }
        if owner.kind == .cloud, request.privacy == .privateLocal {
            throw VoiceRuntimeError.privateSpeechRequiresSafeMode
        }
        let token = replaceToken(for: .playback)
        try await owner.play(request, token: token, receive: receiver)
        guard accepts(token) else { owner.stopPlayback(); throw CancellationError() }
        return token
    }

    /// Creates a bounded, replace-in-place token for callbacks from an upstream
    /// response job. Starting a new job makes the previous callback stale.
    func beginJob() -> VoiceGenerationToken {
        replaceToken(for: .job)
    }

    func stopPlayback() {
        generations[.playback] = nil
        owner?.stopPlayback()
    }

    func cancelJob() {
        generations[.job] = nil
        owner?.cancelJobs()
    }

    func stopAll() async {
        let intent = nextIntent()
        invalidateAll()
        // An adapter may be suspended in startCapture(). Closing it here gives
        // revocation a way to interrupt that await instead of waiting forever.
        if let startingEngine { await startingEngine.stopCapture() }
        await enqueueNoThrow { [self] in
            guard isCurrent(intent) else { return }
            await closeOwner()
            guard isCurrent(intent) else { return }
            mode = .off
        }
    }

    /// Engines and model jobs feed callbacks through this gate. The token and
    /// event domain must both match, rejecting late or cross-wired callbacks.
    @discardableResult func deliver(_ event: VoiceRuntimeEvent, token: VoiceGenerationToken) -> Bool {
        guard event.operation == token.operation, accepts(token) else { return false }
        onEvent(event)
        return true
    }

    func accepts(_ token: VoiceGenerationToken) -> Bool {
        generations[token.operation] == token
    }

    private var receiver: VoiceEngineReceiver {
        { [weak self] token, event in _ = self?.deliver(event, token: token) }
    }

    private func activate(_ engine: any VoiceEngine, intent: UUID) async throws -> VoiceGenerationToken {
        try requireCurrent(intent)
        try validateConfiguration()
        await closeOwner()
        try requireCurrent(intent)
        let token = replaceToken(for: .capture)
        startingEngine = engine
        do {
            try await engine.startCapture(token: token, receive: receiver)
        } catch {
            if startingEngine === engine { startingEngine = nil }
            await engine.stopCapture()
            engine.stopPlayback()
            engine.cancelJobs()
            if isCurrent(intent), accepts(token) { generations[.capture] = nil; mode = .off }
            throw error
        }
        if startingEngine === engine { startingEngine = nil }
        guard isCurrent(intent), accepts(token), engine.kind != .cloud || cloudAccess.allowsCloudAudio else {
            await engine.stopCapture()
            throw CancellationError()
        }
        owner = engine
        mode = .active(engine.kind)
        return token
    }

    private func closeOwner() async {
        guard let current = owner else { return }
        owner = nil
        await current.stopCapture()
        current.stopPlayback()
        current.cancelJobs()
    }

    private func validateConfiguration() throws {
        guard local.kind == .local, cloud.kind == .cloud else {
            throw VoiceRuntimeError.invalidEngineConfiguration
        }
    }

    private func replaceToken(for operation: VoiceOperation) -> VoiceGenerationToken {
        let token = VoiceGenerationToken(operation: operation)
        generations[operation] = token
        return token
    }

    private func invalidateAll() {
        generations.removeAll(keepingCapacity: true)
    }

    private func nextIntent() -> UUID {
        let intent = UUID()
        transitionIntent = intent
        return intent
    }

    private func isCurrent(_ intent: UUID) -> Bool { transitionIntent == intent }

    private func requireCurrent(_ intent: UUID) throws {
        guard isCurrent(intent) else { throw CancellationError() }
    }

    private func enqueue<T>(_ work: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = transitionTail
        let operation = Task { @MainActor in
            await previous?.value
            return try await work()
        }
        transitionTail = Task { @MainActor in _ = try? await operation.value }
        return try await operation.value
    }

    private func enqueueNoThrow(_ work: @escaping @MainActor () async -> Void) async {
        let previous = transitionTail
        let operation = Task { @MainActor in
            await previous?.value
            await work()
        }
        transitionTail = operation
        await operation.value
    }
}
