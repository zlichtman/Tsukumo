import Accelerate
import AVFoundation
import Darwin
import HuggingFace
import MLX
import MLXAudioCore
import MLXAudioTTS
import MLXNN
import Speech
import XCTest
@testable import KemoSabeMac

/// The offline comparison behind the choice of the "Your voice" model. It clones the same
/// processed references with every candidate and writes WAVs plus timings, memory, and speaker
/// similarity. The reference speakers are Kokoro's synthetic voices, never a person's recording.
///
/// It downloads several gigabytes the first time, so it runs only when asked:
/// `TEST_RUNNER_KEMO_VOICE_COMPARISON=1 xcodebuild test … -only-testing:KemoSabeMacTests/OwnVoiceModelComparisonTests`.
/// Models and results go to `TEST_RUNNER_KEMO_VOICE_COMPARISON_DIR`, or
/// ~/Library/Caches/KemoSabeVoiceComparison; nothing is written into the repository.
final class OwnVoiceModelComparisonTests: XCTestCase {
    private var root: URL {
        if let path = ProcessInfo.processInfo.environment["KEMO_VOICE_COMPARISON_DIR"], !path.isEmpty { return URL(fileURLWithPath: path, isDirectory: true) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/KemoSabeVoiceComparison", isDirectory: true)
    }
    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["KEMO_VOICE_COMPARISON"] == "1",
                          "Set TEST_RUNNER_KEMO_VOICE_COMPARISON=1 to download the candidates and compare them on this Mac.")
        try XCTSkipUnless(NeuralSpeechRuntime.isSupported, "Needs a Metal GPU")
    }

    // MARK: Candidates

    struct Candidate {
        let name: String
        let license: String
        let pack: VoiceModelPack
        let length: OwnVoiceAudio.ReferenceLength
        let usesTranscript: Bool
        let load: (URL) async throws -> SpeechGenerationModel
    }

    static let chatterboxTurbo = VoiceModelPack(id: "cmp-chatterbox-turbo-4bit", title: "Chatterbox Turbo", version: 1, sources: [
        .init(repository: "mlx-community/chatterbox-turbo-4bit", revision: "c63817725071d7b5269c7b558772d6e8cbf59cec",
              license: "MIT (ResembleAI/chatterbox-turbo)", folder: "model", files: [
            .init(path: "added_tokens.json", size: 418, sha256: "72e4ab6acb0d9309ac3df4b526ae5fd80a2da5bc5ab7bb02d85096a374f69193"),
            .init(path: "conds.safetensors", size: 164884, sha256: "df9ad2c54848027d94cf01f9fc0ed22bc5d3165df6e6a85c903c1124b8a78a4a"),
            .init(path: "config.json", size: 2565, sha256: "8b99a849d4a1bae2576b70f0a4c67bd48faf3f4164b8774d6f12f4cdd2533b7e"),
            .init(path: "merges.txt", size: 456318, sha256: "1ce1664773c50f3e0cc8842619a93edc4624525b728b188a9e0be33b7726adc5"),
            .init(path: "model.safetensors", size: 414992166, sha256: "59603c7f62272b72d4b1d7870e0bf546b5f88561a367daf6fd6282da997a54a4"),
            .init(path: "model.safetensors.index.json", size: 252012, sha256: "e5ef5ca8e996c3ce3fbca268784942d10150628d20bf8ca8608bac02c87cf3ea"),
            .init(path: "special_tokens_map.json", size: 470, sha256: "92ba8063bf40aa163eadebbfe0de07c2aebe44cf0d4a9e8726580b0781fd2640"),
            .init(path: "tokenizer_config.json", size: 3878, sha256: "bca16a2ac1ddbd78b8d6228f0031884cc74b6ea54b967d6f6d2ebae9ccde23e6"),
            .init(path: "vocab.json", size: 999186, sha256: "f6bd25a65e4e63ca31360e9fb11c7e4f9a391a78385d640acd814092dd6eee4f"),
        ]),
        .init(repository: "mlx-community/S3TokenizerV2", revision: "e0c9886f0e1c35ae85b1f27277416fb19fc72bec",
              license: "Apache-2.0 (FunAudioLLM/CosyVoice)", folder: "s3tokenizer", files: [
            .init(path: "config.json", size: 126, sha256: "8591fcc0eaae8c2bbfc69cf9d439933ecdf2d58cb9be63d00ce88736c4f2aa9d"),
            .init(path: "model.safetensors", size: 494868984, sha256: "928726bc1f206a613d36b8f49e297eae9c5593a21bf9b92ddfe2c23f85eb92cc"),
        ]),
    ])
    static let qwen3Base = VoiceModelPack(id: "cmp-qwen3-tts-0.6b-base-4bit", title: "Qwen3-TTS 0.6B Base", version: 1, sources: [
        .init(repository: "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-4bit", revision: "0d6bb6fe33f92d47a507e23b9148940e8366ab5b",
              license: "Apache-2.0 (Qwen/Qwen3-TTS-12Hz-0.6B-Base)", folder: "model", files: [
            .init(path: "config.json", size: 5522, sha256: "ba59b8d2d47746e844f6a96e2232a969d8d89dcc34450fbad94d912bb9ee2e27"),
            .init(path: "generation_config.json", size: 245, sha256: "f1b90b4513f3b34c62851049e2492d7b4c5940daf1276f89c82b8ef04127f3aa"),
            .init(path: "merges.txt", size: 1671839, sha256: "599bab54075088774b1733fde865d5bd747cbcc7a547c5bc12610e874e26f5e3"),
            .init(path: "model.safetensors", size: 1024490700, sha256: "07dcb37b323614af64624af687876edd5c9a8b442da2a7b549d62f9ba2770ec1"),
            .init(path: "model.safetensors.index.json", size: 77731, sha256: "86f65f69204f3fb9dc5ec22ed94da4865594c901b45d2508c60a5931d12787d4"),
            .init(path: "preprocessor_config.json", size: 127, sha256: "efdde1022ea9d76928bf7a9cd53139138f5ba2e466e837f08f6105ab1af1c119"),
            .init(path: "speech_tokenizer/config.json", size: 2336, sha256: "ee65bb901c876664ab8707c487157aa1a6ee57c65969b28fb5ec9dc211e68167"),
            .init(path: "speech_tokenizer/configuration.json", size: 76, sha256: "6bc26d64eb5024b4d1dab5a52371958b429256d6c9d59787f1f5294a54e0cebd"),
            .init(path: "speech_tokenizer/model.safetensors", size: 682293092, sha256: "836b7b357f5ea43e889936a3709af68dfe3751881acefe4ecf0dbd30ba571258"),
            .init(path: "speech_tokenizer/preprocessor_config.json", size: 234, sha256: "fcb3805e597e786d4067706e602f6688524640f8d3396790e2e09b5942fcbdfb"),
            .init(path: "tokenizer_config.json", size: 7344, sha256: "dc3c31c3bdaedd5016382bb3cbe07323026775ad51f5a4fb564505992ae4a670"),
            .init(path: "vocab.json", size: 2776833, sha256: "ca10d7e9fb3ed18575dd1e277a2579c16d108e32f27439684afa0e10b1440910"),
        ]),
    ])
    static let mossNano = VoiceModelPack(id: "cmp-moss-tts-nano-100m", title: "MOSS-TTS-Nano", version: 1, sources: [
        .init(repository: "mlx-community/MOSS-TTS-Nano-100M", revision: "229a9c51bb0ffff6fd0dbe53b5bf0c441e438a79",
              license: "Apache-2.0 (OpenMOSS-Team/MOSS-TTS-Nano-100M)", folder: "model", files: [
            .init(path: "config.json", size: 5238, sha256: "f947eb159bd7a2dfd3b8bad73cc0d2e33de6064b2610f6591d8be1aab540e869"),
            .init(path: "model.safetensors", size: 284973717, sha256: "0f095f69dc16b42ddfe4d56d925b454b0acd77df63fec274edceaade69154817"),
            .init(path: "special_tokens_map.json", size: 552, sha256: "358c249e2fb29060c6b73157d428853b0c48710deffc8ee670ab1013880946c9"),
            .init(path: "tokenizer.model", size: 470897, sha256: "c353ee1479b536bf414c1b247f5542b6607fb8ae91320e5af1781fee200fddff"),
            .init(path: "tokenizer_config.json", size: 1140, sha256: "2e00db82fd2ba8020e7263a25f31bb8ec6c5cefbfe0b5e0bbd4723ae874d1be1"),
        ]),
        .init(repository: "mlx-community/MOSS-Audio-Tokenizer-Nano", revision: "edccdfd96d5c21f1c078338a98d738b9a6bf6917",
              license: "Apache-2.0 (OpenMOSS-Team/MOSS-Audio-Tokenizer-Nano)", folder: "model/audio_tokenizer", files: [
            .init(path: "config.json", size: 7385, sha256: "b38892f8ba00efc18af2ad9eca999c7603f871548c2e7f99258cb1cefc70ee06"),
            .init(path: "model.safetensors", size: 43983139, sha256: "0f9ac6252413c515c92620ac3a99096cad237a9606735860af3a13eb450cbfdf"),
        ]),
    ])

    private func candidates() -> [Candidate] {
        let only = Set((ProcessInfo.processInfo.environment["KEMO_VOICE_COMPARISON_MODELS"] ?? "").split(separator: ",").map(String.init))
        let all: [Candidate] = [
            Candidate(name: "pocket-tts", license: "CC-BY-4.0", pack: .pocketTTS, length: .pocketTTS, usesTranscript: false) { folder in
                try await PocketTTSModel.fromModelDirectory(folder.appendingPathComponent("model", isDirectory: true))
            },
            Candidate(name: "chatterbox-turbo-4bit", license: "MIT (+ Apache-2.0 S3Tokenizer)", pack: Self.chatterboxTurbo,
                      length: .init(target: 15, maximum: 15), usesTranscript: false) { folder in
                // Chatterbox fetches S3TokenizerV2 through the Hub cache: point that at the pinned copy.
                try Self.mirrorIntoHubCache(folder.appendingPathComponent("s3tokenizer", isDirectory: true), repository: "mlx-community/S3TokenizerV2")
                let model = try await ChatterboxModel.fromModelDirectory(folder.appendingPathComponent("model", isDirectory: true), hfToken: nil)
                XCTAssertNotNil(model.s3Tokenizer, "the pinned S3 tokenizer loaded from the mirror")
                return model
            },
            Candidate(name: "qwen3-tts-0.6b-base-4bit", license: "Apache-2.0", pack: Self.qwen3Base,
                      length: .init(target: 12, maximum: 15), usesTranscript: true) { folder in
                try await Qwen3TTSModel.fromModelDirectory(folder.appendingPathComponent("model", isDirectory: true))
            },
            Candidate(name: "moss-tts-nano-100m", license: "Apache-2.0", pack: Self.mossNano,
                      length: .init(target: 15, maximum: 20), usesTranscript: false) { folder in
                try await MossTTSNanoModel.fromModelDirectory(folder.appendingPathComponent("model", isDirectory: true))
            },
        ]
        return only.isEmpty ? all : all.filter { only.contains($0.name) }
    }

    static func mirrorIntoHubCache(_ source: URL, repository: String) throws {
        _ = NeuralSpeechRuntime.configureCache
        let target = HubCache.default.cacheDirectory.appendingPathComponent("mlx-audio", isDirectory: true)
            .appendingPathComponent(repository.replacingOccurrences(of: "/", with: "_"), isDirectory: true)
        let files = FileManager.default
        try files.createDirectory(at: target, withIntermediateDirectories: true)
        for name in try files.contentsOfDirectory(atPath: source.path) {
            let to = target.appendingPathComponent(name)
            if files.fileExists(atPath: to.path) { continue }
            try files.linkItem(at: source.appendingPathComponent(name), to: to)
        }
    }

    /// Qwen3-TTS caches a reference's encoding by the array's object identity, so every array
    /// handed to it stays alive for the run: a freed address reused by the next speaker's audio
    /// would otherwise return the previous speaker's cached voice.
    nonisolated(unsafe) static var keepAlive: [MLXArray] = []

    // MARK: The speakers

    /// Four synthetic speakers (two higher, two lower) stand in for people.
    static let speakers = ["af_heart", "af_bella", "am_michael", "am_fenrir"]
    static let testLines = [
        "Here's what I found, and one thing we could do next.",
        "Your meeting moved to three o'clock, so you have time for lunch first. Want me to remind you?",
    ]

    @MainActor private func installed(_ pack: VoiceModelPack) async throws -> VoiceModelStore {
        let store = VoiceModelStore(pack: pack, root: root.appendingPathComponent("models", isDirectory: true))
        store.wifiOnly = false
        if !store.isInstalled { store.download(); await store.waitUntilDone() }
        XCTAssertEqual(store.state, .installed, "\(pack.id): \(store.state)")
        return store
    }

    /// Makes a realistic raw take from clean speech: a pause either side, a low hum, steady room
    /// noise, and a lower level, as a phone at arm's length in an ordinary room would record.
    static func roughen(_ clean: [Float], noise: [Float], gainDecibels: Float = -8) -> [Float] {
        let rate = Float(OwnVoiceAudio.sampleRate)
        let pad = [Float](repeating: 0, count: Int(0.7 * rate))
        let body = pad + vDSP.multiply(OwnVoiceAudio.amplitude(gainDecibels), clean) + pad
        return body.indices.map { index in
            body[index] + noise[index % noise.count] + 0.004 * sin(2 * .pi * 50 * Float(index) / rate)
        }
    }
    /// Pink-ish room noise at about -52 dBFS, seeded so every run is the same.
    static func roomNoise(seconds: Double, seed: UInt64 = 7) -> [Float] {
        var state = seed, last: Float = 0
        return (0..<Int(seconds * Double(OwnVoiceAudio.sampleRate))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let white = Float(Int64(bitPattern: state >> 11) % 2000) / 1000 - 1
            last = 0.97 * last + 0.03 * white
            return last * 0.05
        }
    }

    // MARK: The comparison

    @MainActor func testCompareCloningModels() async throws {
        let out = root.appendingPathComponent("results", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let kokoroStore = try await installed(.kokoro)
        let kokoro = KokoroSpeechEngine(store: kokoroStore)
        let noise = Self.roomNoise(seconds: 5)
        let room = OwnVoiceAudio.roomNoise(noise)
        print("CMP room noise: \(String(format: "%.1f", room.decibels)) dBFS (noisy: \(room.isNoisy))")

        // Raw takes (four passages per speaker), a hold-out sentence each for judging, and the
        // single raw take the old flow would have used.
        var takes: [String: [(text: String, raw: [Float])]] = [:]
        var holdout: [String: [Float]] = [:]
        let passages = Array(OwnVoiceEnrollment.passages.prefix(4))
        for speaker in Self.speakers {
            var list: [(String, [Float])] = []
            for passage in passages {
                list.append((passage, Self.roughen(try await kokoro.synthesize(passage, voice: speaker).pcmSamples, noise: noise)))
            }
            takes[speaker] = list
            holdout[speaker] = try await kokoro.synthesize(OwnVoiceEnrollment.passages[6] + " " + OwnVoiceEnrollment.passages[7], voice: speaker).pcmSamples
            try SpeechAudio.wav(list[0].1, sampleRate: OwnVoiceAudio.sampleRate).write(to: out.appendingPathComponent("raw-\(speaker).wav"))
        }
        let started = Date()
        let processed = takes.mapValues { list in list.map { OwnVoiceAudio.process($0.raw, text: $0.text, room: room, noiseSample: noise) } }
        print("CMP processing: \(String(format: "%.2f", Date().timeIntervalSince(started))) s for \(Self.speakers.count * passages.count) takes; noise reduction: \(processed.values.first?.first?.noiseReduction.rawValue ?? "?")")

        let qwenStore = try await installed(Self.qwen3Base), chatterboxStore = try await installed(Self.chatterboxTurbo)
        var judges = try await Judges(qwenFolder: qwenStore.folder, chatterboxFolder: chatterboxStore.folder)
        var rows: [Row] = []
        for candidate in candidates() {
            let store = try await installed(candidate.pack)
            Memory.clearCache()
            Memory.peakMemory = 0
            let activeBefore = Memory.activeMemory
            let footprintBefore = Self.footprint()
            let loadStart = Date()
            let model = try await candidate.load(store.folder)
            let loadSeconds = Date().timeIntervalSince(loadStart)
            var variants: [(label: String, reference: (String) -> OwnVoiceAudio.Reference)] = [
                ("processed", { speaker in OwnVoiceAudio.reference(from: processed[speaker] ?? [], length: candidate.length) }),
            ]
            if candidate.pack == .pocketTTS {
                // The old flow: one raw ten-second take, as recorded.
                variants.append(("raw-single-take", { speaker in
                    let first = takes[speaker]?.first
                    return .init(samples: first?.raw ?? [], segments: [.init(text: first?.text ?? "", start: 0, seconds: 0)])
                }))
                variants.append(("processed-12s", { speaker in OwnVoiceAudio.reference(from: processed[speaker] ?? [], length: .init(target: 12, maximum: 12)) }))
                variants.append(("processed-18s", { speaker in OwnVoiceAudio.reference(from: processed[speaker] ?? [], length: .init(target: 18, maximum: 18)) }))
                variants.append(("processed-18s-gap0.7", { speaker in OwnVoiceAudio.reference(from: processed[speaker] ?? [], length: .init(target: 18, maximum: 20), gap: 0.7) }))
                // The raw takes joined without clean-up, to separate the gain from more speech and from processing.
                variants.append(("raw-joined", { speaker in
                    let raw = (takes[speaker] ?? []).map { OwnVoiceAudio.ProcessedTake(samples: $0.raw, text: $0.text,
                        report: OwnVoiceAudio.report($0.raw), noiseReduction: .none) }
                    return OwnVoiceAudio.reference(from: raw, length: .pocketTTS)
                }))
            }
            // Generate everything first, so the peak memory is this model's alone, then judge.
            var clips: [(variant: String, speaker: String, index: Int, clip: [Float], line: String)] = []
            var timing: [String: (audio: Double, compute: Double, first: [Double])] = [:]
            for variant in variants {
                for speaker in Self.speakers {
                    let reference = variant.reference(speaker)
                    let refArray = MLXArray(reference.samples)
                    Self.keepAlive.append(refArray)
                    for (index, line) in Self.testLines.enumerated() {
                        let start = Date()
                        let audio = try await model.generate(text: line, voice: nil, refAudio: refArray,
                                                             refText: candidate.usesTranscript ? reference.text : nil,
                                                             language: candidate.usesTranscript ? "English" : nil,
                                                             generationParameters: model.defaultGenerationParameters)
                        let samples = audio.asArray(Float.self)
                        let seconds = Date().timeIntervalSince(start)
                        let clip = CloneMeasures.resample(samples, from: model.sampleRate, to: OwnVoiceAudio.sampleRate)
                        let duration = Double(clip.count) / Double(OwnVoiceAudio.sampleRate)
                        var entry = timing[variant.label] ?? (0, 0, [])
                        entry.audio += duration; entry.compute += seconds
                        if index == 0 { entry.first.append(seconds / max(duration, 0.01)) }
                        timing[variant.label] = entry
                        clips.append((variant.label, speaker, index, clip, line))
                        try SpeechAudio.wav(clip, sampleRate: OwnVoiceAudio.sampleRate)
                            .write(to: out.appendingPathComponent("\(candidate.name)-\(variant.label)-\(speaker)-\(index).wav"))
                    }
                }
            }
            let peak = Double(Memory.peakMemory - activeBefore) / 1e6
            let footprint = Double(Self.footprint() - footprintBefore) / 1e6
            Memory.clearCache()
            for variant in variants {
                var row = Row(model: candidate.name, variant: variant.label, license: candidate.license,
                              downloadMB: Double(candidate.pack.totalBytes) / 1e6, loadSeconds: loadSeconds)
                let entry = timing[variant.label] ?? (0, 0, [])
                row.audioSeconds = entry.audio; row.computeSeconds = entry.compute; row.firstRTF = entry.first
                row.peakMLXMB = peak; row.footprintMB = footprint
                for item in clips where item.variant == variant.label {
                    let scores = try judges.score(item.clip, speaker: item.speaker, holdout: holdout)
                    let duration = Double(item.clip.count) / Double(OwnVoiceAudio.sampleRate)
                    row.add(scores, wordsPerSecond: Double(item.line.split(separator: " ").count) / max(duration, 0.01))
                }
                rows.append(row)
                print(row.line)
            }
            Memory.clearCache()
        }
        let json = try JSONEncoder.pretty.encode(rows)
        try json.write(to: out.appendingPathComponent("comparison.json"))
        print("CMP results → \(out.path)")
        print(Row.header)
        for row in rows { print(row.line) }
    }

    /// Intelligibility of the clips the comparison wrote: each is transcribed with on-device
    /// recognition and scored as the share of the line's words heard in order. Runs after
    /// `testCompareCloningModels`, and only when speech recognition is already allowed for this
    /// app (it never asks).
    @MainActor func testIntelligibilityOfTheClones() async throws {
        try XCTSkipUnless(SFSpeechRecognizer.authorizationStatus() == .authorized, "Speech recognition isn't allowed for Tsukumo here")
        let out = root.appendingPathComponent("results", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(atPath: out.path).filter { $0.hasSuffix(".wav") && !$0.hasPrefix("raw-") }.sorted()
        try XCTSkipIf(files.isEmpty, "Run testCompareCloningModels first")
        var scores: [String: [Double]] = [:]
        for name in files {
            guard let index = Int(name.dropLast(4).split(separator: "-").last ?? ""), Self.testLines.indices.contains(index) else { continue }
            let line = Self.testLines[index]
            let (_, audio) = try loadAudioArray(from: out.appendingPathComponent(name), sampleRate: OwnVoiceAudio.sampleRate)
            let heard = try await OwnVoiceTranscriber().transcript(of: audio.asArray(Float.self), expected: line)
            let want = OwnVoiceEnrollment.words(line), got = OwnVoiceEnrollment.words(heard)
            let matched = (0...want.count).last { OwnVoiceEnrollment.matches(heard: got.joined(separator: " "), expected: want.joined(separator: " "), threshold: Double($0) / Double(want.count)) } ?? 0
            let key = String(name.split(separator: "-").dropLast(2).joined(separator: "-"))
            scores[key, default: []].append(Double(matched) / Double(want.count))
        }
        for (key, list) in scores.sorted(by: { $0.key < $1.key }) {
            print(String(format: "CMP-WORDS %@ | %.0f%% of words heard in order (%d clips)", key, 100 * list.reduce(0, +) / Double(list.count), list.count))
        }
    }

    // MARK: Judging

    /// Scores a clone against a different sentence from the same speaker (never the prompt
    /// itself, so copying the reference doesn't score). Two neural speaker encoders from other
    /// models (Qwen3-TTS's ECAPA-TDNN and Chatterbox's voice encoder) plus pitch and MFCCs.
    /// An encoder judging its own model is biased, so each row reports both.
    struct Features { var ecapa: [Float]; var ve: [Float]; var pitch: Float; var mfcc: [Float] }
    struct Judges {
        let qwen: Qwen3TTSModel
        let voiceEncoder: VoiceEncoder
        var cache: [String: Features] = [:]

        init(qwenFolder: URL, chatterboxFolder: URL) async throws {
            qwen = try await Qwen3TTSModel.fromModelDirectory(qwenFolder.appendingPathComponent("model", isDirectory: true))
            let arrays = try MLX.loadArrays(url: chatterboxFolder.appendingPathComponent("model/model.safetensors"))
            var weights: [String: MLXArray] = [:]
            for (key, value) in arrays where key.hasPrefix("ve.") { weights[String(key.dropFirst(3))] = value }
            let encoder = VoiceEncoder()
            let sanitized = encoder.sanitize(weights: weights)
            quantize(model: encoder, groupSize: 64, bits: 4, mode: .affine, filter: { path, _ in sanitized["\(path).scales"] != nil })
            try encoder.update(parameters: ModuleParameters.unflattened(sanitized), verify: [])
            eval(encoder)
            voiceEncoder = encoder
        }

        func features(_ samples: [Float]) throws -> Features {
            let audio = MLXArray(samples)
            OwnVoiceModelComparisonTests.keepAlive.append(audio)
            let conditioning = try qwen.prepareReferenceConditioning(refAudio: audio, refText: "Hello.", language: "English")
            let ecapa = conditioning.speakerEmbedding?.asArray(Float.self) ?? []
            let wav16 = CloneMeasures.resample(samples, from: OwnVoiceAudio.sampleRate, to: 16_000)
            let mels = voiceEncoderMelSpectrogram(MLXArray(wav16), isTurbo: true)
            let embedding = voiceEncoder.inference(mels: mels.transposed().expandedDimensions(axis: 0), melLens: [mels.dim(1)])
            return Features(ecapa: ecapa, ve: embedding.asArray(Float.self), pitch: CloneMeasures.medianPitch(samples), mfcc: CloneMeasures.meanMFCC(samples))
        }
        mutating func score(_ clip: [Float], speaker: String, holdout: [String: [Float]]) throws -> Scores {
            for (name, audio) in holdout where cache[name] == nil { cache[name] = try features(audio) }
            let clone = try features(clip)
            guard let own = cache[speaker] else { throw SpeechEngineError.notEnrolled }
            // Speaker embeddings share a large common component; measure around the speakers' mean.
            func centered(_ key: KeyPath<Features, [Float]>) -> (clone: [Float], speakers: [String: [Float]]) {
                let all = cache.values.map { $0[keyPath: key] }
                guard let first = all.first else { return (clone[keyPath: key], [:]) }
                let mean = all.dropFirst().reduce(first) { vDSP.add($0, $1) }.map { $0 / Float(all.count) }
                return (vDSP.subtract(clone[keyPath: key], mean), cache.mapValues { vDSP.subtract($0[keyPath: key], mean) })
            }
            let ecapa = centered(\.ecapa), ve = centered(\.ve)
            func same(_ c: (clone: [Float], speakers: [String: [Float]])) -> Float { CloneMeasures.cosine(c.clone, c.speakers[speaker] ?? []) }
            func other(_ c: (clone: [Float], speakers: [String: [Float]])) -> Float {
                c.speakers.filter { $0.key != speaker }.map { CloneMeasures.cosine(c.clone, $0.value) }.max() ?? 0
            }
            let both = { (name: String) in CloneMeasures.cosine(ecapa.clone, ecapa.speakers[name] ?? []) + CloneMeasures.cosine(ve.clone, ve.speakers[name] ?? []) }
            let identified = cache.keys.max { both($0) < both($1) } == speaker
            let pitchError = abs(1200 * log2(max(clone.pitch, 1) / max(own.pitch, 1)))
            return Scores(ecapaSame: same(ecapa), ecapaMargin: same(ecapa) - other(ecapa),
                          veSame: CloneMeasures.cosine(clone.ve, own.ve), veMargin: same(ve) - other(ve),
                          mfccDistance: CloneMeasures.distance(clone.mfcc, own.mfcc), pitchErrorCents: pitchError, identified: identified)
        }
    }
    struct Scores {
        var ecapaSame: Float, ecapaMargin: Float, veSame: Float, veMargin: Float, mfccDistance: Float, pitchErrorCents: Float, identified: Bool
    }
    struct Row: Codable {
        var model: String, variant: String, license: String
        var downloadMB: Double, loadSeconds: Double
        var audioSeconds = 0.0, computeSeconds = 0.0
        var firstRTF: [Double] = []
        var peakMLXMB = 0.0, footprintMB = 0.0
        var ecapaSame: [Float] = [], ecapaMargin: [Float] = [], veSame: [Float] = [], veMargin: [Float] = []
        var mfccDistance: [Float] = [], pitchErrorCents: [Float] = [], identified: [Bool] = [], wordsPerSecond: [Double] = []

        mutating func add(_ scores: Scores, wordsPerSecond rate: Double) {
            ecapaSame.append(scores.ecapaSame); ecapaMargin.append(scores.ecapaMargin)
            veSame.append(scores.veSame); veMargin.append(scores.veMargin)
            mfccDistance.append(scores.mfccDistance); pitchErrorCents.append(scores.pitchErrorCents)
            identified.append(scores.identified); wordsPerSecond.append(rate)
        }
        static func mean<T: BinaryFloatingPoint>(_ list: [T]) -> Double { list.isEmpty ? 0 : Double(list.reduce(0, +)) / Double(list.count) }
        static let header = "CMP model | variant | license | MB | load s | RTF (all) | RTF first | peak MLX MB | ECAPA centered same/margin | VE raw same, centered margin | MFCC dist | pitch err ¢ | ID | words/s"
        var line: String {
            let rtf = computeSeconds / max(audioSeconds, 0.01)
            let id = "\(identified.filter { $0 }.count)/\(identified.count)"
            return String(format: "CMP %@ | %@ | %@ | %.0f | %.1f | %.2f | %.2f | %.0f | %.3f/%.3f | %.3f/%.3f | %.2f | %.0f | %@ | %.2f",
                          model, variant, license, downloadMB, loadSeconds, rtf, Self.mean(firstRTF), peakMLXMB,
                          Self.mean(ecapaSame), Self.mean(ecapaMargin), Self.mean(veSame), Self.mean(veMargin),
                          Self.mean(mfccDistance), Self.mean(pitchErrorCents), id, Self.mean(wordsPerSecond))
        }
    }

    /// This process's physical footprint, the number iOS's memory limit is measured against.
    static func footprint() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return result == KERN_SUCCESS ? Int(info.phys_footprint) : 0
    }
}

