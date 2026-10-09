#if os(macOS)
import Foundation

// The BLE setup commands behind the GATT characteristics, independent of CoreBluetooth. Ported from
// Meta's Muse Gadget SDK (Apache-2.0), `linux/src/musegadget/ble_setup.py`: plaintext `get_device_info` at
// any time, the v5 handshake, sensitive actions only inside a confirmed encrypted session, `wifi_scan`
// offering only "the current connection", and `provision_v2` ignoring the Wi-Fi fields it gets back.
// Every send happens under one lock, so encrypted record counters reach the phone in order.
// Tsukumo adds one step the SDK doesn't have: `confirm_app` means only the phone confirmed, so after the
// handshake the owner must allow it on the Mac (with a code from the transcript) before `pairing_confirmed`
// (which carries the SDK token) is sent or any provisioning is accepted. Refused or unanswered closes it.
// Provenance: TsukumoKit/MUSE-NOTICE.md.

/// Where setup sends its packets (CoreBluetooth in the app, a recorder in tests).
public protocol MuseSetupTransport: AnyObject, Sendable {
    /// Queues each packet in order; the transport paces them.
    func send(packets: [[UInt8]])
    /// The negotiated ATT MTU.
    var mtu: Int { get }
    /// Drops the phone's connection after a moment, when it can.
    func disconnect(after delay: Duration)
    /// What the radio knows about the connected phone, for the owner (CoreBluetooth's per-Mac identifier).
    var peer: String? { get }
}

extension MuseSetupTransport {
    public var peer: String? { nil }
}

/// What the owner is asked to allow: this session's code, and whatever identifies the connected phone.
public struct MusePairingRequest: Hashable, Sendable {
    public let code: String
    public let peer: String?
    public init(code: String, peer: String?) { self.code = code; self.peer = peer }
}

/// Whether this Mac is online, and the one network setup offers.
public protocol MuseNetwork: Sendable {
    func isOnline() -> Bool
}

/// What `provision_v2` hands over. The Wi-Fi fields are never kept.
public struct MuseSetupCredentials: Hashable, Sendable {
    public let accessToken, refreshToken, username, apiURL, apiURLv2, noiseHost: String
}

public enum MuseProvisionFailure: Error, Equatable { case status(String) }

public final class MuseSetupController: @unchecked Sendable {
    public typealias Commit = @Sendable (_ save: () -> Bool) -> Bool
    public typealias Provision = @Sendable (MuseSetupCredentials, Commit) async throws -> Void

    static let sensitive: Set<String> = ["provision", "provision_v2", "wifi_scan", "ota", "device.ota", "unpair", "set_wifi", "set_auth"]
    static let plaintextStatuses: Set<String> = ["error_encryption_required", "error_pairing_invalid_hello", "error_pairing_unavailable", "error_pairing_decrypt"]
    /// The one network offered: marked open so the apps skip the password, which the Mac ignores anyway.
    public static let currentConnection = "Use current connection"

    let pairing: MusePairingSession
    let identity: MuseIdentity
    let version: String
    weak var transport: (any MuseSetupTransport)?
    let network: any MuseNetwork
    let provision: Provision
    let onComplete: @Sendable () -> Void
    /// Asks the owner on the Mac to allow this phone, with the session's code; false refuses.
    let confirm: @Sendable (MusePairingRequest) async -> Bool
    /// The owner refused (or didn't answer): pairing closes.
    let onRefused: @Sendable () -> Void
    /// Each step, for the owner's status line ("Muse app connected", "Saving…"); never secrets.
    let onStep: @Sendable (String) -> Void

    private let txLock = NSLock()
    private let stateLock = NSLock()
    private let queue = DispatchQueue(label: "com.zlichtman.tsukumo.muse.setup")
    private var assembler = MuseChunkAssembler()
    private var plaintextBlocked = false
    private var provisioning = false
    /// Takes down a confirmation that a newer hello replaced (without refusing or closing pairing).
    let onConfirmationReplaced: @Sendable (_ code: String) -> Void
    /// The owner's confirmation in flight, for tests.
    public private(set) var confirmTask: Task<Void, Never>?
    /// The provisioning in flight, for tests.
    public private(set) var provisionTask: Task<Void, Never>?

