#if os(macOS)
import Foundation
import Network
import Observation

// Tsukumo's Dock as a Muse gadget, for the Mac app's Settings: the owner's own SDK token, pairing with the
// Muse app over Bluetooth for five minutes when the owner clicks Pair (single use: one pairing, a refusal, or
// the time running out closes it), the owner allowing the phone on the Mac before anything secret leaves,
// the link afterwards, and Unpair. Off by default: nothing advertises or connects until the owner has saved
// a token and paired. Every credential write checks the lifecycle (`MuseLifecycle`), so work from a closed
// pairing or an unpaired Mac can't bring a pairing back.

/// What pairing talks over: CoreBluetooth in the app (`MusePeripheral`), a fake in tests.
public protocol MusePairingRadio: MuseSetupTransport {
    var onWrite: (@Sendable ([UInt8]) -> Void)? { get set }
    var onDisconnect: (@Sendable () -> Void)? { get set }
    var onProblem: (@Sendable (MusePeripheral.Problem?) -> Void)? { get set }
    /// Advertising started (true) or stopped (false).
    var onAdvertising: (@Sendable (Bool) -> Void)? { get set }
    func start()
    func stop()
}
public extension MusePairingRadio {
    /// A radio that doesn't report advertising (a stand-in) never says it started.
    var onAdvertising: (@Sendable (Bool) -> Void)? { get { nil } set {} }
}
extension MusePeripheral: MusePairingRadio {}

/// What Bluetooth is doing for pairing, in words for Settings: whether the Muse app can see this Mac, and if not, why.
public enum MuseBluetoothStatus: Equatable, Sendable {
    /// Pairing isn't open.
    case idle
    /// Pairing was opened; waiting for macOS to start advertising.
    case starting
    /// Advertising: the Muse app can find this Mac under this name.
    case visible(String)
    case off
    case notAllowed
    case unsupported
    case failed(String)

    /// System Settings, Privacy & Security, Bluetooth.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!

    /// The status for a radio's problem (nil: nothing wrong).
    public static func from(_ problem: MusePeripheral.Problem) -> MuseBluetoothStatus {
        switch problem {
        case .bluetoothOff: .off
        case .notAllowed: .notAllowed
        case .unsupported: .unsupported
        case .failed(let why): .failed(why)
        }
    }

    /// One line for Settings; nil while idle.
    public var message: String? {
        switch self {
        case .idle: nil
        case .starting: "Starting Bluetooth…"
        case .visible(let name): "Visible as \(name)"
        case .off: "Bluetooth is off. Turn it on in Control Center, then click Pair again."
        case .notAllowed: "Tsukumo isn’t allowed to use Bluetooth. Allow it in System Settings, Privacy & Security, Bluetooth, then click Pair again."
        case .unsupported: "This Mac can’t be a Bluetooth accessory, so the Muse app can’t find it."
        case .failed(let why): "Bluetooth couldn’t start advertising: \(why)"
        }
    }
    /// Whether the fix is in System Settings' Bluetooth privacy page.
    public var opensBluetoothSettings: Bool { self == .notAllowed || self == .off }
    public var isProblem: Bool {
        switch self {
        case .off, .notAllowed, .unsupported, .failed: true
        default: false
        }
    }
    /// "Visible as MuseGadgetA1B2C3 for 4:59", while pairing is open.
    public static func visibleLine(_ name: String, until: Date, now: Date) -> String {
        let left = max(0, Int(until.timeIntervalSince(now).rounded(.down)))
        return "Visible as \(name) for \(left / 60):" + String(format: "%02d", left % 60)
    }
}

@MainActor @Observable public final class MuseGadget {
    public enum Phase: Equatable, Sendable {
        /// No SDK token yet.
        case needsToken
        /// A token, not paired.
        case notPaired
        /// Bluetooth pairing is open until then.
        case pairing(until: Date)
        case connecting
        case connected
        case retrying(String)
        case problem(String)
    }

