import Foundation
import AppKit

/// What a send asks of the agent: a message, or one of its own actions.
enum CodingSendAction: Equatable { case turn, compact, review }

/// How a new task starts, beyond its agent and prompt.
struct CodingTaskOptions {
    var title: String?
    var effort: String?
    var images: [URL] = []
    /// Run with both: the tasks started together.
    var group: UUID?
    /// A fork: the conversation it continues, and the commit its worktree starts from.
    var fork: CodingForkPoint?
    var startCommit: String?
    var baseCommit: String?
    var baseBranch: String?
    /// Whether the new task opens (Run with both opens only the first).
    var select = true
    /// The new task's ID, chosen by the caller (MacSpaces answers with it before Git finishes).
    /// Refused if a task already has it.
    var id: UUID?
    /// A context packet handed over from KemoSabe: the allowed text, where it came from, and its ID
    /// (kept on the task as its lineage).
    var context: String?
    var contextOrigin: String?
    var packet: UUID?
}

/// The agent chat's side of the store: queued and steered messages, interrupting, per-task model,
/// effort, and access, forks, Run with both, pins and unread markers, notifications, and the
/// commit and pull request steps after review.
extension CodingWorkspaceStore {
    // MARK: Opening and ordering

    func select(_ id: UUID?) {
        selected = id
        if let id, task(id)?.unread == true { update(id, touch: false) { $0.unread = nil } }
    }
    /// Pinned first, then most recently active. With a project, only its tasks.
    func sidebarOrder(project: UUID?) -> [CodingTaskRecord] {
        tasks.filter { $0.archived != true && (project == nil || $0.projectID == project) }
            .sorted { ($0.pinned == true) != ($1.pinned == true) ? $0.pinned == true : $0.updated > $1.updated }
    }
    /// Tasks whose title, agent, or status matches the sidebar search.
    static func matches(_ task: CodingTaskRecord, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        return task.title.localizedCaseInsensitiveContains(query) || task.provider.title.localizedCaseInsensitiveContains(query)
            || CodingTaskStatusBadge.label(task).localizedCaseInsensitiveContains(query)
    }
    func setPinned(_ id: UUID, _ pinned: Bool) { update(id, touch: false) { $0.pinned = pinned ? true : nil }; persist() }
    func rename(_ id: UUID, _ title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        update(id, touch: false) { $0.title = String(trimmed.prefix(120)) }; persist()
    }
    /// Output arrived in a task that isn't open (or while Tsukumo is in the background).
    func noteActivity(_ id: UUID) {
        guard selected != id || !NSApp.isActive, task(id)?.unread != true else { return }
        update(id, touch: false) { $0.unread = true }
    }

    // MARK: Settings per task

    /// A new model or effort applies from the next message: an idle agent is ended and its
    /// conversation resumes with the new settings (both agents keep the session).
    func setModel(_ id: UUID, model: String, effort: String?) {
        guard let record = task(id), record.model != model || record.effort != effort else { return }
        update(id, touch: false) { $0.model = model; $0.effort = effort }
        endIdleSession(id); persist()
        append(id, .init(kind: .system, text: "Model: " + (model.isEmpty ? "provider default" : model) + (effort.map { " · effort " + $0 } ?? ""), detail: record.status.running ? "Applies from the next message after this turn." : "Applies from the next message."))
    }
    func setAccess(_ id: UUID, _ access: CodingAccess) {
        guard let record = task(id) else { return }
        let access = CodingAgentRegistry.shared.clamp(access, for: record.provider)
        guard record.access != access else { return }
        update(id, touch: false) { $0.access = access }
        endIdleSession(id); persist()
        append(id, .init(kind: .system, text: "Access: " + access.title, detail: access.detail + (record.status.running ? " Applies from the next message after this turn." : "")))
    }

    // MARK: Messages while the agent works

