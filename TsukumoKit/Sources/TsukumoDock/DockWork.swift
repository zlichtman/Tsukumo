#if os(macOS)
import AppKit
import CoreGraphics
import Foundation
import Observation

// Working from the dock (design/UI-GUIDE.md#the-side-dock), ported from the old Mac app's
// dock: what a coding bot's work is doing, shown as cues on its tile and in
// its bubble, and the coding app that opens its folder and follows the agent's edits. The old app read
// these from its own coding-task store; in TsukumoKit the host (the Tsukumo app, with the coding agents' real
// adapters) fills `BotDock.cues`, so this file holds only what doesn't depend on where tasks live.

/// What a coding bot's work is doing, for the tile and bubble instead of a chat page.
public struct DockWorkCue: Equatable, Sendable {
    public enum Status: String, Equatable, Sendable { case preparing, running, review, failed, stopped, done }
    public enum Tests: String, Equatable, Sendable { case running, passed, failed }
    public var status: Status
    /// The plan's current step, 1-based, of how many, and its words.
    public var step: Int?
    public var steps: Int?
    public var stepTitle: String?
    /// Steps done of all, 0…1.
    public var progress: Double?
    /// The file it's in, and the changed line when known.
    public var file: String?
    public var line: Int?
    public var tests: Tests?
    /// A command or edit waiting for the owner.
    public var approval: String?
    public var risky = false

    public init(status: Status, step: Int? = nil, steps: Int? = nil, stepTitle: String? = nil, progress: Double? = nil, file: String? = nil,
                line: Int? = nil, tests: Tests? = nil, approval: String? = nil, risky: Bool = false) {
        self.status = status; self.step = step; self.steps = steps; self.stepTitle = stepTitle; self.progress = progress
        self.file = file; self.line = line; self.tests = tests; self.approval = approval; self.risky = risky
    }

    public var running: Bool { status == .running || status == .preparing }
    public var ready: Bool { status == .review }

    /// The one line the bubble leads with.
    public var headline: String {
        if let approval { return "Needs your OK: " + approval }
        if ready { return "Ready for review" }
        switch status {
        case .failed: return "Stopped: it failed"
        case .stopped: return "Stopped"
        case .preparing: return "Making a worktree…"
        case .done: return "Accepted"
        default: break
        }
        if tests == .running { return "Running tests" }
        if let step, let steps, let stepTitle { return "\(step) of \(steps): \(stepTitle)" }
        if let file { return "Editing " + (file as NSString).lastPathComponent }
        return "Working…"
    }
    /// "ETAEstimator.swift:42".
    public var fileLabel: String? { file.map { (($0 as NSString).lastPathComponent) + (line.map { ":\($0)" } ?? "") } }

    /// Steps from a plan's lines ("completed · Read the code", "in_progress · Update ETAEstimator").
    public mutating func apply(plan: String) {
        let entries = plan.split(separator: "\n").map { line -> (done: Bool, active: Bool, title: String) in
            let parts = line.components(separatedBy: " · ")
            let state = (parts.first ?? "").lowercased(), title = parts.dropFirst().joined(separator: " · ").trimmingCharacters(in: .whitespaces)
            return (["completed", "done"].contains(state), ["inprogress", "in_progress", "active"].contains(state), title)
        }.filter { !$0.title.isEmpty }
        guard !entries.isEmpty else { return }
        let done = entries.filter(\.done).count
        let current = entries.firstIndex(where: \.active) ?? entries.firstIndex { !$0.done } ?? entries.count - 1
        steps = entries.count; step = current + 1; stepTitle = entries[current].title
        progress = Double(done) / Double(entries.count)
    }
    /// Whether a command runs tests.
    public static func isTest(_ command: String) -> Bool {
        let text = command.lowercased()
        return [" test", "test ", "pytest", "jest", "vitest", "xcodebuild test", "cargo test", "go test", "npm test"].contains { text.contains($0) } || text.hasPrefix("test")
    }
}

// MARK: Following the agent in your editor

/// A coding app the owner watches agents in.
public struct EditorTarget: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case xcode, cursor, vscode, zed, other }
    public var bundleID: String
    public var name: String
    /// Where the app is.
    public var path: String
    public init(bundleID: String, name: String, path: String) { self.bundleID = bundleID; self.name = name; self.path = path }
    public var kind: Kind {
        switch bundleID {
        case "com.apple.dt.Xcode": .xcode
        case "com.todesktop.230313mzl4w4u92": .cursor
        case "com.microsoft.VSCode": .vscode
        case "dev.zed.Zed": .zed
        default: .other
        }
    }
    /// The editors Tsukumo knows how to follow, by bundle ID.
    public static let known: [(bundleID: String, name: String)] = [
        ("com.apple.dt.Xcode", "Xcode"), ("com.todesktop.230313mzl4w4u92", "Cursor"), ("com.microsoft.VSCode", "Visual Studio Code"), ("dev.zed.Zed", "Zed")
    ]
    /// Known editors installed on this Mac.
    @MainActor public static func installed() -> [EditorTarget] {
        known.compactMap { entry in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: entry.bundleID).map { EditorTarget(bundleID: entry.bundleID, name: entry.name, path: $0.path) }
        }
    }
}

/// A program and its arguments.
public struct ShellCommand: Equatable, Sendable {
    public var executable: String
    public var arguments: [String]
    public init(executable: String, arguments: [String]) { self.executable = executable; self.arguments = arguments }
}

