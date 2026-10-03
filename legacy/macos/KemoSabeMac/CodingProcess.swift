import Foundation
import Darwin

/// A child started in its own process group (`posix_spawn` with `POSIX_SPAWN_SETPGROUP`), so the
/// agent or check and every command it starts can be signalled together with `kill(-pgid)`.
/// Only its standard streams are inherited (`POSIX_SPAWN_CLOEXEC_DEFAULT`); no shell is involved.
///
/// The leader is reaped only after its group has been cleaned up, so its process ID (which is
/// also the group ID) can't be reused by an unrelated process while it may still be signalled.
/// A descendant that deliberately leaves the group (`setsid`, `setpgid`) is out of reach.
final class CodingChild: @unchecked Sendable {
    let pid: pid_t
    /// The parent's end of the child's stdin (nil when stdin is /dev/null).
    private var input: FileHandle?
    /// The parent's end of stdout (and of stderr, when merged).
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
            guard pipe(&pair) == 0 else { throw CodingFailure("Could not open a pipe for the agent: " + String(cString: strerror(errno))) }
            // Close-on-exec for every end, so no other child (ours or Foundation's) inherits them;
            // the dup2 file actions below give the child its own copies without the flag.
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
        posix_spawn_file_actions_addchdir(&actions, directory.path)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard result == 0 else { throw CodingFailure("Could not start \(executable.lastPathComponent): " + String(cString: strerror(result))) }

        // The child has its copies; the parent keeps only its own ends.
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
        guard let handle else { throw CodingFailure("Agent connection is closed.") }
        try handle.write(contentsOf: data)
    }
    /// Ends the child's input: well-behaved agents treat that as the end of the session.
    func closeInput() {
        lock.lock(); let handle = input; input = nil; lock.unlock()
        try? handle?.close()
    }
    /// Signals every process in the group, unless the leader was already reaped (its ID could
    /// then belong to someone else).
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
    /// The group's members other than the (possibly exited) leader.
    private func others() -> [pid_t] {
        var buffer = [pid_t](repeating: 0, count: 256)
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(pid), &buffer, Int32(buffer.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { return [] }
        return buffer.prefix(Int(bytes) / MemoryLayout<pid_t>.size).filter { $0 != 0 && $0 != pid }
    }
    /// Blocks until the leader exits. Anything it left running in its group is then stopped
    /// (SIGTERM, up to `grace` seconds, SIGKILL) before the leader is reaped, so nothing it
    /// started is orphaned. Returns the exit code, or 128 + the signal that ended it.
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
    /// The environment agents and checks start with: the person's own, with Homebrew on PATH.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        environment.merge(extra) { $1 }
        return environment
    }
}

