import XCTest
@testable import KemoSabe

final class ConnectorTests: XCTestCase {
    @MainActor func testSpokenAnimationRequestsReachExplicitPerformance() {
        let examples: [(String, ArtworkPerformance)] = [
            ("Kemosabe, can you please do your animation?", .dance),
            ("Can you please dance for me?", .dance), ("Wave at me", .greeting),
            ("Show me your writing animation", .writing), ("Play the piano", .piano),
            ("Do the reading animation", .reading), ("Stop the animation", .idle),
            ("coding animation", .coding), ("the debugging animation", .debugging)
        ]
        let navigation = AppNavigation()
        for (text, expected) in examples {
            XCTAssertEqual(VoiceCommand.parse(text), .perform(expected), text)
            navigation.open(.settings); navigation.perform(expected)
            XCTAssertNil(navigation.panel); XCTAssertEqual(navigation.performance, expected)
        }
        for text in ["Don't dance", "My friend said dance", "Write an email", "Can you explain animation?", "Do the delete all files animation"] {
            XCTAssertNil(VoiceCommand.parse(text), text)
        }
        XCTAssertEqual(VoiceCommand.parse("Show me your animations"), .open(.animations))
        XCTAssertGreaterThan(VoiceTurnPolicy.endDelay(for: "Can you do your", patient: false), 1)
    }
    func testExplicitVoiceCommandsAndWakeAliases() {
        let cases: [(String, VoiceCommand)] = [
            ("Kemo, connect my calendar.", .connect(.calendar)),
            ("Hey Kemo Sabe, please link my address book", .connect(.contacts)),
            ("Can you connect Gmail please?", .connect(.gmail)),
            ("Open connections", .open(.connections)), ("Show themes", .open(.appearance)),
            ("Switch to the matcha theme", .theme("matcha")),
            ("Turn off reply captions", .setting(.captions, false)),
            ("Give me more time to finish", .setting(.patientListening, true)),
            ("Speak slower", .pace(0.42)), ("Disconnect my calendar", .disconnect(.calendar)),
            ("What’s on my calendar today?", .agenda), ("Read my reminders", .reminders),
            ("Find contact Alex Smith", .contact("alex smith")), ("Go back", .back),
            ("Stop listening", .pause), ("Kemo, turn off voice", .pause)
        ]
        for (text, expected) in cases { XCTAssertEqual(VoiceCommand.parse(text), expected, text) }
    }
    func testMentionsNegationsAndUnknownAccountsCannotConnect() {
        for text in ["Don't connect my calendar", "Do not turn off captions", "My boss said open settings", "What happens if I connect Gmail", "I like the matcha theme", "Connect everything", "Connect my bank", "Disconnect everything", "Allow all permissions"] {
            XCTAssertNil(VoiceCommand.parse(text), text)
        }
    }
    func testVoiceSettingsAreBoundedAndKeepOtherPreferences() {
        var state = SavedState(); state.memories = [.init(text: "Keep me")]
        _ = VoiceSettingsAction.apply(.pace(99), to: &state); XCTAssertEqual(state.speechRate, 0.56)
        _ = VoiceSettingsAction.apply(.setting(.captions, false), to: &state); XCTAssertEqual(state.captionsEnabled, false)
        _ = VoiceSettingsAction.apply(.setting(.patientListening, true), to: &state); XCTAssertEqual(state.patientListening, true)
        _ = VoiceSettingsAction.apply(.theme("matcha"), to: &state); XCTAssertEqual(state.theme.id, "matcha")
        _ = VoiceSettingsAction.apply(.theme("not a theme"), to: &state); XCTAssertEqual(state.theme.id, "matcha")
        XCTAssertEqual(state.memories.first?.text, "Keep me"); XCTAssertNil(state.enabledConnectors)
    }
    func testVoiceThemeSupportsCustomNamesAndRejectsAmbiguity() {
        var state = SavedState()
        var theme = BotTheme.presets[0]; theme.id = "custom-one"; theme.name = "Deep Sea"
        state.customThemes = [theme]
        _ = VoiceSettingsAction.apply(.theme("deep sea"), to: &state); XCTAssertEqual(state.theme.id, theme.id)
        theme.id = "custom-two"; theme.accent = "AAFFCC"; state.customThemes?.append(theme)
        _ = VoiceSettingsAction.apply(.theme("deep sea"), to: &state); XCTAssertEqual(state.theme.id, "custom-one")
        _ = VoiceSettingsAction.apply(.theme("original"), to: &state); XCTAssertEqual(state.theme.id, "apricot")
    }
    @MainActor func testNavigationBackPreservesSettingsAndThemeDrawerOrder() {
        let nav = AppNavigation(); nav.open(.settings); nav.open(.appearance); nav.showingThemes = true
        nav.back(); XCTAssertFalse(nav.showingThemes); XCTAssertEqual(nav.detail, .appearance)
        nav.back(); XCTAssertNil(nav.detail); XCTAssertEqual(nav.panel, .settings)
        nav.open(.connections); nav.home(); XCTAssertNil(nav.panel); XCTAssertNil(nav.detail)
        nav.open(.connections); XCTAssertEqual(nav.panel, .connections); nav.back(); XCTAssertNil(nav.panel)
    }
    func testPermissionAndKemoEnablementAreBothRequired() {
        XCTAssertEqual(ConnectorStatus.resolve(native: true, enabled: false, permission: .allowed), .disconnected)
        XCTAssertEqual(ConnectorStatus.resolve(native: true, enabled: true, permission: .notDetermined), .disconnected)
        XCTAssertEqual(ConnectorStatus.resolve(native: true, enabled: true, permission: .allowed), .connected)
        XCTAssertEqual(ConnectorStatus.resolve(native: true, enabled: true, permission: .limited), .limited)
        XCTAssertEqual(ConnectorStatus.resolve(native: true, enabled: true, permission: .denied), .denied)
        XCTAssertEqual(ConnectorStatus.resolve(native: true, enabled: true, permission: .restricted), .restricted)
        XCTAssertEqual(ConnectorStatus.resolve(native: false, enabled: true, permission: .allowed), .unavailable)
    }
    @MainActor func testConnectPersistsOnlyPreferenceAndDoesNotReadData() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = MockConnectionClient(permission: .notDetermined, afterRequest: .allowed), connectors = ConnectorStore(client: MockConnectionClient(permission: .allowed))
        let tested = ConnectorStore(client: client)
        _ = await tested.connect(.calendar, store: store); _ = await tested.connect(.calendar, store: store)
        XCTAssertEqual(client.requests, 1); XCTAssertEqual(client.reads, 0)
        XCTAssertEqual(store.state.enabledConnectors, ["calendar"])
        let loaded = try LocalRepository(url: folder.appendingPathComponent("state.json")).read()
        XCTAssertEqual(loaded.enabledConnectors, ["calendar"])
        XCTAssertTrue(loaded.memories.isEmpty); XCTAssertTrue(loaded.messages.isEmpty)
        XCTAssertEqual(connectors.status(.calendar, state: loaded), .connected)
    }
    @MainActor func testUnconfiguredServicesNeverRequestPermissionOrConnect() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = MockConnectionClient(permission: .allowed), connectors = ConnectorStore(client: MockConnectionClient(permission: .allowed))
        let tested = ConnectorStore(client: client)
        for id in ConnectorID.allCases where !id.isNative {
            _ = await tested.connect(id, store: store)
            XCTAssertEqual(connectors.status(id, state: store.state), .unavailable)
        }
        XCTAssertNil(store.state.enabledConnectors); XCTAssertEqual(client.requests, 0); XCTAssertEqual(client.reads, 0)
    }
    @MainActor func testDeniedPermissionDoesNotBecomeConnected() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = MockConnectionClient(permission: .denied)
        let connectors = ConnectorStore(client: client)
        _ = await connectors.connect(.calendar, store: store)
        XCTAssertNil(store.state.enabledConnectors); XCTAssertEqual(client.requests, 0)
        XCTAssertEqual(connectors.status(.calendar, state: store.state), .denied)
    }
    @MainActor func testReadsRequireConnectionAndNeverWriteMemory() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = MockConnectionClient(permission: .notDetermined, afterRequest: .allowed), connectors = ConnectorStore(client: MockConnectionClient(permission: .allowed))
        let tested = ConnectorStore(client: client)
        _ = await tested.read(.calendar, store: store); XCTAssertEqual(client.reads, 0)
        _ = await tested.connect(.calendar, store: store)
        let result = await tested.read(.calendar, store: store)
        XCTAssertEqual(result, "A sourced result.")
        XCTAssertEqual(client.reads, 1); XCTAssertTrue(store.state.messages.isEmpty); XCTAssertTrue(store.state.memories.isEmpty)
        _ = connectors.disconnect(.calendar, store: store)
        _ = await tested.read(.calendar, store: store); XCTAssertEqual(client.reads, 1)
    }
    @MainActor func testRevokedPermissionBlocksReadEvenWhenPreferenceIsEnabled() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        store.state.enabledConnectors = ["calendar"]
        let client = MockConnectionClient(permission: .denied)
        let tested = ConnectorStore(client: client)
        _ = await tested.read(.calendar, store: store); XCTAssertEqual(client.reads, 0)
        XCTAssertEqual(tested.status(.calendar, state: store.state), .denied)
    }
    @MainActor func testDisconnectDiscardsAnInFlightRead() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        store.state.enabledConnectors = ["calendar"]
        let tested = ConnectorStore(client: MockConnectionClient(permission: .allowed, delay: 80))
        let task = Task { await tested.read(.calendar, store: store) }
        try await Task.sleep(for: .milliseconds(15))
        _ = tested.disconnect(.calendar, store: store)
        let result = await task.value
        XCTAssertEqual(result, "That lookup was cancelled."); XCTAssertFalse(tested.reading)
    }
    @MainActor func testCancelledPermissionCannotEnableConnection() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let tested = ConnectorStore(client: MockConnectionClient(permission: .notDetermined, delay: 80, afterRequest: .allowed))
        let task = Task { await tested.connect(.calendar, store: store) }
        try await Task.sleep(for: .milliseconds(15)); task.cancel()
        _ = await task.value
        XCTAssertNil(store.state.enabledConnectors); XCTAssertNil(tested.authorizing)
    }
    func testExistingStateDecodesWithoutConnectorPreferences() throws {
        let data = try JSONEncoder().encode(SavedState())
        let loaded = try JSONDecoder().decode(SavedState.self, from: data)
        XCTAssertNil(loaded.enabledConnectors); XCTAssertNil(loaded.disconnectedConnectors); XCTAssertNil(loaded.apiConnectorGrants)
    }

    // MARK: One source of truth for "connected"

    /// Permission granted in Day, People, the onboarding primer, or iOS Settings counts as connected.
    @MainActor func testPermissionGrantedOutsideConnectionsIsConnected() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = MockConnectionClient(permission: .allowed)
        let connectors = ConnectorStore(client: client)
        XCTAssertNil(store.state.enabledConnectors, "Nothing was ever connected through Connections")
        for id in [ConnectorID.calendar, .reminders, .contacts] { XCTAssertEqual(connectors.status(id, state: store.state), .connected, id.rawValue) }
        let result = await connectors.read(.calendar, store: store)
        XCTAssertEqual(result, "A sourced result."); XCTAssertEqual(client.reads, 1)
        // Connect then needs no prompt and records the connection.
        _ = await connectors.connect(.calendar, store: store)
        XCTAssertEqual(client.requests, 0); XCTAssertEqual(store.state.enabledConnectors, ["calendar"])
        XCTAssertEqual(ConnectorStore(client: MockConnectionClient(permission: .limited)).status(.contacts, state: store.state), .limited)
        XCTAssertEqual(ConnectorStore(client: MockConnectionClient(permission: .notDetermined)).status(.calendar, state: SavedState()), .disconnected)
    }
    /// A file from an earlier build, with permission already granted, reads as connected.
    @MainActor func testExistingUsersWithPermissionSeeConnected() throws {
        let legacy = Data(#"{"theme":\#(String(decoding: try JSONEncoder().encode(BotTheme.presets[0]), as: UTF8.self)),"memories":[],"messages":[],"standupFormat":"x","onboarded":true}"#.utf8)
        let state = try JSONDecoder().decode(SavedState.self, from: legacy)
        XCTAssertNil(state.enabledConnectors); XCTAssertNil(state.disconnectedConnectors)
        XCTAssertEqual(ConnectorStore(client: MockConnectionClient(permission: .allowed)).status(.calendar, state: state), .connected)
        XCTAssertEqual(state.kemoAllowedConnectors, [.calendar, .reminders, .contacts])
        XCTAssertFalse(state.kemoAllows(.gmail), "Services that aren't native never count")
    }
    /// Disconnect is remembered across launches, overrides Apple's permission, and Connect clears it.
    @MainActor func testDisconnectPersistsUntilConnect() async throws {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = MockConnectionClient(permission: .allowed)
        let connectors = ConnectorStore(client: client)
        _ = connectors.disconnect(.calendar, store: store)
        XCTAssertEqual(connectors.status(.calendar, state: store.state), .disconnected)
        let loaded = try LocalRepository(url: folder.appendingPathComponent("state.json")).read()
        XCTAssertEqual(loaded.disconnectedConnectors, ["calendar"])
        XCTAssertEqual(connectors.status(.calendar, state: loaded), .disconnected, "Permission alone doesn't turn it back on")
        XCTAssertEqual(connectors.status(.reminders, state: loaded), .connected, "Only the one connection is off")
        _ = await connectors.read(.calendar, store: store); XCTAssertEqual(client.reads, 0)
        _ = await connectors.connect(.calendar, store: store)
        XCTAssertEqual(client.requests, 0, "Apple already allows it; no prompt")
        XCTAssertEqual(connectors.status(.calendar, state: store.state), .connected)
        let reloaded = try LocalRepository(url: folder.appendingPathComponent("state.json")).read()
        XCTAssertNil(reloaded.disconnectedConnectors); XCTAssertEqual(reloaded.enabledConnectors, ["calendar"])
    }
    /// "Add events only" can't read events: Connect says how to fix it instead of asking again.
    @MainActor func testWriteOnlyCalendarPointsToFullAccess() async {
        let (store, folder) = makeStore(); defer { try? FileManager.default.removeItem(at: folder) }
        let client = MockConnectionClient(permission: .writeOnly)
        let connectors = ConnectorStore(client: client)
        let status = connectors.status(.calendar, state: store.state)
        XCTAssertEqual(status, .writeOnly); XCTAssertFalse(status.usable); XCTAssertTrue(status.opensSystemSettings)
        let reply = await connectors.connect(.calendar, store: store)
        #if os(iOS)
        XCTAssertEqual(reply, "KemoSabe can only add events. In Settings → KemoSabe → Calendars, choose Full Access.")
        #endif
        XCTAssertEqual(connectors.message, reply)
        XCTAssertEqual(client.requests, 0); XCTAssertNil(store.state.enabledConnectors)
        let read = await connectors.read(.calendar, store: store)
        XCTAssertEqual(read, reply); XCTAssertEqual(client.reads, 0)
        XCTAssertEqual(ConnectorStatus.resolve(native: true, enabled: false, permission: .writeOnly), .writeOnly)
    }
    /// Denied, restricted, and limited each explain themselves and offer Settings.
    func testPermissionStatesExplainWhereToChangeThem() throws {
        for (permission, status) in [(ConnectorPermission.denied, ConnectorStatus.denied), (.restricted, .restricted), (.limited, .limited)] {
            let resolved = ConnectorStatus.resolve(native: true, enabled: true, permission: permission)
            XCTAssertEqual(resolved, status)
            XCTAssertTrue(resolved.opensSystemSettings)
            let text = try XCTUnwrap(resolved.guidance(for: permission == .limited ? .contacts : .reminders))
            XCTAssertFalse(text.isEmpty)
        }
        XCTAssertTrue(try XCTUnwrap(ConnectorStatus.denied.guidance(for: .calendar)).contains("Calendars"))
        XCTAssertTrue(try XCTUnwrap(ConnectorStatus.restricted.guidance(for: .contacts)).contains("Screen Time"))
        XCTAssertNil(ConnectorStatus.connected.guidance(for: .calendar)); XCTAssertFalse(ConnectorStatus.connected.opensSystemSettings)
        XCTAssertNil(ConnectorStatus.disconnected.guidance(for: .calendar))
    }
    @MainActor private func makeStore() -> (AppStore, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (AppStore(repository: .init(url: folder.appendingPathComponent("state.json")), provider: DelayedProvider()), folder)
    }
}

