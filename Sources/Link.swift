import AppKit
import CoreBluetooth
import CoreImage.CIFilterBuiltins

/// Linking a phone, the way a phone links to a messaging account: the Mac shows a QR code, the Sand Timer app on the
/// phone scans it, and from then on the two find each other over Bluetooth and share one timer, the projects and
/// the record (see LinkEngine). Nothing happens until "Link a Phone…" is used: until then the app doesn't touch
/// Bluetooth at all, so it never asks for it.
@MainActor
enum Link {
    static let engine = LinkEngine(
        name: Host.current().localizedName ?? "Mac", kind: "mac", isHub: true, defaults: .standard,
        folder: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Sand Timer", isDirectory: true))
    static let radio = LinkPeripheral()

    /// Starts offering the link over Bluetooth, if a phone was ever linked.
    static func start(owner: HourglassView) {
        engine.host = owner
        owner.link = engine
        engine.transport = radio
        radio.engine = engine
        engine.start()
    }

    /// The code drawn as a QR code, sharp at `size` points.
    nonisolated static func qrImage(_ text: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = (size * 2 / output.extent.width).rounded(.down)
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: NSSize(width: size, height: size))
        image.addRepresentation(rep)
        return image
    }
}

/// The Mac's side of the Bluetooth link: it offers the service the key names, and phones connect to it. A phone
/// writes its messages to one characteristic, and hears the Mac's as notifications on the other, each message cut
/// into pieces that fit (LinkFormat.frames).
///
/// It announces itself only while a linked phone isn't connected, or while the code is showing, and slowly: a
/// connected phone needs no announcing, and Bluetooth headphones share the radio.
@MainActor
final class LinkPeripheral: NSObject, LinkTransport, CBPeripheralManagerDelegate {
    weak var engine: LinkEngine?
    /// Announce even when every known phone is connected: a new one is about to scan the code.
    var welcoming = false { didSet { updateAdvertising() } }

    private var manager: CBPeripheralManager?
    private var service: CBUUID?
    private var toPhone: CBMutableCharacteristic?
    private var added = false
    private var centrals: [UUID: CBCentral] = [:]
    private var buffers: [UUID: LinkFormat.Reassembler] = [:]
    private var queue: [(central: CBCentral, frame: Data)] = []

    /// Whether Bluetooth is on and allowed; Settings says so when it isn't.
    var problem: String? {
        switch manager?.state {
        case .poweredOff: return "Bluetooth is off."
        case .unauthorized: return "Sand Timer isn't allowed to use Bluetooth. Allow it in System Settings › Privacy & Security › Bluetooth."
        case .unsupported: return "This Mac has no Bluetooth Low Energy."
        default: return nil
        }
    }

    func start(service uuid: UUID) {
        service = CBUUID(nsuuid: uuid)
        if let manager { setUp(manager) } else { manager = CBPeripheralManager(delegate: self, queue: .main) }
    }

    func stop() {
        manager?.stopAdvertising()
        manager?.removeAllServices()
        added = false
        service = nil
        centrals = [:]
        buffers = [:]
        queue = []
    }

    func send(_ message: Data, to peer: String) {
        guard let id = UUID(uuidString: peer), let central = centrals[id] else { return }
        for frame in LinkFormat.frames(message, size: min(512, central.maximumUpdateValueLength)) { queue.append((central, frame)) }
        flush()
    }

    private func flush() {
        guard let manager, let toPhone else { return }
        while let next = queue.first {
            guard centrals[next.central.identifier] != nil else { queue.removeFirst(); continue }
            guard manager.updateValue(next.frame, for: toPhone, onSubscribedCentrals: [next.central]) else { return }  // full: wait to be ready
            queue.removeFirst()
        }
    }

    private func setUp(_ manager: CBPeripheralManager) {
        guard manager.state == .poweredOn, let service, !added else { return updateAdvertising() }
        let toMac = CBMutableCharacteristic(type: CBUUID(nsuuid: LinkFormat.toMac), properties: [.write],
                                            value: nil, permissions: [.writeable])
        let toPhone = CBMutableCharacteristic(type: CBUUID(nsuuid: LinkFormat.toPhone), properties: [.notify],
                                              value: nil, permissions: [.readable])
        let offered = CBMutableService(type: service, primary: true)
        offered.characteristics = [toMac, toPhone]
        self.toPhone = toPhone
        added = true
        manager.add(offered)
    }

