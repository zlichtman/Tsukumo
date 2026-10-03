import Foundation
import Observation

// Agents asking KemoSabe (design/CONTEXT-HARNESS.md#agents-asking-kemosabe). Muse, Claude Code, or
// Codex asks one question ("What time did she say she was free?") through the KemoSabe MCP server.
// The owner allows each agent once (Allow always, Allow once, Don't allow); Apple's on-device model
// then reads only what `ContextPolicy` lets that agent have and extracts only the answer ("Friday
// after 7"), which leaves through a single-use `AgentDisclosure` envelope. Sensitive items still go
// through the Share/Decline card; Device only and Secret items are never read for an agent. Every
// exchange is journaled: who asked, the question, why, exactly what was sent, what was left out.

extension ContextPurpose {
    /// Another agent's questions to KemoSabe: what an agent's "Allow always" or "Allow once" covers.
    static let agentQuestion: Self = "agent-question"
}

// MARK: Who's asking

enum AgentIdentity {
    /// The requester for an MCP connection: the identity its Tsukumo-written config names
    /// (`--agent`), otherwise the MCP client's own `clientInfo`. Both are what the client presents;
    /// any process of this macOS user could present them (design/CONTEXT-HARNESS.md).
    static func requester(agent: String?, clientName: String?, clientTitle: String?) -> AgentRequester? {
        let raw = (agent ?? clientName ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !raw.isEmpty else { return nil }
        if raw.contains("claude") { return .init(recipient: .codingAgent("claude-code"), name: "Claude Code") }
        if raw.contains("codex") { return .init(recipient: .codingAgent("codex"), name: "Codex") }
        if raw.contains("muse") { return .init(recipient: .externalAgent("com.meta.muse"), name: "Muse") }
        if raw.contains("cursor") { return .init(recipient: .codingAgent("cursor-agent"), name: "Cursor Agent") }
        let title = [clientTitle, clientName].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty }
        if raw.hasPrefix("acp:") {
            let id = slug(String(raw.dropFirst(4)))
            guard !id.isEmpty else { return nil }
            return .init(recipient: .acpAgent(id), name: String((title ?? id).prefix(60)))
        }
        let id = slug(raw)
        guard !id.isEmpty else { return nil }
        return .init(recipient: .externalAgent(id), name: String((title ?? id).prefix(60)))
    }
    /// The name a saved grant shows, from its recipient key.
    static func name(forKey key: String) -> String {
        switch key {
        case "coding:claude-code": "Claude Code"
        case "coding:codex": "Codex"
        case "agent:com.meta.muse": "Muse"
        case "coding:cursor-agent": "Cursor Agent"
        default: key.split(separator: ":", maxSplits: 1).last.map(String.init) ?? key
        }
    }
    static func slug(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "-_.".unicodeScalars.contains($0) }
            .map(Character.init).prefix(60))
    }
}

// MARK: The question and the answer

struct AgentQuestion: Identifiable, Equatable, Sendable {
    var id = UUID()
    let requester: AgentRequester
    let question: String
    /// Why it's asking, in its words.
    let purpose: String
    var receivedAt = Date()
    /// The MCP client as it named itself ("claude-code 2.1.282"), for the journal.
    var client: String?
    /// The chat hand-off that started the agent, when one did (`ChatHandoff`): its question and
    /// answer are shown in that chat.
    var handoff: UUID?
    static let maxQuestion = 500, maxPurpose = 200
    var isValid: Bool {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return !text.isEmpty && text.count <= Self.maxQuestion && purpose.count <= Self.maxPurpose
            && !requester.name.trimmingCharacters(in: .whitespaces).isEmpty && requester.recipient.locality != .onDevice
    }
}

enum AgentAnswer: Equatable, Sendable {
    /// Exactly what was sent.
    case answered(String)
    case notFound
    /// The owner said no, to the agent or to this item.
    case declined
    /// The owner hasn't answered the prompt or card yet.
    case waiting
    /// Locked, or Apple's on-device model isn't ready.
    case unavailable(String)
    /// The request itself is malformed.
    case refused(String)

