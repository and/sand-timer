import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NSPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let defaults = UserDefaults.standard
        let view = HourglassView(
            minutes: defaults.object(forKey: "minutes") as? Int ?? 30,
            themeIndex: defaults.integer(forKey: "theme"),
            sizeIndex: defaults.object(forKey: "size") as? Int ?? 1
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
        panel.orderFrontRegardless()
        view.startTicking()
        self.panel = panel
    }

    private func initialOrigin(for size: NSSize) -> CGPoint {
        if let saved = UserDefaults.standard.array(forKey: "origin") as? [CGFloat], saved.count == 2 {
            let origin = CGPoint(x: saved[0], y: saved[1])
            let frame = NSRect(origin: origin, size: size)
            if NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) { return origin }
        }
        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return CGPoint(x: visible.maxX - size.width - 40, y: visible.minY + 40)
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
                             themeIndex: Int(value("--theme") ?? "") ?? 0, sizeIndex: 2)
    view.setPreview(progress: Double(value("--progress") ?? "") ?? 0.35, running: !args.contains("--stopped"))
    view.previewAngle = value("--angle").flatMap(Double.init)
    if view.previewAngle != nil {  // room for a tilted glass
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
