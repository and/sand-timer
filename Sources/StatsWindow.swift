import AppKit
import UniformTypeIdentifiers

/// Everything the statistics window shows. It is read afresh on every refresh, so the window keeps up with the
/// sand as it runs and with a change of color.
struct Statistics {
    var log: SandLog
    var sand: NSColor
    var projects = ProjectList()
}

/// A small window of what the timer has done: time run and timers finished, grouped by hour, day, week, month or year.
/// One window, reused: asking for it again brings the same one back to the front.
final class StatsPanel: NSPanel, NSWindowDelegate {
    private static var shared: StatsPanel?
    /// The open window, if there is one. Tests look here.
    static var open: StatsPanel? { shared?.isVisible == true ? shared : nil }

    private let stats = StatsView()
    /// What the window shows. Tests look here.
    var statsView: StatsView { stats }
    private var refresh: Timer?

    static func show(_ source: @escaping () -> Statistics) {
        let panel = shared ?? StatsPanel()
        shared = panel
        panel.stats.source = source
        panel.stats.reload()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.startRefreshing()
    }

    private init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 470, height: 340),
                   styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        title = "Sand Timer Statistics"
        contentView = stats
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        delegate = self
        setFrameAutosaveName("statistics")  // reopens where it was last left
        if frameAutosaveName.isEmpty || frame.origin == .zero { center() }
    }

    /// While it's on screen it keeps up with the running sand; once closed it costs nothing.
    private func startRefreshing() {
        refresh?.invalidate()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.stats.reload() }
        RunLoop.main.add(timer, forMode: .common)
        refresh = timer
    }

    func windowWillClose(_ notification: Notification) {
        refresh?.invalidate()
        refresh = nil
    }
}

/// Draws the statistics: a picker for how to group them, what the current day, week, month or year comes to,
/// a bar for each of the last spans, and the all-time total along the bottom.
final class StatsView: NSView {
    var source: () -> Statistics = { Statistics(log: SandLog(), sand: .systemPurple) }

    private var period = SandLog.Period(rawValue: UserDefaults.standard.integer(forKey: "statsPeriod")) ?? .daily
    private var buckets: [SandLog.Bucket] = []
    private var total = SandLog.Day()
    private var since: Date?
    private var sand = NSColor.systemPurple
    private var projects = ProjectList()
    /// Whether any time has been counted against a project: only then do bars split by project, and the legend,
    /// breakdown and filter appear. Someone who never makes a project sees the window exactly as before.
    private var usesProjects = false
    /// The project the window is narrowed to: nil for all of them, "" for time with no project.
    private(set) var filter: String? = UserDefaults.standard.string(forKey: "statsProject")
    /// The bar under the pointer, whose span the headline then describes instead of the current one.
    private var hovered: Int?
    private let picker = NSSegmentedControl()
    private let export = NSButton(title: "Export…", target: nil, action: nil)
    let projectFilter = NSPopUpButton(frame: .zero, pullsDown: false)
    /// The filter's choices, as project ids ("" for no project), in the order the menu lists them after All Projects.
    private var filterChoices: [String] = []

    /// Extra height the window takes on when projects are in use: a breakdown under the headline, a legend under the bars.
    private static let projectRoom: CGFloat = 36
    static let baseHeight: CGFloat = 340

