import AppKit
import Observation
import SwiftUI

/// The newest published Tsukumo, as `scripts/release-mac.sh` writes it next to the download:
/// https://zlichtman.com/downloads/tsukumo.json, `{version, build, url, sha256, minimumMacOS, notes}`.
///
/// The feed, not the tap's raw cask, because it's deployed in the same Vercel deploy as the DMG it
/// names (the app never offers a build whose download isn't live yet), it's strict JSON rather than
/// Ruby to pick apart, and it carries the download URL the Download button opens.
struct TsukumoRelease: Equatable, Decodable, Sendable {
    let version: String
    let build: Int
    let url: URL
    let sha256: String
    /// The oldest macOS the build runs on ("26.0"); nil when the feed doesn't say.
    var minimumMacOS: String? = nil
    /// One line about what's new; nil when the feed doesn't say.
    var notes: String? = nil

    static let feed = URL(string: "https://zlichtman.com/downloads/tsukumo.json")!

    struct Invalid: Error {}

    /// Refuses anything that isn't a sane release on the owner's site: a positive build, a dotted
    /// numeric version, an https download on zlichtman.com, and a 64-character hex SHA-256.
    static func parse(_ data: Data) throws -> TsukumoRelease {
        guard let release = try? JSONDecoder().decode(TsukumoRelease.self, from: data), release.build > 0, versionParts(release.version) != nil,
              release.url.scheme == "https", release.url.host() == "zlichtman.com",
              release.url.path().hasPrefix("/downloads/"), release.url.pathExtension == "dmg",
              release.sha256.count == 64, release.sha256.allSatisfy({ $0.isHexDigit }) else { throw Invalid() }
        return release
    }

    /// Whether the published version and build are newer than the running ones: the dotted version
    /// compared number by number first, then the build (the version stays 1.0.0 until the public release).
    static func isNewer(version: String, build: Int, than runningVersion: String, build runningBuild: Int) -> Bool {
        let published = versionParts(version) ?? [0], running = versionParts(runningVersion) ?? [0]
        for index in 0..<max(published.count, running.count) {
            let a = index < published.count ? published[index] : 0, b = index < running.count ? running[index] : 0
            if a != b { return a > b }
        }
        return build > runningBuild
    }
    func isNewer(than runningVersion: String, build runningBuild: Int) -> Bool {
        Self.isNewer(version: version, build: build, than: runningVersion, build: runningBuild)
    }
    /// Whether this Mac's macOS is at least the release's minimum (always, when the feed names none
    /// or names one that isn't a dotted number).
    func runs(on system: OperatingSystemVersion) -> Bool {
        guard let minimum = minimumMacOS.flatMap(Self.versionParts) else { return true }
        let running = [system.majorVersion, system.minorVersion, system.patchVersion]
        for index in 0..<max(minimum.count, running.count) {
            let a = index < running.count ? running[index] : 0, b = index < minimum.count ? minimum[index] : 0
            if a != b { return a > b }
        }
        return true
    }
    private static func versionParts(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.count <= 4, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.compactMap { $0 }
    }
}

/// Homebrew is how Tsukumo installs and updates: `brew install --cask zlichtman/tap/tsukumo`.
enum HomebrewInstall {
    static let cask = "zlichtman/tap/tsukumo"
    static let applicationPath = "/Applications/Tsukumo.app"
    /// Apple silicon's prefix first, then Intel's.
    static let prefixes = ["/opt/homebrew", "/usr/local"]

    /// brew's prefix when this copy is Homebrew's: it runs from /Applications/Tsukumo.app and that
    /// prefix's Caskroom has tsukumo (what `brew list --cask tsukumo` reads). Nil otherwise.
    static func prefix(bundlePath: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        guard URL(fileURLWithPath: bundlePath).standardizedFileURL.path == applicationPath else { return nil }
        return prefixes.first { exists("\($0)/Caskroom/tsukumo") && exists("\($0)/bin/brew") }
    }
    /// Typed into a Tsukumo terminal tab. `brew update` first, since brew refreshes taps only about
    /// once a day on its own and would otherwise not see the new cask yet.
    static func upgradeCommand(prefix: String) -> String {
        "\(prefix)/bin/brew update && \(prefix)/bin/brew upgrade --cask \(cask)"
    }
    /// The build of the Tsukumo on disk, read fresh (Bundle caches its Info.plist).
    static func installedBuild(at bundlePath: String) -> Int? {
        let plist = URL(fileURLWithPath: bundlePath).appendingPathComponent("Contents/Info.plist")
        guard let info = NSDictionary(contentsOf: plist) else { return nil }
        return Int(info["CFBundleVersion"] as? String ?? "")
    }
}

