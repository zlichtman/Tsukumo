import Foundation
import Observation
import TsukumoCore
import TsukumoPolicy
import TsukumoSystemOne
import TsukumoEngines
import TsukumoVoice
#if canImport(CoreML)
import CoreML
#endif

// System One as both apps run it (Settings, Models, System One; design/UI-GUIDE.md): Laya on this device
// first, then the hosted models the person turned on, in the order they dragged them into, then the
// fallback, the bot last spoken to. `SystemOneCenter` keeps the settings, the keys (this device's
// Keychain only), Laya's download, the journal, the marks, and the personal layer, and hands the chat
// its `SystemOneRouter`. Each app draws its own page from it with `SystemOneCopy`, so the iPhone and the
// Mac say the same things in the same order (AGENTS.md rule 9).

// MARK: Laya's download

public extension VoiceModelPack {
    /// convaiinnovations/laya at c5d78730 (Apache-2.0), the base English checkpoint, as converted to Core ML
    /// by aac6fef/laya-coreml at fff78b2d (ported from the old app's `LayaModel.swift`). The hashes are the
    /// conversion's own manifest, checked again on September 27 and October 3, 2026. Attribution:
    /// TsukumoKit/LAYA-NOTICE.md.
    static let laya = VoiceModelPack(id: "laya-coreml", title: "Laya", version: 1, sources: [
        .init(repository: "aac6fef/laya-coreml", revision: "fff78b2d9750c6b748fe8c90fcbf8bed0a1522a9",
              license: "Apache-2.0 (convaiinnovations/laya, laya-coreml)", folder: "model", files: [
            .init(path: "coreml_config.json", size: 2068, sha256: "990b99a736f64c87da57b203d7953c4c1c79c18b615580db894e9c24bda42ab5"),
            .init(path: "rl_agent_config.json", size: 745, sha256: "ae287b56bbcf5f8c4f4541ae9dfd00c914c4c48b940b8398c3058af37ba92bbd"),
            .init(path: "tokenizer/tokenizer.json", size: 3583228, sha256: "6c8aaa9a542084f2457eab775d4eeb51f92a70c0fd9de28d5edb0ddec3c08d30"),
            .init(path: "tokenizer/tokenizer_config.json", size: 308, sha256: "50044de60daaa73df97d262e15a40d4faf0160e7d742df64b377877a1320dd12"),
            .init(path: "model.mlpackage/Manifest.json", size: 617, sha256: "41bab6e532f727e8809c76906f41026a48ef9b276c56068b3d68270a13981e20"),
            .init(path: "model.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 872598, sha256: "dc6a6383ad4a2f04f7525924b0dfb830429dedc44387f143a2f87782e39aeab0"),
            .init(path: "model.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 842750912, sha256: "5872b9f6530c20a845b69c0cb75aa141e9c89ffdd5f36529c3708cec9b7a7a83"),
            .init(path: "LICENSE", size: 10173, sha256: "a6cba85bc92e0cff7a450b1d873c0eaa2e9fc96bf472df0247a26bec77bf3ff9"),
            .init(path: "NOTICE", size: 1209, sha256: "60928ba6b42ad90c048a88791c34c60826e565d279909095ade614c08c5b8ca8"),
        ]),
    ])
    /// "847 MB": every pinned file (the weights alone are 843 MB).
    var megabytesLabel: String { "\(Int((Double(totalBytes) / 1_000_000).rounded())) MB" }
}

/// Where Laya is on this device: the download (the voice models' pinned store), compiling once for this
/// device, then ready.
public enum LayaState: Equatable, Sendable {
    case notDownloaded, waitingForWiFi, downloading(Double), verifying, preparing, ready, failed(String)
    public var isBusy: Bool {
        switch self {
        case .waitingForWiFi, .downloading, .verifying, .preparing: true
        default: false
        }
    }
}

/// Laya's files on this device: downloaded after the person's consent (pinned files from huggingface.co,
/// each checked by size and SHA-256 before anything is installed), compiled once, and loaded as soon as
/// it's verified and at every launch, so the cold start (about 8 seconds) never lands on a message.
@MainActor @Observable public final class LayaModel {
    /// Written into the compiled model once it's ready.
    public nonisolated static let compiledMarker = "tsukumo-compiled.txt"
    /// The old KemoSabe app's marker, for a compiled copy it left on this Mac.
    public nonisolated static let oldCompiledMarker = "kemo-compiled.txt"

    public let store: VoiceModelStore
    public private(set) var preparing = false
    public private(set) var adopting = false
    public private(set) var problem: String?
    public private(set) var ready = false

    @ObservationIgnored private let prepareModel: @Sendable (URL) async throws -> Void
    @ObservationIgnored private let unloadModel: @Sendable () async -> Void
    @ObservationIgnored private let seeds: [URL]

    /// `root` holds the pack's folder; `prepare` compiles a verified download and loads it; `seeds` are
    /// folders where the old app may have left a compiled Laya (read only, used after the same checks).
    public init(root: URL, transport: any VoiceModelTransport = URLSessionVoiceModelTransport(), seeds: [URL] = [],
                prepare: @escaping @Sendable (URL) async throws -> Void, unload: @escaping @Sendable () async -> Void = {}) {
        store = VoiceModelStore(pack: .laya, root: root, transport: transport)
        self.prepareModel = prepare; self.unloadModel = unload; self.seeds = seeds
        ready = Self.isReady(at: directory)
    }

    /// The folder `CoreMLLayaProvider` reads: the pinned files, then the compiled model.
    public var directory: URL { store.folder.appendingPathComponent("model", isDirectory: true) }
    public var sizeLabel: String { store.pack.megabytesLabel }

    /// Compiled for this device, with the configuration and tokenizer beside it.
    public nonisolated static func isReady(at directory: URL) -> Bool {
        let files = FileManager.default
        let compiled = directory.appendingPathComponent("model.mlmodelc")
        return [compiledMarker, oldCompiledMarker].contains { files.fileExists(atPath: compiled.appendingPathComponent($0).path) }
            && ["coreml_config.json", "rl_agent_config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"]
                .allSatisfy { files.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    public var state: LayaState {
        if ready { return .ready }
        if preparing { return .preparing }
        if adopting { return .verifying }
        if let problem { return .failed(problem) }
        switch store.state {
        case .notDownloaded: return .notDownloaded
        case .waitingForWiFi: return .waitingForWiFi
        case .downloading(let fraction): return .downloading(fraction)
        case .verifying: return .verifying
        case .installed: return .preparing
        case .failed(let message): return .failed(message)
        }
    }

    /// At launch: loads a ready Laya ahead of the first message, and finishes a preparation that stopped.
    public func start() {
        refresh()
        if ready { let prepare = prepareModel, directory = self.directory; Task.detached(priority: .utility) { try? await prepare(directory) } }
    }

    public func refresh() {
        store.refresh()
        ready = Self.isReady(at: directory)
        if !ready, store.isInstalled { prepare() }
    }

    /// After the person agreed: a verified compiled copy the old app left is used, or the pinned files are
    /// downloaded (resuming what's already verified); then it's prepared as soon as it's verified.
    public func download() {
        problem = nil
        guard !ready, !state.isBusy else { return }
        if store.isInstalled { prepare(); return }
        if let seed = seeds.lazy.map({ $0.appendingPathComponent(VoiceModelPack.laya.id).appendingPathComponent("model") }).first(where: Self.isReady) {
            adopt(seed)
            return
        }
        store.download()
        Task { [weak self] in
            await self?.store.waitUntilDone()
            self?.refresh()
        }
    }

    /// Compiles the verified download once for this device, then loads it.
    public func prepare() {
        guard !ready, !preparing, store.isInstalled || Self.isReady(at: directory) else { return }
        preparing = true; problem = nil
        let directory = self.directory, prepare = prepareModel
        Task {
            do { try await prepare(directory) } catch { problem = SystemOneCopy.layaPrepareFailed }
            preparing = false
            ready = Self.isReady(at: directory)
            if !ready, problem == nil { problem = SystemOneCopy.layaPrepareFailed }
        }
    }

    /// Removes Laya from this device. Marks and the personal layer stay.
    public func remove() {
        let unload = unloadModel
        Task { await unload() }
        store.delete()
        ready = false; problem = nil
    }

    /// A compiled copy the old KemoSabe app left: used only when its configuration, tokenizer, license,
    /// notice, and weights all pass the same pinned size and SHA-256 checks (Core ML's compiler keeps the
    /// weights file as it is). The copy is a clone on APFS; the old folder is never changed.
    private func adopt(_ seed: URL) {
        adopting = true
        let target = directory, staging = store.root.appendingPathComponent(VoiceModelPack.laya.id + ".adopt", isDirectory: true)
        Task {
            let verified = await Task.detached(priority: .userInitiated) { Self.verifySeed(seed) }.value
            var done = false
            if verified {
                let files = FileManager.default
                do {
                    try? files.removeItem(at: staging)
                    try files.createDirectory(at: staging, withIntermediateDirectories: true)
                    try files.copyItem(at: seed, to: staging.appendingPathComponent("model"))
                    let marker = staging.appendingPathComponent("model/model.mlmodelc").appendingPathComponent(Self.compiledMarker)
                    if !files.fileExists(atPath: marker.path) { try Data("Laya English · c5d7873\n".utf8).write(to: marker) }
                    try files.createDirectory(at: store.root, withIntermediateDirectories: true)
                    try? VoiceModelFiles.excludeFromBackup(store.root)
                    try? files.removeItem(at: store.folder)
                    try files.moveItem(at: staging, to: store.folder)
                    done = true
                } catch {
                    try? files.removeItem(at: staging)
                }
            }
            adopting = false
            if done, Self.isReady(at: target) {
                // Loaded now, like a fresh download.
                ready = false
                preparing = true
                let prepare = prepareModel
                do { try await prepare(target) } catch { problem = SystemOneCopy.layaPrepareFailed }
                preparing = false
                ready = Self.isReady(at: target)
            } else {
                // Not usable: download it as usual.
                store.download()
                await store.waitUntilDone()
                refresh()
            }
        }
    }

    nonisolated static func verifySeed(_ seed: URL) -> Bool {
        let pins = VoiceModelPack.laya.files.map(\.file)
        let plain = pins.filter { !$0.path.hasPrefix("model.mlpackage/") }
        guard let weights = pins.first(where: { $0.path.hasSuffix("weights/weight.bin") }) else { return false }
        do {
            for file in plain { try VoiceModelFiles.verify(seed.appendingPathComponent(file.path), against: file) }
            try VoiceModelFiles.verify(seed.appendingPathComponent("model.mlmodelc/weights/weight.bin"), against: weights)
            return true
        } catch {
            return false
        }
    }
}

#if canImport(CoreML)
public extension LayaModel {
    /// Laya with the real Core ML provider: compiled once (`model.mlpackage` becomes `model.mlmodelc`, and
    /// the marker is written), then loaded into memory.
    convenience init(root: URL, provider: CoreMLLayaProvider, transport: any VoiceModelTransport = URLSessionVoiceModelTransport(), seeds: [URL] = []) {
        self.init(root: root, transport: transport, seeds: seeds, prepare: { directory in
            let compiled = try await CoreMLLayaProvider.compiledModel(in: directory)
            let marker = compiled.appendingPathComponent(LayaModel.compiledMarker)
            if !FileManager.default.fileExists(atPath: marker.path) { try Data("Laya English · c5d7873\n".utf8).write(to: marker) }
            try await provider.prepare()
        }, unload: { await provider.unload() })
    }
}
#endif

// MARK: The center

/// System One's settings, keys, Laya, journal, marks, and personal layer on this device, and the router
/// the chat uses.
@MainActor @Observable public final class SystemOneCenter {
    /// The host may refuse persisted mutations while its store is recovering.
    @ObservationIgnored public var canWrite: @MainActor () -> Bool = { true }
    public private(set) var settings: SystemOneSettings
    public let laya: LayaModel?
    /// The journal's records, newest last (read again with `reload()`).
    public private(set) var records: [DecisionRecord] = []
    public private(set) var marks: [MarkedDecision] = []
    public private(set) var personal: PersonalLayer?
    /// How the personal layer for `route` trained last.
    public private(set) var report: PersonalReport?
    /// The hosted models with a key in this device's Keychain.
    public private(set) var keyed: Set<HostedProviderKind> = []
    /// A Test's result line, by provider ("laya", or a hosted kind's id).
    public private(set) var testResults: [String: String] = [:]
    public private(set) var testing: Set<String> = []
    public let deviceName: String

    @ObservationIgnored public let journal: DecisionJournal
    @ObservationIgnored private let keys: any APIKeyStore
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let folder: URL?
    @ObservationIgnored private let local: (any DecisionProvider)?

    /// `folder` keeps `system-one.json` (the settings, no keys), `system-one-decisions.json` (the journal),
    /// `system-one-marks.json`, and `system-one-personal.json`; nil keeps them in memory. `local` is Laya's
    /// provider, asked once `laya` is ready.
    public init(folder: URL?, keys: any APIKeyStore, deviceName: String, laya: LayaModel? = nil, local: (any DecisionProvider)? = nil,
                session: URLSession = .shared) {
        self.folder = folder; self.keys = keys; self.deviceName = deviceName; self.laya = laya; self.local = local; self.session = session
        journal = DecisionJournal(url: folder?.appendingPathComponent("system-one-decisions.json"))
        settings = Self.read(SystemOneSettings.self, folder, "system-one.json") ?? SystemOneSettings()
        marks = Self.read([MarkedDecision].self, folder, "system-one-marks.json") ?? []
        personal = Self.read(PersonalLayer.self, folder, "system-one-personal.json")
        keyed = Set(HostedProviderKind.allCases.filter { ((try? keys.read($0.keyID)) ?? nil).map(SystemOneAPIProvider.isKey) ?? false })
    }

    // MARK: What the chat uses

    /// Laya (when ready), then each hosted model that's on, agreed to, configured, and keyed, in order.
    public func providers() -> SystemOneProviders {
        let keys = self.keys
        let remotes = settings.remotes(key: { kind in (try? keys.read(kind.keyID)) ?? nil }, session: session)
        return SystemOneProviders(local: laya?.ready == true ? local : nil, remotes: remotes, personal: personal, journal: journal)
    }

    /// The chat's router: untagged messages and each turn's context, with the providers as they are now.
    public func router() -> SystemOneRouter {
        SystemOneRouter { [weak self] in await self?.providers() ?? .none }
    }

    // MARK: Hosted models

    public func setting(_ kind: HostedProviderKind) -> HostedProviderSetting { settings[kind] }
    public func hasKey(_ kind: HostedProviderKind) -> Bool { keyed.contains(kind) }
    public func status(_ kind: HostedProviderKind) -> ProviderStatus { settings.status(kind, hasKey: hasKey(kind)) }

    /// Saves the account ID, model, or address. A changed host turns the model off until it's agreed to again.
    public func update(_ setting: HostedProviderSetting) {
        guard canWrite() else { return }
        var setting = setting
        if setting.on, setting.consentedHost != setting.endpoint?.host { setting.on = false; setting.consentedHost = nil }
        settings[setting.kind] = setting
        save()
    }
    /// Saves a key into this device's Keychain (never synced).
    public func saveKey(_ key: String, for kind: HostedProviderKind) throws {
        guard canWrite() else { throw CocoaError(.fileWriteNoPermission) }
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SystemOneAPIProvider.isKey(key) else { throw SystemOneSetupError.badKey }
        try keys.save(key, for: kind.keyID)
        keyed.insert(kind)
    }
    /// Turns a hosted model on after the person confirmed sending to its host (`HostedConsent`).
    public func turnOn(_ kind: HostedProviderKind) {
        guard canWrite() else { return }
        var setting = settings[kind]
        guard let host = setting.endpoint?.host, hasKey(kind) else { return }
        setting.on = true; setting.consentedHost = host
        settings[kind] = setting
        save()
    }
    public func turnOff(_ kind: HostedProviderKind) {
        guard canWrite() else { return }
        var setting = settings[kind]
        setting.on = false; setting.consentedHost = nil
        settings[kind] = setting
        save()
    }
    /// Removes its key, account ID, address, and agreement. Nothing more goes to its host.
    public func remove(_ kind: HostedProviderKind) {
        guard canWrite() else { return }
        try? keys.remove(kind.keyID)
        keyed.remove(kind)
        settings[kind] = HostedProviderSetting(kind: kind)
        testResults[kind.id] = nil
        save()
    }
    /// Drag to reorder: `kind` takes `target`'s place.
    public func move(_ kind: HostedProviderKind, to target: HostedProviderKind) {
        guard canWrite() else { return }
        settings.move(kind, to: target); save()
    }
    public func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard canWrite() else { return }
        settings.move(fromOffsets: source, toOffset: destination); save()
    }

    // MARK: The status line

    /// "Laya, then Cloudflare Clef-flash, when they’re sure; otherwise the bot you last talked to."
    public var statusLine: String {
        var names: [String] = []
        if laya?.ready == true { names.append("Laya") }
        names += settings.hosted.filter { status($0.kind) == .ready }.map(\.kind.title)
        guard !names.isEmpty else { return SystemOneCopy.nothingOn }
        return names.joined(separator: ", then ")
            + (names.count == 1 ? ", when it’s sure; otherwise the bot you last talked to." : ", when they’re sure; otherwise the bot you last talked to.")
    }
    /// "Last: Laya picked it, 2 min. ago" from the journal.
    public var lastDecisionLine: String? {
        guard let last = records.last else { return nil }
        let when = last.at.formatted(.relative(presentation: .named))
        return last.decidedBy == .fallback ? "Last: unsure, so the bot you last talked to, \(when)" : "Last: \(SystemOneCopy.name(last.decidedBy)) decided, \(when)"
    }

    // MARK: Journal, marks, personal layer

    public func reload() async {
        records = await journal.all()
    }

    /// Recent decisions to show, newest first.
    public var recent: [DecisionRecord] { Array(records.suffix(12).reversed()) }
    public func mark(for record: DecisionRecord) -> MarkedDecision? { marks.first { $0.id == record.id } }

    /// A decision Laya scored can be marked: its first question, the option shown, and Laya's base.
    public static func markable(_ record: DecisionRecord) -> (question: DecisionRecord.Question, shown: Int)? {
        guard let question = record.questions.first, let laya = question.laya, laya.count == question.options.count, question.options.count >= 2 else { return nil }
        let shown = question.answer ?? laya.indices.max { laya[$0] < laya[$1] } ?? 0
        return (question, shown)
    }

    /// Right (`correct` is what was shown) or Wrong (another option was right). Trains the personal
    /// layer again; it turns on only when it beats Laya's base on the newest marks.
    public func mark(_ record: DecisionRecord, correct: Int) {
        guard canWrite() else { return }
        guard let (question, shown) = Self.markable(record), let laya = question.laya, question.options.indices.contains(correct) else { return }
        marks.removeAll { $0.id == record.id }
        marks.append(MarkedDecision(id: record.id, at: record.at, kind: record.kind, questionID: question.id, options: question.options,
                                    laya: laya, shown: shown, correct: correct))
        retrain()
    }
    public func unmark(_ record: DecisionRecord) {
        guard canWrite() else { return }
        marks.removeAll { $0.id == record.id }
        retrain()
    }
    private func retrain() {
        var heads: [DecisionKind: PersonalHead] = [:]
        var routeReport: PersonalReport?
        for kind in DecisionKind.allCases {
            guard let trained = PersonalTraining.train(kind, marks: marks) else { continue }
            if kind == .route { routeReport = trained.report }
            if let head = trained.head { heads[kind] = head }
        }
        personal = heads.isEmpty ? nil : PersonalLayer(heads: heads)
        report = routeReport
        write(marks, "system-one-marks.json")
        if let personal { write(personal, "system-one-personal.json") } else if let folder { try? FileManager.default.removeItem(at: folder.appendingPathComponent("system-one-personal.json")) }
    }
    /// "Your layer: 12 of 30 marks to train", or how it did.
    public var personalLine: String {
        let routeMarks = marks.filter { $0.kind == .route }.count
        if let report {
            return report.turnedOn
                ? "On: it got \(report.personalRight) of the newest \(report.heldOut) right, Laya alone \(report.baseRight)."
                : "Off: on the newest \(report.heldOut) it got \(report.personalRight) right, not enough more than Laya’s \(report.baseRight)."
        }
        return "\(min(routeMarks, PersonalTraining.minimumExamples)) of \(PersonalTraining.minimumExamples) routing marks to train it."
    }

    // MARK: Test

    /// One sample decision (fixed words, nothing of yours): which of three made-up bots should answer.
    public nonisolated static let sample = DecisionRequest(
        state: "Can you help me plan a birthday dinner for Sam on Friday?",
        questions: [DecisionQuestion(id: "route", kind: .choice, instruction: "Which of the owner's bots should answer this message? Each choice is a bot and its job.",
                                     options: ["Chef: Plans meals and dinners", "Pip: Codes in my projects", "Juniper: Tracks my class deadlines"])],
        deadline: .distantFuture)

    /// Runs the sample on Laya ("laya") or a hosted model, through the same policy and threshold as a
    /// real message, and keeps a line saying how it went. A hosted model must be on (agreed to) first.
    public func test(_ id: String) async {
        let providers: SystemOneProviders
        let timeout: TimeInterval
        if id == "laya" {
            guard laya?.ready == true, let local else { testResults[id] = "Laya isn’t ready on this \(deviceName) yet."; return }
            providers = SystemOneProviders(local: local); timeout = 30
        } else {
            guard let kind = HostedProviderKind(rawValue: id) else { return }
            guard settings[kind].isConsented, let endpoint = settings[kind].endpoint, let key = (try? keys.read(kind.keyID)) ?? nil else {
                testResults[id] = "Turn it on first."; return
            }
            providers = SystemOneProviders(remotes: [SystemOneAPIProvider(endpoint: endpoint, key: key, session: session).remote]); timeout = 10
        }
        testing.insert(id)
        defer { testing.remove(id) }
        let started = Date()
        let request = DecisionRequest(state: Self.sample.state, questions: Self.sample.questions, deadline: started.addingTimeInterval(timeout))
        let decision = await SystemOne.decide(.route, request, providers: providers, level: .open)
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        testResults[id] = Self.testLine(decision, milliseconds: milliseconds)
    }

    nonisolated static func testLine(_ decision: Decision, milliseconds: Int) -> String {
        guard let step = decision.steps.last else { return "Nothing to ask." }
        let options = sample.questions[0].options
        if let result = decision.result, let index = result.answers.first?.selectedIndex {
            return "Picked “\(options[index])” at \(percent(result.score)) in \(milliseconds) ms. Sure enough to decide."
        }
        switch step.reason {
        case .lowConfidence?: return "Unsure (\(step.score.map(percent) ?? "?")) in \(milliseconds) ms, so the bot you last talked to would answer."
        case .rejected?: return "The key was refused, or the limit was reached."
        case .unavailable?: return step.sentTo.map { "Couldn’t get an answer from \($0) in time." } ?? "Laya couldn’t answer in time. Try again."
        case .outOfDistribution?: return "It couldn’t answer this kind of request."
        case .privacy?: return "Not allowed for this request."
        case nil: return "Done in \(milliseconds) ms."
        }
    }
    nonisolated static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }

    // MARK: Files

    private func save() { write(settings, "system-one.json") }
    private func write<T: Encodable>(_ value: T, _ name: String) {
        guard let folder else { return }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? TsukumoJSON.encoder.encode(value).write(to: folder.appendingPathComponent(name), options: .atomic)
    }
    private static func read<T: Decodable>(_ type: T.Type, _ folder: URL?, _ name: String) -> T? {
        guard let folder, let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return nil }
        return try? TsukumoJSON.decoder.decode(T.self, from: data)
    }
}

public enum SystemOneSetupError: Error, LocalizedError, Sendable {
    case badKey
    public var errorDescription: String? {
        switch self {
        case .badKey: "That doesn’t look like a key: paste it without spaces."
        }
    }
}

// MARK: Words

/// What both apps' System One tab says, in one place (AGENTS.md rule 9).
public enum SystemOneCopy {
    public static let untagged = "Untagged messages"
    public static let models = "Decision models"
    public static let recent = "Recent decisions"
    public static let routing = "Routing"
    public static let nothingOn = "Nothing is on yet, so untagged messages go to the bot you last talked to."
    public static func modelsFooter(device: String) -> String {
        "Asked in this order when you don’t tag a bot: Laya on this \(device) first, for any chat; then the hosted models you turned on, in the order you drag them into, only for Open and Personal chats; then the bot you last talked to. Each decides only when it’s sure. Keys stay in this \(device)’s Keychain and never sync."
    }
    public static let watched = "OpenAI’s Decisions API has no public API yet, so there’s nothing to turn on."
    public static let recentEmpty = "None yet. Each decision shows here, with who made it and where it was sent."
    public static let marking = "Mark Laya’s decisions Right or Wrong to train your personal layer on this device. It turns on only when it does better than Laya alone."
    public static let personalLayer = "Your personal layer"

