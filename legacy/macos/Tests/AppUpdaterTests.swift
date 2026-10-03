import XCTest
@testable import KemoSabeMac

final class AppUpdaterTests: XCTestCase {
    private let sha = String(repeating: "0bbe1735", count: 8)
    private func feed(_ fields: [String: Any]) throws -> Data {
        var base: [String: Any] = ["version": "1.0.0", "build": 73, "url": "https://zlichtman.com/downloads/Tsukumo-1.0.0-73.dmg", "sha256": sha]
        base.merge(fields) { _, new in new }
        return try JSONSerialization.data(withJSONObject: base)
    }

    // MARK: Version comparison

    func testANewerBuildOfTheSameVersionIsAnUpdate() {
        XCTAssertTrue(TsukumoRelease.isNewer(version: "1.0.0", build: 73, than: "1.0.0", build: 72))
        XCTAssertFalse(TsukumoRelease.isNewer(version: "1.0.0", build: 72, than: "1.0.0", build: 72))
        XCTAssertFalse(TsukumoRelease.isNewer(version: "1.0.0", build: 71, than: "1.0.0", build: 72))
    }
    func testTheVersionOutranksTheBuild() {
        XCTAssertTrue(TsukumoRelease.isNewer(version: "1.0.1", build: 1, than: "1.0.0", build: 72))
        XCTAssertTrue(TsukumoRelease.isNewer(version: "1.10.0", build: 1, than: "1.9.9", build: 500))
        XCTAssertFalse(TsukumoRelease.isNewer(version: "1.0.0", build: 900, than: "1.1.0", build: 2))
        // Missing components count as zero.
        XCTAssertFalse(TsukumoRelease.isNewer(version: "1.0", build: 72, than: "1.0.0", build: 72))
        XCTAssertTrue(TsukumoRelease.isNewer(version: "1.0", build: 73, than: "1.0.0", build: 72))
    }

    // MARK: Feed parsing

