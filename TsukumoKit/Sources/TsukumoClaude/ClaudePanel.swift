#if os(macOS)
import AppKit
import SwiftUI
import TsukumoCore
import TsukumoEngines
import TsukumoGateway
import TsukumoUI

// The Claude bot's panel: what it runs on, its tasks (New task, each one's status, schedule, transcript, results,
// Stop and Retry), and a chat tab that is TsukumoUI's chat. The dock's Claude tile opens it (`ServiceBotPanelProvider`).

/// The whole panel.
public struct ClaudePanel: View {
    @Bindable var bot: ClaudeBot
    @State private var tab: Tab = .tasks
    @State private var selected: UUID?
    @State private var composing = false
    @Environment(\.colorScheme) private var scheme

    enum Tab: String, CaseIterable, Identifiable { case tasks = "Tasks", chat = "Chat"; var id: String { rawValue } }

    public init(bot: ClaudeBot) { self.bot = bot }
    init(bot: ClaudeBot, tab: Tab, selected: UUID?) { self.bot = bot; _tab = State(initialValue: tab); _selected = State(initialValue: selected) }

    public var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(spacing: 0) {
            header(theme)
            Divider().overlay(theme.hairline)
            if let problem = bot.storeProblem {
                Label(problem, systemImage: "exclamationmark.triangle").font(TsukumoType.font(.caption)).foregroundStyle(.orange)
                    .padding(.horizontal, 18).padding(.vertical, 8).frame(maxWidth: .infinity, alignment: .leading)
            }
            switch tab {
            case .tasks: tasks(theme)
            case .chat: ClaudeChatTab(session: bot.chat)
            }
        }
        .background(theme.background)
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .sheet(isPresented: $composing) {
            NewClaudeTask(bot: bot) { id in selected = id }
        }
        .onAppear { bot.panelOpened(); bot.refreshAvailability() }
    }

    private func header(_ theme: TsukumoTheme) -> some View {
        HStack(spacing: 12) {
            BotAvatar(bot: DemoFixture.claude, size: 34, showsEngine: false)
            VStack(alignment: .leading, spacing: 2) {
                Text("Claude").font(TsukumoType.font(.headline, weight: .semibold))
                Text(bot.engineLine).font(TsukumoType.font(.caption)).foregroundStyle(theme.secondary).lineLimit(2)
                    .accessibilityIdentifier("claudeEngineLine")
            }
            Spacer(minLength: 12)
            Picker("", selection: $tab) { ForEach(Tab.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            ClaudeEngineMenu(bot: bot)
        }
        .padding(.horizontal, 18).padding(.vertical, 12)
    }

    /// Side by side in a window of its own; in the dock's narrower panel, the list, then a task with a way back.
    private func tasks(_ theme: TsukumoTheme) -> some View {
        GeometryReader { space in
            if space.size.width >= Self.sideBySide {
                HStack(spacing: 0) {
                    list(theme).frame(width: 270)
                    Divider().overlay(theme.hairline)
                    if let task = bot.tasks.first(where: { $0.id == selected }) ?? bot.tasks.last {
                        ClaudeTaskDetail(bot: bot, task: task)
                    } else {
                        VStack { Spacer(); Text("No tasks yet.").foregroundStyle(theme.secondary); Spacer() }.frame(maxWidth: .infinity)
                    }
                }
            } else if let task = bot.tasks.first(where: { $0.id == selected }) {
                VStack(alignment: .leading, spacing: 0) {
                    Button { selected = nil } label: { Label("Tasks", systemImage: "chevron.left") }
                        .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 8)
                        .accessibilityIdentifier("claudeBackToTasks")
                    Divider().overlay(theme.hairline)
                    ClaudeTaskDetail(bot: bot, task: task)
                }
            } else {
                list(theme)
            }
        }
    }
    /// The width from which the list and a task show side by side.
    static let sideBySide: CGFloat = 640

    private func list(_ theme: TsukumoTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { composing = true } label: {
                Label("New task", systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless).padding(.horizontal, 14).padding(.vertical, 10)
            .accessibilityIdentifier("claudeNewTask")
            Divider().overlay(theme.hairline)
            if bot.tasks.isEmpty {
                Text("Give Claude a goal and it works on it in the background, on its own Claude. Anything personal, it asks KemoSabe first.")
                    .font(TsukumoType.font(.callout)).foregroundStyle(theme.secondary).padding(14)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(bot.tasks.reversed()) { task in
                            ClaudeTaskRow(task: task, scheduled: bot.isScheduled(task), selected: task.id == selected, calendar: bot.calendar)
                                .contentShape(Rectangle())
                                .onTapGesture { selected = task.id }
                        }
                    }
                    .padding(6)
                }
            }
        }
    }
}

