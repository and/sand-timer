import AppKit
import QuartzCore
import ServiceManagement

/// The overlay's content: draws the timer, flips it on click, and offers settings on right-click.
final class HourglassView: NSView {
    /// Includes 6 and 12 minutes: 0.1 and 0.2 of an hour, the time blocks many professionals bill in.
    static let durations = [1, 2, 3, 5, 6, 10, 12, 15, 20, 25, 30, 45, 60]
    /// 25 minutes is the classic Pomodoro work session.
    static let pomodoroMinutes = 25
    /// A new install starts ready for a Pomodoro session.
    static let defaultMinutes = pomodoroMinutes
    /// Where "Support Sand Timer" leads: the README's support section, which offers both GitHub Sponsors and Ko-fi
    /// (Ko-fi doesn't need a GitHub account).
    static let supportURL = URL(string: "https://github.com/and/sand-timer#support-it")!
    static let sizes: [(name: String, scale: CGFloat)] = [("Small", 0.5), ("Medium", 0.7), ("Large", 1.0)]
    static let mediumSizeIndex = 1
    static let pad: CGFloat = 12
    private static let flipDuration = 0.6
    /// Toppling over takes a moment of gathering speed; being stood back up is a gentler lift.
    private static let fallOverDuration = 0.5
    private static let standUpDuration = 0.7
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
    private var base: Theme.Base
    private var sizeIndex: Int
    private var soundOn = UserDefaults.standard.object(forKey: "soundOn") as? Bool ?? true
    private var grainSoundOn = UserDefaults.standard.object(forKey: "grainSoundOn") as? Bool ?? true
    /// "Float Anywhere": the timer stays wherever it's let go instead of falling to the bottom of the screen.
    private(set) var floats = UserDefaults.standard.bool(forKey: "float")
    private var flip: (start: Date, from: SandClock)?
    /// Tipping onto its side to pause, or standing back up. `groundY` is the screen y the timer pivots on.
    private var tip: (from: Double, to: Double, start: Date, pivot: CGPoint, side: Double, then: () -> Void)?
    /// 0 standing up; a quarter turn (positive = fell to the right) while lying on its side, paused.
    private var lyingAngle = 0.0
    /// When the display at the new base switches on after a flip lands.
    private var displayOnAt: Date?
    private static let displayFade = 0.3
    /// Progress when each bulb's sand last settled flat: after a flip lands, when it's stood back up, and gradually while
    /// it's shaken. The top's crater and the bottom's new cone build from there, so a flattened heap stays flat.
    private var topSettledProgress = 0.0
    private var bottomSettledProgress = 0.0
    private var agitation = Agitation()
    /// When sand started through the neck; the stream's front falls from here.
    private var releasedAt: Date?
    /// Gravity the sand feels, as a share of normal: 0 in free fall, above 1 while the timer is jerked upward.
    private var feltGravity = 1.0
    /// When grains stopped leaving the neck because the timer went into free fall; the stream falls away from here.
    private var flowInterruptedAt: Date?
    private var wasRunning = false
    private var wasAnimating = false
    private var drag: (mouse: CGPoint, center: CGPoint, box: CGRect?)?
    private var dragged = false
    private var lastDragSample: (time: TimeInterval, point: CGPoint)?
    private var dragVelocity = CGVector.zero
    private var smoothedVelocity = CGVector.zero
    private var streamLean = StreamLean()
    /// Set while the timer is falling to the bottom of the screen.
    private var drop: Drop?
    /// Extra margin while the window is grown so a turning glass isn't clipped.
    private var expansion: (dx: CGFloat, dy: CGFloat)?
    private var lastTick = CACurrentMediaTime()
    private var lastRedraw = 0.0
    private var timer: Timer?
    /// Called when the user asks to hide the timer in the menu bar.
    var onHide: (() -> Void)?
    /// Snapshot only: angles past the slide threshold show a flip in progress; smaller ones bend the stream.
    var previewAngle: Double?
    /// Snapshot only: how stirred up the sand looks.
    var previewAgitation: Double?

