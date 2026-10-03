import SwiftUI
import AppKit

/// Tsukumo's collaboration page, in the spirit of Amoeba: everyone on the project (you, other
/// people once sharing exists, and each agent task) as soft blobs sized by how much they're doing,
/// merging where their work overlaps. Below it: plans, overlaps with what to do about them, the
/// files each participant touches, and the timeline of handoffs and messages.
struct CodingCollaborationView: View {
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopProjects.self) private var projects
    @Environment(DesktopNavigation.self) private var desktop
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var composing = false
    @State private var focus: String?
    private var orchestrator: CodingOrchestrator { coding.orchestrator }
    private var palette: DesktopPalette { preferences.palette(scheme) }
    var body: some View {
        let project = projects.selected
        let board = orchestrator.board(for: project)
        VStack(spacing: 0) {
            header(board)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    if project == nil {
                        ContentUnavailableView {
                            Label("No project open", systemImage: "folder")
                        } description: { Text("Open a project to plan work across agents and see who's touching what.") } actions: {
                            Button("Open project…") { projects.choose() }.buttonStyle(DesktopButtonStyle(prominent: true))
                        }.padding(.top, 40)
                    } else {
                        if composing || orchestrator.runs(for: project).isEmpty && coding.forProject(project).isEmpty {
                            CollabPlanComposer(done: { composing = false })
                        }
                        ForEach(orchestrator.runs(for: project).filter { $0.phase != .cancelled && $0.phase != .accepted }) { run in CollabRunCard(run: run) }
                        CollabField(board: board, palette: palette, focus: $focus) { open($0) }
                        CollabOverlapList(board: board, project: project)
                        CollabParticipants(board: board, palette: palette, focus: $focus) { open($0) }
                        CollabTimeline(entries: board.messages, palette: palette)
                        finishedRuns(project)
                        archived(project)
                        sharingFooter(project)
                    }
                }.padding(.horizontal, 28).padding(.vertical, 22).frame(maxWidth: 1040, alignment: .leading).frame(maxWidth: .infinity)
            }
            if !orchestrator.notice.isEmpty {
                HStack { Text(orchestrator.notice).font(.caption).textSelection(.enabled); Spacer(); Button("Dismiss") { orchestrator.notice = "" }.buttonStyle(DesktopButtonStyle()) }
                    .padding(10).foregroundStyle(.orange)
            }
        }
        .task {
            orchestrator.displayName = { AccountStore.shared.account.firstName ?? "You" }
            orchestrator.startCoordinating()
        }
    }
    private func header(_ board: CollabBoard) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Coordination").font(.system(size: 19, weight: .semibold))
                Text(summary(board)).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            if board.needsAttention > 0 {
                Label("\(board.needsAttention) need\(board.needsAttention == 1 ? "s" : "") you", systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(.orange)
            }
            Button { composing.toggle() } label: { Label("Plan with agents", systemImage: "square.stack.3d.up") }
                .buttonStyle(DesktopButtonStyle(prominent: true)).disabled(projects.selected == nil || !coding.signedIn || coding.storageFailed)
        }.padding(.horizontal, 22).padding(.vertical, 12)
    }
    private func summary(_ board: CollabBoard) -> String {
        let agents = board.active.filter { $0.agent != nil }.count
        let name = projects.projects.first { $0.id == projects.selected }?.name
        return [name, agents == 0 ? "No agents working" : "\(agents) agent\(agents == 1 ? "" : "s") working", "Checked every few seconds"].compactMap { $0 }.joined(separator: " · ")
    }
    private func open(_ id: String) {
        guard let uuid = UUID(uuidString: id), coding.task(uuid) != nil else { focus = focus == id ? nil : id; return }
        coding.selected = uuid; desktop.tsukumoSurface = "Project"
    }
    @ViewBuilder private func finishedRuns(_ project: UUID?) -> some View {
        let finished = orchestrator.runs(for: project).filter { $0.phase == .accepted || $0.phase == .cancelled }
        if !finished.isEmpty {
            DisclosureGroup("Earlier plans (\(finished.count))") {
                ForEach(finished) { run in
                    HStack { Text(run.title).lineLimit(1); Spacer(); Text(run.phase.title).foregroundStyle(.secondary) }.font(.system(size: 12)).padding(.vertical, 3)
                }
            }.font(.system(size: 13))
        }
    }
    @ViewBuilder private func archived(_ project: UUID?) -> some View {
        let archived = coding.forProject(project, archived: true)
        if !archived.isEmpty {
            DisclosureGroup("Archived tasks (\(archived.count))") {
                ForEach(archived) { task in
                    HStack {
                        Text(task.title).lineLimit(1)
                        Text(task.status.title).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Unarchive") { coding.unarchive(task.id) }.buttonStyle(DesktopButtonStyle())
                        CodingDeleteTaskButton(task: task)
                    }.padding(.vertical, 3)
                }
            }.font(.system(size: 13))
        }
    }
    @ViewBuilder private func sharingFooter(_ project: UUID?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if orchestrator.isShared(project) {
                Label("Shared through this project's Git remote", systemImage: "person.2").font(.system(size: 13, weight: .medium))
            } else if orchestrator.sharingAvailable, let project {
                Button { Task { if let root = try? projects.resolve(project) { await orchestrator.share(project, root: root) } } } label: { Label("Share this project", systemImage: "person.badge.plus") }
                    .buttonStyle(DesktopButtonStyle())
            } else {
                Label("Sharing starts once iCloud sync is set up", systemImage: "icloud.slash").font(.system(size: 13, weight: .medium))
                Text("People who join will appear here with their tasks and files. Until then this page shows you and your agents on this Mac.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }.padding(.top, 6)
    }
}

// MARK: - The field

/// A participant drawn on the field: a node card.
struct CollabNode: Identifiable, Equatable {
    var id: String
    var title: String
    var subtitle: String
    var symbol: String
    /// The agent's mark (official logo) for agents; nil for people.
    var mark: CodingAgentMark?
    var state: CollabState
    var files: Int
    var person: Bool
    var hue: Double
    var active: Bool { state.active }
}

/// A system diagram, left to right: people, then the tasks that start from nothing, then each
/// task that waits on another one column further right. Rows are evenly spaced per column, so
/// nothing overlaps and the layout doesn't jump between checks (September 28, 2026: the owner
/// found the old floating blobs "ugly" and asked for something "more techy").
enum CollabLayout {
    static let card = CGSize(width: 250, height: 58)
    static let columnGap: CGFloat = 86, rowGap: CGFloat = 18, margin: CGFloat = 28
    /// Each node's column: people 0, independent tasks 1, dependent tasks one past what they wait on.
    static func columns(_ nodes: [CollabNode], dependencies: [(String, String)]) -> [String: Int] {
        var column: [String: Int] = [:]
        for node in nodes { column[node.id] = node.person ? 0 : 1 }
        for _ in 0..<nodes.count {
            var changed = false
            for (from, to) in dependencies {
                guard let a = column[from], let b = column[to], b <= a else { continue }
                column[to] = a + 1; changed = true
            }
            if !changed { break }
        }
        if !nodes.contains(where: \.person) { for (id, c) in column { column[id] = c - 1 } }
        return column
    }
    /// Card centers in a canvas of `size`, and the height the diagram needs.
    static func place(_ nodes: [CollabNode], dependencies: [(String, String)], width: CGFloat) -> (points: [String: CGPoint], height: CGFloat) {
        guard !nodes.isEmpty else { return ([:], 220) }
        let column = columns(nodes, dependencies: dependencies)
        let count = (column.values.max() ?? 0) + 1
        var byColumn: [[CollabNode]] = Array(repeating: [], count: count)
        for node in nodes { byColumn[column[node.id] ?? 0].append(node) }
        let tallest = byColumn.map(\.count).max() ?? 1
        let height = max(220, CGFloat(tallest) * card.height + CGFloat(tallest - 1) * rowGap + margin * 2)
        let used = CGFloat(count) * card.width + CGFloat(count - 1) * columnGap
        let left = max(margin, (width - used) / 2)
        var points: [String: CGPoint] = [:]
        for (c, list) in byColumn.enumerated() {
            let block = CGFloat(list.count) * card.height + CGFloat(max(0, list.count - 1)) * rowGap
            let top = (height - block) / 2
            for (r, node) in list.enumerated() {
                points[node.id] = CGPoint(x: left + CGFloat(c) * (card.width + columnGap) + card.width / 2,
                                          y: top + CGFloat(r) * (card.height + rowGap) + card.height / 2)
            }
        }
        return (points, height)
    }
    /// A right-angled wire from the right edge of one card to the left edge of another.
    static func wire(from a: CGPoint, to b: CGPoint) -> Path {
        var path = Path()
        let start = CGPoint(x: a.x + card.width / 2, y: a.y), end = CGPoint(x: b.x - card.width / 2, y: b.y)
        let mid = (start.x + end.x) / 2
        path.move(to: start)
        if abs(start.y - end.y) < 1 { path.addLine(to: end); return path }
        let bend: CGFloat = min(8, abs(end.y - start.y) / 2), down: CGFloat = end.y > start.y ? 1 : -1
        path.addLine(to: CGPoint(x: mid - bend, y: start.y))
        path.addQuadCurve(to: CGPoint(x: mid, y: start.y + bend * down), control: CGPoint(x: mid, y: start.y))
        path.addLine(to: CGPoint(x: mid, y: end.y - bend * down))
        path.addQuadCurve(to: CGPoint(x: mid + bend, y: end.y), control: CGPoint(x: mid, y: end.y))
        path.addLine(to: end)
        return path
    }
}

struct CollabField: View {
    let board: CollabBoard
    let palette: DesktopPalette
    @Binding var focus: String?
    var open: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 900
    var body: some View {
        let nodes = Self.nodes(board)
        let links = Self.links(board, nodes: nodes)
        let dependencies = Self.dependencies(board, nodes: nodes)
        let wires = Self.wires(nodes, dependencies: dependencies)
        let layout = CollabLayout.place(nodes, dependencies: dependencies, width: width)
        ZStack(alignment: .topLeading) {
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : Self.clock(context.date)
                Canvas { canvas, size in
                    grid(canvas, size: size)
                    draw(canvas, nodes: nodes, points: layout.points, wires: wires, links: links, time: time)
                }
            }
            ForEach(nodes) { node in
                if let point = layout.points[node.id] {
                    card(node).frame(width: CollabLayout.card.width, height: CollabLayout.card.height)
                        .position(point)
                }
            }
            TimelineView(.animation(minimumInterval: 1.0 / 60, paused: reduceMotion)) { context in
                let time = reduceMotion ? 0 : Self.clock(context.date)
                Canvas { canvas, _ in drawOverlaps(canvas, points: layout.points, links: links, time: time) }.allowsHitTesting(false)
            }
            ForEach(links, id: \.0) { link in
                let ids = link.0.components(separatedBy: "|")
                if ids.count == 2, let a = layout.points[ids[0]], let b = layout.points[ids[1]] {
                    let p = Self.overlapAnchor(a, b)
                    Text("⚠︎ \(link.1) SHARED").font(.system(size: 9.5, weight: .semibold, design: .monospaced)).tracking(0.6)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(palette.background, in: RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.orange.opacity(0.7), lineWidth: 1))
                        .foregroundStyle(Color.orange).position(p).allowsHitTesting(false)
                }
            }
            if nodes.isEmpty {
                Text("NO ACTIVE NODES · start a task or a plan and everyone working on this project appears here")
                    .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: layout.height)
        .frame(maxWidth: .infinity)
        .background(GeometryReader { geo in Color.clear.onAppear { width = geo.size.width }.onChange(of: geo.size.width) { _, w in width = w } })
        .background(palette.foreground.opacity(0.02), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(palette.foreground.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .contain).accessibilityLabel("Participants and overlaps")
    }

    // MARK: Cards

    private func card(_ node: CollabNode) -> some View {
        Button { open(node.id) } label: {
            HStack(spacing: 10) {
                Group {
                    if let mark = node.mark { CodingAgentBadge(mark: mark, size: 26) }
                    else { Image(systemName: "person.fill").font(.system(size: 12, weight: .semibold)).frame(width: 26, height: 26)
                        .background(Color(hue: node.hue, saturation: 0.35, brightness: 0.8).opacity(0.25), in: RoundedRectangle(cornerRadius: 6)) }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(node.title).font(.system(size: 12, weight: .semibold)).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 5) {
                        led(node)
                        Text(node.subtitle.uppercased()).font(.system(size: 9, weight: .medium, design: .monospaced)).tracking(0.4)
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.background.opacity(0.92), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(focus == node.id ? palette.accent : palette.foreground.opacity(node.active ? 0.16 : 0.08), lineWidth: focus == node.id ? 1.5 : 1))
            .overlay(alignment: .leading) {
                // A status stripe on the card's edge.
                RoundedRectangle(cornerRadius: 1.5).fill(Self.stateColor(node.state).opacity(node.active ? 0.9 : 0.35)).frame(width: 3, height: 26).offset(x: -1.5)
            }
        }
        .buttonStyle(.plain).opacity(node.active ? 1 : 0.6)
        .help(node.person ? "Show the files you changed by hand" : "Open this task")
        .accessibilityLabel(node.title + ", " + node.subtitle)
    }
    private func led(_ node: CollabNode) -> some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || node.state != .working)) { context in
            let pulse = node.state == .working && !reduceMotion ? 0.72 + 0.28 * sin(Self.clock(context.date) * 3.2) : 1
            Circle().fill(Self.stateColor(node.state)).frame(width: 6, height: 6)
                .shadow(color: Self.stateColor(node.state).opacity(node.state == .working ? 0.8 : 0), radius: 3)
                .opacity(pulse)
        }.frame(width: 6, height: 6)
    }
    static func stateColor(_ state: CollabState) -> Color {
        switch state {
        case .working, .planning: Color(red: 0.36, green: 0.86, blue: 0.56)
        case .needsYou: Color.orange
        case .review: Color(red: 0.45, green: 0.66, blue: 1)
        case .failed: Color(red: 1, green: 0.38, blue: 0.38)
        case .paused, .done: Color.gray
        }
    }

    // MARK: Canvas

    /// The animation clock: packets, overlap dashes, and LEDs all move with it.
    static func clock(_ date: Date) -> Double {
        #if DEBUG
        if let demoTime { return demoTime }
        #endif
        return date.timeIntervalSinceReferenceDate
    }
    #if DEBUG
    /// A fixed time for rendering the diagram frame by frame (the website's loop, `SiteDemoSnapshotTests`).
    nonisolated(unsafe) static var demoTime: Double?
    #endif
    private func grid(_ canvas: GraphicsContext, size: CGSize) {
        let step: CGFloat = 16
        var dots = Path()
        var y = step / 2
        while y < size.height { var x = step / 2; while x < size.width { dots.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2)); x += step }; y += step }
        canvas.fill(dots, with: .color(palette.foreground.opacity(0.07)))
    }
    private func draw(_ canvas: GraphicsContext, nodes: [CollabNode], points: [String: CGPoint], wires: [(String, String)], links: [(String, Int)], time: Double) {
        let active = Dictionary(nodes.map { ($0.id, $0.active && $0.state != .paused) }, uniquingKeysWith: { a, _ in a })
        // Wires: person → task (dispatch) and task → task (handoff), with packets flowing on live ones.
        for (from, to) in wires {
            guard let a = points[from], let b = points[to] else { continue }
            let path = CollabLayout.wire(from: a, to: b)
            let live = active[to] == true
            canvas.stroke(path, with: .color(palette.foreground.opacity(live ? 0.28 : 0.12)), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
            // Ports on both ends.
            for p in [CGPoint(x: a.x + CollabLayout.card.width / 2, y: a.y), CGPoint(x: b.x - CollabLayout.card.width / 2, y: b.y)] {
                canvas.fill(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(palette.background))
                canvas.stroke(Path(ellipseIn: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)), with: .color(palette.foreground.opacity(live ? 0.5 : 0.2)), lineWidth: 1)
            }
            guard live, !reduceMotion else { continue }
            // Packets: short bright dashes riding the wire.
            let phase = CGFloat((time * 60).truncatingRemainder(dividingBy: 48))
            canvas.stroke(path, with: .color(palette.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 42], dashPhase: -phase))
        }
    }
    /// Overlaps: a dashed orange bus drawn above the cards, from edge to edge, never through one.
    private func drawOverlaps(_ canvas: GraphicsContext, points: [String: CGPoint], links: [(String, Int)], time: Double) {
        for (key, _) in links {
            let ids = key.components(separatedBy: "|")
            guard ids.count == 2, let a = points[ids[0]], let b = points[ids[1]] else { continue }
            let phase = reduceMotion ? 0 : CGFloat((time * 20).truncatingRemainder(dividingBy: 10))
            canvas.stroke(Self.overlapPath(a, b), with: .color(Color.orange.opacity(0.85)), style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [4, 5], dashPhase: phase))
        }
    }
    /// Between cards in different columns: a wire 14 pt below the handoff wires' height, edge to
    /// edge. In the same column: an arc out to the right of both cards.
    static func overlapPath(_ a: CGPoint, _ b: CGPoint) -> Path {
        let w = CollabLayout.card.width / 2, drop: CGFloat = 14
        if abs(a.x - b.x) < 1 {
            var path = Path(); let x = a.x + w
            path.move(to: CGPoint(x: x, y: a.y + drop)); path.addCurve(to: CGPoint(x: x, y: b.y + drop), control1: CGPoint(x: x + 46, y: a.y + drop), control2: CGPoint(x: x + 46, y: b.y + drop))
            return path
        }
        let (l, r) = a.x < b.x ? (a, b) : (b, a)
        return CollabLayout.wire(from: CGPoint(x: l.x, y: l.y + drop), to: CGPoint(x: r.x, y: r.y + drop))
    }
    static func overlapAnchor(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
        let w = CollabLayout.card.width / 2, drop: CGFloat = 14
        if abs(a.x - b.x) < 1 { return CGPoint(x: a.x + w + 36, y: (a.y + b.y) / 2 + drop) }
        let (l, r) = a.x < b.x ? (a, b) : (b, a)
        return CGPoint(x: (l.x + w + r.x - w) / 2, y: (l.y + r.y) / 2 + drop)
    }

    // MARK: Model

    static func nodes(_ board: CollabBoard) -> [CollabNode] {
        let recent = Date().addingTimeInterval(-12 * 3600)
        func shown(_ task: CollabTask) -> Bool {
            if task.state.active || task.agent == nil { return true }
            return task.plan != nil && task.updated > recent
        }
        return board.tasks.filter(shown).map { task in
            let person = task.agent == nil
            let files = Set(task.files.map(\.path)).count
            // "Δ3": files changed, kept short so the status line fits the card.
            let subtitle = person ? (files == 0 ? "idle · by hand" : "Δ\(files) · by hand")
                : [task.agent ?? "", task.state.title].joined(separator: " · ") + (files > 0 ? " · Δ\(files)" : "")
            return CollabNode(id: task.id, title: person ? task.ownerName : task.title, subtitle: subtitle,
                              symbol: person ? "person.fill" : CodingAgentNames.symbol(forTitle: task.agent ?? ""),
                              mark: person ? nil : mark(forAgent: task.agent ?? ""),
                              state: task.state, files: files, person: person, hue: hue(task))
        }.sorted { ($0.person ? 0 : 1, $0.id) < ($1.person ? 0 : 1, $1.id) }
    }
    /// The official mark for an agent named by its title, or initials for one Tsukumo doesn't know.
    @MainActor static func mark(forAgent title: String) -> CodingAgentMark {
        let registry = CodingAgentRegistry.shared
        if let provider = registry.choices(including: []).first(where: { CodingAgentNames.title($0) == title }) {
            return registry.adapter(for: provider).mark
        }
        return CodingAgentMark(symbol: CodingAgentNames.symbol(forTitle: title), initials: String(title.prefix(1)), hue: 0.72)
    }
    /// Each participant keeps its hue: people warm, Codex cool, Claude Code in between.
    static func hue(_ task: CollabTask) -> Double {
        let seed = Double(task.id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }) / 65535
        if task.agent == nil { return 0.08 + seed * 0.04 }
        return task.agent == CodingProvider.codex.title ? 0.52 + seed * 0.14 : 0.72 + seed * 0.16
    }
    /// Pairs of shown participants with unresolved overlaps, keyed "a|b", and how many.
    static func links(_ board: CollabBoard, nodes: [CollabNode]) -> [(String, Int)] {
        let shown = Set(nodes.map(\.id))
        var counts: [String: Int] = [:]
        for overlap in board.overlaps where !overlap.resolved {
            let ids = overlap.tasks.map(\.id).filter(shown.contains).sorted()
            for i in ids.indices { for j in ids.indices where j > i { counts[ids[i] + "|" + ids[j], default: 0] += 1 } }
        }
        return counts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }
    static func dependencies(_ board: CollabBoard, nodes: [CollabNode]) -> [(String, String)] {
        let shown = Set(nodes.map(\.id))
        return board.tasks.flatMap { task -> [(String, String)] in
            guard shown.contains(task.id), let plan = task.plan else { return [] }
            return (task.dependsOn ?? []).compactMap { dependency in
                board.tasks.first { $0.plan == plan && $0.subtask == dependency && shown.contains($0.id) }.map { ($0.id, task.id) }
            }
        }
    }
    /// The wires drawn: handoffs between tasks, plus a dispatch wire from the first person to each
    /// task that waits on nothing.
    static func wires(_ nodes: [CollabNode], dependencies: [(String, String)]) -> [(String, String)] {
        let waiting = Set(dependencies.map(\.1))
        guard let person = nodes.first(where: \.person) else { return dependencies }
        return nodes.filter { !$0.person && !waiting.contains($0.id) }.map { (person.id, $0.id) } + dependencies
    }
}

