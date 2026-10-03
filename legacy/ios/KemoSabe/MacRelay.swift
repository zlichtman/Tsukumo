import CryptoKit
import Foundation
import Security

// Your Mac's agents from iPhone (design/CONTEXT-HARNESS.md#your-macs-agents-from-iphone). The iPhone has
// no Claude Code, Codex, Muse Code, or Cursor Agent, and only each company's own apps may sign in to
// them or hold their tokens. So the iPhone sends a chat's messages to the owner's own paired Mac, which
// runs each one through the same path as its own chat with that agent (`KemoSabeHandoff`: the owner's
// unmodified CLI, headless, on their own sign-in), and the reply streams back. No credential or token is
// ever read, copied, or sent; the Mac only starts the agent's program. When the agent asks KemoSabe
// something, the question comes back to the iPhone and the iPhone's own KemoSabe answers it
// (`AgentQuestionDesk`, with its consent card).
//
// This file is the protocol both apps compile: pairing codes and invites, keys, the frames, and their
// framing. Same Wi‑Fi only for now (`MacRelayNetwork`: Bonjour and TLS with a pre-shared key); a
// transport through iCloud can be added behind `MacRelayTransport` later.

enum MacRelay {
    /// 2: `welcome` and `pong` list every agent (`agents`), and `send` names one (`agent`). 3: the account's
    /// records sync over the connection when the Mac has no iCloud (`MacRelaySync`). Each side speaks
    /// the lower of the two versions: a version 1 Mac (Tsukumo 74) still runs Claude, and a version 2
    /// side never sees a sync frame.
    static let version = 3
    /// The oldest version this build still speaks.
    static let oldestVersion = 1
    /// The version both sides speak, from the other side's; nil when there's none.
    static func agreed(_ theirs: Int?) -> Int? {
        let theirs = theirs ?? oldestVersion
        return theirs >= oldestVersion ? min(theirs, version) : nil
    }
    /// The Bonjour service the Mac advertises while Agents on your Mac is on.
    static let serviceType = "_kemosabe-relay._tcp"
    /// The longest frame either side accepts. Sync pages (version 3) are the large ones; everything else
    /// stays far below this.
    static let maxFrame = 8 * 1024 * 1024
    /// How long the Mac keeps a finished turn's result for a phone that reconnects (`resume`).
    static let resultLifetime: TimeInterval = 10 * 60
    /// How long a pairing code works.
    static let pairingLifetime: TimeInterval = 10 * 60
    /// The TLS identity a pairing connection uses; its key comes from the code.
    static let pairingIdentity = "pair"
    /// The TLS identity a paired iPhone uses; its key was made when it paired.
    static func identity(phone: UUID) -> String { "phone:" + phone.uuidString }
    static func phone(identity: String) -> UUID? {
        identity.hasPrefix("phone:") ? UUID(uuidString: String(identity.dropFirst(6))) : nil
    }
    /// Where it's set up: on iPhone, "Settings → Models → Agents on your Mac"; on the Mac,
    /// "Tsukumo → Settings → Models → Agents on your Mac" (`SettingsCatalog.macAgents`).
    static let phoneSettings = "Settings → Models → " + SettingsCatalog.macAgents.iPhone
    static let macSettings = "Tsukumo → Settings → Models → " + SettingsCatalog.macAgents.mac

    struct Failure: Error, Equatable, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    /// An agent on the Mac, as the phone shows it.
    enum AgentState: String, Codable, Sendable {
        case signedIn, signedOut, notInstalled
        /// Installed; sign-in not known yet.
        case installed
        init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .installed }
        /// What the phone says about it, or nil when it's ready. `product` is its program ("Codex").
        func problem(_ product: String) -> String? {
            switch self {
            case .signedIn, .installed: nil
            case .signedOut: "\(product) isn’t signed in on your Mac. Open Tsukumo on your Mac and sign in to \(product) there."
            case .notInstalled: "\(product) isn’t installed on your Mac. Install it on your Mac and sign in there."
            }
        }
        /// Claude Code's, as version 1 said it.
        var problem: String? { problem(ChatAgents.claude.product) }
    }

    /// One agent the Mac can run for the phone (`welcome.agents`, `pong.agents`).
    struct Agent: Codable, Equatable, Sendable, Identifiable {
        /// Its chat ID: "claude-code", "codex", "muse", "cursor-agent", "acp:<id>".
        var id: String
        /// "Codex", or an added agent's own name.
        var name: String
        /// Its program's name ("Claude Code").
        var product: String
        var state: AgentState
        init(id: String, name: String, product: String, state: AgentState) { self.id = id; self.name = name; self.product = product; self.state = state }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = String(try container.decode(String.self, forKey: .id).prefix(80))
            name = String((try container.decodeIfPresent(String.self, forKey: .name) ?? ChatAgents.kind(id)?.title ?? id).prefix(60))
            product = String((try container.decodeIfPresent(String.self, forKey: .product) ?? ChatAgents.kind(id)?.product ?? name).prefix(60))
            state = try container.decodeIfPresent(AgentState.self, forKey: .state) ?? .installed
        }
        var problem: String? { state.problem(product) }
    }
    /// The most agents a Mac lists.
    static let maxAgents = 12
}

