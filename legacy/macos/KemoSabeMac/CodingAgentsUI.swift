import SwiftUI
import AppKit

// The agent chooser in the composer, Run with…, and Settings → Coding → Agents: every built-in
// and added agent with its mark, whether it's installed, and whether you're signed in.

/// A snapshot of one agent for the choosers and Settings.
struct CodingAgentRowInfo: Identifiable, Equatable {
    var provider: CodingProvider
    var title: String
    var mark: CodingAgentMark
    var transport: CodingAgentTransport
    var installed: Bool
    var signIn: CodingAgentSignInState
    var installLink: URL?
    var installNote: String
    var signInCommand: String?
    var custom: CodingCustomAgent?
    var grant: CodingAccess
    var id: CodingProvider { provider }
    /// "Signed in · Muse Session Protocol", or why it can't run.
    var status: String { installed ? signIn.title + " · " + transport.title : "Not installed" }
}
extension CodingAgentRegistry {
    func rows() -> [CodingAgentRowInfo] {
        return adapters.map { adapter in
            .init(provider: adapter.provider, title: adapter.title, mark: adapter.mark, transport: adapter.transport,
                  installed: installed[adapter.provider] != nil, signIn: signIn(adapter.provider), installLink: adapter.installLink,
                  installNote: adapter.installNote, signInCommand: adapter.signInCommand, custom: (adapter as? CustomACPAdapter)?.agent,
                  grant: grant(for: adapter.provider))
        }
    }
}

/// An agent's logo: its symbol for the built-ins, its initials otherwise, on its own color.
struct CodingAgentBadge: View {
    let mark: CodingAgentMark
    var size: CGFloat = 22
    var dimmed = false
    var body: some View {
        if let logo = mark.logo {
            Image(logo).resizable().interpolation(.high).scaledToFit()
                .foregroundStyle(mark.logoTint ?? Color.primary)
                .padding(size * 0.08)
                .frame(width: size, height: size).opacity(dimmed ? 0.4 : 1).accessibilityHidden(true)
        } else { badge }
    }
    private var badge: some View {
        ZStack {
            Circle().fill(Color(hue: mark.hue, saturation: 0.5, brightness: 0.78).opacity(dimmed ? 0.35 : 1))
            if let symbol = mark.symbol {
                Image(systemName: symbol).font(.system(size: size * 0.48, weight: .semibold)).foregroundStyle(.white)
            } else {
                Text(mark.initials).font(.system(size: size * (mark.initials.count > 1 ? 0.38 : 0.5), weight: .bold, design: .rounded)).foregroundStyle(.white)
            }
        }.frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// The composer's agent chooser: every agent, installed ones selectable, with sign-in state.
struct CodingAgentChooser: View {
    let rows: [CodingAgentRowInfo]
    let selection: CodingProvider
    var choose: (CodingProvider) -> Void
    var addAgent: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Agent").font(.system(size: 13, weight: .semibold)).padding(.horizontal, 8).padding(.bottom, 4)
            ForEach(rows) { row in
                Button { if row.installed { choose(row.provider) } } label: {
                    HStack(spacing: 10) {
                        CodingAgentBadge(mark: row.mark, size: 26, dimmed: !row.installed)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.title).font(.system(size: 12.5, weight: .medium)).foregroundStyle(row.installed ? .primary : .secondary)
                            Text(row.status).font(.system(size: 10.5)).foregroundStyle(row.installed && row.signIn == .signedOut ? Color.orange : Color.secondary)
                        }
                        Spacer(minLength: 8)
                        if row.provider == selection { Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)) }
                        else if !row.installed, let link = row.installLink {
                            Link("Install", destination: link).font(.system(size: 11)).help(row.installNote)
                        }
                    }.padding(.horizontal, 8).padding(.vertical, 6).contentShape(Rectangle())
                }.buttonStyle(DesktopRowButtonStyle(selected: row.provider == selection)).disabled(!row.installed && row.installLink == nil)
                    .accessibilityLabel(row.title + ", " + row.status)
            }
            Divider().padding(.vertical, 4)
            Button { addAgent() } label: { Label("Add agent…", systemImage: "plus").font(.system(size: 12)).padding(.horizontal, 8).padding(.vertical, 4) }
                .buttonStyle(DesktopRowButtonStyle())
        }.padding(10).frame(width: 330)
    }
}

