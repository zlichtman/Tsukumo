import SwiftUI

// Chatting with an agent in KemoSabe (design/CONTEXT-HARNESS.md#chatting-with-an-agent). On the Mac,
// the composer's model chip lists each installed coding agent (Claude Code, Codex, Muse Code, Cursor
// Agent, and any ACP agent added in Tsukumo) under "Chat with an agent": the chat becomes three-way,
// you, the agent, and Kemo. The agent runs headless on your own sign-in with the KemoSabe MCP server
// attached; when it asks Kemo something, Kemo steps in with a card ("Codex asked KemoSabe"), reads
// this device with Apple's on-device model, and answers; only the answer goes to the agent.
// "@Kemo …" talks to Kemo directly, on this device only. On iPhone the same agents run on the paired
// Mac (`MacRelayPhone`). The messages are ordinary chat messages marked with `ChatHandoff`, so they
// sync and show on iPhone too.

/// What a chat message is, in a chat with an agent.
struct ChatHandoff: Codable, Equatable, Sendable {
    enum Part: String, Codable, Sendable {
        /// Your message to the agent (it looks like any message of yours).
        case task
        /// The agent's question to Kemo, while Kemo reads (the card shows Kemo thinking, or asks
        /// your consent the first time).
        case question
        /// Kemo's answer to the agent's question, read on this device by Apple's on-device model.
        case answer
        /// The agent's reply.
        case result
        /// A line about the agent itself (it stopped, it needs a sign-in).
        case status
        /// A part from a newer build shows as a status line.
        init(from decoder: Decoder) throws { self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .status }
    }
    /// The chat with the agent (its working folder, and how its questions find this chat).
    var id: UUID
    var part: Part
    /// The agent's name ("Claude").
    var agent: String
    /// The question's purpose ("Why: planning a date"), or what the answer left out.
    var detail: String?
    /// Where Kemo answered ("Mac" or "iPhone").
    var device: String?
    /// The agent's own session, so the next message continues it (`claude --resume`).
    var session: String?
    /// On an answer: the question it answers.
    var question: String?
    /// On an answer: what Kemo looked at, which stayed on the device ("7 messages, 2 chats").
    var stayed: String?
    /// On an answer: exactly what went to the agent.
    var shared: String?
    /// The agent's chat ID ("claude-code", "codex", "muse", "cursor-agent", "acp:<id>"), so a reopened
    /// chat continues with the same agent. Nil on messages from before the other agents: Claude.
    var agentID: String? = nil

    /// The message's role: you, Kemo for its card, otherwise the agent.
    var speaker: String {
        switch part {
        case .task: "You"
        case .question, .answer: "KemoSabe"
        case .result, .status: agent
        }
    }
    /// "On this Mac · Apple on-device", or "On your Mac · …" when it's shown on another device.
    var localCaption: String { Self.localCaption(device ?? AgentDevice.name) }
    static func localCaption(_ device: String) -> String { (device == AgentDevice.name ? "On this " : "On your ") + device + " · Apple on-device" }
    /// "Stayed on this Mac: 7 messages, 2 chats".
    var stayedLine: String? { stayed.map { "Stayed on " + ((device ?? AgentDevice.name) == AgentDevice.name ? "this " : "your ") + (device ?? AgentDevice.name) + ": " + $0 } }
    static let claude = ChatAgents.claude.title
    /// Claude's `RecipientID`: Claude Code, whether Tsukumo or the chat started it.
    static let claudeAgentID = ChatAgents.claude.id
}

/// One agent a chat can be with: its chat ID (also its `RecipientID.codingAgent`, what a context packet
/// goes to), its name in the chat, its program's own name, and its official mark.
struct ChatAgentKind: Equatable, Sendable {
    /// "codex"
    let id: String
    /// "Codex": how the chat names it.
    let title: String
    /// "Codex": the program that runs it, for "Not signed in to Codex".
    let product: String
    /// Its official mark in the asset catalog, or "" for initials.
    let logo: String
}

