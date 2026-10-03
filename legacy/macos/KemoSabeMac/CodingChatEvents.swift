import Foundation

/// Turns what each agent reports into Tsukumo's events, so the transcript can draw them as
/// messages, reasoning, command cards, file edits with diffs, and plans. Pure functions; the
/// sessions call them and tests check them against recorded shapes of each protocol.
enum CodingChatEvents {
    // MARK: Claude Code (stream-json)

    /// A `tool_use` block as a card. Commands keep their command line; edits carry a unified diff
    /// built from the tool's own input (old and new text), so the card can show it before the
    /// Changes pane has reviewed the folder; the to-do list becomes the plan.
    static func claudeTool(name: String, input: [String: Any], id: String, directory: String) -> CodingEvent {
        func string(_ key: String) -> String { input[key] as? String ?? "" }
        let path = relative(string("file_path").isEmpty ? string("notebook_path") : string("file_path"), to: directory)
        switch name {
        case "Bash":
            return .init(id: id, kind: .command, text: string("command"), detail: "", status: "running", tool: name)
        case "Edit":
            let diff = unifiedDiff(path: path, hunks: [(string("old_string"), string("new_string"))])
            return .init(id: id, kind: .file, text: path, detail: diff, status: "running", tool: name)
        case "MultiEdit":
            let edits = (input["edits"] as? [[String: Any]] ?? []).map { ($0["old_string"] as? String ?? "", $0["new_string"] as? String ?? "") }
            return .init(id: id, kind: .file, text: path, detail: unifiedDiff(path: path, hunks: edits), status: "running", tool: name)
        case "Write":
            return .init(id: id, kind: .file, text: path, detail: unifiedDiff(path: path, hunks: [("", string("content"))], added: true), status: "running", tool: name)
        case "NotebookEdit":
            return .init(id: id, kind: .file, text: path, detail: unifiedDiff(path: path, hunks: [("", string("new_source"))]), status: "running", tool: name)
        case "TodoWrite":
            let steps = (input["todos"] as? [[String: Any]] ?? []).map { todo -> String in
                let status = todo["status"] as? String ?? "pending"
                return (status == "in_progress" ? "inProgress" : status) + " · " + (todo["content"] as? String ?? "")
            }
            return .init(id: id, kind: .plan, text: "Plan", detail: steps.joined(separator: "\n"), tool: name)
        default:
            return .init(id: id, kind: .command, text: toolSummary(name: name, input: input, directory: directory), detail: "", status: "running", tool: name)
        }
    }
    /// One line saying what a non-shell tool did: "Read Sources/App.swift", "Search “TODO”".
    static func toolSummary(name: String, input: [String: Any], directory: String) -> String {
        func string(_ key: String) -> String { input[key] as? String ?? "" }
        switch name {
        case "Read": return "Read " + relative(string("file_path"), to: directory)
        case "Grep": return "Search “\(string("pattern"))”" + (string("path").isEmpty ? "" : " in " + relative(string("path"), to: directory))
        case "Glob": return "Find files " + string("pattern")
        case "LS": return "List " + relative(string("path"), to: directory)
        case "WebFetch": return "Fetch " + string("url")
        case "WebSearch": return "Search the web for “\(string("query"))”"
        case "Task", "Agent": return "Subagent: " + (string("description").isEmpty ? string("subagent_type") : string("description"))
        default:
            let first = input.keys.sorted().compactMap { key -> String? in (input[key] as? String).map { "\(key): \($0.prefix(80))" } }.first
            return name + (first.map { " · " + $0 } ?? "")
        }
    }
    /// A `tool_result` block: its text (content is a string or a list of text blocks) and whether it failed.
    static func claudeToolResult(_ block: [String: Any]) -> (text: String, failed: Bool) {
        let text: String
        if let string = block["content"] as? String { text = string }
        else if let parts = block["content"] as? [[String: Any]] { text = parts.compactMap { $0["text"] as? String }.joined(separator: "\n") }
        else { text = "" }
        return (text, block["is_error"] as? Bool == true)
    }

    // MARK: Codex app-server

