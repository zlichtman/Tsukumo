#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import os
import Security

let updateLog = Logger(subsystem: "com.zlichtman.tsukumo.mac", category: "updates")

/// Checks an app's code signature against the team's requirement, and its notarization.
public protocol SignatureChecking: Sendable {
    func check(app: URL, identity: UpdateIdentity) throws(UpdateFailure)
}

/// The real check, with the Security framework: the signature is valid under strict validation for every
/// architecture and all nested code, and satisfies `anchor apple generic and certificate leaf[subject.OU] =
/// "28LJG7MXT3" and identifier "com.zlichtman.tsukumo.mac"`, narrowed to Developer ID. Then notarization: the
/// `notarized` requirement (a stapled ticket, or Apple's record of it), and Gatekeeper's own assessment
/// (`spctl -a -t exec`) mustn't reject it.
public struct CodeSignatureChecker: SignatureChecking {
    public var requireNotarization: Bool
    public init(requireNotarization: Bool = true) { self.requireNotarization = requireNotarization }

    public func check(app: URL, identity: UpdateIdentity) throws(UpdateFailure) {
        guard Self.satisfies(app: app, requirement: identity.developerIDRequirement, strict: true) else { throw .badSignature }
        guard requireNotarization else { return }
        guard Self.satisfies(app: app, requirement: "notarized", strict: false) else { throw .notNotarized }
        let assessment = UpdateTool.run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", app.path], timeout: 60)
        guard assessment.status == 0, !assessment.output.contains("rejected") else { throw .notNotarized }
    }

    /// Whether the code at `app` is validly signed and satisfies `requirement`.
    public static func satisfies(app: URL, requirement text: String, strict: Bool) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess, let requirement else { return false }
        let flags = strict ? SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode) : []
        return SecStaticCodeCheckValidityWithErrors(code, flags, requirement, nil) == errSecSuccess
    }

    /// Whether a requirement's text compiles (tests).
    public static func compiles(_ text: String) -> Bool {
        var requirement: SecRequirement?
        return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess
    }
}

/// What a running copy of Tsukumo compares an update against.
public struct UpdateVerifier: Sendable {
    public var identity: UpdateIdentity
    public var runningBuild: Int
    public var osVersion: OperatingSystemVersion
    /// The Mach-O CPU type this Mac runs (CPU_TYPE_ARM64 or CPU_TYPE_X86_64).
    public var cpuType: Int32
    public var signature: any SignatureChecking
    /// Bounds on the app inside an image, checked before anything is copied out of it.
    public var maxAppBytes: Int64 = 600 * 1024 * 1024
    public var maxAppFiles = 20_000
    /// Extended attributes (the resource fork included) allowed on any one entry before the copy.
    public var maxExtendedAttributeBytes: Int64 = 1024 * 1024
    public static let maxInfoPlistBytes = 256 * 1024

    public init(identity: UpdateIdentity = .tsukumo, runningBuild: Int, osVersion: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                cpuType: Int32 = UpdateVerifier.hostCPUType, signature: any SignatureChecking = CodeSignatureChecker()) {
        self.identity = identity; self.runningBuild = runningBuild; self.osVersion = osVersion; self.cpuType = cpuType; self.signature = signature
    }

    public static let cpuARM64: Int32 = 0x0100_000C
    public static let cpuX86_64: Int32 = 0x0100_0007
    public static var hostCPUType: Int32 {
        #if arch(arm64)
        cpuARM64
        #else
        cpuX86_64
        #endif
    }

    // MARK: Checksum

    /// The file's SHA-256, in lowercase hex, read in pieces.
    public static func sha256(of file: URL) throws(UpdateFailure) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { throw .copyFailed }
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk: Data?
            do { chunk = try handle.read(upToCount: 1 << 20) } catch { throw .copyFailed }
            guard let chunk, !chunk.isEmpty else { break }  // nil at the end of the file
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: The disk image

