#if os(macOS)
import CryptoKit
import Foundation

// The Muse link's Noise XX handshake and its transport, with CryptoKit.
// Ported from Meta's Muse Gadget SDK (Apache-2.0): `noise/noise_xx.py` (the pattern
// Noise_XX_25519_AESGCM_SHA256, the empty prologue, low-order point checks, the nonce ceiling, and a
// state that's dead after any failure), `noise/framing.py` (chunked transport frames), and
// `noise/transport.py` (service requests in, service responses out). Provenance: TsukumoKit/MUSE-NOTICE.md.

public struct MuseNoiseError: Error, Equatable, CustomStringConvertible {
    public let description: String
    init(_ description: String) { self.description = description }
}

public enum MuseNoise {
    public static let protocolName = Array("Noise_XX_25519_AESGCM_SHA256".utf8)
    static let dhKeyLength = 32, tagLength = 16
    static let minMessage2 = dhKeyLength + (dhKeyLength + tagLength) + tagLength
    static let minMessage3 = dhKeyLength + tagLength + tagLength
    static let maxSafeNonce: UInt64 = (1 << 53) - 1

    /// X25519 public keys of small order, refused before any DH (the SDK's list, byte for byte).
    static let lowOrderPoints: [[UInt8]] = [
        [UInt8](repeating: 0, count: 32),
        [1] + [UInt8](repeating: 0, count: 31),
        [0xE0, 0xEB, 0x7A, 0x7C, 0x3B, 0x41, 0xB8, 0xAE, 0x16, 0x56, 0xE3, 0xFA, 0xF1, 0x9F, 0xC4, 0x6A,
         0xDA, 0x09, 0x8D, 0xEB, 0x9C, 0x32, 0xB1, 0xFD, 0x86, 0x62, 0x05, 0x16, 0x5F, 0x49, 0xB8, 0x00],
        [0x5F, 0x9C, 0x95, 0xBC, 0xA3, 0x50, 0x8C, 0x24, 0xB1, 0xD0, 0xB1, 0x55, 0x9C, 0x83, 0xEF, 0x5B,
         0x04, 0x44, 0x5C, 0xC4, 0x58, 0x1C, 0x8E, 0x86, 0xD8, 0x22, 0x4E, 0xDD, 0xD0, 0x9F, 0x11, 0x57],
        [0xEC] + [UInt8](repeating: 0xFF, count: 30) + [0x7F],
        [0xED] + [UInt8](repeating: 0xFF, count: 30) + [0x7F],
        [0xEE] + [UInt8](repeating: 0xFF, count: 30) + [0x7F],
    ]

    static func hmac(_ key: [UInt8], _ data: [UInt8]) -> [UInt8] {
        Array(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }
    /// Noise's HKDF: two or three outputs from the chaining key.
    static func hkdf(_ chainingKey: [UInt8], _ material: [UInt8], outputs: Int) -> [[UInt8]] {
        let temp = hmac(chainingKey, material)
        let first = hmac(temp, [0x01])
        let second = hmac(temp, first + [0x02])
        return outputs == 2 ? [first, second] : [first, second, hmac(temp, second + [0x03])]
    }
    static func sha256(_ data: [UInt8]) -> [UInt8] { Array(SHA256.hash(data: data)) }

    static func dh(_ privateKey: Curve25519.KeyAgreement.PrivateKey, _ publicKey: [UInt8]) throws -> [UInt8] {
        guard publicKey.count == dhKeyLength else { throw MuseNoiseError("x25519: invalid public key length") }
        if lowOrderPoints.contains(publicKey) { throw MuseNoiseError("x25519: rejected low-order public key") }
        let peer = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: publicKey)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes { Array($0) }
        if shared.allSatisfy({ $0 == 0 }) { throw MuseNoiseError("x25519: DH produced all-zeros output") }
        return shared
    }
}

/// One direction's AES-256-GCM key and nonce counter. Any failure poisons it for good.
public final class MuseCipherState: @unchecked Sendable {
    private let lock = NSLock()
    private var key: SymmetricKey?
    private var nonce: UInt64 = 0
    private var poisoned = false

    public init() {}
    init(key: [UInt8]) throws { try initializeKey(key) }

    func initializeKey(_ raw: [UInt8]) throws {
        try lock.withLock {
            guard !poisoned else { throw MuseNoiseError("CipherState: poisoned after prior failure") }
            guard raw.count == 32 else { throw MuseNoiseError("CipherState: AES-GCM key must be 32 bytes") }
            key = SymmetricKey(data: raw)
            nonce = 0
        }
    }
    var hasKey: Bool { lock.withLock { key != nil } }

