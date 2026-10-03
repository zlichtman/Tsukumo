import XCTest
@testable import KemoSabe

@MainActor final class VoiceRuntimeTests: XCTestCase {
    func testCloudRequiresConsentAndValidatedEnabledGate() async throws {
        for access in [
            VoiceCloudAccess(),
            VoiceCloudAccess(featureGate: .init(isEnabled: true), audioConsent: true),
            VoiceCloudAccess(featureGate: .init(isEnabled: true, validationSucceeded: true), audioConsent: false)
        ] {
            let fixture = Fixture(access: access)
            do {
                try await fixture.runtime.activateCloudCapture()
                XCTFail("Cloud capture must remain closed")
            } catch {
                XCTAssertEqual(error as? VoiceRuntimeError, .cloudAudioNotAllowed)
            }
            XCTAssertTrue(fixture.log.values.isEmpty)
        }
    }

    func testTransitionHasOneCaptureOwnerAndStopsLocalBeforeCloudStarts() async throws {
        let fixture = Fixture(access: .allowed)
        try await fixture.runtime.activateLocalCapture()
        try await fixture.runtime.activateCloudCapture()
        XCTAssertEqual(fixture.log.values, ["local.capture.start", "local.capture.stop",
            "local.playback.stop", "local.jobs.cancel", "cloud.capture.start"])
        XCTAssertFalse(fixture.local.capturing)
        XCTAssertTrue(fixture.cloud.capturing)
        XCTAssertEqual(fixture.runtime.mode, .active(.cloud))
    }

    func testSafeModeClosesCloudBeforePrivateLocalSpeech() async throws {
        let fixture = Fixture(access: .allowed)
        try await fixture.runtime.activateCloudCapture()
        try await fixture.runtime.enterSafeMode(speaking: "private local answer")
        XCTAssertEqual(fixture.log.values, ["cloud.capture.start", "cloud.capture.stop",
            "cloud.playback.stop", "cloud.jobs.cancel", "local.play.privateLocal"])
        XCTAssertFalse(fixture.cloud.capturing)
        XCTAssertEqual(fixture.local.lastPlayback?.text, "private local answer")
        XCTAssertEqual(fixture.runtime.mode, .safeMode)
    }

    func testPrivateSpeechCannotReachCloudWithoutSafeMode() async throws {
        let fixture = Fixture(access: .allowed)
        try await fixture.runtime.activateCloudCapture()
        do {
            try await fixture.runtime.play(.init("secret", privacy: .privateLocal))
            XCTFail("Private speech must use the explicit Safe Mode transition")
        } catch {
            XCTAssertEqual(error as? VoiceRuntimeError, .privateSpeechRequiresSafeMode)
        }
        XCTAssertNil(fixture.cloud.lastPlayback)
    }

    func testLateAndCrossWiredCallbacksAreRejected() async throws {
        let fixture = Fixture(access: .allowed)
        let oldCapture = try await fixture.runtime.activateLocalCapture()
        let job = fixture.runtime.beginJob()
        try await fixture.runtime.activateCloudCapture()

        XCTAssertFalse(fixture.runtime.accepts(oldCapture))
        fixture.local.emitCapture("stale")
        XCTAssertFalse(fixture.runtime.deliver(.jobText("stale", final: true), token: job))
        let current = try XCTUnwrap(fixture.cloud.captureToken)
        XCTAssertFalse(fixture.runtime.deliver(.playbackFinished, token: current))
        XCTAssertTrue(fixture.runtime.deliver(.transcript("current", final: false), token: current))
        XCTAssertEqual(fixture.received, [.transcript("current", final: false)])
    }

    func testPlaybackStopAndJobCancellationAreIndependent() async throws {
        let fixture = Fixture()
        try await fixture.runtime.activateLocalCapture()
        let job = fixture.runtime.beginJob()
        let playback = try await fixture.runtime.play(.init("hello"))

        fixture.runtime.stopPlayback()
        XCTAssertFalse(fixture.runtime.accepts(playback))
        XCTAssertTrue(fixture.runtime.accepts(job))
        XCTAssertEqual(fixture.local.stopPlaybackCount, 1)
        XCTAssertEqual(fixture.local.cancelJobsCount, 0)

        fixture.runtime.cancelJob()
        XCTAssertFalse(fixture.runtime.accepts(job))
        XCTAssertEqual(fixture.local.stopPlaybackCount, 1)
        XCTAssertEqual(fixture.local.cancelJobsCount, 1)
    }

    func testControllerDefersLocalPlaybackUntilRuntimeOwnsLocalAudio() {
        XCTAssertFalse(VoiceController.localPlaybackReady(in: .off))
        XCTAssertFalse(VoiceController.localPlaybackReady(in: .transitioning(to: .local)))
        XCTAssertFalse(VoiceController.localPlaybackReady(in: .active(.cloud)))
        XCTAssertTrue(VoiceController.localPlaybackReady(in: .active(.local)))
        XCTAssertTrue(VoiceController.localPlaybackReady(in: .safeMode))
    }

    func testPlaybackFailureCaptionPreservesFullAvailableReply() {
        let caption = VoiceController.replyCaption(
            generatedText: "First sentence. **The reading is 12.5.** See https://example.com/path.",
            attemptedText: "The reading is 12.5."
        )

        XCTAssertEqual(caption, "First sentence. The reading is 12.5. See the link.")
    }

    func testPlaybackFailureCaptionFallsBackToAttemptedText() {
        XCTAssertEqual(
            VoiceController.replyCaption(generatedText: "  ", attemptedText: "Keep AB-204 unchanged."),
            "Keep AB-204 unchanged."
        )
    }

