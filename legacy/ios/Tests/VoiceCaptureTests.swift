import AVFoundation
import XCTest
@testable import KemoSabe

final class VoiceCaptureTests: XCTestCase {
    @MainActor func testPrimarySuccessIsEchoCancelledAndStartIsIdempotent() async throws {
        let fixture = CaptureFixture(failures: [nil])
        let capture = fixture.capture()
        checkTrue(try await capture.start { _ in })
        checkTrue(try await capture.start { _ in XCTFail("A running capture must not replace its callback") })
        XCTAssertTrue(capture.isRunning)
        XCTAssertEqual(fixture.events, ["create0", "start0:voiceProcessing"])
        XCTAssertTrue(capture.lastDiagnostics.isEmpty)
        capture.stop(); capture.stop(); await capture.waitUntilSettled()
        XCTAssertEqual(fixture.events.last, "stop0")
        XCTAssertEqual(fixture.backends[0].stopCount, 1)
        XCTAssertFalse(capture.isRunning)
    }

    @MainActor func testEveryPrimaryFailureCleansUpBeforeFreshStandardFallback() async throws {
        for stage in VoiceCaptureStage.allCases {
            let failure = VoiceCaptureBackendError(stage: stage, code: 17)
            let fixture = CaptureFixture(failures: [failure, nil])
            let capture = fixture.capture()
            checkFalse(try await capture.start { _ in }, "Fallback must disable echo-cancellation claims")
            XCTAssertEqual(fixture.events, ["create0", "start0:voiceProcessing", "stop0", "create1", "start1:standard"])
            XCTAssertTrue(capture.isRunning)
            XCTAssertNil(fixture.backends[0].callback)
            XCTAssertEqual(capture.lastDiagnostics, [.init(mode: .voiceProcessing, stage: stage, domain: "KemoSabe.VoiceCapture", code: 17)])
            capture.stop(); await capture.waitUntilSettled()
            XCTAssertEqual(fixture.backends[1].stopCount, 1)
            XCTAssertNil(fixture.backends[1].callback)
        }
    }

    @MainActor func testBothFailuresAreBoundedCleanedUpAndContentFree() async throws {
        let secret = "private transcript and device name must not escape"
        let first = VoiceCaptureBackendError(stage: .tapInstallation,
            error: NSError(domain: "AVFAudioErrorDomain", code: -10868, userInfo: [NSLocalizedDescriptionKey: secret]))
        let second = VoiceCaptureBackendError(stage: .engineStart,
            error: NSError(domain: NSOSStatusErrorDomain, code: -50, userInfo: [NSLocalizedDescriptionKey: secret]))
        let fixture = CaptureFixture(failures: [first, second])
        let capture = fixture.capture()
        await checkThrows({ try await capture.start { _ in } }) { error in
            guard let failure = error as? VoiceCaptureError else { return XCTFail("Expected capture diagnostics") }
            XCTAssertEqual(failure.diagnostics.map(\.stage), [.tapInstallation, .engineStart])
            XCTAssertEqual(failure.diagnostics.map(\.domain), ["AVFAudioErrorDomain", NSOSStatusErrorDomain])
            XCTAssertEqual(failure.diagnostics.map(\.code), [-10868, -50])
            XCTAssertFalse(failure.description.contains(secret))
            XCTAssertFalse(failure.localizedDescription.contains(secret))
        }
        XCTAssertFalse(capture.isRunning)
        XCTAssertEqual(fixture.events, ["create0", "start0:voiceProcessing", "stop0", "create1", "start1:standard", "stop1"])
        XCTAssertTrue(fixture.backends.allSatisfy { $0.callback == nil && $0.stopCount == 1 })
        XCTAssertEqual(capture.lastDiagnostics.count, 2)
        XCTAssertFalse(capture.handlesConfigurationChange(fixture.backends[1].engineObject))
    }

