import XCTest
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// When onboarding shows (shared by iPhone and Mac): only on a new install; an install with data
/// from before onboarding existed is marked finished once and never sees it; a step under way
/// carries on across an account switch; finishing marks the account open at the end.
@MainActor final class OnboardingTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }
    private func defaults() throws -> UserDefaults {
        let suite = "OnboardingTests-" + UUID().uuidString
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    private let steps = ["welcome", "account", "companion", "last"]

    func testANewInstallStartsAtTheWelcome() throws {
        let account = try defaults(), device = try defaults()
        let flow = OnboardingFlow(steps: steps, device: device, account: { account })
        flow.decide(Onboarding.evidence(account: account, conversations: false, memories: false))
        XCTAssertEqual(flow.current, "welcome")
        XCTAssertTrue(flow.active)
        XCTAssertEqual(device.string(forKey: Onboarding.stepKey), "welcome", "The step is kept on the device")
        XCTAssertFalse(account.bool(forKey: Onboarding.completedKey))
    }

    /// Installs from before onboarding existed go through the setup once, then never again.
    func testExistingInstallsSeeTheSetupOnceThenNeverAgain() throws {
        let account = try defaults(), device = try defaults()
        account.set(Data("{}".utf8), forKey: AccountStore.key)
        account.set(true, forKey: CompanionIdentity.namedKey)
        account.set(true, forKey: Onboarding.completedKey)
        let flow = OnboardingFlow(steps: steps, device: device, account: { account })
        flow.decide(Onboarding.evidence(account: account, conversations: true, memories: true))
        XCTAssertEqual(flow.current, "welcome", "An install marked finished without seeing it gets the setup once")
        flow.finish()
        XCTAssertEqual(account.integer(forKey: Onboarding.setupKey), Onboarding.currentSetup)
        let again = OnboardingFlow(steps: steps, device: device, account: { account })
        again.decide(Onboarding.evidence(account: account, conversations: true, memories: true))
        XCTAssertNil(again.current, "Never again after that")
        again.decide(.init())
        XCTAssertNil(again.current, "Deleting everything later doesn't bring it back")
    }

    func testAFinishedAccountSkipsIt() throws {
        let account = try defaults(), device = try defaults()
        account.set(true, forKey: Onboarding.completedKey)
        account.set(Onboarding.currentSetup, forKey: Onboarding.setupKey)
        let flow = OnboardingFlow(steps: steps, device: device, account: { account })
        flow.decide(.init())
        XCTAssertNil(flow.current)
        XCTAssertTrue(flow.accountFinished)
        XCTAssertTrue(Onboarding.finished(account: account, device: device))
    }

    /// Signing in during onboarding switches accounts and rebuilds the UI; the flow carries on at
    /// the same step, even on an account that finished onboarding on another launch, and finishing
    /// marks the account open at the end, not the one it started on.
    func testAStepUnderWayCarriesOnAcrossAnAccountSwitch() throws {
        let local = try defaults(), apple = try defaults(), device = try defaults()
        var open = local
        let flow = OnboardingFlow(steps: steps, device: device, account: { open })
        flow.decide(.init())
        flow.advance()
        XCTAssertEqual(flow.current, "account")
        // Sign in with Apple: the device is on the Apple account now.
        open = apple
        apple.set(true, forKey: Onboarding.completedKey)
        let relaunched = OnboardingFlow(steps: steps, device: device, account: { open })
        relaunched.decide(Onboarding.evidence(account: apple, conversations: true, memories: true))
        XCTAssertEqual(relaunched.current, "account", "A step under way continues")
        apple.removeObject(forKey: Onboarding.completedKey)
        relaunched.advance(); XCTAssertEqual(relaunched.current, "companion")
        XCTAssertFalse(Onboarding.finished(account: apple, device: device), "Not finished while a step is under way")
        relaunched.advance(); XCTAssertEqual(relaunched.current, "last")
        let before = relaunched.finishedRevision
        relaunched.advance()
        XCTAssertNil(relaunched.current, "Advancing past the last step finishes")
        XCTAssertEqual(relaunched.finishedRevision, before + 1)
        XCTAssertTrue(apple.bool(forKey: Onboarding.completedKey), "The account open at the end is marked")
        XCTAssertFalse(local.bool(forKey: Onboarding.completedKey), "The account left behind isn't")
        XCTAssertNil(device.string(forKey: Onboarding.stepKey))
        XCTAssertTrue(Onboarding.finished(account: apple, device: device))
    }

    func testAnUnknownSavedStepIsDropped() throws {
        let account = try defaults(), device = try defaults()
        device.set("retired-step", forKey: Onboarding.stepKey)
        let flow = OnboardingFlow(steps: steps, device: device, account: { account })
        flow.decide(.init())
        XCTAssertEqual(flow.current, "welcome")
    }

    func testRestartAndSkip() throws {
        let account = try defaults(), device = try defaults()
        account.set(true, forKey: Onboarding.completedKey)
        let flow = OnboardingFlow(steps: steps, device: device, account: { account })
        flow.restart()
        XCTAssertEqual(flow.current, "welcome", "Developer settings can show it again")
        flow.go("not-a-step")
        XCTAssertEqual(flow.current, "welcome")
        flow.skip()
        XCTAssertNil(flow.current)
        XCTAssertTrue(flow.decided)
        XCTAssertNil(device.string(forKey: Onboarding.stepKey))
    }

    /// The store's own contents count: any conversation or memory makes the install an existing one.
    func testTheStoreTellsANewInstallFromAnExistingOne() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OnboardingTests-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try defaults()
        let store = AppStore(repository: .init(url: root.appendingPathComponent("state.json")), provider: APIUnavailableLocal(), apiKeys: MemoryAPIKeys())
        XCTAssertFalse(store.hasConversations)
        XCTAssertEqual(store.onboardingEvidence(account: account)?.existingInstall, false)
        store.appendVisibleMessage(role: "You", text: "Hello")
        XCTAssertTrue(store.hasConversations)
        XCTAssertEqual(store.onboardingEvidence(account: account)?.existingInstall, true)
    }

    #if os(iOS)
    /// The watch learns whether the iPhone finished onboarding from its status; an iPhone build from
    /// before onboarding sends nothing, which the watch counts as set up.
    func testTheWatchStatusCarriesWhetherTheIPhoneIsSetUp() throws {
        var status = WatchLink.Status(model: "Apple on-device", ready: true)
        status.setUp = false
        let decoded = try WatchLink.decode(WatchLink.Status.self, from: WatchLink.encode(status))
        XCTAssertEqual(decoded.setUp, false)
        // A status from an iPhone build before onboarding: the same fields, without `setUp`.
        struct OlderStatus: Codable { var model = "Apple on-device"; var ready = true; var note = "" }
        let older = try WatchLink.encode(OlderStatus())
        XCTAssertNil(try WatchLink.decode(WatchLink.Status.self, from: older).setUp)
    }
    #endif

    /// One account everywhere: the words never suggest a second account.
    func testAccountWordsSayOneAccount() {
        XCTAssertTrue(AppleAccountSession.oneAccountNote.contains("same Apple Account you use on your"))
        XCTAssertTrue(AppleAccountSession.oneAccountNote.contains("one KemoSabe account for iPhone, Mac, and Apple Watch"))
        XCTAssertTrue(AppleAccountSession.linkedNote.hasPrefix("Linked to your KemoSabe account."))
        for words in [AppleAccountSession.oneAccountNote, AppleAccountSession.linkedNote] {
            XCTAssertFalse(words.localizedCaseInsensitiveContains("create"), words)
            XCTAssertFalse(words.localizedCaseInsensitiveContains("new account"), words)
        }
    }
}
