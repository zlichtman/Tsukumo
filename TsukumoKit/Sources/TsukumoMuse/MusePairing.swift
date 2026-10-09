#if os(macOS)
import CryptoKit
import Foundation

// The device's side of Muse Gadget BLE pairing, protocol version 5, with CryptoKit.
// Ported from Meta's Muse Gadget SDK (Apache-2.0), `linux/src/musegadget/pairing.py` and
// `ble_framing.py`. Community mode only: `pairing_auth` "none", epoch 0, policy `confirm_app`, so the
// Muse app's own confirmation stands in for a button. The transcript, key schedule, and records match
// the SDK's published vectors (`tests/vectors/link_pairing_v5.json`). Community pairing keeps setup
// secrets from passive listeners; it doesn't authenticate the phone, so it can't stop an active
// man-in-the-middle. Provenance: TsukumoKit/MUSE-NOTICE.md.

public enum MusePairingError: Error, Equatable {
    /// The wire status to report ("error_pairing_invalid_hello", "error_pairing_decrypt").
    case status(String)
}

public enum MusePairing {
    public static let version = 5
    /// The pairing model the apps expect (the server's name for a Muse Link; it stays as it is).
    public static let model = "hatch_link"
    public static let suite = "p256-hkdf-sha256-aes-gcm-v1"
    public static let policyButton = "confirm_press", policyApp = "confirm_app"
    public static let authOfficial = "fleet_ecdsa_p256_v1", authCommunity = "none"
    static let buttonConfirmTimeout = 60
    static let recordLabel = "hatch-link ble setup v1"
    static let sessionIDLabel = Array("hatch-link session id v1".utf8)
    static let clientFinishedTimeout: TimeInterval = 60, confirmedTimeout: TimeInterval = 120, provisioningTimeout: TimeInterval = 120
    public static let invalidHello = "error_pairing_invalid_hello", decryptFailed = "error_pairing_decrypt"
    static let pointBytes = 65, nonceBytes = 16, sessionIDBytes = 16, tagBytes = 16
    public static let maxB64 = 4096, maxCiphertextB64 = 16384

    // MARK: base64url without padding

