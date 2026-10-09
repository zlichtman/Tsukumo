#if os(macOS)
import Foundation
import Darwin

// How a coding agent CLI runs (ported from `CodingProcess.swift` in the old Tsukumo app, where it ran
// in production): its own process group, so the agent and every command it starts are stopped together;
// newline-delimited JSON both ways; no shell anywhere.

/// Why a coding agent couldn't run or stopped, in words to show.
public struct CodingAgentFailure: Error, Hashable, Sendable, LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A child started in its own process group (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`), so the
/// agent and everything it starts can be signalled together with `kill(-pgid)`. Only its standard
/// streams are inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`).
///
/// The leader is reaped only after its group has been cleaned up, so its process ID (which is also
/// the group ID) can't be reused by an unrelated process while it may still be signalled. A
/// descendant that deliberately leaves the group (`setsid`, `setpgid`) is out of reach.
final class CodingChild: @unchecked Sendable {
    let pid: pid_t
    private var input: FileHandle?
    let output: FileHandle
    let errors: FileHandle?
    private let lock = NSLock()
    private var reaped = false
    private(set) var status: Int32 = 0

    static func spawn(_ executable: URL, _ arguments: [String], directory: URL, environment: [String: String],
                      input: Bool, mergeErrors: Bool) throws -> CodingChild {
        var fds: [Int32] = []
        defer { for fd in fds where fd >= 0 { close(fd) } }
        func pipePair() throws -> (read: Int32, write: Int32) {
            var pair: [Int32] = [-1, -1]
            guard pipe(&pair) == 0 else { throw CodingAgentFailure("Couldn’t open a pipe for the agent: " + String(cString: strerror(errno))) }
            // Close-on-exec for every end, so no other child inherits them; dup2 gives the child its own copies.
            for fd in pair { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
            fds += pair
            return (pair[0], pair[1])
        }
        let stdout = try pipePair()
        var stderr: (read: Int32, write: Int32)?, stdin: (read: Int32, write: Int32)?
        if !mergeErrors { stderr = try pipePair() }
        if input { stdin = try pipePair() }
        // Writing to an agent that already exited reports EPIPE instead of killing the app.
        if let stdin { _ = fcntl(stdin.write, F_SETNOSIGPIPE, 1) }

        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes); defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))
        posix_spawnattr_setpgroup(&attributes, 0)
        var all = sigset_t(), none = sigset_t(); sigfillset(&all); sigemptyset(&none)
        posix_spawnattr_setsigdefault(&attributes, &all); posix_spawnattr_setsigmask(&attributes, &none)
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions); defer { posix_spawn_file_actions_destroy(&actions) }
        if let stdin { posix_spawn_file_actions_adddup2(&actions, stdin.read, 0) }
        else { posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0) }
        posix_spawn_file_actions_adddup2(&actions, stdout.write, 1)
        posix_spawn_file_actions_adddup2(&actions, stderr?.write ?? stdout.write, 2)
        posix_spawn_file_actions_addchdir_np(&actions, directory.path)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw CodingAgentFailure("Couldn’t start \(executable.lastPathComponent): " + String(cString: strerror(result))) }

        let keep = [stdout.read, stderr?.read, stdin?.write].compactMap { $0 }
        for fd in fds where !keep.contains(fd) { close(fd) }
        fds = []
        return CodingChild(pid: pid,
                           input: stdin.map { FileHandle(fileDescriptor: $0.write, closeOnDealloc: true) },
                           output: FileHandle(fileDescriptor: stdout.read, closeOnDealloc: true),
                           errors: stderr.map { FileHandle(fileDescriptor: $0.read, closeOnDealloc: true) })
    }
    private init(pid: pid_t, input: FileHandle?, output: FileHandle, errors: FileHandle?) {
        self.pid = pid; self.input = input; self.output = output; self.errors = errors
    }

    func write(_ data: Data) throws {
        lock.lock(); let handle = input; lock.unlock()
        guard let handle else { throw CodingAgentFailure("The agent’s connection is closed.") }
        try handle.write(contentsOf: data)
    }
    /// Ends the child's input: well-behaved agents treat that as the end of the session.
    func closeInput() {
        lock.lock(); let handle = input; input = nil; lock.unlock()
        try? handle?.close()
    }
    /// Signals every process in the group, unless the leader was already reaped.
    func signalGroup(_ signal: Int32) {
        lock.lock(); defer { lock.unlock() }
        guard !reaped else { return }
        kill(-pid, signal)
    }
    /// Closes input, asks the whole group to stop (SIGTERM), and forces it (SIGKILL) after `grace`.
    func terminate(grace: TimeInterval) {
        closeInput(); signalGroup(SIGTERM)
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + grace) { [self] in signalGroup(SIGKILL) }
    }
    private func others() -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 != 0 && $0 != pid }
    }
    /// Blocks until the leader exits; anything it left in its group is stopped (SIGTERM, up to `grace`,
    /// SIGKILL) before the leader is reaped. Returns the exit code, or 128 + the signal that ended it.
    @discardableResult func waitAndReapGroup(grace: TimeInterval) -> Int32 {
        var info = siginfo_t()
        while waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) == -1, errno == EINTR {}
        if !others().isEmpty {
            signalGroup(SIGTERM)
            let deadline = Date().addingTimeInterval(grace)
            while !others().isEmpty, Date() < deadline { usleep(50_000) }
            signalGroup(SIGKILL)
        }
        lock.lock(); defer { lock.unlock() }
        var raw: Int32 = 0
        while waitpid(pid, &raw, 0) == -1, errno == EINTR {}
        reaped = true
        let signal = raw & 0x7f
        status = signal == 0 ? (raw >> 8) & 0xff : 128 + signal
        return status
    }
}

