import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Testing
import TsukumoCore
import UniformTypeIdentifiers
@testable import TsukumoUI

// Snapshots. The demo's final frame is compared with the website video's final frame
// (Reference/website-demo-final.png, 720 x 1564: an iPhone 17 Pro, 402 pt wide, scaled to 720 px) by
// layout: the conversation's blocks (the owner's bubble, KemoSabe's card, Claude's reply) must sit
// where the website has them, at the same sizes, within a few points. Every snapshot is also written to
// $TSUKUMO_SNAPSHOTS (or a temporary folder) for a look.

/// A rendered image's pixels, with the conversation's blocks found in it.
struct Pixels {
    let width: Int, height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width; height = image.height
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        bytes.withUnsafeMutableBytes { buffer in
            let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        self.bytes = bytes
    }
    func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
        let i = (y * width + x) * 4
        return (Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2]))
    }

    struct Block: CustomStringConvertible {
        var top: Int, bottom: Int, left: Int, right: Int
        var height: Int { bottom - top }
        var description: String { "y \(top)…\(bottom) x \(left)…\(right)" }
    }

    /// Bands of rows that differ from the background, merged across gaps under `mergeGap` pixels.
    func blocks(rows: Range<Int>, background: (Int, Int, Int), mergeGap: Int, threshold: Int = 9) -> [Block] {
        var blocks: [Block] = []
        var gap = 1_000_000
        for y in rows where y < height {
            var left = Int.max, right = -1, count = 0
            for x in 0..<width {
                let p = pixel(x, y)
                if max(abs(p.0 - background.0), abs(p.1 - background.1), abs(p.2 - background.2)) > threshold {
                    count += 1; left = min(left, x); right = max(right, x)
                }
            }
            guard count > 2 else { gap += 1; continue }
            if gap < mergeGap, var last = blocks.popLast() {
                last.bottom = y; last.left = min(last.left, left); last.right = max(last.right, right)
                blocks.append(last)
            } else {
                blocks.append(Block(top: y, bottom: y, left: left, right: right))
            }
            gap = 0
        }
        return blocks.filter { $0.height > 8 }
    }
}

