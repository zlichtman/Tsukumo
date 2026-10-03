import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// System One (September 27, 2026): Laya decides on this device first, Jev only when Laya abstains
/// and the chat's level lets the packet leave, and the caller's own rules otherwise. Shared by
/// iPhone and Mac.
final class SystemOneTests: XCTestCase {
    /// Answers every question with fixed probabilities (the first option gets `top`), and records
    /// each request it receives.
    private final class Fixed: DecisionProvider, @unchecked Sendable {
        let modelVersion: String
        let top: Double
        let pick: Int
        private let lock = NSLock()
        private var seen: [DecisionRequest] = []
        init(_ version: String, top: Double, pick: Int = 0) { modelVersion = version; self.top = top; self.pick = pick }
        var requests: [DecisionRequest] { lock.withLock { seen } }
        func decide(_ request: DecisionRequest) async throws -> DecisionResult {
            lock.withLock { seen.append(request) }
            return .init(modelVersion: modelVersion, answers: request.questions.map { question in
                let rest = (1 - top) / Double(question.options.count - 1)
                return .init(questionID: question.id, probabilities: question.options.indices.map { $0 == min(pick, question.options.count - 1) ? top : rest })
            }, calibrated: false, abstention: nil)
        }
    }
    private func request(_ state: String = "Make time for reading tomorrow afternoon", options: [String] = ["09:00", "14:00", "17:00"]) -> DecisionRequest {
        .init(state: state, questions: [.init(id: "fit", kind: .choice, instruction: "Which time fits?", options: options)], deadline: Date().addingTimeInterval(30))
    }
    private func journal() -> SystemOneJournal {
        SystemOneJournal(url: FileManager.default.temporaryDirectory.appendingPathComponent("system-one-\(UUID().uuidString).json"))
    }

