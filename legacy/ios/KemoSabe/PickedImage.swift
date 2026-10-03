import SwiftUI
import PhotosUI
import ImageIO
import UniformTypeIdentifiers
import os

/// Loading a photo someone picked, and decoding it safely (September 28, 2026: a profile picture
/// failed with only "That photo couldn't be used"). The picker's file is tried first, which works
/// for photos still in iCloud and very large ones, then its data. Decoding goes through ImageIO's
/// downsampler, so HEIC, HDR, and 48 MP photos never need to be decoded at full size.
enum PickedImage {
    enum Failure: LocalizedError, Equatable {
        case notLoaded, notAnImage
        var errorDescription: String? {
            switch self {
            case .notLoaded: "That photo couldn't be loaded from your library. If it's stored in iCloud, check your connection and try again."
            case .notAnImage: "That file isn't a photo KemoSabe can read. Try another one."
            }
        }
    }
    private static let log = Logger(subsystem: "com.zlichtman.kemosabe", category: "picked-image")

    /// The picked photo's bytes.
    static func load(_ item: PhotosPickerItem) async throws -> Data {
        do {
            if let file = try await item.loadTransferable(type: PickedImageFile.self) {
                defer { try? FileManager.default.removeItem(at: file.url) }
                return try Data(contentsOf: file.url)
            }
        } catch { log.error("file load failed: \(String(describing: type(of: error)), privacy: .public) \((error as NSError).code, privacy: .public)") }
        do {
            if let data = try await item.loadTransferable(type: Data.self) { return data }
        } catch { log.error("data load failed: \(String(describing: type(of: error)), privacy: .public) \((error as NSError).code, privacy: .public)") }
        throw Failure.notLoaded
    }

    /// The image scaled so its longest side is at most `maxSide` pixels, upright.
    static func decode(_ data: Data, maxSide: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceShouldCacheImmediately: true,
                  kCGImageSourceThumbnailMaxPixelSize: maxSide] as CFDictionary)
        else { throw Failure.notAnImage }
        return image
    }

    /// A centered square crop of `data`, `side` pixels, as JPEG.
    static func squareJPEG(_ data: Data, side: Int, quality: CGFloat = 0.88) throws -> Data {
        let image = try decode(data, maxSide: side * 3)
        let edge = min(image.width, image.height)
        let crop = CGRect(x: (image.width - edge) / 2, y: (image.height - edge) / 2, width: edge, height: edge)
        guard let square = image.cropping(to: crop) else { throw Failure.notAnImage }
        return try jpeg(square, maxSide: side, quality: quality)
    }

    /// The image scaled to at most `maxSide`, as JPEG.
    static func resizedJPEG(_ data: Data, maxSide: Int, quality: CGFloat = 0.85) throws -> Data {
        try jpeg(decode(data, maxSide: maxSide), maxSide: maxSide, quality: quality)
    }

    private static func jpeg(_ image: CGImage, maxSide: Int, quality: CGFloat) throws -> Data {
        var output = image
        let longest = max(image.width, image.height)
        if longest > maxSide {
            // Scale in sRGB, 8-bit: HDR and wide-gamut sources come out as a plain JPEG.
            let scale = CGFloat(maxSide) / CGFloat(longest)
            let width = max(1, Int((CGFloat(image.width) * scale).rounded())), height = max(1, Int((CGFloat(image.height) * scale).rounded()))
            guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw Failure.notAnImage }
            context.interpolationQuality = .high
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            guard let scaled = context.makeImage() else { throw Failure.notAnImage }
            output = scaled
        }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw Failure.notAnImage }
        CGImageDestinationAddImage(destination, output, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw Failure.notAnImage }
        return data as Data
    }
}

/// The picker's own file for an image, copied out before the picker removes it.
struct PickedImageFile: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + (received.file.pathExtension.isEmpty ? "img" : received.file.pathExtension))
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self(url: copy)
        }
    }
}
