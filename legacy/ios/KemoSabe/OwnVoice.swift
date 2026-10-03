import Foundation
import AVFoundation
import Speech
import Observation

/// "Your voice": Kemo can read aloud in the person's own voice, cloned on this device from a
/// short live recording session. Only the person's own voice: after a quick check of the room
/// they read a few randomly chosen passages shown on screen (a calm one, a question, an
/// exclamation) and then say the consent line, and every take is checked with on-device speech
/// recognition. There is no way to import an audio file. The takes are cleaned up on the device
/// (`OwnVoiceAudio`), the best of them become the voice's reference, and that reference and the
/// consent recording live in the account's folder with complete file protection, excluded from
/// backups, never uploaded or synced. One Delete removes all of it.
enum OwnVoiceEnrollment {
    static let consentLine = "This is my voice and I'm creating a voice for my own KemoSabe."

    /// One line to read, about eight seconds at an easy pace.
    struct Passage: Equatable, Hashable, Codable, Sendable {
        enum Kind: String, Codable, CaseIterable, Sendable { case calm, question, exclamation }
        let text: String
        let kind: Kind
    }
    /// Lines with a spread of English sounds, and of intonation: calm narration, questions that
    /// rise, and exclamations with energy, so the voice isn't flat.
    static let bank: [Passage] = [
        .init(text: "The quiet river bends past the old mill, where children skip flat stones and count every splash before supper.", kind: .calm),
        .init(text: "On Thursday morning I packed a warm jacket, two peaches, and a map, then walked north until the fog lifted.", kind: .calm),
        .init(text: "A bright yellow kite drifted over the harbor while fishermen checked their nets and gulls argued about breakfast.", kind: .calm),
        .init(text: "Please remind me to water the ferns, call my brother after lunch, and pick up fresh bread on the way home.", kind: .calm),
        .init(text: "The jazz trio played softly by the window as rain tapped the glass and the coffee grew cold between stories.", kind: .calm),
        .init(text: "We measured the garden twice, planted beans along the fence, and marked each row with a painted wooden stick.", kind: .calm),
        .init(text: "Every evening the lighthouse keeper wound the brass clock, wrote three lines in his journal, and watched the tide.", kind: .calm),
        .init(text: "My favorite sandwich has sharp cheddar, crisp apple, and a thin layer of honey mustard on toasted rye bread.", kind: .calm),
        .init(text: "Just before the concert, the violinist tuned each string, smiled at the crowd, and waited for complete silence.", kind: .calm),
        .init(text: "If the train is late again, we can share a pot of tea at the station café and plan the whole weekend.", kind: .calm),
        .init(text: "Have you ever noticed how the city sounds different at dawn, before the buses and the coffee shops wake up?", kind: .question),
        .init(text: "Would you rather climb a snowy mountain in January or swim in a warm, quiet lake in the middle of August?", kind: .question),
        .init(text: "Which song was playing when we drove to the beach, and do you remember who sang along the loudest?", kind: .question),
        .init(text: "Could you pass the blue notebook, check the oven timer, and tell me whether the soup needs more pepper?", kind: .question),
        .init(text: "Why do cats always choose the one chair you were just about to sit in, right after lunch?", kind: .question),
        .init(text: "What a wonderful surprise! The whole team cheered, the lights flashed, and somebody even brought chocolate cake!", kind: .exclamation),
        .init(text: "Look at that sunset! The sky turned orange, then pink, then a deep purple that seemed to glow forever!", kind: .exclamation),
        .init(text: "We did it! After three long weeks of practice, the choir finally hit every note in the final chorus!", kind: .exclamation),
        .init(text: "Watch out for the puddle! Oh no, too late, my new shoes are completely soaked through again!", kind: .exclamation),
        .init(text: "That was the best pizza I have ever tasted, with crispy basil, fresh mozzarella, and a smoky crust!", kind: .exclamation),
    ]
    static var passages: [String] { bank.map(\.text) }

    /// A session starts with four takes (about 32 seconds) and can grow to five.
    static let startingTakes = 4
    static let maximumTakes = 5
    static let quietCheckSeconds: TimeInterval = 3
    static let minimumTakeSeconds: TimeInterval = 3
    static let maximumTakeSeconds: TimeInterval = 15
    static let maximumConsentSeconds: TimeInterval = 10

    static func passage<G: RandomNumberGenerator>(using generator: inout G) -> String { passages.randomElement(using: &generator) ?? passages.first ?? "" }
    static func randomPassage() -> String { var generator = SystemRandomNumberGenerator(); return passage(using: &generator) }

