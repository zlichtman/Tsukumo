import AuthenticationServices
import AVFoundation
import Contacts
import EventKit
import SwiftUI
import UserNotifications

/// The iPhone's onboarding steps, in order. The companion step hands off to the intro chat
/// (`CompanionIntro`), which runs in Chat itself; the others cover the app.
enum PhoneOnboardingStep: String, CaseIterable {
    case welcome, account, companion, permissions
    static var all: [String] { allCases.map(\.rawValue) }
}

extension OnboardingFlow {
    var phoneStep: PhoneOnboardingStep? { current.flatMap(PhoneOnboardingStep.init(rawValue:)) }
    /// Whether the full-screen pages show (every step but the intro chat).
    var coversPhone: Bool { phoneStep.map { $0 != .companion } ?? false }
}

/// The pages of the iPhone's onboarding, over the app: welcome, one account, and the optional
/// permissions after the companion's intro. Themed like the rest of the app and laid out for every
/// iPhone size (it scrolls when the text is large or the screen is small).
struct PhoneOnboardingView: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.mobilePalette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            Group {
                switch flow.phoneStep {
                case .welcome: OnboardingWelcomePage()
                case .account: OnboardingAccountPage()
                case .permissions: OnboardingPermissionsPage()
                case .companion, nil: EmptyView()
                }
            }
            .id(flow.current)
            .transition(reduceMotion ? .opacity : .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity), removal: .opacity))
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: flow.current)
    }
}

/// One onboarding page: a scrolling column (at most 440 pt wide) with its actions pinned to the bottom.
private struct OnboardingPage<Content: View, Actions: View>: View {
    /// The step for the dots; nil for the sign-in screen, which isn't part of the steps.
    let step: PhoneOnboardingStep?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: 22) { content }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
                    .padding(.horizontal, 28).padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }.scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .top) { if let step { OnboardingDots(step: step).padding(.top, 8) } }
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) { actions }
                .frame(maxWidth: 440).padding(.horizontal, 28).padding(.top, 8).padding(.bottom, 12)
                .frame(maxWidth: .infinity)
                .background(palette.background)
        }
    }
}

/// Where you are: four small dots, the current one a longer capsule in the accent color.
private struct OnboardingDots: View {
    let step: PhoneOnboardingStep
    @Environment(\.mobilePalette) private var palette
    var body: some View {
        let index = PhoneOnboardingStep.allCases.firstIndex(of: step) ?? 0
        HStack(spacing: 6) {
            ForEach(Array(PhoneOnboardingStep.allCases.enumerated()), id: \.offset) { offset, _ in
                Capsule().fill(offset == index ? palette.accent : palette.foreground.opacity(0.18))
                    .frame(width: offset == index ? 18 : 6, height: 6)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(index + 1) of \(PhoneOnboardingStep.allCases.count)")
    }
}

/// The main action: a full-width capsule in the accent color.
private struct OnboardingPrimary: View {
    let title: String
    let identifier: String
    let action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(KemoType.font(.headline)).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.large)
            .accessibilityIdentifier(identifier)
    }
}

// MARK: Welcome