// MARK: - Participants and their files

struct CollabParticipants: View {
    let board: CollabBoard
    let palette: DesktopPalette
    @Binding var focus: String?
    var open: (String) -> Void
    var body: some View {
        let shown = board.tasks.filter { $0.state.active && !$0.files.isEmpty }
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Who's touching what").font(.system(size: 13, weight: .medium))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(shown.filter { focus == nil || $0.id == focus }) { task in card(task) }
                }
                if focus != nil { Button("Show everyone") { focus = nil }.buttonStyle(DesktopButtonStyle()) }
            }
        }
    }
    private func card(_ task: CollabTask) -> some View {
        let overlapping = Set(board.overlaps.filter { !$0.resolved && $0.tasks.contains { $0.id == task.id } }.map(\.path))
        return VStack(alignment: .leading, spacing: 6) {
            Button { open(task.id) } label: {
                HStack { Text(task.agent == nil ? task.ownerName + " (by hand)" : task.title).font(.system(size: 12, weight: .medium)).lineLimit(1); Spacer(); Text(task.state.title).font(.system(size: 10)).foregroundStyle(.secondary) }
            }.buttonStyle(.plain)
            ForEach(Self.rows(task), id: \.self) { row in
                HStack(spacing: 6) {
                    Image(systemName: overlapping.contains(row.path) ? "exclamationmark.triangle.fill" : row.claimed ? "flag" : "doc.text")
                        .font(.system(size: 9)).foregroundStyle(overlapping.contains(row.path) ? Color.orange : .secondary).frame(width: 12)
                    Text(row.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head)
                    if !row.symbols.isEmpty { Text(row.symbols).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: 4)
                    if row.added + row.removed > 0 { Text("+\(row.added) −\(row.removed)").font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary) }
                }
            }
        }.padding(12).background(palette.foreground.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    struct Row: Hashable { var path: String; var symbols: String; var added: Int; var removed: Int; var claimed: Bool }
    static func rows(_ task: CollabTask) -> [Row] {
        Dictionary(grouping: task.files, by: \.path).map { path, touches in
            Row(path: path, symbols: touches.compactMap(\.symbol).sorted().joined(separator: ", "), added: touches.reduce(0) { $0 + $1.added },
                removed: touches.reduce(0) { $0 + $1.removed }, claimed: touches.allSatisfy { $0.kind == .claimed })
        }.sorted { ($0.claimed ? 1 : 0, $0.path) < ($1.claimed ? 1 : 0, $1.path) }.prefix(14).map { $0 }
    }
}

