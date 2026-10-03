import XCTest
@testable import KemoSabe

final class CompanionIntroTests: XCTestCase {
    func testReadsNamesFromNaturalReplies() {
        XCTAssertEqual(CompanionIntro.name(from: "Mochi"), "Mochi")
        XCTAssertEqual(CompanionIntro.name(from: "call you mochi!"), "Mochi")
        XCTAssertEqual(CompanionIntro.name(from: "I'll call you Pip."), "Pip")
        XCTAssertEqual(CompanionIntro.name(from: "how about sir fluff"), "Sir Fluff")
        XCTAssertEqual(CompanionIntro.name(from: "your name is DJ Kemo"), "DJ Kemo")
        XCTAssertEqual(CompanionIntro.name(from: "keep KemoSabe"), "KemoSabe")
        XCTAssertEqual(CompanionIntro.name(from: "that's fine"), "KemoSabe")
        XCTAssertNil(CompanionIntro.name(from: "what is the weather going to be like tomorrow"), "A question isn't a name")
        XCTAssertNil(CompanionIntro.name(from: "🙂🙂"))
    }
    func testReadsLooks() {
        XCTAssertEqual(CompanionIntro.look(from: "keep this look"), .keep)
        XCTAssertEqual(CompanionIntro.look(from: "Lavender"), .theme(BotTheme.presets.first { $0.id == "lavender" }!))
        XCTAssertEqual(CompanionIntro.look(from: "make it blue"), .theme(BotTheme.presets.first { $0.id == "sky" }!))
        XCTAssertEqual(CompanionIntro.look(from: "surprise me with something"), .unclear)
    }
    func testReadsPersonalities() {
        XCTAssertEqual(CompanionIntro.personality(from: "Playful"), .personality(.playful))
        XCTAssertEqual(CompanionIntro.personality(from: "be chill"), .personality(.calm))
        XCTAssertEqual(CompanionIntro.personality(from: "skip"), .skip)
        XCTAssertEqual(CompanionIntro.personality(from: "hmm not sure"), .unclear)
    }
}
