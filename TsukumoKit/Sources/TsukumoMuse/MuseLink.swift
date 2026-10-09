#if os(macOS)
import Foundation
import TsukumoCore

// One control session with the owner's Muse VM. Ported from Meta's Muse Gadget SDK (Apache-2.0),
// `linux/src/musegadget/link_client.py`: a WebSocket to `/v1/noise?vm_id=…` with the per-VM bearer, the
// Noise XX handshake, then a long-lived `POST /link-control` whose body carries JSON messages each way,
// each after its length as a little-endian u32: `link.register`, `link.invoke` → `link.result`,
// `link.unpaired`. Messages to the owner's Muse chat go as separate `POST /chat/stream` requests on the
// same session. Commands' parameters and output are never logged. Provenance: TsukumoKit/MUSE-NOTICE.md.

public enum MuseSocketMessage: Sendable { case data(Data), text(String) }

/// The edge refused the upgrade: 401 means fetch fresh VM credentials, 403 not allowed right now.
public struct MuseUpgradeRejected: Error, Equatable { public let status: Int; public init(status: Int) { self.status = status } }

public protocol MuseSocket: Sendable {
    func send(_ data: Data) async throws
    func receive() async throws -> MuseSocketMessage
    func close() async
}
public protocol MuseSocketConnector: Sendable {
    func connect(url: URL, headers: [String: String]) async throws -> any MuseSocket
}

/// What `link.register` says about this device.
public struct MuseDeviceDescription: Sendable {
    public let nodeID, displayName, version: String
    public let registration: MuseRegistration
    public let commands: [MuseCommandSpec]
    public init(nodeID: String, displayName: String, version: String, registration: MuseRegistration, commands: [MuseCommandSpec]) {
        self.nodeID = nodeID; self.displayName = displayName; self.version = version; self.registration = registration; self.commands = commands
    }
    public var registerParams: JSONValue {
        .object([
            "node_id": .string(nodeID), "display_name": .string(displayName), "platform": .string(registration.platform),
            "version": .string(version), "device_family": .string(registration.deviceFamily), "model_id": .string(registration.modelID),
            "is_wakeup_supported": .bool(false),
            "commands_v2": .object(Dictionary(uniqueKeysWithValues: commands.map { ($0.name, $0.json) })),
        ])
    }
}

public enum MuseLink {
    public static let noisePath = "/v1/noise", controlPath = "/link-control", chatPath = "/chat/stream", appID = "musegadget"
    static let requestTimeout: Duration = .seconds(60), handshakeTimeout: Duration = .seconds(20)
    static let maxResponseBytes = 1024 * 1024, maxInbound = 4 * 1024 * 1024, maxConcurrentInvokes = 4
    /// At most this many commands running or waiting; more are refused at once.
    static let maxPendingInvokes = 16
    /// A command's deadline when its spec names none (the SDK's default), and the most any may ask for.
    static let defaultTimeoutMs = 30_000, maxTimeoutMs = 600_000

    /// A whole number of milliseconds from JSON, or nil for anything else (fractions, infinities, huge values).
    static func milliseconds(_ value: JSONValue?) -> Int? {
        guard case .number(let number)? = value, number.isFinite, number.rounded() == number, number >= 1,
              number <= Double(maxTimeoutMs) else { return nil }
        return Int(number)
    }

    /// The deadline for one invoke: the command's own (or the default), shortened if Muse asks for less.
    static func deadline(spec: MuseCommandSpec?, requested: Int?) -> Int {
        let own = min(spec?.timeoutMs ?? defaultTimeoutMs, maxTimeoutMs)
        return min(requested ?? own, own)
    }

    /// `wss://<host>/v1/noise?vm_id=…`, the id escaped as JavaScript's encodeURIComponent does.
    public static func noiseURL(host: String, vmID: String) -> URL? {
        var allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        allowed.insert(charactersIn: "-_.!~*'()")
        let escaped = vmID.addingPercentEncoding(withAllowedCharacters: allowed) ?? vmID
        return URL(string: "wss://\(host)\(noisePath)?vm_id=\(escaped)")
    }

    public static func encode(_ message: [String: JSONValue]) -> Data {
        let body = (try? JSONEncoder().encode(JSONValue.object(message))) ?? Data("{}".utf8)
        var length = UInt32(body.count).littleEndian
        return Data(bytes: &length, count: 4) + body
    }

