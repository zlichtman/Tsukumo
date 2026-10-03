import SwiftUI
import XCTest
@testable import KemoSabe

/// The watch recolors Kemo's untinted frames on the CPU (watchOS has no shaders).
/// These tests hold it to the iPhone's real `kemoPlate` shader.
final class KemoTintTests: XCTestCase {
    @MainActor func testWatchRecolorMatchesTheIPhoneShader() throws {
        let side: CGFloat = 200
        func render(_ theme: BotTheme, _ performance: ArtworkPerformance, at time: Double) throws -> CGImage {
            let view = PuppetArtwork(theme: theme, side: side, time: 0, pose: performance.pose(at: time), performance: performance)
                .frame(width: side, height: side)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 1; renderer.isOpaque = false
            return try XCTUnwrap(renderer.cgImage)
        }
        let custom = BotTheme(id: "custom-test", name: "Mint", body: "B8F0D8", accent: "3050C0", background: "101820")
        let palettes = ["lavender", "ink", "moss", "ember"].compactMap { id in BotTheme.presets.first { $0.id == id } } + [custom]
        XCTAssertEqual(palettes.count, 5)
        for (performance, time) in [(ArtworkPerformance.idle, 0.0), (.greeting, 1.3), (.thinking, 1.6)] {
            let untinted = try render(BotTheme.presets[0], performance, at: time)
            let apricot = try pixels(untinted)
            for theme in palettes {
                let shader = try pixels(try render(theme, performance, at: time))
                // The comparison means nothing unless the shader really recolored Kemo.
                let tinting = zip(apricot, shader).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
                XCTAssertGreaterThan(Double(tinting) / Double(shader.count), 4, "\(theme.name) was not tinted")
                let body = try XCTUnwrap(KemoTint.RGB(hex: theme.body)), accent = try XCTUnwrap(KemoTint.RGB(hex: theme.accent))
                let watch = try pixels(try XCTUnwrap(KemoTint.recolored(untinted, body: body, accent: accent)))
                XCTAssertEqual(shader.count, watch.count)
                var total = 0, large = 0, visible = 0
                for i in 0..<min(shader.count, watch.count) {
                    let difference = abs(Int(shader[i]) - Int(watch[i]))
                    total += difference
                    if difference > 12 { large += 1 }
                    if i % 4 == 3, shader[i] > 0 { visible += 1 }
                }
                let mean = Double(total) / Double(shader.count)
                // Measured on Xcode 27: a mean of 0.02 to 0.08 per channel, against 9 to 31 for
                // the tint itself. Only antialiased edges where a paw overlaps the body may
                // differ, because the shader tints each layer before compositing them.
                XCTAssertLessThan(mean, 0.3, "\(theme.name) \(performance)")
                XCTAssertLessThan(Double(large) / Double(visible * 4), 0.002, "\(theme.name) \(performance)")
                XCTAssertGreaterThan(visible, 10_000, "Kemo should cover much of the frame")
            }
        }
    }

    func testApricotIsDrawnUntintedAndOtherPalettesAreTinted() {
        XCTAssertFalse(WatchLink.Palette(BotTheme.presets[0]).tinted)
        XCTAssertEqual(WatchLink.Palette(BotTheme.presets[0]).name, "Apricot")
        for theme in BotTheme.presets.dropFirst() { XCTAssertTrue(WatchLink.Palette(theme).tinted, theme.name) }
        // A custom palette with Apricot's colors is still a separate palette, as on the iPhone.
        var copy = BotTheme.presets[0]; copy.id = "custom"; copy.name = "Mine"
        XCTAssertTrue(WatchLink.Palette(copy).tinted)
    }

    func testRecolorKeepsTransparencyAndCoverage() {
        var pixels: [UInt8] = [0, 0, 0, 0,  120, 60, 50, 128,  246, 232, 209, 255]
        pixels.withUnsafeMutableBufferPointer { KemoTint.recolor($0, body: .init(r: 0.2, g: 0.4, b: 0.6), accent: .init(r: 0, g: 0, b: 1)) }
        XCTAssertEqual(Array(pixels[0..<4]), [0, 0, 0, 0])
        XCTAssertEqual(pixels[7], 128)
        XCTAssertEqual(pixels[11], 255)
        // Half-covered coral paint becomes the accent at half coverage: blue, scaled by its lightness.
        XCTAssertEqual(pixels[4], 0); XCTAssertEqual(pixels[5], 0)
        XCTAssertGreaterThan(pixels[6], 100); XCTAssertLessThanOrEqual(pixels[6], 128)
        // The reference cream takes the body color.
        XCTAssertEqual(Int(pixels[8]), 51, accuracy: 1); XCTAssertEqual(Int(pixels[9]), 102, accuracy: 1); XCTAssertEqual(Int(pixels[10]), 153, accuracy: 1)
    }

    func testHexAndContrast() {
        XCTAssertEqual(KemoTint.RGB(hex: "#EF705B"), KemoTint.RGB(hex: "ef705b"))
        XCTAssertNil(KemoTint.RGB(hex: "EF705"))
        XCTAssertNil(KemoTint.RGB(hex: "GGGGGG"))
        let black = KemoTint.RGB(r: 0, g: 0, b: 0), white = KemoTint.RGB(r: 1, g: 1, b: 1)
        XCTAssertEqual(black.contrast(with: white), 21, accuracy: 0.01)
        XCTAssertEqual(white.contrast(with: white), 1, accuracy: 0.001)
    }

    /// Premultiplied sRGB RGBA8, the form both images are compared in.
    private func pixels(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try data.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return data
    }
}
