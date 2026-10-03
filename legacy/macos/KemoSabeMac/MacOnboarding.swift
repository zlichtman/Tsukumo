import AppKit
import AuthenticationServices
import SwiftUI

/// Tsukumo's onboarding steps, in order: the same welcome, account, and companion as iPhone, then
/// what Tsukumo needs (coding agents, a project, the quick terminal).
enum MacOnboardingStep: String, CaseIterable {
    case welcome, account, companion, setup
    static var all: [String] { allCases.map(\.rawValue) }
}

extension OnboardingFlow {
    var macStep: MacOnboardingStep? { current.flatMap(MacOnboardingStep.init(rawValue:)) }
}

/// What a Mac already has from before onboarding existed, besides the account's settings and chats:
/// a main window that has been open before (AppKit saved its frame), projects, or coding tasks.
enum MacOnboardingEvidence {
    static let windowFrameKey = "NSWindow Frame KemoSabe.MainWindow"
    static func earlierUse(device: UserDefaults, projects: Int, tasks: Int) -> Bool {
        device.object(forKey: windowFrameKey) != nil || projects > 0 || tasks > 0
    }
}

/// Onboarding in the main window's content area (never a separate window), in one centered column.
struct DesktopOnboardingView: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        let palette = preferences.palette(scheme)
        VStack(spacing: 0) {
            // The traffic lights' row stays clear; the step dots sit just below it.
            MacOnboardingDots(step: flow.macStep ?? .welcome, accent: palette.accent).padding(.top, 44)
            Group {
                switch flow.macStep {
                case .welcome: MacOnboardingWelcome()
                case .account: MacOnboardingAccount()
                case .companion: MacOnboardingCompanion()
                case .setup: MacOnboardingSetup()
                case nil: EmptyView()
                }
            }
            .id(flow.current)
            .transition(.opacity)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: flow.current)
        .background(palette.background)
    }
}

private struct MacOnboardingDots: View {
    let step: MacOnboardingStep
    let accent: Color
    var body: some View {
        let index = MacOnboardingStep.allCases.firstIndex(of: step) ?? 0
        HStack(spacing: 6) {
            ForEach(Array(MacOnboardingStep.allCases.enumerated()), id: \.offset) { offset, _ in
                Capsule().fill(offset == index ? accent : Color.primary.opacity(0.16)).frame(width: offset == index ? 18 : 6, height: 6)
            }
        }.accessibilityElement(children: .ignore).accessibilityLabel("Step \(index + 1) of \(MacOnboardingStep.allCases.count)")
    }
}

/// One step: a scrolling column at most 520 pt wide, centered in the window, with its actions under it.
private struct MacOnboardingPage<Content: View, Actions: View>: View {
    var width: CGFloat = 520
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 18) {
                    content
                    VStack(spacing: 10) { actions }.padding(.top, 10)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: width).padding(.horizontal, 32).padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }.scrollBounceBehavior(.basedOnSize)
        }
    }
}

/// The main action, in the accent color, as the composer's send button is.
private struct MacOnboardingPrimary: View {
    let title: String
    let identifier: String
    let action: () -> Void
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                .frame(minWidth: 220).padding(.vertical, 9)
                .background(preferences.palette(scheme).accent, in: Capsule())
                .contentShape(Capsule())
        }.buttonStyle(.plain).keyboardShortcut(.defaultAction).accessibilityIdentifier(identifier)
    }
}

private struct MacOnboardingTitle: View {
    let text: String
    var body: some View {
        Text(text).font(.system(size: 26, weight: .semibold)).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
    }
}

// MARK: Welcome