    var status: String {
        switch self {
        case .answered: "answered"
        case .notFound: "notFound"
        case .declined: "declined"
        case .waiting: "waiting"
        case .unavailable: "unavailable"
        case .refused: "refused"
        }
    }
    /// What the agent reads.
    func text(owner: String = "The owner") -> String {
        switch self {
        case .answered(let text): text
        case .notFound: "KemoSabe couldn’t find that in what it may share with you."
        case .declined: "\(owner) didn’t share that. Don’t ask again for it; carry on without it or ask them directly."
        case .waiting: "\(owner) hasn’t answered on their \(AgentDevice.name) yet. Ask again in a minute."
        case .unavailable(let reason): reason
        case .refused(let reason): reason
        }
    }
}

enum AgentConsent: String, Equatable, Sendable { case always, once, deny }

/// What an answer left out, as counts by reason, level, and kind, never content. Keys are
/// "notRead.deviceOnly.conversation" (Device only and Secret are never read for an agent) and
/// "notShared.sensitive.journal" (Sensitive items that weren't shared).
struct AgentWithheld: Codable, Equatable, Sendable {
    var counts: [String: Int] = [:]
    var isEmpty: Bool { counts.isEmpty }
    var total: Int { counts.values.reduce(0, +) }
    mutating func add(_ reason: String, _ level: PrivacyLevel, _ kind: ContextItemKind) { counts[reason + "." + level.rawValue + "." + kind.rawValue, default: 0] += 1 }
    /// "Not read: 1 Device only chat, 2 Secret memories. Not shared: 1 Sensitive journal entry."
    var summary: String {
        func part(_ reason: String) -> String? {
            let keys: [String] = counts.keys.filter { $0.hasPrefix(reason + ".") }.sorted()
            let items: [String] = keys.compactMap { key -> String? in
                let count = counts[key] ?? 0
                let pieces = key.split(separator: ".").map(String.init)
                guard pieces.count == 3, let level = PrivacyLevel(rawValue: pieces[1]), let kind = ContextItemKind(rawValue: pieces[2]) else { return nil }
                return "\(count) \(level.title) \(AgentQuestionSource.noun(kind, count: count))"
            }
            return items.isEmpty ? nil : items.joined(separator: ", ")
        }
        var lines: [String] = []
        if let read = part("notRead") { lines.append("Not read: " + read + ".") }
        if let shared = part("notShared") { lines.append("Not shared: " + shared + ".") }
        return lines.joined(separator: " ")
    }
}

/// What one question touched, for the chat: what was left out, and what Kemo looked at on this
/// device, as counts ("7 messages, 2 chats"). Everything counted stayed here; only the answer left.
struct AgentExchangeReport: Equatable, Sendable {
    var withheld = AgentWithheld()
    var messages = 0
    var items: [ContextItemKind: Int] = [:]
    /// Calendar, Reminders, and Contacts reads, by connection, in the order they were read.
    var connections: [String] = []
    /// "7 messages, 2 chats, 1 memory, calendar", or nil when nothing was looked at.
    var stayed: String? {
        var parts: [String] = []
        if messages > 0 { parts.append("\(messages) message" + (messages == 1 ? "" : "s")) }
        for kind in ContextItemKind.allCases where kind != .connector {
            guard let count = items[kind], count > 0 else { continue }
            parts.append("\(count) " + AgentQuestionSource.noun(kind, count: count))
        }
        parts += connections.map { AgentQuestionSource.connectionNoun($0) }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
    mutating func looked(at sources: [AgentQuestionSource]) {
        for source in sources {
            messages += source.messages
            if source.item.ref.kind == .connector {
                if !connections.contains(source.item.ref.id) { connections.append(source.item.ref.id) }
            } else { items[source.item.ref.kind, default: 0] += 1 }
        }
    }
}

// MARK: Where answers can come from

/// One item an answer might come from. Its text is read only by Apple's on-device model here.
struct AgentQuestionSource: Equatable, Sendable {
    let item: ContextItem
    /// How the owner's own transcript and card name it ("your conversation with Sarah").
    let title: String
    let text: String
    /// The card's target, when the item can be shown on one.
    let target: AgentRequestTarget?
    var date: Date?
    /// For a chat or a Messages excerpt: how many messages it holds, for "Stayed on this Mac: 7 messages, 2 chats".
    var messages = 0
    /// Found by searching for this question (Messages, Contacts, Location), so it ranks as relevant
    /// even when it shares no word with the question.
    var matched = false

