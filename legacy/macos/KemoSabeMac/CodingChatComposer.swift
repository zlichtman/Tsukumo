import SwiftUI
import AppKit
import UniformTypeIdentifiers
import Observation

// MARK: Drafts

/// What's typed in a composer, kept per task (and for the new-task page) while you switch around.
struct CodingComposerDraft: Equatable {
    var text = ""
    var images: [URL] = []
}
@MainActor @Observable final class CodingComposerDrafts {
    static let shared = CodingComposerDrafts()
    var drafts: [String: CodingComposerDraft] = [:]
    static func key(_ task: UUID?) -> String { task?.uuidString ?? "new" }
}
/// Settings for a task that hasn't started yet. The last ones used are remembered and start the
/// next new chat (Full access never carries over: a new chat starts at Ask first).
struct CodingNewTaskSettings: Equatable, Codable {
    var provider: CodingProvider = .codex
    var model = ""
    var effort: String?
    var access: CodingAccess = .edit
    var isolated = true
    static let key = "tsukumo.newTask.defaults"
    static func remembered(_ defaults: UserDefaults = .standard) -> Self {
        guard let data = defaults.data(forKey: key), var saved = try? JSONDecoder().decode(Self.self, from: data) else { return .init() }
        if saved.access == .full { saved.access = .edit }
        return saved
    }
    func remember(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// Images pasted or dropped into a composer are copied into the account's Coding folder, so the
/// agent reads a stable file and the message can show it later.
enum CodingAttachments {
    static let imageTypes: [UTType] = [.png, .jpeg, .gif, .webP, .tiff, .heic, .bmp]
    static func isImage(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .image)
    }
    static func store(data: Data, ext: String, in folder: URL) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let url = folder.appendingPathComponent(UUID().uuidString + "." + ext)
        try data.write(to: url, options: .atomic)
        return url
    }
    /// Pasteboard or file images as PNG (JPEG and GIF files are kept as they are).
    static func store(image url: URL, in folder: URL) throws -> URL {
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) { return try store(data: Data(contentsOf: url), ext: ext == "jpeg" ? "jpg" : ext, in: folder) }
        guard let image = NSImage(contentsOf: url), let png = png(image) else { throw CodingFailure("This image couldn't be read.") }
        return try store(data: png, ext: "png", in: folder)
    }
    static func png(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: Composer

/// The message box under a task (or on the new-task page): the text with `@` file mentions and
/// `/` commands, attached images, the agent, model and effort, access, and send, queue, steer,
/// or stop. Return sends; Shift-Return adds a line; ⌘Return steers a running Codex turn (or
/// interrupts and sends for Claude Code); Esc stops the running turn.
struct CodingComposer: View {
    let task: CodingTaskRecord?
    @Binding var settings: CodingNewTaskSettings
    /// Starts a new task (with the chosen agents side by side for Run with…).
    var start: (_ text: String, _ images: [URL], _ compare: [CodingProvider]?) -> Void
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopProjects.self) private var projects
    @State private var drafts = CodingComposerDrafts.shared
    @State private var catalog = CodingAgentCatalog.shared
    @State private var registry = CodingAgentRegistry.shared
    @State private var showAgents = false
    @State private var showRunWith = false
    @Environment(DesktopNavigation.self) private var desktop
    @State private var files: [String] = []
    @State private var highlighted = 0
    @State private var height: CGFloat = 22
    /// The power-up popover (effort slider and model list), and the page it opens on.
    @State private var showEffort = false
    @State private var effortPage: CodingEffortPopover.Page = .effort
    @State private var showAccess = false
    @State private var notice = ""
    private var key: String { CodingComposerDrafts.key(task?.id) }
    private var draft: CodingComposerDraft { drafts.drafts[key] ?? .init() }
    private var provider: CodingProvider { task?.provider ?? settings.provider }
    private var model: String { task?.model ?? settings.model }
    private var effort: String? { task?.effort ?? settings.effort }
    private var access: CodingAccess { task?.access ?? settings.access }
    private var running: Bool { task?.status.running == true }
    private var capabilities: CodingAgentCapabilities { .of(provider) }
    /// The selected project's folder, resolved once per selection (for mentions on the new-task page).
    @State private var projectFolder: URL?
    private var directory: URL? { task.map { URL(fileURLWithPath: $0.directory) } ?? projectFolder }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let queued = task?.queued, !queued.isEmpty, let task { queue(queued, task: task) }
            ZStack(alignment: .bottomLeading) {
                box
                if !suggestions.isEmpty { suggestionList.offset(y: -(height + 62)).zIndex(2) }
            }
            if !notice.isEmpty { Text(notice).font(.system(size: 11)).foregroundStyle(.orange).padding(.leading, 6) }
            else if running { Text(runningHint).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.leading, 6) }
        }
        .task(id: directory?.path) {
            guard let directory else { files = []; return }
            files = await CodingMentionSearch.files(in: directory)
        }
        .task(id: provider) { catalog.load(provider) }
        .task(id: projects.selected) { projectFolder = projects.selected.flatMap { try? projects.resolve($0) } }
        .onChange(of: draft.text) { highlighted = 0; notice = "" }
    }
    private var runningHint: String {
        capabilities.steer ? "Return queues your message for after this turn · ⌘Return adds it to this turn · Esc stops the turn"
                           : "Return queues your message for after this turn · ⌘Return stops the turn and sends it · Esc stops the turn"
    }
    // MARK: The box
    private var box: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !draft.images.isEmpty { attachments }
            CodingComposerTextView(
                text: Binding(get: { draft.text }, set: { drafts.drafts[key, default: .init()].text = $0 }),
                height: $height,
                placeholder: placeholder,
                focusToken: CodingChatCommands.shared.focusToken,
                handler: .init(
                    submit: { command in submit(command: command) },
                    escape: { escape() },
                    move: { delta in
                        guard !suggestions.isEmpty else { return false }
                        highlighted = (highlighted + delta + suggestions.count) % suggestions.count; return true
                    },
                    complete: { acceptSuggestion() },
                    paste: { pasteboard in attach(from: pasteboard) },
                    drop: { urls in attach(urls) }
                ))
                .frame(height: min(max(height, 22), 220))
                .padding(.horizontal, 6).padding(.top, 4)
            controls
        }
        // KemoSabe's grouped composer: one 26 pt panel on the sidebar tone, a hairline, round controls.
        .padding(10)
        .background(palette.sidebar, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(access == .full ? Color.orange.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: 0.75))
    }
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    private var palette: DesktopPalette { preferences.palette(scheme) }
    private var placeholder: String {
        if task == nil { return "Ask \(provider.title) to build, fix, or explain something… @ for files, / for commands" }
        if task?.status == .done { return "Task complete" }
        return running ? "Message \(provider.title) while it works…" : "Ask for a change or reply… @ for files, / for commands"
    }
    private var attachments: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(draft.images, id: \.self) { url in
                    ZStack(alignment: .topTrailing) {
                        if let image = NSImage(contentsOf: url) {
                            Image(nsImage: image).resizable().scaledToFill().frame(width: 56, height: 56).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        Button { drafts.drafts[key]?.images.removeAll { $0 == url } } label: {
                            Image(systemName: "xmark.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .black.opacity(0.6))
                        }.buttonStyle(.plain).offset(x: 5, y: -5).accessibilityLabel("Remove image")
                    }
                }
            }.padding(.top, 4).padding(.trailing, 6)
        }
    }
    /// The grouped controls: + attach, then compact pickers (project, agent, place on a new chat;
    /// model · effort and access always), and send, which becomes stop while the agent works.
    private var controls: some View {
        HStack(spacing: 6) {
            Button { chooseFiles() } label: { circle("plus") }
                .buttonStyle(PressableButtonStyle()).help(capabilities.images ? "Attach images or files" : "Attach files")
                .accessibilityLabel("Attach")
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    if task == nil {
                        projectMenu
                        agentChip
                    }
                    modelMenu
                    accessMenu
                    if task == nil { placeMenu }
                }.padding(.vertical, 2).padding(.horizontal, 6)
            }
            // Clipped, with soft edges: chips that don't fit scroll inside this strip and never
            // slide under the + or the buttons on the right. The fades sit in the padding, so a
            // row that fits is drawn in full.
            .mask(HStack(spacing: 0) {
                LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing).frame(width: 6)
                Rectangle()
                LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing).frame(width: 6)
            })
            .padding(.horizontal, -6)
            Spacer(minLength: 4)
            if task == nil {
                Button { showRunWith.toggle() } label: { Text("Run with…").font(.system(size: 12, weight: .medium)).padding(.horizontal, 10).frame(height: 30).background(Color.primary.opacity(0.07), in: Capsule()) }
                    .buttonStyle(PressableButtonStyle()).disabled(!canStart).opacity(canStart ? 1 : 0.5)
                    .help("Run with…: send this to two or three agents, each in its own worktree, and compare what each changes")
                    .accessibilityLabel("Run with several agents")
                    .popover(isPresented: $showRunWith, arrowEdge: .top) {
                        CodingRunWithPicker(rows: registry.rows(), chosen: Array(registry.choices(including: []).prefix(2))) { agents in
                            showRunWith = false; submitNew(compare: agents)
                        }
                    }
            }
            if running {
                // While it works: queue what you've typed, and stop.
                if !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button { submit(command: false) } label: { circle("text.append") }
                        .buttonStyle(PressableButtonStyle()).help("Queue for after this turn (Return)").accessibilityLabel("Queue message")
                }
                Button { if let task { coding.interrupt(task.id) } } label: {
                    Image(systemName: "stop.fill").font(.system(size: 12, weight: .bold)).frame(width: 32, height: 32)
                        .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : Color.white)
                        .background(palette.accent, in: Circle())
                }.buttonStyle(PressableButtonStyle()).help("Stop this turn (Esc)").accessibilityLabel("Stop").accessibilityIdentifier("codingStop")
            } else {
                Button { submit(command: false) } label: {
                    Image(systemName: "arrow.up").font(.system(size: 14, weight: .semibold)).frame(width: 32, height: 32)
                        .foregroundStyle(scheme == .dark ? Color.black.opacity(0.85) : Color.white)
                        .background(palette.accent.opacity(canSend ? 1 : 0.45), in: Circle())
                }.buttonStyle(PressableButtonStyle()).disabled(!canSend).help("Send (Return)").accessibilityLabel("Send").accessibilityIdentifier("codingSend")
            }
        }.font(.system(size: 12))
    }
    private func circle(_ symbol: String) -> some View {
        Image(systemName: symbol).font(.system(size: 14, weight: .medium)).frame(width: 32, height: 32)
            .foregroundStyle(Color.primary.opacity(0.82))
            .background(Color.primary.opacity(0.07), in: Circle())
            .overlay(Circle().stroke(Color.primary.opacity(0.1), lineWidth: 0.5)).contentShape(Circle())
    }
    private func chip(_ title: String, symbol: String? = nil, warning: Bool = false, symbolTint: Color? = nil) -> some View {
        HStack(spacing: 5) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).foregroundStyle(symbolTint ?? (warning ? Color.orange : Color.primary.opacity(0.85))) }
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(warning ? Color.orange : Color.primary.opacity(0.85))
        .padding(.horizontal, 10).frame(height: 30)
        .background((warning ? Color.orange : Color.primary).opacity(0.07), in: Capsule())
        .overlay(Capsule().stroke((warning ? Color.orange : Color.primary).opacity(0.12), lineWidth: 0.5))
        .contentShape(Capsule())
    }
    /// The project a new chat works in; its tasks' folder is fixed.
    private var projectMenu: some View {
        let current = projects.projects.first { $0.id == projects.selected }
        return Menu {
            ForEach(projects.projects) { project in
                Button { projects.selected = project.id } label: { checked(project.name, project.id == projects.selected) }
            }
            if !projects.projects.isEmpty { Divider() }
            Button("Open project…") { projects.choose() }
        } label: { chip(current?.name ?? "Choose project", symbol: "folder", warning: current == nil) }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Project").accessibilityLabel("Project, " + (current?.name ?? "none"))
    }
    /// Its own worktree (the default) or the project folder itself: two choices, so a selector
    /// bar shows both at once.
    private var placeMenu: some View {
        CodingSelectorBar(options: [
            .init(value: true, title: "Worktree", symbol: "arrow.triangle.branch", help: "Works in its own worktree from the project's committed HEAD; your uncommitted edits stay put."),
            .init(value: false, title: "Local", symbol: "folder", help: "Works directly in the project folder; its edits change your checkout.")
        ], selection: settings.isolated, accent: palette.accent, compact: true) { settings.isolated = $0 }
        .fixedSize()
        .accessibilityElement(children: .contain).accessibilityLabel("Where it works")
    }
    @ViewBuilder private func checked(_ title: String, _ on: Bool) -> some View {
        if on { Label(title, systemImage: "checkmark") } else { Text(title) }
    }
    private var modelTitle: String {
        let name = catalog.modelsFor(provider).first(where: { $0.id == model })?.name ?? (model.isEmpty ? "Default model" : model)
        return name + (effort.map { " · " + CodingEffortScale.title($0) } ?? "")
    }
    /// The model chip opens the power-up popover: effort on a slider, the model a tap away.
    private var modelMenu: some View {
        let models = catalog.modelsFor(provider)
        let scale = CodingEffortScale(efforts: CodingAgentCatalog.efforts(in: models, model: model), defaultEffort: CodingAgentCatalog.defaultEffort(in: models, model: model))
        let tint = CodingEffortHeat.title(accent: palette.accent, heat: scale.heat(at: scale.step(for: effort)), dark: scheme == .dark)
        return Button { effortPage = .effort; showEffort.toggle() } label: { chip(modelTitle, symbol: "bolt.fill", symbolTint: tint) }
            .buttonStyle(.plain).fixedSize()
            .help("Model and reasoning effort, as \(provider.title) reports them")
            .accessibilityLabel("Model and effort, " + modelTitle)
            .popover(isPresented: $showEffort, arrowEdge: .top) {
                CodingEffortPopover(provider: provider, models: models, loading: catalog.loading.contains(provider), problem: catalog.problems[provider],
                                    running: running, accent: palette.accent, model: model, effort: effort, page: effortPage,
                                    refresh: { catalog.load(provider, force: true) },
                                    commit: { setModel($0, effort: $1) }, close: { showEffort = false })
            }
    }
    /// The access chip opens a selector bar of the four modes; Full access asks first there.
    private var accessMenu: some View {
        Button { showAccess.toggle() } label: { chip(access.title, symbol: access.symbol, warning: access == .full) }
            .buttonStyle(.plain).fixedSize()
            .help(access.detail).accessibilityLabel("Access, " + access.title)
            .popover(isPresented: $showAccess, arrowEdge: .top) {
                CodingAccessPopover(provider: provider, current: access, accent: palette.accent, apply: { apply(access: $0) }, close: { showAccess = false })
            }
    }
    private func queue(_ queued: [CodingQueuedMessage], task: CodingTaskRecord) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(queued) { message in
                HStack(spacing: 6) {
                    Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(.secondary)
                    Text(message.text).lineLimit(1).font(.system(size: 12))
                    if !message.images.isEmpty { Image(systemName: "photo").font(.system(size: 10)).foregroundStyle(.secondary) }
                    Spacer()
                    if running, capabilities.steer {
                        Button("Send now") { coding.removeQueued(task.id, message.id); if !coding.steer(task.id, .init(text: message.text, images: message.images.map { URL(fileURLWithPath: $0) })) { coding.enqueue(task.id, .init(text: message.text)) } }
                            .buttonStyle(DesktopRowButtonStyle(inset: 4)).font(.system(size: 11))
                    }
                    Button { coding.removeQueued(task.id, message.id) } label: { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                        .buttonStyle(DesktopRowButtonStyle(inset: 4)).accessibilityLabel("Remove queued message")
                }.padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            Text("Queued: sent when the agent finishes this turn.").font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.leading, 4)
        }
    }
    // MARK: Suggestions (@ files and / commands)
    private enum Suggestion: Hashable { case file(String), command(String, String) }
    private var suggestions: [Suggestion] {
        let text = draft.text
        if text.hasPrefix("/"), !text.contains(" ") {
            return CodingSlashCommand.suggestions(text, agentCommands: catalog.commands[provider] ?? []).map { .command($0.name, $0.detail) }
        }
        if let query = CodingMentionSearch.activeQuery(text) {
            return CodingMentionSearch.rank(query, in: files, limit: 8).map { .file($0) }
        }
        return []
    }
    private var suggestionList: some View {
        VStack(alignment: .leading, spacing: 1) {
            ForEach(Array(suggestions.enumerated()), id: \.element) { index, suggestion in
                Button { highlighted = index; _ = acceptSuggestion() } label: {
                    HStack(spacing: 8) {
                        switch suggestion {
                        case .file(let path):
                            Image(systemName: "doc").foregroundStyle(.secondary).frame(width: 14)
                            Text(URL(fileURLWithPath: path).lastPathComponent).fontWeight(.medium)
                            Text(path).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                        case .command(let name, let detail):
                            Text("/" + name).fontWeight(.medium).font(.system(size: 12, design: .monospaced))
                            Text(detail).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }.font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 5).contentShape(Rectangle())
                }.buttonStyle(DesktopRowButtonStyle(selected: index == highlighted))
            }
        }
        .padding(5).frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 10, y: 3)
        .fixedSize(horizontal: false, vertical: true)
        .alignmentGuide(.bottom) { $0[.bottom] }
    }
    /// Return or Tab with the list open takes the highlighted choice.
    private func acceptSuggestion() -> Bool {
        let list = suggestions
        guard list.indices.contains(highlighted) else { return false }
        switch list[highlighted] {
        case .file(let path): drafts.drafts[key, default: .init()].text = CodingMentionSearch.complete(draft.text, with: path)
        case .command(let name, _): drafts.drafts[key, default: .init()].text = "/" + name + " "
        }
        highlighted = 0
        return true
    }
    // MARK: Sending
    private var canStart: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && projects.selected != nil && coding.signedIn && !coding.storageFailed
    }
    private var canSend: Bool {
        guard !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let task else { return canStart }
        return task.status != .done && !coding.busy.contains(task.id) && !coding.storageFailed
    }
    /// Return (or ⌘Return when `command`). Slash commands run first; then a new task starts, an
    /// idle task gets the message, and a busy one queues it, steers, or interrupts and sends.
    private func submit(command: Bool) {
        if !suggestions.isEmpty, acceptSuggestion() { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if let slash = CodingSlashCommand.parse(text, agentCommands: catalog.commands[provider] ?? []) {
            if run(slash) { clear() }
            return
        }
        guard canSend else { return }
        guard let task else { submitNew(); return }
        let input = CodingTurnInput(text: text, images: draft.images)
        if !running { coding.send(task.id, input: input) }
        else if command {
            if capabilities.steer, coding.steer(task.id, input) {} else { coding.interruptAndSend(task.id, input) }
        } else { coding.enqueue(task.id, input) }
        clear()
    }
    private func submitNew(compare: [CodingProvider]? = nil) {
        guard canStart else { return }
        let text = draft.text.trimmingCharacters(in: .whitespacesAndNewlines)
        CodingTaskNotifications.shared.requestPermissionIfNeeded()
        start(text, draft.images, compare); clear()
    }
    /// The agent chip: the agent's mark and name, opening the chooser (every agent, whether it's
    /// installed, and whether you're signed in).
    private var agentChip: some View {
        let row = registry.rows().first { $0.provider == provider }
        return Button { showAgents.toggle() } label: {
            HStack(spacing: 6) {
                if let row { CodingAgentBadge(mark: row.mark, size: 16) }
                Text(provider.title).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.primary.opacity(0.85))
            .padding(.horizontal, 10).frame(height: 30)
            .background(Color.primary.opacity(0.07), in: Capsule())
            .overlay(Capsule().stroke(Color.primary.opacity(0.12), lineWidth: 0.5)).contentShape(Capsule())
        }
        .buttonStyle(.plain).fixedSize()
        .help("Agent").accessibilityLabel("Agent, " + provider.title)
        .popover(isPresented: $showAgents, arrowEdge: .top) {
            CodingAgentChooser(rows: registry.rows(), selection: provider,
                               choose: { choice in settings.provider = choice; settings.model = ""; settings.effort = nil; settings.access = registry.clamp(settings.access, for: choice); showAgents = false },
                               addAgent: { showAgents = false; desktop.settingsPage = "Agents" })
        }
    }
    private func clear() { drafts.drafts[key] = .init() }
    /// Carries out a slash command; false leaves the text for editing.
    private func run(_ command: CodingSlashCommand) -> Bool {
        switch command.action {
        case .newTask: coding.select(nil); CodingChatCommands.shared.focusComposer(); return true
        case .model(let name):
            if name.isEmpty { effortPage = .models; showEffort = true; return true }
            let match = catalog.modelsFor(provider).first { $0.id.caseInsensitiveCompare(name) == .orderedSame || $0.name.caseInsensitiveCompare(name) == .orderedSame }
            setModel(match?.id ?? name, effort: effort); return true
        case .effort(let level):
            let allowed = catalog.efforts(provider, model: model)
            guard level.isEmpty || allowed.isEmpty || allowed.contains(level) else { notice = "Effort levels for this model: " + allowed.joined(separator: ", "); return false }
            setModel(model, effort: level.isEmpty ? nil : level); return true
        case .compact, .review, .clear:
            guard let task else { notice = "Start the task first; this command works on a running conversation."; return false }
            guard !task.status.running else { notice = "Wait for this turn to finish, or stop it first."; return false }
            if command.action == .compact { coding.compact(task.id) } else if command.action == .review { coding.review(task.id) } else { coding.clearSession(task.id) }
            return true
        case .agent(let text):
            guard let task else { submitNew(); return false }
            let input = CodingTurnInput(text: text)
            if running { coding.enqueue(task.id, input) } else { coding.send(task.id, input: input) }
            return true
        }
    }
    private func escape() -> Bool {
        if !suggestions.isEmpty { drafts.drafts[key, default: .init()].text += " "; return true }
        // A pending request is answered in its popup, never by stopping the turn underneath it.
        if running, let task, coding.approvals[task.id] == nil { coding.interrupt(task.id); return true }
        return false
    }
    private func setModel(_ model: String, effort: String?) {
        if let task { coding.setModel(task.id, model: model, effort: effort) } else { settings.model = model; settings.effort = effort }
    }
    private func apply(access choice: CodingAccess) {
        if let task { coding.setAccess(task.id, choice) } else { settings.access = choice }
    }
    // MARK: Attachments
    private var attachmentFolder: URL? { coding.storage?.directory.appendingPathComponent("Attachments", isDirectory: true) }
    private func chooseFiles() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.prompt = "Attach"; panel.message = "Images are sent to the agent with your message. Other files are mentioned by path for the agent to read."
        panel.begin { result in
            guard result == .OK else { return }
            Task { @MainActor in _ = attach(panel.urls) }
        }
    }
    /// Images become attachments; other files are mentioned by path (relative inside the project).
    private func attach(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        var mentions: [String] = []
        for url in urls {
            if CodingAttachments.isImage(url), capabilities.images, let folder = attachmentFolder {
                do { drafts.drafts[key, default: .init()].images.append(try CodingAttachments.store(image: url, in: folder)) }
                catch { notice = error.localizedDescription }
            } else if let directory, url.path.hasPrefix(directory.path + "/") {
                mentions.append("@" + String(url.path.dropFirst(directory.path.count + 1)))
            } else { mentions.append("@" + url.path) }
        }
        if !mentions.isEmpty {
            var text = draft.text
            if !text.isEmpty && !text.hasSuffix(" ") && !text.hasSuffix("\n") { text += " " }
            drafts.drafts[key, default: .init()].text = text + mentions.joined(separator: " ") + " "
        }
        return true
    }
    /// Pasted image data (a screenshot) or copied image files; plain text pastes normally.
    private func attach(from pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty, urls.contains(where: CodingAttachments.isImage) {
            return attach(urls)
        }
        guard capabilities.images, let folder = attachmentFolder, pasteboard.string(forType: .string) == nil,
              let image = NSImage(pasteboard: pasteboard), let png = CodingAttachments.png(image) else { return false }
        do { drafts.drafts[key, default: .init()].images.append(try CodingAttachments.store(data: png, ext: "png", in: folder)) }
        catch { notice = error.localizedDescription }
        return true
    }
}

