import AppKit
import Observation

/// What Settings → Agents shows about the MacSpaces connection. A leftover socket file is never
/// reported as a connection: only a listener this process started counts.
@MainActor @Observable final class MacSpacesBridgeStatus {
    static let shared = MacSpacesBridgeStatus()
    enum State: Equatable {
        case off(String)
        case listening(since: Date)
        case failed(String)
    }
    private(set) var state: State = .off("Starts with Tsukumo.")
    /// The last request MacSpaces made and when; no prompt text is kept.
    private(set) var lastRequest: (operation: String, date: Date)?
    /// Connections closed before a reply, by stage, with the most recent one.
    private(set) var refusals = 0
    private(set) var lastRefusal: (note: String, date: Date)?
    /// Starts the receiver again after a failure (set by the app delegate).
    @ObservationIgnored var retry: (() -> Void)?
    func set(_ state: State) { self.state = state }
    func request(_ operation: MacSpacesBridge.Operation) { lastRequest = (operation.rawValue, Date()) }
    func refused(_ stage: LocalBridgeListener.FailureStage) {
        refusals += 1
        lastRefusal = (Self.note(stage), Date())
    }
    static func note(_ stage: LocalBridgeListener.FailureStage) -> String {
        switch stage {
        case .identity: "Refused an app that isn't the signed MacSpaces from this Mac account."
        case .request: "A request was malformed, too large, or didn't arrive in time."
        case .reply: "Tsukumo didn't answer within 5 seconds."
        case .write: "MacSpaces disconnected before the reply was delivered."
        }
    }
}

/// The personal KemoSabe chat as MacSpaces may use it: the open chat of the signed-in account.
/// The app's `AppStore` in the app; a fake in tests. Only the person's typed text goes in, and
/// nothing of the chat (not even its first words) goes back: it's listed as "KemoSabe chat".
@MainActor protocol MacSpacesPersonalChat: AnyObject {
    /// The open chat's ID, or nil when it has no messages yet.
    var bridgeChatID: UUID? { get }
    var bridgeReplying: Bool { get }
    /// Signed in, a model ready, storage working.
    var bridgeReady: Bool { get }
    /// The latest message's ID; a successful send changes it.
    var bridgeLastMessage: UUID? { get }
    var bridgeError: String? { get }
    func bridgeStartNewChat()
    func bridgeSend(_ text: String)
    func bridgeStop()
}

/// What the bridge can reach besides the coding store, supplied by the app delegate.
struct MacSpacesBridgeRoutes {
    /// The current account's personal chat (the app replaces its store on an account switch).
    var chat: @MainActor () -> (any MacSpacesPersonalChat)? = { nil }
    /// Coding projects a new quick task may start in, and how to reach their folders.
    var projects: @MainActor () -> [DesktopProject] = { [] }
    var resolve: @MainActor (UUID) throws -> URL = { _ in throw CocoaError(.fileNoSuchFile) }
    /// Settings a new quick task starts with (Tsukumo's remembered new-task settings).
    var newTask: @MainActor () -> CodingNewTaskSettings = { .remembered() }
    /// Brings a personal chat forward.
    var openChat: @MainActor () -> Void = {}
    /// Where MacSpaces stages attachments (tests use a temporary folder).
    var outbox: URL = MacSpacesBridge.outboxURL
}