    static func iv(_ nonce: UInt64) -> [UInt8] {
        [0, 0, 0, 0] + withUnsafeBytes(of: nonce.bigEndian) { Array($0) }
    }

    public func encrypt(ad: [UInt8], _ plaintext: [UInt8]) throws -> [UInt8] {
        try lock.withLock {
            guard !poisoned else { throw MuseNoiseError("CipherState: poisoned after prior failure") }
            guard let key else { return plaintext }
            let nonce = try nextNonce()
            do {
                let box = try AES.GCM.seal(plaintext, using: key, nonce: AES.GCM.Nonce(data: Self.iv(nonce)), authenticating: ad)
                return Array(box.ciphertext) + Array(box.tag)
            } catch { poisoned = true; throw error }
        }
    }

    public func decrypt(ad: [UInt8], _ ciphertext: [UInt8]) throws -> [UInt8] {
        try lock.withLock {
            guard !poisoned else { throw MuseNoiseError("CipherState: poisoned after prior failure") }
            guard let key else { return ciphertext }
            let nonce = try nextNonce()
            do {
                guard ciphertext.count >= MuseNoise.tagLength else { throw MuseNoiseError("CipherState: decrypt failed") }
                let split = ciphertext.count - MuseNoise.tagLength
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: Self.iv(nonce)),
                                                ciphertext: ciphertext[..<split], tag: ciphertext[split...])
                return Array(try AES.GCM.open(box, using: key, authenticating: ad))
            } catch {
                poisoned = true
                throw MuseNoiseError("CipherState: decrypt failed")
            }
        }
    }

    private func nextNonce() throws -> UInt64 {
        guard nonce < MuseNoise.maxSafeNonce else { poisoned = true; throw MuseNoiseError("CipherState: nonce exhausted") }
        defer { nonce += 1 }
        return nonce
    }
}

struct MuseSymmetricState {
    private(set) var chainingKey = [UInt8](repeating: 0, count: 32)
    private(set) var hash = [UInt8](repeating: 0, count: 32)
    private var cipher = MuseCipherState()

    /// The protocol name, padded to 32 bytes (it's shorter than the hash), then the empty prologue.
    mutating func initialize() {
        var padded = [UInt8](repeating: 0, count: 32)
        padded.replaceSubrange(0..<MuseNoise.protocolName.count, with: MuseNoise.protocolName)
        hash = padded
        chainingKey = padded
        mixHash([])
    }
    mutating func mixHash(_ data: [UInt8]) { hash = MuseNoise.sha256(hash + data) }
    mutating func mixKey(_ material: [UInt8]) throws {
        let out = MuseNoise.hkdf(chainingKey, material, outputs: 2)
        chainingKey = out[0]
        cipher = try MuseCipherState(key: out[1])
    }
    mutating func encryptAndHash(_ plaintext: [UInt8]) throws -> [UInt8] {
        let ciphertext = try cipher.encrypt(ad: hash, plaintext)
        mixHash(ciphertext)
        return ciphertext
    }
    mutating func decryptAndHash(_ ciphertext: [UInt8]) throws -> [UInt8] {
        let plaintext = try cipher.decrypt(ad: hash, ciphertext)
        mixHash(ciphertext)
        return plaintext
    }
    mutating func split() throws -> (MuseCipherState, MuseCipherState) {
        let out = MuseNoise.hkdf(chainingKey, [], outputs: 2)
        chainingKey = [UInt8](repeating: 0, count: 32)
        hash = [UInt8](repeating: 0, count: 32)
        return (try MuseCipherState(key: out[0]), try MuseCipherState(key: out[1]))
    }
}

/// The device's side of the handshake: `-> e`, `<- e, ee, s, es`, `-> s, se`. Its static key is made
/// fresh for each session; the per-VM bearer at the WebSocket upgrade is what authenticates the device.
public struct MuseNoiseInitiator {
    enum Phase { case created, initialized, message1Sent, message2Read, message3Sent, split, dead }
    private var state = MuseSymmetricState()
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: [UInt8]?
    private(set) var remoteStatic: [UInt8]?
    private var phase = Phase.created

    public init() {}

    private func require(_ expected: Phase, _ method: String) throws {
        if phase == .dead { throw MuseNoiseError("NoiseXX: \(method) called on dead handshake") }
        if phase != expected { throw MuseNoiseError("NoiseXX: \(method) called in wrong phase") }
    }

    public mutating func initialize() throws {
        try require(.created, "initialize")
        state.initialize()
        phase = .initialized
    }

