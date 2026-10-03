import Foundation
import Security

/// Kemo's meters and name, copied where the watch face complication can read them.
///
/// The watch app keeps its own copy in UserDefaults. A widget extension can't read another
/// process's defaults, and an App Group would need a group identifier created once in the
/// developer portal (the same blocker as the iCloud container; the App Store Connect API key
/// can't create it). So the copy lives in a keychain group shared by the watch app and its
/// widget (`keychain-access-groups` in both targets' entitlements, the first and only group,
/// so it is the default one), which needs no portal setup. It is this-device-only and holds
/// only pet state: two meters, two dates, and the companion's name. No keys, no conversation.
enum KemoVitalsMirror {
    struct Snapshot: Codable, Equatable, Sendable {
        var vitals: KemoVitals
        /// The companion's name as the iPhone last published it, for the complication.
        var name: String
    }
    private static let service = "com.zlichtman.kemosabe.watch.vitals"
    private static let account = "kemo"

    static func read() -> Snapshot? {
        var query = base
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: data)
    }
    static func write(_ snapshot: Snapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let update: [String: Any] = [kSecValueData as String: data]
        if SecItemUpdate(base as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var item = base
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(item as CFDictionary, nil)
        }
    }
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: false]
    }
}
