import Foundation
import TsukumoCore

// The gateway's own OAuth 2.1 authorization server, as MCP's authorization spec asks: protected resource
// metadata (RFC 9728), authorization server metadata (RFC 8414), dynamic client registration (RFC 7591),
// the authorization code flow with PKCE S256 only, resource indicators (RFC 8707), refresh tokens that rotate,
// and revocation (RFC 7009). The authorize step never trusts the browser: it puts a native Tsukumo window on
// the owner's Mac naming the client ("Grok wants to connect to KemoSabe") and waits for the owner there; the
// browser only waits on a page that says so. Tokens and codes are random, short-lived, and kept as hashes.

/// One sign-in waiting on the owner, then on the client to trade its code.
struct AuthorizationRequest {
    let id: String
    let client: GatewayClient
    let redirectURI: String
    let challenge: String
    let state: String?
    /// The resource the tokens will be bound to (canonical), and the scope.
    let resource: String
    let scope: String
    let issuer: String
    let createdAt: Date
}

/// A code, as kept: its hash's request, until it expires; used once.
struct AuthorizationCode {
    let client: String
    let redirectURI: String
    let challenge: String
    let resource: String
    let scope: String
    let expiresAt: Date
    var used: Bool
    var family: UUID?
}

@MainActor public final class GatewayAuthorization {
    public static let scope = "kemosabe"
    public static let codeLifetime: TimeInterval = 60
    public static let requestLifetime: TimeInterval = 10 * 60
    static let maxPending = 20
    /// Sign-in windows waiting at once, and authorization requests a minute (each puts a window on the owner's Mac).
    public static let maxSignIns = 3, authorizePerMinute = 6

    let store: GatewayStore
    let desk: GatewayDesk
    private let clock: @Sendable () -> Date
    private var requests: [String: AuthorizationRequest] = [:]
    private var codes: [String: AuthorizationCode] = [:]
    private var recent: [Date] = []

    public init(store: GatewayStore, desk: GatewayDesk, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store; self.desk = desk; self.clock = clock
    }

    // MARK: Metadata

    /// RFC 9728: where this resource's authorization server is.
    func resourceMetadata(base: String) -> HTTPResponse {
        .json(200, GatewayJSON.text(.object([
            "resource": .string(base + "/mcp"),
            "authorization_servers": .array([.string(base)]),
            "scopes_supported": .array([.string(Self.scope)]),
            "bearer_methods_supported": .array([.string("header")]),
            "resource_name": .string("KemoSabe"),
        ])))
    }

    /// RFC 8414.
    func serverMetadata(base: String) -> HTTPResponse {
        .json(200, GatewayJSON.text(.object([
            "issuer": .string(base),
            "authorization_endpoint": .string(base + "/authorize"),
            "token_endpoint": .string(base + "/token"),
            "registration_endpoint": .string(base + "/register"),
            "revocation_endpoint": .string(base + "/revoke"),
            "response_types_supported": .array([.string("code")]),
            "response_modes_supported": .array([.string("query")]),
            "grant_types_supported": .array([.string("authorization_code"), .string("refresh_token")]),
            "code_challenge_methods_supported": .array([.string("S256")]),
            "token_endpoint_auth_methods_supported": .array([.string("none"), .string("client_secret_post"), .string("client_secret_basic")]),
            "revocation_endpoint_auth_methods_supported": .array([.string("none"), .string("client_secret_post"), .string("client_secret_basic")]),
            "scopes_supported": .array([.string(Self.scope)]),
            "authorization_response_iss_parameter_supported": .bool(true),
            "client_id_metadata_document_supported": .bool(false),
        ])))
    }

    // MARK: Registration (RFC 7591)

