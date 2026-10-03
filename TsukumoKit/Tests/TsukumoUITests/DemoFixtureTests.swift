import Foundation
import Testing
import TsukumoCore
@testable import TsukumoUI

/// The website demo, beat for beat (docs/ARCHITECTURE.md#the-demo-mapped).
@MainActor struct DemoFixtureTests {
    /// Waits (briefly, polling) until `condition` holds.
    private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    @Test func playsTheFiveBeatsInOrder() async {
        let session = DemoFixture.session(pace: 0.004)
        var activity: [ActivityItem] = []
        session.onActivity = { activity.append($0) }
        await DemoFixture.play(session, pace: 0.004)

        // Beat 1: the message typed in and sent to Claude, tagged with its chip.
        let first = session.thread.messages.first
        #expect(first?.text == DemoFixture.task)
        #expect(first?.tags == [DemoFixture.claudeID])
        #expect(session.draft.isEmpty)

        #expect(await eventually { session.events.contains(.replied(DemoFixture.claudeID)) })
        let exchange = session.events.compactMap { if case .askedKemoSabe(let id, _) = $0 { id } else { nil } }.first
        #expect(exchange != nil)
        guard let exchange else { return }
        // Beats 2 to 5: Claude works, asks KemoSabe, KemoSabe answers, Claude replies.
        #expect(session.events == [
            .sent(to: [DemoFixture.claudeID]),
            .working(DemoFixture.claudeID),
            .askedKemoSabe(exchange, by: DemoFixture.claudeID),
            .answered(exchange, .answered),
            .replied(DemoFixture.claudeID)
        ])
        #expect(session.working.isEmpty)
        #expect(!session.kemoSabeIsReading)
        #expect(session.banner == "Answered Claude: “After 7 tonight”")
        #expect(activity.map(\.kind) == [.kemoSabeAnswer, .botWork])
        #expect(activity.first?.title == "Answered Claude")
    }

    @Test func endsOnTheWebsitesFinalFrame() async {
        let session = DemoFixture.session(pace: 0.004)
        await DemoFixture.play(session, pace: 0.004)
        #expect(await eventually { session.events.contains(.replied(DemoFixture.claudeID)) })
        let expected = DemoFixture.finalThread.messages
        let played = session.thread.messages
        #expect(played.count == expected.count)
        #expect(played.map(\.author) == expected.map(\.author))
        #expect(played.map(\.text) == expected.map(\.text))
        guard played.count == 3, case .gateAnswer(let card) = played[1].parts.first, case .gateAnswer(let want) = expected[1].parts.first else {
            Issue.record("No answer card"); return
        }
        // KemoSabe read the two chats Claude may have, never the Device only one.
        #expect(card.question == "What time is Sarah free tonight?")
        #expect(card.shared == "After 7 tonight")
        #expect(card.stayedLine == "Stayed on this iPhone: 4 messages, 2 chats")
        #expect(card.notReadLine == "Not read: 1 Device only chat.")
        #expect(card.caption == "On this iPhone · Apple on-device")
        #expect(card.shared == want.shared && card.stayed == want.stayed && card.notRead == want.notRead)
        #expect(played[2].text == "Sarah’s free after 7. Book Osteria Lucia on Valencia for 7:30: it’s quiet and candlelit, and a short walk from her place.")
    }

    @Test func pacingMatchesTheWebsiteVideo() {
        // The old app's ChatHandoffFixture, which recorded the website video.
        #expect(DemoFixture.typingStart == 1.5)
        #expect(DemoFixture.typingSpeed == 16)
        #expect(DemoFixture.sendPause == 0.5)
        #expect(DemoFixture.working == 2.5)
        #expect(DemoFixture.looking == 2.5)
        #expect(DemoFixture.finishing == 3)
        let total = DemoFixture.typingStart + Double(DemoFixture.task.count) / DemoFixture.typingSpeed + DemoFixture.sendPause
            + DemoFixture.working + DemoFixture.looking + DemoFixture.finishing
        #expect(total > 12 && total < 20)
    }

    @Test func theCardsCopyHasNoShortNamesOrDashes() {
        let card = DemoFixture.answerCard(exchange: GateExchangeID())
        let words = [DemoFixture.task, DemoFixture.question, DemoFixture.result, card.stayedLine ?? "", card.notReadLine ?? "", card.caption]
        for line in words {
            #expect(!line.contains("—"))
            #expect(!line.split(whereSeparator: { !$0.isLetter }).contains("Kemo"))
        }
    }
}
