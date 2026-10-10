import CoreBluetooth
import Foundation
import UIKit

/// This iPhone as a linked device of a Mac, the way a phone links to a messaging account. The Mac's QR code carries
/// a key; with it the phone finds the Mac over Bluetooth whenever they're near each other, and the two share one
/// timer, the projects and the record. The engine is the Mac's own (Sources/LinkEngine.swift); this is the iPhone's
/// end of the radio.
@MainActor
enum LinkClient {
    static let engine = LinkEngine(
        name: UIDevice.current.name, kind: "ios", isHub: false, defaults: .standard,
        folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0])
    static let radio = LinkCentral()

    static func start(store: Store) {
        engine.host = store
        engine.transport = radio
        radio.engine = engine
        engine.start()
    }
}

/// The phone's side of the Bluetooth link: it looks for the service its key names, connects to the Mac offering it,
/// writes its messages to one characteristic and hears the Mac's as notifications on the other, each message cut
/// into pieces that fit. When the Mac goes out of reach it looks again after a while, waiting longer each time.
/// iOS keeps it going in the background, where it looks for the service and stays connected.
@MainActor
final class LinkCentral: NSObject, LinkTransport, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var engine: LinkEngine?
    private var manager: CBCentralManager?
    private var service: CBUUID?
    private var mac: CBPeripheral?
    private var toMac: CBCharacteristic?
    private var peer: String?
    private var outbox: [Data] = []
    private var writing = false
    private var inbox = LinkFormat.Reassembler()
    private var attempts = 0
    private var retry: DispatchWorkItem?

    /// Why the phone can't reach the Mac, if it can't.
    var problem: String? {
        switch manager?.state {
        case .poweredOff: return "Bluetooth is off."
        case .unauthorized: return "Sand Timer isn't allowed to use Bluetooth. Allow it in Settings › Sand Timer."
        case .unsupported: return "This iPhone has no Bluetooth Low Energy."
        default: return nil
        }
    }

    func start(service uuid: UUID) {
        service = CBUUID(nsuuid: uuid)
        attempts = 0
        if let manager { look(manager) } else { manager = CBCentralManager(delegate: self, queue: .main) }
    }

    func stop() {
        service = nil
        retry?.cancel()
        manager?.stopScan()
        drop()
    }

    func send(_ message: Data, to peer: String) {
        guard peer == self.peer, let mac else { return }
        outbox += LinkFormat.frames(message, size: min(512, mac.maximumWriteValueLength(for: .withoutResponse)))
        pump()
    }

    /// The app came to the front: look for the Mac now.
    func wake() {
        attempts = 0
        retry?.cancel()
        if let manager { look(manager) }
    }

    private func look(_ manager: CBCentralManager) {
        guard manager.state == .poweredOn, let service, mac == nil, !manager.isScanning else { return }
        manager.scanForPeripherals(withServices: [service])
    }

    private func drop() {
        let was = peer
        peer = nil
        toMac = nil
        outbox = []
        writing = false
        inbox = LinkFormat.Reassembler()
        if let mac { manager?.cancelPeripheralConnection(mac) }
        mac = nil
        if let was { engine?.disconnected(peer: was) }
        NotificationCenter.default.post(name: LinkEngine.changed, object: nil)
    }

    /// Tries again after a while: 2 s, then 5, 15, 30, and a minute from then on.
    private func again() {
        guard service != nil, let manager else { return }
        let delay = [2.0, 5, 15, 30, 60][min(attempts, 4)]
        attempts += 1
        retry?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.look(manager) }
        retry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func pump() {
        guard !writing, let mac, let toMac, let frame = outbox.first else { return }
        writing = true
        mac.writeValue(frame, for: toMac, type: .withResponse)
    }

    // MARK: CBCentralManagerDelegate

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            if central.state == .poweredOn { look(central) } else { drop() }
            NotificationCenter.default.post(name: LinkEngine.changed, object: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            guard mac == nil else { return }
            central.stopScan()
            mac = peripheral
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            guard peripheral == mac, let service else { return }
            peripheral.discoverServices([service])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == mac else { return }
            drop()
            again()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == mac else { return }
            drop()
            again()
        }
    }

    // MARK: CBPeripheralDelegate

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == mac, let offered = peripheral.services?.first(where: { $0.uuid == service }) else { return drop() }
            peripheral.discoverCharacteristics([CBUUID(nsuuid: LinkFormat.toMac), CBUUID(nsuuid: LinkFormat.toPhone)], for: offered)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == mac else { return }
            let found = service.characteristics ?? []
            toMac = found.first { $0.uuid == CBUUID(nsuuid: LinkFormat.toMac) }
            guard toMac != nil, let toPhone = found.first(where: { $0.uuid == CBUUID(nsuuid: LinkFormat.toPhone) }) else {
                drop()
                return again()
            }
            peripheral.setNotifyValue(true, for: toPhone)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == mac, characteristic.isNotifying, peer == nil else { return }
            attempts = 0
            peer = peripheral.identifier.uuidString
            engine?.connected(peer: peer!)
            NotificationCenter.default.post(name: LinkEngine.changed, object: nil)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == mac, let peer, let value = characteristic.value,
                  characteristic.uuid == CBUUID(nsuuid: LinkFormat.toPhone) else { return }
            if let message = inbox.add(value) { engine?.received(message, from: peer) }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        MainActor.assumeIsolated {
            guard peripheral == mac else { return }
            writing = false
            if error == nil, !outbox.isEmpty { outbox.removeFirst() }
            pump()
        }
    }
}
