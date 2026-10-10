import CryptoKit
import Foundation

/// What linked devices agree on, shared by the Mac (Sources/Link.swift) and the iPhone app, and matched by the
/// Android app (android/…/link/Crypto.kt): the QR code's text, the Bluetooth service it points to, how each message
/// is sealed, and how a message is cut into pieces small enough for Bluetooth.
enum LinkFormat {
    /// The QR code says this prefix and the key, base64url without padding.
    static let codePrefix = "sandtimer-link:2:"

    struct Unreadable: LocalizedError {
        var errorDescription: String? { "That isn't a Sand Timer code. On the Mac, open Sand Timer's Settings and click Link a Phone…" }
    }

    static func code(key: Data) -> String { codePrefix + base64url(key) }

    /// The key from a code, or nil if it isn't one.
    static func parse(_ text: String) -> Data? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix(codePrefix) else { return nil }
        var b64 = text.dropFirst(codePrefix.count).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let key = Data(base64Encoded: b64), key.count == 32 else { return nil }
        return key
    }

    /// The Bluetooth service a linked Mac offers, its UUID drawn from the key: a phone looks for its own Mac's, and
    /// never mistakes another Mac running Sand Timer nearby for it.
    static func serviceUUID(key: Data) -> UUID {
        var b = Array(SHA256.hash(data: Data("sandtimer-service".utf8) + key).prefix(16))
        b[6] = b[6] & 0x0f | 0x40  // a version 4 UUID, as anything reading it expects
        b[8] = b[8] & 0x3f | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The service's two characteristics: the phone writes to the first, and hears from the Mac on the second.
    static let toMac = UUID(uuidString: "6C2ED600-0001-4D61-9C00-53616E645469")!
    static let toPhone = UUID(uuidString: "6C2ED600-0002-4D61-9C00-53616E645469")!

    /// A short, stable digest of a month of the record, to tell whether it has changed since it was sent.
    static func digest(_ value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data()
        return SHA256.hash(data: data).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// AES-GCM, as nonce + ciphertext + tag: the layout every app reads and writes.
    static func seal(_ data: Data, key: SymmetricKey) throws -> Data {
        guard let sealed = try AES.GCM.seal(data, using: key).combined else { throw CryptoKitError.incorrectParameterSize }
        return sealed
    }

    static func open(_ data: Data, key: SymmetricKey) throws -> Data {
        try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key)
    }

    /// A sealed message cut into Bluetooth-sized pieces, each a byte saying whether more follow (1) or not (0), then
    /// up to `size` - 1 bytes of the message.
    static func frames(_ message: Data, size: Int) -> [Data] {
        let chunk = max(1, size - 1)
        var frames: [Data] = []
        var start = message.startIndex
        repeat {
            let end = min(message.endIndex, start + chunk)
            frames.append(Data([end < message.endIndex ? 1 : 0]) + message[start..<end])
            start = end
        } while start < message.endIndex
        return frames
    }

    /// Puts the pieces of a message back together, one sender's at a time.
    struct Reassembler {
        private var buffer = Data()
        /// No message is anywhere near this big; a sender going on past it is ignored.
        static let limit = 2 << 20

        /// The whole message once its last piece has come, else nil.
        mutating func add(_ frame: Data) -> Data? {
            guard let flag = frame.first else { return nil }
            buffer.append(frame.dropFirst())
            if buffer.count > Self.limit { buffer = Data(); return nil }
            guard flag == 0 else { return nil }
            defer { buffer = Data() }
            return buffer
        }
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// The timer as linked devices share it: one timer on every screen. Each device writes it when someone changes the
/// timer there, stamped with the moment, and the latest change wins. The device that started a session is its
/// `owner`, and only the owner counts its time, so a session seen on two screens is counted once.
struct SharedTimer: Equatable {
    var minutes: Int
    /// When the session began; it identifies the session across devices.
    var started: Date?
    var runningUntil: Date?
    var pausedWith: TimeInterval?
    var project: String?
    var owner = ""
    var stamp = Date.distantPast

    enum Phase { case idle, running, paused }

    func phase(at now: Date) -> Phase {
        if let until = runningUntil, until > now { return .running }
        return (pausedWith ?? 0) > 0 && runningUntil == nil ? .paused : .idle
    }

    func remaining(at now: Date) -> TimeInterval {
        switch phase(at: now) {
        case .running: return runningUntil!.timeIntervalSince(now)
        case .paused: return pausedWith ?? 0
        case .idle: return 0
        }
    }

    /// Whether two say the same thing, near enough: an animation or a radio's delay shouldn't count as a change.
    func matches(_ other: SharedTimer, at now: Date) -> Bool {
        let phase = phase(at: now)
        guard phase == other.phase(at: now), minutes == other.minutes, project == other.project else { return false }
        switch phase {
        case .idle: return true
        case .running:
            return sameSession(as: other) && abs(runningUntil!.timeIntervalSince(other.runningUntil!)) <= 1.5
        case .paused:
            return sameSession(as: other) && abs((pausedWith ?? 0) - (other.pausedWith ?? 0)) <= 1.5
        }
    }

    func sameSession(as other: SharedTimer) -> Bool {
        guard let a = started, let b = other.started else { return started == nil && other.started == nil }
        return abs(a.timeIntervalSince(b)) <= 1
    }

    /// As it travels: times in seconds since 1970.
    var wire: [String: Any] {
        var out: [String: Any] = ["minutes": minutes, "owner": owner, "stamp": stamp.timeIntervalSince1970]
        if let started { out["started"] = started.timeIntervalSince1970 }
        if let runningUntil { out["runningUntil"] = runningUntil.timeIntervalSince1970 }
        if let pausedWith { out["pausedWith"] = pausedWith }
        if let project { out["project"] = project }
        return out
    }

    init(minutes: Int, started: Date? = nil, runningUntil: Date? = nil, pausedWith: TimeInterval? = nil,
         project: String? = nil, owner: String = "", stamp: Date = .distantPast) {
        self.minutes = minutes
        self.started = started
        self.runningUntil = runningUntil
        self.pausedWith = pausedWith
        self.project = project
        self.owner = owner
        self.stamp = stamp
    }

    init?(wire: [String: Any]?) {
        guard let wire, let minutes = (wire["minutes"] as? NSNumber)?.intValue else { return nil }
        func date(_ key: String) -> Date? { (wire[key] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) } }
        self.init(minutes: minutes, started: date("started"), runningUntil: date("runningUntil"),
                  pausedWith: (wire["pausedWith"] as? NSNumber)?.doubleValue, project: wire["project"] as? String,
                  owner: wire["owner"] as? String ?? "", stamp: date("stamp") ?? .distantPast)
    }
}
