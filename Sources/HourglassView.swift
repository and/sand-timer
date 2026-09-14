import AppKit
import QuartzCore

/// The overlay's content: draws the timer, flips it on click, and offers settings on right-click.
final class HourglassView: NSView {
    static let durations = [1, 2, 3, 5, 10, 15, 20, 30, 45, 60]
    static let sizes: [(name: String, scale: CGFloat)] = [("Small", 0.5), ("Medium", 0.7), ("Large", 1.0)]
    static let pad: CGFloat = 12
    private static let flipDuration = 0.6
    /// How long the crater and pile take to form again after a flip shakes the sand flat.
    private static let settleDuration = 0.8
    /// Long enough for the last grains to fall from the neck to the pile after the top runs dry.
    private static let tailDuration = 0.45

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
    private var flip: (start: Date, from: SandClock)?
    /// When the last flip landed; the sand's shapes re-form from here.
    private var landedAt: Date?
    /// When sand started through the neck; the stream's front falls from here.
    private var releasedAt: Date?
    private var wasRunning = false
    private var wasAnimating = false
    private var drag: (mouse: CGPoint, origin: CGPoint)?
    private var dragged = false
    private var lastDragSample: (time: TimeInterval, x: CGFloat)?
    private var dragVelocity = 0.0
    private var smoothedVelocity = 0.0
    private var sway = Sway()
    /// Extra margin while the window is grown so a turning or swaying glass isn't clipped.
    private var expansion: (dx: CGFloat, dy: CGFloat)?
    private var lastTick = CACurrentMediaTime()
    private var timer: Timer?
    /// Fixed rotation used when rendering a snapshot: small angles sway, larger ones show a flip in progress.
    var previewAngle: Double?

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
        clock = SandClock(duration: clock.duration, progress: progress, runningSince: running ? Date() : nil, flowStartProgress: 0)
        releasedAt = running ? .distantPast : nil
    }

    private static func smoothstep(_ t: Double) -> Double {
        let x = min(1, max(0, t))
        return x * x * (3 - 2 * x)
    }

    private func tick() {
        let now = Date()
        let media = CACurrentMediaTime()
        let dt = min(0.05, max(0.001, media - lastTick))
        lastTick = media

        let running = clock.isRunning(at: now)
        if soundOn && wasRunning && !running && clock.progress(at: now) >= 1 {
            NSSound(named: "Glass")?.play()
        }
        wasRunning = running

        if let flip, now.timeIntervalSince(flip.start) >= Self.flipDuration {
            self.flip = nil
            landedAt = now
            releasedAt = clock.runningSince == nil ? nil : now.addingTimeInterval(SandPhysics.releaseDelay)
        }

        // Sway: the drag's sideways speed (zero once the mouse stops moving) accelerates the spring.
        let dragIsLive = dragged && lastDragSample.map { ProcessInfo.processInfo.systemUptime - $0.time < 0.06 } == true
        let velocity = smoothedVelocity + ((dragIsLive ? dragVelocity : 0) - smoothedVelocity) * min(1, dt * 20)
        let acceleration = abs(velocity - smoothedVelocity) < 0.01 ? 0 : (velocity - smoothedVelocity) / dt
        smoothedVelocity = abs(velocity) < 0.01 ? 0 : velocity
        sway.step(acceleration: acceleration, dt: dt)

        let stream = streamExtent(at: now)
        let patter = grainSoundOn && stream.map { $0.front > 150 && $0.tail < 150 } == true
        if let grains = Sounds.grains, patter != grains.isPlaying {
            if patter { grains.play() } else { grains.stop() }
        }

        let moving = flip != nil || dragged || !sway.isSettled || smoothedVelocity != 0
        if !moving { setExpanded(false) }
        let settling = landedAt.map { now.timeIntervalSince($0) < Self.settleDuration } ?? false
        let trailing = clock.finishTime.map { now > $0 && now.timeIntervalSince($0) < Self.tailDuration } ?? false
        let animating = running || moving || settling || trailing
        if animating || wasAnimating { needsDisplay = true }
        wasAnimating = animating
    }

    /// The falling stream as (tail, front) distances below the neck, or nil when nothing is falling.
    private func streamExtent(at now: Date) -> (tail: Double, front: Double)? {
        guard flip == nil, clock.runningSince != nil, let releasedAt, now > releasedAt else { return nil }
        let tail = clock.finishTime.map { SandPhysics.fallDistance(after: now.timeIntervalSince($0)) } ?? 0
        guard tail < 400 else { return nil }
        return (tail, SandPhysics.fallDistance(after: now.timeIntervalSince(releasedAt)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        var frame = SandFrame(progress: clock.progress(at: now), flowStartProgress: clock.flowStartProgress)
        var angle = 0.0
        if let flip {
            let t = min(1, now.timeIntervalSince(flip.start) / Self.flipDuration)
            angle = .pi * (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
            frame.progress = flip.from.progress(at: flip.start)
            frame.flowStartProgress = flip.from.flowStartProgress
            // The first jolt of the turn shakes the crater and pile flat, then the sand lets go and slides.
            frame.shapeAmount = max(0, 1 - angle / SandPhysics.slideThreshold)
            frame.turning = SandPhysics.turningSand(angle: angle, progress: frame.progress)
        } else if let previewAngle, previewAngle > SandPhysics.slideThreshold {
            angle = previewAngle
            frame.turning = SandPhysics.turningSand(angle: angle, progress: frame.progress)
        } else {
            angle = previewAngle ?? sway.tilt
            frame.surfaceTilt = previewAngle ?? sway.sandTilt
            frame.streamTilt = angle
            frame.shapeAmount = landedAt.map { Self.smoothstep(now.timeIntervalSince($0) / Self.settleDuration) } ?? 1
            frame.stream = streamExtent(at: now)
        }

        let scale = Self.sizes[sizeIndex].scale
        func placeTimer(rotated: Bool) {
            ctx.translateBy(x: bounds.midX, y: bounds.midY)
            if rotated { ctx.rotate(by: CGFloat(angle)) }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -100, y: -200)
        }
        ctx.saveGState()
        placeTimer(rotated: false)
        renderer.drawShadow(opacity: CGFloat(abs(cos(angle))))
        ctx.restoreGState()

        ctx.saveGState()
        placeTimer(rotated: true)
        let labels = clock.glassLabels(progress: frame.progress)
        renderer.draw(frame, time: CACurrentMediaTime(), theme: Theme.all[themeIndex],
                      topLabel: labels.remaining, bottomLabel: labels.elapsed)
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        guard let window, flip == nil else { return }
        drag = (NSEvent.mouseLocation, window.frame.origin)
        dragged = false
        lastDragSample = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil, let window else { return }
        let mouse = NSEvent.mouseLocation
        if !dragged, let start = drag?.mouse, hypot(mouse.x - start.x, mouse.y - start.y) > 3 {
            dragged = true
            setExpanded(true)
        }
        guard dragged, let drag else { return }
        window.setFrameOrigin(CGPoint(x: drag.origin.x + mouse.x - drag.mouse.x, y: drag.origin.y + mouse.y - drag.mouse.y))
        if let last = lastDragSample, event.timestamp > last.time {
            let speed = Double((mouse.x - last.x) / CGFloat(event.timestamp - last.time))
            dragVelocity = dragVelocity * 0.4 + speed * 0.6
        }
        lastDragSample = (event.timestamp, mouse.x)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; dragged = false }
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
        setExpanded(true)
        flip = (now, clock)
        if soundOn { Sounds.flip?.stop(); Sounds.flip?.play() }
        clock.flip(at: now)
        releasedAt = nil
        wasRunning = false
        needsDisplay = true
    }

    /// Grows the window (keeping the timer in place) while it turns or sways, so nothing is clipped.
    /// Margins are whole points, so growing and shrinking never drifts the window.
    private func setExpanded(_ expanded: Bool) {
        guard let window, expanded != (expansion != nil) else { return }
        if expanded {
            let content = Self.contentSize(sizeIndex: sizeIndex)
            let diagonal = hypot(content.width, content.height)
            let margin = (dx: ceil((diagonal - content.width) / 2), dy: ceil((diagonal - content.height) / 2))
            expansion = margin
            drag?.origin.x -= margin.dx
            drag?.origin.y -= margin.dy
            window.setFrame(window.frame.insetBy(dx: -margin.dx, dy: -margin.dy), display: true)
        } else if let margin = expansion {
            expansion = nil
            window.setFrame(window.frame.insetBy(dx: margin.dx, dy: margin.dy), display: true)
        }
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
    @objc private func resumeClicked() {
        clock.resume(at: Date())
        releasedAt = Date()
        needsDisplay = true
    }
    @objc private func flipClicked() { flipTimer() }
    @objc private func restartClicked() {
        guard flip == nil else { return }
        clock.restart(at: Date())
        releasedAt = Date()
        landedAt = nil
        needsDisplay = true
    }

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
        guard let window, flip == nil else { return }
        setExpanded(false)
        sizeIndex = sender.tag
        UserDefaults.standard.set(sizeIndex, forKey: "size")
        let size = Self.contentSize(sizeIndex: sizeIndex)
        let frame = window.frame
        window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
        saveWindowOrigin()
    }

    private func saveWindowOrigin() {
        guard let window else { return }
        let frame = expansion.map { window.frame.insetBy(dx: $0.dx, dy: $0.dy) } ?? window.frame
        UserDefaults.standard.set([frame.origin.x, frame.origin.y], forKey: "origin")
    }
}
