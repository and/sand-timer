import CryptoKit
import Foundation

func linkTests() {
    suite("Linking a phone") {
        let early = Date(timeIntervalSince1970: 1_000)
        let late = Date(timeIntervalSince1970: 2_000)

        test("a change made here stamps only the projects it touched") {
            let before = ProjectList(all: [Project(id: "a", name: "A", color: "#111111", updated: early),
                                           Project(id: "b", name: "B", color: "#222222", updated: early)])
            var after = before
            after.all[1].name = "Bee"
            after.all.append(Project(id: "c", name: "C", color: "#333333"))
            let stamped = after.stamped(since: before, at: late)
            expect(stamped.all.map(\.updated) == [early, late, late], "\(stamped.all.map(\.updated))")
        }

        test("two lists come together project by project, the later change winning") {
            let mine = ProjectList(all: [Project(id: "a", name: "Mac name", color: "#111111", updated: late),
                                         Project(id: "b", name: "Old", color: "#222222", updated: early)])
            let theirs = ProjectList(all: [Project(id: "b", name: "Phone name", color: "#222222", archived: true, updated: late),
                                           Project(id: "a", name: "Stale", color: "#111111", updated: early),
                                           Project(id: "c", name: "Made on phone", color: "#333333", updated: early)])
            let merged = mine.merged(with: theirs)
            expect(merged.all.map(\.id) == ["a", "b", "c"], "this list's order, then theirs")
            expect(merged.all.map(\.name) == ["Mac name", "Phone name", "Made on phone"])
            expect(merged.all[1].archived, "a removal on the phone is a change like any other")
            expect(merged.merged(with: theirs) == merged, "merging again changes nothing")
            expect(theirs.merged(with: mine).all.map(\.name).sorted() == merged.all.map(\.name).sorted(), "either way round")
        }

        test("a project's stamp survives the settings and the trip to a phone") {
            let project = Project(id: "a", name: "A", color: "#111111", updated: late)
            expect(Project(stored: project.stored) == project)
            let json = try JSONSerialization.data(withJSONObject: project.stored)
            let back = try require(try JSONSerialization.jsonObject(with: json) as? [String: Any], "JSON")
            expect(Project(stored: back) == project, "through JSON, as Firestore carries it")
            expect(Project(stored: ["id": "x"])?.updated == .distantPast, "a project from before linking loses to any change")
        }

        test("a phone's time adds to the Mac's, day, hour and project") {
            let calendar = Calendar(identifier: .gregorian)
            let morning = calendar.date(from: DateComponents(year: 2026, month: 10, day: 7, hour: 9, minute: 10))!
            var mac = SandLog()
            mac.add(seconds: 600, finished: 1, project: "a", on: morning, calendar: calendar)
            var phone = SandLog()
            phone.add(seconds: 300, project: "a", on: morning, calendar: calendar)
            phone.add(seconds: 120, project: "b", on: morning.addingTimeInterval(86_400), calendar: calendar)
            let both = mac.including(phone)
            let day = try require(both.days["2026-10-07"], "the day")
            expect(day.seconds == 900 && day.finished == 1)
            expect(day.projects["a"]?.seconds == 900)
            expect(day.hours[9]?.seconds == 900 && day.hours[9]?.projects["a"]?.seconds == 900)
            expect(both.days["2026-10-08"]?.projects["b"]?.seconds == 120, "a day only the phone ran")
        }

        test("the linked records are read back from the settings, all phones together") {
            let defaults = try require(UserDefaults(suiteName: "sand-timer-link-tests"), "a scratch settings domain")
            defer { defaults.removePersistentDomain(forName: "sand-timer-link-tests") }
            defaults.set(["phone-1": ["2026-10-07": ["seconds": 60, "finished": 1]],
                          "phone-2": ["2026-10-07": ["seconds": 30.5, "finished": 0,
                                                     "hours": ["9": ["seconds": 30.5, "finished": 0]]]]],
                         forKey: SandLog.linkedKey)
            let linked = SandLog.linked(from: defaults)
            expect(linked.days["2026-10-07"]?.seconds == 90.5, "whole seconds from a phone count too")
            expect(linked.days["2026-10-07"]?.finished == 1)
            expect(linked.days["2026-10-07"]?.hours[9]?.seconds == 30.5)
        }

        test("the record goes a month at a time") {
            var log = SandLog()
            let calendar = Calendar(identifier: .gregorian)
            for (month, day) in [(9, 30), (10, 1), (10, 7)] {
                log.add(seconds: 60, on: calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!, calendar: calendar)
            }
            let months = log.storedByMonth
            expect(Set(months.keys) == ["2026-09", "2026-10"])
            expect(Set(months["2026-10"]?.keys ?? [:].keys) == ["2026-10-01", "2026-10-07"])
            expect(SandLog.load(stored: months["2026-09"] ?? [:]).allTime.seconds == 60)
        }

        test("a month's digest changes with it, and only with it") {
            let body: [String: Any] = ["device": "d", "month": "2026-10", "days": ["2026-10-07": ["seconds": 60.0, "finished": 0]]]
            let same: [String: Any] = ["days": ["2026-10-07": ["finished": 0, "seconds": 60.0]], "month": "2026-10", "device": "d"]
            let more: [String: Any] = ["device": "d", "month": "2026-10", "days": ["2026-10-07": ["seconds": 61.0, "finished": 0]]]
            expect(LinkFormat.digest(body) == LinkFormat.digest(same), "the order things were written in doesn't matter")
            expect(LinkFormat.digest(body) != LinkFormat.digest(more))
        }

        test("what is sent opens again with the key, and with no other") {
            let key = SymmetricKey(size: .bits256)
            let sealed = try LinkFormat.seal(Data("{\"a\":1}".utf8), key: key)
            let opened = try LinkFormat.open(sealed, key: key)
            expect(String(decoding: opened, as: UTF8.self) == "{\"a\":1}")
            expect((try? LinkFormat.open(sealed, key: SymmetricKey(size: .bits256))) == nil, "a different key can't read it")
            expect(sealed.count == 12 + 7 + 16, "nonce, then the text, then the tag: the layout the phones expect")
        }

        test("the key goes into the code as base64url, without padding") {
            let bytes = Data([0xfb, 0xff, 0xfe, 0x00, 0x01])
            expect(LinkFormat.base64url(bytes) == "-__-AAE")
            let key = Data((0..<32).map { UInt8($0 * 7 & 0xff) })
            let text = LinkFormat.base64url(key)
            expect(!text.contains("=") && !text.contains("+") && !text.contains("/") && text.count == 43)
        }

        test("a code gives back the key it was made from, and nothing else is a code") {
            let key = Data((0..<32).map { UInt8($0 * 7 & 0xff) })
            expect(LinkFormat.parse(LinkFormat.code(key: key)) == key)
            expect(LinkFormat.parse("  " + LinkFormat.code(key: key) + "\n") == key, "stray space from a paste")
            expect(LinkFormat.parse("anchor-pair:2:x") == nil && LinkFormat.parse(LinkFormat.codePrefix + "short") == nil)
            expect(LinkFormat.parse("sandtimer-link:1:token:" + LinkFormat.base64url(key)) == nil, "the old Firebase code")
        }

        test("each key names its own Bluetooth service, the same one every time") {
            let key = Data((0..<32).map { UInt8($0) })
            let service = LinkFormat.serviceUUID(key: key)
            expect(service == LinkFormat.serviceUUID(key: key))
            expect(service != LinkFormat.serviceUUID(key: Data(repeating: 9, count: 32)))
            let text = service.uuidString
            expect(text[text.index(text.startIndex, offsetBy: 14)] == "4", "a version 4 UUID: \(text)")
        }

        test("a message goes in Bluetooth-sized pieces and comes back whole") {
            let message = Data((0..<1000).map { UInt8($0 & 0xff) })
            let frames = LinkFormat.frames(message, size: 182)
            expect(frames.allSatisfy { $0.count <= 182 })
            expect(frames.dropLast().allSatisfy { $0.first == 1 } && frames.last?.first == 0)
            var whole = LinkFormat.Reassembler()
            let results = frames.map { whole.add($0) }
            expect(results.dropLast().allSatisfy { $0 == nil } && results.last == message)
            expect(LinkFormat.frames(Data(), size: 20) == [Data([0])], "even an empty message is one piece")
            expect(whole.add(Data([0, 7])) == Data([7]), "and the next message starts afresh")
        }

        test("the shared timer travels and tells a change from an echo") {
            let now = Date(timeIntervalSince1970: 1_000_000)
            let running = SharedTimer(minutes: 25, started: now, runningUntil: now.addingTimeInterval(1500), project: "a",
                                      owner: "mac", stamp: now)
            let back = try require(SharedTimer(wire: try JSONSerialization.jsonObject(with: try JSONSerialization.data(withJSONObject: running.wire)) as? [String: Any]), "wire")
            expect(back == running)
            var late = running
            late.runningUntil = now.addingTimeInterval(1501)
            expect(running.matches(late, at: now), "a second out is an animation, not a change")
            late.runningUntil = now.addingTimeInterval(1510)
            expect(!running.matches(late, at: now))
            var paused = running
            paused.runningUntil = nil
            paused.pausedWith = 600
            expect(paused.phase(at: now) == .paused && paused.remaining(at: now) == 600 && !paused.matches(running, at: now))
            expect(running.phase(at: now.addingTimeInterval(1600)) == .idle, "run out is waiting to be flipped")
            var other = running
            other.started = now.addingTimeInterval(5)
            expect(!running.matches(other, at: now), "another session, even with the same end")
        }

        test("a Mac and two phones share one timer, the projects and every record") {
            try MainActor.assumeIsolated {
                let wire = TestWire()
                let mac = try wire.device("mac", hub: true)
                let phone = try wire.device("phone", hub: false)
                let other = try wire.device("other", hub: false)
                let early = Date(timeIntervalSince1970: 1_000), late = Date(timeIntervalSince1970: 2_000)
                mac.host.projects = ProjectList(all: [Project(id: "a", name: "Writing", color: "#111111", updated: late)])
                phone.host.projects = ProjectList(all: [Project(id: "a", name: "Old name", color: "#111111", updated: early),
                                                        Project(id: "b", name: "Reading", color: "#222222", updated: early)])
                let calendar = Calendar.current
                let today = Date()
                mac.host.log.add(seconds: 600, project: "a", on: today, calendar: calendar)
                phone.host.log.add(seconds: 300, finished: 1, project: "b", on: today, calendar: calendar)

                let code = try mac.engine.linkCode()
                try phone.engine.link(code: code)
                try other.engine.link(code: code)
                expect(mac.radio.service != nil && mac.radio.service == phone.radio.service, "both on the key's service")
                wire.connect(phone, to: mac)
                wire.connect(other, to: mac)
                wire.pump()

                expect(Set(mac.engine.devices.map(\.id)) == [phone.engine.deviceID, other.engine.deviceID])
                expect(mac.engine.connected == Set([phone.engine.deviceID, other.engine.deviceID]))
                expect(phone.engine.devices.map(\.name) == ["mac"], "the phone knows the Mac by name")
                for device in [mac, phone, other] {
                    expect(device.host.projects.all.map(\.name) == ["Writing", "Reading"], "\(device.name): \(device.host.projects.all.map(\.name))")
                }
                let day = SandLog.dayKey(today)
                expect(SandLog.linked(from: mac.defaults).days[day]?.seconds == 300, "the phone's time on the Mac")
                expect(SandLog.linked(from: phone.defaults).days[day]?.seconds == 600, "the Mac's time on the phone")
                expect(SandLog.linked(from: other.defaults).days[day]?.seconds == 900, "both, passed on to the other phone")

                // Started on the phone: the Mac and the other phone show it, and only the phone counts it.
                let now = Date()
                phone.host.timer = SharedTimer(minutes: 25, started: now, runningUntil: now.addingTimeInterval(1500), project: "b")
                phone.engine.timerChanged()
                wire.pump()
                let seen = try require(mac.host.adopted.last, "the Mac took the phone's timer")
                expect(seen.timer.phase(at: now) == .running && seen.timer.project == "b" && !seen.counts)
                let passed = try require(other.host.adopted.last?.timer.runningUntil, "passed on to the other phone")
                expect(abs(passed.timeIntervalSince(phone.host.timer.runningUntil!)) < 0.001)
                expect(!mac.engine.countsHere && phone.engine.countsHere)

                // The Mac's own view of the timer now matches: no echo goes back.
                let sent = wire.delivered
                mac.engine.timerChanged()
                wire.pump()
                expect(wire.delivered == sent, "an echo isn't sent")

                // Paused on the Mac: the phone lies its glass down, and still counts the session.
                var paused = mac.host.timer
                paused.runningUntil = nil
                paused.pausedWith = 1200
                mac.host.timer = paused
                mac.engine.timerChanged()
                wire.pump()
                let pause = try require(phone.host.adopted.last, "the phone took the pause")
                expect(pause.timer.phase(at: Date()) == .paused && pause.timer.pausedWith == 1200 && pause.counts)
                expect(pause.timer.owner == phone.engine.deviceID, "a pause keeps the session's owner")

                // A project renamed on the other phone reaches everyone.
                var renamed = other.host.projects
                renamed.all[1].name = "Books"
                other.host.projects = renamed.stamped(since: other.host.projects, at: Date())
                other.engine.projectsChanged()
                wire.pump()
                expect(mac.host.projects.all.map(\.name) == ["Writing", "Books"] && phone.host.projects.all.map(\.name) == ["Writing", "Books"])

                // A record that grows goes again, only the month that changed.
                phone.host.log.add(seconds: 60, project: "b", on: today, calendar: calendar)
                wire.disconnect(phone, from: mac)
                wire.connect(phone, to: mac)
                wire.pump()
                expect(SandLog.linked(from: mac.defaults).days[day]?.seconds == 360)
                expect(mac.engine.devices.count == 2, "reconnecting is the same phone")

                // Unlinked from the Mac: the phones forget the link and the others' time, keeping their own.
                mac.engine.unlink()
                wire.pump()
                expect(!phone.engine.isLinked && !other.engine.isLinked)
                expect(SandLog.linked(from: phone.defaults).days.isEmpty && phone.host.log.days[day]?.seconds == 360)
            }
        }

        test("linking stays off, Bluetooth untouched, until it's turned on") {
            try MainActor.assumeIsolated {
                let wire = TestWire()
                let mac = try wire.device("mac", hub: true)
                mac.engine.start()
                expect(!mac.engine.isEnabled && mac.radio.service == nil, "a fresh install never starts the radio")
                _ = try mac.engine.linkCode()
                expect(mac.engine.isEnabled && mac.radio.service != nil, "showing the code turns it on")
                mac.engine.setEnabled(false)
                expect(mac.radio.service == nil && mac.engine.isLinked, "off stops the radio, and keeps the link")
                mac.engine.start()
                expect(mac.radio.service == nil, "and it stays off")
                mac.engine.setEnabled(true)
                expect(mac.radio.service != nil)
                let before = mac.radio.service
                mac.engine.forget()  // as Unlink All leaves it
                expect(mac.radio.service == nil)
                _ = try mac.engine.linkCode()
                expect(mac.radio.service != nil && mac.radio.service != before, "a new code offers its new service straight away")
            }
        }

        test("lists that say the same settle at once, whatever the order or a stamp's last digit") {
            let now = Date()
            let a = Project(id: "a", name: "A", color: "#111111", updated: now)
            let b = Project(id: "b", name: "B", color: "#222222", updated: now.addingTimeInterval(-60))
            let mine = ProjectList(all: [a, b])
            // As another device writes it back: seconds since 1970, a hair off, in its own order.
            var theirs = ProjectList(all: [b, a])
            theirs.all[1].updated = Date(timeIntervalSince1970: now.timeIntervalSince1970 + 0.0000003)
            expect(mine.agrees(with: theirs) && theirs.agrees(with: mine))
            expect(mine.merged(with: theirs).agrees(with: mine), "nothing taken from a copy of itself")
            var renamed = theirs
            renamed.all[1].name = "Changed"
            renamed.all[1].updated = now.addingTimeInterval(1)
            expect(!mine.agrees(with: renamed) && mine.merged(with: renamed).project("a")?.name == "Changed")
            let twice = ProjectList(all: [a, b, Project(id: "a", name: "A again", color: "#333333", updated: now)])
            expect(twice.agrees(with: mine) && twice.merged(with: mine).all.count == 2, "a second copy of an id doesn't count")
            expect(ProjectList.load(stored: twice.all.map(\.stored)).all.map(\.name) == ["A", "B"], "and isn't loaded")
        }

        test("two devices with the same projects in another order stop talking") {
            try MainActor.assumeIsolated {
                let wire = TestWire()
                let mac = try wire.device("mac", hub: true)
                let phone = try wire.device("phone", hub: false)
                let now = Date()
                let projects = (0..<4).map { Project(id: "p\($0)", name: "P\($0)", color: "#111111", updated: now.addingTimeInterval(Double($0) * 0.37)) }
                mac.host.projects = ProjectList(all: projects)
                phone.host.projects = ProjectList(all: projects.reversed())
                try phone.engine.link(code: try mac.engine.linkCode())
                wire.connect(phone, to: mac)
                wire.pump(limit: 200)
                expect(wire.queue.isEmpty && wire.delivered < 50, "settled in \(wire.delivered) messages")
            }
        }

        test("a stranger's messages are ignored") {
            try MainActor.assumeIsolated {
                let wire = TestWire()
                let mac = try wire.device("mac", hub: true)
                let stranger = try wire.device("stranger", hub: false)
                _ = try mac.engine.linkCode()
                try stranger.engine.link(code: LinkFormat.code(key: Data(repeating: 1, count: 32)))
                stranger.host.log.add(seconds: 60, on: Date())
                wire.connect(stranger, to: mac)
                wire.pump()
                expect(mac.engine.devices.isEmpty && mac.engine.connected.isEmpty)
                expect(SandLog.linked(from: mac.defaults).days.isEmpty)
            }
        }
    }
}