// MARK: - Overlaps

struct CollabOverlapList: View {
    let board: CollabBoard
    let project: UUID?
    @Environment(CodingWorkspaceStore.self) private var coding
    @State private var path = ""
    @State private var owner: String?
    @State private var messageTo: UUID?
    @State private var message = ""
    private var orchestrator: CodingOrchestrator { coding.orchestrator }
    var body: some View {
        let open = board.overlaps.filter { !$0.resolved }, resolved = board.overlaps.filter(\.resolved)
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Overlaps").font(.system(size: 13, weight: .medium)); Spacer(); if open.isEmpty { Text("No overlapping work").font(.system(size: 11)).foregroundStyle(.secondary) } }
            ForEach(open) { overlap in row(overlap) }
            if !resolved.isEmpty {
                DisclosureGroup("Settled (\(resolved.count))") {
                    ForEach(resolved) { overlap in
                        HStack { Text(place(overlap)).font(.system(size: 11, design: .monospaced)); Spacer(); Text("owned by " + name(overlap.owner?.task)).font(.system(size: 11)).foregroundStyle(.secondary) }.padding(.vertical, 2)
                    }
                }.font(.system(size: 12))
            }
            assign
            messaging
        }
    }
    private func place(_ overlap: CollabOverlap) -> String { overlap.path + (overlap.symbol.map { " · " + $0 } ?? "") }
    private func name(_ id: String?) -> String { board.tasks.first { $0.id == id }.map { $0.agent == nil ? $0.ownerName : $0.title } ?? "someone" }
    private func row(_ overlap: CollabOverlap) -> some View {
        let tasks = overlap.tasks
        let agents = tasks.filter { UUID(uuidString: $0.id) != nil }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
                Text(place(overlap)).font(.system(size: 12, design: .monospaced))
                Spacer()
                if let suggested = overlap.suggestedOwner { Text("Suggested owner: " + name(suggested.id)).font(.system(size: 11)).foregroundStyle(.secondary) }
            }
            Text(tasks.map { name($0.id) + " (" + ($0.agent ?? "by hand") + ")" }.joined(separator: " and ")).font(.system(size: 11)).foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Menu("Pause") {
                    ForEach(agents.filter { $0.state == .working || $0.state == .needsYou }) { task in Button(task.title) { if let id = UUID(uuidString: task.id) { orchestrator.pause(id) } } }
                }.menuStyle(.button).fixedSize().disabled(!agents.contains { $0.state == .working || $0.state == .needsYou })
                Menu("Hand off to…") {
                    ForEach(tasks) { task in Button(name(task.id)) { if let project { orchestrator.handOff(overlap, to: task, project: project) } } }
                }.menuStyle(.button).fixedSize()
                Menu("Tell…") {
                    ForEach(agents) { target in
                        ForEach(tasks.filter { $0.id != target.id && UUID(uuidString: $0.id) != nil }) { source in
                            Button("Tell “\(target.title)” about “\(source.title)”") {
                                if let to = UUID(uuidString: target.id), let from = UUID(uuidString: source.id) { Task { await orchestrator.tell(to, about: from, path: overlap.path) } }
                            }
                        }
                    }
                }.menuStyle(.button).fixedSize().disabled(agents.count < 2)
            }.font(.system(size: 12))
        }.padding(12).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private var assign: some View {
        let candidates = board.tasks.filter { $0.state.active }
        return DisclosureGroup("Assign an owner") {
            HStack {
                TextField("Relative path, e.g. src/auth.ts", text: $path).textFieldStyle(.roundedBorder)
                Picker("Owner", selection: $owner) {
                    Text("Choose").tag(nil as String?)
                    ForEach(candidates) { task in Text(name(task.id)).tag(Optional(task.id)) }
                }.fixedSize()
                Button("Assign") {
                    if let owner, let project { orchestrator.assignOwner(path.trimmingCharacters(in: .whitespaces), symbol: nil, to: owner, project: project); path = "" }
                }.buttonStyle(DesktopButtonStyle()).disabled(owner == nil || path.isEmpty)
            }.padding(.top, 6)
            Text("Ownership coordinates work; it doesn't lock files. The owner's changes stay; others are asked to leave the file alone when you hand it off.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    private var messaging: some View {
        let agents = coding.forProject(project).filter { $0.status != .done }
        return DisclosureGroup("Message an agent") {
            HStack {
                Picker("To", selection: $messageTo) {
                    Text("Choose").tag(nil as UUID?)
                    ForEach(agents) { task in Text(task.title).tag(Optional(task.id)) }
                }.fixedSize()
                TextField("A note for its next turn", text: $message).textFieldStyle(.roundedBorder).onSubmit(send)
                Button("Send", action: send).buttonStyle(DesktopButtonStyle()).disabled(messageTo == nil || message.trimmingCharacters(in: .whitespaces).isEmpty)
            }.padding(.top, 6)
            Text("It appears in that task's conversation as your message. If the agent is mid-turn, it waits until the turn ends.").font(.system(size: 11)).foregroundStyle(.secondary)
        }.font(.system(size: 12))
    }
    private func send() {
        guard let messageTo else { return }
        orchestrator.message(messageTo, message); message = ""
    }
}

// MARK: - Timeline

struct CollabTimeline: View {
    let entries: [CollabMessage]
    let palette: DesktopPalette
    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Handoffs and messages").font(.system(size: 13, weight: .medium))
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(entries.suffix(60).reversed()) { entry in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: Self.symbol(entry.kind)).font(.system(size: 11)).foregroundStyle(entry.kind == .overlap ? Color.orange : palette.accent).frame(width: 16).padding(.top, 2)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.text).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Text(entry.fromName + " · " + entry.date.formatted(.relative(presentation: .named))).font(.system(size: 10)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 7)
                        Divider().opacity(0.5)
                    }
                }.padding(.horizontal, 14).padding(.vertical, 4)
                    .background(palette.foreground.opacity(0.03), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        }
    }
    static func symbol(_ kind: CollabMessageKind?) -> String {
        switch kind ?? .message {
        case .message: "text.bubble"
        case .handoff: "arrow.right.circle"
        case .overlap: "exclamationmark.triangle"
        case .plan: "square.stack.3d.up"
        case .integration: "arrow.triangle.merge"
        }
    }
}

