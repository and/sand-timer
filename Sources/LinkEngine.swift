import CryptoKit
import Foundation

/// The app a link works for: the Mac's timer, or a phone's. The engine asks it for what to share, and hands it what
/// the other devices changed.
@MainActor
protocol LinkHost: AnyObject {
    var projects: ProjectList { get }
    /// A list already put together with the other devices' and stamped: take it as it stands.
    func takeLinkedProjects(_ list: ProjectList)
    /// This device's own record, as it stands now.
    func ownLog() -> SandLog
    /// The timer here, unstamped and with no owner: the engine fills those in.
    func localTimer() -> SharedTimer
    /// Make the timer here what another device made it. `counts` says whether this device counts its time.
    func adopt(_ timer: SharedTimer, counts: Bool)
    /// The linked records, the devices or their connections changed.
    func linkChanged()
}

/// How the engine reaches the other devices: Bluetooth, from the Mac's side or a phone's.
@MainActor
protocol LinkTransport: AnyObject {
    /// Offers or looks for the service, and keeps at it until `stop`.
    func start(service: UUID)
    func stop()
    /// One sealed message to one connected device, known by the transport's own name for it.
    func send(_ message: Data, to peer: String)
}

/// Linking devices, the way a phone links to a messaging account: the Mac shows a QR code holding a key, a phone
/// scans it, and from then on they find each other over Bluetooth and share one timer, the projects and the record.
///
/// The Mac is the hub. Each phone connects to it, and it passes on what one phone says to the others. Every message
/// is JSON sealed with the key:
/// - `hello`: the sender, the months of the record it holds (`have`: device → month → digest), its projects and
///   the timer. Each side sends one as they connect, and puts itself together with the other's.
/// - `projects`: the list, after a change. Each project's `updated` stamp decides, the later change winning.
/// - `timer`: the shared timer, after a change. The later stamp wins.
/// - `logs`: one month of one device's record, with its digest. A device sends its own months; the Mac also passes
///   on the phones' to each other. Only what the other side's `have` lacks goes.
/// - `bye`: a phone unlinking itself; `unlinked`: the Mac unlinking every phone.
@MainActor
final class LinkEngine {
    /// Posted when linking starts or stops, a device comes or goes, or a record arrives.
    static let changed = Notification.Name("SandTimerLinkChanged")
    static let devicesKey = "linkedDevices"
    static let deviceIDKey = "deviceID"
    static let digestsKey = "linkDigests"
    static let timerKey = "linkTimer"
    static let enabledKey = "linkEnabled"
    /// How often connected devices check that each has the other's latest record.
    static let logInterval: TimeInterval = 5 * 60

    /// Another device this one is linked with.
    struct Device: Equatable {
        let id: String
        let name: String
        let kind: String
        let seen: Date
    }

    private struct Peer {
        var device: Device?
        var have: [String: [String: String]] = [:]
        var greeted = false
    }

    let name: String
    let kind: String
    /// The Mac: it passes each phone's record and changes on to the others.
    let isHub: Bool
    weak var host: LinkHost?
    var transport: LinkTransport?

    private let defaults: UserDefaults
    private let file: URL
    private(set) var key: Data?
    private var peers: [String: Peer] = [:]
    private var adopting = false
    private var logTimer: Timer?
    private var logsSoon: DispatchWorkItem?

    init(name: String, kind: String, isHub: Bool, defaults: UserDefaults, folder: URL) {
        self.name = name
        self.kind = kind
        self.isHub = isHub
        self.defaults = defaults
        file = folder.appendingPathComponent("link.json")
        key = (try? Data(contentsOf: file))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            .flatMap { ($0["key"] as? String).flatMap { Data(base64Encoded: $0) } }
            .flatMap { $0.count == 32 ? $0 : nil }
    }

    var isLinked: Bool { key != nil }

