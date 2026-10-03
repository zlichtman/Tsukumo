import Foundation
import Testing
@testable import TsukumoEngines

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

