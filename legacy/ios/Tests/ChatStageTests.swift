import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Kemo in a chat (the owner's request, September 27, 2026): a profile picture beside each reply,
/// and, while the chat has room, the big Kemo up on the stage acting out what it's doing. Where Kemo
/// is comes from `ChatStage`, a pure function of the transcript's content height, its viewport, the
/// scroll position, and the chat's state.
final class ChatStageTests: XCTestCase {
    /// A 700 pt chat with a 250 pt stage: while the stage is shown the transcript sees 450 pt.
    private let stage: CGFloat = 250
    private func metrics(content: CGFloat, viewport: CGFloat, top: CGFloat = 0) -> ChatStage.Metrics {
        .init(contentHeight: content, viewportHeight: viewport, distanceFromTop: top)
    }
    private func decide(_ m: ChatStage.Metrics, shown: Bool, allowed: Bool = true, voiceMode: Bool = false, pinned: Bool = false) -> Bool {
        ChatStage.stageShown(m, stageHeight: stage, shown: shown, allowed: allowed, voiceMode: voiceMode, pinned: pinned)
    }

    func testANewChatStartsWithKemoOnTheStage() {
        // Before anything is measured, and with the empty state's greeting, Kemo is up on the stage.
        XCTAssertTrue(decide(.init(), shown: true))
        XCTAssertTrue(decide(metrics(content: 320, viewport: 450), shown: true))
        // On a small screen the greeting may not fit under the stage; a new chat still starts with Kemo up.
        XCTAssertTrue(ChatStage.stageShown(metrics(content: 400, viewport: 360, top: 12), stageHeight: stage, shown: true, allowed: true, empty: true))
        XCTAssertTrue(ChatStage.stageShown(metrics(content: 400, viewport: 600), stageHeight: stage, shown: false, allowed: true, empty: true))
        XCTAssertFalse(ChatStage.stageShown(.init(), stageHeight: stage, shown: true, allowed: false, empty: true), "Unless the person hid it")
        XCTAssertEqual(ChatStage.performance(live: "idle", conversationEmpty: true), "greeting", "A new chat opens with a greeting")
        XCTAssertEqual(ChatStage.performance(live: "idle", conversationEmpty: false), "idle")
        XCTAssertEqual(ChatStage.performance(live: "coding", conversationEmpty: true), "coding", "The task under way plays as it is")
    }

    func testAShortConversationKeepsTheStage() {
        // Everything fits under the stage, whether it's shown now (450 pt viewport) or not (700 pt).
        XCTAssertTrue(decide(metrics(content: 440, viewport: 450), shown: true))
        XCTAssertTrue(decide(metrics(content: 440, viewport: 700), shown: false), "Room again: Kemo hops back up")
        XCTAssertTrue(decide(metrics(content: 450, viewport: 700), shown: false), "Exactly fitting is room")
    }

    func testFillingTheViewMovesKemoIntoTheAvatar() {
        // The latest message is followed at the bottom: the conversation fills the view.
        let full = metrics(content: 520, viewport: 450, top: 70)
        XCTAssertFalse(decide(full, shown: true))
        // Once in the avatar, the same conversation (now in the whole 700 pt) stays there.
        XCTAssertFalse(decide(metrics(content: 520, viewport: 700), shown: false),
                       "Not enough to scroll: no room for the stage, and nothing to scroll to")
        XCTAssertFalse(decide(metrics(content: 1600, viewport: 700, top: 900), shown: false))
    }

    func testScrollingToTheTopBringsTheStageBack() {
        // A long conversation scrolled to its top: the stage area is free.
        XCTAssertTrue(decide(metrics(content: 1600, viewport: 700, top: 0), shown: false))
        XCTAssertTrue(decide(metrics(content: 1600, viewport: 700, top: ChatStage.slack), shown: false), "A bounce's worth of give")
        XCTAssertFalse(decide(metrics(content: 1600, viewport: 700, top: 40), shown: false), "Not at the top yet")
        // Up there, it stays while the person reads the start, then leaves once they've scrolled past it.
        XCTAssertTrue(decide(metrics(content: 1600, viewport: 450, top: 0), shown: true))
        XCTAssertTrue(decide(metrics(content: 1600, viewport: 450, top: stage), shown: true))
        XCTAssertFalse(decide(metrics(content: 1600, viewport: 450, top: stage + 2 * ChatStage.slack), shown: true))
        XCTAssertFalse(decide(metrics(content: 1600, viewport: 450, top: 1150), shown: true), "Scrolled to the latest message")
    }

    func testKemoNeverFlickersBetweenTheTwo() {
        // Leaving the stage while scrolling down keeps the bottom in place, so the offset drops by the
        // stage's height: the next decision must not bring Kemo straight back.
        let leaving = metrics(content: 1600, viewport: 450, top: stage + 2 * ChatStage.slack)
        XCTAssertFalse(decide(leaving, shown: true))
        let after = metrics(content: 1600, viewport: 700, top: leaving.distanceFromTop - stage)
        XCTAssertFalse(decide(after, shown: false))
        // Coming back at the top keeps the top in place, so the next decision keeps it there.
        XCTAssertTrue(decide(metrics(content: 1600, viewport: 700, top: 0), shown: false))
        XCTAssertTrue(decide(metrics(content: 1600, viewport: 450, top: 0), shown: true))
        // Barely overflowing: following the bottom hides it, and the top (the same place) doesn't bring it back.
        XCTAssertFalse(decide(metrics(content: 470, viewport: 450, top: 20), shown: true))
        XCTAssertFalse(decide(metrics(content: 470, viewport: 700, top: 0), shown: false))
        // Every scroll position of a long conversation settles: a shown stage and a hidden one agree.
        for top in stride(from: CGFloat(0), through: 1150, by: 5) {
            let shownNow = decide(metrics(content: 1600, viewport: 450, top: top), shown: true)
            if !shownNow {
                let reopened = decide(metrics(content: 1600, viewport: 700, top: max(0, top - stage)), shown: false)
                XCTAssertFalse(reopened, "No flicker at \(top)")
            }
        }
    }

    func testTheStageKeepsTheTopInPlaceOnlyWhenScrolledUp() {
        XCTAssertFalse(ChatStage.anchorsTop(metrics(content: 300, viewport: 450), stageHeight: stage, shown: true), "A short chat follows its bottom")
        XCTAssertTrue(ChatStage.anchorsTop(metrics(content: 1600, viewport: 450), stageHeight: stage, shown: true))
        XCTAssertFalse(ChatStage.anchorsTop(metrics(content: 1600, viewport: 700), stageHeight: stage, shown: false))
        XCTAssertFalse(ChatStage.anchorsTop(.init(), stageHeight: stage, shown: true))
    }

    func testTheChatsStateComesFirst() {
        let long = metrics(content: 1600, viewport: 700, top: 900)
        // Hidden by the person: Kemo stays in the avatar even with room.
        XCTAssertFalse(decide(metrics(content: 100, viewport: 450), shown: true, allowed: false))
        // A performance just asked for plays on the stage, even in a long conversation.
        XCTAssertTrue(decide(long, shown: false, pinned: true))
        XCTAssertFalse(decide(long, shown: false, allowed: false, pinned: true))
        // Voice mode keeps Kemo where it is (in place, or the band) until the exchange ends.
        XCTAssertTrue(decide(long, shown: true, voiceMode: true))
        XCTAssertFalse(decide(metrics(content: 100, viewport: 700), shown: false, voiceMode: true))
    }

    /// September 28, 2026: the hand-off demo ended with the big Kemo still up and your message scrolled
    /// away under it. Content arriving while nobody has scrolled grew under a stage anchored to the top.
    /// Following the latest message, the stage leaves as soon as the conversation outgrows the room.
    func testAGrowingConversationNeverPushesAMessageUnderTheStage() {
        // The numbers the demo reported: 364 pt under a 190 pt stage, the answer card arriving.
        let grown = ChatStage.Metrics(contentHeight: 577, viewportHeight: 364, distanceFromTop: 0)
        XCTAssertFalse(ChatStage.stageShown(grown, stageHeight: 190, shown: true, allowed: true, browsing: false), "Following: Kemo moves into the avatar")
        XCTAssertFalse(ChatStage.anchorsTop(grown, stageHeight: 190, shown: true, browsing: false), "Following keeps the latest message in place")
        let settled = ChatStage.Metrics(contentHeight: 510, viewportHeight: 554, distanceFromTop: 0)
        XCTAssertFalse(ChatStage.stageShown(settled, stageHeight: 190, shown: false, allowed: true, browsing: false), "And it doesn't hop back while it wouldn't fit")
        // Still fitting under the stage: it stays.
        XCTAssertTrue(ChatStage.stageShown(.init(contentHeight: 311, viewportHeight: 364), stageHeight: 190, shown: true, allowed: true, browsing: false))
        // Scrolled up by hand to the start: the stage comes back there, as before.
        XCTAssertTrue(ChatStage.stageShown(grown, stageHeight: 190, shown: true, allowed: true, browsing: true))
        XCTAssertTrue(ChatStage.atBottom(.init(contentHeight: 510, viewportHeight: 364, distanceFromTop: 146)))
        XCTAssertFalse(ChatStage.atBottom(.init(contentHeight: 510, viewportHeight: 364, distanceFromTop: 125)))
    }
}