    func register(_ request: HTTPRequest) -> HTTPResponse {
        guard let body = try? JSONDecoder().decode(JSONValue.self, from: request.body), case .object(let fields) = body else {
            return registrationError("invalid_client_metadata", "The body must be a JSON object.")
        }
        guard case .array(let list)? = fields["redirect_uris"], !list.isEmpty, list.count <= 5 else {
            return registrationError("invalid_redirect_uri", "Give one to five redirect_uris.")
        }
        var uris: [String] = []
        for item in list {
            guard let uri = item.stringValue, Self.validRedirect(uri) else {
                return registrationError("invalid_redirect_uri", "Each redirect URI must be https, or http on this computer, with no fragment.")
            }
            uris.append(uri)
        }
        let method = fields["token_endpoint_auth_method"]?.stringValue ?? "none"
        guard ["none", "client_secret_post", "client_secret_basic"].contains(method) else {
            return registrationError("invalid_client_metadata", "token_endpoint_auth_method must be none, client_secret_post, or client_secret_basic.")
        }
        if case .array(let grants)? = fields["grant_types"] {
            guard grants.allSatisfy({ ["authorization_code", "refresh_token"].contains($0.stringValue ?? "") }) else {
                return registrationError("invalid_client_metadata", "Only authorization_code and refresh_token are supported.")
            }
        }
        if case .array(let types)? = fields["response_types"] {
            guard types.allSatisfy({ $0.stringValue == "code" }) else { return registrationError("invalid_client_metadata", "Only the code response type is supported.") }
        }
        let name = fields["client_name"]?.stringValue ?? URL(string: uris[0])?.host() ?? "An agent"
        guard let (client, secret) = store.register(name: name, redirectURIs: uris, authMethod: method) else {
            return registrationError("invalid_client_metadata", "Too many clients are registered. Try again later.")
        }
        var out: [String: JSONValue] = [
            "client_id": .string(client.id),
            "client_id_issued_at": .number(client.registeredAt.timeIntervalSince1970.rounded(.down)),
            "client_name": .string(client.name),
            "redirect_uris": .array(client.redirectURIs.map(JSONValue.string)),
            "grant_types": .array([.string("authorization_code"), .string("refresh_token")]),
            "response_types": .array([.string("code")]),
            "token_endpoint_auth_method": .string(method),
            "scope": .string(Self.scope),
        ]
        if let secret { out["client_secret"] = .string(secret); out["client_secret_expires_at"] = .number(0) }
        return .json(201, GatewayJSON.text(.object(out)))
    }

    static func validRedirect(_ text: String) -> Bool {
        guard text.count <= 2_000, let url = URL(string: text), url.fragment == nil, let scheme = url.scheme?.lowercased(), let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil else { return false }
        if scheme == "https" { return true }
        return scheme == "http" && ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }

    private func registrationError(_ code: String, _ description: String) -> HTTPResponse {
        .json(400, GatewayJSON.text(.object(["error": .string(code), "error_description": .string(description)])))
    }

    // MARK: Authorize

    func authorize(_ request: HTTPRequest, base: String, relayed: Bool = false) -> HTTPResponse {
        let q = request.query
        expire()
        // Until the client and its redirect are known good, problems are shown here, never redirected.
        guard let clientID = q["client_id"], let client = store.client(clientID) else { return page(400, "That app isn’t registered with KemoSabe.") }
        let redirect = q["redirect_uri"] ?? (client.redirectURIs.count == 1 ? client.redirectURIs[0] : "")
        guard client.redirectURIs.contains(redirect) else { return page(400, "That return address doesn’t match the app’s registration.") }
        func fail(_ error: String, _ description: String) -> HTTPResponse {
            .redirect(Self.append(redirect, ["error": error, "error_description": description, "state": q["state"], "iss": base]))
        }
        guard q["response_type"] == "code" else { return fail("unsupported_response_type", "Only response_type=code is supported.") }
        guard let challenge = q["code_challenge"], Self.validPKCE(challenge) else { return fail("invalid_request", "A PKCE code_challenge is required.") }
        guard q["code_challenge_method"] == "S256" else { return fail("invalid_request", "code_challenge_method must be S256.") }
        if let state = q["state"], state.count > 1_024 { return fail("invalid_request", "state is too long.") }
        if let resource = q["resource"], !resource.isEmpty, !Self.matches(resource: resource, base: base) {
            return fail("invalid_target", "That resource isn’t this server.")
        }
        if let scope = q["scope"], !scope.isEmpty, !scope.split(separator: " ").allSatisfy({ $0 == Self.scope }) {
            return fail("invalid_scope", "The only scope is kemosabe.")
        }
        // Each request puts a window on the owner's Mac: a few a minute, a few waiting, one per app.
        let now = clock()
        recent = recent.filter { now.timeIntervalSince($0) < 60 }
        guard requests.count < Self.maxPending, recent.count < Self.authorizePerMinute else {
            return fail("temporarily_unavailable", "Too many sign-ins. Try again in a minute.")
        }
        recent.append(now)
        let id = GatewaySecrets.base64url(GatewaySecrets.random(18))
        let local = !relayed && Self.isLocal(base)
        let resource = Self.canonical(q["resource"].flatMap { $0.isEmpty ? nil : $0 } ?? base + "/mcp")
        let card = GatewayApprovalRequest(callerID: client.id, callerName: client.name, tool: nil, kind: .newClient(redirectURI: redirect, local: local, relayed: relayed),
                                          text: Self.signInText(client: client, redirect: redirect, base: base, relayed: relayed),
                                          fingerprint: "auth|" + id, at: now)
        guard case .added = desk.submit(card, perCaller: 1, everyone: Self.maxSignIns) else {
            return fail("temporarily_unavailable", "Another sign-in is waiting for the owner. Try again in a minute.")
        }
        requests[id] = AuthorizationRequest(id: id, client: client, redirectURI: redirect, challenge: challenge, state: q["state"],
                                            resource: resource, scope: Self.scope, issuer: base, createdAt: now)
        return waiting(id, client: client, base: base)
    }