    @MainActor func testUnstagedFailureDoesNotLeakUnderlyingErrorDescription() async throws {
        let fixture = CaptureFixture(failures: [NSError(domain: "TestDomain", code: 42,
            userInfo: [NSLocalizedDescriptionKey: "secret audio context"]), nil])
        let capture = fixture.capture()
        checkFalse(try await capture.start { _ in })
        XCTAssertEqual(capture.lastDiagnostics, [.init(mode: .voiceProcessing, stage: .unknown, domain: "TestDomain", code: 42)])
        capture.stop(); await capture.waitUntilSettled()
    }

    @MainActor func testExplicitRetryAfterBothFailuresStartsFreshAndClearsOldDiagnostics() async throws {
        let fixture = CaptureFixture(failures: [VoiceCaptureBackendError(stage: .sessionActivation, code: 1),
                                               VoiceCaptureBackendError(stage: .inputFormat, code: 2), nil])
        let capture = fixture.capture()
        await checkThrows({ try await capture.start { _ in } })
        XCTAssertEqual(capture.lastDiagnostics.count, 2)
        checkTrue(try await capture.start { _ in })
        XCTAssertTrue(capture.isRunning)
        XCTAssertTrue(capture.lastDiagnostics.isEmpty)
        XCTAssertEqual(Array(fixture.events.suffix(2)), ["create2", "start2:voiceProcessing"])
        capture.stop(); await capture.waitUntilSettled()
    }

    @MainActor func testBackendReturningWithoutRunningAlsoFallsBack() async throws {
        let fixture = CaptureFixture(failures: [nil, nil])
        fixture.nonRunningIndices = [0]
        let capture = fixture.capture()
        checkFalse(try await capture.start { _ in })
        XCTAssertEqual(capture.lastDiagnostics.first?.stage, .engineStart)
        XCTAssertEqual(fixture.backends[0].stopCount, 1)
        capture.stop(); await capture.waitUntilSettled()
    }

    @MainActor func testConfigurationChangeOwnershipAndStoppedEngineRestart() async throws {
        let fixture = CaptureFixture(failures: [nil, nil])
        let capture = fixture.capture()
        XCTAssertFalse(capture.handlesConfigurationChange(nil))
        try await capture.start { _ in }
        let retired = fixture.backends[0]
        XCTAssertTrue(capture.handlesConfigurationChange(retired.engineObject))
        XCTAssertFalse(capture.handlesConfigurationChange(NSObject()))
        retired.isRunning = false // Hardware reconfiguration can stop the native engine itself.
        XCTAssertTrue(capture.handlesConfigurationChange(retired.engineObject))
        checkTrue(try await capture.start { _ in })
        XCTAssertEqual(retired.stopCount, 1)
        XCTAssertFalse(capture.handlesConfigurationChange(retired.engineObject))
        XCTAssertTrue(capture.handlesConfigurationChange(fixture.backends[1].engineObject))
        capture.stop(); await capture.waitUntilSettled()
        XCTAssertFalse(capture.handlesConfigurationChange(fixture.backends[1].engineObject))
    }

    func testTapUsesSupportedDurationAndRejectsUnavailableOrInvalidInput() throws {
        XCTAssertEqual(try VoiceCaptureFormat.tapFrames(sampleRate: 48_000, channels: 1), 4_800)
        XCTAssertEqual(try VoiceCaptureFormat.tapFrames(sampleRate: 44_100, channels: 2), 4_410)
        for rate in [0, -1, Double.nan, Double.infinity, Double.greatestFiniteMagnitude] {
            XCTAssertThrowsError(try VoiceCaptureFormat.tapFrames(sampleRate: rate, channels: 1)) { error in
                XCTAssertEqual((error as? VoiceCaptureBackendError)?.stage, .inputFormat)
            }
        }
        XCTAssertThrowsError(try VoiceCaptureFormat.tapFrames(sampleRate: 48_000, channels: 0))
    }

