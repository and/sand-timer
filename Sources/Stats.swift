import Foundation

/// What the timer has done, kept as one entry per day: how long its sand ran, and how many timers ran all the way
/// out, with the same broken down by hour. Every view of the statistics — by day, week, month or year — is a sum over
/// those days, and the hourly view a sum over their hours. Each day and hour also keeps its time project by project,
/// by the project's id; time run with no project, and anything recorded before projects existed, is under "".
struct SandLog: Equatable {
    struct Day: Equatable {
        var seconds: TimeInterval = 0
        var finished: Int = 0
        /// The same, hour by hour (0 to 23, local time), for the hourly view. Days recorded before the hours were kept
        /// have none, and the detail is let go after a year while the day's totals stay.
        var hours: [Int: Slot] = [:]
        /// The day's time by project id.
        var projects: [String: Tally] = [:]

        /// By project, with whatever wasn't counted against one — including everything from before projects — under "".
        var byProject: [String: Tally] { SandLog.withRemainder(projects, seconds: seconds, finished: finished) }
    }

    /// What one hour holds.
    struct Slot: Equatable {
        var seconds: TimeInterval = 0
        var finished: Int = 0
        var projects: [String: Tally] = [:]

        var byProject: [String: Tally] { SandLog.withRemainder(projects, seconds: seconds, finished: finished) }
    }

    /// Time run and timers finished, for one project.
    struct Tally: Equatable {
        var seconds: TimeInterval = 0
        var finished: Int = 0
    }

    /// `projects` with any time and finishes the totals hold beyond them put under "", the untagged.
    fileprivate static func withRemainder(_ projects: [String: Tally], seconds: TimeInterval, finished: Int) -> [String: Tally] {
        var all = projects
        let counted = projects.values.reduce(Tally()) { Tally(seconds: $0.seconds + $1.seconds, finished: $0.finished + $1.finished) }
        let rest = Tally(seconds: max(0, seconds - counted.seconds), finished: max(0, finished - counted.finished))
        if rest.seconds > 0.5 || rest.finished > 0 {
            all["", default: Tally()].seconds += rest.seconds
            all[""]?.finished += rest.finished
        }
        return all
    }

    /// One span in the statistics: a day, a week, a month or a year, with what the timer did in it.
    struct Bucket {
        /// Under the bar: the day of the month, the week's first day, the month, the year.
        let label: String
        /// A second line under that, where it helps: the initial of the weekday, so a daily chart shows its weekends.
        let subLabel: String?
        /// Spelled out, for the headline: "Today", "Monday 15 Sep", "Week of 8 Sep", "September 2026", "2026".
        let title: String
        let start: Date
        let seconds: TimeInterval
        let finished: Int
        /// The same, by project id; untagged time under "".
        var projects: [String: Tally] = [:]
    }

    /// How the statistics are grouped.
    /// Hourly comes last in the list so that a choice already saved by its number still means the same period.
    enum Period: Int, CaseIterable {
        case daily, weekly, monthly, yearly, hourly

        /// The order the picker shows them in: shortest first.
        static let shown: [Period] = [.hourly, .daily, .weekly, .monthly, .yearly]

        /// What the picker calls it.
        var name: String { ["Daily", "Weekly", "Monthly", "Yearly", "Hourly"][rawValue] }
        var unit: Calendar.Component { [.day, .weekOfYear, .month, .year, .hour][rawValue] }
        /// How many spans the chart shows, the one happening now last.
        var span: Int { [14, 12, 12, 5, 24][rawValue] }
        /// What the span happening now is called.
        var currentTitle: String { ["Today", "This week", "This month", "This year", "This hour"][rawValue] }
        fileprivate var labelTemplate: String { ["d", "d MMM", "MMM", "yyyy", "j"][rawValue] }
        /// Only a day is worth naming twice; a week, month or year has nothing to add underneath.
        fileprivate var subLabelTemplate: String? { self == .daily ? "EEEEE" : nil }
        fileprivate var titleTemplate: String { ["EEEE d MMM", "d MMM", "MMMM yyyy", "yyyy", "EEEE j"][rawValue] }
    }

