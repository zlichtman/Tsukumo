import Foundation
import Observation

// The Mac side of the Tsukumo relay: one outbound WebSocket that gives the KemoSabe gateway a public address, so
// cloud agents (Claude, ChatGPT, Grok, OpenClaw) can reach it while nothing on the owner's network listens. It
// registers this Mac's key once, then reconnects with a fresh challenge each time (jittered backoff, a ping every
// 30 seconds), and passes each relayed request into the gateway through the same `GatewayServer.respond(to:via:)`
// the loopback socket uses, marked `.relay`, then returns the answer whole or streamed under the relay's flow-control
// window. The wire format is `RelayEnvelope`'s alone. Off until the owner turns it on in Settings, Gateway.

@MainActor @Observable public final class RelayConnection {
    public enum Status: Equatable, Sendable {
        /// Not turned on, or disconnected by the owner.
        case off
        case connecting
        /// Live: the public address is reachable while this Mac is awake.
        case connected(publicBase: String)
        /// Lost or refused; trying again after a pause.
        case retrying(reason: String)
        /// Stopped for a reason the owner should see (replaced, an address the relay deleted, a bad setting).
        case stopped(reason: String)
    }

    public private(set) var status: Status = .off
    /// The device key's kind, once there is one (Secure Enclave or software).
    public private(set) var keyKind: RelayDeviceKey.Kind?

    let store: GatewayStore
    private let keys: any RelayKeyStore
    private let transport: any RelayTransport
    private let secureEnclave: Bool
    /// Where each relayed request goes: the gateway server's `respond(to:via:)`.
    private let handler: @MainActor ((HTTPRequest.ParseResult, HTTPRequest?)) async -> HTTPResponse
    /// Seams for tests: the pauses, the jitter, and the keepalive.
    var backoffFirst: Duration = .seconds(1)
    var backoffMax: Duration = .seconds(60)
    var pingInterval: Duration = RelayEnvelope.pingInterval
    /// A socket that has said nothing (not even `pong`) for this long is treated as gone.
    var silenceLimit: Duration = .seconds(75)
    var jitter: @Sendable () -> Double = { Double.random(in: 0.5...1.0) }
    var largestBody = HTTPRequest.maxBody
    var unregisterTimeout: Duration = .seconds(10)
    /// The relay is hostile until proven otherwise: everything it can make this Mac hold or wait on is bounded.
    /// How long the relay has to send `ready` once the socket opens.
    var handshakeTimeout: Duration = .seconds(15)
    /// A streamed request body must keep arriving (the relay's own limits: 15 seconds idle, 60 in all).
    var uploadIdleTimeout: Duration = .seconds(15)
    var uploadTotalTimeout: Duration = .seconds(60)
    /// How long a streamed answer waits for the relay to acknowledge room in its window (since its last real progress),
    /// and for room in the socket's queue.
    var ackTimeout: Duration = .seconds(60)
    var roomTimeout: Duration = .seconds(60)
    /// Request body bytes held across every request at once (16 uploads of 15 MB would be 240 MB).
    var maxBufferedBytes = 24 * 1_024 * 1_024
    /// Requests admitted at once: uploading, or with a handler still running (a cancelled one too, until it exits).
    var maxInFlight = RelayEnvelope.maxInFlight
    var outboxSoftLimit = RelayOutbox.defaultSoftLimit
    var outboxHardLimit = RelayOutbox.defaultHardLimit
    /// Handlers running now, across sockets: a slot is freed only when its handler actually exits.
    private(set) var busy = 0
    /// Request body bytes charged now: from the first chunk until the handler that holds the parsed body exits.
    private(set) var buffered = 0

    private var loop: Task<Void, Never>?
    private var socket: (any RelaySocket)?
    /// Every frame to the relay goes through the live socket's outbox, in order.
    private var outbox: RelayOutbox?
    private var generation = 0
    private var requests: [String: RelayedRequest] = [:]
    /// The deletion in progress: the socket it was sent on (only that socket's `unregistered` or 4001 confirms it),
    /// its first caller, and any later callers, who join it instead of starting another.
    private final class Deletion {
        var outbox: RelayOutbox?
        var first: CheckedContinuation<Bool, Never>?
        var joiners: [CheckedContinuation<Bool, Never>] = []
    }
    private var deletion: Deletion?
    /// A deletion is in progress (Settings disables Delete This Address meanwhile).
    public var deleting: Bool { deletion != nil }
    private var askedToUnregister = false
    /// Said when the relay takes no new registrations (HTTP 503 `registrations_closed`, or 4001 after a registration
    /// it couldn't confirm). Connect tries again.
    public static let relayFull = "This relay is full right now. Try again later."
    private var lastHeard = ContinuousClock.now
    /// The relay's own `Retry-After`, honored as the next pause's floor (at most a minute).
    private var pauseFloor: Duration = .zero