// MARK: Frames

extension MacRelay {
    /// One message on the wire: a type and the fields it uses.
    ///
    /// - Connecting: Mac `challenge{v, nonce, mac, name}`, then the phone's `hello{v, phone, build, name, proof}`
    ///   (or `pair{…}` with a pairing code), then `welcome{v, mac, name, claude, agents}` or `refused{problem}`.
    ///   `v` is the lower of the two sides' versions; `agents` (version 2) lists every agent the Mac can
    ///   run, and `claude` is Claude Code's state, as version 1 had it.
    /// - A turn: `send{chat, turn, text, session, agent}` (`agent` is the chat's agent, version 2; without
    ///   it, Claude); the Mac streams `delta{turn, text}` and ends with `done{turn, reply, session}` or
    ///   `failed{turn, problem}`. `stop{turn}` ends it; `resume{turn}` after reconnecting gets the result
    ///   (or `running{turn, text}` while it's still going).
    /// - KemoSabe's questions: Mac `ask{chat, turn, ask, text, purpose, agent, client}` (`agent` is the MCP
    ///   identity, "codex"); phone `answer{ask, status, text}`.
    /// - `ping` → `pong{claude, agents}`.
    /// - Unpairing: the phone's `unpair{phone, proof}` (HMAC of this connection's nonce with its key);
    ///   the Mac removes that phone and answers `unpaired{mac, phone}` before it closes the connection.
    ///   An older Mac ignores `unpair` (an unknown type), so the phone keeps waiting for `unpaired`.
    /// - Sync (version 3, `MacRelaySync`): the phone's `hello` says `sync: "hub"` when it can carry the
    ///   account's records (it syncs with iCloud). The Mac asks `syncPull{request, token}` and gets
    ///   `syncRecords{request, records, token, more}` a page at a time; it sends its own changes with
    ///   `syncPush{request, records}` and gets `syncAck{request}` (or `syncFailed{request, problem}` for
    ///   either). The phone's `syncChanged` says it has something new, so the Mac syncs soon.
    struct Frame: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case challenge, hello, pair, paired, welcome, refused
            case send, delta, done, failed, stop, resume, running
            case ask, answer, ping, pong
            case unpair, unpaired
            case syncPull, syncRecords, syncPush, syncAck, syncFailed, syncChanged
            /// A type from a newer build.
            case unknown
            init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown }
        }
        var type: Kind
        var v: Int?
        var nonce: String?
        /// The Mac's ID (challenge, welcome, paired).
        var mac: UUID?
        /// The Mac's name, or the phone's.
        var name: String?
        var phone: UUID?
        var build: String?
        var proof: String?
        var claude: AgentState?
        /// Every agent the Mac can run (version 2: `welcome`, `pong`).
        var agents: [Agent]?
        /// A paired phone's long-term key, base64, only in `paired`.
        var key: String?
        var chat: UUID?
        var turn: UUID?
        var text: String?
        var reply: String?
        var problem: String?
        /// The agent's own session for this chat, so a chat continued on another device resumes it.
        var session: String?
        var ask: UUID?
        var purpose: String?
        /// On `send`, the chat's agent ("codex"); on `ask`, the MCP identity that asked.
        var agent: String?
        var client: String?
        var status: String?
        /// Sync (version 3): the request a reply answers, the records, the phone's log position, whether
        /// another page follows, and, on `hello`, "hub" when the phone can carry the account's records.
        var request: UUID?
        var records: [SyncRecord]?
        var token: String?
        var more: Bool?
        var sync: String?
        init(_ type: Kind) { self.type = type }
        static func make(_ type: Kind, _ fill: (inout Frame) -> Void) -> Frame { var frame = Frame(type); fill(&frame); return frame }
    }
}

// MARK: Framing

extension MacRelay {
    /// A 4-byte big-endian length, then that many bytes of JSON, as the MacSpaces bridge frames its messages.
    enum Framing {
        static func encode(_ frame: Frame) throws -> Data {
            let body = try JSONEncoder().encode(frame)
            guard body.count <= MacRelay.maxFrame else { throw Failure("That message is too long to send.") }
            let n = UInt32(body.count)
            return Data([UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)]) + body
        }
        /// Collects bytes as they arrive and returns each whole frame.
        struct Reader {
            private var buffer = Data()
            var pending: Int { buffer.count }
            mutating func append(_ data: Data) throws -> [Frame] {
                buffer.append(data)
                var frames: [Frame] = []
                while buffer.count >= 4 {
                    let header = buffer.prefix(4)
                    let count = header.reduce(0) { ($0 << 8) | Int($1) }
                    guard count <= MacRelay.maxFrame else { throw Failure("A message was larger than KemoSabe accepts.") }
                    guard buffer.count >= 4 + count else { break }
                    let body = buffer.dropFirst(4).prefix(count)
                    buffer = Data(buffer.dropFirst(4 + count))
                    frames.append(try JSONDecoder().decode(Frame.self, from: Data(body)))
                }
                return frames
            }
        }
    }
}

