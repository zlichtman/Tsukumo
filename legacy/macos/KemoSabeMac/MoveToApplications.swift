import AppKit
import Darwin
import Observation
import SwiftUI

/// Move to Applications (September 27, 2026). When Tsukumo opens from anywhere but Applications (the
/// downloaded disk image, Downloads, the Desktop, or a copy macOS runs from a hidden translocated
/// path), a themed page comes before the main window: Kemo at its desk, Tsukumo's icon and the
/// Applications folder joined by a moving pathway, and one "Move to Applications" button. Moving
/// copies the app into /Applications (an older copy there goes to the Trash, never deleted), clears
/// the download quarantine on that copy only, reopens it, quits this one, and ejects the disk image.
/// "Not now" carries on into the app and asks again after a week. The launch hook in
/// `KemoSabeMacApp` is one call to `offer`; everything else lives here.
enum MoveToApplications {
    static let bundleName = "Tsukumo.app"
    static let applications = URL(fileURLWithPath: "/Applications", isDirectory: true)
    static let snoozeKey = "moveToApplications.notNowAt"
    static let snoozeInterval: TimeInterval = 7 * 24 * 60 * 60
    /// DEBUG only: shows the page from anywhere (a build folder, UI tests) and moves into a
    /// temporary folder instead of /Applications, without reopening, quitting, or ejecting.
    static let forceArgument = "--show-move-to-applications"
    static let quarantineAttribute = "com.apple.quarantine"

    // MARK: Where Tsukumo runs from

    enum Kind: Equatable { case installed, buildProducts, volume, downloads, elsewhere }

    struct Placement: Equatable {
        var kind: Kind
        /// macOS runs a quarantined app that hasn't been moved from a hidden read-only copy.
        var translocated = false
        /// The mounted volume it runs from (`/Volumes/<name>`), for ejecting a disk image afterwards.
        var volume: URL?
        /// Installed copies and build folders (Xcode's DerivedData, release scripts) are never asked.
        var offersMove: Bool { kind != .installed && kind != .buildProducts }
    }

    /// Where `bundle` counts as running from. For a translocated copy, `original` is where the person
    /// actually opened it (from `SecTranslocateCreateOriginalPathForURL`); when that's unknown, it's
    /// somewhere other than Applications.
    static func placement(of bundle: URL, original: URL? = nil, translocated: Bool = false, home: URL) -> Placement {
        let isTranslocated = translocated || looksTranslocated(bundle)
        guard let url = isTranslocated ? original : bundle else { return .init(kind: .elsewhere, translocated: true) }
        let path = url.standardizedFileURL.path
        let home = home.standardizedFileURL.path
        func under(_ folder: String) -> Bool { path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") }
        if path.contains("/Build/Products/") || path.contains("/DerivedData/") { return .init(kind: .buildProducts, translocated: isTranslocated) }
        if under("/Applications") || under(home + "/Applications") { return .init(kind: .installed, translocated: isTranslocated) }
        if under("/Volumes") {
            let name = path.dropFirst("/Volumes/".count).split(separator: "/", maxSplits: 1).first.map(String.init) ?? ""
            return .init(kind: .volume, translocated: isTranslocated, volume: name.isEmpty ? nil : URL(fileURLWithPath: "/Volumes/" + name, isDirectory: true))
        }
        if under(home + "/Downloads") { return .init(kind: .downloads, translocated: isTranslocated) }
        return .init(kind: .elsewhere, translocated: isTranslocated)
    }

    /// App Translocation's hidden mount point, the fallback when Security's SPI isn't there.
    static func looksTranslocated(_ url: URL) -> Bool { url.path.contains("/AppTranslocation/") }

    /// Whether `url` is translocated and, if so, its original path, through Security's
    /// `SecTranslocateIsTranslocatedURL` and `SecTranslocateCreateOriginalPathForURL` (looked up at
    /// runtime, as LetsMove does, since they aren't in the public headers).
    static func translocation(of url: URL) -> (translocated: Bool, original: URL?) {
        typealias IsTranslocated = @convention(c) (CFURL, UnsafeMutablePointer<Bool>, UnsafeMutableRawPointer?) -> UInt8
        typealias CreateOriginal = @convention(c) (CFURL, UnsafeMutableRawPointer?) -> Unmanaged<CFURL>?
        guard let handle = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY),
              let isSymbol = dlsym(handle, "SecTranslocateIsTranslocatedURL"),
              let originalSymbol = dlsym(handle, "SecTranslocateCreateOriginalPathForURL") else { return (looksTranslocated(url), nil) }
        let isTranslocated = unsafeBitCast(isSymbol, to: IsTranslocated.self)
        let createOriginal = unsafeBitCast(originalSymbol, to: CreateOriginal.self)
        var flag = false
        guard isTranslocated(url as CFURL, &flag, nil) != 0 else { return (looksTranslocated(url), nil) }
        guard flag else { return (false, nil) }
        return (true, createOriginal(url as CFURL, nil)?.takeRetainedValue() as URL?)
    }

