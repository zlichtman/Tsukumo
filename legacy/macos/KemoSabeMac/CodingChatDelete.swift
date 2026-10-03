import Foundation
import SwiftUI

/// Delete…, with a confirmation that says what goes (used for archived tasks in Coordination).
struct CodingDeleteTaskButton: View {
    let task: CodingTaskRecord
    @Environment(CodingWorkspaceStore.self) private var coding
    @State private var confirming = false
    var body: some View {
        Button("Delete…", role: .destructive) { confirming = true }.buttonStyle(DesktopButtonStyle())
            .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirming, titleVisibility: .visible) {
                Button("Delete task", role: .destructive) { Task { await coding.delete(task.id) } }
            } message: { Text(CodingAgentSessionRemoval.summary(task)) }
    }
}

/// The quiet one-line notes a task starts with (the folder is in their detail).
enum CodingTaskNote {
    static let worktree = "Working in its own worktree"
    static let folder = "Working in your project folder"
    /// Notes written by earlier builds, shown the same quiet way.
    static let legacy = ["Created isolated worktree": worktree, "Using your working folder": folder]
    static func isQuiet(_ event: CodingEvent) -> Bool { event.kind == .system && (event.status == "quiet" || legacy[event.text] != nil) }
    static func text(_ event: CodingEvent) -> String { legacy[event.text] ?? event.text }
}

/// Deleting a task also removes the agent's own saved session, so it no longer shows in that
/// agent's app: Codex's thread (`thread/delete`, after `thread/read` confirms it belongs to this
/// task's folder) and Claude Code's transcript file (only the one file whose folder and name match
/// this task's folder and session exactly, and whose contents say so). Nothing is matched by pattern.
enum CodingAgentSessionRemoval {
    /// What the delete confirmation lists.
    /// Each adapter says what it removes (`CodingAgentAdapter.removalPhrase`); an agent that
    /// can't delete its sessions (Cursor Agent's ACP server lists but doesn't delete) is named as keeping it.
    @MainActor static func summary(_ task: CodingTaskRecord) -> String {
        var parts = [task.isolated ? "its worktree and branch (changes you haven't accepted are lost)" : "its conversation in Tsukumo (your project folder isn't changed)"]
        if task.isolated { parts.append("its conversation in Tsukumo") }
        var kept = ""
        if task.sessionID != nil {
            if let phrase = CodingAgentRegistry.shared.adapter(for: task.provider).removalPhrase(task) { parts.append(phrase) }
            else { kept = " \(task.provider.title) keeps its own copy of the conversation; it has no way to delete it." }
        }
        return "This removes " + parts.joined(separator: ", ") + ". It can't be undone." + kept
    }
    /// Removes the task's agent session through its adapter; returns a problem to show, or nil.
    @MainActor static func remove(_ task: CodingTaskRecord) async -> String? {
        guard let session = task.sessionID, !session.isEmpty else { return nil }
        return await CodingAgentRegistry.shared.adapter(for: task.provider).removeSession(task)
    }

    // MARK: Claude Code