@MainActor enum Snapshot {
    static var folder: URL {
        let path = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOTS"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("TsukumoUISnapshots").path
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func render<V: View>(_ view: V, width: CGFloat, scale: CGFloat, scheme: ColorScheme) -> CGImage? {
        let renderer = ImageRenderer(content: view.frame(width: width).environment(\.colorScheme, scheme))
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: width, height: nil)
        return renderer.cgImage
    }
    @discardableResult static func save(_ image: CGImage, _ name: String) -> URL {
        let url = folder.appendingPathComponent(name + ".png")
        if let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) {
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        return url
    }
    static func reference() -> CGImage? {
        guard let url = Bundle.module.url(forResource: "website-demo-final", withExtension: "png", subdirectory: "Reference"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
}

@MainActor struct SnapshotTests {
    /// The website's iPhone: 402 pt wide, shown at 720 px.
    let width: CGFloat = 402
    var scale: CGFloat { 720 / width }

    @Test func demoFinalFrameMatchesTheWebsiteLayout() throws {
        let reference = try #require(Snapshot.reference())
        let session = ChatSession(thread: DemoFixture.finalThread, bots: DemoFixture.bots, runner: DemoFixture.runner(), gate: GateAnswerer(gate: DemoFixture.gate()))
        let view = ChatTranscriptContent(session: session, showsStage: false)
            .environment(\.engineInfo, DemoFixture.engineInfo)
            .background(TsukumoTheme(.dark).background)
        let ours = try #require(Snapshot.render(view, width: width, scale: scale, scheme: .dark))
        let saved = Snapshot.save(ours, "demo-final-frame")

        let ref = Pixels(reference), mine = Pixels(ours)
        #expect(ref.width == 720 && mine.width == 720)
        // The website's conversation sits between its header (y 225) and its composer (y 1180).
        let refBlocks = ref.blocks(rows: 232..<1180, background: ref.pixel(8, 240), mergeGap: 36)
        let ourBlocks = mine.blocks(rows: 0..<mine.height, background: mine.pixel(2, 2), mergeGap: 36)
        let summary = "website: \(refBlocks)\nours: \(ourBlocks)\nsnapshot: \(saved.path)"
        try #require(refBlocks.count == 3, "The website frame should show three blocks. \(summary)")
        try #require(ourBlocks.count == 3, "The demo's final frame should show three blocks: bubble, card, reply. \(summary)")

        // Same sizes and the same gaps between blocks, within about 8 pt (14 px).
        let tolerance = 14
        for (want, got) in zip(refBlocks, ourBlocks) {
            #expect(abs(want.height - got.height) <= max(tolerance, want.height / 10), "height \(want) vs \(got). \(summary)")
            #expect(abs(want.left - got.left) <= tolerance * 2, "left edge \(want) vs \(got). \(summary)")
            #expect(abs(want.right - got.right) <= tolerance * 2, "right edge \(want) vs \(got). \(summary)")
            #expect(abs((want.top - refBlocks[0].top) - (got.top - ourBlocks[0].top)) <= tolerance * 2, "offset \(want) vs \(got). \(summary)")
        }
        // The owner's bubble is on the right; KemoSabe's card and Claude's reply hang from the left.
        #expect(ourBlocks[0].right > 600 && ourBlocks[0].left > 150)
        #expect(ourBlocks[1].left < 80 && ourBlocks[2].left < 80)
    }

    @Test func chatStatesRenderInLightAndDark() throws {
        for scheme in [ColorScheme.dark, .light] {
            let name = scheme == .dark ? "dark" : "light"
            // KemoSabe reading for Claude, and the first-time consent card.
            var thread = DemoFixture.emptyThread
            let exchange = GateExchangeID()
            thread.messages = [
                .owner(DemoFixture.task, tags: [DemoFixture.claudeID]),
                Message(author: .bot(BotSpec.kemoSabeID), parts: [.gateQuestion(GateQuestionCard(exchange: exchange, askedBy: DemoFixture.claudeID, askerName: "Claude",
                                                                                                   question: DemoFixture.question, purpose: DemoFixture.purpose))])
            ]
            let session = ChatSession(thread: thread, bots: DemoFixture.bots, runner: DemoFixture.runner(), gate: GateAnswerer(gate: DemoFixture.gate()))
            let view = ChatTranscriptContent(session: session, showsStage: true).environment(\.engineInfo, DemoFixture.engineInfo)
                .background(TsukumoTheme(scheme).background)
            let image = try #require(Snapshot.render(view, width: width, scale: 2, scheme: scheme))
            Snapshot.save(image, "demo-reading-\(name)")
            #expect(image.height > 400)

            let empty = ChatSession(thread: DemoFixture.emptyThread, bots: DemoFixture.bots, runner: DemoFixture.runner(), gate: GateAnswerer(gate: DemoFixture.gate()))
            let greeting = try #require(Snapshot.render(ChatTranscriptContent(session: empty).background(TsukumoTheme(scheme).background), width: width, scale: 2, scheme: scheme))
            Snapshot.save(greeting, "chat-empty-\(name)")
        }
    }

    @Test func everyCharacterPartDraws() throws {
        // A sheet of characters: every shape, with toppers, props, and eyes cycling, and each state.
        var looks: [BotLook] = []
        for (index, shape) in BotLook.Shape.allCases.enumerated() {
            let props = BotLook.Prop.allCases, toppers = BotLook.Topper.allCases, eyes = BotLook.Eyes.allCases
            looks.append(BotLook(shape: shape, palette: BotPalette.bright[index % BotPalette.bright.count].id,
                                 eyes: eyes[index % eyes.count], prop: props[(index * 2) % props.count], topper: toppers[index % toppers.count]))
            looks.append(BotLook(shape: shape, palette: BotPalette.bright[(index + 7) % BotPalette.bright.count].id,
                                 eyes: eyes[(index + 1) % eyes.count], prop: props[(index * 2 + 1) % props.count], topper: toppers[(index + 3) % toppers.count]))
        }
        for scheme in [ColorScheme.dark, .light] {
            let sheet = VStack(spacing: 8) {
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(64)), count: 6)) {
                    ForEach(Array(looks.enumerated()), id: \.offset) { _, look in ClayCharacter(look: look).frame(width: 64, height: 64) }
                }
                HStack {
                    ForEach(ClayState.allCases, id: \.self) { state in ClayCharacter(look: looks[0], state: state).frame(width: 44, height: 44) }
                }
                HStack(spacing: 12) {
                    BotAvatar(bot: .kemoSabe(), size: 40)
                    BotAvatar(bot: .kemoSabe(), size: 40, locked: true)
                    BotAvatar(bot: DemoFixture.claude, size: 40)
                    KemoSabeFigure(searching: true).frame(width: 80, height: 80)
                }
            }
            .padding(12)
            .environment(\.engineInfo, DemoFixture.engineInfo)
            .background(TsukumoTheme(scheme).background)
            let image = try #require(Snapshot.render(sheet, width: 430, scale: 2, scheme: scheme))
            Snapshot.save(image, "characters-\(scheme == .dark ? "dark" : "light")")
            // Something was drawn: plenty of pixels differ from the background.
            let pixels = Pixels(image)
            let background = pixels.pixel(1, 1)
            var drawn = 0
            for y in stride(from: 0, to: pixels.height, by: 3) {
                for x in stride(from: 0, to: pixels.width, by: 3) {
                    let p = pixels.pixel(x, y)
                    if abs(p.0 - background.0) + abs(p.1 - background.1) + abs(p.2 - background.2) > 40 { drawn += 1 }
                }
            }
            #expect(drawn > 2000)
        }
    }

    @Test func artworkShipsWithTheModule() {
        for name in TsukumoArt.Name.allCases {
            #expect(TsukumoArt.url(name) != nil, "\(name.rawValue).png is missing")
        }
    }
}