/// The agents KemoSabe chats with, in the order the model menu lists them. An agent added in Tsukumo
/// (any ACP agent) is "acp:<its ID>" and shows its own name and initials.
enum ChatAgents {
    static let claude = ChatAgentKind(id: "claude-code", title: "Claude", product: "Claude Code", logo: "AgentLogoClaude")
    static let codex = ChatAgentKind(id: "codex", title: "Codex", product: "Codex", logo: "AgentLogoOpenAI")
    static let muse = ChatAgentKind(id: "muse", title: "Muse Code", product: "Muse Code", logo: "AgentLogoMuse")
    static let cursor = ChatAgentKind(id: "cursor-agent", title: "Cursor Agent", product: "Cursor Agent", logo: "AgentLogoCursor")
    static let builtIn = [claude, codex, muse, cursor]
    /// A built-in agent by its chat ID.
    static func kind(_ id: String) -> ChatAgentKind? { builtIn.first { $0.id == id } }
    /// A built-in agent by the name a chat shows ("Claude"), for its avatar.
    static func kind(title: String) -> ChatAgentKind? { builtIn.first { $0.title == title } }
}

extension ChatMessage {
    init(handoff: ChatHandoff, text: String, date: Date = Date()) {
        self.init(role: handoff.speaker, text: text, date: date)
        self.handoff = handoff
    }
}

/// An agent the chat can talk to, as the Mac offers it (installed, signed in) in the model chip, or as
/// the iPhone offers it through the paired Mac.
struct ChatAgentOption: Identifiable {
    /// "claude-code"
    let id: String
    /// "Claude"
    let title: String
    /// Its official mark, in the asset catalog ("" for initials).
    let logo: String
    /// "Claude Code · your own sign-in", "Not signed in", "Claude Code isn't installed".
    let detail: String
    let available: Bool
    /// Opens its own sign-in (a Tsukumo terminal tab running `claude`), or on iPhone, pairing with your Mac.
    var signIn: (() -> Void)?
    /// The button for `signIn`: "Sign in", or "Pair" on an iPhone that has no Mac yet.
    var actionTitle = "Sign in"
    /// A built-in agent by ID, for a chat whose agent isn't listed right now.
    static func known(_ id: String) -> ChatAgentOption? {
        ChatAgents.kind(id).map { .init(id: id, title: $0.title, logo: $0.logo, detail: "", available: true) }
    }
}

/// An agent's official mark as it's meant to be seen (Claude's and Cursor's in their own colors,
/// OpenAI's in the text color, Muse's in its blue), or the agent's initial when it has none.
struct ChatAgentLogo: View {
    let logo: String
    var title = ""
    var size: CGFloat = 16
    var body: some View {
        Group {
            if logo.isEmpty {
                ZStack {
                    Circle().fill(Color(hue: 0.62, saturation: 0.5, brightness: 0.78))
                    Text(String(title.prefix(1)).uppercased()).font(.system(size: size * 0.55, weight: .bold, design: .rounded)).foregroundStyle(.white)
                }
            } else {
                Image(logo).resizable().interpolation(.high).scaledToFit()
                    .foregroundStyle(logo == ChatAgents.muse.logo ? Color(red: 0.03, green: 0.4, blue: 1) : Color.primary)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

private struct ChatAgentsKey: EnvironmentKey { static let defaultValue: [ChatAgentOption] = [] }
extension EnvironmentValues {
    /// The agents this device can chat with: the Mac's own, or on iPhone, the paired Mac's (`MacRelayPhone`).
    var chatAgents: [ChatAgentOption] {
        get { self[ChatAgentsKey.self] }
        set { self[ChatAgentsKey.self] = newValue }
    }
}

/// Who a message in a chat with an agent is for.
enum ChatAgentRouting {
    /// "@Kemo what's on my calendar?" (or the companion's own name) is for Kemo alone, on this device:
    /// the text after the mention. Anything else goes to the agent.
    static func kemoMessage(_ text: String, companion: String = CompanionIdentity.name) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for name in Set(["kemo", "kemosabe", companion.lowercased()]) {
            let mention = "@" + name
            guard trimmed.lowercased().hasPrefix(mention) else { continue }
            let rest = trimmed.dropFirst(mention.count)
            guard rest.isEmpty || rest.first?.isLetter == false else { continue }
            let message = rest.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ",:")))
            return message.isEmpty ? nil : message
        }
        return nil
    }
}