// MARK: Text view

/// A plain-text editor with the composer's keys: Return sends, Shift- or Option-Return adds a
/// line, ⌘Return sends as a command, ↑/↓ and Tab work the suggestion list, Esc stops, and pasted
/// or dropped images become attachments.
struct CodingComposerTextView: NSViewRepresentable {
    struct Handler {
        var submit: (_ command: Bool) -> Void
        var escape: () -> Bool
        var move: (_ delta: Int) -> Bool
        var complete: () -> Bool
        var paste: (NSPasteboard) -> Bool
        var drop: ([URL]) -> Bool
    }
    @Binding var text: String
    @Binding var height: CGFloat
    var placeholder: String
    var focusToken: UUID
    var handler: Handler
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        let view = ComposerTextView()
        view.coordinator = context.coordinator
        view.isRichText = false; view.importsGraphics = false; view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false; view.isAutomaticTextReplacementEnabled = false
        view.font = .systemFont(ofSize: 13); view.drawsBackground = false; view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 2; view.textContainer?.widthTracksTextView = true
        view.isVerticallyResizable = true; view.autoresizingMask = [.width]
        view.delegate = context.coordinator; view.placeholder = placeholder
        view.registerForDraggedTypes([.fileURL, .png, .tiff])
        view.setAccessibilityLabel("Message")
        scroll.documentView = view; scroll.drawsBackground = false; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let view = scroll.documentView as? ComposerTextView else { return }
        context.coordinator.parent = self
        if view.string != text { view.string = text; view.setSelectedRange(NSRange(location: (text as NSString).length, length: 0)); context.coordinator.measure(view) }
        if view.placeholder != placeholder { view.placeholder = placeholder; view.needsDisplay = true }
        if context.coordinator.focusToken != focusToken {
            context.coordinator.focusToken = focusToken
            DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodingComposerTextView
        var focusToken: UUID
        init(_ parent: CodingComposerTextView) { self.parent = parent; focusToken = parent.focusToken }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string; measure(view)
        }
        func measure(_ view: NSTextView) {
            guard let manager = view.layoutManager, let container = view.textContainer else { return }
            manager.ensureLayout(for: container)
            let next = ceil(manager.usedRect(for: container).height) + 2
            if abs(next - parent.height) > 0.5 { DispatchQueue.main.async { self.parent.height = next } }
        }
        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            let flags = NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) ?? []
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                if flags.contains(.shift) { textView.insertNewlineIgnoringFieldEditor(nil); return true }
                parent.handler.submit(flags.contains(.command)); return true
            case #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)): return false
            case #selector(NSResponder.cancelOperation(_:)): return parent.handler.escape()
            case #selector(NSResponder.moveUp(_:)): return parent.handler.move(-1)
            case #selector(NSResponder.moveDown(_:)): return parent.handler.move(1)
            case #selector(NSResponder.insertTab(_:)): return parent.handler.complete()
            default: return false
            }
        }
    }
    final class ComposerTextView: NSTextView {
        weak var coordinator: Coordinator?
        var placeholder = ""
        override func draw(_ rect: NSRect) {
            super.draw(rect)
            guard string.isEmpty else { return }
            let attributes: [NSAttributedString.Key: Any] = [.font: font ?? .systemFont(ofSize: 13), .foregroundColor: NSColor.placeholderTextColor]
            (placeholder as NSString).draw(at: NSPoint(x: (textContainer?.lineFragmentPadding ?? 2), y: 0), withAttributes: attributes)
        }
        /// ⌘Return arrives as a key equivalent, before `insertNewline`.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            if window?.firstResponder === self, event.type == .keyDown, event.keyCode == 36,
               event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
                coordinator?.parent.handler.submit(true); return true
            }
            return super.performKeyEquivalent(with: event)
        }
        override func paste(_ sender: Any?) {
            if coordinator?.parent.handler.paste(.general) == true { return }
            pasteAsPlainText(sender)
        }
        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            if let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
                return coordinator?.parent.handler.drop(urls) ?? false
            }
            if coordinator?.parent.handler.paste(sender.draggingPasteboard) == true { return true }
            return super.performDragOperation(sender)
        }
    }
}
