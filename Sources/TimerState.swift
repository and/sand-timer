import Foundation

/// What the timer is doing at this moment, written into the app's settings whenever it changes so that another
/// program — the MCP server Claude reads — can tell without asking the app. The record in `SandLog` says what has
/// already happened; this says what is happening now.
struct TimerState: Equatable {
    static let key = "timerState"
    /// Where commands from outside the app are allowed at all: off until the menu's control setting is turned on.
    static let controlKey = "allowControl"

    /// How long a flip gives you, in minutes.
    var minutes: Int = 0
    /// When the sand will run out, while it is running.
    var runningUntil: Date?
    /// How much is left, while it is paused.
    var pausedWith: TimeInterval?
    /// When the app last wrote this, so a reader can tell a fresh answer from a stale one.
    var updated = Date.distantPast

    func isRunning(at now: Date) -> Bool { (runningUntil ?? .distantPast) > now }
    func isPaused(at now: Date) -> Bool { !isRunning(at: now) && (pausedWith ?? 0) > 0 }

    /// Seconds of sand left: counted down while it runs, held still while paused, nothing once it has run out.
    func remaining(at now: Date) -> TimeInterval {
        if let until = runningUntil, until > now { return until.timeIntervalSince(now) }
        return isPaused(at: now) ? (pausedWith ?? 0) : 0
    }

    /// "running", "paused", or "waiting to be flipped" — how the timer would be described out loud.
    func describe(at now: Date) -> String {
        if isRunning(at: now) { return "running" }
        return isPaused(at: now) ? "paused" : "waiting to be flipped"
    }

    var stored: [String: Any] {
        var entry: [String: Any] = ["minutes": minutes, "updated": updated]
        if let runningUntil { entry["runningUntil"] = runningUntil }
        if let pausedWith { entry["pausedWith"] = pausedWith }
        return entry
    }

    static func load(stored: [String: Any]?) -> TimerState {
        guard let stored else { return TimerState() }
        return TimerState(minutes: stored["minutes"] as? Int ?? 0,
                          runningUntil: stored["runningUntil"] as? Date,
                          pausedWith: stored["pausedWith"] as? TimeInterval,
                          updated: stored["updated"] as? Date ?? .distantPast)
    }
}
