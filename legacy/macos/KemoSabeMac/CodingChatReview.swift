import SwiftUI
import AppKit

// MARK: Run with both: compare

/// Claude Code's and Codex's changes for the same prompt, side by side. Each column is reviewed
/// the way Accept reviews (a snapshot of its worktree), and Keep this one accepts exactly that
/// reviewed version and archives the other task (its worktree and branch stay).
struct CodingCompareView: View {
    let group: UUID
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let tasks = coding.group(group)
        VStack(spacing: 0) {
            HStack {
                Text("Compare results").font(.system(size: 15, weight: .semibold))
                Text(tasks.first?.title ?? "").foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark") }.buttonStyle(DesktopRowButtonStyle(inset: 6)).accessibilityLabel("Close")
            }.padding(14)
            Divider()
            HStack(spacing: 0) {
                ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                    if index > 0 { Divider() }
                    CodingCompareColumn(task: task) { dismiss() }
                }
            }
        }.frame(minWidth: 900, minHeight: 600)
    }
}
private struct CodingCompareColumn: View {
    let task: CodingTaskRecord
    var chosen: () -> Void
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopPreferences.self) private var preferences
    @State private var review: CodingReview?
    @State private var files: [CodingDiffFile] = []
    @State private var selected: String?
    @State private var error = ""
    @State private var confirming = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(task.provider.title).font(.system(size: 13, weight: .semibold))
                CodingStatusDot(task: task)
                Text(CodingTaskStatusBadge.label(task)).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(files.count) files").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("+\(files.reduce(0) { $0 + $1.additions })").foregroundStyle(.green).font(.system(size: 11, design: .monospaced))
                Text("−\(files.reduce(0) { $0 + $1.deletions })").foregroundStyle(.red).font(.system(size: 11, design: .monospaced))
            }.padding(12)
            Divider()
            if files.isEmpty {
                Text(task.status.running ? "Still working…" : error.isEmpty ? "No changes." : error).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(files) { file in
                            Button { selected = file.path } label: {
                                HStack { Text(file.path).lineLimit(1).truncationMode(.head); Spacer(); Text("+\(file.additions) −\(file.deletions)").foregroundStyle(.secondary) }
                                    .font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 4).contentShape(Rectangle())
                            }.buttonStyle(DesktopRowButtonStyle(selected: (selected ?? files.first?.path) == file.path))
                        }
                    }.padding(6)
                }.frame(maxHeight: 150)
                Divider()
                if let file = files.first(where: { $0.path == (selected ?? files.first?.path) }) {
                    CodingDiffView(file: file, split: false, font: preferences.codeFontSize - 1)
                }
            }
            Divider()
            HStack {
                Button("Open task") { coding.select(task.id); chosen() }.buttonStyle(DesktopRowButtonStyle(inset: 6))
                Spacer()
                Button("Keep this one…") { confirming = true }.buttonStyle(.borderedProminent)
                    .disabled(review == nil || task.status.running || task.status == .done || !task.isolated)
            }.padding(12)
        }
        .frame(maxWidth: .infinity)
        .task(id: task.status) { await load() }
        .confirmationDialog("Keep \(task.provider.title)'s version?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Accept this version") { if let review { Task { await coding.choose(task.id, review: review); chosen() } } }
        } message: { Text("Commits exactly the version shown and fast-forwards it into the project's branch. The other task is archived; its worktree and branch are kept.") }
    }
    private func load() async {
        guard !task.status.running else { return }
        do {
            await coding.refresh(task.id)
            let next = try await coding.review(task.id)
            review = next; files = next.diff == "No changes." ? [] : CodingDiff.parse(next.diff); error = ""
        } catch { self.error = error.localizedDescription; review = nil; files = [] }
    }
}

// MARK: Commit and pull request