    /// A `fileChange` item's changes as one unified diff Tsukumo's diff parser reads. Codex sends
    /// each file's patch (`diff`) and kind (add, delete, update with an optional move).
    static func codexFileDiff(_ changes: [[String: Any]], directory: String) -> String {
        changes.map { change -> String in
            let path = relative(change["path"] as? String ?? "", to: directory)
            let kind = (change["kind"] as? [String: Any])?["type"] as? String ?? "update"
            let body = change["diff"] as? String ?? ""
            var out = "diff --git a/\(path) b/\(path)\n"
            if kind == "add" { out += "new file mode 100644\n" } else if kind == "delete" { out += "deleted file mode 100644\n" }
            if body.split(separator: "\n", omittingEmptySubsequences: false).contains(where: { $0.hasPrefix("@@") }) {
                out += body.hasSuffix("\n") || body.isEmpty ? body : body + "\n"
            } else {
                // A whole file added or removed: every line is one side of a single hunk.
                let lines = body.split(separator: "\n", omittingEmptySubsequences: false).dropLast(body.hasSuffix("\n") ? 1 : 0)
                let sign = kind == "delete" ? "-" : "+"
                out += (kind == "delete" ? "@@ -1,\(lines.count) +0,0 @@\n" : "@@ -0,0 +1,\(lines.count) @@\n")
                out += lines.map { sign + $0 + "\n" }.joined()
            }
            return out
        }.joined()
    }
    /// The paths a `fileChange` item touches, relative to the task's folder.
    static func codexPaths(_ changes: [[String: Any]], directory: String) -> [String] {
        changes.compactMap { $0["path"] as? String }.map { relative($0, to: directory) }
    }
    /// A reasoning item's summary (Codex sends summary parts; the raw content is often withheld).
    static func codexReasoning(_ item: [String: Any]) -> String {
        let parts = (item["summary"] as? [Any] ?? []).compactMap { part -> String? in
            if let text = part as? String { return text }
            return (part as? [String: Any])?["text"] as? String
        }
        return parts.joined(separator: "\n\n")
    }

    // MARK: Shared

    /// Codex runs commands through a login shell (`/bin/zsh -lc '…'`); the card shows what ran inside.
    static func displayCommand(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        for shell in ["/bin/zsh -lc ", "/bin/bash -lc ", "bash -lc ", "zsh -lc ", "/bin/sh -c ", "sh -c "] where trimmed.hasPrefix(shell) {
            var inner = String(trimmed.dropFirst(shell.count))
            if inner.count >= 2, let first = inner.first, (first == "'" || first == "\""), inner.last == first {
                inner = String(inner.dropFirst().dropLast())
                if first == "'" { inner = inner.replacingOccurrences(of: "'\\''", with: "'") }
            }
            return inner
        }
        return trimmed
    }
    /// A path inside the task's folder, relative to it; anything else as given.
    static func relative(_ path: String, to directory: String) -> String {
        guard !path.isEmpty, !directory.isEmpty else { return path }
        let base = directory.hasSuffix("/") ? directory : directory + "/"
        if path.hasPrefix(base) { return String(path.dropFirst(base.count)) }
        // The folder may be reached through /private (a temporary folder, /var → /private/var).
        if path.hasPrefix("/private" + base) { return String(path.dropFirst(("/private" + base).count)) }
        if base.hasPrefix("/private/"), path.hasPrefix(String(base.dropFirst("/private".count))) { return String(path.dropFirst(base.count - "/private".count)) }
        return path
    }
    /// A unified diff of text replacements, for edits whose line numbers the tool doesn't report.
    /// Hunks are numbered from 1; the card shows them without line numbers.
    static func unifiedDiff(path: String, hunks: [(old: String, new: String)], added: Bool = false) -> String {
        var out = "diff --git a/\(path) b/\(path)\n" + (added ? "new file mode 100644\n" : "")
        for (old, new) in hunks {
            let oldLines = lines(old), newLines = lines(new)
            out += "@@ -\(oldLines.isEmpty ? 0 : 1),\(oldLines.count) +\(newLines.isEmpty ? 0 : 1),\(newLines.count) @@\n"
            out += oldLines.map { "-" + $0 + "\n" }.joined() + newLines.map { "+" + $0 + "\n" }.joined()
        }
        return out
    }
    private static func lines(_ text: String) -> [String] {
        guard !text.isEmpty else { return [] }
        var parts = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if text.hasSuffix("\n") { parts.removeLast() }
        return parts
    }
}