extension AppStore {
    /// This chat's agent chat, from its messages: the chat's ID and the agent's session to continue.
    var agentChat: (id: UUID?, session: String?) {
        let marked = conversationMessages.compactMap(\.handoff)
        return (marked.first?.id, marked.last { $0.session != nil }?.session)
    }
    /// The agent a chat with these messages is with (Claude for messages from before the other
    /// agents), or nil when it isn't a chat with an agent.
    static func chatAgent(in messages: [ChatMessage]) -> String? {
        let marked = messages.compactMap(\.handoff)
        guard !marked.isEmpty else { return nil }
        return marked.compactMap(\.agentID).last ?? ChatHandoff.claudeAgentID
    }
    /// A running turn's reply so far, kept with its own chat.
    func streamHandoff(_ chat: UUID, _ text: String) {
        guard handoffTurns[chat] != nil else { return }
        handoffTurns[chat]?.streaming = text
    }
    /// Adds a message to the agent chat `chat` (its handoff ID) wherever that chat is now: on screen,
    /// or saved in the conversation list after you switched chats. With `replacing`, a message with the
    /// same ID is replaced in place (Kemo's card when its answer arrives). Nothing is added to a chat
    /// that's gone (deleted), and never to another chat.
    func putHandoffMessage(_ message: ChatMessage, chat: UUID, replacing: Bool = false) {
        guard storageError == nil else { return }
        func belongs(_ list: [ChatMessage]) -> Bool { list.contains { $0.handoff?.id == chat } }
        func put(_ list: inout [ChatMessage], revision: Int?) {
            var message = message
            if replacing, let index = list.firstIndex(where: { $0.id == message.id }) {
                message.contextRevision = list[index].contextRevision; list[index] = message
            } else {
                if message.contextRevision == nil { message.contextRevision = revision }
                list.append(message)
            }
        }
        if belongs(state.messages) {
            put(&state.messages, revision: state.contextRevision ?? 0)
            state.messages = Array(state.messages.suffix(80))
        } else if let index = state.conversationArchives?.firstIndex(where: { belongs($0.messages) }) {
            put(&state.conversationArchives![index].messages, revision: nil)
        } else { return }
        save()
    }
}

/// A task handed to another agent that's still running in one chat.
struct HandoffTurn: Equatable {
    var agent: String
    var streaming = ""
}

// MARK: The transcript

/// Writes a chat with an agent: your message, then each question the agent asks Kemo (a card that
/// becomes Kemo's answer), then the agent's reply. Shared by the Mac's Claude chat and the demo.
@MainActor enum ChatHandoffTranscript {
    /// Adds your message to the chat on screen and listens for the agent's questions to Kemo during
    /// its turn. Everything after this (the working row, the streaming reply, Kemo's cards, and the
    /// reply) stays with this chat (`id`), even after you switch to another one.
    static func beginTurn(_ id: UUID, text: String, agent: String, agentID: String? = nil, store: AppStore) {
        store.appendVisibleMessage(ChatMessage(handoff: .init(id: id, part: .task, agent: agent, agentID: agentID), text: text))
        store.handoffTurns[id] = HandoffTurn(agent: agent)
        var cards: [String: UUID] = [:]
        store.agentQuestions.handoffObservers[id] = { [weak store] question, answer, report in
            guard let store else { return }
            guard let answer else {
                // Asked: Kemo's card shows the question and Kemo reading this device (or asks you first).
                let message = ChatMessage(handoff: .init(id: id, part: .question, agent: agent, detail: question.purpose.isEmpty ? nil : "Why: " + question.purpose,
                                                         device: AgentDevice.name, agentID: agentID), text: question.question)
                cards[question.id.uuidString] = message.id
                store.putHandoffMessage(message, chat: id)
                return
            }
            var shared: String?
            if case .answered(let text) = answer { shared = text }
            var withheld = report.withheld.isEmpty ? nil : report.withheld.summary
            if withheld == nil, shared == nil { withheld = "Nothing went to \(agent)." }
            var card = ChatMessage(handoff: .init(id: id, part: .answer, agent: agent, detail: withheld, device: AgentDevice.name, question: question.question,
                                                  stayed: report.stayed, shared: shared, agentID: agentID), text: answerText(answer, agent: agent))
            if let existing = cards.removeValue(forKey: question.id.uuidString) { card.id = existing; store.putHandoffMessage(card, chat: id, replacing: true) }
            else { store.putHandoffMessage(card, chat: id) }
        }
    }
    /// The agent's reply (with its session, so the next message continues it), or one status line, in
    /// the turn's own chat, whether it's on screen or saved in the list.
    static func finishTurn(_ id: UUID, agent: String, agentID: String? = nil, reply: String?, session: String?, problem: String? = nil, store: AppStore) {
        store.agentQuestions.handoffObservers[id] = nil
        store.handoffTurns[id] = nil
        if let reply, !reply.isEmpty {
            store.putHandoffMessage(ChatMessage(handoff: .init(id: id, part: .result, agent: agent, session: session, agentID: agentID), text: reply), chat: id)
        } else {
            store.putHandoffMessage(ChatMessage(handoff: .init(id: id, part: .status, agent: agent, session: session, agentID: agentID),
                                                text: problem.map { $0 == "Stopped." ? "\(agent) stopped." : "\(agent) stopped. " + $0 } ?? "\(agent) stopped without a reply."), chat: id)
        }
    }
    /// Kemo's line: exactly what the agent got, or why it got nothing.
    static func answerText(_ answer: AgentAnswer, agent: String) -> String {
        switch answer {
        case .answered(let text): text
        case .notFound: "I couldn’t find that in what \(agent) may ask about."
        case .declined: "I didn’t share that with \(agent)."
        case .waiting: "Waiting for you to allow \(agent)."
        case .unavailable(let reason), .refused(let reason): reason
        }
    }
}

