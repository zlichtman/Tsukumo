import Foundation
import Network
import Security

// Your Mac's agents from iPhone, on the same Wi‑Fi (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone). The Mac
// advertises `_kemosabe-relay._tcp` over Bonjour only while Agents on your Mac (Settings → Models) is on; the
// iPhone browses for it. Every connection is TLS 1.2 with a pre-shared key: a paired iPhone's own key
// (identity `phone:<id>`), or, while the Mac shows a code, the key derived from that code (identity
// `pair`). A peer without one of those keys never finishes the handshake and gets nothing. Inside,
// `MacRelaySession` proves which phone is talking with a fresh nonce per connection.
//
// Compiled into both apps, so the Mac's tests run the phone's side against the Mac's over localhost.

/// Frames in and out, whatever carries them. Same Wi‑Fi today (`MacRelayConnection`); a transport
/// through iCloud can be another channel later.
@MainActor protocol MacRelayChannel: AnyObject {
    var onFrame: ((MacRelay.Frame) -> Void)? { get set }
    /// The channel closed on its own (the other side left, or the network failed). Not called after `close()`.
    var onClose: ((String?) -> Void)? { get set }
    func send(_ frame: MacRelay.Frame)
    /// Sends one last frame (a refusal), then closes.
    func close(sending frame: MacRelay.Frame)
    func close()
}

/// How the phone opens a channel to its paired Mac.
@MainActor protocol MacRelayTransport: AnyObject {
    /// A channel to the Mac, authenticated with `identity` and `key`, or nil with the reason.
    func open(mac: UUID?, identity: String, key: Data) async -> Result<MacRelayChannel, MacRelay.Failure>
}

// MARK: TLS with a pre-shared key

enum MacRelayTLS {
    /// The phone's side: one identity and its key.
    static func client(identity: String, key: Data) -> NWParameters {
        parameters { options in
            sec_protocol_options_add_pre_shared_key(options, dispatch(key), dispatch(Data(identity.utf8)))
        }
    }
    /// The Mac's side: every key it may accept, and `allow` asked for each identity a phone presents
    /// (a removed phone or an expired code is refused even before the listener restarts).
    static func server(keys: [String: Data], allow: @escaping @Sendable (String) -> Bool) -> NWParameters {
        parameters { options in
            for (identity, key) in keys.sorted(by: { $0.key < $1.key }) {
                sec_protocol_options_add_pre_shared_key(options, dispatch(key), dispatch(Data(identity.utf8)))
            }
            // Network.framework picks the key by the identity the phone sent; this block may veto it.
            sec_protocol_options_set_pre_shared_key_selection_block(options, { _, hint, complete in
                let identity = hint.flatMap { String(data: Data($0 as DispatchData), encoding: .utf8) }
                complete(identity.flatMap { keys[$0] != nil && allow($0) ? dispatch(Data($0.utf8)) : nil })
            }, DispatchQueue(label: "com.zlichtman.kemosabe.relay.psk"))
        }
    }
    private static func parameters(_ configure: (sec_protocol_options_t) -> Void) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        configure(options)
        sec_protocol_options_append_tls_ciphersuite(options, tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!)
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(options, .TLSv12)
        let tcp = NWProtocolTCP.Options()
        tcp.enableKeepalive = true; tcp.keepaliveIdle = 20; tcp.connectionTimeout = 8
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.includePeerToPeer = false
        return parameters
    }
    private static func dispatch(_ data: Data) -> __DispatchData {
        data.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
    }
}

// MARK: A connection

/// One framed TLS connection, with its callbacks on the main queue.
@MainActor final class MacRelayConnection: MacRelayChannel {
    let connection: NWConnection
    var onFrame: ((MacRelay.Frame) -> Void)?
    var onClose: ((String?) -> Void)?
    /// The handshake finished (the peer holds the key).
    var onReady: (() -> Void)?
    private var reader = MacRelay.Framing.Reader()
    private(set) var closed = false
    private(set) var ready = false

