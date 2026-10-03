import Foundation
import SwiftUI

// Connecting agents to the KemoSabe MCP server (design/CONTEXT-HARNESS.md#agents-asking-kemosabe).
// - One click in Settings → Connections writes the `kemosabe` server into Claude Code's, Codex's, or
//   Muse's own config, after showing exactly what's written and saving a copy of the file. Other
//   entries are never touched.
// - Sessions Tsukumo launches get the server without any config: Claude Code by `--mcp-config`,
//   Codex by `-c mcp_servers.kemosabe.*`, ACP agents in `session/new`, Muse in `session/start`.

enum KemoSabeMCP {
    static let serverName = "kemosabe"
    /// The helper inside this app: Tsukumo.app/Contents/Helpers/kemosabe-mcp.
    static var bundledHelper: URL? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/kemosabe-mcp")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }
    /// Tests set this to put the server into launched sessions; the test host leaves sessions as they were otherwise.
    nonisolated(unsafe) static var launchOverride: URL??
    /// The helper that launched sessions get, or nil to leave them unchanged.
    static var launchHelper: URL? {
        if let launchOverride { return launchOverride }
        return ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? bundledHelper : nil
    }
    /// Claude Code: `--mcp-config` takes the server as JSON for this session only. A chat hand-off
    /// names itself, so the chat that started Claude shows its question and the answer.
    static func claudeLaunchArguments(handoff: String? = nil) -> [String] {
        guard let helper = launchHelper else { return [] }
        let args = helperArguments(agent: "claude-code", handoff: handoff)
        let config: [String: Any] = ["mcpServers": [serverName: ["type": "stdio", "command": helper.path, "args": args]]]
        guard let data = try? JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes]) else { return [] }
        return ["--mcp-config", String(decoding: data, as: UTF8.self)]
    }
    /// The helper's arguments: the agent's identity, and the chat that started it, when one did.
    static func helperArguments(agent: String, handoff: String? = nil) -> [String] {
        ["--agent", agent] + (handoff.map { ["--handoff", $0] } ?? [])
    }
    /// Codex app-server: config overrides for this process only (`-c key=value`, values in TOML). A chat
    /// hand-off's KemoSabe tool needs no approval (`default_tools_approval_mode`), so asking KemoSabe
    /// is never declined with everything else.
    static func codexLaunchArguments(handoff: String? = nil) -> [String] {
        guard let helper = launchHelper else { return [] }
        var args = ["-c", "mcp_servers.\(serverName).command=" + tomlString(helper.path),
                    "-c", "mcp_servers.\(serverName).args=" + tomlArray(helperArguments(agent: "codex", handoff: handoff)),
                    "-c", "mcp_servers.\(serverName).tool_timeout_sec=180"]
        if handoff != nil { args += ["-c", "mcp_servers.\(serverName).default_tools_approval_mode=\"approve\""] }
        return args
    }
    /// ACP `session/new` and `session/load`: stdio servers are `{name, command, args, env}`.
    static func acpServers(agent: String, handoff: String? = nil) -> [[String: Any]] {
        guard let helper = launchHelper else { return [] }
        return [["name": serverName, "command": helper.path, "args": helperArguments(agent: agent, handoff: handoff), "env": [Any]()]]
    }
    /// MSP `session/start` and `session/resume` `config`, when the host granted `sessionMcp`.
    static func museSessionConfig(handoff: String? = nil) -> [String: Any]? {
        guard let helper = launchHelper else { return nil }
        return ["mcpServers": [serverName: ["transport": "stdio", "command": helper.path, "args": helperArguments(agent: "muse", handoff: handoff),
                                            "mode": "optional", "framing": "lineDelimitedJson"]]]
    }
    /// A TOML array of strings: `["--agent", "codex"]`.
    static func tomlArray(_ items: [String]) -> String { "[" + items.map(tomlString).joined(separator: ", ") + "]" }
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Writes and removes the `kemosabe` entry in each agent's own config file.
struct KemoSabeMCPSetup {
    enum Client: String, CaseIterable, Identifiable {
        case claude, codex, muse
        var id: String { rawValue }
        var title: String { switch self { case .claude: "Claude Code"; case .codex: "Codex"; case .muse: "Muse" } }
        var provider: CodingProvider { switch self { case .claude: .claude; case .codex: .codex; case .muse: .muse } }
        /// The `--agent` the helper is started with, which names the agent to KemoSabe.
        var agent: String { switch self { case .claude: "claude-code"; case .codex: "codex"; case .muse: "muse" } }
    }
    enum Status: Equatable {
        case connected
        /// There's a `kemosabe` entry, but it starts another copy of the helper.
        case otherHelper(String)
        case notConnected
    }
    struct SetupError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    let home: URL
    var environment: [String: String] = ProcessInfo.processInfo.environment
    let helper: String
    static let marker = "# Added by Tsukumo: lets Codex ask KemoSabe (Settings → Connections)."