    /// Where this copy of Tsukumo runs from.
    static func current(bundle: URL = Bundle.main.bundleURL) -> Placement {
        let translocation = translocation(of: bundle)
        return placement(of: bundle, original: translocation.original, translocated: translocation.translocated,
                         home: FileManager.default.homeDirectoryForCurrentUser)
    }

    // MARK: When to ask

    /// A forced DEBUG launch always shows the page; tests and UI tests never do otherwise; an
    /// installed copy or a build folder is never asked; and "Not now" holds for a week.
    static func shouldOffer(_ placement: Placement, forced: Bool, uiTesting: Bool, testHost: Bool, snoozedAt: Date?, now: Date) -> Bool {
        if forced { return true }
        if testHost || uiTesting || !placement.offersMove { return false }
        return !isSnoozed(since: snoozedAt, now: now)
    }
    static func isSnoozed(since: Date?, now: Date) -> Bool {
        guard let since else { return false }
        return abs(now.timeIntervalSince(since)) < snoozeInterval
    }
    static func snoozedAt(_ defaults: UserDefaults) -> Date? { defaults.object(forKey: snoozeKey) as? Date }
    static func snooze(_ defaults: UserDefaults, now: Date = Date()) { defaults.set(now, forKey: snoozeKey) }

    // MARK: Installing

    enum Plan: Equatable { case install, replace(existing: Int?) }
    /// Nothing there yet, or a copy (with its build, when it has one) that would go to the Trash.
    static func plan(destination: URL) -> Plan {
        FileManager.default.fileExists(atPath: destination.path) ? .replace(existing: build(of: destination)) : .install
    }
    /// A bundle's build number, read from its Info.plist (`Bundle(url:)` caches, and a replaced copy
    /// at the same path would read stale).
    static func build(of app: URL) -> Int? {
        guard let data = try? Data(contentsOf: app.appendingPathComponent("Contents/Info.plist")),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return Int(info["CFBundleVersion"] as? String ?? "")
    }
    /// The confirmation before replacing the copy in Applications.
    static func replacePrompt(existing: Int?, current: Int, running: Bool) -> (title: String, detail: String) {
        var detail: String
        switch existing {
        case let existing? where existing > current:
            detail = "The one there is newer (build \(existing)) than this one (build \(current)). It goes to the Trash."
        case let existing? where existing == current:
            detail = "The one there is the same build (\(current)). It goes to the Trash."
        case let existing?:
            detail = "The one there is build \(existing) and this one is build \(current). The older copy goes to the Trash."
        case nil:
            detail = "The copy there goes to the Trash."
        }
        if running { detail += " It's open now, so it quits first." }
        return ("Replace the Tsukumo in Applications?", detail)
    }

    enum Route: Equatable { case direct, administrator }
    /// Straight in when this account can write to Applications (and move any copy there); otherwise
    /// through the administrator prompt.
    static func route(applications: URL, destination: URL) -> Route {
        let files = FileManager.default
        guard files.isWritableFile(atPath: applications.path) else { return .administrator }
        if files.fileExists(atPath: destination.path), !files.isWritableFile(atPath: destination.path) { return .administrator }
        return .direct
    }

    struct Failure: Error, Equatable {
        let message: String
        var cancelled = false
    }