/// A coding agent's process, speaking newline-delimited JSON. Both pipes are drained while it runs;
/// lines and the exit are delivered in order on `queue`, the owner's serial queue.
final class CodingLineProcess: @unchecked Sendable {
    let child: CodingChild
    private let queue: DispatchQueue
    private let grace: TimeInterval
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail = ""
    private var ended = false

    /// Starts `executable` in `directory`. `onJSON` gets each JSON object line, `onExit` the exit code and
    /// the end of what it wrote to stderr; both on `queue`.
    init(executable: URL, arguments: [String], directory: URL, environment: [String: String], queue: DispatchQueue,
         grace: TimeInterval = 2, onJSON: @escaping @Sendable ([String: Any]) -> Void,
         onExit: @escaping @Sendable (Int32, String) -> Void) throws {
        self.queue = queue; self.grace = grace
        child = try CodingChild.spawn(executable, arguments, directory: directory, environment: environment, input: true, mergeErrors: false)
        let child = self.child
        let readers = DispatchGroup()
        for (handle, isError) in [(child.output, false), (child.errors, true)] {
            guard let handle else { continue }
            readers.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { readers.leave() }
                while true {
                    let bytes = handle.availableData
                    if bytes.isEmpty { break }
                    guard let self else { continue }
                    if isError { self.noteError(bytes) } else {
                        for object in self.lines(bytes) { queue.async { onJSON(object) } }
                    }
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = child.waitAndReapGroup(grace: grace)
            // The group is gone, so its pipes close; a descendant that escaped still holding one doesn't
            // hold the exit up for long.
            _ = readers.wait(timeout: .now() + 3)
            let tail = self?.lock.withLock { self?.errorTail ?? "" } ?? ""
            queue.async { onExit(status, tail) }
        }
    }

    private func lines(_ bytes: Data) -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        buffer.append(bytes)
        var objects: [[String: Any]] = []
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[buffer.startIndex..<end]); buffer.removeSubrange(buffer.startIndex...end)
            Self.trace("<", line)
            guard !line.isEmpty, let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { continue }
            objects.append(object)
        }
        // A frame past 16 MB is not a protocol message.
        if buffer.count > 16_000_000 { buffer.removeAll(); DispatchQueue.global().async { [child, grace] in child.terminate(grace: grace) } }
        return objects
    }
    private func noteError(_ bytes: Data) {
        lock.withLock { errorTail = String((errorTail + String(decoding: bytes, as: UTF8.self)).suffix(2000)) }
    }

    func send(_ message: [String: Any]) throws {
        var data = try JSONSerialization.data(withJSONObject: message, options: [.withoutEscapingSlashes])
        Self.trace(">", data)
        data.append(10)
        try child.write(data)
    }

    /// For checking an agent's wire format during development: with `TSUKUMO_CODING_TRACE` set to a file,
    /// every line both ways is appended to it. Never set in the app.
    private static let traceFile = ProcessInfo.processInfo.environment["TSUKUMO_CODING_TRACE"]
    private static let traceLock = NSLock()
    private static func trace(_ direction: String, _ line: Data) {
        guard let traceFile else { return }
        traceLock.withLock {
            guard let handle = FileHandle(forWritingAtPath: traceFile) ?? {
                FileManager.default.createFile(atPath: traceFile, contents: nil); return FileHandle(forWritingAtPath: traceFile)
            }() else { return }
            handle.seekToEndOfFile()
            handle.write(Data((direction + " ").utf8) + line + Data([10]))
            try? handle.close()
        }
    }
    func closeInput() { child.closeInput() }
    /// Ends the agent and everything it started now: input closed, SIGTERM to the group, SIGKILL after the grace.
    func stop() { child.terminate(grace: grace) }
    /// Gives the agent `wait` seconds to wind down on its own (after an interrupt), then stops it.
    func stop(after wait: TimeInterval) {
        let child = child, grace = grace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { child.terminate(grace: grace) }
    }
}