    /// From a downloaded DMG to a checked copy of the app in `root` (a private folder): the SHA-256 must match
    /// the feed; the image is mounted read-only (`hdiutil attach -nobrowse -readonly -noautoopen -plist`) on a
    /// private mount point inside `root`, and its devices are kept; exactly one app must be at its top, named
    /// Tsukumo.app and not a link; the app's tree is walked within bounds (bytes, files, no device nodes, no
    /// links out of the bundle, small extended attributes and resource forks) before `ditto` copies it out
    /// with no resource forks, extended attributes, ACLs, or quarantine (`copyFlags`); the image's devices are
    /// detached whatever happens (an attachment left by a failed or timed-out attach too); then the copy gets
    /// every check (`checkApp`). `isCancelled` is asked between steps; a stop throws `.cancelled`.
    public func stage(diskImage: URL, feed: UpdateFeed, in root: URL,
                      isCancelled: @Sendable () -> Bool = { false }) throws(UpdateFailure) -> URL {
        func stopIfCancelled() throws(UpdateFailure) { if isCancelled() { throw .cancelled } }
        guard try Self.sha256(of: diskImage) == feed.sha256.lowercased() else { throw .checksumMismatch }
        try stopIfCancelled()
        let mount = root.appendingPathComponent("mount", isDirectory: true)
        let staged = root.appendingPathComponent(identity.appName, isDirectory: true)
        try? FileManager.default.removeItem(at: staged)
        do {
            try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw .copyFailed }
        let devices = Self.attach(diskImage, at: mount)
        defer { Self.detach(devices: devices, image: diskImage, mount: mount) }
        guard !devices.isEmpty else { throw .mountFailed }
        try stopIfCancelled()
        let found = try Self.onlyApp(in: mount, named: identity.appName)
        try inspectTree(found)
        try stopIfCancelled()
        guard UpdateTool.run("/usr/bin/ditto", Self.copyFlags + [found.path, staged.path], timeout: 300).status == 0 else {
            try? FileManager.default.removeItem(at: staged)
            throw .copyFailed
        }
        do {
            try stopIfCancelled()
            try checkApp(at: staged, feed: feed, newerThan: runningBuild, isCancelled: isCancelled)
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
        return staged
    }

    /// How an app is copied: the data only, no resource forks, extended attributes, ACLs, or quarantine, so a
    /// hostile image can't hide gigabytes outside the data forks the tree walk counts. A bundle's signature and
    /// its stapled ticket are regular files inside it (`_CodeSignature/CodeResources`, `Contents/CodeResources`)
    /// and its executables' signatures are inside the Mach-O files, so nothing the checks need is lost.
    public static let copyFlags = ["--norsrc", "--noextattr", "--noacl", "--noqtn"]

    /// Attaches the image read-only and returns its devices (`/dev/diskN`, then its slices) from hdiutil's plist,
    /// or nothing when the attach failed.
    static func attach(_ image: URL, at mount: URL) -> [String] {
        let attach = UpdateTool.run("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path, image.path],
                                    timeout: 180)
        guard attach.status == 0 else { return [] }
        return devices(fromAttachPlist: Data(attach.output.utf8))
    }

    /// The `dev-entry` of every system entity in `hdiutil attach -plist`'s output, the whole disk first.
    static func devices(fromAttachPlist data: Data) -> [String] {
        // hdiutil may print lines before the plist; start at the XML.
        let text = String(decoding: data, as: UTF8.self)
        guard let start = text.range(of: "<?xml"),
              let plist = try? PropertyListSerialization.propertyList(from: Data(text[start.lowerBound...].utf8), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else { return [] }
        return entities.compactMap { $0["dev-entry"] as? String }.filter { $0.hasPrefix("/dev/disk") }.sorted { $0.count < $1.count }
    }

    /// Detaches the attached devices (forced if busy) and any attachment of `image` hdiutil still lists (a
    /// partial or timed-out attach), then removes the mount folder. A device that won't detach is logged.
    static func detach(devices: [String], image: URL, mount: URL) {
        var targets = devices.first.map { [$0] } ?? []
        targets += attachedDevices(of: image).filter { !targets.contains($0) }
        for device in targets where !detachDevice(device) {
            updateLog.error("Couldn’t detach \(device, privacy: .public) for the update image")
        }
        if FileManager.default.fileExists(atPath: mount.path), (try? FileManager.default.contentsOfDirectory(atPath: mount.path))?.isEmpty == false {
            updateLog.error("The update mount point is still in use: \(mount.path, privacy: .public)")
        } else {
            try? FileManager.default.removeItem(at: mount)
        }
    }

    static func detachDevice(_ device: String) -> Bool {
        if UpdateTool.run("/usr/bin/hdiutil", ["detach", device, "-quiet"], timeout: 60).status == 0 { return true }
        return UpdateTool.run("/usr/bin/hdiutil", ["detach", device, "-force", "-quiet"], timeout: 60).status == 0
    }

    /// The whole-disk devices hdiutil lists for this image file.
    static func attachedDevices(of image: URL) -> [String] {
        let info = UpdateTool.run("/usr/bin/hdiutil", ["info", "-plist"], timeout: 30)
        guard info.status == 0, let start = info.output.range(of: "<?xml"),
              let plist = try? PropertyListSerialization.propertyList(from: Data(info.output[start.lowerBound...].utf8), format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        let path = image.resolvingSymlinksInPath().path
        return images.filter { ($0["image-path"] as? String).map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == path }
            .compactMap { image in
                (image["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["dev-entry"] as? String }.sorted { $0.count < $1.count }.first
            }
    }

    /// The one app at the top of a mounted image, which must be `name` and a real folder (not a link).
    static func onlyApp(in mount: URL, named name: String) throws(UpdateFailure) -> URL {
        guard let items = try? FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey]) else {
            throw .appMissing
        }
        let apps = items.filter { $0.pathExtension.lowercased() == "app" }
        guard apps.count == 1, let app = apps.first, app.lastPathComponent == name else { throw .appMissing }
        let values = try? app.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isSymbolicLink == false, values?.isDirectory == true else { throw .appMissing }
        return app
    }

    /// Walks the app's tree without following links, before anything is copied: at most `maxAppBytes` in
    /// regular files and `maxAppFiles` entries; only folders, regular files, and links that stay inside the
    /// bundle (relative, resolving under its root); never a device node, socket, or pipe; and no entry (the
    /// bundle itself included) whose extended attributes, its resource fork among them, pass
    /// `maxExtendedAttributeBytes`. Those count toward `maxAppBytes` too, though the copy leaves them out.
    public func inspectTree(_ app: URL) throws(UpdateFailure) {
        let root = app.standardizedFileURL.path
        guard let walker = FileManager.default.enumerator(atPath: root) else { throw .unsafeApp }
        var bytes = try Self.extendedAttributeBytes(root, limit: maxExtendedAttributeBytes)
        var count = 0
        while let item = walker.nextObject() as? String {
            count += 1
            guard count <= maxAppFiles else { throw .unsafeApp }
            let path = root + "/" + item
            var info = stat()
            guard lstat(path, &info) == 0 else { throw .unsafeApp }
            bytes += try Self.extendedAttributeBytes(path, limit: maxExtendedAttributeBytes)
            guard bytes <= maxAppBytes else { throw .unsafeApp }
            switch info.st_mode & S_IFMT {
            case S_IFDIR: continue
            case S_IFREG:
                bytes += Int64(info.st_size)
                guard bytes <= maxAppBytes else { throw .unsafeApp }
            case S_IFLNK:
                guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path), !target.hasPrefix("/") else { throw .unsafeApp }
                let resolved = (((path as NSString).deletingLastPathComponent as NSString).appendingPathComponent(target) as NSString).standardizingPath
                guard resolved == root || resolved.hasPrefix(root + "/") else { throw .unsafeApp }
            default:
                throw .unsafeApp  // device nodes, sockets, pipes
            }
        }
    }

    /// The total size of an entry's extended attributes (not following links), or `.unsafeApp` past `limit`.
    static func extendedAttributeBytes(_ path: String, limit: Int64) throws(UpdateFailure) -> Int64 {
        let length = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        guard length > 0 else { return 0 }
        guard length < 64 * 1024 else { throw .unsafeApp }
        var buffer = [CChar](repeating: 0, count: length)
        guard listxattr(path, &buffer, length, XATTR_NOFOLLOW) == length else { throw .unsafeApp }
        let names = buffer.split(separator: 0).map { String(decoding: $0.map { UInt8(bitPattern: $0) }, as: UTF8.self) }
        var total: Int64 = 0
        for name in names {
            let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
            guard size >= 0 else { throw .unsafeApp }
            total += Int64(size)
            guard total <= limit else { throw .unsafeApp }
        }
        return total
    }

    // MARK: The app

    /// Every check on an app, run on the staged copy, again on the copy about to be swapped in, and on the app
    /// at the destination after the swap: bundle ID; a build newer than `newerThan` (the running build, and
    /// the one at the destination) and equal to the feed's; the feed's version; its signature and notarization;
    /// then its minimum macOS and this Mac's architecture (so a build is only ever remembered as one this Mac
    /// can't run once its signature has passed). Info.plist must be a regular file of at most 256 KB.
    public func checkApp(at app: URL, feed: UpdateFeed, newerThan minimum: Int,
                         isCancelled: @Sendable () -> Bool = { false }) throws(UpdateFailure) {
        let info = try Self.infoPlist(of: app)
        guard info["CFBundleIdentifier"] as? String == identity.bundleIdentifier else { throw .wrongBundle }
        guard let buildText = info["CFBundleVersion"] as? String, let build = Int(buildText) else { throw .mismatch }
        guard UpdatePolicy.isNewer(build, than: max(minimum, runningBuild)) else { throw .notNewer }
        guard build == feed.build, info["CFBundleShortVersionString"] as? String == feed.version else { throw .mismatch }
        guard let executable = info["CFBundleExecutable"] as? String, !executable.isEmpty, !executable.contains("/") else { throw .wrongBundle }
        if isCancelled() { throw .cancelled }
        try signature.check(app: app, identity: identity)
        if isCancelled() { throw .cancelled }
        if let minimumOS = info["LSMinimumSystemVersion"] as? String {
            guard let required = UpdatePolicy.osVersion(minimumOS) else { throw .mismatch }
            guard UpdatePolicy.satisfies(required, running: osVersion) else { throw .needsNewerMacOS(minimumOS) }
        }
        guard let types = Self.cpuTypes(of: app.appendingPathComponent("Contents/MacOS").appendingPathComponent(executable)) else { throw .wrongBundle }
        guard types.contains(cpuType) else { throw .wrongArchitecture }
    }

    /// An app's Info.plist, read only when it's a regular file of at most 256 KB.
    public static func infoPlist(of app: URL) throws(UpdateFailure) -> [String: Any] {
        let path = app.appendingPathComponent("Contents/Info.plist").path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= maxInfoPlistBytes,
              let data = FileManager.default.contents(atPath: path), data.count <= maxInfoPlistBytes,
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { throw .wrongBundle }
        return plist
    }

    /// The build in an app's Info.plist, or nil.
    public static func build(of app: URL) -> Int? {
        guard let info = try? infoPlist(of: app), let text = info["CFBundleVersion"] as? String else { return nil }
        return Int(text)
    }

    /// The CPU types in a Mach-O file, thin or universal, or nil when it isn't one.
    public static func cpuTypes(of executable: URL) -> [Int32]? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4096), head.count >= 8 else { return nil }
        let bytes = [UInt8](head)
        func big(_ at: Int) -> UInt32? {
            guard at + 4 <= bytes.count else { return nil }
            return UInt32(bytes[at]) << 24 | UInt32(bytes[at + 1]) << 16 | UInt32(bytes[at + 2]) << 8 | UInt32(bytes[at + 3])
        }
        func little(_ at: Int) -> UInt32? { big(at).map { $0.byteSwapped } }
        guard let magic = big(0) else { return nil }
        switch magic {
        case 0xCAFE_BABE, 0xCAFE_BABF:  // universal (fat_arch is 20 bytes, fat_arch_64 is 32)
            guard let count = big(4), count > 0, count < 32 else { return nil }
            let size = magic == 0xCAFE_BABE ? 20 : 32
            var types: [Int32] = []
            for index in 0..<Int(count) {
                guard let type = big(8 + index * size) else { return nil }
                types.append(Int32(bitPattern: type))
            }
            return types
        case 0xCFFA_EDFE, 0xCEFA_EDFE:  // thin, little-endian (MH_MAGIC_64 or MH_MAGIC as read big-endian)
            return little(4).map { [Int32(bitPattern: $0)] }
        default:
            return nil
        }
    }
}

/// Runs a system tool with no input. Its output goes to a private temporary file (so a helper that keeps the
/// output open can't hold us), and it gets a hard deadline: SIGTERM at `timeout`, SIGKILL after a 5-second grace.
enum UpdateTool {
    struct Outcome { let status: Int32; let output: String; let timedOut: Bool }

    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> Outcome {
        let outputURL = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-update-tool-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let output = try? FileHandle(forWritingTo: outputURL) else { return Outcome(status: -1, output: "", timedOut: false) }
        defer { try? output.close(); try? FileManager.default.removeItem(at: outputURL) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = output
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return Outcome(status: -1, output: "", timedOut: false) }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            if exited.wait(timeout: .now() + 5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                if exited.wait(timeout: .now() + 5) == .timedOut {
                    updateLog.error("\(path, privacy: .public) didn’t stop after SIGKILL")
                    return Outcome(status: -9, output: "", timedOut: true)
                }
            }
        }
        let text = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
        return Outcome(status: timedOut ? -9 : process.terminationStatus, output: text, timedOut: timedOut)
    }
}
#endif
