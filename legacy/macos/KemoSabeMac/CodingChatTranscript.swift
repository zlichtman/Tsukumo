import SwiftUI
import AppKit

// MARK: Model

/// A command or tool call as a card: what ran, its output, exit code, and duration.
struct CodingToolCard: Equatable {
    var id: String
    var title: String
    /// A shell command (shown as `$ command`), as opposed to a tool such as Read or Search.
    var shell: Bool
    var tool: String
    var output: String
    var exitCode: Int?
    var duration: Double?
    var status: String
    var check: Bool
    var running: Bool { status == "running" || status == "inProgress" || status == "in_progress" }
    var failed: Bool { status == "failed" || status == "declined" || (exitCode ?? 0) != 0 }
    init(_ event: CodingEvent) {
        id = event.id
        tool = event.tool ?? (event.kind == .check ? "check" : "")
        shell = event.kind == .check || tool == "Bash" || tool == "commandExecution" || (event.tool == nil && event.kind == .command)
        title = shell ? CodingChatEvents.displayCommand(event.text) : event.text
        // Codex streams a command's output into `detail`; Claude Code's results arrive in `output`.
        output = [event.detail, event.output ?? ""].filter { !$0.isEmpty }.joined(separator: "\n")
        exitCode = event.exitCode; duration = event.duration; status = event.status; check = event.kind == .check
    }
    var symbol: String {
        if check { return "checkmark.seal" }
        if shell { return "terminal" }
        switch tool {
        case "Read": return "doc.text"
        case "Grep", "Glob", "LS": return "magnifyingglass"
        case "WebFetch", "WebSearch", "webSearch": return "globe"
        case "Task", "Agent": return "person.2"
        case "mcpToolCall", "dynamicToolCall": return "puzzlepiece.extension"
        default: return "wrench.and.screwdriver"
        }
    }
    /// "1.2 s", "2 min 5 s".
    static func duration(_ seconds: Double) -> String {
        if seconds < 1 { return String(format: "%.0f ms", seconds * 1000) }
        if seconds < 60 { return String(format: "%.1f s", seconds) }
        return "\(Int(seconds) / 60) min \(Int(seconds) % 60) s"
    }
}
/// The start and end of long output, with how many lines sit between them.
struct CodingOutputPreview: Equatable {
    var head: [String]
    var omitted: Int
    var tail: [String]
    init(_ text: String, head count: Int = 6, tail tailCount: Int = 6) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        if lines.count <= count + tailCount + 1 { head = lines; omitted = 0; tail = [] }
        else { head = Array(lines.prefix(count)); tail = Array(lines.suffix(tailCount)); omitted = lines.count - count - tailCount }
    }
    var lineCount: Int { head.count + omitted + tail.count }
}
/// A step of an agent's plan.
struct CodingPlanStep: Equatable {
    enum State: Equatable { case pending, active, done }
    var state: State
    var text: String
    /// Plan text as both agents report it here: one "status · step" per line, or plain lines.
    static func parse(_ detail: String) -> [CodingPlanStep] {
        detail.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            guard let range = line.range(of: " · ") else { return .init(state: .pending, text: line) }
            let status = line[..<range.lowerBound].lowercased(), text = String(line[range.upperBound...])
            let state: State = status.contains("complete") || status == "done" ? .done : status.contains("progress") || status == "active" ? .active : .pending
            return .init(state: state, text: text)
        }
    }
}
/// What the transcript draws, built from a task's events.
enum CodingTranscriptItem: Identifiable, Equatable {
    case user(CodingEvent)
    case assistant(CodingEvent)
    case reasoning(CodingEvent)
    case tools([CodingToolCard])
    case file(CodingEvent)
    case plan(CodingEvent)
    case note(CodingEvent)
    var id: String {
        switch self {
        case .user(let e), .assistant(let e), .reasoning(let e), .file(let e), .plan(let e), .note(let e): e.id
        case .tools(let cards): "tools-" + (cards.first?.id ?? "")
        }
    }
    /// Consecutive commands and tool calls share one group, so a busy turn reads as
    /// "Ran 6 commands" between messages instead of a wall of cards.
    static func build(_ events: [CodingEvent]) -> [CodingTranscriptItem] {
        var items: [CodingTranscriptItem] = []
        for event in events {
            switch event.kind {
            case .user: items.append(.user(event))
            case .assistant: if !event.text.isEmpty { items.append(.assistant(event)) }
            case .reasoning: if !event.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { items.append(.reasoning(event)) }
            case .command, .check:
                let card = CodingToolCard(event)
                if case .tools(let cards) = items.last { items[items.count - 1] = .tools(cards + [card]) } else { items.append(.tools([card])) }
            case .file: items.append(.file(event))
            case .plan: items.append(.plan(event))
            case .approval, .system, .collaboration: items.append(.note(event))
            }
        }
        return items
    }
    /// "Ran 3 commands, read 2 files".
    static func summary(_ cards: [CodingToolCard]) -> String {
        let commands = cards.filter(\.shell).count, others = cards.count - commands
        var parts: [String] = []
        if commands > 0 { parts.append("Ran \(commands) command\(commands == 1 ? "" : "s")") }
        if others > 0 { parts.append((commands > 0 ? "used " : "Used ") + "\(others) tool\(others == 1 ? "" : "s")") }
        return parts.joined(separator: ", ")
    }
}

