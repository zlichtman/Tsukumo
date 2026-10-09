#if os(macOS)
import AppKit
import SwiftUI
import TsukumoCore
import TsukumoGate
import TsukumoGateway
import TsukumoUI
import TsukumoVoice

// A bot's panel, beside the dock or in Settings, Bots. KemoSabe's is its palette and its voice. Any other bot's is
// that bot and KemoSabe together: who it is (its name, job, what the owner told it, its character), what it runs on
// (a bot made here) or how it connects (a brought-in bot: the owner's ChatGPT dot, an agent signed in to the
// gateway), what it asked KemoSabe, what it was given, what it sent to the Inbox, what it may do without asking (its
// gateway grants and KemoSabe's consent), Revoke, and Remove from Dock. A bot that chats adds its settings: model and
// effort, project, access, voice, and chirps.

/// Words the dock uses for a bot's panel.
public enum DockPanelWords {
    /// The menu item that opens it.
    public static func menuTitle(_ bot: BotSpec) -> String {
        bot.isKemoSabe ? "\(bot.name)’s Settings…" : "\(bot.name)’s Settings and Activity…"
    }
    /// A caller's way in, in words.
    static func kind(_ caller: GatewayCaller) -> String {
        switch caller.kind {
        case .oauth: "Signed in to the gateway"
        case .token: "A token you made"
        case .device: "Paired with this Mac"
        case .local: "On this Mac"
        }
    }
    /// What KemoSabe did with a question, from its journal.
    static func outcome(_ entry: GateJournalEntry) -> String {
        switch entry.outcome {
        case .shared: entry.shared.map { "Shared: “\($0)”" } ?? "Answered"
        case .notFound: "Nothing matched"
        case .declined: "You didn’t allow it"
        case .waiting: "Waiting for you"
        case .unavailable: "KemoSabe couldn’t answer here"
        case .failed: "Not answered"
        }
    }
}

/// Words for one of the owner's bots.
public enum BotPanelWords {
    /// Where it's from and what runs it: "Made here · runs on Codex", "Your ChatGPT dot", "Brought in · asks KemoSabe
    /// through the gateway".
    public static func kind(_ bot: BotSpec, engine: String) -> String {
        if bot.isKemoSabe { return "Your secure assistant · Apple on-device" }
        if bot.isClaudeBot { return "Tsukumo’s Claude bot · on your Claude Code" }
        switch bot.origin {
        case .made: return "Made here · runs on " + engine
        case .dot: return "Your ChatGPT dot · lives in ChatGPT and Codex"
        case .caller: return (bot.service.map { $0.title + " · " } ?? "") + "asks KemoSabe through the gateway"
        }
    }
    /// A dot's conversation in the Codex app, with `message` typed into its composer, ready to send (Codex's own link
    /// for a conversation takes a prompt to prefill; it never sends it by itself).
    public static func codexLink(thread: String?, message: String? = nil) -> URL? {
        guard let thread, !thread.isEmpty, thread.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        var parts = URLComponents()
        parts.scheme = "codex"; parts.host = "threads"; parts.path = "/" + thread
        if let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            parts.queryItems = [URLQueryItem(name: "prompt", value: String(message.prefix(4000)))]
        }
        return parts.url
    }
}

