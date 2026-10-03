import XCTest
@testable import KemoSabe

final class ConversationSuggestionsTests: XCTestCase {
    private func archive(_ texts: [String]) -> ConversationArchive {
        .init(model: "Apple on-device", recipient: nil, messages: texts.enumerated().map { .init(role: $0.offset % 2 == 0 ? "You" : "KemoSabe", text: $0.element) })
    }
    private let tahoe = ["Help me plan a ski trip to Tahoe in January", "Here are lodging ideas near Palisades and Northstar", "Which Tahoe resorts have night skiing?"]
    private let dinner = ["What should I cook for dinner with salmon and rice?", "Try a teriyaki salmon bowl with rice and cucumber."]
    private let standup = ["Write my standup about the watch app release", "Yesterday: shipped the watch app build. Today: TestFlight upload."]

    func testSuggestsTheSavedConversationADraftBelongsWith() {
        let saved = [archive(tahoe), archive(dinner), archive(standup)]
        XCTAssertEqual(ConversationSuggestions.suggestion(for: "Are Tahoe lodging prices lower near Northstar?", current: [], saved: saved)?.id, saved[0].id)
        XCTAssertEqual(ConversationSuggestions.suggestion(for: "Could the salmon bowl use brown rice instead?", current: [], saved: saved)?.id, saved[1].id)
    }
    func testStaysQuietWhenTheDraftFitsHereOrMatchesNothing() {
        let saved = [archive(tahoe), archive(dinner)]
        XCTAssertNil(ConversationSuggestions.suggestion(for: "What time is it in Tokyo right now?", current: [], saved: saved))
        XCTAssertNil(ConversationSuggestions.suggestion(for: "Tahoe", current: [], saved: saved), "One word is not enough to move a conversation")
        let current = archive(["More Tahoe ski questions: lodging near Northstar"]).messages
        XCTAssertNil(ConversationSuggestions.suggestion(for: "Is Northstar lodging near the Tahoe lifts?", current: current, saved: saved))
        XCTAssertNil(ConversationSuggestions.suggestion(for: "Tahoe lodging near Northstar", current: [], saved: []))
    }
    func testTwoEquallyGoodMatchesAreNotSuggested() {
        let saved = [archive(tahoe), archive(tahoe)]
        XCTAssertNil(ConversationSuggestions.suggestion(for: "Tahoe lodging near Northstar", current: [], saved: saved))
    }
    func testWordsIgnoreCommonWordsAndPlurals() {
        XCTAssertEqual(ConversationSuggestions.words("What are the best Tahoe resorts for you?"), ["best", "tahoe", "resort"])
    }
}