    /// Holds a message until the current turn ends; it's sent then, in order.
    func enqueue(_ id: UUID, _ input: CodingTurnInput) {
        guard task(id) != nil, !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        update(id, touch: false) { $0.queued = ($0.queued ?? []) + [.init(text: input.text, images: input.images.map(\.path))] }
        persist()
    }
    func removeQueued(_ id: UUID, _ message: UUID) {
        update(id, touch: false) { $0.queued?.removeAll { $0.id == message }; if $0.queued?.isEmpty == true { $0.queued = nil } }
        persist()
    }
    /// Adds the message to the running turn (Codex). False when the agent can't take it now.
    @discardableResult func steer(_ id: UUID, _ input: CodingTurnInput) -> Bool {
        guard let session = runningSession(id), task(id)?.status == .working else { return false }
        do {
            guard try session.steer(input) else { return false }
            var event = CodingEvent(kind: .user, text: input.text, status: "steered")
            if !input.images.isEmpty { event.images = input.images.map(\.path) }
            append(id, event); persist()
            return true
        } catch { notice = error.localizedDescription; return false }
    }
    /// Ends the running turn and keeps the agent (Esc).
    /// With no agent process yet (a worktree still being made), it stops the task instead.
    func interrupt(_ id: UUID) {
        if let session = runningSession(id) { session.interrupt() } else if task(id)?.status.running == true { stop(id) }
    }
    /// Stops the turn, then sends this message first.
    func interruptAndSend(_ id: UUID, _ input: CodingTurnInput) {
        update(id, touch: false) { $0.queued = [.init(text: input.text, images: input.images.map(\.path))] + ($0.queued ?? []) }
        persist()
        if runningSession(id) != nil { interrupt(id) } else { stop(id); flushQueue(id) }
    }
    /// Called when a turn changes state: a finished turn sends the next queued message, and a
    /// finished or waiting task notifies you when Tsukumo is in the background.
    func turnChanged(_ id: UUID, _ state: CodingTaskStatus) {
        guard !state.running, let record = task(id) else { return }
        if state == .review || state == .interrupted, record.queued?.isEmpty == false {
            // Let the agent settle its turn before the next message starts.
            Task { @MainActor in try? await Task.sleep(for: .milliseconds(150)); self.flushQueue(id) }
            return
        }
        CodingTaskNotifications.shared.finished(record, state: state)
    }
    func approvalChanged(_ id: UUID, _ approval: CodingApproval?) {
        guard let approval, let record = task(id) else { CodingTaskNotifications.shared.approvalCleared(id); return }
        CodingTaskNotifications.shared.needsApproval(record, approval: approval)
    }
    func flushQueue(_ id: UUID) {
        guard let record = task(id), !record.status.running, let next = record.queued?.first else { return }
        update(id, touch: false) { $0.queued?.removeFirst(); if $0.queued?.isEmpty == true { $0.queued = nil } }
        send(id, input: .init(text: next.text, images: next.images.map { URL(fileURLWithPath: $0) }))
    }

    // MARK: Agent actions

    func compact(_ id: UUID) { send(id, input: .init(text: ""), action: .compact) }
    func review(_ id: UUID) { send(id, input: .init(text: ""), action: .review) }
    /// A fresh agent session in the same task and folder: the conversation so far stays visible
    /// here, but the agent starts without it.
    func clearSession(_ id: UUID) {
        guard let record = task(id), !record.status.running else { return }
        endIdleSession(id)
        update(id) { $0.sessionID = nil; $0.fork = nil }
        append(id, .init(kind: .system, text: "New agent session", detail: "The agent starts fresh from the next message; it doesn't see the conversation above."))
        persist()
    }

    // MARK: Fork