    public init(pairing: MusePairingSession, identity: MuseIdentity, version: String, transport: any MuseSetupTransport, network: any MuseNetwork,
                provision: @escaping Provision, confirm: @escaping @Sendable (MusePairingRequest) async -> Bool,
                onComplete: @escaping @Sendable () -> Void = {}, onRefused: @escaping @Sendable () -> Void = {},
                onConfirmationReplaced: @escaping @Sendable (_ code: String) -> Void = { _ in }, onStep: @escaping @Sendable (String) -> Void = { _ in }) {
        self.pairing = pairing; self.identity = identity; self.version = version; self.transport = transport
        self.network = network; self.provision = provision; self.confirm = confirm; self.onComplete = onComplete
        self.onRefused = onRefused; self.onConfirmationReplaced = onConfirmationReplaced; self.onStep = onStep
    }

    // MARK: From the transport (any thread)

    /// One write from the phone; whole messages are handled one at a time, in order.
    public func received(_ packet: [UInt8]) {
        queue.async { [self] in
            guard let message = stateLock.withLock({ assembler.feed(packet) }) else { return }
            handle(message)
        }
    }
    /// The phone went away: the session is cleared.
    public func disconnected() {
        queue.async { [self] in
            stateLock.withLock { assembler.reset(); plaintextBlocked = false }
            pairing.reset()
        }
    }
    /// Waits until every write received so far has been handled (tests).
    public func drain() async {
        await withCheckedContinuation { continuation in queue.async { continuation.resume() } }
    }

    // MARK: Dispatch

