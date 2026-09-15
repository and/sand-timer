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
        let view = HourglassView(
            minutes: defaults.object(forKey: "minutes") as? Int ?? HourglassView.defaultMinutes,
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
        // Start at Login is opt-in: ask once, on the first launch, once the timer is on screen.
        if !defaults.bool(forKey: "loginItemConfigured") {
            DispatchQueue.main.async { [weak self] in self?.askAboutStartingAtLogin() }
        }
    }

    private func askAboutStartingAtLogin() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "loginItemConfigured") else { return }
        defaults.set(true, forKey: "loginItemConfigured")  // asked once; the menu option handles any change of mind
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Start Sand Timer when you log in?"
        alert.informativeText = "You can change this any time from the timer's right-click menu."
        alert.addButton(withTitle: "Start at Login")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("Sand Timer: couldn't enable Start at Login: \(error)")
        }
        // macOS may ask the user to allow it in System Settings first.
        if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
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
    let view = HourglassView(minutes: Int(value("--minutes") ?? "") ?? HourglassView.defaultMinutes,
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

/// `SandTimer --iconset Out.iconset` renders the app icon at every size macOS asks for, drawn with the app's own
/// renderer: the purple hourglass, mid-pour, on a warm rounded-square tile. The build turns it into AppIcon.icns.
func renderIconset(to directory: String) throws {
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (points, scales) in [(16, [1, 2]), (32, [1, 2]), (128, [1, 2]), (256, [1, 2]), (512, [1, 2])] {
        for scale in scales {
            let pixels = points * scale
            let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
            try iconImage(pixels: pixels).representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: directory).appendingPathComponent(name))
        }
    }
}

private func iconImage(pixels: Int) -> NSBitmapImageRep {
    let side = CGFloat(pixels)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let cg = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)

    // The standard macOS tile: an 824-point rounded square centered on a 1024-point canvas, with a soft shadow.
    let tile = CGRect(x: side * 100 / 1024, y: side * 100 / 1024, width: side * 824 / 1024, height: side * 824 / 1024)
    let outline = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.3)
    shadow.shadowBlurRadius = side * 0.02
    shadow.shadowOffset = NSSize(width: 0, height: -side * 0.01)
    shadow.set()
    NSColor.white.setFill()
    outline.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: NSColor(srgbRed: 0.99, green: 0.97, blue: 0.93, alpha: 1),
               ending: NSColor(srgbRed: 0.88, green: 0.84, blue: 0.78, alpha: 1))?.draw(in: outline, angle: -90)

    // The hourglass, drawn upright and filling most of the tile's height.
    let view = HourglassView(minutes: 25, themeIndex: 0, baseIndex: 0, sizeIndex: 2)
    view.setPreview(progress: 0.42, running: true)
    let scale = tile.height * 0.84 / view.bounds.height
    cg.translateBy(x: tile.midX, y: tile.midY)
    cg.scaleBy(x: scale, y: -scale)
    cg.translateBy(x: -view.bounds.midX, y: -view.bounds.midY)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
    view.draw(view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let arguments = CommandLine.arguments
if arguments.contains("--snapshot") {
    do { try renderSnapshot(arguments) } catch { print(error); exit(1) }
    exit(0)
}
if let flag = arguments.firstIndex(of: "--iconset"), flag + 1 < arguments.count {
    do { try renderIconset(to: arguments[flag + 1]) } catch { print(error); exit(1) }
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
