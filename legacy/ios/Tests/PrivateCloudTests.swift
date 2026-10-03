import XCTest
import FoundationModels
#if os(macOS)
@testable import KemoSabeMac
#else
@testable import KemoSabe
#endif

/// Apple's Private Cloud Compute as a model choice (the owner's instruction, September 25, 2026).
/// Private Cloud can't answer in a simulator, so its availability, quota, and failures are fakes; the
/// errors are the SDK's own `PrivateCloudComputeLanguageModel.Error` values.
@MainActor final class PrivateCloudTests: XCTestCase {
    private var folder: URL!
    override func setUp() { folder = FileManager.default.temporaryDirectory.appendingPathComponent("PrivateCloudTests-" + UUID().uuidString) }
    override func tearDown() { try? FileManager.default.removeItem(at: folder) }

    private func store(_ model: AppleTurns, cloud: PrivateCloudStatus = .init(availability: .available, quota: nil)) -> AppStore {
        let store = AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: model, privateCloud: FakeCloud(status: cloud))
        return store
    }
    private func send(_ store: AppStore, _ text: String) async -> String? {
        let done = expectation(description: "reply")
        var reply: String?
        store.send(text, completion: { reply = $0; done.fulfill() })
        await fulfillment(of: [done], timeout: 5)
        return reply
    }

    func testPrivateCloudRunsTheSameHarnessWithoutTheLock() async {
        let model = AppleTurns()
        let store = store(model)
        XCTAssertTrue(store.runsOnlyOnDevice)
        XCTAssertEqual(store.modelLabel, "Apple on-device")
        store.selectAppleModel(.privateCloud)
        XCTAssertEqual(store.modelRoute, .onDevice, "Same Apple route: same tools, gates, and context rules")
        XCTAssertEqual(store.appleModel, .privateCloud)
        XCTAssertFalse(store.runsOnlyOnDevice, "The lock shows only while the on-device model is the only one in use")
        XCTAssertEqual(store.modelLabel, "Apple Private Cloud")
        XCTAssertEqual(store.availability, "Runs on Apple’s Private Cloud Compute.")
        let reply = await send(store, "What's a good name for a cat?")
        XCTAssertEqual(reply, "privateCloud answer")
        XCTAssertEqual(model.models, [.privateCloud])
        XCTAssertNil(store.notice)
        // Choosing on-device again brings the lock back.
        store.selectAppleModel(.onDevice)
        XCTAssertTrue(store.runsOnlyOnDevice)
        XCTAssertNil(store.state.appleModel)
    }

    func testUnavailablePrivateCloudCantBeChosenAndFallsBackToOnDevice() async {
        let model = AppleTurns()
        let store = store(model, cloud: .init(availability: .unavailable("This device doesn’t support Apple Intelligence."), quota: nil))
        store.selectAppleModel(.privateCloud)
        XCTAssertEqual(store.appleModel, .onDevice)
        XCTAssertNil(store.state.appleModel)
        // A choice saved while it was available answers on-device when it no longer is.
        store.state.appleModel = AppleModel.privateCloud.rawValue
        XCTAssertEqual(store.appleModel, .onDevice)
        XCTAssertTrue(store.runsOnlyOnDevice)
        _ = await send(store, "Hi")
        XCTAssertEqual(model.models, [.onDevice])
        XCTAssertEqual(PrivateCloudStatus.olderSystem.unavailableReason, "Needs iOS 27 or macOS 27.")
    }

    func testQuotaLimitFallsBackToOnDeviceForThatReplyAndSaysWhenItResets() async throws {
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip("Private Cloud needs iOS 27 or macOS 27") }
        let reset = Date().addingTimeInterval(3 * 3600)
        let model = AppleTurns()
        model.cloudFailure = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: reset, debugDescription: "test"))
        let store = store(model)
        store.selectAppleModel(.privateCloud)
        let reply = await send(store, "Plan a picnic menu")
        XCTAssertEqual(reply, "onDevice answer")
        XCTAssertEqual(model.models, [.privateCloud, .onDevice])
        let notice = try XCTUnwrap(store.notice)
        XCTAssertTrue(notice.hasPrefix("Private Cloud limit reached until "), notice)
        XCTAssertTrue(notice.hasSuffix(". On-device answered this one."), notice)
        XCTAssertNil(store.error)
        XCTAssertEqual(store.state.messages.last?.text, "onDevice answer")
        // Until it resets, replies go straight to on-device, still saying why.
        _ = await send(store, "And a dessert?")
        XCTAssertEqual(model.models, [.privateCloud, .onDevice, .onDevice])
        XCTAssertNotNil(store.notice)
        XCTAssertNotNil(store.privateCloudStatus.quotaLine())
    }

    func testOtherPrivateCloudFailuresFallBackInOneLine() async throws {
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip("Private Cloud needs iOS 27 or macOS 27") }
        let cases: [(Error, String)] = [
            (PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "offline")), "Couldn’t reach Private Cloud. On-device answered this one."),
            (PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "down")), "Private Cloud isn’t available right now. On-device answered this one."),
            (NSError(domain: "FoundationModels.LanguageModelError", code: -1), "Private Cloud couldn’t answer. On-device answered this one."),
        ]
        for (failure, line) in cases {
            let model = AppleTurns(); model.cloudFailure = failure
            let store = store(model)
            store.selectAppleModel(.privateCloud)
            let reply = await send(store, "Hello")
            XCTAssertEqual(reply, "onDevice answer")
            XCTAssertEqual(store.notice, line)
        }
    }

    func testWithoutOnDeviceTheFailureIsOneLine() async throws {
        guard #available(iOS 27, macOS 27, *) else { throw XCTSkip("Private Cloud needs iOS 27 or macOS 27") }
        let model = AppleTurns(); model.isAvailable = false
        model.cloudFailure = PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(resetDate: nil, debugDescription: "test"))
        let store = store(model)
        store.selectAppleModel(.privateCloud)
        XCTAssertTrue(store.canChat, "Private Cloud doesn't need the on-device model")
        let reply = await send(store, "Hello")
        XCTAssertNil(reply)
        XCTAssertEqual(model.models, [.privateCloud])
        XCTAssertEqual(store.error, "Private Cloud limit reached, and the on-device model isn’t ready. Try again later.")
        XCTAssertNil(store.notice)
    }

    func testHarnessErrorsNeverSwitchModels() {
        XCTAssertNil(PrivateCloudFallback.reason(for: CancellationError()))
        XCTAssertNil(PrivateCloudFallback.reason(for: PlanningError.busy))
        XCTAssertNil(PrivateCloudFallback.reason(for: PlanningError.changedContext))
        XCTAssertNil(PrivateCloudFallback.reason(for: ToolFailure.expired))
    }

    func testResetTimesReadNaturally() {
        let zone = TimeZone(identifier: "America/Chicago")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 10))!
        XCTAssertEqual(PrivateCloudFallback.format(now.addingTimeInterval(5 * 3600), now: now, timeZone: zone), "3:00 PM")
        XCTAssertEqual(PrivateCloudFallback.format(now.addingTimeInterval(23 * 3600), now: now, timeZone: zone), "tomorrow 9:00 AM")
        XCTAssertEqual(PrivateCloudFallback.quota(resetDate: now.addingTimeInterval(5 * 3600)).notice(now: now, timeZone: zone),
                       "Private Cloud limit reached until 3:00 PM. On-device answered this one.")
    }

    #if os(iOS)
    func testTheWatchConfirmsPrivateCloudWithItsOneLine() {
        let choice = WatchLink.ModelChoice(id: WatchLink.ModelChoice.privateCloud, title: "Apple Private Cloud", destination: "Apple’s Private Cloud Compute")
        XCTAssertEqual(choice.confirmationLine, "Runs on Apple’s Private Cloud Compute.")
        XCTAssertEqual(WatchLink.ModelChoice.privateCloudLine, PrivateCloudText.destination)
        let connected = WatchLink.ModelChoice(id: UUID().uuidString, title: "Claude", destination: "api.anthropic.com")
        XCTAssertEqual(connected.confirmationLine, "Sends to api.anthropic.com")
    }

    func testLockedWatchUsesPrivateCloudThenOnDevice() async {
        let watch = LockedWatchMode(folder: { [folder] in folder!.appendingPathComponent("watch-locked") }, keys: MemoryAPIKeys(), protectedDataAvailable: { false })
        watch.refresh(route: .onDevice, apple: .privateCloud, profile: nil, allProfiles: [])
        XCTAssertEqual(watch.workingSet, .init(route: .privateCloud))
        watch.privateCloudReply = { _ in "From Private Cloud" }
        watch.onDeviceReply = { _ in XCTFail("Private Cloud answered"); return "" }
        let answered = await watch.answer("Hi", capture: false)
        XCTAssertEqual(answered, .answered("From Private Cloud"))
        watch.privateCloudReply = { _ in throw CancellationError() }
        watch.onDeviceAvailable = { true }
        watch.onDeviceReply = { _ in "From on-device" }
        let fellBack = await watch.answer("Hi", capture: false)
        XCTAssertEqual(fellBack, .answered("From on-device"))
        watch.apiReply = { _, _, _ in XCTFail("Never another destination"); return "" }
        watch.onDeviceAvailable = { false }
        let unavailable = await watch.answer("Hi", capture: false)
        XCTAssertEqual(unavailable, .failed(LockedWatchMode.unlockToAnswer))
    }
    #endif
}

private struct FakeCloud: PrivateCloudProbing { var status: PrivateCloudStatus }

/// Answers with the Apple model it was asked to use; Private Cloud can be made to fail.
private final class AppleTurns: ModelProvider {
    let runsLocally = true
    var isAvailable = true
    let availabilityDescription = "Test"
    var cloudFailure: Error?
    var models: [AppleModel] = []
    func reply(to: String, history: [ChatMessage], memories: [MemoryNote], standupFormat: String) async throws -> String { "" }
    func respond(_ request: PlanningRequest, tools: ToolRegistry, onSnapshot: @escaping @MainActor (String) -> Void) async throws -> CompanionPlan {
        models.append(request.appleModel)
        if request.appleModel == .privateCloud, let cloudFailure { throw cloudFailure }
        return .init(answer: request.appleModel.rawValue + " answer")
    }
}