    public static func b64url(_ data: [UInt8]) -> String {
        Data(data).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    /// Decodes unpadded base64url, refusing what the firmware refuses.
    public static func unb64url(_ text: String?, maxCharacters: Int = maxB64) throws -> [UInt8] {
        guard let text, !text.isEmpty, text.count <= maxCharacters, text.count % 4 != 1,
              text.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_").contains($0) })
        else { throw MusePairingError.status(invalidHello) }
        let standard = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        guard let data = Data(base64Encoded: standard + String(repeating: "=", count: (4 - standard.count % 4) % 4)) else {
            throw MusePairingError.status(invalidHello)
        }
        return Array(data)
    }

    static func counter(_ text: String?) -> UInt64? {
        guard let text, !text.isEmpty, text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return UInt64(text)
    }

    // MARK: The transcript and key schedule

    /// The canonical v5 transcript; its SHA-256 is `transcript_hash`.
    public static func transcript(community: Bool, authEpoch: Int, policy: String, deviceID: String, nodeID: String, mac: String,
                                  firmwareVersion: String, mobilePub: String, devicePub: String, mobileNonce: String,
                                  deviceNonce: String) throws -> String {
        let button = policy == policyButton
        guard button || (community && policy == policyApp) else { throw MusePairingError.status(invalidHello) }
        guard community ? authEpoch == 0 : authEpoch > 0 else { throw MusePairingError.status(invalidHello) }
        let fields = [deviceID, nodeID, mac, firmwareVersion, mobilePub, devicePub, mobileNonce, deviceNonce]
        guard fields.allSatisfy({ !$0.isEmpty }) else { throw MusePairingError.status(invalidHello) }
        return [
            "hatch-link-pairing-v\(version)",
            "version=\(version)",
            "initiator_role=mobile",
            "responder_role=link",
            "device_id=\(deviceID)",
            "node_id=\(nodeID)",
            "mac=\(mac)",
            "model=\(model)",
            "firmware_version=\(firmwareVersion)",
            "selected_cipher_suite=\(suite)",
            "pairing_auth=\(community ? authCommunity : authOfficial)",
            "pairing_auth_epoch=\(authEpoch)",
            "pairing_policy=\(policy)",
            "confirm_timeout_seconds=\(button ? buttonConfirmTimeout : 0)",
            "mobile_pub=\(mobilePub)",
            "device_pub=\(devicePub)",
            "mobile_nonce=\(mobileNonce)",
            "device_nonce=\(deviceNonce)",
        ].joined(separator: "\n")
    }

    /// `(mobileTx, mobileRx, sessionID)`: the device decrypts with `mobileTx` and encrypts with `mobileRx`.
    public static func sessionKeys(ecdh: [UInt8], mobileNonce: [UInt8], deviceNonce: [UInt8], transcriptHash: [UInt8])
        -> (mobileTx: [UInt8], mobileRx: [UInt8], sessionID: [UInt8], sessionSecret: [UInt8]) {
        let salt = Array(SHA256.hash(data: mobileNonce + deviceNonce + transcriptHash))
        let secret = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: ecdh), salt: salt,
                                            info: Array(recordLabel.utf8), outputByteCount: 32)
        let secretBytes = secret.withUnsafeBytes { Array($0) }
        let tx = HKDF<SHA256>.expand(pseudoRandomKey: secret, info: Array("mobile->device".utf8), outputByteCount: 32).withUnsafeBytes { Array($0) }
        let rx = HKDF<SHA256>.expand(pseudoRandomKey: secret, info: Array("device->mobile".utf8), outputByteCount: 32).withUnsafeBytes { Array($0) }
        let sessionID = Array(SHA256.hash(data: sessionIDLabel + transcriptHash + ecdh).prefix(sessionIDBytes))
        return (tx, rx, sessionID, secretBytes)
    }

    /// Six digits from HKDF-SHA256 over the transcript hash.
    public static func verificationCode(transcriptHash: [UInt8]) -> String {
        let bytes = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: transcriptHash), salt: [UInt8](),
                                           info: Array("tsukumo muse pairing code v1".utf8), outputByteCount: 4).withUnsafeBytes { Array($0) }
        let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) } % 1_000_000
        return String(format: "%06u", value)
    }

    static func recordNonce(direction: UInt8, counter: UInt64) -> [UInt8] {
        [direction, 0, 0, 0] + withUnsafeBytes(of: counter.bigEndian) { Array($0) }
    }
    static func recordAAD(sessionID: String, direction: UInt8, counter: UInt64) -> [UInt8] {
        Array("\(recordLabel)|\(sessionID)|\(direction == 0 ? "m2d" : "d2m")|\(counter)".utf8)
    }

    /// One compact JSON object, as the SDK writes it.
    static func compact(_ object: [String: JSONLike]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object.mapValues(\.any), options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}

/// The few JSON values pairing writes, kept `Sendable`.
public enum JSONLike: Sendable, Equatable {
    case string(String), int(Int), bool(Bool)
    var any: Any {
        switch self {
        case .string(let value): value
        case .int(let value): value
        case .bool(let value): value
        }
    }
}

/// One device's pairing state, safe from any thread. Methods that move the handshake on return a
/// nonzero generation; work started for an older generation checks `isCurrent` before acting.
public final class MusePairingSession: @unchecked Sendable {
    public enum State: String, Sendable { case idle, waitClientFinished, ready, provisioning }

    let nodeID: String, deviceID: String, mac: String, firmwareVersion: String
    /// The owner's SDK token, sent to the Muse app inside the encrypted `pairing_confirmed` status.
    let sdkToken: String?
    private let clock: @Sendable () -> TimeInterval
    private let makeKey: @Sendable () -> P256.KeyAgreement.PrivateKey
    private let randomBytes: @Sendable (Int) -> [UInt8]
    private let lock = NSLock()

    private var generation = 0
    private var state = State.idle
    private var deadline: TimeInterval = 0
    private var rxKey: SymmetricKey?
    private var txKey: SymmetricKey?
    private var sessionID = ""
    private var transcriptHash: [UInt8] = []
    /// The owner allowed this session (this session ID) on the Mac. Any reset or new hello clears it.
    private var ownerApproved = false
    private var rxCounter: UInt64 = 0
    private var txCounter: UInt64 = 0

