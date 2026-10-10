import Charts
import SwiftUI

/// The record, by hour, day, week, month or year — the Mac's own grouping (`SandLog.buckets`) — each bar split by
/// project: this phone's time and any linked Mac's.
struct StatsScreen: View {
    @EnvironmentObject private var store: Store
    @AppStorage("statsPeriod") private var periodRaw = SandLog.Period.daily.rawValue
    @State private var selected: Date?

    private var period: SandLog.Period { SandLog.Period(rawValue: periodRaw) ?? .daily }

    var body: some View {
        let log = store.wholeLog
        let buckets = log.buckets(period, at: Date())
        let bucket = buckets.last { $0.start == selected } ?? buckets.last
        let projects = store.projects

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Period", selection: $periodRaw) {
                    ForEach(SandLog.Period.shown, id: \.rawValue) { Text($0.name).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                .onChange(of: periodRaw) { selected = nil }

                if let bucket {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(bucket.title).foregroundStyle(.secondary)
                        Text(SandLog.durationLabel(bucket.seconds)).font(.system(size: 36, weight: .medium))
                        Text("\(SandLog.timersLabel(bucket.finished)) finished").font(.footnote).foregroundStyle(.secondary)
                        let parts = SandLog.ordered(Set(bucket.projects.keys), by: projects).filter { (bucket.projects[$0]?.seconds ?? 0) >= 1 }
                        if parts.count > 1 || parts.first.map({ !$0.isEmpty }) == true {
                            ForEach(parts, id: \.self) { id in
                                HStack(spacing: 6) {
                                    Circle().fill(color(id)).frame(width: 8, height: 8)
                                    Text("\(projects.name(of: id))  \(SandLog.durationLabel(bucket.projects[id]?.seconds ?? 0))")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .padding(.top, 4)
                        }
                    }
                }

                Chart {
                    ForEach(buckets, id: \.start) { b in
                        ForEach(SandLog.ordered(Set(b.projects.keys), by: projects), id: \.self) { id in
                            BarMark(x: .value("When", b.label + "\u{200B}" + String(b.start.timeIntervalSince1970)),
                                    y: .value("Minutes", (b.projects[id]?.seconds ?? 0) / 60))
                                .foregroundStyle(color(id))
                                .opacity(bucket?.start == b.start ? 1 : 0.7)
                        }
                    }
                }
                .chartXAxis {
                    AxisMarks { value in
                        AxisValueLabel { Text((value.as(String.self) ?? "").components(separatedBy: "\u{200B}").first ?? "") }
                    }
                }
                .chartYAxisLabel("minutes")
                .chartOverlay { proxy in
                    GeometryReader { geometry in
                        Rectangle().fill(.clear).contentShape(Rectangle())
                            .onTapGesture { location in
                                let x = location.x - geometry[proxy.plotFrame!].origin.x
                                let index = Int(x / (proxy.plotSize.width / CGFloat(buckets.count)))
                                if buckets.indices.contains(index) { selected = buckets[index].start }
                            }
                    }
                }
                .frame(height: 200)

                let all = log.allTime
                if let first = log.firstDay() {
                    Text("Since \(first.formatted(date: .abbreviated, time: .omitted)) · \(SandLog.durationLabel(all.seconds)) · \(SandLog.timersLabel(all.finished)) finished")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if store.linked {
                    Text("Includes the time from your linked Mac.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding()
        }
        .background(Color.ink)
    }

    private func color(_ id: String) -> Color {
        guard !id.isEmpty, let hex = store.projects.project(id)?.color, let ui = UIColor(hex: hex) else { return Color(white: 0.55) }
        return Color(uiColor: ui)
    }
}