// MARK: Views

/// The task's conversation: messages, reasoning, tool and file cards, and plans. It follows new
/// output unless you've scrolled up, and then offers Jump to latest.
struct CodingTranscriptView: View {
    let task: CodingTaskRecord
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(AppStore.self) private var store
    @Environment(\.colorScheme) private var scheme
    private var accent: Color { preferences.palette(scheme).accent }
    @State private var position = ScrollPosition(edge: .bottom)
    @State private var atBottom = true
    /// Kemo at its workstation above the conversation while there's room (`ChatStage`), acting out
    /// what the agent is doing; when the conversation fills the view, the stage folds away.
    @State private var stageShown = true
    @State private var stageMetrics = ChatStage.Metrics()
    /// The person scrolled by hand and isn't back at the latest message (`ChatStage`).
    @State private var browsing = false
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private var reduceMotion: Bool { preferences.followReduceMotion ? systemReduceMotion : preferences.reduceMotion }
    static let stageHeight: CGFloat = 168
    var body: some View {
        let items = CodingTranscriptItem.build(task.events)
        ZStack(alignment: .bottom) {
          VStack(spacing: 0) {
            if stageShown {
                ArtworkCompanion(theme: store.state.theme, performance: CodingActivity.performance(task), reducedMotion: reduceMotion, active: true, framesPerSecond: 30)
                    .frame(height: Self.stageHeight).frame(maxWidth: .infinity)
                    .accessibilityIdentifier("tsukumoKemoAtWork")
                    .transition(reduceMotion ? .opacity : .scale(scale: 0.4, anchor: .top).combined(with: .opacity))
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if let omitted = task.omittedEvents, omitted > 0 {
                        Text("\(omitted) earlier events are kept in this task's log.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    }
                    // The first message shows at once, while the worktree is being made.
                    if task.status == .preparing, !task.events.contains(where: { $0.kind == .user }), let starting = CodingChatCommands.shared.starting {
                        CodingUserMessage(event: .init(kind: .user, text: starting))
                    }
                    ForEach(items) { item in row(item).id(item.id) }
                    if task.status.running {
                        // The agent's avatar with its small thinking orb, at the end of the conversation: one signal.
                        let activity = CodingActivity.current(task)
                        HStack(alignment: .top, spacing: CodingAgentAvatar.gap) {
                            CodingAgentAvatar(provider: task.provider, orb: activity.state, accent: accent)
                            VStack(alignment: .leading, spacing: 3) {
                                CodingAgentAvatar.name(task.provider)
                                Text(activity.label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                            }
                        }.padding(.top, 2).accessibilityElement(children: .combine).accessibilityIdentifier("codingThinking")
                    }
                    Color.clear.frame(height: 4)
                }
                .padding(.horizontal, 22).padding(.vertical, 16)
                .frame(maxWidth: 820).frame(maxWidth: .infinity)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .defaultScrollAnchor(ChatStage.anchorsTop(stageMetrics, stageHeight: Self.stageHeight, shown: stageShown, browsing: browsing) ? .top : .bottom, for: .sizeChanges)
            .onScrollPhaseChange { _, phase in if phase == .interacting { browsing = true } }
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 60
            } action: { _, bottom in atBottom = bottom }
            .onScrollGeometryChange(for: ChatStage.Metrics.self) { geometry in
                ChatStage.Metrics(contentHeight: geometry.contentSize.height + geometry.contentInsets.top + geometry.contentInsets.bottom,
                                  viewportHeight: geometry.containerSize.height,
                                  distanceFromTop: geometry.contentOffset.y + geometry.contentInsets.top)
            } action: { _, metrics in updateStage(metrics) }
          }
            .onChange(of: task.events.last?.text.count) { follow() }
            .onChange(of: task.events.last?.detail.count) { follow() }
            .onChange(of: task.events.count) { follow() }
            .onChange(of: task.id) { atBottom = true; browsing = false; stageShown = true; stageMetrics = .init(); position.scrollTo(edge: .bottom) }
            if !atBottom {
                Button { atBottom = true; withAnimation(.easeOut(duration: 0.2)) { position.scrollTo(edge: .bottom) } } label: {
                    Label("Jump to latest", systemImage: "arrow.down").font(.system(size: 12, weight: .medium))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1)))
                        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                }.buttonStyle(.plain).padding(.bottom, 10).transition(.opacity).accessibilityIdentifier("jumpToLatest")
            }
        }
    }
    private func follow() { if atBottom { position.scrollTo(edge: .bottom) } }
    /// The stage comes and goes with the room, as in KemoSabe's chat.
    private func updateStage(_ metrics: ChatStage.Metrics) {
        let measured = stageMetrics.viewportHeight > 0
        stageMetrics = metrics
        if ChatStage.atBottom(metrics) { browsing = false }
        let next = ChatStage.stageShown(metrics, stageHeight: Self.stageHeight, shown: stageShown, allowed: true, empty: task.events.isEmpty, browsing: browsing)
        guard next != stageShown else { return }
        if !measured { stageShown = next; return }
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.74)) { stageShown = next }
    }
    @ViewBuilder private func row(_ item: CodingTranscriptItem) -> some View {
        switch item {
        case .user(let event): CodingUserMessage(event: event)
        case .assistant(let event): CodingAssistantMessage(event: event, task: task, codeSize: preferences.codeFontSize)
        case .reasoning(let event): CodingReasoningRow(event: event, live: task.status.running && task.events.last?.id == event.id)
        case .tools(let cards): CodingToolGroup(cards: cards, live: task.status.running && cards.contains(where: { $0.id == task.events.last?.id }))
        case .file(let event): CodingFileCardView(event: event, codeSize: preferences.codeFontSize)
        case .plan(let event): CodingPlanCard(event: event)
        case .note(let event): CodingNoteRow(event: event)
        }
    }
}
struct CodingUserMessage: View {
    let event: CodingEvent
    var body: some View {
        HStack {
            Spacer(minLength: 80)
            VStack(alignment: .trailing, spacing: 6) {
                if let images = event.images, !images.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(images, id: \.self) { path in
                            if let image = NSImage(contentsOfFile: path) {
                                Image(nsImage: image).resizable().scaledToFill().frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                            }
                        }
                    }
                }
                Text(event.text).textSelection(.enabled).lineSpacing(3)
                    .padding(.horizontal, 13).padding(.vertical, 9)
                    .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .contextMenu { Button("Copy") { CodingClipboard.copy(event.text) } }
    }
}
private struct CodingAssistantMessage: View {
    let event: CodingEvent
    let task: CodingTaskRecord
    let codeSize: CGFloat
    @Environment(CodingWorkspaceStore.self) private var coding
    @State private var hovering = false
    var body: some View {
        // The agent's reply carries its mark, like a profile picture in a chat.
        HStack(alignment: .top, spacing: CodingAgentAvatar.gap) {
        CodingAgentAvatar(provider: task.provider)
        VStack(alignment: .leading, spacing: 4) {
            CodingAgentAvatar.name(task.provider)
            CodingMarkdownView(text: event.text, codeSize: codeSize)
            HStack(spacing: 2) {
                Button { CodingClipboard.copy(event.text) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                if event.ref != nil, task.sessionID != nil {
                    Button { Task { await coding.fork(task.id, at: event.id) } } label: { Image(systemName: "arrow.triangle.branch") }.help("Fork a new task from here")
                }
            }
            .buttonStyle(DesktopRowButtonStyle(inset: 4)).font(.system(size: 11)).foregroundStyle(.secondary)
            .opacity(hovering ? 1 : 0).accessibilityHidden(!hovering)
        }
        }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Copy") { CodingClipboard.copy(event.text) }
            if event.ref != nil, task.sessionID != nil { Button("Fork from here") { Task { await coding.fork(task.id, at: event.id) } } }
        }
    }
}
private struct CodingReasoningRow: View {
    let event: CodingEvent
    let live: Bool
    @State private var open = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 6) {
                    if live { KemoOrb(size: 14, state: .searching) } else { Image(systemName: "brain").font(.system(size: 11)) }
                    Text(live ? "Thinking…" : title).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }.font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel(open ? "Hide reasoning" : "Show reasoning")
            if open {
                CodingMarkdownView(text: event.text, codeSize: 11).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.leading, 12).overlay(alignment: .leading) { Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 2) }
            }
        }
    }
    /// The first bold heading of a reasoning summary ("**Planning the change**"), or "Thought".
    private var title: String {
        let first = event.text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").first.map(String.init) ?? ""
        let plain = first.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
        return plain.isEmpty || plain.count > 80 ? "Thought" : plain
    }
}
/// Consecutive tool calls: one line while collapsed ("Ran 4 commands"), each card when open.
/// The latest group stays open while the agent works.
private struct CodingToolGroup: View {
    let cards: [CodingToolCard]
    let live: Bool
    @State private var open: Bool?
    var body: some View {
        let expanded = open ?? (live || cards.count <= 2)
        VStack(alignment: .leading, spacing: 6) {
            if cards.count > 2 {
                Button { withAnimation(.easeOut(duration: 0.15)) { open = !expanded } } label: {
                    HStack(spacing: 6) {
                        Text(CodingTranscriptItem.summary(cards))
                        if cards.contains(where: \.failed) { Text("· \(cards.filter(\.failed).count) failed").foregroundStyle(.red) }
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(expanded ? 90 : 0))
                    }.font(.system(size: 12)).foregroundStyle(.secondary).contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if expanded { ForEach(cards, id: \.id) { CodingToolCardView(card: $0) } }
        }
    }
}
struct CodingToolCardView: View {
    let card: CodingToolCard
    @State private var open = false
    @State private var full = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: card.symbol).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                    Text(card.shell ? "$ " + card.title : card.title).font(.system(size: 12, design: card.shell ? .monospaced : .default))
                        .lineLimit(open ? 6 : 1).truncationMode(.tail).frame(maxWidth: .infinity, alignment: .leading)
                    if card.running { KemoOrb(size: 14, state: .searching) }
                    if let duration = card.duration { Text(CodingToolCard.duration(duration)).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit() }
                    if let code = card.exitCode {
                        Text(code == 0 ? "exit 0" : "exit \(code)").font(.system(size: 10.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(code == 0 ? Color.green : Color.red)
                            .padding(.horizontal, 5).padding(.vertical, 1).background((code == 0 ? Color.green : Color.red).opacity(0.1), in: Capsule())
                    } else if card.failed { Text(card.status == "declined" ? "declined" : "failed").font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red) }
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary).rotationEffect(.degrees(open ? 90 : 0))
                }.padding(.horizontal, 10).padding(.vertical, 7).contentShape(Rectangle())
            }.buttonStyle(.plain)
            .accessibilityLabel((card.shell ? "Command " : "") + card.title + (card.exitCode.map { ", exit code \($0)" } ?? ""))
            if open {
                Divider().opacity(0.5)
                output.padding(10)
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .contextMenu {
            Button(card.shell ? "Copy command" : "Copy") { CodingClipboard.copy(card.title) }
            if !card.output.isEmpty { Button("Copy output") { CodingClipboard.copy(card.output) } }
        }
    }
    @ViewBuilder private var output: some View {
        let mono = Font.system(size: 11.5, design: .monospaced)
        if card.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Text(card.running ? "Waiting for output…" : "No output").font(.system(size: 11)).foregroundStyle(.tertiary)
        } else if full {
            ScrollView { Text(card.output).font(mono).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 360)
            Button("Show less") { full = false }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(.top, 6)
        } else {
            let preview = CodingOutputPreview(card.output)
            VStack(alignment: .leading, spacing: 0) {
                Text(preview.head.joined(separator: "\n")).font(mono).textSelection(.enabled)
                if preview.omitted > 0 {
                    Button("… \(preview.omitted) more lines · Show all") { full = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(.vertical, 4)
                    Text(preview.tail.joined(separator: "\n")).font(mono).textSelection(.enabled)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
/// A file edit with its diff inline; the path opens the file in the Changes pane.
private struct CodingFileCardView: View {
    let event: CodingEvent
    let codeSize: CGFloat
    @State private var open = true
    @State private var full = false
    var body: some View {
        let files = CodingDiff.parse(event.detail)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "doc.badge.ellipsis").font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 14)
                Text(verb(files)).font(.system(size: 12)).foregroundStyle(.secondary)
                ForEach(files.prefix(3)) { file in
                    Button(file.path) { CodingChatCommands.shared.reveal(file.path) }
                        .buttonStyle(.plain).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.head)
                        .help("Show in Changes")
                }
                if files.isEmpty { Text(event.text).font(.system(size: 12, weight: .medium)).lineLimit(1) }
                Spacer(minLength: 4)
                let added = files.reduce(0) { $0 + $1.additions }, removed = files.reduce(0) { $0 + $1.deletions }
                if added > 0 { Text("+\(added)").foregroundStyle(.green).font(.system(size: 11, design: .monospaced)) }
                if removed > 0 { Text("−\(removed)").foregroundStyle(.red).font(.system(size: 11, design: .monospaced)) }
                if event.status == "running" || event.status == "inProgress" { KemoOrb(size: 14, state: .searching) }
                if event.status == "failed" || event.status == "declined" { Text(event.status).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.red) }
                Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0))
                }.buttonStyle(DesktopRowButtonStyle(inset: 4)).foregroundStyle(.tertiary).accessibilityLabel(open ? "Hide diff" : "Show diff")
            }.padding(.horizontal, 10).padding(.vertical, 6)
            if open, !files.isEmpty {
                Divider().opacity(0.5)
                let lines = files.flatMap { file in (files.count > 1 ? [CodingDiffLine(kind: .note, text: file.path)] : []) + file.hunks.flatMap(\.lines) }
                let limit = full ? lines.count : 24
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(lines.prefix(limit).enumerated()), id: \.offset) { _, line in diffLine(line) }
                }.padding(.vertical, 4)
                if lines.count > limit {
                    Button("Show all \(lines.count) lines") { full = true }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 6)
                }
            }
        }
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    private func verb(_ files: [CodingDiffFile]) -> String {
        if files.count > 3 { return "Edited \(files.count) files:" }
        if files.first?.change == .added { return "Created" }
        if files.first?.change == .deleted { return "Deleted" }
        return "Edited"
    }
    private func diffLine(_ line: CodingDiffLine) -> some View {
        let sign = line.kind == .added ? "+" : line.kind == .removed ? "−" : " "
        return HStack(spacing: 6) {
            Text(line.kind == .note ? "" : sign).foregroundStyle(line.kind == .added ? .green : line.kind == .removed ? .red : .secondary).frame(width: 10)
            Text(line.text.isEmpty ? " " : line.text).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(line.kind == .note ? .secondary : .primary)
        }
        .font(.system(size: max(10, codeSize - 1), design: .monospaced))
        .padding(.horizontal, 10).padding(.vertical, 0.5).frame(maxWidth: .infinity, alignment: .leading)
        .background(line.kind == .added ? Color.green.opacity(0.1) : line.kind == .removed ? Color.red.opacity(0.1) : .clear)
    }
}
private struct CodingPlanCard: View {
    let event: CodingEvent
    var body: some View {
        let steps = CodingPlanStep.parse(event.detail)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.clipboard").font(.system(size: 11))
                Text("Plan").font(.system(size: 12, weight: .semibold))
                Text("\(steps.filter { $0.state == .done }.count) of \(steps.count) done").font(.system(size: 11)).foregroundStyle(.secondary)
            }.foregroundStyle(.secondary)
            if let explanation = event.output, !explanation.isEmpty { Text(explanation).font(.system(size: 12)).foregroundStyle(.secondary) }
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Image(systemName: step.state == .done ? "checkmark.circle.fill" : step.state == .active ? "circle.dotted.circle" : "circle")
                        .foregroundStyle(step.state == .done ? Color.green : step.state == .active ? Color.accentColor : .secondary).font(.system(size: 12))
                    Text(step.text).font(.system(size: 12.5)).strikethrough(step.state == .done, color: .secondary)
                        .foregroundStyle(step.state == .done ? .secondary : .primary)
                }
            }
        }
        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
