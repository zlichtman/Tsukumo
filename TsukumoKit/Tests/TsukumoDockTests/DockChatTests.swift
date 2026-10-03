#if os(macOS)
import XCTest
import TsukumoCore
import TsukumoUI
@testable import TsukumoDock

/// Each bot's chat on the dock is TsukumoUI's `ChatSession`: a bot's turn acts out on its tile, KemoSabe's
/// consent makes the asking bot need you and can be answered from the dock, conversations are saved,
/// Together tags several bots, and the website demo plays beat for beat (ported in spirit from
/// macos/Tests/AgentsDockTests.swift, whose fake runners became ChatSession stand-ins).
@MainActor final class DockChatTests: XCTestCase {
    nonisolated private let folder = temporaryFolder("DockChatTests")
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testEveryBotHasItsOwnChatAndTogetherHasEveryone() throws {
        let dock = makeDock()
        let homework = try dock.add(BotSpec(name: "Homework", engine: .codingAgent("claude-code"), look: .kemoSabe)).get()
        let research = try dock.add(BotSpec(name: "Research", engine: .codingAgent("codex"), look: .kemoSabe)).get()
        XCTAssertEqual(dock.session(homework.id)?.threadBots.map(\.id), [BotSpec.kemoSabeID, homework.id], "A bot's chat has KemoSabe and the bot")
        XCTAssertEqual(dock.session(BotSpec.kemoSabeID)?.threadBots.map(\.id), [BotSpec.kemoSabeID])
        XCTAssertEqual(Set(dock.session(BotDock.togetherID)?.threadBots.map(\.id) ?? []), Set([BotSpec.kemoSabeID, homework.id, research.id]))
        XCTAssertEqual(dock.session(homework.id)?.placeholder, "Message Homework…", "Untagged, it goes to the bot whose chat it is")
        dock.remove(research.id)
        XCTAssertNil(dock.session(research.id), "Removing a bot closes its chat")
        XCTAssertFalse(dock.session(BotDock.togetherID)?.threadBots.contains { $0.id == research.id } ?? true)
    }

    func testABotsTurnActsOutOnItsTileAndFinishesWithACelebration() async throws {
        let dock = makeDock()
        let homework = try dock.add(BotSpec(name: "Homework", engine: .api(profile: UUID()), look: .kemoSabe)).get()
        let session = try XCTUnwrap(dock.session(homework.id))
        session.draft = "What’s left on the stats assignment?"
        session.send()
        XCTAssertEqual(dock.characterState(homework.id), .thinking, "A turn started, no words yet")
        XCTAssertTrue(dock.running(homework.id))
        XCTAssertEqual(dock.subtitle(homework.id), "Working…")
        let talked = await waitUntil { dock.characterState(homework.id) == .talking }
        XCTAssertTrue(talked, "Words streaming in")
        let done = await waitUntil { dock.characterState(homework.id) == .done }
        XCTAssertTrue(done, "A little celebration when it finishes")
        XCTAssertEqual(dock.callout?.bot, homework.id, "The owner wasn't looking: its tile says so")
        XCTAssertEqual(dock.callout?.text, "Problems 4 to 6 are left. It’s due at 5.")
        XCTAssertTrue(dock.store.state.activity.contains { $0.title == "Homework replied" })
        XCTAssertEqual(dock.store.state.lastTalkedTo, nil, "Sending from code doesn't count as the owner opening it")
    }

    func testConversationsAreSavedAndReopen() async throws {
        let file = folder.appendingPathComponent("dock.json")
        let dock = makeDock(file: file)
        let homework = try dock.add(BotSpec(name: "Homework", engine: .api(profile: UUID()), look: .kemoSabe)).get()
        let session = try XCTUnwrap(dock.session(homework.id))
        session.draft = "Hi"
        session.send()
        _ = await waitUntil { !session.isBusy }
        let reopened = makeDock(file: file)
        XCTAssertEqual(reopened.session(homework.id)?.thread.messages.count, 2, "The owner's message and the reply")
        reopened.clear(homework.id)
        XCTAssertEqual(makeDock(file: file).session(homework.id)?.thread.messages.count, 0, "Clearing a conversation is saved")
    }