/// Tsukumo's logo and KemoSabe, and one line on what they are.
private struct MacOnboardingWelcome: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(AppStore.self) private var store
    var body: some View {
        MacOnboardingPage {
            // The bundled logo, unchanged, on a dark plate so its cream lettering reads in light mode too.
            Group {
                if let url = Bundle.main.url(forResource: "Tsukumo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
                    Image(nsImage: logo).resizable().scaledToFit()
                } else {
                    TsukumoMark(size: 96)
                }
            }
            .frame(width: 380, height: 190)
            .background(Color(red: 0.09, green: 0.075, blue: 0.12), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .accessibilityLabel("Tsukumo").accessibilityIdentifier("onboardingLogo")
            HStack(spacing: 8) {
                CompanionAvatar(theme: store.state.theme, size: 26)
                Text("with KemoSabe").font(.system(size: 15, weight: .medium)).foregroundStyle(.secondary)
            }
            Text("Build with coding agents in one place: tasks as chats, a terminal, and agents working together. KemoSabe, your personal companion, lives here too.")
                .font(.system(size: 15)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } actions: {
            MacOnboardingPrimary(title: "Continue", identifier: "onboardingContinue") { flow.advance() }
        }
    }
}

// MARK: Account

/// The same Apple Account as the iPhone, or a local account that links later.
private struct MacOnboardingAccount: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var session = AppleAccountSession.shared
    private var linked: Bool { session.status == .linked }
    var body: some View {
        MacOnboardingPage {
            HStack(spacing: 16) {
                ForEach(["iphone", "laptopcomputer", "applewatch"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 28)).foregroundStyle(preferences.palette(scheme).accent)
                }
            }.accessibilityHidden(true)
            MacOnboardingTitle(text: "Sign in with the same Apple Account as your iPhone")
            Text("It's one KemoSabe account for iPhone, Mac, and Apple Watch: your name, your companion, and your profile. Tsukumo gets a private ID from Apple, never your password.")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if linked {
                VStack(spacing: 4) {
                    Label("Linked to your KemoSabe account", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold)).foregroundStyle(preferences.palette(scheme).accent)
                        .accessibilityIdentifier("onboardingLinked")
                    if !AccountStore.shared.displayName.isEmpty {
                        Text(AccountStore.shared.displayName).font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    if AccountSyncService.availableInBuild {
                        Label("Syncing with your iCloud", systemImage: "icloud").font(.system(size: 12)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("onboardingSync")
                    }
                }
            }
            if let notice = session.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if linked {
                MacOnboardingPrimary(title: "Continue", identifier: "onboardingContinue") { flow.advance() }
            } else {
                if AppleAccountSession.availableInBuild {
                    SignInWithAppleButton(.signIn, onRequest: session.prepare, onCompletion: { session.handle($0, account: AccountStore.shared) })
                        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                        .frame(width: 260, height: 36).accessibilityIdentifier("onboardingSignInWithApple")
                    if session.status == .finishingSignIn {
                        HStack {
                            Button("Try again") { session.retrySwitch() }
                            Button("Restart \(KemoSabeMacApp.appName)") { DesktopSettingsView.relaunch() }
                        }.buttonStyle(DesktopButtonStyle())
                    }
                } else {
                    Text("Sign in with Apple arrives in a coming build. You can link this Mac then, in Settings → Account.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                // An account is required; only builds without Sign in with Apple and UI tests go on locally.
                if !AppleAccountSession.accountRequired {
                    Button("Continue without an account") { flow.advance() }
                        .buttonStyle(DesktopButtonStyle()).accessibilityIdentifier("onboardingLocal")
                }
            }
        }
        .onAppear { session.refresh() }
    }
}

// MARK: Companion

/// The companion's intro chat (`CompanionIntro`), the same conversation as on iPhone; or, when the
/// account already has a named companion, a short confirmation.
private struct MacOnboardingCompanion: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(AppStore.self) private var store
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(CompanionIntro.stepKey, store: AccountDirectory.accountSettings) private var introStep = ""
    @AppStorage(CompanionIdentity.key, store: AccountDirectory.accountSettings) private var companionName = CompanionIdentity.defaultName
    /// Set when this step found the companion already named, so it confirms rather than asks.
    @State private var alreadyNamed = false
    @State private var reply = ""
    @FocusState private var focused: Bool
    var body: some View {
        Group {
            if alreadyNamed { confirmation } else { intro }
        }
        .onAppear {
            guard CompanionIntro.step == nil else { return }
            if CompanionIdentity.needsNaming { store.beginCompanionIntro() } else { alreadyNamed = true }
        }
    }
    private var confirmation: some View {
        MacOnboardingPage {
            ArtworkCompanion(theme: store.state.theme, performance: "greeting", reducedMotion: reduceMotion, active: true)
                .frame(width: 180, height: 180).accessibilityHidden(true)
            MacOnboardingTitle(text: "Your companion is already named \(CompanionIdentity.name)")
                .accessibilityIdentifier("onboardingAlreadyNamed")
            Text("Your companion comes with your account: the same name, look, and personality on every device. Change them any time in Settings → Companion.")
                .font(.system(size: 14)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } actions: {
            MacOnboardingPrimary(title: "Continue", identifier: "onboardingContinue") { flow.advance() }
        }
    }
    private var intro: some View {
        let step = CompanionIntro.Step(rawValue: introStep)
        return VStack(spacing: 12) {
            ArtworkCompanion(theme: store.state.theme, performance: step == nil ? "greeting" : "idle", reducedMotion: reduceMotion, active: true)
                .frame(height: 150).accessibilityHidden(true)
            // The same conversation as KemoSabe's chat; it stays there afterwards.
            ChatTranscript { answer($0) }.frame(maxWidth: 560, maxHeight: .infinity)
            VStack(spacing: 10) {
                if let step {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(CompanionIntro.choices(for: step), id: \.self) { choice in
                                Button(choice) { answer(choice) }.buttonStyle(DesktopButtonStyle()).accessibilityIdentifier("introChoice-" + choice)
                            }
                        }.padding(.horizontal, 2)
                    }
                    HStack(spacing: 8) {
                        TextField(step == .name ? "Name your companion" : "Type an answer", text: $reply)
                            .textFieldStyle(.plain).focused($focused).onSubmit { answer(reply) }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(preferences.palette(scheme).sidebar, in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.75))
                            .accessibilityIdentifier("onboardingIntroInput")
                        Button { answer(reply) } label: {
                            Image(systemName: "arrow.up").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                                .frame(width: 32, height: 32).background(preferences.palette(scheme).accent, in: Circle())
                        }.buttonStyle(.plain).disabled(reply.trimmingCharacters(in: .whitespaces).isEmpty)
                            .accessibilityLabel("Send").accessibilityIdentifier("onboardingIntroSend")
                    }
                    Button("Skip for now") { skip() }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
                        .accessibilityIdentifier("onboardingIntroSkip")
                } else {
                    MacOnboardingPrimary(title: "Continue", identifier: "onboardingContinue") { flow.advance() }
                }
            }.frame(maxWidth: 560)
        }
        .padding(.horizontal, 32).padding(.bottom, 24)
        .onAppear { focused = true }
    }
    private func answer(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        reply = ""
        store.answerCompanionIntro(text)
    }
    /// Keeps the current name, look, and tone; they can be changed later in Settings → Companion.
    private func skip() {
        CompanionIdentity.set(CompanionIdentity.name)
        CompanionIntro.step = nil
        flow.advance()
    }
}

