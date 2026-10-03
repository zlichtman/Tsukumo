import Foundation
import Darwin
import CoreGraphics
import Security

// The app's end of the KemoSabe MCP helper's channel (`KemoSabeBridgeWire`, design/CONTEXT-HARNESS.md
// #agents-asking-kemosabe). A Unix socket that only this macOS user can open (a 0700 folder, a 0600
// socket, and each peer's user ID checked with `getpeereid`), and a per-install secret every request
// must carry. One request per connection. While Tsukumo isn't running there's nothing to connect
// to, so the helper tells the agent to ask again once it is.

final class KemoSabeBridgeServer: @unchecked Sendable {
    typealias Handler = @Sendable (KemoSabeBridgeWire.Request) async -> KemoSabeBridgeWire.Response
    enum ServerError: Error, Equatable { case pathTooLong, alreadyServing, socket(String) }

    let folder: URL
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.zlichtman.kemosabe.bridge")
    private var source: DispatchSourceRead?
    private var listener: Int32 = -1
    private(set) var secret = ""
    /// How long the app may take to answer one question (the owner may be deciding).
    var answerTimeout = 200

    init(folder: URL = KemoSabeBridgeWire.folder(), handler: @escaping Handler) {
        self.folder = folder
        self.handler = handler
    }
    deinit { stop() }

    var socketPath: String { folder.appendingPathComponent(KemoSabeBridgeWire.socketName).path }

    func start() throws {
        // A peer that hangs up mid-answer is an EPIPE here, never a signal that ends Tsukumo.
        // (Agents Tsukumo spawns get default signal handling back: `CodingChild` sets POSIX_SPAWN_SETSIGDEF.)
        signal(SIGPIPE, SIG_IGN)
        let manager = FileManager.default
        try manager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(folder.path, 0o700)
        secret = try Self.loadSecret(in: folder)
        guard var address = KemoSabeBridgeWire.address(socketPath) else { throw ServerError.pathTooLong }
        if manager.fileExists(atPath: socketPath) {
            // Another Tsukumo (a second copy, or a test) already answers here: leave it.
            if Self.answers(socketPath) { throw ServerError.alreadyServing }
            unlink(socketPath)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket(String(cString: strerror(errno))) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0 else { let message = String(cString: strerror(errno)); close(fd); throw ServerError.socket(message) }
        chmod(socketPath, 0o600)
        guard listen(fd, 16) == 0 else { let message = String(cString: strerror(errno)); close(fd); unlink(socketPath); throw ServerError.socket(message) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptWaiting() }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
    }

    func stop() {
        guard let source else { return }
        self.source = nil; listener = -1
        source.cancel()
        unlink(socketPath)
    }

    private func acceptWaiting() {
        while listener >= 0 {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) & ~O_NONBLOCK)
            var on: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            // Only this macOS user.
            var uid: uid_t = 0, gid: gid_t = 0
            guard getpeereid(client, &uid, &gid) == 0, uid == getuid() else { close(client); continue }
            KemoSabeBridgeWire.setTimeout(client, seconds: 10)
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        func finish(_ response: KemoSabeBridgeWire.Response) {
            if let data = try? JSONEncoder().encode(response) { _ = KemoSabeBridgeWire.writeAll(fd, data + Data([UInt8(ascii: "\n")])) }
            close(fd)
        }
        guard let line = KemoSabeBridgeWire.readLine(fd), let request = try? JSONDecoder().decode(KemoSabeBridgeWire.Request.self, from: line) else {
            return finish(.init(status: KemoSabeBridgeWire.Status.refused.rawValue, text: "KemoSabe couldn’t read that request."))
        }
        guard request.v == KemoSabeBridgeWire.version, KemoSabeBridgeWire.constantTimeEqual(request.secret, secret) else {
            return finish(.init(status: KemoSabeBridgeWire.Status.refused.rawValue, text: "This copy of kemosabe-mcp isn’t the one Tsukumo set up. Reconnect it in Tsukumo → Settings → Connections."))
        }
        KemoSabeBridgeWire.setTimeout(fd, seconds: answerTimeout)
        let handler = handler
        Task.detached { finish(await handler(request)) }
    }

    // MARK: Helpers

    /// The install's secret: read, or made once (32 random bytes, hex, 0600).
    static func loadSecret(in folder: URL) throws -> String {
        let url = folder.appendingPathComponent(KemoSabeBridgeWire.secretName)
        if let saved = try? String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), saved.count == 64 { return saved }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ServerError.socket("No random bytes") }
        let secret = bytes.map { String(format: "%02x", $0) }.joined()
        unlink(url.path)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw ServerError.socket(String(cString: strerror(errno))) }
        defer { close(fd) }
        guard KemoSabeBridgeWire.writeAll(fd, Data(secret.utf8)) else { throw ServerError.socket("Couldn't save the secret") }
        return secret
    }
    /// Whether something already answers on this socket.
    static func answers(_ path: String) -> Bool {
        guard var address = KemoSabeBridgeWire.address(path) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        } == 0
    }
    /// The Mac's screen is locked: KemoSabe doesn't answer until it's unlocked.
    static func screenLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
    }
}

/// Turns one bridge request into a question for the open account's desk.
@MainActor enum KemoSabeBridgeAnswers {
    static func respond(_ request: KemoSabeBridgeWire.Request, store: AppStore?) async -> KemoSabeBridgeWire.Response {
        guard let requester = AgentIdentity.requester(agent: request.agent, clientName: request.client?.name, clientTitle: request.client?.title) else {
            return .init(status: AgentAnswer.refused("").status, text: "KemoSabe needs to know which agent is asking. Connect it from Tsukumo → Settings → Connections.")
        }
        guard let store else { return .init(status: "unavailable", text: "KemoSabe isn’t open on this Mac yet. Ask again in a moment.") }
        let client = [request.client?.name, request.client?.version].compactMap { $0 }.joined(separator: " ")
        let answer = await store.agentQuestions.ask(.init(requester: requester, question: request.question.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          purpose: request.purpose.trimmingCharacters(in: .whitespacesAndNewlines),
                                                          client: client.isEmpty ? nil : client, handoff: request.handoff.flatMap(UUID.init(uuidString:))))
        return .init(status: answer.status, text: answer.text())
    }
}
