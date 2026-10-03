import SwiftUI
import AppKit

/// How you answer an agent's request.
enum CodingApprovalDecision: Equatable {
    case allowOnce
    /// Codex `acceptForSession`; Claude Code rules added with destination `session`.
    case allowSession
    /// With an optional note the agent reads (Claude Code's deny message; a Codex steer).
    case deny(note: String)
    var allows: Bool { if case .deny = self { false } else { true } }
    var note: String { if case .deny(let note) = self { note.trimmingCharacters(in: .whitespacesAndNewlines) } else { "" } }
    var summary: String {
        switch self { case .allowOnce: "Allowed once"; case .allowSession: "Allowed for this session"; case .deny: "Denied" }
    }
}

/// Whether a request could destroy work or reach beyond the task. A risky request has no default
/// key: Return doesn't allow it, "Allow for this session" isn't offered, and the popup says why.
struct CodingApprovalRisk: Equatable {
    var dangerous: Bool
    var reason: String
    static let safe = CodingApprovalRisk(dangerous: false, reason: "")
    static func assess(command: String?, kind: CodingApproval.Kind) -> Self {
        guard kind == .command, let command else { return .safe }
        let text = " " + command.lowercased().replacingOccurrences(of: "\n", with: " ; ") + " "
        func has(_ pattern: String) -> Bool { text.range(of: pattern, options: .regularExpression) != nil }
        let checks: [(String, String)] = [
            (#"\brm\s+(-[a-z]*r[a-z]*f|-[a-z]*f[a-z]*r|-r\b.*-f\b|-f\b.*-r\b|--recursive)"#, "deletes files recursively"),
            (#"\bsudo\b"#, "runs as administrator"),
            (#"\bgit\s+push\b"#, "pushes to a remote"),
            (#"\bgit\s+(reset\s+--hard|clean\s+-[a-z]*f|checkout\s+--\s|restore\s|branch\s+-d|stash\s+(drop|clear)|filter-branch|rebase\b)"#, "can discard Git work"),
            (#"(curl|wget)\b[^|;]*\|\s*(sudo\s+)?(sh|bash|zsh|python3?)\b"#, "runs a script from the internet"),
            (#"\b(mkfs|diskutil\s+(erase|partition)|dd\s+if=)"#, "writes to a disk"),
            (#"\bchmod\s+-r|\bchown\s+-r"#, "changes permissions recursively"),
            (#"\b(launchctl|defaults\s+write|csrutil|spctl|systemsetup)\b"#, "changes system settings"),
            (#"\b(npm|yarn|pnpm|cargo|gem|twine|pod\s+trunk)\s+publish\b|\bgh\s+(release|pr\s+merge|repo\s+delete)"#, "publishes or changes something online"),
            (#"\bkill(all)?\s+-9\b|\bpkill\b"#, "stops other processes"),
            (#">\s*/dev/|\s~/?\.(ssh|aws|zshrc|bashrc|gitconfig)|\.ssh/|keychain"#, "touches your system files or credentials"),
            (#"\bdrop\s+(table|database)\b|\btruncate\s+table\b"#, "deletes database data"),
        ]
        for (pattern, reason) in checks where has(pattern) { return .init(dangerous: true, reason: "This command " + reason + ".") }
        return .safe
    }
}

/// The agent's request as a popup over the composer, like Claude Code's permission prompt: what it
/// wants (the command, or the files with the diff), then 1 Allow once, 2 Allow for this session,
/// 3 Deny (with an optional note). Return allows once and Esc denies, except that a risky command
/// has no default: it needs 1 or a click. The buttons arm half a second after the popup appears,
/// so a click meant for something else can't answer it.
struct CodingApprovalPopup: View {
    let task: CodingTaskRecord
    let approval: CodingApproval
    @Environment(CodingWorkspaceStore.self) private var coding
    @State private var answer = ""
    @State private var note = ""
    @State private var noting = false
    @State private var armed = false
    @State private var details = false
    @FocusState private var focused: Bool
    private var risk: CodingApprovalRisk { approval.risk }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            if approval.kind == .question { questions } else { request }
            if !risk.reason.isEmpty {
                Label(risk.reason + " Read it before allowing.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11.5, weight: .medium)).foregroundStyle(.orange)
            }
            if noting {
                TextField("Tell \(task.provider.title) what to do instead (optional)", text: $note).textFieldStyle(.roundedBorder).focused($focused)
                    .onSubmit { decide(.deny(note: note)) }
            }
            choices
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(risk.dangerous ? Color.orange.opacity(0.6) : Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.22), radius: 18, y: 6)
        .focusable().focused($focused).focusEffectDisabled()
        .onKeyPress(characters: CharacterSet(charactersIn: "123")) { press in
            guard armed, !noting, approval.kind != .question else { return .ignored }
            switch press.characters {
            case "1": decide(.allowOnce)
            case "2": if !risk.dangerous { decide(.allowSession) }
            default: noting = true; focused = true
            }
            return .handled
        }
        .onKeyPress(.return) {
            guard armed, !noting, approval.kind != .question, !risk.dangerous else { return .ignored }
            decide(.allowOnce); return .handled
        }
        .onKeyPress(.escape) {
            guard armed else { return .ignored }
            decide(.deny(note: note)); return .handled
        }
        .task(id: approval.id) {
            armed = false; noting = false; note = ""; answer = ""
            focused = true
            try? await Task.sleep(for: .milliseconds(500))
            armed = true
        }
        .accessibilityElement(children: .contain).accessibilityLabel("\(task.provider.title) asks for permission")
    }
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: approval.kind == .question ? "questionmark.bubble.fill" : approval.kind == .files ? "doc.badge.gearshape.fill" : "terminal.fill")
                .foregroundStyle(risk.dangerous ? Color.orange : Color.accentColor)
            Text(approval.kind == .question ? "\(task.provider.title) has a question" : approval.kind == .files ? "\(task.provider.title) wants to edit \(approval.title)" : "\(task.provider.title) wants to run a command")
                .font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
            Spacer()
            if approval.pending > 1 { Text("1 of \(approval.pending)").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
            Button(details ? "Hide details" : "Details") { details.toggle() }.buttonStyle(DesktopRowButtonStyle(inset: 4)).font(.system(size: 11))
        }
    }
    @ViewBuilder private var request: some View {
        if approval.kind == .command {
            ScrollView {
                Text(approval.command ?? approval.title).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 120).fixedSize(horizontal: false, vertical: true)
                .padding(9).background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        } else if !approval.diff.isEmpty {
            CodingApprovalDiff(diff: approval.diff)
        }
        if details { ScrollView { Text(approval.detail).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 120) }
    }
    @ViewBuilder private var questions: some View {
        ForEach(approval.questions, id: \.id) { question in Text(question.text).font(.system(size: 13)) }
        TextField("Your answer", text: $answer).textFieldStyle(.roundedBorder)
    }
    @ViewBuilder private var choices: some View {
        if approval.kind == .question {
            HStack {
                Spacer()
                Button("Decline") { decide(.deny(note: "")) }
                Button("Send answer") { decide(.allowOnce) }.buttonStyle(.borderedProminent)
                    .disabled(!armed || answer.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } else {
            HStack(spacing: 6) {
                choice("1", "Allow once", prominent: !risk.dangerous) { decide(.allowOnce) }
                if !risk.dangerous { choice("2", "Allow for this session", prominent: false) { decide(.allowSession) } }
                choice("3", noting ? "Deny with note" : "Deny…", prominent: false) { if noting { decide(.deny(note: note)) } else { noting = true; focused = true } }
                Spacer()
                if noting { Button("Deny without note") { decide(.deny(note: "")) }.buttonStyle(DesktopRowButtonStyle(inset: 5)).font(.system(size: 11)) }
            }
            Text(risk.dangerous ? "Press 1 or click to allow. Esc denies." : "Return allows once · Esc denies · 1, 2, 3 choose").font(.system(size: 10.5)).foregroundStyle(.tertiary)
        }
    }
    private func choice(_ key: String, _ title: String, prominent: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(key).font(.system(size: 10.5, weight: .semibold, design: .monospaced)).frame(width: 16, height: 16)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(title).font(.system(size: 12, weight: .medium))
            }.padding(.horizontal, 10).padding(.vertical, 6)
                .foregroundStyle(prominent ? Color.white : Color.primary)
                .background(prominent ? Color.accentColor : Color.primary.opacity(0.07), in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).disabled(!armed).opacity(armed ? 1 : 0.5)
    }
    private func decide(_ decision: CodingApprovalDecision) {
        guard armed else { return }
        armed = false
        coding.respond(task.id, decision: decision, answer: answer)
        noting = false; note = ""; answer = ""
    }
}

/// The diff of a proposed edit, up to 40 lines.
private struct CodingApprovalDiff: View {
    let diff: String
    @Environment(DesktopPreferences.self) private var preferences
    var body: some View {
        let lines = CodingDiff.parse(diff).flatMap { file in file.hunks.flatMap(\.lines) }
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(40).enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 6) {
                        Text(line.kind == .added ? "+" : line.kind == .removed ? "−" : " ").foregroundStyle(line.kind == .added ? .green : line.kind == .removed ? .red : .secondary).frame(width: 10)
                        Text(line.text.isEmpty ? " " : line.text).lineLimit(1)
                    }
                    .font(.system(size: max(10, preferences.codeFontSize - 1), design: .monospaced))
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(line.kind == .added ? Color.green.opacity(0.1) : line.kind == .removed ? Color.red.opacity(0.1) : .clear)
                }
                if lines.count > 40 { Text("\(lines.count - 40) more lines").font(.system(size: 11)).foregroundStyle(.secondary).padding(8) }
            }.padding(.vertical, 4)
        }.frame(maxHeight: 220).fixedSize(horizontal: false, vertical: true)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
}