    static func noun(_ kind: ContextItemKind, count: Int = 1) -> String {
        let one = count == 1
        switch kind {
        case .conversation, .message: return one ? "chat" : "chats"
        case .memory: return one ? "memory" : "memories"
        case .doc: return one ? "doc" : "docs"
        case .journal: return one ? "journal entry" : "journal entries"
        case .person: return one ? "People note" : "People notes"
        case .connector: return one ? "calendar read" : "calendar reads"
        case .textMessage: return one ? "Messages excerpt" : "Messages excerpts"
        case .location: return "location"
        case .record, .slice: return one ? "item" : "items"
        }
    }
    /// "calendar", "reminders", "contacts": what a connection read is called in the transcript.
    static func connectionNoun(_ id: String) -> String { ConnectorID(rawValue: id)?.title.lowercased() ?? "connection" }
}

@MainActor protocol AgentQuestionSources {
    func sources() async -> [AgentQuestionSource]
    /// Everything `sources()` lists, plus what the sources that search (Messages, Contacts,
    /// Location) found for this question.
    func sources(for question: String) async -> [AgentQuestionSource]
}
extension AgentQuestionSources {
    func sources(for question: String) async -> [AgentQuestionSource] { await sources() }
}

/// The account's chats, memories, People notes, docs, and journal; Calendar, Reminders, and Contacts
/// when connected here; and the personal sources the owner turned on (`PersonalQuestionSource`).
@MainActor struct StoreAgentQuestionSources: AgentQuestionSources {
    weak var store: AppStore?
    /// Docs and Journal; nil leaves them out (tests).
    var docs: (() -> DocsStore)? = { DocsStore.shared }
    /// Apple's apps on this device: Calendar, Reminders, and Contacts, each only when connected.
    /// False leaves them out (tests), so a test never reads this device's real data.
    var includeCalendar = true
    /// Messages and Location; nil uses the store's (`AppStore.personalQuestionSources`, none in a test host).
    var personal: [any PersonalQuestionSource]? = nil
    func sources(for question: String) async -> [AgentQuestionSource] {
        var list = await sources()
        guard let store else { return list }
        let now = Date()
        if includeCalendar {
            let names = MessagesQuery.parse(question, knownNames: store.knownPeopleNames, now: now).names
            if let contacts = await store.contactsForAgentQuestion(names) {
                list.append(.init(item: .connector(.contacts), title: "your contacts", text: contacts, target: nil, date: now, matched: true))
            }
        }
        for source in personal ?? store.personalQuestionSources {
            list += await source.sources(for: question, now: now)
        }
        return list
    }
    func sources() async -> [AgentQuestionSource] {
        guard let store else { return [] }
        var list: [AgentQuestionSource] = []
        for archive in store.state.conversationArchives ?? [] {
            let title = archive.counterpart.map { "your conversation with \($0)" } ?? "your chat “\(archive.title)”"
            list.append(.init(item: .conversation(archive.id, level: archive.privacy), title: title,
                              text: archive.messages.map { "\($0.role): \($0.text)" }.joined(separator: "\n"), target: .conversation(archive.id),
                              date: archive.messages.last?.date ?? archive.date, messages: archive.messages.count))
        }
        for note in store.state.memories {
            list.append(.init(item: .init(.init(.memory, note.id), level: store.memoryLevel(note)), title: "a memory you saved", text: note.text, target: .memory(note.id)))
        }
        for profile in store.state.people?.profiles ?? [] {
            let lines = [profile.about].compactMap { $0 } + profile.sources.flatMap { source in source.fields.map { "\($0.kind.title): \($0.value)" } }
            list.append(.init(item: .person(profile), title: "what you’ve saved about \(profile.name)", text: lines.joined(separator: "\n"),
                              target: .person(profile.id), date: profile.lastInteraction))
        }
        if let docs = docs?() {
            docs.reloadIfNeeded()
            for page in docs.pages where page.trashed == nil {
                list.append(.init(item: .doc(page), title: "your doc “\(page.displayTitle)”", text: page.displayTitle + "\n" + page.plainText, target: .doc(page.id), date: page.modified))
            }
            for entry in docs.entries {
                list.append(.init(item: .journal(entry), title: "your journal entry for \(entry.day)", text: entry.day + "\n" + entry.plainText,
                                  target: .journal(entry.id), date: entry.modified))
            }
        }
        if includeCalendar, let calendar = await store.calendarTextForAgentQuestion(), !calendar.isEmpty {
            list.append(.init(item: .connector(.calendar), title: "your calendar", text: calendar, target: nil, date: Date()))
        }
        if includeCalendar, let reminders = await store.remindersForAgentQuestion() {
            list.append(.init(item: .connector(.reminders), title: "your reminders", text: reminders, target: nil, date: Date()))
        }
        return list
    }
}

// MARK: Waiting for a card

/// Replies from the card to a waiting question: opens the envelope once, for that requester, and
/// hands back exactly the text that leaves. A reply after the question gave up is refused, so the
/// card records that nothing was sent.
actor AgentQuestionReplyBox: AgentRequestTransport {
    enum Reply: Equatable, Sendable { case shared(String), declined, notFound, refused }
    private var result: Reply?
    private var finished = false
    private var waiter: CheckedContinuation<Reply?, Never>?
    struct Gone: Error {}

    func reply(_ reply: AgentRequestReply, to request: AgentRequest, disclosure: AgentDisclosure) async throws {
        guard !finished, result == nil else { throw Gone() }
        let value: Reply
        switch reply {
        case .shared(let envelope): value = .shared(try await disclosure.open(envelope, as: request.requester.recipient).text)
        case .declined: value = .declined
        case .notFound: value = .notFound
        case .refused: value = .refused
        }
        guard !finished else { throw Gone() }
        finish(value)
    }
    func wait(timeout: Duration) async -> Reply? {
        if finished { return result }
        return await withCheckedContinuation { continuation in
            waiter = continuation
            Task { try? await Task.sleep(for: timeout); self.finish(nil) }
        }
    }
    private func finish(_ value: Reply?) {
        guard !finished else { return }
        finished = true; result = value
        waiter?.resume(returning: value); waiter = nil
    }
}

// MARK: The desk

/// A line shown in the app when an agent was answered.
struct AgentQuestionNotice: Identifiable, Equatable {
    var id = UUID()
    let text: String
}

/// Answers agents' questions on this device. Owned by the store (`AppStore.agentQuestions`); the Mac's
/// bridge server calls `ask` for each `ask_kemosabe` call.
@MainActor @Observable final class AgentQuestionDesk {
    struct ConsentPrompt: Identifiable, Equatable {
        let requester: AgentRequester
        let question: String
        let purpose: String
        /// Asked in a chat with the agent: the chat's Kemo card asks, not an alert.
        var inChat = false
        var id: String { requester.recipient.key }
    }
    /// The agent waiting for the owner's first answer ("Let Muse ask KemoSabe?").
    private(set) var consent: ConsentPrompt?
    /// Shown briefly after an agent was answered.
    var notice: AgentQuestionNotice?

