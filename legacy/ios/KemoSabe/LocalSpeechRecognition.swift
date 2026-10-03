import AVFoundation
import Speech
import Observation

/// Model downloads are explicit. Checking availability never starts capture or
/// sends an utterance to a server; the legacy recognizer is also local-only.
@MainActor @Observable final class RecognitionModelAssets {
    enum State { case checking, installed, needsDownload, unsupported }
    private(set) var state: State = .checking
    private(set) var downloading = false
    private(set) var message: String?
    private(set) var locale: Locale?
    var ready: Bool { state == .installed }

    func refresh() async {
        guard !downloading else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            state = .needsDownload; return
        }
        #endif
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) else {
            state = .unsupported; locale = nil; return
        }
        locale = supported
        state = await AssetInventory.status(forModules: Self.modules(locale: supported)) == .installed ? .installed : .needsDownload
    }

    func download() async {
        guard !downloading, state == .needsDownload, let locale else { return }
        downloading = true; message = nil
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: Self.modules(locale: locale)) {
                try await request.downloadAndInstall()
            }
        } catch {
            message = "The speech download didn’t finish. Check your connection and try again."
        }
        downloading = false
        await refresh()
    }
    static func modules(locale: Locale) -> [any SpeechModule] {
        [SpeechTranscriber(locale: locale, preset: .progressiveTranscription), detector()]
    }
    static func detector() -> SpeechDetector {
        SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium), reportResults: true)
    }
}

/// A finalized segment is not a finished conversational turn. SpeechAnalyzer
/// revises overlapping ranges; append-only handling repeats entire phrases.
struct LocalTranscript {
    struct Segment { let start: Double; let end: Double; let text: String; let final: Bool }
    private var segments: [Segment] = []
    mutating func replace(start: Double, end: Double, text: String, final: Bool = false) -> String {
        guard start.isFinite, end.isFinite, end >= start else { return rendered }
        // Apple publishes each phrase as volatile revisions followed by a final
        // result. A late partial must never erase already finalized words.
        // Ambiguous overlap is ignored; only non-final ranges are replaceable.
        guard !segments.contains(where: { $0.final && (($0.start < end && start < $0.end) || $0.start == start) }) else { return rendered }
        segments.removeAll { !$0.final && (($0.start < end && start < $0.end) || $0.start == start) }
        segments.append(.init(start: start, end: end, text: text, final: final))
        segments.sort { $0.start < $1.start }
        // The controller rotates a recognition cycle every 45 seconds. This
        // extra cap bounds pathological result streams without retaining audio.
        segments = Array(segments.suffix(128))
        return rendered
    }
    var rendered: String {
        String(segments.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " ").prefix(4000))
    }
}

enum LocalSpeechError: Error { case format, overflow }

/// Each packet owns its PCM bytes. A tap buffer cannot safely outlive Apple's
/// callback without copying; no references to a recycled hardware buffer escape.
struct SpeechAudioPacket: @unchecked Sendable {
    let buffer: AVAudioPCMBuffer
    init(copying source: AVAudioPCMBuffer) throws {
        guard source.frameLength > 0,
              let copy = AVAudioPCMBuffer(pcmFormat: source.format, frameCapacity: source.frameLength) else {
            throw LocalSpeechError.format
        }
        copy.frameLength = source.frameLength
        let from = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: source.audioBufferList))
        let to = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard from.count == to.count else { throw LocalSpeechError.format }
        for index in from.indices {
            guard let src = from[index].mData, let dest = to[index].mData,
                  from[index].mDataByteSize <= to[index].mDataByteSize else { throw LocalSpeechError.format }
            memcpy(dest, src, Int(from[index].mDataByteSize))
        }
        buffer = copy
    }
}

/// Only the audio callback and stream consumer touch this bounded bridge.
/// Overflow aborts the turn instead of silently dropping words or growing RAM.
final class SpeechAudioBridge: @unchecked Sendable {
    typealias Stream = AsyncThrowingStream<SpeechAudioPacket, Error>
    private let lock = NSLock()
    private var continuation: Stream.Continuation?
    func connect() -> Stream {
        let pair = Stream.makeStream(bufferingPolicy: .bufferingOldest(12))
        lock.lock(); continuation?.finish(); continuation = pair.continuation; lock.unlock()
        return pair.stream
    }
    func append(_ buffer: AVAudioPCMBuffer) {
        lock.lock(); defer { lock.unlock() }
        guard let continuation else { return }
        do {
            switch continuation.yield(try SpeechAudioPacket(copying: buffer)) {
            case .enqueued: break
            case .dropped:
                continuation.finish(throwing: LocalSpeechError.overflow); self.continuation = nil
            case .terminated: self.continuation = nil
            @unknown default: continuation.finish(throwing: LocalSpeechError.overflow); self.continuation = nil
            }
        } catch { continuation.finish(throwing: error); self.continuation = nil }
    }
    func disconnect() {
        lock.lock(); continuation?.finish(); continuation = nil; lock.unlock()
    }
}

