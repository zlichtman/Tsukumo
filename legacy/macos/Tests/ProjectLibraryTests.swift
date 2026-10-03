import XCTest
@testable import KemoSabeMac

final class ProjectLibraryTests: XCTestCase {
    func testLinksAndPrivateHiddenFoldersAreNotIndexed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "# Reference".write(to: root.appendingPathComponent("PLAN.md"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".private"), withIntermediateDirectories: true)
        try "secret".write(to: root.appendingPathComponent(".private/key.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.md"), withDestinationURL: root.appendingPathComponent("PLAN.md"))
        let index = try ProjectLibraryIndex.read(root)
        XCTAssertEqual(index.references.map(\.relativePath), ["PLAN.md"])
        let malicious = ProjectReference(relativePath: "linked.md", byteCount: 11, kind: .document)
        XCTAssertThrowsError(try ProjectLibraryIndex.bytes(malicious, root: root))
        XCTAssertThrowsError(try ProjectLibraryIndex.bytes(.init(relativePath: "../outside.md", byteCount: 1, kind: .document), root: root))
    }
    func testOversizedSourcesAreExcludedAndNeverSilentlyTruncated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(repeating: 65, count: ProjectLibraryIndex.maximumTextBytes + 1).write(to: root.appendingPathComponent("large.md"))
        let index = try ProjectLibraryIndex.read(root)
        XCTAssertTrue(index.incomplete); XCTAssertTrue(index.references.isEmpty)
        XCTAssertThrowsError(try ProjectLibraryIndex.bytes(.init(relativePath: "large.md", byteCount: 1, kind: .document), root: root))
    }
    @MainActor func testCloseClearsReferenceContentAndIdentity() {
        let library = TsukumoLibrary()
        library.text = "Private source"; library.folderName = "Project"; library.fingerprint = "digest"
        library.close()
        XCTAssertTrue(library.text.isEmpty); XCTAssertTrue(library.folderName.isEmpty)
        XCTAssertTrue(library.fingerprint.isEmpty); XCTAssertNil(library.selected)
    }
}
