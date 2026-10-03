import Foundation
import Observation

/// One goal worked on by several agents: the lead's plan, the person's edits to it, the task each
/// subtask runs as, and the integration of their results.
struct OrchestratorRun: Codable, Identifiable, Equatable {
    enum Phase: String, Codable {
        /// The lead agent is reading the project and proposing a plan.
        case planning
        /// The plan is waiting for the person to review, edit, and start it.
        case reviewing
        /// Subtasks are running, each in its own worktree, as their dependencies allow.
        case running
        /// Finished subtasks are being merged, tested, and reviewed.
        case integrating
        /// The integrated result was accepted into the base branch.
        case accepted
        case cancelled
        var title: String {
            switch self { case .planning: "Planning"; case .reviewing: "Plan ready"; case .running: "Running"; case .integrating: "Integrating"; case .accepted: "Accepted"; case .cancelled: "Cancelled" }
        }
    }
    var id = UUID()
    var projectID: UUID
    var projectPath: String
    var goal: String
    var lead: CodingProvider
    var access: CodingAccess
    var phase: Phase = .planning
    var leadTask: UUID?
    var plan: OrchestratorPlan?
    /// Why the plan is a single task, when the lead's answer couldn't be used.
    var planNote: String?
    /// Subtask ID → the coding task running it.
    var tasks: [String: UUID] = [:]
    /// The project's commit and branch when the plan started; every worktree and the integration start here.
    var baseCommit: String?
    var baseBranch: String?
    var integration: OrchestratorIntegration?
    var created = Date()
    var title: String {
        let line = goal.split(separator: "\n").first.map(String.init) ?? goal
        return line.count > 70 ? String(line.prefix(69)) + "…" : line
    }
}

struct OrchestratorIntegration: Codable, Equatable {
    struct Conflict: Codable, Equatable {
        var subtask: String
        var commit: String
        var files: [String]
    }
    var branch: String
    var directory: String
    var base: String
    /// Subtasks merged (or skipped), in the order they went in.
    var merged: [String] = []
    var skipped: [String] = []
    /// Subtask → the checkpoint commit that was merged.
    var commits: [String: String] = [:]
    var conflict: Conflict?
    /// The task an agent is resolving the conflict in.
    var resolveTask: UUID?
    var test: OrchestratorTestResult?
    /// The commit the project fast-forwarded to.
    var accepted: String?
}

/// Coordination kept in the account's Coding folder beside its tasks: plans, the timeline of
/// messages and handoffs, ownership decisions, overlaps already warned about, and messages
/// waiting for an agent's turn to end.
struct CodingCollabState: Codable, Equatable {
    var schema = 1
    var ownerID: String
    var runs: [OrchestratorRun] = []
    var messages: [CollabMessage] = []
    var ownership: [CollabOwnership] = []
    var warned: [String] = []
    /// Task ID → messages to deliver when its current turn ends.
    var queued: [String: [String]] = [:]
    /// Project ID → the test command the person chose.
    var testCommands: [String: String] = [:]
    /// Projects the person chose to share, once sharing is available.
    var shared: [String] = []
}

