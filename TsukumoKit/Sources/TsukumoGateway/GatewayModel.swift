import CryptoKit
import Foundation
import Security
import TsukumoCore
import TsukumoPolicy

// The KemoSabe gateway (October 6, 2026, the owner: Tsukumo's value is the barrier on the device, not hosting
// everyone's bots). Agents elsewhere (Grok, Claude, ChatGPT and dots, OpenClaw, a coding agent in a terminal,
// later a Muse gadget) come to KemoSabe as callers: they ask a narrow, typed question, plain code decides under
// the owner's rules and grants whether it may be answered, KemoSabe answers on this Mac, and only the answer
// (or the one file, excerpt, or photo the owner allowed) leaves. Agents can also send results in, to an Inbox.
// docs/ARCHITECTURE.md#the-kemosabe-gateway has the trust boundary and the threat model.

/// The tools a caller may use. Typed, never "ask anything" except through KemoSabe's own Gate. Every one but
/// `tsukumo.deliver` takes something out; `tsukumo.deliver` brings an agent's result in.
public enum GatewayToolName: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case freeBusy = "kemosabe.free_busy"
    case contactLookup = "kemosabe.contact_lookup"
    case ask = "kemosabe.ask"
    case listShareable = "kemosabe.list_shareable"
    case shareFile = "kemosabe.share_file"
    case shareMessages = "kemosabe.share_messages"
    case sharePhoto = "kemosabe.share_photo"
    case deliver = "tsukumo.deliver"
    /// Not a tool anyone calls (never offered or run): a bot's reply that KemoSabe released to a paired device's
    /// caller outside MCP (Muse's `bot.ask`), recorded here so the ledger holds every disclosure to that caller.
    case botReply = "tsukumo.bot_reply"
    public var id: String { rawValue }

    /// The name on the wire. Anthropic's and OpenAI's tool names allow only letters, digits, `_`, and `-`, so
    /// MCP lists `kemosabe_free_busy`; a call by either spelling works.
    public var wireName: String { rawValue.replacingOccurrences(of: ".", with: "_") }
    public init?(wire: String) {
        guard let tool = Self.allCases.first(where: { $0.rawValue == wire || $0.wireName == wire }) else { return nil }
        self = tool
    }
    /// "Free/busy times", for the owner.
    public var title: String {
        switch self {
        case .freeBusy: "Free/busy times"
        case .contactLookup: "Contact lookups"
        case .ask: "Questions for KemoSabe"
        case .listShareable: "Lists of what you could share"
        case .shareFile: "Files"
        case .shareMessages: "Message excerpts"
        case .sharePhoto: "Photos"
        case .deliver: "Sending you things"
        case .botReply: "Bot replies, through KemoSabe"
        }
    }
    public var symbol: String {
        switch self {
        case .freeBusy: "calendar.badge.clock"
        case .contactLookup: "person.crop.circle.badge.questionmark"
        case .ask: "questionmark.bubble"
        case .listShareable: "list.bullet.rectangle"
        case .shareFile: "doc"
        case .shareMessages: "message"
        case .sharePhoto: "photo"
        case .deliver: "tray.and.arrow.down"
        case .botReply: "arrowshape.turn.up.right"
        }
    }
    /// The tools a standing grant can be given for (delivering needs none; it lands in the Inbox).
    public static let grantable: [GatewayToolName] = [.freeBusy, .contactLookup, .ask, .listShareable, .shareFile, .shareMessages, .sharePhoto]
}

/// What `kemosabe.list_shareable` lists.
public enum ShareKind: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case files, messages, photos
    public var id: String { rawValue }
}

/// A contact field a caller may receive. Nothing else about a person ever leaves through the gateway.
public enum ContactField: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case firstName = "first_name", lastName = "last_name", phone, email
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .firstName: "first name"
        case .lastName: "last name"
        case .phone: "one phone number"
        case .email: "one email address"
        }
    }
}