    public init(server: GatewayServer, store: GatewayStore, keys: any RelayKeyStore, transport: any RelayTransport = URLSessionRelayTransport(),
                secureEnclave: Bool = true) {
        self.store = store; self.keys = keys; self.transport = transport; self.secureEnclave = secureEnclave
        handler = { [weak server] parsed in await server?.respond(to: parsed, via: .relay) ?? .status(503) }
    }

    /// With another handler in place of the gateway (tests of streaming and cancel).
    init(handler: @escaping @MainActor ((HTTPRequest.ParseResult, HTTPRequest?)) async -> HTTPResponse, store: GatewayStore,
         keys: any RelayKeyStore, transport: any RelayTransport) {
        self.store = store; self.keys = keys; self.transport = transport; secureEnclave = false
        self.handler = handler
    }

    /// The public MCP address agents connect to, while there is one.
    public var publicMCPURL: String? { store.settings.publicBaseString.map { $0 + "/mcp" } }
    public var running: Bool { loop != nil }

    // MARK: Owner actions

    /// Matches the settings: connects while the gateway and the public address are on and a relay is set.
    public func apply() {
        let settings = store.settings
        guard settings.enabled, settings.relayEnabled else { stop(); return }
        guard settings.relay != nil else { stop(); status = .stopped(reason: "Enter your relay’s address."); return }
        // A connection stopped for a reason (replaced) waits for the owner's Connect, never another setting changing.
        if loop == nil, !stopped { start() }
    }
    var stopped: Bool { if case .stopped = status { true } else { false } }
    /// The public base while connected.
    public var connectedBase: String? { if case .connected(let base) = status { base } else { nil } }

    /// Connects (or reconnects after the owner disconnected or it stopped).
    public func start() {
        stop()
        askedToUnregister = false
        generation += 1
        let mine = generation
        status = .connecting
        loop = Task { [weak self] in await self?.run(mine) }
    }

    /// Disconnects; the registration and its address stay, so agents reconnect when it comes back.
    public func stop() {
        generation += 1
        loop?.cancel()
        loop = nil
        socket?.close(code: RelayEnvelope.Close.normal)
        socket = nil
        outbox?.finish()
        outbox = nil
        dropRequests()
        status = .off
    }

