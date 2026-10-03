import Foundation
import Observation
import CryptoKit

@MainActor @Observable final class CodingWorkspaceStore {
    private(set) var tasks: [CodingTaskRecord] = []
    var selected: UUID?
    var notice = ""
    private(set) var storageFailed = false
    private(set) var approvals: [UUID: CodingApproval] = [:]
    private(set) var busy: Set<UUID> = []
    /// The signed-in account's coding storage; nil while signed out, when nothing runs or saves.
    private(set) var storage: CodingStorage?
    private let sessionFactory: (CodingTaskRecord) -> any AgentSession
    private var sessions: [UUID: any AgentSession] = [:]
    private var monitor: Task<Void, Never>?
    private var refreshing: Set<UUID> = []
    /// Bumped on every account change. Callbacks and awaited work from an earlier account
    /// compare against it and are dropped, so nothing from one account lands in another's tasks.
    private(set) var generation = 0
    /// Streamed events go to each task's append-only log at once; the snapshot of all tasks is
    /// rewritten at most this often while they stream (and at once for status changes).
    private let snapshotDelay: Duration
    private var pendingSnapshot: Task<Void, Never>?
    /// Removes a deleted task's session from its agent (Codex thread, Claude Code transcript) and
    /// returns a problem to show, if any. Off in test hosts unless a test sets it.
    var removeAgentSession: ((CodingTaskRecord) async -> String?)? = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil ? { await CodingAgentSessionRemoval.remove($0) } : nil
    /// Plans, coordination, and integration across this account's tasks (CodingOrchestrator.swift).
    @ObservationIgnored private(set) var orchestrator: CodingOrchestrator!
    init(storage: CodingStorage? = nil, sessionFactory: ((CodingTaskRecord) -> any AgentSession)? = nil, snapshotDelay: Duration = .seconds(1)) {
        // Each task's session comes from its agent's adapter (CodingAgentAdapters.swift).
        self.sessionFactory = sessionFactory ?? { CodingAgentRegistry.shared.adapter(for: $0.provider).makeSession($0) }
        self.storage = storage ?? CodingStorage.forAccount(AccountDirectory.current())
        self.snapshotDelay = snapshotDelay
        load()
        orchestrator = CodingOrchestrator(store: self)
    }
    var signedIn: Bool { storage != nil }
    var accountID: String? { storage?.ownerID }
    /// Editor drafts belong to the account too, beside its tasks.
    var draftsFolder: URL? { storage?.directory.appendingPathComponent("Drafts", isDirectory: true) }
    private func load() {
        guard let storage else { return }
        do { tasks = try storage.read() } catch { storageFailed = true; notice = error.localizedDescription; return }
        let interrupted = tasks.filter(\.status.running).map(\.id)
        for id in interrupted {
            update(id) { $0.status = .interrupted }
            append(id, .init(kind: .system, text: "App restarted. Send a message to resume the saved agent session."))
        }
        if !interrupted.isEmpty { _ = persist() }
    }

    // MARK: Account lifecycle

    /// Follows the device's signed-in account (nil when signed out).
    func follow(_ account: AccountIdentity?, base: URL = AccountDirectory.base) {
        switchAccount(to: account.map { CodingStorage.forAccount($0, base: base) })
    }
    /// A different account (or signing out) stops every agent process, records the stop in the
    /// old account's tasks, and loads the new account's tasks. Late callbacks from the old
    /// sessions, and awaited Git work started for the old account, are ignored.
    func switchAccount(to next: CodingStorage?) {
        guard next?.ownerID != storage?.ownerID || next?.directory != storage?.directory else { return }
        generation += 1
        let running = sessions; sessions = [:]; approvals = [:]
        for session in running.values { session.stop() }
        for id in tasks.filter(\.status.running).map(\.id) {
            update(id) { $0.status = .interrupted }
            append(id, .init(kind: .system, text: "Stopped because the account changed", detail: "Sign back in to this account and send a message to resume the saved agent session."))
        }
        // Everything still pending is written to the old account before its tasks are let go.
        flush()
        pendingSnapshot?.cancel(); pendingSnapshot = nil
        tasks = []; busy = []; refreshing = []; selected = nil; notice = ""; storageFailed = false
        storage = next
        load()
        orchestrator?.reload()
    }
    /// Whether a callback still comes from the live session of the same account.
    private func isCurrent(_ generation: Int, _ id: UUID, _ session: (any AgentSession)?) -> Bool {
        guard generation == self.generation, let session, let live = sessions[id] else { return false }
        return live === session
    }

