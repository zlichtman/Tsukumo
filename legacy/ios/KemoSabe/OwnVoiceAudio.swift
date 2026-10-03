import Foundation
import Accelerate
import AVFoundation
import AudioToolbox

/// The on-device clean-up behind "Your voice": measuring the room, live level feedback, and
/// turning the takes into one clean reference for the voice model. Everything here works on mono
/// float samples in memory; nothing is written or sent anywhere.
///
/// Per take: a high-pass filter (rumble and hum), noise reduction only when the room was noisy
/// (Apple's sound isolation where it runs offline, otherwise a spectral gate), silence trimmed
/// from both ends, and loudness brought to one level. Clipped takes are rejected. The reference
/// is the best takes, best first, up to the length the model uses.
enum OwnVoiceAudio {
    static let sampleRate = 24_000
    /// 20 ms analysis frames.
    static var frameLength: Int { sampleRate / 50 }

    // MARK: Levels

    static func decibels(_ amplitude: Float) -> Float { 20 * log10(max(amplitude, 1e-7)) }
    static func amplitude(_ decibels: Float) -> Float { pow(10, decibels / 20) }
    static func rms(_ samples: [Float]) -> Float { samples.isEmpty ? 0 : vDSP.rootMeanSquare(samples) }
    static func peak(_ samples: [Float]) -> Float { samples.isEmpty ? 0 : vDSP.maximumMagnitude(samples) }

    /// The level of each 20 ms frame in dBFS.
    static func frameLevels(_ samples: [Float], frame: Int = frameLength) -> [Float] {
        guard frame > 0, samples.count >= frame else { return samples.isEmpty ? [] : [decibels(rms(samples))] }
        return stride(from: 0, to: samples.count - frame + 1, by: frame).map { start in
            decibels(samples.withUnsafeBufferPointer { vDSP.rootMeanSquare(UnsafeBufferPointer(rebasing: $0[start..<(start + frame)])) })
        }
    }

    // MARK: The quiet check

    /// Room noise measured before recording: the median 20 ms level, so a single click or cough
    /// doesn't count as a noisy room.
    struct RoomNoise: Equatable, Codable, Sendable {
        let decibels: Float
        /// Above this the voice would carry the room with it.
        static let noisyAbove: Float = -48
        /// Below this, noise reduction is skipped so the voice stays untouched.
        static let quietBelow: Float = -60
        var isNoisy: Bool { decibels > Self.noisyAbove }
        var needsNoiseReduction: Bool { decibels > Self.quietBelow }
    }
    static func roomNoise(_ samples: [Float]) -> RoomNoise {
        let levels = frameLevels(samples).sorted()
        return RoomNoise(decibels: levels.isEmpty ? -120 : levels[levels.count / 2])
    }

    // MARK: Live feedback

    enum LevelFeedback: Equatable, Sendable {
        case listening, tooQuiet, good, tooLoud
        var label: String? {
            switch self {
            case .listening, .good: nil
            case .tooQuiet: "Too quiet"
            case .tooLoud: "Too loud"
            }
        }
    }
    /// Speech is judged on the loudest frame of the last second or so, so the pauses between
    /// words don't read as "too quiet".
    static func feedback(recentLevels: [Float], recentPeak: Float) -> LevelFeedback {
        guard let loudest = recentLevels.max() else { return .listening }
        if recentPeak >= clipLevel || loudest > -6 { return .tooLoud }
        if loudest < -42 { return recentLevels.count < 10 ? .listening : .tooQuiet }
        return .good
    }

    // MARK: Clipping

    /// A sample at or above this is at the top of the converter's range.
    static let clipLevel: Float = 0.985
    struct Clipping: Equatable, Sendable {
        let samples: Int
        /// Runs of consecutive clipped samples: the flat tops a real clip leaves.
        let runs: Int
        let total: Int
        var fraction: Double { total == 0 ? 0 : Double(samples) / Double(total) }
        var isClipped: Bool { runs >= 3 || fraction > 0.0005 }
    }
    static func clipping(_ samples: [Float], threshold: Float = clipLevel) -> Clipping {
        var clipped = 0, runs = 0, run = 0
        for sample in samples {
            if abs(sample) >= threshold { clipped += 1; run += 1; if run == 2 { runs += 1 } } else { run = 0 }
        }
        return Clipping(samples: clipped, runs: runs, total: samples.count)
    }