    @ObservationIgnored private weak var store: AppStore?
    @ObservationIgnored var model: any AgentExtractionModel = AppleAgentExtractionModel()
    @ObservationIgnored var sources: any AgentQuestionSources
    /// The Mac says whether its screen is locked; locked means no answers.
    @ObservationIgnored var isLocked: () -> Bool = { false }
    @ObservationIgnored var consentTimeout: Duration = .seconds(150)
    @ObservationIgnored var cardTimeout: Duration = .seconds(150)
    /// How long "Don't allow" keeps an agent from prompting again.
    @ObservationIgnored var quietAfterDeny: TimeInterval = 10 * 60
    nonisolated static let onceLifetime: TimeInterval = 10 * 60
    /// The most items the on-device model reads for one question.
    static let maxSources = 8
    @ObservationIgnored private var queue: [ConsentPrompt] = []
    @ObservationIgnored private var waiters: [String: [(UUID, CheckedContinuation<AgentConsent?, Never>)]] = [:]
    @ObservationIgnored private var deniedUntil: [String: Date] = [:]
    /// Chat hand-offs waiting to show their agent's questions and the answers, by hand-off.
    /// Called with no answer when the question arrives, then with the answer.
    @ObservationIgnored var handoffObservers: [UUID: (AgentQuestion, AgentAnswer?, AgentExchangeReport) -> Void] = [:]