// MARK: Avatars

/// Another agent's avatar: its official mark (Claude's spark, OpenAI's blossom for Codex, Muse's,
/// Cursor's cube), or its initial.
struct HandoffAgentAvatar: View {
    let agent: String
    var size: CGFloat = 28
    var body: some View {
        if let kind = ChatAgents.kind(title: agent) {
            ChatAgentLogo(logo: kind.logo, title: agent, size: size * 0.84).frame(width: size, height: size)
        } else {
            ChatAgentLogo(logo: "", title: agent, size: size)
        }
    }
}

/// Kemo's avatar with a lock ring: Kemo answering for another agent, on this device.
struct KemoLockedAvatar: View {
    let theme: BotTheme
    let accent: Color
    var home = false
    var orb: OrbState?
    var size: CGFloat = 28
    var body: some View {
        KemoAvatarSlot(theme: theme, home: home, orb: orb, accent: accent, size: size)
            .padding(2)
            .overlay(Circle().stroke(accent, lineWidth: 1.5))
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "lock.fill").font(.system(size: size * 0.3, weight: .bold)).foregroundStyle(.white)
                    .frame(width: size * 0.46, height: size * 0.46).background(accent, in: Circle())
                    .offset(x: 3, y: 3)
            }
            .accessibilityHidden(true)
    }
}

#if DEBUG
// MARK: The demo fixture

/// `--agent-handoff-fixture` (DEBUG only, with `--ui-testing --isolated-fixture`): a chat with Claude,
/// on Mac or iPhone, the same every run, about 20 seconds, ending on a still frame that loops. A fake
/// Claude runs in-process and a fake extractor stands in for Apple's on-device model; Sarah's thread
/// says she's free after 7, and a Device only thread is there to be left out.
///
/// 1. 1.5 s: the message types into the composer (about 2.5 s) and is sent.
/// 2. Claude works for 2.5 s, then asks Kemo "What time is Sarah free tonight?".
/// 3. Kemo's card: Kemo reads this device for 2.5 s (the orb, and its searching performance), then
///    answers "After 7 tonight", with what stayed and what was shared.
/// 4. Claude works for 3 s, then gives one place, a time, and a short reason. Then nothing moves.
@MainActor enum ChatHandoffFixture {
    static var requested: Bool { ProcessInfo.processInfo.arguments.contains("--agent-handoff-fixture") }
    /// The iPhone plays it once per launch.
    static var started = false
    static let task = "find a date spot for Sarah and I tonight"
    static let question = "What time is Sarah free tonight?"
    static let purpose = "planning a date tonight"
    static let result = "Sarah’s free after 7. Book Osteria Lucia on Valencia for 7:30: it’s quiet and candlelit, and a short walk from her place."
    static let claude = AgentRequester(recipient: .codingAgent(ChatHandoff.claudeAgentID), name: ChatHandoff.claude)
    static let chatID = UUID(uuidString: "5A3C0DE0-7A1E-4C6B-9E2A-000000000720")!
    /// The fixed pacing, in seconds.
    nonisolated static let typingStart = 1.5, typingSpeed = 16.0, sendPause = 0.5, working = 2.5, looking = 2.5, finishing = 3.0