    public mutating func writeMessage1() throws -> [UInt8] {
        try require(.initialized, "write_message1")
        do {
            let key = Curve25519.KeyAgreement.PrivateKey()
            ephemeral = key
            let pub = Array(key.publicKey.rawRepresentation)
            state.mixHash(pub)
            _ = try state.encryptAndHash([])
            phase = .message1Sent
            return pub
        } catch { phase = .dead; throw error }
    }

    @discardableResult
    public mutating func readMessage2(_ message: [UInt8]) throws -> [UInt8] {
        try require(.message1Sent, "read_message2")
        guard message.count >= MuseNoise.minMessage2 else {
            phase = .dead
            throw MuseNoiseError("NoiseXX: message 2 too short (\(message.count) < \(MuseNoise.minMessage2))")
        }
        do {
            guard let ephemeral else { throw MuseNoiseError("NoiseXX: missing initiator ephemeral key") }
            var offset = 0
            let re = Array(message[offset..<offset + MuseNoise.dhKeyLength])
            remoteEphemeral = re
            state.mixHash(re)
            offset += MuseNoise.dhKeyLength
            try state.mixKey(try MuseNoise.dh(ephemeral, re))
            let rs = try state.decryptAndHash(Array(message[offset..<offset + MuseNoise.dhKeyLength + MuseNoise.tagLength]))
            remoteStatic = rs
            offset += MuseNoise.dhKeyLength + MuseNoise.tagLength
            try state.mixKey(try MuseNoise.dh(ephemeral, rs))
            let payload = try state.decryptAndHash(Array(message[offset...]))
            phase = .message2Read
            return payload
        } catch { phase = .dead; throw error }
    }

    public mutating func writeMessage3() throws -> [UInt8] {
        try require(.message2Read, "write_message3")
        do {
            guard let remoteEphemeral else { throw MuseNoiseError("NoiseXX: missing responder ephemeral key") }
            let staticKey = Curve25519.KeyAgreement.PrivateKey()
            let encryptedStatic = try state.encryptAndHash(Array(staticKey.publicKey.rawRepresentation))
            try state.mixKey(try MuseNoise.dh(staticKey, remoteEphemeral))
            let encryptedPayload = try state.encryptAndHash([])
            phase = .message3Sent
            return encryptedStatic + encryptedPayload
        } catch { phase = .dead; throw error }
    }

    /// The two transport ciphers: sending first, receiving second.
    public mutating func split() throws -> (send: MuseCipherState, receive: MuseCipherState) {
        try require(.message3Sent, "split")
        phase = .split
        ephemeral = nil
        remoteEphemeral = nil
        let (first, second) = try state.split()
        return (first, second)
    }

    public var handshakeHash: [UInt8] { state.hash }
}

/// The VM's side of the handshake, for tests (the SDK keeps one for the same reason).
public struct MuseNoiseResponder {
    private var state = MuseSymmetricState()
    private var ephemeral: Curve25519.KeyAgreement.PrivateKey?
    private var remoteEphemeral: [UInt8]?
    private let payload: [UInt8]
    private var done = false

    public init(payload: [UInt8] = []) { self.payload = payload; state.initialize() }

    public mutating func readMessage1AndWriteMessage2(_ message1: [UInt8]) throws -> [UInt8] {
        guard message1.count >= MuseNoise.dhKeyLength else { throw MuseNoiseError("NoiseXX: message 1 too short") }
        let re = Array(message1[..<MuseNoise.dhKeyLength])
        remoteEphemeral = re
        state.mixHash(re)
        _ = try state.decryptAndHash(Array(message1[MuseNoise.dhKeyLength...]))
        let e = Curve25519.KeyAgreement.PrivateKey()
        ephemeral = e
        let ePub = Array(e.publicKey.rawRepresentation)
        state.mixHash(ePub)
        try state.mixKey(try MuseNoise.dh(e, re))
        let s = Curve25519.KeyAgreement.PrivateKey()
        let encryptedStatic = try state.encryptAndHash(Array(s.publicKey.rawRepresentation))
        try state.mixKey(try MuseNoise.dh(s, re))
        let encryptedPayload = try state.encryptAndHash(payload)
        return ePub + encryptedStatic + encryptedPayload
    }