    public init(nodeID: String, deviceID: String, mac: String, firmwareVersion: String, sdkToken: String? = nil,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                makeKey: @escaping @Sendable () -> P256.KeyAgreement.PrivateKey = { P256.KeyAgreement.PrivateKey() },
                randomBytes: @escaping @Sendable (Int) -> [UInt8] = { count in (0..<count).map { _ in UInt8.random(in: 0...255) } }) {
        self.nodeID = nodeID; self.deviceID = deviceID; self.mac = mac
        self.firmwareVersion = firmwareVersion.isEmpty ? "unknown" : firmwareVersion
        self.sdkToken = sdkToken; self.clock = clock; self.makeKey = makeKey; self.randomBytes = randomBytes
        lock.withLock { resetLocked() }
    }

    /// The pairing fields of `get_device_info`.
    public var deviceInfo: [String: JSONLike] {
        ["device_id": .string(deviceID), "mac": .string(mac), "model": .string(MusePairing.model),
         "pairing_protocol": .int(MusePairing.version), "pairing_auth": .string(MusePairing.authCommunity),
         "pairing_auth_epoch": .int(0), "pairing_policy": .string(MusePairing.policyApp)]
    }

    /// Six digits for the owner, from this session's transcript (nil without a session). The Muse app doesn't
    /// show a matching code, so it can't prove which phone this is; it names this attempt on the Mac.
    public var verificationCode: String? {
        lock.withLock { transcriptHash.isEmpty ? nil : MusePairing.verificationCode(transcriptHash: transcriptHash) }
    }

    /// This session's ID (base64url), empty without one.
    public var currentSessionID: String { lock.withLock { sessionID } }

    /// Records the owner's Allow for exactly this session: only while it's still the confirmed session the owner
    /// was shown (the same generation and session ID), atomically with that check. False when it was replaced.
    public func approve(generation value: Int, sessionID expected: String) -> Bool {
        lock.withLock {
            guard !expireLocked(), state == .ready, value == generation, !expected.isEmpty, expected == sessionID else { return false }
            ownerApproved = true
            return true
        }
    }

    /// Confirmed by the phone and allowed by the owner, for the current session.
    public var ownerConfirmed: Bool {
        lock.withLock { _ = expireLocked(); return ownerApproved && (state == .ready || state == .provisioning) }
    }

    public var currentState: State { lock.withLock { _ = expireLocked(); return state } }
    public var confirmed: Bool { [.ready, .provisioning].contains(currentState) }
    public func isCurrent(_ value: Int) -> Bool { lock.withLock { value != 0 && value == generation } }
    public func reset() { lock.withLock { resetLocked() } }

    /// Starts a session from `pairing_client_hello`; returns `pairing_ready`.
    public func handleHello(_ message: [String: Any]) throws -> [String: JSONLike] {
        guard let version = message["version"] as? NSNumber, CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == Double(MusePairing.version),
              message["pairing_auth"] as? String == MusePairing.authCommunity, message["pairing_policy"] as? String == MusePairing.policyApp
        else { throw MusePairingError.status(MusePairing.invalidHello) }
        return try lock.withLock {
            resetLocked()
            let mobilePub: [UInt8], mobileNonce: [UInt8], peer: P256.KeyAgreement.PublicKey
            do {
                mobilePub = try MusePairing.unb64url(message["mobile_pub"] as? String)
                mobileNonce = try MusePairing.unb64url(message["mobile_nonce"] as? String)
                guard mobilePub.count == MusePairing.pointBytes, mobilePub[0] == 0x04, mobileNonce.count == MusePairing.nonceBytes else {
                    throw MusePairingError.status(MusePairing.invalidHello)
                }
                peer = try P256.KeyAgreement.PublicKey(x963Representation: mobilePub)
            } catch {
                resetLocked()
                throw MusePairingError.status(MusePairing.invalidHello)
            }
            let key = makeKey()
            let devicePub = Array(key.publicKey.x963Representation)
            let deviceNonce = randomBytes(MusePairing.nonceBytes)
            let transcript = try MusePairing.transcript(
                community: true, authEpoch: 0, policy: MusePairing.policyApp, deviceID: deviceID, nodeID: nodeID, mac: mac,
                firmwareVersion: firmwareVersion, mobilePub: MusePairing.b64url(mobilePub), devicePub: MusePairing.b64url(devicePub),
                mobileNonce: MusePairing.b64url(mobileNonce), deviceNonce: MusePairing.b64url(deviceNonce))
            let transcriptHash = Array(SHA256.hash(data: Array(transcript.utf8)))
            guard let ecdh = try? key.sharedSecretFromKeyAgreement(with: peer).withUnsafeBytes({ Array($0) }) else {
                resetLocked()
                throw MusePairingError.status(MusePairing.invalidHello)
            }
            let keys = MusePairing.sessionKeys(ecdh: ecdh, mobileNonce: mobileNonce, deviceNonce: deviceNonce, transcriptHash: transcriptHash)
            rxKey = SymmetricKey(data: keys.mobileTx)
            txKey = SymmetricKey(data: keys.mobileRx)
            sessionID = MusePairing.b64url(keys.sessionID)
            self.transcriptHash = transcriptHash
            rxCounter = 0; txCounter = 0
            state = .waitClientFinished
            deadline = clock() + MusePairing.clientFinishedTimeout
            return ["type": .string("pairing_ready"), "version": .int(MusePairing.version), "device_id": .string(deviceID),
                    "node_id": .string(nodeID), "mac": .string(mac), "model": .string(MusePairing.model),
                    "firmware_version": .string(firmwareVersion), "pairing_auth": .string(MusePairing.authCommunity),
                    "pairing_auth_epoch": .int(0), "pairing_policy": .string(MusePairing.policyApp),
                    "device_pub": .string(MusePairing.b64url(devicePub)), "device_nonce": .string(MusePairing.b64url(deviceNonce)),
                    "transcript_hash": .string(MusePairing.b64url(transcriptHash)), "session_id": .string(sessionID)]
        }
    }