private struct CodingNoteRow: View {
    let event: CodingEvent
    @State private var open = false
    var body: some View {
        let quiet = CodingTaskNote.isQuiet(event)
        VStack(alignment: .leading, spacing: 4) {
            Button { if !event.detail.isEmpty { open.toggle() } } label: {
                HStack(spacing: 6) {
                    Image(systemName: quiet ? "arrow.triangle.branch" : symbol).font(.system(size: 10))
                    Text(CodingTaskNote.text(event)).lineLimit(1)
                    if !event.detail.isEmpty { Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).rotationEffect(.degrees(open ? 90 : 0)) }
                }.font(.system(size: 11.5)).foregroundStyle(quiet ? AnyShapeStyle(.tertiary) : AnyShapeStyle(tint)).contentShape(Rectangle())
            }.buttonStyle(.plain).help(quiet ? event.detail : "")
            if open { Text(event.detail).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled).padding(.leading, 16) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var failed: Bool { event.text.contains("failed") || event.text.contains("Failed") || event.text.contains("error") || event.text == "Denied" }
    private var tint: Color { failed ? .orange : .secondary }
    private var symbol: String {
        if event.kind == .approval { return event.text == "Denied" ? "hand.raised" : "checkmark.shield" }
        if event.kind == .collaboration { return "person.2" }
        return failed ? "exclamationmark.triangle" : "info.circle"
    }
}
enum CodingClipboard {
    static func copy(_ text: String) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
}

/// An agent as a chat avatar: its mark (symbol or initials on its own color), with the small thinking
/// orb while it works. KemoSabe's replies show Kemo instead (`KemoAvatarSlot`).
struct CodingAgentAvatar: View {
    let provider: CodingProvider
    var orb: OrbState?
    var accent: Color = .accentColor
    static let size: CGFloat = 24
    static let gap: CGFloat = 10
    var body: some View {
        CodingAgentBadge(mark: CodingAgentRegistry.shared.adapter(for: provider).mark, size: Self.size)
            .overlay(alignment: .bottomTrailing) {
                if let orb {
                    KemoOrb(size: Self.size * 0.62, state: orb).tint(accent)
                        .background(Circle().fill(.background).padding(-1.5))
                        .offset(x: Self.size * 0.2, y: Self.size * 0.2)
                }
            }
            .frame(width: Self.size, height: Self.size)
    }
    /// The agent's name beside its avatar, small and quiet.
    static func name(_ provider: CodingProvider) -> some View {
        Text(provider.title).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary).lineLimit(1)
            .frame(minHeight: size * 0.7, alignment: .center)
    }
}