    init(minutes: Int, themeIndex: Int, baseIndex: Int = 0, sizeIndex: Int) {
        self.minutes = Self.durations.contains(minutes) ? minutes : Self.defaultMinutes
        self.themeIndex = Theme.colors.indices.contains(themeIndex) ? themeIndex : 0
        base = Theme.Base(rawValue: baseIndex) ?? .black
        self.sizeIndex = Self.sizes.indices.contains(sizeIndex) ? sizeIndex : 1
        clock = SandClock(duration: TimeInterval(self.minutes * 60))
        super.init(frame: NSRect(origin: .zero, size: Self.contentSize(sizeIndex: self.sizeIndex)))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Seconds between redraws. Anything moving (a flip, a fall, a drag, a shake) gets a smooth 60 fps; sand simply
    /// pouring changes so slowly that 30 fps looks the same and costs about half as much, and 20 in Low Power Mode.
    static func redrawInterval(inMotion: Bool, lowPowerMode: Bool) -> Double {
        inMotion ? 1.0 / 60 : (lowPowerMode ? 1.0 / 20 : 1.0 / 30)
    }

    func startTicking() {
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func setPreview(progress: Double, running: Bool) {
        clock = SandClock(duration: clock.duration, progress: progress, runningSince: running ? Date() : nil)
        releasedAt = running ? .distantPast : nil
        topSettledProgress = 0
        bottomSettledProgress = 0
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

        if let flip, let window {
            // A turning timer is wider and taller than a standing one: walls push it back rather than letting it through.
            moveTimer(to: CGPoint(x: window.frame.midX, y: window.frame.midY), angle: flipAngle(at: now))
            if now.timeIntervalSince(flip.start) >= Self.flipDuration {
                self.flip = nil
                displayOnAt = now
                settleSand(at: now)  // the turn shook both heaps flat
                releasedAt = clock.runningSince == nil ? nil : now.addingTimeInterval(SandPhysics.releaseDelay)
                letGo()  // settle back onto the ground if the turn lifted it
            }
        }

        if let tip {
            if now.timeIntervalSince(tip.start) >= tipDuration(tip) {
                // Now that it's still, move the window to where the timer came to rest and draw it centered again.
                let rest = tipCenter(tip, angle: tip.to)
                self.tip = nil
                lyingAngle = tip.to
                placeWindow(around: rest, expanded: tip.to != 0)
                settleSand(at: now)
                if tip.to != 0 {
                    // Landing on its side jolts the sand: the far end hits at the angular speed of the fall.
                    let spin = 2 * abs(tip.to - tip.from) / Self.fallOverDuration
                    agitation.impact(speed: spin * SandPhysics.timerHeightMeters / 2)
                    if soundOn { Sounds.playFall(impactSpeed: spin * SandPhysics.timerHeightMeters) }
                }
                tip.then()
                letGo()  // tipped over in mid-air: fall the rest of the way
            }
        }

        // How the drag accelerates the timer (including stopping): sideways bends the stream, and hard shakes stir the sand.
        let timerHeight = Double(400 * Self.sizes[sizeIndex].scale)
        let metersPerPoint = SandPhysics.timerHeightMeters / timerHeight
        let dragIsLive = dragged && lastDragSample.map { ProcessInfo.processInfo.systemUptime - $0.time < 0.06 } == true
        let target = dragIsLive ? dragVelocity : .zero
        let blend = min(1, dt * 20)
        let velocity = CGVector(dx: smoothedVelocity.dx + (target.dx - smoothedVelocity.dx) * blend,
                                dy: smoothedVelocity.dy + (target.dy - smoothedVelocity.dy) * blend)
        let change = CGVector(dx: velocity.dx - smoothedVelocity.dx, dy: velocity.dy - smoothedVelocity.dy)
        let accelerationX = abs(change.dx) < 0.01 ? 0 : Double(change.dx) / dt
        smoothedVelocity = hypot(velocity.dx, velocity.dy) < 0.01 ? .zero : velocity
        streamLean.step(acceleration: accelerationX, timerHeightPoints: timerHeight, dt: dt)
        agitation.step(dt: dt)
        agitation.shake(acceleration: Double(hypot(change.dx, change.dy)) / dt * metersPerPoint)
        // What the sand feels: normal gravity plus the timer's upward acceleration, or none at all while it falls
        // freely. Sand pours faster or slower with it, and stops in free fall.
        let upwardAcceleration = Double(change.dy) / dt * metersPerPoint
        let gravityTarget = drop != nil ? 0 : max(0, 1 + upwardAcceleration / SandPhysics.earthGravity)
        feltGravity += (gravityTarget - feltGravity) * min(1, dt / 0.05)
        if flip == nil, tip == nil, clock.isRunning(at: now) {
            clock.shiftFlow(by: (SandPhysics.flowRate(gravityFactor: feltGravity) - 1) * dt)
        }
        if feltGravity < SandPhysics.freeFallThreshold {
            if flowInterruptedAt == nil, streamExtent(at: now) != nil { flowInterruptedAt = now }
        } else if flowInterruptedAt != nil {
            flowInterruptedAt = nil
            releasedAt = now  // gravity is back: grains start leaving the neck again
        }

        if var falling = drop {
            falling.step(dt: dt)
            moveTimer(to: CGPoint(x: window?.frame.midX ?? 0, y: CGFloat(falling.y)), angle: lyingAngle)
            if let speed = falling.impactSpeed {
                let impact = Agitation.impactSpeed(windowSpeed: speed, metersPerPoint: metersPerPoint)
                agitation.impact(speed: impact)
                if soundOn { Sounds.playFall(impactSpeed: impact) }
            }
            drop = falling.isResting ? nil : falling
            if falling.isResting { saveWindowOrigin() }
        }

        let stream = streamExtent(at: now)
        // Jolts shake the heaps flatter, and they stay that way: new sand builds on the leveled sand.
        let flatten = min(1, agitation.level * dt * 4)
        if flatten > 0 {
            let progress = clock.progress(at: now)
            topSettledProgress += (progress - topSettledProgress) * flatten
            bottomSettledProgress += (progress - bottomSettledProgress) * flatten
        }
        let visible = window?.isVisible == true
        // Shaken sand rattles, louder the more it's stirred up; it fades with the sand as each jolt settles.
        if let rattle = Sounds.shake {
            let level = visible && grainSoundOn ? agitation.level : 0
            if level > 0.02 {
                rattle.volume = Float(min(0.5, level * 0.55))  // a light rattle, not a shaker
                if !rattle.isPlaying { rattle.play() }
            } else if rattle.isPlaying {
                rattle.stop()
            }
        }
        let pouring = visible && grainSoundOn && stream.map { $0.front > 150 && $0.tail < 150 } == true
        Sounds.setPour(active: pouring, glassiness: pouring ? SandPhysics.pourGlassiness(progress: clock.progress(at: now)) : 0)

        let moving = flip != nil || tip != nil || !streamLean.isSettled || !agitation.isSettled
        let inMotion = moving || dragged || drop != nil || smoothedVelocity != .zero
        if tip == nil { setExpanded(flip != nil || lyingAngle != 0) }
        let displaySwitchingOn = displayOnAt.map { now.timeIntervalSince($0) < SandPhysics.releaseDelay + Self.displayFade } ?? false
        let settling = displaySwitchingOn
        let trailing = clock.finishTime.map { now > $0 && now.timeIntervalSince($0) < Self.tailDuration } ?? false
        let animating = running || moving || settling || trailing
        let interval = Self.redrawInterval(inMotion: inMotion || settling,
                                            lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
        if visible && (animating || wasAnimating) && media - lastRedraw >= interval - 0.002 {
            needsDisplay = true
            lastRedraw = media
        }
        wasAnimating = animating
    }

    /// The falling stream as (tail, front) distances below the neck, or nil when nothing is falling.
    private func streamExtent(at now: Date) -> (tail: Double, front: Double)? {
        guard flip == nil, clock.runningSince != nil, let releasedAt, now > releasedAt else { return nil }
        // The stream lets go of the neck when the top runs dry, or when the timer goes into free fall.
        let lettingGo = [clock.finishTime, flowInterruptedAt].compactMap { $0 }.min()
        let tail = lettingGo.map { SandPhysics.fallDistance(after: now.timeIntervalSince($0)) } ?? 0
        guard tail < 400 else { return nil }
        return (tail, SandPhysics.fallDistance(after: now.timeIntervalSince(releasedAt)))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let now = Date()
        var frame = SandFrame(progress: clock.progress(at: now))
        frame.topSettledProgress = topSettledProgress
        frame.bottomSettledProgress = bottomSettledProgress
        var angle = 0.0
        var liftedByHand = 1.0  // a flip lifts the timer off the desk
        if let flip {
            angle = flipAngle(at: now)
            frame.progress = flip.from.progress(at: flip.start)
            // The first jolt of the turn shakes the crater and pile flat, then the sand lets go and slides.
            frame.shapeAmount = max(0, 1 - angle / SandPhysics.slideThreshold)
            frame.turning = SandPhysics.turningSand(angle: angle, progress: frame.progress)
            liftedByHand = abs(cos(angle))
        } else if tip != nil || lyingAngle != 0 {
            angle = tipAngle(at: now)
            // Tipping over shakes the heaps flat before the sand slides along the wall.
            frame.shapeAmount = max(0, 1 - abs(angle) / SandPhysics.slideThreshold)
            frame.turning = SandPhysics.lyingSand(angle: angle, progress: frame.progress)
            frame.agitation = previewAgitation ?? agitation.level
        } else if let previewAngle, previewAngle > SandPhysics.slideThreshold {
            angle = previewAngle
            frame.turning = SandPhysics.turningSand(angle: angle, progress: frame.progress)
            frame.agitation = previewAgitation ?? 0
        } else {
            frame.streamTilt = previewAngle ?? streamLean.angle
            frame.agitation = previewAgitation ?? agitation.level
            frame.stream = streamExtent(at: now)
            frame.landedProgress = SandPhysics.landedProgress(progress: frame.progress, settledProgress: bottomSettledProgress,
                                                              duration: clock.duration, falling: frame.stream != nil)
        }

        let scale = Self.sizes[sizeIndex].scale
        // While tipping over or standing up the window holds still and the timer moves within it, so its position and
        // rotation always change together in the same frame.
        var shift = CGPoint.zero
        if let tip, let window {
            let center = tipCenter(tip, angle: angle)
            shift = CGPoint(x: center.x - window.frame.midX, y: center.y - window.frame.midY)
        }
        func placeTimer(rotated: Bool) {
            ctx.translateBy(x: bounds.midX + shift.x, y: bounds.midY - shift.y)
            if rotated { ctx.rotate(by: CGFloat(angle)) }
            ctx.scaleBy(x: scale, y: scale)
            ctx.translateBy(x: -100, y: -200)
        }
        // The shadow falls on the ground (the bottom of the screen) and fades the higher the timer is above it.
        let groundOffset = SandPhysics.restingHalfHeight(angle: angle)
        var strength = liftedByHand
        if let window, let screen = window.screen ?? NSScreen.main {
            let lowestPoint = window.frame.midY + shift.y - CGFloat(groundOffset) * scale
            strength *= SandPhysics.shadowStrength(heightAboveGround: Double((lowestPoint - screen.visibleFrame.minY) / scale))
        }
        ctx.saveGState()
        placeTimer(rotated: false)
        renderer.drawShadow(groundOffset: CGFloat(groundOffset), lying: CGFloat(abs(sin(angle))), strength: CGFloat(strength))
        ctx.restoreGState()

        ctx.saveGState()
        placeTimer(rotated: true)
        // The base display switches off as the timer is tipped to flip it, and the one that ends up at the bottom
        // switches on as the sand starts falling again.
        func ease(_ t: Double) -> Double { let x = min(1, max(0, t)); return x * x * (3 - 2 * x) }
        var display = BaseDisplay(text: clock.remainingLabel(progress: frame.progress))
        if let flip {
            display.brightness = 1 - ease(now.timeIntervalSince(flip.start) / Self.displayFade)
            display.rotation = -angle
        } else if let displayOnAt {
            display.brightness = ease((now.timeIntervalSince(displayOnAt) - SandPhysics.releaseDelay) / Self.displayFade)
        }
        renderer.neckScale = CGFloat(SandPhysics.neckScale(minutes: Double(minutes)))
        renderer.draw(frame, time: CACurrentMediaTime(), theme: Theme(color: themeIndex, base: base), display: display)
        ctx.restoreGState()
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { return rightMouseDown(with: event) }
        guard let window, flip == nil, tip == nil else { return }
        drop = nil  // caught mid-fall
        drag = (NSEvent.mouseLocation, CGPoint(x: window.frame.midX, y: window.frame.midY), screenBox)
        dragged = false
        lastDragSample = nil
    }

    override func mouseDragged(with event: NSEvent) {
        guard drag != nil else { return }
        let mouse = NSEvent.mouseLocation
        if !dragged, let start = drag?.mouse, hypot(mouse.x - start.x, mouse.y - start.y) > 3 {
            dragged = true
        }
        guard dragged, let drag else { return }
        // The timer follows the hand but stops at the screen's edges. Its speed comes from where it actually is,
        // so slamming into a wall is a sudden stop that jolts the sand.
        let placed = moveTimer(to: CGPoint(x: drag.center.x + mouse.x - drag.mouse.x, y: drag.center.y + mouse.y - drag.mouse.y),
                               angle: lyingAngle, box: drag.box)
        if let last = lastDragSample, event.timestamp > last.time {
            let seconds = CGFloat(event.timestamp - last.time)
            dragVelocity = CGVector(dx: dragVelocity.dx * 0.4 + (placed.x - last.point.x) / seconds * 0.6,
                                    dy: dragVelocity.dy * 0.4 + (placed.y - last.point.y) / seconds * 0.6)
        }
        lastDragSample = (event.timestamp, placed)
    }

    override func mouseUp(with event: NSEvent) {
        defer { drag = nil; dragged = false }
        guard drag != nil else { return }
        if dragged {
            letGo()
        } else if event.clickCount == 1 {
            // Click to start, pause and resume like any timer. A stray click on a running timer only pauses it,
            // which the next click undoes; flipping mid-run is left to the menu.
            let now = Date()
            if clock.isRunning(at: now) {
                pauseClicked()
            } else if clock.isPaused(at: now) {
                resumeClicked()
            } else {
                flipTimer()
            }
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        NSMenu.popUpContextMenu(makeMenu(), with: event, for: self)
    }

    private func flipTimer() {
        guard flip == nil, tip == nil, lyingAngle == 0 else { return }
        let now = Date()
        setExpanded(true)
        flip = (now, clock)
        if soundOn { Sounds.flip?.stop(); Sounds.flip?.play() }
        clock.flip(at: now)
        releasedAt = nil
        wasRunning = false
        needsDisplay = true
    }

    private func flipAngle(at now: Date) -> Double {
        guard let flip else { return 0 }
        let t = min(1, now.timeIntervalSince(flip.start) / Self.flipDuration)
        return .pi * (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
    }

    private func tipDuration(_ tip: (from: Double, to: Double, start: Date, pivot: CGPoint, side: Double, then: () -> Void)) -> Double {
        tip.to == 0 ? Self.standUpDuration : Self.fallOverDuration
    }

    private func tipAngle(at now: Date) -> Double {
        guard let tip else { return lyingAngle }
        let t = min(1, now.timeIntervalSince(tip.start) / tipDuration(tip))
        // Falling over speeds up under gravity until it hits; standing it back up eases in and out.
        let eased = tip.to != 0 ? t * t : (t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2)
        return tip.from + (tip.to - tip.from) * eased
    }

    /// Screen points from the timer's center down to the ground it rests on, when tilted `angle` radians.
    private func halfHeight(angle: Double) -> CGFloat {
        CGFloat(SandPhysics.restingHalfHeight(angle: angle)) * Self.sizes[sizeIndex].scale
    }

    /// Topples the timer onto its side (a quarter turn, positive = to the right) or stands it back up, pivoting on the
    /// bottom corner on that side. Standing up reverses the fall, so it returns to where it was knocked over from.
    private func tipOver(to angle: Double, then: @escaping () -> Void) {
        guard let window, flip == nil, tip == nil, angle != lyingAngle else { return }
        drop = nil
        setExpanded(true)
        let side: Double = (angle != 0 ? angle : lyingAngle) < 0 ? -1 : 1
        let offset = SandPhysics.centerFromPivot(angle: lyingAngle, side: side)
        let scale = Self.sizes[sizeIndex].scale
        let pivot = CGPoint(x: window.frame.midX - CGFloat(offset.x) * scale, y: window.frame.midY - CGFloat(offset.y) * scale)
        let start = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let newTip = (from: lyingAngle, to: angle, start: Date(), pivot: pivot, side: side, then: then)
        tip = newTip
        // One still window big enough for the timer at any angle anywhere along its path.
        let end = tipCenter(newTip, angle: angle)
        let content = Self.contentSize(sizeIndex: sizeIndex)
        let reach = ceil(hypot(content.width, content.height) / 2) + 2
        expansion = nil
        window.setFrame(NSRect(x: floor(min(start.x, end.x) - reach), y: floor(min(start.y, end.y) - reach),
                               width: ceil(abs(end.x - start.x) + 2 * reach), height: ceil(abs(end.y - start.y) + 2 * reach)),
                        display: false)
        if angle == 0, soundOn, let sound = Sounds.standUp(standUpDuration: Self.standUpDuration) {
            sound.stop()
            sound.play()
        }
        needsDisplay = true
    }

    /// Grows the window (keeping the timer in place) while it turns or lies on its side, so nothing is clipped.
    /// Margins are whole points, so growing and shrinking never drifts the window.
    private func setExpanded(_ expanded: Bool) {
        guard let window, expanded != (expansion != nil) else { return }
        if expanded {
            let content = Self.contentSize(sizeIndex: sizeIndex)
            let diagonal = hypot(content.width, content.height)
            let margin = (dx: ceil((diagonal - content.width) / 2), dy: ceil((diagonal - content.height) / 2))
            expansion = margin
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
        if lyingAngle == 0 { menu.addItem(item("Flip", #selector(flipClicked))) }
        menu.addItem(item("Restart", #selector(restartClicked)))
        menu.addItem(.separator())

        let durations = Self.durations.map { ($0 == Self.pomodoroMinutes ? "\($0) min 🍅" : "\($0) min", $0, $0 == minutes) }
        menu.addItem(submenu("Duration", durations, #selector(durationPicked)))
        menu.addItem(submenu("Color", Theme.colors.enumerated().map { ($1.name, $0, $0 == themeIndex) }, #selector(themePicked)))
        menu.addItem(submenu("Base", Theme.Base.allCases.map { ($0.name, $0.rawValue, $0 == base) }, #selector(basePicked)))
        menu.addItem(submenu("Size", Self.sizes.enumerated().map { ($1.name, $0, $0 == sizeIndex) }, #selector(sizePicked)))
        let sound = item("Flip, Fall & Finish Sounds", #selector(soundToggled))
        sound.state = soundOn ? .on : .off
        menu.addItem(sound)
        let grainSound = item("Sand Sounds", #selector(grainSoundToggled))
        grainSound.state = grainSoundOn ? .on : .off
        menu.addItem(grainSound)
        menu.addItem(.separator())

        let login = item("Start at Login", #selector(loginToggled))
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        let float = item("Float Anywhere", #selector(floatToggled))
        float.state = floats ? .on : .off
        menu.addItem(float)
        menu.addItem(item("Hide to Menu Bar", #selector(hideClicked)))
        menu.addItem(.separator())
        menu.addItem(item("Support Sand Timer…", #selector(supportClicked)))
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

    /// Both heaps are level right now: the top's crater and the bottom's cone start over from the current sand.
    private func settleSand(at now: Date) {
        topSettledProgress = clock.progress(at: now)
        bottomSettledProgress = topSettledProgress
    }

    /// "Pause" or "Resume" for the menu bar's menu, or nil when the timer isn't running or paused.
    var pauseActionTitle: String? {
        let now = Date()
        if clock.isRunning(at: now) { return "Pause" }
        return clock.isPaused(at: now) ? "Resume" : nil
    }

    func togglePause() {
        if clock.isRunning(at: Date()) { pauseClicked() } else { resumeClicked() }
    }

    /// Time left for the menu bar while the timer is hidden; nil when no sand is flowing or paused.
    var menuBarTime: String? {
        let now = Date()
        guard clock.isRunning(at: now) || clock.isPaused(at: now) else { return nil }
        return clock.remainingLabel(progress: clock.progress(at: now)) + (clock.isPaused(at: now) ? " ⏸" : "")
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

    /// Pausing a real hourglass means laying it on its side, where no sand can pass the neck.
    @objc private func pauseClicked() {
        guard flip == nil, tip == nil, clock.isRunning(at: Date()) else { return }
        clock.pause(at: Date())
        // Knocked over, it falls toward whichever side has more room: lying down it needs 400 units past its corner.
        var fallRight = true
        if let window, let box = screenBox {
            let halfWidth = CGFloat(SandPhysics.outlineHalfWidth) * Self.sizes[sizeIndex].scale
            fallRight = box.maxX - (window.frame.midX + halfWidth) >= (window.frame.midX - halfWidth) - box.minX
        }
        tipOver(to: fallRight ? .pi / 2 : -.pi / 2) {}
    }

    /// Stands the timer back up; the sand drops into place and starts flowing again.
    @objc private func resumeClicked() {
        guard clock.isPaused(at: Date()) else { return }
        let resume = { [weak self] in
            guard let self else { return }
            clock.resume(at: Date())
            releasedAt = Date().addingTimeInterval(SandPhysics.releaseDelay)
            needsDisplay = true
        }
        if lyingAngle != 0 { tipOver(to: 0, then: resume) } else if tip == nil { resume() }
    }

    @objc private func flipClicked() { flipTimer() }

    @objc private func restartClicked() {
        let restart = { [weak self] in
            guard let self else { return }
            clock.restart(at: Date())
            releasedAt = Date()
            topSettledProgress = 0
            bottomSettledProgress = 0
            needsDisplay = true
        }
        guard flip == nil, tip == nil else { return }
        if lyingAngle != 0 { tipOver(to: 0, then: restart) } else { restart() }
    }

    @objc private func hideClicked() { onHide?() }

    @objc private func floatToggled() {
        floats.toggle()
        UserDefaults.standard.set(floats, forKey: "float")
        letGo()  // floating: stay put; not floating any more: fall to the bottom of the screen
    }
    @objc private func supportClicked() { NSWorkspace.shared.open(Self.supportURL) }

    @objc private func loginToggled() {
        UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        let service = SMAppService.mainApp
        do {
            if service.status == .enabled { try service.unregister() } else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Start at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
        // macOS may ask the user to allow it in System Settings first.
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
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

    @objc private func basePicked(_ sender: NSMenuItem) {
        base = Theme.Base(rawValue: sender.tag) ?? .black
        UserDefaults.standard.set(base.rawValue, forKey: "base")
        needsDisplay = true
    }

    @objc private func sizePicked(_ sender: NSMenuItem) {
        guard let window, flip == nil, tip == nil else { return }
        setExpanded(false)
        sizeIndex = sender.tag
        let size = Self.contentSize(sizeIndex: sizeIndex)
        let frame = window.frame
        window.setFrame(NSRect(x: frame.midX - size.width / 2, y: frame.minY, width: size.width, height: size.height), display: true)
        restOnFloor()
    }

    // MARK: Gravity

    /// Screen y of the timer's center when it rests on the bottom of the screen (just above the Dock),
    /// standing up or lying on its side. Its shadow falls just below.
    private var floorCenterY: CGFloat? {
        guard let screen = window?.screen ?? NSScreen.main else { return nil }
        return screen.visibleFrame.minY + halfHeight(angle: lyingAngle)
    }

    private var screenBox: CGRect? { (window?.screen ?? NSScreen.main)?.visibleFrame }

    /// Where the timer's center is at `angle` along a tip: swung about its pivot corner, kept inside the screen.
    private func tipCenter(_ tip: (from: Double, to: Double, start: Date, pivot: CGPoint, side: Double, then: () -> Void),
                           angle: Double) -> CGPoint {
        let offset = SandPhysics.centerFromPivot(angle: angle, side: tip.side)
        let scale = Self.sizes[sizeIndex].scale
        return keptCenter(CGPoint(x: tip.pivot.x + CGFloat(offset.x) * scale, y: tip.pivot.y + CGFloat(offset.y) * scale), angle: angle)
    }

    /// Sets the window around `center`: the timer's own size, or grown so a turned or lying timer isn't clipped.
    private func placeWindow(around center: CGPoint, expanded: Bool) {
        guard let window else { return }
        let content = Self.contentSize(sizeIndex: sizeIndex)
        var frame = NSRect(x: (center.x - content.width / 2).rounded(), y: (center.y - content.height / 2).rounded(),
                           width: content.width, height: content.height)
        expansion = nil
        if expanded {
            let diagonal = hypot(content.width, content.height)
            let margin = (dx: ceil((diagonal - content.width) / 2), dy: ceil((diagonal - content.height) / 2))
            frame = frame.insetBy(dx: -margin.dx, dy: -margin.dy)
            expansion = margin
        }
        window.setFrame(frame, display: true)
        needsDisplay = true
    }

    /// The nearest center that keeps the timer's outline, tilted `angle` radians, inside the screen.
    private func keptCenter(_ target: CGPoint, angle: Double, box: CGRect? = nil) -> CGPoint {
        guard let box = box ?? screenBox else { return target }
        let scale = Double(Self.sizes[sizeIndex].scale)
        let kept = SandPhysics.keptInside(
            x: Double(target.x), y: Double(target.y),
            halfWidth: SandPhysics.restingHalfWidth(angle: angle) * scale,
            halfHeight: SandPhysics.restingHalfHeight(angle: angle) * scale,
            box: (Double(box.minX), Double(box.maxX), Double(box.minY), Double(box.maxY)))
        return CGPoint(x: kept.x, y: kept.y)
    }

    /// Moves the timer's center toward `target`, keeping its outline (tilted `angle` radians) inside the screen
    /// as if the screen were a box. Works on the window's center, which stays put when the window grows for turning.
    /// Returns where the center ended up.
    @discardableResult
    private func moveTimer(to target: CGPoint, angle: Double, box: CGRect? = nil) -> CGPoint {
        guard let window else { return target }
        let center = keptCenter(target, angle: angle, box: box)
        window.setFrameOrigin(CGPoint(x: (center.x - window.frame.width / 2).rounded(), y: (center.y - window.frame.height / 2).rounded()))
        return center
    }

    /// Let go after a drag: fall to the bottom of the screen.
    @objc private func letGo() {
        guard let window, let floor = floorCenterY else { return }
        if floats {
            // Floating: it stays where it was let go, just kept inside the screen.
            drop = nil
            moveTimer(to: CGPoint(x: window.frame.midX, y: window.frame.midY), angle: lyingAngle)
            saveWindowOrigin()
            return
        }
        let falling = Drop(y: Double(window.frame.midY), floor: Double(floor))
        if falling.isResting {
            moveTimer(to: CGPoint(x: window.frame.midX, y: floor), angle: lyingAngle)
            saveWindowOrigin()
        } else {
            drop = falling
        }
    }

    /// Places the timer resting on the bottom of its screen right away, or, when floating, keeps it where it is.
    func restOnFloor() {
        guard let window, let floor = floorCenterY else { return }
        drop = nil
        if floats {
            moveTimer(to: CGPoint(x: window.frame.midX, y: window.frame.midY), angle: lyingAngle)
            saveWindowOrigin()
            return
        }
        moveTimer(to: CGPoint(x: window.frame.midX, y: floor), angle: lyingAngle)
        saveWindowOrigin()
    }

    private func saveWindowOrigin() {
        guard let window else { return }
        let frame = expansion.map { window.frame.insetBy(dx: $0.dx, dy: $0.dy) } ?? window.frame
        UserDefaults.standard.set([frame.origin.x, frame.origin.y], forKey: "origin")
    }
}
