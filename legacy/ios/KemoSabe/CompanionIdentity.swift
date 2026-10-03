import Foundation
import SwiftUI

/// The companion's name. KemoSabe is the default; the person picks their own the
/// first time they open the app and can change it in Character settings. Every
/// surface reads it from here: chat labels, spoken captions, model instructions,
/// the wake word, the Mac companion, and the watch.
enum CompanionIdentity {
    static let key = "kemo.companion.name"
    static let namedKey = "kemo.companion.named"
    static let defaultName = "KemoSabe"
    static let maxLength = 24
    static let suggestions = ["KemoSabe", "Mochi", "Sunny", "Pip", "Nova", "Biscuit", "Juniper"]

    nonisolated static var name: String { clean(AccountDirectory.accountSettings.string(forKey: key)) }
    /// True until the person has chosen a name (or kept the default) once.
    nonisolated static var needsNaming: Bool { !AccountDirectory.accountSettings.bool(forKey: namedKey) }

    nonisolated static func clean(_ value: String?) -> String {
        let collapsed = (value ?? "").split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = String(collapsed.filter { !$0.isNewline && $0 != "\"" }.prefix(maxLength)).trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? defaultName : trimmed
    }
    nonisolated static func set(_ value: String, defaults: UserDefaults = AccountDirectory.accountSettings) {
        defaults.set(clean(value), forKey: key)
        defaults.set(true, forKey: namedKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// Posted when the name or personality changes, so the account can carry it to other devices.
    static let changed = Notification.Name("KemoCompanionIdentityChanged")
    static let personalityKey = "kemo.companion.personality"
    nonisolated static var personality: CompanionPersonality? {
        AccountDirectory.accountSettings.string(forKey: personalityKey).flatMap(CompanionPersonality.init(rawValue:))
    }
    nonisolated static func setPersonality(_ value: CompanionPersonality?, defaults: UserDefaults = AccountDirectory.accountSettings) {
        defaults.set(value?.rawValue, forKey: personalityKey)
        NotificationCenter.default.post(name: changed, object: nil)
    }
    /// Opens the model instructions: the chosen name, what it is, and its personality.
    nonisolated static var intro: String {
        let name = name
        let identity = name == defaultName ? "You are KemoSabe." : "You are \(name), the person's KemoSabe companion. Your name is \(name)."
        guard let personality else { return identity }
        return identity + " " + personality.instruction
    }
    /// Lowercased words someone might say to address the companion, besides KemoSabe itself.
    nonisolated static var spokenName: String? {
        let name = name.lowercased()
        guard name != defaultName.lowercased(), name.count >= 2 else { return nil }
        return name
    }
}

/// A tone for the companion's replies. It shapes wording only; it never changes
/// what the companion may do or know.
enum CompanionPersonality: String, CaseIterable, Codable, Identifiable {
    case warm, playful, calm, direct
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var detail: String {
        switch self {
        case .warm: "Kind and encouraging, never gushing."
        case .playful: "A little humor when it fits."
        case .calm: "Steady and unhurried."
        case .direct: "Brief and to the point."
        }
    }
    var symbol: String {
        switch self {
        case .warm: "sun.max"
        case .playful: "face.smiling"
        case .calm: "leaf"
        case .direct: "arrow.right"
        }
    }
    var instruction: String {
        switch self {
        case .warm: "Your personality is warm: kind and encouraging without gushing."
        case .playful: "Your personality is playful: a little light humor when it fits, never at the cost of the answer."
        case .calm: "Your personality is calm: steady and unhurried, reassuring through clarity."
        case .direct: "Your personality is direct: brief and to the point."
        }
    }
}

/// A saved companion: a name, a look, and a personality. Switching characters
/// changes all three at once; conversations, memories, and permissions stay put.
struct CompanionCharacter: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var theme: BotTheme
    var personality: CompanionPersonality?
}

enum CompanionCharacters {
    static let key = "kemo.companion.characters"
    static let limit = 12
    static func load(_ defaults: UserDefaults = AccountDirectory.accountSettings) -> [CompanionCharacter] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([CompanionCharacter].self, from: data)) ?? []
    }
    static func save(_ list: [CompanionCharacter], _ defaults: UserDefaults = AccountDirectory.accountSettings) {
        defaults.set(try? JSONEncoder().encode(Array(list.prefix(limit))), forKey: key)
    }
    /// Adds or replaces a character, newest first.
    static func upsert(_ character: CompanionCharacter, into list: [CompanionCharacter]) -> [CompanionCharacter] {
        [character] + list.filter { $0.id != character.id }
    }
}

enum CompanionCharacterSwitch {
    @MainActor static func apply(_ character: CompanionCharacter, store: AppStore) {
        CompanionIdentity.set(character.name)
        CompanionIdentity.setPersonality(character.personality)
        store.state.theme = character.theme
        store.save()
    }
    static func isActive(_ character: CompanionCharacter, theme: BotTheme) -> Bool {
        character.name == CompanionIdentity.name && character.theme.id == theme.id && character.personality == CompanionIdentity.personality
    }
}
