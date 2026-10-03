import XCTest
import SwiftUI
import AppKit
@testable import KemoSabeMac

/// Renders the September 26, 2026 Mac surfaces for review: the chat model chip's power-up picker,
/// Settings → Personalization, and Day on another day, each in light and dark. Skipped unless
/// `TSUKUMO_SNAPSHOT_DIR` is set. Offscreen windows, so AppKit-backed controls draw as they do on screen.
@MainActor final class ChatModelDaySnapshotTests: XCTestCase {
    private var folder: URL!
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("ChatModelDaySnapshots-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    func testRenderSnapshots() throws {
        guard let path = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_DIR"], !path.isEmpty else { throw XCTSkip("Set TSUKUMO_SNAPSHOT_DIR to render the snapshots") }
        let out = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ChatModelDaySnapshots-" + UUID().uuidString)!
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), apiKeys: MemoryAPIKeys())
        let claude = try APIModelProfile.validated(name: "Claude", endpoint: APIModelPreset.claude.endpoint, model: "claude-opus-5", supportsImages: true, format: .anthropic)
        store.state.apiProfiles = [claude]; store.state.selectedAPIProfile = claude.id; store.state.modelRoute = .api
        store.state.modelEfforts = [ModelEffortKey.api(claude.id): "xhigh"]
        let preferences = DesktopPreferences(defaults: defaults)
        let navigation = DesktopNavigation(defaults: defaults)
        let routines = RoutineStore(ledger: RoutineLedger(url: folder.appendingPathComponent("routines.json")))
        let connectors = ConnectorStore()
        for dark in [false, true] {
            let scheme: ColorScheme = dark ? .dark : .light
            let mode = dark ? "dark" : "light"
            let palette = preferences.palette(scheme)
            func popover(_ view: some View) -> some View {
                view.environment(store)
                    .background(palette.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.2), radius: 12, y: 4)
                    .padding(28).background(palette.sidebar)
            }
            try render(popover(ChatModelPopover(accent: palette.accent, animate: false, addModel: {}, close: {})), size: CGSize(width: 376, height: 250), dark: dark,
                       to: out.appendingPathComponent("mac-model-effort-\(mode).png"))
            try render(popover(ChatModelPopover(accent: palette.accent, animate: false, page: .models, addModel: {}, close: {})), size: CGSize(width: 376, height: 330), dark: dark,
                       to: out.appendingPathComponent("mac-model-list-\(mode).png"))
            try render(popover(ChatModelPopover(accent: palette.accent, animate: false, pending: .privateCloud, addModel: {}, close: {})), size: CGSize(width: 376, height: 200), dark: dark,
                       to: out.appendingPathComponent("mac-model-confirm-\(mode).png"))
            let settings = PersonalRoutineSettings().formStyle(.grouped)
                .environment(\.openConnections) {}
                .environment(store).environment(routines).environment(connectors)
                .background(palette.background)
            try render(settings, size: CGSize(width: 720, height: 900), dark: dark, to: out.appendingPathComponent("mac-personalization-\(mode).png"))
            try render(AboutPersonalizationPage().background(palette.background), size: CGSize(width: 560, height: 700), dark: dark,
                       to: out.appendingPathComponent("mac-personalization-about-\(mode).png"))
            for (name, offset) in [("today", 0), ("tomorrow", 1), ("yesterday", -1)] {
                let day = DesktopDayPage(day: Calendar.current.date(byAdding: .day, value: offset, to: Date())!)
                    .environment(store).environment(routines).environment(connectors).environment(navigation).environment(preferences)
                    .background(palette.background)
                try render(day, size: CGSize(width: 1000, height: 640), dark: dark, to: out.appendingPathComponent("mac-day-\(name)-\(mode).png"))
            }
        }
    }
    private func render(_ view: some View, size: CGSize, dark: Bool, to url: URL) throws {
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light).frame(width: size.width, height: size.height))
        host.frame = .init(origin: .zero, size: size)
        window.contentView = host
        // Let tasks and layout settle before drawing.
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        window.contentView = nil
    }
}