    public mutating func readMessage3(_ message3: [UInt8]) throws {
        guard message3.count >= MuseNoise.minMessage3 else { throw MuseNoiseError("NoiseXX: message 3 too short") }
        guard let ephemeral else { throw MuseNoiseError("NoiseXX: missing responder ephemeral key") }
        let split = MuseNoise.dhKeyLength + MuseNoise.tagLength
        let rs = try state.decryptAndHash(Array(message3[..<split]))
        try state.mixKey(try MuseNoise.dh(ephemeral, rs))
        _ = try state.decryptAndHash(Array(message3[split...]))
        done = true
    }

    /// The responder sends with the initiator's receive key.
    public mutating func split() throws -> (send: MuseCipherState, receive: MuseCipherState) {
        guard done else { throw MuseNoiseError("NoiseXX: split called in wrong phase") }
        let (first, second) = try state.split()
        return (second, first)
    }
    public var handshakeHash: [UInt8] { state.hash }
}

// MARK: Transport frames (framing.py)

/// `NoiseTransportFrame`: one chunk of a message too big for one encrypted frame.
public struct MuseNoiseFrame: Hashable, Sendable {
    public var chunkID: Int64 = 0, chunkIndex: UInt32 = 0, totalChunks: UInt32 = 1, payload: [UInt8] = []

    public static let maxChunkPayload = 65489, maxTotalChunks = 256, maxPending = 16
    public static let maxAssemblyBytes = 16 * 1024 * 1024, assemblyTTL: TimeInterval = 60

    func encoded() -> [UInt8] {
        var out: [UInt8] = []
        if chunkID != 0 { out += MuseProto.int64Field(1, chunkID) }
        if chunkIndex != 0 { out += MuseProto.varintField(2, UInt64(chunkIndex)) }
        if totalChunks != 0 { out += MuseProto.varintField(3, UInt64(totalChunks)) }
        if !payload.isEmpty { out += MuseProto.bytesField(4, payload) }
        return out
    }

    static func decode(_ data: [UInt8]) throws -> MuseNoiseFrame {
        var reader = MuseProto.Reader(data), frame = MuseNoiseFrame()
        while !reader.atEnd {
            let (field, wire) = try reader.key()
            switch field {
            case 1: try reader.expect(MuseProto.wireVarint, wire, "NoiseTransportFrame.chunk_id"); frame.chunkID = MuseProto.int64(try reader.varint())
            case 2: try reader.expect(MuseProto.wireVarint, wire, "NoiseTransportFrame.chunk_index"); frame.chunkIndex = try MuseProto.uint32(reader.varint())
            case 3: try reader.expect(MuseProto.wireVarint, wire, "NoiseTransportFrame.total_chunks"); frame.totalChunks = try MuseProto.uint32(reader.varint())
            case 4: try reader.expect(MuseProto.wireDelimited, wire, "NoiseTransportFrame.payload"); frame.payload = try reader.delimited()
            default: try reader.skip(wire)
            }
        }
        return frame
    }

    /// Splits `data` into frames sharing one random chunk ID.
    static func split(_ data: [UInt8], chunkID: Int64? = nil) throws -> [[UInt8]] {
        let id = chunkID ?? Int64.random(in: .min ... .max)
        let total = max(1, (data.count + maxChunkPayload - 1) / maxChunkPayload)
        guard total <= maxTotalChunks else { throw MuseNoiseError("payload too large for noise framing") }
        if data.isEmpty { return [MuseNoiseFrame(chunkID: id, chunkIndex: 0, totalChunks: 1, payload: []).encoded()] }
        return (0..<total).map { index in
            let start = index * maxChunkPayload
            let chunk = Array(data[start..<min(start + maxChunkPayload, data.count)])
            return MuseNoiseFrame(chunkID: id, chunkIndex: UInt32(index), totalChunks: UInt32(total), payload: chunk).encoded()
        }
    }
}

/// Puts chunked frames back together. Any malformed frame poisons it.
final class MuseNoiseFrameDecoder {
    private struct Assembly { var chunks: [UInt32: [UInt8]]; let total: UInt32; var bytes: Int; let created: Date }
    private var pending: [Int64: Assembly] = [:]
    private var poisoned = false
    private let clock: () -> Date

    init(clock: @escaping () -> Date = Date.init) { self.clock = clock }