    func testRevokingCloudAccessClosesCloudCapture() async throws {
        let fixture = Fixture(access: .allowed)
        try await fixture.runtime.activateCloudCapture()
        await fixture.runtime.updateCloudAccess(.init())
        XCTAssertFalse(fixture.cloud.capturing)
        XCTAssertEqual(fixture.runtime.mode, .off)
    }

    func testRevokingCloudAccessInterruptsCloudStillStarting() async {
        let fixture = Fixture(access: .allowed)
        fixture.cloud.blocksStart = true
        let starting = Task { try await fixture.runtime.activateCloudCapture() }
        await fixture.cloud.startEntered.wait()
        await fixture.runtime.updateCloudAccess(.init())
        do { _ = try await starting.value; XCTFail("Revoked cloud startup must not become active") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(fixture.cloud.capturing)
        XCTAssertEqual(fixture.runtime.mode, .off)
    }

    func testLatestTransitionWinsBeforeOlderStartCanResurrect() async throws {
        let fixture = Fixture(access: .allowed)
        fixture.local.blocksStart = true
        let old = Task { try await fixture.runtime.activateLocalCapture() }
        await fixture.local.startEntered.wait()
        let latest = Task { try await fixture.runtime.activateCloudCapture() }
        await expectMode(.transitioning(to: .cloud), runtime: fixture.runtime)
        fixture.local.releaseStart()

        do { _ = try await old.value; XCTFail("The superseded transition must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        _ = try await latest.value
        XCTAssertFalse(fixture.local.capturing)
        XCTAssertTrue(fixture.cloud.capturing)
        XCTAssertEqual(fixture.runtime.mode, .active(.cloud))
    }

    func testStopAllInterruptsAnEngineStillStarting() async {
        let fixture = Fixture()
        fixture.local.blocksStart = true
        let starting = Task { try await fixture.runtime.activateLocalCapture() }
        await fixture.local.startEntered.wait()
        await fixture.runtime.stopAll()
        do { _ = try await starting.value; XCTFail("Stopped startup must not become active") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(fixture.local.capturing)
        XCTAssertEqual(fixture.runtime.mode, .off)
    }

    func testConvenienceRuntimeKeepsCloudPermanentlyDisabled() async {
        let log = RuntimeLog()
        let runtime = VoiceRuntimeCoordinator(local: FakeVoiceEngine(kind: .local, log: log)) { _ in }
        await runtime.updateCloudAccess(.allowed)
        do { _ = try await runtime.activateCloudCapture(); XCTFail("Disabled cloud adapter must not start") }
        catch { XCTAssertEqual(error as? VoiceRuntimeError, .cloudAudioNotAllowed) }
    }

    private func expectMode(_ expected: VoiceRuntimeMode, runtime: VoiceRuntimeCoordinator) async {
        for _ in 0..<100 {
            if runtime.mode == expected { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for mode \(expected)")
    }
}

@MainActor private final class Fixture {
    let log = RuntimeLog()
    let local: FakeVoiceEngine
    let cloud: FakeVoiceEngine
    var received: [VoiceRuntimeEvent] = []
    lazy var runtime = VoiceRuntimeCoordinator(local: local, cloud: cloud, cloudAccess: access) { [weak self] in
        self?.received.append($0)
    }
    let access: VoiceCloudAccess

    init(access: VoiceCloudAccess = .init()) {
        self.access = access
        local = FakeVoiceEngine(kind: .local, log: log)
        cloud = FakeVoiceEngine(kind: .cloud, log: log)
    }
}

private extension VoiceCloudAccess {
    static let allowed = VoiceCloudAccess(
        featureGate: .init(isEnabled: true, validationSucceeded: true),
        audioConsent: true
    )
}

@MainActor private final class RuntimeLog {
    var values: [String] = []
}

@MainActor private final class RuntimeLatch {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        guard !open else { return }
        open = true
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor private final class FakeVoiceEngine: VoiceEngine {
    let kind: VoiceEngineKind
    let log: RuntimeLog
    private(set) var capturing = false
    private(set) var captureToken: VoiceGenerationToken?
    private var captureReceiver: VoiceEngineReceiver?
    private(set) var lastPlayback: VoicePlaybackRequest?
    private(set) var stopPlaybackCount = 0
    private(set) var cancelJobsCount = 0
    var blocksStart = false
    let startEntered = RuntimeLatch()
    private var startWaiter: CheckedContinuation<Void, Never>?

    init(kind: VoiceEngineKind, log: RuntimeLog) {
        self.kind = kind
        self.log = log
    }

    func startCapture(token: VoiceGenerationToken, receive: @escaping VoiceEngineReceiver) async throws {
        capturing = true
        captureToken = token
        captureReceiver = receive
        log.values.append("\(kind.rawValue).capture.start")
        startEntered.signal()
        if blocksStart { await withCheckedContinuation { startWaiter = $0 } }
    }

    func stopCapture() async {
        capturing = false
        log.values.append("\(kind.rawValue).capture.stop")
        releaseStart()
    }

    func play(_ request: VoicePlaybackRequest, token: VoiceGenerationToken,
              receive: @escaping VoiceEngineReceiver) async throws {
        lastPlayback = request
        log.values.append("\(kind.rawValue).play.\(request.privacy)")
    }

    func stopPlayback() {
        stopPlaybackCount += 1
        log.values.append("\(kind.rawValue).playback.stop")
    }

    func cancelJobs() {
        cancelJobsCount += 1
        log.values.append("\(kind.rawValue).jobs.cancel")
    }

    func releaseStart() {
        blocksStart = false
        startWaiter?.resume()
        startWaiter = nil
    }

    func emitCapture(_ text: String) {
        guard let captureToken else { return }
        captureReceiver?(captureToken, .transcript(text, final: true))
    }
}