    /// Deletes this Mac's address on the relay (`unregister`), then forgets the device id, the public base, and the
    /// key. Returns whether the relay confirmed it; the local copies are forgotten either way.
    /// A second call while one runs joins it and gets the same answer.
    @discardableResult public func unregister() async -> Bool {
        if let deletion { return await withCheckedContinuation { deletion.joiners.append($0) } }
        let deletion = Deletion()
        self.deletion = deletion
        var confirmed = false
        if let outbox, case .connected = status {
            let timeout = unregisterTimeout
            deletion.outbox = outbox
            askedToUnregister = true
            confirmed = await withCheckedContinuation { continuation in
                deletion.first = continuation
                outbox.push(RelayEnvelope.unregister)
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: timeout)
                    self?.answer(deletion, false)
                }
            }
        }
        stop()
        forgetRegistration()
        store.update { $0.relayEnabled = false }
        self.deletion = nil
        deletion.joiners.forEach { $0.resume(returning: confirmed) }
        return confirmed
    }

    private func answer(_ deletion: Deletion, _ confirmed: Bool) {
        deletion.first?.resume(returning: confirmed)
        deletion.first = nil
    }

    /// The relay confirmed a deletion, on `outbox`: it counts only if that's the socket the deletion was sent on.
    private func finishUnregistering(from outbox: RelayOutbox) {
        guard let deletion, let sentOn = deletion.outbox, sentOn === outbox else { return }
        answer(deletion, true)
    }

    private func forgetRegistration() {
        store.update { $0.relayDeviceID = ""; $0.publicBaseURL = "" }
        try? RelayDeviceKey.delete(store: keys)
        keyKind = nil
    }

    // MARK: The connection loop

    private func current(_ mine: Int) -> Bool { mine == generation && !Task.isCancelled }

    private func run(_ mine: Int) async {
        var delay = backoffFirst
        while current(mine) {
            let outcome = await connectOnce(mine)
            guard current(mine) else { return }
            switch outcome {
            case .stop(let reason):
                status = reason.map { .stopped(reason: $0) } ?? .off
                loop = nil
                return
            case .again(let reason, let fresh):
                if fresh { delay = backoffFirst }
                status = .retrying(reason: reason)
                let pause = max(delay * jitter(), pauseFloor)
                pauseFloor = .zero
                delay = min(delay * 2, backoffMax)
                try? await Task.sleep(for: pause)
            case .now:
                continue
            }
        }
    }

    private enum Outcome { case stop(String?), again(String, fresh: Bool), now }

    private func connectOnce(_ mine: Int) async -> Outcome {
        let settings = store.settings
        guard let relay = settings.relay else { return .stop("Enter your relay’s address.") }
        let key: RelayDeviceKey
        do { key = try RelayDeviceKey.loadOrCreate(store: keys, secureEnclave: secureEnclave) } catch {
            return .stop("Tsukumo couldn’t keep this Mac’s key in the Keychain.")
        }
        keyKind = key.kind
        let known = RelayEnvelope.validDeviceID(settings.relayDeviceID) ? settings.relayDeviceID : nil
        status = .connecting

        // 1. A challenge (a new device id too, when registering).
        let challenge: RelayEnvelope.Challenge
        do {
            let (code, body, retryAfter) = try await transport.challenge(RelayEnvelope.challengeURL(relay: relay, deviceID: known))
            guard current(mine) else { return .stop(nil) }
            switch code {
            case 200: break
            case 404 where known != nil:
                // The relay forgot this Mac (its lease ran out after 30 days away): register again, with a new address.
                store.update { $0.relayDeviceID = ""; $0.publicBaseURL = "" }
                return .now
            case 429: return .again("The relay asked Tsukumo to wait.", fresh: false)
            // 503 without Retry-After is `registrations_closed`; with it, the relay is busy: wait as long as it asks.
            case 503 where known == nil && retryAfter == nil: return .stop(Self.relayFull)
            case 503:
                pauseFloor = .seconds(min(60, max(0, retryAfter ?? 0)))
                return .again("The relay is busy right now.", fresh: false)
            default: return .again("The relay answered \(code).", fresh: false)
            }
            guard let decoded = try? JSONDecoder().decode(RelayEnvelope.Challenge.self, from: body), decoded.protocolName == RelayEnvelope.protocolName,
                  decoded.mode == (known == nil ? .register : .connect), RelayEnvelope.validDeviceID(decoded.deviceID),
                  known.map({ $0 == decoded.deviceID }) ?? true, (1...200).contains(decoded.nonce.count) else {
                return .again("The relay’s answer wasn’t one Tsukumo understands.", fresh: false)
            }
            challenge = decoded
        } catch {
            return .again("Can’t reach the relay.", fresh: false)
        }

        // 2. The socket, with the signature on the upgrade request.
        let socket: any RelaySocket
        do {
            let signature = try key.sign(RelayEnvelope.authMessage(mode: challenge.mode, deviceID: challenge.deviceID, nonce: challenge.nonce))
            let headers = RelayEnvelope.upgradeHeaders(nonce: challenge.nonce, signature: signature,
                                                       publicKey: challenge.mode == .register ? key.publicKey : nil)
            socket = try await transport.connect(RelayEnvelope.connectURL(relay: relay, deviceID: challenge.deviceID), headers: headers)
        } catch let closed as RelayClosed {
            return refused(closed, registering: challenge.mode == .register)
        } catch {
            return .again("Can’t reach the relay.", fresh: false)
        }
        guard current(mine) else { socket.close(code: RelayEnvelope.Close.normal); return .stop(nil) }
        self.socket = socket

        // 3. The first frame is `ready`, within the handshake deadline.
        let late = RelayFlag()
        let timeout = handshakeTimeout
        let timer = Task { [weak socket] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            late.set()
            socket?.close(code: RelayEnvelope.Close.normal)
        }
        defer { timer.cancel() }
        do {
            let first = try await socket.receive()
            timer.cancel()
            guard current(mine) else { socket.close(code: RelayEnvelope.Close.normal); return .stop(nil) }
            guard case .ready(let id, let base, let registered)? = RelayEnvelope.parse(first), id == challenge.deviceID,
                  registered == (challenge.mode == .register), let publicBase = acceptable(base, relay: relay, deviceID: id) else {
                socket.close(code: RelayEnvelope.Close.protocolError)
                if self.socket === socket { self.socket = nil }
                return .again("The relay’s answer wasn’t one Tsukumo understands.", fresh: false)
            }
            store.update { $0.relayDeviceID = id; $0.publicBaseURL = publicBase }
            status = .connected(publicBase: publicBase)
        } catch let closed as RelayClosed {
            // A stale handshake (the owner restarted meanwhile) clears only its own socket, never the replacement.
            if self.socket === socket { self.socket = nil }
            guard current(mine) else { return .stop(nil) }
            if late.isSet { return .again("The relay didn’t finish connecting.", fresh: false) }
            return refused(closed, registering: challenge.mode == .register)
        } catch {
            if self.socket === socket { self.socket = nil }
            guard current(mine) else { return .stop(nil) }
            return .again(late.isSet ? "The relay didn’t finish connecting." : "The connection to the relay dropped.", fresh: false)
        }

        // 4. Serve until it closes.
        let outbox = RelayOutbox(socket, softLimit: outboxSoftLimit, hardLimit: outboxHardLimit)
        // A relay that stops reading fills the queue; past the hard limit the socket closes and the client starts over.
        outbox.onSaturated = { [weak socket] in socket?.close(code: 1008) }
        self.outbox = outbox
        lastHeard = .now
        let started = ContinuousClock.now
        let keepalive = Task { [weak self] in await self?.keepAlive(outbox, mine) }
        defer { keepalive.cancel() }
        var outcome = await serve(socket, outbox, mine)
        outbox.finish()
        if self.socket === socket { self.socket = nil; self.outbox = nil }
        // Only this socket's requests: after a restart, the new connection's are none of this cleanup's business.
        dropRequests(of: outbox)
        // A connection that lasted starts the pauses over; one that keeps dropping at once backs off.
        if case .again(let reason, _) = outcome { outcome = .again(reason, fresh: ContinuousClock.now - started > .seconds(60)) }
        return outcome
    }

    /// The public base from `ready`, when it's an address the gateway accepts and it names this device: the relay's
    /// own host with `/d/<id>`, or a per-device origin whose first label is the id.
    private func acceptable(_ base: String, relay: URL, deviceID: String) -> String? {
        guard let url = GatewaySettings.validPublicBase(base), let host = url.host()?.lowercased() else { return nil }
        let path = url.path(percentEncoded: true)
        if path.isEmpty {
            // A per-device origin is on the default port only.
            guard url.scheme == "https", url.port == nil, host == deviceID + "." + (relay.host()?.lowercased() ?? "") else { return nil }
        } else {
            guard path == "/d/" + deviceID, GatewaySettings.origin(of: url) == GatewaySettings.origin(of: relay) else { return nil }
        }
        return GatewaySettings.trimmed(url.absoluteString)
    }

    /// What a refused upgrade or a close means.
    private func refused(_ closed: RelayClosed, registering: Bool) -> Outcome {
        if let status = closed.httpStatus {
            switch status {
            case 401: return .again("The relay didn’t accept this Mac’s signature. Trying again.", fresh: false)
            case 404 where !registering:
                store.update { $0.relayDeviceID = ""; $0.publicBaseURL = "" }
                return .now
            case 429: return .again("The relay is taking no more registrations from this network today.", fresh: false)
            case 409: return .again("The relay is finishing a deletion. Trying again soon.", fresh: false)
            // 503 without Retry-After is `registrations_closed` (the relay is full); with it, `relay_busy` (it couldn't
            // finish confirming this device): a fresh challenge after the pause it asked for.
            case 503 where registering && closed.retryAfter == nil: return .stop(Self.relayFull)
            case 503:
                pauseFloor = .seconds(min(60, max(0, closed.retryAfter ?? 0)))
                return .again("The relay is busy right now.", fresh: false)
            default: return .again("The relay answered \(status).", fresh: false)
            }
        }
        switch closed.code {
        case RelayEnvelope.Close.replaced:
            return .stop("Another connection replaced this one. Connect again to take the address back.")
        case RelayEnvelope.Close.unregistered:
            forgetRegistration()
            // Asked for (Delete This Address): done. Unasked: the relay filled up before it could confirm this
            // registration and deleted it, so wait for the owner to try again later (Connect registers anew).
            guard askedToUnregister else { return .stop(Self.relayFull) }
            store.update { $0.relayEnabled = false }
            return .stop(nil)
        default:
            return .again("The connection to the relay dropped.", fresh: true)
        }
    }

    private func serve(_ socket: any RelaySocket, _ outbox: RelayOutbox, _ mine: Int) async -> Outcome {
        while current(mine) {
            let text: String
            do { text = try await socket.receive() } catch let closed as RelayClosed {
                // Only this socket, while it's still the current one, can confirm a deletion sent on it.
                if closed.code == RelayEnvelope.Close.unregistered, current(mine) { finishUnregistering(from: outbox) }
                return current(mine) ? refused(RelayClosed(code: closed.code), registering: false) : .stop(nil)
            } catch {
                return .again("The connection to the relay dropped.", fresh: false)
            }
            guard current(mine) else { return .stop(nil) }
            lastHeard = .now
            guard let frame = RelayEnvelope.parse(text) else {
                socket.close(code: text.utf8.count > RelayEnvelope.maxFrameChars ? RelayEnvelope.Close.frameTooLarge : RelayEnvelope.Close.protocolError)
                return .again("The relay sent something Tsukumo didn’t understand.", fresh: false)
            }
            receive(frame, on: outbox)
        }
        return .stop(nil)
    }

    /// A ping every 30 seconds; a socket silent for longer than `silenceLimit` (no pong) is closed and reconnected.
    private func keepAlive(_ outbox: RelayOutbox, _ mine: Int) async {
        while current(mine) {
            try? await Task.sleep(for: pingInterval)
            guard current(mine), self.outbox === outbox else { return }
            if ContinuousClock.now - lastHeard > silenceLimit {
                socket?.close(code: 1001)
                return
            }
            outbox.push(RelayEnvelope.ping)
        }
    }

    // MARK: Requests

    private final class RelayedRequest {
        let head: RelayEnvelope.RequestHead
        var body = Data()
        var bodyDone: Bool
        var tooLarge = false
        let started = ContinuousClock.now
        var lastChunk = ContinuousClock.now
        var watchdog: Task<Void, Never>?
        /// Answered (a `res` went out): body frames that still arrive are dropped.
        var answered = false
        var cancelled = false
        var task: Task<Void, Never>?
        /// The socket this request came in on: its frames and its cleanup are that socket's alone.
        let outbox: RelayOutbox
        /// The answer's flow-control window: bytes queued or sent and not yet acknowledged, and of those the bytes the
        /// socket actually sent (an ack may cover only those).
        let window = RelayWindow()
        var lastProgress = ContinuousClock.now
        /// Body bytes charged to `buffered`.
        var charge = 0
        var waiter: CheckedContinuation<Void, Never>?
        init(head: RelayEnvelope.RequestHead, bodyDone: Bool, outbox: RelayOutbox) { self.head = head; self.bodyDone = bodyDone; self.outbox = outbox }
        func wake() { waiter?.resume(); waiter = nil }
        func end() { cancelled = true; task?.cancel(); watchdog?.cancel(); body = Data(); wake() }
    }

    private func receive(_ frame: RelayEnvelope.Inbound, on socket: RelayOutbox) {
        switch frame {
        case .request(let head, let body, let streamed):
            guard requests[head.id] == nil else { return }
            let uploading = requests.values.filter { $0.task == nil }.count
            guard uploading + busy < maxInFlight, buffered + body.count <= maxBufferedBytes else {
                send(.status(503, headers: [("Retry-After", "5")]), id: head.id, method: head.method, on: socket)
                return
            }
            let request = RelayedRequest(head: head, bodyDone: !streamed, outbox: socket)
            request.body = body
            charge(request, body.count)
            requests[head.id] = request
            if streamed { watch(request, on: socket) } else { answer(request, on: socket) }
        case .chunk(let id, let data):
            guard let request = requests[id], request.outbox === socket, !request.bodyDone, !request.cancelled else { return }
            if request.answered || request.tooLarge { return }
            if request.body.count + data.count > largestBody {
                // Over the gateway's own limit: refused with the same 413 a local request gets, and nothing more is taken.
                request.tooLarge = true
                request.body = Data()
                finishEarly(request, .status(413), on: socket)
                return
            }
            if buffered + data.count > maxBufferedBytes {
                // Too much held across every request at once (uploads, and bodies handlers still hold): this one is
                // refused, and its bytes let go.
                request.tooLarge = true
                request.body = Data()
                finishEarly(request, .status(503, headers: [("Retry-After", "5")]), on: socket)
                return
            }
            request.body.append(data)
            charge(request, data.count)
            request.lastChunk = .now
            socket.push(RelayEnvelope.ack(id: id, bytes: data.count))
        case .end(let id):
            guard let request = requests[id], request.outbox === socket, !request.bodyDone else { return }
            request.bodyDone = true
            request.watchdog?.cancel()
            if !request.answered && !request.cancelled && !request.tooLarge { answer(request, on: socket) }
        case .cancel(let id):
            // The id is gone at once (late answers are suppressed), but its slot is held until the handler exits (`busy`).
            guard let request = requests[id], request.outbox === socket else { return }
            requests[id] = nil
            request.end()
            if request.task == nil { release(request) }
        case .ack(let id, let bytes):
            guard let request = requests[id], request.outbox === socket, !request.cancelled else { return }
            guard bytes > 0, request.window.acknowledge(bytes) else {
                // An empty ack, or one for bytes the socket hasn't sent, is a protocol error: never a way to open the
                // window or to hold a slot with no progress.
                self.socket?.close(code: RelayEnvelope.Close.protocolError)
                return
            }
            request.lastProgress = .now
            request.wake()
        case .invalid(let id?):
            // A malformed chunk ends its request with a 400.
            if let request = requests[id], request.outbox === socket { finishEarly(request, .status(400), on: socket) }
        case .badRequest(let id):
            // A malformed request (an inline body over 256 KiB, bad base64) gets its one answer: 400.
            if requests[id] == nil { send(.status(400), id: id, method: "GET", on: socket) }
        case .unregistered:
            finishUnregistering(from: socket)
        case .ready, .pong, .unknown, .invalid:
            break
        }
    }

    /// Answers before the body is all in (413, 400): the relay stops sending it, and whatever still comes is dropped.
    private func finishEarly(_ request: RelayedRequest, _ response: HTTPResponse, on socket: RelayOutbox) {
        guard !request.answered else { return }
        request.answered = true
        send(response, id: request.head.id, method: request.head.method, on: socket)
        request.end()
        if request.task == nil { release(request) }
        // Gone at once: whatever still comes for this id is ignored, and its slot is free.
        if requests[request.head.id] === request { requests[request.head.id] = nil }
    }

    private func charge(_ request: RelayedRequest, _ bytes: Int) {
        request.charge += bytes
        buffered += bytes
    }
    /// Lets a request's body bytes go from the budget, once.
    private func release(_ request: RelayedRequest) {
        buffered -= request.charge
        request.charge = 0
    }

    /// The window's bytes for a request (tests).
    func window(_ id: String) -> (reserved: Int, sent: Int)? { requests[id].map { ($0.window.reserved, $0.window.sent) } }

    /// A streamed upload's deadlines: 408 when it goes quiet too long or takes too long in all.
    private func watch(_ request: RelayedRequest, on socket: RelayOutbox) {
        let idle = uploadIdleTimeout, total = uploadTotalTimeout
        let tick = min(idle, total) / 4
        request.watchdog = Task { @MainActor [weak self, weak request] in
            while !Task.isCancelled {
                try? await Task.sleep(for: tick)
                guard let self, let request, self.requests[request.head.id] === request, !request.bodyDone, !request.answered, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                if now - request.lastChunk > idle || now - request.started > total {
                    self.finishEarly(request, .status(408), on: socket)
                    return
                }
            }
        }
    }

    private func answer(_ request: RelayedRequest, on socket: RelayOutbox) {
        let id = request.head.id
        let parsed: (HTTPRequest.ParseResult, HTTPRequest?)
        if let wire = RelayEnvelope.wire(request.head, body: request.body) { parsed = HTTPRequest.parse(wire) } else { parsed = (.invalid(400), nil) }
        request.body = Data()
        busy += 1
        request.task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                // The parsed body was the handler's until now: its bytes stay charged until here.
                self.busy -= 1
                self.release(request)
                if self.requests[id] === request { self.requests[id] = nil }
            }
            let response = await self.handler(parsed)
            guard !request.cancelled, !Task.isCancelled, self.requests[id] === request else { return }
            request.answered = true
            await self.deliver(response, for: request, on: socket)
        }
    }

    /// Sends the gateway's answer: whole in one `res` when its body fits in 256 KiB, otherwise `res` with `stream`,
    /// chunks of at most 256 KiB with at most 1 MiB unacknowledged, and `end`.
    private func deliver(_ response: HTTPResponse, for request: RelayedRequest, on socket: RelayOutbox) async {
        let id = request.head.id
        let headers = RelayEnvelope.responseHeaders(response)
        let body = RelayEnvelope.bodyless(method: request.head.method, status: response.status) ? Data() : response.body
        if body.count <= RelayEnvelope.maxChunkBytes {
            socket.push(RelayEnvelope.response(id: id, status: response.status, headers: headers, body: body, stream: false))
            return
        }
        socket.push(RelayEnvelope.response(id: id, status: response.status, headers: headers, body: nil, stream: true))
        var offset = 0
        while offset < body.count {
            let piece = body.subdata(in: offset..<min(offset + RelayEnvelope.maxChunkBytes, body.count))
            request.lastProgress = .now
            while request.window.reserved + piece.count > RelayEnvelope.windowBytes, !request.cancelled, !socket.finished {
                // The deadline runs from the last real progress (an ack for sent bytes), not from the last wake.
                let left = ackTimeout - (ContinuousClock.now - request.lastProgress)
                if left <= .zero { request.end(); return }
                let deadline = Task { @MainActor [weak request] in
                    try? await Task.sleep(for: left)
                    guard !Task.isCancelled, let request else { return }
                    request.wake()
                }
                // Every cancel goes through `request.end()`, which wakes this wait at once.
                if !request.cancelled { await withCheckedContinuation { request.waiter = $0 } }
                deadline.cancel()
                if Task.isCancelled { return }
            }
            // And room in the socket's queue, within a deadline and cancellable: a relay that stops reading slows the
            // stream, never fills memory or holds the slot.
            guard await socket.room(within: roomTimeout) else { request.end(); return }
            guard !request.cancelled, !socket.finished, requests[id] === request else { return }
            request.window.reserve(piece.count)
            let window = request.window, size = piece.count
            socket.push(RelayEnvelope.chunk(id: id, data: piece)) { window.sent(size) }
            offset += piece.count
        }
        socket.push(RelayEnvelope.end(id: id))
    }

    private func send(_ response: HTTPResponse, id: String, method: String, on socket: RelayOutbox) {
        let body = RelayEnvelope.bodyless(method: method, status: response.status) ? Data() : response.body
        let text = RelayEnvelope.response(id: id, status: response.status, headers: RelayEnvelope.responseHeaders(response), body: body, stream: false)
        socket.push(text)
    }

    /// Ends requests: every one (`stop`), or only those of one socket (that socket's own cleanup).
    private func dropRequests(of outbox: RelayOutbox? = nil) {
        for (id, request) in requests where outbox == nil || request.outbox === outbox {
            request.end()
            if request.task == nil { release(request) }
            requests[id] = nil
        }
    }
}

