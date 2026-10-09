@preconcurrency import AVFoundation
import Foundation

// On-device Whisper's rules, ported from the old KemoSabe app (`legacy/ios/KemoSabe/OnDeviceWhisper.swift`):
// Apple's recognizer gives the live words and helps find the end of what you say; then Whisper reads the
// same audio again, on this device, and its text replaces Apple's before anything is sent. Audio never
// leaves the device on this path, and it is only ever in memory.

/// When Whisper runs and which text wins. Pure, so it's unit tested.
public enum WhisperTranscription {
    public struct Conditions: Equatable, Sendable {
        public var installed: Bool
        /// A Metal GPU MLX can use (not the Simulator).
        public var supported: Bool
        /// iPhone: the app is in front. Always true on Mac.
        public var foreground: Bool
        /// iPhone: protected data is readable (the device is unlocked). Always true on Mac.
        public var unlocked: Bool
        public init(installed: Bool, supported: Bool, foreground: Bool = true, unlocked: Bool = true) {
            self.installed = installed; self.supported = supported; self.foreground = foreground; self.unlocked = unlocked
        }
    }
    /// Whisper runs only when downloaded and able to run now; the background and a locked iPhone quietly
    /// keep Apple's recognizer. (The old app's Talk to KemoSabe and watch surfaces aren't in Tsukumo.)
    public static func shouldRun(_ conditions: Conditions) -> Bool {
        conditions.installed && conditions.supported && conditions.foreground && conditions.unlocked
    }

    public enum Outcome: Equatable, Sendable { case transcribed(String), failed, timedOut, skipped }
    public enum Source: Equatable, Sendable { case whisper, apple }
    public struct Final: Equatable, Sendable {
        public let text: String
        public let source: Source
        public init(text: String, source: Source) { self.text = text; self.source = source }
    }
    /// Whisper's text when it produced a usable transcript; Apple's otherwise (failure, timeout, skipped,
    /// empty, or a known silence hallucination).
    public static func finalText(apple: String, outcome: Outcome, names: [String] = []) -> Final {
        let heard = apple.trimmingCharacters(in: .whitespacesAndNewlines)
        guard case .transcribed(let raw) = outcome else { return Final(text: heard, source: .apple) }
        let text = restoringNames(normalized(raw), apple: heard, names: names)
        guard !text.isEmpty, !looksLikeHallucination(text, apple: heard) else { return Final(text: heard, source: .apple) }
        return Final(text: text, source: .whisper)
    }

