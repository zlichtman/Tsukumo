#if os(macOS)
import XCTest
import TsukumoCore
import TsukumoUI
@testable import TsukumoDock

/// The side dock always showing, the dock's themes, each bot's settings, toppers, and characters looping
/// in Core Animation (ported from macos/Tests/BotsHomeTests.swift).
@MainActor final class DockThemesTests: XCTestCase {
    nonisolated private let folder = temporaryFolder("DockThemesTests")
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    private var file: URL { folder.appendingPathComponent("dock.json") }

    func testTheSideDockAlwaysShowsUnlessHiddenForNow() throws {
        // A file from the preview, which had a choice of where the bots lived, still loads.
        let older = try JSONDecoder().decode(DockSettings.self, from: Data(#"{"home":"notch","edge":"left"}"#.utf8))
        XCTAssertEqual(older.edge, .left)
        let store = BotDockStore(file: file)
        let controller = BotDockController(dock: BotDock(store: store) { thread, bots in
            ChatSession(thread: thread, bots: bots, runner: SlowRunner(), gate: SilentKemoSabe())
        })
        XCTAssertTrue(controller.showsSideDock, "The Tsukumo app is the side dock")
        controller.setHidden(true)
        XCTAssertFalse(controller.showsSideDock, "Hide Dock puts it away for now")
        controller.open(.together)
        XCTAssertTrue(controller.showsSideDock, "Opening a chat brings it back")
        XCTAssertEqual(controller.dock.surface, .together)
        controller.setHidden(true)
        XCTAssertNil(controller.dock.surface, "Hiding closes the open chat")
        controller.close()
    }

    func testTheDefaultModelIsSavedWithTheDock() throws {
        let store = BotDockStore(file: file)
        XCTAssertNil(store.defaultModel)
        let profile = UUID()
        store.setDefaultModel(DefaultModel(engine: .api(profile: profile), model: "claude-opus-5-5"))
        XCTAssertEqual(BotDockStore(file: file).defaultModel, DefaultModel(engine: .api(profile: profile), model: "claude-opus-5-5"))
        store.setDefaultModel(nil)
        XCTAssertNil(BotDockStore(file: file).defaultModel)
    }

    func testRestingAndLoopingCharactersAreLayerAnimationsAndStillWhenAsked() {
        let look = BotLook.suggested(name: "Homework", job: "Tracks my class deadlines")
        let view = ClayLayerView(frame: .init(x: 0, y: 0, width: 48, height: 48))
        view.configure(look: look, state: .idle, side: 48, animate: true, level: .lively, phase: 0.3)
        XCTAssertEqual(Set(view.playing), ["breathe", "blink"], "Idle breathes and blinks in Core Animation")
        XCTAssertNotNil(view.sprite.contents)
        view.configure(look: look, state: .working, side: 48, animate: true, level: .lively, phase: 0.3)
        XCTAssertEqual(Set(view.playing), ["breathe", "loop"], "Typing is a loop of pictures")
        for state in [ClayState.thinking, .talking, .needsYou, .sleeping] {
            view.configure(look: look, state: state, side: 48, animate: true, level: .lively, phase: 0.3)
            XCTAssertTrue(view.playing.contains("loop"), "\(state) loops")
        }
        view.configure(look: look, state: .working, side: 48, animate: false, level: .lively, phase: 0.3)
        XCTAssertEqual(view.playing, [], "Reduce Motion or out of sight: one still picture")
        XCTAssertNotNil(view.sprite.contents)
        view.configure(look: look, state: .idle, side: 48, animate: true, level: .still, phase: 0.3)
        XCTAssertEqual(view.playing, [], "Still")
        XCTAssertEqual(ClaySprites.loop(look, state: .thinking, level: .lively, side: 48, scale: 1)?.frames.count, 12)
        XCTAssertNil(ClaySprites.loop(look, state: .idle, level: .lively, side: 48, scale: 1), "Idle breathes and blinks instead")
        XCTAssertFalse(ClaySprites.looping.contains(.chirping), "A chirp's hop is drawn live, once")
        let lively = ClaySprites.loop(look, state: .talking, level: .lively, side: 48, scale: 1)!.duration
        let calm = ClaySprites.loop(look, state: .talking, level: .calm, side: 48, scale: 1)!.duration
        XCTAssertGreaterThan(calm, lively, "Calm plays slower")
    }

    func testDockThemesAreSaved() throws {
        let fresh = DockSettings()
        XCTAssertEqual(fresh.style, .glass); XCTAssertEqual(fresh.indicator, .dot)
        XCTAssertEqual(fresh.engineMark, .ring, "A thin ring of the engine's color by default")
        XCTAssertEqual(fresh.labels, .glass); XCTAssertTrue(fresh.separators)
        XCTAssertEqual(DockStyle.allCases.map(\.title), ["Glass", "Tinted glass", "Solid", "Minimal"])
        BotDockStore(file: file).update {
            $0.style = .minimal; $0.indicator = .ring; $0.engineMark = .logo; $0.labels = .plain
            $0.separators = false; $0.spacing = 0.2; $0.corners = 0.25
        }
        let saved = BotDockStore(file: file).settings
        XCTAssertEqual(saved.style, .minimal); XCTAssertEqual(saved.indicator, .ring); XCTAssertEqual(saved.engineMark, .logo)
        XCTAssertEqual(saved.labels, .plain); XCTAssertFalse(saved.separators)
        XCTAssertEqual(saved.spacing, 0.2, accuracy: 0.0001); XCTAssertEqual(saved.corners, 0.25, accuracy: 0.0001)
        var wild = DockSettings(); wild.spacing = 5; wild.corners = -1
        let clamped = wild.clamped()
        XCTAssertEqual(clamped.spacing, DockSettings.spacingRange.upperBound); XCTAssertEqual(clamped.corners, DockSettings.cornersRange.lowerBound)
        XCTAssertNotEqual(DockEngineColor.hex(.codingAgent("claude-code")), DockEngineColor.hex(.codingAgent("codex")), "Each engine its own color")
    }

    func testEachBotsSettingsAreSavedAndAnEngineChangeResetsItsModel() throws {
        let store = BotDockStore(file: file)
        var bot = BotSpec(name: "Research", engine: .codingAgent("claude-code"), model: "claude-opus-5-5", effort: "high",
                          role: "Reads papers", look: .suggested(name: "Research", job: "Reads papers"))
        bot.contextScope.mayAskKemoSabe = false; bot.contextScope.ceiling = .open; bot.contextScope.project = "/tmp/papers"
        bot.permissions = BotPermissions(access: .autoEdit, approvalsHere: false, mayChirp: false, speaks: false)
        bot = try store.add(bot).get()
        store.setChirpWatch(DockChirpWatch(sources: [.reminders], words: [" Stats ", ""], leadMinutes: 5), for: bot.id)
        let reopened = BotDockStore(file: file)
        let saved = try XCTUnwrap(reopened.bot(bot.id))
        XCTAssertEqual(saved.model, "claude-opus-5-5"); XCTAssertEqual(saved.effort, "high")
        XCTAssertFalse(saved.contextScope.mayAskKemoSabe); XCTAssertEqual(saved.contextScope.ceiling, .open)
        XCTAssertEqual(saved.contextScope.project, "/tmp/papers")
        XCTAssertEqual(saved.permissions, BotPermissions(access: .autoEdit, approvalsHere: false, mayChirp: false, speaks: false))
        XCTAssertEqual(reopened.chirpWatch(bot.id), DockChirpWatch(sources: [.reminders], words: ["stats"], leadMinutes: 15), "Cleaned and bounded")
        var moved = saved; moved.engine = .codingAgent("codex")
        let after = try store.update(moved).get()
        XCTAssertNil(after.model, "Another engine starts on its own default model"); XCTAssertNil(after.effort)
        var renamed = after; renamed.name = "   "
        if case .success = store.update(renamed) { XCTFail("An empty name is refused") }
        XCTAssertEqual(DockStarter.all.map(\.title), ["Homework helper", "Project coder", "Research reader"])
        let starter = DockStarter.all[1].bot(existing: store.bots)
        XCTAssertEqual(starter.look.prop, .hardHat); XCTAssertEqual(starter.permissions.access, .askFirst)
    }

    func testKemoSabeIsFirstStaysAndKeepsWhoItIs() throws {
        let store = BotDockStore(file: file, kemoSabeName: "Mochi")
        XCTAssertEqual(store.bots.map(\.id), [BotSpec.kemoSabeID])
        XCTAssertEqual(store.bots[0].name, "Mochi", "KemoSabe under the companion's own name")
        if case .success = store.add(.kemoSabe()) { XCTFail("KemoSabe is already there") }
        var renamed = store.bots[0]; renamed.name = "Other"; renamed.engine = .codingAgent("codex"); renamed.permissions.mayChirp = false
        let kept = try store.update(renamed).get()
        XCTAssertEqual(kept.name, "Mochi"); XCTAssertEqual(kept.engine, .appleOnDevice); XCTAssertFalse(kept.permissions.mayChirp)
        store.remove(BotSpec.kemoSabeID)
        XCTAssertEqual(store.bots.first?.id, BotSpec.kemoSabeID, "KemoSabe can't be removed")
    }

    func testToppersGiveEachBotItsOwnSilhouette() {
        XCTAssertEqual(BotLook.suggested(name: "PowderMeet coder", job: "Codes the iOS app").topper, .none, "Nothing under a hard hat")
        let headset = BotLook.suggested(name: "Support", job: "Takes my calls")
        XCTAssertEqual(headset.prop, .headset)
        XCTAssertFalse([BotLook.Topper.ears, .roundEars].contains(headset.topper), "No ears under a headset")
        var taken: [BotLook] = []
        for name in ["Homework", "Research", "Writer", "Designer", "Ops"] {
            taken.append(.suggested(name: name, job: name, taken: taken))
        }
        let toppers = taken.map(\.topper).filter { $0 != .none }
        XCTAssertEqual(Set(toppers).count, toppers.count, "Different toppers while some are left")
        XCTAssertEqual(Set(taken.map(\.palette)).count, taken.count, "Different palettes while some are left")
    }
}
#endif
