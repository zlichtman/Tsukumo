import XCTest
@testable import KemoSabeMac

/// When Tsukumo's onboarding shows: only on a new install. A Mac that has opened Tsukumo's window
/// before, or has projects or coding tasks, skips it even with no chats or account data.
@MainActor final class MacOnboardingTests: XCTestCase {
    private var suites: [String] = []
    override func tearDown() {
        for suite in suites { UserDefaults().removePersistentDomain(forName: suite) }
        suites = []
    }
    private func defaults() throws -> UserDefaults {
        let suite = "MacOnboardingTests-" + UUID().uuidString
        suites.append(suite)
        return try XCTUnwrap(UserDefaults(suiteName: suite))
    }
    private func decide(device: UserDefaults, account: UserDefaults, projects: Int = 0, tasks: Int = 0) -> OnboardingFlow {
        let flow = OnboardingFlow(steps: MacOnboardingStep.all, device: device, account: { account })
        let earlier = MacOnboardingEvidence.earlierUse(device: device, projects: projects, tasks: tasks)
        flow.decide(Onboarding.evidence(account: account, conversations: false, memories: false, other: earlier))
        return flow
    }

    func testANewMacStartsAtTheWelcomeAndEndsWithSetup() throws {
        let flow = decide(device: try defaults(), account: try defaults())
        XCTAssertEqual(flow.macStep, .welcome)
        XCTAssertEqual(MacOnboardingStep.allCases, [.welcome, .account, .companion, .setup])
        flow.advance(); flow.advance(); flow.advance()
        XCTAssertEqual(flow.macStep, .setup)
        flow.finish()
        XCTAssertNil(flow.macStep)
    }

    /// A Mac used before onboarding existed goes through the setup once (the owner's request,
    /// September 25, 2026); the companion step then says the companion is already named.
    func testAMacUsedBeforeGetsTheSetupOnce() throws {
        let window = try defaults()
        window.set("0 0 1120 760 0 0 1512 944 ", forKey: MacOnboardingEvidence.windowFrameKey)
        let account = try defaults()
        account.set(true, forKey: CompanionIdentity.namedKey)
        account.set("Mochi", forKey: CompanionIdentity.key)
        let flow = decide(device: window, account: account, projects: 1, tasks: 2)
        XCTAssertEqual(flow.macStep, .welcome)
        flow.finish()
        XCTAssertNil(decide(device: window, account: account, projects: 1).macStep, "Once only")
    }

    /// Onboarding in progress when Tsukumo quits picks up at the same step.
    func testAStepUnderWayResumesAfterARelaunch() throws {
        let device = try defaults(), account = try defaults()
        let flow = decide(device: device, account: account)
        flow.go(MacOnboardingStep.setup.rawValue)
        // The window's frame was saved while onboarding showed; that doesn't end it.
        device.set("0 0 1120 760 0 0 1512 944 ", forKey: MacOnboardingEvidence.windowFrameKey)
        XCTAssertEqual(decide(device: device, account: account, projects: 1).macStep, .setup)
    }
}