    init(store: AppStore) {
        self.store = store
        sources = StoreAgentQuestionSources(store: store)
    }

    /// One question from an agent, answered or not. Never throws; every path is journaled except a
    /// locked account (which can't write) and a malformed request.
    func ask(_ question: AgentQuestion) async -> AgentAnswer {
        if let handoff = question.handoff, question.isValid { handoffObservers[handoff]?(question, nil, AgentExchangeReport()) }
        let (answer, report) = await respond(question)
        if let handoff = question.handoff { handoffObservers[handoff]?(question, answer, report) }
        return answer
    }

    private func respond(_ question: AgentQuestion) async -> (AgentAnswer, AgentExchangeReport) {
        let none = AgentExchangeReport()
        guard question.isValid else { return (.refused("Ask one question of up to \(AgentQuestion.maxQuestion) characters, with a short purpose."), none) }
        guard let store, store.storageError == nil, !isLocked() else {
            return (.unavailable("KemoSabe is locked right now (the \(AgentDevice.name) is locked or its data isn’t open). Ask again later."), none)
        }
        let key = question.requester.recipient.key
        if let until = deniedUntil[key], until > Date() {
            await journal(question, .declined, target: "nothing: you didn’t allow \(question.requester.name) to ask")
            return (.declined, none)
        }
        if store.state.agentQuestionGrants(for: question.requester.recipient).isEmpty {
            switch await requestConsent(question) {
            case nil:
                await journal(question, .unanswered, target: "nothing yet: waiting for you to allow \(question.requester.name)")
                return (.waiting, none)
            case .deny?:
                await journal(question, .declined, target: "nothing: you didn’t allow \(question.requester.name) to ask")
                return (.declined, none)
            case .always?, .once?: break
            }
        }
        // A hand-off's chat shows Kemo looking on this device while it reads.
        if question.handoff != nil { store.localLookup = question.question }
        defer {
            if question.handoff != nil, store.localLookup == question.question { store.localLookup = nil }
            if store.state.spendAgentQuestionOnce(question.requester.recipient) { store.save() }
        }
        return await answer(question, store: store)
    }

    private func answer(_ question: AgentQuestion, store: AppStore) async -> (AgentAnswer, AgentExchangeReport) {
        let (answer, withheld, looked) = await answerWithheld(question, store: store)
        var report = AgentExchangeReport(withheld: withheld)
        report.looked(at: looked)
        return (answer, report)
    }

