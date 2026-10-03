import Foundation

/// Handing a KemoSabe chat's context to a Tsukumo coding task (design/CONTEXT-HARNESS.md#context-packets).
/// The packet is evaluated for the task's agent (Claude Code, Codex, Muse, Cursor, or an ACP agent), and
/// only the allowed slice goes, ahead of the owner's message, as the task's opening context (or the next
/// message of a task that exists). The task keeps the packet's ID as its lineage; the delivery is journaled.
@MainActor enum TsukumoContextHandoff {
    /// The recipient an agent is, the same identity it has when it asks KemoSabe (`AgentIdentity`).
    static func recipient(_ provider: CodingProvider) -> RecipientID {
        switch provider {
        case .claude: .codingAgent("claude-code")
        case .codex: .codingAgent("codex")
        case .cursor: .codingAgent("cursor-agent")
        case .muse: .externalAgent("com.meta.muse")
        default: .acpAgent(provider.customID?.uuidString.lowercased() ?? provider.rawValue)
        }
    }

    /// A new task in each project with the remembered agent, and the latest tasks that can take a message.
    static func destinations(projects: [DesktopProject], tasks: [CodingTaskRecord], settings: CodingNewTaskSettings) -> [ContextPacketDestination] {
        var list = projects.map { project in
            ContextPacketDestination(kind: .codingTask, reader: recipient(settings.provider).key, name: settings.provider.title,
                                     place: "a new task in “\(project.name)”", project: project.id, provider: settings.provider.rawValue)
        }
        let known = Set(projects.map(\.id))
        let open = tasks.filter { $0.archived != true && $0.status != .done && !$0.status.running && known.contains($0.projectID) }
            .sorted { $0.updated > $1.updated }
        for task in open.prefix(4) {
            list.append(.init(kind: .codingTask, reader: recipient(task.provider).key, name: task.provider.title,
                              place: "the task “\(task.title)”", project: task.projectID, provider: task.provider.rawValue, task: task.id))
        }
        return list
    }

    /// Gives the packet to its task: a new one, started with `message`, or an existing one, as its next
    /// message. Returns the task's ID, or throws why not. Access never exceeds Ask first.
    static func deliver(_ packet: ContextPacket, message: String, store: AppStore, coding: CodingWorkspaceStore,
                        project: DesktopProject?, root: () throws -> URL, settings: CodingNewTaskSettings) async throws -> UUID {
        let destination = packet.destination
        guard destination.kind == .codingTask, let reader = destination.recipient else { throw CodingFailure("That destination isn’t a task.") }
        let review = packet.review(for: reader, grants: store.liveGrants)
        guard let text = ContextPacket.text(review, origin: packet.origin, limit: ContextPacketBuilder.largeLimit) else {
            throw CodingFailure("Nothing in it can go to \(destination.name).")
        }
        let taskID: UUID
        if let existing = destination.task {
            guard let task = coding.task(existing), !task.status.running, task.status != .done else {
                throw CodingFailure("That task is busy or finished. Choose another.")
            }
            let before = task.events.count
            coding.send(existing, input: .init(text: message.isEmpty ? "Here’s context from KemoSabe for this task." : message,
                                               context: text, contextOrigin: packet.origin))
            guard (coding.task(existing)?.events.count ?? before) > before else {
                throw CodingFailure(coding.notice.isEmpty ? "Tsukumo couldn’t send it to that task." : coding.notice)
            }
            coding.notePacket(packet.id, on: existing)
            taskID = existing
        } else {
            guard let project, !message.isEmpty else { throw CodingFailure("Say what the task is.") }
            var access = settings.access
            let order = CodingAccess.allCases
            if (order.firstIndex(of: access) ?? 0) > (order.firstIndex(of: .edit) ?? 1) { access = .edit }
            guard let created = await coding.create(project: project, root: try root(), provider: settings.provider, model: settings.model,
                                                    access: access, isolated: settings.isolated, prompt: message,
                                                    options: .init(effort: settings.effort, context: text, contextOrigin: packet.origin, packet: packet.id)) else {
                throw CodingFailure(coding.notice.isEmpty ? "Tsukumo couldn’t create the task." : coding.notice)
            }
            taskID = created
        }
        var journaled = packet
        journaled.destination.task = taskID
        await store.agentRequests.append(store.packetRecord(journaled, review: review, text: text))
        return taskID
    }
}

extension CodingWorkspaceStore {
    /// Adds a packet to a task's lineage.
    func notePacket(_ packet: UUID, on id: UUID) {
        guard task(id) != nil else { return }
        update(id) { $0.contextPackets = ($0.contextPackets ?? []) + [packet] }
        persist()
    }
}