/// Authenticated local adapter. Model selection, tools and approvals stay in Tsukumo.
@MainActor final class MacSpacesBridgeServer: NSObject {
    static let personalDestination = "personal"
    static let maxPersonalCharacters = 2000
    private let listener = LocalBridgeListener()
    private let coding: CodingWorkspaceStore
    private let openConversation: (UUID) -> Void
    private let endpoint: URL
    private let receiptsURL: URL
    private let status: MacSpacesBridgeStatus
    private let routes: MacSpacesBridgeRoutes
    private var receipts: BridgeReceiptStore?
    /// Quick tasks accepted but still being set up (Git worktree), and ones whose setup failed.
    private var creating: [UUID: (title: String, owner: String, failure: String?)] = [:]
    /// Tsukumo's own record of MacSpaces submissions, per account owner, outside the shared socket folder.
    nonisolated static var defaultReceiptsURL: URL {
        AccountDirectory.base.appendingPathComponent("MacSpaces", isDirectory: true).appendingPathComponent("bridge-receipts.json")
    }
    init(coding: CodingWorkspaceStore, receipts: BridgeReceiptStore? = nil, endpoint: URL = MacSpacesBridge.endpointURL,
         receiptsURL: URL = MacSpacesBridgeServer.defaultReceiptsURL, status: MacSpacesBridgeStatus = .shared,
         routes: MacSpacesBridgeRoutes = .init(), open: @escaping (UUID) -> Void) {
        self.coding = coding; self.receipts = receipts; self.endpoint = endpoint; self.receiptsURL = receiptsURL
        self.status = status; self.routes = routes; openConversation = open
        super.init()
    }
    var isListening: Bool { listener.isListening }
    /// Starts listening. Fails closed: unreadable receipts or an endpoint another listener holds
    /// leave the bridge off, with the reason in Settings → Agents.
    func start() throws {
        guard !listener.isListening else { return }
        do {
            if receipts == nil { receipts = try BridgeReceiptStore(url: receiptsURL) }
            listener.onFailure = { [weak self] stage in Task { @MainActor in self?.status.refused(stage) } }
            try listener.start(at: endpoint) { [weak self] data, reply in
                Task { @MainActor in reply(self?.handle(data) ?? Data()) }
            }
            status.set(.listening(since: Date()))
        } catch {
            receipts = nil
            status.set(.failed(error.localizedDescription))
            throw error
        }
    }
    func stop() {
        listener.stop()
        if case .listening = status.state { status.set(.off("Stopped.")) }
    }

    // MARK: Requests

    /// Answers in the request's version, so a version 1 MacSpaces keeps working. Discovery replies
    /// always carry capabilities; an older client ignores them, a newer one negotiates from them.
    func handle(_ data: Data) -> Data {
        var version = 1
        var response: MacSpacesBridge.Response
        do {
            guard data.count <= MacSpacesBridge.maxBytes else { throw MacSpacesBridge.Failure("Request too large.") }
            let request: MacSpacesBridge.Request
            do { request = try JSONDecoder().decode(MacSpacesBridge.Request.self, from: data) } catch { throw MacSpacesBridge.Failure("Tsukumo couldn't read this request. Update both apps.") }
            try request.validate()
            version = request.version
            status.request(request.operation)
            guard let storage = coding.storage, !coding.storageFailed else { throw MacSpacesBridge.Failure("Sign in to Tsukumo and resolve any storage errors first.") }
            let owner = storage.ownerID
            switch request.operation {
            case .discover:
                response = .init(conversations: discoverable(owner), status: "Choose a conversation or where a new task goes. Only what you type or attach is sent.",
                                 capabilities: capabilities())
            case .create:
                response = try once(request, owner: owner) { try create(request, owner: owner) }
            default:
                guard let id = request.conversation else { throw MacSpacesBridge.Failure("Choose a conversation first.") }
                if let chat = routes.chat(), let chatID = chat.bridgeChatID, chatID == id {
                    response = try personal(request, chat: chat, owner: owner)
                } else if let task = coding.task(id), task.ownerID == owner, task.archived != true {
                    response = try codingTask(request, task: task, owner: owner)
                } else if let pending = creating[id], pending.owner == owner {
                    if let failure = pending.failure { throw MacSpacesBridge.Failure(failure) }
                    guard request.operation == .status || request.operation == .open else { throw MacSpacesBridge.Failure("This task is still being set up. Try again in a moment.") }
                    if request.operation == .open { openConversation(id) }
                    response = .init(conversations: [preparing(id, title: pending.title)], status: CodingTaskStatus.preparing.title)
                } else { throw MacSpacesBridge.Failure("Conversation unavailable in this account.") }
            }
        } catch let failure as MacSpacesBridge.Failure { response = .init(error: failure.message, uncertain: failure.uncertain ? true : nil) }
        catch { response = .init(error: error.localizedDescription) }
        response.version = version
        return encode(response)
    }

