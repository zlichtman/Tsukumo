import XCTest
import SwiftUI
import AppKit
import Darwin
@testable import KemoSabeMac

/// Move to Applications: where Tsukumo counts as running from, when it asks, the replace decision, and
/// the copy itself, all against temporary folders (never the real /Applications/Tsukumo.app).
final class MoveToApplicationsTests: XCTestCase {
    private let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
    private var folder: URL!
    override func setUp() {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("MoveToApplications-" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDown() {
        // Folders a test made read-only get their permissions back so they can be removed.
        if let items = FileManager.default.enumerator(atPath: folder.path) {
            for case let item as String in items { chmod(folder.appendingPathComponent(item).path, 0o755) }
        }
        try? FileManager.default.removeItem(at: folder)
    }

    private func place(_ path: String, original: String? = nil, translocated: Bool = false) -> MoveToApplications.Placement {
        MoveToApplications.placement(of: URL(fileURLWithPath: path), original: original.map { URL(fileURLWithPath: $0) }, translocated: translocated, home: home)
    }

    // MARK: Where it runs from

    func testApplicationsCountsAsInstalled() {
        for path in ["/Applications/Tsukumo.app", "/Applications/Utilities/Tsukumo.app", "/Users/someone/Applications/Tsukumo.app"] {
            XCTAssertEqual(place(path).kind, .installed, path)
            XCTAssertFalse(place(path).offersMove, path)
        }
        XCTAssertEqual(place("/ApplicationsOld/Tsukumo.app").kind, .elsewhere, "Only the Applications folder itself")
    }

    func testADiskImageIsAVolumeWithItsMountPoint() {
        let placement = place("/Volumes/Tsukumo 67/Tsukumo.app")
        XCTAssertEqual(placement.kind, .volume)
        XCTAssertEqual(placement.volume?.path, "/Volumes/Tsukumo 67")
        XCTAssertTrue(placement.offersMove)
        XCTAssertFalse(placement.translocated)
    }

    func testDownloadsAndElsewhereOfferTheMove() {
        XCTAssertEqual(place("/Users/someone/Downloads/Tsukumo.app").kind, .downloads)
        XCTAssertEqual(place("/Users/someone/Downloads/Tsukumo 2/Tsukumo.app").kind, .downloads)
        XCTAssertEqual(place("/Users/someone/Desktop/Tsukumo.app").kind, .elsewhere)
        XCTAssertTrue(place("/Users/someone/Downloads/Tsukumo.app").offersMove)
        XCTAssertTrue(place("/Users/someone/Desktop/Tsukumo.app").offersMove)
    }

    func testATranslocatedCopyIsJudgedByWhereItWasOpened() {
        let hidden = "/private/var/folders/xy/abc123/T/AppTranslocation/6A1B2C3D-0000-4000-8000-000000000000/d/Tsukumo.app"
        XCTAssertTrue(MoveToApplications.looksTranslocated(URL(fileURLWithPath: hidden)))
        let fromImage = place(hidden, original: "/Volumes/Tsukumo/Tsukumo.app", translocated: true)
        XCTAssertEqual(fromImage, .init(kind: .volume, translocated: true, volume: URL(fileURLWithPath: "/Volumes/Tsukumo", isDirectory: true)))
        let fromDownloads = place(hidden, original: "/Users/someone/Downloads/Tsukumo.app", translocated: true)
        XCTAssertEqual(fromDownloads.kind, .downloads); XCTAssertTrue(fromDownloads.translocated)
        // The SPI missing: the path alone says it's translocated, and it's somewhere to move from.
        let unknown = place(hidden)
        XCTAssertEqual(unknown.kind, .elsewhere); XCTAssertTrue(unknown.translocated); XCTAssertTrue(unknown.offersMove)
        XCTAssertEqual(place(hidden, original: "/Applications/Tsukumo.app", translocated: true).kind, .installed)
    }

    func testBuildFoldersAreNeverAsked() {
        let derived = place("/Users/someone/Library/Developer/Xcode/DerivedData/KemoSabeMac-abc/Build/Products/Debug/Tsukumo.app")
        XCTAssertEqual(derived.kind, .buildProducts); XCTAssertFalse(derived.offersMove)
        XCTAssertEqual(place("/tmp/tsukumo-release/Build/Products/Release/Tsukumo.app").kind, .buildProducts)
    }

    func testTheRunningTestHostIsNotTranslocated() {
        let result = MoveToApplications.translocation(of: Bundle.main.bundleURL)
        XCTAssertFalse(result.translocated, "The SPI answers for an ordinary build folder")
        XCTAssertNil(result.original)
    }

    // MARK: When it asks

    func testWhenItAsks() {
        let downloads = place("/Users/someone/Downloads/Tsukumo.app"), installed = place("/Applications/Tsukumo.app")
        let now = Date()
        XCTAssertTrue(MoveToApplications.shouldOffer(downloads, forced: false, uiTesting: false, testHost: false, snoozedAt: nil, now: now))
        XCTAssertFalse(MoveToApplications.shouldOffer(installed, forced: false, uiTesting: false, testHost: false, snoozedAt: nil, now: now))
        XCTAssertFalse(MoveToApplications.shouldOffer(downloads, forced: false, uiTesting: true, testHost: false, snoozedAt: nil, now: now), "Never under --ui-testing")
        XCTAssertFalse(MoveToApplications.shouldOffer(downloads, forced: false, uiTesting: false, testHost: true, snoozedAt: nil, now: now), "Never in the test host")
        XCTAssertFalse(MoveToApplications.shouldOffer(downloads, forced: false, uiTesting: false, testHost: false, snoozedAt: now.addingTimeInterval(-3600), now: now))
        XCTAssertTrue(MoveToApplications.shouldOffer(installed, forced: true, uiTesting: true, testHost: false, snoozedAt: now, now: now), "The DEBUG argument forces it")
    }

    func testNotNowHoldsForAWeek() throws {
        let now = Date()
        XCTAssertFalse(MoveToApplications.isSnoozed(since: nil, now: now))
        XCTAssertTrue(MoveToApplications.isSnoozed(since: now.addingTimeInterval(-86_400), now: now))
        XCTAssertTrue(MoveToApplications.isSnoozed(since: now.addingTimeInterval(-6.9 * 86_400), now: now))
        XCTAssertFalse(MoveToApplications.isSnoozed(since: now.addingTimeInterval(-7 * 86_400), now: now), "Asks again after a week")
        XCTAssertFalse(MoveToApplications.isSnoozed(since: now.addingTimeInterval(-30 * 86_400), now: now))
        let suite = "MoveToApplicationsTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertNil(MoveToApplications.snoozedAt(defaults))
        MoveToApplications.snooze(defaults, now: now)
        XCTAssertEqual(try XCTUnwrap(MoveToApplications.snoozedAt(defaults)).timeIntervalSince1970, now.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertTrue(MoveToApplications.isSnoozed(since: MoveToApplications.snoozedAt(defaults), now: now.addingTimeInterval(3 * 86_400)))
    }

    // MARK: Replacing

    /// A stand-in app bundle: an Info.plist with `build`, and a nested file.
    @discardableResult private func fakeApp(at url: URL, build: Int?) throws -> URL {
        let contents = url.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.zlichtman.kemosabe.mac"]
        if let build { info["CFBundleVersion"] = String(build) }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data("binary \(build ?? 0)".utf8).write(to: contents.appendingPathComponent("Tsukumo"))
        return url
    }

    func testTheReplaceDecision() throws {
        let applications = folder.appendingPathComponent("Applications", isDirectory: true)
        let destination = applications.appendingPathComponent("Tsukumo.app")
        XCTAssertEqual(MoveToApplications.plan(destination: destination), .install)
        try fakeApp(at: destination, build: 60)
        XCTAssertEqual(MoveToApplications.plan(destination: destination), .replace(existing: 60))
        let older = MoveToApplications.replacePrompt(existing: 60, current: 67, running: false)
        XCTAssertEqual(older.title, "Replace the Tsukumo in Applications?")
        XCTAssertEqual(older.detail, "The one there is build 60 and this one is build 67. The older copy goes to the Trash.")
        XCTAssertTrue(MoveToApplications.replacePrompt(existing: 70, current: 67, running: false).detail.hasPrefix("The one there is newer (build 70)"))
        XCTAssertTrue(MoveToApplications.replacePrompt(existing: 67, current: 67, running: false).detail.contains("same build"))
        XCTAssertTrue(MoveToApplications.replacePrompt(existing: nil, current: 67, running: true).detail.hasSuffix("It's open now, so it quits first."))
    }

    func testTheRouteNeedsAnAdministratorOnlyWhenItCantWrite() throws {
        let applications = folder.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        let destination = applications.appendingPathComponent("Tsukumo.app")
        XCTAssertEqual(MoveToApplications.route(applications: applications, destination: destination), .direct)
        try fakeApp(at: destination, build: 60)
        XCTAssertEqual(MoveToApplications.route(applications: applications, destination: destination), .direct)
        chmod(destination.path, 0o555)
        XCTAssertEqual(MoveToApplications.route(applications: applications, destination: destination), .administrator, "A copy this account can't move")
        chmod(destination.path, 0o755); chmod(applications.path, 0o555)
        XCTAssertEqual(MoveToApplications.route(applications: applications, destination: destination), .administrator, "An Applications folder this account can't write")
    }

    // MARK: Copying

    func testInstallingCopiesTrashesTheOldOneAndClearsQuarantine() throws {
        let source = try fakeApp(at: folder.appendingPathComponent("Volume/Tsukumo.app"), build: 67)
        let binary = source.appendingPathComponent("Contents/MacOS/Tsukumo").path
        let value = "0083;66f00000;Safari;"
        XCTAssertEqual(setxattr(source.path, MoveToApplications.quarantineAttribute, value, value.utf8.count, 0, XATTR_NOFOLLOW), 0)
        XCTAssertEqual(setxattr(binary, MoveToApplications.quarantineAttribute, value, value.utf8.count, 0, XATTR_NOFOLLOW), 0)
        let applications = folder.appendingPathComponent("Applications", isDirectory: true)
        try fakeApp(at: applications.appendingPathComponent("Tsukumo.app"), build: 60)
        let trash = folder.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let installer = MoveToApplications.Installer(applications: applications) { old in
            try FileManager.default.moveItem(at: old, to: trash.appendingPathComponent("Tsukumo-old.app"))
        }
        let installed = try installer.install(from: source)
        XCTAssertEqual(installed, applications.appendingPathComponent("Tsukumo.app"))
        XCTAssertEqual(MoveToApplications.build(of: installed), 67)
        XCTAssertEqual(MoveToApplications.build(of: trash.appendingPathComponent("Tsukumo-old.app")), 60, "The old copy went to the Trash, not deleted")
        XCTAssertFalse(MoveToApplications.isQuarantined(installed))
        XCTAssertFalse(MoveToApplications.isQuarantined(installed.appendingPathComponent("Contents/MacOS/Tsukumo")))
        XCTAssertTrue(MoveToApplications.isQuarantined(source), "Only the copy it made is changed")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Tsukumo.app"], "No staging copy left behind")
    }

    func testAFailedCopyLeavesTheInstalledAppAlone() throws {
        let applications = folder.appendingPathComponent("Applications", isDirectory: true)
        try fakeApp(at: applications.appendingPathComponent("Tsukumo.app"), build: 60)
        let installer = MoveToApplications.Installer(applications: applications) { _ in XCTFail("Nothing goes to the Trash when the copy fails") }
        XCTAssertThrowsError(try installer.install(from: folder.appendingPathComponent("Missing/Tsukumo.app")))
        XCTAssertEqual(MoveToApplications.build(of: applications.appendingPathComponent("Tsukumo.app")), 60)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Tsukumo.app"])
    }

    /// The administrator prompt's steps, run here as this account on temporary folders (with quotes in
    /// the path) to check the quoting and order, without the prompt.
    func testTheAdministratorStepsQuoteAndOrderCorrectly() throws {
        let odd = folder.appendingPathComponent("Zach's \"Drive\"", isDirectory: true)
        let source = try fakeApp(at: odd.appendingPathComponent("Volume/Tsukumo.app"), build: 67)
        let value = "0083;66f00000;Safari;"
        XCTAssertEqual(setxattr(source.path, MoveToApplications.quarantineAttribute, value, value.utf8.count, 0, XATTR_NOFOLLOW), 0)
        let applications = odd.appendingPathComponent("Applications", isDirectory: true)
        let destination = try fakeApp(at: applications.appendingPathComponent("Tsukumo.app"), build: 60).standardizedFileURL
        let trashed = odd.appendingPathComponent("Trash/Tsukumo-b60.app")
        try FileManager.default.createDirectory(at: trashed.deletingLastPathComponent(), withIntermediateDirectories: true)
        let command = MoveToApplications.administratorCommand(source: source, destination: destination, trashed: trashed, owner: "\(getuid()):\(getgid())")
        try MoveToApplications.run("/bin/sh", ["-c", command])
        XCTAssertEqual(MoveToApplications.build(of: destination), 67)
        XCTAssertEqual(MoveToApplications.build(of: trashed), 60)
        XCTAssertFalse(MoveToApplications.isQuarantined(destination))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: applications.path), ["Tsukumo.app"])
    }

    func testDiskImageMountPointsComeFromHdiutil() throws {
        let info: [String: Any] = ["images": [
            ["image-path": "/Users/someone/Downloads/Tsukumo.dmg",
             "system-entities": [["content-hint": "GUID_partition_scheme"], ["content-hint": "Apple_HFS", "mount-point": "/Volumes/Tsukumo"]]],
            ["image-path": "/tmp/other.dmg", "system-entities": [["mount-point": "/Volumes/Other Disk"]]],
        ]]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        XCTAssertEqual(MoveToApplications.diskImageMountPoints(data), ["/Volumes/Tsukumo", "/Volumes/Other Disk"])
        XCTAssertEqual(MoveToApplications.diskImageMountPoints(Data()), [])
    }

    @MainActor func testThePageSaysWhatsHappening() {
        let model = MoveToApplicationsModel()
        XCTAssertEqual(model.title, "Move Tsukumo to Applications")
        XCTAssertEqual(model.performance, "coding")
        XCTAssertNil(model.trip(at: Date()))
        let start = Date()
        model.phase = .moving; model.travelStart = start
        XCTAssertEqual(model.performance, "executing")
        XCTAssertEqual(try XCTUnwrap(model.trip(at: start.addingTimeInterval(MoveToApplicationsModel.tripDuration / 2))), 0.5, accuracy: 0.001)
        XCTAssertEqual(model.trip(at: start.addingTimeInterval(10)), 1)
        XCTAssertTrue(model.busy)
        model.phase = .moved
        XCTAssertEqual(model.title, "Moved. Opening Tsukumo…")
        model.phase = .failed("Nope"); model.travelStart = nil
        XCTAssertEqual(model.failure, "Nope"); XCTAssertFalse(model.busy); XCTAssertEqual(model.title, "Move Tsukumo to Applications")
    }
}

/// The Move to Applications page, light and dark, waiting, mid-move, moved, and with Reduce Motion.
/// Writes PNGs for review when `TSUKUMO_SNAPSHOT_DIR` is set.
@MainActor final class MoveToApplicationsSnapshotTests: XCTestCase {
    private var out: URL? {
        guard let path = ProcessInfo.processInfo.environment["TSUKUMO_SNAPSHOT_DIR"], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    func testThePageRendersInLightAndDark() throws {
        let clock = Date().timeIntervalSinceReferenceDate
        for scheme in [ColorScheme.dark, .light] {
            let suffix = scheme == .dark ? "dark" : "light"
            let waiting = MoveToApplicationsModel(); waiting.frozenClock = clock + 1.0
            try render(waiting, scheme: scheme, name: "mac-move-to-applications-" + suffix)
            let moving = MoveToApplicationsModel(); moving.phase = .moving
            moving.travelStart = Date(timeIntervalSinceReferenceDate: clock); moving.frozenClock = clock + MoveToApplicationsModel.tripDuration * 0.55
            try render(moving, scheme: scheme, name: "mac-move-to-applications-moving-" + suffix)
            let moved = MoveToApplicationsModel(); moved.phase = .moved; moved.frozenClock = clock
            try render(moved, scheme: scheme, name: "mac-move-to-applications-moved-" + suffix)
        }
        let failed = MoveToApplicationsModel(); failed.frozenClock = clock
        failed.phase = .failed("Moving into Applications needs an administrator's password. Tsukumo wasn't moved.")
        try render(failed, scheme: .dark, name: "mac-move-to-applications-failed-dark")
        let reduced = MoveToApplicationsModel(); reduced.phase = .moving; reduced.travelStart = Date(); reduced.frozenClock = clock
        try render(reduced, scheme: .dark, reduceMotion: true, name: "mac-move-to-applications-reduce-motion-dark")
    }

    private func render(_ model: MoveToApplicationsModel, scheme: ColorScheme, reduceMotion: Bool = false, name: String) throws {
        let size = MoveToApplicationsPresenter.size
        let preferences = DesktopPreferences(defaults: UserDefaults(suiteName: "MoveToApplicationsSnapshots-" + UUID().uuidString)!)
        let theme = BotTheme.presets[0]
        let page = MoveToApplicationsPage(model: model, theme: theme, reduceMotionOverride: reduceMotion)
            .environment(preferences).environment(\.colorScheme, scheme)
            .frame(width: size.width, height: size.height)
        let window = NSWindow(contentRect: .init(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let host = NSHostingView(rootView: page)
        host.frame = .init(origin: .zero, size: size)
        window.contentView = host
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(host.fittingSize.width > 0)
        if let out {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: rep)
            try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: out.appendingPathComponent(name + ".png"))
        }
        window.contentView = nil
    }
}