private extension SpeechAudio {
    var pcmSamples: [Float] { if case .pcm(let samples, _) = payload { return samples }; return [] }
}
private extension JSONEncoder {
    static var pretty: JSONEncoder { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]; return encoder }
}

/// Small signal measures for judging clones.
enum CloneMeasures {
    static func resample(_ samples: [Float], from source: Int, to target: Int) -> [Float] {
        AppleSoundIsolation.resample(samples, from: Double(source), to: Double(target)) ?? samples
    }
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let dot = vDSP.dot(a, b), norms = (vDSP.sumOfSquares(a) * vDSP.sumOfSquares(b)).squareRoot()
        return norms > 0 ? dot / norms : 0
    }
    static func distance(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return .infinity }
        return vDSP.distanceSquared(a, b).squareRoot()
    }
    /// Median fundamental frequency of voiced 40 ms frames, by autocorrelation (70–400 Hz).
    static func medianPitch(_ samples: [Float], sampleRate: Int = OwnVoiceAudio.sampleRate) -> Float {
        let frame = sampleRate / 25, hop = sampleRate / 100, shortest = sampleRate / 400, longest = sampleRate / 70
        var found: [Float] = []
        var start = 0
        while start + frame <= samples.count {
            let window = Array(samples[start..<(start + frame)])
            start += hop
            let mean = vDSP.mean(window)
            let centered = vDSP.add(-mean, window)
            let energy = vDSP.sumOfSquares(centered)
            guard (energy / Float(frame)).squareRoot() > 0.02 else { continue }
            var bestLag = 0, best: Float = 0
            for lag in shortest...longest {
                let sum = vDSP.dot(centered[0..<(frame - lag)], centered[lag..<frame])
                if sum > best { best = sum; bestLag = lag }
            }
            if bestLag > 0, best > 0.4 * energy { found.append(Float(sampleRate) / Float(bestLag)) }
        }
        return found.isEmpty ? 0 : found.sorted()[found.count / 2]
    }
    /// Mean MFCCs 1–19 over the frames with speech: a model-free sketch of the voice's timbre.
    static func meanMFCC(_ samples: [Float], sampleRate: Int = OwnVoiceAudio.sampleRate) -> [Float] {
        let size = 512, hop = 240, bands = 40, coefficients = 20
        guard samples.count > size, let dft = try? vDSP.DiscreteFourierTransform(previous: nil, count: size, direction: .forward,
                                                                                transformType: .complexComplex, ofType: Float.self) else { return [] }
        let window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: size, isHalfWindow: false)
        let bins = size / 2 + 1
        func mel(_ hz: Float) -> Float { 2595 * log10(1 + hz / 700) }
        func hz(_ mel: Float) -> Float { 700 * (pow(10, mel / 2595) - 1) }
        let edges = (0...(bands + 1)).map { hz(mel(80) + Float($0) * (mel(7600) - mel(80)) / Float(bands + 1)) }
        let bin = { (f: Float) in f * Float(size) / Float(sampleRate) }
        let filters: [[Float]] = (0..<bands).map { band in
            (0..<bins).map { k in
                let x = Float(k), lo = bin(edges[band]), mid = bin(edges[band + 1]), hi = bin(edges[band + 2])
                return x < lo || x > hi ? 0 : x <= mid ? (x - lo) / max(mid - lo, 1e-3) : (hi - x) / max(hi - mid, 1e-3)
            }
        }
        let zeros = [Float](repeating: 0, count: size)
        var sum = [Float](repeating: 0, count: coefficients - 1), frames = 0
        for start in stride(from: 0, through: samples.count - size, by: hop) {
            let frame = Array(samples[start..<(start + size)])
            guard OwnVoiceAudio.rms(frame) > 0.01 else { continue }
            let spectrum = dft.transform(real: vDSP.multiply(frame, window), imaginary: zeros)
            let power = (0..<bins).map { spectrum.real[$0] * spectrum.real[$0] + spectrum.imaginary[$0] * spectrum.imaginary[$0] }
            let energies = filters.map { log(max(vDSP.dot($0, power), 1e-10)) }
            for c in 1..<coefficients {
                var value: Float = 0
                for (m, energy) in energies.enumerated() { value += energy * cos(Float.pi * Float(c) * (Float(m) + 0.5) / Float(bands)) }
                sum[c - 1] += value
            }
            frames += 1
        }
        return frames == 0 ? [] : sum.map { $0 / Float(frames) }
    }
}