    // Laya
    public static let layaTitle = "Laya"
    public static func layaDetail(device: String) -> String { "On this \(device) · Convai · Apache-2.0" }
    public static let layaConsentTitle = "Download Laya?"
    public static func layaConsentMessage(size: String, device: String) -> String {
        "\(size) from huggingface.co (aac6fef/laya-coreml, a Core ML conversion of Convai’s Laya, Apache-2.0), pinned and checked, kept and run only on this \(device). Then System One decides on this \(device) first, for every chat, and nothing about your messages leaves it."
    }
    public static let layaRemoveTitle = "Remove Laya?"
    public static func layaRemoveMessage(size: String, device: String) -> String {
        "This frees \(size) on this \(device). Your marks and personal layer stay, and you can download it again."
    }
    public static let layaPrepareFailed = "Laya couldn’t be prepared on this device. Try again, or remove it and download it again."
    public static func layaAbout(device: String) -> String {
        "Laya decides on this \(device), so it can decide for any chat, even Device only and Secret ones. It’s measured as weak at routing, so it decides only when it’s at least 90% sure; otherwise the next model, or the bot you last talked to, answers."
    }

    /// "Ready", "Needs a key", "Downloading 42%", "Off"
    public static func status(_ status: ProviderStatus) -> String {
        switch status {
        case .ready: "Ready"
        case .needsKey: "Needs a key"
        case .off: "Off"
        case .notDownloaded: "Not downloaded"
        case .downloading(let fraction): "Downloading \(Int((fraction * 100).rounded()))%"
        case .preparing: "Preparing"
        case .failed: "Failed"
        }
    }
    /// Laya's row status.
    public static func status(_ state: LayaState) -> ProviderStatus {
        switch state {
        case .ready: .ready
        case .downloading(let fraction): .downloading(fraction)
        case .waitingForWiFi: .downloading(0)
        case .verifying, .preparing: .preparing
        case .failed: .failed
        case .notDownloaded: .notDownloaded
        }
    }
    /// The line under Laya's state.
    public static func layaLine(_ state: LayaState, size: String) -> String {
        switch state {
        case .notDownloaded: "Not downloaded · \(size)"
        case .waitingForWiFi: "Waiting for Wi-Fi"
        case .downloading(let fraction): "Downloading \(Int((fraction * 100).rounded()))%"
        case .verifying: "Verifying"
        case .preparing: "Preparing for this device"
        case .ready: "Ready"
        case .failed(let reason): reason
        }
    }