/// Someone asking KemoSabe through the gateway: an MCP client signed in with OAuth (a cloud agent), a client
/// with a token the owner made (a coding agent in a terminal), or a caller inside the app (a Muse gadget,
/// later). Each is its own recipient, with its own grants, budgets, and ledger.
public struct GatewayCaller: Codable, Hashable, Identifiable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// Approved through OAuth on this Mac (ChatGPT, Claude, Grok, OpenClaw).
        case oauth
        /// A token the owner made in Settings (Claude Code or Codex in a terminal, or a client without OAuth).
        case token
        /// A caller inside the app, through `GatewayTools` directly.
        case local
        /// A device the owner paired on this Mac (Muse), through `GatewayTools` directly. Unlike `local`, it's
        /// connected only while it's listed: Revoke cuts it off until the owner pairs it again.
        case device
    }
    public var id: String
    /// "Grok", as the caller named itself (OAuth) or the owner named it.
    public var name: String
    public var kind: Kind
    /// Where it sends people back to after signing in ("grok.com"), or how it connects.
    public var detail: String
    public var createdAt: Date
    public var lastSeen: Date?

    public init(id: String, name: String, kind: Kind, detail: String, createdAt: Date = Date(), lastSeen: Date? = nil) {
        self.id = id; self.name = GatewayText.name(name); self.kind = kind; self.detail = detail
        self.createdAt = createdAt; self.lastSeen = lastSeen
    }
    /// Its recipient for the policy and KemoSabe's journal: another company's agent, never on this device.
    public var recipient: RecipientID { .externalAgent("gateway." + id) }
    /// Tsukumo's own Claude bot among the callers (TsukumoClaude makes it): Tsukumo's, so it's never an unverified
    /// agent or bound to a service the way a paired device is.
    public static let claudeBotID = "tsukumo-claude"
    public var isTsukumosClaudeBot: Bool { id == Self.claudeBotID }
}

/// A standing grant: one caller may use one tool within a scope until it expires, without asking the owner
/// each time. Anything outside it asks the owner on a card. Revocable; shown in Settings.
public struct GatewayGrant: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var caller: String
    public var tool: GatewayToolName
    /// Free/busy: how many days ahead of now it may look.
    public var daysAhead: Int?
    /// Contact lookups: the fields it may receive.
    public var fields: [ContactField]?
    /// Lists: the kinds it may list.
    public var kinds: [ShareKind]?
    /// Lists and files: the picked folders (`PickedFolder.id`) it may see into.
    public var folders: [UUID]?
    /// Message excerpts: the conversations it may have (a thread's id, or "contact:" and a person's ledger subject).
    public var items: [String]?
    /// Message excerpts: whether senders' names go with them (otherwise "Owner" and "Person 1").
    public var senderNames: Bool?
    /// Photos: whether a rough location goes with them (otherwise it's stripped).
    public var location: Bool?
    public var expiresAt: Date?
    public var grantedAt: Date

    public static let standardDays = 7
    public static let standingLifetime: TimeInterval = 7 * 86_400

    public init(id: UUID = UUID(), caller: String, tool: GatewayToolName, daysAhead: Int? = nil, fields: [ContactField]? = nil,
                kinds: [ShareKind]? = nil, folders: [UUID]? = nil, items: [String]? = nil, senderNames: Bool? = nil, location: Bool? = nil,
                expiresAt: Date?, grantedAt: Date = Date()) {
        self.id = id; self.caller = caller; self.tool = tool; self.daysAhead = daysAhead; self.fields = fields
        self.kinds = kinds; self.folders = folders; self.items = items; self.senderNames = senderNames; self.location = location
        self.expiresAt = expiresAt; self.grantedAt = grantedAt
    }

    /// The grant the owner gives with "Allow for 7 days" for the plain tools: free/busy for the next 7 days, first
    /// names with one phone or email, or questions for KemoSabe. The content tools' grants are scoped by the call.
    public static func standard(_ tool: GatewayToolName, caller: String, now: Date) -> GatewayGrant {
        switch tool {
        case .freeBusy: GatewayGrant(caller: caller, tool: tool, daysAhead: standardDays, expiresAt: now.addingTimeInterval(standingLifetime), grantedAt: now)
        case .contactLookup: GatewayGrant(caller: caller, tool: tool, fields: [.firstName, .phone, .email],
                                          expiresAt: now.addingTimeInterval(standingLifetime), grantedAt: now)
        default: GatewayGrant(caller: caller, tool: tool, expiresAt: now.addingTimeInterval(standingLifetime), grantedAt: now)
        }
    }

    public func isLive(now: Date) -> Bool { expiresAt.map { $0 > now } ?? true }

    /// "Next 7 days, busy or free only · until Oct 13", for the owner.
    public func summary(now: Date) -> String {
        var parts: [String] = []
        let folderCount = (folders ?? []).count, itemCount = (items ?? []).count
        switch tool {
        case .freeBusy: parts.append("Next \(daysAhead ?? 0) days, busy or free only")
        case .contactLookup: parts.append(ContactField.allCases.filter { (fields ?? []).contains($0) }.map(\.title).joined(separator: ", "))
        case .ask: parts.append("Answered under KemoSabe’s rules")
        case .listShareable: parts.append("Names of " + (kinds ?? []).map(\.rawValue).joined(separator: ", ") + ", never what’s in them")
        case .shareFile: parts.append("Files in \(folderCount) \(folderCount == 1 ? "folder" : "folders")")
        case .shareMessages: parts.append("\(itemCount) \(itemCount == 1 ? "conversation" : "conversations")" + (senderNames == true ? ", with names" : ", without names"))
        case .sharePhoto: parts.append(location == true ? "Photos, with rough location" : "Photos, location stripped")
        case .deliver: parts.append("Into your Inbox")
        case .botReply: parts.append("Released by KemoSabe")
        }
        if let expiresAt { parts.append("until " + expiresAt.formatted(date: .abbreviated, time: .omitted)) }
        return parts.joined(separator: " · ")
    }
}