/// A device in the tests: an engine, its settings, the app it works for and its end of the wire.
@MainActor
final class TestDevice {
    let name: String
    let engine: LinkEngine
    let host = TestHost()
    let radio: TestRadio
    let defaults: UserDefaults

    init(name: String, hub: Bool, wire: TestWire) throws {
        self.name = name
        let suite = "sand-timer-link-test-\(name)-\(UUID().uuidString)"
        defaults = try require(UserDefaults(suiteName: suite), "a scratch settings domain")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        engine = LinkEngine(name: name, kind: hub ? "mac" : "android", isHub: hub, defaults: defaults, folder: folder)
        radio = TestRadio(name: name, wire: wire)
        engine.host = host
        engine.transport = radio
    }
}

@MainActor
final class TestHost: LinkHost {
    var projects = ProjectList()
    var log = SandLog()
    var timer = SharedTimer(minutes: 25)
    var adopted: [(timer: SharedTimer, counts: Bool)] = []

    func takeLinkedProjects(_ list: ProjectList) { projects = list }
    func ownLog() -> SandLog { log }
    func localTimer() -> SharedTimer { SharedTimer(minutes: timer.minutes, started: timer.started, runningUntil: timer.runningUntil,
                                                   pausedWith: timer.pausedWith, project: timer.project) }
    func adopt(_ timer: SharedTimer, counts: Bool) {
        self.timer = timer
        adopted.append((timer, counts))
    }
    func linkChanged() {}
}

