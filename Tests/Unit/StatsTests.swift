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

        test("a chart is ruled at round amounts of time, two to four lines of them") {
            expect(SandLog.gridStep(for: 25 * 60) == 600, "under half an hour: every ten minutes")
            expect(SandLog.gridStep(for: 56 * 60) == 900, "under an hour: every quarter of an hour")
            expect(SandLog.gridStep(for: 3 * 3600 + 31 * 60) == 3600, "a long morning: every hour")
            expect(SandLog.gridStep(for: 8 * 3600) == 7200, "a working day: every two hours")
            for most in stride(from: 300.0, to: 200_000, by: 137) {
                let step = SandLog.gridStep(for: most), lines = (most / step).rounded(.down)
                expect(most / step <= 4.0001, "\(SandLog.durationLabel(most)) would be ruled \(Int(most / step)) times")
                expect(lines >= 1, "\(SandLog.durationLabel(most)) would have no line at all")
            }
        }

        test("an export covers every span since the first day, not just the ones on the chart") {
            var log = SandLog()
            log.add(seconds: 1500, finished: 1, on: day(2026, 1, 2), calendar: calendar)
            log.add(seconds: 600, on: day(2026, 1, 3), calendar: calendar)
            log.add(seconds: 90, on: now, calendar: calendar)

            let daily = log.csv(.daily, at: now, calendar: calendar).split(separator: "\n").map(String.init)
            expect(daily.first == "Start,End,Time run (seconds),Time run (minutes),Timers finished", "got \(daily.first ?? "")")
            expect(daily.count == 263, "every day from 2 January to 20 September, header included: \(daily.count)")
            expect(daily[1] == "2026-01-02,2026-01-02,1500,25.0,1", "got \(daily[1])")
            expect(daily[2] == "2026-01-03,2026-01-03,600,10.0,0", "got \(daily[2])")
            expect(daily.last == "2026-09-20,2026-09-20,90,1.5,0", "today comes last: \(daily.last ?? "")")
            expect(daily.contains("2026-05-05,2026-05-05,0,0.0,0"), "a day the timer wasn't used is still a row")

            let monthly = log.csv(.monthly, at: now, calendar: calendar).split(separator: "\n").map(String.init)
            expect(monthly.count == 10, "nine months and a header: \(monthly.count)")
            expect(monthly[1] == "2026-01-01,2026-01-31,2100,35.0,1", "January runs to the 31st: \(monthly[1])")
            expect(monthly.last == "2026-09-01,2026-09-20,90,1.5,0", "the month still running ends today: \(monthly.last ?? "")")
            expect(log.csv(.yearly, at: now, calendar: calendar).split(separator: "\n").count == 2, "one year, one row")
            expect(SandLog().csv(.daily, at: now, calendar: calendar).split(separator: "\n").count == 1, "nothing recorded: just the header")
            expect(SandLog.exportFilename(at: now, calendar: calendar) == "sand_timer_report_202609201000.csv",
                   "named for the moment it was saved: \(SandLog.exportFilename(at: now, calendar: calendar))")
        }

        test("today's progress against a daily target reads as minutes and seconds") {
            expect(SandLog.goalLabel(seconds: 21 * 60 + 18, target: 3600) == "21:18/60:00", SandLog.goalLabel(seconds: 1278, target: 3600))
            expect(SandLog.goalLabel(seconds: 0, target: 1800) == "0:00/30:00", "nothing run yet")
            expect(SandLog.goalLabel(seconds: 3600 + 5, target: 3600) == "60:05/60:00", "past the target it goes on counting")
            expect(SandLog.goalLabel(seconds: 59.9, target: 60) == "0:59/1:00", "a second isn't counted until it is over")
            expect(SandLog.goalLabel(seconds: 4878, target: 7200) == "1:21:18/2:00:00", "a long target is read in hours")
            var log = SandLog()
            log.add(seconds: 300, on: now, calendar: calendar)
            log.add(seconds: 900, on: day(2026, 9, 19), calendar: calendar)
            expect(log.seconds(on: now, calendar: calendar) == 300, "only today's sand counts toward today")
            expect(SandLog().seconds(on: now, calendar: calendar) == 0)
        }

        test("the marks along the base fall at round amounts of time inside the target") {
            expect(SandLog.goalTicks(target: 3 * 3600) == [1.0 / 3, 2.0 / 3], "hours for three hours: \(SandLog.goalTicks(target: 10800))")
            expect(SandLog.goalTicks(target: 3600) == [0.25, 0.5, 0.75], "quarters of an hour for one: \(SandLog.goalTicks(target: 3600))")
            expect(SandLog.goalTicks(target: 8 * 3600).count == 3, "every two hours for eight")
            expect(SandLog.goalTicks(target: 120).isEmpty, "a target too short to mark has none")
            expect(SandLog.goalTicks(target: 0).isEmpty, "and no target has none")
            expect(SandLog.goalTicks(target: 5400).allSatisfy { $0 > 0 && $0 < 1 }, "none at either end")
        }

        test("an hourly view gathers the time into the hours it ran in, the one happening now last") {
            var log = SandLog()
            log.add(seconds: 600, on: day(2026, 9, 20, hour: 9), calendar: calendar)
            log.add(seconds: 300, finished: 1, on: calendar.date(byAdding: .minute, value: 40, to: day(2026, 9, 20, hour: 9))!, calendar: calendar)
            log.add(seconds: 120, on: now, calendar: calendar)                        // 10:00, the hour happening now
            log.add(seconds: 900, on: day(2026, 9, 19, hour: 11), calendar: calendar)   // yesterday, 23 hours back
            log.add(seconds: 60, on: day(2026, 9, 19, hour: 9), calendar: calendar)     // 25 hours back: out of view
            let hours = log.buckets(.hourly, at: now, calendar: calendar)
            expect(hours.count == 24, "a day of bars, got \(hours.count)")
            expect(hours.last?.seconds == 120 && hours.last?.title == "This hour", "now: \(String(describing: hours.last))")
            expect(hours[hours.count - 2].seconds == 900 && hours[hours.count - 2].finished == 1, "nine o'clock: both runs and the finish")
            expect(hours[hours.count - 2].title == "Last hour")
            expect(hours.first?.seconds == 900, "eleven yesterday opens the chart")
            expect(hours.map(\.seconds).reduce(0, +) == 1920, "and the hour before it is left out")
            expect(log.buckets(.daily, at: now, calendar: calendar).last?.seconds == 1020, "the day's total is unchanged by any of it")
        }

        test("an hourly export starts at the first hour kept, and says which hour each row is") {
            var log = SandLog()
            log.add(seconds: 600, on: day(2026, 9, 20, hour: 8), calendar: calendar)
            let rows = log.csv(.hourly, at: now, calendar: calendar).split(separator: "\n").map(String.init)
            expect(rows.count == 4, "08:00, 09:00 and 10:00, and a header: \(rows.count)")
            expect(rows[1] == "2026-09-20 08:00,2026-09-20 09:00,600,10.0,0", "got \(rows[1])")
            expect(rows.last?.hasPrefix("2026-09-20 10:00,2026-09-20 11:00,") == true, "got \(rows.last ?? "")")
        }

        test("the hours survive a restart, an older record without them still loads, and old detail is let go") {
            let defaults = try require(UserDefaults(suiteName: "sand-timer-tests"), "a scratch settings domain")
            defer { defaults.removeObject(forKey: SandLog.defaultsKey) }
            var log = SandLog()
            log.add(seconds: 1500, finished: 1, on: day(2026, 9, 20, hour: 14), calendar: calendar)
            log.save(to: defaults)
            expect(SandLog.load(from: defaults) == log, "hours and all come back")
            let older = SandLog.load(stored: ["2026-09-01": ["seconds": 300.0, "finished": 1]])
            expect(older.days["2026-09-01"]?.seconds == 300 && older.days["2026-09-01"]?.hours.isEmpty == true, "a day from before the hours")
            var aged = SandLog()
            aged.add(seconds: 600, on: day(2025, 3, 2), calendar: calendar)
            aged.add(seconds: 600, on: now, calendar: calendar)
            aged.prune(at: now, calendar: calendar)
            expect(aged.days["2025-03-02"]?.seconds == 600 && aged.days["2025-03-02"]?.hours.isEmpty == true, "old: total kept, hours let go")
            expect(aged.days["2026-09-20"]?.hours.isEmpty == false, "recent hours kept")
        }

        test("time is kept by project id, beside the totals, and older time counts as no project") {
            var log = SandLog()
            log.add(seconds: 600, project: "a", on: now, calendar: calendar)
            log.add(seconds: 300, finished: 1, project: "b", on: now, calendar: calendar)
            log.add(seconds: 120, on: now, calendar: calendar)
            let today = try require(log.days[SandLog.dayKey(now, calendar: calendar)], "today")
            expect(today.seconds == 1020 && today.finished == 1, "the totals hold everything")
            expect(today.byProject["a"]?.seconds == 600 && today.byProject["b"]?.finished == 1 && today.byProject[""]?.seconds == 120)
            let bucket = try require(log.buckets(.daily, at: now, calendar: calendar).last, "today's bar")
            expect(bucket.projects["a"]?.seconds == 600 && bucket.projects[""]?.seconds == 120)
            let hour = try require(log.buckets(.hourly, at: now, calendar: calendar).last, "this hour")
            expect(hour.projects["b"]?.seconds == 300, "and hour by hour")

            let older = SandLog.load(stored: ["2026-09-01": ["seconds": 300.0, "finished": 1]])
            expect(older.days["2026-09-01"]?.byProject[""] == SandLog.Tally(seconds: 300, finished: 1), "from before projects")
        }

        test("renaming or recolouring a project leaves its time where it was") {
            var log = SandLog()
            log.add(seconds: 600, project: "a", on: now, calendar: calendar)
            var list = ProjectList(all: [Project(id: "a", name: "Client A", color: "#2876E2")])
            list.all[0].name = "Client Alpha"
            list.all[0].color = "#FF0000"
            expect(log.buckets(.daily, at: now, calendar: calendar).last?.projects["a"]?.seconds == 600)
            expect(log.csv(.daily, at: now, projects: list, calendar: calendar).contains("\"Client Alpha (minutes)\""))
        }

        test("narrowed to one project, the record holds only its time") {
            var log = SandLog()
            log.add(seconds: 600, project: "a", on: now, calendar: calendar)
            log.add(seconds: 300, finished: 1, project: "b", on: day(2026, 9, 19), calendar: calendar)
            let a = log.only(project: "a")
            expect(a.allTime.seconds == 600 && a.allTime.finished == 0)
            expect(a.buckets(.hourly, at: now, calendar: calendar).last?.seconds == 600)
            expect(log.only(project: "b").buckets(.daily, at: now, calendar: calendar).last?.seconds == 0)
        }

        test("an export adds a column per project once projects are used, and none before") {
            var log = SandLog()
            log.add(seconds: 600, on: now, calendar: calendar)
            expect(log.csv(.daily, at: now, calendar: calendar).split(separator: "\n").first?.split(separator: ",").count == 5)
            log.add(seconds: 1200, project: "a", on: now, calendar: calendar)
            let list = ProjectList(all: [Project(id: "a", name: "Client, \"A\"", color: "#2876E2")])
            let rows = log.csv(.daily, at: now, projects: list, calendar: calendar).split(separator: "\n").map(String.init)
            expect(rows[0].hasSuffix(",\"Client, \"\"A\"\" (minutes)\",\"No project (minutes)\""), "quoted as a spreadsheet expects: \(rows[0])")
            expect(rows.last?.hasSuffix(",1800,30.0,0,20.0,10.0") == true, "got \(rows.last ?? "")")
        }

        test("projects survive a restart, day and hour") {
            let defaults = try require(UserDefaults(suiteName: "sand-timer-tests"), "a scratch settings domain")
            defer { defaults.removeObject(forKey: SandLog.defaultsKey) }
            var log = SandLog()
            log.add(seconds: 600, finished: 1, project: "a", on: now, calendar: calendar)
            log.add(seconds: 60, on: now, calendar: calendar)
            log.save(to: defaults)
            expect(SandLog.load(from: defaults) == log)
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