    @MainActor func testDeliveredAudioIsNotRetainedAndStopReleasesCallback() async throws {
        let fixture = CaptureFixture(failures: [nil])
        let capture = fixture.capture()
        weak var callbackOwner: NSObject?
        var delivered = 0
        do {
            let owner = NSObject(); callbackOwner = owner
            try await capture.start { [owner] _ in
                _ = owner; delivered += 1
            }
        }
        XCTAssertNotNil(callbackOwner)
        weak var deliveredBuffer: AVAudioPCMBuffer?
        do {
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
            buffer.frameLength = 4_800; deliveredBuffer = buffer
            fixture.backends[0].callback?(buffer)
        }
        XCTAssertEqual(delivered, 1)
        XCTAssertNil(deliveredBuffer)
        capture.stop(); await capture.waitUntilSettled()
        XCTAssertNil(callbackOwner)
        XCTAssertTrue(capture.lastDiagnostics.isEmpty)
    }

    @MainActor func testFailedCandidatesDoNotRetainCallback() async {
        let fixture = CaptureFixture(failures: [VoiceCaptureBackendError(stage: .inputFormat, code: 1),
                                               VoiceCaptureBackendError(stage: .engineStart, code: 2)])
        let capture = fixture.capture()
        weak var callbackOwner: NSObject?
        do {
            let owner = NSObject(); callbackOwner = owner
            await checkThrows({ try await capture.start { [owner] _ in _ = owner } })
        }
        XCTAssertNil(callbackOwner)
        XCTAssertFalse(capture.isRunning)
    }
}

@MainActor private final class CaptureFixture {
    let failures: [Error?]
    var nonRunningIndices: Set<Int> = []
    var events: [String] = []
    var backends: [FakeVoiceCaptureBackend] = []
    init(failures: [Error?]) { self.failures = failures }

    func capture() -> VoiceCapture {
        VoiceCapture(makeBackend: { [unowned self] in
            let index = self.backends.count
            precondition(index < self.failures.count, "Capture exceeded its bounded attempts")
            self.events.append("create\(index)")
            let backend = FakeVoiceCaptureBackend(index: index, failure: self.failures[index],
                becomesRunning: !self.nonRunningIndices.contains(index), record: { [weak self] in self?.events.append($0) })
            self.backends.append(backend)
            return backend
        })
    }
}

@MainActor private final class FakeVoiceCaptureBackend: VoiceCaptureBackend {
    let index: Int
    let failure: Error?
    let becomesRunning: Bool
    let record: (String) -> Void
    let engineObject: AnyObject? = NSObject()
    var isRunning = false
    var stopCount = 0
    var callback: ((AVAudioPCMBuffer) -> Void)?
    init(index: Int, failure: Error?, becomesRunning: Bool, record: @escaping (String) -> Void) {
        self.index = index; self.failure = failure; self.becomesRunning = becomesRunning; self.record = record
    }
    func start(mode: VoiceCaptureMode, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        record("start\(index):\(mode.rawValue)"); callback = onBuffer
        if let failure { throw failure }
        isRunning = becomesRunning
    }
    func deactivate() async {}
    func stopAudio() { record("stop\(index)"); stopCount += 1; isRunning = false; callback = nil }
}

@MainActor private func checkTrue(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertTrue(value, message, file: file, line: line) }
@MainActor private func checkFalse(_ value: Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) { XCTAssertFalse(value, message, file: file, line: line) }
@MainActor private func checkThrows(_ operation: () async throws -> Bool, file: StaticString = #filePath, line: UInt = #line, verify: (Error) -> Void = { _ in }) async {
    do { _ = try await operation(); XCTFail("Expected failure", file: file, line: line) } catch { verify(error) }
}

extension VoiceCaptureTests {
    @MainActor func testOffDuringActivationNeverStartsAudioOrFallback() async {
        let first = DelayedCaptureBackend(), fixture = DelayedCaptureFixture([first])
        first.activation = CaptureGate()
        let capture = fixture.capture()
        let start = Task { try await capture.start { _ in XCTFail("No audio after Off") } }
        await first.started.wait()
        capture.stop()
        XCTAssertFalse(capture.isRunning)
        first.activation?.open()
        await checkThrows({ try await start.value }) { XCTAssertTrue($0 is CancellationError) }
        await capture.waitUntilSettled()
        XCTAssertEqual(fixture.created, 1)
        XCTAssertEqual(first.deactivateCount, 1)
        XCTAssertFalse(first.isRunning)
        XCTAssertTrue(capture.lastDiagnostics.isEmpty)
    }