// MARK: - Plans

struct CollabPlanComposer: View {
    var done: () -> Void
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopProjects.self) private var projects
    @State private var goal = ""
    @State private var lead: CodingProvider = .claude
    @State private var access: CodingAccess = .edit
    @State private var sending = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Plan with agents").font(.system(size: 15, weight: .semibold))
            Text("Give one goal. A lead agent reads the project and proposes subtasks for several agents to run at once, each in its own worktree. You review and edit the plan; nothing starts until you do.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("What should the agents build?", text: $goal, axis: .vertical).lineLimit(3...8).textFieldStyle(.plain).padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            HStack(spacing: 14) {
                Picker("Lead", selection: $lead) { ForEach(CodingAgentRegistry.shared.choices(including: [lead])) { Text($0.title).tag($0) } }.fixedSize()
                Picker("Subtasks may", selection: $access) { ForEach(CodingAccess.allCases.filter { $0 != .readOnly }) { Text($0.title).tag($0) } }.fixedSize()
                Spacer()
                if sending { KemoOrb(size: 18, state: .weaving) }
                Button("Cancel", action: done).buttonStyle(DesktopButtonStyle())
                Button("Ask for a plan") { ask() }.buttonStyle(DesktopButtonStyle(prominent: true))
                    .disabled(sending || goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || projects.selected == nil)
            }.font(.system(size: 12))
            Text("The lead plans with read-only access. \(lead.title) uses its own sign-in; it gets the project and this goal, never your chats or memories.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            if access == .full { Text("Full access lets each subtask's agent run commands with your Mac account's access without asking.").font(.system(size: 11)).foregroundStyle(.orange) }
        }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private func ask() {
        guard let project = projects.projects.first(where: { $0.id == projects.selected }) else { return }
        sending = true
        Task {
            defer { sending = false }
            do {
                let root = try projects.resolve(project.id)
                if await coding.orchestrator.plan(goal: goal, project: project, root: root, lead: lead, access: access) != nil { goal = ""; done() }
            } catch { coding.orchestrator.notice = error.localizedDescription }
        }
    }
}