@MainActor
final class TestRadio: LinkTransport {
    let name: String
    unowned let wire: TestWire
    var service: UUID?
    init(name: String, wire: TestWire) { self.name = name; self.wire = wire }
    func start(service: UUID) { self.service = service }
    func stop() { service = nil }
    func send(_ message: Data, to peer: String) { wire.queue.append((from: name, to: peer, message: message)) }
}

/// Carries messages between test devices, in order, when pumped: a reply waits until the message it answers is done.
@MainActor
final class TestWire {
    var devices: [String: TestDevice] = [:]
    var queue: [(from: String, to: String, message: Data)] = []
    var delivered = 0

    func device(_ name: String, hub: Bool) throws -> TestDevice {
        let device = try TestDevice(name: name, hub: hub, wire: self)
        devices[name] = device
        return device
    }

    /// A phone finding the Mac: each side hears of the other, the phone first, as over Bluetooth.
    func connect(_ phone: TestDevice, to mac: TestDevice) {
        mac.engine.connected(peer: phone.name)
        phone.engine.connected(peer: mac.name)
    }

    func disconnect(_ phone: TestDevice, from mac: TestDevice) {
        mac.engine.disconnected(peer: phone.name)
        phone.engine.disconnected(peer: mac.name)
    }

    func pump(limit: Int = .max) {
        var left = limit
        while !queue.isEmpty && left > 0 {
            left -= 1
            let next = queue.removeFirst()
            delivered += 1
            devices[next.to]?.engine.received(next.message, from: next.from)
        }
    }
}
