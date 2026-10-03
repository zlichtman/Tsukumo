import AVFoundation
import CryptoKit
import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// The speech-engine boundary, the pinned voice-model downloads, engine choice and fallback, and
/// the own-voice consent and storage rules. Everything here runs without the GPU; the real
/// Kokoro and Pocket TTS synthesis is exercised on the Mac by `NeuralVoiceIntegrationTests`.
final class SpeechEngineTests: XCTestCase {
    // MARK: Manifest

    func testEveryModelFileIsPinnedToACommitSizeAndChecksum() throws {
        for pack in [VoiceModelPack.kokoro, .pocketTTS] {
            XCTAssertFalse(pack.files.isEmpty)
            var seen = Set<String>()
            for (source, file) in pack.files {
                XCTAssertEqual(source.revision.count, 40, source.repository)
                XCTAssertTrue(source.revision.allSatisfy(\.isHexDigit))
                XCTAssertEqual(file.sha256.count, 64, file.path)
                XCTAssertTrue(file.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase }, file.path)
                XCTAssertGreaterThan(file.size, 0)
                XCTAssertTrue(seen.insert(source.folder + "/" + file.path).inserted, "duplicate \(file.path)")
                let url = try XCTUnwrap(source.url(for: file), file.path)
                XCTAssertEqual(url.scheme, "https")
                XCTAssertEqual(url.host, "huggingface.co")
                XCTAssertTrue(url.path.contains("/resolve/\(source.revision)/"), "must never follow a moving branch")
                XCTAssertFalse(file.path.contains(".."))
            }
        }
    }

    func testKokoroPackHasTheModelEveryListedVoiceAndTheEnglishG2P() throws {
        let pack = VoiceModelPack.kokoro
        let model = try XCTUnwrap(pack.sources.first { $0.folder == "model" })
        let paths = Set(model.files.map(\.path))
        XCTAssertTrue(paths.contains("config.json"))
        XCTAssertTrue(paths.contains("kokoro-v1_0.safetensors"))
        for voice in KokoroVoices.all { XCTAssertTrue(paths.contains("voices/\(voice.id).safetensors"), voice.id) }
        let g2p = try XCTUnwrap(pack.sources.first { $0.folder == "g2p" })
        XCTAssertEqual(Set(g2p.files.map(\.path)), ["us_bart.safetensors", "us_bart_config.json", "us_gold.json", "us_silver.json"])
        // About 342 MB, shown before downloading.
        XCTAssertEqual(pack.totalBytes, 331_818_383 + 9_119_497)
        XCTAssertEqual(VoiceModelPack.pocketTTS.totalBytes, 235_986_469)
    }

    func testKokoroVoiceIDsFallBackToHeart() {
        XCTAssertEqual(KokoroVoices.normalized("am_puck"), "am_puck")
        XCTAssertEqual(KokoroVoices.normalized("bf_emma"), KokoroVoices.defaultID)
        XCTAssertEqual(KokoroVoices.normalized(nil), "af_heart")
        XCTAssertTrue(KokoroVoices.all.allSatisfy { $0.id.hasPrefix("a") }, "the bundled G2P is American English")
    }

    // MARK: Checksums

    func testVerifyAcceptsTheExactFileAndRefusesAnyOther() throws {
        let folder = try temporaryFolder()
        let good = folder.appendingPathComponent("good.bin")
        let data = Data("kokoro speaks on device".utf8)
        try data.write(to: good)
        let pin = VoiceModelPack.File(path: "good.bin", size: Int64(data.count), sha256: sha256(data))
        XCTAssertNoThrow(try VoiceModelFiles.verify(good, against: pin))
        XCTAssertEqual(try VoiceModelFiles.sha256(of: good), pin.sha256)

        let tampered = folder.appendingPathComponent("tampered.bin")
        var changed = data
        changed[0] = 0x4B // same size, one byte different
        try changed.write(to: tampered)
        XCTAssertThrowsError(try VoiceModelFiles.verify(tampered, against: pin)) {
            XCTAssertEqual($0 as? VoiceModelDownloadError, .checksumMismatch("good.bin"))
        }
        let short = folder.appendingPathComponent("short.bin")
        try Data("kokoro".utf8).write(to: short)
        XCTAssertThrowsError(try VoiceModelFiles.verify(short, against: pin)) {
            XCTAssertEqual($0 as? VoiceModelDownloadError, .sizeMismatch("good.bin"))
        }
    }

    // MARK: Download state machine

    @MainActor func testDownloadVerifiesInstallsAndKeepsItOutOfBackups() async throws {
        let (pack, contents) = testPack()
        let root = try temporaryFolder()
        let transport = FakeTransport(contents: contents)
        let store = VoiceModelStore(pack: pack, root: root, transport: transport)
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertTrue(store.wifiOnly, "Wi-Fi only by default")
        store.download()
        XCTAssertTrue(store.state.isBusy)
        await store.waitUntilDone()
        XCTAssertEqual(store.state, .installed)
        XCTAssertEqual(transport.requests.map(\.wifiOnly), [true, true, true])
        XCTAssertTrue(transport.requests.allSatisfy { $0.url.absoluteString.contains("/resolve/\(String(repeating: "a", count: 40))/") })
        XCTAssertTrue(VoiceModelFiles.isExcludedFromBackup(root))
        XCTAssertTrue(VoiceModelFiles.isExcludedFromBackup(store.folder))
        XCTAssertEqual(try Data(contentsOf: store.folder.appendingPathComponent("model/voices/a.bin")), contents["voices/a.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.staging.path))

        // A new store on the same folder sees the install without downloading again.
        let again = VoiceModelStore(pack: pack, root: root, transport: FakeTransport(contents: [:]))
        XCTAssertEqual(again.state, .installed)
        again.delete()
        XCTAssertEqual(again.state, .notDownloaded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: again.folder.path))
    }

    @MainActor func testATamperedFileFailsAndNothingIsInstalled() async throws {
        var (pack, contents) = testPack()
        let original = try XCTUnwrap(contents["config.json"])
        var tampered = Data("{\"evil\":1}".utf8)
        tampered.append(Data(repeating: 0x20, count: max(0, original.count - tampered.count)))
        contents["config.json"] = tampered.prefix(original.count)
        let store = VoiceModelStore(pack: pack, root: try temporaryFolder(), transport: FakeTransport(contents: contents))
        store.download()
        await store.waitUntilDone()
        guard case .failed(let message) = store.state else { return XCTFail("expected failure, got \(store.state)") }
        XCTAssertTrue(message.contains("checksum") || message.contains("size"), message)
        XCTAssertFalse(VoiceModelFiles.isInstalled(pack, at: store.folder))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.folder.path))
    }

    @MainActor func testCancelKeepsVerifiedFilesAndTheNextDownloadResumes() async throws {
        let (pack, contents) = testPack()
        let root = try temporaryFolder()
        let transport = FakeTransport(contents: contents, pauseOn: "voices/b.bin")
        let store = VoiceModelStore(pack: pack, root: root, transport: transport)
        store.download()
        try await transport.waitForPause()
        store.cancel()
        await store.waitUntilDone()
        XCTAssertEqual(store.state, .notDownloaded)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.staging.appendingPathComponent("model/config.json").path))

        let resumed = FakeTransport(contents: contents)
        let second = VoiceModelStore(pack: pack, root: root, transport: resumed)
        second.download()
        await second.waitUntilDone()
        XCTAssertEqual(second.state, .installed)
        XCTAssertFalse(resumed.requests.contains { $0.url.lastPathComponent == "config.json" }, "verified files aren't fetched twice")
    }

    @MainActor func testWaitingForWiFiIsShownAndCellularCanBeAllowed() async throws {
        let (pack, contents) = testPack()
        let transport = FakeTransport(contents: contents, waitFirst: true, pauseOn: "config.json")
        let store = VoiceModelStore(pack: pack, root: try temporaryFolder(), transport: transport)
        store.download()
        try await transport.waitForPause()
        try await waitUntil { store.state == .waitingForWiFi }
        store.cancel()
        await store.waitUntilDone()
        store.wifiOnly = false
        let cellular = FakeTransport(contents: contents)
        let other = VoiceModelStore(pack: pack, root: store.root, transport: cellular)
        other.wifiOnly = false
        other.download()
        await other.waitUntilDone()
        XCTAssertEqual(other.state, .installed)
        XCTAssertTrue(cellular.requests.allSatisfy { !$0.wifiOnly })
    }

    func testWiFiOnlySessionsRefuseCellularHotspotAndLowData() {
        let wifi = URLSessionVoiceModelTransport.configuration(wifiOnly: true)
        XCTAssertFalse(wifi.allowsCellularAccess)
        XCTAssertFalse(wifi.allowsExpensiveNetworkAccess)
        XCTAssertFalse(wifi.allowsConstrainedNetworkAccess)
        XCTAssertTrue(wifi.waitsForConnectivity)
        let any = URLSessionVoiceModelTransport.configuration(wifiOnly: false)
        XCTAssertTrue(any.allowsCellularAccess)
        XCTAssertTrue(any.allowsExpensiveNetworkAccess)
    }

    // MARK: Always the best voice model for the device (VoiceAuto)

    private func device(neural: Bool = true, now: Bool = true, whisper: Bool = false, kokoro: Bool = false, own: Bool = false) -> VoiceAuto.Device {
        .init(neuralSupported: neural, canRunNow: now, whisperInstalled: whisper, kokoroInstalled: kokoro, ownVoiceReady: own)
    }

    func testListeningIsWhisperOnceItIsHereAndTheDeviceCanRunIt() {
        XCTAssertEqual(VoiceAuto.listening(device()), .apple, "Apple's recognizer until Whisper is downloaded")
        XCTAssertEqual(VoiceAuto.listening(device(whisper: true)), .whisper)
        XCTAssertEqual(VoiceAuto.listening(device(neural: false, whisper: true)), .apple, "Where MLX can't run, Apple's recognizer")
        XCTAssertEqual(VoiceAuto.listeningTitle(.whisper), "Whisper · on this device")
        XCTAssertEqual(VoiceAuto.listeningTitle(.apple), "Apple · on this device")
    }

    func testSpeakingIsTheBestVoiceTheDeviceCanRunNeverACloudOne() {
        let heart = VoicePersona.kokoro("af_heart"), puck = VoicePersona.kokoro("am_puck")
        XCTAssertEqual(VoiceAuto.speaking(device(), persona: heart), .apple, "Apple's best voice until Kokoro is here")
        XCTAssertEqual(VoiceAuto.speaking(device(kokoro: true), persona: puck), .kokoro(voice: "am_puck"))
        XCTAssertEqual(VoiceAuto.speaking(device(kokoro: true, own: true), persona: .own), .ownVoice)
        XCTAssertEqual(VoiceAuto.speaking(device(kokoro: true), persona: .own), .kokoro(voice: KokoroVoices.defaultID),
                       "Your voice isn't ready: Kokoro's default, not Apple")
        XCTAssertEqual(VoiceAuto.speaking(device(own: true), persona: .own), .ownVoice)
        XCTAssertEqual(VoiceAuto.speaking(device(now: false, kokoro: true), persona: heart), .apple, "In the background, Apple speaks")
        XCTAssertEqual(VoiceAuto.speaking(device(neural: false, kokoro: true, own: true), persona: .own), .apple, "No GPU, Apple speaks")
    }

    /// OpenAI is an opt-in: while it's on and connected it replaces only what was turned on.
    func testTheOpenAIOptInReplacesOnlyWhatWasTurnedOn() {
        let ready = device(whisper: true, kokoro: true)
        XCTAssertEqual(VoiceAuto.speaking(ready, persona: .kokoro("af_heart"), openAIVoice: "nova"), .openAI(voice: "nova"))
        XCTAssertEqual(VoiceAuto.listening(ready, openAI: nil), .whisper, "Speaking on OpenAI leaves listening automatic")
        XCTAssertEqual(VoiceAuto.listening(ready, openAI: .gpt4oTranscribe), .openAI(.gpt4oTranscribe))
        XCTAssertEqual(VoiceAuto.speaking(ready, persona: .kokoro("af_heart"), openAIVoice: nil), .kokoro(voice: "af_heart"),
                       "Transcribing on OpenAI leaves speaking automatic")
        XCTAssertEqual(SpeechEngineKind.openAI.destination, "api.openai.com")
        for kind in [SpeechEngineKind.apple, .kokoro, .ownVoice] { XCTAssertNil(kind.destination, kind.rawValue) }
        XCTAssertTrue(VoiceAuto.listeningTitle(.openAI(.gpt4oTranscribe)).contains("api.openai.com"))
        XCTAssertTrue(VoiceAuto.speakingTitle(.openAI(voice: "nova"), appleVoice: nil).contains("api.openai.com"))
    }

    /// Off by default; anyone who chose an OpenAI voice or transcription before keeps it.
    func testOpenAIChoicesMadeBeforeAreKept() throws {
        let suite = "openai-voice-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(CloudVoice.speaking(in: defaults), "Off by default")
        XCTAssertNil(CloudVoice.transcriber(in: defaults))
        defaults.set("coral", forKey: CloudVoice.voiceKey)
        XCTAssertTrue(CloudVoice.speaking(in: defaults), "An OpenAI voice chosen before engines existed still speaks")
        defaults.set("kokoro", forKey: CloudVoice.legacyEngineKey)
        XCTAssertFalse(CloudVoice.speaking(in: defaults), "Someone who moved to Kokoro stays on it")
        defaults.set("openAI", forKey: CloudVoice.legacyEngineKey)
        XCTAssertTrue(CloudVoice.speaking(in: defaults), "Someone who chose OpenAI keeps it")
        defaults.set(false, forKey: CloudVoice.speakingKey)
        XCTAssertFalse(CloudVoice.speaking(in: defaults), "The switch wins once it's used")
        defaults.set("gpt-4o-mini-transcribe", forKey: CloudVoice.transcriberKey)
        XCTAssertEqual(CloudVoice.transcriber(in: defaults), .gpt4oMiniTranscribe, "An OpenAI transcriber chosen before is kept")
        for onDevice in ["apple", "whisper-on-device"] {
            defaults.set(onDevice, forKey: CloudVoice.transcriberKey)
            XCTAssertNil(CloudVoice.transcriber(in: defaults), "The old on-device choices are now automatic")
        }
    }

    func testOnlyModelsTheDeviceCanRunAreOffered() {
        XCTAssertEqual(VoiceAuto.missing(device()).map(\.id), [VoiceModelPack.whisper.id, VoiceModelPack.kokoro.id])
        XCTAssertEqual(VoiceAuto.missing(device(whisper: true)).map(\.id), [VoiceModelPack.kokoro.id])
        XCTAssertTrue(VoiceAuto.missing(device(whisper: true, kokoro: true)).isEmpty)
        XCTAssertTrue(VoiceAuto.missing(device(neural: false)).isEmpty, "Nothing better to download where MLX can't run")
    }

    func testTheVoiceChoiceIsOnlyWhichVoiceAndKeepsEarlierChoices() throws {
        let suite = "voice-persona-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(VoicePersona.stored(in: defaults), .kokoro(KokoroVoices.defaultID), "Heart by default")
        defaults.set("am_puck", forKey: VoicePersona.legacyKokoroKey)
        XCTAssertEqual(VoicePersona.stored(in: defaults), .kokoro("am_puck"), "An earlier Kokoro voice is kept")
        defaults.set("ownVoice", forKey: VoicePersona.legacyEngineKey)
        XCTAssertEqual(VoicePersona.stored(in: defaults), .own, "Someone who chose their own voice keeps it")
        defaults.set("openAI", forKey: VoicePersona.legacyEngineKey)
        XCTAssertEqual(VoicePersona.stored(in: defaults), .kokoro("am_puck"), "An OpenAI voice becomes the Kokoro voice: nothing goes to a cloud")
        defaults.set("own", forKey: VoicePersona.key)
        XCTAssertEqual(VoicePersona.stored(in: defaults), .own)
        XCTAssertEqual(VoicePersona(stored: "nonsense"), .kokoro(KokoroVoices.defaultID))
        XCTAssertEqual(VoicePersona.own.title(neuralSupported: true), "Your voice (cloned)")
        XCTAssertEqual(VoicePersona.kokoro("am_puck").title(neuralSupported: true), "Puck")
        XCTAssertEqual(VoicePersona.kokoro("am_puck").title(neuralSupported: false), "Apple")
    }

    /// One consent downloads every better model the device can run; nothing downloads in tests or
    /// before it, and Remove takes them off and stops them coming back.
    @MainActor func testBetterVoiceModelsNeedOneConsentAndRemoveUndoesIt() throws {
        let root = try temporaryFolder()
        let suite = "better-voices-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeTransport(contents: [:])
        let voices = SpeechVoices(kokoro: VoiceModelStore(pack: .kokoro, root: root, transport: transport),
                                  pocket: VoiceModelStore(pack: .pocketTTS, root: root, transport: transport),
                                  own: OwnVoiceStore(folder: { root.appendingPathComponent("Voice") }),
                                  whisper: VoiceModelStore(pack: .whisper, root: root, transport: transport), defaults: defaults)
        XCTAssertFalse(voices.betterModelsAgreed)
        voices.resumeBetterModels()
        XCTAssertEqual(voices.kokoro.state, .notDownloaded, "Nothing downloads before the consent")
        voices.downloadBetterModels()
        XCTAssertTrue(voices.betterModelsAgreed)
        XCTAssertTrue(defaults.bool(forKey: SpeechVoices.betterModelsKey), "A device setting")
        XCTAssertEqual(voices.kokoro.state, .notDownloaded, "Never downloads in tests")
        voices.removeBetterModels()
        XCTAssertFalse(voices.betterModelsAgreed)
        XCTAssertTrue(voices.kokoro.wifiOnly && voices.whisper.wifiOnly, "Wi-Fi only by default")
    }

    func testShortSizesRoundToWholeMegabytes() {
        XCTAssertEqual(VoiceModelPack.kokoro.shortSizeLabel, "341 MB")
        XCTAssertEqual(VoiceModelPack.pocketTTS.shortSizeLabel, "236 MB")
    }

    @MainActor func testNeuralVoicesNeverRunInTheSimulatorSoAppleSpeaks() throws {
        #if targetEnvironment(simulator)
        let root = try temporaryFolder()
        let kokoro = VoiceModelStore(pack: .kokoro, root: root, transport: FakeTransport(contents: [:]))
        let voices = SpeechVoices(kokoro: kokoro, pocket: VoiceModelStore(pack: .pocketTTS, root: root, transport: FakeTransport(contents: [:])),
                                  own: OwnVoiceStore(folder: { root.appendingPathComponent("Voice") }))
        XCTAssertFalse(NeuralSpeechRuntime.isSupported)
        XCTAssertFalse(voices.device.neuralSupported)
        XCTAssertEqual(voices.route(), .apple)
        XCTAssertFalse(KokoroSpeechEngine(store: kokoro).isAvailable)
        #else
        throw XCTSkip("Simulator-only check")
        #endif
    }

    // MARK: Audio and text

    func testSentencesSplitForStreamingAndLongOnesAreCut() {
        XCTAssertEqual(SpeechChunks.sentences("Morning. What would make today good? We can start with one thing!"),
                       ["Morning.", "What would make today good?", "We can start with one thing!"])
        XCTAssertEqual(SpeechChunks.sentences("   "), [])
        let long = Array(repeating: "word", count: 120).joined(separator: " ") + "."
        let pieces = SpeechChunks.sentences(long, maxCharacters: 100)
        XCTAssertGreaterThan(pieces.count, 4)
        XCTAssertTrue(pieces.allSatisfy { $0.count <= 100 })
        XCTAssertEqual(pieces.joined(separator: " "), long)
    }

    func testPCMIsWrappedAsPlayableWAV() throws {
        let audio = SpeechAudio(payload: .pcm([0, 0.5, -0.5, 1, -1, 2], sampleRate: 24_000))
        XCTAssertEqual(audio.duration, 6.0 / 24_000, accuracy: 1e-9)
        let wav = [UInt8](audio.playableData())
        XCTAssertEqual(wav.count, 44 + 12)
        XCTAssertEqual(String(decoding: wav.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: wav.dropFirst(8).prefix(4), as: UTF8.self), "WAVE")
        let rateBytes = Array(wav.dropFirst(24).prefix(4))
        XCTAssertEqual(rateBytes.count, 4)
        let rate = rateBytes.reversed().reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        XCTAssertEqual(rate, 24_000)
        let url = try temporaryFolder().appendingPathComponent("a.wav")
        try Data(wav).write(to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(file.length, 6)
        XCTAssertEqual(file.fileFormat.sampleRate, 24_000)
        let encoded = Data([1, 2, 3])
        XCTAssertEqual(SpeechAudio(payload: .encoded(encoded)).playableData(), encoded)
    }

    @MainActor func testAppleVoiceRendersSpeechBehindTheBoundary() async throws {
        let engine = AppleSpeechEngine(rate: 0.5)
        XCTAssertTrue(engine.isAvailable)
        XCTAssertNil(engine.destination)
        guard !engine.voices.isEmpty else { throw XCTSkip("No Apple voices installed here") }
        let audio = try await engine.synthesize("Hello from Kemo.", voice: nil)
        XCTAssertGreaterThan(audio.duration, 0.3)
        do { _ = try await engine.synthesize("  ", voice: nil); XCTFail("empty text should throw") }
        catch { XCTAssertEqual(error as? SpeechEngineError, .emptyText) }
    }

    // MARK: Your voice

    func testConsentAndPassageMustBeWhatWasShown() throws {
        let consent = OwnVoiceEnrollment.consentLine
        XCTAssertTrue(OwnVoiceEnrollment.matches(heard: "This is my voice and I'm creating a voice for my own Kemo Sabe", expected: consent, threshold: 0.8))
        XCTAssertTrue(OwnVoiceEnrollment.matches(heard: "this is my voice and im creating a voice for my own kemosabe", expected: consent, threshold: 0.8))
        XCTAssertFalse(OwnVoiceEnrollment.matches(heard: "This is not my voice", expected: consent, threshold: 0.8))
        XCTAssertFalse(OwnVoiceEnrollment.matches(heard: "", expected: consent))
        let passage = try XCTUnwrap(OwnVoiceEnrollment.passages.first)
        let other = try XCTUnwrap(OwnVoiceEnrollment.passages.dropFirst().first)
        XCTAssertTrue(OwnVoiceEnrollment.matches(heard: passage.replacingOccurrences(of: "flat", with: "fat"), expected: passage))
        XCTAssertFalse(OwnVoiceEnrollment.matches(heard: other, expected: passage))
    }

    func testThePassageIsChosenAtRandomFromTheBank() {
        var generator = SeededGenerator(seed: 7)
        let picks = (0..<40).map { _ in OwnVoiceEnrollment.passage(using: &generator) }
        XCTAssertTrue(picks.allSatisfy(OwnVoiceEnrollment.passages.contains))
        XCTAssertGreaterThan(Set(picks).count, 3)
        XCTAssertGreaterThanOrEqual(OwnVoiceEnrollment.passages.count, 8)
    }

    @MainActor func testOwnVoiceIsSavedProtectedAndDeletedInOneStep() async throws {
        let account = try temporaryFolder()
        let voiceFolder = account.appendingPathComponent("Voice")
        let store = OwnVoiceStore(folder: { voiceFolder })
        XCTAssertFalse(store.isEnrolled)
        let scratch = try temporaryFolder()
        let sample = scratch.appendingPathComponent("sample.wav"), consent = scratch.appendingPathComponent("consent.wav")
        try SpeechAudio.wav([Float](repeating: 0.1, count: 24_000), sampleRate: 24_000).write(to: sample)
        try SpeechAudio.wav([Float](repeating: 0.1, count: 12_000), sampleRate: 24_000).write(to: consent)
        let record = OwnVoiceRecord(createdAt: Date(timeIntervalSince1970: 1_790_000_000), passage: try XCTUnwrap(OwnVoiceEnrollment.passages.first),
                                    consentLine: OwnVoiceEnrollment.consentLine, heardPassage: "…", heardConsent: "…",
                                    sampleSeconds: 1, model: "mlx-community/pocket-tts@test")
        try store.save(.forTesting(sampleFile: sample, consentFile: consent, record: record))
        XCTAssertTrue(store.isEnrolled)
        XCTAssertEqual(store.record, record)
        XCTAssertEqual(store.sampleURL?.deletingLastPathComponent().standardizedFileURL, voiceFolder.standardizedFileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sample.path), "the temporary take is removed")
        XCTAssertTrue(VoiceModelFiles.isExcludedFromBackup(voiceFolder), "never in a backup")
        #if os(iOS) && !targetEnvironment(simulator)
        let protection = try FileManager.default.attributesOfItem(atPath: voiceFolder.appendingPathComponent("sample.wav").path)[.protectionKey] as? FileProtectionType
        XCTAssertEqual(protection, .complete)
        #endif
        XCTAssertEqual(OwnVoiceStore(folder: { voiceFolder }).record, record, "survives a relaunch")

        await store.delete()
        XCTAssertFalse(store.isEnrolled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: voiceFolder.path), "Delete removes everything")
    }

    @MainActor func testOwnVoiceDefaultsToTheAccountFolder() {
        XCTAssertEqual(OwnVoiceStore().folder.standardizedFileURL.path,
                       AccountDirectory.currentFolder.appendingPathComponent("Voice").standardizedFileURL.path)
    }

    @MainActor func testYourVoiceIsNeverWrittenWhileTheAccountIsSwitching() async throws {
        let voiceFolder = AccountDirectory.currentFolder.appendingPathComponent("Voice-switch-" + UUID().uuidString, isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: voiceFolder) }
        let store = OwnVoiceStore(folder: { voiceFolder })
        let scratch = try temporaryFolder()
        func take() throws -> OwnVoiceTake {
            let sample = scratch.appendingPathComponent(UUID().uuidString + ".wav"), consent = scratch.appendingPathComponent(UUID().uuidString + ".wav")
            try SpeechAudio.wav([Float](repeating: 0.1, count: 2_400), sampleRate: 24_000).write(to: sample)
            try SpeechAudio.wav([Float](repeating: 0.1, count: 2_400), sampleRate: 24_000).write(to: consent)
            return .forTesting(sampleFile: sample, consentFile: consent, record: .init(
                createdAt: .now, passage: "p", consentLine: OwnVoiceEnrollment.consentLine, heardPassage: "p", heardConsent: "c", sampleSeconds: 0.1, model: "test"))
        }
        let first = try take()
        AccountDirectory.beginSwitch()
        XCTAssertThrowsError(try store.save(first), "refused behind the write fence")
        AccountDirectory.endSwitch()
        XCTAssertFalse(store.isEnrolled)
        XCTAssertFalse(FileManager.default.fileExists(atPath: voiceFolder.path))
        try store.save(take())
        XCTAssertTrue(store.isEnrolled)
        await store.delete()
        XCTAssertFalse(store.isEnrolled)
    }

    #if os(macOS)
    @MainActor func testReadAloudOnMacIsOffByDefaultAndSavedPerAccount() {
        let settings = AccountDirectory.accountSettings
        let saved = settings.object(forKey: MacReadAloud.enabledKey)
        defer { settings.set(saved, forKey: MacReadAloud.enabledKey) }
        settings.removeObject(forKey: MacReadAloud.enabledKey)
        let reader = MacReadAloud()
        XCTAssertFalse(reader.enabled, "off until the person turns it on")
        reader.setEnabled(true)
        XCTAssertTrue(settings.bool(forKey: MacReadAloud.enabledKey))
        XCTAssertTrue(MacReadAloud().enabled)
        reader.setEnabled(false)
        XCTAssertNil(reader.speaking)
    }
    #endif

    func testG2PMirrorCopiesTheVerifiedFilesOnce() throws {
        let source = try temporaryFolder(), target = try temporaryFolder().appendingPathComponent("g2p")
        let g2p = try XCTUnwrap(VoiceModelPack.kokoro.sources.first { $0.folder == "g2p" })
        for file in g2p.files { try Data(count: Int(min(file.size, 64))).write(to: source.appendingPathComponent(file.path)) }
        // Sizes differ from the pins here, so each prepare copies; real files match and are skipped.
        try KokoroG2PMirror.prepare(from: source, to: target)
        for file in g2p.files { XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent(file.path).path)) }
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("config.json")), Data("{}".utf8))
        XCTAssertNoThrow(try KokoroG2PMirror.prepare(from: source, to: target))
    }

    // MARK: Helpers

    private func temporaryFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("speech-tests-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func testPack() -> (VoiceModelPack, [String: Data]) {
        let contents: [String: Data] = ["config.json": Data("{\"model\":\"test\"}".utf8), "voices/a.bin": Data(repeating: 7, count: 4096),
                                        "voices/b.bin": Data(repeating: 9, count: 2048)]
        let files = ["config.json", "voices/a.bin", "voices/b.bin"].map { path in
            let data = contents[path] ?? Data()
            return VoiceModelPack.File(path: path, size: Int64(data.count), sha256: sha256(data))
        }
        let pack = VoiceModelPack(id: "test-" + UUID().uuidString, title: "Test", version: 1, sources: [
            .init(repository: "example/test", revision: String(repeating: "a", count: 40), license: "MIT", folder: "model", files: files),
        ])
        return (pack, contents)
    }
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<200 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }
}

