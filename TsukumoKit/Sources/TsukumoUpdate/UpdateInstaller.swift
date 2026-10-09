#if os(macOS)
import Darwin
import Foundation

/// Where the running copy is, and whether it may replace itself there.
public enum InstallLocation {
    /// Never install over a translocated copy (Gatekeeper's read-only App Translocation, from opening an app
    /// that wasn't moved out of Downloads or a disk image) or over a copy on a mounted disk image.
    public static func problem(path: String, readOnlyVolume: Bool, diskImageMounts: [String]) -> UpdateFailure? {
        if path.contains("/AppTranslocation/") { return .translocated }
        let standardized = (path as NSString).standardizingPath
        if diskImageMounts.contains(where: { mount in
            let root = (mount as NSString).standardizingPath
            return !root.isEmpty && root != "/" && (standardized == root || standardized.hasPrefix(root + "/"))
        }) { return .onDiskImage }
        if readOnlyVolume { return .onDiskImage }
        return nil
    }

    /// The same, for a real bundle: its volume's read-only flag and the disk images `hdiutil info` lists.
    public static func problem(for bundle: URL) -> UpdateFailure? {
        let readOnly = (try? bundle.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly ?? false
        return problem(path: bundle.resolvingSymlinksInPath().path, readOnlyVolume: readOnly, diskImageMounts: diskImageMounts())
    }

    /// The mount points of every attached disk image.
    static func diskImageMounts() -> [String] {
        let info = UpdateTool.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 30)
        guard info.status == 0, let start = info.output.range(of: "<?xml"),
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.output[start.lowerBound...].utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        return images.flatMap { image in
            (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
        }
    }
}

/// One install at a time: an exclusive `flock` on a file in the app's Application Support folder, held for the
/// whole transaction (from the first check to the relaunch helper), so two running copies can't both install.
public final class UpdateLock: @unchecked Sendable {
    private var descriptor: Int32

    private init(descriptor: Int32) { self.descriptor = descriptor }

    /// Takes the lock without waiting, or throws `.busy` when another process (or another holder here) has it.
    public static func acquire(_ file: URL) throws(UpdateFailure) -> UpdateLock {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(file.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw .installFailed }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw .busy }
        return UpdateLock(descriptor: descriptor)
    }

    public func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

/// Puts a checked app in place of the running one.
///
/// The threat-model boundary: a process running as the owner can already replace /Applications/Tsukumo.app
/// directly, so the installer doesn't try to defend against one. It does make tampering with the staged copy
/// pointless: the copy about to be swapped in, and the app at the destination after the swap, each get every
/// check again (`verify`).
public struct UpdateInstaller: Sendable {
    /// Moves the replaced copy to the Trash; false when it couldn't (the copy is then kept, renamed).
    public var trash: @Sendable (URL) -> Bool
    /// Every check on an app (signature, notarization, bundle ID, the selected build, newer than the given
    /// build, the feed's version, minimum macOS, architecture).
    public var verify: @Sendable (URL, Int) throws(UpdateFailure) -> Void
    /// The atomic swap (`renamex_np` with `RENAME_SWAP`); tests stand in a volume that can't.
    public var swap: @Sendable (String, String) -> Int32

    public init(trash: @escaping @Sendable (URL) -> Bool = UpdateInstaller.moveToTrash,
                verify: @escaping @Sendable (URL, Int) throws(UpdateFailure) -> Void = { _, _ throws(UpdateFailure) in },
                swap: @escaping @Sendable (String, String) -> Int32 = { renamex_np($0, $1, UInt32(RENAME_SWAP)) }) {
        self.trash = trash; self.verify = verify; self.swap = swap
    }

