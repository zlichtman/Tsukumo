#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import TsukumoCore
import TsukumoPolicy
import TsukumoUI
@testable import TsukumoDock

/// The dock keeps KemoSabe standard (its color is the one thing that changes), takes chats and bots that
/// sync from the owner's iPhone, and draws the editors and the first run. With
/// `TSUKUMO_CUSTOMIZATION_SNAPSHOT_DIR` and `TSUKUMO_ONBOARDING_SNAPSHOT_DIR` set (the repository's
/// `design/bot-customization` and `design/onboarding`), light and dark PNGs are written there.
@MainActor final class BotCustomizationTests: XCTestCase {
    func testKemoSabeKeepsOnlyItsColorOnTheDock() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dock-\(UUID().uuidString).json")
        let store = BotDockStore(file: file)
        var edited = try XCTUnwrap(store.bot(BotSpec.kemoSabeID))
        edited.look = BotLook(shape: .block, palette: "lagoon", eyes: .visor, prop: .hardHat, accentColor: "6F63C9")
        edited.engine = .codingAgent("codex")
        edited.contextScope.ceiling = .open
        edited.permissions.mayChirp = false
        let saved = try store.update(edited).get()
        XCTAssertEqual(saved.look, .kemoSabe(tint: "6F63C9"))
        XCTAssertEqual(saved.engine, .appleOnDevice)
        XCTAssertEqual(saved.contextScope.ceiling, .deviceOnly)
        XCTAssertFalse(saved.permissions.mayChirp)
        // And a relaunch keeps its color and its chirping choice.
        let again = BotDockStore(file: file)
        XCTAssertEqual(again.bots.first?.look, .kemoSabe(tint: "6F63C9"))
        XCTAssertEqual(again.bots.first?.permissions.mayChirp, false)
        // A new bot can't be added wearing KemoSabe's look.
        var copycat = BotSpec(name: "Copycat", engine: .appleOnDevice, look: .kemoSabe)
        copycat = try again.add(copycat).get()
        XCTAssertNotEqual(copycat.look, .kemoSabe)
    }

    func testSyncedChatsLandInTheirConversations() throws {
        let dock = BotDock.demo(pace: 0.02)
        let claude = DemoFixture.claudeID
        // Claude's conversation on the Mac, as sync reads it (it hasn't been saved yet).
        let library = dock.store.library
        var macChat = try XCTUnwrap(dock.session(claude)?.thread)
        XCTAssertFalse(library.threads.contains { $0.id == macChat.id })
        // The iPhone added a reply in the same chat, and made a chat of its own.
        macChat.messages.append(Message(date: Date(), author: .owner, parts: [.text("and from the iPhone")], tags: [claude]))
        let threads = library.threads + [macChat]
        let phoneChat = ChatThread(title: "Groceries", botIDs: [BotSpec.kemoSabeID], messages: [Message.owner("oat milk", tags: [BotSpec.kemoSabeID])])
        var bots = library.bots
        bots[0].look = .kemoSabe(tint: "2F8F8B")
        dock.applySynced(bots: bots, threads: threads + [phoneChat])
        XCTAssertEqual(dock.session(claude)?.thread.messages.last?.text, "and from the iPhone", "the open conversation shows it")
        XCTAssertEqual(dock.store.otherChats.map(\.id), [phoneChat.id], "the iPhone's own chat is kept beside the conversations")
        XCTAssertEqual(dock.bots.first?.kemoSabeTint, "2F8F8B")
        XCTAssertEqual(dock.bots.first?.engine, .appleOnDevice)
    }

    // MARK: Pictures

    private func folder(_ key: String) -> URL? {
        guard let path = ProcessInfo.processInfo.environment[key], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme) -> CGImage? {
        let root = view.environment(\.colorScheme, scheme).environment(\.dockGlassFallback, true).frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep.cgImage
    }

    private func save(_ image: CGImage?, _ name: String, in out: URL?) throws {
        let image = try XCTUnwrap(image, "\(name) didn't draw")
        XCTAssertGreaterThan(image.width, 100)
        guard let out else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(out.appendingPathComponent(name + ".png") as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    private func panel<V: View>(_ content: V, scheme: ColorScheme, height: CGFloat) -> some View {
        ZStack {
            (scheme == .dark ? RGB(hex: "2A2238").color : RGB(hex: "E9DFEA").color)
            content
                .frame(width: DockMetrics.form.width, height: height)
                .background { DockGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
    }

    func testEditorPictures() throws {
        let out = folder("TSUKUMO_CUSTOMIZATION_SNAPSHOT_DIR")
        for scheme in [ColorScheme.light, .dark] {
            let name = scheme == .dark ? "dark" : "light"
            let dock = BotDock.demo(pace: 0.02)
            dock.update(BotSpec.kemoSabe(tint: "6F63C9"))
            let kemoSabe = try XCTUnwrap(dock.bot(BotSpec.kemoSabeID))
            try save(render(panel(DockBotForm(dock: dock, editing: kemoSabe) {}, scheme: scheme, height: 560), size: CGSize(width: 480, height: 600), scheme: scheme),
                     "mac-kemosabe-settings-" + name, in: out)

            var juniper = try XCTUnwrap(dock.bots.first { $0.name == "Juniper" })
            juniper.look.bodyColor = "BFE8D3"
            juniper.look.accentColor = "6F63C9"
            juniper.look.expression = .grin
            juniper.look.accessory = .scarf
            juniper.look.scale = 1.15
            juniper.look.ring = .custom
            juniper.look.ringColor = "6F63C9"
            juniper.personality = BotPersonality(tone: .coach, instructions: "Call me Sam. Keep it to my stats class.")
            dock.update(juniper)
            let edited = try XCTUnwrap(dock.bot(juniper.id))
            XCTAssertEqual(edited.look.accessory, .scarf)
            try save(render(panel(DockBotForm(dock: dock, editing: edited, openDrawers: ["Look", "Personality", "Dock"]) {}, scheme: scheme, height: 1500),
                            size: CGSize(width: 480, height: 1540), scheme: scheme),
                     "mac-bot-editor-" + name, in: out)
        }
    }

    func testOnboardingPictures() throws {
        let out = folder("TSUKUMO_ONBOARDING_SNAPSHOT_DIR")
        for scheme in [ColorScheme.light, .dark] {
            for step in OnboardingFlow<FakeOnboardingHost>.Step.allCases {
                let host = FakeOnboardingHost()
                if step == .bots { _ = host.add(starter: StarterBot.all[0]) }
                let name = "mac-\(step.rawValue + 1)-\(["welcome", "sign-in", "connect", "bots"][step.rawValue])-" + (scheme == .dark ? "dark" : "light")
                try save(render(OnboardingFlow(host: host, start: step), size: CGSize(width: 520, height: 700), scheme: scheme), name, in: out)
            }
        }
    }
}

/// A first run with nothing behind it: in-memory account, sources, and bots.
@MainActor final class FakeOnboardingHost: OnboardingHost {
    let accounts = AccountStore(file: nil, appleID: MemoryAppleIDStore())
    let deviceName = "Mac"
    let fixtureSignIn = true
    var appleIntelligence: (ready: Bool, text: String) { (true, "Ready") }
    var connected: Set<OnboardingProvider> = [.claude]
    func isConnected(_ provider: OnboardingProvider) -> Bool { connected.contains(provider) }
    func connect(_ provider: OnboardingProvider, key: String) async throws { connected.insert(provider) }
    var onboardingSources = [OnboardingSource(id: "calendar", title: "Calendar", symbol: "calendar", on: true, level: .personal),
                             OnboardingSource(id: "reminders", title: "Reminders", symbol: "checklist", on: false, level: .personal)]
    func setSource(_ id: String, on: Bool) async {}
    func setSource(_ id: String, level: PrivacyLevel) async {}
    var bots: [BotSpec] = [.kemoSabe()]
    var engineChoices: [EngineChoice] { BotDock.macEngines }
    func add(starter: StarterBot) -> BotSpec? { let bot = starter.bot(existing: bots); bots.append(bot); return bot }
    func save(bot: BotSpec) { bots.append(bot) }
    func remove(bot id: UUID) { bots.removeAll { $0.id == id } }
    var finished = false
    func finishOnboarding() { finished = true }
}
#endif
