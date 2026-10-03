import CryptoKit
import Network
import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Turning System One on in the builds the owner runs (September 29, 2026): the Jev key in the
/// Keychain with no access group (the Developer ID Mac build has no keychain-access-groups
/// entitlement and no provisioning profile), Jev answering through a stub server on this device,
/// Laya's download finishing and preparing without the page open, hosted services after Jev
/// following the same privacy rule, and the page's text. Shared by iPhone and Mac. Nothing here
/// touches the owner's Keychain items, TypeSafe, OpenAI, or Hugging Face.
final class SystemOneActivationTests: XCTestCase {
    private var services: [String] = []
    private var folders: [URL] = []
    override func tearDown() {
        for service in services { try? KeychainJevKey(service: service).remove() }
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
    }
    /// A Keychain service of this test's own, removed afterwards.
    private func keys() -> KeychainJevKey {
        let service = "com.zlichtman.kemosabe.system-one.tests." + UUID().uuidString
        services.append(service)
        return KeychainJevKey(service: service)
    }
    private func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("system-one-activation-" + UUID().uuidString, isDirectory: true)
        folders.append(url); return url
    }
    private func request(_ state: String = "Make time for reading tomorrow afternoon") -> DecisionRequest {
        .init(state: state, questions: [.init(id: "fit", kind: .choice, instruction: "Which time fits?", options: ["09:00", "14:00", "17:00"])],
              deadline: Date().addingTimeInterval(30))
    }

    // MARK: The key

    func testTheJevKeySavesReadsReplacesAndRemovesWithoutAnAccessGroup() throws {
        XCTAssertTrue(KeychainJevKey.service.hasSuffix(".tests"), "Tests never use the real service")
        let keys = keys()
        XCTAssertNil(keys.read()); XCTAssertFalse(keys.exists())
        try keys.save("  tsk-live-abcdef123456\n")
        XCTAssertEqual(keys.read(), "tsk-live-abcdef123456", "Pasted spaces and line breaks are dropped")
        XCTAssertTrue(keys.exists())
        try keys.save("tsk-live-second-key-99")
        XCTAssertEqual(keys.read(), "tsk-live-second-key-99", "Adding again replaces the key")
        try keys.remove()
        XCTAssertNil(keys.read()); XCTAssertFalse(keys.exists())
        XCTAssertNoThrow(try keys.remove(), "Removing a missing key is fine")
    }

    func testAKeyThatIsNotAKeyIsRefusedWithAPlainReason() {
        let keys = keys()
        for bad in ["short", "has a space in it", "tsk-\u{00e9}-accented-key", ""] {
            XCTAssertThrowsError(try keys.save(bad), bad) { XCTAssertEqual($0 as? JevKeyError, .invalid) }
            XCTAssertFalse(JevKey.isValid(bad))
        }
        XCTAssertNil(keys.read())
        let reason = JevKeyError.invalid.errorDescription ?? ""
        XCTAssertTrue(reason.contains("Jev key"), "Not the model connection's message about URLs")
        XCTAssertFalse(reason.contains("chat/completions"))
    }

    @MainActor func testSavingTurnsJevOnAndAnotherLaunchStillSeesTheKey() throws {
        let keys = keys(), defaults = UserDefaults(suiteName: "system-one-activation-" + UUID().uuidString)!
        let settings = SystemOneSettings(keys: keys, defaults: defaults)
        XCTAssertFalse(settings.hasJevKey)
        try settings.saveJevKey("tsk-live-abcdef123456 ")
        XCTAssertTrue(settings.jevActive)
        let relaunched = SystemOneSettings(keys: keys, defaults: defaults)
        XCTAssertTrue(relaunched.hasJevKey); XCTAssertTrue(relaunched.jevActive)
        try relaunched.removeJevKey()
        settings.refresh()
        XCTAssertFalse(settings.hasJevKey, "The page checks again when it shows")
    }

    /// A Keychain that says it saved but kept nothing: Jev must not show as Active.
    private final class Forgetful: JevKeyStoring, @unchecked Sendable {
        func read() -> String? { nil }
        func save(_ key: String) throws {}
        func remove() throws {}
    }
    @MainActor func testASaveTheKeychainDidNotKeepIsReported() {
        let settings = SystemOneSettings(keys: Forgetful(), defaults: UserDefaults(suiteName: "system-one-activation-" + UUID().uuidString)!)
        XCTAssertThrowsError(try settings.saveJevKey("tsk-live-abcdef123456")) { XCTAssertEqual($0 as? JevKeyError, .notSaved) }
        XCTAssertFalse(settings.jevActive)
    }

    // MARK: Jev through a stub server

    func testJevAnswersThroughAStubServerOnThisDevice() async throws {
        let server = try StubJevServer(json: #"{"model":"jev-2026-09-15","answers":{"fit":{"type":"choice","probabilities":{"09:00":0.03,"14:00":0.94,"17:00":0.03}}}}"#)
        let port = try await server.start()
        defer { server.stop() }
        let jev = JevDecisionProvider(key: "tsk-stub-key-123", endpoint: URL(string: "http://127.0.0.1:\(port)/v1/systemone")!)
        let result = try await jev.decide(request())
        XCTAssertEqual(result.modelVersion, "Jev · jev-2026-09-15")
        XCTAssertEqual(result.answers.first?.selectedIndex, 1)
        let seen = try XCTUnwrap(server.requests.first)
        XCTAssertTrue(seen.head.hasPrefix("POST /v1/systemone "))
        XCTAssertTrue(seen.head.lowercased().contains("authorization: bearer tsk-stub-key-123"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: seen.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["state", "model", "questions"])
    }

    /// The whole path a decision takes: the key saved through settings, providers resolved the way
    /// `current()` resolves them, the stub answering, and the journal recording Jev. A Sensitive chat
    /// sends nothing.
    @MainActor func testFromSavedKeyToAJournaledJevDecision() async throws {
        let server = try StubJevServer(json: #"{"model":"jev-latest","answers":{"fit":{"type":"choice","probabilities":{"09:00":0.02,"14:00":0.96,"17:00":0.02}}}}"#)
        let port = try await server.start()
        defer { server.stop() }
        let keys = keys(), defaults = UserDefaults(suiteName: "system-one-activation-" + UUID().uuidString)!, folder = folder()
        XCTAssertTrue(SystemOneProviders.resolve(defaults: defaults, keys: keys, layaAvailable: false, folder: folder).remotes.isEmpty, "No key, no Jev")
        try SystemOneSettings(keys: keys, defaults: defaults).saveJevKey("tsk-stub-key-123")
        let providers = SystemOneProviders.resolve(defaults: defaults, keys: keys, layaAvailable: false, folder: folder,
                                                   jevEndpoint: URL(string: "http://127.0.0.1:\(port)/v1/systemone")!)
        XCTAssertNil(providers.laya, "Laya isn't downloaded")
        XCTAssertEqual(providers.remotes.map(\.source), [.jev])
        let blocked = await SystemOne.decide(request(), kind: .candidateFit, level: .sensitive, providers: providers)
        XCTAssertNil(blocked)
        XCTAssertTrue(server.requests.isEmpty, "Nothing leaves for a Sensitive chat")
        let result = await SystemOne.decide(request(), kind: .candidateFit, level: .personal, providers: providers)
        XCTAssertEqual(result?.answers.first?.selectedIndex, 1)
        XCTAssertEqual(server.requests.count, 1)
        let records = await SystemOneJournal(url: folder.appendingPathComponent(SystemOneJournal.fileName)).records()
        XCTAssertEqual(records.map(\.decidedBy), [.fallback, .jev])
        XCTAssertEqual(records.last?.questions?.first?.answer, 1)
        XCTAssertEqual(records.last?.questions?.first?.options, ["09:00", "14:00", "17:00"])
        XCTAssertNil(records.last?.markable, "Laya didn't score it, so there's nothing to train Laya with")
    }

    // MARK: Hosted services after Jev

    private final class Fixed: DecisionProvider, @unchecked Sendable {
        let modelVersion: String, top: Double
        private let lock = NSLock()
        private var seen: [DecisionRequest] = []
        init(_ version: String, top: Double) { modelVersion = version; self.top = top }
        var requests: [DecisionRequest] { lock.withLock { seen } }
        func decide(_ request: DecisionRequest) async throws -> DecisionResult {
            lock.withLock { seen.append(request) }
            return .init(modelVersion: modelVersion, answers: request.questions.map { question in
                let rest = (1 - top) / Double(question.options.count - 1)
                return .init(questionID: question.id, probabilities: question.options.indices.map { $0 == 0 ? top : rest })
            }, calibrated: false, abstention: nil)
        }
    }

    func testAThirdServiceSlotsInAfterJevUnderTheSameRule() async throws {
        let laya = Fixed("Laya test", top: 0.5), jev = Fixed("Jev test", top: 0.6), third = Fixed("Decisions test", top: 0.97)
        let recipient = RecipientID.apiModel(profile: UUID(), host: "decisions.example.test")
        let remote = SystemOneRemote(source: .openAIDecisions, host: "decisions.example.test", recipient: recipient, provider: third)
        let journal = SystemOneJournal(url: folder().appendingPathComponent(SystemOneJournal.fileName))
        let providers = SystemOneProviders(laya: laya, remotes: [.jev(jev), remote], journal: journal)
        for level in [PrivacyLevel.sensitive, .deviceOnly, .secret] {
            let result = await SystemOne.decide(request(), kind: .candidateFit, level: level, providers: providers)
            XCTAssertNil(result, "\(level)")
            XCTAssertFalse(SystemOne.mayReceive(level, recipient: recipient))
        }
        XCTAssertTrue(jev.requests.isEmpty); XCTAssertTrue(third.requests.isEmpty, "Never for Sensitive, Device only, or Secret")
        let asked = request()
        let result = await SystemOne.decide(asked, kind: .candidateFit, level: .personal, providers: providers)
        XCTAssertEqual(result?.modelVersion, "Decisions test")
        XCTAssertEqual(third.requests.count, 1)
        XCTAssertEqual(third.requests.first?.state, asked.state, "Only the request's words")
        XCTAssertEqual(third.requests.first?.questions, asked.questions, "and the choices")
        let last = await journal.records().last
        XCTAssertEqual(last?.decidedBy, .openAIDecisions)
        XCTAssertEqual(last?.steps.map(\.provider), [.laya, .jev, .openAIDecisions])
        XCTAssertEqual(last?.steps.last?.sentTo, "decisions.example.test")
    }

    func testOpenAIDecisionsIsShownInPreviewAndNeverCalled() {
        XCTAssertEqual(SystemOneCatalog.decisions.map(\.title), ["Laya", "Jev", "OpenAI Decisions"])
        XCTAssertEqual(SystemOneCatalog.openAIDecisions.status, "In preview")
        XCTAssertTrue(SystemOneCatalog.openAIDecisions.detail.contains("hasn't published"))
        let defaults = UserDefaults(suiteName: "system-one-activation-" + UUID().uuidString)!
        defaults.set(true, forKey: SystemOneSettings.jevKey)
        let keys = keys()
        try? keys.save("tsk-live-abcdef123456")
        let providers = SystemOneProviders.resolve(defaults: defaults, keys: keys, layaAvailable: false, folder: folder())
        XCTAssertEqual(providers.remotes.map(\.source), [.jev], "Only Jev is ever resolved")
    }

    // MARK: Laya's download

    /// Serves the pinned test files from memory.
    private final class MemoryTransport: VoiceModelTransport, @unchecked Sendable {
        let contents: [String: Data]
        init(_ contents: [String: Data]) { self.contents = contents }
        func download(_ url: URL, wifiOnly: Bool, progress: @escaping @Sendable (Int64) -> Void,
                      waiting: @escaping @Sendable () -> Void) async throws -> URL {
            guard let tail = url.path.components(separatedBy: "/resolve/").last,
                  let path = tail.split(separator: "/", maxSplits: 1).last.map(String.init), let data = contents[path] else { throw URLError(.fileDoesNotExist) }
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("laya-test-" + UUID().uuidString)
            try data.write(to: file); progress(Int64(data.count))
            return file
        }
    }
    private final class Compiles: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var failFirst: Bool
        init(failFirst: Bool) { self.failFirst = failFirst }
        var count: Int { lock.withLock { calls } }
        func compile(_ directory: URL) throws -> URL {
            let call = lock.withLock { calls += 1; return calls }
            if failFirst && call == 1 { throw DecisionError.incompatibleBundle }
            let compiled = directory.appendingPathComponent("model.mlmodelc")
            try FileManager.default.createDirectory(at: compiled, withIntermediateDirectories: true)
            try Data("test".utf8).write(to: compiled.appendingPathComponent(LayaModel.compiledMarker))
            return compiled
        }
    }
    @MainActor private func layaModel(failFirst: Bool) -> (LayaModel, Compiles) {
        var contents: [String: Data] = [:], files: [VoiceModelPack.File] = []
        for path in ["coreml_config.json", "rl_agent_config.json", "tokenizer/tokenizer.json", "tokenizer/tokenizer_config.json"] {
            let data = Data("{\"file\":\"\(path)\"}".utf8)
            contents[path] = data
            files.append(.init(path: path, size: Int64(data.count), sha256: SHA256Hex.of(data)))
        }
        let pack = VoiceModelPack(id: "laya-test-" + UUID().uuidString, title: "Laya", version: 1, sources: [
            .init(repository: "example/laya", revision: String(repeating: "b", count: 40), license: "Apache-2.0", folder: "model", files: files)])
        let store = VoiceModelStore(pack: pack, root: folder(), transport: MemoryTransport(contents))
        let compiles = Compiles(failFirst: failFirst)
        return (LayaModel(store: store, compile: { try compiles.compile($0) }), compiles)
    }
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition())
    }

    @MainActor func testDownloadPreparesLayaEvenWithThePageClosed() async throws {
        let (laya, compiles) = layaModel(failFirst: false)
        XCTAssertEqual(laya.state, .notDownloaded)
        laya.download()  // No view calls refresh() here.
        try await waitUntil { laya.state == .ready }
        XCTAssertEqual(compiles.count, 1)
    }

    /// A failed preparation used to leave "Preparing" on screen forever: Download did nothing once
    /// the files were installed. Now it prepares again.
    @MainActor func testAFailedPreparationCanBeTriedAgain() async throws {
        let (laya, compiles) = layaModel(failFirst: true)
        laya.download()
        try await waitUntil { if case .failed = laya.state { return true } else { return false } }
        XCTAssertTrue(laya.store.isInstalled, "The verified files stay")
        laya.download()
        try await waitUntil { laya.state == .ready }
        XCTAssertEqual(compiles.count, 2)
    }

    func testLayaDownloadsFromAPublicPinnedAddress() {
        let pack = VoiceModelPack.laya
        for entry in pack.files {
            let url = entry.source.url(for: entry.file)
            XCTAssertEqual(url?.scheme, "https")
            XCTAssertEqual(url?.host(), "huggingface.co", "A public host, no App Store or account needed")
            XCTAssertTrue(url?.path.hasPrefix("/aac6fef/laya-coreml/resolve/fff78b2d9750c6b748fe8c90fcbf8bed0a1522a9/") == true, "Pinned to one commit")
            XCTAssertNil(url?.query)
        }
        XCTAssertEqual(pack.files.first { $0.file.path.hasSuffix("weight.bin") }?.file.sha256,
                       "5872b9f6530c20a845b69c0cb75aa141e9c89ffdd5f36529c3708cec9b7a7a83", "Checked by SHA-256")
    }

    // MARK: The page

    func testTheModelsPageHasTheSystemOneTabOnBothDevices() {
        XCTAssertEqual(ModelsTab.allCases.map(\.rawValue), ["LLM", "System One", "Training"])
        for device in [SettingsPage.Device.iPhone, .mac] {
            XCTAssertTrue(SettingsCatalog.groups(for: device).flatMap(\.pages).contains { $0.id == "Models" }, "\(device)")
            XCTAssertTrue(SettingsCatalog.groups(for: device, search: "Jev").flatMap(\.pages).contains { $0.id == "Models" })
            XCTAssertTrue(SettingsCatalog.groups(for: device, search: "OpenAI Decisions").flatMap(\.pages).contains { $0.id == "Models" })
        }
        XCTAssertEqual(SettingsCatalog.moved["System One"]?.page, "Models")
        XCTAssertEqual(SettingsCatalog.moved["System One"]?.tab, .systemOne)
        XCTAssertEqual(JevDecisionProvider.keysPage.absoluteString, "https://console.typesafe.ai/")
    }

    func testTheStatusCardSaysOnOrOffAndTheOneActionToFixIt() {
        var card = SystemOneStatus.card(laya: .notDownloaded, layaOn: true, jevActive: false, personalKinds: [])
        XCTAssertEqual([card.title, card.detail], ["Off", "Download Laya to decide on this device."])
        XCTAssertFalse(card.on); XCTAssertEqual(card.action, .downloadLaya)
        card = SystemOneStatus.card(laya: .notDownloaded, layaOn: true, jevActive: true, personalKinds: [])
        XCTAssertEqual([card.title, card.detail], ["On · Jev decides with your key", "Until Laya is on this device."])
        XCTAssertTrue(card.on); XCTAssertEqual(card.action, .downloadLaya)
        card = SystemOneStatus.card(laya: .ready, layaOn: true, jevActive: false, personalKinds: [.candidateFit])
        XCTAssertEqual([card.title, card.detail], ["On · Laya decides on this device", "Your personal layer is on for Plan fit."])
        XCTAssertNil(card.action)
        card = SystemOneStatus.card(laya: .ready, layaOn: true, jevActive: true, personalKinds: [])
        XCTAssertEqual(card.detail, "Jev helps when Laya isn't sure.")
        card = SystemOneStatus.card(laya: .ready, layaOn: false, jevActive: false, personalKinds: [])
        XCTAssertEqual([card.title, card.detail], ["Off", "Turn on Laya to decide on this device."])
        XCTAssertEqual(card.action, .turnOnLaya)
        card = SystemOneStatus.card(laya: .downloading, layaOn: true, jevActive: false, personalKinds: [])
        XCTAssertEqual(card.title, "Off · Laya is downloading"); XCTAssertNil(card.action, "Nothing to do while it downloads")
        card = SystemOneStatus.card(laya: .preparing, layaOn: true, jevActive: false, personalKinds: [])
        XCTAssertEqual(card.title, "Off · Preparing Laya"); XCTAssertNil(card.action)
        XCTAssertEqual(SystemOneStatus.card(laya: .failed, layaOn: true, jevActive: false, personalKinds: []).action, .downloadLaya)
    }

    func testThePageTextNeverSaysKemoOrUsesEmDashes() {
        var text = SystemOneCatalog.decisions.flatMap { [$0.title, $0.detail, $0.status] }
        text += [SystemOneCatalog.routing, SystemOneCatalog.marking, SystemOneCatalog.training.detail, SystemOneCatalog.trainingPrivacy, SystemOneCatalog.layaDownload]
        text += [JevKeyError.invalid, .notSaved, .keychain(-25308)].compactMap(\.errorDescription)
        text += DecisionKind.allCases.flatMap { [$0.title, $0.detail] }
        for laya in [SystemOneStatus.Laya.notDownloaded, .downloading, .preparing, .ready, .failed] {
            for jev in [true, false] {
                let card = SystemOneStatus.card(laya: laya, layaOn: true, jevActive: jev, personalKinds: [.routineIntent])
                text += [card.title, card.detail, card.action?.title].compactMap { $0 }
            }
        }
        text += [TrainingCatalog.layaLine, TrainingCatalog.voiceLine, TrainingCatalog.dayPlansLine, TrainingCatalog.privacy]
        for line in text {
            XCTAssertFalse(line.contains("\u{2014}"), line)
            XCTAssertNil(line.range(of: #"\bKemo\b"#, options: .regularExpression), line)
        }
    }
}

private enum SHA256Hex {
    static func of(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}

/// A tiny HTTP server on 127.0.0.1 that answers every request with one JSON body, standing in for
/// api.typesafe.ai. It records what it received.
final class StubJevServer: @unchecked Sendable {
    struct Received { let head: String; let body: Data }
    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub-jev")
    private let lock = NSLock()
    private var received: [Received] = []
    private let status: Int, json: Data
    init(status: Int = 200, json: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        listener = try NWListener(using: parameters)
        self.status = status; self.json = Data(json.utf8)
    }
    var requests: [Received] { lock.withLock { received } }
    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            connection.start(queue: self.queue)
            self.read(connection, Data())
        }
        final class Once: @unchecked Sendable { let lock = NSLock(); var done = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                once.lock.lock(); defer { once.lock.unlock() }
                guard !once.done else { return }
                switch state {
                case .ready: once.done = true; continuation.resume(returning: self?.listener.port?.rawValue ?? 0)
                case .failed(let error): once.done = true; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: queue)
        }
    }
    func stop() { listener.cancel() }
    private func read(_ connection: NWConnection, _ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                let length = head.split(separator: "\r\n").first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let body = buffer[end.upperBound...]
                if body.count >= length {
                    self.lock.withLock { self.received.append(.init(head: head, body: Data(body.prefix(length)))) }
                    let reply = "HTTP/1.1 \(self.status) OK\r\nContent-Type: application/json\r\nContent-Length: \(self.json.count)\r\nConnection: close\r\n\r\n"
                    connection.send(content: Data(reply.utf8) + self.json, completion: .contentProcessed { _ in connection.cancel() })
                    return
                }
            }
            if complete || error != nil { connection.cancel(); return }
            self.read(connection, buffer)
        }
    }
}
