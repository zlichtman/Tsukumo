import SwiftUI
import TsukumoCore

// The first run, the same on iPhone and Mac: welcome (KemoSabe's cloud and one line), sign in with
// Apple (or go on without an account, which keeps sync off), connect what you use (Apple Intelligence's
// status, Claude or OpenAI keys, KemoSabe's personal sources), and your bots (KemoSabe always, the
// starters, or one of your own). Then the chat. Every step after sign-in can be skipped.

/// A model provider the first run can connect with a key.
public enum OnboardingProvider: String, CaseIterable, Identifiable, Sendable {
    case claude, openAI
    public var id: String { rawValue }
    public var title: String { self == .claude ? "Claude" : "OpenAI" }
    public var mark: EngineInfo.Mark { self == .claude ? .claude : .openAI }
    public var placeholder: String { self == .claude ? "sk-ant-…" : "sk-…" }
}

/// A personal source KemoSabe may read, as the first run shows it.
public struct OnboardingSource: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public var on: Bool
    public var level: PrivacyLevel
    public init(id: String, title: String, symbol: String, on: Bool, level: PrivacyLevel) {
        self.id = id; self.title = title; self.symbol = symbol; self.on = on; self.level = level
    }
}

/// What the first run needs from the app it runs in.
@MainActor public protocol OnboardingHost: AnyObject {
    var accounts: AccountStore { get }
    /// "iPhone" or "Mac".
    var deviceName: String { get }
    /// Sign in with a stand-in (UI tests and screenshots).
    var fixtureSignIn: Bool { get }
    /// Whether Apple's on-device model can run here, and why not in plain words.
    var appleIntelligence: (ready: Bool, text: String) { get }
    /// Whether each provider is connected already.
    func isConnected(_ provider: OnboardingProvider) -> Bool
    /// Checks and saves a key (into this device's Keychain). Throws a message to show.
    func connect(_ provider: OnboardingProvider, key: String) async throws
    var onboardingSources: [OnboardingSource] { get }
    func setSource(_ id: String, on: Bool) async
    func setSource(_ id: String, level: PrivacyLevel) async
    var bots: [BotSpec] { get }
    var engineChoices: [EngineChoice] { get }
    /// Adds a starter, on an engine this device has. Returns the bot.
    func add(starter: StarterBot) -> BotSpec?
    func save(bot: BotSpec)
    func remove(bot id: UUID)
    /// The first run is done: show the chat.
    func finishOnboarding()
}

/// The first run.
public struct OnboardingFlow<Host: OnboardingHost>: View {
    public enum Step: Int, CaseIterable, Sendable { case welcome, signIn, connect, bots }
    let host: Host
    @State private var step: Step
    @State private var problem: String?
    @State private var keys: [OnboardingProvider: String] = [:]
    @State private var connecting: OnboardingProvider?
    @State private var connectProblem: [OnboardingProvider: String] = [:]
    @State private var starters: [String: UUID] = [:]
    @State private var making = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `start` opens at a later step (screenshots).
    public init(host: Host, start: Step = .welcome) {
        self.host = host
        _step = State(initialValue: start)
    }

    private var theme: TsukumoTheme { TsukumoTheme(scheme) }

    public var body: some View {
        VStack(spacing: 0) {
            progress.padding(.top, 14)
            ScrollView {
                VStack(spacing: 22) {
                    switch step {
                    case .welcome: welcome
                    case .signIn: signIn
                    case .connect: connect
                    case .bots: botsStep
                    }
                }
                .frame(maxWidth: 520)
                .padding(.horizontal, 24)
                .padding(.vertical, 22)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            footer
        }
        .background(theme.background.ignoresSafeArea())
        .foregroundStyle(theme.ink)
        .tint(theme.accent)
        .sheet(isPresented: $making) {
            BotEditor(existing: host.bots, engines: host.engineChoices, device: host.deviceName) { bot in
                host.save(bot: bot); making = false
            } onCancel: { making = false }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 560)
            #endif
        }
    }

    // MARK: Progress and the buttons at the bottom