    /// The opening set, chosen at random: calm, a question, an exclamation, and calm again.
    static func startingPassages<G: RandomNumberGenerator>(using generator: inout G) -> [Passage] {
        var chosen: [Passage] = []
        for kind in [Passage.Kind.calm, .question, .exclamation, .calm] {
            if let next = bank.filter({ $0.kind == kind && !chosen.contains($0) }).randomElement(using: &generator) { chosen.append(next) }
        }
        return chosen
    }
    /// One more passage for "Record more": unused, from the kind used least so far.
    static func nextPassage<G: RandomNumberGenerator>(after used: [Passage], using generator: inout G) -> Passage? {
        let unused = bank.filter { !used.contains($0) }
        let counts = Dictionary(grouping: used, by: \.kind).mapValues(\.count)
        let fewest = Passage.Kind.allCases.filter { kind in unused.contains { $0.kind == kind } }
            .min { (counts[$0] ?? 0) < (counts[$1] ?? 0) }
        return unused.filter { $0.kind == fewest }.randomElement(using: &generator) ?? unused.randomElement(using: &generator)
    }

    /// Whether what recognition heard is the expected line: at least `threshold` of the
    /// expected words, in order. Tolerates recognition slips, not a different sentence.
    static func matches(heard: String, expected: String, threshold: Double = 0.7) -> Bool {
        let want = words(expected), got = words(heard)
        guard !want.isEmpty, !got.isEmpty else { return false }
        return Double(commonSubsequence(want, got)) / Double(want.count) >= threshold
    }
    static func words(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "kemo sabe", with: "kemosabe")
            .replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "'", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    }
    private static func commonSubsequence(_ a: [String], _ b: [String]) -> Int {
        var previous = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var current = [Int](repeating: 0, count: b.count + 1)
            for (j, y) in b.enumerated() { current[j + 1] = x == y ? previous[j] + 1 : max(previous[j + 1], current[j]) }
            previous = current
        }
        return previous[b.count]
    }
}

/// What was agreed to, kept with the recordings. The fields after `model` were added with the
/// multi-take flow; a voice made before it has only the first ones.
struct OwnVoiceRecord: Codable, Equatable {
    var createdAt: Date
    var passage: String
    var consentLine: String
    var heardPassage: String
    var heardConsent: String
    /// Seconds of speech in the saved reference.
    var sampleSeconds: Double
    /// The model the voice is made with, pinned like its download.
    var model: String
    /// Every passage read, and what recognition heard for each.
    var passages: [String]? = nil
    var heardPassages: [String]? = nil
    /// Which takes the reference is made of, best first.
    var reference: [OwnVoiceAudio.Segment]? = nil
    var roomNoiseDecibels: Float? = nil
    var noiseReduction: OwnVoiceAudio.NoiseReduction? = nil

    var takeCount: Int { passages?.count ?? 1 }
}

/// A finished session from `OwnVoiceTrainer`. Its initializer is private to this file, so the
/// store can only ever save live takes made in the flow, never an imported file.
struct OwnVoiceTake {
    let sampleFile: URL
    let consentFile: URL
    let record: OwnVoiceRecord
    fileprivate init(sampleFile: URL, consentFile: URL, record: OwnVoiceRecord) {
        self.sampleFile = sampleFile; self.consentFile = consentFile; self.record = record
    }
    #if DEBUG
    /// Tests only: a take from files the test wrote itself.
    static func forTesting(sampleFile: URL, consentFile: URL, record: OwnVoiceRecord) -> OwnVoiceTake {
        .init(sampleFile: sampleFile, consentFile: consentFile, record: record)
    }
    #endif
}

/// The person's voice reference and consent, in the current account's folder.
@MainActor @Observable final class OwnVoiceStore {
    nonisolated static let folderName = "Voice"
    static let sampleName = "sample.wav", consentName = "consent.wav", recordName = "consent.json"
    @ObservationIgnored private let folderProvider: () -> URL
    private(set) var record: OwnVoiceRecord?

    init(folder: @escaping () -> URL = { AccountDirectory.currentFolder.appendingPathComponent(OwnVoiceStore.folderName, isDirectory: true) }) {
        folderProvider = folder
        reload()
    }
    var folder: URL { folderProvider() }
    var isEnrolled: Bool { record != nil && sampleURL != nil }
    var sampleURL: URL? {
        let url = folder.appendingPathComponent(Self.sampleName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    func reload() {
        record = (try? Data(contentsOf: folder.appendingPathComponent(Self.recordName)))
            .flatMap { try? JSONDecoder.ownVoice.decode(OwnVoiceRecord.self, from: $0) }
    }

    /// Saves a finished session: copies it in with complete file protection and removes the
    /// temporary files. Replaces an earlier voice.
    func save(_ take: OwnVoiceTake) throws {
        // Never into an account that isn't open, or while the device is switching accounts.
        try AccountDirectory.checkWrite(to: folder)
        let files = FileManager.default
        try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: Self.protection)
        try VoiceModelFiles.excludeFromBackup(folder)
        try Self.write(Data(contentsOf: take.sampleFile), to: folder.appendingPathComponent(Self.sampleName))
        try Self.write(Data(contentsOf: take.consentFile), to: folder.appendingPathComponent(Self.consentName))
        try Self.write(JSONEncoder.ownVoice.encode(take.record), to: folder.appendingPathComponent(Self.recordName))
        try? files.removeItem(at: take.sampleFile); try? files.removeItem(at: take.consentFile)
        reload()
    }
    /// Removes the recordings, the consent record, and any voice made from them, and stops
    /// using the voice for replies.
    func delete() async {
        guard AccountDirectory.permitsWrite(to: folder) else { return }
        try? FileManager.default.removeItem(at: folder)
        record = nil
        await NeuralSpeechWorker.shared.unload()
    }

    #if os(iOS)
    private static let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.complete]
    nonisolated fileprivate static func write(_ data: Data, to url: URL) throws { try data.write(to: url, options: [.atomic, .completeFileProtection]) }
    #else
    private static let protection: [FileAttributeKey: Any] = [:]
    nonisolated fileprivate static func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    #endif
}

