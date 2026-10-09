import Foundation
import Observation
import TsukumoCore

/// A client that registered itself with the gateway's authorization server (OAuth dynamic client
/// registration). Registering grants nothing: it becomes a caller only when the owner approves it on this Mac.
public struct GatewayClient: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var redirectURIs: [String]
    public var registeredAt: Date
    /// Set once the owner approved it; its caller has the same id.
    public var approved: Bool
    /// "none" (a public client using PKCE alone), or "client_secret_post" / "client_secret_basic" with a secret
    /// kept only as its hash.
    public var authMethod: String = "none"
    public var secretHash: String?
}

/// A token, as kept: only its SHA-256 hash, whose it is, and until when.
public struct GatewayTokenRecord: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case access, refresh, client }
    public var hash: String
    public var caller: String
    public var kind: Kind
    /// Refresh tokens rotate; a reused one revokes its whole family.
    public var family: UUID
    public var expiresAt: Date?
    public var revoked: Bool
    public var issuedAt: Date
    /// The resource (RFC 8707) this token's family is bound to ("http://127.0.0.1:47615/mcp"); nil for a client token
    /// the owner made, which works at this server's local address only.
    public var resource: String?
    /// The scope granted to the family.
    public var scope: String?
}

/// Everything the gateway keeps, as one file on this Mac (`gateway.json`): its settings, its callers and their
/// grants, registered clients, and token hashes. Never synced. The disclosure ledger is a file of its own.
public struct GatewayState: Codable, Hashable, Sendable {
    public var settings = GatewaySettings()
    public var callers: [GatewayCaller] = []
    public var grants: [GatewayGrant] = []
    public var clients: [GatewayClient] = []
    public var tokens: [GatewayTokenRecord] = []
    public init() {}

    private enum CodingKeys: String, CodingKey { case settings, callers, grants, clients, tokens }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = (try? c.decodeIfPresent(GatewaySettings.self, forKey: .settings)) ?? GatewaySettings()
        callers = (try? c.decodeIfPresent([GatewayCaller].self, forKey: .callers)) ?? []
        // A grant a newer build wrote that this one can't read is dropped: it then grants nothing.
        grants = ((try? c.decodeIfPresent([Lossy<GatewayGrant>].self, forKey: .grants)) ?? []).compactMap(\.value)
        clients = (try? c.decodeIfPresent([GatewayClient].self, forKey: .clients)) ?? []
        tokens = ((try? c.decodeIfPresent([Lossy<GatewayTokenRecord>].self, forKey: .tokens)) ?? []).compactMap(\.value)
    }
}

private struct Lossy<T: Decodable>: Decodable {
    let value: T?
    init(from decoder: Decoder) throws { value = try? T(from: decoder) }
}

/// The gateway's state, saved on every change.
@MainActor @Observable public final class GatewayStore {
    public private(set) var state: GatewayState
    @ObservationIgnored private let file: URL?
    @ObservationIgnored let clock: @Sendable () -> Date
    /// A caller, grant, or token changed (the app saves; the dock and Settings follow).
    @ObservationIgnored public var onChange: (() -> Void)?
    /// Bumped whenever a caller loses something (revoked, a grant removed or replaced): a call that started under an
    /// older generation doesn't return what it read.
    @ObservationIgnored private var generations: [String: Int] = [:]
    public func generation(_ caller: String) -> Int { generations[caller, default: 0] }
    private func bump(_ caller: String) { generations[caller, default: 0] += 1 }

    public static let accessLifetime: TimeInterval = 60 * 60
    public static let refreshLifetime: TimeInterval = 30 * 86_400
    public static let maxClients = 40