    func testTheFeedParses() throws {
        let release = try TsukumoRelease.parse(feed([:]))
        XCTAssertEqual(release.version, "1.0.0")
        XCTAssertEqual(release.build, 73)
        XCTAssertEqual(release.url.absoluteString, "https://zlichtman.com/downloads/Tsukumo-1.0.0-73.dmg")
        XCTAssertEqual(release.sha256, sha)
        XCTAssertNil(release.minimumMacOS)
        XCTAssertNil(release.notes)
        // What release-mac.sh writes: the minimum macOS and a line of notes.
        let full = try TsukumoRelease.parse(feed(["minimumMacOS": "26.0", "notes": "Updates through Homebrew."]))
        XCTAssertEqual(full.minimumMacOS, "26.0")
        XCTAssertEqual(full.notes, "Updates through Homebrew.")
        // The unversioned download is fine too, and unknown fields are ignored.
        XCTAssertEqual(try TsukumoRelease.parse(feed(["url": "https://zlichtman.com/downloads/Tsukumo.dmg", "channel": "x"])).build, 73)
    }
    func testTheMinimumMacOSIsCompared() throws {
        let release = try TsukumoRelease.parse(feed(["minimumMacOS": "26.1"]))
        XCTAssertTrue(release.runs(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 1, patchVersion: 0)))
        XCTAssertTrue(release.runs(on: OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 0)))
        XCTAssertFalse(release.runs(on: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 4)))
        XCTAssertFalse(release.runs(on: OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)))
        // No minimum, or one that isn't a number, never holds an update back.
        XCTAssertTrue(try TsukumoRelease.parse(feed([:])).runs(on: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
        XCTAssertTrue(try TsukumoRelease.parse(feed(["minimumMacOS": "Tahoe"])).runs(on: OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)))
    }
    func testAnOddFeedIsRefused() throws {
        let bad: [[String: Any]] = [
            ["build": 0], ["build": -4], ["build": "73"],
            ["version": "1.0.x"], ["version": ""], ["version": "1..0"],
            ["url": "http://zlichtman.com/downloads/Tsukumo-1.0.0-73.dmg"],
            ["url": "https://example.com/downloads/Tsukumo-1.0.0-73.dmg"],
            ["url": "https://zlichtman.com/elsewhere/Tsukumo.dmg"],
            ["url": "https://zlichtman.com/downloads/Tsukumo-1.0.0-73.zip"],
            ["sha256": "abc"], ["sha256": String(repeating: "z", count: 64)]
        ]
        for fields in bad { XCTAssertThrowsError(try TsukumoRelease.parse(feed(fields)), "\(fields)") }
        XCTAssertThrowsError(try TsukumoRelease.parse(Data("<html>".utf8)))
        XCTAssertThrowsError(try TsukumoRelease.parse(JSONSerialization.data(withJSONObject: ["version": "1.0.0", "build": 73])))
    }

    // MARK: Homebrew install detection

    func testAHomebrewCopyIsInApplicationsWithACaskroomEntry() {
        let appleSilicon: Set = ["/opt/homebrew/Caskroom/tsukumo", "/opt/homebrew/bin/brew"]
        XCTAssertEqual(HomebrewInstall.prefix(bundlePath: "/Applications/Tsukumo.app", exists: appleSilicon.contains), "/opt/homebrew")
        XCTAssertEqual(HomebrewInstall.prefix(bundlePath: "/Applications/./Tsukumo.app", exists: appleSilicon.contains), "/opt/homebrew")
        let intel: Set = ["/usr/local/Caskroom/tsukumo", "/usr/local/bin/brew"]
        XCTAssertEqual(HomebrewInstall.prefix(bundlePath: "/Applications/Tsukumo.app", exists: intel.contains), "/usr/local")
    }
    func testOtherCopiesArentHomebrews() {
        let everything: Set = ["/opt/homebrew/Caskroom/tsukumo", "/opt/homebrew/bin/brew"]
        // Elsewhere than /Applications: a disk image, Downloads, a build folder.
        for path in ["/Volumes/Tsukumo/Tsukumo.app", "/Users/me/Downloads/Tsukumo.app", "/Users/me/Applications/Tsukumo.app"] {
            XCTAssertNil(HomebrewInstall.prefix(bundlePath: path, exists: everything.contains), path)
        }
        // In /Applications, but the Caskroom has no tsukumo (the DMG, or the old development copy).
        XCTAssertNil(HomebrewInstall.prefix(bundlePath: "/Applications/Tsukumo.app", exists: Set(["/opt/homebrew/bin/brew"]).contains))
        // A Caskroom entry without brew itself.
        XCTAssertNil(HomebrewInstall.prefix(bundlePath: "/Applications/Tsukumo.app", exists: Set(["/opt/homebrew/Caskroom/tsukumo"]).contains))
    }
    func testTheCommandNamesTheTapsCask() {
        XCTAssertEqual(HomebrewInstall.upgradeCommand(prefix: "/opt/homebrew"),
                       "/opt/homebrew/bin/brew update && /opt/homebrew/bin/brew upgrade --cask zlichtman/tap/tsukumo")
    }
    func testTheInstalledBuildIsReadFromDisk() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let contents = folder.appendingPathComponent("Tsukumo.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let app = folder.appendingPathComponent("Tsukumo.app").path
        XCTAssertNil(HomebrewInstall.installedBuild(at: app))
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleVersion": "73"], format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        XCTAssertEqual(HomebrewInstall.installedBuild(at: app), 73)
    }

    // MARK: Checking

    @MainActor func testCheckingOffersANewerBuildAndNotTheSameOne() async throws {
        let data = try feed([:])
        let updater = AppUpdater(defaults: try isolatedDefaults(), fetch: { _ in data }, homebrew: { nil })
        await updater.check(runningVersion: "1.0.0", runningBuild: 72)
        XCTAssertEqual(updater.phase, .available(try TsukumoRelease.parse(data)))
        XCTAssertTrue(updater.showsCard)
        XCTAssertFalse(updater.installedByHomebrew)
        let current = AppUpdater(defaults: try isolatedDefaults(), fetch: { _ in data }, homebrew: { nil })
        await current.check(runningVersion: "1.0.0", runningBuild: 73)
        XCTAssertEqual(current.phase, .upToDate)
        XCTAssertFalse(current.showsCard)
    }
    @MainActor func testACheckThatFailsSaysSo() async throws {
        let offline = AppUpdater(defaults: try isolatedDefaults(), fetch: { _ in throw URLError(.notConnectedToInternet) }, homebrew: { nil })
        await offline.check(runningVersion: "1.0.0", runningBuild: 72)
        guard case .failed = offline.phase else { return XCTFail("\(offline.phase)") }
        let garbled = AppUpdater(defaults: try isolatedDefaults(), fetch: { _ in Data("{}".utf8) }, homebrew: { nil })
        await garbled.check(runningVersion: "1.0.0", runningBuild: 72)
        XCTAssertEqual(garbled.phase, .failed("The update information wasn't readable. Try again later."))
    }
    @MainActor func testACopyNotFromHomebrewOffersTheDownload() async throws {
        let data = try feed([:])
        var opened: [URL] = []
        let updater = AppUpdater(defaults: try isolatedDefaults(), fetch: { _ in data }, homebrew: { nil }, openURL: { opened.append($0) })
        await updater.check(runningVersion: "1.0.0", runningBuild: 72)
        XCTAssertEqual(updater.updateTitle, "Download")
        updater.update(desktop: DesktopNavigation(defaults: try isolatedDefaults()))
        XCTAssertEqual(opened, [URL(string: "https://zlichtman.com/downloads/Tsukumo-1.0.0-73.dmg")!])
        // Nothing runs, and the offer stays until it's dismissed or the new build is running.
        guard case .available = updater.phase else { return XCTFail("\(updater.phase)") }
    }
    @MainActor func testHomebrewsCopyOffersUpdateWithHomebrew() async throws {
        let data = try feed([:])
        let updater = AppUpdater(defaults: try isolatedDefaults(), fetch: { _ in data }, homebrew: { "/opt/homebrew" }, openURL: { _ in XCTFail("opened a download") })
        await updater.check(runningVersion: "1.0.0", runningBuild: 72)
        XCTAssertTrue(updater.installedByHomebrew)
        XCTAssertEqual(updater.updateTitle, "Update with Homebrew")
        XCTAssertEqual(updater.phase, .available(try TsukumoRelease.parse(data)))
    }
    @MainActor func testABuildForANewerMacOSIsntOffered() async throws {
        let data = try feed(["minimumMacOS": "27.0"])
        let updater = AppUpdater(defaults: try isolatedDefaults(), fetch: { _ in data }, homebrew: { "/opt/homebrew" },
                                 system: OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
        await updater.check(runningVersion: "1.0.0", runningBuild: 72)
        XCTAssertEqual(updater.phase, .failed("Tsukumo 1.0.0 (73) needs macOS 27.0 or later."))
        XCTAssertFalse(updater.showsCard)
    }
    @MainActor func testDismissingHidesTheCardUntilANewerBuild() async throws {
        let defaults = try isolatedDefaults()
        let data = try feed([:])
        let updater = AppUpdater(defaults: defaults, fetch: { _ in data }, homebrew: { nil })
        await updater.check(runningVersion: "1.0.0", runningBuild: 72)
        updater.dismiss()
        XCTAssertEqual(updater.dismissedBuild, 73)
        await updater.check(runningVersion: "1.0.0", runningBuild: 72)
        XCTAssertFalse(updater.showsCard)
        let newer = try feed(["build": 74, "url": "https://zlichtman.com/downloads/Tsukumo-1.0.0-74.dmg"])
        let later = AppUpdater(defaults: defaults, fetch: { _ in newer }, homebrew: { nil })
        await later.check(runningVersion: "1.0.0", runningBuild: 72)
        XCTAssertTrue(later.showsCard)
    }

    private func isolatedDefaults() throws -> UserDefaults {
        let suite = "updater-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }
}
