#if os(macOS)
import XCTest
import TsukumoCore
import TsukumoUI
@testable import TsukumoDock

/// The dock's characters (their states, what each acts out, still poses), customization and order saved
/// with the dock, the dock's settings, and where each edge and position puts the shelf and bubbles
/// (ported from macos/Tests/BotDockTests.swift onto BotSpec and TsukumoUI's clay).
@MainActor final class BotDockTests: XCTestCase {
    nonisolated private let folder = temporaryFolder("BotDockTests")
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }
    private var file: URL { folder.appendingPathComponent("dock.json") }

    func testStatesComeFromWhatTheBotIsDoing() {
        func state(needsYou: Bool = false, running: Bool = false, words: Bool = false, coding: Bool = false, voicing: Bool = false,
                   chirp: TimeInterval? = nil, done: Bool = false, tucked: Bool = false, night: Bool = false) -> ClayState {
            DockCharacterState.resolve(needsYou: needsYou, running: running, hasWords: words, coding: coding, voicing: voicing,
                                       sinceChirp: chirp, done: done, tucked: tucked, night: night)
        }
        XCTAssertEqual(state(), .idle)
        XCTAssertEqual(state(running: true), .thinking, "No words yet: thinking")
        XCTAssertEqual(state(running: true, words: true), .talking)
        XCTAssertEqual(state(running: true, coding: true), .working, "A coding bot at work types")
        XCTAssertEqual(state(voicing: true), .talking, "Its reply read aloud")
        XCTAssertEqual(state(chirp: 1), .chirping)
        XCTAssertEqual(state(chirp: 3), .idle, "The hop is short")
        XCTAssertEqual(state(needsYou: true, running: true, chirp: 1), .needsYou, "Needing you wins")
        XCTAssertEqual(state(done: true), .done)
        XCTAssertEqual(state(tucked: true), .sleeping)
        XCTAssertEqual(state(night: true), .sleeping)
        XCTAssertEqual(state(running: true, night: true), .thinking, "Busy characters don't sleep")
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 14))!
        XCTAssertFalse(DockCharacterState.isNight(day, calendar: calendar))
        XCTAssertTrue(DockCharacterState.isNight(calendar.date(bySettingHour: 23, minute: 30, second: 0, of: day)!, calendar: calendar))
        XCTAssertTrue(DockCharacterState.isNight(calendar.date(bySettingHour: 6, minute: 0, second: 0, of: day)!, calendar: calendar))
        XCTAssertEqual(ClayState.needsYou.label, "Needs you")
    }

    func testEachStateActsItOutAndStillHoldsAPose() {
        func pose(_ state: ClayState, _ time: Double, still: Bool = false) -> ClayPose { ClayMotion.pose(state, time: time, local: time, still: still) }
        XCTAssertTrue(pose(.working, 1).keyboard, "Typing on a tiny keyboard")
        XCTAssertEqual(pose(.thinking, 1).dots, 3, "Dots over its head")
        XCTAssertGreaterThan(pose(.needsYou, 1).rightArm, 2.4, "A raised hand")
        XCTAssertEqual(pose(.sleeping, 1).blink, 1, "Eyes shut")
        XCTAssertGreaterThan(pose(.done, 0.3).confetti, 0, "A little celebration…")
        XCTAssertEqual(pose(.done, 3).confetti, 0, "…then it settles")
        XCTAssertGreaterThan(pose(.chirping, 0.25).lift, 0.05, "A hop")
        XCTAssertNotEqual(pose(.talking, 1.0).mouth, pose(.talking, 1.05).mouth, "Its mouth moves")
        for state in ClayState.allCases {
            XCTAssertEqual(pose(state, 0.3, still: true), pose(state, 7.9, still: true), "\(state) moves when still")
        }
        XCTAssertGreaterThan(pose(.needsYou, 0, still: true).rightArm, 2.4, "A still pose still shows the state")
        XCTAssertTrue(pose(.working, 0, still: true).keyboard)
    }

    func testNewBotsGetACharacterForTheirJob() throws {
        let store = BotDockStore(file: file)
        let homework = try store.add(BotSpec(name: "Homework", engine: .codingAgent("claude-code"), role: "Tracks my class deadlines", look: .kemoSabe)).get()
        let coder = try store.add(BotSpec(name: "PowderMeet coder", engine: .codingAgent("codex"), role: "the iOS app", look: .kemoSabe)).get()
        XCTAssertEqual(homework.look.prop, .pencil)
        XCTAssertEqual(coder.look.prop, .hardHat)
        XCTAssertEqual(coder.look.eyes, .visor)
        XCTAssertNotEqual(homework.look.palette, coder.look.palette, "Each gets a palette of its own")
        XCTAssertNotEqual(homework.look.shape, coder.look.shape)
        XCTAssertNotEqual(homework.look.palette, BotLook.kemoSabe.palette, "KemoSabe's own palette stays KemoSabe's")
        XCTAssertEqual(BotLook.suggested(name: "Homework", job: "x"), BotLook.suggested(name: "Homework", job: "x"), "The same words, the same character")
    }

    func testDraggingReordersAndKemoSabeStaysFirst() throws {
        let store = BotDockStore(file: file)
        func add(_ name: String) throws -> BotSpec { try store.add(BotSpec(name: name, engine: .codingAgent("codex"), look: .kemoSabe)).get() }
        let a = try add("A"), b = try add("B"), c = try add("C")
        store.move(c.id, to: 1)
        XCTAssertEqual(store.bots.dropFirst().map(\.id), [c.id, a.id, b.id])
        store.move(a.id, to: 0)
        XCTAssertEqual(store.bots.first?.id, BotSpec.kemoSabeID, "Nothing goes ahead of KemoSabe")
        XCTAssertEqual(store.bots.dropFirst().map(\.id), [a.id, c.id, b.id])
        store.move(BotSpec.kemoSabeID, to: 3)
        XCTAssertEqual(store.bots.first?.id, BotSpec.kemoSabeID, "KemoSabe doesn't move")
        store.move(a.id, to: 99)
        XCTAssertEqual(BotDockStore(file: file).bots.map(\.id), [BotSpec.kemoSabeID, c.id, b.id, a.id], "The order is saved")
    }

    func testSettingsAreSaved() throws {
        let store = BotDockStore(file: file)
        store.update {
            $0.edge = .left; $0.position = .top; $0.size = 56; $0.magnification = true; $0.magnifiedSize = 96
            $0.autohide = false; $0.autohideDelay = 1.5; $0.indicator = .none; $0.engineMark = .none; $0.namesOnHover = false
            $0.animation = .calm; $0.sleepAtNight = false; $0.chirpSounds = true
        }
        let saved = BotDockStore(file: file).settings
        XCTAssertEqual(saved.edge, .left); XCTAssertEqual(saved.position, .top); XCTAssertEqual(saved.size, 56)
        XCTAssertTrue(saved.magnification); XCTAssertEqual(saved.magnifiedSize, 96); XCTAssertFalse(saved.autohide)
        XCTAssertEqual(saved.autohideDelay, 1.5); XCTAssertEqual(saved.indicator, .none); XCTAssertEqual(saved.engineMark, .none)
        XCTAssertFalse(saved.namesOnHover); XCTAssertEqual(saved.animation, .calm); XCTAssertFalse(saved.sleepAtNight); XCTAssertTrue(saved.chirpSounds)
        XCTAssertNil(BotDockStore(file: folder.appendingPathComponent("other/dock.json")).state.settings, "Another dock is its own")
        store.update { $0.size = 300; $0.magnifiedSize = 10; $0.autohideDelay = -2 }
        XCTAssertEqual(store.settings.size, 80); XCTAssertEqual(store.settings.magnifiedSize, 88); XCTAssertEqual(store.settings.autohideDelay, 0)
        let partial = try JSONDecoder().decode(DockSettings.self, from: Data(#"{"edge":"left","future":"x","style":"holographic"}"#.utf8))
        XCTAssertEqual(partial.edge, .left); XCTAssertTrue(partial.autohide); XCTAssertEqual(partial.style, .glass, "A newer build's style falls back")
    }

    func testANewDockStartsFromTheSystemDocksSize() {
        let dock = UserDefaults(suiteName: "BotDockTests-" + UUID().uuidString)!
        XCTAssertEqual(DockSettings.matchingSystemDock(dock).size, 48, "About 48 pt when the Dock doesn't say")
        dock.set(64.0, forKey: "tilesize"); dock.set(true, forKey: "magnification"); dock.set(100.0, forKey: "largesize")
        let settings = DockSettings.matchingSystemDock(dock)
        XCTAssertEqual(settings.size, 64); XCTAssertTrue(settings.magnification); XCTAssertEqual(settings.magnifiedSize, 100)
        dock.set(128.0, forKey: "tilesize")
        XCTAssertEqual(DockSettings.matchingSystemDock(dock).size, 80, "A huge Dock doesn't make a huge side dock")
    }

    func testEdgesAndPositionsPlaceTheShelfAndBubbles() {
        let screen = CGRect(x: 0, y: 80, width: 1440, height: 790)
        func layout(_ edge: DockSettings.Edge, _ position: DockSettings.Position, magnify: Bool = false) -> DockLayout {
            var settings = DockSettings(); settings.edge = edge; settings.position = position; settings.magnification = magnify; settings.magnifiedSize = 80
            return DockLayout(settings: settings, tiles: 6, screen: screen)
        }
        let right = layout(.right, .center)
        XCTAssertEqual(right.shelf.maxX, screen.maxX - DockLayout.screenMargin)
        XCTAssertEqual(right.shelf.midY, screen.midY, accuracy: 0.5)
        XCTAssertEqual(right.thickness, 48 + right.padding * 2)
        XCTAssertLessThanOrEqual(right.bubbleFrame(forTile: 5, size: DockMetrics.bubble).maxX, right.shelf.minX, "The bubble opens toward the screen")
        XCTAssertEqual(right.tuckedFrame.maxX, screen.maxX)
        XCTAssertTrue(right.revealedFrame.contains(right.shelf))
        let left = layout(.left, .center)
        XCTAssertEqual(left.shelf.minX, screen.minX + DockLayout.screenMargin)
        XCTAssertGreaterThanOrEqual(left.bubbleFrame(forTile: 0, size: DockMetrics.bubble).minX, left.shelf.maxX)
        XCTAssertEqual(left.tuckedFrame.minX, screen.minX)
        XCTAssertGreaterThanOrEqual(left.calloutFrame(forTile: 1, size: DockMetrics.callout).minX, left.shelf.maxX)
        let top = layout(.right, .top, magnify: true)
        XCTAssertEqual(top.revealedFrame.maxY, screen.maxY - DockLayout.screenMargin, accuracy: 0.5, "Room for magnified tiles stays on screen")
        let bottom = layout(.left, .bottom, magnify: true)
        XCTAssertEqual(bottom.revealedFrame.minY, screen.minY + DockLayout.screenMargin, accuracy: 0.5)
        // Tiles run down the shelf, with the separator before + and Together, all inside it.
        let centers = (0..<6).map(right.tileCenter)
        XCTAssertEqual(centers.map(\.y), centers.map(\.y).sorted(by: >))
        XCTAssertEqual(centers[4].y - centers[5].y, right.size + right.spacing, accuracy: 0.5)
        XCTAssertEqual(centers[3].y - centers[4].y, right.size + right.spacing + DockLayout.separatorGap, accuracy: 0.5)
        for center in centers { XCTAssertTrue(right.shelf.contains(center)) }
        XCTAssertEqual(right.shelfInPanel.size, right.shelf.size)
        XCTAssertEqual(right.revealedFrame.minX + right.shelfInPanel.minX, right.shelf.minX, accuracy: 0.5)
        XCTAssertLessThanOrEqual(top.bubbleFrame(forTile: 0, size: DockMetrics.bubble).maxY, screen.maxY, "A bubble near the top stays on screen")
        XCTAssertEqual(DockMetrics.size(for: .edit(nil)), DockMetrics.form, "A bot's settings are taller than a chat")
    }

    func testMagnificationLikeTheDock() {
        XCTAssertEqual(DockLayout.magnification(distance: 0, size: 48, magnified: 96), 2, accuracy: 0.001)
        XCTAssertEqual(DockLayout.magnification(distance: 200, size: 48, magnified: 96), 1)
        XCTAssertEqual(DockLayout.magnification(distance: 10, size: 48, magnified: 40), 1, "Nothing smaller than the tile")
        XCTAssertGreaterThan(DockLayout.magnification(distance: 30, size: 48, magnified: 96), DockLayout.magnification(distance: 80, size: 48, magnified: 96))
    }

    func testChirpingCharactersAndTheirNeighbors() throws {
        var clock = Calendar.current.date(bySettingHour: 14, minute: 0, second: 0, of: Date())!
        let dock = makeDock()
        dock.now = { clock }
        let homework = try dock.add(BotSpec(name: "Homework", engine: .codingAgent("claude-code"), look: .kemoSabe)).get()
        dock.post(DockChirp(bot: homework.id, text: "Your stats assignment is due in 2 hours.", key: "k"))
        XCTAssertEqual(dock.characterState(homework.id), .chirping)
        XCTAssertEqual(dock.lastChirp?.bot, homework.id, "Its neighbors glance at it")
        XCTAssertEqual(dock.callout?.text, "Your stats assignment is due in 2 hours.")
        XCTAssertEqual(dock.store.state.activity.last?.title, "Homework chirped in")
        dock.post(DockChirp(bot: homework.id, text: "Again", key: "k"))
        XCTAssertEqual(dock.store.state.activity.count, 1, "Each chirp happens once")
        clock = clock.addingTimeInterval(5)
        XCTAssertEqual(dock.characterState(homework.id), .idle)
        clock = Calendar.current.date(bySettingHour: 23, minute: 30, second: 0, of: clock)!
        XCTAssertEqual(dock.characterState(homework.id), .sleeping, "Asleep at night")
        dock.store.update { $0.sleepAtNight = false }
        XCTAssertEqual(dock.characterState(homework.id), .idle, "Unless sleeping at night is off")
        dock.react(.giggle, on: homework.id); dock.react(.poke, on: homework.id)
        XCTAssertEqual(dock.reaction[homework.id]?.kind, .poke)
        XCTAssertEqual(dock.reaction[homework.id]?.tick, 2)
        var quiet = homework; quiet.permissions.mayChirp = false
        dock.update(quiet)
        dock.post(DockChirp(bot: homework.id, text: "Quiet", key: "k2"))
        XCTAssertEqual(dock.store.state.activity.count, 1, "A bot that may not chirp stays quiet")
    }

    func testEveryMotionIsStillUnderReduceMotion() {
        for motion in DockMotion.allCases { XCTAssertTrue(motion.spec(reduceMotion: true).isStill, "\(motion)") }
        XCTAssertFalse(DockMotion.hop.spec(reduceMotion: false).isStill)
    }
}
#endif