/// Tsukumo's update check. It reads the release feed and compares it with the running build. A copy
/// Homebrew installed updates with "Update with Homebrew": a Tsukumo terminal tab runs `brew upgrade`,
/// and once brew has put the new build in /Applications, Tsukumo quits and reopens it. Tsukumo stays
/// open while brew works because the tab's shell lives inside Tsukumo, so quitting first would stop
/// brew midway; brew replaces the app on disk while it runs. Any other copy (no `tsukumo` in brew's
/// Caskroom) offers Download, which opens the website's disk image in the browser. The app itself
/// never downloads, verifies, or installs a build, so there's no signature to compare.
@MainActor @Observable final class AppUpdater {
    static let shared = AppUpdater()
    enum Phase: Equatable {
        case idle, checking, upToDate
        case available(TsukumoRelease)
        /// brew is running in a Tsukumo terminal tab.
        case upgrading(TsukumoRelease)
        case restarting
        case failed(String)
    }
    private(set) var phase: Phase = .idle
    private(set) var checkedAt: Date?
    private let defaults: UserDefaults
    private let fetch: @Sendable (URL) async throws -> Data
    private let homebrew: () -> String?
    private let openURL: (URL) -> Void
    private let system: OperatingSystemVersion
    private var watcher: Task<Void, Never>?

    init(defaults: UserDefaults = .standard,
         fetch: @escaping @Sendable (URL) async throws -> Data = AppUpdater.download,
         homebrew: @escaping () -> String? = { HomebrewInstall.prefix(bundlePath: Bundle.main.bundlePath) },
         openURL: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) },
         system: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        self.defaults = defaults; self.fetch = fetch; self.homebrew = homebrew; self.openURL = openURL; self.system = system
    }

    nonisolated static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }
    nonisolated static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0" }

    /// Whether this copy is Homebrew's (so updating runs brew rather than opening the download).
    var installedByHomebrew: Bool { homebrew() != nil }
    /// The update button: "Update with Homebrew" for Homebrew's copy, "Download" for any other.
    var updateTitle: String { installedByHomebrew ? "Update with Homebrew" : "Download" }

    /// The sidebar card hides once dismissed for that build; a newer build shows it again.
    var dismissedBuild: Int { defaults.integer(forKey: "desktop.update.dismissedBuild") }
    func dismiss() {
        if case .available(let release) = phase { defaults.set(release.build, forKey: "desktop.update.dismissedBuild"); phase = .idle }
    }
    var showsCard: Bool {
        switch phase {
        case .available(let release): release.build > dismissedBuild
        case .upgrading, .restarting: true
        default: false
        }
    }
    var release: TsukumoRelease? {
        switch phase { case .available(let r), .upgrading(let r): r; default: nil }
    }

    func check(runningVersion: String = AppUpdater.currentVersion, runningBuild: Int = AppUpdater.currentBuild) async {
        switch phase { case .checking, .upgrading, .restarting: return; default: break }
        phase = .checking
        do {
            let release = try TsukumoRelease.parse(try await fetch(TsukumoRelease.feed))
            checkedAt = Date()
            if !release.isNewer(than: runningVersion, build: runningBuild) { phase = .upToDate }
            else if !release.runs(on: system) {
                phase = .failed("Tsukumo \(release.version) (\(release.build)) needs macOS \(release.minimumMacOS ?? "") or later.")
            } else { phase = .available(release) }
        } catch is TsukumoRelease.Invalid { phase = .failed("The update information wasn't readable. Try again later.") }
        catch { phase = .failed("Couldn't check for updates. Check your connection and try again.") }
    }

    /// Update with Homebrew: runs brew in a new Tsukumo terminal tab and shows it. A copy that didn't
    /// come from Homebrew opens the download in the browser instead.
    func update(desktop: DesktopNavigation) {
        guard case .available(let release) = phase else { return }
        guard let prefix = homebrew() else { openURL(release.url); return }
        let pane = TerminalWorkspace.main.openTab(agent: CodingAgentCommand(id: "homebrew-update", name: "Homebrew update", command: HomebrewInstall.upgradeCommand(prefix: prefix)))
        showTerminal(desktop)
        phase = .upgrading(release)
        watch(pane: pane, release: release)
    }
    func showTerminal(_ desktop: DesktopNavigation) {
        desktop.settingsPage = nil; desktop.page = "Tsukumo"; desktop.tsukumoSurface = "Terminal"
    }

    /// Waits for brew in the tab. Done when the Tsukumo on disk is the new build and nothing runs in
    /// the tab any more; failed when the command has stopped (twice in a row, so the moment between
    /// `brew update` and `brew upgrade` doesn't count) without installing it; given up when the tab closes.
    private func watch(pane: UUID, release: TsukumoRelease) {
        watcher?.cancel()
        watcher = Task { [weak self] in
            var opened = false, started = false, idleChecks = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, case .upgrading = self.phase else { return }
                let sessions = TerminalSessions.shared
                if sessions.state(pane) != nil { opened = true }
                else if opened { self.phase = .available(release); return }
                else { continue }
                if sessions.runningProgram(pane) != nil { started = true; idleChecks = 0; continue }
                if (HomebrewInstall.installedBuild(at: Bundle.main.bundlePath) ?? 0) >= release.build { self.relaunch(); return }
                guard started else { continue }
                idleChecks += 1
                if idleChecks >= 2 {
                    self.phase = .failed("Homebrew didn't install build \(release.build). The terminal tab shows why; check again in a few minutes.")
                    return
                }
            }
        }
    }

    /// Quits and reopens the copy brew just installed, once this process has exited.
    private func relaunch() {
        phase = .restarting
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        /usr/bin/open "$1"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "tsukumo-relaunch", Bundle.main.bundlePath]
        do { try process.run(); NSApp.terminate(nil) }
        catch { phase = .failed("The update is installed. Quit and reopen Tsukumo to use it.") }
    }

    nonisolated static func download(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 15)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

