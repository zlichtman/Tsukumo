import CryptoKit
import Foundation
import Security

// This Mac's key for the Tsukumo relay: ECDSA P-256, made in the Secure Enclave when this Mac has one (the private
// key never leaves it; the Keychain holds only the enclave's wrapped blob), otherwise in software. Either way it's
// kept in this Mac's Keychain, this device only, never synced. The relay keeps only the public key; the device
// proves the key on every connect by signing the relay's nonce.

/// Where the device key's blob is kept.
public protocol RelayKeyStore: Sendable {
    func load() -> Data?
    func save(_ data: Data?) throws
}

public struct RelayKeyError: Error, Equatable { public let reason: String }

/// This Mac's Keychain: a generic password, this device only (`AfterFirstUnlockThisDeviceOnly`, not synchronizable).
public struct KeychainRelayKeyStore: RelayKeyStore {
    public let service: String
    public let account = "relay-device-key"
    public init(service: String) { self.service = service }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecAttrSynchronizable as String: false]
    }
    public func load() -> Data? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
        return value as? Data
    }
    public func save(_ data: Data?) throws {
        guard let data else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw RelayKeyError(reason: "The Keychain refused to delete the key (\(status)).") }
            return
        }
        let fields: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, fields as CFDictionary)
        if status == errSecItemNotFound {
            let added = SecItemAdd(query.merging(fields) { _, new in new } as CFDictionary, nil)
            guard added == errSecSuccess else { throw RelayKeyError(reason: "The Keychain refused to keep the key (\(added)).") }
        } else if status != errSecSuccess { throw RelayKeyError(reason: "The Keychain refused to keep the key (\(status)).") }
    }
}

/// The key in memory, for tests and `--ui-testing`.
public final class MemoryRelayKeyStore: RelayKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    public init(_ data: Data? = nil) { self.data = data }
    public func load() -> Data? { lock.withLock { data } }
    public func save(_ data: Data?) throws { lock.withLock { self.data = data } }
}

/// The device key: which kind, its blob (the enclave's wrapped key, or the raw software key), and its public key.
public struct RelayDeviceKey: Sendable {
    public enum Kind: String, Codable, Sendable { case secureEnclave, software }
    public let kind: Kind
    let blob: Data
    /// The 65-byte uncompressed point the relay keeps (`x963Representation`).
    public let publicKey: Data

    private struct Stored: Codable { let kind: Kind; let blob: Data }

    /// The saved key, or a new one (saved before it's returned). The Secure Enclave is tried first when asked for.
    public static func loadOrCreate(store: any RelayKeyStore, secureEnclave: Bool) throws -> RelayDeviceKey {
        if let data = store.load(), let stored = try? JSONDecoder().decode(Stored.self, from: data), let key = try? RelayDeviceKey(kind: stored.kind, blob: stored.blob) {
            return key
        }
        let key = try make(secureEnclave: secureEnclave)
        try store.save(try JSONEncoder().encode(Stored(kind: key.kind, blob: key.blob)))
        return key
    }

    /// Forgets the key (after the registration is deleted).
    public static func delete(store: any RelayKeyStore) throws { try store.save(nil) }

    static func make(secureEnclave: Bool) throws -> RelayDeviceKey {
        if secureEnclave, SecureEnclave.isAvailable, let key = try? SecureEnclave.P256.Signing.PrivateKey() {
            return try RelayDeviceKey(kind: .secureEnclave, blob: key.dataRepresentation)
        }
        return try RelayDeviceKey(kind: .software, blob: P256.Signing.PrivateKey().rawRepresentation)
    }

    init(kind: Kind, blob: Data) throws {
        self.kind = kind; self.blob = blob
        switch kind {
        case .secureEnclave: publicKey = try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).publicKey.x963Representation
        case .software: publicKey = try P256.Signing.PrivateKey(rawRepresentation: blob).publicKey.x963Representation
        }
    }

    /// ECDSA P-256 with SHA-256 over `message`, as 64 raw bytes (r then s).
    public func sign(_ message: Data) throws -> Data {
        switch kind {
        case .secureEnclave: try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob).signature(for: message).rawRepresentation
        case .software: try P256.Signing.PrivateKey(rawRepresentation: blob).signature(for: message).rawRepresentation
        }
    }
}