    /// Keyed yyyy-MM-dd in local time, so the keys sort and compare like the days they stand for.
    private(set) var days: [String: Day] = [:]

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// Midnight at the start of a day written as one of our keys.
    static func date(forDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// Counts time run and timers finished on the day and hour `date` falls in, against `project` (an id; "" for none).
    mutating func add(seconds: TimeInterval = 0, finished: Int = 0, project: String = "", on date: Date, calendar: Calendar = .current) {
        guard seconds > 0 || finished > 0 else { return }
        let key = Self.dayKey(date, calendar: calendar)
        let run = max(0, seconds)
        var day = days[key] ?? Day()
        day.seconds += run
        day.finished += finished
        day.projects[project, default: Tally()].seconds += run
        day.projects[project]?.finished += finished
        let hour = calendar.component(.hour, from: date)
        var slot = day.hours[hour] ?? Slot()
        slot.seconds += run
        slot.finished += finished
        slot.projects[project, default: Tally()].seconds += run
        slot.projects[project]?.finished += finished
        day.hours[hour] = slot
        days[key] = day
    }

    /// The record as if only `project` had ever been run: what the statistics show when narrowed to one project.
    func only(project: String) -> SandLog {
        var narrowed = SandLog()
        for (key, day) in days {
            guard let tally = day.byProject[project] else { continue }
            var kept = Day(seconds: tally.seconds, finished: tally.finished, projects: [project: tally])
            for (hour, slot) in day.hours {
                guard let part = slot.byProject[project] else { continue }
                kept.hours[hour] = Slot(seconds: part.seconds, finished: part.finished, projects: [project: part])
            }
            narrowed.days[key] = kept
        }
        return narrowed
    }

    /// Every project id with time or finishes anywhere in the record, "" included when some time had none.
    var projectIDs: Set<String> { Set(days.values.flatMap { $0.byProject.keys }) }

    var allTime: Day {
        days.values.reduce(into: Day()) { total, day in
            total.seconds += day.seconds
            total.finished += day.finished
        }
    }

    /// The first day the timer ran, for "since …".
    func firstDay(calendar: Calendar = .current) -> Date? {
        days.filter { $0.value.seconds > 0 || $0.value.finished > 0 }.keys.min()
            .flatMap { Self.date(forDayKey: $0, calendar: calendar) }
    }

    /// The last `period.span` spans, oldest first, with the one happening now last: what the chart shows.
    func buckets(_ period: Period, at now: Date, calendar: Calendar = .current) -> [Bucket] {
        guard let current = calendar.dateInterval(of: period.unit, for: now)?.start else { return [] }
        let starts: [Date] = stride(from: period.span - 1, through: 0, by: -1).compactMap {
            calendar.date(byAdding: period.unit, value: -$0, to: current)
        }
        return buckets(period, starts: starts, calendar: calendar)
    }

    /// The first hour the record has hour by hour: where an hourly export starts, rather than at the first day of all.
    func firstHour(calendar: Calendar = .current) -> Date? {
        days.compactMap { key, day -> Date? in
            guard let hour = day.hours.filter({ $0.value.seconds > 0 || $0.value.finished > 0 }).keys.min(),
                  let start = Self.date(forDayKey: key, calendar: calendar) else { return nil }
            return calendar.date(bySettingHour: hour, minute: 0, second: 0, of: start)
        }.min()
    }

    /// Every span from the first day recorded to the one happening now: what an export covers.
    func allBuckets(_ period: Period, at now: Date, calendar: Calendar = .current) -> [Bucket] {
        let from = period == .hourly ? firstHour(calendar: calendar) : firstDay(calendar: calendar)
        guard let current = calendar.dateInterval(of: period.unit, for: now)?.start, let first = from,
              var start = calendar.dateInterval(of: period.unit, for: first)?.start else { return [] }
        var starts: [Date] = []
        while start <= current {
            starts.append(start)
            guard let next = calendar.date(byAdding: period.unit, value: 1, to: start), next > start else { break }
            start = next
        }
        return buckets(period, starts: starts, calendar: calendar)
    }

    private func buckets(_ period: Period, starts: [Date], calendar: Calendar) -> [Bucket] {
        guard let first = starts.first else { return [] }

        var totals = [Day](repeating: Day(), count: starts.count)
        func add(_ seconds: TimeInterval, _ finished: Int, _ projects: [String: Tally], at date: Date) {
            guard date >= first, let index = starts.lastIndex(where: { $0 <= date }) else { return }
            totals[index].seconds += seconds
            totals[index].finished += finished
            for (id, tally) in projects {
                totals[index].projects[id, default: Tally()].seconds += tally.seconds
                totals[index].projects[id]?.finished += tally.finished
            }
        }
        for (key, day) in days {
            guard let date = Self.date(forDayKey: key, calendar: calendar) else { continue }
            if period == .hourly {
                // The hours before the day's start are nowhere in view, so a day that ended before the first bar is skipped whole.
                guard calendar.date(byAdding: .day, value: 1, to: date).map({ $0 > first }) ?? false else { continue }
                for (hour, slot) in day.hours {
                    if let start = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: date) {
                        add(slot.seconds, slot.finished, slot.byProject, at: start)
                    }
                }
            } else {
                add(day.seconds, day.finished, day.byProject, at: date)
            }
        }

        let labels = Self.formatter(period.labelTemplate, calendar: calendar)
        let subLabels = period.subLabelTemplate.map { Self.formatter($0, calendar: calendar) }
        let titles = Self.formatter(period.titleTemplate, calendar: calendar)
        return zip(starts, totals).enumerated().map { index, entry in
            let (start, day) = entry
            let last = starts.count - 1
            var title = titles.string(from: start)
            if period == .weekly { title = "Week of \(title)" }
            if index == last { title = period.currentTitle }
            if index == last - 1 && period == .daily { title = "Yesterday" }
            if index == last - 1 && period == .hourly { title = "Last hour" }
            return Bucket(label: labels.string(from: start), subLabel: subLabels?.string(from: start), title: title,
                          start: start, seconds: day.seconds, finished: day.finished, projects: day.projects)
        }
    }