/// The gateway's settings. Off until the owner turns it on, with the explanation seen once.
public struct GatewaySettings: Codable, Hashable, Sendable {
    public static let defaultPort: UInt16 = 47_615
    public static let defaultMaxBytes = 10 * 1_024 * 1_024, ceilingBytes = 50 * 1_024 * 1_024
    public var enabled = false
    public var explained = false
    public var port: UInt16 = GatewaySettings.defaultPort
    /// The public address this server answers at: a bare origin ("https://<id>.tsukumo-relay.example") or a path
    /// base ("https://tsukumo-relay.example.workers.dev/d/<id>"), used for the OAuth issuer and resource URLs and
    /// accepted as a Host. The Tsukumo relay sets it from its `ready` frame. Empty: no public address, and the
    /// gateway answers on this Mac only.
    public var publicBaseURL = ""
    /// The public address through the Tsukumo relay (Settings, Gateway, Public address): off until the owner turns
    /// it on, with its explanation seen once. The relay's URL and this Mac's device id live here, in `gateway.json`
    /// on this Mac (never iCloud); the device's private key is in this Mac's Keychain.
    public var relayEnabled = false
    public var relayExplained = false
    public var relayURL = ""
    public var relayDeviceID = ""
    /// The largest file `kemosabe.share_file` sends.
    public var maxFileBytes = GatewaySettings.defaultMaxBytes
    /// The largest thing `tsukumo.deliver` accepts.
    public var maxDeliveryBytes = GatewaySettings.defaultMaxBytes
    /// What a standing free/busy grant shows: whole days busy or free (the default), or quarter hours. Anything
    /// finer than the resolution asks the owner.
    public var freeBusyResolution: FreeBusyResolution = .day
    /// The widest free/busy window, in days.
    public var freeBusyMaxDays = 7
    /// Whether agents may ask for files, message excerpts, and photos (`list_shareable`, `share_*`). Off until
    /// the owner turns it on.
    public var contentTools = false
    /// Whether agents may send things into the Inbox (`tsukumo.deliver`). Off until the owner turns it on.
    public var inbox = false
    public var budget = GatewayBudget()
    public init() {}

    public enum FreeBusyResolution: String, Codable, CaseIterable, Hashable, Sendable { case day, quarterHour }

