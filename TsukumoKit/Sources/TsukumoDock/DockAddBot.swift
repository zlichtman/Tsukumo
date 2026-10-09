#if os(macOS)
import SwiftUI
import TsukumoCore
import TsukumoEngines
import TsukumoGateway
import TsukumoUI

// Add a Bot, beside the dock (October 8, 2026, the owner: "the first thing is, do they have something to import as a
// bot?"). First the bots the owner already has elsewhere, to bring in: their ChatGPT dot (read from Codex on this Mac),
// Tsukumo's Claude bot (Claude has no bot of its own, so Tsukumo makes one on the owner's Claude Code), and each agent
// signed in to the KemoSabe gateway; and a Leafy of their own on Codex (their dot's name and pet, chatting right here).
// Then continuing one of their recent Codex or Claude Code conversations as a bot, in that same session. Then making one:
// the owner's own name for it, its job, an engine of theirs, what they tell it, and a character (a Codex pet on a Codex
// bot, or the engine's mark).

/// The Add a Bot panel. `done` gets the bot that was added (nil when the owner closed it).
public struct DockAddBot: View {
    let dock: BotDock
    let done: (BotSpec?) -> Void
    @State private var draft: BotSpec
    @State private var problem: String?
    /// Making a new bot (2.01's flow): its AI model first, then its name, job, character, and drawers.
    @State private var making = false
    /// The new bot's AI model is picked (step two).
    @State private var picked = false
    @State private var open: Set<String> = ["Brain"]
    /// Which agent's conversations show ("codex" or "claude-code"): the model first.
    @State private var agent: String?
    @Environment(\.colorScheme) private var scheme

    public init(dock: BotDock, done: @escaping (BotSpec?) -> Void) {
        self.dock = dock; self.done = done
        let engine = DockAddBot.firstEngine(dock)
        _draft = State(initialValue: BotSpec(name: "", engine: engine, service: dock.service(of: engine)))
    }

