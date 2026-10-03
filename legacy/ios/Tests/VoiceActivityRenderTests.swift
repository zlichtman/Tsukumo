import SwiftUI
import XCTest
@testable import KemoSabe

/// Renders Kemo's Live Activity (Lock Screen and Dynamic Island pieces) for every state, with the
/// frames from the widget extension's own asset catalog. Set KEMO_SAVE_ACTIVITY_RENDERS=1 (as
/// TEST_RUNNER_KEMO_SAVE_ACTIVITY_RENDERS=1 with xcodebuild) to keep the PNGs for a look.
final class VoiceActivityRenderTests: XCTestCase {
    private static let attributes = KemoVoiceAttributes(name: "KemoSabe", body: "F6E8D2", accent: "EF705B", tinted: false,
                                                        background: "211B2C", foreground: "FCFCFC", themeAccent: "EF705B")

    @MainActor override func setUpWithError() throws {
        // The app embeds the widget extension; its asset catalog holds the Live Activity frames.
        let appex = try XCTUnwrap(Bundle.main.builtInPlugInsURL?.appendingPathComponent("KemoSabeWidgets.appex"))
        KemoVoiceFrames.bundle = try XCTUnwrap(Bundle(url: appex), "The widget extension is embedded in the app")
    }
    @MainActor override func tearDown() { KemoVoiceFrames.bundle = .main }

    @MainActor func testEveryStateDrawsAnApprovedFrameInsideThePresentationSizes() throws {
        for phase in [VoiceAnywherePhase.listening, .thinking, .speaking, .answered, .failed] {
            let state = KemoVoiceAttributes.ContentState(phase: phase, line: "Line", level: 2, mouthOpen: true)
            let frame = KemoVoiceFrames.image(state.frame, attributes: Self.attributes)
            let mini = KemoVoiceFrames.image(state.frame + "-mini", attributes: Self.attributes)
            XCTAssertNotNil(frame.cgImage, "\(state.frame) is in the extension's catalog")
            XCTAssertNotNil(mini.cgImage, "\(state.frame)-mini is in the extension's catalog")
            // Assets larger than the presentation can stop a Live Activity from starting.
            XCTAssertLessThanOrEqual(frame.size.width, 48); XCTAssertLessThanOrEqual(mini.size.width, 24)
        }
    }

    @MainActor func testAPaletteRecolorsTheFrames() throws {
        var mint = Self.attributes
        mint.body = "BDEBD5"; mint.accent = "2F8F6B"; mint.tinted = true
        let approved = try XCTUnwrap(KemoVoiceFrames.image("kemo-listening", attributes: Self.attributes).cgImage)
        let tinted = try XCTUnwrap(KemoVoiceFrames.image("kemo-listening", attributes: mint).cgImage)
        XCTAssertEqual(approved.width, tinted.width)
        XCTAssertNotEqual(Self.pixels(approved), Self.pixels(tinted), "Kemo takes the companion's palette")
    }

    @MainActor func testTheLockScreenAndIslandRenderEveryState() throws {
        let save = ProcessInfo.processInfo.environment["KEMO_SAVE_ACTIVITY_RENDERS"] == "1"
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("kemo-activity-renders")
        if save { try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        var machine = VoiceAnywhereMachine()
        machine.handle(.level(0.7))
        var states: [(String, KemoVoiceAttributes.ContentState)] = [("listening", machine.content)]
        machine.handle(.transcribing); states.append(("thinking", machine.content))
        machine.handle(.answered(reply: "You have two meetings today: the design review at 10 and lunch with Sam at 12:30.", heard: "What's on my calendar today?"))
        machine.handle(.word); states.append(("speaking", machine.content))
        machine.handle(.finishedSpeaking); states.append(("answered", machine.content))
        var failed = VoiceAnywhereMachine(); failed.handle(.failed("Unlock your iPhone to answer.")); states.append(("failed", failed.content))

        for (name, state) in states {
            let background = KemoVoiceFrames.color(Self.attributes.background)
            let lock = KemoVoiceLockScreen(attributes: Self.attributes, state: state)
                .frame(width: 370).background(background)
            let island = HStack(spacing: 0) {
                KemoVoiceFrame(attributes: Self.attributes, state: state, mini: true).frame(width: 24, height: 24)
                Spacer(minLength: 0)
                KemoVoiceTrailingSign(state: state, tint: KemoVoiceFrames.color(Self.attributes.themeAccent))
            }.padding(.horizontal, 10).frame(width: 250, height: 37).background(.black, in: Capsule())
            for (part, view) in [("lock", AnyView(lock)), ("island", AnyView(island.padding(8).background(.white)))] {
                let renderer = ImageRenderer(content: view)
                renderer.scale = 2
                let image = try XCTUnwrap(renderer.uiImage, "\(part) \(name)")
                XCTAssertGreaterThan(image.size.height, 30)
                if save { try image.pngData()?.write(to: folder.appendingPathComponent("\(part)-\(name).png")) }
            }
        }
        if save { print("ACTIVITY_RENDERS: " + folder.path) }
    }

    private static func pixels(_ image: CGImage) -> [UInt8] {
        let width = image.width, height = image.height
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return data
    }
}