/// The frames to one socket, sent in order by one writer, with the bytes queued and not yet handed to the socket
/// counted. A relay that stops reading can't make the queue grow without bound: streamed answers wait for room
/// (`room()`, below `softLimit`), and anything that would take the queue past `hardLimit` (acks and inline answers
/// piling up) closes the socket instead (`onSaturated`), and the connection starts over. `finished` once the socket
/// failed, saturated, or was closed.
final class RelayOutbox: @unchecked Sendable {
    static let defaultSoftLimit = 1_024 * 1_024, defaultHardLimit = 8 * 1_024 * 1_024
    let softLimit: Int, hardLimit: Int
    private typealias Frame = (text: String, onSent: (@Sendable () -> Void)?)
    private let continuation: AsyncStream<Frame>.Continuation
    private let lock = NSLock()
    private var done = false
    private var queued = 0
    private var waiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Waits registered now (tests).
    var waitCount: Int { lock.withLock { waiters.count } }
    /// Called once, off the main actor, when the queue would pass `hardLimit`.
    var onSaturated: (@Sendable () -> Void)?
    var finished: Bool { lock.withLock { done } }
    var queuedBytes: Int { lock.withLock { queued } }

    init(_ socket: any RelaySocket, softLimit: Int = RelayOutbox.defaultSoftLimit, hardLimit: Int = RelayOutbox.defaultHardLimit) {
        self.softLimit = softLimit; self.hardLimit = hardLimit
        let (stream, continuation) = AsyncStream<Frame>.makeStream()
        self.continuation = continuation
        Task { [weak self] in
            for await frame in stream {
                // Counted as handed to the socket right before the send: the relay can ack a chunk as soon as it has it,
                // even before this send returns, but never bytes still waiting in this queue.
                frame.onSent?()
                do { try await socket.send(frame.text) } catch { self?.finish(); return }
                self?.sent(frame.text.utf8.count)
            }
        }
    }