/// Run with…: the same prompt to two or three chosen agents, compared side by side.
struct CodingRunWithPicker: View {
    let rows: [CodingAgentRowInfo]
    @State var chosen: [CodingProvider]
    var start: ([CodingProvider]) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Run with…").font(.system(size: 13, weight: .semibold))
            Text("Each agent gets this prompt in its own worktree. Compare shows what each changed.").font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 2) {
                ForEach(rows.filter(\.installed)) { row in
                    let on = chosen.contains(row.provider)
                    Button {
                        if on { chosen.removeAll { $0 == row.provider } } else if chosen.count < CodingWorkspaceStore.maximumCompared { chosen.append(row.provider) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: on ? "checkmark.circle.fill" : "circle").foregroundStyle(on ? Color.accentColor : Color.secondary)
                            CodingAgentBadge(mark: row.mark, size: 22)
                            Text(row.title).font(.system(size: 12.5))
                            Spacer()
                            if row.signIn == .signedOut { Text("Not signed in").font(.system(size: 10.5)).foregroundStyle(.orange) }
                        }.padding(.horizontal, 6).padding(.vertical, 5).contentShape(Rectangle())
                    }.buttonStyle(DesktopRowButtonStyle(selected: on)).disabled(!on && chosen.count >= CodingWorkspaceStore.maximumCompared)
                }
            }
            HStack {
                Text(chosen.count < 2 ? "Choose two or three" : "\(chosen.count) agents").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Start") { start(chosen) }.buttonStyle(DesktopButtonStyle(prominent: true)).disabled(!(2...CodingWorkspaceStore.maximumCompared).contains(chosen.count))
                    .keyboardShortcut(.defaultAction)
            }
        }.padding(14).frame(width: 330)
    }
}

// MARK: Settings → Coding → Agents