// MARK: Tsukumo setup

/// Coding agents (their own sign-in, never typed here), a project folder, and the quick terminal.
private struct MacOnboardingSetup: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(DesktopProjects.self) private var projects
    @State private var sessions = TerminalSessions.shared
    @State private var terminal = TerminalPreferences.shared
    @State private var hotkeyProblem: String?
    /// Claude Code and Codex, the agents Tsukumo starts tasks with.
    private var agents: [CodingAgentCommand] { CodingAgentCommand.known.filter { ["claude", "codex"].contains($0.id) } }
    var body: some View {
        MacOnboardingPage(width: 620) {
            MacOnboardingTitle(text: "Set up Tsukumo")
            Text("Everything here is optional, and it's all in Settings later.")
                .font(.system(size: 14)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 18) {
                SettingsCard(title: "Coding agents") {
                    ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                        if index > 0 { Divider() }
                        let found = sessions.installed.contains(agent.command)
                        SettingsRow(title: agent.name, detail: !sessions.checkedAgents ? "Looking on this Mac…"
                                    : found ? "Installed. Sign in with your subscription in its own sign-in, which opens in Terminal."
                                    : "Not found on this Mac. Once you install it, it shows up in Settings → Agents.") {
                            if found {
                                Button("Sign in") { AgentSignIn.open(agent) }.buttonStyle(DesktopButtonStyle())
                                    .accessibilityIdentifier("onboardingSignIn-" + agent.id)
                            } else if !sessions.checkedAgents {
                                KemoOrb(size: 18, state: .searching)
                            } else {
                                Text("Not found").foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                SettingsCard(title: "Project") {
                    SettingsRow(title: projects.projects.isEmpty ? "Add a project folder" : projects.projects.map(\.name).joined(separator: ", "),
                                detail: "Tsukumo works in folders on this Mac. Adding one doesn't share its files with a model or agent until you start a task in it.") {
                        Button(projects.projects.isEmpty ? "Add folder…" : "Add another…") { projects.choose() }
                            .buttonStyle(DesktopButtonStyle()).accessibilityIdentifier("onboardingAddProject")
                    }
                }
                SettingsCard(title: "Quick terminal") {
                    SettingsRow(title: "Quick terminal", detail: hotkeyProblem ?? "A terminal drops down from the top of the screen with this shortcut, from any app.") {
                        HStack(spacing: 10) {
                            KeyCaps(keys: TerminalHotkey(terminal.quickHotkey)?.keyCaps ?? [terminal.quickHotkey])
                            Toggle("Quick terminal", isOn: Binding(get: { terminal.quickTerminal }, set: { terminal.quickTerminal = $0; hotkeyProblem = QuickTerminal.shared.reload() }))
                                .labelsHidden().toggleStyle(.switch).accessibilityIdentifier("onboardingQuickTerminal")
                        }
                    }
                }
            }.multilineTextAlignment(.leading)
        } actions: {
            MacOnboardingPrimary(title: "Done", identifier: "onboardingDone") { flow.finish() }
        }
        .onAppear { sessions.checkAgents() }
    }
}

// MARK: Sign in

/// Fills the window whenever there's no account on this Mac (right after signing out, say):
/// Tsukumo's logo and Sign in with Apple. Everything runs through the account.
struct MacSignInGate: View {
    @Environment(DesktopPreferences.self) private var preferences
    @Environment(\.colorScheme) private var scheme
    @State private var session = AppleAccountSession.shared
    var body: some View {
        MacOnboardingPage(width: 420) {
            Group {
                if let url = Bundle.main.url(forResource: "Tsukumo", withExtension: "png"), let logo = NSImage(contentsOf: url) {
                    Image(nsImage: logo).resizable().scaledToFit()
                } else {
                    TsukumoMark(size: 80)
                }
            }
            .frame(width: 300, height: 150)
            .background(Color(red: 0.09, green: 0.075, blue: 0.12), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .accessibilityLabel("Tsukumo")
            MacOnboardingTitle(text: "Sign in to continue")
            Text("One account for your iPhone, Mac, and Apple Watch.").font(.system(size: 14)).foregroundStyle(.secondary)
            if let notice = session.notice {
                Text(notice).font(.system(size: 12)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            SignInWithAppleButton(.signIn, onRequest: session.prepare, onCompletion: { session.handle($0, account: AccountStore.shared) })
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(width: 260, height: 36).accessibilityIdentifier("gateSignInWithApple")
            if session.status == .finishingSignIn {
                Button("Try again") { session.retrySwitch() }.buttonStyle(DesktopButtonStyle())
            }
        }
        .background(preferences.palette(scheme).background)
        .onAppear { session.refresh() }
        .accessibilityIdentifier("signInGate")
    }
}