    // MARK: Trim

    /// Removes silence before the first word and after the last, keeping a short pad so words
    /// aren't clipped. Speech is anything well above the take's own floor.
    static func trimSilence(_ samples: [Float], padding: Double = 0.12) -> [Float] {
        let levels = frameLevels(samples)
        guard levels.count > 2, let loudest = levels.max() else { return samples }
        let floor = levels.sorted()[levels.count / 10]
        // Never closer than 25 dB under the loudest frame: a take with little silence has its
        // floor inside the speech.
        let threshold = min(max(floor + 12, loudest - 40), loudest - 25)
        guard let first = levels.firstIndex(where: { $0 > threshold }), let last = levels.lastIndex(where: { $0 > threshold }) else { return [] }
        let pad = Int(padding * Double(sampleRate))
        let start = max(0, first * frameLength - pad)
        let end = min(samples.count, (last + 1) * frameLength + pad)
        return start < end ? Array(samples[start..<end]) : []
    }

    // MARK: High-pass

    /// A 4th-order Butterworth high-pass (two biquads) that takes out rumble, hum, and handling
    /// noise below the voice.
    static func highPass(_ samples: [Float], cutoff: Double = 70) -> [Float] {
        guard !samples.isEmpty else { return samples }
        var coefficients: [Double] = []
        for q in [0.541_196_1, 1.306_563] {
            let w0 = 2 * Double.pi * cutoff / Double(sampleRate), alpha = sin(w0) / (2 * q), cosw = cos(w0)
            let a0 = 1 + alpha
            coefficients += [(1 + cosw) / 2 / a0, -(1 + cosw) / a0, (1 + cosw) / 2 / a0, -2 * cosw / a0, (1 - alpha) / a0]
        }
        guard var biquad = vDSP.Biquad(coefficients: coefficients, channelCount: 1, sectionCount: 2, ofType: Float.self) else { return samples }
        return biquad.apply(input: samples)
    }

    // MARK: Loudness

    /// The speech level in dBFS, gated like LUFS: frames under -60 dBFS don't count, then
    /// neither do frames more than 15 dB under the level of what's left (the pauses).
    static func speechLevel(_ samples: [Float]) -> Float {
        let levels = frameLevels(samples).filter { $0 > -60 }
        guard !levels.isEmpty else { return -120 }
        let power: ([Float]) -> Float = { list in 10 * log10(list.reduce(0) { $0 + pow(10, $1 / 10) } / Float(list.count)) }
        let first = power(levels)
        let voiced = levels.filter { $0 > first - 15 }
        return voiced.isEmpty ? first : power(voiced)
    }
    /// The level every reference is brought to: loud enough for the model's encoder, with room
    /// under full scale.
    static let targetLevel: Float = -20
    static let peakCeiling: Float = -1
    /// One gain for the whole take, never pushing a peak past the ceiling. No compression.
    static func normalizeLoudness(_ samples: [Float], target: Float = targetLevel, ceiling: Float = peakCeiling) -> [Float] {
        let level = speechLevel(samples), top = peak(samples)
        guard level > -100, top > 0 else { return samples }
        let gain = min(amplitude(target - level), amplitude(ceiling) / top)
        return vDSP.multiply(gain, samples)
    }

    // MARK: Noise reduction

    enum NoiseReduction: String, Codable, Sendable { case none, soundIsolation, spectralGate }

    /// Reduces steady background noise only when the room needs it: Apple's sound isolation if
    /// it runs offline on this device, otherwise a spectral gate built from the room recording.
    static func reduceNoise(_ samples: [Float], room: RoomNoise, noiseSample: [Float]?) -> ([Float], NoiseReduction) {
        guard room.needsNoiseReduction else { return (samples, .none) }
        if let isolated = AppleSoundIsolation.isolate(samples, sampleRate: sampleRate) { return (isolated, .soundIsolation) }
        return (spectralGate(samples, noise: noiseSample), .spectralGate)
    }

