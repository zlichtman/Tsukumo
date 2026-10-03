import SwiftUI
import XCTest
@testable import KemoSabe

/// Renders the watch app's Kemo frames from the real iPhone artwork and shader
/// (watchOS has no Metal or SwiftUI shaders). Skipped unless requested:
///   TEST_RUNNER_KEMO_RENDER_WATCH_FRAMES=1 xcodebuild test -only-testing:KemoSabeTests/WatchArtworkRenderTests
/// then scale the printed folder's 400 px PNGs to 256 px and replace the matching
/// kemo-*.imageset files in ios/KemoSabeWatch/Assets.xcassets (kemo-idle, -blink,
/// -greeting, -listening, and -thinking at 128 px in
/// ios/KemoSabeWatchWidgets/Assets.xcassets, for the pet-mood complication).
final class WatchArtworkRenderTests: XCTestCase {
    @MainActor func testRenderWatchFrames() throws {
        guard ProcessInfo.processInfo.environment["KEMO_RENDER_WATCH_FRAMES"] == "1" else {
            throw XCTSkip("Set KEMO_RENDER_WATCH_FRAMES=1 to regenerate the watch frames.")
        }
        let output = FileManager.default.temporaryDirectory.appendingPathComponent("kemo-watch-frames")
        try? FileManager.default.removeItem(at: output)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let idle = ArtworkPerformance.idle.pose(at: 0)
        var blink = idle; blink.eyelids = 1
        var talking = ArtworkPerformance.speaking.pose(at: 0.4); talking.mouth = 0.9
        var resting = talking; resting.mouth = 0.05
        let frames: [(String, ArtworkPerformance, ArtworkPerformance.Pose)] = [
            ("kemo-idle", .idle, idle), ("kemo-blink", .idle, blink),
            ("kemo-listening", .listening, ArtworkPerformance.listening.pose(at: 1.2)),
            ("kemo-thinking", .thinking, ArtworkPerformance.thinking.pose(at: 1.6)),
            ("kemo-speaking-open", .speaking, talking), ("kemo-speaking-closed", .speaking, resting),
            ("kemo-greeting", .greeting, ArtworkPerformance.greeting.pose(at: 1.3))
        ]
        let side: CGFloat = 200
        for (name, performance, pose) in frames {
            let view = PuppetArtwork(theme: BotTheme.presets[0], side: side, time: 0, pose: pose, performance: performance)
                .frame(width: side, height: side)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2; renderer.isOpaque = false
            let png = try XCTUnwrap(renderer.uiImage?.pngData(), name)
            try png.write(to: output.appendingPathComponent(name + ".png"))
        }
        print("WATCH_FRAMES: " + output.path)
    }
}
