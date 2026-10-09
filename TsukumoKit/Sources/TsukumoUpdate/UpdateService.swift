#if os(macOS)
import Foundation
import Observation

/// The running copy of Tsukumo, and whether it may update itself at all.
public struct UpdateEnvironment: Sendable {
    public var bundleIdentifier: String?
    public var version: String
    public var build: Int
    public var bundleURL: URL
    public var arguments: [String]
    public var isDebugBuild: Bool

    public init(bundleIdentifier: String?, version: String, build: Int, bundleURL: URL, arguments: [String], isDebugBuild: Bool) {
        self.bundleIdentifier = bundleIdentifier; self.version = version; self.build = build; self.bundleURL = bundleURL
        self.arguments = arguments; self.isDebugBuild = isDebugBuild
    }

    /// The main bundle and this process's arguments.
    public static func main(isDebugBuild: Bool) -> UpdateEnvironment {
        let bundle = Bundle.main
        return UpdateEnvironment(bundleIdentifier: bundle.bundleIdentifier,
                                 version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                                 build: Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "") ?? 0,
                                 bundleURL: bundle.bundleURL, arguments: CommandLine.arguments, isDebugBuild: isDebugBuild)
    }

    /// Arguments of runs that must never check or install: tests, the demo, pictures, and smoke checks.
    public static let quietArguments: Set<String> = ["--ui-testing", "--demo", "--capture", "--voice-check", "--gateway-smoke", "--relay-smoke", "--onboarding"]

    /// Why this copy doesn't update itself, or nil when it does: Debug builds, test, demo and capture runs,
    /// and any copy that isn't Tsukumo's Dock never check or install.
    public func offReason(identity: UpdateIdentity = .tsukumo) -> String? {
        if isDebugBuild { return "Updates are off in Debug builds." }
        if arguments.contains(where: Self.quietArguments.contains) { return "Updates are off in test and demo runs." }
        if bundleIdentifier != identity.bundleIdentifier || build <= 0 { return "Updates are off in this copy of Tsukumo." }
        return nil
    }
}


/// A build this Mac can't run, remembered only after its signature passed (never from the feed's word):
/// keyed by its build, its DMG's SHA-256, this macOS version, and this architecture, for at most 7 days.
public struct UnrunnableBuild: Codable, Equatable, Sendable {
    public let build: Int
    public let sha256: String
    public let osVersion: String
    public let cpuType: Int32
    public let recorded: Date
    public static let lifetime: TimeInterval = 7 * 24 * 60 * 60
}

/// Set when the owner or the app stops update work; checked before anything is committed.
final class UpdateCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Tsukumo's Dock's software update: checks tsukumo.json on zlichtman.com a few seconds after launch and every
/// six hours while it runs (when Check automatically is on, the default), and when the owner asks. A newer
/// build is downloaded when the owner clicks Download, or by itself when Download updates automatically is on
/// (off by default). The download is checked from end to end (`UpdateVerifier`) before it's offered as
/// "Ready to install", and installs only when the owner clicks Install and Relaunch, under the install lock,
/// with every check run again before and after the swap and before the relaunch.
@MainActor @Observable public final class UpdateService {
    public enum Status: Equatable, Sendable {
        case idle
        case off(String)
        case checking
        case upToDate
        case available(UpdateFeed)
        case downloading(UpdateFeed)
        case ready(UpdateFeed)
        case installing(UpdateFeed)
        case failed(String)
        case notice(String)

        /// The status line in Settings.
        public var title: String {
            switch self {
            case .idle: "Tsukumo checks for updates on zlichtman.com."
            case .off(let why): why
            case .checking: "Checking…"
            case .upToDate: "Up to date"
            case .available(let feed): "Version \(feed.version) is available"
            case .downloading(let feed): "Downloading \(feed.version)…"
            case .ready(let feed): "Version \(feed.version) is ready to install"
            case .installing(let feed): "Installing \(feed.version)…"
            case .failed(let why), .notice(let why): why
            }
        }

