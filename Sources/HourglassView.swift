import AppKit
import QuartzCore

/// The overlay's content: draws the timer, flips it on click, and offers settings on right-click.
final class HourglassView: NSView {
    static let durations = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]
    static let sizes: [(name: String, scale: CGFloat)] = [("Small", 0.5), ("Medium", 0.7), ("Large", 1.0)]
    static let pad: CGFloat = 12
    private static let flipDuration: CFTimeInterval = 0.6

    static func contentSize(sizeIndex: Int) -> NSSize {
        let scale = sizes[sizeIndex].scale
        return NSSize(width: ((200 + 2 * pad) * scale).rounded(), height: ((400 + 2 * pad) * scale).rounded())
    }

    private let renderer = HourglassRenderer()
    private var clock: SandClock
    private var minutes: Int
    private var themeIndex: Int
    private var sizeIndex: Int
    private var soundOn = UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true
    private var grainSoundOn = UserDefaults.standard.object(forKey: "grainSoundOn") as? Bool ?? true
    private var flip: (start: CFTimeInterval, fromProgress: Double, restoreFrame: NSRect?)?
    private var wasRunning = false
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var dragged = false
    private var timer: Timer?
    /// Fixed rotation used when rendering a snapshot.
    var previewAngle: CGFloat?

    init(minutes: Int, themeIndex: Int, sizeIndex: Int) {
        self.minutes = Self.durations.contains(minutes) ? minutes : 30
        self.themeIndex = Theme.all.indices.contains(themeIndex) ? themeIndex : 0
        self.sizeIndex = Self.sizes.indices.contains(sizeIndex) ? sizeIndex : 1
        clock = SandClock(duration: TimeInterval(self.minutes * 60))
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize(sizeIndex: self.sizeIndex)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func startTicking() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setPreview(progress: Double, running: Bool) {
        clock = SandClock(duration: clock.duration, progress: progress, runningSince: running ? Date() : nil)
    }

    private func tick() {
        let now = Date()
        let running = clock.isRunning(at: now)
        if soundOn && wasRunning && !running && clock.progress(at: now) >= 1 {
            NSSound(named: "Glass")?.play()
        }
        let patter = grainSoundOn && running && flip == nil
        if let grains = Sounds.grains, patter != grains.isPlaying {
            if patter { grains.play() } else { grains.stop() }
        }
        if running != wasRunning { needsDisplay = true }
        wasRunning = running
        if let flip, CACurrentMediaTime() - flip.start >= Self.flipDuration {
            self.flip = nil
            if let frame = flip.restoreFrame { window?.setFrame(frame, display: false) }
            needsDisplay = true
        }
        if running || flip != nil { needsDisplay = true }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        var progress = clock.progress(at: now)
        var flowing = clock.isRunning(at: now)
        var angle = previewAngle ?? 0
        if let flip {
            let t = min(1, (CACurrentMediaTime() - flip.start) / Self.flipDuration)
            let eased = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
            angle = .pi * CGFloat(eased)
            progress = flip.fromProgress
            flowing = false
        }

        // Fit the (possibly rotated) timer inside the view.
        let w = 200 + 2 * Self.pad, h = 400 + 2 * Self.pad
        let c = abs(cos(angle)), s = abs(sin(angle))
        let k = min(bounds.width / (w * c + h * s), bounds.height / (w * s + h * c))
        ctx.saveGState()
        ctx.translateBy(x: bounds.midX, y: bounds.midY)
        ctx.rotate(by: angle)
        ctx.scaleBy(x: k, y: k)
        ctx.translateBy(x: -100, y: -200)
        let labels = clock.glassLabels(progress: progress)
        renderer.draw(progress: progress, flowing: flowing, time: CACurrentMediaTime(), theme: Theme.all[themeIndex],
                      topLabel: labels.remaining, bottomLabel: labels.elapsed, shadow: angle == 0)
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        guard let window, flip == nil else { return }
        drag = (NSEvent.mouseLocation, window.frame.origin)
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let drag, let window else { return }
        let mouse = NSEvent.mouseLocation
        let dx = mouse.x - drag.mouse.x, dy = mouse.y - drag.mouse.y
        if hypot(dx, dy) > 3 { dragged = true }
        if dragged { window.setFrameOrigin(CGPoint(x: drag.origin.x + dx, y: drag.origin.y + dy)) }
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil }
        guard drag != nil else { return }
        if dragged {
            saveWindowOrigin()
        } else if event.clickCount == 1 {
            flipTimer()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
    }

    private func flipTimer() {
        guard flip == nil else { return }
        let now = Date()
        // Grow the window to a square for the turn so the glass doesn't get clipped.
        var restore: NSRect?
        if let window {
            let frame = window.frame
            let side = frame.height
            restore = frame
            window.setFrame(NSRect(x: frame.midX - side / 2, y: frame.minY, width: side, height: side), display: false)
        }
        flip = (CACurrentMediaTime(), clock.progress(at: now), restore)
        if soundOn { Sounds.flip?.stop(); Sounds.flip?.play() }
        clock.flip(at: now)
        wasRunning = false
        needsDisplay = true
    }

    // MARK: Menu

    private func makeMenu() -> NSMenu {
        let now = Date()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let status = NSMenuItem(title: statusText(at: now), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        if clock.isRunning(at: now) {
            menu.addItem(item("Pause", #selector(pauseClicked)))
        } else if clock.isPaused(at: now) {
            menu.addItem(item("Resume", #selector(resumeClicked)))
        }
        menu.addItem(item("Flip", #selector(flipClicked)))
        menu.addItem(item("Restart", #selector(restartClicked)))
        menu.addItem(.separator())

        menu.addItem(submenu("Duration", Self.durations.map { ("\($0) min", $0, $0 == minutes) }, #selector(durationPicked)))
        menu.addItem(submenu("Color", Theme.all.enumerated().map { ($1.name, $0, $0 == themeIndex) }, #selector(themePicked)))
        menu.addItem(submenu("Size", Self.sizes.enumerated().map { ($1.name, $0, $0 == sizeIndex) }, #selector(sizePicked)))
        let sound = item("Flip & Finish Sounds", #selector(soundToggled))
        sound.state = soundOn ? .on : .off
        menu.addItem(sound)
        let grainSound = item("Falling Sand Sound", #selector(grainSoundToggled))
        grainSound.state = grainSoundOn ? .on : .off
        menu.addItem(grainSound)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Sand Timer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        quit.target = NSApp
        menu.addItem(quit)
        return menu
    }

    private func item(_ title: String, _ action: Selector, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.tag = tag
        return item
    }

    private func submenu(_ title: String, _ entries: [(String, Int, Bool)], _ action: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        for (name, tag, selected) in entries {
            let entry = item(name, action, tag: tag)
            entry.state = selected ? .on : .off
            menu.addItem(entry)
        }
        parent.submenu = menu
        return parent
    }

    private func statusText(at now: Date) -> String {
        let seconds = Int(clock.remaining(at: now).rounded(.up))
        let time = seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
        if clock.isRunning(at: now) { return "\(time) remaining" }
        if clock.isPaused(at: now) { return "Paused · \(time) remaining" }
        return "Done · click the timer to flip it"
    }

    @objc private func pauseClicked() { clock.pause(at: Date()); needsDisplay = true }
    @objc private func resumeClicked() { clock.resume(at: Date()); needsDisplay = true }
    @objc private func flipClicked() { flipTimer() }
    @objc private func restartClicked() { clock.restart(at: Date()); needsDisplay = true }

    @objc private func soundToggled() {
        soundOn.toggle()
        UserDefaults.standard.set(soundOn, forKey: "soundOn")
    }

    @objc private func grainSoundToggled() {
        grainSoundOn.toggle()
        UserDefaults.standard.set(grainSoundOn, forKey: "grainSoundOn")
    }

    @objc private func durationPicked(_ sender: NSMenuItem) {
        minutes = sender.tag
        clock.setDuration(TimeInterval(minutes * 60), at: Date())
        UserDefaults.standard.set(minutes, forKey: "minutes")
        needsDisplay = true
    }

    @objc private func themePicked(_ sender: NSMenuItem) {
        themeIndex = sender.tag
        UserDefaults.standard.set(themeIndex, forKey: "theme")
        needsDisplay = true
    }

    @objc private func sizePicked(_ sender: NSMenuItem) {
        guard let window else { return }
        sizeIndex = sender.tag
        UserDefaults.standard.set(sizeIndex, forKey: "size")
        let size = Self.contentSize(sizeIndex: sizeIndex)
        let frame = window.frame
        window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
        saveWindowOrigin()
    }

    private func saveWindowOrigin() {
        guard let origin = window?.frame.origin else { return }
        UserDefaults.standard.set([origin.x, origin.y], forKey: "origin")
    }
}