    private func discoverable(_ owner: String) -> [MacSpacesBridge.Conversation] {
        var list: [MacSpacesBridge.Conversation] = []
        if let chat = routes.chat(), let summary = personalSummary(chat) { list.append(summary) }
        list += coding.tasks.filter { $0.archived != true && $0.ownerID == owner }.sorted { $0.updated > $1.updated }.prefix(100).map(summary)
        return list
    }
    private func capabilities() -> MacSpacesBridge.Capabilities {
        var destinations: [MacSpacesBridge.Destination] = []
        if routes.chat() != nil { destinations.append(.init(id: Self.personalDestination, title: "KemoSabe chat", kind: "personal", acceptsAttachments: false)) }
        destinations += routes.projects().prefix(30).map { .init(id: "project:" + $0.id.uuidString, title: String($0.name.prefix(60)), kind: "coding", acceptsAttachments: true) }
        return .init(version: MacSpacesBridge.version, operations: ["discover", "submit", "status", "cancel", "open", "create"],
                     destinations: destinations, maxAttachments: MacSpacesBridge.Attachment.maxCount, maxAttachmentBytes: MacSpacesBridge.Attachment.maxBytes)
    }

    /// Runs a sending request at most once per account and request UUID. The receipt is written
    /// before anything is dispatched; if it can't be, nothing is sent.
    private func once(_ request: MacSpacesBridge.Request, owner: String, _ dispatch: () throws -> MacSpacesBridge.Response) throws -> MacSpacesBridge.Response {
        guard let receipts else { throw MacSpacesBridge.Failure("Receipt storage unavailable; nothing was sent.") }
        if let old = try receipts.existing(request, owner: owner) { return old }
        // Everything that can be checked without acting is checked before the reservation, so a
        // refusal here leaves nothing sent and the outcome certain.
        try preflight(request, owner: owner)
        do { try receipts.reserve(request, owner: owner) } catch { throw MacSpacesBridge.Failure("Tsukumo couldn't record this request, so nothing was sent.") }
        var response: MacSpacesBridge.Response
        do { response = try dispatch() } catch {
            let failure = MacSpacesBridge.Response(error: error.localizedDescription + " Open Tsukumo to check; it will not be resent automatically.")
            try? receipts.complete(request, owner: owner, response: failure)
            return failure
        }
        // Already sent: a receipt that can't be completed stays "uncertain", which is still never resent.
        do { try receipts.complete(request, owner: owner, response: response) } catch {
            response.status = "Sent, but Tsukumo couldn't save its receipt. Check the conversation before sending again."
        }
        return response
    }
    /// Refusals that don't depend on acting: the destination, busy state, sizes and attachments.
    private func preflight(_ request: MacSpacesBridge.Request, owner: String) throws {
        let files = request.attachments ?? []
        if request.operation == .create {
            guard let destination = request.destination else { throw MacSpacesBridge.Failure("Choose where the new task goes.") }
            if destination == Self.personalDestination {
                guard let chat = routes.chat(), chat.bridgeReady else { throw MacSpacesBridge.Failure("KemoSabe chat isn't ready. Open Tsukumo to sign in or choose a model.") }
                guard !chat.bridgeReplying else { throw MacSpacesBridge.Failure("KemoSabe is still replying in the open chat. Try again when it finishes.") }
                guard files.isEmpty else { throw MacSpacesBridge.Failure("KemoSabe chat doesn't take attachments from MacSpaces yet.") }
                try checkPersonalLength(request.prompt ?? "")
            } else {
                guard let project = project(destination) else { throw MacSpacesBridge.Failure("That project isn't in Tsukumo anymore. Choose another.") }
                _ = try routes.resolve(project.id)
            }
        } else if let chat = routes.chat(), chat.bridgeChatID == request.conversation {
            guard chat.bridgeReady, !chat.bridgeReplying else { throw MacSpacesBridge.Failure("KemoSabe is busy or not ready. Open the chat in Tsukumo.") }
            guard files.isEmpty else { throw MacSpacesBridge.Failure("KemoSabe chat doesn't take attachments from MacSpaces yet.") }
            try checkPersonalLength(request.prompt ?? "")
        } else if let task = coding.task(request.conversation) {
            guard summary(task).canSubmit else { throw MacSpacesBridge.Failure("This conversation is busy or finished. Open it in Tsukumo.") }
        }
        // Every attachment must be exactly what was staged for this request.
        for file in files { _ = try file.read(for: request.id, outbox: routes.outbox) }
    }
    private func checkPersonalLength(_ text: String) throws {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).count <= Self.maxPersonalCharacters else {
            throw MacSpacesBridge.Failure("KemoSabe chat messages are limited to 2,000 characters.")
        }
    }
    private func project(_ destination: String) -> DesktopProject? {
        guard destination.hasPrefix("project:"), let id = UUID(uuidString: String(destination.dropFirst("project:".count))) else { return nil }
        return routes.projects().first { $0.id == id }
    }

    // MARK: Coding conversations

    private func codingTask(_ request: MacSpacesBridge.Request, task: CodingTaskRecord, owner: String) throws -> MacSpacesBridge.Response {
        let id = task.id
        switch request.operation {
        case .submit:
            return try once(request, owner: owner) {
                let input = try codingInput(request, taskID: id)
                let before = task.events.last?.id
                coding.send(id, input: input)
                guard !coding.storageFailed, let updated = coding.task(id), updated.events.last?.id != before, updated.status != .failed else {
                    throw MacSpacesBridge.Failure("Tsukumo could not start this request.")
                }
                return .init(conversations: [summary(updated)], status: "Submitted to Tsukumo. Approvals remain there.")
            }
        case .cancel:
            guard task.status.running else { throw MacSpacesBridge.Failure("This conversation has no running task.") }
            coding.stop(id)
            return .init(conversations: coding.task(id).map { [summary($0)] } ?? [], status: "Task cancelled.")
        case .open:
            openConversation(id)
            return .init(conversations: [summary(task)], status: "Opened in Tsukumo.")
        default:
            return .init(conversations: [summary(task)], status: task.status.title)
        }
    }
    /// A new coding task in a project, with the remembered agent and model. MacSpaces never raises
    /// access: the task asks first before editing or running commands, even if Tsukumo's own
    /// remembered setting allows more, so every approval happens in Tsukumo.
    private func create(_ request: MacSpacesBridge.Request, owner: String) throws -> MacSpacesBridge.Response {
        let destination = request.destination ?? ""
        if destination == Self.personalDestination {
            guard let chat = routes.chat() else { throw MacSpacesBridge.Failure("KemoSabe chat isn't available.") }
            chat.bridgeStartNewChat()
            return try sendPersonal(request.prompt ?? "", chat: chat, status: "Started a KemoSabe chat.")
        }
        guard let project = project(destination) else { throw MacSpacesBridge.Failure("That project isn't in Tsukumo anymore.") }
        let root = try routes.resolve(project.id)
        let id = UUID(), prompt = request.prompt ?? ""
        let input = try codingInput(request, taskID: id)
        var settings = routes.newTask()
        let order = CodingAccess.allCases
        if (order.firstIndex(of: settings.access) ?? 0) > (order.firstIndex(of: .edit) ?? 1) { settings.access = .edit }
        let title = String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(70))
        creating[id] = (title, owner, nil)
        let coding = coding
        Task { @MainActor [weak self] in
            let created = await coding.create(project: project, root: root, provider: settings.provider, model: settings.model, access: settings.access,
                                              isolated: settings.isolated, prompt: input.text, options: .init(effort: settings.effort, images: input.images, select: false, id: id))
            guard let self else { return }
            if created == nil { self.creating[id]?.failure = "Tsukumo couldn't create this task" + (coding.notice.isEmpty ? "." : ": " + coding.notice) }
            else { self.creating.removeValue(forKey: id) }
        }
        return .init(conversations: [preparing(id, title: title)], status: "Started a task in \(project.name). Approvals remain in Tsukumo.")
    }
    private func preparing(_ id: UUID, title: String) -> MacSpacesBridge.Conversation {
        .init(id: id, title: title, status: CodingTaskStatus.preparing.title, canSubmit: false, canCancel: false,
              kind: "coding", needsApproval: false, activity: "Setting up", updated: Date(), acceptsAttachments: true)
    }
    /// The prompt, with attachments copied out of MacSpaces' outbox into this account's Coding folder:
    /// images go to the agent as images, other files are named in the message by their copied path.
    private func codingInput(_ request: MacSpacesBridge.Request, taskID: UUID) throws -> CodingTurnInput {
        var input = CodingTurnInput(text: request.prompt ?? "")
        let files = request.attachments ?? []
        guard !files.isEmpty else { return input }
        guard let storage = coding.storage else { throw MacSpacesBridge.Failure("Sign in to Tsukumo first.") }
        let folder = storage.directory.appendingPathComponent("MacSpaces Attachments", isDirectory: true)
            .appendingPathComponent(taskID.uuidString, isDirectory: true).appendingPathComponent(request.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var others: [String] = []
        for file in files {
            let data = try file.read(for: request.id, outbox: routes.outbox)
            let copy = folder.appendingPathComponent(file.name)
            try data.write(to: copy, options: .withoutOverwriting)
            if CodingAttachments.isImage(copy) { input.images.append(copy) } else { others.append(copy.path) }
        }
        if !others.isEmpty { input.text += "\n\nAttached from MacSpaces:\n" + others.map { "- " + $0 }.joined(separator: "\n") }
        return input
    }
    private func summary(_ task: CodingTaskRecord) -> MacSpacesBridge.Conversation {
        let needsYou = task.status == .needsInput || coding.approvals[task.id] != nil
        return .init(id: task.id, title: String(task.title.prefix(100)), status: task.status.title,
                     canSubmit: !task.status.running && task.status != .done && !coding.busy.contains(task.id) &&
                        !coding.tasks.contains { $0.id != task.id && $0.directory == task.directory && $0.status.running },
                     canCancel: task.status.running, kind: "coding", needsApproval: needsYou,
                     activity: needsYou ? "Needs you in Tsukumo" : task.status.running ? Self.activity(task.events.last?.kind) : nil,
                     updated: task.updated, acceptsAttachments: true)
    }
    /// A content-free phrase for the latest step of a running task.
    static func activity(_ kind: CodingEvent.Kind?) -> String {
        switch kind {
        case .command: "Running a command"
        case .file: "Editing files"
        case .plan: "Planning"
        case .check: "Running a check"
        case .reasoning: "Thinking"
        case .assistant: "Writing"
        case .approval: "Needs you in Tsukumo"
        default: "Working"
        }
    }

    // MARK: Personal chat

    private func personal(_ request: MacSpacesBridge.Request, chat: any MacSpacesPersonalChat, owner: String) throws -> MacSpacesBridge.Response {
        switch request.operation {
        case .submit:
            return try once(request, owner: owner) { try sendPersonal(request.prompt ?? "", chat: chat, status: "Sent to KemoSabe.") }
        case .cancel:
            guard chat.bridgeReplying else { throw MacSpacesBridge.Failure("KemoSabe isn't replying right now.") }
            chat.bridgeStop()
            return .init(conversations: personalSummary(chat).map { [$0] } ?? [], status: "Reply stopped.")
        case .open:
            routes.openChat()
            return .init(conversations: personalSummary(chat).map { [$0] } ?? [], status: "Opened in Tsukumo.")
        default:
            return .init(conversations: personalSummary(chat).map { [$0] } ?? [], status: chat.bridgeReplying ? "Replying" : "Ready")
        }
    }
    private func sendPersonal(_ text: String, chat: any MacSpacesPersonalChat, status: String) throws -> MacSpacesBridge.Response {
        let before = chat.bridgeLastMessage
        chat.bridgeSend(text)
        guard chat.bridgeLastMessage != before else {
            throw MacSpacesBridge.Failure(chat.bridgeError ?? "KemoSabe couldn't send this.")
        }
        return .init(conversations: personalSummary(chat).map { [$0] } ?? [], status: status)
    }
    private func personalSummary(_ chat: any MacSpacesPersonalChat) -> MacSpacesBridge.Conversation? {
        guard let id = chat.bridgeChatID else { return nil }
        return .init(id: id, title: "KemoSabe chat", status: chat.bridgeReplying ? "Replying" : "Ready",
                     canSubmit: chat.bridgeReady && !chat.bridgeReplying, canCancel: chat.bridgeReplying, kind: "personal",
                     needsApproval: false, activity: chat.bridgeReplying ? "Writing a reply" : nil, updated: nil, acceptsAttachments: false)
    }
    private func encode(_ response: MacSpacesBridge.Response) -> Data { (try? JSONEncoder().encode(response)) ?? Data() }
}