extension JSONEncoder {
    static var ownVoice: JSONEncoder { let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.sortedKeys]; return encoder }
}
extension JSONDecoder {
    static var ownVoice: JSONDecoder { let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601; return decoder }
}

// MARK: - The session

/// Where a "Your voice" session is, as plain state: the room check, each take, the consent
/// line, building the voice, and hearing it. `OwnVoiceTrainer` drives it with real audio; the
/// rules live here so they can be tested without a microphone.
struct OwnVoiceSession: Equatable {
    enum Stage: Equatable { case roomCheck, takes, consent, building, preview }
    enum RoomCheck: Equatable { case notStarted, measuring, done(OwnVoiceAudio.RoomNoise) }
    enum Status: Equatable {
        case waiting, recording, checking, accepted
        /// Needs another go, with the one-line reason.
        case redo(String)
    }
    struct Take: Equatable, Identifiable {
        let id: Int
        let passage: OwnVoiceEnrollment.Passage
        var status: Status = .waiting
        var heard: String?
        var report: OwnVoiceAudio.TakeReport?
    }

    private(set) var room: RoomCheck = .notStarted
    /// The person chose to go on in a noisy room.
    private(set) var acceptedNoisyRoom = false
    private(set) var takes: [Take]
    private(set) var consent: Status = .waiting
    private(set) var heardConsent: String?
    /// Bumped each time the takes that make the voice change, so a stale build is never used.
    private(set) var revision = 0
    private(set) var builtRevision: Int?

    init(passages: [OwnVoiceEnrollment.Passage]) {
        takes = passages.enumerated().map { Take(id: $0.offset, passage: $0.element) }
    }

    var roomNoise: OwnVoiceAudio.RoomNoise? { if case .done(let noise) = room { return noise }; return nil }
    var isNoisy: Bool { roomNoise?.isNoisy == true }
    var isRecording: Bool { room == .measuring || consent == .recording || takes.contains { $0.status == .recording } }
    var isBusy: Bool { isRecording || consent == .checking || takes.contains { $0.status == .checking } }
    var acceptedTakes: [Take] { takes.filter { $0.status == .accepted } }
    /// The take to record next: the first one not yet accepted.
    var currentTake: Take? { takes.first { $0.status != .accepted } }
    var canRecordMore: Bool { stage == .preview && takes.count < OwnVoiceEnrollment.maximumTakes }

    var stage: Stage {
        guard let noise = roomNoise, !noise.isNoisy || acceptedNoisyRoom else { return .roomCheck }
        if currentTake != nil { return .takes }
        if consent != .accepted { return .consent }
        return builtRevision == revision ? .preview : .building
    }

    // Room check
    mutating func beginRoomCheck() { guard !isBusy else { return }; room = .measuring; acceptedNoisyRoom = false }
    mutating func roomMeasured(_ noise: OwnVoiceAudio.RoomNoise) { room = .done(noise) }
    mutating func continueInNoisyRoom() { if isNoisy { acceptedNoisyRoom = true } }
    mutating func cancelRoomCheck() { if room == .measuring { room = .notStarted } }