    /// Opens one phone-to-device `pairing_encrypted` record. Any failure clears the session.
    public func decrypt(_ envelope: [String: Any]) throws -> String {
        try lock.withLock {
            if expireLocked() || state == .idle { resetLocked(); throw MusePairingError.status(MusePairing.decryptFailed) }
            do {
                guard envelope["session_id"] as? String == sessionID, let counter = MusePairing.counter(envelope["counter"] as? String),
                      counter == rxCounter, let rxKey else { throw MusePairingError.status(MusePairing.decryptFailed) }
                let ciphertext = try MusePairing.unb64url(envelope["ciphertext"] as? String, maxCharacters: MusePairing.maxCiphertextB64)
                let tag = try MusePairing.unb64url(envelope["tag"] as? String)
                guard tag.count == MusePairing.tagBytes else { throw MusePairingError.status(MusePairing.decryptFailed) }
                let box = try AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: MusePairing.recordNonce(direction: 0, counter: counter)),
                                                ciphertext: ciphertext, tag: tag)
                let plain = try AES.GCM.open(box, using: rxKey, authenticating: MusePairing.recordAAD(sessionID: sessionID, direction: 0, counter: counter))
                guard let text = String(data: plain, encoding: .utf8) else { throw MusePairingError.status(MusePairing.decryptFailed) }
                rxCounter += 1
                return text
            } catch {
                resetLocked()
                throw MusePairingError.status(MusePairing.decryptFailed)
            }
        }
    }

    /// Confirms the session after its first record, which must be exactly `{"action": "pairing_client_finished"}`.
    /// Under `confirm_app` the Muse app already asked the person. Returns the new generation, or 0.
    public func handleClientFinished(_ command: [String: Any]) -> Int {
        lock.withLock {
            let ok = command.count == 1 && command["action"] as? String == "pairing_client_finished"
                && !expireLocked() && state == .waitClientFinished && rxCounter == 1
            guard ok else { resetLocked(); return 0 }
            generation += 1
            state = .ready
            deadline = clock() + MusePairing.confirmedTimeout
            return generation
        }
    }

    public func markProvisioning() -> Int {
        lock.withLock {
            if !expireLocked(), state == .ready, ownerApproved {
                generation += 1
                state = .provisioning
                deadline = clock() + MusePairing.provisioningTimeout
            }
            return state == .provisioning ? generation : 0
        }
    }
    public func extendProvisioning(_ value: Int) -> Bool {
        lock.withLock {
            guard provisioningLocked(value) else { return false }
            deadline = clock() + MusePairing.provisioningTimeout
            return true
        }
    }
    /// Runs `commit` (local saving only) while the session is still the one that started it.
    public func commitProvisioning(_ value: Int, _ commit: () -> Bool) -> Bool {
        lock.withLock { provisioningLocked(value) && commit() }
    }

    /// Seals a device-to-phone record; nil without a session, or for a stale generation.
    public func encrypt(_ plaintext: String, generation value: Int = 0) -> [String: JSONLike]? {
        lock.withLock {
            if (value != 0 && value != generation) || expireLocked() || state == .idle { return nil }
            guard let txKey else { return nil }
            let counter = txCounter
            guard let box = try? AES.GCM.seal(Array(plaintext.utf8), using: txKey,
                                              nonce: AES.GCM.Nonce(data: MusePairing.recordNonce(direction: 1, counter: counter)),
                                              authenticating: MusePairing.recordAAD(sessionID: sessionID, direction: 1, counter: counter))
            else { return nil }
            txCounter += 1
            return ["type": .string("pairing_encrypted"), "session_id": .string(sessionID), "counter": .string(String(counter)),
                    "ciphertext": .string(MusePairing.b64url(Array(box.ciphertext))), "tag": .string(MusePairing.b64url(Array(box.tag)))]
        }
    }

    /// A status record; `pairing_confirmed` carries the owner's SDK token (apps read only type and status).
    public func encryptStatus(_ status: String, generation value: Int = 0) -> [String: JSONLike]? {
        var message: [String: JSONLike] = ["type": .string("status"), "status": .string(status)]
        if let sdkToken, status == "pairing_confirmed" { message["sdk_token"] = .string(sdkToken) }
        return encrypt(MusePairing.compact(message), generation: value)
    }

    private func provisioningLocked(_ value: Int) -> Bool {
        value != 0 && value == generation && !expireLocked() && state == .provisioning
    }
    private func resetLocked() {
        generation += 1
        clearLocked()
    }
    private func clearLocked() {
        state = .idle; deadline = 0; rxKey = nil; txKey = nil; sessionID = ""; transcriptHash = []; ownerApproved = false
        rxCounter = 0; txCounter = 0
    }
    /// Drops the keys of an expired session but keeps its generation, so its owner can still tell.
    private func expireLocked() -> Bool {
        guard state != .idle, clock() > deadline else { return false }
        clearLocked()
        return true
    }
}