    private func answerWithheld(_ question: AgentQuestion, store: AppStore) async -> (AgentAnswer, AgentWithheld, [AgentQuestionSource]) {
        let recipient = question.requester.recipient, now = Date()
        let relevant = Self.rank(await sources.sources(for: question.question), for: question.question)
        let decision = ContextPolicy.evaluate(relevant.map(\.item), to: recipient, purpose: .agentQuestion, grants: store.liveGrants, now: now)
        var withheld = AgentWithheld()
        var readable: [AgentQuestionSource] = [], sensitive: [AgentQuestionSource] = []
        for source in relevant {
            switch decision.denied[source.item.ref] {
            case nil: readable.append(source)
            case .needsGrant?: sensitive.append(source)
            case .staysOnDevice?, .secret?: withheld.add("notRead", source.item.level, source.item.ref.kind)
            }
        }
        guard let model = extractionModel else {
            return (.unavailable("Apple’s on-device model isn’t ready on the owner’s \(AgentDevice.name), so KemoSabe can’t look yet."), withheld, [])
        }
        let chosen = Array(readable.prefix(Self.maxSources))
        if !chosen.isEmpty {
            let level = chosen.map(\.item.level).max() ?? .open
            let text = chosen.map { "[\($0.title)]\n\($0.text)" }.joined(separator: "\n\n")
            let subject = AgentRequestSubject(item: .init(.init(.record, "agent-question:" + question.id.uuidString), level: level),
                                              title: "what \(question.requester.name) may read", text: text)
            let result: AgentExtractionResult
            do {
                result = try await store.runOnDeviceModel { try await AgentExtractor.run(model, lookingFor: question.question, subject: subject) }
            } catch {
                return (.unavailable("KemoSabe couldn’t read on the owner’s \(AgentDevice.name) right now. Ask again in a moment."), withheld, [])
            }
            if case .found(let slice) = result {
                for source in sensitive { withheld.add("notShared", source.item.level, source.item.ref.kind) }
                return (await disclose(AgentSlice(answer: slice.answer, excerpt: ""), level: level, question, read: chosen, withheld: withheld, store: store), withheld, relevant)
            }
        }
        // Not in what it may read without asking: a Sensitive item goes to the card, one item, and
        // the owner sees exactly what would be shared.
        if let best = sensitive.first(where: { $0.target != nil }), let target = best.target {
            for source in sensitive where source != best { withheld.add("notShared", source.item.level, source.item.ref.kind) }
            return (await askOnCard(question, target: target, withheld: withheld, store: store), withheld, relevant)
        }
        for source in sensitive { withheld.add("notShared", source.item.level, source.item.ref.kind) }
        await journal(question, .notFound, target: Self.readSummary(chosen), withheld: withheld, automatic: true)
        return (.notFound, withheld, relevant)
    }

    /// Sends the answer through a single-use envelope: a grant for exactly this slice, this
    /// requester, and this request, opened once immediately before it's returned.
    private func disclose(_ slice: AgentSlice, level: PrivacyLevel, _ question: AgentQuestion, read: [AgentQuestionSource],
                          withheld: AgentWithheld, store: AppStore) async -> AgentAnswer {
        let request = AgentRequest(id: question.id, requester: question.requester, target: .question,
                                   lookingFor: String(question.question.prefix(AgentRequest.maxLookingFor)), receivedAt: question.receivedAt,
                                   channel: .mcp, purpose: question.purpose, withheld: withheld)
        let disclosure = store.agentRequests.disclosure
        do {
            let envelope = try await disclosure.makeEnvelope(slice, level: level, for: request, grant: AgentDisclosure.grant(for: request))
            let sent = try await disclosure.open(envelope, as: question.requester.recipient)
            await journal(question, .shared, target: Self.readSummary(read), shared: sent.text, withheld: withheld, automatic: true)
            notice = .init(text: "Answered \(question.requester.name): “\(sent.text)”")
            return .answered(sent.text)
        } catch {
            await journal(question, .failed, target: Self.readSummary(read), withheld: withheld, automatic: true)
            return .unavailable("KemoSabe couldn’t send that. Nothing was shared.")
        }
    }