    func decode(_ data: [UInt8]) throws -> [UInt8]? {
        guard !poisoned else { throw MuseNoiseError("NoiseFrameDecoder: poisoned after prior failure") }
        do {
            let frame = try MuseNoiseFrame.decode(data)
            guard frame.totalChunks >= 1, frame.totalChunks <= UInt32(MuseNoiseFrame.maxTotalChunks) else { throw MuseNoiseError("invalid totalChunks") }
            guard frame.chunkIndex < frame.totalChunks else { throw MuseNoiseError("chunkIndex out of range") }
            guard frame.payload.count <= MuseNoiseFrame.maxChunkPayload else { throw MuseNoiseError("payload too large for noise frame") }
            let now = clock()
            pending = pending.filter { now.timeIntervalSince($0.value.created) <= MuseNoiseFrame.assemblyTTL }
            var assembly = pending[frame.chunkID] ?? Assembly(chunks: [:], total: frame.totalChunks, bytes: 0, created: now)
            if pending[frame.chunkID] == nil, pending.count >= MuseNoiseFrame.maxPending { throw MuseNoiseError("too many pending noise frame assemblies") }
            guard assembly.total == frame.totalChunks else { throw MuseNoiseError("inconsistent totalChunks for chunkId") }
            guard assembly.chunks[frame.chunkIndex] == nil else { throw MuseNoiseError("duplicate chunkIndex") }
            assembly.bytes += frame.payload.count
            guard assembly.bytes <= MuseNoiseFrame.maxAssemblyBytes else { throw MuseNoiseError("assembly exceeded byte budget") }
            assembly.chunks[frame.chunkIndex] = frame.payload
            guard assembly.chunks.count == Int(assembly.total) else { pending[frame.chunkID] = assembly; return nil }
            pending[frame.chunkID] = nil
            return (0..<assembly.total).flatMap { assembly.chunks[$0] ?? [] }
        } catch {
            poisoned = true
            throw error
        }
    }
}

// MARK: The transport (transport.py)

/// One frame from the VM, after decryption and reassembly.
public struct MuseDecryptedFrame: Sendable {
    public enum Kind: Sendable { case response(MuseApplicationResponse), bodyChunk(MuseBodyChunk), reset(MuseReset) }
    public let streamID: Int64
    public let kind: Kind
}

/// Requests out on numbered streams, frames back in. Dead after any failure.
final class MuseNoiseTransport {
    private let send: MuseCipherState
    private let receive: MuseCipherState
    private let decoder = MuseNoiseFrameDecoder()
    private var nextStream: Int64 = 1
    private var dead = false

    init(send: MuseCipherState, receive: MuseCipherState) { self.send = send; self.receive = receive }

    private func alive() throws { if dead { throw MuseNoiseError("NoiseTransport: dead after prior failure") } }

    /// A whole request (its body ends here), or the start of a streamed one.
    func request(_ verb: String, _ path: String, body: [UInt8] = [], headers: [MuseHeader] = [], endBody: Bool = true) throws -> (stream: Int64, frames: [Data]) {
        try alive()
        do {
            let stream = nextStream
            nextStream += 1
            let frame = MuseServiceFrame(streamID: stream, value: .request(MuseApplicationRequest(verb: verb, path: path, headers: headers, body: body, endBody: endBody)))
            return (stream, try encrypt(frame))
        } catch { dead = true; throw error }
    }

    func bodyChunk(_ stream: Int64, _ data: [UInt8], endBody: Bool = false) throws -> [Data] {
        try alive()
        do { return try encrypt(MuseServiceFrame(streamID: stream, value: .bodyChunk(MuseBodyChunk(data: data, endBody: endBody)))) }
        catch { dead = true; throw error }
    }

    func decrypt(_ ciphertext: [UInt8]) throws -> MuseDecryptedFrame? {
        try alive()
        do {
            let plain = try receive.decrypt(ad: [], ciphertext)
            guard let assembled = try decoder.decode(plain) else { return nil }
            let payload = try MuseEnvelope.decodeResponsePayload(assembled)
            guard !payload.isEmpty else { throw MuseNoiseError("empty ServiceResponse payload") }
            let frame = try MuseEnvelope.decodeFrame(payload)
            switch frame.value {
            case .response(let response)?: return MuseDecryptedFrame(streamID: frame.streamID, kind: .response(response))
            case .bodyChunk(let chunk)?: return MuseDecryptedFrame(streamID: frame.streamID, kind: .bodyChunk(chunk))
            case .reset(let reset)?: return MuseDecryptedFrame(streamID: frame.streamID, kind: .reset(reset))
            case .request?: throw MuseNoiseError("NoiseTransport: unexpected request frame from server")
            case nil: return nil
            }
        } catch { dead = true; throw error }
    }

    private func encrypt(_ frame: MuseServiceFrame) throws -> [Data] {
        let envelope = MuseEnvelope.encodeRequestEnvelope(frame: frame)
        return try MuseNoiseFrame.split(envelope).map { Data(try send.encrypt(ad: [], $0)) }
    }
}
#endif