/// The commands that open a folder in an editor and reveal a file at a line (built, never run, in tests).
public enum EditorFollow {
    public static func open(project: URL, in editor: EditorTarget) -> ShellCommand {
        switch editor.kind {
        case .xcode: .init(executable: "/usr/bin/xed", arguments: [project.path])
        case .cursor, .vscode: .init(executable: cli(editor), arguments: ["-n", project.path])
        case .zed: .init(executable: cli(editor), arguments: [project.path])
        case .other: .init(executable: "/usr/bin/open", arguments: ["-a", editor.path, project.path])
        }
    }
    public static func reveal(_ file: URL, line: Int?, in editor: EditorTarget) -> ShellCommand {
        let located = file.path + (line.map { ":\($0)" } ?? "")
        switch editor.kind {
        case .xcode: return .init(executable: "/usr/bin/xed", arguments: (line.map { ["--line", String($0)] } ?? []) + [file.path])
        case .cursor, .vscode: return .init(executable: cli(editor), arguments: ["-r", "-g", located])
        case .zed: return .init(executable: cli(editor), arguments: [located])
        case .other: return .init(executable: "/usr/bin/open", arguments: ["-a", editor.path, file.path])
        }
    }
    /// Each app's own command-line tool, inside the app, so nothing has to be on PATH.
    public static func cli(_ editor: EditorTarget) -> String {
        switch editor.kind {
        case .cursor: editor.path + "/Contents/Resources/app/bin/cursor"
        case .vscode: editor.path + "/Contents/Resources/app/bin/code"
        case .zed: editor.path + "/Contents/MacOS/cli"
        default: "/usr/bin/open"
        }
    }
    /// A path an agent reported, made absolute against its folder.
    public static func url(_ path: String, in directory: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : URL(fileURLWithPath: directory).appendingPathComponent(path)
    }
    /// The changed line: where the edit's first added line is in the file now, or the diff's hunk start.
    public static func line(in diff: String, file: URL?, contents: String? = nil) -> Int? {
        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false)
        let added = lines.first { $0.hasPrefix("+") && !$0.hasPrefix("+++") && !$0.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty }
            .map { String($0.dropFirst()) }
        if let added, let text = contents ?? file.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) {
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line == Substring(added) { return index + 1 }
        }
        guard let header = lines.first(where: { $0.hasPrefix("@@") }),
              let plus = header.split(separator: " ").first(where: { $0.hasPrefix("+") }),
              let start = Int(plus.dropFirst().split(separator: ",").first ?? "") else { return nil }
        return start > 1 ? start : nil
    }
}

/// At most one reveal every few seconds.
public struct FollowThrottle: Equatable, Sendable {
    public var interval: TimeInterval = 4
    public private(set) var lastFired: Date?
    public init(interval: TimeInterval = 4) { self.interval = interval }
    public func ready(at now: Date) -> Bool { lastFired.map { now.timeIntervalSince($0) >= interval } ?? true }
    /// Seconds until the next reveal may go.
    public func wait(at now: Date) -> TimeInterval { lastFired.map { max(0, interval - now.timeIntervalSince($0)) } ?? 0 }
    public mutating func fired(at now: Date) { lastFired = now }
}

/// Never pull the owner out of what they're typing: follow only while the editor or the host is in
/// front, or the keyboard has been idle a while.
public enum FollowGate {
    public static let idleKeyboard: TimeInterval = 8
    public static func allows(frontmost: String?, editor: String, own: String, keyboardIdle: TimeInterval) -> Bool {
        frontmost == editor || frontmost == own || keyboardIdle >= idleKeyboard
    }
}

/// Opens a coding bot's folder in the chosen editor and reveals each file the agent edits.
@MainActor @Observable public final class EditorFollower {
    /// The chosen editor (nil: don't open one).
    @ObservationIgnored public var editor: () -> EditorTarget? = { nil }
    @ObservationIgnored public var run: (ShellCommand) -> Void = EditorFollower.launch
    @ObservationIgnored public var frontmost: () -> String? = { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }
    @ObservationIgnored public var keyboardIdle: () -> TimeInterval = { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown) }
    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored public var own = Bundle.main.bundleIdentifier ?? "com.zlichtman.tsukumo"
    @ObservationIgnored public private(set) var throttle = FollowThrottle()
    @ObservationIgnored private var opened: Set<String> = []
    @ObservationIgnored private var pending: (file: URL, line: Int?)?
    @ObservationIgnored private var retry: Task<Void, Never>?
    /// What was last shown ("ETAEstimator.swift:42").
    public private(set) var lastShown: String?

    public init() {}

    /// Work started in a folder: it opens in the editor, once.
    public func started(folder: URL) {
        guard let editor = editor(), !opened.contains(folder.path) else { return }
        opened.insert(folder.path)
        run(EditorFollow.open(project: folder, in: editor))
    }
    /// The agent edited a file: reveal it (throttled, and never while the owner types elsewhere).
    public func request(_ file: URL, line: Int?) {
        pending = (file, line)
        flush()
    }
    /// Reveals the latest pending file if the throttle and the gate allow; otherwise tries again later.
    public func flush() {
        guard let pending, let editor = editor() else { return }
        let now = now()
        guard throttle.ready(at: now) else { schedule(throttle.wait(at: now)); return }
        guard FollowGate.allows(frontmost: frontmost(), editor: editor.bundleID, own: own, keyboardIdle: keyboardIdle()) else { schedule(2); return }
        self.pending = nil
        throttle.fired(at: now)
        run(EditorFollow.reveal(pending.file, line: pending.line, in: editor))
        lastShown = pending.file.lastPathComponent + (pending.line.map { ":\($0)" } ?? "")
    }
    private func schedule(_ seconds: TimeInterval) {
        guard retry == nil else { return }
        retry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.2, seconds)))
            self?.retry = nil
            self?.flush()
        }
    }

    public nonisolated static func launch(_ command: ShellCommand) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command.executable)
        process.arguments = command.arguments
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
#endif
