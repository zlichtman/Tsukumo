import Foundation

// The relay's network, behind two small protocols so the connection can be tested against an in-process fake relay
// with no network: `GET /challenge`, and a WebSocket opened with the signed upgrade headers. The real one is
// URLSession's (`URLSessionWebSocketTask`), with no cookies, no cache, and no redirects followed.

/// A socket closed, or an upgrade refused. `code` is the WebSocket close code (4000 replaced, 4001 unregistered, …);
/// `httpStatus` is the upgrade's answer when it was refused before any socket (401, 404, 409, 429, 503).
public struct RelayClosed: Error, Equatable, Sendable {
    public let code: Int
    public let httpStatus: Int?
    /// The refused upgrade's `Retry-After`, in seconds, when it had one (the relay's `relay_busy`).
    public let retryAfter: Int?
    public init(code: Int, httpStatus: Int? = nil, retryAfter: Int? = nil) { self.code = code; self.httpStatus = httpStatus; self.retryAfter = retryAfter }
}

/// Why a challenge was abandoned.
public enum RelayChallengeError: Error, Equatable { case tooLarge, timedOut }

/// One live WebSocket to the relay: text frames each way.
public protocol RelaySocket: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// The next text frame; throws `RelayClosed` when the socket closes.
    func receive() async throws -> String
    func close(code: Int)
}

public protocol RelayTransport: Sendable {
    /// `GET` the challenge: its status, body, and `Retry-After` in seconds (when there is one).
    func challenge(_ url: URL) async throws -> (status: Int, body: Data, retryAfter: Int?)
    /// Opens the WebSocket with these upgrade headers.
    func connect(_ url: URL, headers: [String: String]) async throws -> any RelaySocket
}

/// URLSession's WebSocket.
public final class URLSessionRelayTransport: NSObject, RelayTransport, URLSessionTaskDelegate, @unchecked Sendable {
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    /// The challenge's largest body, and how long it may take in all.
    let challengeLimit: Int
    let challengeDeadline: Duration

    public init(challengeLimit: Int = 16 * 1_024, challengeDeadline: Duration = .seconds(15)) {
        self.challengeLimit = challengeLimit; self.challengeDeadline = challengeDeadline
        super.init()
    }

    /// The challenge, streamed: past `challengeLimit` bytes or `challengeDeadline` it's abandoned (the download is
    /// cancelled), so a hostile relay can't make this Mac buffer an endless answer or wait forever for one.
    public func challenge(_ url: URL) async throws -> (status: Int, body: Data, retryAfter: Int?) {
        var draft = URLRequest(url: url)
        draft.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = session, limit = challengeLimit, deadline = challengeDeadline, request = draft
        return try await withThrowingTaskGroup(of: (Int, Data, Int?).self) { group in
            group.addTask {
                let (bytes, response) = try await session.bytes(for: request)
                let task = bytes.task
                return try await withTaskCancellationHandler {
                    if response.expectedContentLength > Int64(limit) { task.cancel(); throw RelayChallengeError.tooLarge }
                    var data = Data()
                    for try await byte in bytes {
                        data.append(byte)
                        if data.count > limit { task.cancel(); throw RelayChallengeError.tooLarge }
                    }
                    let http = response as? HTTPURLResponse
                    let retry = http?.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
                    return (http?.statusCode ?? 0, data, retry)
                } onCancel: { task.cancel() }
            }
            group.addTask {
                try await Task.sleep(for: deadline)
                throw RelayChallengeError.timedOut
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw RelayChallengeError.timedOut }
            return first
        }
    }

    public func connect(_ url: URL, headers: [String: String]) async throws -> any RelaySocket {
        var request = URLRequest(url: url)
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = RelayEnvelope.maxFrameChars + 64 * 1_024
        task.resume()
        return URLSessionRelaySocket(task: task)
    }

    /// The relay never redirects; nothing here follows one.
    public func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                           newRequest request: URLRequest) async -> URLRequest? { nil }
}

final class URLSessionRelaySocket: RelaySocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    init(task: URLSessionWebSocketTask) { self.task = task }

    func send(_ text: String) async throws {
        do { try await task.send(.string(text)) } catch { throw closed() }
    }
    func receive() async throws -> String {
        do {
            switch try await task.receive() {
            case .string(let text): return text
            case .data: throw RelayClosed(code: RelayEnvelope.Close.protocolError)
            @unknown default: throw RelayClosed(code: RelayEnvelope.Close.protocolError)
            }
        } catch let error as RelayClosed {
            task.cancel(with: .init(rawValue: error.code) ?? .protocolError, reason: nil)
            throw error
        } catch {
            throw closed()
        }
    }
    func close(code: Int) { task.cancel(with: .init(rawValue: code) ?? .normalClosure, reason: nil) }

    /// The close code, or the upgrade's HTTP status when no socket opened.
    private func closed() -> RelayClosed {
        let response = task.response as? HTTPURLResponse
        let status = response?.statusCode
        let code = task.closeCode.rawValue
        let retry = response?.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        return RelayClosed(code: code == 0 ? 1006 : code, httpStatus: status == 101 ? nil : status, retryAfter: retry)
    }
}