    /// Splits the control stream into length-prefixed JSON messages, across body chunks.
    public struct MessageDecoder: Sendable {
        private var buffer: [UInt8] = []
        public init() {}
        public mutating func feed(_ data: [UInt8]) throws -> [[String: JSONValue]] {
            buffer += data
            var messages: [[String: JSONValue]] = []
            while buffer.count >= 4 {
                let length = Int(UInt32(buffer[0]) | UInt32(buffer[1]) << 8 | UInt32(buffer[2]) << 16 | UInt32(buffer[3]) << 24)
                guard length <= MuseLink.maxInbound else { throw MuseNoiseError("inbound message too large: \(length)") }
                guard buffer.count >= 4 + length else { break }
                let raw = Array(buffer[4..<4 + length])
                buffer.removeFirst(4 + length)
                guard !raw.isEmpty else { continue }  // keepalive
                guard String(bytes: raw, encoding: .utf8) != nil,
                      case .object(let object)? = try? JSONDecoder().decode(JSONValue.self, from: Data(raw)) else { continue }
                messages.append(object)
            }
            return messages
        }
    }
}

/// The owner's Muse chat accepted (or refused) a message.
public struct MuseChatResult: Sendable, Equatable {
    public let ok: Bool, status: Int
    public let response: JSONValue?
}