        /// The update's notes, while one is offered.
        public var notes: String? {
            switch self {
            case .available(let feed), .downloading(let feed), .ready(let feed), .installing(let feed): feed.notes.isEmpty ? nil : feed.notes
            default: nil
            }
        }

        public var isBusy: Bool {
            switch self {
            case .checking, .downloading, .installing: true
            default: false
            }
        }

        public var isFailure: Bool { if case .failed = self { true } else { false } }
    }

    public private(set) var status: Status
    /// When the last check finished (shown under the status).
    public private(set) var lastChecked: Date?
    /// The verified download is kept so the owner can open it by hand when Tsukumo can't replace itself.
    public private(set) var canOpenDownload = false

    public var checksAutomatically: Bool {
        didSet { defaults.set(checksAutomatically, forKey: Keys.check) }
    }
    public var downloadsAutomatically: Bool {
        didSet {
            defaults.set(downloadsAutomatically, forKey: Keys.download)
            if downloadsAutomatically, case .available = status { work = Task { [weak self] in await self?.download() } }
        }
    }

    public let environment: UpdateEnvironment
    public var isEnabled: Bool { environment.offReason(identity: identity) == nil }

    /// Tells the owner an update is ready (the app posts a notification only if notifications are allowed).
    @ObservationIgnored public var onReady: ((UpdateFeed) -> Void)?
    /// Opens the kept DMG (the app uses NSWorkspace).
    @ObservationIgnored public var openFile: ((URL) -> Void)?
    /// Quits so the helper can reopen the new copy (the app calls NSApp.terminate).
    @ObservationIgnored public var quit: (() -> Void)?

    enum Keys {
        static let check = "updates.checkAutomatically"
        static let download = "updates.downloadAutomatically"
        static let lastCheck = "updates.lastCheck"
        static let unrunnable = "updates.unrunnable"
        static let keptOldCopy = "updates.keptOldCopy"
    }

    /// The install lock's file, in the app's Application Support folder.
    public static let standardLockFile = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Tsukumo", isDirectory: true).appendingPathComponent("update.lock")

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let transport: any UpdateTransport
    @ObservationIgnored private let identity: UpdateIdentity
    @ObservationIgnored private let signature: any SignatureChecking
    @ObservationIgnored private let osVersion: OperatingSystemVersion
    @ObservationIgnored private let cpuType: Int32
    @ObservationIgnored private let installer: UpdateInstaller
    @ObservationIgnored private let workFolder: URL
    @ObservationIgnored private let lockFile: URL
    @ObservationIgnored private let relaunch: @Sendable (URL) throws -> Void
    @ObservationIgnored private let locationProblem: @Sendable (URL) -> UpdateFailure?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var launchCheck: Task<Void, Never>?
    @ObservationIgnored private var work: Task<Void, Never>?
    /// Cancels the detached staging or install task while one runs.
    @ObservationIgnored private var cancelDetached: (() -> Void)?
    @ObservationIgnored private var cancellation = UpdateCancellation()
    /// Held from the install until this process exits, so no other copy installs meanwhile.
    @ObservationIgnored private var installLock: UpdateLock?
    @ObservationIgnored private var staged: (feed: UpdateFeed, app: URL, root: URL, diskImage: URL)?