    /// The file each agent reads its MCP servers from.
    func file(_ client: Client) -> URL {
        func custom(_ name: String) -> URL? { environment[name].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) } }
        switch client {
        case .claude: return (custom("CLAUDE_CONFIG_DIR") ?? home).appendingPathComponent(".claude.json")
        case .codex: return (custom("CODEX_HOME") ?? home.appendingPathComponent(".codex")).appendingPathComponent("config.toml")
        case .muse: return (custom("XDG_CONFIG_HOME") ?? home.appendingPathComponent(".config")).appendingPathComponent("muse/settings.json")
        }
    }
    /// The entry, exactly as it's written.
    func entry(_ client: Client) -> [String: Any] {
        switch client {
        case .claude: ["type": "stdio", "command": helper, "args": ["--agent", client.agent], "env": [String: String]()]
        case .muse: ["type": "stdio", "command": helper, "args": ["--agent", client.agent], "mode": "optional"]
        case .codex: [:]
        }
    }
    var codexBlock: String {
        [Self.marker, "[mcp_servers.\(KemoSabeMCP.serverName)]", "command = " + KemoSabeMCP.tomlString(helper),
         "args = [\"--agent\", \"codex\"]", "tool_timeout_sec = 180"].joined(separator: "\n") + "\n"
    }
    /// What the Connect sheet shows: the text added to the file.
    func preview(_ client: Client) -> String {
        switch client {
        case .codex: return codexBlock
        case .claude, .muse:
            let wrapped: [String: Any] = ["mcpServers": [KemoSabeMCP.serverName: entry(client)]]
            let data = (try? JSONSerialization.data(withJSONObject: wrapped, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data()
            return String(decoding: data, as: UTF8.self)
        }
    }
    /// The command that does the same, for people who'd rather type it.
    func equivalentCommand(_ client: Client) -> String? {
        switch client {
        case .claude: "claude mcp add --scope user \(KemoSabeMCP.serverName) -- \(helper) --agent claude-code"
        case .codex: "codex mcp add \(KemoSabeMCP.serverName) -- \(helper) --agent codex"
        case .muse: nil
        }
    }

    func status(_ client: Client) -> Status {
        let url = file(client)
        guard let data = try? Data(contentsOf: url) else { return .notConnected }
        switch client {
        case .claude, .muse:
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let servers = (object["mcpServers"] ?? object["mcp_servers"]) as? [String: Any],
                  let ours = servers[KemoSabeMCP.serverName] as? [String: Any] else { return .notConnected }
            let command = ours["command"] as? String ?? ""
            return command == helper ? .connected : .otherHelper(command)
        case .codex:
            let text = String(decoding: data, as: UTF8.self)
            guard let range = codexTableRange(in: text) else { return .notConnected }
            let block = text[range]
            if block.contains("command = " + KemoSabeMCP.tomlString(helper)) { return .connected }
            let command = block.split(separator: "\n").first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("command") }
            return .otherHelper(command.map { String($0.split(separator: "=", maxSplits: 1).last ?? "").trimmingCharacters(in: CharacterSet(charactersIn: " \"")) } ?? "")
        }
    }

    /// Adds (or updates) the entry. Returns the backup's location when the file existed.
    @discardableResult func connect(_ client: Client, now: Date = Date()) throws -> URL? {
        try update(client, now: now) { text in
            switch client {
            case .codex:
                var kept = try removingCodexTable(from: text ?? "")
                if !kept.isEmpty, !kept.hasSuffix("\n") { kept += "\n" }
                if !kept.isEmpty, !kept.hasSuffix("\n\n") { kept += "\n" }
                return kept + codexBlock
            case .claude, .muse:
                var object = try jsonObject(text, client: client)
                var servers = try servers(of: &object, client: client)
                servers[KemoSabeMCP.serverName] = entry(client)
                object["mcpServers"] = servers
                return try json(object)
            }
        }
    }
    /// Removes only the `kemosabe` entry. Returns the backup's location, or nil when there was nothing to remove.
    @discardableResult func disconnect(_ client: Client, now: Date = Date()) throws -> URL? {
        guard status(client) != .notConnected else { return nil }
        return try update(client, now: now) { text in
            switch client {
            case .codex:
                return try removingCodexTable(from: text ?? "").replacingOccurrences(of: "\n\n\n", with: "\n\n")
            case .claude, .muse:
                var object = try jsonObject(text, client: client)
                var servers = try servers(of: &object, client: client)
                servers[KemoSabeMCP.serverName] = nil
                object["mcpServers"] = servers
                return try json(object)
            }
        }
    }

    // MARK: Files

    private func update(_ client: Client, now: Date, _ change: (String?) throws -> String) throws -> URL? {
        let url = file(client), manager = FileManager.default
        let existing = manager.fileExists(atPath: url.path) ? try String(contentsOf: url, encoding: .utf8) : nil
        let next = try change(existing)
        var backup: URL?
        let permissions = (try? manager.attributesOfItem(atPath: url.path))?[.posixPermissions]
        if existing != nil {
            let stamp = DateFormatter.kemoBackupStamp.string(from: now)
            let copy = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".before-kemosabe-" + stamp)
            try? manager.removeItem(at: copy)
            try manager.copyItem(at: url, to: copy)
            backup = copy
        } else {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        try Data(next.utf8).write(to: url, options: .atomic)
        if let permissions { try? manager.setAttributes([.posixPermissions: permissions], ofItemAtPath: url.path) }
        return backup
    }
    private func jsonObject(_ text: String?, client: Client) throws -> [String: Any] {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return client == .muse ? ["schema_version": 1] : [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
            throw SetupError(message: "\(file(client).path) isn't valid JSON, so Tsukumo left it alone.")
        }
        return object
    }
    /// The servers table, with Muse's legacy `mcp_servers` folded into `mcpServers` (Muse drops both
    /// when both are present).
    private func servers(of object: inout [String: Any], client: Client) throws -> [String: Any] {
        var servers = object["mcpServers"] as? [String: Any] ?? [:]
        if object["mcpServers"] != nil, object["mcpServers"] as? [String: Any] == nil {
            throw SetupError(message: "mcpServers in \(file(client).path) isn't a table, so Tsukumo left it alone.")
        }
        if client == .muse, let legacy = object["mcp_servers"] as? [String: Any] {
            for (name, value) in legacy where servers[name] == nil { servers[name] = value }
            object["mcp_servers"] = nil
        }
        return servers
    }
    private func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    // MARK: Codex TOML

    /// The `[mcp_servers.kemosabe]` table (with its sub-tables and Tsukumo's comment), if present.
    func codexTableRange(in text: String) -> Range<String.Index>? {
        let lines = text.components(separatedBy: "\n")
        func header(_ line: String) -> String? {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("["), let close = trimmed.firstIndex(of: "]") else { return nil }
            return String(trimmed[trimmed.index(after: trimmed.startIndex)..<close]).replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: " ", with: "")
        }
        let name = "mcp_servers." + KemoSabeMCP.serverName
        guard var start = lines.firstIndex(where: { header($0) == name }) else { return nil }
        var end = start + 1
        while end < lines.count, !(header(lines[end]).map { $0 != name && !$0.hasPrefix(name + ".") } ?? false) { end += 1 }
        if start > 0, lines[start - 1] == Self.marker { start -= 1 }
        let offset = { (line: Int) in text.index(text.startIndex, offsetBy: lines[..<line].reduce(0) { $0 + $1.count + 1 }, limitedBy: text.endIndex) ?? text.endIndex }
        return offset(start)..<offset(end)
    }
    private func removingCodexTable(from text: String) throws -> String {
        var kept = text
        if let range = codexTableRange(in: kept) { kept.removeSubrange(range) }
        // Any other form of the name (an inline table, a dotted key) is left for the person.
        if kept.range(of: #"(?m)^\s*(mcp_servers\.)?"?kemosabe"?\s*[.=]"#, options: .regularExpression) != nil
            || kept.range(of: #"(?m)^\s*\[\s*mcp_servers\s*\.\s*"?kemosabe"?\s*[.\]]"#, options: .regularExpression) != nil {
            throw SetupError(message: "\(file(.codex).path) already names kemosabe in a form Tsukumo doesn't edit. Remove it there, then connect again.")
        }
        return kept
    }
}

