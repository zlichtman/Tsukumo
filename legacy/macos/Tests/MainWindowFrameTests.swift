import XCTest
@testable import KemoSabeMac

/// The main window never opens collapsed or off screen from a bad saved frame.
final class MainWindowFrameTests: XCTestCase {
    private let minSize = NSSize(width: 760, height: 540)
    private let screen = NSRect(x: 0, y: 0, width: 1512, height: 944)

    func testASavedFrameAtLeastTheMinimumOnScreenIsKept() {
        XCTAssertTrue(MainWindowFrame.isUsable(NSRect(x: 100, y: 80, width: 1120, height: 760), minSize: minSize, visibleFrames: [screen]))
        XCTAssertTrue(MainWindowFrame.isUsable(NSRect(x: 0, y: 0, width: 760, height: 540), minSize: minSize, visibleFrames: [screen]), "Exactly the minimum is fine")
    }

    func testAFrameOfAlmostNoSizeIsReplaced() {
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 400, y: 300, width: 0, height: 0), minSize: minSize, visibleFrames: [screen]))
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 400, y: 300, width: 1, height: 28), minSize: minSize, visibleFrames: [screen]))
    }

    func testAFrameSmallerThanTheMinimumInEitherDirectionIsReplaced() {
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 0, y: 0, width: 759, height: 800), minSize: minSize, visibleFrames: [screen]))
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 0, y: 0, width: 1200, height: 539), minSize: minSize, visibleFrames: [screen]))
    }

    func testAFrameOffEveryScreenIsReplaced() {
        // Saved on a display that is no longer connected.
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 3000, y: 0, width: 1120, height: 760), minSize: minSize, visibleFrames: [screen]))
        // Touching an edge only is not on screen.
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 1512, y: 0, width: 1120, height: 760), minSize: minSize, visibleFrames: [screen]))
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 0, y: 0, width: 1120, height: 760), minSize: minSize, visibleFrames: []), "No screens")
    }

    func testAFrameOnASecondScreenIsKept() {
        let second = NSRect(x: 1512, y: 0, width: 2560, height: 1415)
        XCTAssertTrue(MainWindowFrame.isUsable(NSRect(x: 2000, y: 200, width: 1120, height: 760), minSize: minSize, visibleFrames: [screen, second]))
    }

    func testAFrameThatIsNotANumberIsReplaced() {
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 0, y: 0, width: CGFloat.infinity, height: 760), minSize: minSize, visibleFrames: [screen]))
        XCTAssertFalse(MainWindowFrame.isUsable(NSRect(x: 0, y: 0, width: CGFloat.nan, height: 760), minSize: minSize, visibleFrames: [screen]))
    }

    func testTheDefaultSizeIsUsableOnTheSmallestSupportedScreen() {
        XCTAssertEqual(MainWindowFrame.defaultContentSize, NSSize(width: 1120, height: 760))
        let frame = NSRect(origin: NSPoint(x: 196, y: 92), size: MainWindowFrame.defaultContentSize)
        XCTAssertTrue(MainWindowFrame.isUsable(frame, minSize: minSize, visibleFrames: [screen]))
    }
}
