import EventKit
import Foundation

/// Where calendar entries are made. The real one is the Calendar database; tests use a list in memory.
protocol CalendarStore: AnyObject {
    /// Makes an entry and returns what it can be found by again, or nil if it could not be made.
    func create(title: String, start: Date, end: Date) -> String?
    /// Moves the end of an entry made earlier.
    func setEnd(of id: String, to end: Date)
}

/// Puts the time the sand runs onto the calendar. Every stretch of running is one entry: it starts when the sand
/// starts, ends when the sand is due to run out, and is cut short to the moment of a pause, an end or a quit. The
/// first stretch of a session carries the project's name; each one after a pause carries it followed by "- resume".
///
/// It is driven the way `FocusShortcuts` is: the tick says whether the sand is running, and this works out what
/// that means for the calendar, so every way of starting or stopping (a click, a link, a phone, the sand running out)
/// is covered without each one being told.
final class CalendarLog {
    static let shared = CalendarLog()
    static let enabledKey = "calendarLog"
    static let calendarKey = "calendarLogCalendar"
    /// How long a stretch must have run before it is entered. A paused run restored at launch is, for one tick, running;
    /// that must not leave an entry behind.
    static let settle: TimeInterval = 2
    /// How far the due time may drift (leaning the glass, shaking it) before the entry is moved.
    static let drift: TimeInterval = 60
    static let resumeSuffix = " - resume"

    /// Only the app's own timer drives it; tests make their own, so they never touch anyone's calendar.
    var active = false
    var isEnabled: Bool
    var store: CalendarStore
    private let defaults: UserDefaults

    /// The entry for the stretch running now.
    private var open: (id: String, end: Date, start: Date)?
    /// When the stretch running now began, before it has run long enough to be entered.
    private var waiting: (since: Date, session: Date)?
    /// The session the open entry, or the last one made, belongs to.
    private var session: Date?

    init(store: CalendarStore = EventKitStore(), defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.enabledKey)
    }

    func setEnabled(_ on: Bool, at now: Date = Date()) {
        if !on { close(at: now) }
        isEnabled = on
        waiting = nil
        defaults.set(on, forKey: Self.enabledKey)
    }

    /// Called every tick. `session` is when the run began (a restart or a flip begins another), `finish` when the
    /// sand is due to run out, and `project` the name to put on the entry.
    func update(running: Bool, session started: Date?, finish: Date?, project: String, at now: Date = Date()) {
        guard active, isEnabled else { return }
        guard running, let finish else {
            waiting = nil
            close(at: now)
            return
        }
        let key = started ?? .distantPast
        if let current = open {
            if key == session {
                if abs(finish.timeIntervalSince(current.end)) > Self.drift {
                    store.setEnd(of: current.id, to: max(finish, current.start.addingTimeInterval(1)))
                    open = (current.id, finish, current.start)
                }
                return
            }
            close(at: now)  // a restart while running: that stretch is over, another begins
        }
        if waiting?.session != key { waiting = (now, key) }
        guard let waiting, now.timeIntervalSince(waiting.since) >= Self.settle else { return }
        let resuming = session == key
        let title = resuming ? project + Self.resumeSuffix : project
        if let id = store.create(title: title, start: waiting.since, end: finish) {
            open = (id, finish, waiting.since)
        }
        session = key
        self.waiting = nil
    }

    /// The app is quitting: the entry stops where the sand does. A run carried on at the next launch gets its own.
    func quitting(at now: Date = Date()) { close(at: now) }

    private func close(at now: Date) {
        guard let current = open else { return }
        store.setEnd(of: current.id, to: max(now, current.start.addingTimeInterval(1)))
        open = nil
    }
}

/// The Calendar database, through EventKit.
final class EventKitStore: CalendarStore {
    private let store = EKEventStore()

    static var status: EKAuthorizationStatus { EKEventStore.authorizationStatus(for: .event) }
    static var hasAccess: Bool {
        if #available(macOS 14, *) { return status == .fullAccess }
        return status.rawValue == 3  // `.authorized`, which macOS 14 renamed `.fullAccess`
    }

    /// Asks macOS for access to the calendar, which it puts to the user the first time.
    func requestAccess(_ done: @escaping (Bool) -> Void) {
        let finish: (Bool, Error?) -> Void = { granted, _ in DispatchQueue.main.async { done(granted) } }
        if #available(macOS 14, *) { store.requestFullAccessToEvents(completion: finish) } else { store.requestAccess(to: .event, completion: finish) }
    }

    /// The calendars entries can be put in: name and identifier.
    var calendars: [(id: String, name: String)] {
        store.calendars(for: .event).filter(\.allowsContentModifications).map { ($0.calendarIdentifier, $0.title) }
    }

    private var chosen: EKCalendar? {
        UserDefaults.standard.string(forKey: CalendarLog.calendarKey).flatMap(store.calendar(withIdentifier:))
            ?? store.defaultCalendarForNewEvents
    }

    func create(title: String, start: Date, end: Date) -> String? {
        guard Self.hasAccess, let calendar = chosen else { return nil }
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = title
        event.startDate = start
        event.endDate = max(end, start.addingTimeInterval(1))
        event.notes = "Made by Sand Timer."
        do { try store.save(event, span: .thisEvent, commit: true) } catch { return nil }
        return event.eventIdentifier
    }

    func setEnd(of id: String, to end: Date) {
        guard Self.hasAccess, let event = store.event(withIdentifier: id) else { return }
        event.endDate = max(end, event.startDate.addingTimeInterval(1))
        try? store.save(event, span: .thisEvent, commit: true)
    }
}