public actor MuseLinkSession {
    public enum Outcome: String, Sendable { case closed, authRejected, forbidden, unpaired, stopped }

    let url: URL?
    let token: String
    let device: MuseDeviceDescription
    let handler: any MuseCommandHandler
    let connector: any MuseSocketConnector
    /// Each invoke, its command and how it ended (never its parameters or output).
    let log: @Sendable (String) -> Void

    public private(set) var registeredAt: Date?
    /// Why Muse refused `link.register`, if it did.
    public private(set) var registerRejected: String?

    private var socket: (any MuseSocket)?
    private var transport: MuseNoiseTransport?
    private var controlStream: Int64 = 0
    private var registerID = ""
    private var writer: AsyncStream<Data>.Continuation?
    private var requests: [Int64: PendingRequest] = [:]
    private var invokes: [UUID: Task<Void, Never>] = [:]
    private var running = 0
    /// Handler work started and not yet finished (it may outlive its reply after a timeout).
    private var outstanding = 0
    /// The session is over: no command starts after this, even one whose request was already in.
    private var ended = false
    /// Work waiting for a slot. Each is resumed exactly once: true with a slot, false when the session ended or
    /// the work was cancelled (and then removed).
    private var queued: [(token: UUID, continuation: CheckedContinuation<Bool, Never>)] = []

    private struct PendingRequest {
        var status: Int32 = 0
        var body: [UInt8] = []
        let done: CheckedContinuation<(Int32, [UInt8]), Error>
    }

    public init(noiseHost: String, vmID: String, vmAuthToken: String, device: MuseDeviceDescription, handler: any MuseCommandHandler,
                connector: any MuseSocketConnector, log: @escaping @Sendable (String) -> Void = { _ in }) {
        url = MuseLink.noiseURL(host: noiseHost, vmID: vmID)
        token = vmAuthToken; self.device = device; self.handler = handler; self.connector = connector; self.log = log
    }

    /// Connects, registers, and serves until the session ends. Cancelling the task ends it with `.stopped`.
    public func run() async -> Outcome {
        guard let url else { return .closed }
        let socket: any MuseSocket
        do {
            socket = try await connector.connect(url: url, headers: ["Authorization": "Bearer \(token)"])
        } catch let rejected as MuseUpgradeRejected {
            return rejected.status == 401 ? .authRejected : .forbidden
        } catch {
            return Task.isCancelled ? .stopped : .closed
        }
        self.socket = socket
        let outcome = await withTaskCancellationHandler {
            await serve(socket)
        } onCancel: {
            Task { await socket.close() }
        }
        finish()
        await socket.close()
        return Task.isCancelled ? .stopped : outcome
    }

    private func serve(_ socket: any MuseSocket) async -> Outcome {
        do {
            let (send, receive) = try await Self.withTimeout(MuseLink.handshakeTimeout) { try await Self.handshake(socket) }
            transport = MuseNoiseTransport(send: send, receive: receive)
            log("Noise session established")
        } catch let rejected as MuseUpgradeRejected {
            return rejected.status == 401 ? .authRejected : .forbidden
        } catch {
            return .closed
        }
        startWriter(socket)
        do {
            try openControlStream()
            return try await readLoop(socket)
        } catch let rejected as MuseUpgradeRejected {
            return rejected.status == 401 ? .authRejected : .forbidden
        } catch {
            return .closed
        }
    }

    /// `-> e`, `<- e, ee, s, es`, `-> s, se`. The bearer already authenticated the device at the upgrade,
    /// so message 3's payload is empty.
    static func handshake(_ socket: any MuseSocket) async throws -> (MuseCipherState, MuseCipherState) {
        var initiator = MuseNoiseInitiator()
        try initiator.initialize()
        try await socket.send(Data(try initiator.writeMessage1()))
        guard case .data(let message2) = try await socket.receive() else { throw MuseNoiseError("Noise handshake got a text frame") }
        try initiator.readMessage2(Array(message2))
        try await socket.send(Data(try initiator.writeMessage3()))
        let (send, receive) = try initiator.split()
        return (send, receive)
    }

    static func withTimeout<T: Sendable>(_ limit: Duration, _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                try await Task.sleep(for: limit)
                throw MuseNoiseError("timed out")
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw MuseNoiseError("timed out") }
            return first
        }
    }

    /// One writer sends frames in the order they were encrypted, so the VM's nonces line up.
    private func startWriter(_ socket: any MuseSocket) {
        let (stream, continuation) = AsyncStream<Data>.makeStream()
        writer = continuation
        Task {
            for await frame in stream {
                do { try await socket.send(frame) } catch {
                    await socket.close()
                    return
                }
            }
        }
    }
    private func enqueue(_ frames: [Data]) { for frame in frames { writer?.yield(frame) } }

    private func openControlStream() throws {
        guard let transport else { throw MuseNoiseError("no transport") }
        let (stream, frames) = try transport.request("POST", MuseLink.controlPath, endBody: false)
        controlStream = stream
        enqueue(frames)
        registerID = UUID().uuidString.lowercased()
        try send(["type": .string("req"), "id": .string(registerID), "method": .string("link.register"), "params": device.registerParams])
        log("sent link.register as \(device.nodeID)")
    }

    /// One message on the control stream.
    func send(_ message: [String: JSONValue]) throws {
        guard let transport else { throw MuseNoiseError("no transport") }
        enqueue(try transport.bodyChunk(controlStream, Array(MuseLink.encode(message))))
    }

    // MARK: Receiving

    private func readLoop(_ socket: any MuseSocket) async throws -> Outcome {
        var decoder = MuseLink.MessageDecoder()
        while true {
            let raw: MuseSocketMessage
            do { raw = try await socket.receive() } catch let rejected as MuseUpgradeRejected { throw rejected } catch {
                return .closed
            }
            guard case .data(let data) = raw else { continue }  // text frames are ignored
            guard let transport, let frame = try transport.decrypt(Array(data)) else { continue }
            if frame.streamID != controlStream {
                deliver(frame)
                continue
            }
            let bytes: [UInt8], ended: Bool
            switch frame.kind {
            case .reset: return .closed
            case .response(let response):
                if response.status >= 400 { return response.status == 403 ? .forbidden : .closed }
                bytes = response.body; ended = response.endBody
            case .bodyChunk(let chunk):
                bytes = chunk.data; ended = chunk.endBody
            }
            for message in try decoder.feed(bytes) {
                if let outcome = handle(message) { return outcome }
            }
            if ended { return .closed }
        }
    }

    private func handle(_ message: [String: JSONValue]) -> Outcome? {
        if message["id"]?.stringValue == registerID, message["method"] == nil || message["method"] == .null {
            if let error = message["error"], error != .null {
                registerRejected = Self.describe(error)
                log("link.register refused")
            } else {
                registeredAt = Date()
                log("registered with the Muse")
            }
            return nil
        }
        if let event = message["event"]?.stringValue, event == "link.unpaired" || event == "node.unpaired" { return .unpaired }
        if message["method"]?.stringValue == "link.invoke" {
            // The deadline starts now, when Muse's request arrives, not when a slot frees up.
            let receivedAt = Date()
            // Bounded: past the limit (counting work still finishing after its reply) a command is refused at once.
            guard invokes.count < MuseLink.maxPendingInvokes, outstanding < MuseLink.maxPendingInvokes else {
                if let id = message["id"]?.stringValue, !id.isEmpty {
                    try? send(["method": .string("link.result"), "id": .string(id), "ok": .bool(false),
                               "error": .string("Tsukumo is busy with other requests. Try again shortly.")])
                }
                return nil
            }
            let key = UUID()
            invokes[key] = Task {
                await self.invoke(message, receivedAt: receivedAt)
                self.finished(key)
            }
        }
        return nil
    }

    private func invoke(_ message: [String: JSONValue], receivedAt: Date) async {
        guard let id = message["id"]?.stringValue, !id.isEmpty else { return }
        let command = message["command"]?.stringValue ?? ""
        var params: [String: JSONValue] = [:]
        if case .object(let object)? = message["params"] { params = object }
        let deadline = MuseLink.deadline(spec: device.commands.first { $0.name == command }, requested: MuseLink.milliseconds(message["timeout_ms"]))
        let expires = receivedAt.addingTimeInterval(Double(deadline) / 1000)
        guard !ended, !Task.isCancelled else { return }
        let handler = self.handler
        outstanding += 1
        // The work waits for a slot, then runs the handler with what's left of the deadline; a request already
        // past it when its turn comes is never run.
        let work = Task<MuseCommandResult?, Never> {
            // No slot (the session ended, or this was cancelled while it waited): never run.
            guard await self.acquire() else {
                self.workDone()
                return nil
            }
            let left = Int(expires.timeIntervalSinceNow * 1000)
            guard !Task.isCancelled, !self.ended, left > 0 else {
                self.release()
                self.workDone()
                return nil
            }
            let result = await handler.run(command, params: params, timeoutMs: left)
            self.release()
            self.workDone()
            return result
        }
        let result = await Self.first(of: work, until: expires)
        guard !Task.isCancelled else { return }
        let outcome = result ?? .failed("Timed out after \(deadline / 1000) seconds.")
        let ms = Int(Date().timeIntervalSince(receivedAt) * 1000)
        log("\(TsukumoMuseCommands.printable(command)) \(result == nil ? "timed out" : outcome.isOK ? "ok" : "failed") in \(ms) ms")
        var reply: [String: JSONValue] = ["method": .string("link.result"), "id": .string(id)]
        for (key, value) in outcome.fields { reply[key] = value }
        try? send(reply)
    }

    private func finished(_ key: UUID) { invokes[key] = nil }
    private func workDone() { outstanding -= 1 }

    /// The work's result, or nil at the deadline. At the deadline the work is cancelled (its Gate wait or bot
    /// turn stops) but never awaited, so Muse hears about the timeout at once even if the work ignores the
    /// cancellation; whatever it returns later is dropped. Cancelling the caller cancels the work too.
    static func first(of work: Task<MuseCommandResult?, Never>, until expires: Date) async -> MuseCommandResult? {
        let (stream, continuation) = AsyncStream<MuseCommandResult?>.makeStream()
        let waiter = Task {
            continuation.yield(await work.value)
            continuation.finish()
        }
        let timer = Task {
            let left = expires.timeIntervalSinceNow
            if left > 0 { try? await Task.sleep(for: .milliseconds(Int(left * 1000))) }
            continuation.yield(nil)
            continuation.finish()
        }
        let result = await withTaskCancellationHandler {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next() ?? nil
        } onCancel: {
            work.cancel()
            continuation.finish()
        }
        timer.cancel()
        if result == nil {
            work.cancel()
            waiter.cancel()
        }
        return result
    }

    /// A slot to run in, or false: after the session ended, or when cancelled (before or while waiting), nothing
    /// is queued, and a waiter that's cancelled is removed and told no.
    func acquire() async -> Bool {
        guard !ended, !Task.isCancelled else { return false }
        if running < MuseLink.maxConcurrentInvokes { running += 1; return true }
        let token = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in queued.append((token, continuation)) }
        } onCancel: {
            Task { await self.stopWaiting(token) }
        }
    }
    private func stopWaiting(_ token: UUID) {
        guard let index = queued.firstIndex(where: { $0.token == token }) else { return }
        queued.remove(at: index).continuation.resume(returning: false)
    }
    /// Gives a slot back, or hands it to the next waiter (unless the session ended).
    func release() {
        if !ended, !queued.isEmpty { queued.removeFirst().continuation.resume(returning: true) } else { running -= 1 }
    }
    /// Work waiting for a slot (tests).
    var waitingForSlots: Int { queued.count }

    private func deliver(_ frame: MuseDecryptedFrame) {
        guard var request = requests[frame.streamID] else { return }
        let bytes: [UInt8], ended: Bool
        switch frame.kind {
        case .reset(let reset):
            requests[frame.streamID] = nil
            request.done.resume(throwing: MuseNoiseError("stream reset: \(reset.reason)"))
            return
        case .response(let response): request.status = response.status; bytes = response.body; ended = response.endBody
        case .bodyChunk(let chunk): bytes = chunk.data; ended = chunk.endBody
        }
        request.body += bytes
        if request.body.count > MuseLink.maxResponseBytes {
            requests[frame.streamID] = nil
            request.done.resume(throwing: MuseNoiseError("response too large"))
        } else if ended {
            requests[frame.streamID] = nil
            request.done.resume(returning: (request.status, request.body))
        } else {
            requests[frame.streamID] = request
        }
    }

    // MARK: To the owner's Muse chat

    /// Posts a message to the owner's Muse as coming from this device (`device_id` is the node id), to the
    /// main chat, or a side chat with `sessionID`. The reply appears in the Muse chat, not here.
    public func sendChat(_ text: String, sessionID: String? = nil) async throws -> MuseChatResult {
        guard let transport, registeredAt != nil else { throw MuseNoiseError("not connected to the Muse") }
        var body: [String: JSONValue] = ["message": .string(text), "output_modality": .string("text"), "device_id": .string(device.nodeID)]
        if let sessionID { body["session_id"] = .string(sessionID) }
        let data = Array((try? JSONEncoder().encode(JSONValue.object(body))) ?? Data())
        let headers = [MuseHeader("Content-Type", "application/json"), MuseHeader("x-request-id", UUID().uuidString.lowercased()),
                       MuseHeader("x-app-id", MuseLink.appID)]
        let (stream, frames) = try transport.request("POST", MuseLink.chatPath, body: data, headers: headers, endBody: true)
        let timeout = Task { [weak self] in
            try? await Task.sleep(for: MuseLink.requestTimeout)
            await self?.fail(stream, MuseNoiseError("timed out"))
        }
        defer { timeout.cancel() }
        let (status, response) = try await withCheckedThrowingContinuation { continuation in
            requests[stream] = PendingRequest(done: continuation)
            enqueue(frames)
        }
        let decoded = response.isEmpty ? nil : (try? JSONDecoder().decode(JSONValue.self, from: Data(response)))
            ?? .string(String(decoding: response.prefix(2000), as: UTF8.self))
        return MuseChatResult(ok: (200..<300).contains(Int(status)), status: Int(status), response: decoded)
    }

    private func fail(_ stream: Int64, _ error: Error) {
        requests.removeValue(forKey: stream)?.done.resume(throwing: error)
    }

    private func finish() {
        ended = true
        for task in invokes.values { task.cancel() }
        invokes = [:]
        // Everything waiting is told no, and nothing can queue after this (`acquire` checks `ended`).
        for waiter in queued { waiter.continuation.resume(returning: false) }
        queued = []
        for (_, request) in requests { request.done.resume(throwing: MuseNoiseError("session ended")) }
        requests = [:]
        writer?.finish()
        writer = nil
        transport = nil
    }

    static func describe(_ value: JSONValue) -> String {
        if let text = value.stringValue { return String(text.prefix(200)) }
        if let message = value["message"]?.stringValue { return String(message.prefix(200)) }
        return "refused"
    }
}

