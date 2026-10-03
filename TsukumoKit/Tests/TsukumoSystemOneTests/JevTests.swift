import Foundation
import Testing
@testable import TsukumoSystemOne

/// Stubbed URL loading: each session gets its own handler, keyed by a header, so parallel tests
/// never share one. Nothing touches the network.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    typealias Handler = @Sendable (URLRequest) -> (Int, Data)
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handlers: [String: Handler] = [:]
    nonisolated(unsafe) private static var seen: [String: [URLRequest]] = [:]

    static func session(_ handler: @escaping Handler) -> (URLSession, String) {
        let id = UUID().uuidString
        lock.withLock { handlers[id] = handler }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Stub": id]
        return (URLSession(configuration: configuration), id)
    }
    static func requests(_ id: String) -> [URLRequest] { lock.withLock { seen[id] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let id = request.value(forHTTPHeaderField: "X-Stub") ?? ""
        var copy = request
        if copy.httpBody == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(buffer, count: count) }
            stream.close()
            copy.httpBody = data
        }
        let handler = Self.lock.withLock { () -> Handler? in Self.seen[id, default: []].append(copy); return Self.handlers[id] }
        let (status, body) = handler?(copy) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Jev's documented contract against stubbed URL loading (porting the Jev tests in `SystemOneTests`).
struct JevTests {
    let request = DecisionRequest(state: "plan dinner", questions: [
        DecisionQuestion(id: "fit", kind: .choice, instruction: "Which time?", options: ["6 PM", "9 PM"]),
        DecisionQuestion(id: "ask", kind: .probability, instruction: "Missing a day?", options: ["No", "Yes"]),
        DecisionQuestion(id: "how", kind: .score, instruction: "How urgent?", options: ["low", "mid", "high"])
    ], deadline: Date().addingTimeInterval(60))

    let reply = #"{"model":"jev-2","answers":{"fit":{"type":"choice","probabilities":{"6 PM":0.2,"9 PM":0.8}},"ask":{"type":"noul","noul":0.9},"how":{"type":"score","probabilities":{"0":0.1,"1":0.2,"2":0.7}}}}"#

    @Test func theRequestFollowsTheDocumentedContract() async throws {
        let (session, id) = StubURLProtocol.session { [reply] _ in (200, Data(reply.utf8)) }
        let result = try await JevDecisionProvider(key: "test-key-123", session: session).decide(request)
        let sent = try #require(StubURLProtocol.requests(id).first)
        #expect(sent.httpMethod == "POST" && sent.url == JevDecisionProvider.endpoint)
        #expect(sent.value(forHTTPHeaderField: "Authorization") == "Bearer test-key-123")
        let body = try #require(try JSONSerialization.jsonObject(with: sent.httpBody ?? Data()) as? [String: Any])
        #expect(body["state"] as? String == "plan dinner" && body["model"] as? String == "jev-latest")
        let questions = try #require(body["questions"] as? [String: Any])
        #expect((questions["ask"] as? [String: Any])?["type"] as? String == "noul")
        #expect(result.modelVersion == "Jev · jev-2")
        #expect(result.answers.map(\.selectedIndex) == [1, 1, 2])
        #expect(abs(result.answers[1].probabilities[1] - 0.9) < 1e-9)
    }

    @Test func malformedOrMismatchedAnswersAreRefused() {
        for body in [#"{"model":"m","answers":{}}"#, #"{"answers":{}}"#, "not json",
                     #"{"model":"m","answers":{"fit":{"type":"choice","probabilities":{"6 PM":0.2,"7 PM":0.8}}}}"#,
                     #"{"model":"m","answers":{"fit":{"type":"choice","probabilities":{"6 PM":true,"9 PM":0.8}}}}"#] {
            #expect(throws: DecisionError.invalidOutput) { try JevDecisionProvider.parse(Data(body.utf8), for: request) }
        }
    }

    @Test func aRefusedKeyIsReported() async {
        let (session, _) = StubURLProtocol.session { _ in (401, Data()) }
        await #expect(throws: RemoteDecisionError.keyRejected) { try await JevDecisionProvider(key: "bad-key-123", session: session).decide(request) }
        let (limited, _) = StubURLProtocol.session { _ in (429, Data()) }
        await #expect(throws: RemoteDecisionError.limited) { try await JevDecisionProvider(key: "k-123456", session: limited).decide(request) }
    }

    @Test func throughSystemOneASensitiveRequestNeverTouchesTheNetwork() async {
        let (session, id) = StubURLProtocol.session { [reply] _ in (200, Data(reply.utf8)) }
        let decision = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(remotes: [JevDecisionProvider.remote(key: "k-123456", session: session)]),
                                              level: .sensitive)
        #expect(decision.abstained && StubURLProtocol.requests(id).isEmpty)
    }

    @Test func aLayaWithoutItsBundleIsUnavailable() async {
        struct NoTokenizer: LayaTokenizer { func encode(_ text: String) -> [Int] { [] }; func tokenID(_ token: String) -> Int? { nil } }
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let laya = CoreMLLayaProvider(directory: missing) { _ in NoTokenizer() }
        await #expect(throws: DecisionError.unavailable) { try await laya.decide(request) }
        let decision = await SystemOne.decide(.planFit, request, providers: SystemOneProviders(local: laya), level: .open)
        #expect(decision.steps.first?.reason == .unavailable)
    }
}