/// The update card at the foot of the sidebar, laid out like Codex's: a title with a dismiss
/// button, one line of detail, and a full-width capsule button. A Homebrew copy walks through
/// Update with Homebrew, Show Terminal, and Reopening…; any other copy offers Download.
struct UpdateCard: View {
    @State private var updater = AppUpdater.shared
    @Environment(DesktopNavigation.self) private var desktop
    let accent: Color
    var body: some View {
        if updater.showsCard {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 6) {
                    Text(title).font(.system(size: 13, weight: .medium)).frame(maxWidth: .infinity, alignment: .leading)
                    if case .available = updater.phase {
                        Button { updater.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16) }
                            .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Dismiss update")
                    }
                }
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                capsule(buttonLabel, identifier: "updateButton", action: act).disabled(busy)
            }
            .padding(12)
            .background(.regularMaterial.opacity(0.8), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
            .padding(.bottom, 8)
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
    private func capsule(_ label: String, identifier: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.system(size: 11, weight: .medium)).lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: 24).foregroundStyle(.white)
                .background(accent.opacity(busy ? 0.55 : 1), in: Capsule())
        }.buttonStyle(.plain).padding(.top, 10).accessibilityIdentifier(identifier)
    }
    private var build: Int { updater.release?.build ?? AppUpdater.currentBuild }
    private var title: String {
        switch updater.phase {
        case .upgrading: "Updating with Homebrew"
        case .restarting: "Reopening Tsukumo"
        default: "Update available"
        }
    }
    private var detail: String {
        if case .upgrading = updater.phase { return "Tsukumo reopens when brew finishes." }
        return "Tsukumo \(updater.release?.version ?? AppUpdater.currentVersion) (\(build))"
    }
    private var busy: Bool { if case .restarting = updater.phase { true } else { false } }
    private var buttonLabel: String {
        switch updater.phase {
        case .upgrading: "Show Terminal"
        case .restarting: "Reopening…"
        default: updater.updateTitle
        }
    }
    private func act() {
        switch updater.phase {
        case .available: updater.update(desktop: desktop)
        case .upgrading: updater.showTerminal(desktop)
        default: break
        }
    }
}