/// After review: commit the reviewed version on the task's branch with a message you can edit,
/// or push the branch and open a pull request with `gh`. Nothing is pushed until you confirm.
struct CodingCommitActions: View {
    let task: CodingTaskRecord
    let review: CodingReview?
    let files: [CodingDiffFile]
    @Environment(CodingWorkspaceStore.self) private var coding
    @State private var committing = false
    @State private var message = ""
    @State private var opening = false
    @State private var prTitle = ""
    @State private var prBody = ""
    @State private var working = false
    @State private var result = ""
    var body: some View {
        HStack(spacing: 6) {
            Button("Commit…") { message = CodingCommitMessage.generate(title: task.title, files: files); committing = true }
                .disabled(!ready || files.isEmpty)
                .help("Commit the reviewed version on \(task.branch ?? "the task's branch") without merging it")
                .popover(isPresented: $committing, arrowEdge: .top) { commitSheet }
            Button("Pull request…") {
                let generated = CodingCommitMessage.generate(title: task.title, files: files)
                prTitle = generated.split(separator: "\n").first.map(String.init) ?? task.title
                prBody = generated.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(2).joined(separator: "\n") + "\n\nMade with \(task.provider.title) in Tsukumo."
                opening = true
            }
            .disabled(!task.isolated || task.status.running || task.branch == nil)
            .help("Push \(task.branch ?? "the task's branch") and open a pull request with gh")
            .sheet(isPresented: $opening) { pullRequestSheet }
            if working { KemoOrb(size: 16, state: .searching) }
        }
        if !result.isEmpty { Text(result).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(3) }
    }
    private var ready: Bool { review != nil && task.isolated && !task.status.running && task.status != .done && !working }
    private var commitSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Commit on \(task.branch ?? "branch")").font(.headline)
            TextEditor(text: $message).font(.system(size: 12, design: .monospaced)).frame(width: 420, height: 160)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            Text("Commits exactly the reviewed version. Nothing is merged or pushed.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { committing = false }
                Button("Commit") {
                    guard let review else { return }
                    committing = false; working = true
                    Task {
                        defer { working = false }
                        do { let sha = try await coding.commit(task.id, review: review, message: message); result = "Committed \(sha.prefix(8)) on \(task.branch ?? "")." }
                        catch { result = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(14)
    }
    private var pullRequestSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Open a pull request").font(.headline)
            Text("This pushes **\(task.branch ?? "")** to the project's **origin** remote and opens a pull request into **\(task.baseBranch ?? "")** with the GitHub CLI (`gh`), signed in as you. Only committed work is pushed: commit the reviewed version first.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            TextField("Title", text: $prTitle).textFieldStyle(.roundedBorder)
            TextEditor(text: $prBody).font(.system(size: 12)).frame(height: 140)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.12)))
            HStack {
                Spacer()
                Button("Cancel") { opening = false }
                Button("Push and open pull request") {
                    opening = false; working = true
                    Task {
                        defer { working = false }
                        do { let url = try await coding.openPullRequest(task.id, title: prTitle, body: prBody); result = "Pull request: " + url; if let link = URL(string: url), link.scheme == "https" { NSWorkspace.shared.open(link) } }
                        catch { result = error.localizedDescription }
                    }
                }.buttonStyle(.borderedProminent).disabled(prTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }.padding(18).frame(width: 520)
    }
}

// MARK: Sidebar

/// A task's state as a small mark: a live orb while running, orange when it needs you,
/// green when ready for review, red when failed.
struct CodingStatusDot: View {
    let task: CodingTaskRecord
    var body: some View {
        Group {
            switch task.status {
            case .working, .preparing: KemoOrb(size: 12, state: .searching)
            case .needsInput: Circle().fill(Color.orange).frame(width: 7, height: 7)
            case .review: Circle().fill(Color.green).frame(width: 7, height: 7)
            case .failed: Circle().fill(Color.red).frame(width: 7, height: 7)
            case .done: Image(systemName: "checkmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            default: Circle().strokeBorder(Color.secondary, lineWidth: 1).frame(width: 7, height: 7)
            }
        }.frame(width: 12, height: 12).accessibilityLabel(CodingTaskStatusBadge.label(task))
    }
}
/// One task in the sidebar: status, title, unread and pin marks, and a short status line while
/// it runs or waits. Right-click to rename, pin, or archive.
struct CodingTaskSidebarRow: View {
    let task: CodingTaskRecord
    let number: Int?
    /// Asks to delete the task; the sidebar confirms first.
    var onDelete: (() -> Void)?
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopProjects.self) private var projects
    @Environment(DesktopNavigation.self) private var desktop
    @State private var renaming = false
    @State private var name = ""
    var body: some View {
        Button { projects.selected = task.projectID; coding.select(task.id); desktop.tsukumoSurface = "Project" } label: {
            HStack(spacing: 7) {
                CodingStatusDot(task: task)
                VStack(alignment: .leading, spacing: 1) {
                    Text(task.title).lineLimit(1).fontWeight(task.unread == true ? .semibold : .regular)
                    if let line = statusLine { Text(line).font(.system(size: 10.5)).foregroundStyle(task.status == .needsInput ? Color.orange : .secondary).lineLimit(1) }
                }
                Spacer(minLength: 0)
                if task.pinned == true { Image(systemName: "pin.fill").font(.system(size: 8)).foregroundStyle(.tertiary) }
                if task.unread == true { Circle().fill(Color.accentColor).frame(width: 6, height: 6).accessibilityLabel("Unread") }
            }.font(.system(size: 12)).padding(.leading, 18).padding(.trailing, 6).padding(.vertical, 5)
        }
        .buttonStyle(DesktopRowButtonStyle(selected: coding.selected == task.id))
        .help(task.provider.title + " · " + CodingTaskStatusBadge.label(task) + (number.map { " · ⌘\($0)" } ?? ""))
        .contextMenu {
            Button("Rename…") { name = task.title; renaming = true }
            Button(task.pinned == true ? "Unpin" : "Pin") { coding.setPinned(task.id, task.pinned != true) }
            if task.status.running { Button("Stop") { coding.stop(task.id) } }
            Divider()
            Button("Archive") { coding.archive(task.id) }
            if let onDelete { Button("Delete task…", role: .destructive, action: onDelete) }
        }
        .popover(isPresented: $renaming, arrowEdge: .trailing) {
            HStack {
                TextField("Task name", text: $name).textFieldStyle(.roundedBorder).frame(width: 220).onSubmit { coding.rename(task.id, name); renaming = false }
                Button("Rename") { coding.rename(task.id, name); renaming = false }.buttonStyle(.borderedProminent)
            }.padding(10)
        }
    }
    /// Running tasks say what they're doing; others their state, when it matters.
    private var statusLine: String? {
        switch task.status {
        case .needsInput: return "Needs approval"
        case .working, .preparing:
            guard let last = task.events.last(where: { $0.kind == .command || $0.kind == .file || $0.kind == .reasoning }) else { return "\(task.provider.title) is working" }
            if last.kind == .reasoning { return "Thinking" }
            let text = last.kind == .command && (last.tool == "Bash" || last.tool == "commandExecution") ? "$ " + CodingChatEvents.displayCommand(last.text) : last.text
            return text.split(separator: "\n").first.map(String.init)
        case .failed: return "Failed"
        case .review: return task.changes.isEmpty ? "Finished" : "Ready for review · \(task.changes.count) file\(task.changes.count == 1 ? "" : "s")"
        default: return nil
        }
    }
}