/// Words for the KemoSabe gateway's ledger (Settings, Gateway, and each service's panel).
public enum LedgerWords {
    public static func outcome(_ entry: LedgerEntry) -> String {
        switch entry.outcome {
        case .disclosed: return entry.facts.prefix(3).joined(separator: "; ")
        case .nothingFound: return "Nothing matched"
        case .pending: return "Waiting for you"
        case .declined: return "You didn’t allow it"
        case .refused: return "Refused: " + (entry.note ?? "the rules")
        case .received: return entry.facts.first ?? "Sent you something"
        }
    }
    public static func flag(_ flag: LedgerFlag) -> String {
        switch flag {
        case .compositionRisk: "follows other requests"
        case .crossCallerCorrelation: "several agents"
        case .precisionProbe: "finer than you allow"
        case .calendarEnumeration: "many calendar requests"
        case .contactEnumeration: "many different people"
        case .slidingWindow: "narrow windows in a row"
        case .itemEnumeration: "asking for things that aren’t there"
        case .callerBudgetExceeded: "over its budget"
        case .crossCallerBudgetExceeded: "over the shared budget"
        case .rateLimit: "many requests this hour"
        case .consentRequired: "asked you"
        case .consentDeduplicated: "repeated request"
        case .consentRateLimit: "too many cards waiting"
        case .expiredGrant: "used an expired grant"
        case .delegationAttempt: "asked to act for another agent"
        case .untrustedInstruction: "carried instructions"
        case .resourceAbuse: "malformed or oversized"
        case .unknownCaller: "unknown agent"
        }
    }
}

/// One line of what a service asked KemoSabe, from KemoSabe's journal or the gateway's ledger.
public struct ServiceActivityLine: Identifiable, Hashable, Sendable {
    public var id: String
    public var date: Date
    /// "“What time is Sarah free tonight?”", "Free/busy times"
    public var title: String
    /// "Shared: “After 7”", "Waiting for you"
    public var outcome: String
    /// Whether something left (an answer, an excerpt, a file).
    public var shared: Bool
}

public extension BotDock {
    /// What a bot asked KemoSabe, newest first: its chat's questions (KemoSabe's journal) and its gateway callers'
    /// calls (the ledger), never the content that stayed.
    func activity(of bot: BotSpec, limit: Int = 30) -> [ServiceActivityLine] {
        let callers = callers(of: bot)
        let ids = Set(callers.map(\.id)), recipients = Set(callers.map { $0.recipient.key })
        var lines: [ServiceActivityLine] = []
        for entry in gate?.journal.all() ?? [] where entry.botID == bot.id || recipients.contains(entry.requester) {
            lines.append(ServiceActivityLine(id: "journal-" + entry.id.description, date: entry.decidedAt, title: "“" + entry.question + "”",
                                             outcome: DockPanelWords.outcome(entry), shared: entry.outcome == .shared))
        }
        for entry in gatewayHub?.ledger.entries ?? [] where ids.contains(entry.caller) && entry.outcome != .received && entry.tool != .ask {
            lines.append(ServiceActivityLine(id: "ledger-" + entry.id.uuidString, date: entry.at, title: entry.tool.title,
                                             outcome: LedgerWords.outcome(entry), shared: entry.outcome == .disclosed))
        }
        return Array(lines.sorted { $0.date > $1.date }.prefix(limit))
    }
    /// What a bot's gateway callers sent to the Inbox.
    func deliveries(of bot: BotSpec) -> [InboxItem] {
        let ids = Set(callers(of: bot).map(\.id))
        return (gatewayHub?.inbox.items ?? []).filter { ids.contains($0.caller) }.reversed()
    }
    /// Revokes a bot: its gateway callers (their tokens, grants, cards, and KemoSabe's consent) and KemoSabe's consent
    /// for its chat. A brought-in bot stays on the dock until the owner removes it; signing in again starts over.
    func revoke(_ bot: BotSpec) {
        if let hub = gatewayHub { for caller in callers(of: bot) { hub.revoke(caller) } }
        if bot.engine.chats { gate?.revokeConsent(.bot(bot)) }
    }
}

/// A bot's panel: KemoSabe's palette and voice, or a service's activity, permissions, and settings.
public struct DockBotPanel: View {
    let dock: BotDock
    let bot: BotSpec
    /// In Settings, Bots (no Open Chat).
    let inSettings: Bool
    /// More of KemoSabe's settings below its look (Settings, Bots: the bots it answers, chirps, its journal).
    let more: AnyView?
    let done: () -> Void
    @State private var draft: BotSpec
    @State private var watch: DockChirpWatch
    @State private var words: String
    @State private var problem: String?
    @State private var confirmRevoke = false
    @State private var confirmRemove = false
    @State private var dotMessage = ""
    /// The drawers open now: Brain, or Connection for a connected bot, to begin with.
    @State private var open: Set<String>
    @Environment(\.colorScheme) private var scheme

