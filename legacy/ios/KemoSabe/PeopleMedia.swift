import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Photos and backgrounds for People profiles, in the account's own folder with complete
/// file protection. Like the rest of People, they never enter model context.
enum PeopleMedia {
    static var folder: URL { AccountDirectory.folder(for: AccountDirectory.current()).appendingPathComponent("People", isDirectory: true) }

    /// Saves an image scaled to at most `maxSide` pixels as JPEG and returns its file name.
    static func save(_ data: Data, maxSide: Int, prefix: String) throws -> String {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary) else { throw PeopleError.invalid }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { throw PeopleError.invalid }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PeopleError.invalid }
        let name = prefix + "-" + UUID().uuidString + ".jpg"
        let folder = folder
        try AccountDirectory.checkWrite(to: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try (output as Data).write(to: folder.appendingPathComponent(name), options: [.atomic, .completeFileProtection])
        return name
    }
    static func remove(_ name: String?) {
        guard let name, safe(name) else { return }
        try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
    }
    static func image(_ name: String?) -> Image? {
        guard let name, safe(name) else { return nil }
        let path = folder.appendingPathComponent(name).path
        #if os(macOS)
        return NSImage(contentsOfFile: path).map { Image(nsImage: $0) }
        #else
        return UIImage(contentsOfFile: path).map { Image(uiImage: $0) }
        #endif
    }
    /// Only names this type wrote: no paths, no traversal.
    static func safe(_ name: String) -> Bool {
        name.count <= 80 && name.hasSuffix(".jpg") && !name.contains("/") && !name.hasPrefix(".")
    }
}
