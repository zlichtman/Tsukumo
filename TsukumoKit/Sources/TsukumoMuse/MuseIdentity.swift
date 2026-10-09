#if os(macOS)
import Foundation
import Security

// Who this Mac is to Muse, and the secrets it keeps. Ported from Meta's Muse Gadget SDK (Apache-2.0),
// `identity.py` and `config.py`: a random, locally administered MAC-shaped value made once (never a real
// hardware address), the `homelink-xxxxxx` node id, and the BLE name `MuseGadget` plus the same six hex
// digits with no hyphen (the apps compare the two). The identity is a file in the app's own folder on this
// Mac (never iCloud); the SDK token and the device tokens are in this Mac's Keychain.
// Provenance: TsukumoKit/MUSE-NOTICE.md.

public struct MuseIdentity: Codable, Hashable, Sendable {
    public static let nodePrefix = "homelink-", bleNamePrefix = "MuseGadget"
    public let mac: String
    /// How it registers with Muse: `macos` first; the SDK's known `linux` if Muse refused that once.
    public var registration: MuseRegistration

    public init(mac: String, registration: MuseRegistration = .mac) { self.mac = mac; self.registration = registration }
    enum CodingKeys: String, CodingKey { case mac, registration }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mac = try container.decode(String.self, forKey: .mac)
        registration = (try? container.decodeIfPresent(MuseRegistration.self, forKey: .registration)) ?? .mac
    }

    public var suffix: String { String(mac.replacingOccurrences(of: ":", with: "").suffix(6)) }
    public var nodeID: String { Self.nodePrefix + suffix }
    /// The pairing id the apps expect (its `hatch-link:` prefix is the server's and stays as it is).
    public var deviceID: String { "hatch-link:" + mac }
    /// "MuseGadgetA1B2C3": no separator, as the apps compare it with the node id.
    public var bleName: String { Self.bleNamePrefix + suffix.uppercased() }

    static func isMAC(_ text: String) -> Bool {
        text.range(of: "^[0-9a-f]{2}(:[0-9a-f]{2}){5}$", options: .regularExpression) != nil
    }

    /// A unicast, locally administered MAC-shaped value.
    public static func generateMAC(random: () -> [UInt8] = { (0..<6).map { _ in UInt8.random(in: 0...255) } }) -> String {
        var octets = random()
        octets[0] = (octets[0] & 0xFC) | 0x02
        return octets.map { String(format: "%02x", $0) }.joined(separator: ":")
    }

    /// The saved identity, or a new one saved now. It survives unpairing.
    public static func loadOrCreate(file: URL, random: () -> [UInt8] = { (0..<6).map { _ in UInt8.random(in: 0...255) } }) -> MuseIdentity {
        if let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(MuseIdentity.self, from: data), isMAC(saved.mac) {
            return saved
        }
        let identity = MuseIdentity(mac: generateMAC(random: random))
        identity.save(file: file)
        return identity
    }

    public func save(file: URL) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: file, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
}

/// What `link.register` says this device is. Never family `link` (Muse pushes ESP32 firmware to those).
public enum MuseRegistration: String, Codable, Sendable {
    /// Tsukumo on a Mac.
    case mac
    /// The Linux SDK's own values, which Muse is known to accept; used only after Muse refused `mac`.
    case linuxCompatible

    public var platform: String { self == .mac ? "macos" : "linux" }
    public var deviceFamily: String { "homehub" }
    public var modelID: String { self == .mac ? "tsukumo-mac" : "linux" }
}

/// The owner's own SDK token from gadgets.muse.ai: `mgst_` and 43 base64url characters. Personal: it's
/// never built into Tsukumo; each owner pastes their own.
public enum MuseSDKToken {
    public static let settingsURL = URL(string: "https://gadgets.muse.ai/settings/sdk-tokens")!
    public static let termsURL = URL(string: "https://gadgets.muse.ai/sdk-terms")!
    public static func isValid(_ token: String) -> Bool {
        token.range(of: "^mgst_[A-Za-z0-9_-]{42}[AEIMQUYcgkosw048]$", options: .regularExpression) != nil
    }
}