    private static let inset: CGFloat = 22
    /// Room kept along the bottom right for the Export button.
    private static let exportWidth: CGFloat = 78
    /// Room kept along the left for the times the chart is ruled at.
    private static let axisWidth: CGFloat = 34

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: 340))
        picker.segmentStyle = .automatic
        picker.segmentDistribution = .fillEqually
        picker.segmentCount = SandLog.Period.shown.count
        for (segment, group) in SandLog.Period.shown.enumerated() {
            picker.setLabel(group.name, forSegment: segment)
        }
        picker.selectedSegment = SandLog.Period.shown.firstIndex(of: period) ?? 0
        picker.target = self
        picker.action = #selector(periodPicked)
        addSubview(picker)
        export.bezelStyle = .rounded
        export.controlSize = .small
        export.font = .systemFont(ofSize: 11)
        export.toolTip = "Save these statistics as a CSV file"
        export.target = self
        export.action = #selector(exportClicked)
        addSubview(export)
        projectFilter.controlSize = .small
        projectFilter.font = .systemFont(ofSize: 11)
        projectFilter.target = self
        projectFilter.action = #selector(filterPicked)
        projectFilter.isHidden = true
        addSubview(projectFilter)
    }

    @objc private func filterPicked() {
        let index = projectFilter.indexOfSelectedItem
        filter = index <= 0 || index - 1 >= filterChoices.count ? nil : filterChoices[index - 1]
        if let filter { UserDefaults.standard.set(filter, forKey: "statsProject") } else { UserDefaults.standard.removeObject(forKey: "statsProject") }
        hovered = nil
        reload()
    }

    /// Narrows the window to one project (nil for all): what picking from the filter does. Tests call it directly.
    func show(project: String?) {
        filter = project
        reload()
        projectFilter.selectItem(at: project.flatMap { filterChoices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }

    /// Rebuilds the filter's menu when the projects change: All Projects, each project in use, then No Project.
    private func rebuildFilter(ids: Set<String>) {
        let choices = SandLog.ordered(ids.union(projects.visible.map(\.id)), by: projects)
        let titles = ["All Projects"] + choices.map { projects.name(of: $0) }
        guard choices != filterChoices || projectFilter.itemTitles != titles else { return }
        filterChoices = choices
        projectFilter.removeAllItems()
        // One by one: adding titles in a batch quietly drops any that repeat, and two projects may share a name.
        for (index, title) in titles.enumerated() {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            if index > 0 { item.image = HourglassView.swatch(color(of: choices[index - 1])) }
            projectFilter.menu?.addItem(item)
        }
        if let filter, !choices.contains(filter) { self.filter = nil }
        projectFilter.selectItem(at: filter.flatMap { choices.firstIndex(of: $0) }.map { $0 + 1 } ?? 0)
    }

    /// A project's colour as it is now; time with no project is a quiet grey once projects are in use.
    private func color(of id: String) -> NSColor {
        if id.isEmpty { return usesProjects ? .systemGray : sand }
        return projects.project(id).flatMap { NSColor(hex: $0.color) } ?? .systemGray
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func periodPicked() {
        period = SandLog.Period.shown.indices.contains(picker.selectedSegment) ? SandLog.Period.shown[picker.selectedSegment] : .daily
        UserDefaults.standard.set(period.rawValue, forKey: "statsPeriod")
        hovered = nil
        reload()
    }

    /// Saves the whole record as a CSV file, grouped the way the window is showing it — not just the spans on
    /// screen, but every one from the first day the sand ran.
    @objc func exportClicked() {
        let csv = exportedCSV()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = SandLog.exportFilename(at: Date())
        panel.title = "Export Statistics"
        if let exportFolder { panel.directoryURL = exportFolder }
        let save = { [weak self] (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do {
                try self?.write(csv, to: url)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the statistics"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    /// What Export saves: the whole record, grouped as the window shows it, and narrowed to the project it's showing.
    func exportedCSV() -> String {
        let statistics = source()
        let log = filter.map { statistics.log.only(project: $0) } ?? statistics.log
        return log.csv(period, at: Date(), projects: statistics.projects)
    }

    /// Writes an export where the save panel said to.
    func write(_ csv: String, to url: URL) throws {
        try csv.write(to: url, atomically: true, encoding: .utf8)
    }

    /// The Export button, for tests.
    var exportButton: NSButton { export }
    /// Where the save dialog opens, and so where a save goes unless the user moves elsewhere; nil for the usual place.
    /// Tests point it at a folder of their own, since a dialog already on screen can't be steered from code.
    var exportFolder: URL?

    /// Reads the record again and redraws: called when the window opens, once a second while it's open, and
    /// whenever the pointer moves over a different bar.
    func reload() {
        let statistics = source()
        sand = statistics.sand
        projects = statistics.projects
        let ids = statistics.log.projectIDs
        usesProjects = ids.contains { !$0.isEmpty } || !projects.visible.isEmpty
        if usesProjects { rebuildFilter(ids: ids) } else { filter = nil }
        projectFilter.isHidden = !usesProjects
        let log = filter.map { statistics.log.only(project: $0) } ?? statistics.log
        buckets = log.buckets(period, at: Date())
        total = log.allTime
        since = log.firstDay()
        export.isEnabled = total.seconds > 0 || total.finished > 0  // nothing to save until the sand has run
        fitWindow()
        needsDisplay = true
    }

    /// Taller while projects are in use, keeping the window's top edge where it is.
    private func fitWindow() {
        let height = Self.baseHeight + (usesProjects ? Self.projectRoom : 0)
        guard let window, abs(bounds.height - height) > 0.5 else { return }
        var frame = window.frameRect(forContentRect: NSRect(x: 0, y: 0, width: bounds.width, height: height))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    override func layout() {
        super.layout()
        picker.frame = NSRect(x: Self.inset, y: bounds.height - 42, width: bounds.width - 2 * Self.inset, height: 24)
        export.frame = NSRect(x: bounds.width - Self.inset - Self.exportWidth, y: 18, width: Self.exportWidth, height: 22)
        projectFilter.frame = NSRect(x: bounds.width - Self.inset - 160, y: picker.frame.minY - 18 - 22, width: 160, height: 22)
    }

    // MARK: Following the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let area = plotArea
        let slot = buckets.isEmpty ? 0 : area.width / CGFloat(buckets.count)
        let index = slot > 0 && area.insetBy(dx: 0, dy: -18).contains(point) ? Int((point.x - area.minX) / slot) : nil
        let inside = index.flatMap { buckets.indices.contains($0) ? $0 : nil }
        if inside != hovered {
            hovered = inside
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        guard hovered != nil else { return }
        hovered = nil
        needsDisplay = true
    }

    // MARK: Drawing

    /// Where the bars stand: between the headline and the labels along the bottom, which are two rows deep for a
    /// daily chart, since each day is named twice — the date, and the initial of the weekday under it.
    private var chartArea: NSRect {
        // With projects in use, a legend sits under the labels and a breakdown under the headline.
        let floor = 76 + (buckets.contains { $0.subLabel != nil } ? 13 : 0) + (usesProjects ? 18 : 0)
        let headline: CGFloat = 72 + (usesProjects ? 18 : 0)
        return NSRect(x: Self.inset, y: CGFloat(floor), width: bounds.width - 2 * Self.inset,
                      height: max(20, picker.frame.minY - 18 - headline - 12 - CGFloat(floor)))
    }

    /// Where the bars themselves go: the chart less the gutter holding the times.
    private var plotArea: NSRect {
        let area = chartArea
        return NSRect(x: area.minX + Self.axisWidth, y: area.minY, width: area.width - Self.axisWidth, height: area.height)
    }

    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()

        let shown = hovered.flatMap { buckets.indices.contains($0) ? buckets[$0] : nil } ?? buckets.last
        let width = bounds.width - 2 * Self.inset
        let headline = picker.frame.minY - 18
        text(shown?.title ?? period.currentTitle, size: 12, color: .secondaryLabelColor)
            .draw(in: NSRect(x: Self.inset, y: headline - 16, width: width, height: 16))
        text(SandLog.durationLabel(shown?.seconds ?? 0), size: 30, weight: .medium, color: .labelColor)
            .draw(in: NSRect(x: Self.inset, y: headline - 54, width: width, height: 38))
        let finished = shown?.finished ?? 0
        text("\(SandLog.timersLabel(finished)) finished", size: 12, color: .secondaryLabelColor)
            .draw(in: NSRect(x: Self.inset, y: headline - 72, width: width, height: 16))
        if usesProjects, let shown { breakdown(shown).draw(in: NSRect(x: Self.inset, y: headline - 90, width: width, height: 16)) }

        drawChart()
        if usesProjects { drawLegend() }
        drawFooter()
    }

    /// The projects in a span by time spent, each with a dot in its colour: "● Client A 40m · ● Writing 20m".
    private func breakdown(_ bucket: SandLog.Bucket) -> NSAttributedString {
        let line = NSMutableAttributedString()
        let parts = bucket.projects.filter { $0.value.seconds >= 1 }.sorted { $0.value.seconds > $1.value.seconds }
        for (index, part) in parts.enumerated() {
            if index > 0 { line.append(text("  ·  ", size: 12, color: .tertiaryLabelColor)) }
            line.append(text("● ", size: 12, color: color(of: part.key)))
            line.append(text("\(projects.name(of: part.key)) \(SandLog.durationLabel(part.value.seconds))", size: 12, color: .secondaryLabelColor))
        }
        if parts.isEmpty { line.append(text(" ", size: 12, color: .secondaryLabelColor)) }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        line.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: line.length))
        return line
    }

    /// Under the bars: a dot and a name for each project with time in view, in the order they were made.
    private func drawLegend() {
        let shown = Set(buckets.flatMap { $0.projects.filter { $0.value.seconds >= 1 }.keys })
        var x = Self.inset + Self.axisWidth
        let y = chartArea.minY - (buckets.contains { $0.subLabel != nil } ? 13 : 0) - 38
        for id in SandLog.ordered(shown, by: projects) {
            let entry = NSMutableAttributedString(attributedString: text("● ", size: 11, color: color(of: id)))
            entry.append(text(projects.name(of: id), size: 11, color: .secondaryLabelColor))
            let width = entry.size().width
            guard x + width <= bounds.width - Self.inset else { break }
            entry.draw(at: NSPoint(x: x, y: y))
            x += width + 14
        }
    }

    private func drawChart() {
        let area = plotArea
        guard !buckets.isEmpty else { return }
        let slot = area.width / CGFloat(buckets.count)
        let barWidth = min(30, max(4, slot - max(4, slot * 0.28)))
        let radius = min(3, barWidth / 2)
        let most = buckets.map(\.seconds).max() ?? 0

        // Ruled at round amounts of time, so a bar's height can be read without hovering over it.
        if most > 0 {
            let step = SandLog.gridStep(for: most)
            var value = step
            while value <= most {
                let y = (area.minY + area.height * CGFloat(value / most)).rounded()
                NSColor.separatorColor.setFill()
                // The rule starts just after its label, so the two never cross.
                NSRect(x: area.minX - 4, y: y, width: area.maxX - area.minX + 4, height: 1).fill()
                let time = text(SandLog.durationLabel(value), size: 9, color: .tertiaryLabelColor)
                time.draw(at: NSPoint(x: area.minX - 8 - time.size().width, y: y - time.size().height / 2))
                value += step
            }
        }

        for (index, bucket) in buckets.enumerated() {
            let x = area.minX + slot * CGFloat(index) + (slot - barWidth) / 2
            // A faint full-height track behind every bar, so empty days still read as days.
            NSColor.labelColor.withAlphaComponent(0.06).setFill()
            NSBezierPath(roundedRect: NSRect(x: x, y: area.minY, width: barWidth, height: area.height),
                         xRadius: radius, yRadius: radius).fill()

            if most > 0 && bucket.seconds > 0 {
                let height = max(3, area.height * CGFloat(bucket.seconds / most))
                let current = index == buckets.count - 1
                let lit = hovered == index || (hovered == nil && current)
                let bar = NSRect(x: x, y: area.minY, width: barWidth, height: height)
                if usesProjects {
                    // Stacked by project, untagged time at the foot, inside the bar's rounded outline.
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).addClip()
                    var y = bar.minY
                    let ids = SandLog.ordered(Set(bucket.projects.keys), by: projects)
                    for id in ids.filter(\.isEmpty) + ids.filter({ !$0.isEmpty }) {
                        let part = CGFloat((bucket.projects[id]?.seconds ?? 0) / max(1, bucket.seconds)) * height
                        guard part > 0 else { continue }
                        color(of: id).withAlphaComponent(lit ? 1 : 0.6).setFill()
                        NSRect(x: bar.minX, y: y, width: bar.width, height: part).fill()
                        y += part
                    }
                    NSGraphicsContext.restoreGraphicsState()
                } else {
                    sand.withAlphaComponent(lit ? 1 : 0.6).setFill()
                    NSBezierPath(roundedRect: bar, xRadius: radius, yRadius: radius).fill()
                }
            }
        }

        // The line they stand on, then a label under as many bars as will fit without crowding.
        NSColor.separatorColor.setFill()
        NSRect(x: chartArea.minX, y: area.minY - 1, width: area.maxX - chartArea.minX, height: 1).fill()
        let widest = buckets.map { text($0.label, size: 10, color: .labelColor).size().width }.max() ?? 0
        let every = max(1, Int(((widest + 10) / slot).rounded(.up)))
        for (index, bucket) in buckets.enumerated() where (buckets.count - 1 - index) % every == 0 {
            let lit = hovered == index || (hovered == nil && index == buckets.count - 1)
            let label = text(bucket.label, size: 10, color: lit ? .labelColor : .tertiaryLabelColor)
            // Drawn from a point rather than into a box, so a label is never wrapped onto a second line, and
            // kept inside the chart, so the one under the last bar doesn't run off the edge.
            func place(_ line: NSAttributedString, above: CGFloat) {
                let middle = area.minX + slot * (CGFloat(index) + 0.5) - line.size().width / 2
                line.draw(at: NSPoint(x: min(max(area.minX, middle), area.maxX - line.size().width), y: area.minY - above))
            }
            place(label, above: 16)
            if let weekday = bucket.subLabel {
                place(text(weekday, size: 9, color: lit ? .secondaryLabelColor : .tertiaryLabelColor), above: 28)
            }
        }
    }

    private func drawFooter() {
        let width = bounds.width - 2 * Self.inset
        NSColor.separatorColor.setFill()
        NSRect(x: Self.inset, y: 46, width: width, height: 1).fill()
        let summary: String
        if total.seconds == 0 && total.finished == 0 {
            summary = "Nothing yet — click the timer to start it"
        } else {
            let start = since.map { date -> String in
                let formatter = DateFormatter()
                formatter.setLocalizedDateFormatFromTemplate("d MMM yyyy")
                return "Since \(formatter.string(from: date))"
            } ?? "All time"
            summary = "\(start) · \(SandLog.durationLabel(total.seconds)) · \(SandLog.timersLabel(total.finished)) finished"
        }
        text(summary, size: 11, color: .secondaryLabelColor, truncating: true)
            .draw(in: NSRect(x: Self.inset, y: 22, width: width - Self.exportWidth - 12, height: 16))
    }

    private func text(_ string: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor,
                      truncating: Bool = false) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color]
        if truncating {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail  // one line, however long the tally grows
            attributes[.paragraphStyle] = paragraph
        }
        return NSAttributedString(string: string, attributes: attributes)
    }
}
