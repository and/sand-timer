import Foundation
import SwiftUI
import UserNotifications

/// Everything the screens show, kept in the app's settings under the same names the Mac uses for the record and
/// the projects. Every change goes through here, so the screens and the notification always agree.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var timer: Timekeeper
    @Published private(set) var projects: ProjectList
    @Published private(set) var activeProject: String?
    /// Linked devices' records, added together.
    @Published private(set) var linkedLog: SandLog
    @Published var chime: Bool { didSet { defaults.set(chime, forKey: "chime") } }
    @Published var targetMinutes: Int { didSet { defaults.set(targetMinutes, forKey: HourglassView.dailyTargetKey) } }
    @Published var oneThingAtATime: Bool { didSet { defaults.set(oneThingAtATime, forKey: HourglassView.oneThingKey) } }
    /// Keep the screen awake while the sand runs and the timer is showing.
    @Published var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "keepScreenOn") } }
    /// While the sand runs, hide everything but the glass until the phone moves.
    @Published var cleanView: Bool { didSet { defaults.set(cleanView, forKey: "cleanView") } }
    // Linking, as the link last told it
    @Published private(set) var linkEnabled = false
    @Published private(set) var linked = false
    @Published private(set) var devices: [LinkEngine.Device] = []
    @Published private(set) var connected: Set<String> = []
    @Published private(set) var linkProblem: String?

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let session = (defaults.data(forKey: "session")).flatMap { try? JSONDecoder().decode(Session.self, from: $0) } ?? Session()
        timer = Timekeeper(session: session, log: SandLog.load(from: defaults))
        projects = ProjectList.load(from: defaults)
        activeProject = defaults.string(forKey: ProjectList.activeKey)
        linkedLog = SandLog.linked(from: defaults)
        chime = defaults.object(forKey: "chime") as? Bool ?? true
        targetMinutes = defaults.integer(forKey: HourglassView.dailyTargetKey)
        oneThingAtATime = defaults.object(forKey: HourglassView.oneThingKey) as? Bool ?? true
        keepScreenOn = defaults.object(forKey: "keepScreenOn") as? Bool ?? true
        cleanView = defaults.object(forKey: "cleanView") as? Bool ?? true
    }

    /// This phone's record with the linked devices': what Statistics and the target count.
    var wholeLog: SandLog { timer.log.including(linkedLog) }

    // MARK: The timer

    private func change(_ edit: (inout Timekeeper) -> Void) {
        var t = timer
        edit(&t)
        t.log.prune(at: Date())
        guard t != timer else { return }
        if t.log != timer.log { t.log.save(to: defaults) }
        if t.session != timer.session { defaults.set(try? JSONEncoder().encode(t.session), forKey: "session") }
        timer = t
        Notifier.schedule(timer.session, projects: projects, chime: chime)
        LinkClient.engine.timerChanged()
    }

    /// Brings the record up to now: a run that ended while the app was away is put right, the time so far counted.
    func refresh() {
        settle()
        change { $0.count(at: Date()) }
    }

    /// Puts right a run whose sand has run out. The notification scheduled for that moment chimes, in the app or out.
    func settle() {
        change { $0.settle(at: Date()) }
    }

    /// A tap on the glass: flip it when it's waiting, pause it while it runs, carry on when it's paused.
    func tap() {
        let now = Date()
        if timer.session.isRunning(at: now) { pause() } else if timer.session.isPaused(at: now) { resume() } else { start() }
    }

    func start() { change { $0.start(at: Date(), minutes: $0.session.minutes, project: activeProject) } }
    func pause() { change { $0.pause(at: Date()) } }
    func resume() { change { $0.resume(at: Date()) } }
    func end() { change { $0.end(at: Date()) } }
    func setMinutes(_ minutes: Int) { change { $0.session.minutes = min(60, max(1, minutes)) } }

    // MARK: Projects

    /// A change made here: the projects it touched are stamped now, for merging with a linked Mac's.
    func updateProjects(_ list: ProjectList) {
        setProjects(list.stamped(since: projects, at: Date()))
        LinkClient.engine.projectsChanged()
    }

    /// Takes a list as it stands: from `updateProjects`, or put together with a linked Mac's.
    func setProjects(_ list: ProjectList) {
        list.save(to: defaults)
        projects = list
        if projects.project(activeProject)?.archived != false { setActiveProject(nil) }
    }

    func setActiveProject(_ id: String?) {
        guard id != activeProject else { return }
        activeProject = id
        if let id { defaults.set(id, forKey: ProjectList.activeKey) } else { defaults.removeObject(forKey: ProjectList.activeKey) }
        LinkClient.engine.timerChanged()  // a linked Mac shows the project that's on
    }

    // MARK: Linking

    /// Reads how the link stands again, for the screens.
    func linkChanged() {
        let engine = LinkClient.engine
        linkEnabled = engine.isEnabled
        linked = engine.isLinked
        devices = engine.devices
        connected = engine.connected
        linkProblem = engine.isEnabled ? LinkClient.radio.problem : nil
        linkedLog = SandLog.linked(from: defaults)
    }
}

extension Store: LinkHost {
    func takeLinkedProjects(_ list: ProjectList) { setProjects(list) }

    func ownLog() -> SandLog {
        refresh()  // the time run so far counts, not just finished stretches
        return timer.log
    }

    func localTimer() -> SharedTimer {
        let now = Date()
        let s = timer.session
        let inSession = s.inSession(at: now)
        return SharedTimer(minutes: s.minutes, started: inSession ? s.started : nil,
                           runningUntil: s.isRunning(at: now) ? s.runningUntil : nil,
                           pausedWith: s.isPaused(at: now) ? s.pausedWith : nil,
                           project: inSession ? s.project : activeProject)
    }

    func adopt(_ shared: SharedTimer, counts: Bool) {
        if shared.project == nil || projects.project(shared.project) != nil { setActiveProject(shared.project) }
        change { $0.adopt(shared, counts: counts, at: Date()) }
    }
}

/// Names the Mac's own code uses for settings this app shares, kept here so the two read the same keys.
enum HourglassView {
    static let dailyTargetKey = "dailyTargetMinutes"
    static let oneThingKey = "oneThingAtATime"
}