    static func seed(_ store: AppStore) {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        func thread(_ id: String, _ lines: [(String, String)], level: PrivacyLevel?) -> ConversationArchive {
            var archive = ConversationArchive(id: UUID(uuidString: id)!, date: start, model: "Messages", recipient: nil,
                messages: lines.enumerated().map { index, line in ChatMessage(role: line.0, text: line.1, date: start.addingTimeInterval(Double(index) * 300)) },
                device: .this)
            archive.privacy = level
            return archive
        }
        store.state.conversationArchives = [
            thread("5A3C0DE0-7A1E-4C6B-9E2A-000000000701", [("You", "Dinner tonight?"), ("Sarah", "Tonight works! I'm free after 7."), ("You", "I'll find somewhere.")], level: nil),
            thread("5A3C0DE0-7A1E-4C6B-9E2A-000000000702", [("Sarah", "The new door code is 4411 if you get there before me tonight.")], level: .deviceOnly),
        ]
        store.state.allowAgentQuestions(claude.recipient, once: false)
        store.state.chatAgent = ChatHandoff.claudeAgentID
        store.save()
        store.agentQuestions.model = FakeExtraction()
        store.agentQuestions.sources = StoreAgentQuestionSources(store: store, docs: nil, includeCalendar: false)
    }

    /// Stands in for Apple's on-device model: finds when Sarah's free, after the fixture's looking pause.
    struct FakeExtraction: AgentExtractionModel {
        var delay = ChatHandoffFixture.looking
        let isAvailable = true
        func extract(lookingFor: String, from text: String) async throws -> AgentExtractionDraft {
            try await Task.sleep(for: .seconds(delay))
            guard let line = text.split(separator: "\n").first(where: { $0.contains("free after 7") }) else { return .init(found: false, answer: "", excerpt: "") }
            return .init(found: true, answer: "After 7 tonight", excerpt: String(line))
        }
    }

    /// The fake agent's turn (Claude's, unless tests name another): works, asks Kemo, works, and returns its reply.
    static func claudeTurn(chat: UUID, desk: AgentQuestionDesk?, pace: Double = 1, requester: AgentRequester? = nil) async -> String? {
        try? await Task.sleep(for: .seconds(working * pace))
        guard !Task.isCancelled, let desk else { return nil }
        _ = await desk.ask(.init(requester: requester ?? claude, question: question, purpose: purpose, client: "fixture", handoff: chat))
        try? await Task.sleep(for: .seconds(finishing * pace))
        return Task.isCancelled ? nil : result
    }

    /// Types the message into a composer, one character at a time, then sends it.
    static func type(into draft: @escaping (String) -> Void, then send: @escaping () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(typingStart))
            var typed = ""
            for character in task {
                typed.append(character); draft(typed)
                try? await Task.sleep(for: .seconds(1 / typingSpeed))
            }
            try? await Task.sleep(for: .seconds(sendPause))
            draft(""); send()
        }
    }

    /// iPhone (and any device without Claude Code): the chat played in-process.
    static func play(store: AppStore) {
        ChatHandoffTranscript.beginTurn(chatID, text: task, agent: ChatHandoff.claude, store: store)
        Task { @MainActor [weak store] in
            let reply = await claudeTurn(chat: chatID, desk: store?.agentQuestions)
            guard let store else { return }
            ChatHandoffTranscript.finishTurn(chatID, agent: ChatHandoff.claude, reply: reply, session: "fixture-session", store: store)
        }
    }
}
#endif
