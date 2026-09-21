import Foundation

/// What the timer has done, kept as one entry per day: how long its sand ran, and how many timers ran all the way
/// out. Every view of the statistics — by day, week, month or year — is a sum over those days.
struct SandLog: Equatable {
    struct Day: Equatable {
        var seconds: TimeInterval = 0
        var finished: Int = 0
    }

    /// One span in the statistics: a day, a week, a month or a year, with what the timer did in it.
    struct Bucket {
        /// Under the bar: the day of the month, the week's first day, the month, the year.
        let label: String
        /// Spelled out, for the headline: "Today", "Monday 15 Sep", "Week of 8 Sep", "September 2026", "2026".
        let title: String
        let start: Date
        let seconds: TimeInterval
        let finished: Int
    }

    /// How the statistics are grouped.
    enum Period: Int, CaseIterable {
        case daily, weekly, monthly, yearly

        /// What the picker calls it.
        var name: String { ["Daily", "Weekly", "Monthly", "Yearly"][rawValue] }
        var unit: Calendar.Component { [.day, .weekOfYear, .month, .year][rawValue] }
        /// How many spans the chart shows, the one happening now last.
        var span: Int { [14, 12, 12, 5][rawValue] }
        /// What the span happening now is called.
        var currentTitle: String { ["Today", "This week", "This month", "This year"][rawValue] }
        fileprivate var labelTemplate: String { ["d", "d MMM", "MMM", "yyyy"][rawValue] }
        fileprivate var titleTemplate: String { ["EEEE d MMM", "d MMM", "MMMM yyyy", "yyyy"][rawValue] }
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

    mutating func add(seconds: TimeInterval = 0, finished: Int = 0, on date: Date, calendar: Calendar = .current) {
        guard seconds > 0 || finished > 0 else { return }
        let key = Self.dayKey(date, calendar: calendar)
        var day = days[key] ?? Day()
        day.seconds += max(0, seconds)
        day.finished += finished
        days[key] = day
    }

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

    /// Every span from the first day recorded to the one happening now: what an export covers.
    func allBuckets(_ period: Period, at now: Date, calendar: Calendar = .current) -> [Bucket] {
        guard let current = calendar.dateInterval(of: period.unit, for: now)?.start, let first = firstDay(calendar: calendar),
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
        for (key, day) in days {
            guard let date = Self.date(forDayKey: key, calendar: calendar), date >= first,
                  let index = starts.lastIndex(where: { $0 <= date }) else { continue }
            totals[index].seconds += day.seconds
            totals[index].finished += day.finished
        }

        let labels = Self.formatter(period.labelTemplate, calendar: calendar)
        let titles = Self.formatter(period.titleTemplate, calendar: calendar)
        return zip(starts, totals).enumerated().map { index, entry in
            let (start, day) = entry
            let last = starts.count - 1
            var title = titles.string(from: start)
            if period == .weekly { title = "Week of \(title)" }
            if index == last { title = period.currentTitle }
            if index == last - 1 && period == .daily { title = "Yesterday" }
            return Bucket(label: labels.string(from: start), title: title, start: start, seconds: day.seconds, finished: day.finished)
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

    /// Forgets days older than the longest view can reach back, so the record can't grow without end.
    mutating func prune(at now: Date, calendar: Calendar = .current) {
        guard let thisYear = calendar.dateInterval(of: .year, for: now)?.start,
              let oldest = calendar.date(byAdding: .year, value: -(Period.yearly.span - 1), to: thisYear) else { return }
        let cutoff = Self.dayKey(oldest, calendar: calendar)
        days = days.filter { $0.key >= cutoff }
    }

    /// How long the sand ran, in the shortest form that still reads naturally: "3h 20m", "45m", "12s".
    static func durationLabel(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
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

    /// The whole record as comma-separated rows, one for every span of `period` from the first day recorded to the
    /// one happening now. Dates are written yyyy-MM-dd, which sorts and reads the same in every spreadsheet, and
    /// every field is a plain number or date, so nothing needs quoting or escaping.
    func csv(_ period: Period, at now: Date, calendar: Calendar = .current) -> String {
        var rows = ["Start,End,Time run (seconds),Time run (minutes),Timers finished"]
        for bucket in allBuckets(period, at: now, calendar: calendar) {
            // The last day of the span, and for the span still running, today.
            let nextStart = calendar.date(byAdding: period.unit, value: 1, to: bucket.start) ?? bucket.start
            let last = min(calendar.date(byAdding: .day, value: -1, to: nextStart) ?? bucket.start, now)
            rows.append([Self.dayKey(bucket.start, calendar: calendar), Self.dayKey(last, calendar: calendar),
                         String(format: "%.0f", bucket.seconds), String(format: "%.1f", bucket.seconds / 60),
                         "\(bucket.finished)"].joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }
}

// MARK: Keeping the record between launches

extension SandLog {
    static let defaultsKey = "sandLog"

    static func load(from defaults: UserDefaults = .standard) -> SandLog {
        var log = SandLog()
        for (key, entry) in defaults.dictionary(forKey: defaultsKey) as? [String: [String: Any]] ?? [:] {
            log.days[key] = Day(seconds: entry["seconds"] as? Double ?? 0, finished: entry["finished"] as? Int ?? 0)
        }
        return log
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(days.mapValues { ["seconds": $0.seconds, "finished": $0.finished] as [String: Any] }, forKey: Self.defaultsKey)
    }
}