    /// `CLAUDE_CONFIG_DIR` when set (the agents start with Tsukumo's environment), else `~/.claude`.
    static var claudeHome: URL {
        if let custom = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !custom.isEmpty { return URL(fileURLWithPath: custom) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude", isDirectory: true)
    }
    /// Claude Code's folder name for a working directory, as its CLI makes it (2.1.282): every UTF-16
    /// unit that isn't an ASCII letter or digit becomes "-"; past 200 units, the first 200 plus "-"
    /// and the base-36 absolute value of the path's 32-bit string hash. Checked against the folders
    /// in `~/.claude/projects` ("/…/KemoSabe : Tsukumo" → "-…-KemoSabe---Tsukumo").
    static func claudeFolderName(_ path: String) -> String {
        let units = path.utf16.map { unit -> UInt16 in
            let ascii = (48...57).contains(unit) || (65...90).contains(unit) || (97...122).contains(unit)
            return ascii ? unit : 45
        }
        guard units.count > 200 else { return String(decoding: units, as: UTF16.self) }
        var hash: Int32 = 0
        for unit in path.utf16 { hash = (hash &<< 5) &- hash &+ Int32(unit) }
        return String(decoding: units.prefix(200), as: UTF16.self) + "-" + String(abs(Int64(hash)), radix: 36)
    }
    /// The one transcript that belongs to this session in this folder, or nil if there isn't one
    /// or it doesn't prove it: a UUID session ID, a regular file (not a link) at exactly
    /// `projects/<folder>/<session>.jsonl`, and every `sessionId` and `cwd` in it matching.
    static func claudeTranscript(session: String, directory: String, home: URL) -> URL? {
        guard UUID(uuidString: session) != nil, !directory.isEmpty else { return nil }
        let folders = Set([directory, URL(fileURLWithPath: directory).resolvingSymlinksInPath().path]).map(claudeFolderName)
        let accepted = Set([directory, URL(fileURLWithPath: directory).standardizedFileURL.path, URL(fileURLWithPath: directory).resolvingSymlinksInPath().path])
        for folder in folders {
            let projects = home.appendingPathComponent("projects", isDirectory: true)
            let file = projects.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(session + ".jsonl")
            guard let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]), values.isRegularFile == true, values.isSymbolicLink != true,
                  file.deletingLastPathComponent().deletingLastPathComponent().standardizedFileURL == projects.standardizedFileURL,
                  let data = try? Data(contentsOf: file) else { continue }
            var sawCwd = false, consistent = true
            for line in data.split(separator: 10) {
                guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
                if let id = object["sessionId"] as? String, id != session { consistent = false; break }
                if let cwd = object["cwd"] as? String { if accepted.contains(cwd) { sawCwd = true } else { consistent = false; break } }
            }
            if consistent && sawCwd { return file }
        }
        return nil
    }
    static func removeClaudeSession(_ session: String, directory: String, home: URL) -> String? {
        guard let file = claudeTranscript(session: session, directory: directory, home: home) else { return nil }
        do {
            try FileManager.default.removeItem(at: file)
            // The session's own folder of subagent transcripts and tool results, when it has one.
            let folder = file.deletingPathExtension()
            if let values = try? folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true {
                try FileManager.default.removeItem(at: folder)
            }
            return nil
        } catch { return "The task was deleted, but Claude Code's saved session couldn't be removed: " + error.localizedDescription }
    }
    static func samePath(_ a: String, _ b: String) -> Bool {
        let left = URL(fileURLWithPath: a), right = URL(fileURLWithPath: b)
        return left.standardizedFileURL == right.standardizedFileURL || left.resolvingSymlinksInPath() == right.resolvingSymlinksInPath()
    }
}

/// One short-lived `codex app-server` that deletes one thread and exits: `initialize`, then
/// `thread/read` to confirm the thread's working directory is this task's folder, then
/// `thread/delete` (the method in the generated schema; there's also `thread/archive`, which only
/// hides it). No turn starts, so nothing is billed.
@MainActor final class CodingCodexThreadDeletion {
    private let threadID: String
    private let directory: String
    private let executableOverride: URL?
    private let transport = CodingProcess(grace: 1)
    private var done: CheckedContinuation<String?, Never>?
    private var timeout: Task<Void, Never>?
    init(threadID: String, directory: String, executableOverride: URL? = nil) {
        self.threadID = threadID; self.directory = directory; self.executableOverride = executableOverride
    }
    /// Nil when the thread is gone (or was already); otherwise what went wrong.
    func run() async -> String? {
        await withCheckedContinuation { continuation in
            done = continuation
            transport.onJSON = { [weak self] in self?.receive($0) }
            transport.onExit = { [weak self] code in self?.finish("Codex exited (\(code)) before removing its thread.") }
            do {
                try transport.start(executable: executableOverride ?? CodingProcess.executable("codex"), arguments: ["app-server", "--listen", "stdio://"], directory: FileManager.default.homeDirectoryForCurrentUser)
                try transport.send(["id": "delete-init", "method": "initialize", "params": ["clientInfo": ["name": "tsukumo", "version": "1.0.0"], "capabilities": ["experimentalApi": true]]])
            } catch { finish(error.localizedDescription); return }
            timeout = Task { [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled else { return }
                self?.finish("Codex didn't answer in time.")
            }
        }
    }
    private func receive(_ object: [String: Any]) {
        let error = (object["error"] as? [String: Any])?["message"] as? String
        switch object["id"] as? String {
        case "delete-init":
            try? transport.send(["method": "initialized"])
            try? transport.send(["id": "delete-read", "method": "thread/read", "params": ["threadId": threadID, "includeTurns": false]])
        case "delete-read":
            if let error {
                // A thread Codex no longer has is already gone.
                finish(error.lowercased().contains("not found") || error.lowercased().contains("no thread") ? nil : "Codex couldn't find its thread: " + error); return
            }
            let cwd = ((object["result"] as? [String: Any])?["thread"] as? [String: Any])?["cwd"] as? String ?? ""
            guard CodingAgentSessionRemoval.samePath(cwd, directory) else { finish("Codex's thread belongs to another folder, so it was left alone."); return }
            try? transport.send(["id": "delete-thread", "method": "thread/delete", "params": ["threadId": threadID]])
        case "delete-thread":
            finish(error.map { "Codex couldn't remove its thread: " + $0 })
        default: break
        }
    }
    private func finish(_ problem: String?) {
        guard let done else { return }
        self.done = nil; timeout?.cancel()
        transport.onExit = nil; transport.stop()
        done.resume(returning: problem.map { "The task was deleted. " + $0 })
    }
}
