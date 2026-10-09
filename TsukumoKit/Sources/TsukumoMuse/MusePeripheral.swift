#if os(macOS)
import CoreBluetooth
import Foundation
import os

// The GATT peripheral the Muse app pairs with, on CoreBluetooth. The CoreBluetooth counterpart of Meta's
// Muse Gadget SDK (Apache-2.0) `linux/src/musegadget/ble_server.py`: the same service and characteristic
// UUIDs, RX for the phone's writes, TX for notifications, and the advertised name `MuseGadgetXXXXXX`.
// It advertises only while the owner has opened pairing in Settings (five minutes, one pairing), never otherwise.
// What macOS doesn't allow: a peripheral can't advertise manufacturer data (the SDK's informational
// "paired" flag), can't set the Mac's own GAP name, and can't drop a central's connection, so a failed
// handshake clears the session instead. Advertising starting, stopping, and every Bluetooth state and error are logged
// at notice level (`log show --predicate 'subsystem == "com.zlichtman.tsukumo.mac" && category == "muse-bluetooth"'`),
// so a phone that can't find this Mac can be diagnosed. Provenance: TsukumoKit/MUSE-NOTICE.md.

public enum MuseGATT {
    public static let serviceUUID = "7fdd3d1c-38ea-46cf-8b46-314ecf5f240c"
    public static let rxUUID = "4d593029-28a2-4a6e-a1f0-3c2d5e8f9b01"
    public static let txUUID = "d75dc4ca-7b2b-4e9c-8f0a-1d2e3f4a5b6c"
    static var service: CBUUID { CBUUID(string: serviceUUID) }
    static var rx: CBUUID { CBUUID(string: rxUUID) }
    static var tx: CBUUID { CBUUID(string: txUUID) }
}

/// Advertises the setup service and carries setup's packets both ways.
public final class MusePeripheral: NSObject, MuseSetupTransport, CBPeripheralManagerDelegate, @unchecked Sendable {
    /// Why it isn't advertising, in words for Settings; nil while it is.
    public enum Problem: Sendable, Equatable { case bluetoothOff, notAllowed, unsupported, failed(String) }

    private let name: String
    private let queue = DispatchQueue(label: "com.zlichtman.tsukumo.muse.ble")
    private var manager: CBPeripheralManager?
    private var txCharacteristic: CBMutableCharacteristic?
    private var central: CBCentral?
    private var outbox: [[UInt8]] = []
    private var pumping = false
    private var advertising = false
    /// Until the phone's MTU is known, assume one big enough for full 160-byte packets, as the SDK does.
    private var negotiatedMTU = MuseBLEFraming.maxPacketBytes + 3

    public var onWrite: (@Sendable ([UInt8]) -> Void)?
    public var onDisconnect: (@Sendable () -> Void)?
    public var onProblem: (@Sendable (Problem?) -> Void)?
    /// Advertising started (true) or stopped (false), as CoreBluetooth reports it.
    public var onAdvertising: (@Sendable (Bool) -> Void)?

    static let log = Logger(subsystem: "com.zlichtman.tsukumo.mac", category: "muse-bluetooth")

    public init(name: String) { self.name = name }

    public func start() {
        queue.async { [self] in
            guard manager == nil else { return }
            Self.log.notice("Muse pairing: opening Bluetooth as \(self.name, privacy: .public)")
            manager = CBPeripheralManager(delegate: self, queue: queue)
        }
    }
    public func stop() {
        queue.async { [self] in
            if manager != nil { Self.log.notice("Muse pairing: stopped advertising \(self.name, privacy: .public)") }
            if advertising { onAdvertising?(false) }
            manager?.stopAdvertising()
            manager?.removeAllServices()
            manager?.delegate = nil
            manager = nil
            central = nil
            outbox = []
            advertising = false
        }
    }

    // MARK: MuseSetupTransport

    public var mtu: Int { queue.sync { negotiatedMTU } }

