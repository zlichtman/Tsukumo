import SwiftUI

/// A new Tsukumo chat's empty state, on KemoSabe's center line: your Kemo at its workstation (the
/// same companion, in your palette, playing the coding performance, the way Codex shows its mascot at
/// a terminal), a greeting, and a few ways to start that fill in the composer (nothing is sent until
/// you send it). The orb stays the loading signal inside a running conversation.
struct CodingNewChatGreeting: View {
    let provider: CodingProvider
    let project: String?
    let creating: Bool
    /// The page's height, which puts Kemo exactly where a new KemoSabe chat's is (`NewChatMetrics`).
    var pageHeight: CGFloat = 0
    @Environment(AppStore.self) private var store
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        // The same layout as a new KemoSabe chat: Kemo the same size, in the same place, above the title.
        NewChatLayout(title: "What should we build?",
                      subtitle: project.map { "\(provider.title) in \($0)" } ?? "Choose a project in the composer to start.",
                      subtitleFont: preferences.font(content: true), topInset: NewChatMetrics.topInset(pageHeight: pageHeight)) {
            ArtworkCompanion(theme: store.state.theme, performance: creating ? "executing" : "coding", reducedMotion: reduceMotion, active: true)
                .accessibilityHidden(true).accessibilityIdentifier("tsukumoKemoAtWork")
        } suggestions: {
            suggestion("Explain this codebase", icon: "text.magnifyingglass", message: "Give me a tour of this codebase: what it does, how it's organized, and where to start reading.")
            suggestion("Find and fix a bug", icon: "ladybug", message: "Find the most likely bug in ")
            suggestion("Write tests for recent changes", icon: "checkmark.seal", message: "Write tests for the most recent changes in this project, then run them.")
        }
    }
    private func suggestion(_ title: String, icon: String, message: String) -> some View {
        Button {
            CodingComposerDrafts.shared.drafts[CodingComposerDrafts.key(nil), default: .init()].text = message
            CodingChatCommands.shared.focusComposer()
        } label: {
            HStack(spacing: 12) {
                Image(systemName: icon).foregroundStyle(preferences.palette(scheme).accent).frame(width: 22)
                Text(title).font(KemoType.font(.callout)); Spacer(); Image(systemName: "arrow.up.left").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 16).padding(.vertical, 14)
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.primary.opacity(0.06)))
                .contentShape(RoundedRectangle(cornerRadius: 16))
        }.buttonStyle(.plain).frame(maxWidth: 380)
    }
}

/// What the agent is doing now, for the orb at the end of the conversation: its orb state and a
/// short label, from the latest thing it reported.
enum CodingActivity {
    /// What Kemo acts out at its workstation above the task's conversation: the coding performances
    /// while the agent works, a finish when it's ready for review, and idle otherwise.
    static func performance(_ task: CodingTaskRecord) -> String {
        let performance: ArtworkPerformance
        switch task.status {
        case .preparing: performance = .executing
        case .needsInput: performance = .waiting
        case .working:
            let last = task.events.last(where: { $0.kind != .system && $0.kind != .approval })
            switch last?.kind {
            case .command?, .check?:
                let card = CodingToolCard(last!)
                if card.check || card.title.contains(" test") { performance = .testing }
                else if card.shell { performance = .executing }
                else if ["Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "webSearch"].contains(card.tool) { performance = .research }
                else { performance = .coding }
            case .plan?: performance = .reviewing
            default: performance = .coding
            }
        case .review, .done: performance = .done
        case .failed: performance = .problem
        case .ready, .interrupted: performance = .idle
        }
        return performance.rawValue
    }
    static func current(_ task: CodingTaskRecord) -> (state: OrbState, label: String) {
        if task.status == .preparing { return (.connecting, task.isolated ? "Making a worktree…" : "Starting…") }
        if task.status == .needsInput { return (.breathing, "Waiting for your answer") }
        guard let last = task.events.last(where: { $0.kind != .system && $0.kind != .approval }) else { return (.connecting, "Starting \(task.provider.title)…") }
        switch last.kind {
        case .user: return (.breathing, "Thinking…")
        case .reasoning: return (.breathing, "Thinking…")
        case .assistant: return (.composing, "Writing…")
        case .file: return (.shaping, "Editing " + (CodingDiff.parse(last.detail).first?.path ?? last.text) + "…")
        case .plan: return (.weaving, "Planning…")
        case .command, .check:
            let card = CodingToolCard(last)
            guard card.running else { return (.weaving, "Working…") }
            if card.shell { return (.working, "Running " + String(card.title.prefix(60)) + "…") }
            if ["Read", "Grep", "Glob", "LS", "WebSearch", "WebFetch", "webSearch"].contains(card.tool) { return (.searching, card.title + "…") }
            return (.working, card.title + "…")
        default: return (.weaving, "Working…")
        }
    }
}