    /// Copies an app into a folder: to a hidden name first, so a failed copy never touches what's
    /// there; then the old copy goes to the Trash and the new one takes its name.
    struct Installer: Sendable {
        var applications: URL
        var trash: @Sendable (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
        var destination: URL { applications.appendingPathComponent(MoveToApplications.bundleName) }
        func install(from source: URL) throws -> URL {
            let files = FileManager.default
            try files.createDirectory(at: applications, withIntermediateDirectories: true)
            let staging = applications.appendingPathComponent(".Tsukumo-moving-\(UUID().uuidString).app")
            do {
                try MoveToApplications.run("/usr/bin/ditto", [source.path, staging.path])
                MoveToApplications.removeQuarantine(staging)
                if files.fileExists(atPath: destination.path) { try trash(destination) }
                try files.moveItem(at: staging, to: destination)
            } catch {
                // Only the partial copy this made, never the app that was there.
                if files.fileExists(atPath: staging.path) { try? files.removeItem(at: staging) }
                throw (error as? Failure) ?? Failure(message: "Tsukumo couldn't be copied into Applications.")
            }
            return destination
        }
    }

    /// Clears the download quarantine from every file in `root` (the copy this made, only), so the
    /// copy in Applications opens in place instead of being translocated again.
    static func removeQuarantine(_ root: URL) {
        func strip(_ path: String) { _ = removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) }
        strip(root.path)
        guard let files = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let relative as String in files { strip(root.appendingPathComponent(relative).path) }
    }
    static func isQuarantined(_ url: URL) -> Bool { getxattr(url.path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }

    static func shellQuoted(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// The shell steps the administrator prompt runs: the same staging, Trash, and quarantine steps
    /// as `Installer`, then the copy is given back to this account so its updater can replace it.
    static func administratorCommand(source: URL, destination: URL, trashed: URL, owner: String) -> String {
        let staging = shellQuoted(destination.deletingLastPathComponent().appendingPathComponent(".Tsukumo-moving-\(UUID().uuidString).app").path)
        let target = shellQuoted(destination.path)
        return [
            "set -e",
            "/usr/bin/ditto \(shellQuoted(source.path)) \(staging) || { /bin/rm -rf \(staging); exit 1; }",
            "/usr/bin/xattr -dr \(quarantineAttribute) \(staging) 2>/dev/null || true",
            "/usr/sbin/chown -R \(owner) \(staging)",
            "if [ -e \(target) ]; then /bin/mv \(target) \(shellQuoted(trashed.path)); fi",
            "/bin/mv \(staging) \(target)",
        ].joined(separator: "; ")
    }

    /// Runs `administratorCommand` behind the standard administrator prompt.
    @MainActor static func installAsAdministrator(source: URL, applications: URL) -> Result<URL, Failure> {
        let destination = applications.appendingPathComponent(bundleName)
        let stamp = Int(Date().timeIntervalSince1970)
        let trashed = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".Trash/Tsukumo-\(build(of: destination).map { "b\($0)" } ?? "old")-\(stamp).app")
        let command = administratorCommand(source: source, destination: destination, trashed: trashed, owner: "\(getuid()):\(getgid())")
        let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        var error: NSDictionary?
        _ = NSAppleScript(source: "do shell script \"\(escaped)\" with administrator privileges")?.executeAndReturnError(&error)
        guard let error else { return .success(destination) }
        if (error[NSAppleScript.errorNumber] as? Int) == -128 {
            return .failure(.init(message: "Moving into Applications needs an administrator's password. Tsukumo wasn't moved.", cancelled: true))
        }
        return .failure(.init(message: "Tsukumo couldn't be copied into Applications."))
    }

    /// Quits another running Tsukumo from `destination` (the copy being replaced), waiting up to 5 s.
    @MainActor static func runningCopies(at destination: URL) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            $0 != NSRunningApplication.current && $0.bundleURL?.standardizedFileURL == destination.standardizedFileURL
        }
    }
    @MainActor static func quitRunningCopies(at destination: URL) async -> Bool {
        let running = runningCopies(at: destination)
        guard !running.isEmpty else { return true }
        running.forEach { $0.terminate() }
        for _ in 0..<25 {
            if running.allSatisfy(\.isTerminated) { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return running.allSatisfy(\.isTerminated)
    }

    // MARK: Disk images

    /// The mount points `hdiutil info -plist` lists for attached disk images.
    static func diskImageMountPoints(_ info: Data) -> [String] {
        guard let plist = try? PropertyListSerialization.propertyList(from: info, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.flatMap { ($0["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String } }
    }
    /// Whether `volume` is a mounted disk image (and not, say, an external drive someone keeps apps on).
    static func isDiskImage(_ volume: URL) -> Bool {
        guard let info = try? output("/usr/bin/hdiutil", ["info", "-plist"]) else { return false }
        let path = volume.standardizedFileURL.path
        return diskImageMountPoints(info).contains { URL(fileURLWithPath: $0).standardizedFileURL.path == path }
    }

    // MARK: Reopening

    /// Waits for this process to exit, opens the copy in Applications, then ejects the disk image it
    /// came from (retrying while the old process's translocated mount lets go).
    static let relaunchScript = """
    while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
    /usr/bin/open "$2"
    [ -z "$3" ] && exit 0
    sleep 1
    for attempt in 1 2 3 4 5; do /usr/bin/hdiutil detach "$3" -quiet && exit 0; sleep 2; done
    """
    @MainActor static func relaunch(_ app: URL, eject volume: URL?) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "tsukumo-move", String(ProcessInfo.processInfo.processIdentifier), app.path, volume?.path ?? ""]
        try process.run()
        NSApp.terminate(nil)
    }

    // MARK: Processes

    static func run(_ tool: String, _ arguments: [String]) throws { _ = try output(tool, arguments) }
    @discardableResult static func output(_ tool: String, _ arguments: [String]) throws -> Data {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure(message: "Tsukumo couldn't be copied into Applications.") }
        return data
    }

    // MARK: The launch hook

    @MainActor private static var offeredThisLaunch = false
    @MainActor private static var presenter: MoveToApplicationsPresenter?

    /// Shows the page when this copy should move, and returns true; `then` carries on the launch
    /// after "Not now" (or after a forced DEBUG run). Returns false, once and for all this launch,
    /// when there's nothing to ask.
    @MainActor static func offer(theme: BotTheme, preferences: DesktopPreferences, defaults: UserDefaults = .standard, then: @escaping () -> Void) -> Bool {
        guard !offeredThisLaunch else { return false }
        offeredThisLaunch = true
        let arguments = ProcessInfo.processInfo.arguments
        #if DEBUG
        let forced = arguments.contains(forceArgument)
        #else
        let forced = false
        #endif
        let placement = current()
        guard shouldOffer(placement, forced: forced, uiTesting: arguments.contains("--ui-testing"), testHost: KemoSabeMacApp.isTestHost,
                          snoozedAt: snoozedAt(defaults), now: Date()) else { return false }
        let target = forced ? FileManager.default.temporaryDirectory.appendingPathComponent("TsukumoMoveToApplications/Applications", isDirectory: true) : applications
        let presenter = MoveToApplicationsPresenter(placement: placement, applications: target, dryRun: forced, theme: theme,
                                                    preferences: preferences, defaults: defaults) {
            Self.presenter = nil
            then()
        }
        Self.presenter = presenter
        presenter.show()
        return true
    }
}

// MARK: - The page's state

@MainActor @Observable final class MoveToApplicationsModel {
    enum Phase: Equatable { case offer, moving, moved, failed(String) }
    var phase: Phase = .offer
    /// When the app icon set off along the pathway into the folder.
    var travelStart: Date?
    var movedNote = "It's in Applications now."
    var move: () -> Void = {}
    var notNow: () -> Void = {}
    /// Snapshot tests hold the pathway's clock still.
    var frozenClock: Double?
    static let tripDuration = 1.3

    var title: String {
        switch phase {
        case .moving: "Moving Tsukumo…"
        case .moved: "Moved. Opening Tsukumo…"
        default: "Move Tsukumo to Applications"
        }
    }
    var subtitle: String {
        phase == .moved ? movedNote : "So it can update itself and keep your agents' sign-ins in one place."
    }
    /// Kemo at its desk: coding while it waits, running the move, then done.
    var performance: String {
        switch phase {
        case .moving: "executing"
        case .moved: "done"
        default: "coding"
        }
    }
    var failure: String? { if case .failed(let message) = phase { message } else { nil } }
    var busy: Bool { phase == .moving || phase == .moved }
    /// How far along the pathway the icon is, 0 to 1, or nil while it waits at the start.
    func trip(at date: Date) -> Double? {
        if phase == .moved { return 1 }
        guard phase == .moving, let travelStart else { return nil }
        return min(1, max(0, date.timeIntervalSince(travelStart) / Self.tripDuration))
    }
}

// MARK: - The window

@MainActor final class MoveToApplicationsPresenter: NSObject, NSWindowDelegate {
    static let size = NSSize(width: 720, height: 520)
    let model = MoveToApplicationsModel()
    private let placement: MoveToApplications.Placement
    private let applications: URL
    private let dryRun: Bool
    private let defaults: UserDefaults
    private let preferences: DesktopPreferences
    private let theme: BotTheme
    private let then: () -> Void
    private var window: NSWindow?
    private var finished = false

    init(placement: MoveToApplications.Placement, applications: URL, dryRun: Bool, theme: BotTheme,
         preferences: DesktopPreferences, defaults: UserDefaults, then: @escaping () -> Void) {
        self.placement = placement; self.applications = applications; self.dryRun = dryRun
        self.theme = theme; self.preferences = preferences; self.defaults = defaults; self.then = then
        super.init()
        model.move = { [weak self] in self?.move() }
        model.notNow = { [weak self] in self?.notNow() }
    }

    func show() {
        let window = NSWindow(contentRect: .init(origin: .zero, size: Self.size), styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = KemoSabeMacApp.appName; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true; window.isReleasedWhenClosed = false; window.delegate = self
        // One close button: the traffic lights' close, which is "Not now".
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        switch preferences.colorMode {
        case .dark: window.appearance = NSAppearance(named: .darkAqua)
        case .light: window.appearance = NSAppearance(named: .aqua)
        case .system: break
        }
        let dark = window.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        window.backgroundColor = NSColor(preferences.palette(dark ? .dark : .light).background)
        window.contentView = NSHostingView(rootView: MoveToApplicationsPage(model: model, theme: theme).environment(preferences))
        window.setContentSize(Self.size)
        window.center()
        self.window = window
        installMenu()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Hide and Quit while the page is up; the app's own menu replaces this when the launch carries on.
    private func installMenu() {
        let main = NSMenu(), appItem = NSMenuItem(), menu = NSMenu(title: KemoSabeMacApp.appName)
        menu.addItem(withTitle: "Hide " + KemoSabeMacApp.appName, action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        menu.addItem(withTitle: "Quit " + KemoSabeMacApp.appName, action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = menu; main.addItem(appItem)
        NSApp.mainMenu = main
    }

    /// Not while it's moving: the launch carries on from the move's own end.
    func windowShouldClose(_ sender: NSWindow) -> Bool { !model.busy }
    func windowWillClose(_ notification: Notification) {
        // The close button is "Not now"; closing after a move (or while quitting to reopen) isn't.
        if !finished { notNow(closing: false) }
    }

    private func notNow(closing: Bool = true) {
        guard !finished, !model.busy else { return }
        if !dryRun { MoveToApplications.snooze(defaults) }
        finish(closing: closing)
    }

    private func finish(closing: Bool = true) {
        guard !finished else { return }
        finished = true
        if closing { window?.close() }
        window = nil
        then()
    }

    private func move() {
        guard !model.busy, let window else { return }
        let destination = applications.appendingPathComponent(MoveToApplications.bundleName)
        guard case .replace(let existing) = MoveToApplications.plan(destination: destination) else {
            Task { await perform(destination) }; return
        }
        let prompt = MoveToApplications.replacePrompt(existing: existing, current: AppUpdater.currentBuild,
                                                      running: !MoveToApplications.runningCopies(at: destination).isEmpty)
        let alert = NSAlert()
        alert.messageText = prompt.title; alert.informativeText = prompt.detail
        alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { @MainActor in await self?.perform(destination) }
        }
    }

    private func perform(_ destination: URL) async {
        let started = Date()
        model.phase = .moving; model.travelStart = started
        let source = Bundle.main.bundleURL
        let volume = placement.volume
        async let diskImage: URL? = Task.detached { volume.flatMap { MoveToApplications.isDiskImage($0) ? $0 : nil } }.value
        if !dryRun, !(await MoveToApplications.quitRunningCopies(at: destination)) {
            fail("Quit the Tsukumo that's open from Applications, then try again."); return
        }
        var result: Result<URL, MoveToApplications.Failure>
        switch MoveToApplications.route(applications: applications, destination: destination) {
        case .direct:
            result = await Self.install(from: source, into: applications)
        case .administrator:
            result = MoveToApplications.installAsAdministrator(source: source, applications: applications)
            // An administrator copy that failed (not one the person cancelled) goes to the
            // Applications folder in the home folder instead.
            if case .failure(let failure) = result, !failure.cancelled {
                let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
                result = await Self.install(from: source, into: home)
                model.movedNote = "It's in the Applications folder in your home folder, since this Mac needs an administrator to change Applications."
            }
        }
        // Let the icon finish its trip into the folder.
        let remaining = MoveToApplicationsModel.tripDuration + 0.2 - Date().timeIntervalSince(started)
        if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)) }
        switch result {
        case .failure(let failure):
            fail(failure.message)
        case .success(let app):
            model.phase = .moved
            let eject = await diskImage
            try? await Task.sleep(for: .seconds(1.1))
            if dryRun { finish(); return }
            finished = true
            do { try MoveToApplications.relaunch(app, eject: eject) }
            catch { finished = false; fail("Tsukumo was moved but couldn't reopen. Open it from Applications.") }
        }
    }

    private static func install(from source: URL, into folder: URL) async -> Result<URL, MoveToApplications.Failure> {
        await Task.detached { () -> Result<URL, MoveToApplications.Failure> in
            do { return .success(try MoveToApplications.Installer(applications: folder).install(from: source)) }
            catch { return .failure((error as? MoveToApplications.Failure) ?? .init(message: "Tsukumo couldn't be copied into Applications.")) }
        }.value
    }

    private func fail(_ message: String) {
        model.travelStart = nil
        model.phase = .failed(message)
    }
}

// MARK: - The page

struct MoveToApplicationsPage: View {
    let model: MoveToApplicationsModel
    let theme: BotTheme
    /// Tsukumo's bundled icon and the Applications folder's own icon unless a test passes others.
    var appIcon: NSImage?
    var folderIcon: NSImage?
    /// Snapshot tests set this; the app follows the person's setting.
    var reduceMotionOverride: Bool?
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool {
        reduceMotionOverride ?? (preferences.followReduceMotion ? systemReduceMotion : preferences.reduceMotion)
    }

    var body: some View {
        let palette = preferences.palette(scheme)
        VStack(spacing: 0) {
            // Centered below the traffic lights' row.
            Spacer(minLength: 28)
            ArtworkCompanion(theme: theme, performance: model.performance, reducedMotion: reduceMotion, active: true)
                .frame(width: 128, height: 128)
                .accessibilityHidden(true).accessibilityIdentifier("moveToApplications.kemo")
            MoveToApplicationsPathway(model: model, accent: palette.accent,
                                      appIcon: appIcon ?? DesktopIconArtwork.bundledIcon() ?? NSApp.applicationIconImage,
                                      folderIcon: folderIcon ?? NSWorkspace.shared.icon(forFile: "/Applications"), reduceMotion: reduceMotion)
                .frame(width: MoveToApplicationsPathway.size.width, height: MoveToApplicationsPathway.size.height)
            VStack(spacing: 8) {
                Text(model.title).font(.system(size: 24, weight: .semibold)).accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("moveToApplications.title")
                Text(model.subtitle).font(.system(size: 13)).foregroundStyle(palette.foreground.opacity(0.65))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .multilineTextAlignment(.center).frame(maxWidth: 460).padding(.top, 14)
            .contentTransition(.opacity)
            actions(accent: palette.accent).padding(.top, 22)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(palette.foreground)
        .background(palette.background)
        .animation(reduceMotion ? .easeInOut(duration: 0.35) : .easeOut(duration: 0.2), value: model.phase)
        .accessibilityIdentifier("moveToApplications")
    }

    private func actions(accent: Color) -> some View {
        VStack(spacing: 10) {
            Button(action: model.move) {
                Text("Move to Applications").font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(minWidth: 220).padding(.vertical, 9)
                    .background(accent, in: Capsule()).contentShape(Capsule())
            }
            .buttonStyle(.plain).keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("moveToApplications.move")
            Button("Not now", action: model.notNow)
                .buttonStyle(.plain).font(.system(size: 13)).foregroundStyle(.secondary)
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("moveToApplications.notNow")
            Text(model.failure ?? " ").font(.system(size: 12)).foregroundStyle(.orange)
                .multilineTextAlignment(.center).frame(maxWidth: 460).opacity(model.failure == nil ? 0 : 1)
                .accessibilityHidden(model.failure == nil)
        }
        // Kept in place while moving so nothing jumps; hidden once it's moved.
        .disabled(model.busy).opacity(model.phase == .moved ? 0 : model.busy ? 0.45 : 1)
    }
}

/// Tsukumo's icon and the Applications folder, joined by an arc of coral dashes that march toward
/// the folder with a glowing dot riding along. Moving, the icon follows the arc into the folder,
/// shrinking as it goes, and the folder gives a small bump as it lands. With Reduce Motion, the path
/// holds still, there's no dot, and the icon crossfades into the folder instead of travelling.
struct MoveToApplicationsPathway: View {
    let model: MoveToApplicationsModel
    let accent: Color
    let appIcon: NSImage
    let folderIcon: NSImage
    let reduceMotion: Bool
    static let size = CGSize(width: 460, height: 128)
    static let start = CGPoint(x: 54, y: 82), end = CGPoint(x: 406, y: 82), control = CGPoint(x: 230, y: -6)
    static let iconSide: CGFloat = 72
    /// The dashed stretch between the two icons, as fractions of the arc.
    static let span = (from: 0.15, to: 0.85)

    static func point(_ t: Double) -> CGPoint {
        let u = 1 - t
        return .init(x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
                     y: u * u * start.y + 2 * u * t * control.y + t * t * end.y)
    }
    static var arc: Path {
        var path = Path(); path.move(to: start); path.addQuadCurve(to: end, control: control); return path
    }
    static func ease(_ t: Double) -> Double { t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2 }

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || model.phase == .moved)) { tick in
            let clock = model.frozenClock ?? tick.date.timeIntervalSinceReferenceDate
            let trip = model.trip(at: model.frozenClock.map { Date(timeIntervalSinceReferenceDate: $0) } ?? tick.date)
            ZStack(alignment: .topLeading) {
                track(clock: clock)
                if !reduceMotion, trip == nil { glow(clock: clock) }
                folder(trip: trip)
                icon(trip: trip)
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.phase == .moved ? "Tsukumo is in Applications" : "Tsukumo, then the Applications folder")
    }

    private func track(clock: Double) -> some View {
        let arc = Self.arc.trimmedPath(from: Self.span.from, to: Self.span.to)
        let phase = reduceMotion ? 0 : -CGFloat((clock * 22).truncatingRemainder(dividingBy: 14))
        return ZStack {
            arc.stroke(accent.opacity(0.14), style: StrokeStyle(lineWidth: 8, lineCap: .round))
            arc.stroke(accent, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, dash: [6, 8], dashPhase: phase))
        }
    }

    private func glow(clock: Double) -> some View {
        let cycle = (clock / 2.2).truncatingRemainder(dividingBy: 1)
        let point = Self.point(Self.span.from + (Self.span.to - Self.span.from) * cycle)
        return Circle().fill(accent).frame(width: 9, height: 9)
            .shadow(color: accent.opacity(0.9), radius: 6).shadow(color: accent.opacity(0.5), radius: 12)
            .opacity(sin(.pi * cycle))
            .position(point)
    }

    private func folder(trip: Double?) -> some View {
        // A small bump as the icon lands.
        let landing = trip.map { max(0, ($0 - 0.8) / 0.2) } ?? 0
        let bump = reduceMotion ? 0 : sin(.pi * landing) * 0.1
        return ZStack(alignment: .bottomTrailing) {
            Image(nsImage: folderIcon).resizable().interpolation(.high).frame(width: Self.iconSide, height: Self.iconSide)
            if model.phase == .moved {
                Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                    .frame(width: 22, height: 22).background(accent, in: Circle())
                    .transition(.opacity).offset(x: 2, y: 2)
            }
        }
        .scaleEffect(1 + bump)
        .position(Self.end)
    }

    @ViewBuilder private func icon(trip: Double?) -> some View {
        let image = Image(nsImage: appIcon).resizable().interpolation(.high).frame(width: Self.iconSide, height: Self.iconSide)
        if reduceMotion {
            // A crossfade: the icon fades out where it is while the folder takes it.
            image.opacity(trip == nil ? 1 : 0).position(Self.start)
        } else {
            let t = Self.ease(trip ?? 0)
            image.scaleEffect(1 - 0.5 * t)
                .opacity(trip.map { $0 < 0.82 ? 1 : max(0, 1 - ($0 - 0.82) / 0.18) } ?? 1)
                .position(Self.point(t))
        }
    }
}