    @MainActor func testQuickOffOnWaitsForOldActivationAndDeactivation() async throws {
        let first = DelayedCaptureBackend(), second = DelayedCaptureBackend()
        first.activation = CaptureGate(); first.deactivation = CaptureGate()
        let fixture = DelayedCaptureFixture([first, second]), capture = fixture.capture()
        let oldStart = Task { try await capture.start { _ in } }
        await first.started.wait()
        capture.stop()
        let newStart = Task { try await capture.start { _ in } }
        first.activation?.open()
        await first.deactivating.wait()
        XCTAssertEqual(fixture.created, 1, "Must wait before starting a new audio session")
        XCTAssertFalse(capture.isRunning)
        first.deactivation?.open()
        await checkThrows({ try await oldStart.value }) { XCTAssertTrue($0 is CancellationError) }
        checkTrue(try await newStart.value)
        XCTAssertTrue(first.deactivated); XCTAssertTrue(second.isRunning)
        capture.stop(); await capture.waitUntilSettled()
    }

    @MainActor func testOffStopsAudioImmediatelyAndOldDeactivationCannotKillNewCapture() async throws {
        let first = DelayedCaptureBackend(), second = DelayedCaptureBackend()
        first.deactivation = CaptureGate()
        let fixture = DelayedCaptureFixture([first, second]), capture = fixture.capture()
        try await capture.start { _ in }
        capture.stop()
        XCTAssertFalse(first.isRunning); XCTAssertNil(first.callback)
        let restart = Task { try await capture.start { _ in } }
        await first.deactivating.wait()
        XCTAssertEqual(fixture.created, 1)
        first.deactivation?.open()
        checkTrue(try await restart.value)
        XCTAssertTrue(first.deactivated); XCTAssertTrue(capture.isRunning)
        capture.stop(); await capture.waitUntilSettled()
    }

    @MainActor func testCallerCancellationCleansUpWithoutFallback() async {
        let first = DelayedCaptureBackend(), fixture = DelayedCaptureFixture([first])
        first.activation = CaptureGate()
        let capture = fixture.capture(), start = Task { try await capture.start { _ in } }
        await first.started.wait()
        start.cancel(); first.activation?.open()
        await checkThrows({ try await start.value }) { XCTAssertTrue($0 is CancellationError) }
        await capture.waitUntilSettled()
        XCTAssertFalse(capture.isRunning); XCTAssertEqual(fixture.created, 1)
        XCTAssertTrue(first.deactivated); XCTAssertTrue(capture.lastDiagnostics.isEmpty)
    }
}

@MainActor private final class CaptureGate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }
    func open() {
        isOpen = true
        let continuations = waiting; waiting = []
        continuations.forEach { $0.resume() }
    }
}

@MainActor private final class DelayedCaptureFixture {
    let backends: [DelayedCaptureBackend]
    var created = 0
    init(_ backends: [DelayedCaptureBackend]) { self.backends = backends }
    func capture() -> VoiceCapture {
        VoiceCapture { [unowned self] in
            precondition(created < backends.count, "Unexpected fallback or extra startup")
            defer { created += 1 }
            return backends[created]
        }
    }
}

@MainActor private final class DelayedCaptureBackend: VoiceCaptureBackend {
    let started = CaptureGate(), deactivating = CaptureGate()
    var activation: CaptureGate?, deactivation: CaptureGate?
    var isRunning = false, deactivated = false
    var deactivateCount = 0
    var engineObject: AnyObject? = NSObject()
    var callback: ((AVAudioPCMBuffer) -> Void)?
    func start(mode: VoiceCaptureMode, onBuffer: @escaping (AVAudioPCMBuffer) -> Void) async throws {
        started.open(); callback = onBuffer
        await activation?.wait()
        try Task.checkCancellation()
        isRunning = true
    }
    func stopAudio() { isRunning = false; callback = nil }
    func deactivate() async {
        deactivateCount += 1; deactivating.open()
        await deactivation?.wait()
        deactivated = true
    }
}