    public init(environment: UpdateEnvironment, defaults: UserDefaults = .standard, transport: any UpdateTransport = HTTPSUpdateTransport(),
                identity: UpdateIdentity = .tsukumo, signature: any SignatureChecking = CodeSignatureChecker(),
                osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion, cpuType: Int32 = UpdateVerifier.hostCPUType,
                installer: UpdateInstaller = UpdateInstaller(),
                workFolder: URL = FileManager.default.temporaryDirectory.appendingPathComponent("TsukumoUpdate", isDirectory: true),
                lockFile: URL = UpdateService.standardLockFile,
                relaunch: @escaping @Sendable (URL) throws -> Void = { _ = try UpdateInstaller.relaunch($0) },
                locationProblem: @escaping @Sendable (URL) -> UpdateFailure? = { InstallLocation.problem(for: $0) }) {
        self.environment = environment
        self.defaults = defaults
        self.transport = transport
        self.identity = identity
        self.signature = signature
        self.osVersion = osVersion
        self.cpuType = cpuType
        self.installer = installer
        self.workFolder = workFolder
        self.lockFile = lockFile
        self.relaunch = relaunch
        self.locationProblem = locationProblem
        defaults.register(defaults: [Keys.check: true, Keys.download: false])
        checksAutomatically = defaults.bool(forKey: Keys.check)
        downloadsAutomatically = defaults.bool(forKey: Keys.download)
        lastChecked = defaults.object(forKey: Keys.lastCheck) as? Date
        status = environment.offReason(identity: identity).map { .off($0) } ?? .idle
        // The previous version, when the Trash refused it during the last install, is pointed out once.
        if isEnabled, let kept = defaults.string(forKey: Keys.keptOldCopy) {
            defaults.removeObject(forKey: Keys.keptOldCopy)
            if FileManager.default.fileExists(atPath: kept) {
                status = .notice("The previous version is still at \(kept). You can move it to the Trash.")
            }
        }
    }

    private var verifier: UpdateVerifier {
        UpdateVerifier(identity: identity, runningBuild: environment.build, osVersion: osVersion, cpuType: cpuType, signature: signature)
    }

    private var osText: String { "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)" }

    /// The remembered build this Mac can't run, while it still applies: the same macOS version and
    /// architecture, and less than 7 days old. Anything else is cleared.
    public func unrunnable(now: Date = Date()) -> UnrunnableBuild? {
        guard let data = defaults.data(forKey: Keys.unrunnable),
              let record = try? JSONDecoder().decode(UnrunnableBuild.self, from: data) else { return nil }
        guard record.osVersion == osText, record.cpuType == cpuType, now.timeIntervalSince(record.recorded) < UnrunnableBuild.lifetime,
              now >= record.recorded else {
            defaults.removeObject(forKey: Keys.unrunnable)
            return nil
        }
        return record
    }

    private func remember(unrunnable feed: UpdateFeed) {
        let record = UnrunnableBuild(build: feed.build, sha256: feed.sha256, osVersion: osText, cpuType: cpuType, recorded: Date())
        defaults.set(try? JSONEncoder().encode(record), forKey: Keys.unrunnable)
    }

    // MARK: Checking