    private func askOnCard(_ question: AgentQuestion, target: AgentRequestTarget, withheld: AgentWithheld, store: AppStore) async -> AgentAnswer {
        let asking = question.question.count > 150 ? String(question.question.prefix(149)) + "…" : question.question
        let request = AgentRequest(id: question.id, requester: question.requester, target: target, lookingFor: "the answer to “\(asking)”",
                                   receivedAt: question.receivedAt, channel: .mcp, purpose: question.purpose, withheld: withheld)
        let box = AgentQuestionReplyBox()
        store.agentRequests.receive(request, replyTo: box)
        switch await box.wait(timeout: cardTimeout) {
        case .shared(let text)?:
            notice = .init(text: "Shared with \(question.requester.name): “\(text)”")
            return .answered(text)
        case .declined?, .refused?: return .declined
        case .notFound?: return .notFound
        case nil: return .waiting
        }
    }

    // MARK: Consent

    /// The owner's answer to "Let Muse ask KemoSabe?".
    func decide(_ choice: AgentConsent) {
        guard let prompt = consent, let store else { return }
        switch choice {
        case .always: store.state.allowAgentQuestions(prompt.requester.recipient, once: false); store.save()
        case .once: store.state.allowAgentQuestions(prompt.requester.recipient, once: true); store.save()
        case .deny: deniedUntil[prompt.id] = Date().addingTimeInterval(quietAfterDeny)
        }
        for (_, waiter) in waiters.removeValue(forKey: prompt.id) ?? [] { waiter.resume(returning: choice) }
        consent = nil
        if !queue.isEmpty { consent = queue.removeFirst() }
    }

    private func requestConsent(_ question: AgentQuestion) async -> AgentConsent? {
        let key = question.requester.recipient.key
        if consent?.id != key, !queue.contains(where: { $0.id == key }) {
            let prompt = ConsentPrompt(requester: question.requester, question: question.question, purpose: question.purpose, inChat: question.handoff != nil)
            if consent == nil { consent = prompt } else { queue.append(prompt) }
        }
        let token = UUID(), timeout = consentTimeout
        return await withCheckedContinuation { continuation in
            waiters[key, default: []].append((token, continuation))
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                // The prompt stays up: an answer after this still counts for the next question.
                guard let self, let index = self.waiters[key]?.firstIndex(where: { $0.0 == token }) else { return }
                self.waiters[key]?.remove(at: index).1.resume(returning: nil)
            }
        }
    }

    // MARK: Helpers

    private var extractionModel: (any AgentExtractionModel)? {
        if model.isAvailable { return model }
        #if DEBUG
        if AgentRequestFixture.requested { return FixtureAgentExtractionModel() }
        #endif
        return nil
    }

    private func journal(_ question: AgentQuestion, _ outcome: AgentRequestRecord.Outcome, target: String, shared: String? = nil,
                         withheld: AgentWithheld = .init(), automatic: Bool? = nil) async {
        guard let store else { return }
        await store.agentRequests.append(.init(id: question.id, requester: question.requester.name, requesterKey: question.requester.recipient.key,
            channel: AgentRequestChannel.mcp.rawValue, target: target, lookingFor: question.question, outcome: outcome, shared: shared,
            receivedAt: question.receivedAt, decidedAt: Date(), purpose: question.purpose.isEmpty ? nil : question.purpose,
            withheld: withheld.isEmpty ? nil : withheld.summary, withheldCount: withheld.isEmpty ? nil : withheld.total, automatic: automatic))
    }

    /// "your chats and calendar": the kinds the on-device model read, for the owner's transcript.
    static func readSummary(_ read: [AgentQuestionSource]) -> String {
        var nouns: [String] = []
        for source in read {
            let ref = source.item.ref
            let noun = ref.kind == .connector ? AgentQuestionSource.connectionNoun(ref.id) : AgentQuestionSource.noun(ref.kind, count: 2)
            if !nouns.contains(noun) { nouns.append(noun) }
        }
        guard !nouns.isEmpty else { return "nothing it may read matched" }
        return "your " + (nouns.count == 1 ? nouns[0] : nouns.dropLast().joined(separator: ", ") + " and " + nouns.last!)
    }