    private static func formatter(_ template: String, calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? .current
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
    }

    /// Forgets days older than the longest view can reach back, so the record can't grow without end, and the
    /// hour-by-hour detail of days more than a year ago, keeping their totals.
    mutating func prune(at now: Date, calendar: Calendar = .current) {
        guard let thisYear = calendar.dateInterval(of: .year, for: now)?.start,
              let oldest = calendar.date(byAdding: .year, value: -(Period.yearly.span - 1), to: thisYear) else { return }
        let cutoff = Self.dayKey(oldest, calendar: calendar)
        days = days.filter { $0.key >= cutoff }
        if let yearAgo = calendar.date(byAdding: .year, value: -1, to: now) {
            let detailCutoff = Self.dayKey(yearAgo, calendar: calendar)
            for key in days.keys where key < detailCutoff && !(days[key]?.hours.isEmpty ?? true) { days[key]?.hours = [:] }
        }
    }

    /// How long the sand ran, in the shortest form that still reads naturally: "3h 20m", "45m", "12s".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }

    /// Round amounts of time to rule a chart with — five minutes up to a day — chosen to give two to four lines.
    /// A chart ruled every five minutes is a ladder; one ruled once barely says more than no rule at all.
    static func gridStep(for most: TimeInterval) -> TimeInterval {
        let ladder: [TimeInterval] = [300, 600, 900, 1800, 3600, 7200, 10800, 21600, 43200, 86400]
        return ladder.first { most / $0 <= 4 } ?? ladder[ladder.count - 1]
    }