/// The notice for the ported SDK, with the Apache-2.0 license text, bundled with the app.
public enum MuseNotice {
    public static var url: URL? { Bundle.module.url(forResource: "Muse-NOTICE", withExtension: "txt") }
}

/// What setup hands over: the device tokens and where to reach Muse. Kept in the Keychain as one item.
public struct MuseCredentials: Codable, Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String
    public var username: String
    public var apiURLv2: String
    public var noiseHost: String
    public var savedAt: Date

    public init(accessToken: String, refreshToken: String, username: String = "", apiURLv2: String = "", noiseHost: String = "", savedAt: Date = Date()) {
        self.accessToken = accessToken; self.refreshToken = refreshToken; self.username = username
        self.apiURLv2 = apiURLv2; self.noiseHost = noiseHost; self.savedAt = savedAt
    }
}

/// One counter for "the pairing as the owner last left it". Closing pairing, unpairing, removing the token,
/// or stopping moves it on, and every credential write and completion checks it under the same lock, so work
/// that started before (a provisioning in flight, a token refresh) can never bring a pairing back.
public final class MuseLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    public init() {}
    public var current: Int { lock.withLock { generation } }
    /// Moves on, then runs `body` (an unpair's delete) before any older work can write.
    @discardableResult
    public func advance(_ body: () -> Void = {}) -> Int {
        lock.withLock {
            generation += 1
            body()
            return generation
        }
    }
    /// Runs `body` only while `value` is still current, under the lock; false when it's stale.
    public func ifCurrent(_ value: Int, _ body: () -> Bool) -> Bool {
        lock.withLock { value == generation && body() }
    }
}

/// Where the SDK token and the device's credentials are kept.
public protocol MuseSecrets: Sendable {
    func sdkToken() -> String?
    func setSDKToken(_ token: String?) throws
    func credentials() -> MuseCredentials?
    func setCredentials(_ credentials: MuseCredentials?) throws
}

public struct MuseSecretsError: Error {}

/// This Mac's Keychain, this device only (never synced).
public struct KeychainMuseSecrets: MuseSecrets {
    public let service: String
    public init(service: String) { self.service = service }

    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    private func read(_ account: String) -> Data? {
        var query = query(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    private func write(_ data: Data?, _ account: String) throws {
        guard let data else {
            let status = SecItemDelete(query(account) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw MuseSecretsError() }
            return
        }
        let fields: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query(account) as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query(account).merging(fields) { _, new in new } as CFDictionary, nil) == errSecSuccess else { throw MuseSecretsError() }
        } else if status != errSecSuccess { throw MuseSecretsError() }
    }

    public func sdkToken() -> String? { read("sdk-token").flatMap { String(data: $0, encoding: .utf8) } }
    public func setSDKToken(_ token: String?) throws { try write(token.map { Data($0.utf8) }, "sdk-token") }
    public func credentials() -> MuseCredentials? { read("pairing").flatMap { try? JSONDecoder().decode(MuseCredentials.self, from: $0) } }
    public func setCredentials(_ credentials: MuseCredentials?) throws {
        try write(credentials.flatMap { try? JSONEncoder().encode($0) }, "pairing")
    }
}

/// Secrets in memory, for tests and `--ui-testing`.
public final class MemoryMuseSecrets: MuseSecrets, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    private var saved: MuseCredentials?
    public init(token: String? = nil, credentials: MuseCredentials? = nil) { self.token = token; saved = credentials }
    public func sdkToken() -> String? { lock.withLock { token } }
    public func setSDKToken(_ token: String?) throws { lock.withLock { self.token = token } }
    public func credentials() -> MuseCredentials? { lock.withLock { saved } }
    public func setCredentials(_ credentials: MuseCredentials?) throws { lock.withLock { saved = credentials } }
}
#endif