    /// Spectral subtraction with a floor: each frequency bin is turned down where it's close to
    /// the noise profile, by at most `reduction` dB, with gains smoothed over time so it doesn't
    /// warble. The noise profile is the room recording, or the take's quietest frames.
    static func spectralGate(_ samples: [Float], noise: [Float]?, reduction: Float = 14) -> [Float] {
        let size = 512, hop = 128
        guard samples.count > size, let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: size, direction: .forward,
                                                                                 transformType: .complexComplex, ofType: Float.self),
              let inverse = try? vDSP.DiscreteFourierTransform(previous: nil, count: size, direction: .inverse,
                                                                transformType: .complexComplex, ofType: Float.self) else { return samples }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let bins = size / 2 + 1
        let zeros = [Float](repeating: 0, count: size)
        func spectrum(_ frame: ArraySlice<Float>) -> (re: [Float], im: [Float]) {
            let windowed = vDSP.multiply(Array(frame), window)
            let out = dft.transform(real: windowed, imaginary: zeros)
            return (out.real, out.imaginary)
        }
        func magnitudes(_ re: [Float], _ im: [Float]) -> [Float] { (0..<bins).map { (re[$0] * re[$0] + im[$0] * im[$0]).squareRoot() } }
        let padded = [Float](repeating: 0, count: size) + samples + [Float](repeating: 0, count: size)
        let starts = Array(stride(from: 0, through: padded.count - size, by: hop))
        let frames = starts.map { spectrum(padded[$0..<($0 + size)]) }
        let mags = frames.map { magnitudes($0.re, $0.im) }

        // The noise profile: the mean spectrum of the room recording, or of this take's quietest tenth.
        var profile = [Float](repeating: 0, count: bins)
        let noiseFrames: [[Float]]
        if let noise, noise.count > size {
            noiseFrames = stride(from: 0, through: noise.count - size, by: hop).map { let s = spectrum(noise[$0..<($0 + size)]); return magnitudes(s.re, s.im) }
        } else {
            let energy = mags.map { $0.reduce(0, +) }
            let quiet = energy.indices.sorted { energy[$0] < energy[$1] }.prefix(max(1, mags.count / 10))
            noiseFrames = quiet.map { mags[$0] }
        }
        for frame in noiseFrames { profile = vDSP.add(profile, frame) }
        profile = vDSP.multiply(1 / Float(max(1, noiseFrames.count)), profile)