    /// The automatic checks: once shortly after launch, then whenever six hours have passed (looked at every
    /// half hour, so a Mac that slept still checks soon after it wakes). Nothing when updates are off.
    public func start() {
        guard isEnabled else { return }
        cancellation = UpdateCancellation()
        launchCheck = Task { [weak self] in
            try? await Task.sleep(for: UpdatePolicy.launchDelay)
            guard !Task.isCancelled else { return }
            await self?.checkIfDue(force: true)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.timerFired() }
        }
    }

    /// A timer tick: a due check, as tracked work (never alongside other work).
    func timerFired() {
        guard !cancellation.isCancelled, !status.isBusy else { return }
        work = Task { [weak self] in await self?.checkIfDue(force: false) }
    }

    /// Stops everything: the timer, a pending launch check, tracked work, and the detached staging or install
    /// task (each checks between its steps and stops). Nothing is committed after this (the swap is the commit).
    public func stop() {
        timer?.invalidate()
        timer = nil
        cancellation.cancel()
        launchCheck?.cancel()
        work?.cancel()
        cancelDetached?()
    }

    /// The button and the menu: does the next thing (check, download, or install) as tracked work.
    public func trigger() {
        guard !status.isBusy else { return }
        work = Task { [weak self] in await self?.perform() }
    }

    /// The menu's Check for Updates, as tracked work.
    public func checkNow() {
        guard !status.isBusy else { return }
        work = Task { [weak self] in await self?.check(manual: true) }
    }

    func checkIfDue(force: Bool, now: Date = Date()) async {
        guard isEnabled, checksAutomatically, !cancellation.isCancelled else { return }
        switch status {
        case .checking, .downloading, .installing, .ready: return
        default: break
        }
        if !force, let lastChecked, now.timeIntervalSince(lastChecked) < UpdatePolicy.checkInterval { return }
        await check(manual: false)
    }

    /// Reads the feed. A newer build is offered (and downloaded by itself when that's on). Automatic checks
    /// stay quiet when they fail. What the feed claims is never remembered.
    public func check(manual: Bool = true) async {
        guard isEnabled else { status = .off(environment.offReason(identity: identity) ?? ""); return }
        switch status {
        case .checking, .downloading, .installing: return
        case .ready where !manual: return
        default: break
        }
        let previous = status
        status = .checking
        let feed: UpdateFeed
        do {
            let data = try await transport.data(from: UpdatePolicy.feedURL, limit: UpdatePolicy.maxFeedBytes, timeout: UpdatePolicy.feedTimeout)
            feed = try UpdateFeed.parse(data)
        } catch {
            // An automatic check that fails stays quiet: the line goes back to what it said before.
            status = manual ? .failed(error.message) : (previous.isFailure ? .idle : previous)
            return
        }
        lastChecked = Date()
        defaults.set(lastChecked, forKey: Keys.lastCheck)
        if let staged, staged.feed == feed { status = .ready(feed); return }
        guard UpdatePolicy.isNewer(feed.build, than: environment.build) else { status = .upToDate; return }
        if let record = unrunnable(), record.build == feed.build, record.sha256 == feed.sha256 {
            status = manual ? .failed("Version \(feed.version) doesn’t run on this Mac.") : .upToDate
            return
        }
        // The feed's own minimum macOS only decides whether to download now; it's never remembered.
        if let minimum = UpdatePolicy.osVersion(feed.minimumMacOS), !UpdatePolicy.satisfies(minimum, running: osVersion) {
            status = .failed(UpdateFailure.needsNewerMacOS(feed.minimumMacOS).message)
            return
        }
        status = .available(feed)
        if downloadsAutomatically { await download() }
    }

    // MARK: Downloading

    /// Downloads the offered build and checks it end to end. On success it's "Ready to install".
    public func download() async {
        guard isEnabled, case .available(let feed) = status else { return }
        status = .downloading(feed)
        discardStaged()
        let root = workFolder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            status = .failed(UpdateFailure.copyFailed.message); return
        }
        let diskImage = root.appendingPathComponent("Tsukumo-\(feed.version).dmg")
        let cancellation = self.cancellation
        do {
            try await transport.download(from: feed.url, to: diskImage, limit: UpdatePolicy.maxDownloadBytes, timeout: UpdatePolicy.downloadTimeout)
        } catch {
            try? FileManager.default.removeItem(at: root)
            status = .failed((cancellation.isCancelled ? UpdateFailure.cancelled : error).message); return
        }
        guard !cancellation.isCancelled else { try? FileManager.default.removeItem(at: root); status = .failed(UpdateFailure.cancelled.message); return }
        let verifier = self.verifier
        // Tracked, and stopped between its steps (after the checksum, the mount, the tree walk, the copy, and each
        // check) when stop() is called.
        let staging = Task.detached(priority: .userInitiated) { () -> Result<URL, UpdateFailure> in
            do throws(UpdateFailure) {
                return .success(try verifier.stage(diskImage: diskImage, feed: feed, in: root, isCancelled: { cancellation.isCancelled }))
            } catch { return .failure(error) }
        }
        cancelDetached = { staging.cancel() }
        let result = await staging.value
        cancelDetached = nil
        guard !cancellation.isCancelled else { try? FileManager.default.removeItem(at: root); status = .failed(UpdateFailure.cancelled.message); return }
        switch result {
        case .success(let app):
            staged = (feed, app, root, diskImage)
            status = .ready(feed)
            onReady?(feed)
        case .failure(let failure):
            // Only reached after the signature and notarization passed (UpdateVerifier.checkApp's order).
            if failure.isUnrunnable { remember(unrunnable: feed) }
            try? FileManager.default.removeItem(at: root)
            status = .failed(failure.message)
        }
    }

    private func discardStaged() {
        if let staged { try? FileManager.default.removeItem(at: staged.root) }
        staged = nil
        canOpenDownload = false
    }

    // MARK: Installing

    /// Replaces the running copy with the checked one and relaunches, holding the install lock throughout (to
    /// this process's exit). Not from a disk image or a translocated copy; when the folder isn't writable or
    /// can't swap atomically, it says so and keeps the download to open by hand. The app is checked in full
    /// before the swap, after it, and again just before the relaunch.
    public func installAndRelaunch() async {
        guard isEnabled, case .ready(let feed) = status, let staged else { return }
        let destination = environment.bundleURL
        if let problem = locationProblem(destination) { status = .failed(problem.message); return }
        let lock: UpdateLock
        do { lock = try UpdateLock.acquire(lockFile) } catch { status = .failed(error.message); return }
        status = .installing(feed)
        let verifier = self.verifier
        var installer = self.installer
        installer.verify = { app, newerThan throws(UpdateFailure) in try verifier.checkApp(at: app, feed: feed, newerThan: newerThan) }
        let running = environment.build
        let cancellation = self.cancellation
        // Tracked; stop() before the swap (checked after the copy, before and after the check, and before the
        // swap) commits nothing. After the swap the install finishes, and the relaunch doesn't happen.
        let installing = Task.detached(priority: .userInitiated) { () -> Result<UpdateInstaller.Outcome, UpdateFailure> in
            do throws(UpdateFailure) {
                let outcome = try installer.install(staged: staged.app, over: destination, runningBuild: running, isCancelled: { cancellation.isCancelled })
                // Just before the relaunch: what's at the destination is still the selected build, in full.
                try verifier.checkApp(at: destination, feed: feed, newerThan: running)
                return .success(outcome)
            } catch { return .failure(error) }
        }
        cancelDetached = { installing.cancel() }
        let result = await installing.value
        cancelDetached = nil
        let outcome: UpdateInstaller.Outcome
        switch result {
        case .failure(let failure):
            lock.release()
            canOpenDownload = failure.offersDownload
            status = .failed(failure.message)
            if !failure.offersDownload { discardStaged() }
            return
        case .success(let done):
            outcome = done
        }
        if let kept = outcome.keptOldCopy { defaults.set(kept.path, forKey: Keys.keptOldCopy) }
        guard !cancellation.isCancelled else {
            lock.release()
            status = .notice("Version \(feed.version) is installed. Quit Tsukumo and open it again to finish.")
            return
        }
        do {
            try relaunch(destination)
        } catch {
            // Installed, but the helper didn't start: say so rather than quit without reopening.
            lock.release()
            status = .failed("Version \(feed.version) is installed. Quit Tsukumo and open it again to finish.")
            return
        }
        installLock = lock
        try? FileManager.default.removeItem(at: staged.root)
        self.staged = nil
        quit?()
    }

    /// Opens the kept, checked DMG so the owner can drag Tsukumo to Applications.
    public func openDownload() {
        guard let staged, canOpenDownload else { return }
        openFile?(staged.diskImage)
    }

    /// The button's job: Check, Download, or Install and Relaunch.
    public enum Action: Equatable, Sendable { case check, download, install }
    public var action: Action {
        switch status {
        case .available: .download
        case .ready: .install
        default: .check
        }
    }

    public func perform() async {
        switch action {
        case .check: await check(manual: true)
        case .download: await download()
        case .install: await installAndRelaunch()
        }
    }

    #if DEBUG
    /// Pictures only (`--capture`): shows a status without checking anything.
    public func preview(_ status: Status) { self.status = status }
    #endif
}
#endif