    /// The browser waits here until the owner answers on the Mac.
    func wait(_ request: HTTPRequest, base: String) -> HTTPResponse {
        expire()
        // A sign-in waits only at the address it started at (this Mac, or the public address).
        guard let id = request.query["request"], let pending = requests[id], pending.issuer == base else { return page(400, "This sign-in has expired. Start again from the app.") }
        guard let decision = desk.decision(for: "auth|" + id) else {
            if desk.card(for: "auth|" + id) == nil {
                requests[id] = nil
                return .redirect(Self.append(pending.redirectURI, ["error": "access_denied", "error_description": "The owner didn’t answer in time.",
                                                                    "state": pending.state, "iss": pending.issuer]))
            }
            return waiting(id, client: pending.client, base: base)
        }
        requests[id] = nil
        let tools: [GatewayToolName]
        switch decision.approval {
        case .deny:
            return .redirect(Self.append(pending.redirectURI, ["error": "access_denied", "error_description": "The owner didn’t allow it.",
                                                                "state": pending.state, "iss": pending.issuer]))
        case .allowClient(let picked): tools = picked
        case .once, .standing: tools = []
        }
        let now = clock()
        let caller = store.caller(pending.client.id).map { existing -> GatewayCaller in
            var updated = existing; updated.name = pending.client.name; return updated
        } ?? GatewayCaller(id: pending.client.id, name: pending.client.name, kind: .oauth,
                           detail: URL(string: pending.redirectURI)?.host() ?? "OAuth", createdAt: now)
        store.approve(client: pending.client.id, caller: caller)
        // From the sign-in window, only free/busy can be allowed ahead of time (whole days, the next 7); everything
        // else asks on a card the first time.
        if tools.contains(.freeBusy) { store.grant(.standard(.freeBusy, caller: caller.id, now: now)) }
        let code = GatewaySecrets.token("ksac_")
        codes[GatewaySecrets.hash(code)] = AuthorizationCode(client: pending.client.id, redirectURI: pending.redirectURI, challenge: pending.challenge,
                                                             resource: pending.resource, scope: pending.scope,
                                                             expiresAt: now.addingTimeInterval(Self.codeLifetime), used: false)
        return .redirect(Self.append(pending.redirectURI, ["code": code, "state": pending.state, "iss": pending.issuer]))
    }

    // MARK: Token

