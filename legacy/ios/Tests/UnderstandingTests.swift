import XCTest
@testable import KemoSabe

/// From the user's watch on September 24: "can you dream" came back spelled out
/// letter by letter, and "can you do your animation" came back as "ANIMATION".
final class UnderstandingTests: XCTestCase {
    private typealias Choice = ConversationRouting.Choice
    func testExactToolsRunOnlyWhenAskedFor() {
        let text = Choice(intent: .textTransformation, contextUse: .newRequest)
        XCTAssertEqual(ConversationRouting.guarded(text, message: "He Kyun Sabi can you dream").intent, .answer)
        XCTAssertEqual(ConversationRouting.guarded(text, message: "Can you do your animation").intent, .answer)
        XCTAssertEqual(ConversationRouting.guarded(text, message: "Spell necessary").intent, .textTransformation)
        XCTAssertEqual(ConversationRouting.guarded(text, message: "Say hello world in all caps").intent, .textTransformation)
        let math = Choice(intent: .calculation, contextUse: .newRequest)
        XCTAssertEqual(ConversationRouting.guarded(math, message: "What's 18% of 240").intent, .calculation)
        XCTAssertEqual(ConversationRouting.guarded(math, message: "How are you today").intent, .answer)
        let count = Choice(intent: .numericSequence, contextUse: .followUp)
        XCTAssertEqual(ConversationRouting.guarded(count, message: "Count from 5 to 10").intent, .numericSequence)
        XCTAssertEqual(ConversationRouting.guarded(count, message: "Tell me a story").intent, .answer)
        XCTAssertEqual(ConversationRouting.guarded(count, message: "Tell me a story").contextUse, .followUp)
        let draft = Choice(intent: .prepareDraft, contextUse: .newRequest)
        XCTAssertEqual(ConversationRouting.guarded(draft, message: "Draft a note to Sam").intent, .prepareDraft)
    }
    func testGreetingsDontHideACommand() {
        // "Hey, do your animation." came back as a count on device; it's a command.
        XCTAssertEqual(VoiceCommand.parse("Hey, do your animation."), VoiceCommand.parse("do your animation"))
        XCTAssertNotNil(VoiceCommand.parse("Hey, do your animation."))
        XCTAssertEqual(VoiceCommand.parse("Hey uh do your dance"), VoiceCommand.parse("do your dance"))
        XCTAssertNil(VoiceCommand.parse("Hey, uh, what is going on?"))
    }
    func testMisheardNamesAreDropped() {
        XCTAssertEqual(WakeName.stripped("He Kyun Sabi can you dream"), "Can you dream")
        XCTAssertEqual(WakeName.stripped("Hey KemoSabe, what's on today?"), "What's on today?")
        XCTAssertEqual(WakeName.stripped("Kimo Sabi dance"), "Dance")
        XCTAssertEqual(WakeName.stripped("Kemo, set a timer"), "Set a timer")
        XCTAssertEqual(WakeName.stripped("Can you dream"), "Can you dream")
        XCTAssertEqual(WakeName.stripped("Hey Kemo"), "Hey Kemo", "A name alone stays, so the reply can greet back")
        XCTAssertEqual(WakeName.stripped("Keep the salmon for dinner"), "Keep the salmon for dinner")
        XCTAssertEqual(WakeName.stripped("Kids say the funniest things"), "Kids say the funniest things")
    }
    func testLooserAnimationAndThemeRequests() {
        XCTAssertEqual(VoiceCommand.parse("Can you do your animation"), .perform(.dance))
        XCTAssertEqual(VoiceCommand.parse("Can you dance for me?"), .perform(.dance))
        XCTAssertEqual(VoiceCommand.parse("do a little dance"), .perform(.dance))
        XCTAssertEqual(VoiceCommand.parse("time to celebrate"), .perform(.done))
        XCTAssertEqual(VoiceCommand.parse("make it lavender"), .theme("lavender"))
        XCTAssertEqual(VoiceCommand.parse("can you go purple"), .theme("lavender"))
        XCTAssertEqual(VoiceCommand.parse("change your color to blue"), .theme("sky"))
        XCTAssertNil(VoiceCommand.parse("write a song about dancing"))
        XCTAssertNil(VoiceCommand.parse("why is the sky blue"))
        XCTAssertNil(VoiceCommand.parse("set an alarm for 7"))
        XCTAssertNil(VoiceCommand.parse("can you dream"))
        XCTAssertNil(VoiceCommand.parse("I like the matcha theme"))
        XCTAssertNil(VoiceCommand.parse("Don't dance"))
        XCTAssertTrue(VoiceCommand.perform(.dance).worksFromWatch)
        XCTAssertFalse(VoiceCommand.open(.settings).worksFromWatch)
    }
    func testWatchCaptureBecomesAReminderOrSomethingToRemember() {
        XCTAssertEqual(WatchCapture.request("Buy oat milk tomorrow"), "Add this as a reminder: Buy oat milk tomorrow")
        XCTAssertEqual(WatchCapture.request("call mom at 6"), "Add this as a reminder: call mom at 6")
        XCTAssertEqual(WatchCapture.request("Sam likes oolong tea"), "Remember this: Sam likes oolong tea")
    }
    func testKemoActsOutTheTask() {
        XCTAssertEqual(TaskActivity.performance(for: "Draft a caption for my trip photos"), .writing)
        XCTAssertEqual(TaskActivity.performance(for: "Remember that Sam likes oolong"), .filing)
        XCTAssertEqual(TaskActivity.performance(for: "Remind me to call mom"), .focus)
        XCTAssertEqual(TaskActivity.performance(for: "Plan my day tomorrow"), .calendarPlanning)
        XCTAssertEqual(TaskActivity.performance(for: "Why does my Swift function crash"), .coding)
        XCTAssertEqual(TaskActivity.performance(for: "What's 12*7"), .calculating)
        XCTAssertEqual(TaskActivity.performance(for: "Recommend a song for running"), .groove)
        XCTAssertEqual(TaskActivity.performance(for: "Can you dream"), .thinking)
        XCTAssertEqual(TaskActivity.label(for: "Draft an email to Sam"), "Writing…")
    }
}