private struct OnboardingWelcomePage: View {
    @Environment(OnboardingFlow.self) private var flow
    var body: some View {
        OnboardingPage(step: .welcome) {
            Spacer(minLength: 0)
            // The official logo, unchanged: Kemo and the KemoSabe wordmark on its own plum.
            Image("BrandWordmark").resizable().scaledToFit()
                .frame(maxWidth: 240)
                .clipShape(RoundedRectangle(cornerRadius: 48, style: .continuous))
                .accessibilityLabel("KemoSabe")
                .accessibilityIdentifier("onboardingLogo")
            Text("Your personal companion. It chats with you, plans your day, and remembers what matters to you.")
                .font(KemoType.font(.title3)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        } actions: {
            OnboardingPrimary(title: "Continue", identifier: "onboardingContinue") { flow.advance() }
        }
    }
}

// MARK: Account

/// One account for iPhone, Mac, and Watch: Sign in with Apple, or a local account that links later.
private struct OnboardingAccountPage: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(\.mobilePalette) private var palette
    @Environment(\.colorScheme) private var scheme
    @State private var session = AppleAccountSession.shared
    private var linked: Bool { session.status == .linked }
    var body: some View {
        OnboardingPage(step: .account) {
            Spacer(minLength: 0)
            HStack(spacing: 18) {
                ForEach(["iphone", "laptopcomputer", "applewatch"], id: \.self) { symbol in
                    Image(systemName: symbol).font(.system(size: 30, weight: .regular)).foregroundStyle(palette.accent)
                }
            }.accessibilityHidden(true)
            Text("One account for iPhone, Mac, and Watch")
                .font(KemoType.font(.title, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingAccountTitle")
            Text("Sign in with Apple once. KemoSabe on your iPhone, Tsukumo on your Mac, and your Apple Watch all use the same account, the same companion, and the same profile.")
                .font(KemoType.font(.body)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if linked {
                VStack(spacing: 6) {
                    Label("Linked to your KemoSabe account", systemImage: "checkmark.circle.fill")
                        .font(KemoType.font(.headline)).foregroundStyle(palette.accent)
                        .accessibilityIdentifier("onboardingLinked")
                    if !AccountStore.shared.displayName.isEmpty {
                        Text(AccountStore.shared.displayName).font(KemoType.font(.subheadline)).foregroundStyle(.secondary)
                    }
                    if AccountSyncService.availableInBuild {
                        Label("Syncing with your iCloud", systemImage: "icloud").font(KemoType.font(.footnote)).foregroundStyle(.secondary)
                            .accessibilityIdentifier("onboardingSync")
                    }
                }.padding(.top, 4)
            }
            if let notice = session.notice {
                Text(notice).font(KemoType.font(.footnote)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        } actions: {
            if linked {
                OnboardingPrimary(title: "Continue", identifier: "onboardingContinue") { flow.advance() }
            } else {
                if AppleAccountSession.availableInBuild {
                    // Apple's own button, white in dark mode and black in light, as on the Account page.
                    SignInWithAppleButton(.signIn, onRequest: session.prepare, onCompletion: { session.handle($0, account: AccountStore.shared) })
                        .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                        .frame(height: 52).clipShape(Capsule())
                        .accessibilityIdentifier("onboardingSignInWithApple")
                    if session.status == .finishingSignIn {
                        Button("Try again") { session.retrySwitch() }.accessibilityIdentifier("onboardingRetrySignIn")
                    }
                } else {
                    Text("Sign in with Apple arrives in a coming build. You can link this iPhone then, in Settings → Account.")
                        .font(KemoType.font(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                // An account is required; only builds without Sign in with Apple and UI tests go on locally.
                if !AppleAccountSession.accountRequired {
                    Button { flow.advance() } label: {
                        Text("Continue without an account").font(KemoType.font(.body, weight: .medium)).frame(maxWidth: .infinity).padding(.vertical, 10)
                    }.buttonStyle(.plain).foregroundStyle(palette.foreground).accessibilityIdentifier("onboardingLocal")
                }
            }
        }
        .onAppear { session.refresh() }
    }
}

// MARK: Permissions

/// Microphone, notifications, calendar, and contacts, each asked only when the person taps Allow.
private struct OnboardingPermissionsPage: View {
    @Environment(OnboardingFlow.self) private var flow
    @Environment(AppStore.self) private var store
    @Environment(VoiceController.self) private var voice
    @Environment(ConnectorStore.self) private var connectors
    @Environment(\.mobilePalette) private var palette
    enum Permission: String, CaseIterable, Identifiable {
        case microphone, notifications, calendar, contacts
        var id: String { rawValue }
        var title: String {
            switch self {
            case .microphone: "Microphone"
            case .notifications: "Notifications"
            case .calendar: "Calendar"
            case .contacts: "Contacts"
            }
        }
        var detail: String {
            switch self {
            case .microphone: "Talk to \(CompanionIdentity.name) out loud. Speech is turned into text on this iPhone."
            case .notifications: "Hear from \(CompanionIdentity.name) when something needs you."
            case .calendar: "Plan your day around what's already on it."
            case .contacts: "Find someone's details and bring the people you choose into People."
            }
        }
        var symbol: String {
            switch self {
            case .microphone: "mic"
            case .notifications: "bell"
            case .calendar: "calendar"
            case .contacts: "person.crop.circle"
            }
        }
    }
    enum Answer: Equatable { case open, allowed, off, notNow }
    @State private var answers: [Permission: Answer] = [:]
    @State private var asking: Permission?
    var body: some View {
        OnboardingPage(step: .permissions) {
            Text("A few permissions, if you want them")
                .font(KemoType.font(.title, weight: .bold)).fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader).accessibilityIdentifier("onboardingPermissionsTitle")
            Text("Nothing is asked until you tap Allow. You can change any of these later.")
                .font(KemoType.font(.body)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) { ForEach(Permission.allCases) { row($0) } }
                .multilineTextAlignment(.leading)
        } actions: {
            OnboardingPrimary(title: "Done", identifier: "onboardingDone") { flow.finish() }
        }
        .task { await loadCurrent() }
    }
    private func row(_ permission: Permission) -> some View {
        let answer = answers[permission] ?? .open
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: permission.symbol).font(.system(size: 18, weight: .medium)).foregroundStyle(palette.accent)
                .frame(width: 28, height: 28).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(permission.title).font(KemoType.font(.headline))
                Text(permission.detail).font(KemoType.font(.footnote)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    switch answer {
                    case .open:
                        if asking == permission { KemoOrb(size: 18, state: .connecting).tint(palette.accent) }
                        else {
                            Button("Allow") { Task { await ask(permission) } }
                                .buttonStyle(.borderedProminent).buttonBorderShape(.capsule).controlSize(.small)
                                .accessibilityIdentifier("onboardingAllow-" + permission.rawValue)
                            Button("Not now") { answers[permission] = .notNow }
                                .buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.small)
                                .accessibilityIdentifier("onboardingNotNow-" + permission.rawValue)
                        }
                    case .allowed:
                        Label("On", systemImage: "checkmark.circle.fill").foregroundStyle(palette.accent)
                    case .off:
                        Text("Off. Turn it on in iOS Settings → KemoSabe.").foregroundStyle(.secondary)
                    case .notNow:
                        Text("Not now").foregroundStyle(.secondary)
                    }
                }.font(KemoType.font(.footnote, weight: .medium)).padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(palette.foreground.opacity(0.05), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("onboardingPermission-" + permission.rawValue)
    }
    /// Shows what's already allowed, without asking for anything.
    private func loadCurrent() async {
        if store.state.voiceEnabled == true, AVAudioApplication.shared.recordPermission == .granted { answers[.microphone] = .allowed }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        if NotificationPermission(settings.authorizationStatus) == .allowed { answers[.notifications] = .allowed }
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess { answers[.calendar] = .allowed }
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { answers[.contacts] = .allowed }
    }
    private func ask(_ permission: Permission) async {
        asking = permission
        defer { asking = nil }
        #if DEBUG
        // UI tests never raise the system's permission alerts.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { answers[permission] = .allowed; return }
        #endif
        let allowed: Bool
        switch permission {
        case .microphone:
            // The same path as the composer's microphone: it asks, then turns voice on.
            await voice.requestPermissions(store: store)
            allowed = store.state.voiceEnabled == true
        case .notifications:
            // The same path as Settings → Notifications (it also sets up Reply, Review, and View).
            allowed = await KemoNotifier.shared.requestPermission()
        // Calendar and Contacts go through Connections, so allowing them here connects them to Kemo too.
        case .calendar:
            _ = await connectors.connect(.calendar, store: store)
            allowed = connectors.status(.calendar, state: store.state).usable
        case .contacts:
            _ = await connectors.connect(.contacts, store: store)
            allowed = connectors.status(.contacts, state: store.state).usable
        }
        answers[permission] = allowed ? .allowed : .off
    }
}

// MARK: Sign in

/// Covers the app whenever there's no account on this iPhone (a new install past onboarding, or
/// right after signing out): the logo and Sign in with Apple, nothing else.
struct SignInGateView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.mobilePalette) private var palette
    @State private var session = AppleAccountSession.shared
    var body: some View {
        OnboardingPage(step: nil) {
            Spacer(minLength: 0)
            Image("BrandWordmark").resizable().scaledToFit()
                .frame(maxWidth: 200)
                .clipShape(RoundedRectangle(cornerRadius: 40, style: .continuous))
                .accessibilityLabel("KemoSabe")
            Text("Sign in to continue").font(KemoType.font(.title, weight: .bold)).accessibilityAddTraits(.isHeader)
            Text("One account for your iPhone, Mac, and Apple Watch.")
                .font(KemoType.font(.body)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let notice = session.notice {
                Text(notice).font(KemoType.font(.footnote)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        } actions: {
            SignInWithAppleButton(.signIn, onRequest: session.prepare, onCompletion: { session.handle($0, account: AccountStore.shared) })
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: 52).clipShape(Capsule())
                .accessibilityIdentifier("gateSignInWithApple")
            if session.status == .finishingSignIn {
                Button("Try again") { session.retrySwitch() }.accessibilityIdentifier("gateRetrySignIn")
            }
        }
        .background(palette.background.ignoresSafeArea())
        .onAppear { session.refresh() }
        .accessibilityIdentifier("signInGate")
    }
}