    /// Apple's recognizer is hinted with the bots' names; Whisper isn't, and hears "KemoSabe" as "Kimo Saib"
    /// or "chemo save". When Apple heard a name and Whisper didn't, the closest one- to three-word stretch of
    /// Whisper's text within 40% edit distance is spelled as the name.
    public static func restoringNames(_ text: String, apple: String, names: [String]) -> String {
        var words = text.split(separator: " ").map(String.init)
        for name in names {
            let target = letters(name)
            guard target.count >= 4, letters(apple).contains(target), !letters(text).contains(target), !words.isEmpty else { continue }
            var best: (range: Range<Int>, score: Double)?
            for start in words.indices {
                for length in 1...3 where start + length <= words.count {
                    let candidate = letters(words[start..<(start + length)].joined())
                    guard !candidate.isEmpty else { continue }
                    let score = Double(editDistance(candidate, target)) / Double(target.count)
                    if score < (best?.score ?? .infinity) { best = (start..<(start + length), score) }
                }
            }
            guard let best, best.score <= 0.4 else { continue }
            let trailing = String(words[best.range.upperBound - 1].reversed().prefix { !$0.isLetter && !$0.isNumber }.reversed())
            let leading = String(words[best.range.lowerBound].prefix { !$0.isLetter && !$0.isNumber })
            words.replaceSubrange(best.range, with: [leading + name + trailing])
        }
        return words.joined(separator: " ")
    }
    private static func letters(_ text: String) -> String { String(text.lowercased().filter { $0.isLetter }) }
    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        var previous = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var current = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, y) in b.enumerated() { current[j + 1] = min(previous[j + 1] + 1, current[j] + 1, previous[j] + (x == y ? 0 : 1)) }
            previous = current
        }
        return previous[b.count]
    }

    /// How long to wait for Whisper before keeping Apple's text: an allowance for a cold start plus time
    /// proportional to the audio, capped so a long turn never stalls.
    public static func timeout(forAudioSeconds seconds: Double) -> TimeInterval {
        guard seconds.isFinite, seconds > 0 else { return minimumTimeout }
        return min(maximumTimeout, minimumTimeout + seconds * perAudioSecond)
    }
    public static let minimumTimeout: TimeInterval = 3
    public static let perAudioSecond: TimeInterval = 0.5
    public static let maximumTimeout: TimeInterval = 20

    /// Cleans Whisper's text: drops non-speech tags ("[BLANK_AUDIO]", "(music)"), a leading dash, and stray
    /// whitespace.
    public static func normalized(_ text: String) -> String {
        var result = text.replacingOccurrences(of: #"\[[^\]]{0,40}\]"#, with: " ", options: .regularExpression)
        // "(music)" or "*laughs*" go; a real parenthetical ("(the blue one)") stays.
        let tags = (try? NSRegularExpression(pattern: #"[\(\*][^\)\*]{0,30}[\)\*]"#))?
            .matches(in: result, range: NSRange(result.startIndex..., in: result)) ?? []
        for match in tags.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let inner = result[range].dropFirst().dropLast().lowercased()
            if nonSpeech.contains(where: { inner.contains($0) }) { result.replaceSubrange(range, with: " ") }
        }
        result = result.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("-") || result.hasPrefix(">>") {
            result = String(result.drop { $0 == "-" || $0 == ">" }).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
    private static let nonSpeech = ["music", "laugh", "applause", "silence", "inaudible", "noise", "sigh", "cough",
                                    "blank", "static", "breath", "clears throat", "background"]

    /// Phrases Whisper is known to produce from silence or noise, and runaway repetition. Kept only when
    /// Apple heard the same thing.
    public static func looksLikeHallucination(_ whisper: String, apple: String) -> Bool {
        let bare = whisper.lowercased().components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .trimmingCharacters(in: .whitespaces)
        if silencePhrases.contains(bare), !apple.lowercased().contains(bare) { return true }
        if !apple.isEmpty, whisper.count > apple.count * 3 + 60 { return true }
        return false
    }
    private static let silencePhrases: Set<String> = ["you", "thank you", "thanks for watching", "thank you for watching",
                                                      "thank you so much for watching", "please subscribe", "bye"]

    /// Runs `work` against a deadline. MLX can't be interrupted mid-pass, so a late result is ignored; the
    /// caller has already moved on with Apple's text.
    public static func race(timeout: TimeInterval, _ work: @escaping @Sendable () async throws -> String) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let once = FirstOutcome(continuation)
            Task.detached(priority: .userInitiated) {
                do { once.resume(.transcribed(try await work())) } catch { once.resume(.failed) }
            }
            Task.detached {
                try? await Task.sleep(for: .seconds(max(0, timeout)))
                once.resume(.timedOut)
            }
        }
    }
    /// The whole choice for one utterance: skip when Whisper can't run, otherwise race it against its
    /// timeout and pick the text.
    public static func select(apple: String, conditions: Conditions, audioSeconds: Double, timeout: TimeInterval? = nil, names: [String] = [],
                              transcribe: @escaping @Sendable () async throws -> String) async -> Final {
        guard shouldRun(conditions) else { return finalText(apple: apple, outcome: .skipped) }
        let outcome = await race(timeout: timeout ?? self.timeout(forAudioSeconds: audioSeconds), transcribe)
        return finalText(apple: apple, outcome: outcome, names: names)
    }
}

private final class FirstOutcome: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<WhisperTranscription.Outcome, Never>?
    init(_ continuation: CheckedContinuation<WhisperTranscription.Outcome, Never>) { self.continuation = continuation }
    func resume(_ outcome: WhisperTranscription.Outcome) {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(returning: outcome)
    }
}

/// Whisper's input: 16 kHz mono Float32 samples.
public enum WhisperAudioInput {
    public static let sampleRate: Double = 16_000
    public enum Failure: Error { case format }
    static var format: AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)
    }

    /// Captured microphone buffers (any rate, any channel count) as 16 kHz mono. Runs of buffers with the
    /// same format convert together, so a route change mid-utterance still works.
    public static func monoSamples(from buffers: [AVAudioPCMBuffer]) throws -> [Float] {
        var samples: [Float] = []
        var index = buffers.startIndex
        while index < buffers.endIndex {
            let format = buffers[index].format
            var run: [AVAudioPCMBuffer] = []
            while index < buffers.endIndex, buffers[index].format == format { run.append(buffers[index]); index += 1 }
            samples += try convert(run, from: format)
        }
        return samples
    }

    private static func convert(_ run: [AVAudioPCMBuffer], from source: AVAudioFormat) throws -> [Float] {
        guard let target = format, source.sampleRate > 0 else { throw Failure.format }
        if source.commonFormat == .pcmFormatFloat32, source.sampleRate == sampleRate, source.channelCount == 1 {
            return run.flatMap { buffer in
                guard let channel = buffer.floatChannelData?[0] else { return [Float]() }
                return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
            }
        }
        guard let converter = AVAudioConverter(from: source, to: target) else { throw Failure.format }
        converter.downmix = true
        let frames = run.reduce(0) { $0 + Int($1.frameLength) }
        let capacity = AVAudioFrameCount(Double(frames) * sampleRate / source.sampleRate) + 4096
        var samples: [Float] = []
        samples.reserveCapacity(Int(capacity))
        var next = run.startIndex
        while true {
            guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { throw Failure.format }
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, state in
                guard next < run.endIndex else { state.pointee = .endOfStream; return nil }
                defer { next += 1 }
                state.pointee = .haveData
                return run[next]
            }
            if let failure { throw failure }
            if let channel = output.floatChannelData?[0], output.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            }
            switch status {
            case .haveData: continue
            case .error: throw Failure.format
            default: return samples
            }
        }
    }
}