    /// Queues a frame. False when the outbox is finished or this frame saturated it (the socket is then closed).
    @discardableResult func push(_ text: String, onSent: (@Sendable () -> Void)? = nil) -> Bool {
        let size = text.utf8.count
        lock.lock()
        guard !done else { lock.unlock(); return false }
        guard queued + size <= hardLimit else {
            lock.unlock()
            let saturated = onSaturated
            finish()
            saturated?()
            return false
        }
        queued += size
        lock.unlock()
        continuation.yield((text, onSent))
        return true
    }

    /// Waits until the queue is under `softLimit`. True when there's room; false when the outbox finished, the
    /// deadline passed, or the task was cancelled (which resumes it at once).
    func room(within limit: Duration) async -> Bool {
        let id = UUID()
        // This wait's own cancelled mark (read and written under `lock`): nothing outlives the wait.
        let cancelled = RelayFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Bool, Never>) in
                lock.lock()
                if done || cancelled.isSet || Task.isCancelled { lock.unlock(); waiter.resume(returning: false); return }
                if queued < softLimit { lock.unlock(); waiter.resume(returning: true); return }
                waiters[id] = waiter
                lock.unlock()
                Task { [weak self] in
                    try? await Task.sleep(for: limit)
                    self?.resolve(id, false)
                }
            }
        } onCancel: {
            lock.lock()
            cancelled.set()
            let waiter = waiters.removeValue(forKey: id)
            lock.unlock()
            waiter?.resume(returning: false)
        }
    }

    private func resolve(_ id: UUID, _ value: Bool) {
        let waiter = lock.withLock { waiters.removeValue(forKey: id) }
        waiter?.resume(returning: value)
    }

    private func sent(_ size: Int) {
        lock.lock()
        queued = max(0, queued - size)
        var ready: [CheckedContinuation<Bool, Never>] = []
        if queued < softLimit { ready = Array(waiters.values); waiters = [:] }
        lock.unlock()
        ready.forEach { $0.resume(returning: true) }
    }

    func finish() {
        lock.lock()
        done = true
        let ready = Array(waiters.values)
        waiters = [:]
        lock.unlock()
        continuation.finish()
        ready.forEach { $0.resume(returning: false) }
    }
}

/// A flag set from any thread.
final class RelayFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

/// One streamed answer's flow-control window, shared with the socket's writer: `reserved` counts bytes queued or sent
/// and not yet acknowledged (what the window limits), `sent` the part the socket actually sent (all an ack may cover).
final class RelayWindow: @unchecked Sendable {
    private let lock = NSLock()
    private var queuedOrSent = 0
    private var transmitted = 0
    var reserved: Int { lock.withLock { queuedOrSent } }
    var sent: Int { lock.withLock { transmitted } }
    func reserve(_ bytes: Int) { lock.withLock { queuedOrSent += bytes } }
    func sent(_ bytes: Int) { lock.withLock { transmitted += bytes } }
    /// Takes an ack: false (a protocol error) when it covers more than was sent.
    func acknowledge(_ bytes: Int) -> Bool {
        lock.withLock {
            guard bytes <= transmitted else { return false }
            transmitted -= bytes
            queuedOrSent -= bytes
            return true
        }
    }
}
