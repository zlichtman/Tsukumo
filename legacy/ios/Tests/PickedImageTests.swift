import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import KemoSabe

/// Picked photos decode through ImageIO at a bounded size (September 28, 2026: a profile picture
/// failed with "That photo couldn't be used").
final class PickedImageTests: XCTestCase {
    private func encoded(_ type: UTType, width: Int, height: Int, wide: Bool = false) throws -> Data {
        let space = wide ? CGColorSpace(name: CGColorSpace.displayP3)! : CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.9, green: 0.4, blue: 0.3, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }
    private func size(_ jpeg: Data) throws -> (Int, Int) {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        return (image.width, image.height)
    }
    func testAPictureIsASquareAtTheSyncedSize() throws {
        for type in [UTType.heic, .jpeg, .png] {
            let jpeg = try PickedImage.squareJPEG(try encoded(type, width: 4032, height: 3024, wide: true), side: 600)
            let (w, h) = try size(jpeg)
            XCTAssertEqual(w, 600, "\(type)"); XCTAssertEqual(h, 600, "\(type)")
        }
    }
    func testALargeCoverIsScaledDown() throws {
        let jpeg = try PickedImage.resizedJPEG(try encoded(.heic, width: 8064, height: 6048), maxSide: 1600)
        let (w, h) = try size(jpeg)
        XCTAssertEqual(max(w, h), 1600)
    }
    func testNotAnImageSaysSo() {
        XCTAssertThrowsError(try PickedImage.squareJPEG(Data("hello".utf8), side: 600)) { XCTAssertEqual($0 as? PickedImage.Failure, .notAnImage) }
        XCTAssertTrue(PickedImage.Failure.notLoaded.localizedDescription.contains("iCloud"))
    }
}