// MARK: BLE framing (ble_framing.py)

/// Messages bigger than one BLE packet: `0xFE`, index, total, then a piece. A packet that doesn't start
/// with `0xFE` is a whole message.
public enum MuseBLEFraming {
    public static let magic: UInt8 = 0xFE
    public static let headerBytes = 3, maxPacketBytes = 160, maxChunks = 255, maxMessageBytes = 8192, defaultMTU = 23
    /// The pause between notifications of one message.
    public static let stagger: Duration = .milliseconds(50)

    /// Packets that each fit one notification at `mtu`.
    public static func chunks(_ data: [UInt8], mtu: Int = defaultMTU) throws -> [[UInt8]] {
        let notifyMax = min(mtu > 3 ? mtu - 3 : 20, maxPacketBytes)
        let usable = notifyMax - headerBytes
        var pieces = stride(from: 0, to: data.count, by: usable).map { Array(data[$0..<min($0 + usable, data.count)]) }
        if pieces.isEmpty { pieces = [[]] }
        guard pieces.count <= maxChunks else { throw MuseNoiseError("message needs \(pieces.count) chunks (max \(maxChunks))") }
        return pieces.enumerated().map { [magic, UInt8($0.offset), UInt8(pieces.count)] + $0.element }
    }
}

/// Reassembles chunked writes strictly in order; anything out of order or oversize is dropped.
public struct MuseChunkAssembler: Sendable {
    private var buffer: [UInt8] = []
    private var total = 0, next = 0
    private let maxBytes: Int
    public init(maxBytes: Int = MuseBLEFraming.maxMessageBytes) { self.maxBytes = maxBytes }

    public mutating func reset() { buffer = []; total = 0; next = 0 }

    /// One write; a whole message once one is ready.
    public mutating func feed(_ packet: [UInt8]) -> [UInt8]? {
        guard packet.count >= MuseBLEFraming.headerBytes, packet[0] == MuseBLEFraming.magic else { return packet }
        let index = Int(packet[1]), count = Int(packet[2]), piece = packet[MuseBLEFraming.headerBytes...]
        if count == 0 { reset(); return nil }
        if index == 0 || count != total { reset(); total = count }
        if index != next || index >= total { reset(); return nil }
        if buffer.count + piece.count > maxBytes { reset(); return nil }
        buffer += piece
        next = index + 1
        guard next >= total else { return nil }
        let message = buffer
        reset()
        return message
    }
}
#endif
