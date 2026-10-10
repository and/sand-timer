import AppKit

/// The real Mac timer linked to a phone, the phone's side played by a second engine and the radio by a queue: what the
/// Mac's hand does to the glass — knocking it over, standing it up, either way round — reaches the phone.
func linkedTimerTests() {
    suite("A linked phone") {
        test("knocked over or stood up on the Mac, either way round, the phone follows") {
            try MainActor.assumeIsolated {
                let timer = TimerHarness(minutes: 25)
                let link = try LinkedPair(mac: timer.view)
                timer.click(); timer.settle()
                link.pump()
                expect(link.phone.last?.phase(at: Date()) == .running, "started on the Mac, running on the phone")

                for side: CGFloat in [-1, 1] {
                    let name = side < 0 ? "left" : "right"
                    timer.pressTopCap(); timer.pushTopCap(by: 220 * side, steps: 20); timer.releaseTopCap()
                    timer.settle(minimum: 0.8)
                    link.pump()
                    expect(timer.isPaused, "knocked over to the \(name): paused on the Mac")
                    expect(link.phone.last?.phase(at: Date()) == .paused, "knocked over to the \(name): paused on the phone, not \(String(describing: link.phone.last?.phase(at: Date())))")

                    let pivot = try require(timer.view.lyingPivot, "the corner it lies on")
                    timer.pressTopCap()
                    timer.liftTopCap(toLean: -0.15 * Double(side), from: Double(side) * .pi / 2, pivot: pivot)
                    timer.releaseTopCap()
                    timer.settle(minimum: 1.5)
                    link.pump()
                    expect(timer.isRunning, "stood up from the \(name): running on the Mac")
                    expect(link.phone.last?.phase(at: Date()) == .running, "stood up from the \(name): running on the phone")
                    if let until = link.phone.last?.runningUntil {
                        expect(abs(until.timeIntervalSince(Date().addingTimeInterval(timer.view.secondsLeft))) < 2,
                               "the same sand left on both")
                    }
                }

                // Leaning without toppling slows the sand; the phone hears where it now runs out.
                timer.pressTopCap(); timer.pushTopCap(by: 60, steps: 10)
                timer.run(4)
                timer.releaseTopCap(); timer.settle(minimum: 1.2)
                link.pump()
                if let until = link.phone.last?.runningUntil {
                    expect(abs(until.timeIntervalSince(Date().addingTimeInterval(timer.view.secondsLeft))) < 2,
                           "after a lean, the phone runs out with the Mac: \(until) vs \(timer.view.secondsLeft)s left")
                }

                timer.menu("endClicked"); timer.settle()
                link.pump()
                expect(link.phone.last?.phase(at: Date()) == .idle, "ended on the Mac, ended on the phone")
            }
        }
    }
}

/// A Mac engine for the harness's timer and a phone engine, joined by a queue pumped by hand.
@MainActor
final class LinkedPair: LinkTransport {
    let mac: LinkEngine
    let phoneEngine: LinkEngine
    let phone = PhoneStandIn()
    private let phoneRadio = PhoneRadio()
    private var queue: [(to: String, message: Data)] = []

    /// What the phone was last told the timer is.
    final class PhoneStandIn: LinkHost {
        var projects = ProjectList()
        var last: SharedTimer?
        func takeLinkedProjects(_ list: ProjectList) { projects = list }
        func ownLog() -> SandLog { SandLog() }
        func localTimer() -> SharedTimer { last.map { SharedTimer(minutes: $0.minutes, started: $0.started, runningUntil: $0.runningUntil,
                                                                  pausedWith: $0.pausedWith, project: $0.project) } ?? SharedTimer(minutes: 25) }
        func adopt(_ timer: SharedTimer, counts: Bool) { last = timer }
        func linkChanged() {}
    }

    final class PhoneRadio: LinkTransport {
        weak var pair: LinkedPair?
        func start(service: UUID) {}
        func stop() {}
        func send(_ message: Data, to peer: String) { pair?.queue.append(("mac", message)) }
    }

    init(mac view: HourglassView) throws {
        func engine(_ name: String, hub: Bool) throws -> LinkEngine {
            let suite = "sand-timer-linked-\(name)-\(UUID().uuidString)"
            let defaults = try require(UserDefaults(suiteName: suite), "settings for \(name)")
            return LinkEngine(name: name, kind: hub ? "mac" : "android", isHub: hub, defaults: defaults,
                              folder: FileManager.default.temporaryDirectory.appendingPathComponent(suite))
        }
        mac = try engine("mac", hub: true)
        phoneEngine = try engine("phone", hub: false)
        phoneRadio.pair = self
        mac.host = view
        view.link = mac
        mac.transport = self
        phoneEngine.host = phone
        phoneEngine.transport = phoneRadio
        try phoneEngine.link(code: try mac.linkCode())
        mac.connected(peer: "phone")
        phoneEngine.connected(peer: "mac")
        pump()
    }

    func start(service: UUID) {}
    func stop() {}
    func send(_ message: Data, to peer: String) { queue.append(("phone", message)) }

    func pump() {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if next.to == "mac" { mac.received(next.message, from: "phone") } else { phoneEngine.received(next.message, from: "mac") }
        }
    }
}