    static var stopWords: Set<String> { AgentQuestionTerms.stopWords }
    static func terms(_ text: String) -> Set<String> { AgentQuestionTerms.terms(text) }
    /// The items that share words with the question, best first (then newest). An item a source
    /// found by searching for this question (`matched`) counts as sharing one.
    static func rank(_ sources: [AgentQuestionSource], for question: String) -> [AgentQuestionSource] {
        let wanted = terms(question)
        guard !wanted.isEmpty else { return [] }
        struct Scored { let source: AgentQuestionSource; let score: Int; let date: Date }
        var scored: [Scored] = []
        for source in sources {
            let score = terms(source.title + "\n" + source.text).intersection(wanted).count + (source.matched ? 1 : 0)
            if score > 0 { scored.append(Scored(source: source, score: score, date: source.date ?? .distantPast)) }
        }
        scored.sort { left, right in left.score != right.score ? left.score > right.score : left.date > right.date }
        return scored.map(\.source)
    }
}

// MARK: Grants

extension SavedState {
    /// What "Allow always" and "Allow once" cover: every kind an answer can come from. A kind grant
    /// opens Personal items, never Sensitive (those still ask on the card).
    static let agentQuestionKinds: [ContextItemKind] = [.conversation, .memory, .doc, .journal, .person, .connector]

    /// The live grants that let this agent ask.
    func agentQuestionGrants(for recipient: RecipientID, now: Date = Date()) -> [RecipientGrant] {
        (recipientGrants ?? []).filter { $0.applies(to: recipient, purpose: .agentQuestion, now: now) }
    }
    /// Every agent that may ask, for Connections: one grant per agent, "always" before "once".
    func agentQuestionAgents(now: Date = Date()) -> [RecipientGrant] {
        var seen = Set<String>()
        return (recipientGrants ?? []).filter { $0.purpose == ContextPurpose.agentQuestion.rawValue && $0.isLive(now: now) }
            .sorted { left, right in left.singleUse != right.singleUse ? !left.singleUse : left.grantedAt > right.grantedAt }
            .filter { seen.insert($0.recipient).inserted }
    }
    mutating func allowAgentQuestions(_ recipient: RecipientID, once: Bool, now: Date = Date()) {
        var grants = (recipientGrants ?? []).filter { !($0.recipient == recipient.key && $0.purpose == ContextPurpose.agentQuestion.rawValue) }
        grants.append(RecipientGrant(recipient: recipient, kinds: Self.agentQuestionKinds, purpose: .agentQuestion,
                                     expiresAt: once ? now.addingTimeInterval(AgentQuestionDesk.onceLifetime) : nil, singleUse: once, grantedAt: now))
        recipientGrants = grants
    }
    /// Remove in Connections: the agent asks again next time.
    mutating func revokeAgentQuestions(_ recipientKey: String) {
        recipientGrants?.removeAll { $0.recipient == recipientKey && $0.purpose == ContextPurpose.agentQuestion.rawValue }
        if recipientGrants?.isEmpty == true { recipientGrants = nil }
    }
    /// "Allow once" covers one question: spent after it, answered or not.
    @discardableResult mutating func spendAgentQuestionOnce(_ recipient: RecipientID, now: Date = Date()) -> Bool {
        guard var grants = recipientGrants else { return false }
        let once = grants.filter { $0.recipient == recipient.key && $0.purpose == ContextPurpose.agentQuestion.rawValue && $0.singleUse }.map(\.id)
        guard !once.isEmpty else { return false }
        RecipientGrants.spend(once, in: &grants)
        grants = RecipientGrants.pruned(grants, now: now)
        recipientGrants = grants.isEmpty ? nil : grants
        return true
    }
}
