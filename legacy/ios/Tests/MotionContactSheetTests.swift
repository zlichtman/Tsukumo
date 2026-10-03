import SwiftUI
import XCTest
@testable import KemoSabe

/// Renders performances at several moments into one sheet for visual review.
/// Skipped unless requested:
///   TEST_RUNNER_KEMO_MOTION_SHEET=idle,greeting,... xcodebuild test -only-testing:KemoSabeTests/MotionContactSheetTests
final class MotionContactSheetTests: XCTestCase {
    @MainActor func testRenderContactSheet() throws {
        guard let list = ProcessInfo.processInfo.environment["KEMO_MOTION_SHEET"], !list.isEmpty else {
            throw XCTSkip("Set KEMO_MOTION_SHEET to a comma-separated list of performances.")
        }
        let performances = try list.split(separator: ",").map { try XCTUnwrap(ArtworkPerformance(rawValue: String($0)), String($0)) }
        let times = (ProcessInfo.processInfo.environment["KEMO_MOTION_TIMES"] ?? "0.4,1.2,2.0,2.8,4.4,6.2").split(separator: ",").compactMap { Double($0) }
        let side: CGFloat = CGFloat(Double(ProcessInfo.processInfo.environment["KEMO_MOTION_SIDE"] ?? "180") ?? 180)
        let sheet = VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(performances.enumerated()), id: \.offset) { _, performance in
                HStack(spacing: 4) {
                    Text(performance.rawValue).font(.system(size: 13, weight: .semibold)).frame(width: 110, alignment: .leading)
                    ForEach(times, id: \.self) { time in
                        ArtworkScene(theme: BotTheme.presets[0], performance: performance, side: side, time: time)
                            .overlay(alignment: .topLeading) { Text(String(format: "%.1fs", time)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.7)).padding(4) }
                    }
                }
            }
        }.padding(8).background(Color(red: 0.13, green: 0.11, blue: 0.17))
        let renderer = ImageRenderer(content: sheet)
        renderer.scale = 1
        let png = try XCTUnwrap(renderer.uiImage?.pngData())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("kemo-motion-sheet.png")
        try png.write(to: url)
        print("MOTION_SHEET: " + url.path)
    }
}
