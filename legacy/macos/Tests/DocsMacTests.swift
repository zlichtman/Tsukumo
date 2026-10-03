import AppKit
import SwiftUI
import XCTest
@testable import KemoSabeMac

/// Docs and Journal on the Mac: the two-pane Library draws, and (with DOCS_SNAPSHOT_DIR set)
/// renders light and dark screenshots for design/docs-journal.
@MainActor final class DocsMacTests: XCTestCase {
    func testLibraryDocsAndJournalRenderInBothAppearances() throws {
        let docs = DocsStore.shared
        if docs.pages.isEmpty { docs.seedSample() }
        XCTAssertFalse(docs.livePages.isEmpty)
        let folder = ProcessInfo.processInfo.environment["DOCS_SNAPSHOT_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        for dark in [false, true] {
            let palette = DesktopPalette.make(.kemoSabe, dark: dark)
            for section in ["Docs", "Journal"] {
                let image = try render(Host(section: section).background(palette.background).foregroundStyle(palette.foreground).tint(palette.accent)
                    .environment(\.colorScheme, dark ? .dark : .light), dark: dark)
                XCTAssertGreaterThan(image.width, 0)
                if let folder {
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try data.write(to: folder.appendingPathComponent("mac-\(section.lowercased())-\(dark ? "dark" : "light").png"))
                }
            }
        }
    }
    private struct Host: View {
        @State var section: String
        var body: some View { DesktopDocsLibrary(section: $section).frame(width: 1180, height: 760) }
    }
    /// Draws the view in an offscreen window, so lists, fields, and scroll views render as they do on screen.
    private func render(_ view: some View, dark: Bool) throws -> CGImage {
        let hosting = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        hosting.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
        hosting.cacheDisplay(in: hosting.bounds, to: rep)
        return try XCTUnwrap(rep.cgImage)
    }
}