    /// Linking is off until it's turned on in Settings, and off means off: no Bluetooth at all, not even the
    /// question of whether it may be used. Turning it off keeps the link, so turning it on again reconnects.
    var isEnabled: Bool { defaults.bool(forKey: Self.enabledKey) }

    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            start()
        } else {
            transport?.stop()
            for peer in Array(peers.keys) { disconnected(peer: peer) }
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// This device's id among the linked ones, made once.
    var deviceID: String {
        if let id = defaults.string(forKey: Self.deviceIDKey), !id.isEmpty { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Self.deviceIDKey)
        return id
    }

    /// The devices this one is linked with, as last heard from.
    var devices: [Device] {
        (defaults.array(forKey: Self.devicesKey) as? [[String: Any]] ?? []).compactMap { entry in
            guard let id = entry["id"] as? String else { return nil }
            return Device(id: id, name: entry["name"] as? String ?? "Device", kind: entry["kind"] as? String ?? "",
                          seen: Date(timeIntervalSince1970: (entry["seen"] as? NSNumber)?.doubleValue ?? 0))
        }
    }

    /// The ids of the devices connected right now.
    var connected: Set<String> { Set(peers.values.compactMap { $0.device?.id }) }

    /// The timer as last shared.
    var shared: SharedTimer? { SharedTimer(wire: defaults.dictionary(forKey: Self.timerKey)) }

    /// Whether this device counts the time of the session going now: it does unless another device started it.
    var countsHere: Bool {
        guard isLinked, let owner = shared?.owner, !owner.isEmpty else { return true }
        return owner == deviceID
    }

    /// Starts finding the other devices, if linked.
    func start() {
        guard isEnabled, let key else { return }
        transport?.start(service: LinkFormat.serviceUUID(key: key))
        guard logTimer == nil else { return }
        let timer = Timer(timeInterval: Self.logInterval, repeats: true) { _ in
            MainActor.assumeIsolated { [weak self] in self?.sendLogs() }
        }
        RunLoop.main.add(timer, forMode: .common)
        logTimer = timer
    }

    // MARK: Linking

    /// The Mac's QR code, making the key first if this is the first phone.
    func linkCode() throws -> String {
        let made = key == nil
        if made { try save(key: SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }) }
        if !isEnabled { setEnabled(true) } else if made { start() }  // a new key is a new service to offer
        return LinkFormat.code(key: key!)
    }

    /// A phone joining the Mac whose code it scanned.
    func link(code text: String) throws {
        guard let key = LinkFormat.parse(text) else { throw LinkFormat.Unreadable() }
        if key != self.key { forget() }
        try save(key: key)
        defaults.set(true, forKey: Self.enabledKey)
        start()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Unlinks: a phone says goodbye to the Mac, and the Mac tells every connected phone it is no longer linked. The
    /// key goes, so a phone that missed the news finds nothing to connect to. Each device keeps its own record.
    func unlink() {
        broadcast(["t": isHub ? "unlinked" : "bye"])
        // The goodbye goes out before the connection does.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.forget() }
    }

    /// Forgets the link here: the key, the other devices and their records.
    func forget() {
        transport?.stop()
        try? FileManager.default.removeItem(at: file)
        key = nil
        peers = [:]
        logTimer?.invalidate()
        logTimer = nil
        for k in [SandLog.linkedKey, Self.devicesKey, Self.digestsKey, Self.timerKey] { defaults.removeObject(forKey: k) }
        host?.linkChanged()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func save(key: Data) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: ["key": key.base64EncodedString()])
        try data.write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        self.key = key
    }

    // MARK: Changes made here

    /// The timer changed here. If that is a change to the shared timer rather than an echo of one, it is stamped and
    /// sent: a new session belongs to this device, a pause or resume of one going on keeps its owner.
    func timerChanged() {
        guard isLinked, !adopting, let host else { return }
        let now = Date()
        var local = host.localTimer()
        if local.phase(at: now) != .running { sendLogsSoon() }  // a pause or an end: the time just run goes across
        let before = shared
        if let before, before.matches(local, at: now) { return }
        let ongoing = before.map { local.phase(at: now) != .idle && $0.sameSession(as: local) } ?? false
        local.owner = ongoing ? before!.owner : deviceID
        local.stamp = now
        defaults.set(local.wire, forKey: Self.timerKey)
        broadcast(["t": "timer", "timer": local.wire])
    }

    /// The projects changed here.
    func projectsChanged() {
        guard isLinked, let host else { return }
        broadcast(["t": "projects", "projects": host.projects.all.map(\.stored)])
    }

    // MARK: The transport's news

    /// A device connected. A phone greets the Mac straight away; the Mac waits to be greeted, so that it only ever
    /// talks to a device holding the key.
    func connected(peer: String) {
        peers[peer] = Peer()
        if !isHub { greet(peer) }
    }

    func disconnected(peer: String) {
        guard let gone = peers.removeValue(forKey: peer) else { return }
        if let device = gone.device { remember(device, seen: Date()) }
        host?.linkChanged()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// A whole message from a connected device. One that doesn't open with the key is ignored.
    func received(_ data: Data, from peer: String) {
        guard let key, peers[peer] != nil,
              let opened = try? LinkFormat.open(data, key: SymmetricKey(data: key)),
              let message = (try? JSONSerialization.jsonObject(with: opened)) as? [String: Any],
              let type = message["t"] as? String else { return }
        switch type {
        case "hello": hello(message, from: peer)
        case "projects": takeProjects(message["projects"], from: peer)
        case "timer": takeTimer(SharedTimer(wire: message["timer"] as? [String: Any]), from: peer)
        case "logs": takeLogs(message, from: peer)
        case "bye":
            if let id = peers[peer]?.device?.id {
                defaults.set((defaults.array(forKey: Self.devicesKey) as? [[String: Any]] ?? []).filter { $0["id"] as? String != id },
                             forKey: Self.devicesKey)
            }
            peers[peer]?.device = nil
            host?.linkChanged()
            NotificationCenter.default.post(name: Self.changed, object: nil)
        case "unlinked" where !isHub:
            forget()
        default: break
        }
    }

    // MARK: Messages

    private func greet(_ peer: String) {
        guard let host else { return }
        peers[peer]?.greeted = true
        var hello: [String: Any] = ["t": "hello", "device": ["id": deviceID, "name": name, "kind": kind],
                                    "have": have(), "projects": host.projects.all.map(\.stored)]
        if let shared { hello["timer"] = shared.wire }
        send(hello, to: peer)
    }

    private func hello(_ message: [String: Any], from peer: String) {
        guard let info = message["device"] as? [String: Any], let id = info["id"] as? String, id != deviceID else { return }
        let device = Device(id: id, name: info["name"] as? String ?? "Device", kind: info["kind"] as? String ?? "", seen: Date())
        peers[peer]?.device = device
        peers[peer]?.have = message["have"] as? [String: [String: String]] ?? [:]
        remember(device, seen: Date())
        if peers[peer]?.greeted == false { greet(peer) }
        takeProjects(message["projects"], from: peer)
        let theirs = SharedTimer(wire: message["timer"] as? [String: Any])
        takeTimer(theirs, from: peer)
        sendLogs(to: peer)
        host?.linkChanged()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func takeProjects(_ value: Any?, from peer: String) {
        guard let host, let stored = value as? [[String: Any]] else { return }
        let theirs = ProjectList.load(stored: stored)
        let merged = host.projects.merged(with: theirs)
        if merged != host.projects {
            host.takeLinkedProjects(merged)
            if isHub { broadcast(["t": "projects", "projects": merged.all.map(\.stored)], except: peer) }
        }
        if merged != theirs { send(["t": "projects", "projects": merged.all.map(\.stored)], to: peer) }
    }

    /// The other side's timer: taken on if it's the later change, otherwise ours goes back to it.
    private func takeTimer(_ theirs: SharedTimer?, from peer: String) {
        guard let host else { return }
        var mine = shared ?? host.localTimer()
        if mine.owner.isEmpty { mine.owner = deviceID }
        guard let theirs, theirs.stamp > mine.stamp else {
            if theirs?.stamp != mine.stamp { send(["t": "timer", "timer": mine.wire], to: peer) }
            return
        }
        defaults.set(theirs.wire, forKey: Self.timerKey)
        adopting = true
        host.adopt(theirs, counts: theirs.owner == deviceID)
        adopting = false
        if isHub { broadcast(["t": "timer", "timer": theirs.wire], except: peer) }
    }

    private func takeLogs(_ message: [String: Any], from peer: String) {
        guard let device = message["device"] as? String, device != deviceID, let month = message["month"] as? String,
              let digest = message["digest"] as? String, let days = message["days"] as? [String: Any] else { return }
        var records = defaults.dictionary(forKey: SandLog.linkedKey) as? [String: [String: Any]] ?? [:]
        var record = (records[device] ?? [:]).filter { !$0.key.hasPrefix(month) }
        record.merge(days) { _, new in new }
        records[device] = record
        defaults.set(records, forKey: SandLog.linkedKey)
        var digests = defaults.dictionary(forKey: Self.digestsKey) as? [String: [String: String]] ?? [:]
        digests[device, default: [:]][month] = digest
        defaults.set(digests, forKey: Self.digestsKey)
        peers[peer]?.have[device, default: [:]][month] = digest
        host?.linkChanged()
        if isHub { for other in peers.keys where other != peer && peers[other]?.device != nil { sendLogs(to: other) } }
    }

    /// Every month this device holds, its own and the others', with their digests.
    private func have() -> [String: [String: String]] {
        var have = defaults.dictionary(forKey: Self.digestsKey) as? [String: [String: String]] ?? [:]
        have[deviceID] = own()
        return have
    }

    private func own() -> [String: String] {
        (host?.ownLog().storedByMonth ?? [:]).mapValues { LinkFormat.digest($0) }
    }

    private func sendLogsSoon() {
        logsSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.sendLogs() }
        logsSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func sendLogs() {
        for peer in peers.keys where peers[peer]?.device != nil { sendLogs(to: peer) }
    }

    /// The months the other side lacks or holds an older copy of: this device's own, and on the Mac the other
    /// phones' too, never the other side's own back to it.
    private func sendLogs(to peer: String) {
        guard let host, let them = peers[peer]?.device?.id else { return }
        var outgoing: [(device: String, month: String, digest: String, days: [String: Any])] = []
        for (month, days) in host.ownLog().storedByMonth {
            outgoing.append((deviceID, month, LinkFormat.digest(days), days))
        }
        if isHub {
            let digests = defaults.dictionary(forKey: Self.digestsKey) as? [String: [String: String]] ?? [:]
            let records = defaults.dictionary(forKey: SandLog.linkedKey) as? [String: [String: Any]] ?? [:]
            for (device, record) in records where device != them {
                var months: [String: [String: Any]] = [:]
                for (day, entry) in record { months[String(day.prefix(7)), default: [:]][day] = entry }
                for (month, days) in months {
                    outgoing.append((device, month, digests[device]?[month] ?? LinkFormat.digest(days), days))
                }
            }
        }
        for item in outgoing.sorted(by: { ($0.month, $0.device) < ($1.month, $1.device) })
        where peers[peer]?.have[item.device]?[item.month] != item.digest {
            send(["t": "logs", "device": item.device, "month": item.month, "digest": item.digest, "days": item.days], to: peer)
            peers[peer]?.have[item.device, default: [:]][item.month] = item.digest
        }
    }

    private func remember(_ device: Device, seen: Date) {
        var list = (defaults.array(forKey: Self.devicesKey) as? [[String: Any]] ?? []).filter { $0["id"] as? String != device.id }
        list.append(["id": device.id, "name": device.name, "kind": device.kind, "seen": seen.timeIntervalSince1970])
        defaults.set(list, forKey: Self.devicesKey)
    }

    private func broadcast(_ message: [String: Any], except: String? = nil) {
        for peer in peers.keys where peer != except && (peers[peer]?.device != nil || !isHub) { send(message, to: peer) }
    }

    private func send(_ message: [String: Any], to peer: String) {
        guard let key, let json = try? JSONSerialization.data(withJSONObject: message),
              let sealed = try? LinkFormat.seal(json, key: SymmetricKey(data: key)) else { return }
        transport?.send(sealed, to: peer)
    }
}