    init(_ connection: NWConnection) { self.connection = connection }
    /// A connection to a Mac the browser found, or to a host and port (tests).
    convenience init(to endpoint: NWEndpoint, identity: String, key: Data) {
        self.init(NWConnection(to: endpoint, using: MacRelayTLS.client(identity: identity, key: key)))
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in MainActor.assumeIsolated { self?.changed(state) } }
        connection.start(queue: .main)
    }
    private func changed(_ state: NWConnection.State) {
        switch state {
        case .ready:
            guard !ready else { return }
            ready = true
            let handler = onReady; onReady = nil
            handler?(); receive()
        case .waiting(let error), .failed(let error): finish(Self.describe(error))
        case .cancelled: finish(nil)
        default: break
        }
    }
    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self, !self.closed else { return }
                if let data, !data.isEmpty {
                    do {
                        for frame in try self.reader.append(data) {
                            self.onFrame?(frame)
                            if self.closed { return }
                        }
                    } catch { self.finish((error as? LocalizedError)?.errorDescription ?? error.localizedDescription); return }
                }
                if let error { self.finish(Self.describe(error)); return }
                if complete { self.finish(nil); return }
                self.receive()
            }
        }
    }
    func send(_ frame: MacRelay.Frame) {
        guard !closed, let data = try? MacRelay.Framing.encode(frame) else { return }
        connection.send(content: data, completion: .contentProcessed { _ in })
    }
    func close(sending frame: MacRelay.Frame) {
        guard !closed, let data = try? MacRelay.Framing.encode(frame) else { return close() }
        closed = true; onFrame = nil; onClose = nil; onReady = nil
        let connection = connection
        connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
    }
    func close() {
        guard !closed else { return }
        closed = true; onFrame = nil; onClose = nil; onReady = nil
        connection.cancel()
    }
    private func finish(_ problem: String?) {
        guard !closed else { return }
        closed = true
        let handler = onClose
        onFrame = nil; onClose = nil; onReady = nil
        connection.cancel()
        handler?(problem)
    }
    /// What went wrong, in words: a key the Mac doesn't accept, Local Network turned off, or the network.
    static func describe(_ error: NWError) -> String {
        switch error {
        case .tls(let status) where [errSSLBadRecordMac, errSSLUnknownPSKIdentity, errSSLPeerHandshakeFail, errSSLHandshakeFail, errSSLPeerDecryptError].contains(status):
            return "Your Mac didn’t accept this iPhone’s key."
        case .dns(let code) where code == -65570:
            return "Local Network is off for KemoSabe. Turn it on in Settings → Privacy & Security → Local Network."
        case .posix(.ECONNREFUSED): return "Your Mac isn’t answering. Check that Agents on your Mac is on in Tsukumo → Settings → Models."
        default: return error.localizedDescription
        }
    }
}

/// The phone's same-Wi‑Fi transport: finds the Mac with Bonjour, or connects to a fixed endpoint (tests).
@MainActor final class MacRelayDirectTransport: MacRelayTransport {
    let endpoint: () -> NWEndpoint?
    var timeout: Duration = .seconds(8)
    init(endpoint: @escaping () -> NWEndpoint?) { self.endpoint = endpoint }
    func open(mac: UUID?, identity: String, key: Data) async -> Result<MacRelayChannel, MacRelay.Failure> {
        guard let endpoint = endpoint() else { return .failure(.init("Your Mac isn’t on this Wi‑Fi.")) }
        let connection = MacRelayConnection(to: endpoint, identity: identity, key: key)
        let timeout = timeout
        return await withCheckedContinuation { continuation in
            var finished = false
            func done(_ result: Result<MacRelayChannel, MacRelay.Failure>) {
                guard !finished else { return }
                finished = true; continuation.resume(returning: result)
            }
            connection.onReady = { done(.success(connection)) }
            connection.onClose = { problem in done(.failure(.init(problem ?? "Your Mac closed the connection."))) }
            connection.start()
            Task { @MainActor in
                try? await Task.sleep(for: timeout)
                guard !finished else { return }
                connection.close(); done(.failure(.init("Your Mac didn’t answer.")))
            }
        }
    }
}