    func task(_ id: UUID?) -> CodingTaskRecord? { tasks.first { $0.id == id } }
    func forProject(_ id: UUID?, archived: Bool = false) -> [CodingTaskRecord] {
        tasks.filter { $0.projectID == id && ($0.archived ?? false) == archived }.sorted { $0.updated > $1.updated }
    }
    /// Archiving stops the task's agent and hides it from the sidebar. Nothing is deleted: the
    /// worktree, branch, and event log stay, and Unarchive brings it back.
    func archive(_ id: UUID) {
        guard task(id) != nil, !storageFailed else { return }
        if task(id)?.status.running == true { stop(id) }
        update(id) { $0.archived = true }
        if selected == id { selected = nil }
        _ = persist()
    }
    /// Deletes a task for good: stops its agent, removes the worktree and branch Tsukumo made for
    /// it (never the project folder itself), its event log, and the record. Changes that weren't
    /// accepted are lost, so the views confirm first.
    func delete(_ id: UUID) async {
        guard let record = task(id), let storage, !storageFailed else { return }
        if record.status.running || sessions[id] != nil { stop(id) }
        let generation = generation
        let worktrees = storage.directory.appendingPathComponent("Worktrees", isDirectory: true).standardizedFileURL.path + "/"
        let folder = URL(fileURLWithPath: record.directory).standardizedFileURL
        if record.isolated, folder.path.hasPrefix(worktrees) {
            let root = URL(fileURLWithPath: record.projectPath)
            if FileManager.default.fileExists(atPath: root.path) {
                _ = try? await CodingCommand.git(["worktree", "remove", "--force", folder.path], at: root)
                if let branch = record.branch, branch.hasPrefix("tsukumo/") { _ = try? await CodingCommand.git(["branch", "-D", branch], at: root) }
                _ = try? await CodingCommand.git(["worktree", "prune"], at: root)
            }
            try? FileManager.default.removeItem(at: folder)
        }
        // The agent's own saved session goes too (CodingChatDelete.swift), so it leaves the Codex app's Recents.
        if let removeAgentSession { let problem = await removeAgentSession(record); if let problem { notice = problem } }
        guard generation == self.generation else { return }
        try? FileManager.default.removeItem(at: storage.logURL(id))
        tasks.removeAll { $0.id == id }
        busy.remove(id); refreshing.remove(id)
        if selected == id { selected = nil }
        _ = persist()
    }
    /// Deletes every task of a project, as the project is removed from Tsukumo.
    func deleteTasks(ofProject project: UUID) async {
        for id in tasks.filter({ $0.projectID == project }).map(\.id) { await delete(id) }
    }
    /// Tasks whose project was removed from Tsukumo before removing a project also deleted its tasks.
    func orphans(keeping projects: Set<UUID>) -> [CodingTaskRecord] {
        tasks.filter { !projects.contains($0.projectID) }.sorted { $0.updated > $1.updated }
    }
    func unarchive(_ id: UUID) {
        guard task(id) != nil, !storageFailed else { return }
        update(id) { $0.archived = nil }; _ = persist()
    }
    func startMonitoring() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                for record in tasks where record.status != .done && record.archived != true { await refresh(record.id) }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
    func stopAll() {
        monitor?.cancel(); monitor = nil; orchestrator?.stop()
        let running = sessions; sessions = [:]; approvals = [:]
        for session in running.values { session.stop() }
        for id in running.keys { update(id) { $0.status = .interrupted } }
        if !running.isEmpty { _ = persist() } else { flush() }
    }
    /// Writes a pending snapshot now (at quit, and before an account change).
    func flush() { if pendingSnapshot != nil { _ = persist() } }
    /// `title`, `base` (the commit a worktree starts from), and `prepare` (run in the new worktree
    /// before the agent starts) are for orchestrated subtasks; a task started by hand uses none.
    @discardableResult func create(project: DesktopProject, root: URL, provider: CodingProvider, model: String, access: CodingAccess, isolated: Bool, prompt: String, options: CodingTaskOptions = .init(),
                                   title: String? = nil, base: String? = nil, prepare: ((URL) async throws -> Void)? = nil) async -> UUID? {
        guard let storage, !storageFailed, options.fork != nil || !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              options.id.map({ task($0) == nil }) ?? true else { return nil }
        let generation = generation
        // An agent never gets more access than its own grant (Settings → Agents).
        var record = CodingTaskRecord(projectID: project.id, ownerID: storage.ownerID, title: String((options.title ?? title ?? prompt).prefix(70)), provider: provider, model: model.trimmingCharacters(in: .whitespacesAndNewlines), access: CodingAgentRegistry.shared.clamp(access, for: provider), projectPath: root.path, directory: root.path, isolated: isolated)
        if let id = options.id { record.id = id }
        record.effort = options.effort; record.group = options.group; record.fork = options.fork
        record.contextPackets = options.packet.map { [$0] }
        tasks.append(record); if options.select { selected = record.id }
        guard persist() else { return nil }
        busy.insert(record.id); defer { if generation == self.generation { busy.remove(record.id) } }
        do {
            if isolated {
                let head = try await CodingCommand.git(["rev-parse", base ?? "HEAD"], at: root)
                let base = options.baseCommit ?? head
                var baseBranch = options.baseBranch ?? ""
                if baseBranch.isEmpty { baseBranch = try await CodingCommand.git(["symbolic-ref", "--short", "HEAD"], at: root) }
                let directory = storage.directory.appendingPathComponent("Worktrees/" + record.id.uuidString)
                try FileManager.default.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
                let branch = "tsukumo/" + record.id.uuidString.lowercased()
                // A fork starts from a commit of its source's files; a new task from the project's HEAD.
                _ = try await CodingCommand.git(["worktree", "add", "-b", branch, directory.path, options.startCommit ?? base], at: root)
                record.directory = directory.path; record.branch = branch; record.baseCommit = base; record.baseBranch = baseBranch
                try await prepare?(directory)
            } else if tasks.contains(where: { $0.id != record.id && $0.directory == root.path && $0.status.running }) {
                throw CodingFailure("Another task is running in this folder. Use a worktree to run alongside it.")
            }
            // The account changed while Git worked: the worktree stays in the old account's folder.
            guard generation == self.generation else { return nil }
            record.status = .ready; replace(record)
            append(record.id, .init(kind: .system, text: isolated ? CodingTaskNote.worktree : CodingTaskNote.folder, detail: record.directory, status: "quiet"))
            guard persist() else { return record.id }
            busy.remove(record.id)
            if !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                send(record.id, input: .init(text: prompt, images: options.images, context: options.context, contextOrigin: options.contextOrigin))
            }
            return record.id
        } catch {
            guard generation == self.generation else { return nil }
            fail(record.id, error); return record.id
        }
    }
    func send(_ id: UUID, _ text: String) { send(id, input: .init(text: text)) }
    /// Sends a message (or, for `.compact` and `.review`, asks the agent to do that instead).
    func send(_ id: UUID, input: CodingTurnInput, action: CodingSendAction = .turn) {
        guard signedIn, !storageFailed, let record = task(id), !record.status.running, !busy.contains(id), record.status != .done,
              action != .turn || !input.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if tasks.contains(where: { $0.id != id && $0.directory == record.directory && $0.status.running }) { notice = "Another task is working in this folder. Stop it first."; return }
        var message = CodingEvent(kind: action == .turn ? .user : .system, text: action == .turn ? input.text : action == .compact ? "Asked the agent to compact its context" : "Asked the agent to review the changes")
        if !input.images.isEmpty { message.images = input.images.map(\.path) }
        // Context handed over from KemoSabe shows as a note (open it to read exactly what went) and
        // goes to the agent ahead of the message; the message itself shows as written.
        var delivered = input
        if action == .turn, let context = input.context, !context.isEmpty {
            append(id, .init(kind: .system, text: "Context from KemoSabe" + (input.contextOrigin.map { ": " + $0 } ?? ""), detail: context))
            delivered.text = context + "\n\n" + input.text
            delivered.context = nil
        }
        append(id, message)
        guard persist() else { return }
        let session = liveSession(id, record)
        do {
            switch action {
            case .turn: try session.send(input: delivered)
            case .compact: try session.compact()
            case .review: try session.review()
            }
        } catch { fail(id, error) }
    }
    /// The task's running agent session, or a new one whose callbacks are bound to it.
    func liveSession(_ id: UUID, _ record: CodingTaskRecord) -> any AgentSession {
        if let existing = sessions[id] { return existing }
        let session = sessionFactory(record); sessions[id] = session
        // Every callback is bound to this session and account: after a stop or an account
        // change the session is no longer live, and whatever it still reports is dropped.
        let generation = generation
        session.onEvent = { [weak self, weak session] event, delta in
            guard let self, isCurrent(generation, id, session) else { return }
            append(id, event, delta: delta); noteActivity(id)
        }
        session.onState = { [weak self, weak session] state in
            guard let self, isCurrent(generation, id, session) else { return }
            update(id) { $0.status = state }; _ = persist()
            if !state.running { Task { await self.refresh(id) } }
            turnChanged(id, state)
        }
        session.onSession = { [weak self, weak session] handle in
            guard let self, isCurrent(generation, id, session) else { return }
            // A fork's own session has started; it no longer needs its source's.
            update(id) { $0.sessionID = handle; $0.fork = nil }; _ = persist()
        }
        session.onApproval = { [weak self, weak session] approval in
            guard let self, isCurrent(generation, id, session) else { return }
            approvals[id] = approval; approvalChanged(id, approval)
        }
        session.onReport = { [weak session] report in
            guard session != nil else { return }
            CodingAgentCatalog.shared.record(record.provider, report: report)
            if let signedIn = report.signedIn { CodingAgentRegistry.shared.report(record.provider, signIn: signedIn ? .signedIn : .signedOut) }
        }
        return session
    }
    /// The running session, if the task has one (for steering and interrupting a turn).
    func runningSession(_ id: UUID) -> (any AgentSession)? { sessions[id] }
    /// Ends the task's idle session so the next message starts one with the task's new settings
    /// (model, effort, access), resuming the same conversation.
    func endIdleSession(_ id: UUID) {
        guard task(id)?.status.running != true, let session = sessions.removeValue(forKey: id) else { return }
        session.stop()
    }
    func stop(_ id: UUID) {
        // Removed first, so the stopping session's own last reports are ignored.
        let session = sessions.removeValue(forKey: id); approvals.removeValue(forKey: id)
        session?.stop()
        update(id) { $0.status = .interrupted }; _ = persist()
    }
    func respond(_ id: UUID, allow: Bool, answer: String = "") {
        respond(id, decision: allow ? .allowOnce : .deny(note: ""), answer: answer)
    }
    func respond(_ id: UUID, decision: CodingApprovalDecision, answer: String = "") {
        guard !storageFailed, let approval = approvals[id] else { return }
        do { try sessions[id]?.respond(approval.id, decision: decision, answers: answer) } catch { fail(id, error) }
    }
    func claim(_ path: String, for id: UUID) {
        guard WeaveSnapshot.validPath(path), let record = task(id), !storageFailed else { notice = "Choose a relative file path inside this project."; return }
        // Claims are coordination, not locks. Existing changes remain visible as overlaps.
        for index in tasks.indices where tasks[index].projectID == record.projectID { tasks[index].claims.removeAll { $0 == path } }
        update(id) { $0.claims.append(path) }; _ = persist()
    }
    func refresh(_ id: UUID) async {
        guard !refreshing.contains(id), let record = task(id), record.status != .preparing else { return }
        let generation = generation
        refreshing.insert(id); defer { if generation == self.generation { refreshing.remove(id) } }
        do {
            let root = URL(fileURLWithPath: record.directory)
            let tracked = try await CodingCommand.git(["diff", "--name-status", "-z", record.baseCommit ?? "HEAD", "--"], at: root)
            let untracked = try await CodingCommand.git(["ls-files", "--others", "--exclude-standard", "-z"], at: root)
            guard generation == self.generation else { return }
            var changes = Self.parseChanges(tracked)
            for path in untracked.split(separator: "\0").map(String.init) { changes.append(.init(path: path, status: "?")) }
            changes.sort { $0.path < $1.path }
            if task(id)?.changes != changes { update(id) { $0.changes = changes }; _ = persist() }
        } catch {
            // Non-git local folders remain usable; a worktree losing Git is a visible failure.
            if record.isolated, generation == self.generation { notice = "Could not inspect \(record.title): \(error.localizedDescription)" }
        }
    }
    static func parseChanges(_ output: String) -> [CodingChange] {
        let fields = output.split(separator: "\0").map(String.init)
        var index = 0, changes: [CodingChange] = []
        while index + 1 < fields.count {
            let status = fields[index]; index += 1
            let first = fields[index]; index += 1
            if status.hasPrefix("R") || status.hasPrefix("C"), index < fields.count {
                changes.append(.init(path: first, status: "D")); changes.append(.init(path: fields[index], status: "A")); index += 1
            } else { changes.append(.init(path: first, status: status)) }
        }
        return changes
    }
    /// The Git tree of a folder exactly as it is on disk now: tracked and untracked files, minus
    /// ignored ones. Built in a private copy of the index, so the folder's own index, files, and
    /// branches are untouched; only content-addressed objects are added to the repository.
    static func snapshotTree(at root: URL) async throws -> String {
        let index = try await CodingCommand.git(["rev-parse", "--path-format=absolute", "--git-path", "index"], at: root)
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("tsukumo-index-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: scratch); try? FileManager.default.removeItem(atPath: scratch.path + ".lock") }
        if FileManager.default.fileExists(atPath: index) { try FileManager.default.copyItem(atPath: index, toPath: scratch.path) }
        let environment = ["GIT_INDEX_FILE": scratch.path]
        _ = try await CodingCommand.git(["add", "--all", "--", "."], at: root, environment: environment)
        return try await CodingCommand.git(["write-tree"], at: root, environment: environment)
    }
    /// A review binds what is shown to what can be accepted: the diff is computed from the same
    /// snapshot tree that Accept later commits, not from whatever is on disk by then.
    func review(_ id: UUID) async throws -> CodingReview {
        guard let record = task(id) else { throw CodingFailure("This task is no longer available.") }
        let root = URL(fileURLWithPath: record.directory)
        let head = try await CodingCommand.git(["rev-parse", "HEAD"], at: root)
        let tree = try await Self.snapshotTree(at: root)
        let base = record.baseCommit ?? head
        let diff = try await CodingCommand.git(["diff", "--binary", "--full-index", "--no-ext-diff", "--no-textconv", base, tree, "--"], at: root)
        return .init(taskID: id, base: base, head: head, tree: tree, diff: diff.isEmpty ? "No changes." : diff)
    }
    /// Checks that ran against exactly this reviewed tree. An earlier pass on other files can't vouch for it.
    func checks(for review: CodingReview) -> [CodingEvent] {
        task(review.taskID)?.events.filter { $0.kind == .check && $0.tree == review.tree } ?? []
    }
    func check(_ id: UUID, command: String) async {
        guard let record = task(id), !record.status.running, !busy.contains(id), !command.isEmpty, !storageFailed else { return }
        let generation = generation
        busy.insert(id); defer { if generation == self.generation { busy.remove(id) } }
        let eventID = UUID().uuidString, root = URL(fileURLWithPath: record.directory)
        append(id, .init(id: eventID, kind: .check, text: command, status: "running"))
        do {
            // The tree before and after: a check that changed files (or ran while they changed)
            // vouches for no version. Folders outside Git have no tree to vouch for.
            let before = try? await Self.snapshotTree(at: root)
            let result = try await CodingCommand.run("/bin/zsh", ["-l", "-c", command], at: root, timeout: 300)
            let after = try? await Self.snapshotTree(at: root)
            guard generation == self.generation else { return }
            let tree = before != nil && before == after ? before : nil
            var detail = result.output
            if before != nil, tree == nil { detail += "\n\nFiles changed while this check ran, so its result doesn't count for any reviewed version." }
            append(id, .init(id: eventID, kind: .check, text: command, detail: detail, status: result.code == 0 ? "passed" : "failed", exitCode: Int(result.code), tree: tree))
            await refresh(id)
        } catch { if generation == self.generation { append(id, .init(id: eventID, kind: .check, text: command, detail: error.localizedDescription, status: "failed")) } }
    }
    /// Accept commits exactly the reviewed tree and fast-forwards the project to it. It refuses if
    /// the task's files or branch moved since the review. No reset, force, auto-conflict
    /// resolution, branch deletion, or worktree removal can discard a person's concurrent work.
    func accept(_ id: UUID, review: CodingReview) async {
        guard review.taskID == id, let record = task(id), record.isolated, !record.status.running, !busy.contains(id), !storageFailed,
              let branch = record.branch, let baseBranch = record.baseBranch else { return }
        let generation = generation
        busy.insert(id); defer { if generation == self.generation { busy.remove(id) } }
        do {
            let root = URL(fileURLWithPath: record.projectPath), work = URL(fileURLWithPath: record.directory)
            guard try await CodingCommand.git(["symbolic-ref", "--short", "HEAD"], at: work) == branch else { throw CodingFailure("The task's branch changed. Review it in Git before merging.") }
            guard try await CodingCommand.git(["rev-parse", "HEAD"], at: work) == review.head else { throw CodingFailure("The task's branch moved since review. Review it again before accepting.") }
            guard try await Self.snapshotTree(at: work) == review.tree else { throw CodingFailure("Files changed since review. Review again before accepting.") }
            guard try await CodingCommand.git(["symbolic-ref", "--short", "HEAD"], at: root) == baseBranch else { throw CodingFailure("The project's branch changed. Switch back to \(baseBranch) before accepting.") }
            guard try await CodingCommand.git(["status", "--porcelain"], at: root).isEmpty else { throw CodingFailure("Save or commit the project's existing changes before accepting this task.") }
            // The commit is built from the reviewed tree object, never from the files on disk, so
            // an edit landing after the check above can't slip into what is accepted.
            var commit = review.head
            if try await CodingCommand.git(["rev-parse", review.head + "^{tree}"], at: work) != review.tree {
                commit = try await CodingCommand.git(["commit-tree", review.tree, "-p", review.head, "-m", "Tsukumo: " + record.title], at: work)
                // Compare-and-swap: only moves the branch if it is still at the reviewed head.
                _ = try await CodingCommand.git(["update-ref", "-m", "Tsukumo: accept reviewed tree", "refs/heads/" + branch, commit, review.head], at: work)
                // The worktree's index follows its branch; its files are left as they are.
                _ = try await CodingCommand.git(["read-tree", commit], at: work)
            }
            _ = try await CodingCommand.git(["merge", "--ff-only", commit], at: root)
            guard generation == self.generation else { return }
            sessions.removeValue(forKey: id)?.stop()
            let passed = checks(for: review).filter { $0.status == "passed" }.map(\.text)
            update(id) { $0.status = .done }
            append(id, .init(kind: .system, text: "Accepted into \(baseBranch)", detail: "Commit \(commit) with reviewed tree \(review.tree)." + (passed.isEmpty ? " No checks ran on this version." : " Checks passed on this version: " + passed.joined(separator: ", ") + ".") + " The task worktree and branch are retained as a restore point."))
            _ = persist()
        } catch {
            guard generation == self.generation else { return }
            notice = error.localizedDescription; append(id, .init(kind: .system, text: "Accept paused", detail: error.localizedDescription))
        }
    }
    /// A note in the task's conversation from coordination (an overlap, a handoff, a queued
    /// message). It's shown to the person; it isn't sent to the agent.
    func note(_ id: UUID, _ text: String, detail: String = "") {
        guard task(id) != nil, !storageFailed else { return }
        append(id, .init(kind: .collaboration, text: text, detail: detail))
    }
    func markDone(_ id: UUID) { guard let record = task(id), !record.status.running else { return }; update(id) { $0.status = .done }; _ = persist() }
    /// Changes a task. `touch: false` leaves its last-updated time (and so its place in lists) alone.
    func update(_ id: UUID, touch: Bool = true, _ body: (inout CodingTaskRecord) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let before = tasks[index].status
        body(&tasks[index]); if touch { tasks[index].updated = Date() }
        if tasks[index].status != before { orchestrator?.taskStatusChanged(id, tasks[index].status) }
    }
    func replace(_ task: CodingTaskRecord) { if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } }
    /// Records an event: first as one line appended to the task's log (the full audit trail),
    /// then into the capped in-memory view. The snapshot catches up after `snapshotDelay`.
    func append(_ id: UUID, _ event: CodingEvent, delta: Bool = false) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        if let storage, !storageFailed {
            let seq = (tasks[index].logged ?? 0) + 1
            do { try storage.appendLog(.init(seq: seq, event: event, delta: delta), task: id) }
            catch { stopStorage(error); return }
            tasks[index].logged = seq
            scheduleSnapshot()
        }
        CodingTranscript.apply(event, delta: delta, to: &tasks[index]); tasks[index].updated = Date()
    }
    private func scheduleSnapshot() {
        guard pendingSnapshot == nil else { return }
        let generation = generation, delay = snapshotDelay
        pendingSnapshot = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == self.generation else { return }
            pendingSnapshot = nil; _ = persist()
        }
    }
    func fail(_ id: UUID, _ error: Error) { notice = error.localizedDescription; update(id) { $0.status = .failed }; append(id, .init(kind: .system, text: "Task failed", detail: error.localizedDescription)); _ = persist() }
    /// Writes the snapshot now (status, session, and other metadata changes aren't debounced).
    @discardableResult func persist() -> Bool {
        pendingSnapshot?.cancel(); pendingSnapshot = nil
        guard let storage, !storageFailed else { return false }
        do { try storage.save(tasks); return true }
        catch { stopStorage(error); return false }
    }
    private func stopStorage(_ error: Error) {
        storageFailed = true; notice = "Coding storage stopped: " + error.localizedDescription
        // Stop execution when receipts can no longer be durably recorded.
        let running = sessions; sessions = [:]; approvals = [:]
        for session in running.values { session.stop() }
        for id in running.keys { update(id) { $0.status = .interrupted } }
    }
}
