#if os(macOS)
import Foundation

// Keeps a paired Mac connected to its Muse. Ported from Meta's Muse Gadget SDK (Apache-2.0),
// `linux/src/musegadget/service.py`: each round fetches the leased VMs with the device token (which also
// gives a fresh per-VM bearer), connects to the default VM, and serves until the connection ends. Failures
// back off exponentially to a minute; a session that stayed up 30 seconds resets the backoff; a refused
// bearer or a 403 waits at least 15 seconds. The device token rotates every 3 hours, at once when the API
// refuses it, and once at start to report the SDK token. A 401 on refresh means the pairing is gone.
// Provenance: TsukumoKit/MUSE-NOTICE.md.

public struct MuseBackoff: Sendable {
    public static let base: TimeInterval = 2, ceiling: TimeInterval = 60, authFloor: TimeInterval = 15
    public var failures = 0
    public var floor: TimeInterval = 0
    public init() {}
    public mutating func next() -> TimeInterval {
        let delay = min(Self.base * pow(2, Double(min(failures, 16))), Self.ceiling)
        failures += 1
        return max(delay, floor)
    }
    public mutating func reset() { failures = 0; floor = 0 }
}

public actor MuseService {
    public enum Status: Sendable, Equatable {
        case connecting
        case connected(String)
        /// Waiting to try again, and why.
        case retrying(TimeInterval, String)
        /// Muse removed this Mac, or its pairing was revoked: pair again.
        case unpaired
        case stopped
        /// The saved pairing points somewhere that isn't Muse's: nothing is sent.
        case refused(String)
    }

    public static let defaultNoiseHost = "hatch.metaaivm.com"
    public static let healthySession: TimeInterval = 30
    public static let tokenRefreshAge: TimeInterval = 3 * 3600, tokenRetry: TimeInterval = 300

    var identity: MuseIdentity
    let secrets: any MuseSecrets
    let api: MuseAPI
    let connector: any MuseSocketConnector
    let handler: any MuseCommandHandler
    let displayName: String
    let version: String
    let onStatus: @Sendable (Status) -> Void
    /// Muse refused `link.register` as a Mac: the identity now registers as the SDK's Linux device.
    let onIdentityChange: @Sendable (MuseIdentity) -> Void
    let sleep: @Sendable (TimeInterval) async -> Void
    let now: @Sendable () -> Date
    let log: @Sendable (String) -> Void
    /// The owner's pairing as it was when this service started; a write after it moved on is refused.
    let lifecycle: MuseLifecycle
    let generation: Int

    private var lastRefreshAttempt: Date?
    private var sdkTokenReported = false
    public private(set) var current: MuseLinkSession?

    public init(identity: MuseIdentity, secrets: any MuseSecrets, api: MuseAPI, connector: any MuseSocketConnector, handler: any MuseCommandHandler,
                displayName: String, version: String, onStatus: @escaping @Sendable (Status) -> Void = { _ in },
                onIdentityChange: @escaping @Sendable (MuseIdentity) -> Void = { _ in },
                sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) },
                now: @escaping @Sendable () -> Date = Date.init, log: @escaping @Sendable (String) -> Void = { _ in },
                lifecycle: MuseLifecycle = MuseLifecycle()) {
        self.identity = identity; self.secrets = secrets; self.api = api; self.connector = connector; self.handler = handler
        self.displayName = displayName; self.version = version; self.onStatus = onStatus; self.onIdentityChange = onIdentityChange
        self.sleep = sleep; self.now = now; self.log = log
        self.lifecycle = lifecycle; generation = lifecycle.current
    }

    /// Saves (or, with nil, forgets) the pairing only while the owner's pairing is still the one this started with.
    @discardableResult
    private func store(_ credentials: MuseCredentials?) -> Bool {
        lifecycle.ifCurrent(generation) { (try? secrets.setCredentials(credentials)) != nil }
    }

    /// Serves until the task is cancelled, or until the pairing is gone.
    public func run() async {
        var backoff = MuseBackoff()
        while !Task.isCancelled && lifecycle.current == generation {
            guard let saved = secrets.credentials() else { onStatus(.unpaired); return }
            guard MuseAPI.root(saved.apiURLv2) != nil, MuseEndpoints.noiseHost(saved.noiseHost) != nil else {
                onStatus(.refused("This Mac’s Muse pairing points somewhere that isn’t Muse. Unpair and pair again."))
                return
            }
            guard let credentials = await maybeRefresh(saved) else {
                if secrets.credentials() == nil { onStatus(.unpaired); return }
                onStatus(.retrying(Self.tokenRetry, "Couldn’t renew this Mac’s Muse sign-in."))
                await sleep(Self.tokenRetry)
                continue
            }
            onStatus(.connecting)
            guard let root = MuseAPI.root(credentials.apiURLv2) else { return }
            let (vms, status) = await api.fetchVMs(accessToken: credentials.accessToken, root: root)
            if status == 401 {
                log("device token rejected by the API; refreshing")
                if await maybeRefresh(credentials, force: true) == nil {
                    if secrets.credentials() == nil { onStatus(.unpaired); return }
                    await sleep(Self.tokenRetry)
                }
                continue
            }
            guard let vm = vms.first(where: \.isDefault) ?? vms.first else {
                let delay = backoff.next()
                onStatus(.retrying(delay, "Muse isn’t reachable right now."))
                await sleep(delay)
                continue
            }
            let (outcome, lasted) = await session(vm, credentials)
            switch outcome {
            case .stopped:
                onStatus(.stopped)
                return
            case .unpaired:
                store(nil)
                log("the Muse removed this device")
                onStatus(.unpaired)
                return
            default: break
            }
            if lasted >= Self.healthySession { backoff.reset() }
            if outcome == .authRejected || outcome == .forbidden { backoff.floor = MuseBackoff.authFloor }
            let delay = backoff.next()
            onStatus(.retrying(delay, outcome == .forbidden ? "Muse didn’t allow the connection just now." : "The connection to Muse ended."))
            await sleep(delay)
        }
        onStatus(.stopped)
    }

    private func session(_ vm: MuseVM, _ credentials: MuseCredentials) async -> (MuseLinkSession.Outcome, TimeInterval) {
        let device = MuseDeviceDescription(nodeID: identity.nodeID, displayName: displayName, version: version,
                                           registration: identity.registration, commands: handler.commands)
        let session = MuseLinkSession(noiseHost: MuseEndpoints.noiseHost(credentials.noiseHost) ?? Self.defaultNoiseHost,
                                      vmID: vm.id.isEmpty ? vm.name : vm.id, vmAuthToken: vm.authToken, device: device,
                                      handler: handler, connector: connector, log: log)
        current = session
        let watcher = Task { [onStatus] in
            // Connected once Muse accepts the registration.
            for _ in 0..<600 {
                if Task.isCancelled { return }
                if await session.registeredAt != nil { onStatus(.connected(vm.name.isEmpty ? vm.id : vm.name)); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let outcome = await session.run()
        watcher.cancel()
        current = nil
        let registered = await session.registeredAt
        if await session.registerRejected != nil, identity.registration == .mac {
            identity.registration = .linuxCompatible
            onIdentityChange(identity)
            log("link.register refused as a Mac; registering as the SDK's Linux device from now on")
        }
        return (outcome, registered.map { now().timeIntervalSince($0) } ?? 0)
    }

    /// The credentials to use, rotated first when due. Nil only when a due refresh failed; the pairing is
    /// removed when Muse says it's revoked.
    func maybeRefresh(_ credentials: MuseCredentials, force: Bool = false) async -> MuseCredentials? {
        let token = secrets.sdkToken()
        let age = now().timeIntervalSince(credentials.savedAt)
        let reportDue = token != nil && !sdkTokenReported
        let due = force || age >= Self.tokenRefreshAge
        guard due || reportDue else { return credentials }
        if !force, let last = lastRefreshAttempt, now().timeIntervalSince(last) < Self.tokenRetry { return credentials }
        lastRefreshAttempt = now()
        if reportDue { sdkTokenReported = true }
        guard let root = MuseAPI.root(credentials.apiURLv2) else { return nil }
        let (tokens, status) = await api.refresh(refreshToken: credentials.refreshToken, deviceID: identity.nodeID,
                                                 root: root, sdkToken: token)
        if let tokens {
            var next = credentials
            next.accessToken = tokens.access
            next.refreshToken = tokens.refresh
            next.savedAt = now()
            // Unpaired or stopped while the refresh was out: the new tokens are dropped, never saved.
            guard store(next) else { return nil }
            log("device token rotated")
            return next
        }
        // Only reporting the SDK token: nothing refused the current token, so this never unpairs.
        guard due else { return credentials }
        if status == 401 {
            store(nil)
            log("pairing revoked")
            return nil
        }
        return force ? nil : credentials
    }

    /// A message to the owner's Muse chat, on the live session.
    public func sendChat(_ text: String, sessionID: String? = nil) async throws -> MuseChatResult {
        guard let current else { throw MuseNoiseError("not connected to the Muse") }
        return try await current.sendChat(text, sessionID: sessionID)
    }
}
#endif
