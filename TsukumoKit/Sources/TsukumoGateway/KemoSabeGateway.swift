import Foundation
import Observation
import TsukumoCore
import TsukumoGate

/// The whole gateway for an app: its store (`gateway.json`), ledger (`gateway-ledger.json`), the owner's cards,
/// the Inbox, the tools, the authorization server, and the server on 127.0.0.1. Off until the owner turns it on;
/// turning it off stops the server at once.
@MainActor @Observable public final class KemoSabeGateway {
    public let store: GatewayStore
    public let ledger: DisclosureLedger
    public let desk: GatewayDesk
    public let inbox: GatewayInbox
    public let tools: GatewayTools
    public let authorization: GatewayAuthorization
    public let server: GatewayServer
    /// Listening now, and why not when it should be.
    public private(set) var listening = false
    public private(set) var problem: String?

    public init(folder: URL, sources: GatewaySources, content: (any GatewayContent)?, clock: @escaping @Sendable () -> Date = { Date() }) {
        store = GatewayStore(file: folder.appendingPathComponent("gateway.json"), clock: clock)
        ledger = DisclosureLedger(file: folder.appendingPathComponent("gateway-ledger.json"), clock: clock)
        desk = GatewayDesk(clock: clock)
        inbox = GatewayInbox(folder: folder.appendingPathComponent("Inbox", isDirectory: true), clock: clock)
        tools = GatewayTools(store: store, ledger: ledger, desk: desk, sources: sources, content: content, clock: clock)
        authorization = GatewayAuthorization(store: store, desk: desk, clock: clock)
        server = GatewayServer(tools: tools, authorization: authorization)
        tools.inbox = store.settings.inbox ? inbox : nil
    }

    /// The address MCP clients on this Mac use.
    public var localURL: String { "http://127.0.0.1:\(server.running ? server.port : store.settings.port)/mcp" }
    /// The address a public front end would give it, if the owner set one up (Tsukumo doesn't open one).
    public var publicURL: String? { store.settings.publicBaseString.map { $0 + "/mcp" } }

    /// Starts or stops the server to match the settings.
    public func apply() async {
        tools.inbox = store.settings.inbox ? inbox : nil
        defer { relay?.apply() }
        guard store.settings.enabled else {
            server.stop()
            listening = false
            problem = nil
            return
        }
        let port = store.settings.port
        if server.running, server.port == port { listening = true; return }
        do {
            try await server.start(port: port)
            listening = true
            problem = nil
        } catch {
            server.failed(error, port: port)
            listening = false
            problem = "Port \(port) is in use or can’t be opened. Pick another port."
        }
    }

    /// Turns the gateway on or off (the first time on, the owner has seen the explanation).
    public func setEnabled(_ on: Bool) async {
        store.update { $0.enabled = on; if on { $0.explained = true } }
        await apply()
    }

    // MARK: The public address (the Tsukumo relay)

    /// The relay client, once the app attaches one (its key store is the app's Keychain, or memory under tests).
    public private(set) var relay: RelayConnection?

    public func attachRelay(keys: any RelayKeyStore, transport: any RelayTransport = URLSessionRelayTransport(), secureEnclave: Bool = true) {
        relay?.stop()
        relay = RelayConnection(server: server, store: store, keys: keys, transport: transport, secureEnclave: secureEnclave)
    }

    /// Turns the public address on or off (the first time on, the owner has seen the explanation). Off disconnects
    /// and keeps the registration.
    public func setRelayEnabled(_ on: Bool) {
        store.update { $0.relayEnabled = on; if on { $0.relayExplained = true } }
        relay?.apply()
    }

    /// Sets the relay's address. A different relay doesn't know this Mac's device id, so it's forgotten (the key stays).
    public func setRelayURL(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value != store.settings.relayURL else { return }
        store.update { $0.relayURL = value; $0.relayDeviceID = ""; $0.publicBaseURL = "" }
        relay?.stop()
        relay?.apply()
    }

    /// Told after a caller is revoked (the app unpairs Muse when Muse is revoked).
    @ObservationIgnored public var onRevoke: (@MainActor (GatewayCaller) -> Void)?

    /// Revokes a caller everywhere: its tokens, grants, cards, and KemoSabe's consent for it.
    public func revoke(_ caller: GatewayCaller) {
        desk.dropAll(from: caller.id)
        tools.gate?.revokeConsent(caller.recipient)
        store.revoke(caller.id)
        onRevoke?(caller)
    }

    /// The commands that connect the coding agents in a terminal, with a token made for each.
    public static func claudeCodeCommand(url: String, token: String) -> String {
        "claude mcp add --transport http kemosabe \(url) --header \"Authorization: Bearer \(token)\""
    }
    public static func codexCommand(url: String) -> String {
        "codex mcp add kemosabe --url \(url) --bearer-token-env-var KEMOSABE_TOKEN"
    }
}