    /// "A phone wants to pair as your Muse device", with this attempt's code, until the owner answers.
    public struct Confirmation: Equatable, Sendable {
        public let code: String
        /// What Bluetooth says about the phone (its identifier on this Mac), when it says anything.
        public let peer: String?
        public let until: Date
    }

    public static let pairingWindow: TimeInterval = 300
    public static let version = "1"

    public private(set) var phase: Phase = .needsToken
    public private(set) var hasToken = false
    public private(set) var isPaired = false
    /// What pairing is doing now ("The Muse app connected."), while it's open.
    public private(set) var pairingStep: String?
    /// A phone waiting for the owner to allow it.
    public private(set) var confirmation: Confirmation?
    public private(set) var identity: MuseIdentity
    /// The last test message's result.
    public private(set) var testResult: String?
    /// What Bluetooth is doing for pairing: starting, visible to the Muse app, or why not.
    public private(set) var bluetooth: MuseBluetoothStatus = .idle

    /// The name the Muse app lists ("MuseGadgetA1B2C3").
    public var deviceName: String { identity.bleName }

    let identityFile: URL
    let secrets: any MuseSecrets
    let api: MuseAPI
    let connector: any MuseSocketConnector
    let network: any MuseNetwork
    let displayName: String
    /// The Bluetooth side, or nil where it isn't used (`--ui-testing`).
    let makeRadio: (@MainActor (String) -> any MusePairingRadio)?
    public let lifecycle = MuseLifecycle()
    @ObservationIgnored public var handler: (any MuseCommandHandler)?
    /// A phone is waiting for the owner (the app shows its confirmation window).
    @ObservationIgnored public var onConfirmationNeeded: (@MainActor () -> Void)?
    /// Muse became paired (true) or stopped being paired (false), however that happened: the owner's Pair or Unpair,
    /// Muse removing this Mac, or the pairing's credentials gone. The app adds Muse to the KemoSabe gateway's callers,
    /// or revokes it there.
    @ObservationIgnored public var onPairingChanged: (@MainActor (Bool) -> Void)?
    @ObservationIgnored public var confirmationTimeout: Duration = .seconds(60)
    @ObservationIgnored private var service: MuseService?
    @ObservationIgnored private var serviceTask: Task<Void, Never>?
    @ObservationIgnored private var radio: (any MusePairingRadio)?
    @ObservationIgnored private(set) var setup: MuseSetupController?
    @ObservationIgnored private var windowTask: Task<Void, Never>?
    @ObservationIgnored private var confirmationWaiter: CheckedContinuation<Bool, Never>?

    public init(folder: URL, secrets: any MuseSecrets, displayName: String, api: MuseAPI = MuseAPI(),
                connector: any MuseSocketConnector = URLSessionMuseConnector(), network: any MuseNetwork = SystemMuseNetwork(),
                makeRadio: (@MainActor (String) -> any MusePairingRadio)? = { MusePeripheral(name: $0) }) {
        identityFile = folder.appendingPathComponent("muse-identity.json")
        identity = MuseIdentity.loadOrCreate(file: identityFile)
        self.secrets = secrets; self.api = api; self.connector = connector; self.network = network
        self.displayName = displayName; self.makeRadio = makeRadio
        hasToken = secrets.sdkToken() != nil
        isPaired = secrets.credentials() != nil
        phase = hasToken ? (isPaired ? .connecting : .notPaired) : .needsToken
    }

    /// Connects when there's a token and a pairing; otherwise does nothing.
    public func start() {
        guard hasToken, isPaired, serviceTask == nil, let handler else { refreshPhase(); return }
        // Every callback names the lifecycle it started in, so an older service can't change a newer one.
        let generation = lifecycle.current
        let service = MuseService(identity: identity, secrets: secrets, api: api, connector: connector, handler: handler,
                                  displayName: displayName, version: Self.version,
                                  onStatus: { [weak self] status in Task { @MainActor in self?.apply(status, generation: generation) } },
                                  onIdentityChange: { [weak self] identity in Task { @MainActor in self?.saveIdentity(identity, generation: generation) } },
                                  lifecycle: lifecycle)
        self.service = service
        phase = .connecting
        serviceTask = Task { await service.run() }
    }

