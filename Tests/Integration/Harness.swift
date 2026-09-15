import AppKit

/// The real timer view in a floating window, set up the way the app does it, with helpers to drive it like a user.
final class TimerHarness {
    let view: HourglassView
    let panel: NSPanel

    init(minutes: Int = 1, color: Int = 0, base: Int = 0, size: Int = 2, x: CGFloat? = nil) {
        sizeIndex = size
        view = HourglassView(minutes: minutes, themeIndex: color, baseIndex: base, sizeIndex: size)
        panel = NSPanel(contentRect: NSRect(origin: .zero, size: view.frame.size),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.level = .floating
        panel.contentView = view
        let screen = NSScreen.main?.visibleFrame ?? .zero
        panel.setFrameOrigin(CGPoint(x: x ?? screen.midX - view.frame.width / 2, y: screen.midY))
        view.restOnFloor()
        // The view reads the hand from here, so tests move a finger instead of the real pointer.
        view.handLocation = { [unowned self] in self.fingerOnScreen ?? NSEvent.mouseLocation }
        panel.orderFrontRegardless()
        view.startTicking()
    }

    deinit { panel.orderOut(nil) }

    var screen: CGRect { panel.screen?.visibleFrame ?? NSScreen.main!.visibleFrame }
    var center: CGPoint { CGPoint(x: panel.frame.midX, y: panel.frame.midY) }
    var scale: CGFloat { HourglassView.sizes[sizeIndex].scale }
    var sizeIndex: Int

    func run(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// Waits for a flip, fall, tip-over or stand-up to finish, however busy the machine is: at least `minimum` seconds
    /// (the window holds still while the glass turns), then until the window has stopped moving.
    func settle(minimum: Double = 0.8, timeout: Double = 5) {
        run(minimum)
        let deadline = Date().addingTimeInterval(timeout)
        var last = panel.frame, stillSince = Date()
        while Date() < deadline {
            run(0.05)
            if panel.frame != last {
                last = panel.frame
                stillSince = Date()
            } else if Date().timeIntervalSince(stillSince) >= 0.3 {
                return
            }
        }
    }

    /// A plain click in the middle of the timer.
    func click() {
        let point = NSPoint(x: view.bounds.midX, y: view.bounds.midY)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            if type == .leftMouseDown { view.mouseDown(with: event) } else { view.mouseUp(with: event) }
        }
    }

    private var fingerOnScreen: CGPoint?

    /// Presses on the middle of the top cap, like putting a finger on a real timer.
    func pressTopCap() {
        guard let top = view.topCapScreenPoint else { return }
        fingerOnScreen = top
        sendMouse(.leftMouseDown, at: panel.convertPoint(fromScreen: top))
    }

    /// Lifts a toppled timer by its top cap (already pressed), sweeping the hand around the corner it lies on until the
    /// timer leans `target` radians from upright.
    func liftTopCap(toLean target: Double, from lying: Double, pivot: CGPoint, steps: Int = 24) {
        let side: Double = lying < 0 ? -1 : 1
        for i in 1...steps {
            let angle = lying + (target - lying) * Double(i) / Double(steps)
            let offset = SandPhysics.topCapFromPivot(angle: angle, side: side)
            let screen = CGPoint(x: pivot.x + CGFloat(offset.x) * scale, y: pivot.y + CGFloat(offset.y) * scale)
            sendMouse(.leftMouseDragged, at: panel.convertPoint(fromScreen: screen))
            fingerOnScreen = screen
            run(1.0 / 60)
        }
    }

    /// Pushes the pressed top cap sideways by `points`, a little at a time.
    func pushTopCap(by points: CGFloat, steps: Int = 12) {
        moveTopCap(by: CGVector(dx: points, dy: 0), steps: steps)
    }

    /// Moves the finger pressing the top cap by `offset` screen points (y up), in `steps` even moves a frame apart.
    func moveTopCap(by offset: CGVector, steps: Int = 12) {
        guard let start = fingerOnScreen else { return }
        for i in 1...steps {
            let fraction = CGFloat(i) / CGFloat(steps)
            fingerOnScreen = CGPoint(x: start.x + offset.dx * fraction, y: start.y + offset.dy * fraction)
            sendMouse(.leftMouseDragged, at: panel.convertPoint(fromScreen: fingerOnScreen!))
            run(1.0 / 60)
        }
    }

    func releaseTopCap() {
        guard let finger = fingerOnScreen else { return }
        sendMouse(.leftMouseUp, at: panel.convertPoint(fromScreen: finger))
        fingerOnScreen = nil
    }

    private func sendMouse(_ type: NSEvent.EventType, at point: NSPoint) {
        let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        switch type {
        case .leftMouseDown: view.mouseDown(with: event)
        case .leftMouseDragged: view.mouseDragged(with: event)
        default: view.mouseUp(with: event)
        }
    }

    /// Triggers a menu command, as if chosen from the right-click menu.
    func menu(_ action: String, tag: Int? = nil) {
        if let tag {
            let item = NSMenuItem()
            item.tag = tag
            view.perform(NSSelectorFromString(action + ":"), with: item)
        } else {
            view.perform(NSSelectorFromString(action))
        }
    }

    var isRunning: Bool { view.pauseActionTitle == "Pause" }
    var isPaused: Bool { view.pauseActionTitle == "Resume" }

    func render() -> NSBitmapImageRep {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep
    }

    /// Height (in the timer's 400-unit drawing space) of the purple sand in the lower bulb, measured at `offset` units
    /// from the center line: how far above the bottom cap the topmost sand pixel in that column sits.
    func bottomSandHeight(atOffset offset: CGFloat) -> CGFloat? {
        let rep = render()
        let pixelsPerUnit = CGFloat(rep.pixelsWide) / view.bounds.width * scale
        let column = Int((view.bounds.midX / view.bounds.width) * CGFloat(rep.pixelsWide) + offset * pixelsPerUnit)
        func row(forUnit y: CGFloat) -> Int { Int((view.bounds.midY / view.bounds.height) * CGFloat(rep.pixelsHigh) + (y - 200) * pixelsPerUnit) }
        let capRow = row(forUnit: 354)
        for y in row(forUnit: 215)..<capRow {
            guard let c = rep.colorAt(x: column, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
            if c.blueComponent > c.redComponent * 1.3 && c.blueComponent > c.greenComponent * 1.8 {
                return CGFloat(capRow - y) / pixelsPerUnit
            }
        }
        return nil
    }

    /// Screen distance from the bottom of the timer's solid pixels down to the bottom of the usable screen.
    func gapBelowTimer() -> CGFloat {
        let rep = render()
        var lowest = -1
        rows: for y in stride(from: rep.pixelsHigh - 1, through: 0, by: -1) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.95 {
                lowest = y
                break rows
            }
        }
        let pointsPerPixel = view.bounds.height / CGFloat(rep.pixelsHigh)
        return panel.frame.minY + CGFloat(rep.pixelsHigh - 1 - lowest) * pointsPerPixel - screen.minY
    }
}
