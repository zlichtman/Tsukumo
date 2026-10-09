import Foundation

// The Tsukumo relay's wire format, as the Mac client speaks it: every frame, the signed message, the limits, and
// the close codes, in this one file, so a protocol revision touches only this. The spec is the relay's own
// (`relay/src/protocol.ts` and docs/ARCHITECTURE.md, "The envelope"); protocol `tsukumo-relay-v1`.
//
// Frames are JSON objects in WebSocket text frames. `*_b64` fields are standard base64 with padding; keys,
// signatures, and nonces are base64url without padding. Headers are `[name, value]` pairs, names lowercase.

public enum RelayEnvelope {
    public static let protocolName = "tsukumo-relay-v1"

    // MARK: Limits (the relay's `LIMITS`)

    /// Largest inline body in a `req` or `res`, and largest decoded `chunk`, either way.
    public static let maxChunkBytes = 256 * 1_024
    /// Body bytes either side may have sent for one request and not yet had acknowledged.
    public static let windowBytes = 1_024 * 1_024
    /// Largest text frame, checked before it's parsed.
    public static let maxFrameChars = 400 * 1_024
    /// How long a challenge's nonce stays good.
    public static let nonceLifetime: TimeInterval = 30
    /// Requests this Mac works on at once over the relay (the relay allows 8 per device).
    public static let maxInFlight = 16
    /// Keepalive: one `ping` every 30 seconds, exactly these 15 bytes.
    public static let pingInterval: Duration = .seconds(30)
    public static let ping = #"{"type":"ping"}"#
    public static let unregister = #"{"type":"unregister"}"#

    // MARK: Close codes

    public enum Close {
        /// Replaced by a newer connection of this device: don't fight it.
        public static let replaced = 4000
        /// The registration was deleted: stop.
        public static let unregistered = 4001
        public static let protocolError = 4400
        public static let frameTooLarge = 4409
        public static let normal = 1000
    }

    // MARK: Connecting

    public enum Mode: String, Sendable { case register, connect }

    /// A device id: 128 random bits as lowercase RFC 4648 base32 with no padding (26 characters).
    public static func validDeviceID(_ id: String) -> Bool {
        id.count == 26 && id.allSatisfy { ("a"..."z").contains($0) || ("2"..."7").contains($0) }
    }