    public func stop() {
        stopService()
        closePairing()
        refreshPhase()
    }

    // MARK: The SDK token

    /// Saves the owner's token (this Mac's Keychain only); nil when it's saved, else why not.
    public func setToken(_ text: String) -> String? {
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard MuseSDKToken.isValid(token) else { return "That isn’t an SDK token. Copy it again from gadgets.muse.ai: it starts with mgst_." }
        do { try secrets.setSDKToken(token) } catch { return "Tsukumo couldn’t save it in this Mac’s Keychain." }
        hasToken = true
        refreshPhase()
        // The next step is pairing, so it opens at once (with its countdown) rather than waiting for a second click.
        if !isPaired, makeRadio != nil, autoPairAfterToken { pair() }
        return nil
    }
    /// Opens pairing as soon as a token is saved (the Mac app); off in tests that pair step by step.
    @ObservationIgnored public var autoPairAfterToken = false

    /// Turns Muse off on this Mac: forgets the token and the pairing, and disconnects.
    public func removeToken() {
        unpair()
        try? secrets.setSDKToken(nil)
        hasToken = false
        refreshPhase()
    }

    // MARK: Pairing

    /// Opens Bluetooth pairing for five minutes, for the Muse app to find this Mac. Single use.
    public func pair() {
        guard let token = secrets.sdkToken() else { refreshPhase(); return }
        guard let makeRadio else { phase = .problem("Bluetooth isn’t used in this test run."); return }
        closePairing()
        let generation = lifecycle.current
        let pairing = MusePairingSession(nodeID: identity.nodeID, deviceID: identity.deviceID, mac: identity.mac,
                                         firmwareVersion: Self.version, sdkToken: token)
        let radio = makeRadio(identity.bleName)
        let secrets = self.secrets, api = self.api, lifecycle = self.lifecycle
        let controller = MuseSetupController(
            pairing: pairing, identity: identity, version: Self.version, transport: radio, network: network,
            provision: { credentials, commit in
                try await Self.verifyAndSave(credentials, commit: commit, api: api, secrets: secrets, lifecycle: lifecycle, generation: generation)
            },
            confirm: { [weak self] request in await self?.askOwner(request, generation: generation) ?? false },
            onComplete: { [weak self] in Task { @MainActor in self?.paired(generation) } },
            onRefused: { [weak self] in Task { @MainActor in self?.refused(generation) } },
            onConfirmationReplaced: { [weak self] code in Task { @MainActor in self?.replaced(code, generation: generation) } },
            onStep: { [weak self] step in Task { @MainActor in if self?.lifecycle.current == generation { self?.pairingStep = step } } })
        radio.onWrite = { [weak controller] packet in controller?.received(packet) }
        radio.onDisconnect = { [weak controller] in controller?.disconnected() }
        radio.onProblem = { [weak self] problem in Task { @MainActor in self?.bluetooth(problem, generation: generation) } }
        radio.onAdvertising = { [weak self] on in Task { @MainActor in self?.advertising(on, generation: generation) } }
        bluetooth = .starting
        self.radio = radio
        setup = controller
        pairingStep = nil
        let until = Date().addingTimeInterval(Self.pairingWindow)
        phase = .pairing(until: until)
        radio.start()
        windowTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.pairingWindow))
            guard !Task.isCancelled, let self, self.lifecycle.current == generation else { return }
            self.closePairing()
            self.refreshPhase()
        }
    }

    public func cancelPairing() {
        closePairing()
        refreshPhase()
    }

    /// The owner's answer in the confirmation window: Allow sends the pairing on; Deny closes it.
    public func answerConfirmation(_ allow: Bool) {
        confirmation = nil
        confirmationWaiter?.resume(returning: allow)
        confirmationWaiter = nil
    }

    /// Forgets the pairing (the identity is kept) and disconnects. Muse keeps listing the device until it's
    /// removed in the Muse app too.
    public func unpair() {
        stopService()
        closePairing()
        let secrets = self.secrets
        lifecycle.advance { try? secrets.setCredentials(nil) }
        setPaired(false)
        refreshPhase()
    }

    /// Every change to `isPaired` goes through here, so `onPairingChanged` hears each transition exactly once.
    private func setPaired(_ paired: Bool) {
        guard isPaired != paired else { return }
        isPaired = paired
        onPairingChanged?(paired)
    }

    /// Sends the owner's message to their Muse, in the side chat `session` (Muse starts one for an id it hasn't seen;
    /// empty is the main chat), or throws when Muse isn't connected now.
    public func chat(_ text: String, session: String) async throws -> MuseChatResult {
        guard let service else { throw MuseNoiseError("not connected to the Muse") }
        return try await service.sendChat(text, sessionID: session.isEmpty ? nil : session)
    }

    /// Sends one line to the owner's Muse chat from this Mac, to check the link.
    public func sendTestMessage() async {
        guard let service else { testResult = "Not connected to Muse."; return }
        do {
            let result = try await service.sendChat("Hello from Tsukumo’s Dock on \(displayName).")
            testResult = result.ok ? "Sent. It’s in your Muse chat." : "Muse didn’t take it (HTTP \(result.status))."
        } catch {
            testResult = "Couldn’t send: \(error)"
        }
    }

    /// Checks where the credentials point (only Muse's own hosts) and the device token (by listing the VMs),
    /// then saves them while both the pairing session and the owner's pairing are still current.
    nonisolated static func verifyAndSave(_ credentials: MuseSetupCredentials, commit: MuseSetupController.Commit, api: MuseAPI,
                                          secrets: any MuseSecrets, lifecycle: MuseLifecycle, generation: Int) async throws {
        guard let root = MuseAPI.root(credentials.apiURLv2), MuseEndpoints.noiseHost(credentials.noiseHost) != nil else {
            throw MuseProvisionFailure.status("auth_failed")
        }
        let (vms, _) = await api.fetchVMs(accessToken: credentials.accessToken, root: root)
        guard !vms.isEmpty else { throw MuseProvisionFailure.status("auth_failed") }
        let record = MuseCredentials(accessToken: credentials.accessToken, refreshToken: credentials.refreshToken, username: credentials.username,
                                     apiURLv2: credentials.apiURLv2, noiseHost: credentials.noiseHost, savedAt: Date())
        let saved = commit { lifecycle.ifCurrent(generation) { (try? secrets.setCredentials(record)) != nil } }
        guard saved else { throw MuseProvisionFailure.status("error_storage") }
    }

    // MARK: Internals

    /// Shows the confirmation and waits for the owner, for this pairing only; no answer in time refuses.
    private func askOwner(_ request: MusePairingRequest, generation: Int) async -> Bool {
        guard lifecycle.current == generation else { return false }
        // A newer session's request replaces an older one still showing (that one is void).
        if confirmationWaiter != nil { answerConfirmation(false) }
        let timeout = confirmationTimeout
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        confirmation = Confirmation(code: request.code, peer: request.peer, until: Date().addingTimeInterval(seconds))
        pairingStep = "Allow the phone on this Mac."
        onConfirmationNeeded?()
        let timer = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled else { return }
            self?.answerConfirmation(false)
        }
        let allowed = await withCheckedContinuation { confirmationWaiter = $0 }
        timer.cancel()
        return allowed && lifecycle.current == generation
    }

    private func paired(_ generation: Int) {
        guard lifecycle.current == generation else { return }
        setPaired(true)
        pairingStep = nil
        // Let the last status reach the phone before Bluetooth closes; the window is used up either way.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(1500))
            guard let self, self.lifecycle.current == generation else { return }
            self.closePairing()
            self.start()
        }
    }

    /// A newer hello replaced the session whose confirmation shows: take it down, keep pairing open.
    private func replaced(_ code: String, generation: Int) {
        guard lifecycle.current == generation, confirmation?.code == code else { return }
        answerConfirmation(false)
        pairingStep = "Another phone started pairing. Allow only the one you’re pairing yourself."
    }

    private func refused(_ generation: Int) {
        guard lifecycle.current == generation else { return }
        closePairing()
        phase = .problem("Pairing wasn’t allowed on this Mac. Click Pair to try again.")
    }

    private func stopService() {
        serviceTask?.cancel()
        serviceTask = nil
        service = nil
    }

    /// Closes Bluetooth and makes every piece of work from this pairing stale.
    private func closePairing() {
        lifecycle.advance()
        windowTask?.cancel()
        windowTask = nil
        radio?.stop()
        radio = nil
        setup = nil
        pairingStep = nil
        bluetooth = .idle
        if confirmationWaiter != nil { answerConfirmation(false) }
        confirmation = nil
        // A running link started before this keeps going only if it's restarted on the new lifecycle.
        if serviceTask != nil, isPaired { stopService(); start() }
    }

    private func advertising(_ on: Bool, generation: Int) {
        guard lifecycle.current == generation, case .pairing = phase else { return }
        bluetooth = on ? .visible(deviceName) : .idle
    }

    private func bluetooth(_ problem: MusePeripheral.Problem?, generation: Int) {
        guard lifecycle.current == generation, case .pairing = phase, let problem else { return }
        closePairing()
        bluetooth = .from(problem)
        switch problem {
        case .bluetoothOff: phase = .problem("Turn on Bluetooth, then click Pair again.")
        case .notAllowed: phase = .problem("Allow Tsukumo to use Bluetooth in System Settings, Privacy & Security, Bluetooth.")
        case .unsupported: phase = .problem("This Mac can’t be a Bluetooth accessory.")
        case .failed(let why): phase = .problem("Bluetooth couldn’t start: \(why)")
        }
    }

    func apply(_ status: MuseService.Status, generation: Int) {
        // An older service (stopped, or replaced by a newer one) never changes what's running now.
        guard lifecycle.current == generation else { return }
        switch status {
        case .connecting: phase = .connecting
        case .connected: phase = .connected
        case .retrying(_, let why): phase = .retrying(why)
        case .refused(let why):
            stopService()
            phase = .problem(why)
        case .unpaired:
            stopService()
            setPaired(secrets.credentials() != nil)
            phase = isPaired ? .connecting : .problem("Muse removed this Mac. Pair again to reconnect.")
        case .stopped: refreshPhase()
        }
    }

    private func saveIdentity(_ identity: MuseIdentity, generation: Int) {
        guard lifecycle.current == generation else { return }
        self.identity = identity
        identity.save(file: identityFile)
    }

    private func refreshPhase() {
        if case .pairing = phase, radio != nil { return }
        if !hasToken { phase = .needsToken }
        else if !isPaired { phase = .notPaired }
        else if serviceTask == nil { phase = .connecting }
    }
}

/// Whether this Mac is online (Network's path monitor; nothing is contacted).
public final class SystemMuseNetwork: MuseNetwork, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var satisfied = true
    public init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.lock.withLock { self.satisfied = path.status == .satisfied }
        }
        monitor.start(queue: DispatchQueue(label: "com.zlichtman.tsukumo.muse.network"))
    }
    deinit { monitor.cancel() }
    public func isOnline() -> Bool { lock.withLock { satisfied } }
}
#endif