struct CodingCollabStorage {
    var url: URL
    var ownerID: String
    var formerOwners: Set<String> = []
    init(_ storage: CodingStorage) {
        url = storage.directory.appendingPathComponent("Collaboration.json"); ownerID = storage.ownerID; formerOwners = storage.formerOwners
    }
    func read() throws -> CodingCollabState? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var state = try JSONDecoder().decode(CodingCollabState.self, from: Data(contentsOf: url))
        guard state.schema == 1, formerOwners.union([ownerID]).contains(state.ownerID) else {
            throw CodingFailure("Coordination data belongs to another account or a newer version. It has not been overwritten.")
        }
        state.ownerID = ownerID
        return state
    }
    func save(_ state: CodingCollabState) throws {
        guard state.ownerID == ownerID, AccountDirectory.permitsWrite(to: url.deletingLastPathComponent()) else { throw CodingFailure("Account changed; coordination was not saved.") }
        _ = try read()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(state).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Runs plans across agents and keeps them from colliding. It watches every task of the account:
/// what each actually touches (its diff, down to functions, and the files its tools name), the
/// overlaps between them, and the handoffs from one subtask to the next. It never starts an
/// agent without the person's click (Plan, Start, Resolve), never sends an agent a message the
/// person didn't ask for, and merges into the base branch only on Accept.
@MainActor @Observable final class CodingOrchestrator {
    /// Set by the sync layer once a transport can carry shared zones (CloudKit). Until then
    /// sharing is off and the page says so.
    static var transportFactory: ((String) -> any SyncTransport)?
    private(set) var state: CodingCollabState?
    /// What each task touches now, from its diff and its current turn's tool events.
    private(set) var touches: [UUID: [CollabFileTouch]] = [:]
    /// What the person changed by hand in each project's own folder.
    private(set) var personTouches: [UUID: [CollabFileTouch]] = [:]
    /// When the person's own edits in each project last changed.
    @ObservationIgnored private var personChanged: [UUID: Date] = [:]
    /// Runs with Git work in flight.
    private(set) var working: Set<UUID> = []
    var notice = ""
    @ObservationIgnored private weak var store: CodingWorkspaceStore?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var starting: Set<String> = []
    @ObservationIgnored private var shares: [UUID: CollabShare] = [:]
    @ObservationIgnored var displayName: () -> String = { "You" }
    @ObservationIgnored var parallelLimit = 4
    /// Whether an agent starting work starts the coordination loop (off in tests, which call `coordinate()`).
    @ObservationIgnored var autoCoordinate = !AccountDirectory.isTestHost
    init(store: CodingWorkspaceStore) { self.store = store; reload() }

    var me: String { store?.accountID ?? "local" }
    var personID: String { "person-" + me }
    var sharingAvailable: Bool { Self.transportFactory != nil }

    /// The open account's coordination (after launch and every account change).
    func reload() {
        loop?.cancel(); loop = nil
        touches = [:]; personTouches = [:]; working = []; starting = []; shares = [:]; notice = ""
        guard let storage = store?.storage else { state = nil; return }
        do { state = try CodingCollabStorage(storage).read() ?? CodingCollabState(ownerID: storage.ownerID) }
        catch { state = nil; notice = error.localizedDescription }
    }
    func stop() { loop?.cancel(); loop = nil }
    @discardableResult private func persist() -> Bool {
        guard let state, let storage = store?.storage else { return false }
        do { try CodingCollabStorage(storage).save(state); return true }
        catch { notice = "Coordination couldn't be saved: " + error.localizedDescription; return false }
    }

    // MARK: Runs

    func run(_ id: UUID?) -> OrchestratorRun? { state?.runs.first { $0.id == id } }
    func runs(for project: UUID?) -> [OrchestratorRun] { (state?.runs ?? []).filter { $0.projectID == project }.sorted { $0.created > $1.created } }
    private func mutate(_ id: UUID, _ body: (inout OrchestratorRun) -> Void) {
        guard let index = state?.runs.firstIndex(where: { $0.id == id }) else { return }
        body(&state!.runs[index]); persist()
    }
    /// The run and subtask a task belongs to, if any.
    func subtask(of task: UUID) -> (run: OrchestratorRun, subtask: OrchestratorSubtask)? {
        for run in state?.runs ?? [] {
            if let id = run.tasks.first(where: { $0.value == task })?.key, let subtask = run.plan?.subtask(id) { return (run, subtask) }
        }
        return nil
    }
    /// Tasks that exist to plan or to resolve a conflict: they take part, but their changes aren't
    /// anyone's work in progress, so they don't raise overlaps.
    func isHelper(_ task: UUID) -> Bool {
        (state?.runs ?? []).contains { $0.leadTask == task || $0.integration?.resolveTask == task }
    }

    /// Asks the lead agent for a plan. The lead gets read-only access in its own worktree.
    @discardableResult func plan(goal: String, project: DesktopProject, root: URL, lead: CodingProvider, access: CodingAccess) async -> UUID? {
        let goal = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, state != nil, !goal.isEmpty else { return nil }
        let run = OrchestratorRun(projectID: project.id, projectPath: root.path, goal: goal, lead: lead, access: access)
        state!.runs.append(run)
        record(run.projectID, .plan, "Asked \(lead.title) to plan “\(run.title)”")
        guard persist() else { return nil }
        // Subtasks can go to any installed agent (every adapter), the lead included.
        var agents = CodingAgentRegistry.shared.available.map(\.provider)
        if !agents.contains(lead) { agents.insert(lead, at: 0) }
        let id = await store.create(project: project, root: root, provider: lead, model: "", access: .readOnly, isolated: true,
                                    prompt: OrchestratorPlanner.prompt(goal: goal, agents: agents), title: "Plan: " + run.title)
        guard let id else {
            mutate(run.id) { $0.phase = .reviewing; $0.plan = OrchestratorPlanner.single(goal: goal, agent: lead); $0.planNote = "The lead agent couldn't start" + (store.notice.isEmpty ? "." : ": " + store.notice) }
            return run.id
        }
        mutate(run.id) { $0.leadTask = id }
        // A lead that failed while it was being created (before its ID was known here) still ends planning.
        if let status = store.task(id)?.status, !status.running, status != .ready { planArrived(run.id) }
        return run.id
    }
    /// The lead's answer: its messages (and tool inputs, where a plan may also appear), in order.
    static func reply(of task: CodingTaskRecord) -> String {
        task.events.filter { $0.kind == .assistant || $0.kind == .command || $0.kind == .plan }
            .map { $0.kind == .assistant ? $0.text : $0.detail }.joined(separator: "\n\n")
    }
    /// What an agent said last, for handoffs.
    static func finalNote(of task: CodingTaskRecord) -> String {
        guard let lastUser = task.events.lastIndex(where: { $0.kind == .user }) else { return "" }
        return task.events[(lastUser + 1)...].filter { $0.kind == .assistant }.last?.text ?? ""
    }
    private func planArrived(_ runID: UUID) {
        guard let store, let run = run(runID), run.phase == .planning, let task = store.task(run.leadTask) else { return }
        var (plan, note) = OrchestratorPlanner.plan(from: Self.reply(of: task), goal: run.goal, lead: run.lead)
        if note != nil, task.status == .failed || task.status == .interrupted { note = "The lead agent stopped before proposing a plan." }
        mutate(runID) { $0.phase = .reviewing; $0.plan = plan; $0.planNote = note }
        record(run.projectID, .plan, note == nil ? "\(run.lead.title) proposed \(plan.subtasks.count) subtask\(plan.subtasks.count == 1 ? "" : "s") for “\(run.title)”" : "The plan for “\(run.title)” is one task: \(note!)", from: run.leadTask?.uuidString)
    }
    /// The person's edits while reviewing. Validated when they start it.
    func updatePlan(_ runID: UUID, _ plan: OrchestratorPlan) {
        guard run(runID)?.phase == .reviewing else { return }
        mutate(runID) { $0.plan = plan }
    }
    /// Starts the reviewed plan: only on the person's click.
    func start(_ runID: UUID) async {
        guard let run = run(runID), run.phase == .reviewing, let plan = run.plan else { return }
        do { try OrchestratorPlanner.validate(plan) } catch { notice = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription; return }
        let root = URL(fileURLWithPath: run.projectPath)
        do {
            let base = try await CodingCommand.git(["rev-parse", "HEAD"], at: root)
            let branch = try? await CodingCommand.git(["symbolic-ref", "--short", "HEAD"], at: root)
            mutate(runID) { $0.phase = .running; $0.baseCommit = base; $0.baseBranch = branch }
        } catch { notice = "Plans need a Git repository with at least one commit: " + error.localizedDescription; return }
        if let lead = run.leadTask, store?.task(lead)?.status.running == false { store?.markDone(lead) }
        record(run.projectID, .plan, "Started “\(run.title)”: " + plan.subtasks.map(\.title).joined(separator: " · "))
        await advance(runID)
    }
    func cancel(_ runID: UUID) {
        guard let run = run(runID), run.phase != .accepted else { return }
        if let lead = run.leadTask, store?.task(lead)?.status.running == true { store?.stop(lead) }
        mutate(runID) { $0.phase = .cancelled }
        record(run.projectID, .plan, "Cancelled “\(run.title)”. Its tasks and worktrees are kept.")
    }

    /// Where each subtask is, from its task's status.
    func states(_ run: OrchestratorRun) -> [String: OrchestratorSchedule.State] {
        var states: [String: OrchestratorSchedule.State] = [:]
        for subtask in run.plan?.subtasks ?? [] {
            guard let task = store?.task(run.tasks[subtask.id]) else { states[subtask.id] = .waiting; continue }
            switch task.status {
            case .preparing, .ready, .working, .needsInput: states[subtask.id] = .running
            case .review, .done: states[subtask.id] = .finished
            case .failed, .interrupted: states[subtask.id] = .failed
            }
        }
        return states
    }
    /// Starts every subtask whose dependencies have finished, up to the limit at once.
    func advance(_ runID: UUID) async {
        guard let run = run(runID), run.phase == .running, let plan = run.plan else { return }
        for id in OrchestratorSchedule.ready(plan.subtasks, states: states(run), limit: parallelLimit) {
            let key = runID.uuidString + "/" + id
            guard starting.insert(key).inserted else { continue }
            await startSubtask(runID, id)
            starting.remove(key)
        }
    }
    private func startSubtask(_ runID: UUID, _ subtaskID: String) async {
        guard let store, let run = run(runID), run.tasks[subtaskID] == nil, let plan = run.plan, let subtask = plan.subtask(subtaskID), let base = run.baseCommit else { return }
        let root = URL(fileURLWithPath: run.projectPath)
        var handoffs: [OrchestratorHandoff] = []
        var start = base, conflicts: [String] = []
        do {
            // Each dependency's result is committed where it stands, and this subtask starts from it.
            for dependency in subtask.dependsOn {
                guard let task = store.task(run.tasks[dependency]), let source = plan.subtask(dependency) else { continue }
                let commit = try await CodingIntegration.checkpoint(URL(fileURLWithPath: task.directory), message: "Tsukumo: \(source.title)")
                let files = try await CodingIntegration.changedFiles(from: task.baseCommit ?? base, to: commit, at: root)
                handoffs.append(.init(subtask: dependency, title: source.title, agent: task.provider.title, commit: commit, files: files, notes: Self.finalNote(of: task)))
            }
            if !handoffs.isEmpty { (start, conflicts) = try await CodingIntegration.combine(handoffs.map(\.commit), at: root) }
        } catch {
            notice = "Couldn't hand off to “\(subtask.title)”: " + error.localizedDescription
            record(run.projectID, .handoff, notice); return
        }
        var extra: [String] = []
        if !conflicts.isEmpty { extra.append("Some earlier results conflicted and aren't in your worktree yet (integration will settle them): " + conflicts.joined(separator: ", ")) }
        let prompt = OrchestratorHandoff.prompt(goal: run.goal, subtask: subtask, plan: plan, handoffs: handoffs, notes: extra)
        let project = DesktopProject(id: run.projectID, name: "", bookmark: Data())
        guard self.run(runID)?.phase == .running,
              let id = await store.create(project: project, root: root, provider: subtask.agent, model: "", access: run.access, isolated: true, prompt: prompt, title: subtask.title, base: start) else {
            notice = "“\(subtask.title)” couldn't start" + (store.notice.isEmpty ? "." : ": " + store.notice); return
        }
        mutate(runID) { $0.tasks[subtaskID] = id }
        for handoff in handoffs {
            let from = run.tasks[handoff.subtask]?.uuidString ?? handoff.subtask
            record(run.projectID, .handoff, "“\(handoff.title)” → “\(subtask.title)”: \(handoff.files.count) file\(handoff.files.count == 1 ? "" : "s") and its notes", from: from, to: id.uuidString)
            store.note(id, "Starting from “\(handoff.title)”", detail: handoff.summary)
        }
        if handoffs.isEmpty { record(run.projectID, .plan, "Started “\(subtask.title)” with \(subtask.agent.title)", from: id.uuidString) }
    }

    // MARK: Status changes (hook from CodingWorkspaceStore)

    func taskStatusChanged(_ id: UUID, _ status: CodingTaskStatus) {
        if status.running, autoCoordinate { startCoordinating() }
        // Later, never inside the store's own update.
        Task { @MainActor [weak self] in await self?.react(id, status) }
    }
    private func react(_ id: UUID, _ status: CodingTaskStatus) async {
        guard let state else { return }
        let settled = !status.running && status != .ready
        if settled { deliverQueued(id) }
        for run in state.runs where run.leadTask == id && run.phase == .planning && settled { planArrived(run.id) }
        if let placed = subtask(of: id), placed.run.phase == .running {
            let (run, subtask) = placed
            if status == .review { record(run.projectID, .plan, "“\(subtask.title)” finished", from: id.uuidString) }
            else if status == .failed { record(run.projectID, .plan, "“\(subtask.title)” failed; what depends on it waits", from: id.uuidString) }
            await advance(run.id)
            if let current = self.run(run.id), let plan = current.plan, states(current).values.allSatisfy({ $0 == .finished }), states(current).count == plan.subtasks.count, status == .review {
                record(run.projectID, .plan, "Every subtask of “\(run.title)” finished. Integrate when you're ready.")
            }
        }
        for run in state.runs where run.integration?.resolveTask == id && settled {
            record(run.projectID, .integration, "The conflict resolution finished. Continue integration to check and merge it.", from: id.uuidString)
        }
    }

    // MARK: Messages

    /// Sends an agent a message from the person. It appears in the task's conversation as the
    /// person's message; if the agent is mid-turn it waits (with a note saying so) until the turn ends.
    func message(_ taskID: UUID, _ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let store, let task = store.task(taskID), !text.isEmpty, state != nil else { return }
        record(task.projectID, .message, text, from: personID, to: taskID.uuidString)
        if task.status == .done { store.note(taskID, "Message not sent: this task is done", detail: text); return }
        if task.status.running || task.status == .ready || store.busy.contains(taskID) {
            state!.queued[taskID.uuidString, default: []].append(text); persist()
            store.note(taskID, "Message waiting for this turn to end", detail: text)
        } else { store.send(taskID, text) }
    }
    private func deliverQueued(_ taskID: UUID) {
        guard let store, var queue = state?.queued[taskID.uuidString], !queue.isEmpty, let task = store.task(taskID) else { return }
        guard !task.status.running, task.status != .done, !store.busy.contains(taskID) else { return }
        let next = queue.removeFirst()
        state!.queued[taskID.uuidString] = queue.isEmpty ? nil : queue; persist()
        store.send(taskID, next)
    }
    func queued(_ taskID: UUID) -> [String] { state?.queued[taskID.uuidString] ?? [] }

    /// Adds an entry to the project's timeline.
    func record(_ project: UUID, _ kind: CollabMessageKind, _ text: String, from: String? = nil, to: String = "", about: [String]? = nil) {
        guard state != nil else { return }
        let from = from ?? "tsukumo"
        let name = from == personID ? displayName() : from == "tsukumo" ? "Tsukumo" : UUID(uuidString: from).flatMap { store?.task($0)?.title } ?? from
        state!.messages.append(.init(id: UUID().uuidString, project: project.uuidString, from: from, fromName: name, to: to, text: text, date: Date(), kind: kind, about: about))
        if state!.messages.count > 600 { state!.messages.removeFirst(state!.messages.count - 600) }
        persist()
    }
    func timeline(_ project: UUID?) -> [CollabMessage] {
        guard let project else { return [] }
        return (state?.messages ?? []).filter { $0.project == project.uuidString }
    }

    // MARK: Tracking and overlaps

    func startCoordinating(every interval: Duration = .seconds(4)) {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.coordinate()
                try? await Task.sleep(for: interval)
            }
        }
    }
    /// One pass: what every open task touches, what the person changed by hand, new overlaps
    /// (each warned about once, in both tasks), and the shared board if the project is shared.
    func coordinate() async {
        guard let store, state != nil else { return }
        let generation = store.generation
        let live = store.tasks.filter { $0.status != .done && $0.archived != true }
        var fresh: [UUID: [CollabFileTouch]] = [:]
        for task in live {
            let found = await Self.touches(of: task)
            fresh[task.id] = found ?? touches[task.id] ?? []
        }
        var person: [UUID: [CollabFileTouch]] = [:]
        let projects = Dictionary(store.tasks.map { ($0.projectID, $0.projectPath) } + (state?.runs ?? []).map { ($0.projectID, $0.projectPath) }, uniquingKeysWith: { a, _ in a })
        for (project, path) in projects {
            // While a task works directly in the folder, its changes are the agent's, not the person's.
            if store.tasks.contains(where: { $0.projectID == project && !$0.isolated && $0.status != .done }) { continue }
            person[project] = await Self.touches(directory: URL(fileURLWithPath: path), base: "HEAD") ?? []
        }
        guard generation == store.generation else { return }
        if fresh != touches { touches = fresh }
        if person != personTouches {
            for (project, files) in person where files != personTouches[project] { personChanged[project] = Date() }
            personTouches = person
        }
        for project in projects.keys { warnOverlaps(project) }
        await publishShared()
    }

    /// A task's touches: its diff since its base (placed in functions where possible), files it
    /// created, and while it's working, the files its current turn's tools named. Nil if Git failed.
    static func touches(of task: CodingTaskRecord) async -> [CollabFileTouch]? {
        var found = await touches(directory: URL(fileURLWithPath: task.directory), base: task.baseCommit ?? "HEAD")
        if task.status.running {
            let reported = reportedPaths(task)
            let known = Set(found?.map(\.path) ?? [])
            found = (found ?? []) + reported.filter { !known.contains($0) }.map { CollabFileTouch(path: $0, kind: .changed) }
        }
        return found
    }
    static func touches(directory: URL, base: String) async -> [CollabFileTouch]? {
        guard let diff = try? await CodingCommand.git(["diff", "-U0", "--no-color", "--no-ext-diff", "--no-textconv", "--no-renames", base, "--"], at: directory),
              let untracked = try? await CodingCommand.git(["ls-files", "--others", "--exclude-standard", "-z"], at: directory) else { return nil }
        var result = CollabDiff.touches(diff: diff) { path in Self.text(directory, path) }
        for path in untracked.split(separator: "\0").map(String.init) where CollabPaths.valid(path) {
            let lines = Self.text(directory, path).map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? 0
            result.append(.init(path: path, kind: .changed, added: lines))
        }
        return result
    }
    private static func text(_ directory: URL, _ path: String) -> String? {
        let url = directory.appendingPathComponent(path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]), size.isSymbolicLink != true, (size.fileSize ?? 0) <= 1_000_000 else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }
    /// Files named by the current turn's file-change and tool events, relative to the task's folder.
    static func reportedPaths(_ task: CodingTaskRecord) -> [String] {
        let start = task.events.lastIndex { $0.kind == .user }.map { $0 + 1 } ?? 0
        guard start <= task.events.count else { return [] }
        var paths: [String] = []
        for event in task.events[start...] {
            if event.kind == .file { paths += event.detail.split(separator: "\n").map(String.init) }
            if event.kind == .command { paths += filePaths(in: event.detail) }
        }
        var seen: Set<String> = []
        return paths.compactMap { CollabPaths.relative($0, to: task.directory) }.filter { seen.insert($0).inserted }
    }
    private static let filePathPattern = try! NSRegularExpression(pattern: #"\"?(?:file_path|filePath|notebook_path|path)\"?\s*[:=]\s*\"?([^\",\]\}\n]+)"#)
    static func filePaths(in detail: String) -> [String] {
        filePathPattern.matches(in: detail, range: NSRange(detail.startIndex..., in: detail)).compactMap { match in
            Range(match.range(at: 1), in: detail).map { String(detail[$0]).trimmingCharacters(in: .whitespaces) }
        }
    }

    static func collabState(_ status: CodingTaskStatus) -> CollabState {
        switch status {
        case .preparing: .planning
        case .ready, .working: .working
        case .needsInput: .needsYou
        case .review: .review
        case .interrupted: .paused
        case .failed: .failed
        case .done: .done
        }
    }
    /// The project's board: every task of this account (with what it touches, including planned
    /// and assigned claims), the person's own folder, decisions, and the timeline; plus other
    /// people's part once the project is shared.
    func board(for project: UUID?) -> CollabBoard {
        guard let project, let store else { return CollabBoard() }
        let key = project.uuidString
        var tasks: [CollabTask] = []
        for task in store.tasks where task.projectID == project && task.archived != true {
            let placement = subtask(of: task.id)
            var files = touches[task.id] ?? task.changes.map { CollabFileTouch(path: $0.path, kind: .changed) }
            let changed = Set(files.map(\.path))
            let claims = (placement?.subtask.files ?? []) + task.claims
            files += Set(claims).subtracting(changed).sorted().filter(CollabPaths.valid).map { CollabFileTouch(path: $0, kind: .claimed) }
            if isHelper(task.id) { files = [] }
            tasks.append(.init(id: task.id.uuidString, project: key, owner: me, ownerName: displayName(), agent: task.provider.title, title: task.title,
                               state: Self.collabState(task.status), branch: task.branch, files: files, updated: task.updated,
                               plan: placement?.run.id.uuidString, subtask: placement?.subtask.id, dependsOn: placement?.subtask.dependsOn))
        }
        let mine = personTouches[project] ?? []
        tasks.append(.init(id: personID, project: key, owner: me, ownerName: displayName(), agent: nil, title: "Your working folder", state: mine.isEmpty ? .done : .working, files: mine,
                           updated: personChanged[project] ?? .distantPast))
        // Presence is refreshed once a minute (it counts for two), so a shared board isn't rewritten every few seconds.
        let seen = Date(timeIntervalSinceReferenceDate: (Date().timeIntervalSinceReferenceDate / 60).rounded(.down) * 60)
        var board = CollabBoard(tasks: tasks, presence: [.init(person: me, name: displayName(), project: key, device: "this Mac", lastSeen: seen)],
                                messages: timeline(project), ownership: (state?.ownership ?? []).filter { $0.project == key })
        if let share = shares[project] { board = board.merged(with: share.others()) }
        return board
    }
    private func warnOverlaps(_ project: UUID) {
        guard let store, state != nil else { return }
        for overlap in board(for: project).overlaps where !overlap.resolved {
            let ids = overlap.tasks.map(\.id).sorted()
            let key = project.uuidString + "|" + ids.joined(separator: ",") + "|" + overlap.id
            guard !state!.warned.contains(key) else { continue }
            state!.warned.append(key)
            if state!.warned.count > 2000 { state!.warned.removeFirst(state!.warned.count - 2000) }
            let place = overlap.path + (overlap.symbol.map { " (\($0))" } ?? "")
            for task in overlap.tasks {
                guard let id = UUID(uuidString: task.id) else { continue }
                let others = overlap.tasks.filter { $0.id != task.id }.map { "“\($0.title)”" }.joined(separator: ", ")
                store.note(id, "Overlap: \(place) is also being changed by \(others)", detail: "Open Coordination to pause one, hand the file off, or tell one agent about the other's change. Nothing was sent to the agent.")
            }
            record(project, .overlap, overlap.tasks.map { "“\($0.title)”" }.joined(separator: " and ") + " both touch " + place, about: ids)
        }
        persist()
    }

    // MARK: Overlap actions

    func pause(_ taskID: UUID) {
        guard let store, let task = store.task(taskID), task.status.running else { return }
        store.stop(taskID)
        record(task.projectID, .message, "Paused “\(task.title)”. Send it a message to resume.", from: personID, to: taskID.uuidString)
    }
    /// The file (or function) belongs to `owner` from now on.
    func assignOwner(_ path: String, symbol: String?, to owner: String, project: UUID) {
        guard state != nil, CollabPaths.valid(path) else { notice = "Choose a relative file path inside this project."; return }
        state!.ownership.removeAll { $0.project == project.uuidString && $0.path == path && $0.symbol == symbol }
        state!.ownership.append(.init(project: project.uuidString, path: path, symbol: symbol, task: owner, decidedBy: me, date: Date()))
        let name = board(for: project).tasks.first { $0.id == owner }?.title ?? "you"
        record(project, .message, "“\(name)” owns \(path)" + (symbol.map { " (\($0))" } ?? ""), from: personID, to: owner)
    }
    /// Hands an overlapping file to one task and asks the others to leave it alone.
    func handOff(_ overlap: CollabOverlap, to owner: CollabTask, project: UUID) {
        assignOwner(overlap.path, symbol: overlap.symbol, to: owner.id, project: project)
        let place = overlap.path + (overlap.symbol.map { " (\($0))" } ?? "")
        for other in overlap.tasks where other.id != owner.id {
            guard let id = UUID(uuidString: other.id) else { continue }
            message(id, "Coordination from Tsukumo: “\(owner.title)” now owns \(place). Leave it to them and undo any edits you made there that they don't need. If you need a change there, describe it in your final message instead of making it.")
        }
    }
    /// Tells one agent what another has done to a file they share, as a message in its conversation.
    func tell(_ taskID: UUID, about sourceID: UUID, path: String) async {
        guard let store, let source = store.task(sourceID), CollabPaths.valid(path) else { return }
        let directory = URL(fileURLWithPath: source.directory)
        var change = (try? await CodingCommand.git(["diff", "--no-color", "--no-ext-diff", source.baseCommit ?? "HEAD", "--", path], at: directory)) ?? ""
        if change.isEmpty, let text = Self.text(directory, path) { change = "(new file)\n" + text }
        if change.count > 6000 { change = String(change.prefix(6000)) + "\n… (shortened)" }
        message(taskID, """
        Coordination from Tsukumo: “\(source.title)” (\(source.provider.title)) is also changing \(path). Its change so far:
        ```diff
        \(change.isEmpty ? "(no change yet; it expects to edit this file)" : change)
        ```
        Keep your change compatible with it, and don't undo it.
        """)
    }

    // MARK: Integration

    func testCommand(for run: OrchestratorRun) -> String {
        state?.testCommands[run.projectID.uuidString] ?? CodingIntegration.detectTestCommand(at: URL(fileURLWithPath: run.projectPath)) ?? ""
    }
    /// Merges every finished subtask into the run's integration branch, in dependency order.
    func integrate(_ runID: UUID) async {
        guard let store, let run = run(runID), run.phase == .running || run.phase == .integrating, let plan = run.plan, let base = run.baseCommit, let storage = store.storage else { return }
        let states = states(run)
        guard plan.subtasks.allSatisfy({ states[$0.id] == .finished }) else { notice = "Every subtask needs to finish (or be marked done) before integrating."; return }
        guard working.insert(runID).inserted else { return }
        defer { working.remove(runID) }
        do {
            if run.integration == nil {
                let short = String(runID.uuidString.lowercased().prefix(8))
                let directory = storage.directory.appendingPathComponent("Worktrees/integration-" + runID.uuidString)
                let branch = "tsukumo/integration-" + short
                try await CodingIntegration.addWorktree(project: URL(fileURLWithPath: run.projectPath), base: base, directory: directory, branch: branch)
                mutate(runID) { $0.integration = .init(branch: branch, directory: directory.path, base: base) }
                record(run.projectID, .integration, "Integrating “\(run.title)” on \(branch)")
            }
            mutate(runID) { $0.phase = .integrating }
            try await mergeRemaining(runID)
        } catch {
            notice = "Integration stopped: " + error.localizedDescription
            record(run.projectID, .integration, notice)
        }
    }
    private func mergeRemaining(_ runID: UUID) async throws {
        guard let store, let run = run(runID), let plan = run.plan, let integration = run.integration, integration.conflict == nil else { return }
        let directory = URL(fileURLWithPath: integration.directory)
        for id in OrchestratorSchedule.order(plan.subtasks) where !(self.run(runID)?.integration?.merged.contains(id) ?? true) {
            guard let task = store.task(run.tasks[id]), let subtask = plan.subtask(id) else { continue }
            let commit = try await CodingIntegration.checkpoint(URL(fileURLWithPath: task.directory), message: "Tsukumo: " + subtask.title)
            switch try await CodingIntegration.merge(commit, into: directory, message: "Tsukumo: merge “\(subtask.title)”") {
            case .merged, .unchanged:
                mutate(runID) { $0.integration?.merged.append(id); $0.integration?.commits[id] = commit }
                record(run.projectID, .integration, "Merged “\(subtask.title)”", from: task.id.uuidString)
            case .conflict(let files):
                mutate(runID) { $0.integration?.conflict = .init(subtask: id, commit: commit, files: files) }
                record(run.projectID, .integration, "“\(subtask.title)” conflicts with what's merged so far in " + files.joined(separator: ", "), from: task.id.uuidString)
                return
            }
        }
        record(run.projectID, .integration, "Every subtask is merged. Run the tests, review, then accept.")
        let command = testCommand(for: run)
        if !command.isEmpty { await runTests(runID, command: command) }
    }
    /// Asks an agent to resolve the conflict in a new worktree holding the merge in progress.
    func resolveConflict(_ runID: UUID, agent: CodingProvider) async {
        guard let store, let run = run(runID), let plan = run.plan, let integration = run.integration, let conflict = integration.conflict, integration.resolveTask == nil,
              let subtask = plan.subtask(conflict.subtask) else { return }
        guard working.insert(runID).inserted else { return }
        defer { working.remove(runID) }
        let head: String
        do { head = try await CodingCommand.git(["rev-parse", "HEAD"], at: URL(fileURLWithPath: integration.directory)) }
        catch { notice = error.localizedDescription; return }
        let prompt = """
        Resolve merge conflicts. Tsukumo is integrating several agents' work toward this goal:
        \(run.goal)

        Merging “\(subtask.title)” into the work merged so far conflicted in: \(conflict.files.joined(separator: ", ")). The merge is in progress in your worktree, with conflict markers in those files.
        Resolve each file so both sides' intent is kept, remove every conflict marker, and don't make unrelated changes. Don't commit; Tsukumo commits the merge when you're done. End with a short note on how you resolved each file.
        """
        let project = DesktopProject(id: run.projectID, name: "", bookmark: Data())
        let commit = conflict.commit, title = subtask.title
        let id = await store.create(project: project, root: URL(fileURLWithPath: run.projectPath), provider: agent, model: "", access: .edit, isolated: true, prompt: prompt,
                                    title: "Resolve conflicts: " + title, base: head) { directory in
            _ = try await CodingIntegration.merge(commit, into: directory, message: "Tsukumo: merge “\(title)”", keepConflicts: true)
        }
        guard let id else { notice = "The resolving task couldn't start" + (store.notice.isEmpty ? "." : ": " + store.notice); return }
        mutate(runID) { $0.integration?.resolveTask = id }
        record(run.projectID, .integration, "Asked \(agent.title) to resolve the conflicts in " + conflict.files.joined(separator: ", "), from: personID, to: id.uuidString)
    }
    /// After a resolution (by an agent, or retried by hand): checks it, merges it, and carries on.
    func continueIntegration(_ runID: UUID) async {
        guard let store, let run = run(runID), let integration = run.integration else { return }
        guard working.insert(runID).inserted else { return }
        defer { working.remove(runID) }
        do {
            if let conflict = integration.conflict, let resolveID = integration.resolveTask, let task = store.task(resolveID) {
                guard !task.status.running else { notice = "The resolving agent is still working."; return }
                let folder = URL(fileURLWithPath: task.directory)
                let left = CodingIntegration.conflictMarkers(in: folder, paths: conflict.files)
                guard left.isEmpty else { notice = "Conflict markers remain in " + left.joined(separator: ", ") + "."; return }
                let commit = try await CodingIntegration.checkpoint(folder, message: "Tsukumo: merge “\(run.plan?.subtask(conflict.subtask)?.title ?? conflict.subtask)” (conflicts resolved)")
                let includes = try await CodingCommand.run("/usr/bin/git", ["merge-base", "--is-ancestor", conflict.commit, commit], at: folder)
                guard includes.code == 0 else { notice = "The resolution doesn't include the subtask's merge. Resolve again."; return }
                try await CodingIntegration.git(["merge", "--ff-only", commit], at: URL(fileURLWithPath: integration.directory))
                mutate(runID) { $0.integration?.merged.append(conflict.subtask); $0.integration?.commits[conflict.subtask] = commit; $0.integration?.conflict = nil; $0.integration?.resolveTask = nil }
                store.markDone(resolveID)
                record(run.projectID, .integration, "Merged the resolution of " + conflict.files.joined(separator: ", "), from: resolveID.uuidString)
            } else if integration.conflict != nil {
                // Retried without a resolving task: try the merge again as it stands now.
                mutate(runID) { $0.integration?.conflict = nil }
            }
            try await mergeRemaining(runID)
        } catch {
            notice = "Integration stopped: " + error.localizedDescription
            record(run.projectID, .integration, notice)
        }
    }
    /// Leaves the conflicting subtask out of the integration and carries on with the rest.
    func skipConflict(_ runID: UUID) async {
        guard let run = run(runID), let conflict = run.integration?.conflict else { return }
        if let resolve = run.integration?.resolveTask, store?.task(resolve)?.status.running == true { store?.stop(resolve) }
        mutate(runID) { $0.integration?.skipped.append(conflict.subtask); $0.integration?.merged.append(conflict.subtask); $0.integration?.conflict = nil; $0.integration?.resolveTask = nil }
        record(run.projectID, .integration, "Left “\(run.plan?.subtask(conflict.subtask)?.title ?? conflict.subtask)” out of the integration", from: personID)
        await continueIntegration(runID)
    }
    func runTests(_ runID: UUID, command: String) async {
        let command = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let run = run(runID), let integration = run.integration, !command.isEmpty, state != nil else { return }
        state!.testCommands[run.projectID.uuidString] = command
        mutate(runID) { $0.integration?.test = nil }
        record(run.projectID, .integration, "Running \(command) on the integration")
        let result = await CodingIntegration.runTests(command, in: URL(fileURLWithPath: integration.directory))
        mutate(runID) { $0.integration?.test = result }
        record(run.projectID, .integration, (result.passed ? "Tests passed: " : "Tests failed: ") + command)
    }
    func reviewIntegration(_ runID: UUID) async throws -> CodingReview {
        guard let run = run(runID), let integration = run.integration else { throw CodingFailure("Integrate first.") }
        return try await CodingIntegration.review(run: runID, directory: URL(fileURLWithPath: integration.directory), base: integration.base)
    }
    /// Accepts the reviewed integration into the base branch (the person's click), then marks the subtasks done.
    func accept(_ runID: UUID, review: CodingReview) async {
        guard let store, let run = run(runID), run.phase == .integrating, let plan = run.plan, let integration = run.integration, integration.conflict == nil,
              plan.subtasks.allSatisfy({ integration.merged.contains($0.id) }), let baseBranch = run.baseBranch, review.taskID == runID else { return }
        guard working.insert(runID).inserted else { return }
        defer { working.remove(runID) }
        do {
            let commit = try await CodingIntegration.accept(review, integration: URL(fileURLWithPath: integration.directory), branch: integration.branch,
                                                            project: URL(fileURLWithPath: run.projectPath), baseBranch: baseBranch, title: run.title)
            mutate(runID) { $0.integration?.accepted = commit; $0.phase = .accepted }
            for id in run.tasks.values where store.task(id)?.status.running == false { store.markDone(id) }
            let tested = integration.test.flatMap { $0.passed && $0.tree == review.tree ? $0.command : nil }
            record(run.projectID, .integration, "Accepted “\(run.title)” into \(baseBranch) at \(commit.prefix(12))." + (tested.map { " \($0) passed on this version." } ?? " No tests passed on this exact version."), from: personID)
        } catch {
            notice = error.localizedDescription
            record(run.projectID, .integration, "Accept paused: " + error.localizedDescription)
        }
    }

    // MARK: Sharing

    /// Turns sharing on for a project (once a transport exists). The project is named by its Git remote.
    func share(_ project: UUID, root: URL) async {
        guard let factory = Self.transportFactory, let storage = store?.storage, state != nil else {
            notice = "Sharing starts once iCloud sync is set up."; return
        }
        guard let remote = try? await CodingCommand.git(["config", "--get", "remote.origin.url"], at: root), let id = CollabProject.id(remote: remote) else {
            notice = "Add a Git remote (origin) so other people's Tsukumo can find this project."; return
        }
        let engine = SyncEngine(transport: factory(id), device: AccountRecords.deviceID(), url: storage.directory.appendingPathComponent("Shared/" + id + ".json"))
        attach(CollabShare(engine: engine, project: id, me: me), to: project)
        if !state!.shared.contains(project.uuidString) { state!.shared.append(project.uuidString); persist() }
    }
    /// Uses a share for a project's board (tests use one on `MemorySyncTransport`).
    func attach(_ share: CollabShare, to project: UUID) { shares[project] = share }
    func isShared(_ project: UUID?) -> Bool { project.map { shares[$0] != nil } ?? false }
    /// This person's part of each shared board, under the shared project's name, then a sync.
    func publishShared() async {
        for (project, share) in shares {
            var board = board(for: project)
            board.tasks = board.tasks.filter { $0.owner == me }.map { var task = $0; task.project = share.project; return task }
            board.presence = board.presence.map { var presence = $0; presence.project = share.project; presence.device = share.engine.device; return presence }
            let authors = Set(board.tasks.map(\.id)).union([personID, me])
            board.messages = board.messages.filter { authors.contains($0.from) }.map { var message = $0; message.project = share.project; return message }
            board.ownership = board.ownership.map { var owner = $0; owner.project = share.project; return owner }
            do { try share.publish(board); try await share.engine.sync() }
            catch { notice = (error as? SyncError).map { if case .unavailable(let reason) = $0 { reason } else { "\($0)" } } ?? error.localizedDescription }
        }
    }
}