/// Where coding agents are found and the environment they run in. A Mac app gets launchd's short PATH,
/// so the owner's login shell is asked for theirs (where npm, nvm, Homebrew, and ~/.local/bin put CLIs).
public enum CodingEnvironment {
    /// The usual places, before PATH: Claude Code's and Cursor's installers, Homebrew, and the common
    /// homes of npm, Bun, Volta, and pnpm globals.
    public static func wellKnownDirectories(home: String) -> [String] {
        [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", home + "/.npm-global/bin", home + "/.bun/bin",
         home + "/.volta/bin", home + "/Library/pnpm", home + "/.cargo/bin", home + "/bin"]
    }

    /// Every folder searched, in order, without repeats: the well-known ones, the login shell's PATH, then this
    /// process's PATH, then the system's.
    public static func searchPath(home: String = NSHomeDirectory(), loginPATH: String?, processPATH: String?) -> [String] {
        var seen = Set<String>(), result: [String] = []
        let all = wellKnownDirectories(home: home) + (loginPATH ?? "").split(separator: ":").map(String.init)
            + (processPATH ?? "").split(separator: ":").map(String.init) + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        for path in all where !path.isEmpty && seen.insert(path).inserted { result.append(path) }
        return result
    }

    /// Finds a program by name in `path`, or takes a path as given (`~` expanded).
    public static func find(_ command: String, in path: [String]) -> URL? {
        if command.contains("/") {
            let expanded = (command as NSString).expandingTildeInPath
            return FileManager.default.isExecutableFile(atPath: expanded) ? URL(fileURLWithPath: expanded) : nil
        }
        for folder in path {
            let url = URL(fileURLWithPath: folder).appendingPathComponent(command)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// The owner's login shell's PATH (`$SHELL -l -c`, a few seconds at most), or nil.
    public static func loginShellPATH(shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
                                      timeout: TimeInterval = 4) -> String? {
        guard FileManager.default.isExecutableFile(atPath: shell) else { return nil }
        let marker = "__TSUKUMO_PATH__"
        guard let output = try? run(URL(fileURLWithPath: shell), ["-l", "-c", "printf '\(marker)%s\(marker)' \"$PATH\""],
                                    timeout: timeout, environment: ProcessInfo.processInfo.environment) else { return nil }
        let parts = output.output.components(separatedBy: marker)
        guard parts.count >= 3, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    /// The environment an agent starts with: the owner's own, with `path` as PATH, so the agent finds
    /// what it runs (node, git) the way it does in a terminal.
    public static func environment(path: [String], base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var environment = base
        environment["PATH"] = path.joined(separator: ":")
        environment["TERM_PROGRAM"] = "Tsukumo"
        environment["NO_COLOR"] = "1"
        return environment
    }

    /// The variables a sealed agent keeps from `base`: where programs are, the owner's home and name (where its sign-in
    /// lives: the login keychain and `~/.claude`), temporary files, the locale, a different config folder or a sign-in the
    /// owner set by variable, and a proxy or certificates the network needs. Nothing else of the owner's environment.
    public static let sealedKeys = ["PATH", "HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "CLAUDE_CONFIG_DIR",
                                    "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "HTTPS_PROXY", "HTTP_PROXY", "NO_PROXY", "https_proxy",
                                    "http_proxy", "no_proxy", "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS"]

    /// A sealed agent's environment: only `sealedKeys` from `base`, plus Tsukumo's own markers and no self-updates mid-task.
    public static func sealed(from base: [String: String]) -> [String: String] {
        var environment = base.filter { sealedKeys.contains($0.key) }
        environment["TERM_PROGRAM"] = "Tsukumo"
        environment["NO_COLOR"] = "1"
        environment["DISABLE_AUTOUPDATER"] = "1"
        return environment
    }

    /// Runs a short command (a version check) to the end, its output and stderr merged, ended after `timeout`.
    public static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, environment: [String: String],
                           directory: URL = FileManager.default.temporaryDirectory) throws -> (output: String, code: Int32) {
        let child = try CodingChild.spawn(executable, arguments, directory: directory, environment: environment, input: false, mergeErrors: true)
        let exited = DispatchGroup(); exited.enter()
        DispatchQueue.global(qos: .utility).async { child.waitAndReapGroup(grace: 1); exited.leave() }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { child.terminate(grace: 1) }
        timer.resume(); defer { timer.cancel() }
        var captured = Data()
        while let bytes = try? child.output.read(upToCount: 65536), !bytes.isEmpty {
            if captured.count < 200_000 { captured.append(bytes) }
        }
        exited.wait(); try? child.output.close()
        return (String(decoding: captured, as: UTF8.self), child.status)
    }
}
#endif