    public init(file: URL?, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.clock = clock
        state = file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? TsukumoJSON.decoder.decode(GatewayState.self, from: $0) } ?? GatewayState()
    }

    public var settings: GatewaySettings { state.settings }
    public var callers: [GatewayCaller] { state.callers }
    public func caller(_ id: String) -> GatewayCaller? { state.callers.first { $0.id == id } }

    public func update(_ change: (inout GatewaySettings) -> Void) {
        change(&state.settings)
        save()
    }

    // MARK: Callers

    /// A caller with a token the owner made: the token, shown once, and the caller.
    public func addTokenCaller(name: String) -> (caller: GatewayCaller, token: String) {
        let now = clock()
        let caller = GatewayCaller(id: "t-" + GatewaySecrets.base64url(GatewaySecrets.random(9)), name: name, kind: .token,
                                   detail: "Signs in with a token", createdAt: now)
        let token = GatewaySecrets.token("ksk_")
        state.callers.append(caller)
        state.tokens.append(GatewayTokenRecord(hash: GatewaySecrets.hash(token), caller: caller.id, kind: .client, family: UUID(),
                                               expiresAt: nil, revoked: false, issuedAt: now))
        save()
        return (caller, token)
    }

    /// Adds a caller (an approved OAuth client, or one inside the app).
    public func add(_ caller: GatewayCaller) {
        if let index = state.callers.firstIndex(where: { $0.id == caller.id }) { state.callers[index] = caller } else { state.callers.append(caller) }
        save()
    }

    /// Revokes a caller: its tokens, grants, and registration go, and it must be approved again.
    public func revoke(_ id: String) {
        bump(id)
        state.callers.removeAll { $0.id == id }
        state.grants.removeAll { $0.caller == id }
        state.tokens.removeAll { $0.caller == id }
        state.clients.removeAll { $0.id == id }
        save()
    }

    func touch(_ id: String) {
        guard let index = state.callers.firstIndex(where: { $0.id == id }) else { return }
        let now = clock()
        // Saved at most once a minute: last seen is a hint, not a record.
        if let seen = state.callers[index].lastSeen, now.timeIntervalSince(seen) < 60 { return }
        state.callers[index].lastSeen = now
        save()
    }

    // MARK: Grants

    public func grants(for caller: String) -> [GatewayGrant] {
        let now = clock()
        return state.grants.filter { $0.caller == caller && $0.isLive(now: now) }
    }
    /// Whether the caller had a grant for this tool that has expired (the ledger notes a replay after expiry).
    public func hadExpiredGrant(caller: String, tool: GatewayToolName) -> Bool {
        let now = clock()
        return state.grants.contains { $0.caller == caller && $0.tool == tool && !$0.isLive(now: now) }
    }
    /// Adds a standing grant. A grant for the same tool and the same scope (the same people, conversations, or
    /// folders) replaces the old one; other scopes stand beside it. Expired grants are kept 30 days, so a call
    /// replaying one is noticed.
    public func grant(_ grant: GatewayGrant) {
        bump(grant.caller)
        let now = clock()
        state.grants.removeAll { old in
            (old.caller == grant.caller && old.tool == grant.tool && old.items == grant.items && old.folders == grant.folders)
                || (old.expiresAt.map { now.timeIntervalSince($0) > 30 * 86_400 } ?? false)
        }
        state.grants.append(grant)
        save()
    }
    public func revokeGrant(_ id: UUID) {
        if let caller = state.grants.first(where: { $0.id == id })?.caller { bump(caller) }
        state.grants.removeAll { $0.id == id }
        save()
    }
    public func revokeGrant(caller: String, tool: GatewayToolName) {
        bump(caller)
        state.grants.removeAll { $0.caller == caller && $0.tool == tool }
        save()
    }

    // MARK: Tokens

    /// The caller a bearer token belongs to, if it's live and, when `resource` is given, bound to that resource with
    /// the gateway's scope. A client token the owner made works only at a local resource (127.0.0.1 or localhost,
    /// at `/mcp` itself, never a path base) and never on a request that came through the relay (`ownerTokens: false`).
    public func authenticate(_ token: String, resource: String? = nil, ownerTokens: Bool = true) -> GatewayCaller? {
        guard token.count <= 200, token.hasPrefix("ks") else { return nil }
        let hash = GatewaySecrets.hash(token), now = clock()
        guard let record = state.tokens.first(where: { GatewaySecrets.equal($0.hash, hash) }), !record.revoked,
              record.kind == .access || record.kind == .client, record.expiresAt.map({ $0 > now }) ?? true,
              let caller = caller(record.caller) else { return nil }
        if record.kind == .client, !ownerTokens { return nil }
        if let resource {
            switch record.kind {
            case .access:
                guard record.resource == resource, (record.scope ?? "").split(separator: " ").contains(Substring(GatewayAuthorization.scope)) else { return nil }
            default:
                guard let url = URL(string: resource), let host = url.host(), ["127.0.0.1", "localhost"].contains(host),
                      url.path(percentEncoded: true) == "/mcp" else { return nil }
            }
        }
        touch(caller.id)
        return caller
    }

    /// A new access and refresh token for a caller (after the owner approved it, or a refresh).
    func issue(for caller: String, family: UUID = UUID(), resource: String, scope: String) -> (access: String, refresh: String) {
        let now = clock()
        let access = GatewaySecrets.token("ksat_"), refresh = GatewaySecrets.token("ksrt_")
        prune(now)
        state.tokens.append(GatewayTokenRecord(hash: GatewaySecrets.hash(access), caller: caller, kind: .access, family: family,
                                               expiresAt: now.addingTimeInterval(Self.accessLifetime), revoked: false, issuedAt: now,
                                               resource: resource, scope: scope))
        state.tokens.append(GatewayTokenRecord(hash: GatewaySecrets.hash(refresh), caller: caller, kind: .refresh, family: family,
                                               expiresAt: now.addingTimeInterval(Self.refreshLifetime), revoked: false, issuedAt: now,
                                               resource: resource, scope: scope))
        save()
        return (access, refresh)
    }

    enum RefreshResult { case issued(access: String, refresh: String), invalid, reused, wrongTarget, wrongScope }

    /// Trades a refresh token for new ones. Each refresh token works once; using a spent one revokes its whole
    /// family (someone else has a copy).
    /// A `resource` or `scope` asked for must be the family's own: a refresh can't move a token to another resource
    /// or widen it.
    /// `endpoint` is the resource of the address this refresh arrived at: a family bound elsewhere is refused before its
    /// replay state is touched.
    func refresh(_ token: String, client: String, endpoint: String? = nil, resource: String? = nil, scope: String? = nil) -> RefreshResult {
        let hash = GatewaySecrets.hash(token), now = clock()
        guard let index = state.tokens.firstIndex(where: { GatewaySecrets.equal($0.hash, hash) && $0.kind == .refresh }) else { return .invalid }
        let record = state.tokens[index]
        guard record.caller == client, caller(client) != nil else { return .invalid }
        if let endpoint, record.resource != endpoint { return .wrongTarget }
        if record.revoked {
            for i in state.tokens.indices where state.tokens[i].family == record.family { state.tokens[i].revoked = true }
            save()
            return .reused
        }
        guard record.expiresAt.map({ $0 > now }) ?? true else { return .invalid }
        guard let bound = record.resource else { return .invalid }
        if let resource, GatewayAuthorization.canonical(resource) != bound { return .wrongTarget }
        let granted = Set((record.scope ?? "").split(separator: " ").map(String.init))
        if let scope, !Set(scope.split(separator: " ").map(String.init)).isSubset(of: granted) { return .wrongScope }
        state.tokens[index].revoked = true
        let pair = issue(for: client, family: record.family, resource: bound, scope: record.scope ?? GatewayAuthorization.scope)
        return .issued(access: pair.access, refresh: pair.refresh)
    }

    /// RFC 7009: revokes a token (and, for a refresh token, its family).
    func revokeToken(_ token: String) {
        let hash = GatewaySecrets.hash(token)
        guard let record = state.tokens.first(where: { GatewaySecrets.equal($0.hash, hash) }) else { return }
        for i in state.tokens.indices where state.tokens[i].hash == hash || (record.kind == .refresh && state.tokens[i].family == record.family) {
            state.tokens[i].revoked = true
        }
        save()
    }

    /// Revokes every token of a family (an authorization code used twice).
    func revokeFamily(_ family: UUID) {
        for i in state.tokens.indices where state.tokens[i].family == family { state.tokens[i].revoked = true }
        save()
    }

    private func prune(_ now: Date) {
        // Expired tokens go after a day; revoked refresh tokens stay until they'd have expired, to catch reuse.
        state.tokens.removeAll { record in (record.expiresAt.map { $0.addingTimeInterval(86_400) < now } ?? false) }
    }

    // MARK: Clients

    /// Registers a client; with a secret method, the secret (shown once) too.
    func register(name: String, redirectURIs: [String], authMethod: String) -> (client: GatewayClient, secret: String?)? {
        let now = clock()
        // Unapproved registrations are let go after a day; there's a ceiling so nobody can fill the file.
        state.clients.removeAll { !$0.approved && now.timeIntervalSince($0.registeredAt) > 86_400 }
        guard state.clients.count < Self.maxClients else { return nil }
        let secret = authMethod == "none" ? nil : GatewaySecrets.token("kscs_")
        var client = GatewayClient(id: "c-" + GatewaySecrets.base64url(GatewaySecrets.random(12)), name: GatewayText.name(name),
                                   redirectURIs: redirectURIs, registeredAt: now, approved: false)
        client.authMethod = authMethod
        client.secretHash = secret.map(GatewaySecrets.hash)
        state.clients.append(client)
        save()
        return (client, secret)
    }
    func client(_ id: String) -> GatewayClient? { state.clients.first { $0.id == id } }
    func approve(client id: String, caller: GatewayCaller) {
        if let index = state.clients.firstIndex(where: { $0.id == id }) { state.clients[index].approved = true }
        add(caller)
    }

    private func save() {
        if let file {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? TsukumoJSON.encoder.encode(state).write(to: file, options: [.atomic])
        }
        onChange?()
    }
}