    func token(_ request: HTTPRequest, base: String) -> HTTPResponse {
        let form = Self.body(request)
        guard let client = authenticateClient(request, form) else {
            return tokenError(401, "invalid_client", "The client isn’t registered, or its credentials are wrong.",
                              headers: [("WWW-Authenticate", "Basic realm=\"KemoSabe\"")])
        }
        switch form["grant_type"] {
        case "authorization_code":
            guard let code = form["code"], let verifier = form["code_verifier"], Self.validPKCE(verifier) else {
                return tokenError(400, "invalid_request", "code and a PKCE code_verifier are required.")
            }
            let hash = GatewaySecrets.hash(code)
            guard var record = codes[hash] else { return tokenError(400, "invalid_grant", "That code isn’t valid.") }
            // A code redeems only at the endpoint it was issued for (this Mac, or the public address), checked before
            // anything else, so a code from one can neither be redeemed at the other nor spend its replay protection there.
            guard record.resource == Self.canonical(base + "/mcp") else {
                return tokenError(400, "invalid_grant", "That code was issued for another address.")
            }
            if record.used {
                // A code used twice: someone else has it. Everything issued from it is revoked.
                if let family = record.family { store.revokeFamily(family) }
                codes[hash] = nil
                return tokenError(400, "invalid_grant", "That code was already used.")
            }
            guard record.client == client.id, record.expiresAt > clock(), form["redirect_uri"].map({ $0 == record.redirectURI }) ?? true,
                  GatewaySecrets.equal(GatewaySecrets.s256(verifier), record.challenge) else {
                return tokenError(400, "invalid_grant", "That code, its client, its return address, or its verifier doesn’t match.")
            }
            // The tokens are bound to the resource the sign-in named (RFC 8707); asking for another one now is refused.
            if let resource = form["resource"], !resource.isEmpty, Self.canonical(resource) != record.resource || !Self.matches(resource: resource, base: base) {
                return tokenError(400, "invalid_target", "That resource isn’t the one this code was issued for.")
            }
            if let scope = form["scope"], !scope.isEmpty, !scope.split(separator: " ").allSatisfy({ $0 == Substring(record.scope) }) {
                return tokenError(400, "invalid_scope", "The only scope is kemosabe.")
            }
            let family = UUID()
            record.used = true
            record.family = family
            codes[hash] = record
            return tokens(store.issue(for: client.id, family: family, resource: record.resource, scope: record.scope))
        case "refresh_token":
            guard let token = form["refresh_token"] else { return tokenError(400, "invalid_request", "refresh_token is required.") }
            let resource = form["resource"].flatMap { $0.isEmpty ? nil : $0 }, scope = form["scope"].flatMap { $0.isEmpty ? nil : $0 }
            switch store.refresh(token, client: client.id, endpoint: Self.canonical(base + "/mcp"), resource: resource, scope: scope) {
            case .issued(let access, let refresh): return tokens((access, refresh))
            case .invalid, .reused: return tokenError(400, "invalid_grant", "That refresh token isn’t valid.")
            case .wrongTarget: return tokenError(400, "invalid_target", "That refresh token is for another resource.")
            case .wrongScope: return tokenError(400, "invalid_scope", "A refresh can’t widen the scope.")
            }
        default:
            return tokenError(400, "unsupported_grant_type", "Use authorization_code or refresh_token.")
        }
    }

    func revoke(_ request: HTTPRequest) -> HTTPResponse {
        let form = Self.body(request)
        guard authenticateClient(request, form) != nil else { return tokenError(401, "invalid_client", "The client isn’t registered.") }
        if let token = form["token"] { store.revokeToken(token) }
        return .status(200, headers: [("Cache-Control", "no-store")])
    }

    private func tokens(_ pair: (access: String, refresh: String)) -> HTTPResponse {
        .json(200, GatewayJSON.text(.object([
            "access_token": .string(pair.access), "token_type": .string("Bearer"), "expires_in": .number(GatewayStore.accessLifetime),
            "refresh_token": .string(pair.refresh), "scope": .string(Self.scope),
        ])), headers: [("Pragma", "no-cache")])
    }

