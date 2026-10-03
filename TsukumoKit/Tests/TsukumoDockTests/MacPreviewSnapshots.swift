#if os(macOS)
import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import XCTest
import TsukumoCore
import TsukumoUI
@testable import TsukumoDock

/// Renders the Mac side for the owner, light and dark: the side dock beside a bot's chat (KemoSabe's
/// consent waiting), and a bot's settings. With
/// `TSUKUMO_MAC_SNAPSHOT_DIR` set (the repository's `design/mac-preview`), the PNGs are written there;
/// without it the views still lay out and draw, and the checks run. Offscreen renders can't draw live
/// Liquid Glass, so the glass is a stand-in here (`dockGlassFallback`).
@MainActor final class MacPreviewSnapshots: XCTestCase {
    private var out: URL? {
        guard let path = ProcessInfo.processInfo.environment["TSUKUMO_MAC_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Draws a view in an offscreen window (so AppKit controls draw too) at 2x.
    private func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme) -> CGImage? {
        let root = view
            .environment(\.colorScheme, scheme)
            .environment(\.dockGlassFallback, true)
            .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        rep.size = size
        host.cacheDisplay(in: host.bounds, to: rep)
        window.contentView = nil
        return rep.cgImage
    }

    private func save(_ image: CGImage?, _ name: String) throws {
        let image = try XCTUnwrap(image, "\(name) didn't draw")
        XCTAssertGreaterThan(image.width, 100)
        guard let out else { return }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let url = out.appendingPathComponent(name + ".png") as CFURL
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }

    // MARK: Scenes

    /// The demo dock at a moment: Claude waiting on KemoSabe's consent (or, `finished`, the demo's end),
    /// Pip at work in its project, Juniper resting.
    private func demoDock(finished: Bool = false) async throws -> BotDock {
        let dock = BotDock.demo(pace: 0.02)
        let pip = try XCTUnwrap(dock.bots.first { $0.name == "Pip" })
        var cue = DockWorkCue(status: .running, file: "Sources/ETAEstimator.swift", line: 42, tests: .running)
        cue.apply(plan: "completed · Read the code\nin_progress · Update ETAEstimator\npending · Run the tests")
        dock.cues[pip.id] = cue
        let play = Task { @MainActor in await dock.playDemo(pace: 0.02, autoAllow: finished ? 0.05 : nil) }
        if finished {
            await play.value
            _ = await waitUntil { !(dock.session(DemoFixture.claudeID)?.isBusy ?? true) }
            // Past the celebration, so Claude rests with the others.
            dock.now = { Date().addingTimeInterval(10) }
        } else {
            _ = await waitUntil { !dock.pending.isEmpty }
        }
        return dock
    }

    private func wallpaper(_ scheme: ColorScheme) -> LinearGradient {
        scheme == .dark
            ? LinearGradient(colors: [RGB(hex: "1B2238").color, RGB(hex: "3A2A48").color, RGB(hex: "5A3A3F").color], startPoint: .topLeading, endPoint: .bottomTrailing)
            : LinearGradient(colors: [RGB(hex: "BFD6EE").color, RGB(hex: "E6D8EE").color, RGB(hex: "F6DCCB").color], startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    func testTheSideDockBesideABotsChat() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let dock = try await demoDock(finished: false)
            dock.open(.bot(DemoFixture.claudeID))
            let canvas = CGSize(width: 820, height: 620)
            var settings = dock.settings; settings.size = 52
            let layout = DockLayout(settings: settings, tiles: dock.bots.count + 2, screen: CGRect(origin: .zero, size: canvas))
            let panel = layout.revealedFrame
            let bubble = layout.bubbleFrame(forTile: 1, size: DockMetrics.bubble)
            let scene = ZStack(alignment: .topLeading) {
                wallpaper(scheme)
                DockShelfView(dock: dock, layout: layout, revealed: true, reduceMotion: false, fixedTime: 1000)
                    .frame(width: panel.width, height: panel.height)
                    .offset(x: panel.minX, y: canvas.height - panel.maxY)
                DockBubble(dock: dock)
                    .shadow(color: .black.opacity(0.18), radius: 16, y: 6)
                    .offset(x: bubble.minX, y: canvas.height - bubble.maxY)
            }
            try save(render(scene, size: canvas, scheme: scheme), "side-dock-\(scheme == .dark ? "dark" : "light")")
        }
    }

    func testABotsSettings() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let dock = BotDock.demo(pace: 0.02)
            let claude = try XCTUnwrap(dock.bot(DemoFixture.claudeID))
            dock.engineChoices = BotDock.macEngines + [EngineChoice(engine: claude.engine, info: DemoFixture.engineInfo(claude.engine),
                                                                     models: ["claude-opus-5-5", "claude-sonnet-5"], wire: .anthropic)]
            let size = CGSize(width: DockMetrics.form.width + 60, height: 900)
            let scene = ZStack {
                wallpaper(scheme)
                DockBotForm(dock: dock, editing: claude) {}
                    .frame(width: DockMetrics.form.width, height: 860)
                    .background { DockGlass(shape: RoundedRectangle(cornerRadius: 22, style: .continuous)) }
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            }
            try save(render(scene, size: size, scheme: scheme), "bot-settings-\(scheme == .dark ? "dark" : "light")")
        }
    }

}

#endif
