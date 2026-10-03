import SwiftUI
import UniformTypeIdentifiers

/// Provider-neutral, read-only coordination evidence. Importing a snapshot never
/// authorizes file access, execution, disclosure, or an agent-to-agent message.
struct WeaveSnapshot: Codable, Equatable {
    struct Agent: Codable, Identifiable, Equatable {
        let id: String
        let provider: String
        let task: String
        let state: String
        let files: [String]
    }
    struct Message: Codable, Identifiable, Equatable {
        let id: String
        let from: String
        let to: String
        let text: String
        let acknowledged: Bool
    }
    let version: Int
    let project: String
    let revision: Int
    let agents: [Agent]
    let messages: [Message]
    static func decode(_ data: Data, project: String) throws -> Self {
        guard data.count <= 256_000 else { throw CocoaError(.fileReadTooLarge) }
        let result = try JSONDecoder().decode(Self.self, from: data)
        let ids = Set(result.agents.map(\.id))
        guard result.version == 1, result.project == project, result.revision >= 0,
              result.agents.count <= 32, ids.count == result.agents.count,
              result.messages.count <= 200, Set(result.messages.map(\.id)).count == result.messages.count,
              result.agents.allSatisfy({ agent in
                  !agent.id.isEmpty && agent.id.count <= 100 && agent.provider.count <= 100 && agent.task.count <= 1000 &&
                  ["Planning", "Working", "Waiting", "Review", "Done", "Failed"].contains(agent.state) && agent.files.count <= 100 && agent.files.allSatisfy(validPath)
              }), result.messages.allSatisfy({ ids.contains($0.from) && ids.contains($0.to) && $0.text.count <= 2000 && !$0.id.isEmpty }) else { throw CocoaError(.fileReadCorruptFile) }
        return result
    }
    static func validPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        return !path.isEmpty && path.count <= 500 && !path.contains("\\") && !path.contains("\0") && !parts.contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
    var files: [String] { Array(Set(agents.flatMap(\.files))).sorted() }
    func owners(_ file: String) -> [Agent] {
        agents.filter { $0.state != "Done" && $0.state != "Failed" && $0.files.contains { $0 == file || $0.hasPrefix(file + "/") || file.hasPrefix($0 + "/") } }
    }
    var conflicts: [String] { files.filter { owners($0).count > 1 } }
    static func example(project: String) -> Self {
        .init(version: 1, project: project, revision: 1, agents: [
            .init(id: "claude", provider: "Claude Code", task: "Handle the sign-in issue", state: "Working", files: ["src/auth/session.ts", "src/auth/token.ts"]),
            .init(id: "codex", provider: "Codex", task: "Add regression coverage", state: "Waiting", files: ["src/auth/session.ts", "tests/auth.test.ts"]),
            .init(id: "review", provider: "Cursor", task: "Review the patch", state: "Planning", files: ["tests/auth.test.ts"])
        ], messages: [
            .init(id: "m1", from: "claude", to: "codex", text: "I plan to change session.ts and token.ts. Can you own the regression tests?", acknowledged: true),
            .init(id: "m2", from: "codex", to: "claude", text: "I can cover the tests. My earlier session.ts claim still needs to be released.", acknowledged: false)
        ])
    }
}
struct WeaveBoard: View {
    let project: String
    @State private var snapshot: WeaveSnapshot?
    @State private var example = false
    @State private var selected: String?
    @State private var importing = false
    @State private var error = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("Coordination").font(.system(size: 15, weight: .medium))
                Spacer()
                if snapshot != nil { Text(example ? "Example · no agents running" : "Imported snapshot · not live").font(.caption).foregroundStyle(.secondary) }
                Button("Import snapshot…") { importing = true }.disabled(project.isEmpty)
                if snapshot != nil { Button("Clear") { snapshot = nil; selected = nil; example = false } }
            }
            if let snapshot {
                if !snapshot.conflicts.isEmpty {
                    Label("\(snapshot.conflicts.count) possible file overlaps · claims are advisory", systemImage: "arrow.triangle.branch").font(.caption).foregroundStyle(.orange)
                }
                ScrollView {
                    HStack(alignment: .top, spacing: 28) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("AGENTS").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            ForEach(snapshot.agents) { agent in
                                Button { selected = agent.id } label: {
                                    VStack(alignment: .leading, spacing: 7) {
                                        HStack { Image(systemName: "circle.hexagongrid"); Text(agent.provider).fontWeight(.medium); Spacer(); Text(agent.state).font(.system(size: 10)).foregroundStyle(.secondary) }
                                        Text(agent.task).foregroundStyle(.secondary).lineLimit(2)
                                        Text("\(agent.files.count) file claims →").font(.system(size: 10)).foregroundStyle(.secondary)
                                    }.font(.system(size: 12)).padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                        .background(Color.primary.opacity(selected == agent.id ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 9))
                                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.primary.opacity(selected == agent.id ? 0.24 : 0.08)))
                                }.buttonStyle(.plain)
                            }
                        }.frame(maxWidth: .infinity)
                        VStack(alignment: .leading, spacing: 10) {
                            Text("FILES").font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                            ForEach(snapshot.files, id: \.self) { file in
                                let owners = snapshot.owners(file)
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Image(systemName: owners.count > 1 ? "exclamationmark.triangle" : "doc.text"); Text(file).font(.system(size: 11, design: .monospaced)).lineLimit(2) }
                                    Text(owners.map(\.provider).joined(separator: " ↔ ")).font(.system(size: 10)).foregroundStyle(.secondary)
                                }.padding(13).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(owners.count > 1 ? Color.orange.opacity(0.065) : Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
                                    .opacity(selected == nil || owners.contains(where: { $0.id == selected }) ? 1 : 0.35)
                            }
                        }.frame(maxWidth: .infinity)
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Handoffs & messages").font(.system(size: 13, weight: .medium))
                        ForEach(snapshot.messages.filter { selected == nil || $0.from == selected || $0.to == selected }) { message in
                            messageRow(message, snapshot: snapshot)
                        }
                    }.padding(.top, 24)
                }
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").font(.system(size: 26)).foregroundStyle(.secondary)
                    Text("No connected agents").font(.system(size: 16, weight: .medium))
                    Text("Agent activity, file claims and handoffs will appear here.").font(.system(size: 12)).foregroundStyle(.secondary)
                    Button("Preview coordination") { snapshot = .example(project: project.isEmpty ? "Example project" : project); example = true }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if !error.isEmpty { Text(error).font(.caption).foregroundStyle(.orange) }
        }.padding(22).fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get(); let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
                let next = try WeaveSnapshot.decode(handle.read(upToCount: 256_001) ?? Data(), project: project)
                if let old = snapshot, !example, next.revision <= old.revision { throw CocoaError(.fileReadCorruptFile) }
                snapshot = next; example = false; selected = nil; error = ""
            } catch { self.error = "Snapshot rejected. Check the project name, revision, agents and relative file paths." }
        }.onChange(of: project) { snapshot = nil; example = false; selected = nil }
    }
    private func messageRow(_ message: WeaveSnapshot.Message, snapshot: WeaveSnapshot) -> some View {
        let from = snapshot.agents.first(where: { $0.id == message.from })?.provider ?? message.from
        let to = snapshot.agents.first(where: { $0.id == message.to })?.provider ?? message.to
        let heading: String = from + " → " + to
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(heading).font(.system(size: 11, weight: .medium))
                Spacer()
                Text(message.acknowledged ? "Acknowledged" : "No acknowledgment").font(.system(size: 10)).foregroundStyle(.secondary)
            }
            Text(message.text).font(.system(size: 12)).textSelection(.enabled)
        }.padding(12).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
    }
    private func name(_ id: String, in snapshot: WeaveSnapshot) -> String { snapshot.agents.first(where: { $0.id == id })?.provider ?? id }
}