extension MuseCommandResult {
    var isOK: Bool { if case .ok = self { true } else { false } }
}

// MARK: URLSession's WebSocket

public struct URLSessionMuseConnector: MuseSocketConnector {
    public init() {}
    public func connect(url: URL, headers: [String: String]) async throws -> any MuseSocket {
        var request = URLRequest(url: url, timeoutInterval: 20)
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        let session = URLSession(configuration: .ephemeral, delegate: MuseNoRedirects(), delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
        task.resume()
        return URLSessionMuseSocket(task: task, session: session)
    }
}

final class URLSessionMuseSocket: MuseSocket, @unchecked Sendable {
    let task: URLSessionWebSocketTask
    let session: URLSession
    private var pinger: Task<Void, Never>?

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
        // Pings every 20 seconds, as the SDK's client does; a missed one ends the connection.
        pinger = Task { [task] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                task.sendPing { error in if error != nil { task.cancel(with: .goingAway, reason: nil) } }
            }
        }
    }
    deinit { pinger?.cancel() }

    private func mapped(_ error: Error) -> Error {
        if let http = task.response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            return MuseUpgradeRejected(status: http.statusCode)
        }
        return error
    }
    func send(_ data: Data) async throws {
        do { try await task.send(.data(data)) } catch { throw mapped(error) }
    }
    func receive() async throws -> MuseSocketMessage {
        do {
            switch try await task.receive() {
            case .data(let data): return .data(data)
            case .string(let text): return .text(text)
            @unknown default: return .text("")
            }
        } catch { throw mapped(error) }
    }
    func close() async {
        pinger?.cancel()
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }
}
#endif