    /// "Laya", "Cloudflare Clef-flash", "the bot you last talked to"
    public static func name(_ source: DecisionSource) -> String {
        if source == .laya { return "Laya" }
        if source == .fallback { return "the bot you last talked to" }
        return HostedProviderKind(rawValue: source.rawValue)?.title ?? source.rawValue
    }
    /// "Decided by Laya" or "Unsure · the bot you last talked to"
    public static func decided(_ record: DecisionRecord) -> String {
        record.decidedBy == .fallback ? "Unsure · the bot you last talked to" : "Decided by " + name(record.decidedBy) + (record.steps.contains { $0.personal && !$0.abstained } ? " · your layer" : "")
    }
    /// "Laya 97% · Cloudflare Clef-flash not sure (62%), sent to api.cloudflare.com"
    public static func steps(_ record: DecisionRecord) -> String {
        record.steps.map { step in
            let who = name(step.provider), percent = step.score.map { SystemOneCenter.percent($0) }
            let what: String
            switch step.reason {
            case nil: what = who + " " + (percent ?? "")
            case .lowConfidence: what = "\(who) not sure" + (percent.map { " (\($0))" } ?? "")
            case .outOfDistribution: what = "\(who): unfamiliar input"
            case .privacy: what = "\(who): not for this chat"
            case .unavailable: what = "\(who) unavailable"
            case .rejected: what = "\(who): key refused or limit reached"
            }
            return what + (step.sentTo.map { ", sent to \($0)" } ?? "")
        }.joined(separator: " · ")
    }
    /// What went to a host: never the words themselves in the journal, only that they went.
    public static func sent(_ record: DecisionRecord) -> String? {
        let hosts = record.steps.compactMap(\.sentTo)
        guard !hosts.isEmpty else { return nil }
        let choices = record.questions.map(\.options.count).reduce(0, +)
        return "Sent to \(ListFormatter.localizedString(byJoining: hosts)): the message’s words, \(record.questions.count == 1 ? "the question" : "\(record.questions.count) questions"), and \(choices) choices."
    }
}
