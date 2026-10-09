#if os(macOS)
import Foundation
import SQLite3

// The owner's recent conversations with Codex and Claude Code on this Mac (October 8, 2026, the owner: bring in a
// Codex session as a bot), so Add a Bot can turn one into a bot that keeps going in that same session. Read only and
// best effort, from each agent's own files: Codex's thread list (`$CODEX_HOME/state_<n>.sqlite`, the threads the owner
// started, not its own reviews or `exec` runs) and Claude Code's transcripts (`$CLAUDE_CONFIG_DIR/projects/*/*.jsonl`,
// only the first lines of each, for its folder and first message). Neither is a published interface: a format an
// update changes reads as nothing.

/// A conversation with a coding agent on this Mac that a bot can continue.
public struct CodingSession: Identifiable, Hashable, Sendable {
    /// The agent's own ID for it (Codex's thread ID, Claude Code's session ID), what resuming it takes.
    public var id: String
    /// "codex" or "claude-code" (`CodingAgentKind.id`).
    public var agent: String
    /// Its name, or its first message, shortened.
    public var title: String
    /// The folder it works in.
    public var folder: String
    public var updated: Date
}

public enum CodingSessions {
    /// The newest conversations of both agents, newest first, at most `limit`.
    public static func recent(limit: Int = 12, codexHome: URL? = nil, claudeHome: URL? = nil) -> [CodingSession] {
        let found = codex(home: codexHome ?? defaultCodexHome, limit: limit) + claudeCode(home: claudeHome ?? defaultClaudeHome, limit: limit)
        return Array(found.sorted { $0.updated > $1.updated }.prefix(limit))
    }

    static var defaultCodexHome: URL {
        if let path = ProcessInfo.processInfo.environment["CODEX_HOME"], !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
    }
    static var defaultClaudeHome: URL {
        if let path = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !path.isEmpty { return URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude")
    }

    // MARK: Codex

    /// Codex's threads the owner started (not archived, not a review or an `exec` run), from its newest state database.
    static func codex(home: URL, limit: Int) -> [CodingSession] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []
        let newest = names.compactMap { name -> (Int, String)? in
            guard name.hasPrefix("state_"), name.hasSuffix(".sqlite"), let n = Int(name.dropFirst(6).dropLast(7)) else { return nil }
            return (n, name)
        }.max { $0.0 < $1.0 }
        guard let file = newest?.1 else { return [] }
        var db: OpaquePointer?
        let uri = "file:" + home.appendingPathComponent(file).path + "?mode=ro"
        guard sqlite3_open_v2(uri, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let db else { sqlite3_close(db); return [] }
        defer { sqlite3_close(db) }
        let sql = """
            SELECT id, COALESCE(NULLIF(name, ''), NULLIF(title, ''), first_user_message, ''), cwd, updated_at_ms
            FROM threads WHERE archived = 0 AND thread_source = 'user' AND source <> 'exec'
            ORDER BY updated_at_ms DESC LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(limit))
        var found: [CodingSession] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
            let id = text(0), folder = text(2)
            guard !id.isEmpty, !folder.isEmpty else { continue }
            found.append(CodingSession(id: id, agent: "codex", title: shortened(text(1)), folder: folder,
                                       updated: Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 3)) / 1000)))
        }
        return found
    }

    // MARK: Claude Code

    /// Claude Code's newest transcripts: each one's session ID, folder, and first message.
    static func claudeCode(home: URL, limit: Int) -> [CodingSession] {
        let projects = home.appendingPathComponent("projects")
        let manager = FileManager.default
        var files: [(URL, Date)] = []
        for folder in (try? manager.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            for file in (try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where file.pathExtension == "jsonl" {
                let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                files.append((file, date))
            }
        }
        var found: [CodingSession] = []
        for (file, date) in files.sorted(by: { $0.1 > $1.1 }).prefix(limit * 2) {
            guard let session = claudeSession(file, updated: date) else { continue }
            found.append(session)
            if found.count == limit { break }
        }
        return found
    }

    /// One transcript's session ID, folder, and first message the owner typed, from its first 256 KB.
    static func claudeSession(_ file: URL, updated: Date) -> CodingSession? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: 256 * 1024)) ?? Data()
        var id = file.deletingPathExtension().lastPathComponent, folder = "", title = ""
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            if let cwd = object["cwd"] as? String, folder.isEmpty { folder = cwd }
            if let session = object["sessionId"] as? String, !session.isEmpty { id = session }
            if title.isEmpty, object["type"] as? String == "user", object["isMeta"] as? Bool != true,
               let message = object["message"] as? [String: Any] {
                let content: String? = (message["content"] as? String)
                    ?? (message["content"] as? [[String: Any]])?.first { $0["type"] as? String == "text" }?["text"] as? String
                if let content, !content.hasPrefix("<"), !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { title = content }
            }
            if !folder.isEmpty && !title.isEmpty { break }
        }
        guard !folder.isEmpty, !title.isEmpty, UUID(uuidString: id) != nil else { return nil }
        return CodingSession(id: id, agent: "claude-code", title: shortened(title), folder: folder, updated: updated)
    }

    static func shortened(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        return line.count <= 60 ? line : String(line.prefix(59)) + "…"
    }
}
#endif