    private enum CodingKeys: String, CodingKey {
        case enabled, explained, port, publicBaseURL, maxFileBytes, maxDeliveryBytes, freeBusyResolution, freeBusyMaxDays, contentTools, inbox, budget
        case relayEnabled, relayExplained, relayURL, relayDeviceID
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        explained = try c.decodeIfPresent(Bool.self, forKey: .explained) ?? false
        port = try c.decodeIfPresent(UInt16.self, forKey: .port) ?? Self.defaultPort
        publicBaseURL = try c.decodeIfPresent(String.self, forKey: .publicBaseURL) ?? ""
        maxFileBytes = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .maxFileBytes))
        maxDeliveryBytes = Self.clamp(try c.decodeIfPresent(Int.self, forKey: .maxDeliveryBytes))
        freeBusyResolution = (try? c.decodeIfPresent(FreeBusyResolution.self, forKey: .freeBusyResolution)) ?? .day
        freeBusyMaxDays = min(14, max(1, try c.decodeIfPresent(Int.self, forKey: .freeBusyMaxDays) ?? 7))
        contentTools = try c.decodeIfPresent(Bool.self, forKey: .contentTools) ?? false
        inbox = try c.decodeIfPresent(Bool.self, forKey: .inbox) ?? false
        budget = (try? c.decodeIfPresent(GatewayBudget.self, forKey: .budget)) ?? GatewayBudget()
        relayEnabled = try c.decodeIfPresent(Bool.self, forKey: .relayEnabled) ?? false
        relayExplained = try c.decodeIfPresent(Bool.self, forKey: .relayExplained) ?? false
        relayURL = try c.decodeIfPresent(String.self, forKey: .relayURL) ?? ""
        relayDeviceID = try c.decodeIfPresent(String.self, forKey: .relayDeviceID) ?? ""
    }
    static func clamp(_ value: Int?) -> Int { min(ceilingBytes, max(1_024, value ?? defaultMaxBytes)) }

    /// The public base URL, when it's set and valid: https (or http on this computer, for a relay running locally
    /// with `wrangler dev`), no user, query, or fragment, and either no path (a per-device origin) or the relay's
    /// path form, `/d/<id>`.
    public var publicBase: URL? { Self.validPublicBase(publicBaseURL) }

    public static func validPublicBase(_ raw: String) -> URL? {
        let trimmed = Self.trimmed(raw.trimmingCharacters(in: .whitespaces))
        guard !trimmed.isEmpty, trimmed.count <= 300, let url = URL(string: trimmed), let scheme = url.scheme, let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return nil }
        guard scheme == "https" || (scheme == "http" && Self.loopback.contains(host)) else { return nil }
        let path = url.path(percentEncoded: true)
        if path.isEmpty { return url }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "d", (1...64).contains(parts[2].count),
              parts[2].allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) }) else { return nil }
        return url
    }

    /// The public base as the gateway uses it, with no trailing slash ("https://host/d/<id>").
    public var publicBaseString: String? { publicBase.map { Self.trimmed($0.absoluteString) } }
    /// A URL's origin, "scheme://host[:port]", lowercased: what a browser sends as Origin.
    public static func origin(of url: URL) -> String {
        "\(url.scheme?.lowercased() ?? "https")://\(url.host()?.lowercased() ?? "")" + (url.port.map { ":\($0)" } ?? "")
    }
    static func trimmed(_ text: String) -> String { text.hasSuffix("/") ? String(text.dropLast()) : text }
    static let loopback: Set<String> = ["127.0.0.1", "localhost"]

    /// The relay's URL, when it's https (or http on this computer, for `wrangler dev`) with no path, query, or fragment.
    public var relay: URL? { Self.validRelay(relayURL) }

    public static func validRelay(_ raw: String) -> URL? {
        let text = Self.trimmed(raw.trimmingCharacters(in: .whitespaces))
        guard !text.isEmpty, text.count <= 300, let url = URL(string: text), let scheme = url.scheme, let host = url.host(), !host.isEmpty,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil, url.path.isEmpty else { return nil }
        guard scheme == "https" || (scheme == "http" && Self.loopback.contains(host)) else { return nil }
        return url
    }
}

/// How many disclosures a caller may have before the owner is asked: per caller per window, and across every
/// caller together (so many callers, or one caller under many names, can't add up to a whole address book).
public struct GatewayBudget: Codable, Hashable, Sendable {
    /// Calls of any tool, per caller per hour.
    public var callsPerHour = 30
    /// Different people looked up (found or not), per caller per day.
    public var contactsPerDay = 5
    /// Different people looked up by every caller together, per day.
    public var contactsPerDayEveryone = 12
    /// Free/busy calls per caller per hour.
    public var freeBusyPerHour = 8
    /// Days of free/busy, counted once each, per caller per day.
    public var freeBusyDaysPerDay = 14
    /// Questions for KemoSabe per caller per hour.
    public var asksPerHour = 10
    /// Files, message excerpts, and photos per caller per hour.
    public var sharesPerHour = 10
    /// Lists per caller per hour.
    public var listsPerHour = 20
    /// Things sent into the Inbox per caller per hour.
    public var deliveriesPerHour = 10
    /// Past this many times a budget, the call is refused without asking (no flood of cards).
    public var hardMultiple = 3
    /// Disclosure units per caller per day: one per contact field, one per day of free/busy (or per hour at
    /// quarter hours), one per list, file, excerpt, photo, or answer. Over it asks the owner; nothing over it is spent.
    public var unitsPerCaller = 40
    /// A caller's own allowance, by caller id, in place of `unitsPerCaller`.
    public var unitsByCaller: [String: Int] = [:]
    /// Disclosure units for every caller together per day.
    public var unitsEveryone = 100
    /// Cards waiting on the owner, per caller and in all.
    public var pendingPerCaller = 3
    public var pendingEveryone = 10
    public init() {}