    func testAConfidentLayaDecidesAndJevIsNotAsked() async throws {
        let laya = Fixed("Laya test", top: 0.97), jev = Fixed("Jev test", top: 0.99), journal = journal()
        let result = await SystemOne.decide(request(), kind: .candidateFit, level: .personal, providers: .init(laya: laya, jev: jev, journal: journal))
        XCTAssertEqual(result?.modelVersion, "Laya test")
        XCTAssertTrue(jev.requests.isEmpty, "Jev is a second opinion only")
        let records = await journal.records()
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.decidedBy, .laya)
        XCTAssertEqual(records.first?.kind, .candidateFit)
        XCTAssertEqual(records.first?.steps, [SystemOneStep(provider: .laya, version: "Laya test", score: 0.97, reason: nil, layer: .base)])
        XCTAssertEqual(records.first?.layer, .base)
        XCTAssertEqual(records.first?.questions?.first?.options, ["09:00", "14:00", "17:00"])
        XCTAssertEqual(records.first?.questions?.first?.answer, 0)
    }

    func testAnUnsureLayaAsksJevForAPersonalChat() async throws {
        let laya = Fixed("Laya test", top: 0.5), jev = Fixed("Jev test", top: 0.95), journal = journal()
        let asked = request()
        let result = await SystemOne.decide(asked, kind: .candidateFit, level: .personal, providers: .init(laya: laya, jev: jev, journal: journal))
        XCTAssertEqual(result?.modelVersion, "Jev test")
        // Jev got the packet only: the request's words and the questions, nothing else.
        XCTAssertEqual(jev.requests.count, 1)
        XCTAssertEqual(jev.requests.first?.state, asked.state)
        XCTAssertEqual(jev.requests.first?.questions, asked.questions)
        let steps = await journal.records().first?.steps ?? []
        XCTAssertEqual(steps.map(\.provider), [.laya, .jev])
        XCTAssertEqual(steps.first?.reason, .lowConfidence)
        XCTAssertNil(steps.last?.reason)
        XCTAssertEqual(steps.last?.sentTo, "api.typesafe.ai")
        XCTAssertNil(steps.first?.sentTo, "Laya stays on this device")
    }

    func testSensitiveDeviceOnlyAndSecretChatsNeverReachJev() async throws {
        for level in [PrivacyLevel.sensitive, .deviceOnly, .secret] {
            let laya = Fixed("Laya test", top: 0.4), jev = Fixed("Jev test", top: 0.99), journal = journal()
            let result = await SystemOne.decide(request(), kind: .routineIntent, level: level, providers: .init(laya: laya, jev: jev, journal: journal))
            XCTAssertNil(result, "\(level): falls back")
            XCTAssertTrue(jev.requests.isEmpty, "\(level) never goes to Jev")
            let steps = await journal.records().first?.steps ?? []
            XCTAssertEqual(steps.last, SystemOneStep(provider: .jev, version: "Jev test", score: nil, reason: .privacy))
            XCTAssertFalse(SystemOne.jevMayReceive(level))
        }
        XCTAssertTrue(SystemOne.jevMayReceive(.open))
        XCTAssertTrue(SystemOne.jevMayReceive(.personal), "Turning Jev on is the grant for Personal requests")
    }

    func testWithoutJevAnUnsureLayaFallsBack() async throws {
        let journal = journal()
        let result = await SystemOne.decide(request(), kind: .routineIntent, level: .open, providers: .init(laya: Fixed("Laya test", top: 0.6), jev: nil, journal: journal))
        XCTAssertNil(result)
        let record = await journal.records().first
        XCTAssertEqual(record?.decidedBy, .fallback)
        XCTAssertEqual(record?.steps.first?.score, 0.6)
    }

    func testWithNeitherProviderNothingIsJournaled() async throws {
        let journal = journal()
        let result = await SystemOne.decide(request(), kind: .routineIntent, level: .open, providers: .init(laya: nil, jev: nil, journal: journal))
        XCTAssertNil(result)
        let records = await journal.records()
        XCTAssertTrue(records.isEmpty)
    }

    func testUnfamiliarInputAbstainsBeforeAnyModelRuns() async throws {
        let laya = Fixed("Laya test", top: 0.99), jev = Fixed("Jev test", top: 0.99), journal = journal()
        let result = await SystemOne.decide(request("明日の午後に読書の時間を作って"), kind: .candidateFit, level: .open,
                                            providers: .init(laya: laya, jev: jev, journal: journal))
        XCTAssertNil(result)
        XCTAssertTrue(laya.requests.isEmpty); XCTAssertTrue(jev.requests.isEmpty)
        let steps = await journal.records().first?.steps ?? []
        XCTAssertEqual(steps.map(\.reason), [.outOfDistribution, .outOfDistribution])
    }

    /// The authority invariant: a confident score only picks a route; the words still have to ask.
    func testAConfidentScoreNeverGrantsAnActionTheWordsDidNotAsk() async throws {
        let alarm = ConversationRouting.systemOneIntents.firstIndex(of: .setAlarm)!
        let plan = ConversationRouting.systemOneIntents.firstIndex(of: .planDay)!
        for (message, pick) in [("What's the weather like tomorrow", alarm), ("Tell me a joke", plan)] {
            var planning = PlanningRequest(message: message, history: [], memories: [], standupFormat: "")
            planning.privacy = .open
            let provider = Fixed("Laya test", top: 0.99, pick: pick)
            let providers = SystemOneProviders(laya: provider, jev: nil, journal: nil)
            let raw = await ConversationRouting.systemOneChoice(planning, providers: providers)
            XCTAssertEqual(raw?.intent, ConversationRouting.systemOneIntents[pick], "System One did choose it")
            let chosen = try await ConversationRouting.choose(planning, systemOne: providers)
            XCTAssertEqual(chosen.intent, .answer, message)
        }
    }

    func testMissingInformationOnlyEverAddsAQuestion() async throws {
        var planning = PlanningRequest(message: "Make time for something", history: [], memories: [], standupFormat: "")
        planning.privacy = .open
        let missing = await DailyAssistant.needsClarification(planning, providers: .init(laya: Fixed("Laya test", top: 0.95, pick: 0), jev: nil, journal: nil))
        XCTAssertTrue(missing)
        let specified = await DailyAssistant.needsClarification(planning, providers: .init(laya: Fixed("Laya test", top: 0.95, pick: 1), jev: nil, journal: nil))
        XCTAssertFalse(specified)
        let unsure = await DailyAssistant.needsClarification(planning, providers: .init(laya: Fixed("Laya test", top: 0.6, pick: 0), jev: nil, journal: nil))
        XCTAssertFalse(unsure, "An abstention changes nothing")
    }

    // MARK: Settings and the lock

    private final class MemoryKeys: JevKeyStoring, @unchecked Sendable {
        var key: String?
        func read() -> String? { key }
        func save(_ key: String) throws { self.key = key }
        func remove() throws { key = nil }
    }
    @MainActor func testJevIsActiveOnlyWithAKeyAndTheLockFollowsIt() throws {
        let defaults = UserDefaults(suiteName: "system-one-tests-" + UUID().uuidString)!
        let keys = MemoryKeys()
        let settings = SystemOneSettings(keys: keys, defaults: defaults)
        XCTAssertTrue(settings.layaEnabled, "Laya is on by default once downloaded")
        XCTAssertFalse(settings.jevActive, "No key: Add your Jev key")
        XCTAssertFalse(settings.jevMayReceive(.personal))
        try settings.saveJevKey("tsk-test-key-123")
        XCTAssertTrue(settings.jevActive)
        XCTAssertTrue(settings.jevMayReceive(.personal))
        XCTAssertFalse(settings.jevMayReceive(.deviceOnly))
        settings.jevEnabled = false
        XCTAssertFalse(settings.jevMayReceive(.open))
        try settings.removeJevKey()
        XCTAssertNil(keys.key)
        XCTAssertFalse(settings.jevActive)
        XCTAssertTrue(KeychainJevKey.service.hasSuffix(".tests"), "Tests never read the real key")
    }

    // MARK: Laya's download

    func testLayaIsPinnedToTheBaseConversion() {
        let pack = VoiceModelPack.laya
        XCTAssertEqual(pack.sources.map(\.repository), ["aac6fef/laya-coreml"])
        XCTAssertEqual(pack.sources.first?.revision, "fff78b2d9750c6b748fe8c90fcbf8bed0a1522a9")
        XCTAssertTrue(pack.files.allSatisfy { $0.file.sha256.count == 64 && $0.file.sha256.allSatisfy(\.isHexDigit) })
        XCTAssertEqual(pack.totalBytes, 847_221_858)
        XCTAssertTrue(pack.files.contains { $0.file.path == "LICENSE" } && pack.files.contains { $0.file.path == "NOTICE" })
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertFalse(LayaModel.isAvailable(at: empty.appendingPathComponent("model")))
        XCTAssertEqual(CoreMLLayaProvider.version, "Laya English · c5d7873")
    }

    // MARK: Jev's HTTP contract

    private final class MockJev: URLProtocol {
        struct Seen { let request: URLRequest; let body: Data }
        nonisolated(unsafe) static var status = 200
        nonisolated(unsafe) static var response = Data()
        nonisolated(unsafe) static var seen: [Seen] = []
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable { let read = stream.read(&buffer, maxLength: buffer.count); if read <= 0 { break }; body.append(buffer, count: read) }
            }
            Self.seen.append(.init(request: request, body: body))
            let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Self.response)
            client?.urlProtocolDidFinishLoading(self)
        }
        override func stopLoading() {}
        static func session() -> URLSession {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockJev.self]
            return URLSession(configuration: configuration)
        }
        static func reset(status: Int = 200, json: String) { self.status = status; response = Data(json.utf8); seen = [] }
    }

    func testJevRequestFollowsTheDocumentedContract() async throws {
        MockJev.reset(json: #"{"model":"jev-2026-09-15","answers":{"fit":{"type":"choice","choice":"14:00","confidence":0.9,"probabilities":{"09:00":0.05,"14:00":0.9,"17:00":0.05}}},"usage":{"input_tokens":40,"output_tokens":0}}"#)
        let jev = JevDecisionProvider(key: "tsk-test-key-123", session: MockJev.session())
        let asked = request()
        let result = try await jev.decide(asked)
        XCTAssertEqual(result.modelVersion, "Jev · jev-2026-09-15")
        XCTAssertEqual(result.answers.first?.selectedIndex, 1)
        XCTAssertEqual(result.answers.first?.probabilities ?? [], [0.05, 0.9, 0.05], accuracy: 1e-9)
        XCTAssertFalse(result.calibrated)
        let seen = try XCTUnwrap(MockJev.seen.first)
        XCTAssertEqual(seen.request.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(seen.request.httpMethod, "POST")
        XCTAssertEqual(seen.request.value(forHTTPHeaderField: "Authorization"), "Bearer tsk-test-key-123")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: seen.body) as? [String: Any])
        XCTAssertEqual(Set(body.keys), ["state", "model", "questions"], "The packet and nothing else")
        XCTAssertEqual(body["state"] as? String, asked.state)
        XCTAssertEqual(body["model"] as? String, "jev-latest")
        let question = try XCTUnwrap((body["questions"] as? [String: Any])?["fit"] as? [String: Any])
        XCTAssertEqual(question["type"] as? String, "choice")
        XCTAssertEqual(question["instructions"] as? String, "Which time fits?")
        XCTAssertEqual(Set(((question["criteria"] as? [String: Any]) ?? [:]).keys), ["09:00", "14:00", "17:00"])
    }

    func testJevYesNoAndScoreAnswersMapToOptionOrder() throws {
        let asked = DecisionRequest(state: "A task starts in five minutes and conflicts with a meeting.", questions: [
            .init(id: "notify", kind: .probability, instruction: "Notify now?", options: ["wait", "notify"]),
            .init(id: "urgency", kind: .score, instruction: "How urgent?", options: ["can wait", "today", "now"])
        ], deadline: Date().addingTimeInterval(30))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: JevDecisionProvider.body(for: asked, model: "jev-latest")) as? [String: Any])
        let questions = try XCTUnwrap(body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(questions["notify"]?["type"] as? String, "noul")
        XCTAssertEqual(questions["notify"]?["criteria"] as? [String: String], ["false": "wait", "true": "notify"])
        XCTAssertEqual(questions["urgency"]?["criteria"] as? [String], ["can wait", "today", "now"])
        let json = #"{"model":"jev-latest","answers":{"notify":{"type":"noul","noul":0.8},"urgency":{"type":"score","score":1.8,"confidence":0.7,"legend":{"0":"can wait","1":"today","2":"now"},"probabilities":{"0":0.1,"1":0.0,"2":0.9}}},"usage":{"input_tokens":1,"output_tokens":0}}"#
        let result = try JevDecisionProvider.parse(Data(json.utf8), for: asked)
        XCTAssertEqual(result.answers[0].probabilities, [0.2, 0.8], accuracy: 1e-9)
        XCTAssertEqual(result.answers[1].selectedIndex, 2)
    }

    func testJevRefusesMalformedOrMismatchedAnswers() throws {
        let asked = request()
        for json in [#"{"answers":{}}"#, #"{"model":"jev","answers":{"fit":{"type":"noul","noul":0.5}}}"#,
                     #"{"model":"jev","answers":{"fit":{"type":"choice","probabilities":{"09:00":0.5,"14:00":0.5}}}}"#,
                     #"{"model":"jev","answers":{"fit":{"type":"choice","probabilities":{"09:00":0.5,"14:00":0.5,"17:00":"x"}}}}"#,
                     #"{"model":"jev","answers":{"fit":{"type":"choice","probabilities":{"09:00":-1,"14:00":1,"17:00":1}}}}"#, "not json"] {
            XCTAssertThrowsError(try JevDecisionProvider.parse(Data(json.utf8), for: asked), json)
        }
    }

    func testARefusedKeyIsReportedAndFallsBack() async throws {
        MockJev.reset(status: 401, json: #"{"detail":"Invalid API key"}"#)
        let jev = JevDecisionProvider(key: "tsk-wrong-key-000", session: MockJev.session())
        do { _ = try await jev.decide(request()); XCTFail("A refused key isn't an answer") }
        catch { XCTAssertEqual(error as? JevDecisionProvider.Failure, .keyRejected) }
        let journal = journal()
        let result = await SystemOne.decide(request(), kind: .candidateFit, level: .open, providers: .init(laya: nil, jev: jev, journal: journal))
        XCTAssertNil(result)
        let step = await journal.records().first?.steps.first
        XCTAssertEqual(step?.reason, .rejected)
    }

    func testThroughTheRouterASensitiveRequestNeverTouchesTheNetwork() async throws {
        MockJev.reset(json: #"{"model":"jev-latest","answers":{"fit":{"type":"choice","probabilities":{"09:00":0,"14:00":1,"17:00":0}}},"usage":{"input_tokens":1,"output_tokens":0}}"#)
        let jev = JevDecisionProvider(key: "tsk-test-key-123", session: MockJev.session())
        let providers = SystemOneProviders(laya: Fixed("Laya test", top: 0.4), jev: jev, journal: nil)
        let blocked = await SystemOne.decide(request(), kind: .candidateFit, level: .sensitive, providers: providers)
        XCTAssertNil(blocked)
        XCTAssertTrue(MockJev.seen.isEmpty, "Nothing was sent")
        let allowed = await SystemOne.decide(request(), kind: .candidateFit, level: .personal, providers: providers)
        XCTAssertEqual(allowed?.answers.first?.selectedIndex, 1)
        XCTAssertEqual(MockJev.seen.count, 1)
    }
}

private func XCTAssertEqual(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}
