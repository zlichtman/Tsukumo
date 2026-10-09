#if os(macOS)
import Darwin
import Foundation

// The files a task leaves in its own folder, collected for the Inbox, and the files the owner stages into it. Claude
// may have written anything there (links, hard links, deep trees, huge files), so the walk goes through directory
// descriptors only: every folder from / down is opened with O_NOFOLLOW from the one above it, every entry is looked
// at with fstatat without following, and every file is opened from its folder's descriptor with O_NOFOLLOW and
// checked again on that descriptor. Links (symbolic or hard), hidden entries, and anything past the bounds are left
// out. It runs off the main actor.

public enum ClaudeFiles {
    public struct Limits: Sendable {
        public var maxFiles = 20
        /// Entries looked at in all (files and folders).
        public var maxEntries = 500
        public var maxDepth = 4
        public var maxFileBytes = 10 * 1_024 * 1_024
        public var maxTotalBytes = 50 * 1_024 * 1_024
        public var deadline: TimeInterval = 5
        public init() {}
    }

    public struct Collected: Sendable, Hashable {
        /// Its path inside the task's folder.
        public let path: String
        public let data: Data
        public var name: String { (path as NSString).lastPathComponent }
    }

    /// The regular, singly linked, non-hidden files under `base`/`folder`, within `limits`. `base` must be a path with no
    /// links in it (the app's own folder, resolved once); `folder` is one name inside it.
    public static func collect(base: String, folder: String, limits: Limits = Limits()) -> [Collected] {
        guard !folder.contains("/"), folder != "..", folder != "." else { return [] }
        guard let baseFD = openNoFollow(path: base) else { return [] }
        defer { close(baseFD) }
        let rootFD = openat(baseFD, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard rootFD >= 0 else { return [] }
        defer { close(rootFD) }
        var state = Walk(limits: limits, started: Date())
        walk(rootFD, prefix: "", depth: 0, state: &state)
        return state.found
    }

    struct Walk {
        let limits: Limits
        let started: Date
        var entries = 0
        var bytes = 0
        var found: [Collected] = []
        var done: Bool {
            found.count >= limits.maxFiles || entries >= limits.maxEntries || bytes >= limits.maxTotalBytes
                || Date().timeIntervalSince(started) > limits.deadline
        }
    }

    /// One folder, entry by entry as `readdir` returns them (no list is built or sorted first): every entry, hidden ones
    /// included, counts toward the entry limit, and the limits and the deadline are checked before each one.
    private static func walk(_ directory: Int32, prefix: String, depth: Int, state: inout Walk) {
        let listing = dup(directory)
        guard listing >= 0, let dir = fdopendir(listing) else { if listing >= 0 { close(listing) }; return }
        defer { closedir(dir) }
        while !state.done, let entry = readdir(dir) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                String(decoding: raw.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            state.entries += 1
            if name.hasPrefix(".") { continue }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                guard depth < state.limits.maxDepth else { continue }
                let child = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { continue }
                walk(child, prefix: prefix + name + "/", depth: depth + 1, state: &state)
                close(child)
            } else if kind == S_IFREG, info.st_nlink == 1, info.st_size <= off_t(state.limits.maxFileBytes),
                      state.bytes + Int(info.st_size) <= state.limits.maxTotalBytes {
                guard let data = read(at: directory, name: name, expected: info, limit: state.limits.maxFileBytes) else { continue }
                state.bytes += data.count
                state.found.append(Collected(path: prefix + name, data: data))
            }
        }
    }

    /// A file's bytes, opened from its folder without following a link, and only if it's still the same regular,
    /// singly linked file `expected` described.
    static func read(at directory: Int32, name: String, expected: stat, limit: Int) -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        return read(fd, expected: expected, limit: limit)
    }

    static func read(_ fd: Int32, expected: stat?, limit: Int) -> Data? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1, info.st_size <= off_t(limit) else { return nil }
        if let expected, expected.st_ino != info.st_ino || expected.st_dev != info.st_dev { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer in buffer.baseAddress.map { Darwin.read(fd, $0, buffer.count) } ?? 0 }
        guard count == Int(info.st_size) else { return nil }
        return data
    }

    /// Opens a folder by its absolute path, one component at a time from /, never following a link.
    static func openNoFollow(path: String) -> Int32? {
        guard path.hasPrefix("/") else { return nil }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        for part in path.split(separator: "/") where !part.isEmpty {
            guard part != "..", part != "." else { close(fd); return nil }
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        return fd
    }

    /// A file inside a folder the owner picked, by its path relative to it: every folder along the way opened without
    /// following a link, and the file itself a regular, singly linked one, at most `limit`.
    public static func readInside(base: String, relative: String, limit: Int) -> Data? {
        let parts = relative.split(separator: "/").map(String.init)
        guard let last = parts.last, !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty }),
              var fd = openNoFollow(path: realPath(base)) else { return nil }
        for part in parts.dropLast() {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            close(fd)
            guard next >= 0 else { return nil }
            fd = next
        }
        defer { close(fd) }
        let file = openat(fd, last, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { return nil }
        defer { close(file) }
        return read(file, expected: nil, limit: limit)
    }

    /// A path with every link resolved by the system (`realpath`), unlike Foundation's, which drops /private.
    public static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// A file the owner picked, for staging: its bytes, without following a link, at most `limit`.
    public static func readPicked(_ url: URL, limit: Int) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size <= off_t(limit) else { return nil }
        var data = Data(count: Int(info.st_size))
        let count = data.withUnsafeMutableBytes { buffer in buffer.baseAddress.map { Darwin.read(fd, $0, buffer.count) } ?? 0 }
        return count == Int(info.st_size) ? data : nil
    }
}
#endif
