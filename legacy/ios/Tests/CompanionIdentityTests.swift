import XCTest
@testable import KemoSabe

final class CompanionIdentityTests: XCTestCase {
    private var saved: [String: Any?] = [:]
    private let keys = [CompanionIdentity.key, CompanionIdentity.namedKey, CompanionIdentity.personalityKey]
    override func setUp() { for key in keys { saved[key] = AccountDirectory.accountSettings.object(forKey: key); AccountDirectory.accountSettings.removeObject(forKey: key) } }
    override func tearDown() { for key in keys { AccountDirectory.accountSettings.set(saved[key] ?? nil, forKey: key) } }

    func testDefaultsToKemoSabeUntilNamed() {
        XCTAssertEqual(CompanionIdentity.name, "KemoSabe")
        XCTAssertTrue(CompanionIdentity.needsNaming)
        XCTAssertEqual(CompanionIdentity.intro, "You are KemoSabe.")
        CompanionIdentity.set("   ")
        XCTAssertEqual(CompanionIdentity.name, "KemoSabe", "A blank name keeps the default")
        XCTAssertFalse(CompanionIdentity.needsNaming)
    }
    func testNamesAreCleaned() {
        XCTAssertEqual(CompanionIdentity.clean("  Mochi\n  Bun "), "Mochi Bun")
        XCTAssertEqual(CompanionIdentity.clean("\"Pip\""), "Pip")
        XCTAssertEqual(CompanionIdentity.clean(String(repeating: "a", count: 40)).count, CompanionIdentity.maxLength)
    }
    func testChosenNameReachesInstructionsAndVoice() {
        CompanionIdentity.set("Mochi")
        CompanionIdentity.setPersonality(.direct)
        XCTAssertTrue(CompanionIdentity.intro.hasPrefix("You are Mochi, the person's KemoSabe companion."))
        XCTAssertTrue(CompanionIdentity.intro.hasSuffix(CompanionPersonality.direct.instruction))
        XCTAssertTrue(ConversationPrompt.instructions.hasPrefix("You are Mochi"))
        XCTAssertTrue(VoiceTurnPolicy.containsName("hey mochi what's next"))
        XCTAssertTrue(VoiceTurnPolicy.containsName("KemoSabe still works"))
        XCTAssertTrue(VoiceController.isNameOnly("Hey Mochi"))
        XCTAssertEqual(WakeName.stripped("Hey Mochi, what's the weather"), "What's the weather")
        XCTAssertEqual(WakeName.stripped("Mochis are tasty"), "Mochis are tasty")
    }
    func testCharactersUpsertNewestFirst() {
        let a = CompanionCharacter(name: "Pip", theme: BotTheme.presets[1], personality: nil)
        var b = CompanionCharacter(name: "Nova", theme: BotTheme.presets[2], personality: .calm)
        var list = CompanionCharacters.upsert(a, into: [])
        list = CompanionCharacters.upsert(b, into: list)
        XCTAssertEqual(list.map(\.name), ["Nova", "Pip"])
        b.name = "Nova II"
        list = CompanionCharacters.upsert(b, into: list)
        XCTAssertEqual(list.map(\.name), ["Nova II", "Pip"])
    }
}