extension DateFormatter {
    static let kemoBackupStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

// MARK: Settings → Connections

/// "Let agents ask KemoSabe": Connect for each installed CLI, and the agents allowed to ask.
struct KemoSabeMCPConnectionsCards: View {
    @Environment(AppStore.self) private var store
    @State private var registry = CodingAgentRegistry.shared
    @State private var confirming: KemoSabeMCPSetup.Client?
    @State private var message: String?
    @State private var revision = 0
    private var setup: KemoSabeMCPSetup? {
        KemoSabeMCP.bundledHelper.map { KemoSabeMCPSetup(home: FileManager.default.homeDirectoryForCurrentUser, helper: $0.path) }
    }

    var body: some View {
        SettingsCard(title: "Let agents ask KemoSabe") {
            ForEach(Array(KemoSabeMCPSetup.Client.allCases.enumerated()), id: \.element) { index, client in
                if index > 0 { Divider() }
                row(client)
            }
        }
        .id(revision)
        Text("An agent asks one question, like “What time did she say she was free?” Apple’s on-device model reads your data on this Mac and sends back only the answer. The first time each agent asks, KemoSabe asks you. Agents Tsukumo starts can already ask.")
            .font(.caption).foregroundStyle(.secondary)
        if let message { Text(message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        SettingsCard(title: "Agents allowed to ask") {
            AgentQuestionGrantsList(store: store).padding(.vertical, 12)
        }
        .sheet(item: $confirming) { client in
            if let setup { KemoSabeMCPConnectSheet(setup: setup, client: client) { result in message = result; revision += 1 } }
        }
    }

    @ViewBuilder private func row(_ client: KemoSabeMCPSetup.Client) -> some View {
        let installed = registry.isInstalled(client.provider)
        let status = setup?.status(client) ?? .notConnected
        SettingsRow(title: client.title, detail: detail(client, installed: installed, status: status)) {
            if status == .connected {
                Button("Disconnect") {
                    do {
                        let backup = try setup?.disconnect(client) ?? nil
                        message = "Removed kemosabe from \(setup?.file(client).path ?? "")." + (backup.map { " A copy is at \($0.path)." } ?? "")
                    } catch { message = error.localizedDescription }
                    revision += 1
                }.accessibilityIdentifier("disconnectKemoSabe-" + client.rawValue)
            } else {
                Button(status == .notConnected ? "Connect…" : "Update…") { confirming = client }
                    .disabled(!installed || setup == nil).accessibilityIdentifier("connectKemoSabe-" + client.rawValue)
            }
        }
    }
    private func detail(_ client: KemoSabeMCPSetup.Client, installed: Bool, status: KemoSabeMCPSetup.Status) -> String {
        guard setup != nil else { return "The KemoSabe server isn't in this build of Tsukumo." }
        guard installed else { return "Not installed." }
        switch status {
        case .connected: return "Connected in \(setup?.file(client).path ?? "")."
        case .otherHelper: return "Its kemosabe entry starts another copy of Tsukumo. Update to use this one."
        case .notConnected: return "Adds the kemosabe server to \(client.title)’s own settings."
        }
    }
}

/// Shows exactly what's written, and where, before anything is.
struct KemoSabeMCPConnectSheet: View {
    let setup: KemoSabeMCPSetup
    let client: KemoSabeMCPSetup.Client
    let done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Connect KemoSabe to \(client.title)").font(.title2.bold())
            Text("Tsukumo adds this to \(setup.file(client).path):").font(.callout)
            ScrollView {
                Text(setup.preview(client)).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            }.frame(maxHeight: 200).background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
                .accessibilityIdentifier("kemoSabeMCPPreview")
            Text("A copy of the file is saved beside it first (…before-kemosabe-<date>). Other entries aren’t changed. Restart \(client.title) to load it.")
                .font(.caption).foregroundStyle(.secondary)
            if let command = setup.equivalentCommand(client) {
                Text("Same as running: \(command)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Connect") {
                    do {
                        let backup = try setup.connect(client)
                        done("Connected \(client.title). Restart it to load KemoSabe." + (backup.map { " The earlier file is at \($0.path)." } ?? ""))
                    } catch { done(error.localizedDescription) }
                    dismiss()
                }.keyboardShortcut(.defaultAction).accessibilityIdentifier("confirmConnectKemoSabe")
            }
        }.padding(24).frame(width: 560)
    }
}