    // Takes
    mutating func beginTake(_ id: Int) -> Bool {
        guard stage == .takes, !isBusy, currentTake?.id == id, let index = takes.firstIndex(where: { $0.id == id }) else { return false }
        takes[index].status = .recording
        return true
    }
    /// The take stopped. A clipped, too quiet, or too short take goes straight back for a redo.
    mutating func takeRecorded(_ id: Int, report: OwnVoiceAudio.TakeReport) {
        guard let index = takes.firstIndex(where: { $0.id == id }), takes[index].status == .recording else { return }
        takes[index].report = report
        if let problem = OwnVoiceAudio.problem(with: report, minimumSeconds: OwnVoiceEnrollment.minimumTakeSeconds) {
            takes[index].status = .redo(problem.message)
        } else {
            takes[index].status = .checking
        }
    }
    /// On-device recognition finished: the take counts only if it's the line on screen.
    mutating func takeChecked(_ id: Int, heard: String) {
        guard let index = takes.firstIndex(where: { $0.id == id }), takes[index].status == .checking else { return }
        takes[index].heard = heard
        if OwnVoiceEnrollment.matches(heard: heard, expected: takes[index].passage.text) {
            takes[index].status = .accepted
            revision += 1
        } else {
            takes[index].status = .redo("That didn't match the line on screen. Read it as shown.")
        }
    }
    mutating func takeFailed(_ id: Int, message: String) {
        guard let index = takes.firstIndex(where: { $0.id == id }), [.recording, .checking].contains(takes[index].status) else { return }
        takes[index].status = .redo(message)
    }
    /// Throws a take away so it can be read again.
    mutating func redo(_ id: Int) {
        guard !isBusy, let index = takes.firstIndex(where: { $0.id == id }) else { return }
        if takes[index].status == .accepted { revision += 1 }
        takes[index].status = .waiting; takes[index].heard = nil; takes[index].report = nil
    }
    /// Adds one more passage after the voice is built; the voice is rebuilt with it.
    mutating func recordMore(_ passage: OwnVoiceEnrollment.Passage) {
        guard canRecordMore else { return }
        takes.append(Take(id: (takes.map(\.id).max() ?? -1) + 1, passage: passage))
    }

    // Consent
    mutating func beginConsent() -> Bool {
        guard stage == .consent, !isBusy else { return false }
        consent = .recording
        return true
    }
    mutating func consentRecorded(seconds: Double) {
        guard consent == .recording else { return }
        consent = seconds >= 1.5 ? .checking : .redo("That was too short. Say the whole line.")
    }
    mutating func consentChecked(heard: String) {
        guard consent == .checking else { return }
        heardConsent = heard
        consent = OwnVoiceEnrollment.matches(heard: heard, expected: OwnVoiceEnrollment.consentLine, threshold: 0.8)
            ? .accepted : .redo("The consent line didn't come through. Say it exactly as shown.")
    }
    mutating func consentFailed(_ message: String) { if consent == .recording || consent == .checking { consent = .redo(message) } }

    // Building
    mutating func built(revision built: Int) { if built == revision { builtRevision = built } }
}

// MARK: - Audio in

/// Where the trainer's audio comes from: the microphone, or a stand-in under UI testing.
/// Delivers 24 kHz mono float samples on the main actor.
@MainActor protocol OwnVoiceCapture: AnyObject {
    func start(_ deliver: @escaping @MainActor ([Float]) -> Void) async throws
    func stop()
}

/// Checks a take with speech recognition on this device; nothing is sent anywhere.
/// `samples` are 24 kHz mono floats. `expected` is the line on screen; a checker must not use
/// it to bias what it hears (the comparison happens afterwards, in `OwnVoiceSession`).
protocol OwnVoiceChecking: Sendable {
    func transcript(of samples: [Float], expected: String) async throws -> String
}

/// The hook for which recognizer checks the takes. Apple's on-device recognizer by default; another
/// engine that runs on this device (an on-device Whisper, say) can set `make` at launch. Never a
/// cloud recognizer: the takes are the person's voice and don't leave the device.
enum OwnVoiceChecks {
    @MainActor static var make: () -> any OwnVoiceChecking = { WhisperFirst() }

    /// On-device Whisper when it's downloaded and can run now (it hears more accurately, so fewer
    /// good takes are sent back), otherwise Apple's on-device recognizer. Whisper reads a file:
    /// the take is written to the temporary folder with complete protection just for the check
    /// and deleted straight after.
    struct WhisperFirst: OwnVoiceChecking {
        func transcript(of samples: [Float], expected: String) async throws -> String {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("own-voice-check-\(UUID().uuidString).wav")
            if (try? OwnVoiceStore.write(SpeechAudio.wav(samples, sampleRate: OwnVoiceAudio.sampleRate), to: url)) != nil {
                let heard = await OnDeviceWhisper.transcribeRecording(url)
                try? FileManager.default.removeItem(at: url)
                if let heard, !heard.isEmpty { return heard }
            }
            return try await OwnVoiceTranscriber().transcript(of: samples, expected: expected)
        }
    }
}

/// The microphone through AVAudioEngine, converted to 24 kHz mono as it arrives. On iPhone the
/// session uses measurement mode, which turns off the system's own processing so the voice is
/// recorded as it is.
@MainActor final class OwnVoiceMicrophone: OwnVoiceCapture {
    private var engine: AVAudioEngine?

