import Foundation
import Observation

/// First-run onboarding on iPhone and Mac (the owner's request, September 25, 2026): a welcome,
/// one account for every device (Sign in with Apple, or continue with a local account that can
/// link later), the companion's own intro chat, and then what each device needs (permissions on
/// iPhone, coding agents and a project on Mac).
///
/// Every account goes through the current setup once (`setupKey`), including installs from before
/// onboarding existed; steps they've already done say so and move on. The step in progress is kept in the device's settings (`stepKey`), because signing in
/// during onboarding switches accounts and rebuilds the UI on the new one, and the flow has to
/// pick up where it was.
enum Onboarding {
    /// In the account's settings: this account finished onboarding (or never needed it).
    static let completedKey = "kemo.onboarding.completed"
    /// In the account's settings: the setup this account went through. Installs from before
    /// onboarding existed were marked finished without seeing it; the owner asked (September 25,
    /// 2026) that the next launch walks them through account and setup once too. Raising
    /// `currentSetup` shows it once more to everyone.
    static let setupKey = "kemo.onboarding.setup"
    static let currentSetup = 1
    /// In the device's settings: the step showing now, until onboarding finishes.
    static let stepKey = "kemo.onboarding.step"
    /// The intro's progress key (`CompanionIntro.stepKey`), named here so the Mac can read it too.
    static let introKey = "kemo.intro.step"

    /// What an install already holds from before onboarding existed.
    struct Evidence: Equatable {
        var accountRecord = false
        var namedCompanion = false
        var introStarted = false
        var conversations = false
        var memories = false
        /// Anything else the device keeps (on the Mac, its coding projects and tasks).
        var other = false
        var existingInstall: Bool { accountRecord || namedCompanion || introStarted || conversations || memories || other }
    }
    /// Reads the account's settings for an account record, a named companion, or an intro under way.
    static func evidence(account: UserDefaults, conversations: Bool, memories: Bool, other: Bool = false) -> Evidence {
        .init(accountRecord: account.data(forKey: AccountStore.key) != nil,
              namedCompanion: account.bool(forKey: CompanionIdentity.namedKey),
              introStarted: account.string(forKey: introKey) != nil,
              conversations: conversations, memories: memories, other: other)
    }

    /// The step to show at launch, or nil when this account has been through the current setup.
    /// `evidence` is kept for callers that report what an install holds. A step already under way
    /// (from before an account switch or a relaunch) continues. `steps` are the device's steps,
    /// first to last.
    static func resume(steps: [String], account: UserDefaults, device: UserDefaults, evidence: Evidence) -> String? {
        if let saved = device.string(forKey: stepKey) {
            if steps.contains(saved) { return saved }
            device.removeObject(forKey: stepKey)
        }
        if account.integer(forKey: setupKey) >= currentSetup { return nil }
        // Everyone, new or existing, goes through the current setup once. Steps an existing
        // install has already done (a named companion) say so and move on.
        return steps.first
    }
}

/// The onboarding a device is showing, and its progress. Owned by the app (not the account-scoped
/// UI), so it carries on across the account switch in the sign-in step. Each device names its own
/// steps (`PhoneOnboardingStep`, `MacOnboardingStep`).
@MainActor @Observable final class OnboardingFlow {
    /// The step showing now, by its raw name; nil when onboarding isn't showing.
    private(set) var current: String?
    var active: Bool { current != nil }
    /// Whether this launch has decided yet (it waits while the store can't be read).
    private(set) var decided = false
    /// Bumped when onboarding finishes, so the app can land where it should.
    private(set) var finishedRevision = 0
    @ObservationIgnored let steps: [String]
    @ObservationIgnored private let device: UserDefaults
    @ObservationIgnored private let account: () -> UserDefaults

    init(steps: [String], device: UserDefaults = AccountDirectory.settings, account: @escaping () -> UserDefaults = { AccountDirectory.accountSettings }) {
        self.steps = steps; self.device = device; self.account = account
    }
    /// Decides at launch whether onboarding shows (see `Onboarding.resume`).
    func decide(_ evidence: Onboarding.Evidence) {
        decided = true
        current = Onboarding.resume(steps: steps, account: account(), device: device, evidence: evidence)
        if let current { device.set(current, forKey: Onboarding.stepKey) }
    }
    /// Starts again from the welcome, whatever was saved (UI tests, and developer settings).
    func restart() { decided = true; if let first = steps.first { go(first) } }
    func go(_ step: String) {
        guard steps.contains(step) else { return }
        current = step
        device.set(step, forKey: Onboarding.stepKey)
    }
    /// The step after the current one, or finishing after the last.
    func advance() {
        guard let current, let index = steps.firstIndex(of: current) else { return }
        if index + 1 < steps.count { go(steps[index + 1]) } else { finish() }
    }
    /// Done: this account is marked finished and the device forgets the step.
    func finish() {
        account().set(true, forKey: Onboarding.completedKey)
        account().set(Onboarding.currentSetup, forKey: Onboarding.setupKey)
        device.removeObject(forKey: Onboarding.stepKey)
        current = nil
        finishedRevision += 1
    }
    /// Stops without marking anything (UI tests that don't exercise onboarding).
    func skip() {
        decided = true
        device.removeObject(forKey: Onboarding.stepKey)
        current = nil
    }
    /// Whether the account open now has finished onboarding; the watch waits for it.
    var accountFinished: Bool { !active && account().bool(forKey: Onboarding.completedKey) }
}

extension Onboarding {
    /// Whether this device has finished setting up (read from settings, for the watch's status).
    static func finished(account: UserDefaults = AccountDirectory.accountSettings, device: UserDefaults = AccountDirectory.settings) -> Bool {
        device.string(forKey: stepKey) == nil && account.bool(forKey: completedKey)
    }
}

extension AppStore {
    /// Whether any conversation exists here, open or saved, with any model.
    var hasConversations: Bool {
        !state.messages.isEmpty
            || (state.apiConversations ?? [:]).values.contains { !$0.isEmpty }
            || !(state.conversationArchives ?? []).isEmpty
    }
    /// What this install already holds, for deciding whether it's new. Nil while the store can't
    /// be read, since an unread store would look empty.
    func onboardingEvidence(account: UserDefaults = AccountDirectory.accountSettings, other: Bool = false) -> Onboarding.Evidence? {
        guard !failedToLoad else { return nil }
        return Onboarding.evidence(account: account, conversations: hasConversations, memories: !state.memories.isEmpty, other: other)
    }
}