// MARK: Pairing

extension MacRelay {
    /// A pairing code: 28 symbols of Crockford base32 (140 random bits), typed in groups of four.
    enum PairingCode {
        static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")
        static let length = 28
        static func make() -> String {
            var bytes = [UInt8](repeating: 0, count: length)
            precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "No random bytes")
            // 256 is a multiple of 32, so each symbol is uniform.
            return String(bytes.map { alphabet[Int($0 & 31)] })
        }
        /// "7K3M-Q9TD-…", for reading and typing.
        static func grouped(_ code: String) -> String {
            stride(from: 0, to: code.count, by: 4).map { start in
                let from = code.index(code.startIndex, offsetBy: start)
                return String(code[from..<code.index(from, offsetBy: min(4, code.count - start))])
            }.joined(separator: "-")
        }
        /// A typed code: any case, spaces or dashes, and O, I, L read as 0, 1, 1. Nil unless it's a whole code.
        static func normalize(_ typed: String) -> String? {
            var code = ""
            for character in typed.uppercased() {
                switch character {
                case " ", "-", "\n", "\t": continue
                case "O": code.append("0")
                case "I", "L": code.append("1")
                default:
                    guard alphabet.contains(character) else { return nil }
                    code.append(character)
                }
            }
            return code.count == length ? code : nil
        }
    }

    /// What the Mac's QR code (or typed code) gives the phone: `kemosabe://pair-mac?mac=<id>&name=<Mac>&code=<code>`.
    struct Invite: Equatable, Sendable {
        var mac: UUID?
        var name: String?
        var code: String
        static let host = "pair-mac"
        init(mac: UUID?, name: String?, code: String) { self.mac = mac; self.name = name; self.code = code }
        init?(url: URL) {
            guard url.scheme?.lowercased() == "kemosabe", url.host()?.lowercased() == Self.host,
                  let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
                  let code = items.first(where: { $0.name == "code" })?.value.flatMap(PairingCode.normalize) else { return nil }
            self.code = code
            mac = items.first { $0.name == "mac" }?.value.flatMap(UUID.init(uuidString:))
            name = items.first { $0.name == "name" }?.value.map { String($0.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80)) }.flatMap { $0.isEmpty ? nil : $0 }
        }
        /// A typed code, or a pasted pairing link.
        init?(typed: String) {
            let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: text), url.scheme != nil { self.init(url: url); return }
            guard let code = PairingCode.normalize(text) else { return nil }
            self.init(mac: nil, name: nil, code: code)
        }
        var url: URL {
            var components = URLComponents()
            components.scheme = "kemosabe"; components.host = Self.host
            components.queryItems = [mac.map { URLQueryItem(name: "mac", value: $0.uuidString) }, name.map { URLQueryItem(name: "name", value: $0) },
                                     URLQueryItem(name: "code", value: code)].compactMap { $0 }
            return components.url!
        }
    }

    /// A code the Mac is showing: single-use, and good for ten minutes.
    struct PairingOffer: Equatable, Sendable {
        let code: String
        let created: Date
        var used = false
        init(code: String = PairingCode.make(), created: Date = Date()) { self.code = code; self.created = created }
        var expires: Date { created.addingTimeInterval(MacRelay.pairingLifetime) }
        func isOpen(at now: Date = Date()) -> Bool { !used && now < expires && now >= created.addingTimeInterval(-60) }
    }
}

// MARK: Keys

extension MacRelay {
    enum Keys {
        /// The pre-shared key a pairing connection uses, from the code alone (HKDF-SHA256).
        static func pairing(code: String) -> Data {
            let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(code.utf8)), salt: Data("kemosabe-relay-pairing".utf8),
                                             info: Data("v1".utf8), outputByteCount: 32)
            return key.withUnsafeBytes { Data($0) }
        }
        /// A paired phone's long-term key: 32 random bytes, made by the Mac when it pairs.
        static func make() -> Data {
            var bytes = [UInt8](repeating: 0, count: 32)
            precondition(SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess, "No random bytes")
            return Data(bytes)
        }
        static func nonce() -> String { make().base64EncodedString() }
        /// Proof that the phone holds `key`, for this connection's nonce: HMAC-SHA256 over the type, nonce, and phone.
        static func proof(key: Data, nonce: String, phone: UUID, kind: Frame.Kind) -> String {
            let message = Data((kind.rawValue + "|" + nonce + "|" + phone.uuidString).utf8)
            return Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: key))).base64EncodedString()
        }
        static func verify(_ proof: String?, key: Data, nonce: String, phone: UUID, kind: Frame.Kind) -> Bool {
            guard let proof, let given = Data(base64Encoded: proof) else { return false }
            let message = Data((kind.rawValue + "|" + nonce + "|" + phone.uuidString).utf8)
            return HMAC<SHA256>.isValidAuthenticationCode(given, authenticating: message, using: SymmetricKey(data: key))
        }
    }
}