        let floorGain = amplitude(-reduction)
        var previous = [Float](repeating: 1, count: bins)
        var output = [Float](repeating: 0, count: padded.count)
        var weight = [Float](repeating: 0, count: padded.count)
        for (index, start) in starts.enumerated() {
            let mag = mags[index]
            var gains = [Float](repeating: 1, count: bins)
            for bin in 0..<bins {
                let over = mag[bin] - 1.8 * profile[bin]
                gains[bin] = mag[bin] > 0 ? min(1, max(floorGain, over / mag[bin])) : floorGain
            }
            // Smooth across neighbouring bins, then in time: fast to open, slower to close.
            var smoothed = gains
            for bin in 1..<(bins - 1) { smoothed[bin] = (gains[bin - 1] + 2 * gains[bin] + gains[bin + 1]) / 4 }
            for bin in 0..<bins { smoothed[bin] = max(smoothed[bin], previous[bin] * 0.6) }
            previous = smoothed
            var re = frames[index].re, im = frames[index].im
            for bin in 0..<bins {
                re[bin] *= smoothed[bin]; im[bin] *= smoothed[bin]
                if bin > 0 && bin < size / 2 { re[size - bin] *= smoothed[bin]; im[size - bin] *= smoothed[bin] }
            }
            let back = inverse.transform(real: re, imaginary: im)
            let frame = vDSP.multiply(vDSP.multiply(1 / Float(size), back.real), window)
            for offset in 0..<size {
                output[start + offset] += frame[offset]
                weight[start + offset] += window[offset] * window[offset]
            }
        }
        return (0..<samples.count).map { index in
            let w = weight[index + size]
            return w > 1e-6 ? output[index + size] / w : 0
        }
    }

    // MARK: Takes

    /// What a take measured, kept with the voice so it can be explained later.
    struct TakeReport: Equatable, Codable, Sendable {
        var seconds: Double
        var speechDecibels: Float
        var peak: Float
        var clipped: Bool
        /// Speech level over the take's own floor.
        var signalToNoise: Float
    }
    enum TakeProblem: Equatable, Sendable {
        case clipped, tooQuiet, tooShort
        var message: String {
            switch self {
            case .clipped: "That take clipped. Hold the phone a little farther away and try again."
            case .tooQuiet: "That take was too quiet. Speak up a little and try again."
            case .tooShort: "That take was too short. Read the whole line."
            }
        }
    }
    static func report(_ samples: [Float]) -> TakeReport {
        let levels = frameLevels(samples).sorted()
        let floor = levels.isEmpty ? -120 : levels[levels.count / 10]
        let speech = speechLevel(samples)
        return TakeReport(seconds: Double(samples.count) / Double(sampleRate), speechDecibels: speech, peak: peak(samples),
                          clipped: clipping(samples).isClipped, signalToNoise: speech - floor)
    }
    /// Why a raw take can't be used, or nil when it's fine.
    static func problem(with raw: TakeReport, minimumSeconds: Double = 3) -> TakeProblem? {
        if raw.clipped { return .clipped }
        if raw.speechDecibels < -45 { return .tooQuiet }
        if raw.seconds < minimumSeconds { return .tooShort }
        return nil
    }

    /// A take after clean-up, ready to join the reference.
    struct ProcessedTake: Equatable, Sendable {
        var samples: [Float]
        var text: String
        var report: TakeReport
        var noiseReduction: NoiseReduction
        /// Higher is better: clean, clear takes go first.
        var score: Float { report.signalToNoise + (report.clipped ? -100 : 0) - abs(report.speechDecibels - targetLevel) * 0.1 }
    }

    /// The clean-up for one take: high-pass, noise reduction when the room needs it, trim, and
    /// loudness. `noiseSample` is the quiet-check recording.
    static func process(_ raw: [Float], text: String, room: RoomNoise, noiseSample: [Float]?) -> ProcessedTake {
        let filtered = highPass(raw)
        let (cleaned, reduction) = reduceNoise(filtered, room: room, noiseSample: noiseSample.map { highPass($0) })
        let trimmed = trimSilence(cleaned)
        let leveled = normalizeLoudness(trimmed)
        var report = report(leveled)
        report.clipped = clipping(raw).isClipped
        return ProcessedTake(samples: leveled, text: text, report: report, noiseReduction: reduction)
    }

    // MARK: The reference

    /// How much reference audio a voice model uses.
    struct ReferenceLength: Equatable, Sendable {
        let target: Double
        let maximum: Double
        /// Pocket TTS keeps the whole prompt in its context. Measured (September 26, 2026, the
        /// comparison in `OwnVoiceModelComparisonTests`): about 18 s of clean takes matched the
        /// speaker best; 12 s was close and 24 s was worse, and faster.
        static let pocketTTS = ReferenceLength(target: 18, maximum: 20)
    }
    /// One piece of the reference: which passage, and where it sits.
    struct Segment: Equatable, Codable, Sendable {
        var text: String
        var start: Double
        var seconds: Double
    }
    struct Reference: Equatable, Sendable {
        var samples: [Float]
        var segments: [Segment]
        var seconds: Double { Double(samples.count) / Double(sampleRate) }
        var text: String { segments.map(\.text).joined(separator: " ") }
    }
    /// The best takes, best first (models that use less read from the start), joined with short
    /// pauses, up to the target length. A take that would run past the maximum is cut at its
    /// quietest moment near the limit so no word is split.
    static func reference(from takes: [ProcessedTake], length: ReferenceLength = .pocketTTS, gap: Double = 0.3) -> Reference {
        let usable = takes.filter { !$0.report.clipped && !$0.samples.isEmpty }.sorted { $0.score > $1.score }
        let pause = [Float](repeating: 0, count: Int(gap * Double(sampleRate)))
        var samples: [Float] = [], segments: [Segment] = []
        let maximum = Int(length.maximum * Double(sampleRate)), target = Int(length.target * Double(sampleRate))
        for take in usable {
            guard samples.count < target else { break }
            let gap = samples.isEmpty ? 0 : pause.count
            // Less than a second of room left isn't worth a piece of a take.
            guard samples.count + gap + sampleRate <= maximum else { break }
            samples += samples.isEmpty ? [] : pause
            let start = Double(samples.count) / Double(sampleRate)
            var piece = take.samples
            if samples.count + piece.count > maximum {
                piece = Array(piece.prefix(quietCut(piece, before: maximum - samples.count)))
                if piece.count < sampleRate { samples.removeLast(gap); break }
            }
            samples += piece
            segments.append(Segment(text: take.text, start: start, seconds: Double(piece.count) / Double(sampleRate)))
        }
        return Reference(samples: samples, segments: segments)
    }
    /// The quietest 20 ms frame in the last 1.5 s before `limit`, as a sample index to cut at.
    static func quietCut(_ samples: [Float], before limit: Int) -> Int {
        let end = max(0, min(limit, samples.count))
        let window = Int(1.5 * Double(sampleRate))
        let start = max(0, end - window)
        guard end - start > frameLength else { return end }
        let levels = frameLevels(Array(samples[start..<end]))
        guard let quietest = levels.indices.min(by: { levels[$0] < levels[$1] }) else { return end }
        return start + quietest * frameLength + frameLength / 2
    }
}