/// What it runs on, and the few choices the owner has.
struct ClaudeEngineMenu: View {
    @Bindable var bot: ClaudeBot
    var body: some View {
        Menu {
            Picker("Runs on", selection: Binding(get: { bot.settings.engine }, set: { value in bot.update { $0.engine = value } })) {
                ForEach(ClaudeEnginePreference.allCases) { Text($0.title).tag($0) }
            }
            if let api = bot.availability.api, !api.models.isEmpty {
                Picker("Model on your API key", selection: Binding(get: { bot.settings.apiModel }, set: { value in bot.update { $0.apiModel = value } })) {
                    ForEach(api.models, id: \.self) { Text($0).tag($0) }
                }
            }
            if let code = bot.availability.claudeCode {
                Picker("Model in Claude Code", selection: Binding(get: { bot.settings.codeModel ?? "" }, set: { value in bot.update { $0.codeModel = value.isEmpty ? nil : value } })) {
                    Text("Claude Code’s default").tag("")
                    ForEach(code.models.filter { $0.id != "default" }) { Text($0.name).tag($0.id) }
                }
            }
            Picker("Tasks at once", selection: Binding(get: { bot.settings.maxConcurrent }, set: { value in bot.update { $0.maxConcurrent = value } })) {
                ForEach(1...3, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("May ask KemoSabe", isOn: Binding(get: { bot.settings.mayAskKemoSabe }, set: { value in bot.update { $0.mayAskKemoSabe = value } }))
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton).fixedSize()
        .help("What Claude runs on")
        .accessibilityIdentifier("claudeEngineMenu")
    }
}

/// A status as a small capsule.
struct ClaudeStatusPill: View {
    let status: ClaudeTaskStatus
    var scheduled = false
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        let color: Color = switch status {
        case .needsYou: theme.accent
        case .running: .blue
        case .done: .green
        case .failed: .red
        case .queued: theme.secondary
        }
        Text(scheduled ? "Scheduled" : status.title)
            .font(TsukumoType.font(.caption2, weight: .semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.14)))
            .foregroundStyle(color)
    }
}

struct ClaudeTaskRow: View {
    let task: ClaudeTask
    let scheduled: Bool
    let selected: Bool
    var calendar: Calendar = .current
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let theme = TsukumoTheme(scheme)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ClaudeStatusPill(status: task.status, scheduled: scheduled)
                if !task.seen { Circle().fill(theme.accent).frame(width: 6, height: 6) }
                Spacer()
            }
            Text(task.title).font(TsukumoType.font(.callout, weight: .medium)).lineLimit(2)
            Text(subtitle).font(TsukumoType.font(.caption)).foregroundStyle(theme.secondary).lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(selected ? theme.fill.opacity(2) : .clear))
    }
    private var subtitle: String {
        var parts = [task.schedule.summary(calendar: calendar)]
        if let next = task.nextRunAt, task.schedule.repeats || task.status == .queued {
            parts.append("next " + ClaudeSchedule.when(next, calendar: calendar))
        }
        return parts.joined(separator: " · ")
    }
}

