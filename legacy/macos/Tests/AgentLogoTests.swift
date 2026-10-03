import XCTest
import SwiftUI
import AppKit
@testable import KemoSabeMac

/// The built-in agents' official marks (September 27, 2026): every built-in agent names a logo that
/// ships in the app, and the badges render in light and dark. Writes a review sheet when
/// `TSUKUMO_SNAPSHOT_DIR` is set.
@MainActor final class AgentLogoTests: XCTestCase {
    private let builtIns: [CodingProvider] = [.claude, .codex, .muse, .cursor]

    func testEveryBuiltInAgentHasItsOfficialMark() {
        for provider in builtIns {
            let mark = CodingAgentRegistry.shared.adapter(for: provider).mark
            let logo = try? XCTUnwrap(mark.logo, "\(provider) has no logo")
            XCTAssertNotNil(logo.flatMap { NSImage(named: $0) }, "\(provider)'s logo \(logo ?? "") isn't in the app's assets")
        }
    }

    func testBadgesRenderInLightAndDark() throws {
        for scheme in [ColorScheme.light, .dark] {
            let row = HStack(spacing: 18) {
                ForEach(builtIns, id: \.self) { provider in
                    VStack(spacing: 6) {
                        CodingAgentBadge(mark: CodingAgentRegistry.shared.adapter(for: provider).mark, size: 44)
                        CodingAgentAvatar(provider: provider)
                    }
                }
            }
            .padding(20).background(scheme == .dark ? Color(white: 0.11) : Color(white: 0.97))
            .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: row); renderer.scale = 2
            let image = try XCTUnwrap(renderer.nsImage, "the badges didn't render")
            XCTAssertGreaterThan(image.size.width, 200)
            if let path = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_DIR"], !path.isEmpty,
               let tiff = image.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: path).appendingPathComponent("agent-logos-\(scheme == .dark ? "dark" : "light").png"))
            }
        }
    }
}