/// Apple's sound isolation audio unit (the Voice Isolation mic mode's model), run offline over a
/// finished take. Nil when it isn't available here or doesn't render, so the caller falls back to
/// the spectral gate. Runs at 48 kHz, the rate it's built for.
enum AppleSoundIsolation {
    static let description = AudioComponentDescription(componentType: kAudioUnitType_Effect,
                                                       componentSubType: kAudioUnitSubType_AUSoundIsolation,
                                                       componentManufacturer: kAudioUnitManufacturer_Apple,
                                                       componentFlags: 0, componentFlagsMask: 0)
    static var isAvailable: Bool {
        var wanted = description
        return AudioComponentFindNext(nil, &wanted) != nil
    }

    static func isolate(_ samples: [Float], sampleRate: Int) -> [Float]? {
        guard isAvailable, !samples.isEmpty,
              let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1),
              let upsampled = resample(samples, from: Double(sampleRate), to: 48_000) else { return nil }
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let effect = AVAudioUnitEffect(audioComponentDescription: description)
        do {
            // Check the formats first: connecting an unsupported format raises instead of throwing.
            try effect.auAudioUnit.inputBusses[0].setFormat(format)
            try effect.auAudioUnit.outputBusses[0].setFormat(format)
            try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4096)
            engine.attach(player); engine.attach(effect)
            engine.connect(player, to: effect, format: format)
            engine.connect(effect, to: engine.mainMixerNode, format: format)
            AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_WetDryMixPercent), kAudioUnitScope_Global, 0, 100, 0)
            AudioUnitSetParameter(effect.audioUnit, AudioUnitParameterID(kAUSoundIsolationParam_SoundToIsolate), kAudioUnitScope_Global, 0,
                                  AudioUnitParameterValue(kAUSoundIsolationSoundType_HighQualityVoice), 0)
            try engine.start()
        } catch { return nil }
        defer { player.stop(); engine.stop() }
        let latency = Int((effect.auAudioUnit.latency * 48_000).rounded())
        let input = upsampled + [Float](repeating: 0, count: latency + 4096)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(input.count)),
              let render = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096) else { return nil }
        buffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { source in buffer.floatChannelData?[0].update(from: source.baseAddress!, count: input.count) }
        player.scheduleBuffer(buffer)
        player.play()
        var output: [Float] = []
        output.reserveCapacity(input.count)
        while output.count < input.count {
            let frames = AVAudioFrameCount(min(4096, input.count - output.count))
            guard (try? engine.renderOffline(frames, to: render)) == .success, let data = render.floatChannelData else { return nil }
            output += UnsafeBufferPointer(start: data[0], count: Int(render.frameLength))
        }
        let aligned = Array(output.dropFirst(latency).prefix(upsampled.count))
        guard aligned.count == upsampled.count, aligned.allSatisfy(\.isFinite),
              let back = resample(aligned, from: 48_000, to: Double(sampleRate)) else { return nil }
        // A unit that silenced the voice is worse than none.
        guard OwnVoiceAudio.speechLevel(back) > OwnVoiceAudio.speechLevel(samples) - 20 else { return nil }
        return back
    }

    /// High-quality sample-rate conversion with AVAudioConverter.
    static func resample(_ samples: [Float], from source: Double, to target: Double) -> [Float]? {
        if source == target { return samples }
        guard let inFormat = AVAudioFormat(standardFormatWithSampleRate: source, channels: 1),
              let outFormat = AVAudioFormat(standardFormatWithSampleRate: target, channels: 1),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let input = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData?[0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * target / source) + 1024
        guard let output = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, outStatus in
            if fed { outStatus.pointee = .endOfStream; return nil }
            fed = true; outStatus.pointee = .haveData; return input
        }
        guard status != .error, error == nil, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}