    func start(_ deliver: @escaping @MainActor ([Float]) -> Void) async throws {
        guard await Self.microphoneAllowed() else { throw OwnVoiceTrainer.Failure.microphone }
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement)
        try session.setActive(true)
        #endif
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(OwnVoiceAudio.sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target) else { throw OwnVoiceTrainer.Failure.microphone }
        let tap = Self.tap(converter: converter, target: target, deliver: deliver)
        let frames = AVAudioFrameCount((format.sampleRate * 0.1).rounded(.up))
        // A fresh engine and its own native format, as the non-throwing tap needs.
        input.installTap(onBus: 0, bufferSize: frames, format: format, block: tap)
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); throw error }
        self.engine = engine
    }
    func stop() {
        if let engine { engine.stop(); engine.inputNode.removeTap(onBus: 0) }
        engine = nil
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    /// Built outside the main actor: AVAudioEngine calls it on its own audio queue.
    nonisolated private static func tap(converter: AVAudioConverter, target: AVAudioFormat,
                                        deliver: @escaping @MainActor ([Float]) -> Void) -> AVAudioNodeTapBlock {
        let box = ConverterBox(converter)
        return { buffer, _ in
            let ratio = target.sampleRate / buffer.format.sampleRate
            guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64) else { return }
            var fed = false
            var error: NSError?
            box.converter.convert(to: out, error: &error) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true; status.pointee = .haveData; return buffer
            }
            guard error == nil, let data = out.floatChannelData, out.frameLength > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(out.frameLength)))
            Task { @MainActor in deliver(samples) }
        }
    }
    private final class ConverterBox: @unchecked Sendable { let converter: AVAudioConverter; init(_ c: AVAudioConverter) { converter = c } }

    static func microphoneAllowed() async -> Bool {
        #if os(iOS)
        if AVAudioApplication.shared.recordPermission == .granted { return true }
        return await AVAudioApplication.requestRecordPermission()
        #else
        return await AVCaptureDevice.requestAccess(for: .audio)
        #endif
    }
}

/// On-device recognition for checking the takes; nothing is sent anywhere.
struct OwnVoiceTranscriber: OwnVoiceChecking {
    enum Failure: Error, LocalizedError {
        case notAllowed, unavailable
        var errorDescription: String? {
            switch self {
            case .notAllowed: "Allow speech recognition so your takes can be checked on this device."
            case .unavailable: "On-device English speech recognition isn't available here."
            }
        }
    }
    /// Ignores `expected`: the check compares afterwards, so recognition isn't nudged.
    func transcript(of samples: [Float], expected _: String) async throws -> String {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            status = await withCheckedContinuation { continuation in SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) } }
        }
        guard status == .authorized else { throw Failure.notAllowed }
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable,
              recognizer.supportsOnDeviceRecognition,
              let format = AVAudioFormat(standardFormatWithSampleRate: Double(OwnVoiceAudio.sampleRate), channels: 1) else { throw Failure.unavailable }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.requiresOnDeviceRecognition = true
        request.shouldReportPartialResults = false
        let chunk = OwnVoiceAudio.sampleRate
        for start in stride(from: 0, to: samples.count, by: chunk) {
            let count = min(chunk, samples.count - start)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)) else { continue }
            buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { buffer.floatChannelData?[0].update(from: $0.baseAddress! + start, count: count) }
            request.append(buffer)
        }
        request.endAudio()
        return try await withCheckedThrowingContinuation { continuation in
            let once = ResumeOnce()
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result, result.isFinal { once.run { continuation.resume(returning: result.bestTranscription.formattedString) } }
                else if error != nil { once.run { continuation.resume(returning: result?.bestTranscription.formattedString ?? "") } }
            }
            // Never wait forever on a stuck recognizer.
            DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                once.run { task.cancel(); continuation.resume(returning: "") }
            }
        }
    }
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock(); private var done = false
        func run(_ body: () -> Void) { lock.lock(); defer { lock.unlock() }; guard !done else { return }; done = true; body() }
    }
}

// MARK: - The trainer

/// Runs a "Your voice" session with real audio: the room check, each take with live level
/// feedback, the on-device checks, cleaning up and building the reference, and "Hear it".
/// Nothing is written until Save; the takes live in memory and are dropped when the sheet closes.
@MainActor @Observable final class OwnVoiceTrainer {
    enum Failure: Error, LocalizedError {
        case microphone
        var errorDescription: String? { "Allow the microphone to record your voice." }
    }
    private(set) var session: OwnVoiceSession
    /// Live input level for the meter, 0…1.
    private(set) var level: Float = 0
    private(set) var feedback: OwnVoiceAudio.LevelFeedback = .listening
    /// The take in progress hit the top of the range.
    private(set) var clipping = false
    private(set) var elapsed: TimeInterval = 0
    /// A problem that isn't about one take (the microphone, recognition).
    private(set) var problem: String?
    private(set) var reference: OwnVoiceAudio.Reference?
    private(set) var noiseReduction: OwnVoiceAudio.NoiseReduction = .none
    private(set) var hearing = false