    func testTogetherSendsOneMessageToEachTaggedBot() async throws {
        let dock = makeDock()
        let homework = try dock.add(BotSpec(name: "Homework", engine: .api(profile: UUID()), look: .kemoSabe)).get()
        let research = try dock.add(BotSpec(name: "Research", engine: .api(profile: UUID()), look: .kemoSabe)).get()
        let together = try XCTUnwrap(dock.session(BotDock.togetherID))
        together.draft = "@Homework what’s left? @Research find Tuesday’s notes"
        together.send()
        XCTAssertTrue(dock.running(homework.id) && dock.running(research.id), "Each tagged bot runs its own turn")
        _ = await waitUntil { !together.isBusy }
        let replies = together.thread.messages.filter { $0.author != .owner }.compactMap(\.author.botID)
        XCTAssertEqual(Set(replies), Set([homework.id, research.id]))
    }

    func testTheWebsiteDemoPlaysAndClaudeActsItOut() async throws {
        let dock = BotDock.demo(pace: 0.03)
        let claude = DemoFixture.claudeID
        var seen: [ClayState] = []
        let watcher = Task { @MainActor in
            while !Task.isCancelled {
                let state = dock.characterState(claude)
                if seen.last != state { seen.append(state) }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        await dock.playDemo(pace: 0.03, autoAllow: 0.5)
        _ = await waitUntil { !(dock.session(claude)?.isBusy ?? true) }
        _ = await waitUntil(1) { seen.contains(.done) }
        watcher.cancel()
        XCTAssertTrue(seen.contains(.thinking), "Claude thinks: \(seen)")
        XCTAssertTrue(seen.contains(.needsYou), "Claude needs you while KemoSabe's consent waits: \(seen)")
        XCTAssertTrue(seen.contains(.done), "Then it celebrates: \(seen)")
        let thread = try XCTUnwrap(dock.session(claude)?.thread)
        XCTAssertEqual(thread.messages.first?.text, DemoFixture.task)
        let card = thread.messages.compactMap { message -> GateAnswerCard? in
            for part in message.parts { if case .gateAnswer(let card) = part { return card } }
            return nil
        }.first
        XCTAssertEqual(card?.shared, DemoFixture.answer, "KemoSabe shares “After 7 tonight”")
        XCTAssertEqual(card?.device, "Mac")
        XCTAssertEqual(card?.notRead, "1 Device only chat", "The door code is never read for Claude")
        XCTAssertEqual(thread.messages.last?.text, DemoFixture.result)
        XCTAssertTrue(dock.store.state.activity.contains { $0.kind == .kemoSabeAnswer }, "Activity has KemoSabe's answer")
        XCTAssertTrue(dock.pending.isEmpty)
    }

    func testAQuestionWaitingOnTheOwnerIsAnsweredFromTheDock() async throws {
        let dock = BotDock.demo(pace: 0.02)
        let claude = DemoFixture.claudeID
        let play = Task { @MainActor in await dock.playDemo(pace: 0.02, autoAllow: nil) }
        let asked = await waitUntil { !dock.pending.isEmpty }
        XCTAssertTrue(asked)
        let request = try XCTUnwrap(dock.pending.first)
        XCTAssertEqual(request.bot, claude)
        XCTAssertEqual(request.question, DemoFixture.question)
        XCTAssertEqual(request.kind, .consent)
        XCTAssertTrue(dock.needsYou(claude)); XCTAssertEqual(dock.waitingBot?.id, claude)
        XCTAssertEqual(dock.subtitle(claude), "Needs you")
        dock.decide(.deny, for: request)
        await play.value
        _ = await waitUntil { !(dock.session(claude)?.isBusy ?? true) }
        XCTAssertFalse(dock.needsYou(claude))
        XCTAssertTrue(dock.store.state.activity.contains { $0.kind == .kemoSabeRefusal }, "Don't allow is journaled as held back")
    }

    func testClearingAndReplayingTheDemoStartsFromAnEmptyChat() async {
        let dock = BotDock.demo(pace: 0.01)
        await dock.playDemo(pace: 0.01, autoAllow: 0.1)
        _ = await waitUntil { !(dock.session(DemoFixture.claudeID)?.isBusy ?? true) }
        await dock.playDemo(pace: 0.01, autoAllow: 0.1)
        _ = await waitUntil { !(dock.session(DemoFixture.claudeID)?.isBusy ?? true) }
        XCTAssertEqual(dock.session(DemoFixture.claudeID)?.thread.messages.filter { $0.author == .owner }.count, 1)
    }
}
#endif
