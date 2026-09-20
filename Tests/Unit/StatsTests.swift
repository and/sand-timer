import Foundation

/// A calendar the tests can count on: Gregorian, no daylight saving, weeks starting on Monday.
private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = 2
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 12) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
}

/// Sunday 20 September 2026, in the week that started on Monday the 14th.
private let now = day(2026, 9, 20, hour: 10)

func statsTests() {
    suite("Statistics") {
        test("time run and finished timers land on the day they happened") {
            var log = SandLog()
            log.add(seconds: 300, on: now, calendar: calendar)
            log.add(seconds: 60, finished: 1, on: now, calendar: calendar)
            log.add(seconds: 900, finished: 1, on: day(2026, 9, 19), calendar: calendar)
            let days = log.buckets(.daily, at: now, calendar: calendar)
            expect(days.count == 14, "a fortnight of bars, got \(days.count)")
            expect(days.last?.seconds == 360 && days.last?.finished == 1, "today: \(String(describing: days.last))")
            expect(days.last?.title == "Today" && days[days.count - 2].title == "Yesterday")
            expect(days[days.count - 2].seconds == 900, "yesterday keeps its own total")
            expect(days.first?.seconds == 0, "a day with nothing in it is still there, empty")
            expect(days.map(\.start) == days.map(\.start).sorted(), "oldest first")
        }

        test("a week, a month and a year gather the days inside them") {
            var log = SandLog()
            log.add(seconds: 600, on: day(2026, 9, 14), calendar: calendar)   // Monday, this week
            log.add(seconds: 600, on: now, calendar: calendar)                // Sunday, the same week
            log.add(seconds: 1200, on: day(2026, 9, 13), calendar: calendar)  // the Sunday before: last week
            log.add(seconds: 3600, on: day(2026, 2, 2), calendar: calendar)   // earlier this year
            log.add(seconds: 1800, on: day(2025, 11, 5), calendar: calendar)  // last year

            let weeks = log.buckets(.weekly, at: now, calendar: calendar)
            expect(weeks.count == 12)
            expect(weeks.last?.seconds == 1200, "this week runs Monday to Sunday: \(weeks.last?.seconds ?? -1)")
            expect(weeks.last?.start == day(2026, 9, 14, hour: 0), "starting on the Monday")
            expect(weeks[weeks.count - 2].seconds == 1200, "the week before keeps the Sunday before")

            let months = log.buckets(.monthly, at: now, calendar: calendar)
            expect(months.count == 12 && months.last?.seconds == 2400, "September: \(months.last?.seconds ?? -1)")
            expect(months.first(where: { $0.start == day(2026, 2, 1, hour: 0) })?.seconds == 3600, "February is still in the last twelve months")

            let years = log.buckets(.yearly, at: now, calendar: calendar)
            expect(years.count == 5)
            expect(years.last?.seconds == 6000 && years.last?.title == "This year", "this year: \(years.last?.seconds ?? -1)")
            expect(years[years.count - 2].seconds == 1800, "last year kept apart")
            expect(log.allTime.seconds == 7800, "all time adds up every day")
        }

        test("days older than the longest view are forgotten") {
            var log = SandLog()
            log.add(seconds: 60, on: day(2019, 5, 5), calendar: calendar)
            log.add(seconds: 60, on: day(2022, 1, 1), calendar: calendar)
            log.add(seconds: 60, on: now, calendar: calendar)
            log.prune(at: now, calendar: calendar)
            expect(log.days.count == 2, "five years of days are kept, got \(log.days.count)")
            expect(log.buckets(.yearly, at: now, calendar: calendar).first?.start == day(2022, 1, 1, hour: 0),
                   "the oldest year shown is the oldest year kept")
            expect(log.firstDay(calendar: calendar) == day(2022, 1, 1, hour: 0))
        }

        test("a spell of sand is written in the shortest form that reads naturally") {
            expect(SandLog.durationLabel(0) == "0s")
            expect(SandLog.durationLabel(42.4) == "42s")
            expect(SandLog.durationLabel(60) == "1m")
            expect(SandLog.durationLabel(25 * 60) == "25m")
            expect(SandLog.durationLabel(3600) == "1h")
            expect(SandLog.durationLabel(3 * 3600 + 20 * 60) == "3h 20m")
            expect(SandLog.timersLabel(1) == "1 timer" && SandLog.timersLabel(0) == "0 timers")
        }

        test("the record survives a restart") {
            let defaults = try require(UserDefaults(suiteName: "sand-timer-tests"), "a scratch settings domain")
            defaults.removeObject(forKey: SandLog.defaultsKey)
            var log = SandLog()
            log.add(seconds: 1500, finished: 2, on: now, calendar: calendar)
            log.save(to: defaults)
            let reloaded = SandLog.load(from: defaults)
            expect(reloaded == log, "what was written comes back")
            expect(reloaded.allTime.seconds == 1500 && reloaded.allTime.finished == 2)
            expect(SandLog.load(from: defaults).days.count == 1)
            defaults.removeObject(forKey: SandLog.defaultsKey)
        }
    }
}