    private var progress: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.self) { each in
                Capsule().fill(each.rawValue <= step.rawValue ? theme.accent : theme.ink.opacity(0.15))
                    .frame(width: each == step ? 22 : 8, height: 8)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    @ViewBuilder private var footer: some View {
        VStack(spacing: 10) {
            switch step {
            case .welcome:
                primary("Get started", id: "onboardingStart") { go(.signIn) }
            case .signIn:
                AppleSignInButton(accounts: host.accounts, fixture: host.fixtureSignIn) { message in
                    problem = message
                    if message == nil && host.accounts.isSignedIn { go(.connect) }
                }
                .frame(maxWidth: 420)
                Button("Continue without an account") { problem = nil; go(.connect) }
                    .font(.body.weight(.medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(theme.secondary)
                    .padding(.vertical, 6)
                    .accessibilityIdentifier("continueWithoutAccount")
            case .connect:
                primary("Continue", id: "connectContinue") { go(.bots) }
                Button("Skip for now") { go(.bots) }
                    .buttonStyle(.plain).foregroundStyle(theme.secondary).padding(.vertical, 4)
                    .accessibilityIdentifier("connectSkip")
            case .bots:
                primary("Start chatting", id: "onboardingFinish") {
                    host.accounts.finishOnboarding()
                    host.finishOnboarding()
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity)
        .background(theme.background)
    }

    private func primary(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: .semibold))
                .frame(maxWidth: 420, minHeight: 50)
                .foregroundStyle(theme.onAccent)
                .background(theme.accent, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(id)
    }

    private func go(_ next: Step) {
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { step = next }
    }

    private func title(_ text: String, _ detail: String) -> some View {
        VStack(spacing: 8) {
            Text(text).font(.system(size: 30, weight: .semibold)).multilineTextAlignment(.center)
            Text(detail).font(.body).foregroundStyle(theme.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(spacing: 18) {
            KemoSabeFigure().frame(width: 200, height: 200).padding(.top, 24)
            TsukumoArt.image(.wordmark).renderingMode(.template).resizable().interpolation(.high).scaledToFit()
                .frame(height: 30)
                .foregroundStyle(theme.ink)
                .accessibilityLabel("Tsukumo")
            Text("All your bots in one chat. KemoSabe keeps what’s personal on this \(host.deviceName) and shares only the answers you allow.")
                .font(.title3).multilineTextAlignment(.center).foregroundStyle(theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingWelcome")
    }

    // MARK: Sign in

    private var signIn: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.checkmark").font(.system(size: 54, weight: .light)).foregroundStyle(theme.accent)
                .padding(.top, 30)
            title("Make it yours", "Sign in with Apple to keep your bots and chats in step on your iPhone and Mac, through your own iCloud.")
            VStack(alignment: .leading, spacing: 10) {
                point("lock", "Your chats sync through your own private iCloud, encrypted. API keys and what KemoSabe reads never do.")
                point("iphone.and.arrow.forward", "Without an account, everything stays on this \(host.deviceName). You can sign in later in Settings.")
            }
            .padding(14)
            .background(theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if let problem {
                // Sign in's note (a build without the capability) is calm; a key that didn't work is a warning.
                Text(problem).font(.footnote).foregroundStyle(step == .signIn ? theme.secondary : Color.orange).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier("signInProblem")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingSignIn")
    }

    private func point(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(theme.accent).frame(width: 22)
            Text(text).font(.subheadline).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Connect

    private var connect: some View {
        VStack(alignment: .leading, spacing: 20) {
            title("Connect what you use", "All optional. You can change any of it later in Settings.").frame(maxWidth: .infinity)
            card("Apple Intelligence") {
                let status = host.appleIntelligence
                HStack(alignment: .top, spacing: 12) {
                    EngineMarkView(.apple, size: 24)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(status.ready ? "Ready" : "Not ready").font(.body.weight(.semibold))
                        Text(status.ready ? "KemoSabe runs on Apple’s model on this \(host.deviceName). Nothing it reads leaves it." : status.text)
                            .font(.footnote).foregroundStyle(status.ready ? theme.secondary : .orange).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("onboardingAppleIntelligence")
            }
            card("Models with your key") {
                ForEach(OnboardingProvider.allCases) { provider in providerRow(provider) }
                Text("Keys stay in this \(host.deviceName)’s Keychain. They never sync.").font(.footnote).foregroundStyle(theme.secondary)
            }
            if !host.onboardingSources.isEmpty {
                card("What KemoSabe may read") {
                    ForEach(host.onboardingSources) { source in sourceRow(source) }
                    Text("KemoSabe reads on this \(host.deviceName) and shares only the answer, with bots you allow. Sensitive items ask you each time.")
                        .font(.footnote).foregroundStyle(theme.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingConnect")
    }

    private func card(_ heading: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading).font(.footnote.weight(.semibold)).foregroundStyle(theme.secondary).textCase(.uppercase)
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(theme.hairline))
    }

    @ViewBuilder private func providerRow(_ provider: OnboardingProvider) -> some View {
        let connected = host.isConnected(provider)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                EngineMarkView(provider.mark, size: 24)
                Text(provider.title).font(.body.weight(.semibold))
                Spacer()
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill").font(.footnote.weight(.medium)).foregroundStyle(.green)
                        .accessibilityIdentifier("connected-" + provider.rawValue)
                }
            }
            if !connected {
                HStack(spacing: 8) {
                    SecureField(provider.placeholder, text: Binding(get: { keys[provider] ?? "" }, set: { keys[provider] = $0 }))
                        .textFieldStyle(.roundedBorder)
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("connectKey-" + provider.rawValue)
                    Button(connecting == provider ? "Checking…" : "Add") { Task { await add(provider) } }
                        .disabled(connecting != nil || (keys[provider] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("connectAdd-" + provider.rawValue)
                }
                if let message = connectProblem[provider] {
                    Text(message).font(.footnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func add(_ provider: OnboardingProvider) async {
        connecting = provider
        defer { connecting = nil }
        do {
            try await host.connect(provider, key: (keys[provider] ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            keys[provider] = nil
            connectProblem[provider] = nil
        } catch {
            connectProblem[provider] = error.localizedDescription
        }
    }

    private func sourceRow(_ source: OnboardingSource) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: Binding(get: { source.on }, set: { on in Task { await host.setSource(source.id, on: on) } })) {
                Label(source.title, systemImage: source.symbol)
            }
            .accessibilityIdentifier("onboardingSource-" + source.id)
            if source.on {
                Picker("How private", selection: Binding(get: { source.level }, set: { level in Task { await host.setSource(source.id, level: level) } })) {
                    ForEach([PrivacyLevel.personal, .sensitive, .deviceOnly]) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(source.level.detail).font(.caption).foregroundStyle(theme.secondary)
            }
        }
    }

    // MARK: Your bots

    private var botsStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Your bots", "KemoSabe is always here. Add a starter or two, or make your own. You can change everything about them later.")
                .frame(maxWidth: .infinity)
            if let kemoSabe = host.bots.first(where: \.isKemoSabe) {
                botCard(kemoSabe, subtitle: "Always here. Answers your other bots’ questions about you, on this \(host.deviceName).", selected: true, locked: true)
                    .accessibilityIdentifier("onboardingKemoSabe")
            }
            ForEach(StarterBot.all) { starter in
                let added = starters[starter.title].flatMap { id in host.bots.first { $0.id == id } }
                Button { toggle(starter) } label: {
                    botCard(added ?? BotSpec(name: starter.name, engine: starter.engine, role: starter.role, look: starter.look),
                            subtitle: starter.role, selected: added != nil, locked: false)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(added != nil ? .isSelected : [])
                .accessibilityIdentifier("starter-" + starter.title)
            }
            ForEach(host.bots.filter { bot in !bot.isKemoSabe && !starters.values.contains(bot.id) }) { bot in
                botCard(bot, subtitle: bot.role.isEmpty ? "Your own bot" : bot.role, selected: true, locked: false)
            }
            Button { making = true } label: {
                Label("Make your own", systemImage: "plus").font(.body.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 46)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(theme.accent.opacity(0.6), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4])))
            }
            .buttonStyle(.plain)
            .foregroundStyle(theme.accent)
            .accessibilityIdentifier("onboardingMakeBot")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingBots")
    }

    private func toggle(_ starter: StarterBot) {
        if let id = starters[starter.title] {
            host.remove(bot: id)
            starters[starter.title] = nil
        } else if let bot = host.add(starter: starter) {
            starters[starter.title] = bot.id
        }
    }

    private func botCard(_ bot: BotSpec, subtitle: String, selected: Bool, locked: Bool) -> some View {
        HStack(spacing: 14) {
            if bot.isKemoSabe {
                BotAvatar(bot: bot, size: 48)
            } else {
                ClayCharacter(look: bot.look, shadow: false).frame(width: 52, height: 52)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(bot.name).font(.body.weight(.semibold))
                Text(subtitle).font(.footnote).foregroundStyle(theme.secondary).lineLimit(2)
            }
            Spacer(minLength: 8)
            Image(systemName: locked ? "lock.fill" : selected ? "checkmark.circle.fill" : "plus.circle")
                .font(.system(size: 22)).foregroundStyle(selected ? theme.accent : theme.secondary)
        }
        .padding(12)
        .background(selected ? theme.accent.opacity(0.08) : theme.fill, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(selected ? theme.accent.opacity(0.45) : theme.hairline))
        .contentShape(Rectangle())
    }
}
