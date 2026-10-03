import XCTest
import SwiftUI
import AppKit
@testable import KemoSabeMac

/// Settings → Models on the Mac: the same `ModelConnectionsView` (LLM, System One, Training) as iPhone,
/// drawn in an offscreen window on the theme's background, with a private folder holding one Plan fit
/// decision to mark and a sample connection. Also the Companion page's Voice sheet. With
/// `TSUKUMO_SNAPSHOT_DIR` set (pass `TEST_RUNNER_TSUKUMO_SNAPSHOT_DIR`), light and dark pictures are
/// saved there (`design/models/` for the owner).
@MainActor final class ModelsMacTests: XCTestCase {
    private var folder: URL!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("ModelsMac-" + UUID().uuidString, isDirectory: true)
        SystemOneStorage.fixtureFolder = folder
    }
    override func tearDown() {
        SystemOneStorage.fixtureFolder = nil
        try? FileManager.default.removeItem(at: folder)
    }

    func testTheMacDrawsEachModelsTabOnTheTheme() throws {
        let record = SystemOneRecord(at: Date().addingTimeInterval(-300), kind: .candidateFit, decidedBy: .fallback,
            steps: [.init(provider: .laya, version: CoreMLLayaProvider.version, score: 0.62, reason: .lowConfidence, layer: .base)],
            milliseconds: 48, questions: [.init(id: "fit", options: ["9:00 AM", "2:00 PM", "5:00 PM"], laya: [0.62, 0.3, 0.08])])
        SystemOneJournal.write([record], to: folder.appendingPathComponent(SystemOneJournal.fileName))
        let keys = MemoryAPIKeys()
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: keys)
        let claude = try APIModelProfile.validated(name: "Claude", endpoint: "https://api.anthropic.com/v1/messages", model: "claude-opus-5-5", format: .anthropic)
        try store.addAPIProfile(claude, key: "sk-ant-sample")
        // A connection that arrived from the iPhone, whose key isn't on this Mac yet.
        let openAI = try APIModelProfile.validated(name: "OpenAI", endpoint: "https://api.openai.com/v1/chat/completions", model: "gpt-5")
        store.state.apiProfiles?.append(openAI)
        let preferences = DesktopPreferences(defaults: UserDefaults(suiteName: "ModelsMac-" + UUID().uuidString)!)
        let out = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        let tabs: [(ModelsTab, String)] = [(.llm, "llm"), (.systemOne, "system-one"), (.training, "training")]
        for (tab, name) in tabs {
            for dark in [false, true] {
                let palette = preferences.palette(dark ? .dark : .light)
                let page = ModelConnectionsView(tab: tab, openPersonalization: {})
                    .environment(store).environment(preferences)
                    .tint(palette.accent).background(palette.background)
                let png = try render(page, size: CGSize(width: 760, height: tab == .llm ? 1000 : 1200), dark: dark)
                XCTAssertGreaterThan(png.count, 20_000, "\(name) drew")
                if let out { try png.write(to: out.appendingPathComponent("mac-\(name)-\(dark ? "dark" : "light").png")) }
            }
        }
        for dark in [false, true] {
            let palette = preferences.palette(dark ? .dark : .light)
            let sheet = MacVoiceSettings(size: nil).environment(store).tint(palette.accent).background(palette.background)
            let png = try render(sheet, size: CGSize(width: 600, height: 1500), dark: dark)
            XCTAssertGreaterThan(png.count, 20_000)
            if let out { try png.write(to: out.appendingPathComponent("mac-companion-voice-\(dark ? "dark" : "light").png")) }
        }
    }

    private func render(_ view: some View, size: CGSize, dark: Bool) throws -> Data {
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.frame = .init(origin: .zero, size: size)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return try XCTUnwrap(rep.representation(using: .png, properties: [:]))
    }
}