    @ObservationIgnored private let capture: OwnVoiceCapture
    @ObservationIgnored private let checker: OwnVoiceChecking
    @ObservationIgnored private let length: OwnVoiceAudio.ReferenceLength
    @ObservationIgnored private var buffer: [Float] = []
    @ObservationIgnored private var recent: [Float] = []
    @ObservationIgnored private var recentPeak: Float = 0
    @ObservationIgnored private var target: Target?
    @ObservationIgnored private var limitTask: Task<Void, Never>?
    @ObservationIgnored private var buildTask: Task<Void, Never>?
    @ObservationIgnored private var noise: [Float] = []
    @ObservationIgnored private var takeAudio: [Int: [Float]] = [:]
    @ObservationIgnored private var consentAudio: [Float] = []
    @ObservationIgnored private let player = SpeechPlayer()
    @ObservationIgnored private var hearTask: Task<Void, Never>?
    private enum Target: Equatable { case room, take(Int), consent }

    static let previewLine = "Hi, it's me. This is how your KemoSabe will sound when it reads a reply."

    init(capture: OwnVoiceCapture? = nil, checker: OwnVoiceChecking? = nil, passages: [OwnVoiceEnrollment.Passage]? = nil,
         length: OwnVoiceAudio.ReferenceLength = .pocketTTS) {
        var generator = SystemRandomNumberGenerator()
        #if DEBUG
        let stubbed = OwnVoiceStub.isActive
        self.capture = capture ?? (stubbed ? OwnVoiceStub.Capture() : OwnVoiceMicrophone())
        self.checker = checker ?? (stubbed ? OwnVoiceStub.Checker() : OwnVoiceChecks.make())
        #else
        self.capture = capture ?? OwnVoiceMicrophone()
        self.checker = checker ?? OwnVoiceChecks.make()
        #endif
        self.length = length
        session = OwnVoiceSession(passages: passages ?? OwnVoiceEnrollment.startingPassages(using: &generator))
    }

    var isRecording: Bool { target != nil }

    // MARK: Room check

    func checkRoom() async {
        guard !session.isBusy else { return }
        session.beginRoomCheck()
        await begin(.room, limit: OwnVoiceEnrollment.quietCheckSeconds)
    }
    func continueInNoisyRoom() { session.continueInNoisyRoom() }

    // MARK: Takes

    func record(_ id: Int) async {
        problem = nil
        guard session.beginTake(id) else { return }
        await begin(.take(id), limit: OwnVoiceEnrollment.maximumTakeSeconds)
    }
    func recordConsent() async {
        problem = nil
        guard session.beginConsent() else { return }
        await begin(.consent, limit: OwnVoiceEnrollment.maximumConsentSeconds)
    }
    func redo(_ id: Int) {
        stopHearing()
        takeAudio[id] = nil
        session.redo(id)
    }
    /// Adds one more passage and, once it's read and checked, rebuilds the voice with it.
    func recordMore() {
        stopHearing()
        var generator = SystemRandomNumberGenerator()
        guard let next = OwnVoiceEnrollment.nextPassage(after: session.takes.map(\.passage), using: &generator) else { return }
        session.recordMore(next)
    }
    /// Throws everything away and begins again with new passages.
    func startOver() {
        discard()
        var generator = SystemRandomNumberGenerator()
        session = OwnVoiceSession(passages: OwnVoiceEnrollment.startingPassages(using: &generator))
    }

    /// Stops the current recording and moves on.
    func stop() {
        guard let target else { return }
        limitTask?.cancel(); limitTask = nil
        capture.stop()
        self.target = nil
        let audio = buffer
        buffer = []; level = 0; recent = []; recentPeak = 0
        switch target {
        case .room:
            noise = audio
            session.roomMeasured(OwnVoiceAudio.roomNoise(audio))
        case .take(let id):
            let report = OwnVoiceAudio.report(audio)
            session.takeRecorded(id, report: report)
            guard session.takes.first(where: { $0.id == id })?.status == .checking,
                  let text = session.takes.first(where: { $0.id == id })?.passage.text else { return }
            takeAudio[id] = audio
            Task { await check(take: id, audio: audio, text: text) }
        case .consent:
            consentAudio = audio
            session.consentRecorded(seconds: Double(audio.count) / Double(OwnVoiceAudio.sampleRate))
            guard session.consent == .checking else { return }
            Task { await checkConsent(audio) }
        }
    }

    /// Stops everything and drops every take (the sheet closing, or Start over).
    func discard() {
        limitTask?.cancel(); limitTask = nil
        buildTask?.cancel(); buildTask = nil
        if target != nil { capture.stop() }
        stopHearing()
        target = nil; buffer = []; noise = []; takeAudio = [:]; consentAudio = []
        reference = nil; level = 0; elapsed = 0; clipping = false; problem = nil
    }

