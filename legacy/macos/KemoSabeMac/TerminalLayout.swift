import Foundation
import CoreGraphics

// The pure parts of Tsukumo's terminal layout: tabs, each a tree of split panes, with the focus and
// the working folder of every pane. Kept apart from the views so it can be tested and saved.

/// Side by side (split right, a vertical divider) or stacked (split down, a horizontal divider).
enum TerminalSplitAxis: String, Codable, Equatable {
    case sideBySide, stacked
}

/// Where focus moves with ⌘⌥ and an arrow.
enum TerminalDirection: CaseIterable {
    case left, right, up, down
}

/// One tab's panes: a leaf is a pane; a split holds two subtrees and the share of the first.
indirect enum TerminalSplit: Codable, Equatable {
    case pane(UUID)
    case split(TerminalSplitAxis, ratio: Double, first: TerminalSplit, second: TerminalSplit)

    static let minimumRatio = 0.1

    /// The panes in reading order (left to right, top to bottom).
    var paneIDs: [UUID] {
        switch self {
        case .pane(let id): [id]
        case .split(_, _, let first, let second): first.paneIDs + second.paneIDs
        }
    }
    func contains(_ id: UUID) -> Bool { paneIDs.contains(id) }

    /// Replaces `pane` with a split of it and `newPane` (after it, to the right or below).
    func splitting(_ pane: UUID, axis: TerminalSplitAxis, newPane: UUID) -> TerminalSplit {
        switch self {
        case .pane(let id):
            return id == pane ? .split(axis, ratio: 0.5, first: .pane(id), second: .pane(newPane)) : self
        case .split(let a, let ratio, let first, let second):
            return .split(a, ratio: ratio, first: first.splitting(pane, axis: axis, newPane: newPane), second: second.splitting(pane, axis: axis, newPane: newPane))
        }
    }
    /// The tree without `pane`: its sibling takes the parent split's place. Nil when it was the only pane.
    func removing(_ pane: UUID) -> TerminalSplit? {
        switch self {
        case .pane(let id): return id == pane ? nil : self
        case .split(let axis, let ratio, let first, let second):
            let a = first.removing(pane), b = second.removing(pane)
            switch (a, b) {
            case (nil, nil): return nil
            case (let only?, nil), (nil, let only?): return only
            case (let a?, let b?): return .split(axis, ratio: ratio, first: a, second: b)
            }
        }
    }
    /// Sets the share of the split at `path` (0 = first child, 1 = second, from the root).
    func settingRatio(_ ratio: Double, at path: [Int]) -> TerminalSplit {
        guard case .split(let axis, let old, let first, let second) = self else { return self }
        guard let step = path.first else {
            return .split(axis, ratio: min(1 - Self.minimumRatio, max(Self.minimumRatio, ratio)), first: first, second: second)
        }
        let rest = Array(path.dropFirst())
        return step == 0 ? .split(axis, ratio: old, first: first.settingRatio(ratio, at: rest), second: second)
                         : .split(axis, ratio: old, first: first, second: second.settingRatio(ratio, at: rest))
    }
    /// Every split back to an even share.
    var equalized: TerminalSplit {
        switch self {
        case .pane: self
        case .split(let axis, _, let first, let second): .split(axis, ratio: 0.5, first: first.equalized, second: second.equalized)
        }
    }
    /// Each pane's frame within `rect` (dividers are drawn by the views, not counted here).
    func frames(in rect: CGRect) -> [UUID: CGRect] {
        switch self {
        case .pane(let id): return [id: rect]
        case .split(let axis, let ratio, let first, let second):
            var a = rect, b = rect
            if axis == .sideBySide {
                a.size.width = rect.width * ratio; b.origin.x = a.maxX; b.size.width = rect.width - a.width
            } else {
                a.size.height = rect.height * ratio; b.origin.y = a.maxY; b.size.height = rect.height - a.height
            }
            return first.frames(in: a).merging(second.frames(in: b)) { x, _ in x }
        }
    }
    /// The pane next to `pane` in a direction: the nearest one that overlaps it across that
    /// direction, preferring the most overlap. Y grows downward (up means a smaller y).
    func neighbor(of pane: UUID, _ direction: TerminalDirection) -> UUID? {
        let frames = frames(in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let from = frames[pane] else { return nil }
        let epsilon = 1e-9
        var best: (id: UUID, distance: Double, overlap: Double)?
        // In reading order, so a tie (two panes overlapping equally) goes to the top or left one.
        for id in paneIDs where id != pane {
            guard let frame = frames[id] else { continue }
            let distance: Double, overlap: Double
            switch direction {
            case .left:
                guard frame.maxX <= from.minX + epsilon else { continue }
                distance = from.minX - frame.maxX; overlap = min(from.maxY, frame.maxY) - max(from.minY, frame.minY)
            case .right:
                guard frame.minX >= from.maxX - epsilon else { continue }
                distance = frame.minX - from.maxX; overlap = min(from.maxY, frame.maxY) - max(from.minY, frame.minY)
            case .up:
                guard frame.maxY <= from.minY + epsilon else { continue }
                distance = from.minY - frame.maxY; overlap = min(from.maxX, frame.maxX) - max(from.minX, frame.minX)
            case .down:
                guard frame.minY >= from.maxY - epsilon else { continue }
                distance = frame.minY - from.maxY; overlap = min(from.maxX, frame.maxX) - max(from.minX, frame.minX)
            }
            guard overlap > epsilon else { continue }
            if let current = best, current.distance < distance - epsilon || (abs(current.distance - distance) <= epsilon && current.overlap >= overlap) { continue }
            best = (id, distance, overlap)
        }
        return best?.id
    }
}

/// What a pane runs and where. The folder follows the shell (OSC 7), so a restored layout reopens
/// each pane where it was. A command (an agent or a profile's command) is typed at the first prompt
/// once; a restored pane starts its shell only, so nothing runs again without being asked.
struct TerminalPaneSpec: Codable, Equatable, Identifiable {
    var id = UUID()
    var directory: String
    var profileID: UUID?
    var command: String?
    /// The agent's name for a pane started from the agent menu, used as its title until the program sets one.
    var label: String?
}

struct TerminalTab: Codable, Equatable, Identifiable {
    var id = UUID()
    /// Set when the person renames the tab; otherwise the title follows the focused pane.
    var customTitle: String?
    var root: TerminalSplit
    var focused: UUID
    var panes: [TerminalPaneSpec]

    init(pane: TerminalPaneSpec) {
        root = .pane(pane.id); focused = pane.id; panes = [pane]
    }
    func pane(_ id: UUID) -> TerminalPaneSpec? { panes.first { $0.id == id } }
    var focusedPane: TerminalPaneSpec? { pane(focused) }
}

/// The tabs of one terminal surface (the Terminal page, the quick terminal, or a project's panel)
/// and which is selected. All changes go through these methods so the tree, the pane list, and the
/// focus never disagree.
struct TerminalLayout: Codable, Equatable {
    var tabs: [TerminalTab] = []
    var selected: UUID?

    var selectedTab: TerminalTab? { tabs.first { $0.id == selected } ?? tabs.last }
    var selectedIndex: Int? { tabs.firstIndex { $0.id == selectedTab?.id } }
    var allPanes: [TerminalPaneSpec] { tabs.flatMap(\.panes) }
    func tab(containing pane: UUID) -> Int? { tabs.firstIndex { $0.root.contains(pane) } }

    @discardableResult mutating func newTab(_ pane: TerminalPaneSpec, after index: Int? = nil) -> TerminalTab {
        let tab = TerminalTab(pane: pane)
        if let index, tabs.indices.contains(index) { tabs.insert(tab, at: index + 1) } else { tabs.append(tab) }
        selected = tab.id
        return tab
    }
    /// Splits the focused pane of the selected tab; the new pane takes focus.
    @discardableResult mutating func split(_ axis: TerminalSplitAxis, with pane: TerminalPaneSpec) -> Bool {
        guard let index = selectedIndex else { return false }
        let focused = tabs[index].focused
        tabs[index].root = tabs[index].root.splitting(focused, axis: axis, newPane: pane.id)
        tabs[index].panes.append(pane)
        tabs[index].focused = pane.id
        return true
    }
    /// Closes one pane. The last pane closes its tab. Returns the closed pane's IDs (for ending processes).
    @discardableResult mutating func closePane(_ id: UUID) -> [UUID] {
        guard let index = tab(containing: id) else { return [] }
        guard let root = tabs[index].root.removing(id) else { return closeTab(tabs[index].id) }
        let order = tabs[index].root.paneIDs
        tabs[index].root = root
        tabs[index].panes.removeAll { $0.id == id }
        if tabs[index].focused == id {
            // Focus moves to the pane before the closed one, as in Ghostty and iTerm.
            let position = order.firstIndex(of: id) ?? 0
            let remaining = root.paneIDs
            tabs[index].focused = remaining[max(0, min(remaining.count - 1, position - 1))]
        }
        return [id]
    }
    @discardableResult mutating func closeTab(_ id: UUID) -> [UUID] {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return [] }
        let closed = tabs[index].root.paneIDs
        tabs.remove(at: index)
        if selected == id || !tabs.contains(where: { $0.id == selected }) {
            selected = tabs.isEmpty ? nil : tabs[max(0, min(tabs.count - 1, index - 1))].id
        }
        return closed
    }
    mutating func moveTab(from source: Int, to destination: Int) {
        guard tabs.indices.contains(source), destination >= 0, destination <= tabs.count, source != destination else { return }
        let tab = tabs.remove(at: source)
        tabs.insert(tab, at: destination > source ? destination - 1 : destination)
    }
    /// A blank name goes back to the automatic title.
    mutating func rename(_ id: UUID, _ title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tabs[index].customTitle = trimmed.isEmpty ? nil : String(trimmed.prefix(60))
    }
    mutating func focus(_ pane: UUID) {
        guard let index = tab(containing: pane) else { return }
        tabs[index].focused = pane
        selected = tabs[index].id
    }
    /// Moves focus to the neighboring pane. False when there's none that way.
    @discardableResult mutating func moveFocus(_ direction: TerminalDirection) -> Bool {
        guard let index = selectedIndex, let next = tabs[index].root.neighbor(of: tabs[index].focused, direction) else { return false }
        tabs[index].focused = next
        return true
    }
    mutating func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selected = tabs[index].id
    }
    /// The next or previous tab, wrapping around.
    mutating func cycleTab(_ step: Int) {
        guard let index = selectedIndex, !tabs.isEmpty else { return }
        selected = tabs[(index + step % tabs.count + tabs.count) % tabs.count].id
    }
    mutating func setRatio(_ ratio: Double, at path: [Int], in tab: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        tabs[index].root = tabs[index].root.settingRatio(ratio, at: path)
    }
    mutating func equalize(_ tab: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tab }) else { return }
        tabs[index].root = tabs[index].root.equalized
    }
    /// Records where a pane's shell is now (from OSC 7), so a restored layout reopens there.
    mutating func updateDirectory(_ pane: UUID, _ directory: String) {
        guard let index = tab(containing: pane), let p = tabs[index].panes.firstIndex(where: { $0.id == pane }), tabs[index].panes[p].directory != directory else { return }
        tabs[index].panes[p].directory = directory
    }

    /// The layout as it's saved for the next launch: commands aren't kept (a restored pane starts its
    /// shell only), and a folder that no longer exists falls back to the home folder.
    func forRestore(home: String, exists: (String) -> Bool) -> TerminalLayout {
        var copy = self
        for t in copy.tabs.indices {
            for p in copy.tabs[t].panes.indices {
                copy.tabs[t].panes[p].command = nil
                if !exists(copy.tabs[t].panes[p].directory) { copy.tabs[t].panes[p].directory = home }
            }
            // Repair a tree and pane list that disagree (an older or damaged save).
            let ids = Set(copy.tabs[t].root.paneIDs)
            copy.tabs[t].panes.removeAll { !ids.contains($0.id) }
            if !ids.contains(copy.tabs[t].focused), let first = copy.tabs[t].root.paneIDs.first { copy.tabs[t].focused = first }
        }
        copy.tabs.removeAll { tab in tab.panes.count != Set(tab.root.paneIDs).count }
        if !copy.tabs.contains(where: { $0.id == copy.selected }) { copy.selected = copy.tabs.last?.id }
        return copy
    }
}

/// A tab's automatic title: the running command while one runs (or what the program calls itself),
/// otherwise the shell's folder, like Ghostty and iTerm with shell integration.
enum TerminalTitle {
    static func make(custom: String?, command: String?, programTitle: String?, directory: String?, label: String?, home: String) -> String {
        if let custom, !custom.isEmpty { return custom }
        if let command {
            if let programTitle, !programTitle.isEmpty { return String(programTitle.prefix(60)) }
            return String(command.trimmingCharacters(in: .whitespaces).prefix(60))
        }
        if let label, !label.isEmpty, programTitle == nil { return label }
        if let directory, !directory.isEmpty { return folderName(directory, home: home) }
        if let programTitle, !programTitle.isEmpty { return String(programTitle.prefix(60)) }
        return "Terminal"
    }
    /// "~" for the home folder, "/" for the root, and the folder's own name otherwise.
    static func folderName(_ path: String, home: String) -> String {
        let trimmed = path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
        if trimmed == home { return "~" }
        if trimmed == "/" { return "/" }
        return (trimmed as NSString).lastPathComponent
    }
}