    public func units(for caller: String) -> Int { unitsByCaller[caller] ?? unitsPerCaller }

    private enum CodingKeys: String, CodingKey {
        case callsPerHour, contactsPerDay, contactsPerDayEveryone, freeBusyPerHour, freeBusyDaysPerDay, asksPerHour, sharesPerHour, listsPerHour
        case deliveriesPerHour, hardMultiple, unitsPerCaller, unitsByCaller, unitsEveryone, pendingPerCaller, pendingEveryone
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = GatewayBudget()
        func read(_ key: CodingKeys, _ fallback: Int, floor: Int = 1) throws -> Int { max(floor, try c.decodeIfPresent(Int.self, forKey: key) ?? fallback) }
        callsPerHour = try read(.callsPerHour, d.callsPerHour)
        contactsPerDay = try read(.contactsPerDay, d.contactsPerDay)
        contactsPerDayEveryone = try read(.contactsPerDayEveryone, d.contactsPerDayEveryone)
        freeBusyPerHour = try read(.freeBusyPerHour, d.freeBusyPerHour)
        freeBusyDaysPerDay = try read(.freeBusyDaysPerDay, d.freeBusyDaysPerDay)
        asksPerHour = try read(.asksPerHour, d.asksPerHour)
        sharesPerHour = try read(.sharesPerHour, d.sharesPerHour)
        listsPerHour = try read(.listsPerHour, d.listsPerHour)
        deliveriesPerHour = try read(.deliveriesPerHour, d.deliveriesPerHour)
        hardMultiple = try read(.hardMultiple, d.hardMultiple, floor: 2)
        unitsPerCaller = try read(.unitsPerCaller, d.unitsPerCaller, floor: 0)
        unitsByCaller = (try? c.decodeIfPresent([String: Int].self, forKey: .unitsByCaller)) ?? [:]
        unitsEveryone = try read(.unitsEveryone, d.unitsEveryone, floor: 0)
        pendingPerCaller = try read(.pendingPerCaller, d.pendingPerCaller)
        pendingEveryone = try read(.pendingEveryone, d.pendingEveryone)
    }
}

// MARK: Secrets

/// Tokens and codes: random, shown once, kept only as SHA-256 hashes.
public enum GatewaySecrets {
    /// 32 random bytes, base64url, after a prefix that says what it is ("ksk_" a client token, "ksat_" an access
    /// token, "ksrt_" a refresh token).
    public static func token(_ prefix: String) -> String { prefix + base64url(random(32)) }
    public static func random(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            var generator = SystemRandomNumberGenerator()
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max, using: &generator) }
        }
        return Data(bytes)
    }
    public static func hash(_ secret: String) -> String { hex(Data(secret.utf8)) }
    /// SHA-256 as hex: tokens are kept this way, and the ledger names a shared item by it.
    public static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    /// PKCE's S256: base64url(SHA-256(verifier)).
    public static func s256(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    /// Compares two strings in time that doesn't depend on where they differ.
    public static func equal(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for index in x.indices { difference |= x[index] ^ y[index] }
        return difference == 0
    }
}

// MARK: Text from callers

/// Everything a caller sends is hostile input: these keep names and questions short, on one line, and free of
/// control characters before anything else looks at them.
public enum GatewayText {
    /// A caller's or a client's name: at most 40 characters, letters, digits, spaces, and a little punctuation.
    public static func name(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.init(charactersIn: " .-_'()&"))
        let kept = String(String.UnicodeScalarView(raw.unicodeScalars.filter { allowed.contains($0) }))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let short = String(kept.prefix(40)).trimmingCharacters(in: .whitespaces)
        return short.isEmpty ? "An agent" : short
    }
    /// One line, no control or format characters, at most `limit` characters; nil when it's longer.
    public static func line(_ raw: String, limit: Int) -> String? {
        let text = clean(raw)
        guard text.count <= limit else { return nil }
        return text
    }
    /// One line, no control or format characters, cut to `limit` characters (for records, which may be long).
    public static func cut(_ raw: String, limit: Int) -> String {
        let text = clean(raw)
        return text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }
    private static func clean(_ raw: String) -> String {
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar)
                || scalar.properties.generalCategory == .format { return " " }
            return Character(scalar)
        }
        return String(scalars).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
