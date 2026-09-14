import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var panel: NSPanel?
    private var view: HourglassView?
    /// Present only while the timer is hidden in the menu bar.
    private var statusItem: NSStatusItem?
    private var statusTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        // Start at Login is on by default; once set up (or changed from the menu) the user's choice is left alone.
        if !defaults.bool(forKey: "loginItemConfigured") {
            defaults.set(true, forKey: "loginItemConfigured")
            do { try SMAppService.mainApp.register() } catch { NSLog("Sand Timer: couldn't enable Start at Login: \(error)") }
            NSLog("Sand Timer: Start at Login status \(SMAppService.mainApp.status.rawValue)")
        }
        let view = HourglassView(
            minutes: defaults.object(forKey: "minutes") as? Int ?? 30,
            themeIndex: defaults.integer(forKey: "theme"),
            baseIndex: defaults.integer(forKey: "base"),
            sizeIndex: HourglassView.mediumSizeIndex  // always starts at Medium; the Size menu changes it for this session
        )

        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.contentView = view
        panel.setFrameOrigin(initialOrigin(for: view.frame.size))
        view.restOnFloor()
        view.onHide = { [weak self] in self?.hideToMenuBar() }
        view.startTicking()
        self.panel = panel
        self.view = view
        if defaults.bool(forKey: "hidden") { hideToMenuBar() } else { panel.orderFrontRegardless() }
    }

    /// Puts the timer away as an hourglass in the menu bar, with the time left beside it while it runs.
    private func hideToMenuBar() {
        guard statusItem == nil else { return }
        panel?.orderOut(nil)
        UserDefaults.standard.set(true, forKey: "hidden")

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Sand Timer")
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self  // rebuilt each time it opens, so Pause/Resume matches the timer
        item.menu = menu
        statusItem = item

        updateStatusTitle()
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.updateStatusTitle() }
        RunLoop.main.add(timer, forMode: .common)
        statusTimer = timer
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func add(_ title: String, _ action: Selector, target: AnyObject?) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = target
            menu.addItem(item)
        }
        add("Show Sand Timer", #selector(showTimer), target: self)
        if let title = view?.pauseActionTitle { add(title, #selector(togglePause), target: self) }
        menu.addItem(.separator())
        add("Quit Sand Timer", #selector(NSApplication.terminate(_:)), target: NSApp)
    }

    @objc private func togglePause() {
        view?.togglePause()
        updateStatusTitle()
    }

    @objc private func showTimer() {
        statusTimer?.invalidate()
        statusTimer = nil
        if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
        statusItem = nil
        UserDefaults.standard.set(false, forKey: "hidden")
        view?.restOnFloor()
        panel?.orderFrontRegardless()
    }

    private func updateStatusTitle() {
        statusItem?.button?.title = view?.menuBarTime.map { " " + $0 } ?? ""
    }

    /// Where it was last left horizontally (if that's still on a screen), else the right side; the view then settles it
    /// onto the bottom of that screen.
    private func initialOrigin(for size: NSSize) -> CGPoint {
        if let saved = UserDefaults.standard.array(forKey: "origin") as? [CGFloat], saved.count == 2,
           let screen = NSScreen.screens.first(where: { $0.visibleFrame.minX <= saved[0] && saved[0] + size.width <= $0.visibleFrame.maxX }) {
            return CGPoint(x: saved[0], y: screen.visibleFrame.minY)
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.maxX - size.width - 40, y: visible.minY)
    }
}

/// `SandTimer --snapshot out.png [--progress 0.4] [--theme 0] [--angle 0.8] [--stopped] [--dark]`
/// renders one frame to a PNG without opening a window.
func renderSnapshot(_ args: [String]) throws {
    func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    let view = HourglassView(minutes: Int(value("--minutes") ?? "") ?? 30,
                             themeIndex: Int(value("--theme") ?? "") ?? 0, baseIndex: Int(value("--base") ?? "") ?? 0, sizeIndex: 2)
    view.setPreview(progress: Double(value("--progress") ?? "") ?? 0.35, running: !args.contains("--stopped"))
    view.previewAngle = value("--angle").flatMap(Double.init)
    view.previewAgitation = value("--shake").flatMap(Double.init)
    if let angle = view.previewAngle, abs(angle) > SandPhysics.slideThreshold {  // room for a turning glass
        let side = hypot(view.frame.width, view.frame.height).rounded(.up)
        view.frame.size = NSSize(width: side, height: side)
    }

    let size = view.bounds.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * 2), pixelsHigh: Int(size.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    cg.translateBy(x: 0, y: size.height)
    cg.scaleBy(x: 1, y: -1)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    (args.contains("--dark") ? NSColor(white: 0.13, alpha: 1) : NSColor.white).setFill()
    view.bounds.fill()
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: value("--snapshot")!))
}

let arguments = CommandLine.arguments
if arguments.contains("--snapshot") {
    do { try renderSnapshot(arguments) } catch { print(error); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