/// Newline-delimited agent transport. Both pipes are drained while the child runs;
/// exit is delivered only after stdout has been consumed. No shell interpolation.
@MainActor final class CodingProcess {
    private var child: CodingChild?
    private var buffer = Data()
    /// How long stragglers left in the group after the agent exits get before SIGKILL.
    private let grace: TimeInterval
    var onJSON: (([String: Any]) -> Void)?
    var onError: ((String) -> Void)?
    var onExit: ((Int32) -> Void)?
    var running: Bool { child != nil }
    init(grace: TimeInterval = 3) { self.grace = grace }
    deinit {
        // A transport dropped without a stop still never leaves its agent or commands behind.
        child?.terminate(grace: grace)
    }
    /// `environment` defaults to the person's own with Homebrew on PATH (built-in agents); an
    /// added ACP agent passes only its allow-list (`CodingAgentEnvironment`).
    func start(executable: URL, arguments: [String], directory: URL, environment: [String: String]? = nil) throws {
        guard child == nil else { throw CodingFailure("This agent process is already connected.") }
        let child = try CodingChild.spawn(executable, arguments, directory: directory,
                                          environment: environment ?? CodingChild.environment(["TERM_PROGRAM": "Tsukumo"]), input: true, mergeErrors: false)
        self.child = child
        let group = DispatchGroup(), grace = grace
        for (handle, isError) in [(child.output, false), (child.errors, true)] {
            guard let handle else { continue }
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                defer { group.leave() }
                while true {
                    let bytes = handle.availableData
                    if bytes.isEmpty { break }
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.child === child else { return }
                        if isError { self.onError?(String(decoding: bytes, as: UTF8.self)) }
                        else { self.receive(bytes) }
                    }
                }
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let status = child.waitAndReapGroup(grace: grace)
            // The group is gone, so its pipes close; a descendant that escaped the group and
            // still holds one doesn't hold up the exit report forever.
            _ = group.wait(timeout: .now() + 5)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.child === child else { return }
                self.child = nil; child.closeInput()
                self.onExit?(status)
            }
        }
    }
    func send(_ message: [String: Any]) throws {
        guard let child else { throw CodingFailure("Agent connection is closed.") }
        var data = try JSONSerialization.data(withJSONObject: message); data.append(10)
        try child.write(data)
    }
    private func receive(_ bytes: Data) {
        buffer.append(bytes)
        while let end = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<end]); buffer.removeSubrange(...end)
            guard !line.isEmpty else { continue }
            guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
                onError?("Agent returned a non-JSON line: " + String(decoding: line.prefix(500), as: UTF8.self)); continue
            }
            onJSON?(object)
        }
        if buffer.count > 8_000_000 { onError?("Agent protocol frame exceeded 8 MB."); stop() }
    }
    /// Ends the child's input (for one-shot commands that read a file, not stdin).
    func closeInput() { child?.closeInput() }
    /// Ends the agent and everything it started now: input closed, SIGTERM to the whole
    /// process group, SIGKILL after the grace period.
    func stop() { child?.terminate(grace: grace) }
    /// Gives the agent `wait` seconds to finish on its own (after an interrupt), then stops it as
    /// `stop()` does. The escalation holds the child, not this transport, so it completes even
    /// if the session that asked for it is released right away.
    func shutdown(after wait: TimeInterval) {
        guard let child else { return }
        let grace = grace
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + wait) { child.terminate(grace: grace) }
    }
    static func executable(_ name: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let paths = [home + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        for path in paths {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        throw CodingFailure("Install \(name) and sign in through its terminal, then try again.")
    }
}

/// Finite git/check commands, drained without a pipe deadlock and with a timeout. Each runs in its
/// own process group: a timeout ends everything it started, and anything it leaves running when
/// it exits is stopped too, so a background child can't hold its output open or outlive it.
struct CodingCommandResult: Sendable { var output: String; var code: Int32; var truncated = false }
enum CodingCommand {
    static func run(_ executable: String, _ arguments: [String], at directory: URL, timeout: TimeInterval = 60, environment extra: [String: String] = [:]) async throws -> CodingCommandResult {
        try await Task.detached(priority: .utility) { try runBlocking(executable, arguments, at: directory, timeout: timeout, environment: extra) }.value
    }
    /// The blocking body of `run`, off the main actor.
    private static func runBlocking(_ executable: String, _ arguments: [String], at directory: URL, timeout: TimeInterval, environment extra: [String: String]) throws -> CodingCommandResult {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"; environment["GIT_OPTIONAL_LOCKS"] = "0"
        environment.merge(extra) { $1 }
        let child = try CodingChild.spawn(URL(fileURLWithPath: executable), arguments, directory: directory, environment: environment, input: false, mergeErrors: true)
        let exited = DispatchGroup(); exited.enter()
        DispatchQueue.global(qos: .utility).async { child.waitAndReapGroup(grace: 2); exited.leave() }
        let timer = DispatchSource.makeTimerSource(queue: .global())
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler { child.terminate(grace: 2) }
        timer.resume(); defer { timer.cancel() }
        var captured = Data(), truncated = false
        while let bytes = try child.output.read(upToCount: 65536), !bytes.isEmpty {
            if captured.count + bytes.count > 2_000_000 { truncated = true }
            if captured.count < 2_000_000 { captured.append(bytes.prefix(2_000_000 - captured.count)) }
        }
        exited.wait(); try? child.output.close()
        return CodingCommandResult(output: String(decoding: captured, as: UTF8.self), code: child.status, truncated: truncated)
    }
    static func git(_ arguments: [String], at directory: URL, environment: [String: String] = [:]) async throws -> String {
        let result = try await run("/usr/bin/git", ["-c", "core.quotepath=false"] + arguments, at: directory, environment: environment)
        guard !result.truncated else { throw CodingFailure("Git output exceeds the review limit. Use your editor to review this task.") }
        guard result.code == 0 else { throw CodingFailure(result.output.isEmpty ? "Git exited \(result.code)." : result.output) }
        return result.output.trimmingCharacters(in: .newlines)
    }
}