    public static let moveToTrash: @Sendable (URL) -> Bool = { url in
        (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil
    }

    /// What happened to the replaced copy.
    public struct Outcome: Equatable, Sendable {
        /// Where the old copy was left when the Trash refused it (nil: it's in the Trash).
        public var keptOldCopy: URL?
    }

    /// Replaces `destination` (normally /Applications/Tsukumo.app) with `staged`. The caller holds the
    /// `UpdateLock`.
    /// 1. The folder must be writable (or it says so, and the owner can open the download instead).
    /// 2. The build at the destination now is read: the new one must be newer than it and than `runningBuild`.
    /// 3. `ditto` copies the new app next to the old one (same volume, permissions kept) under a hidden name.
    /// 4. That copy gets every check again, and only then is its quarantine cleared.
    /// 5. Unless cancelled, the two swap in one atomic rename (`RENAME_SWAP`). A volume that can't swap fails
    ///    closed (`.cantSwap`: open the download instead); there's no two-step fallback.
    /// 6. The app now at the destination gets every check; if it fails, the swap is undone and it's refused.
    /// 7. The old copy goes to the Trash; if the Trash refuses, it stays beside the app, renamed, never deleted.
    public func install(staged: URL, over destination: URL, runningBuild: Int,
                        isCancelled: @Sendable () -> Bool = { false }) throws(UpdateFailure) -> Outcome {
        let fm = FileManager.default
        let folder = destination.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: folder.path) else { throw .notWritable }
        if fm.fileExists(atPath: destination.path), !fm.isWritableFile(atPath: destination.path) { throw .notWritable }
        let newerThan = max(runningBuild, UpdateVerifier.build(of: destination) ?? 0)
        let name = destination.deletingPathExtension().lastPathComponent
        let incoming = folder.appendingPathComponent(".\(name)-update-\(UUID().uuidString).app", isDirectory: true)
        guard UpdateTool.run("/usr/bin/ditto", UpdateVerifier.copyFlags + [staged.path, incoming.path], timeout: 300).status == 0 else {
            try? fm.removeItem(at: incoming)
            throw fm.isWritableFile(atPath: folder.path) ? .copyFailed : .notWritable
        }
        do throws(UpdateFailure) {
            if isCancelled() { throw .cancelled }
            try verify(incoming, newerThan)
        } catch {
            try? fm.removeItem(at: incoming)
            throw error
        }
        Self.clearQuarantine(incoming)
        guard !isCancelled() else { try? fm.removeItem(at: incoming); throw .cancelled }
        guard fm.fileExists(atPath: destination.path) else {
            // Nothing to replace (the running copy was removed): put the new one there, checked again.
            guard rename(incoming.path, destination.path) == 0 else { try? fm.removeItem(at: incoming); throw .installFailed }
            do { try verify(destination, newerThan) } catch { try? fm.removeItem(at: destination); throw error }
            return Outcome(keptOldCopy: nil)
        }
        guard swap(incoming.path, destination.path) == 0 else {
            try? fm.removeItem(at: incoming)
            throw .cantSwap
        }
        // After the swap the old app is at the hidden name. Check what's at the destination now.
        do {
            try verify(destination, newerThan)
        } catch {
            if swap(incoming.path, destination.path) == 0 {
                try? fm.removeItem(at: incoming)  // the new app, swapped back out
                throw error
            }
            // The swap back failed: the previous app is still beside it under the hidden name. Give it a name the
            // owner can find, say exactly where it is, and log it; never leave it unidentified.
            let previous = keep(incoming, in: folder, name: name)
            updateLog.fault("The update failed its check after the swap and couldn’t be swapped back; the previous app is at \(previous.path, privacy: .public)")
            throw .swapBackFailed(previous.path)
        }
        if trash(incoming) { return Outcome(keptOldCopy: nil) }
        return Outcome(keptOldCopy: keep(incoming, in: folder, name: name))
    }

    /// Renames a replaced copy to "<name> (previous).app" (or "(previous 2)" and so on) beside the app; if even
    /// that fails, it stays where it is, and that path is returned.
    private func keep(_ copy: URL, in folder: URL, name: String) -> URL {
        var kept = folder.appendingPathComponent("\(name) (previous).app", isDirectory: true)
        var number = 2
        while FileManager.default.fileExists(atPath: kept.path) {
            kept = folder.appendingPathComponent("\(name) (previous \(number)).app", isDirectory: true)
            number += 1
        }
        return rename(copy.path, kept.path) == 0 ? kept : copy
    }

    /// Removes com.apple.quarantine from a folder and everything in it (not following links).
    static func clearQuarantine(_ root: URL) {
        removexattr(root.path, "com.apple.quarantine", XATTR_NOFOLLOW)
        guard let items = FileManager.default.enumerator(atPath: root.path) else { return }
        for case let item as String in items {
            removexattr(root.appendingPathComponent(item).path, "com.apple.quarantine", XATTR_NOFOLLOW)
        }
    }

    /// The helper that reopens Tsukumo: it waits for this process to exit (checking every 0.2 s, `$3` times,
    /// 300 by default: a minute), then opens the app. If the process is still alive at the deadline it doesn't
    /// open anything and logs why. The PID, the app's path, and the opener are arguments, never part of the script.
    public static let relaunchScript = """
    i=0; while /bin/kill -0 "$1" 2>/dev/null; do if [ "$i" -ge "${3:-300}" ]; then /usr/bin/logger -t tsukumo-update "Tsukumo (pid $1) didn't quit; not reopening it"; exit 1; fi; /bin/sleep 0.2; i=$((i+1)); done; exec "${4:-/usr/bin/open}" "$2"
    """

    /// Starts the helper, detached; the caller then quits.
    public static func relaunch(_ app: URL, after pid: Int32 = ProcessInfo.processInfo.processIdentifier, tries: Int = 300,
                                opener: String = "/usr/bin/open") throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", relaunchScript, "tsukumo-relaunch", String(pid), app.path, String(tries), opener]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return process
    }
}
#endif