/// Serves pinned test files from memory, optionally pausing on one file until cancelled.
private final class FakeTransport: VoiceModelTransport, @unchecked Sendable {
    struct Request { let url: URL; let wifiOnly: Bool }
    private let lock = NSLock()
    private var _requests: [Request] = []
    private var paused = false
    let contents: [String: Data]
    let pauseOn: String?
    let waitFirst: Bool
    init(contents: [String: Data], waitFirst: Bool = false, pauseOn: String? = nil) {
        self.contents = contents; self.waitFirst = waitFirst; self.pauseOn = pauseOn
    }
    var requests: [Request] { lock.withLock { _requests } }
    func waitForPause() async throws {
        for _ in 0..<300 { if lock.withLock({ paused }) { return }; try await Task.sleep(for: .milliseconds(10)) }
        XCTFail("transport never paused")
    }
    func download(_ url: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64) -> Void,
                  waiting: @escaping @Sendable () -> Void) async throws -> URL {
        guard let tail = url.path.components(separatedBy: "/resolve/").last,
              let path = tail.split(separator: "/", maxSplits: 1).last.map(String.init) else { throw URLError(.badURL) }
        lock.withLock { _requests.append(.init(url: url, wifiOnly: wifiOnly)) }
        if waitFirst && wifiOnly { waiting() }
        if path == pauseOn {
            lock.withLock { paused = true }
            while !Task.isCancelled { try await Task.sleep(for: .milliseconds(5)) }
            throw CancellationError()
        }
        guard let data = contents[path] else { throw URLError(.fileDoesNotExist) }
        progress(Int64(data.count / 2)); progress(Int64(data.count))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("fake-" + UUID().uuidString)
        try data.write(to: file)
        return file
    }
}

private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