    /// The first engine a new bot can run on here: an installed coding agent or a key, else Apple on-device.
    static func firstEngine(_ dock: BotDock) -> EngineID {
        dock.engineChoices.first { $0.unavailable == nil && $0.engine != .appleOnDevice }?.engine ?? .appleOnDevice
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if making {
                    Button { if picked { picked = false } else { making = false } } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(DockIconButtonStyle()).accessibilityLabel("Back").accessibilityIdentifier("addBotBack")
                }
                Text(making ? (picked ? "New Bot" : "Choose Its AI Model") : "Add a Bot").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { done(nil) } label: { Image(systemName: "xmark") }.buttonStyle(DockIconButtonStyle()).accessibilityLabel("Close")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                  if making {
                    if picked { newBot } else { modelStep }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange).accessibilityIdentifier("addBotProblem") }
                  } else {
                    // Connected: bots that live elsewhere. Made here: bots on the owner's engines on this Mac.
                    let offers = DockAddBot.offers(dock)
                    group("Connect") { bringIn(offers.filter(\.connected), empty: "Nothing to connect yet. Your ChatGPT dot shows here once Codex is on this Mac and signed in; Muse, Grok, OpenClaw, and Claude.ai show here once they sign in to KemoSabe (Settings, Bots, Connected).") }
                    let ready = offers.filter { !$0.connected }
                    if !ready.isEmpty { group("Ready Made") { bringIn(ready, empty: "") } }
                    let sessions = dock.codingSessions.filter { !dock.isBroughtIn($0) && dock.connections.installedAgents.contains($0.agent) }
                    if !sessions.isEmpty { group("Conversations") { continuing(sessions) } }
                    group("New Bot") {
                        Button { making = true; picked = false; problem = nil } label: {
                            row(mark: Image(systemName: "plus").font(.system(size: 15, weight: .semibold)).foregroundStyle(TsukumoTheme(scheme).accent),
                                title: "Make a Bot", detail: "Pick its AI model, then name it and give it a character.")
                        }
                        .buttonStyle(.plain).accessibilityIdentifier("addBotMakeNew")
                    }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange).accessibilityIdentifier("addBotProblem") }
                  }
                }
                .padding(14)
            }
        }
        .font(.system(size: 12.5))
        .accessibilityIdentifier("addBot")
    }

    // MARK: Bringing one in

    @ViewBuilder private func bringIn(_ offers: [Offer], empty: String) -> some View {
        if offers.isEmpty, !empty.isEmpty { note(empty) }
        ForEach(offers) { offer in
            HStack(alignment: .center, spacing: 10) {
                BotAvatar(bot: offer.bot, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(offer.bot.name).lineLimit(1)
                    Text(offer.detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if offer.unverified, let caller = offer.callerID {
                    Menu("This is…") {
                        ForEach(ServiceID.allCases) { service in
                            Button(service.title) { confirm(caller, as: service) }
                        }
                    }
                    .fixedSize().controlSize(.small).accessibilityIdentifier("addBotConfirm-" + caller)
                } else {
                    Button(offer.connected ? "Connect" : "Add") { add(offer.bot) }.controlSize(.small).accessibilityIdentifier("addBotBringIn-" + offer.id)
                }
            }
        }
    }

    /// Something the owner can bring in.
    struct Offer: Identifiable {
        var id: String
        var bot: BotSpec
        var detail: String
        var callerID: String?
        /// A caller the owner hasn't said which service it is.
        var unverified = false
        /// A bot that lives elsewhere (the dot, a gateway agent), not one made on this Mac's engines.
        var connected = true
    }

    /// What can be brought in now: the owner's ChatGPT dot, Tsukumo's Claude bot, and each gateway agent, unless it's
    /// on the dock already.
    static func offers(_ dock: BotDock) -> [Offer] {
        var offers: [Offer] = []
        let bots = dock.bots
        if let dot = dock.dot {
            if !bots.contains(where: { if case .dot(let id, _) = $0.origin { id == dot.id } else { false } }) {
                var bot = BotSpec(name: dock.uniqueName(dot.name), engine: .service(ServiceID.openAI.rawValue),
                                  role: "Your ChatGPT dot", origin: .dot(id: dot.id, thread: dot.thread), service: .openAI)
                if let pet = dot.pet { bot.look = dock.look(forPet: pet) }
                offers.append(Offer(id: "dot", bot: bot, detail: "Your ChatGPT dot. It lives in ChatGPT and Codex, and another app can’t message it: its page opens it in Codex. What it asks KemoSabe shows on its tile."))
            }
            // A Leafy of the owner's own, on their Codex: the dot's name and pet, chatting right here.
            let twinRole = "\(dot.name), on your Codex"
            if dock.connections.installedAgents.contains("codex"), !bots.contains(where: { $0.role == twinRole }) {
                var twin = BotSpec(name: dock.uniqueName(dot.name), engine: .codingAgent("codex"), role: twinRole, service: .codex)
                twin.instructions = "You're \(dot.name), the owner's friendly helper, here on their Mac. Be warm and brief, and ask KemoSabe for anything personal."
                if let pet = dot.pet { twin.look = dock.look(forPet: pet) }
                offers.append(Offer(id: "dot-codex", bot: twin,
                                    detail: "\(dot.name) to chat with right here, on your Codex, wearing its pet. It doesn’t share your dot’s memory in ChatGPT.",
                                    connected: false))
            }
        }
        if dock.connections.isConnected(.claude), dock.connections.installedAgents.contains("claude-code"), !bots.contains(where: \.isClaudeBot) {
            offers.append(Offer(id: "claude", bot: .claudeBot(name: dock.uniqueName("Claude")),
                                detail: "Tsukumo’s Claude bot: tasks in the background on your Claude Code, asking KemoSabe for anything personal. Claude has no bot of its own yet.",
                                connected: false))
        }
        for caller in dock.gatewayHub?.store.callers ?? [] where !caller.isTsukumosClaudeBot && !bots.contains(where: { $0.origin == .caller(id: caller.id) }) {
            let service = dock.store.binding(forCaller: caller.id)?.service
            let unverified = dock.store.binding(forCaller: caller.id) == nil
            var bot = BotSpec(name: dock.uniqueName(caller.name), engine: .service(service?.rawValue ?? "agent"),
                              origin: .caller(id: caller.id), service: service)
            // OpenClaw's agent comes in as the lobster.
            if service == .openClaw, let lobster = CodexPets.tsukumo.first(where: { $0.id == "tsukumo:lobster" }) {
                bot.look = .pet(lobster.id, name: lobster.name, image: CodexPets.avatarPNG(lobster, side: 96))
            }
            let detail = unverified
                ? "Signed in to KemoSabe and calls itself “\(caller.name)”. Say which service it is to bring it in."
                : (service.map { "Your \($0.title) agent, " } ?? "An agent, ") + DockPanelWords.kind(caller).lowercased() + "."
            offers.append(Offer(id: "caller-" + caller.id, bot: bot, detail: detail, callerID: caller.id, unverified: unverified))
        }
        return offers
    }

    private func confirm(_ caller: String, as service: ServiceID) {
        let kind = dock.gatewayHub?.store.caller(caller)?.kind
        let transport = kind == .token ? "with a token you made" : kind == .device ? "paired with this Mac" : kind == .local ? "from this Mac" : "signed in with OAuth"
        dock.bind(caller: caller, to: service, transport: transport)
        if let bot = dock.bots.first(where: { $0.origin == .caller(id: caller) }) { done(bot) }
    }

    // MARK: Continuing a conversation

    @ViewBuilder private func continuing(_ sessions: [CodingSession]) -> some View {
        let agents = ["codex", "claude-code"].filter { id in sessions.contains { $0.agent == id } }
        let shown = agent.flatMap { agents.contains($0) ? $0 : nil } ?? agents.first ?? "codex"
        if agents.count > 1 {
            Picker("Model", selection: Binding(get: { shown }, set: { agent = $0 })) {
                ForEach(agents, id: \.self) { id in Text(id == "codex" ? "Codex" : "Claude Code").tag(id) }
            }
            .pickerStyle(.segmented).labelsHidden().accessibilityIdentifier("addBotConversationAgent")
        }
        ForEach(sessions.filter { $0.agent == shown }.prefix(6)) { session in
            HStack(alignment: .center, spacing: 10) {
                ServiceMarkView(session.agent == "codex" ? .codex : .claude, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.title).lineLimit(1)
                    Text((session.folder as NSString).lastPathComponent + " · " + session.updated.formatted(.relative(presentation: .named)))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 6)
                Button("Continue") { bringIn(session) }.controlSize(.small).accessibilityIdentifier("addBotSession-" + session.id)
            }
        }
        note("A bot that picks up where the conversation left off, on the same agent in its folder, read only until you allow more.")
    }

    private func bringIn(_ session: CodingSession) {
        let engine = EngineID.codingAgent(session.agent)
        var bot = BotSpec(name: dock.uniqueName(String(session.title.prefix(28))), engine: engine,
                          role: "Continues “\(session.title)”", service: dock.service(of: engine),
                          contextScope: ContextScope(project: session.folder))
        bot.conversation = session.id
        switch dock.add(bot, continuing: session.id) {
        case .success(let added): problem = nil; done(added)
        case .failure(let failure): problem = failure.message
        }
    }

    // MARK: Making one

    /// Step one: which AI model runs it, each with what it is; one this Mac can't use says why.
    @ViewBuilder private var modelStep: some View {
        note("Pick what runs this bot. You can change it later in its Brain.")
        ForEach(dock.engineChoices) { choice in
            Button { pick(choice) } label: {
                row(mark: EngineMarkView(choice.info.mark, size: 20), title: choice.info.title, detail: choice.unavailable ?? choice.info.detail,
                    chevron: choice.unavailable == nil)
            }
            .buttonStyle(.plain).disabled(choice.unavailable != nil).opacity(choice.unavailable == nil ? 1 : 0.5)
            .accessibilityIdentifier("addBotEngine-" + choice.info.title)
        }
    }
    private func pick(_ choice: EngineChoice) {
        draft.engine = choice.engine; draft.model = nil; draft.effort = nil
        draft.service = dock.service(of: choice.engine)
        if !draft.wearsCodexPets, let pet = draft.look.pet, !BotLook.isTsukumoCharacter(pet) { draft.look = BotLook() }
        picked = true
    }

    /// Step two: its character beside its name (which it needs) and job, then drawers.
    @ViewBuilder private var newBot: some View {
        HStack(alignment: .center, spacing: 14) {
            Button { toggle("Character") } label: { BotAvatar(bot: draft, size: 72) }
                .buttonStyle(.plain).help("Character").accessibilityLabel("Character").accessibilityIdentifier("addBotCharacterButton")
            VStack(alignment: .leading, spacing: 7) {
                TextField("Your name for it", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("addBotName")
                TextField("What it does", text: $draft.role).textFieldStyle(.roundedBorder).accessibilityIdentifier("addBotRole")
                HStack(spacing: 5) {
                    EngineMarkView(dock.engineInfo(draft.engine).mark, size: 12)
                    Text(dock.engineInfo(draft.engine).title).font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Change") { picked = false }.buttonStyle(.link).font(.system(size: 11)).accessibilityIdentifier("addBotChangeEngine")
                }
            }
        }
        drawer("Character") {
            BotCharacterPicker(look: $draft.look, service: draft.service, pets: dock.pets, allowsPets: draft.wearsCodexPets)
        }
        if let choice = dock.engineChoices.first(where: { $0.engine == draft.engine }), !choice.models.isEmpty {
            drawer("Brain") {
                HStack(spacing: 8) {
                    Menu(draft.model.map(choice.name(of:)) ?? "Engine’s default") {
                        Button("Engine’s default") { draft.model = nil; draft.effort = nil }
                        Divider()
                        ForEach(choice.models, id: \.self) { model in
                            Button(choice.name(of: model)) { draft.effort = choice.accepted(draft.effort, model: model); draft.model = model }
                        }
                    }.fixedSize().accessibilityIdentifier("addBotModel")
                    let efforts = choice.efforts(for: draft.model)
                    if !efforts.isEmpty {
                        Menu(draft.effort.map { $0.rawValue.capitalized } ?? "Default effort") {
                            Button("Default effort") { draft.effort = nil }
                            ForEach(efforts, id: \.self) { effort in Button(effort.rawValue.capitalized) { draft.effort = effort } }
                        }.fixedSize().accessibilityIdentifier("addBotEffort")
                    }
                }
                note(choice.info.detail)
            }
        }
        drawer("Instructions") {
            TextEditor(text: $draft.instructions)
                .font(.system(size: 12)).frame(minHeight: 56, maxHeight: 110)
                .scrollContentBackground(.hidden).padding(4)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityIdentifier("addBotInstructions")
            note("Sent with every message. KemoSabe keeps everything about you.")
        }
        HStack {
            note("It runs on your own sign-in or key, never Tsukumo’s, and asks KemoSabe for anything personal.")
            Spacer(minLength: 8)
            Button("Make Bot") { add(draft) }
                .buttonStyle(.borderedProminent).tint(TsukumoTheme(scheme).accent)
                .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                .keyboardShortcut(.defaultAction).accessibilityIdentifier("addBotMake")
        }
    }

    private func add(_ bot: BotSpec) {
        switch dock.add(bot) {
        case .success(let added): problem = nil; done(added)
        case .failure(let failure): problem = failure.message
        }
    }

    // MARK: Pieces

    private func toggle(_ title: String) {
        withAnimation(.snappy(duration: 0.2)) { if open.contains(title) { open.remove(title) } else { open.insert(title) } }
    }
    /// A group that opens and closes (2.01's drawers).
    private func drawer(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        let expanded = open.contains(title)
        return VStack(alignment: .leading, spacing: 9) {
            Button { toggle(title) } label: {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).accessibilityIdentifier("addBotDrawer-" + title)
            if expanded { content() }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    /// A row to pick: its mark, title, and one line, on a soft tile.
    private func row(mark: some View, title: String, detail: String, chevron: Bool = true) -> some View {
        HStack(spacing: 10) {
            mark.frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer()
            if chevron { Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
        .contentShape(Rectangle())
    }
    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
#endif