/// An injectable permission client: no system privacy database is touched. `afterRequest` is what
/// Apple's prompt leaves behind; without it the permission doesn't change.
final class MockConnectionClient: NativeConnectionClient, @unchecked Sendable {
    let delay: Int
    private let afterRequest: ConnectorPermission?
    private let lock = NSLock()
    private var current: ConnectorPermission
    private var requestCount = 0, readCount = 0
    var requests: Int { lock.withLock { requestCount } }
    var reads: Int { lock.withLock { readCount } }
    init(permission: ConnectorPermission, delay: Int = 0, afterRequest: ConnectorPermission? = nil) {
        current = permission; self.delay = delay; self.afterRequest = afterRequest
    }
    func permission(_ id: ConnectorID) -> ConnectorPermission { lock.withLock { current } }
    func request(_ id: ConnectorID) async throws -> Bool {
        lock.withLock { requestCount += 1 }; try? await Task.sleep(for: .milliseconds(delay))
        return lock.withLock {
            if let afterRequest { current = afterRequest }
            return current == .allowed || current == .limited
        }
    }
    func read(_ id: ConnectorID, query: String?) async throws -> String {
        lock.withLock { readCount += 1 }; try? await Task.sleep(for: .milliseconds(delay)); return "A sourced result."
    }
}
