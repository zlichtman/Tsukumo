import Foundation

/// Tsukumo ran in the App Sandbox until build 43. Its first unsandboxed launch copies the
/// sandbox container's data to the usual places without touching the original. The copy is
/// staged and marked done only when every item arrived; until then the app doesn't save, so
/// a fresh, empty store can never take the place of data that hasn't been brought over yet.
enum SandboxMigration {
    static let doneKey = "tsukumo.migratedFromSandbox"
    enum Outcome: Equatable { case alreadyDone, nothingToMove, moved, failed }

    @discardableResult static func run(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                       defaults: UserDefaults = .standard, files: FileManager = .default) -> Outcome {
        guard !defaults.bool(forKey: doneKey) else { return .alreadyDone }
        let container = home.appendingPathComponent("Library/Containers/com.zlichtman.kemosabe.mac/Data/Library")
        let from = container.appendingPathComponent("Application Support/KemoSabe")
        let to = home.appendingPathComponent("Library/Application Support/KemoSabe")
        var outcome = Outcome.nothingToMove
        if files.fileExists(atPath: from.path) {
            do { try copyMissing(from: from, to: to, files: files); outcome = .moved }
            catch { return .failed }
        }
        // Settings the sandboxed app saved, for keys this launch hasn't set.
        let plist = container.appendingPathComponent("Preferences/com.zlichtman.kemosabe.mac.plist")
        if let saved = NSDictionary(contentsOf: plist) as? [String: Any] {
            for (key, value) in saved where defaults.object(forKey: key) == nil { defaults.set(value, forKey: key) }
        }
        defaults.set(true, forKey: doneKey)
        return outcome
    }

    /// Copies each item that isn't already at the destination, through a staging folder so a
    /// half-copied item never appears under its real name. An item that already exists (made
    /// while an earlier attempt was retried) is kept, and the container's copy sits beside it.
    private static func copyMissing(from: URL, to: URL, files: FileManager) throws {
        try files.createDirectory(at: to, withIntermediateDirectories: true)
        let staging = to.appendingPathComponent(".migrating-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: staging) }
        for name in try files.contentsOfDirectory(atPath: from.path) {
            let staged = staging.appendingPathComponent(name)
            try files.copyItem(at: from.appendingPathComponent(name), to: staged)
            var target = to.appendingPathComponent(name)
            if files.fileExists(atPath: target.path) { target = to.appendingPathComponent("from-sandbox-" + name) }
            if files.fileExists(atPath: target.path) { continue }
            try files.moveItem(at: staged, to: target)
        }
    }
}