struct CollabRunCard: View {
    let run: OrchestratorRun
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopNavigation.self) private var desktop
    @State private var draft: OrchestratorPlan?
    private var orchestrator: CodingOrchestrator { coding.orchestrator }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title).font(.system(size: 15, weight: .semibold)).lineLimit(2)
                    Text("\(run.phase.title) · lead \(run.lead.title)").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if orchestrator.working.contains(run.id) { KemoOrb(size: 18, state: .weaving) }
                if run.phase != .integrating { Button("Cancel plan") { orchestrator.cancel(run.id) }.buttonStyle(DesktopButtonStyle()) }
            }
            switch run.phase {
            case .planning: planning
            case .reviewing: editor
            case .running: CollabRunProgress(run: run)
            case .integrating: CollabIntegrationView(run: run)
            case .accepted, .cancelled: EmptyView()
            }
        }.padding(18).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
    private var planning: some View {
        HStack(spacing: 10) {
            KemoOrb(size: 22, state: .weaving)
            Text("\(run.lead.title) is reading the project and proposing a plan.").font(.system(size: 12)).foregroundStyle(.secondary)
            Spacer()
            if let lead = run.leadTask { Button("Open the lead's task") { coding.selected = lead; desktop.tsukumoSurface = "Project" }.buttonStyle(DesktopButtonStyle()) }
        }
    }
    @ViewBuilder private var editor: some View {
        let plan = draft ?? run.plan ?? OrchestratorPlanner.single(goal: run.goal, agent: run.lead)
        let problem: String? = { do { try OrchestratorPlanner.validate(plan); return nil } catch { return (error as? LocalizedError)?.errorDescription } }()
        VStack(alignment: .leading, spacing: 10) {
            if let note = run.planNote { Label(note + " Edit it, add subtasks, or start it as it is.", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(.orange) }
            if !plan.summary.isEmpty { Text(plan.summary).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            ForEach(plan.subtasks.indices, id: \.self) { index in
                CollabSubtaskEditor(subtask: binding(index, plan), others: plan.subtasks.map(\.id).filter { $0 != plan.subtasks[index].id }) { remove(index, plan) }
            }
            HStack {
                Button { add(plan) } label: { Label("Add subtask", systemImage: "plus") }.buttonStyle(DesktopButtonStyle()).disabled(plan.subtasks.count >= OrchestratorPlan.maximumSubtasks)
                Spacer()
                if let problem { Text(problem).font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2) }
                Button("Start \(plan.subtasks.count) agent\(plan.subtasks.count == 1 ? "" : "s")") {
                    orchestrator.updatePlan(run.id, plan)
                    Task { await orchestrator.start(run.id); draft = nil }
                }.buttonStyle(DesktopButtonStyle(prominent: true)).disabled(problem != nil)
            }
            Text("Subtasks without dependencies start together, each in its own worktree from the project's current commit. One that depends on others starts from their results when they finish.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }
    private func binding(_ index: Int, _ plan: OrchestratorPlan) -> Binding<OrchestratorSubtask> {
        Binding(get: { (draft ?? plan).subtasks.indices.contains(index) ? (draft ?? plan).subtasks[index] : plan.subtasks[0] },
                set: { value in var next = draft ?? plan; guard next.subtasks.indices.contains(index) else { return }
                    let old = next.subtasks[index].id
                    next.subtasks[index] = value
                    // Renaming a subtask keeps what depends on it.
                    if old != value.id { for i in next.subtasks.indices { next.subtasks[i].dependsOn = next.subtasks[i].dependsOn.map { $0 == old ? value.id : $0 } } }
                    draft = next; orchestrator.updatePlan(run.id, next) })
    }
    private func add(_ plan: OrchestratorPlan) {
        var next = draft ?? plan
        var n = next.subtasks.count + 1
        while next.subtasks.contains(where: { $0.id == "part-\(n)" }) { n += 1 }
        next.subtasks.append(.init(id: "part-\(n)", title: "New subtask", brief: "Describe what this agent should do.", agent: run.lead))
        draft = next; orchestrator.updatePlan(run.id, next)
    }
    private func remove(_ index: Int, _ plan: OrchestratorPlan) {
        var next = draft ?? plan
        guard next.subtasks.count > 1, next.subtasks.indices.contains(index) else { return }
        let id = next.subtasks.remove(at: index).id
        for i in next.subtasks.indices { next.subtasks[i].dependsOn.removeAll { $0 == id } }
        draft = next; orchestrator.updatePlan(run.id, next)
    }
}

struct CollabSubtaskEditor: View {
    @Binding var subtask: OrchestratorSubtask
    let others: [String]
    var remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("id", text: $subtask.id).textFieldStyle(.roundedBorder).frame(width: 110).font(.system(size: 11, design: .monospaced))
                TextField("Title", text: $subtask.title).textFieldStyle(.roundedBorder)
                Picker("", selection: $subtask.agent) { ForEach(CodingAgentRegistry.shared.choices(including: [subtask.agent])) { Text($0.title).tag($0) } }.labelsHidden().fixedSize()
                Button(action: remove) { Image(systemName: "trash") }.buttonStyle(DesktopRowButtonStyle(inset: 5)).help("Remove this subtask").accessibilityLabel("Remove subtask")
            }
            TextField("Brief", text: $subtask.brief, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).font(.system(size: 12))
            HStack(spacing: 8) {
                TextField("Files it expects to change, separated by commas", text: Binding(get: { subtask.files.joined(separator: ", ") }, set: { subtask.files = $0.split(separator: ",").map { OrchestratorPlanner.normalizedPath(String($0)) }.filter { !$0.isEmpty } }))
                    .textFieldStyle(.roundedBorder).font(.system(size: 11, design: .monospaced))
                Menu(subtask.dependsOn.isEmpty ? "Starts at once" : "After " + subtask.dependsOn.joined(separator: ", ")) {
                    ForEach(others, id: \.self) { other in
                        Button { toggle(other) } label: { if subtask.dependsOn.contains(other) { Label(other, systemImage: "checkmark") } else { Text(other) } }
                    }
                }.menuStyle(.button).fixedSize().disabled(others.isEmpty).font(.system(size: 11))
            }
            if !subtask.areas.isEmpty { Text(subtask.areas.joined(separator: " · ")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }.padding(12).background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func toggle(_ id: String) {
        if subtask.dependsOn.contains(id) { subtask.dependsOn.removeAll { $0 == id } } else { subtask.dependsOn.append(id) }
    }
}

struct CollabRunProgress: View {
    let run: OrchestratorRun
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopNavigation.self) private var desktop
    private var orchestrator: CodingOrchestrator { coding.orchestrator }
    var body: some View {
        let plan = run.plan ?? OrchestratorPlan(summary: "", subtasks: [])
        let states = orchestrator.states(run)
        let blocked = Set(OrchestratorSchedule.blocked(plan.subtasks, states: states))
        VStack(alignment: .leading, spacing: 8) {
            ForEach(OrchestratorSchedule.order(plan.subtasks), id: \.self) { id in
                if let subtask = plan.subtask(id) {
                    let task = coding.task(run.tasks[id])
                    HStack(spacing: 10) {
                        Image(systemName: symbol(states[id] ?? .waiting, blocked: blocked.contains(id))).foregroundStyle(states[id] == .failed || blocked.contains(id) ? Color.orange : .secondary).frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(subtask.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                            Text(detail(subtask, task: task, state: states[id] ?? .waiting, blocked: blocked.contains(id))).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if task?.status.running == true { KemoOrb(size: 16, state: .solving) }
                        if let task {
                            if task.status == .interrupted || task.status == .failed { Button("Mark done") { coding.markDone(task.id) }.buttonStyle(DesktopButtonStyle()) }
                            Button("Open") { coding.selected = task.id; desktop.tsukumoSurface = "Project" }.buttonStyle(DesktopButtonStyle())
                        }
                    }
                }
            }
            HStack {
                Spacer()
                let ready = plan.subtasks.allSatisfy { states[$0.id] == .finished }
                Button("Integrate") { Task { await orchestrator.integrate(run.id) } }.buttonStyle(DesktopButtonStyle(prominent: ready)).disabled(!ready || orchestrator.working.contains(run.id))
                    .help(ready ? "Merge every subtask into an integration branch, in dependency order" : "Available when every subtask has finished")
            }
        }
    }
    private func symbol(_ state: OrchestratorSchedule.State, blocked: Bool) -> String {
        if blocked { return "pause.circle" }
        switch state { case .waiting: return "circle.dotted"; case .running: return "circle.lefthalf.filled"; case .finished: return "checkmark.circle"; case .failed: return "exclamationmark.circle" }
    }
    private func detail(_ subtask: OrchestratorSubtask, task: CodingTaskRecord?, state: OrchestratorSchedule.State, blocked: Bool) -> String {
        let agent = task?.provider.title ?? subtask.agent.title
        if blocked { return agent + " · waiting on a subtask that stopped" }
        switch state {
        case .waiting: return agent + (subtask.dependsOn.isEmpty ? " · starting" : " · after " + subtask.dependsOn.joined(separator: ", "))
        case .running: return agent + " · " + (task?.status.title ?? "Working")
        case .finished: return agent + " · finished" + (task.map { " · \($0.changes.count) file\($0.changes.count == 1 ? "" : "s")" } ?? "")
        case .failed: return agent + " · " + (task?.status.title ?? "Stopped") + ". Send it a message to resume, or mark it done."
        }
    }
}

struct CollabIntegrationView: View {
    let run: OrchestratorRun
    @Environment(CodingWorkspaceStore.self) private var coding
    @Environment(DesktopNavigation.self) private var desktop
    @State private var command = ""
    @State private var review: CodingReview?
    @State private var files: [CodingDiffFile] = []
    @State private var selectedFile: String?
    @State private var confirmAccept = false
    private var orchestrator: CodingOrchestrator { coding.orchestrator }
    var body: some View {
        let integration = run.integration
        let plan = run.plan ?? OrchestratorPlan(summary: "", subtasks: [])
        VStack(alignment: .leading, spacing: 12) {
            if let integration {
                Text("Branch \(integration.branch) · \(integration.merged.count - integration.skipped.count) of \(plan.subtasks.count) merged" + (integration.skipped.isEmpty ? "" : " · \(integration.skipped.count) left out"))
                    .font(.system(size: 11)).foregroundStyle(.secondary).textSelection(.enabled)
                ForEach(OrchestratorSchedule.order(plan.subtasks), id: \.self) { id in
                    HStack(spacing: 8) {
                        Image(systemName: integration.skipped.contains(id) ? "minus.circle" : integration.merged.contains(id) ? "checkmark.circle.fill" : integration.conflict?.subtask == id ? "exclamationmark.triangle.fill" : "circle.dotted")
                            .foregroundStyle(integration.conflict?.subtask == id ? Color.orange : .secondary).frame(width: 16)
                        Text(plan.subtask(id)?.title ?? id).font(.system(size: 12))
                    }
                }
                if let conflict = integration.conflict { conflictBox(conflict, integration: integration) }
                else if integration.merged.count == plan.subtasks.count { tests(integration); reviewSection(integration) }
            } else {
                HStack { KemoOrb(size: 18, state: .weaving); Text("Preparing the integration branch…").font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        }.onAppear { command = orchestrator.testCommand(for: run) }
        .confirmationDialog("Accept the integrated result into \(run.baseBranch ?? "the base branch")?", isPresented: $confirmAccept) {
            Button("Accept") { if let review { Task { await orchestrator.accept(run.id, review: review) } } }
        } message: { Text("The project fast-forwards to exactly the tree you reviewed. The subtasks' worktrees and branches stay as restore points.") }
    }
    private func conflictBox(_ conflict: OrchestratorIntegration.Conflict, integration: OrchestratorIntegration) -> some View {
        let resolving = coding.task(integration.resolveTask)
        return VStack(alignment: .leading, spacing: 8) {
            Label("“\(run.plan?.subtask(conflict.subtask)?.title ?? conflict.subtask)” conflicts with what's merged so far", systemImage: "exclamationmark.triangle.fill").font(.system(size: 12, weight: .medium)).foregroundStyle(.orange)
            Text(conflict.files.joined(separator: "\n")).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
            HStack(spacing: 8) {
                if let resolving {
                    Text(resolving.status.running ? "\(resolving.provider.title) is resolving it." : "The resolution is ready to check.").font(.system(size: 11)).foregroundStyle(.secondary)
                    Button("Open") { coding.selected = resolving.id; desktop.tsukumoSurface = "Project" }.buttonStyle(DesktopButtonStyle())
                    Button("Continue integration") { Task { await orchestrator.continueIntegration(run.id) } }.buttonStyle(DesktopButtonStyle(prominent: true)).disabled(resolving.status.running)
                } else {
                    ForEach(Array(CodingAgentRegistry.shared.choices(including: []).prefix(3))) { agent in
                        Button("Resolve with \(agent.title)") { Task { await orchestrator.resolveConflict(run.id, agent: agent) } }.buttonStyle(DesktopButtonStyle(prominent: agent == .claude))
                    }
                    Button("Try again") { Task { await orchestrator.continueIntegration(run.id) } }.buttonStyle(DesktopButtonStyle())
                }
                Button("Leave it out") { Task { await orchestrator.skipConflict(run.id) } }.buttonStyle(DesktopButtonStyle())
            }.font(.system(size: 12)).disabled(orchestrator.working.contains(run.id))
        }.padding(12).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
    private func tests(_ integration: OrchestratorIntegration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                TextField("Test command (none found; enter one)", text: $command).textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                Button("Run tests") { Task { await orchestrator.runTests(run.id, command: command) } }.buttonStyle(DesktopButtonStyle())
                    .disabled(command.trimmingCharacters(in: .whitespaces).isEmpty || orchestrator.working.contains(run.id))
            }
            if let test = integration.test {
                DisclosureGroup {
                    ScrollView { Text(test.output.isEmpty ? "No output." : test.output).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 180)
                } label: {
                    Label((test.passed ? "Passed: " : "Failed: ") + test.command + (test.tree == nil ? " (files changed while it ran)" : ""), systemImage: test.passed ? "checkmark.seal" : "xmark.seal")
                        .foregroundStyle(test.passed ? Color.green : .orange).font(.system(size: 12))
                }
            }
        }
    }
    private func reviewSection(_ integration: OrchestratorIntegration) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button(review == nil ? "Review changes" : "Review again") { load() }.buttonStyle(DesktopButtonStyle())
                if let review {
                    Text("\(files.count) file\(files.count == 1 ? "" : "s") · +\(files.reduce(0) { $0 + $1.additions }) −\(files.reduce(0) { $0 + $1.deletions })").font(.system(size: 11)).foregroundStyle(.secondary)
                    let tested = integration.test.map { $0.passed && $0.tree == review.tree } ?? false
                    if !tested { Text("Tests haven't passed on this version").font(.system(size: 11)).foregroundStyle(.orange) }
                }
                Spacer()
                Button("Accept into \(run.baseBranch ?? "base")") { confirmAccept = true }.buttonStyle(DesktopButtonStyle(prominent: true)).disabled(review == nil || orchestrator.working.contains(run.id))
            }
            if review != nil {
                HStack(alignment: .top, spacing: 10) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(files) { file in
                                Button { selectedFile = file.path } label: {
                                    HStack { Text(file.path).font(.system(size: 11, design: .monospaced)).lineLimit(1).truncationMode(.head); Spacer(); Text("+\(file.additions) −\(file.deletions)").font(.system(size: 10)).foregroundStyle(.secondary) }
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                }.buttonStyle(DesktopRowButtonStyle(selected: selectedFile == file.path))
                            }
                        }
                    }.frame(width: 260, height: 260)
                    if let file = files.first(where: { $0.path == selectedFile }) ?? files.first { CodingDiffView(file: file, split: false, font: 11).frame(height: 260) }
                }
            }
        }
    }
    private func load() {
        Task {
            do { let next = try await orchestrator.reviewIntegration(run.id); review = next; files = CodingDiff.parse(next.diff); selectedFile = files.first?.path }
            catch { orchestrator.notice = error.localizedDescription }
        }
    }
}