/// Runs on the pump task, never on the real-time tap or UI actor. Reuses its
/// converter until the input format changes (for example, an AirPods route).
final class SpeechPCMConverter {
    let outputFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    init(outputFormat: AVAudioFormat) { self.outputFormat = outputFormat }
    func convert(_ input: AVAudioPCMBuffer) throws -> AVAudioPCMBuffer {
        if input.format == outputFormat { return input }
        guard input.format.sampleRate > 0 else { throw LocalSpeechError.format }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: outputFormat)
        }
        guard let converter else { throw LocalSpeechError.format }
        let capacity = ceil(Double(input.frameLength) * outputFormat.sampleRate / input.format.sampleRate) + 32
        guard capacity.isFinite, capacity > 0, capacity < Double(UInt32.max),
              let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: AVAudioFrameCount(capacity)) else {
            throw LocalSpeechError.format
        }
        var supplied = false, failure: NSError?
        let status = converter.convert(to: output, error: &failure) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true; state.pointee = .haveData; return input
        }
        if let failure { throw failure }
        guard status != .error else { throw LocalSpeechError.format }
        return output
    }
}

/// SpeechTranscriber is used only with already-installed model assets. A failed
/// modern recognizer can fall back to SFSpeechRecognizer without network ASR.
@MainActor final class ModernSpeechRecognition {
    let input = SpeechAudioBridge()
    private var analyzer: SpeechAnalyzer?
    private var work: [Task<Void, Never>] = []
    private var cleanup: Task<Void, Never>?
    private var generation = UUID()
    private var continuation: AsyncThrowingStream<AnalyzerInput, Error>.Continuation?

    func start(locale: Locale, context: [String], onText: @escaping @MainActor (String) -> Void,
               onActivity: @escaping @MainActor (Bool) -> Void,
               onFailure: @escaping @MainActor () -> Void) async throws {
        stop()
        let run = generation, previous = cleanup
        await previous?.value
        try Task.checkCancellation()
        guard generation == run else { throw CancellationError() }
        let transcriber = SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
        let detector = RecognitionModelAssets.detector()
        let modules: [any SpeechModule] = [transcriber, detector]
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw LocalSpeechError.format
        }
        try Task.checkCancellation()
        guard generation == run else { throw CancellationError() }
        let session = SpeechAnalyzer(modules: modules, options: .init(priority: .userInitiated, modelRetention: .lingering))
        analyzer = session
        let hints = AnalysisContext()
        hints.contextualStrings[.general] = context
        try await session.setContext(hints)
        try Task.checkCancellation()
        guard generation == run else { await session.cancelAndFinishNow(); throw CancellationError() }
        try await session.prepareToAnalyze(in: format)
        try Task.checkCancellation()
        guard generation == run else { await session.cancelAndFinishNow(); throw CancellationError() }
        let audio = input.connect()
        let analysis = AsyncThrowingStream<AnalyzerInput, Error>.makeStream(bufferingPolicy: .bufferingOldest(12))
        continuation = analysis.continuation
        let reportFailure: @MainActor () -> Void = { [weak self] in
            guard let self, self.generation == run else { return }
            self.stop(); onFailure()
        }
        work.append(Task.detached(priority: .userInitiated) {
            do {
                let converter = SpeechPCMConverter(outputFormat: format)
                for try await packet in audio {
                    try Task.checkCancellation()
                    let buffer = try converter.convert(packet.buffer)
                    guard buffer.frameLength > 0 else { continue }
                    switch analysis.continuation.yield(AnalyzerInput(buffer: buffer)) {
                    case .enqueued: break
                    case .dropped: throw LocalSpeechError.overflow
                    case .terminated: return
                    @unknown default: throw LocalSpeechError.overflow
                    }
                }
                analysis.continuation.finish()
            } catch {
                analysis.continuation.finish(throwing: error)
                if !Task.isCancelled { await reportFailure() }
            }
        })
        work.append(Task { [weak self] in
            var transcript = LocalTranscript()
            do {
                for try await result in transcriber.results {
                    guard !Task.isCancelled, let self, self.generation == run else { return }
                    let text = transcript.replace(start: result.range.start.seconds,
                        end: CMTimeRangeGetEnd(result.range).seconds, text: String(result.text.characters), final: result.isFinal)
                    onText(text)
                }
            } catch { if !Task.isCancelled { reportFailure() } }
        })
        work.append(Task { [weak self] in
            do {
                for try await result in detector.results {
                    guard !Task.isCancelled, let self, self.generation == run else { return }
                    onActivity(result.speechDetected)
                }
            } catch { if !Task.isCancelled { reportFailure() } }
        })
        work.append(Task {
            do { try await session.start(inputSequence: analysis.stream) }
            catch { if !Task.isCancelled { reportFailure() } }
        })
    }

    func stop() {
        generation = UUID(); input.disconnect(); continuation?.finish(); continuation = nil
        let retiredWork = work
        retiredWork.forEach { $0.cancel() }; work = []
        let retired = analyzer, previous = cleanup
        analyzer = nil
        cleanup = Task {
            await previous?.value; await retired?.cancelAndFinishNow()
            for task in retiredWork { await task.value }
        }
    }
}
