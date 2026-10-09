@preconcurrency import AVFoundation
import Foundation

// Playing replies, ported from the old app's `SpeechPlayer` (`legacy/ios/KemoSabe/SpeechVoices.swift`): a
// sentence at a time, making the next while the current one plays, and if a neural voice fails partway, the
// Apple voice says what wasn't spoken yet. New: a reply is spoken while it's still streaming in, sentence by
// sentence (`ReplySpeech`), so the first words play before the bot has finished.

/// Where speech is played. The real one is `AVAudioOutput`; tests use a fake that records what it played.
@MainActor public protocol AudioOutput: AnyObject {
    func play(_ audio: SpeechAudio) async throws
    func stop()
}

/// Plays speech with `AVAudioPlayer`.
@MainActor public final class AVAudioOutput: NSObject, AudioOutput, AVAudioPlayerDelegate {
    private var player: AVAudioPlayer?
    private var finished: CheckedContinuation<Void, Error>?
    public override init() { super.init() }

    public func play(_ audio: SpeechAudio) async throws {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        if session.category != .playAndRecord { try? session.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .allowBluetoothHFP]) }
        try? session.setActive(true, options: [])
        #endif
        let player = try AVAudioPlayer(data: audio.wav)
        player.delegate = self
        self.player = player
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                finished = continuation
                if !player.play() { finished = nil; continuation.resume(throwing: SpeechEngineError.synthesisFailed("playback didn’t start")) }
            }
        } onCancel: {
            Task { @MainActor in self.stop() }
        }
    }
    public func stop() {
        player?.stop(); player = nil
        let continuation = finished; finished = nil
        continuation?.resume(throwing: CancellationError())
    }
    nonisolated public func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.player = nil
            let continuation = self.finished; self.finished = nil
            continuation?.resume()
        }
    }
    nonisolated public func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) {
        let id = ObjectIdentifier(player)
        Task { @MainActor in
            guard let current = self.player, ObjectIdentifier(current) == id else { return }
            self.player = nil
            let continuation = self.finished; self.finished = nil
            continuation?.resume(throwing: SpeechEngineError.synthesisFailed("audio couldn’t be decoded"))
        }
    }
}

/// Speaks sentences in order: one task makes the audio (running ahead of playback), another plays it. If
/// the voice fails, the fallback voice makes that sentence and the rest.
@MainActor public final class SpeechQueue {
    private let output: any AudioOutput
    private var engine: any SpeechEngine
    private let fallback: () -> any SpeechEngine
    private let sentences: AsyncStream<String>
    private let feed: AsyncStream<String>.Continuation
    private var making: Task<Void, Never>?
    private var playing: Task<Void, Never>?
    /// Every sentence was played, or the queue was stopped.
    public private(set) var isDone = false
    /// Whether the fallback voice took over.
    public private(set) var fellBack = false
    public var onDone: (() -> Void)?

    public init(engine: any SpeechEngine, fallback: @escaping () -> any SpeechEngine, output: any AudioOutput) {
        self.engine = engine; self.fallback = fallback; self.output = output
        (sentences, feed) = AsyncStream.makeStream(of: String.self)
        let (audio, audioFeed) = AsyncStream.makeStream(of: SpeechAudio.self)
        making = Task { [weak self] in
            guard let stream = self?.sentences else { audioFeed.finish(); return }
            for await sentence in stream {
                guard let self, !Task.isCancelled else { break }
                if let made = await self.make(sentence) { audioFeed.yield(made) }
            }
            audioFeed.finish()
        }
        playing = Task { [weak self] in
            for await clip in audio {
                guard let self, !Task.isCancelled else { break }
                do { try await self.output.play(clip) } catch { break }
            }
            self?.finishUp()
        }
    }

    private func make(_ sentence: String) async -> SpeechAudio? {
        do { return try await engine.synthesize(sentence) } catch {
            guard !Task.isCancelled, !(error is CancellationError) else { return nil }
            if !fellBack { fellBack = true; engine = fallback() }
            return try? await engine.synthesize(sentence)
        }
    }

    public func append(_ sentence: String) {
        guard !isDone, !sentence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        feed.yield(sentence)
    }
    /// No more sentences are coming; the queue ends after the last one plays.
    public func finish() { feed.finish() }
    /// Stops at once (barge-in, a new turn, or the owner's stop).
    public func stop() {
        guard !isDone else { return }
        feed.finish()
        making?.cancel(); playing?.cancel()
        output.stop()
        finishUp()
    }
    private func finishUp() {
        guard !isDone else { return }
        isDone = true
        onDone?()
    }
}

/// A reply being spoken while it streams in: complete sentences go to the queue as soon as they're there.
@MainActor public final class ReplySpeech {
    public let botID: UUID
    let queue: SpeechQueue
    private var queuedCount = 0
    private var ended = false

    init(botID: UUID, queue: SpeechQueue) { self.botID = botID; self.queue = queue }

    /// The reply so far (the whole text each time). `final` speaks whatever is left.
    public func update(_ text: String, final: Bool) {
        guard !ended else { return }
        let stable = SpeechChunks.stablePrefix(text, final: final)
        if stable.count > queuedCount {
            let fresh = String(stable.dropFirst(queuedCount))
            queuedCount = stable.count
            for sentence in SpeechChunks.sentences(SpeechText.prepared(fresh)) { queue.append(sentence) }
        }
        if final { ended = true; queue.finish() }
    }
    public func stop() { ended = true; queue.stop() }
    public var isDone: Bool { queue.isDone }
}