    /// A new task that continues this one's conversation up to a message. Its worktree starts
    /// with this task's files as they are now (committed on top of its branch as a snapshot).
    @discardableResult func fork(_ id: UUID, at eventID: String) async -> UUID? {
        guard let source = task(id), let event = source.events.first(where: { $0.id == eventID }), let ref = event.ref, let session = source.sessionID else {
            notice = "This message can't be forked: the agent hasn't reported its place in the conversation yet."; return nil
        }
        let project = DesktopProject(id: source.projectID, name: "", bookmark: Data())
        var options = CodingTaskOptions(title: "Fork: " + source.title, effort: source.effort, fork: .init(sessionID: session, ref: ref))
        if source.isolated {
            do {
                let folder = URL(fileURLWithPath: source.directory)
                let tree = try await Self.snapshotTree(at: folder)
                let head = try await CodingCommand.git(["rev-parse", "HEAD"], at: folder)
                let headTree = try await CodingCommand.git(["rev-parse", head + "^{tree}"], at: folder)
                options.startCommit = tree == headTree ? head : try await CodingCommand.git(["commit-tree", tree, "-p", head, "-m", "Tsukumo: files of \(source.title) when forked"], at: folder)
                options.baseCommit = source.baseCommit; options.baseBranch = source.baseBranch
            } catch { notice = "Couldn't copy the task's files for the fork: " + error.localizedDescription; return nil }
        }
        let created = await create(project: project, root: URL(fileURLWithPath: source.projectPath), provider: source.provider, model: source.model, access: source.access, isolated: source.isolated, prompt: "", options: options)
        if let created {
            append(created, .init(kind: .system, text: "Forked from “\(source.title)”", detail: "The agent continues that conversation up to the chosen message. Send a message to start."))
            persist(); CodingChatCommands.shared.focusComposer()
        }
        return created
    }

    // MARK: Run with…

    /// Sends the same prompt to Claude Code and Codex, each in its own worktree, so their
    /// changes can be compared side by side.
    func runWithBoth(project: DesktopProject, root: URL, prompt: String, access: CodingAccess, images: [URL]) async {
        await runWith([.claude, .codex], project: project, root: root, prompt: prompt, access: access, images: images)
    }
    /// Run with…: the same prompt to two or three chosen agents (any adapters), each in its own
    /// worktree; Compare shows their reviewed changes side by side. The first one opens.
    func runWith(_ agents: [CodingProvider], project: DesktopProject, root: URL, prompt: String, access: CodingAccess, images: [URL]) async {
        var chosen: [CodingProvider] = []
        for agent in agents where !chosen.contains(agent) { chosen.append(agent) }
        guard (2...Self.maximumCompared).contains(chosen.count) else { notice = "Choose two or three agents to compare."; return }
        let group = UUID()
        var first: UUID?
        for (index, agent) in chosen.enumerated() {
            let id = await create(project: project, root: root, provider: agent, model: "", access: access, isolated: true, prompt: prompt, options: .init(images: images, group: group, select: index == 0))
            if index == 0 { first = id }
        }
        if let first { select(first) }
    }
    static let maximumCompared = 3
    func group(_ id: UUID?) -> [CodingTaskRecord] {
        guard let id else { return [] }
        return tasks.filter { $0.group == id }.sorted { $0.provider.rawValue < $1.provider.rawValue }
    }
    /// Keeps one task of a comparison: it's accepted as reviewed, and the others are archived
    /// (their worktrees and branches stay as restore points).
    func choose(_ id: UUID, review: CodingReview) async {
        guard let record = task(id), let group = record.group else { return }
        await accept(id, review: review)
        guard task(id)?.status == .done else { return }
        for other in tasks where other.group == group && other.id != id { archive(other.id) }
        select(id)
    }

    // MARK: Commit and pull request