    /// The answer to `GET /challenge`.
    public struct Challenge: Decodable, Sendable, Equatable {
        public let protocolName: String
        public let mode: Mode
        public let deviceID: String
        public let nonce: String
        public let expiresInMs: Int?
        enum CodingKeys: String, CodingKey { case protocolName = "protocol", mode, deviceID = "device_id", nonce, expiresInMs = "expires_in_ms" }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            protocolName = try c.decode(String.self, forKey: .protocolName)
            guard let mode = Mode(rawValue: try c.decode(String.self, forKey: .mode)) else {
                throw DecodingError.dataCorruptedError(forKey: .mode, in: c, debugDescription: "mode")
            }
            self.mode = mode
            deviceID = try c.decode(String.self, forKey: .deviceID)
            nonce = try c.decode(String.self, forKey: .nonce)
            expiresInMs = try c.decodeIfPresent(Int.self, forKey: .expiresInMs)
        }
        public init(mode: Mode, deviceID: String, nonce: String) {
            protocolName = RelayEnvelope.protocolName; self.mode = mode; self.deviceID = deviceID; self.nonce = nonce; expiresInMs = 30_000
        }
    }

    /// `GET <relay>/challenge?device=<id>` to reconnect, `GET <relay>/challenge` to register.
    public static func challengeURL(relay: URL, deviceID: String?) -> URL {
        var components = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        components.path = "/challenge"
        components.queryItems = deviceID.map { [URLQueryItem(name: "device", value: $0)] }
        return components.url!
    }
    /// `wss://<relay>/connect?device=<id>` (`ws://` for a relay on this computer).
    public static func connectURL(relay: URL, deviceID: String) -> URL {
        var components = URLComponents(url: relay, resolvingAgainstBaseURL: false)!
        components.scheme = relay.scheme == "http" ? "ws" : "wss"
        components.path = "/connect"
        components.queryItems = [URLQueryItem(name: "device", value: deviceID)]
        return components.url!
    }

    /// What the device signs: `tsukumo-relay-v1\nauth\n<mode>\n<device_id>\n<nonce>` (UTF-8, no trailing newline),
    /// with ECDSA P-256 and SHA-256, as 64 raw bytes (r then s).
    public static func authMessage(mode: Mode, deviceID: String, nonce: String) -> Data {
        Data("\(protocolName)\nauth\n\(mode.rawValue)\n\(deviceID)\n\(nonce)".utf8)
    }

    /// The upgrade request's headers: the nonce, the signature, and (only when registering) the public key, the
    /// 65-byte uncompressed point (`x963Representation`).
    public static func upgradeHeaders(nonce: String, signature: Data, publicKey: Data?) -> [String: String] {
        var headers = ["X-Tsukumo-Nonce": nonce, "X-Tsukumo-Signature": base64url(signature)]
        if let publicKey { headers["X-Tsukumo-Public-Key"] = base64url(publicKey) }
        return headers
    }

    // MARK: Frames from the relay

    public struct RequestHead: Sendable, Equatable {
        public let id: String
        public let method: String
        /// The device's own path (no `/d/<id>`), starting with "/".
        public let path: String
        /// Without "?"; empty when there's none.
        public let query: String
        public let headers: [(String, String)]
        public static func == (a: RequestHead, b: RequestHead) -> Bool {
            a.id == b.id && a.method == b.method && a.path == b.path && a.query == b.query && a.headers.map { [$0.0, $0.1] } == b.headers.map { [$0.0, $0.1] }
        }
    }

    public enum Inbound: Sendable, Equatable {
        case ready(deviceID: String, publicBase: String, registered: Bool)
        /// A request: its whole body inline, or (`streamed`) the body follows in `chunk`s and an `end`.
        case request(RequestHead, body: Data, streamed: Bool)
        case chunk(id: String, data: Data)
        case end(id: String)
        case cancel(id: String)
        case ack(id: String, bytes: Int)
        case unregistered(deviceID: String)
        case pong
        /// A frame type this version doesn't know: ignored, for later versions.
        case unknown
        /// A malformed `req` (an inline body over 256 KiB, bad base64, missing fields): answered 400, once.
        case badRequest(id: String)
        /// Any other malformed frame (a bad chunk ends its request with 400). Carries the request id when there is one.
        case invalid(id: String?)
    }

    private struct Frame: Decodable {
        var type: String
        var id: String?
        var device_id: String?
        var public_base: String?
        var registered: Bool?
        var method: String?
        var path: String?
        var query: String?
        var headers: [[String]]?
        var body_b64: String?
        var body_stream: Bool?
        var data_b64: String?
        var bytes: Int?
    }

    /// Parses one text frame. Nil when it's over the frame limit or isn't a JSON object with a type (the caller
    /// closes the socket with `protocolError` or `frameTooLarge`).
    public static func parse(_ text: String) -> Inbound? {
        guard text.utf8.count <= maxFrameChars, let frame = try? JSONDecoder().decode(Frame.self, from: Data(text.utf8)) else { return nil }
        switch frame.type {
        case "ready":
            guard let id = frame.device_id, let base = frame.public_base else { return .invalid(id: nil) }
            return .ready(deviceID: id, publicBase: base, registered: frame.registered ?? false)
        case "req":
            guard let id = frame.id, validRequestID(id) else { return .invalid(id: nil) }
            guard let method = frame.method, let path = frame.path, let pairs = frame.headers else { return .badRequest(id: id) }
            var headers: [(String, String)] = []
            for pair in pairs {
                guard pair.count == 2 else { return .badRequest(id: id) }
                headers.append((pair[0].lowercased(), pair[1]))
            }
            let streamed = frame.body_stream == true
            let b64 = frame.body_b64 ?? ""
            guard decodedLength(b64) <= maxChunkBytes + 2, let body = Data(base64Encoded: b64), body.count <= maxChunkBytes else { return .badRequest(id: id) }
            if streamed && !body.isEmpty { return .badRequest(id: id) }
            return .request(RequestHead(id: id, method: method, path: path, query: frame.query ?? "", headers: headers), body: body, streamed: streamed)
        case "chunk":
            guard let id = frame.id, validRequestID(id) else { return .invalid(id: nil) }
            guard let b64 = frame.data_b64, decodedLength(b64) <= maxChunkBytes + 2, let data = Data(base64Encoded: b64), data.count <= maxChunkBytes else { return .invalid(id: id) }
            return .chunk(id: id, data: data)
        case "end":
            guard let id = frame.id, validRequestID(id) else { return .invalid(id: nil) }
            return .end(id: id)
        case "cancel":
            guard let id = frame.id, validRequestID(id) else { return .invalid(id: nil) }
            return .cancel(id: id)
        case "ack":
            guard let id = frame.id, validRequestID(id), let bytes = frame.bytes, bytes >= 0 else { return .invalid(id: nil) }
            return .ack(id: id, bytes: bytes)
        case "unregistered": return .unregistered(deviceID: frame.device_id ?? "")
        case "pong": return .pong
        default: return .unknown
        }
    }

    static func validRequestID(_ id: String) -> Bool { (1...100).contains(id.count) }
    static func decodedLength(_ b64: String) -> Int { b64.utf8.count * 3 / 4 }

    // MARK: Frames to the relay

    private struct Response: Encodable {
        let type = "res"
        let id: String
        let status: Int
        let headers: [[String]]
        let body_b64: String?
        let stream: Bool?
    }
    private struct Chunk: Encodable { let type = "chunk"; let id: String; let data_b64: String }
    private struct IDFrame: Encodable { let type: String; let id: String }
    private struct Ack: Encodable { let type = "ack"; let id: String; let bytes: Int }

    private static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }

    /// The whole answer at once (body at most 256 KiB), or, with `stream`, its head (chunks and `end` follow).
    public static func response(id: String, status: Int, headers: [(String, String)], body: Data?, stream: Bool) -> String {
        encode(Response(id: id, status: status, headers: headers.map { [$0.0.lowercased(), $0.1] },
                        body_b64: stream ? nil : (body ?? Data()).base64EncodedString(), stream: stream ? true : nil))
    }
    public static func chunk(id: String, data: Data) -> String { encode(Chunk(id: id, data_b64: data.base64EncodedString())) }
    public static func end(id: String) -> String { encode(IDFrame(type: "end", id: id)) }
    public static func ack(id: String, bytes: Int) -> String { encode(Ack(id: id, bytes: bytes)) }

    /// The gateway's answer as the relay carries it: names lowercase, and none of the headers the relay sets or
    /// drops for itself (`content-length`, `connection`).
    public static func responseHeaders(_ response: HTTPResponse) -> [(String, String)] {
        response.headers.map { ($0.0.lowercased(), $0.1) }.filter { !["content-length", "connection", "transfer-encoding"].contains($0.0) }
    }
    /// Answers that carry no body: to HEAD, and 204, 205, and 304.
    public static func bodyless(method: String, status: Int) -> Bool { method == "HEAD" || [204, 205, 304].contains(status) }

    // MARK: Into the gateway

    /// A relayed request written out as HTTP/1.1, for the gateway's own parser (`HTTPRequest.parse`), so a relayed
    /// request meets exactly the checks a local one does. `host` is kept as the relay set it (the public host),
    /// never rewritten to 127.0.0.1. Nil when a name or value could break the framing (the relay never sends one).
    public static func wire(_ head: RequestHead, body: Data) -> Data? {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        guard !head.method.isEmpty, head.method.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        let target = head.query.isEmpty ? head.path : head.path + "?" + head.query
        guard target.hasPrefix("/"), !target.unicodeScalars.contains(where: { $0.value <= 0x20 || $0.value == 0x7F }) else { return nil }
        var text = "\(head.method) \(target) HTTP/1.1\r\n"
        for (name, value) in head.headers {
            guard !name.isEmpty, name.unicodeScalars.allSatisfy(allowed.contains),
                  !value.unicodeScalars.contains(where: { $0 == "\r" || $0 == "\n" || $0 == "\0" }) else { return nil }
            // The body is exact: its length is written here, and nothing about framing passes through.
            if ["content-length", "transfer-encoding", "connection"].contains(name) { continue }
            text += "\(name): \(value)\r\n"
        }
        text += "Content-Length: \(body.count)\r\n\r\n"
        return Data(text.utf8) + body
    }

    // MARK: Encodings

    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
    public static func fromBase64url(_ text: String) -> Data? {
        guard text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        var b64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        return Data(base64Encoded: b64)
    }
}
