import Foundation

/// A calendar kept in memory: entries by id, in the order they were made.
final class MemoryCalendar: CalendarStore {
    struct Entry { var title: String; var start: Date; var end: Date }
    var entries: [Entry] = []
    func create(title: String, start: Date, end: Date) -> String? {
        entries.append(Entry(title: title, start: start, end: end))
        return String(entries.count - 1)
    }
    func setEnd(of id: String, to end: Date) { entries[Int(id)!].end = end }
}

func calendarTests() {
    suite("Calendar") {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let session = t0
        func make() throws -> (CalendarLog, MemoryCalendar) {
            let defaults = try require(UserDefaults(suiteName: "sand-timer-calendar-tests"), "a scratch settings domain")
            defaults.removePersistentDomain(forName: "sand-timer-calendar-tests")
            let memory = MemoryCalendar()
            let log = CalendarLog(store: memory, defaults: defaults)
            log.active = true
            log.setEnabled(true)
            return (log, memory)
        }
        func run(_ log: CalendarLog, from: TimeInterval, to: TimeInterval, due: TimeInterval, session key: Date = session, name: String = "Writing") {
            var at = from
            while at <= to {
                log.update(running: true, session: key, finish: t0.addingTimeInterval(due), project: name, at: t0.addingTimeInterval(at))
                at += 1
            }
        }
        func stop(_ log: CalendarLog, at: TimeInterval) {
            log.update(running: false, session: session, finish: nil, project: "Writing", at: t0.addingTimeInterval(at))
        }

        test("starting adds an entry named for the project, from the start to when the sand runs out") {
            let (log, calendar) = try make()
            run(log, from: 0, to: 5, due: 1500)
            expect(calendar.entries.count == 1)
            expect(calendar.entries[0].title == "Writing")
            expect(calendar.entries[0].start == t0, "from the moment the sand started, not when it was entered")
            expect(calendar.entries[0].end == t0.addingTimeInterval(1500))
        }

        test("pausing shortens the entry to now; resuming adds another named resume, for the time left") {
            let (log, calendar) = try make()
            run(log, from: 0, to: 600, due: 1500)
            stop(log, at: 601)
            expect(calendar.entries[0].end == t0.addingTimeInterval(601), "cut short at the pause")
            run(log, from: 900, to: 905, due: 1800)
            expect(calendar.entries.count == 2)
            expect(calendar.entries[1].title == "Writing - resume")
            expect(calendar.entries[1].start == t0.addingTimeInterval(900))
            expect(calendar.entries[1].end == t0.addingTimeInterval(1800), "for the time that was left")
            stop(log, at: 1000)
            run(log, from: 1100, to: 1105, due: 1900)
            expect(calendar.entries[2].title == "Writing - resume", "and again after the next pause")
        }

        test("a new session, by restart or flip, is a new entry without resume; the old one stops there") {
            let (log, calendar) = try make()
            run(log, from: 0, to: 100, due: 1500)
            run(log, from: 101, to: 105, due: 1600, session: t0.addingTimeInterval(101))
            expect(calendar.entries.count == 2 && calendar.entries[1].title == "Writing")
            expect(calendar.entries[0].end == t0.addingTimeInterval(101), "the first stretch ends where the second begins")
        }

        test("a run that stops at once leaves nothing, so a paused run restored at launch adds no entry") {
            let (log, calendar) = try make()
            run(log, from: 0, to: 1, due: 1500)
            stop(log, at: 1)
            expect(calendar.entries.isEmpty)
        }

        test("the end follows the sand when it speeds up or slows down by more than a minute, not for less") {
            let (log, calendar) = try make()
            run(log, from: 0, to: 5, due: 1500)
            run(log, from: 6, to: 6, due: 1530)
            expect(calendar.entries[0].end == t0.addingTimeInterval(1500), "thirty seconds is left alone")
            run(log, from: 7, to: 7, due: 1400)
            expect(calendar.entries[0].end == t0.addingTimeInterval(1400))
        }

        test("quitting ends the entry; turned off, nothing is added") {
            let (log, calendar) = try make()
            run(log, from: 0, to: 10, due: 1500)
            log.quitting(at: t0.addingTimeInterval(11))
            expect(calendar.entries[0].end == t0.addingTimeInterval(11))
            log.setEnabled(false)
            run(log, from: 20, to: 30, due: 1500, session: t0.addingTimeInterval(20))
            expect(calendar.entries.count == 1)
        }
    }
}
