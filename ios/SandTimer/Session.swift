import Foundation

/// What the timer is doing, as moments rather than a ticking count, so it is right whenever it is next looked at:
/// after the app was put away, the phone slept, or it restarted.
struct Session: Codable, Equatable {
    /// How long a flip gives you.
    var minutes = 25
    /// When the sand will run out, while it runs.
    var runningUntil: Date?
    /// How much is left, while paused.
    var pausedWith: TimeInterval?
    /// Where the record is counted up to while the sand runs: the time before this is already in the log.
    var countedFrom: Date?
    /// The project this session's time counts against, if any.
    var project: String?
    /// When this session began: a pause doesn't change it. A linked Mac knows the session by it.
    var started: Date?
    /// Whether this phone counts the session's time: not when a linked Mac started it and counts it there.
    var counts: Bool?

    func isRunning(at now: Date) -> Bool { (runningUntil ?? .distantPast) > now }
    func isPaused(at now: Date) -> Bool { !isRunning(at: now) && (pausedWith ?? 0) > 0 }
    /// Running or paused: under One Thing at a Time the project waits until this is over.
    func inSession(at now: Date) -> Bool { isRunning(at: now) || isPaused(at: now) }

    func remaining(at now: Date) -> TimeInterval {
        if let until = runningUntil, until > now { return until.timeIntervalSince(now) }
        return isPaused(at: now) ? pausedWith ?? 0 : 0
    }

    /// How much of the sand has fallen: 0 just flipped, 1 run out — and 1 while waiting to be flipped.
    func fallen(at now: Date) -> Double {
        let total = Double(minutes) * 60
        guard inSession(at: now), total > 0 else { return 1 }
        return min(1, max(0, 1 - remaining(at: now) / total))
    }
}

extension SandLog {
    /// Counts the sand running from `from` to `until`, split at each hour it crosses, so the hourly view is right.
    mutating func addRun(from: Date, until: Date, project: String, calendar: Calendar = .current) {
        var start = from
        while start < until {
            let hour = calendar.dateInterval(of: .hour, for: start)?.end ?? until
            let end = min(hour, until)
            add(seconds: end.timeIntervalSince(start), project: project, on: start, calendar: calendar)
            start = end
        }
    }
}

/// The timer and its record moving together: every change counts the sand that ran up to that moment. The same
/// rules as the Android app's (android/…/data/TimerState.kt).
struct Timekeeper: Equatable {
    var session: Session
    var log: SandLog

    /// Counts the sand that has run since it was last counted, stopping where the top emptied.
    mutating func count(at now: Date) {
        guard let from = session.countedFrom else { return }
        let until = min(now, session.runningUntil ?? now)
        guard until > from else { return }
        if session.counts != false { log.addRun(from: from, until: until, project: session.project ?? "") }
        session.countedFrom = until
    }

    /// Puts right a run that ended while nobody was looking: its time counted, and one more timer finished.
    /// Returns when it ran out, if it just has.
    @discardableResult
    mutating func settle(at now: Date) -> Date? {
        guard let until = session.runningUntil, until <= now else { return nil }
        count(at: until)
        if session.counts != false { log.add(finished: 1, project: session.project ?? "", on: until) }
        session.runningUntil = nil
        session.pausedWith = nil
        session.countedFrom = nil
        return until
    }

    mutating func start(at now: Date, minutes: Int, project: String?) {
        settle(at: now)
        count(at: now)
        session = Session(minutes: minutes, runningUntil: now.addingTimeInterval(Double(minutes) * 60), countedFrom: now,
                          project: project, started: now)
    }

    mutating func pause(at now: Date) {
        settle(at: now)
        guard let until = session.runningUntil, until > now else { return }
        count(at: now)
        session.runningUntil = nil
        session.pausedWith = until.timeIntervalSince(now)
        session.countedFrom = nil
    }

    mutating func resume(at now: Date) {
        guard session.isPaused(at: now), let left = session.pausedWith else { return }
        session.runningUntil = now.addingTimeInterval(left)
        session.pausedWith = nil
        session.countedFrom = now
    }

    /// Takes on the timer as a linked Mac left it, counting the time run here so far first, if it was this phone's.
    mutating func adopt(_ shared: SharedTimer, counts: Bool, at now: Date) {
        settle(at: now)
        count(at: now)
        var next = Session(minutes: shared.minutes, project: shared.project)
        switch shared.phase(at: now) {
        case .running:
            next.runningUntil = shared.runningUntil
            next.countedFrom = now
        case .paused:
            next.pausedWith = shared.pausedWith
        case .idle:
            session = next
            return
        }
        next.started = shared.started
        next.counts = counts
        session = next
    }

    /// Done early: the time run is kept, but it isn't a finished timer, and the sand settles to the bottom.
    mutating func end(at now: Date) {
        settle(at: now)
        count(at: now)
        session.runningUntil = nil
        session.pausedWith = nil
        session.countedFrom = nil
    }
}