/// Settings → Agents: every coding agent Tsukumo can run, how it connects, sign-in, its own
/// grant (highest access), and Add agent… for any ACP agent.
struct CodingAgentsPage: View {
    @Environment(DesktopNavigation.self) private var desktop
    @State private var registry = CodingAgentRegistry.shared
    @State private var editing: CodingCustomAgent?
    var body: some View {
        SettingsContent {
            CodingAgentsPageContent(rows: registry.rows(),
                                    signIn: { row in if let command = row.signInCommand { AgentSignIn.openInTsukumo(command, name: row.title, desktop: desktop) } },
                                    setGrant: { registry.setGrant($1, for: $0.provider) },
                                    edit: { editing = $0 }, remove: { registry.remove($0) },
                                    add: { editing = CodingCustomAgent(name: "", command: "") })
            MacSpacesBridgeCard()
        }
        .sheet(item: $editing) { agent in CodingAddAgentSheet(agent: agent, isNew: !registry.custom.contains { $0.id == agent.id }) { registry.save($0) } }
        .onAppear { registry.refresh() }
        .task { await registry.checkSignIn() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await registry.checkSignIn() } }
    }
}
struct CodingAgentsPageContent: View {
    let rows: [CodingAgentRowInfo]
    var signIn: (CodingAgentRowInfo) -> Void
    var setGrant: (CodingAgentRowInfo, CodingAccess) -> Void
    var edit: (CodingCustomAgent) -> Void
    var remove: (CodingCustomAgent) -> Void
    var add: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard(title: "Coding agents") {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    agentRow(row)
                }
            }
            HStack {
                Button("Add agent…", action: add).buttonStyle(DesktopButtonStyle()).accessibilityIdentifier("addCodingAgent")
                Text("Any agent that speaks the Agent Client Protocol: give its command and arguments.").font(.caption).foregroundStyle(.secondary)
            }
            Text("Claude Pro and Max, and ChatGPT Plus and Pro, sign in inside Claude Code and Codex; Muse Code signs in with your Meta developer account. Those subscriptions can't be used for KemoSabe's own chat; connect Claude or OpenAI with an API key in Models for that.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SettingsCard(title: "How agents run") {
                SettingsRow(title: "With your logins, outside the sandbox", detail: "Each agent runs in the task's folder with your PATH and its own sign-in. Tsukumo never installs an agent or signs in for you.") { Image(systemName: "terminal").foregroundStyle(.secondary) }
                Divider()
                SettingsRow(title: "Structured sessions", detail: "Claude Code (stream JSON), Codex (app server), Muse Code (Muse Session Protocol), and Cursor Agent and added agents (Agent Client Protocol v1): live progress, approvals, and diffs, with a worktree per task.") { Image(systemName: "checkmark.circle").foregroundStyle(.secondary) }
                Divider()
                SettingsRow(title: "Each agent is its own recipient", detail: "An agent gets the task's folder and your message, never your chats, memories, or keys. An added agent sees only the environment variables you list, and no agent goes past its highest access.") { Image(systemName: "lock.shield").foregroundStyle(.secondary) }
            }
        }
    }
    private func agentRow(_ row: CodingAgentRowInfo) -> some View {
        HStack(alignment: .center, spacing: 12) {
            CodingAgentBadge(mark: row.mark, size: 30, dimmed: !row.installed)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.title).font(.system(size: 13, weight: .medium))
                Text(row.installed ? row.status : row.installNote).font(.system(size: 11))
                    .foregroundStyle(row.installed && row.signIn == .signedOut ? Color.orange : Color.secondary).fixedSize(horizontal: false, vertical: true)
                if let custom = row.custom {
                    Text(([custom.command] + custom.arguments).joined(separator: " ")).font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Menu {
                ForEach(CodingAccess.allCases) { access in
                    Button { setGrant(row, access) } label: { if access == row.grant { Label(access.title, systemImage: "checkmark") } else { Text(access.title) } }
                }
            } label: { Text("Up to " + row.grant.title).font(.system(size: 11.5)) }
                .menuStyle(.button).buttonStyle(.plain).fixedSize().help("The most this agent may do in any task")
            if row.installed, row.signIn == .signedIn {
                // Signed in: a quiet check, and switching accounts behind a menu instead of a button.
                Menu {
                    if row.signInCommand != nil { Button("Sign in to another account…") { signIn(row) } }
                } label: { Label("Signed in", systemImage: "checkmark.circle.fill").font(.system(size: 11.5)).labelStyle(.titleAndIcon) }
                    .menuStyle(.button).buttonStyle(.plain).fixedSize().foregroundStyle(.secondary)
                    .accessibilityIdentifier("signedIn-" + row.provider.rawValue)
            } else if row.installed, row.signInCommand != nil {
                Button("Sign in") { signIn(row) }.buttonStyle(DesktopButtonStyle()).accessibilityIdentifier("signIn-" + row.provider.rawValue)
                    .help("Opens a Tsukumo terminal tab running `\(row.signInCommand ?? "")`, where you sign in yourself")
            } else if !row.installed, let link = row.installLink {
                Link("Install…", destination: link).font(.system(size: 12)).help(row.installNote)
            }
            if let custom = row.custom {
                Button("Edit") { edit(custom) }.buttonStyle(DesktopButtonStyle())
                Button { remove(custom) } label: { Image(systemName: "trash") }.buttonStyle(DesktopRowButtonStyle(inset: 5)).accessibilityLabel("Remove \(row.title)")
            }
        }.padding(.vertical, 11)
    }
}