    public init(dock: BotDock, bot: BotSpec, inSettings: Bool = false, more: AnyView? = nil, done: @escaping () -> Void) {
        self.dock = dock; self.bot = bot; self.inSettings = inSettings; self.more = more; self.done = done
        _draft = State(initialValue: bot.normalized())
        _open = State(initialValue: bot.isKemoSabe ? ["Palette"] : bot.isBroughtIn ? ["Connection"] : ["Brain"])
        let saved = dock.store.chirpWatch(bot.id)
        _watch = State(initialValue: saved)
        _words = State(initialValue: saved.words.joined(separator: ", "))
    }

    private var accent: Color { TsukumoTheme(scheme).accent }
    private var choice: EngineChoice? { dock.engineChoices.first { $0.engine == draft.engine } }
    private var editable: Bool { true }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(bot.name).font(.system(size: 13, weight: .semibold))
                Spacer()
                if bot.engine.chats, !inSettings, !bot.isClaudeBot {
                    // Its chat, one click away (the chat has Settings, back here).
                    Button { dock.open(.bot(bot.id)) } label: { Image(systemName: "bubble.left") }
                        .buttonStyle(DockIconButtonStyle()).help("Chat with \(bot.name)").accessibilityLabel("Chat with \(bot.name)")
                        .accessibilityIdentifier("dockPanelChat")
                }
                Button { done() } label: { Image(systemName: "xmark") }.buttonStyle(DockIconButtonStyle()).accessibilityLabel("Close")
            }
            .padding(.horizontal, 14).padding(.vertical, 12)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if bot.isKemoSabe { kemoSabe } else { botContent }
                    if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(.orange) }
                }
                .padding(14)
            }
            Divider().opacity(0.5)
            HStack {
                if !bot.isKemoSabe {
                    if bot.isBroughtIn {
                        Button("Disconnect…", role: .destructive) { confirmRevoke = true }.accessibilityIdentifier("dockPanelDisconnect")
                    } else {
                        Button("Remove…", role: .destructive) { confirmRemove = true }.accessibilityIdentifier("dockPanelRemove")
                    }
                }
                Spacer()
                if editable {
                    Button("Cancel") { done() }
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent).tint(bot.isKemoSabe ? draft.kemoSabeColor : accent)
                        .keyboardShortcut(.defaultAction).accessibilityIdentifier("dockBotSave")
                } else {
                    Button("Done") { done() }.keyboardShortcut(.defaultAction)
                }
            }
            .controlSize(.regular).padding(12)
        }
        .font(.system(size: 12.5))
        .accessibilityIdentifier(bot.isKemoSabe ? "kemoSabeEditor" : "botPanel")
        .alert("Disconnect \(bot.name)?", isPresented: $confirmRevoke) {
            Button("Disconnect", role: .destructive) {
                dock.revoke(bot)
                if let failure = dock.remove(bot.id) { problem = failure.message } else { done() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its sign-ins and tokens stop working, its grants and waiting cards go, and it leaves the dock. Its chats are kept. Connecting it again starts over.")
        }
        .alert("Remove \(bot.name)?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive) { if let failure = dock.remove(bot.id) { problem = failure.message } else { done() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(bot.isBroughtIn
                 ? "It stays where it lives, and its chats here are kept. You can bring it in again from Add a Bot."
                 : "Its chats are kept with your other chats. Its engine and your keys stay as they are.")
        }
    }

    // MARK: KemoSabe

    @ViewBuilder private var kemoSabe: some View {
        KemoSabeHeader(bot: draft, device: "Mac", side: 104)
        drawer("Character") { KemoSabeCharacterPicker(bot: $draft) }
        drawer("Palette") {
            KemoSabePalettePicker(bot: $draft, minimum: 88, tileHeight: 72)
            note(KemoSabePalettePicker.footer(name: draft.name, device: "Mac") + " What it may read is in Settings, Connections.")
        }
        drawer("Voice") {
            VoicePicker(bot: $draft, compact: true)
            note(VoicePicker.footer(voice: dock.voice, device: "Mac"))
        }
        if let more { more }
    }

    // MARK: One of the owner's bots

    @ViewBuilder private var botContent: some View {
        // As in 2.01 (the owner, October 8, 2026: "a nice drawer thing"): who it is on top, its character beside its
        // name (tap it to open Character), then drawers that open and close, Brain (or Connection) first. One way out
        // at the bottom: Remove (made here) or Disconnect (connected).
        HStack(alignment: .center, spacing: 14) {
            Button { toggle("Character") } label: { BotAvatar(bot: draft, size: 72) }
                .buttonStyle(.plain).help("Character").accessibilityLabel("Character").accessibilityIdentifier("dockBotCharacterButton")
            VStack(alignment: .leading, spacing: 7) {
                TextField("Your name for it", text: $draft.name).textFieldStyle(.roundedBorder).accessibilityIdentifier("dockBotName")
                TextField("What it does", text: $draft.role).textFieldStyle(.roundedBorder).accessibilityIdentifier("dockBotRole")
                HStack(spacing: 5) {
                    if bot.isBroughtIn, let service = bot.service { ServiceMarkView(service, size: 14) }
                    else { EngineMarkView(dock.engineInfo(draft.engine).mark, size: 12) }
                    Text(BotPanelWords.kind(bot, engine: dock.engineInfo(draft.engine).title))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                    if case .dot(_, let thread) = bot.origin, let link = BotPanelWords.codexLink(thread: thread) {
                        Button("Open in Codex") { NSWorkspace.shared.open(link) }.buttonStyle(.link).font(.system(size: 11))
                            .accessibilityIdentifier("dockPanelOpenCodex")
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        drawer("Character") {
            BotCharacterPicker(look: $draft.look, service: draft.service, pets: dock.pets, allowsPets: draft.wearsCodexPets)
        }
        if case .dot(_, let thread) = bot.origin, BotPanelWords.codexLink(thread: thread) != nil { drawer("Message") { dotComposer(thread) } }
        if bot.isBroughtIn {
            drawer("Connection") { connections }
        } else if !bot.isClaudeBot {
            drawer("Brain") { engineMenu; modelMenus }
        }
        if draft.engine.chats, !bot.isClaudeBot, !bot.isBroughtIn {
            drawer("Instructions") {
                TextEditor(text: $draft.instructions)
                    .font(.system(size: 12)).frame(minHeight: 70, maxHeight: 140)
                    .scrollContentBackground(.hidden).padding(4)
                    .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                    .accessibilityIdentifier("dockBotInstructions")
                note("Sent to \(dock.engineInfo(draft.engine).title) with every message. KemoSabe keeps everything about you.")
            }
        }
        if draft.engine.chats, !bot.isBroughtIn { access }
        drawer("Allowed") { permissions }
        if draft.engine.chats { voiceAndChirps }
        drawer("Activity") { asked }
        let deliveries = dock.deliveries(of: bot)
        if !deliveries.isEmpty {
            drawer("Inbox") {
                ForEach(deliveries) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            Text(ByteCountFormatter.string(fromByteCount: Int64(item.bytes), countStyle: .file) + (item.note.map { " · " + $0 } ?? ""))
                                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let hub = dock.gatewayHub {
                            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hub.inbox.url(item)]) }.controlSize(.small)
                        }
                    }
                }
                note("Kept with macOS’s quarantine mark, never opened or run, never read by KemoSabe.")
            }
        }
    }

    /// A message to the owner's dot: it opens the dot's conversation in Codex with the message typed in, for the owner
    /// to send there (OpenAI has no way for another app to message a dot, so its reply is in Codex).
    @ViewBuilder private func dotComposer(_ thread: String?) -> some View {
        TextField("What should \(bot.name) do?", text: $dotMessage, axis: .vertical)
            .lineLimit(2...6).textFieldStyle(.roundedBorder).accessibilityIdentifier("dockDotMessage")
            .onSubmit { sendToDot(thread) }
        HStack {
            note("Opens \(bot.name)’s conversation in Codex with this typed in; press Return there to send it.")
            Spacer(minLength: 8)
            Button("Send in Codex") { sendToDot(thread) }
                .disabled(dotMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .accessibilityIdentifier("dockDotSend")
        }
    }
    private func sendToDot(_ thread: String?) {
        guard let link = BotPanelWords.codexLink(thread: thread, message: dotMessage) else { return }
        NSWorkspace.shared.open(link)
        dotMessage = ""
    }

    /// What a bot made here runs on: one of the engines on this Mac. A bot that continues a conversation stays on that
    /// conversation's agent, in its folder, where the session lives.
    @ViewBuilder private var engineMenu: some View {
        if bot.conversation != nil {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(.secondary)
                EngineMarkView(dock.engineInfo(draft.engine).mark, size: 14)
                Text(dock.engineInfo(draft.engine).title)
            }
            note("It continues a \(dock.engineInfo(draft.engine).title) conversation" + (draft.contextScope.project.map { " in " + ($0 as NSString).lastPathComponent } ?? "") + ", so it stays there.")
        } else {
        Menu(dock.engineInfo(draft.engine).title) {
            ForEach(dock.engineChoices) { choice in
                Button(choice.info.title + (choice.unavailable == nil ? "" : " (not on this Mac)")) {
                    guard draft.engine != choice.engine else { return }
                    draft.engine = choice.engine; draft.model = nil; draft.effort = nil
                    draft.service = dock.service(of: choice.engine)
                }
                .disabled(choice.unavailable != nil)
            }
        }
        .fixedSize().accessibilityIdentifier("dockBotEngine")
        note(dock.engineChoices.first { $0.engine == draft.engine }?.info.detail ?? "Runs on your own sign-in or key, never Tsukumo’s.")
        }
    }

    @ViewBuilder private var connections: some View {
        if case .dot = bot.origin {
            line(systemImage: "sparkles", "Your ChatGPT dot", "It lives in ChatGPT and Codex. Talk to it there: another app can’t message a dot. When ChatGPT asks KemoSabe through its connector, that shows here.")
        }
        let callers = dock.callers(of: bot)
        ForEach(callers) { caller in
            line(systemImage: caller.kind == .oauth ? "cloud" : caller.kind == .device ? "antenna.radiowaves.left.and.right" : "terminal",
                 "“\(caller.name)”", DockPanelWords.kind(caller) + (caller.lastSeen.map { " · last seen " + $0.formatted(.relative(presentation: .named)) } ?? ""))
        }
        if draft.engine == .muse {
            note("Messages you send \(bot.name) here go to a chat of their own in your Muse app. When Muse needs something about you, it asks KemoSabe.")
        }
        if case .caller = bot.origin, callers.isEmpty {
            note("It isn’t signed in to KemoSabe now. When it signs in again and you allow it, its activity shows here.")
        }
    }

    @ViewBuilder private var asked: some View {
        let lines = dock.activity(of: bot, limit: 12)
        if lines.isEmpty {
            note("Nothing yet. When \(bot.name) asks KemoSabe something, it shows here, with what was shared.")
        } else {
            ForEach(lines) { entry in
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        Text(entry.title).lineLimit(2)
                        Spacer(minLength: 6)
                        Text(entry.date.formatted(.relative(presentation: .named))).font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    Label(entry.outcome, systemImage: entry.shared ? "arrow.up.right.circle" : "lock")
                        .font(.system(size: 11)).foregroundStyle(entry.shared ? Color.primary : .secondary).lineLimit(2)
                }
                .accessibilityElement(children: .combine)
            }
            note("What was shared is exactly what left this Mac. What stayed is never shown or kept here.")
        }
    }

    @ViewBuilder private var permissions: some View {
        let now = Date()
        let grants = dock.callers(of: bot).flatMap { caller in (dock.gatewayHub?.store.grants(for: caller.id) ?? []).map { (caller, $0) } }
        let consent = bot.engine.chats ? (dock.gate?.consentGrants(for: .bot(bot)) ?? []) : []
        if grants.isEmpty && consent.isEmpty {
            note("Asks you each time. Its questions wait on a card in KemoSabe’s chat.")
        }
        if !consent.isEmpty {
            HStack {
                line(systemImage: "checkmark.shield", "KemoSabe answers it without asking", "Its chat’s questions, at most \(bot.contextScope.ceiling.title).")
                Spacer()
                Button("Ask Again") { dock.gate?.revokeConsent(.bot(bot)) }.controlSize(.small)
            }
        }
        ForEach(grants, id: \.1.id) { caller, grant in
            HStack {
                line(systemImage: grant.tool.symbol, grant.tool.title, grant.summary(now: now) + " · “\(caller.name)”")
                Spacer()
                Button("Remove") { dock.gatewayHub?.store.revokeGrant(grant.id) }.controlSize(.small)
            }
        }
    }

    // MARK: A bot that chats: its settings

    /// The model and effort, under the engine.
    @ViewBuilder private var modelMenus: some View {
        if let choice, !choice.models.isEmpty {
                HStack(spacing: 8) {
                    Menu(draft.model.map(choice.name(of:)) ?? "Engine’s default") {
                        Button("Engine’s default") { draft.model = nil; draft.effort = nil }
                        Divider()
                        ForEach(choice.models, id: \.self) { model in
                            Button(choice.name(of: model)) { draft.effort = choice.accepted(draft.effort, model: model); draft.model = model }
                        }
                    }.fixedSize().accessibilityIdentifier("dockBotModel")
                    let efforts = choice.efforts(for: draft.model)
                    if !efforts.isEmpty {
                        Menu(draft.effort.map { $0.rawValue.capitalized } ?? "Default effort") {
                            Button("Default effort") { draft.effort = nil }
                            ForEach(efforts, id: \.self) { effort in Button(effort.rawValue.capitalized) { draft.effort = effort } }
                        }.fixedSize().accessibilityIdentifier("dockBotEffort")
                    }
                }
            }
    }

    /// Where it works and what it may reach: its project, what it may do there, and what it may ask KemoSabe.
    @ViewBuilder private var access: some View {
        drawer("Access") {
            if draft.engine.runsOnlyOnMac {
                field("Project") {
                    HStack(spacing: 8) {
                        Text(draft.contextScope.project.map { ($0 as NSString).lastPathComponent } ?? "Its own folder").lineLimit(1)
                        Spacer(minLength: 4)
                        if bot.conversation == nil {
                            Button("Choose…") { chooseProject() }.controlSize(.small)
                            if draft.contextScope.project != nil { Button("Clear") { draft.contextScope.project = nil }.controlSize(.small) }
                        }
                    }
                }
            }
            if draft.engine.runsOnlyOnMac {
                field("In its project") {
                    Menu(draft.permissions.access.title) {
                        ForEach(BotPermissions.Access.allCases) { access in
                            Button(access.title + ": " + access.detail) { draft.permissions.access = access }
                        }
                    }.fixedSize().accessibilityIdentifier("dockBotAccess")
                }
                field("Approvals") {
                    Menu(draft.permissions.approvalsHere ? "In the dock" : "Only in the chat") {
                        Button("In the dock") { draft.permissions.approvalsHere = true }
                        Button("Only in the chat") { draft.permissions.approvalsHere = false }
                    }.fixedSize()
                }
            }
            Toggle("Can ask KemoSabe about you", isOn: $draft.contextScope.mayAskKemoSabe)
                .toggleStyle(.checkbox).accessibilityIdentifier("dockBotMayAsk")
            if draft.contextScope.mayAskKemoSabe {
                field("KemoSabe may share up to") {
                    Menu(draft.contextScope.ceiling.title) {
                        ForEach([PrivacyLevel.open, .personal, .sensitive]) { level in
                            Button(level.title + ": " + level.detail) { draft.contextScope.ceiling = level }
                        }
                    }
                    .fixedSize().accessibilityIdentifier("dockBotCeiling")
                }
            }
        }
    }

    /// How it sounds, and whether it speaks up.
    @ViewBuilder private var voiceAndChirps: some View {
        drawer("Voice") {
            VoicePicker(bot: $draft, compact: true)
            Toggle("Speaks its replies when you talk to it", isOn: $draft.permissions.speaks).toggleStyle(.checkbox)
            note(VoicePicker.footer(voice: dock.voice, device: "Mac"))
        }
        if !bot.isBroughtIn {
            drawer("Chirps") {
                Toggle("May chirp in", isOn: $draft.permissions.mayChirp).toggleStyle(.checkbox)
                if draft.permissions.mayChirp {
                    ForEach(DockChirpSource.allCases) { source in
                        Toggle(source.title, isOn: Binding(get: { watch.sources.contains(source) }, set: { on in
                            watch.sources.removeAll { $0 == source }
                            if on { watch.sources.append(source) }
                        })).toggleStyle(.checkbox)
                    }
                    if !watch.sources.isEmpty {
                        field("Only items with") { TextField("Words to watch for (optional)", text: $words).textFieldStyle(.roundedBorder) }
                        field("How far ahead") {
                            Menu(DockChirpWatch.leadChoices.first { $0.1 == watch.leadMinutes }?.0 ?? "2 hours") {
                                ForEach(DockChirpWatch.leadChoices, id: \.1) { choice in Button(choice.0) { watch.leadMinutes = choice.1 } }
                            }.fixedSize()
                        }
                    }
                    note("Chirps are made on this Mac from what’s coming up. They never go to a bot.")
                }
            }
        }
    }

    // MARK: Pieces

    private func toggle(_ title: String) {
        withAnimation(.snappy(duration: 0.2)) { if open.contains(title) { open.remove(title) } else { open.insert(title) } }
    }
    /// A group that opens and closes (2.01's drawers): its title and a chevron, then its content while open.
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
            .buttonStyle(.plain)
            .accessibilityIdentifier("dockDrawer-" + title)
            .accessibilityAddTraits(expanded ? .isSelected : [])
            if expanded { content() }
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func group(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 12, weight: .semibold))
            content()
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func field(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 11.5)).foregroundStyle(.secondary)
            content()
        }
    }
    private func line(systemImage: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).lineLimit(2)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
    private func chooseProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "The folder \(draft.name) works in."
        if panel.runModal() == .OK, let url = panel.url { draft.contextScope.project = url.path }
    }

    private func save() {
        watch.words = words.split(separator: ",").map(String.init)
        // KemoSabe's chirps switch saves as it's flipped (`more`); keep it.
        if draft.isKemoSabe, let live = dock.bot(draft.id) { draft.permissions = live.permissions }
        switch dock.update(draft) {
        case .success(let saved):
            problem = nil
            if !saved.isKemoSabe { dock.store.setChirpWatch(watch, for: saved.id) }
            done()
        case .failure(let failure):
            problem = failure.message
        }
    }
}
#endif