    private func updateAdvertising() {
        guard let manager, manager.state == .poweredOn, let service, added else { return }
        let phones = Set((engine?.devices ?? []).map(\.id))
        let everyoneHere = !phones.isEmpty && phones.isSubset(of: engine?.connected ?? [])
        if welcoming || !everyoneHere {
            if !manager.isAdvertising { manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service]]) }
        } else if manager.isAdvertising {
            manager.stopAdvertising()
        }
    }

    // MARK: CBPeripheralManagerDelegate

    nonisolated func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated {
            if peripheral.state != .poweredOn {
                added = false
                for id in centrals.keys { engine?.disconnected(peer: id.uuidString) }
                centrals = [:]
            }
            setUp(peripheral)
            NotificationCenter.default.post(name: LinkEngine.changed, object: nil)
        }
    }

    nonisolated func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error { NSLog("Sand Timer link: couldn't announce itself over Bluetooth: \(error.localizedDescription)") }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error { NSLog("Sand Timer link: couldn't offer its Bluetooth service: \(error.localizedDescription)") }
        MainActor.assumeIsolated {
            if error != nil { added = false }
            updateAdvertising()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            centrals[central.identifier] = central
            buffers[central.identifier] = LinkFormat.Reassembler()
            engine?.connected(peer: central.identifier.uuidString)
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        MainActor.assumeIsolated {
            centrals[central.identifier] = nil
            buffers[central.identifier] = nil
            engine?.disconnected(peer: central.identifier.uuidString)
            updateAdvertising()
        }
    }

    nonisolated func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        MainActor.assumeIsolated {
            for request in requests where request.characteristic.uuid == CBUUID(nsuuid: LinkFormat.toMac) {
                let id = request.central.identifier
                guard let value = request.value, centrals[id] != nil else { continue }
                if let message = buffers[id]?.add(value) {
                    engine?.received(message, from: id.uuidString)
                    updateAdvertising()  // a phone that has just said hello may be the last one missing
                }
            }
            if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
        }
    }

    nonisolated func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        MainActor.assumeIsolated { flush() }
    }
}

/// The window showing the QR code to scan. It watches for a new phone to say hello and closes when one does, saying
/// so, and closes by itself after two minutes, since the code is as good as a password while it shows.
final class LinkPanel: NSPanel {
    private static var shared: LinkPanel?
    static var open: LinkPanel? { shared?.isVisible == true ? shared : nil }

    private let image = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "Making a code…")
    private var expiry: Timer?
    private var known: Set<String> = []
    private var observer: NSObjectProtocol?

    @MainActor
    static func show() {
        let panel = shared ?? LinkPanel()
        shared = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        panel.begin()
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 420),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Link a Phone"
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let heading = NSTextField(labelWithString: "Scan with Sand Timer on your phone")
        heading.font = .systemFont(ofSize: NSFont.systemFontSize + 1, weight: .semibold)
        let steps = NSTextField(wrappingLabelWithString:
            "Open Sand Timer on your iPhone or Android phone, go to Settings › Link to a Mac, and point the camera at this code. "
            + "Keep the phone near this Mac: the two talk over Bluetooth, sharing one timer, your projects and your statistics.")
        steps.font = .systemFont(ofSize: 12)
        steps.textColor = .secondaryLabelColor
        let warning = NSTextField(wrappingLabelWithString:
            "Anyone who scans this code can see your projects and time, so don't share it. It goes away in two minutes.")
        warning.font = .systemFont(ofSize: 11)
        warning.textColor = .tertiaryLabelColor
        status.font = .systemFont(ofSize: 12)
        status.alignment = .center
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true
        image.layer?.backgroundColor = NSColor.white.cgColor  // a QR code needs its quiet zone light, in dark mode too
        image.layer?.cornerRadius = 8

        let stack = NSStackView(views: [heading, steps, image, status, warning])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            content.widthAnchor.constraint(equalToConstant: 340),
            image.widthAnchor.constraint(equalToConstant: 232),
            image.heightAnchor.constraint(equalToConstant: 232),
            steps.widthAnchor.constraint(equalToConstant: 296),
            warning.widthAnchor.constraint(equalToConstant: 296),
            status.widthAnchor.constraint(equalToConstant: 296),
        ])
        contentView = content
        setContentSize(content.fittingSize)
    }

    @MainActor
    private func begin() {
        known = Link.engine.connected
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: 120, repeats: false) { [weak self] _ in self?.close() }
        do {
            image.image = Link.qrImage(try Link.engine.linkCode(), size: 232)
            Link.radio.welcoming = true
            status.stringValue = Link.radio.problem ?? "Waiting for your phone…"
        } catch {
            image.image = nil
            status.stringValue = "Couldn't make a code: \(error.localizedDescription)"
        }
        if observer == nil {
            observer = NotificationCenter.default.addObserver(forName: LinkEngine.changed, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.check() }
            }
        }
    }

    /// A phone that wasn't connected when the code appeared has said hello: done.
    @MainActor
    private func check() {
        guard isVisible, image.image != nil else { return }
        guard let phone = Link.engine.devices.first(where: { Link.engine.connected.contains($0.id) && !known.contains($0.id) }) else {
            status.stringValue = Link.radio.problem ?? "Waiting for your phone…"
            return
        }
        image.image = nil
        status.stringValue = "Linked \(phone.name)."
        expiry?.invalidate()
        expiry = Timer.scheduledTimer(withTimeInterval: 2, repeats: false) { [weak self] _ in self?.close() }
    }

    override func close() {
        expiry?.invalidate()
        image.image = nil  // the code shouldn't linger in a window that isn't showing
        MainActor.assumeIsolated { Link.radio.welcoming = false }
        super.close()
    }
}