    func handle(_ raw: [UInt8], decrypted: Bool = false) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(raw)), let command = object as? [String: Any] else {
            sendStatus("error_invalid_command")
            return
        }
        let action = command["action"] as? String ?? ""
        let blocked = stateLock.withLock { plaintextBlocked }
        if !decrypted && action == "pairing_client_hello" {
            hello(command)
        } else if !decrypted && action == "pairing_encrypted" {
            record(command)
        } else if action == "get_device_info" {
            // Public, safe in plaintext at any point; apps read it again when they restart a handshake.
            sendJSON(deviceInfo)
        } else if !decrypted && blocked {
            return
        } else if !decrypted && Self.sensitive.contains(action) {
            sendStatus("error_encryption_required")
        } else if decrypted && action == "pairing_client_finished" {
            clientFinished(command)
        } else if decrypted && Self.sensitive.contains(action) && !pairing.ownerConfirmed {
            sendStatus("error_pairing_confirm_required")
        } else if decrypted && action == "wifi_scan" {
            let networks: [[String: Any]] = network.isOnline() ? [["ssid": Self.currentConnection, "rssi": -40, "secure": false]] : []
            sendEncrypted(["type": "wifi_scan_result", "networks": networks])
        } else if decrypted && action == "provision_v2" {
            provisionV2(command)
        } else {
            sendStatus("error_unknown_action")
        }
    }

    public var deviceInfo: [String: Any] {
        var info: [String: Any] = ["type": "device_info", "node_id": identity.nodeID, "version": version, "build_sha": "",
                                   "network_ready": network.isOnline()]
        for (key, value) in pairing.deviceInfo { info[key] = value.any }
        return info
    }

    private func hello(_ command: [String: Any]) {
        // Once the owner has allowed a phone (or it's setting up), no other hello may take its place.
        if pairing.ownerConfirmed || pairing.currentState == .provisioning {
            sendStatus("error_pairing_unavailable")
            return
        }
        // A new hello replaces an unfinished session: the owner's pending confirmation for it is void (its
        // code is gone), and the new session needs its own Allow with its own code.
        let replaced = pairing.currentState != .idle ? pairing.verificationCode : nil
        do {
            let ready = try pairing.handleHello(command)
            if let replaced { onConfirmationReplaced(replaced) }
            stateLock.withLock { plaintextBlocked = true }
            onStep("The Muse app connected.")
            sendJSON(ready.mapValues(\.any))
        } catch MusePairingError.status(let status) {
            sendStatus(status)
        } catch {
            sendStatus(MusePairing.invalidHello)
        }
    }

    private func record(_ envelope: [String: Any]) {
        let plaintext: String
        do { plaintext = try pairing.decrypt(envelope) } catch {
            sendStatus(MusePairing.decryptFailed)
            transport?.disconnect(after: .milliseconds(300))
            return
        }
        handle(Array(plaintext.utf8), decrypted: true)
    }

    private func clientFinished(_ command: [String: Any]) {
        let generation = pairing.handleClientFinished(command)
        guard generation != 0 else {
            sendStatus(MusePairing.decryptFailed)
            transport?.disconnect(after: .milliseconds(300))
            return
        }
        // Nothing secret goes out until the owner allows this phone, this session, on the Mac.
        let code = pairing.verificationCode ?? "------", sessionID = pairing.currentSessionID
        let request = MusePairingRequest(code: code, peer: transport?.peer)
        onStep("Confirmed in the Muse app. Allow it on this Mac.")
        let pairing = self.pairing, confirm = self.confirm
        confirmTask = Task { [weak self] in
            let allowed = await confirm(request)
            guard let self else { return }
            // Replaced by a newer hello meanwhile: this answer belongs to a session that no longer exists.
            guard pairing.isCurrent(generation) else { return }
            // The approval sticks only to this exact session, checked and recorded under the session's own lock.
            guard allowed, pairing.approve(generation: generation, sessionID: sessionID) else {
                pairing.reset()
                self.transport?.disconnect(after: .milliseconds(300))
                self.onRefused()
                return
            }
            self.onStep("Allowed on this Mac.")
            self.sendStatus("pairing_confirmed", generation: generation)
        }
    }

    private func provisionV2(_ command: [String: Any]) {
        func text(_ key: String) -> String { command[key] as? String ?? "" }
        guard command["ssid"] is String, command["password"] is String, !text("access_token").isEmpty, !text("refresh_token").isEmpty,
              text("token_type") == "device" else {
            sendStatus("error_missing_credentials")
            return
        }
        var marked = 0
        let refusal: String? = stateLock.withLock {
            if provisioning { return "error_operation_in_progress" }
            marked = pairing.markProvisioning()
            provisioning = marked != 0
            return marked != 0 ? nil : "error_pairing_confirm_required"
        }
        if let refusal { sendStatus(refusal); return }
        // The Wi-Fi fields are dropped on purpose: the Mac is already online.
        let credentials = MuseSetupCredentials(accessToken: text("access_token"), refreshToken: text("refresh_token"), username: text("username"),
                                               apiURL: text("api_url"), apiURLv2: text("api_url_v2"), noiseHost: text("noise_host"))
        let pairing = self.pairing, provision = self.provision, generation = marked
        provisionTask = Task { [weak self] in
            defer { self?.stateLock.withLock { self?.provisioning = false } }
            guard let self else { return }
            self.sendStatus("wifi_connecting", generation: generation)
            guard self.network.isOnline() else {
                // Still provisioning, so the app can try again, as the firmware does.
                _ = pairing.extendProvisioning(generation)
                self.sendStatus("wifi_failed", generation: generation)
                return
            }
            self.sendStatus("wifi_connected", generation: generation)
            self.onStep("Checking with Muse…")
            do {
                try await provision(credentials) { save in pairing.commitProvisioning(generation, save) }
            } catch {
                let status = (error as? MuseProvisionFailure).map { if case .status(let s) = $0 { s } else { "auth_failed" } } ?? "auth_failed"
                self.sendStatus(status, generation: generation)
                self.transport?.disconnect(after: .milliseconds(500))
                return
            }
            // A pairing closed meanwhile (cancelled, unpaired, timed out) never completes.
            guard pairing.isCurrent(generation) else { return }
            self.sendStatus("auth_ok", generation: generation)
            self.onComplete()
        }
    }

    // MARK: Sending

    func sendStatus(_ status: String, generation: Int = 0) {
        txLock.withLock {
            if let envelope = pairing.encryptStatus(status, generation: generation) {
                sendLocked(MusePairing.compact(envelope))
                return
            }
            let blocked = stateLock.withLock { plaintextBlocked }
            guard generation == 0, !blocked, Self.plaintextStatuses.contains(status) else { return }
            transport?.send(packets: [Array(status.utf8)])
        }
    }
    func sendJSON(_ object: [String: Any]) {
        txLock.withLock { sendLocked(Self.json(object)) }
    }
    func sendEncrypted(_ object: [String: Any], generation: Int = 0) {
        txLock.withLock {
            guard let envelope = pairing.encrypt(Self.json(object), generation: generation) else { return }
            sendLocked(MusePairing.compact(envelope))
        }
    }
    private func sendLocked(_ text: String) {
        guard let transport, let packets = try? MuseBLEFraming.chunks(Array(text.utf8), mtu: transport.mtu) else { return }
        transport.send(packets: packets)
    }
    static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
#endif
