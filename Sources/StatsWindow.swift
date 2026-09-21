import AppKit
import UniformTypeIdentifiers

/// Everything the statistics window shows. It is read afresh on every refresh, so the window keeps up with the
/// sand as it runs and with a change of color.
struct Statistics {
    var log: SandLog
    var sand: NSColor
}

/// A small window of what the timer has done: time run and timers finished, grouped by day, week, month or year.
/// One window, reused: asking for it again brings the same one back to the front.
final class StatsPanel: NSPanel, NSWindowDelegate {
    private static var shared: StatsPanel?
    /// The open window, if there is one. Tests look here.
    static var open: StatsPanel? { shared?.isVisible == true ? shared : nil }

    private let stats = StatsView()
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
    /// The bar under the pointer, whose span the headline then describes instead of the current one.
    private var hovered: Int?
    private let picker = NSSegmentedControl()
    private let export = NSButton(title: "Export…", target: nil, action: nil)

    private static let inset: CGFloat = 22
    /// Room kept along the bottom right for the Export button.
    private static let exportWidth: CGFloat = 78

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: 340))
        picker.segmentStyle = .automatic
        picker.segmentDistribution = .fillEqually
        picker.segmentCount = SandLog.Period.allCases.count
        for group in SandLog.Period.allCases {
            picker.setLabel(group.name, forSegment: group.rawValue)
        }
        picker.selectedSegment = period.rawValue
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
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    @objc private func periodPicked() {
        period = SandLog.Period(rawValue: picker.selectedSegment) ?? .daily
        UserDefaults.standard.set(period.rawValue, forKey: "statsPeriod")
        hovered = nil
        reload()
    }

    /// Saves the whole record as a CSV file, grouped the way the window is showing it — not just the spans on
    /// screen, but every one from the first day the sand ran.
    @objc private func exportClicked() {
        let csv = source().log.csv(period, at: Date())
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = SandLog.exportFilename(at: Date())
        panel.title = "Export Statistics"
        let save = { (response: NSApplication.ModalResponse) in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn't save the statistics"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: save) } else { save(panel.runModal()) }
    }

    /// Reads the record again and redraws: called when the window opens, once a second while it's open, and
    /// whenever the pointer moves over a different bar.
    func reload() {
        let statistics = source()
        sand = statistics.sand
        buckets = statistics.log.buckets(period, at: Date())
        total = statistics.log.allTime
        since = statistics.log.firstDay()
        export.isEnabled = total.seconds > 0 || total.finished > 0  // nothing to save until the sand has run
        needsDisplay = true
    }

    override func layout() {
        super.layout()
        picker.frame = NSRect(x: Self.inset, y: bounds.height - 42, width: bounds.width - 2 * Self.inset, height: 24)
        export.frame = NSRect(x: bounds.width - Self.inset - Self.exportWidth, y: 18, width: Self.exportWidth, height: 22)
    }

    // MARK: Following the pointer

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let area = chartArea
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

    /// Where the bars stand: between the headline and the row of labels along the bottom.
    private var chartArea: NSRect {
        NSRect(x: Self.inset, y: 76, width: bounds.width - 2 * Self.inset, height: max(20, picker.frame.minY - 18 - 72 - 12 - 76))
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

        drawChart()
        drawFooter()
    }

    private func drawChart() {
        let area = chartArea
        guard !buckets.isEmpty else { return }
        let slot = area.width / CGFloat(buckets.count)
        let barWidth = min(30, max(4, slot - max(4, slot * 0.28)))
        let radius = min(3, barWidth / 2)
        let most = buckets.map(\.seconds).max() ?? 0

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
                sand.withAlphaComponent(lit ? 1 : 0.6).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: area.minY, width: barWidth, height: height),
                             xRadius: radius, yRadius: radius).fill()
            }
        }

        // The line they stand on, then a label under as many bars as will fit without crowding.
        NSColor.separatorColor.setFill()
        NSRect(x: area.minX, y: area.minY - 1, width: area.width, height: 1).fill()
        let widest = buckets.map { text($0.label, size: 10, color: .labelColor).size().width }.max() ?? 0
        let every = max(1, Int(((widest + 10) / slot).rounded(.up)))
        for (index, bucket) in buckets.enumerated() where (buckets.count - 1 - index) % every == 0 {
            let lit = hovered == index || (hovered == nil && index == buckets.count - 1)
            let label = text(bucket.label, size: 10, color: lit ? .labelColor : .tertiaryLabelColor)
            // Drawn from a point rather than into a box, so a label is never wrapped onto a second line, and
            // kept inside the chart, so the one under the last bar doesn't run off the edge.
            let middle = area.minX + slot * (CGFloat(index) + 0.5) - label.size().width / 2
            label.draw(at: NSPoint(x: min(max(area.minX, middle), area.maxX - label.size().width), y: area.minY - 16))
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