    private func begin(_ next: Target, limit: TimeInterval) async {
        stopHearing()
        buffer = []; recent = []; recentPeak = 0; elapsed = 0; clipping = false; feedback = .listening
        target = next
        do {
            try await capture.start { [weak self] samples in self?.receive(samples) }
        } catch {
            target = nil
            let message = (error as? LocalizedError)?.errorDescription ?? "The microphone couldn't start. Try again."
            problem = message
            switch next {
            case .room: session.cancelRoomCheck()
            case .take(let id): session.takeFailed(id, message: message)
            case .consent: session.consentFailed(message)
            }
            return
        }
        limitTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(limit))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    private func receive(_ samples: [Float]) {
        guard target != nil else { return }
        buffer += samples
        elapsed = Double(buffer.count) / Double(OwnVoiceAudio.sampleRate)
        let peak = OwnVoiceAudio.peak(samples)
        if peak >= OwnVoiceAudio.clipLevel, target != .room { clipping = true }
        recent += OwnVoiceAudio.frameLevels(samples)
        if recent.count > 50 { recent.removeFirst(recent.count - 50) }
        recentPeak = max(recentPeak * 0.9, peak)
        let loudest = recent.suffix(5).max() ?? -120
        level = max(0, min(1, (loudest + 60) / 60))
        if target != .room { feedback = OwnVoiceAudio.feedback(recentLevels: recent, recentPeak: recentPeak) }
        // A stand-in capture delivers faster than real time; the limit still holds.
        if target == .room, elapsed >= OwnVoiceEnrollment.quietCheckSeconds { stop() }
        else if elapsed >= OwnVoiceEnrollment.maximumTakeSeconds { stop() }
    }

    private func check(take id: Int, audio: [Float], text: String) async {
        do {
            let heard = try await checker.transcript(of: audio, expected: text)
            session.takeChecked(id, heard: heard)
            if session.takes.first(where: { $0.id == id })?.status != .accepted { takeAudio[id] = nil }
        } catch {
            takeAudio[id] = nil
            session.takeFailed(id, message: (error as? LocalizedError)?.errorDescription ?? "That take couldn't be checked.")
        }
        buildIfReady()
    }
    private func checkConsent(_ audio: [Float]) async {
        do {
            session.consentChecked(heard: try await checker.transcript(of: audio, expected: OwnVoiceEnrollment.consentLine))
        } catch {
            session.consentFailed((error as? LocalizedError)?.errorDescription ?? "The consent line couldn't be checked.")
        }
        if session.consent != .accepted { consentAudio = [] }
        buildIfReady()
    }