/// Add agent… / Edit: a name, a command, its arguments, the environment variables it may see,
/// an optional sign-in command, and Test connection (ACP `initialize` only; no session, no prompt).
struct CodingAddAgentSheet: View {
    @State var agent: CodingCustomAgent
    let isNew: Bool
    var save: (CodingCustomAgent) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var arguments = ""
    @State private var environment = ""
    @State private var signIn = ""
    @State private var testing = false
    @State private var result = ""
    @State private var failed = false
    init(agent: CodingCustomAgent, isNew: Bool, save: @escaping (CodingCustomAgent) -> Void) {
        _agent = State(initialValue: agent); self.isNew = isNew; self.save = save
        _arguments = State(initialValue: CodingAgentArguments.join(agent.arguments))
        _environment = State(initialValue: agent.environment.joined(separator: ", "))
        _signIn = State(initialValue: agent.signIn ?? "")
    }
    private var draft: CodingCustomAgent {
        var draft = agent
        draft.arguments = CodingAgentArguments.split(arguments)
        draft.environment = environment.split(whereSeparator: { $0 == "," || $0.isWhitespace }).map(String.init)
        draft.signIn = signIn.trimmingCharacters(in: .whitespaces).isEmpty ? nil : signIn.trimmingCharacters(in: .whitespaces)
        return draft
    }
    private var valid: Bool { !agent.name.trimmingCharacters(in: .whitespaces).isEmpty && !agent.command.trimmingCharacters(in: .whitespaces).isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(isNew ? "Add agent" : "Edit agent").font(.system(size: 15, weight: .semibold))
            Text("Any agent that speaks the Agent Client Protocol over stdio, such as Gemini CLI (`gemini --experimental-acp`), OpenCode (`opencode acp`), or Goose (`goose acp`).")
                .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $agent.name, prompt: Text("Gemini CLI"))
                TextField("Command", text: $agent.command, prompt: Text("gemini")).font(.system(size: 12, design: .monospaced))
                TextField("Arguments", text: $arguments, prompt: Text("--experimental-acp")).font(.system(size: 12, design: .monospaced))
                TextField("Environment it may see", text: $environment, prompt: Text("GEMINI_API_KEY, GOOGLE_CLOUD_PROJECT"))
                TextField("Sign-in command (optional)", text: $signIn, prompt: Text("gemini")).font(.system(size: 12, design: .monospaced))
            }.formStyle(.grouped).frame(minHeight: 230)
            Text("Besides the names listed, it sees only PATH, HOME, USER, SHELL, LANG, and TMPDIR. Values stay in your environment; Tsukumo never stores them.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !result.isEmpty {
                Label(result, systemImage: failed ? "xmark.octagon" : "checkmark.circle").font(.system(size: 11.5)).foregroundStyle(failed ? Color.red : Color.green)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button { test() } label: { HStack(spacing: 6) { if testing { KemoOrb(size: 14, state: .connecting) }; Text("Test connection") } }
                    .buttonStyle(DesktopButtonStyle()).disabled(!valid || testing)
                Spacer()
                Button("Cancel") { dismiss() }.buttonStyle(DesktopButtonStyle())
                Button(isNew ? "Add" : "Save") { save(draft); dismiss() }.buttonStyle(DesktopButtonStyle(prominent: true)).disabled(!valid).keyboardShortcut(.defaultAction)
            }
        }.padding(20).frame(width: 520)
    }
    private func test() {
        testing = true; result = ""
        let draft = draft
        let launch = CodingACPLaunch(command: draft.command, arguments: draft.arguments, environment: .allowList(draft.environment), name: draft.name)
        Task {
            let outcome = await CodingACPConnectionTest(launch: launch).run()
            testing = false
            switch outcome {
            case .success(let answer): failed = false; result = answer.summary
            case .failure(let error): failed = true; result = error.localizedDescription
            }
        }
    }
}

/// Arguments typed as one line: split on spaces, with quotes grouping.
enum CodingAgentArguments {
    static func split(_ line: String) -> [String] {
        var words: [String] = [], current = "", quote: Character?, started = false
        for character in line {
            if let open = quote {
                if character == open { quote = nil } else { current.append(character) }
            } else if character == "\"" || character == "'" { quote = character; started = true }
            else if character.isWhitespace { if started || !current.isEmpty { words.append(current); current = ""; started = false } }
            else { current.append(character); started = true }
        }
        if started || !current.isEmpty { words.append(current) }
        return words
    }
    static func join(_ words: [String]) -> String { words.map(CodingACP.shellQuote).joined(separator: " ") }
}

extension AgentSignIn {
    /// Opens a Tsukumo terminal tab running the agent's own sign-in, and shows it. The person
    /// signs in themselves; Tsukumo never sees the account or its tokens.
    @MainActor static func openInTsukumo(_ command: String, name: String, desktop: DesktopNavigation) {
        TerminalWorkspace.main.openTab(agent: CodingAgentCommand(id: "sign-in", name: name + " sign-in", command: command))
        desktop.settingsPage = nil; desktop.page = "Tsukumo"; desktop.tsukumoSurface = "Terminal"
    }
}