    /// Commits exactly the reviewed tree on the task's branch (nothing is merged). Refuses if the
    /// files or branch moved since the review.
    func commit(_ id: UUID, review: CodingReview, message: String) async throws -> String {
        guard review.taskID == id, let record = task(id), record.isolated, let branch = record.branch, !record.status.running else { throw CodingFailure("Only a stopped task in its own worktree can be committed here.") }
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw CodingFailure("Write a commit message first.") }
        let work = URL(fileURLWithPath: record.directory)
        guard try await CodingCommand.git(["symbolic-ref", "--short", "HEAD"], at: work) == branch else { throw CodingFailure("The task's branch changed. Review it in Git.") }
        guard try await CodingCommand.git(["rev-parse", "HEAD"], at: work) == review.head else { throw CodingFailure("The task's branch moved since review. Review again.") }
        guard try await Self.snapshotTree(at: work) == review.tree else { throw CodingFailure("Files changed since review. Review again before committing.") }
        guard try await CodingCommand.git(["rev-parse", review.head + "^{tree}"], at: work) != review.tree else { throw CodingFailure("Nothing to commit: the branch already has these files.") }
        let commit = try await CodingCommand.git(["commit-tree", review.tree, "-p", review.head, "-m", text], at: work)
        _ = try await CodingCommand.git(["update-ref", "-m", "Tsukumo: commit reviewed tree", "refs/heads/" + branch, commit, review.head], at: work)
        _ = try await CodingCommand.git(["read-tree", commit], at: work)
        append(id, .init(kind: .system, text: "Committed on \(branch)", detail: "Commit \(commit): " + (text.split(separator: "\n").first.map(String.init) ?? "")))
        persist(); await refresh(id)
        return commit
    }
    /// Pushes the task's branch and opens a pull request with `gh`. Only ever called from the
    /// person's click in the confirmation, never on its own.
    func openPullRequest(_ id: UUID, title: String, body: String) async throws -> String {
        guard let record = task(id), record.isolated, let branch = record.branch, let base = record.baseBranch else { throw CodingFailure("Only a task in its own worktree has a branch to open a pull request from.") }
        let work = URL(fileURLWithPath: record.directory)
        let gh = try CodingProcess.executable("gh")
        let environment = CodingChild.environment()
        let push = try await CodingCommand.run("/usr/bin/git", ["push", "--set-upstream", "origin", branch], at: work, timeout: 180, environment: ["PATH": environment["PATH"] ?? ""])
        guard push.code == 0 else { throw CodingFailure("Push failed: " + push.output) }
        let pr = try await CodingCommand.run(gh.path, ["pr", "create", "--head", branch, "--base", base, "--title", title, "--body", body], at: work, timeout: 120, environment: ["PATH": environment["PATH"] ?? "", "GH_PROMPT_DISABLED": "1"])
        guard pr.code == 0 else { throw CodingFailure("gh couldn't open the pull request: " + pr.output) }
        let url = pr.output.split(separator: "\n").last(where: { $0.hasPrefix("https://") }).map(String.init) ?? pr.output.trimmingCharacters(in: .whitespacesAndNewlines)
        append(id, .init(kind: .system, text: "Opened a pull request", detail: url)); persist()
        return url
    }
}

/// A commit message from what the task changed: its title as the subject, then the files.
enum CodingCommitMessage {
    static func generate(title: String, files: [CodingDiffFile]) -> String {
        var subject = title.split(separator: "\n").first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? "Update files"
        if subject.hasSuffix(".") { subject.removeLast() }
        if let first = subject.first { subject = first.uppercased() + subject.dropFirst() }
        if subject.count > 72 { subject = String(subject.prefix(69)) + "…" }
        guard !files.isEmpty else { return subject }
        let lines = files.prefix(20).map { file -> String in
            let verb = file.change == .added ? "Add" : file.change == .deleted ? "Remove" : file.change == .renamed ? "Rename" : "Update"
            return "- \(verb) \(file.path)" + (file.binary ? "" : " (+\(file.additions) −\(file.deletions))")
        }
        return subject + "\n\n" + lines.joined(separator: "\n") + (files.count > 20 ? "\n- and \(files.count - 20) more files" : "")
    }
}

/// The status a task shows in lists: running, needs approval, done, failed, or ready for review.
enum CodingTaskStatusBadge {
    static func label(_ task: CodingTaskRecord) -> String {
        switch task.status {
        case .needsInput: "Needs approval"
        case .working, .preparing: "Running"
        case .review: "Ready for review"
        case .done: "Done"
        case .failed: "Failed"
        case .interrupted: "Stopped"
        case .ready: "Ready"
        }
    }
}