    /// Cleans up the accepted takes off the main thread and joins the best into the reference.
    private func buildIfReady() {
        guard session.stage == .building, buildTask == nil else { return }
        let revision = session.revision
        let inputs = session.acceptedTakes.compactMap { take in takeAudio[take.id].map { (take.passage.text, $0) } }
        let room = session.roomNoise ?? .init(decibels: -120), noise = self.noise, length = self.length
        buildTask = Task { [weak self] in
            let built = await Task.detached(priority: .userInitiated) { () -> (OwnVoiceAudio.Reference, OwnVoiceAudio.NoiseReduction) in
                let processed = inputs.map { OwnVoiceAudio.process($0.1, text: $0.0, room: room, noiseSample: noise) }
                return (OwnVoiceAudio.reference(from: processed, length: length), processed.first?.noiseReduction ?? .none)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.buildTask = nil
            guard self.session.revision == revision else { self.buildIfReady(); return }
            self.reference = built.0
            self.noiseReduction = built.1
            self.session.built(revision: revision)
        }
    }

    // MARK: Hear it

    /// Plays a sample sentence in the new voice, before anything is saved.
    func hearIt(model: VoiceModelStore) {
        if hearing { stopHearing(); return }
        guard let reference, session.stage == .preview else { return }
        hearing = true
        #if DEBUG
        if OwnVoiceStub.isActive {
            hearTask = Task { [weak self] in try? await Task.sleep(for: .seconds(2)); self?.hearing = false }
            return
        }
        #endif
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
        try? AVAudioSession.sharedInstance().setActive(true)
        #endif
        let engine = OwnVoicePreviewEngine(store: model, reference: reference.samples)
        player.play(Self.previewLine, engine: engine, voice: nil) { [weak self] error, _ in
            self?.hearing = false
            if let error { self?.problem = (error as? LocalizedError)?.errorDescription ?? "Your voice couldn't play." }
        }
    }
    func stopHearing() {
        hearTask?.cancel(); hearTask = nil
        player.stop()
        hearing = false
    }

    // MARK: Saving

    /// The finished session as something the store can save: the reference and the consent
    /// recording as WAV files in the temporary folder, and the record. Nil until the voice is built.
    func finishedTake(model: String) throws -> OwnVoiceTake? {
        guard session.stage == .preview, let reference, !consentAudio.isEmpty else { return nil }
        let folder = FileManager.default.temporaryDirectory
        let sample = folder.appendingPathComponent("own-voice-\(UUID().uuidString).wav")
        let consent = folder.appendingPathComponent("own-voice-\(UUID().uuidString).wav")
        try OwnVoiceStore.write(SpeechAudio.wav(reference.samples, sampleRate: OwnVoiceAudio.sampleRate), to: sample)
        try OwnVoiceStore.write(SpeechAudio.wav(OwnVoiceAudio.normalizeLoudness(consentAudio), sampleRate: OwnVoiceAudio.sampleRate), to: consent)
        let takes = session.acceptedTakes
        let record = OwnVoiceRecord(
            createdAt: .now, passage: takes.first?.passage.text ?? "", consentLine: OwnVoiceEnrollment.consentLine,
            heardPassage: takes.first?.heard ?? "", heardConsent: session.heardConsent ?? "",
            sampleSeconds: reference.seconds, model: model,
            passages: takes.map(\.passage.text), heardPassages: takes.map { $0.heard ?? "" }, reference: reference.segments,
            roomNoiseDecibels: session.roomNoise?.decibels, noiseReduction: noiseReduction)
        return OwnVoiceTake(sampleFile: sample, consentFile: consent, record: record)
    }
}

/// The voice being set up, before it's saved: the same on-device model prompted with the
/// reference in memory. Used only for "Hear it" in the set-up sheet.
@MainActor final class OwnVoicePreviewEngine: SpeechEngine {
    let kind = SpeechEngineKind.ownVoice
    let destination: String? = nil
    let store: VoiceModelStore
    let reference: [Float]
    init(store: VoiceModelStore, reference: [Float]) { self.store = store; self.reference = reference }
    var isAvailable: Bool { store.isInstalled && NeuralSpeechRuntime.isSupported }
    var voices: [SpeechVoiceOption] { [] }
    func synthesize(_ text: String, voice _: String?) async throws -> SpeechAudio {
        guard store.isInstalled else { throw SpeechEngineError.notInstalled }
        guard NeuralSpeechRuntime.canRunNow else { throw SpeechEngineError.inBackground }
        let prepared = SpeechText.prepared(text)
        guard !prepared.isEmpty else { throw SpeechEngineError.emptyText }
        return try await NeuralSpeechWorker.shared.ownVoiceSamples(prepared, reference: reference, folder: store.folder)
    }
}

#if DEBUG
/// UI tests only (`--ui-testing --stub-own-voice`): a stand-in microphone that plays a
/// synthetic voice (a hum with syllables, never a person) faster than real time, and a checker
/// that hears exactly the line on screen. `--stub-noisy-room` makes the room check noisy.
enum OwnVoiceStub {
    static var isActive: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--stub-own-voice")
    }
    static var noisyRoom: Bool { ProcessInfo.processInfo.arguments.contains("--stub-noisy-room") }

    @MainActor final class Capture: OwnVoiceCapture {
        private var task: Task<Void, Never>?
        private var calls = 0
        func start(_ deliver: @escaping @MainActor ([Float]) -> Void) async throws {
            calls += 1
            let room = calls == 1
            let rate = Float(OwnVoiceAudio.sampleRate)
            task = Task { @MainActor in
                var position = 0
                while !Task.isCancelled {
                    let chunk = (0..<(OwnVoiceAudio.sampleRate / 5)).map { offset -> Float in
                        let t = Float(position + offset) / rate
                        let hiss = sin(t * 12_345.6) * sin(t * 777.7)
                        if room { return (OwnVoiceStub.noisyRoom ? 0.02 : 0.0003) * hiss }
                        let syllables = max(0, sin(2 * .pi * 3.5 * t))
                        let voice = (1...6).reduce(Float(0)) { $0 + sin(2 * .pi * 140 * Float($1) * t) / Float($1) }
                        return 0.12 * syllables * voice + 0.0003 * hiss
                    }
                    position += chunk.count
                    deliver(chunk)
                    try? await Task.sleep(for: .milliseconds(40))
                }
            }
        }
        func stop() { task?.cancel(); task = nil }
    }
    struct Checker: OwnVoiceChecking {
        func transcript(of _: [Float], expected: String) async throws -> String {
            try? await Task.sleep(for: .milliseconds(300))
            return expected
        }
    }
}
#endif

extension OwnVoiceEnrollment {
    /// Setting up needs the GPU the model runs on; UI tests open the sheet with the stand-in.
    static var canSetUp: Bool {
        #if DEBUG
        if OwnVoiceStub.isActive { return true }
        #endif
        return NeuralSpeechRuntime.isSupported
    }
}