/// One task: what it is, what's waiting on the owner, its result, and its transcript.
struct ClaudeTaskDetail: View {
    @Bindable var bot: ClaudeBot
    let task: ClaudeTask
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = TsukumoTheme(scheme)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(task.title).font(TsukumoType.font(.title3, weight: .semibold)).textSelection(.enabled)
                    Spacer()
                    controls
                }
                HStack(spacing: 8) {
                    ClaudeStatusPill(status: task.status, scheduled: bot.isScheduled(task))
                    Text(facts).font(TsukumoType.font(.caption)).foregroundStyle(theme.secondary)
                }
                if bot.stillStopping.contains(task.id) {
                    Label("Claude is still stopping.", systemImage: "hourglass").font(TsukumoType.font(.callout)).foregroundStyle(.orange)
                }
                if !task.instructions.isEmpty {
                    Text(task.instructions).font(TsukumoType.font(.callout)).foregroundStyle(theme.secondary).textSelection(.enabled)
                }
                if let approval = bot.approvals[task.id] { approvalCard(approval, theme) }
                if let card = bot.cards[task.id] { kemoSabeCard(card, theme) }
                if let run = task.lastRun { results(run, theme); transcript(run, theme) }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var facts: String {
        var parts = [task.schedule.summary(calendar: bot.calendar), task.access.title]
        if let project = task.project { parts.append((project as NSString).lastPathComponent) }
        if let run = task.lastRun { parts.append(run.engine) }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 8) {
            if task.status == .running || task.status == .needsYou {
                Button("Stop") { bot.stop(task.id) }.accessibilityIdentifier("claudeStop")
            } else {
                Button(task.runs.isEmpty ? "Run now" : "Retry") { bot.retry(task.id) }.accessibilityIdentifier("claudeRetry")
            }
            Menu {
                Button("Delete Task", role: .destructive) { bot.delete(task.id) }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
        }
    }

    private func approvalCard(_ request: ApprovalRequest, _ theme: TsukumoTheme) -> some View {
        card(theme) {
            Label("Claude asks to", systemImage: "hand.raised").font(TsukumoType.font(.caption, weight: .semibold))
            Text(request.summary).font(TsukumoType.font(.body, weight: .semibold)).textSelection(.enabled)
            HStack {
                Button("Allow") { bot.decide(task.id, allow: true) }.buttonStyle(.borderedProminent)
                Button("Don’t allow") { bot.decide(task.id, allow: false) }
            }
        }
    }

    private func kemoSabeCard(_ request: GatewayApprovalRequest, _ theme: TsukumoTheme) -> some View {
        card(theme) {
            Label(request.title, systemImage: "lock.shield").font(TsukumoType.font(.caption, weight: .semibold))
            Text(request.text).font(TsukumoType.font(.callout))
            if let preview = request.preview { Text(preview).font(TsukumoType.font(.callout, weight: .semibold)) }
            HStack {
                Button("Allow once") { bot.answer(request, .once) }.buttonStyle(.borderedProminent)
                if request.standing != nil { Button("Allow for 7 days") { bot.answer(request, .standing) } }
                Button("Don’t allow") { bot.answer(request, .deny) }
            }
            Text("The same card is in KemoSabe’s chat.").font(TsukumoType.font(.caption)).foregroundStyle(theme.secondary)
        }
    }

    private func card<Content: View>(_ theme: TsukumoTheme, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(theme.accent.opacity(0.07)))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(theme.accent.opacity(0.2)))
    }

    @ViewBuilder private func results(_ run: ClaudeRun, _ theme: TsukumoTheme) -> some View {
        if let result = run.result, !result.isEmpty {
            section("Result", theme) {
                Text(result).font(TsukumoType.font(.body)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
        } else if let failure = run.failure {
            section(run.outcome == .stopped ? "Stopped" : "Didn’t finish", theme) {
                Text(failure).font(TsukumoType.font(.callout)).foregroundStyle(theme.secondary).textSelection(.enabled)
            }
        }
        if run.memoryHeld {
            section("Memory", theme) {
                Text("This result used something KemoSabe shared, so later tasks won’t see it.").font(TsukumoType.font(.callout)).foregroundStyle(theme.secondary)
                Button("Keep for Later Tasks") { Task { await bot.keepAsMemory(task.id) } }
            }
        }
        if !run.files.isEmpty {
            section("In your Inbox", theme) {
                ForEach(run.files) { file in
                    HStack {
                        Image(systemName: "doc")
                        Text(file.name)
                        Text(ByteCountFormatter.string(fromByteCount: Int64(file.bytes), countStyle: .file)).foregroundStyle(theme.secondary)
                        Spacer()
                        Button("Show in Finder") { bot.reveal(file) }.buttonStyle(.borderless)
                    }
                    .font(TsukumoType.font(.callout))
                }
            }
        }
    }

    private func transcript(_ run: ClaudeRun, _ theme: TsukumoTheme) -> some View {
        section("Transcript" + (run.resumedAfterQuit ? " · resumed after Tsukumo quit" : ""), theme) {
            ForEach(run.transcript) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: Self.icon(entry.kind)).frame(width: 16).foregroundStyle(entry.kind == .kemoSabe ? theme.accent : theme.secondary)
                    Text(entry.text).font(TsukumoType.font(entry.kind == .claude ? .body : .callout))
                        .foregroundStyle(entry.kind == .claude || entry.kind == .goal ? theme.ink : theme.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    static func icon(_ kind: ClaudeTranscriptEntry.Kind) -> String {
        switch kind {
        case .goal: "target"
        case .claude: "sparkle"
        case .tool: "wrench.and.screwdriver"
        case .kemoSabe: "lock.shield"
        case .approval: "hand.raised"
        case .note: "info.circle"
        case .error: "exclamationmark.triangle"
        }
    }

    private func section<Content: View>(_ title: String, _ theme: TsukumoTheme, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(TsukumoType.font(.caption, weight: .semibold)).foregroundStyle(theme.secondary)
            content()
        }
    }
}

/// A new task: the goal, optional instructions, when, where, and what Claude may do there.
struct NewClaudeTask: View {
    let bot: ClaudeBot
    let onAdd: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var goal = ""
    @State private var instructions = ""
    @State private var when: When = .now
    @State private var at = Date().addingTimeInterval(3_600)
    @State private var hours = 6
    @State private var project: String?
    @State private var access: BotPermissions.Access = .readOnly
    @State private var inputs: [URL] = []
    @State private var allowedSecrets = ""

    enum When: String, CaseIterable, Identifiable {
        case now = "Now", once = "Once, later", daily = "Every day", hourly = "Every few hours"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New task for Claude").font(TsukumoType.font(.title3, weight: .semibold))
            VStack(alignment: .leading, spacing: 6) {
                Text("Goal").font(TsukumoType.font(.caption, weight: .semibold))
                TextField("What should Claude get done?", text: $goal, axis: .vertical).lineLimit(2...5)
                    .accessibilityIdentifier("claudeGoal")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Instructions (optional)").font(TsukumoType.font(.caption, weight: .semibold))
                TextField("How you’d like it done", text: $instructions, axis: .vertical).lineLimit(2...6)
            }
            Picker("When", selection: $when) { ForEach(When.allCases) { Text($0.rawValue).tag($0) } }
            switch when {
            case .now: EmptyView()
            case .once: DatePicker("At", selection: $at, in: Date()...)
            case .daily: DatePicker("At", selection: $at, displayedComponents: .hourAndMinute)
            case .hourly: Stepper("Every \(hours) hours", value: $hours, in: 1...168)
            }
            HStack {
                Text("Works in")
                Text(project.map { ($0 as NSString).lastPathComponent } ?? "Its own folder").foregroundStyle(.secondary)
                Spacer()
                if project != nil { Button("Use Its Own Folder") { project = nil } }
                Button("Choose a Project…") { pick() }
            }
            if project != nil {
                Text("Claude can read every file in this folder, including any personal files in it (documents, photos, notes), and what it reads goes to Anthropic. Only files named like secrets (.env files, keys, keychains, SSH and cloud credentials) are refused. Pick a folder that holds only what this task needs.")
                    .font(TsukumoType.font(.caption)).foregroundStyle(.orange)
                TextField("Secret files to give Claude as copies, by path in the folder (optional)", text: $allowedSecrets)
            } else {
                HStack {
                    Text(inputs.isEmpty ? "No files given" : inputs.map(\.lastPathComponent).joined(separator: ", ")).foregroundStyle(.secondary).lineLimit(1)
                    Spacer()
                    Button("Give It Files…") { pickFiles() }
                }
                Text("Claude reads only its own folder and the files you give it here.").font(TsukumoType.font(.caption)).foregroundStyle(.secondary)
            }
            Picker("Claude may", selection: $access) {
                ForEach([BotPermissions.Access.readOnly, .askFirst, .autoEdit]) { Text($0.title).tag($0) }
            }
            Text(access.detail).font(TsukumoType.font(.caption)).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add Task") {
                    let secrets = allowedSecrets.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if let task = bot.add(goal: goal, instructions: instructions, schedule: schedule, project: project, access: access,
                                          allowedSecrets: secrets, inputs: inputs) { onAdd(task.id) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 480)
    }

    private var schedule: ClaudeSchedule {
        let parts = Calendar.current.dateComponents([.hour, .minute], from: at)
        switch when {
        case .now: return .now
        case .once: return .once(at: at)
        case .daily: return .daily(hour: parts.hour ?? 9, minute: parts.minute ?? 0)
        case .hourly: return .every(hours: hours)
        }
    }

    private func pick() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { project = url.path }
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Give to Claude"
        if panel.runModal() == .OK { inputs = panel.urls }
    }
}

/// The chat tab: TsukumoUI's chat with Claude.
struct ClaudeChatTab: View {
    let session: ChatSession
    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    ChatTranscriptContent(session: session, showsStage: false)
                    Color.clear.frame(height: 1).id("claudeChatBottom")
                }
                .onChange(of: session.thread.messages.count) { proxy.scrollTo("claudeChatBottom", anchor: .bottom) }
            }
            ChatComposer(session: session).padding(.horizontal, 16).padding(.bottom, 8)
        }
    }
}

public extension ClaudeBot {
    /// Shows a result file in the Inbox in Finder (never opens it).
    func reveal(_ file: ClaudeResultFile) {
        guard let inbox = kemoSabe?.gateway.inbox, let item = inbox.items.first(where: { $0.id == file.id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([inbox.url(item)])
    }
}

#endif