    /// Today's progress against a daily target, as minutes and seconds: "21:18/60:00". A target of a hundred minutes or
    /// more would make those numbers hard to read at a glance, so it switches to hours: "1:21:18/2:00:00".
    static func goalLabel(seconds: TimeInterval, target: TimeInterval) -> String {
        let hours = target >= 6000
        func clock(_ value: TimeInterval) -> String {
            let total = max(0, Int(value.rounded(.down)))
            return hours
                ? String(format: "%d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
                : String(format: "%d:%02d", total / 60, total % 60)
        }
        return "\(clock(seconds))/\(clock(target))"
    }

    /// Where the marks along the base fall for a daily target, as fractions of it: at each round amount of time that
    /// divides it into a few parts — hours for three hours, quarters of an hour for one. None when the target is too
    /// short to mark.
    static func goalTicks(target: TimeInterval) -> [Double] {
        guard target > 0 else { return [] }
        let step = gridStep(for: target)
        return stride(from: step, to: target - 1, by: step).map { $0 / target }
    }

    /// How long the sand has run on the day `date` falls in.
    func seconds(on date: Date, calendar: Calendar = .current) -> TimeInterval {
        days[Self.dayKey(date, calendar: calendar)]?.seconds ?? 0
    }

    /// "5 timers" or "1 timer", for the count that ran all the way out.
    static func timersLabel(_ count: Int) -> String { "\(count) timer" + (count == 1 ? "" : "s") }

    /// What an export is called: sand_timer_report_YYYYMMDDHHMM.csv, stamped with the moment it was saved, so a
    /// folder of them sorts by when each was taken and two exports never quietly overwrite one another.
    static func exportFilename(at now: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        return String(format: "sand_timer_report_%04d%02d%02d%02d%02d.csv",
                      parts.year ?? 0, parts.month ?? 0, parts.day ?? 0, parts.hour ?? 0, parts.minute ?? 0)
    }

    /// A span's first and last moments as an export writes them: days as yyyy-MM-dd, and an hour as yyyy-MM-dd HH:00.
    static func bounds(of start: Date, period: Period, at now: Date, calendar: Calendar = .current) -> (start: String, end: String) {
        guard period == .hourly else {
            return (dayKey(start, calendar: calendar), dayKey(lastDay(of: start, period: period, at: now, calendar: calendar), calendar: calendar))
        }
        func hour(_ date: Date) -> String { dayKey(date, calendar: calendar) + String(format: " %02d:00", calendar.component(.hour, from: date)) }
        return (hour(start), hour(calendar.date(byAdding: .hour, value: 1, to: start) ?? start))
    }

    /// The last day a span covers, and for the span still running, today.
    static func lastDay(of start: Date, period: Period, at now: Date, calendar: Calendar = .current) -> Date {
        let nextStart = calendar.date(byAdding: period.unit, value: 1, to: start) ?? start
        return min(calendar.date(byAdding: .day, value: -1, to: nextStart) ?? start, now)
    }

    /// The whole record as comma-separated rows, one for every span of `period` from the first day recorded to the
    /// one happening now. Dates are written yyyy-MM-dd, which sorts and reads the same in every spreadsheet, and
    /// every field is a plain number or date, so nothing needs quoting or escaping — except project names, which are
    /// the user's own and quoted as a spreadsheet expects. Once any time has been counted against a project, each
    /// project with time in the record gets a column of its minutes, in `projects`' order, with untagged time last.
    func csv(_ period: Period, at now: Date, projects: ProjectList = ProjectList(), calendar: Calendar = .current) -> String {
        let ids = projectIDs
        let columns = ids.subtracting([""]).isEmpty ? [] : Self.ordered(ids, by: projects)
        func quoted(_ name: String) -> String { "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var rows = [(["Start", "End", "Time run (seconds)", "Time run (minutes)", "Timers finished"]
                     + columns.map { quoted("\(projects.name(of: $0)) (minutes)") }).joined(separator: ",")]
        for bucket in allBuckets(period, at: now, calendar: calendar) {
            let span = Self.bounds(of: bucket.start, period: period, at: now, calendar: calendar)
            rows.append(([span.start, span.end,
                          String(format: "%.0f", bucket.seconds), String(format: "%.1f", bucket.seconds / 60),
                          "\(bucket.finished)"]
                         + columns.map { String(format: "%.1f", (bucket.projects[$0]?.seconds ?? 0) / 60) }).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    /// Project ids in the order the projects were made, then any the list no longer knows, then the untagged.
    static func ordered(_ ids: Set<String>, by projects: ProjectList) -> [String] {
        let known = projects.all.map(\.id).filter(ids.contains)
        let unknown = ids.subtracting(known).subtracting([""]).sorted()
        return known + unknown + (ids.contains("") ? [""] : [])
    }
}

// MARK: Keeping the record between launches

extension SandLog {
    static let defaultsKey = "sandLog"

    static func load(from defaults: UserDefaults = .standard) -> SandLog {
        load(stored: defaults.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:])
    }

    /// The record from however it was read back — the app's own settings, or another program reading the app's
    /// preferences, as the MCP server does.
    static func load(stored: [String: [String: Any]]) -> SandLog {
        var log = SandLog()
        for (key, entry) in stored {
            var day = Day(seconds: entry["seconds"] as? Double ?? 0, finished: entry["finished"] as? Int ?? 0,
                          projects: tallies(entry["projects"]))
            for (hour, slot) in entry["hours"] as? [String: [String: Any]] ?? [:] {
                guard let hour = Int(hour), (0..<24).contains(hour) else { continue }
                day.hours[hour] = Slot(seconds: slot["seconds"] as? Double ?? 0, finished: slot["finished"] as? Int ?? 0,
                                       projects: tallies(slot["projects"]))
            }
            log.days[key] = day
        }
        return log
    }

    private static func tallies(_ stored: Any?) -> [String: Tally] {
        (stored as? [String: [String: Any]] ?? [:]).mapValues {
            Tally(seconds: $0["seconds"] as? Double ?? 0, finished: $0["finished"] as? Int ?? 0)
        }
    }

    private static func stored(_ tallies: [String: Tally]) -> [String: Any] {
        tallies.mapValues { ["seconds": $0.seconds, "finished": $0.finished] as [String: Any] }
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(stored, forKey: Self.defaultsKey)
    }

    /// The record as the settings keep it: by day key, each day's seconds, finishes, projects and hours. A linked
    /// device's record travels in the same form, so the Android app writes it this way too.
    var stored: [String: [String: Any]] {
        days.mapValues { day -> [String: Any] in
            var entry: [String: Any] = ["seconds": day.seconds, "finished": day.finished]
            if !day.projects.isEmpty { entry["projects"] = Self.stored(day.projects) }
            if !day.hours.isEmpty {
                entry["hours"] = Dictionary(uniqueKeysWithValues: day.hours.map { hour, slot -> (String, [String: Any]) in
                    var hourEntry: [String: Any] = ["seconds": slot.seconds, "finished": slot.finished]
                    if !slot.projects.isEmpty { hourEntry["projects"] = Self.stored(slot.projects) }
                    return (String(hour), hourEntry)
                })
            }
            return entry
        }
    }
}

// MARK: Records from linked devices

extension SandLog {
    /// Where the records of linked devices are kept, by device id, each in the form `stored` writes. The statistics,
    /// the daily target and the MCP server count them with this Mac's own.
    static let linkedKey = "linkedLogs"

    /// This record with `other`'s time and finishes added in, day by day, hour by hour and project by project.
    func including(_ other: SandLog) -> SandLog {
        var sum = self
        for (key, theirs) in other.days {
            var day = sum.days[key] ?? Day()
            day.seconds += theirs.seconds
            day.finished += theirs.finished
            Self.add(theirs.projects, to: &day.projects)
            for (hour, slot) in theirs.hours {
                var mine = day.hours[hour] ?? Slot()
                mine.seconds += slot.seconds
                mine.finished += slot.finished
                Self.add(slot.projects, to: &mine.projects)
                day.hours[hour] = mine
            }
            sum.days[key] = day
        }
        return sum
    }

    private static func add(_ tallies: [String: Tally], to total: inout [String: Tally]) {
        for (id, tally) in tallies {
            total[id, default: Tally()].seconds += tally.seconds
            total[id]?.finished += tally.finished
        }
    }

    /// Every linked device's record, added together.
    static func linked(stored: [String: Any]?) -> SandLog {
        (stored ?? [:]).values.reduce(SandLog()) { sum, record in
            sum.including(load(stored: record as? [String: [String: Any]] ?? [:]))
        }
    }

    static func linked(from defaults: UserDefaults = .standard) -> SandLog {
        linked(stored: defaults.dictionary(forKey: linkedKey))
    }

    /// The record cut into months, keyed yyyy-MM, each in the stored form: how it is sent to linked devices, a
    /// document a month, so a day's change sends one small month rather than the whole history.
    var storedByMonth: [String: [String: [String: Any]]] {
        var months: [String: [String: [String: Any]]] = [:]
        for (key, entry) in stored { months[String(key.prefix(7)), default: [:]][key] = entry }
        return months
    }
}