// MARK: The Mac's listener

/// Accepts phones' connections and, while on, advertises the Mac on Bonjour.
@MainActor final class MacRelayListener {
    enum State: Equatable { case stopped, starting, ready(port: UInt16), failed(String) }
    private(set) var state: State = .stopped { didSet { onState?(state) } }
    var onState: ((State) -> Void)?
    var onConnection: ((MacRelayConnection) -> Void)?
    private var listener: NWListener?
    /// Connections still in their handshake.
    private var handshaking: [ObjectIdentifier: MacRelayConnection] = [:]

    /// Starts (or restarts, with new keys) on `port`; advertises `service` when given.
    func start(keys: [String: Data], allow: @escaping @Sendable (String) -> Bool, service: (name: String, mac: UUID)?, port: NWEndpoint.Port = .any) {
        stop()
        let parameters = MacRelayTLS.server(keys: keys, allow: allow)
        parameters.allowLocalEndpointReuse = true
        let listener: NWListener
        do { listener = try NWListener(using: parameters, on: port) }
        catch { state = .failed(error.localizedDescription); return }
        if let service {
            listener.service = NWListener.Service(name: service.name, type: MacRelay.serviceType, domain: nil,
                                                  txtRecord: NWTXTRecord(["id": service.mac.uuidString, "v": String(MacRelay.version)]))
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            MainActor.assumeIsolated {
                guard let self, let listener, self.listener === listener else { return }
                switch state {
                case .ready: self.state = .ready(port: listener.port?.rawValue ?? 0)
                case .failed(let error), .waiting(let error): self.state = .failed(error.localizedDescription)
                case .cancelled: self.state = .stopped
                default: break
                }
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            MainActor.assumeIsolated {
                guard let self else { connection.cancel(); return }
                let link = MacRelayConnection(connection)
                let id = ObjectIdentifier(link)
                self.handshaking[id] = link
                // The session starts talking once the handshake proves the phone holds a key.
                link.onReady = { [weak self, weak link] in
                    self?.handshaking[id] = nil
                    if let link { self?.onConnection?(link) }
                }
                link.onClose = { [weak self] _ in self?.handshaking[id] = nil }
                link.start()
            }
        }
        self.listener = listener
        state = .starting
        listener.start(queue: .main)
    }
    func stop() {
        guard let listener else { return }
        self.listener = nil
        listener.stateUpdateHandler = nil; listener.newConnectionHandler = nil
        listener.cancel()
        state = .stopped
    }
    var port: UInt16? { if case .ready(let port) = state { port } else { nil } }
}

// MARK: The phone's browser

/// Finds Macs advertising Agents on your Mac on this Wi‑Fi.
@MainActor final class MacRelayBrowser {
    struct Found: Equatable {
        let endpoint: NWEndpoint
        let name: String
        let mac: UUID?
    }
    private(set) var found: [Found] = []
    var onChange: (([Found]) -> Void)?
    /// Browsing can't run (Local Network is off, say).
    var onProblem: ((String) -> Void)?
    private var browser: NWBrowser?
    var running: Bool { browser != nil }

    /// UI tests never browse the real network: the owner's own Tsukumo may be answering on this Wi‑Fi.
    static var offline: Bool {
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && arguments.contains("--isolated-fixture")
    }

    func start() {
        guard browser == nil else { return }
        if Self.offline { found = []; onChange?([]); return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: MacRelay.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.found = results.compactMap { result in
                    guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                    var mac: UUID?
                    if case .bonjour(let txt) = result.metadata { mac = txt["id"].flatMap(UUID.init(uuidString:)) }
                    return Found(endpoint: result.endpoint, name: name, mac: mac)
                }
                self.onChange?(self.found)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed(let error), .waiting(let error): self?.onProblem?(MacRelayConnection.describe(error))
                default: break
                }
            }
        }
        self.browser = browser
        browser.start(queue: .main)
    }
    func stop() {
        browser?.cancel(); browser = nil
        found = []
    }
}