    /// The client by its id and, for a client with a secret, the secret (in the body or HTTP Basic).
    private func authenticateClient(_ request: HTTPRequest, _ form: [String: String]) -> GatewayClient? {
        var id = form["client_id"], secret = form["client_secret"]
        if let header = request.header("authorization"), header.lowercased().hasPrefix("basic "),
           let decoded = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)).flatMap({ String(data: $0, encoding: .utf8) }),
           let colon = decoded.firstIndex(of: ":") {
            id = String(decoded[..<colon]).removingPercentEncoding
            secret = String(decoded[decoded.index(after: colon)...]).removingPercentEncoding
        }
        guard let id, let client = store.client(id) else { return nil }
        if let hash = client.secretHash {
            guard let secret, GatewaySecrets.equal(GatewaySecrets.hash(secret), hash) else { return nil }
        }
        return client
    }

    private func tokenError(_ status: Int, _ code: String, _ description: String, headers: [(String, String)] = []) -> HTTPResponse {
        .json(status, GatewayJSON.text(.object(["error": .string(code), "error_description": .string(description)])), headers: headers)
    }

    // MARK: Helpers

    static func validPKCE(_ text: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return (43...128).contains(text.count) && text.unicodeScalars.allSatisfy(allowed.contains)
    }
    /// A resource indicator names this server: its base, or its MCP endpoint (with or without a trailing slash).
    /// A resource as tokens are bound to it: the MCP endpoint, lowercased, with no trailing slash.
    public static func canonical(_ resource: String) -> String {
        var text = resource.trimmingCharacters(in: .whitespaces).lowercased()
        while text.hasSuffix("/") { text.removeLast() }
        return text.hasSuffix("/mcp") ? text : text + "/mcp"
    }
    static func isLocal(_ base: String) -> Bool { URL(string: base)?.host().map { ["127.0.0.1", "localhost"].contains($0) } ?? false }
    /// The sign-in window's words: the name is the app's own claim, so it says so, with the whole return address
    /// and how it reached this Mac.
    static func signInText(client: GatewayClient, redirect: String, base: String, relayed: Bool = false) -> String {
        let reached = relayed ? "It reached KemoSabe through the public relay (\(URL(string: base)?.host() ?? base))."
            : isLocal(base) ? "It reached KemoSabe from this Mac." : "It reached KemoSabe through \(URL(string: base)?.host() ?? base)."
        return "Unverified app: it calls itself “\(client.name)”, which Tsukumo can’t check. Signing in sends you back to \(String(redirect.prefix(300))). \(reached) It gets nothing until you allow each kind of request."
    }
    static func matches(resource: String, base: String) -> Bool {
        let trimmed = resource.hasSuffix("/") ? String(resource.dropLast()) : resource
        return trimmed == base || trimmed == base + "/mcp"
    }
    static func body(_ request: HTTPRequest) -> [String: String] {
        if request.header("content-type")?.lowercased().hasPrefix("application/json") == true,
           let value = try? JSONDecoder().decode([String: JSONValue].self, from: request.body) {
            return value.compactMapValues { $0.stringValue }
        }
        return request.form
    }
    static func append(_ uri: String, _ parameters: [String: String?]) -> String {
        guard var components = URLComponents(string: uri) else { return uri }
        var items = components.queryItems ?? []
        for (key, value) in parameters.sorted(by: { $0.key < $1.key }) { if let value { items.append(URLQueryItem(name: key, value: value)) } }
        components.queryItems = items
        // "+" in a query reads as a space to many servers: encode it.
        components.percentEncodedQuery = components.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B")
        return components.string ?? uri
    }

    private func expire() {
        let now = clock()
        requests = requests.filter { now.timeIntervalSince($0.value.createdAt) < Self.requestLifetime }
        codes = codes.filter { $0.value.expiresAt.addingTimeInterval(Self.requestLifetime) > now }
    }

    /// The wait page refreshes to the same address it's on: under a path base (the relay's `/d/<id>`) too.
    private func waiting(_ id: String, client: GatewayClient, base: String) -> HTTPResponse {
        page(200, "Allow \(client.name) on your Mac. Tsukumo is showing a window there. This page moves on by itself once you answer.",
             refresh: Self.basePath(base) + "/authorize/wait?request=" + id)
    }
    /// The base's path ("" for an origin, "/d/<id>" for the relay's path form).
    static func basePath(_ base: String) -> String {
        guard let path = URL(string: base)?.path(percentEncoded: true), path != "/" else { return "" }
        return path.hasSuffix("/") ? String(path.dropLast()) : path
    }
    private func page(_ status: Int, _ message: String, refresh: String? = nil) -> HTTPResponse {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
        }
        let meta = refresh.map { "<meta http-equiv=\"refresh\" content=\"2;url=\(escape($0))\">" } ?? ""
        return .html(status, """
            <!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\(meta)
            <title>KemoSabe</title><style>body{font:16px -apple-system,system-ui,sans-serif;background:#FBF6EE;color:#211B2C;display:flex;
            min-height:90vh;align-items:center;justify-content:center;margin:0 16px}main{max-width:420px}h1{font-size:22px}
            @media (prefers-color-scheme:dark){body{background:#211B2C;color:#FBF6EE}}</style></head>
            <body><main><h1>KemoSabe</h1><p>\(escape(message))</p></main></body></html>
            """)
    }
}