    /// The connected phone as CoreBluetooth names it to this Mac (a random identifier, not the phone's name).
    public var peer: String? {
        queue.sync { central.map { "Bluetooth ID " + String($0.identifier.uuidString.prefix(8)) } }
    }

    public func send(packets: [[UInt8]]) {
        queue.async { [self] in
            outbox += packets
            pump()
        }
    }

    /// CoreBluetooth has no way for a peripheral to drop a central; the setup session is cleared instead.
    public func disconnect(after delay: Duration) {
        let seconds = Double(delay.components.seconds) + Double(delay.components.attoseconds) / 1e18
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            central = nil
            outbox = []
            onDisconnect?()
        }
    }

    /// Notifications go one at a time, 50 ms apart, as the SDK paces them.
    private func pump() {
        guard !pumping, let manager, let tx = txCharacteristic, !outbox.isEmpty else { return }
        let packet = outbox[0]
        guard manager.updateValue(Data(packet), for: tx, onSubscribedCentrals: central.map { [$0] }) else {
            return  // Queue full: `peripheralManagerIsReady` pumps again.
        }
        outbox.removeFirst()
        guard !outbox.isEmpty else { return }
        pumping = true
        queue.asyncAfter(deadline: .now() + 0.05) { [self] in
            pumping = false
            pump()
        }
    }

    // MARK: CBPeripheralManagerDelegate (on `queue`)

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Self.log.notice("Muse pairing: Bluetooth state \(peripheral.state.rawValue, privacy: .public)")
        switch peripheral.state {
        case .poweredOn:
            let rx = CBMutableCharacteristic(type: MuseGATT.rx, properties: [.write, .writeWithoutResponse], value: nil, permissions: [.writeable])
            let tx = CBMutableCharacteristic(type: MuseGATT.tx, properties: [.read, .notify], value: nil, permissions: [.readable])
            let service = CBMutableService(type: MuseGATT.service, primary: true)
            service.characteristics = [rx, tx]
            txCharacteristic = tx
            peripheral.removeAllServices()
            peripheral.add(service)
        case .poweredOff: onProblem?(.bluetoothOff)
        case .unauthorized: onProblem?(.notAllowed)
        case .unsupported: onProblem?(.unsupported)
        default: break
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error {
            Self.log.error("Muse pairing: adding the service failed: \(error.localizedDescription, privacy: .public)")
            onProblem?(.failed(error.localizedDescription)); return
        }
        // The name only. macOS gives a peripheral 28 bytes of advertisement (and the name 10 more in the scan
        // response): the 128-bit service UUID takes 18, which cut "MuseGadgetXXXXXX" to "MuseGadg", and the Muse
        // app, which finds gadgets by that name, never listed this Mac (October 8, 2026). The service is still
        // there for the phone once it connects.
        peripheral.startAdvertising([CBAdvertisementDataLocalNameKey: name])
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        advertising = error == nil
        if let error {
            Self.log.error("Muse pairing: advertising failed: \(error.localizedDescription, privacy: .public)")
            onProblem?(.failed(error.localizedDescription))
        } else {
            Self.log.notice("Muse pairing: advertising as \(self.name, privacy: .public) with service \(MuseGATT.serviceUUID, privacy: .public)")
            onProblem?(nil)
            onAdvertising?(true)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        self.central = central
        negotiatedMTU = central.maximumUpdateValueLength + 3
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard self.central == nil || self.central?.identifier == central.identifier else { return }
        self.central = nil
        outbox = []
        negotiatedMTU = MuseBLEFraming.maxPacketBytes + 3
        onDisconnect?()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for request in requests where request.characteristic.uuid == MuseGATT.rx {
            if central == nil { central = request.central }
            negotiatedMTU = request.central.maximumUpdateValueLength + 3
            if let value = request.value { onWrite?(Array(value)) }
        }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        request.value = Data()
        peripheral.respond(to: request, withResult: .success)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) { pump() }
}
#endif
