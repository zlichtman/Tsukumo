import Foundation
import Observation

/// The watch's first run (the owner's request, September 25, 2026), minimal like the rest of the
/// watch: there's no sign-in here. Until the iPhone has finished its own setup, Kemo shows one
/// line, "Finish setup on your iPhone". Once it has, one screen says "Tap Kemo to talk"; the first
/// tap finishes it and starts talking. Kept in the watch's own settings.
@MainActor @Observable final class WatchFirstRun {
    static let doneKey = "watchFirstRunDone"
    /// The pet's saved state (`KemoPet`), which every watch install before the first-run screen has.
    static let earlierInstallKey = "kemoVitals"
    private(set) var done: Bool
    @ObservationIgnored private let defaults: UserDefaults

    /// Reads before `KemoPet` saves anything, so an earlier install is told apart from a new one.
    init(defaults: UserDefaults = .standard, arguments: [String] = ProcessInfo.processInfo.arguments) {
        self.defaults = defaults
        // An install from before the first-run screen never sees it.
        if !defaults.bool(forKey: Self.doneKey), defaults.object(forKey: Self.earlierInstallKey) != nil {
            defaults.set(true, forKey: Self.doneKey)
        }
        done = defaults.bool(forKey: Self.doneKey)
        #if DEBUG
        // UI tests skip it with --ui-testing; --first-run shows it as on a new install.
        if arguments.contains("--first-run") { defaults.removeObject(forKey: Self.doneKey); done = false }
        else if arguments.contains("--ui-testing") { done = true }
        #endif
    }
    func finish() {
        done = true
        defaults.set(true, forKey: Self.doneKey)
    }
}
